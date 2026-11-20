///|
/// §451: the AV1 encoder session — a sequence-level API wrapping the
/// §446a-§449b machinery. Frame 0 is a key frame (4×32x32 intra
/// DC_PRED blocks with real quantized residuals via the pseudo-inverse
/// fdct, §451a); frames ≥ 1 are full-residual inter frames (ME +
/// MC + pseudo-inverse quantization, §449a/§449b). Every frame is
/// returned as one size-delimited packet (TD + sequence header on the
/// first packet + frame OBU); the expected reconstruction planes are
/// handed back for pixel round-trip assertions.

///|
/// The source/reference plane set for one frame.
pub(all) struct Av1EncPlanes {
  y : FixedArray[Int32]
  y_stride : Int32
  u : FixedArray[Int32]
  uv_stride : Int32
  v : FixedArray[Int32]
}

///|
/// The AV1 encoder session (4:2:0, 8-bit, 64-multiple geometry).
pub struct Av1Encoder {
  seq : Av1SequenceParameters
  seq_obu : Bytes
  refs : Av1RefmvsReferenceStore
  mut frames : Int32
  mut last_ref : Av1EncPlanes?
}

///|
/// Create the session and the sequence-header OBU.
pub fn Av1Encoder::new(cfg : Av1SeqEncConfig) -> Av1Encoder raise {
  let seq_obu = match av1_enc_write_sequence_header_obu(cfg) {
    Ok(b) => b
    Err(e) => fail("seq header: \{e}")
  }
  let seq = match av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail("seq parse: \{e}")
  }
  if seq.width % 64 != 0 || seq.height % 64 != 0 {
    fail("geometry must be 64-multiples")
  }
  {
    seq,
    seq_obu,
    refs: av1_refmvs_reference_store_new(),
    frames: 0,
    last_ref: None,
  }
}

