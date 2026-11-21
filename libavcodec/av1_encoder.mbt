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
  /// §464: the reconstructed picture in every reference slot (index =
  /// the AV1 slot 0..7). `None` means the slot has never been refreshed.
  /// This mirrors the decoder's reference-frame store so an inter frame
  /// can predict from an older picture, not just the previous one.
  slots : FixedArray[Av1EncPlanes?]
  /// §464: which slot the most recent frame was written to (the "current"
  /// reference); the next frame refreshes the following slot.
  mut cur_slot : Int32
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
    slots: FixedArray::make(8, None),
    cur_slot: 0,
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
  skip_uniform~ : Bool = false,
  /// §462: jointly choose qindex AND skip threshold by trial-encoding
  /// both shapes. When set, this overrides the separate rd_lambda~ /
  /// skip_sad_pct~ paths for inter frames (the lambda is rd_lambda or
  /// 1000 when unset).
  rd_skip_pcts? : Array[Int32],
  /// §464: which past reconstruction to predict from. 0 = the previous
  /// frame (default, the pre-§464 behaviour); k = the picture encoded k
  /// frames ago. The chosen picture's slot is what the frame header's
  /// ref_frame_idx entries point at, so the decoder resolves the same
  /// picture. Values beyond the retained history fall back to the oldest
  /// available slot.
  ref_age~ : Int32 = 0,
  /// §465: jointly choose qindex, skip threshold AND reference age by
  /// trial-encoding every combination. The list holds the ages to try
  /// (0 = previous frame); the encoder resolves each to the slot ring.
  /// When set, this takes precedence over rd_skip_pcts~ / rd_lambda~ /
  /// ref_age~ for inter frames.
  rd_ref_ages? : Array[Int32],
  /// §468 (first step): loop-filter levels for the frame header. Default
  /// 0 keeps deblocking off, matching every prior behaviour. NOTE: setting
  /// these makes the DECODER filter the reconstruction while the encoder's
  /// expected planes are still unfiltered, so the frame's pixel-exactness
  /// contract no longer holds until the encoder applies the same filter
  /// (the §468 second step). Provided now so the header path can be
  /// exercised and verified independently.
  loop_filter_level0~ : Int32 = 0,
  loop_filter_level1~ : Int32 = 0,
  loop_filter_sharpness~ : Int32 = 0,
  /// §498: the per-SB 64x64-vs-32x32 partition SAD margin for inter
  /// frames. 0 (default) keeps the §449b single-partition residual path;
  /// a value ≥ 0 routes it through the partitioned pipeline, where an SB
  /// splits into four 32x32 blocks when their quadrant SADs beat the
  /// whole-SB SAD by more than the margin. Loop-filter levels must stay
  /// 0 in this mode (the deblock mirror is not partition-aware yet).
  split_margin~ : Int32 = 0,
  /// §499: NEARMV stack hits (drl bools, no MV payload) instead of NEWMV
  /// when a deeper refmv candidate equals the target. Applies to the
  /// residual inter paths (me_res420 and the partitioned pipeline).
  drl~ : Bool = false,
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
        loop_filter_level0,
        loop_filter_level1,
        loop_filter_sharpness,
        tiles,
        tile_cols: sb_cols,
        tile_rows: sb_rows,
      }) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    parts.push(kf_obu)
    // §468b: the decoder runs the in-loop deblocking filter after
    // reconstructing, so the encoder must apply the same filter to its own
    // reconstruction for the "expected == decoded" contract to hold. The
    // filter is a no-op when every level is zero.
    if loop_filter_level0 != 0 ||
      loop_filter_level1 != 0 ||
      loop_filter_sharpness != 0 {
      let hdr = match av1_parse_frame_header(kf_obu, self.seq) {
        Ok(h) => h
        Err(e) => return Err(e)
      }
      let _ = av1_enc_deblock_frame(
        expected_y,
        w,
        expected_u,
        expected_v,
        cw,
        w,
        h,
        hdr,
        3, // key luma blocks are TX_32X32
        2, // 4:2:0 chroma is TX_16X16
        !self.seq.monochrome,
        1,
        1,
        8,
      )
    }
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
    // §464: the key frame refreshes every slot in the decoder
    // (refresh_mask 0xFF), so mirror that in the session's ring.
    for i in 0..<8 {
      self.slots[i] = Some(planes)
    }
    self.cur_slot = 0
    self.last_ref = Some(planes)
    return Ok((Bytes::from_array(out[:]), planes))
  }
  // ---- Inter frames: the §449b full-residual pipeline. §464: the
  // reference is `ref_age` frames back, taken from the session's slot
  // store; the frame header's ref_frame_idx entries point at that slot
  // so the decoder resolves the same picture.
  let n_hist = if self.frames < 8 { self.frames } else { 8 }
  if n_hist <= 0 {
    return Err("inter frame without a key frame")
  }
  // Walk back `ref_age` frames through the slot ring. cur_slot holds the
  // most recent frame; slot k back is (cur_slot - k) mod 8.
  let age = if ref_age < 0 { 0 } else { ref_age }
  let capped = if age >= n_hist { n_hist - 1 } else { age }
  let mut ref_slot = self.cur_slot - capped
  while ref_slot < 0 {
    ref_slot = ref_slot + 8
  }
  let ref_p = match self.slots[ref_slot] {
    Some(p) => p
    None => return Err("selected reference slot is empty")
  }
  // §464: the reconstruction lands in the slot after the current one.
  let out_slot = (self.cur_slot + 1) % 8
  // §465: the three-way joint choice, when requested, decides the q, the
  // skip threshold AND which past reconstruction to predict from. It runs
  // before the q/skip selection below and overrides all three.
  let three_way = match rd_ref_ages {
    Some(ages) => {
      let cands = match rd_candidates {
        Some(c) => c
        None => av1_enc_rd_default_q_candidates()
      }
      let lambda = match rd_lambda {
        Some(l) => l
        None => 1000
      }
      let pcts = match rd_skip_pcts {
        Some(p) => p
        None => [50, 100]
      }
      // Build one candidate per requested age, resolving each through the
      // slot ring; skip ages with no retained picture.
      let ref_cands : Array[Av1EncRefCandidate] = []
      for a in ages {
        let av = if a < 0 { 0 } else { a }
        let ac = if av >= n_hist { n_hist - 1 } else { av }
        let mut sl = self.cur_slot - ac
        while sl < 0 {
          sl = sl + 8
        }
        match self.slots[sl] {
          Some(p) =>
            ref_cands.push({
              slot: sl,
              age: ac,
              y: p.y,
              y_stride: p.y_stride,
              u: p.u,
              uv_stride: p.uv_stride,
              v: p.v,
            })
          None => ()
        }
      }
      if ref_cands.is_empty() {
        return Err("av1 enc: no retained reference for the requested ages")
      }
      let choice = match
        av1_enc_rd_select_q_skip_ref_inter(
          self.seq,
          self.refs,
          src.y,
          src.y_stride,
          src.u,
          src.uv_stride,
          src.v,
          ref_cands,
          cands,
          pcts,
          lambda~,
          range~,
          dz_pm~,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Some((choice, ref_cands[choice.ref_index]))
    }
    None => None
  }
  // The chosen reference (three-way winner, or the ref_age walk above).
  let chosen : Av1EncRefCandidate = match three_way {
    Some((_, rc)) => rc
    None =>
      {
        slot: ref_slot,
        age: capped,
        y: ref_p.y,
        y_stride: ref_p.y_stride,
        u: ref_p.u,
        uv_stride: ref_p.uv_stride,
        v: ref_p.v,
      }
  }
  let ref_slot = chosen.slot
  // §457: with `rd_lambda~`, pick the qindex that minimizes
  // lambda*SAD + bits*1000 over the candidate ladder (default when only
  // the lambda is given). The selector trial-encodes on a private refmvs
  // fork, so self.refs is untouched; the real encode below re-encodes the
  // winner against the untouched state.
  // §465: the three-way choice already settled q and skip; feed them in
  // as the joint result so the branches below do not re-search.
  // §462: joint (q, skip) selection takes precedence when requested.
  let joint = match three_way {
    Some((choice, _)) =>
      Some({ q: choice.q, skip_pct: choice.skip_pct, cost: choice.cost, })
    None =>
      match rd_skip_pcts {
        Some(pcts) => {
          let cands = match rd_candidates {
            Some(c) => c
            None => av1_enc_rd_default_q_candidates()
          }
          let lambda = match rd_lambda {
            Some(l) => l
            None => 1000
          }
          let choice = match
            av1_enc_rd_select_q_skip_inter(
              self.seq,
              self.refs,
              src.y,
              src.y_stride,
              src.u,
              src.uv_stride,
              src.v,
              chosen.y,
              chosen.y_stride,
              chosen.u,
              chosen.uv_stride,
              chosen.v,
              cands,
              pcts,
              lambda~,
              range~,
              dz_pm~,
            ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          Some(choice)
        }
        None => None
      }
  }
  let q = match joint {
    Some(choice) => choice.q
    None =>
      match rd_lambda {
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
              chosen.y,
              chosen.y_stride,
              chosen.u,
              chosen.uv_stride,
              chosen.v,
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
  }
  // §458/§460: a positive skip percentage takes the skip-mixed path.
  // §462 overrides it with the jointly-chosen threshold.
  let effective_skip = match joint {
    Some(choice) => choice.skip_pct
    None =>
      match skip_sad_pct {
        Some(pct) => pct
        None => 0
      }
  }
  let use_skip = effective_skip > 0
  if split_margin > 0 &&
    (loop_filter_level0 != 0 ||
      loop_filter_level1 != 0 ||
      loop_filter_sharpness != 0) {
    return Err(
      "av1 enc: split_margin requires zero loop-filter levels (the deblock mirror is not partition-aware yet)",
    )
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
      chosen.y,
      chosen.y_stride,
      chosen.u,
      chosen.uv_stride,
      chosen.v,
      base_q_idx=q,
      range~,
      dz_pm~,
      skip_sad_pct=effective_skip,
      skip_uniform~,
      ref_slot~,
      refresh_slot=out_slot,
      loop_filter_level0~,
      loop_filter_level1~,
      loop_filter_sharpness~,
    )
  } else if split_margin > 0 {
    match
      av1_enc_write_me_res_part420_inter_frame_obu(
        self.seq,
        self.refs,
        src.y,
        src.y_stride,
        chosen.y,
        chosen.y_stride,
        chosen.u,
        chosen.uv_stride,
        chosen.v,
        base_q_idx=q,
        range~,
        dz_pm~,
        ref_slot~,
        refresh_slot=out_slot,
        split_margin~,
        drl~,
      ) {
      Ok((obu, ey, eu, ev, _splits)) => Ok((obu, ey, eu, ev))
      Err(e) => Err(e)
    }
  } else {
    av1_enc_write_me_res420_inter_frame_obu(
      self.seq,
      self.refs,
      src.y,
      src.y_stride,
      src.u,
      src.uv_stride,
      src.v,
      chosen.y,
      chosen.y_stride,
      chosen.u,
      chosen.uv_stride,
      chosen.v,
      base_q_idx=q,
      range~,
      dz_pm~,
      ref_slot~,
      refresh_slot=out_slot,
      loop_filter_level0~,
      loop_filter_level1~,
      loop_filter_sharpness~,
      drl~,
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
  // §464: this frame's reconstruction lands in `out_slot`; the header's
  // refresh_frame_flags and the decoder's reference store were set to the
  // same slot, so the ring here and the decoder stay in lockstep.
  self.cur_slot = out_slot
  self.slots[out_slot] = Some(planes)
  self.last_ref = Some(planes)
  Ok((Bytes::from_array(out[:]), planes))
}