///|
/// Encode one frame from the source planes. Returns the packet bytes
/// (TD + [seq] + frame) and the expected reconstruction planes (the
/// decoder will realize these pixel-for-pixel; feed them back as the
/// next frame's reference view or just assert against the decode).
pub fn Av1Encoder::encode_frame(
  self : Av1Encoder,
  src : Av1EncPlanes,
  base_q_idx~ : Int32 = 100,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
  rd_lambda? : Int32,
  rd_candidates? : Array[Int32],
  skip_sad_pct? : Int32,
) -> Result[(Bytes, Av1EncPlanes), String] {
  let w = self.seq.width
  let h = self.seq.height
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  let dq_tbl = if self.seq.bitdepth == 8 {
    av1_dq_tbl_0
  } else if self.seq.bitdepth == 10 {
    av1_dq_tbl_1
  } else {
    av1_dq_tbl_2
  }
  let ydc_tbl = dq_tbl[base_q_idx * 2].to_int()
  let yac_tbl = dq_tbl[base_q_idx * 2 + 1].to_int()
  let td = av1_enc_write_temporal_delimiter()
  let parts : Array[Bytes] = [td]
  if self.frames == 0 {
    parts.push(self.seq_obu)
  }
  if self.frames == 0 {
    // ---- Key frame: per-tile intra DC + residuals.
    let basis32 = av1_enc_itx_basis(3)
    let basis16 = av1_enc_itx_basis(2)
    // The frame's dq_u_* deltas are zero, so the chroma qindices equal
    // base_q_idx (fill_dq: udc = uac = base_q_idx + 0) — but the dc/ac
    // table COLUMNS differ, so the two entries stay separate.
    let udc_tbl = dq_tbl[base_q_idx * 2].to_int()
    let uac_tbl = dq_tbl[base_q_idx * 2 + 1].to_int()
    let sb_cols = w >> 6
    let sb_rows = h >> 6
    let tiles : Array[Bytes] = []
    let expected_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
    let expected_u : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
    let expected_v : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
    for try_ in 0..<sb_rows {
      for tx_ in 0..<sb_cols {
        let tile = match
          av1_enc_write_intra_dc_tile(
            src.y,
            try_ * 64 * w + tx_ * 64,
            src.y_stride,
            src.u,
            try_ * 32 * cw + tx_ * 32,
            src.uv_stride,
            src.v,
            expected_y,
            try_ * 64 * w + tx_ * 64,
            w,
            expected_u,
            try_ * 32 * cw + tx_ * 32,
            cw,
            expected_v,
            base_q_idx,
            basis32,
            basis16,
            ydc_tbl,
            yac_tbl,
            udc_tbl,
            uac_tbl,
            dz_pm~,
          ) {
          Ok(t) => t
          Err(e) => return Err(e)
        }
        tiles.push(tile)
      }
    }
    let kf_obu = match
      av1_enc_write_key_frame_obu(self.seq, {
        ..Av1KeyFrameEncConfig::default(),
        base_q_idx,
        tiles,
        tile_cols: sb_cols,
        tile_rows: sb_rows,
      }) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    parts.push(kf_obu)
    self.refs.refresh_without_mvs(0, w, h, 255)
    let out : Array[Byte] = []
    for part in parts {
      for i = 0; i < part.length(); i = i + 1 {
        out.push(part[i])
      }
    }
    self.frames = self.frames + 1
    let planes : Av1EncPlanes = {
      y: expected_y,
      y_stride: w,
      u: expected_u,
      uv_stride: cw,
      v: expected_v,
    }
    self.last_ref = Some(planes)
    return Ok((Bytes::from_array(out[:]), planes))
  }
  // ---- Inter frames: the §449b full-residual pipeline. The encoder's
  // reference = the previous frame's expected reconstruction (the
  // decoder's slot 0 realizes it — validated by the frame's own
  // exactness assertion in the tests).
  let ref_p = match self.last_ref {
    Some(p) => p
    None => return Err("inter frame without a key frame")
  }
  // §457: with `rd_lambda~`, pick the qindex that minimizes
  // lambda*SAD + bits*1000 over the candidate ladder (default when only
  // the lambda is given). The selector trial-encodes on a private refmvs
  // fork, so self.refs is untouched; the real encode below re-encodes the
  // winner against the untouched state.
  let q = match rd_lambda {
    Some(lambda) => {
      let cands = match rd_candidates {
        Some(c) => c
        None => av1_enc_rd_default_q_candidates()
      }
      match
        av1_enc_rd_select_q_inter(
          self.seq,
          self.refs,
          src.y,
          src.y_stride,
          src.u,
          src.uv_stride,
          src.v,
          ref_p.y,
          ref_p.y_stride,
          ref_p.u,
          ref_p.uv_stride,
          ref_p.v,
          cands,
          lambda~,
          range~,
          dz_pm~,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    None => base_q_idx
  }
  // §458: when `skip_sad_pct~` is positive, static zero-MV SBs take the
  // GLOBALMV skip path (no residual token chain). Both entries return the
  // same (obu, exp_y, exp_u, exp_v) shape; the skip one differs only in
  // the per-SB mode decision and the exact reconstruction it implies.
  let use_skip = match skip_sad_pct {
    Some(pct) => pct > 0
    None => false
  }
  let result = if use_skip {
    av1_enc_write_me_skip420_inter_frame_obu(
      self.seq,
      self.refs,
      src.y,
      src.y_stride,
      src.u,
      src.uv_stride,
      src.v,
      ref_p.y,
      ref_p.y_stride,
      ref_p.u,
      ref_p.uv_stride,
      ref_p.v,
      base_q_idx=q,
      range~,
      dz_pm~,
      skip_sad_pct=skip_sad_pct.unwrap(),
    )
  } else {
    av1_enc_write_me_res420_inter_frame_obu(
      self.seq,
      self.refs,
      src.y,
      src.y_stride,
      src.u,
      src.uv_stride,
      src.v,
      ref_p.y,
      ref_p.y_stride,
      ref_p.u,
      ref_p.uv_stride,
      ref_p.v,
      base_q_idx=q,
      range~,
      dz_pm~,
    )
  }
  let (frame_obu, exp_y, exp_u, exp_v) = match result {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  parts.push(frame_obu)
  let out : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  self.frames = self.frames + 1
  let planes : Av1EncPlanes = {
    y: exp_y,
    y_stride: w,
    u: exp_u,
    uv_stride: cw,
    v: exp_v,
  }
  self.last_ref = Some(planes)
  Ok((Bytes::from_array(out[:]), planes))
}
