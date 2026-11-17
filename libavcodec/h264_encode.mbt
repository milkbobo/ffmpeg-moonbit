///|
/// Pure-MoonBit H.264 intra encoder, slice 1 of the port: one IDR picture
/// as a single I slice (CAVLC, Baseline 4:2:0 8-bit, flat QP, POC type 2).
/// The porting strategy mirrors every decoder component it must interop
/// with: parameter sets are written then re-parsed with `h264_ps.mbt`,
/// prediction and reconstruction call the decoder's own `h264_pred*` /
/// `h264_idct*` functions, residual writing inverts `h264_decode_residual`
/// table by table, the macroblock layer mirrors `h264_decode_mb_cavlc_intra`
/// field for field, and nC prediction replicates `h264_nc_luma` /
/// `h264_nc_chroma` / `h264_block0_nc` on a mirrored per-MB nz state - so
/// the encoder's local reconstruction is, by construction, exactly what
/// `h264_decode_annexb_frames` produces from the stream when both sides use
/// the same deblocking setting.

///|
fn h264_enc_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Bytes::from_array(out[:])
}

///|
pub struct H264EncodedFrame {
  /// SPS + PPS + IDR slice NALs, Annex B start codes.
  annexb : Bytes
  /// The encoder's local reconstruction, macroblock-aligned planes. With
  /// deblocking enabled these are the filtered pixels; I_PCM stays lossless.
  recon_y : Array[Int32]
  recon_u : Array[Int32]
  recon_v : Array[Int32]
  ystride : Int32
  cstride : Int32
  width : Int32
  height : Int32
  qp : Int32
  /// The per-macroblock nC mirror after coding (48 slots per MB): the P
  /// encoder seeds its persistent state from this, because uncoded blocks'
  /// nC reads see the previous frame's counts.
  mb_nz : Array[Array[Int32]]
  /// The per-macroblock prediction-mode mirror (16 slots per MB, the
  /// 2x2-replicated grid for Intra 8x8 macroblocks) and the Intra_NxN /
  /// transform-size flags: the B-slice sequence seeds its persistent
  /// per-macroblock state and the decoder-context mirror's intra fields
  /// from these, because the next picture's intra mode prediction and the
  /// CABAC transform-size context read them.
  mb_modes : Array[Array[Int32]]
  mb_intra4x4 : Array[Bool]
  mb_tf8 : Array[Bool]
}

///|
/// Per-macroblock mirror of what the decoder keeps in `H264MbInfo` for
/// neighbour prediction: the nz counts, the Intra4x4 signalling modes and
/// the availability marker.
priv struct H264EncMbState {
  nz : Array[Int32]
  modes : Array[Int32]
  mut intra4x4 : Bool
  mut transform_8x8 : Bool
  /// `§423`: the extended QP this macroblock was reconstructed at (AQ may
  /// vary it per MB); the in-loop deblock reads it like the decoder's
  /// `qscale_table`.
  mut qp : Int32
}

///|
fn new_h264_enc_mb_state() -> H264EncMbState {
  {
    nz: Array::make(48, 0),
    modes: Array::make(16, 0),
    intra4x4: false,
    transform_8x8: false,
    qp: 0,
  }
}

///|
priv struct H264IntraEncoder {
  p : H264EncParams
  pps : H264Pps
  mut chroma_qp : Int32
  src_y : Array[Int32]
  src_u : Array[Int32]
  src_v : Array[Int32]
  rec_y : Array[Int32]
  rec_u : Array[Int32]
  rec_v : Array[Int32]
  ystride : Int32
  cstride : Int32
  mb_width : Int32
  states : Array[H264EncMbState]
  cur_nz : Array[Int32]
  cur_modes : Array[Int32]
  /// Opt-in High-profile transform_8x8 (I_NxN may become I8x8).
  dct8x8 : Bool
  /// Shared decision counters (I8x8 usage).
  stats : H264EncStats
  /// This macroblock's QP / `mb_qp_delta` (adaptive quantisation; both
  /// stay at the picture QP with AQ off).
  mut mb_qp : Int32
  mut mb_dqp : Int32
  /// The decoder's running QP: `mb_qp_delta` accumulates onto the previous
  /// macroblock's QP, not the slice QP (only written dqp's advance it).
  mut prev_qp : Int32
  /// Per-MB luma activity and the picture average (`aq_on` false: unused).
  mut aq_act : Array[Int32]
  mut aq_avg : Int32
  aq_on : Bool
  aq_strength : Int32
  /// `§429`: per-MB ROI QP offsets (empty = no ROI; only applied with AQ on).
  roi_off : Array[Int32]
  /// `§423`: apply the in-loop deblocking filter to the reconstruction (and
  /// so to the reference planes) instead of returning pre-filter pixels.
  deblock : Bool
}

///|
/// Encode one IDR I-frame. `y`/`u`/`v` are tightly packed planar u8
/// (`width * height`, `(width/2) * (height/2)` each); dimensions must be
/// positive and even (cropping covers the macroblock remainder). `qp` is
/// the flat slice QP; `pcm` selects I_PCM for every macroblock - a
/// lossless conformance path.
/// With `aq=true`, `aq_strength` selects the QP offset (0..6, default 1);
/// 0 produces the flat-QP stream. The final macroblock QP is clipped to 0..51.
pub fn h264_encode_intra_frame(
  y : Bytes,
  u : Bytes,
  v : Bytes,
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  pcm~ : Bool = false,
  dct8x8~ : Bool = false,
  stats~ : H264EncStats = H264EncStats::new(),
  pps_qp~ : Int32 = -1,
  aq~ : Bool = false,
  aq_strength~ : Int32 = 1,
  /// `§429`: per-macroblock ROI quantisation offsets (`H264Roi`); applied on
  /// top of AQ and silently ignored when `aq=false` (upstream semantics).
  roi~ : Array[H264Roi] = [],
  vbv~ : H264Vbv? = None,
  /// HRD ticks since the preceding buffering period (zero at stream start).
  idr_cpb_delay~ : Int32 = 0,
  b_seq~ : Bool = false,
  /// `§410`: explicit P weighted prediction. The PPS then carries
  /// `weighted_pred_flag = 1` and every P slice header a fitted
  /// `pred_weight_table()`; off, the stream stays byte-identical.
  weightp~ : Bool = false,
  /// `§434`: opt-in explicit B weighted prediction (PPS `weighted_bipred_idc
  /// = 1`); the B slice headers carry the tables. Only meaningful in a B
  /// sequence (`b_seq`); off keeps the parameter sets byte-identical.
  weightp_b~ : Bool = false,
  /// `§412`/`§419`: 8 (default), 9, 10, 12 or 14 bits. Above 8 the input planes are
  /// little-endian 16-bit samples (`yuv420p10le`) and the SPS switches to
  /// High 10 (profile_idc 110); `qp` keeps its 8-bit meaning.
  bit_depth~ : Int32 = 8,
  /// `§415`: the sequence's P-slice reference count, signalled by the
  /// parameter sets this picture carries (single-frame callers keep 1).
  multi_ref~ : Int32 = 1,
  /// `§420`: chroma format, 1 (4:2:0, default) or 2 (4:2:2 — the chroma
  /// planes are `w/2 x h`; profile High 4:2:2 at 8..10 bits and Hi444PP
  /// above, `§422d`).
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset (x264 `chroma-qp-offset`, -12..12).
  /// Written to both PPS offsets and applied to the chroma dequantisation
  /// and deblocking QP; 0 keeps the stream byte-identical.
  chroma_qp_offset~ : Int32 = 0,
  /// `§423`: in-loop deblocking, default on. The IDR's planes are filtered
  /// exactly as a conforming decoder will filter them before they are returned.
  /// Pass `deblock=false` for the legacy pre-filter reconstruction.
  deblock~ : Bool = true,
  /// `§433`: slice-level deblocking alpha/beta offsets in div2 units
  /// (-6..=6, x264 `--deblock alpha:beta`). Either nonzero opts the PPS into
  /// `deblocking_filter_control_present_flag` and shifts the filter strength
  /// of this picture (and, through the filtered reference, the sequence);
  /// 0/0 keeps the stream byte-identical. Requires `deblock=true`.
  deblock_alpha~ : Int32 = 0,
  deblock_beta~ : Int32 = 0,
  /// `§426`: sample aspect ratio for the SPS VUI (0/0 = unset).
  sar~ : (Int32, Int32) = (0, 0),
  /// `§427`: ATSC A/53 caption triples (multiple of 3, ≤63 bytes) carried
  /// in a GA94 `user_data_registered` SEI before the slice NAL.
  a53~ : Bytes? = None,
  /// `§427`: one `user_data_unregistered` SEI payload (16-byte UUID + user
  /// data); `None` writes no SEI NAL.
  sei_unregistered~ : Bytes? = None,
  /// `§428`: stereo frame packing layout carried in a
  /// `frame_packing_arrangement` SEI (`§424d` semantics: IDR AUs only; the
  /// decoder context persists it onto every following frame).
  stereo3d~ : Int32 = 0,
  /// `§431`: `false` codes a non-IDR open-GOP keyframe instead of the
  /// sequence's IDR — an I slice in a type-1 NAL with the position's
  /// `frame_num` / `poc_lsb` and the non-IDR `dec_ref_pic_marking` syntax,
  /// without parameter sets. Such a picture starts no buffering period and
  /// carries no frame-packing SEI (`vbv` / `stereo3d` apply to the IDR).
  idr~ : Bool = true,
  /// `§431`: `frame_num` of a non-IDR I picture (ignored when `idr`).
  frame_num~ : Int32 = 0,
  /// `§431`: `pic_order_cnt_lsb` of a non-IDR I picture (`b_seq` only).
  poc_lsb~ : Int32 = 0,
) -> Result[H264EncodedFrame, String] {
  if aq_strength < 0 || aq_strength > 6 {
    return Err("h264 enc: aq_strength must be in 0..=6")
  }
  if chroma_format < 1 || chroma_format > 3 {
    return Err("h264 enc: chroma_format must be 1, 2 or 3")
  }
  if chroma_qp_offset < -12 || chroma_qp_offset > 12 {
    return Err("h264 enc: chroma_qp_offset must be in -12..=12")
  }
  match h264_enc_deblock_offsets_ok(deblock, deblock_alpha, deblock_beta) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0 {
    return Err("h264 enc: invalid geometry \{width}x\{height}")
  }
  if qp < 0 || qp > 51 {
    return Err("h264 enc: qp out of range")
  }
  if !h264_enc_bit_depth_ok(bit_depth) {
    return Err(
      "h264 enc: unsupported bit depth \{bit_depth} (8, 9, 10, 12 or 14)",
    )
  }
  // §421: 4:4:4 chroma matches luma in both directions.
  let chroma_w = if chroma_format == 3 { width } else { width / 2 }
  let chroma_h = if chroma_format == 1 { height / 2 } else { height }
  if y.length() != h264_enc_plane_bytes(width, height, bit_depth) ||
    u.length() != h264_enc_plane_bytes(chroma_w, chroma_h, bit_depth) ||
    v.length() != h264_enc_plane_bytes(chroma_w, chroma_h, bit_depth) {
    return Err("h264 enc: plane size mismatch")
  }
  let p = {
    width,
    height,
    qp,
    level_idc,
    bit_depth,
    nrefs: multi_ref,
    sar,
    deblock_alpha,
    deblock_beta,
    weightp_b,
  }
  // The parameter sets carry `pic_init_qp`: in a rate-controlled sequence
  // that is the sequence's base QP (one PPS serves every picture) while
  // this picture's own QP travels in `slice_qp_delta`.
  let p_ps = {
    width,
    height,
    qp: if pps_qp < 0 {
      qp
    } else {
      pps_qp
    },
    level_idc,
    bit_depth,
    nrefs: multi_ref,
    sar,
    deblock_alpha,
    deblock_beta,
    weightp_b,
  }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = if chroma_format == 3 { mb_width * 16 } else { mb_width * 8 }
  let pheight = mb_height * 16
  let chroma_plane_h = if chroma_format == 1 { pheight / 2 } else { pheight }
  // Parse the parameter sets we just wrote: the parsed PPS carries the
  // dequantisation tables the local reconstruction shares with the decoder.
  let ps = new_h264_param_sets()
  let sps_nal = if b_seq {
    h264_enc_write_sps_b(p_ps, dct8x8~, vbv~, chroma_format~)
  } else {
    h264_enc_write_sps(p_ps, dct8x8~, vbv~, chroma_format~)
  }
  let pps_nal = h264_enc_write_pps(
    p_ps,
    dct8x8~,
    weightp~,
    chroma_format~,
    chroma_qp_offset~,
  )
  // Round-trip the parameter sets through the decoder's own parsers: the
  // parsed PPS carries the dequantisation tables shared with the local
  // reconstruction.
  let sps_raw = if b_seq {
    h264_enc_sps_rbsp_b(p_ps, dct8x8~, vbv~, chroma_format~)
  } else {
    h264_enc_sps_rbsp(p_ps, dct8x8~, vbv~, chroma_format~)
  }
  let pps_raw = h264_enc_pps_rbsp(
    p_ps,
    dct8x8~,
    weightp~,
    chroma_format~,
    chroma_qp_offset~,
  )
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_raw), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  match
    ff_h264_decode_picture_parameter_set(
      BitReader::new(pps_raw),
      ps,
      pps_raw.length() * 8,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: PPS round-trip failed: \{e}")
  }
  let pps = match ps.pps_list[0] {
    Some(v) => v
    None => return Err("h264 enc: no PPS after round-trip")
  }
  let chroma_qp = h264_get_chroma_qp(pps, 0, p.qp_ext(qp), bit_depth~)
  // `§429`: ROI offsets ride the same `mb_qp_delta` mechanism as AQ; upstream
  // requires AQ and silently skips the ROI otherwise.
  let roi_off = match
    h264_roi_offsets_for(roi, aq, mb_width, mb_height, bit_depth) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let self_ : H264IntraEncoder = {
    p,
    pps,
    chroma_qp,
    src_y: h264_enc_load_plane(y, width, height, ystride, pheight, bit_depth~),
    src_u: h264_enc_load_plane(
      u,
      chroma_w,
      chroma_h,
      cstride,
      chroma_plane_h,
      bit_depth~,
    ),
    src_v: h264_enc_load_plane(
      v,
      chroma_w,
      chroma_h,
      cstride,
      chroma_plane_h,
      bit_depth~,
    ),
    rec_y: Array::make(ystride * pheight, 0),
    rec_u: Array::make(cstride * chroma_plane_h, 0),
    rec_v: Array::make(cstride * chroma_plane_h, 0),
    ystride,
    cstride,
    mb_width,
    states: {
      // Distinct instances: Array::make would alias one struct into every
      // slot and each macroblock's commit would clobber the neighbours.
      let sts : Array[H264EncMbState] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        sts.push(new_h264_enc_mb_state())
      }
      sts
    },
    cur_nz: Array::make(48, 0),
    cur_modes: Array::make(16, 0),
    dct8x8,
    stats,
    mb_qp: qp,
    mb_dqp: 0,
    prev_qp: qp,
    aq_act: [],
    aq_avg: 0,
    aq_on: aq,
    aq_strength,
    roi_off,
    deblock,
  }
  if aq {
    let (act, avg) = h264_aq_measure(self_.src_y, ystride, mb_width, mb_height)
    self_.aq_act = act
    self_.aq_avg = avg
  }
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(7) // slice_type: I (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num (log2_max_frame_num = 4)
  if idr {
    r.put_ue(0) // idr_pic_id
  }
  if b_seq {
    // `§431`: a non-IDR I picture keeps the sequence's POC (open GOP).
    r.put(if idr { 0 } else { poc_lsb & 15 }, 4) // pic_order_cnt_lsb
  }
  if idr {
    r.put_bit(0) // no_output_of_prior_pics_flag
    r.put_bit(0) // long_term_reference_flag
  } else {
    r.put_bit(0) // adaptive_ref_pic_marking_mode_flag
  }
  // POC type 2 (b_seq off) has no picture order syntax at all.
  r.put_se(qp - p_ps.qp) // slice_qp_delta
  // `§433`: with the PPS deblocking control on, every slice header carries
  // idc 0 (filter all edges) and both div2 offsets.
  if pps.deblocking_filter_parameters_present != 0 {
    r.put_ue(0) // disable_deblocking_filter_idc
    r.put_se(p.deblock_alpha) // slice_alpha_c0_offset_div2
    r.put_se(p.deblock_beta) // slice_beta_offset_div2
  }
  for mb_y = 0; mb_y < mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < mb_width; mb_x = mb_x + 1 {
      if pcm {
        self_.encode_pcm(mb_x, mb_y, r)
      } else {
        match self_.encode_macroblock(mb_x, mb_y, r) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
  }
  r.trailing_bits()
  let slice_nal = h264_enc_nal(r, 3, if idr { 5 } else { 1 })
  // `§423`: the reconstruction (and the planes a following P picture will
  // reference) becomes the decoder's filtered output.
  // `§424`: I_PCM is the lossless conformance path. Filtering its samples
  // would make both the local reconstruction and decoder output differ from
  // the source, so the whole-PCM picture keeps its original pixels.
  if self_.deblock && !pcm {
    h264_enc_deblock_picture(
      self_.rec_y,
      self_.rec_u,
      self_.rec_v,
      self_.ystride,
      self_.cstride,
      mb_width,
      mb_height,
      h264_enc_infos_from_intra(self_.states),
      self_.pps,
      bit_depth,
      alpha=p.deblock_alpha,
      beta=p.deblock_beta,
    )
  }
  let header : Array[Bytes] = []
  if idr {
    header.push(sps_nal)
    header.push(pps_nal)
    match vbv {
      None => ()
      Some(v) => {
        // Every IDR starts a buffering period; its timing can still refer
        // to the preceding period when it belongs to a longer bitstream.
        header.push(h264_enc_sei_buffering_period(v))
        header.push(
          h264_enc_sei_pic_timing(
            v,
            idr_cpb_delay,
            dpb_output_delay=if b_seq { 2 } else { 0 },
          ),
        )
      }
    }
  }
  match h264_enc_sei_side_data_nals(a53, sei_unregistered) {
    Ok(nals) =>
      for nal in nals {
        header.push(nal)
      }
    Err(e) => return Err(e)
  }
  if idr && stereo3d != 0 {
    match h264_enc_sei_frame_packing(stereo3d) {
      Ok(nal) => header.push(nal)
      Err(e) => return Err(e)
    }
  }
  header.push(slice_nal)
  Ok({
    annexb: h264_enc_concat(header),
    recon_y: self_.rec_y,
    recon_u: self_.rec_u,
    recon_v: self_.rec_v,
    ystride: self_.ystride,
    cstride: self_.cstride,
    width,
    height,
    qp,
    mb_modes: {
      let out : Array[Array[Int32]] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        let st = self_.states[k]
        let arr : Array[Int32] = Array::make(16, 0)
        for i = 0; i < 16; i = i + 1 {
          arr[i] = st.modes[i]
        }
        out.push(arr)
      }
      out
    },
    mb_intra4x4: {
      let out : Array[Bool] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        out.push(self_.states[k].intra4x4)
      }
      out
    },
    mb_tf8: {
      let out : Array[Bool] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        out.push(self_.states[k].transform_8x8)
      }
      out
    },
    mb_nz: {
      let out : Array[Array[Int32]] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        let st = self_.states[k]
        let nz : Array[Int32] = Array::make(48, 0)
        for i = 0; i < 48; i = i + 1 {
          nz[i] = st.nz[i]
        }
        out.push(nz)
      }
      out
    },
  })
}

///|
/// §421: one 4:4:4 intra macroblock. `ChromaArrayType == 3` reuses the LUMA
/// prediction modes and the luma residual path for all three planes: there is
/// no `chroma_pred_mode` syntax, no chroma DC Hadamard, and one 4-bit `cbp`
/// gates the same 8x8 quadrant pattern in every plane (a quadrant is coded
/// when ANY plane is non-zero, and the zero planes then emit
/// `TotalCoeff = 0`).
fn H264IntraEncoder::encode_macroblock_444(
  self : H264IntraEncoder,
  mb_x : Int32,
  mb_y : Int32,
  r : H264Rbsp,
) -> Result[Unit, String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  let state = self.states[mb_idx]
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = state.nz[i]
  }
  let top_avail = mb_y > 0
  let left_avail = mb_x > 0
  // Adaptive quantisation rides `mb_qp_delta` exactly like the 4:2:0 path.
  self.mb_qp = self.p.qp
  self.mb_dqp = 0
  if self.aq_on {
    let adj = h264_aq_adj(self.aq_act[mb_idx], self.aq_avg, self.aq_strength)
    let mut mq = self.p.qp + adj + h264_roi_off_at(self.roi_off, mb_idx)
    if mq < 0 {
      mq = 0
    }
    if mq > 51 {
      mq = 51
    }
    self.mb_qp = mq
    self.mb_dqp = mq - self.prev_qp
  }
  let qp = self.p.qp_ext(self.mb_qp)
  // §421: every plane indexes its own dequant table; 4:4:4 chroma takes the
  // direct (table-free) QP mapping.
  let cq0 = h264_get_chroma_qp(self.pps, 0, qp, bit_depth=self.p.bit_depth)
  let cq1 = h264_get_chroma_qp(self.pps, 1, qp, bit_depth=self.p.bit_depth)
  let plane_qp : Array[Int32] = [qp, cq0, cq1]
  let mb : Array[Int32] = Array::make(768, 0)
  let levels_all : Array[Int32] = Array::make(768, 0)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  // ---- prediction-mode decision: luma SAD, shared by all three planes ----
  let mut cbp = 0
  if self.dct8x8 {
    cbp = match
      h264_enc_i8444_pass(
        [self.src_y, self.src_u, self.src_v],
        [self.rec_y, self.rec_u, self.rec_v],
        self.ystride,
        mb_x,
        mb_y,
        self.mb_width,
        self.pps,
        plane_qp,
        levels_all,
        self.cur_modes,
        self.p.bit_depth,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    self.stats.i8_mbs += 1
    for i in 0..<48 {
      self.cur_nz[i] = 0
    }
  } else {
    let effs : Array[Int32] = Array::make(16, 0)
    let topright_of : Array[Bool] = Array::make(16, false)
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      let blk_top = gy > 0 || top_avail
      let blk_left = gx > 0 || left_avail
      let topright = if gy == 0 {
        top_avail && (gx < 3 || mb_x < self.mb_width - 1)
      } else {
        gx == 0 || gx == 2 || (gx == 1 && gy % 2 == 0)
      }
      topright_of[g] = topright
      let mut best_sig = 0
      let mut best_eff : Int32 = -1
      let mut best_sad = -1
      for sig = 0; sig < 9; sig = sig + 1 {
        let eff = match h264_check_intra4x4_mode(sig, blk_top, blk_left) {
          Ok(v) => v
          Err(_) => -1
        }
        if eff < 0 {
          continue
        }
        let err = h264_pred4x4(
            self.rec_y,
            off,
            self.ystride,
            eff,
            blk_top,
            blk_left,
            topright,
            bit_depth=self.p.bit_depth,
          )
          is Err(_)
        if err {
          continue
        }
        let sad = h264_enc_sad4(self.src_y, self.rec_y, off, self.ystride)
        if best_sad < 0 || sad < best_sad {
          best_sad = sad
          best_sig = sig
          best_eff = eff
        }
      }
      if best_eff < 0 {
        return Err("h264 enc: no feasible intra4x4 mode")
      }
      self.cur_modes[g] = best_sig
      effs[g] = best_eff
    }
    // ---- per-block, per-plane: predict, transform, quantise, reconstruct ----
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let eff = effs[g]
      let topright = topright_of[g]
      let blk_top = gy > 0 || top_avail
      let blk_left = gx > 0 || left_avail
      let mut any = false
      for p = 0; p < 3; p = p + 1 {
        let src = if p == 0 {
          self.src_y
        } else if p == 1 {
          self.src_u
        } else {
          self.src_v
        }
        let rec = if p == 0 {
          self.rec_y
        } else if p == 1 {
          self.rec_u
        } else {
          self.rec_v
        }
        let stride = if p == 0 { self.ystride } else { self.cstride }
        let off = mb_y * 16 * stride + mb_x * 16 + gy * 4 * stride + gx * 4
        match
          h264_pred4x4(
            rec,
            off,
            stride,
            eff,
            blk_top,
            blk_left,
            topright,
            bit_depth=self.p.bit_depth,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        let res : Array[Int32] = Array::make(16, 0)
        for row = 0; row < 4; row = row + 1 {
          for col = 0; col < 4; col = col + 1 {
            res[row * 4 + col] = src[off + row * stride + col] -
              rec[off + row * stride + col]
          }
        }
        let levels = h264_enc_fdct_quant_res(res, 0, plane_qp[p])
        let qmul = h264_build_dequant4(self.pps, p, plane_qp[p])
        let mut total = 0
        for s = 0; s < 16; s = s + 1 {
          levels_all[256 * p + 16 * i + s] = levels[s]
          if levels[s] != 0 {
            total = total + 1
            mb[256 * p + 16 * i + s] = h264_enc_dequant_level(
              levels[s],
              qmul[s],
              bit_depth=self.p.bit_depth,
            )
          }
        }
        self.cur_nz[16 * p + gy * 4 + gx] = total
        if total != 0 {
          any = true
          h264_idct_add(
            rec,
            off,
            stride,
            mb,
            256 * p + 16 * i,
            bit_depth=self.p.bit_depth,
          )
        }
      }
      if any {
        cbp = cbp | (1 << (i / 4))
      }
    }
  }
  // ---- syntax ----
  r.put_ue(0) // mb_type: I_NxN
  if self.dct8x8 {
    r.put_bit(1)
  }
  for i = 0; i < 16; i = i + 1 {
    if self.dct8x8 && i % 4 != 0 {
      continue
    }
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let predicted = self.pred_mode(mb_idx, mb_x, mb_y, gx, gy)
    let mode = self.cur_modes[g]
    if mode == predicted {
      r.put_bit(1)
    } else {
      r.put_bit(0)
      let rem = if mode > predicted { mode - 1 } else { mode }
      r.put(rem, 3)
    }
  }
  // No `chroma_pred_mode`: 4:4:4 reuses the luma modes.
  r.put_ue(h264_enc_cbp_golomb_gray(cbp))
  if cbp != 0 {
    r.put_se(self.mb_dqp)
    self.prev_qp = self.mb_qp
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  }
  for p = 0; p < 3; p = p + 1 {
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      if (cbp & (1 << i8)) != 0 {
        if self.dct8x8 {
          for sub in 0..<4 {
            let i = 4 * i8 + sub
            let gx = h264_luma_block_x[i]
            let gy = h264_luma_block_y[i]
            let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy, base=16 * p)
            let view = h264_cavlc8_sub_view(levels_all, 4 * p + i8, sub)
            self.cur_nz[16 * p + gy * 4 + gx] = h264_enc_write_residual(
              r, view, 16, nc,
            )
          }
          let leader = 16 * p + h264_luma_block_grid[4 * i8]
          self.cur_nz[leader] += self.cur_nz[leader + 1] +
            self.cur_nz[leader + 4] +
            self.cur_nz[leader + 5]
          continue
        }
        for i4 = 0; i4 < 4; i4 = i4 + 1 {
          let i = i8 * 4 + i4
          let gx = h264_luma_block_x[i]
          let gy = h264_luma_block_y[i]
          let view = scan_view_at(
            levels_all,
            16 * p + i,
            h264_zigzag_scan_t,
            0,
            16,
          )
          let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy, base=16 * p)
          ignore(h264_enc_write_residual(r, view, 16, nc))
        }
      }
    }
  }
  for i = 0; i < 48; i = i + 1 {
    state.nz[i] = self.cur_nz[i]
  }
  for i = 0; i < 16; i = i + 1 {
    state.modes[i] = self.cur_modes[i]
  }
  state.intra4x4 = true
  state.transform_8x8 = self.dct8x8
  state.qp = self.p.qp_ext(self.mb_qp)
  Ok(())
}

///|
fn H264IntraEncoder::encode_pcm(
  self : H264IntraEncoder,
  mb_x : Int32,
  mb_y : Int32,
  r : H264Rbsp,
) -> Unit {
  r.put_ue(25) // mb_type: I_PCM
  r.align_zero()
  let bd = self.p.bit_depth
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let s = self.src_y[ybase + row * self.ystride + col]
      r.put(s, bd)
      self.rec_y[ybase + row * self.ystride + col] = s
    }
  }
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  for plane = 0; plane < 2; plane = plane + 1 {
    let src = if plane == 0 { self.src_u } else { self.src_v }
    let dst = if plane == 0 { self.rec_u } else { self.rec_v }
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        let s = src[cbase + row * self.cstride + col]
        r.put(s, bd)
        dst[cbase + row * self.cstride + col] = s
      }
    }
  }
  // The decoder marks every PCM nz slot as 16 (`h264_cavlc.c`).
  let state = self.states[mb_y * self.mb_width + mb_x]
  for i = 0; i < 48; i = i + 1 {
    state.nz[i] = 16
  }
  state.intra4x4 = false
  state.transform_8x8 = false
  state.qp = self.p.qp_ext(self.mb_qp)
}

///|
fn H264IntraEncoder::nc_luma(
  self : H264IntraEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  gx : Int32,
  gy : Int32,
  /// §421: plane base of the `nz` mirror (0 luma, 16/32 the 4:4:4 chroma
  /// planes, which use the luma grid).
  base~ : Int32 = 0,
) -> Int32 {
  let left = if gx > 0 {
    self.cur_nz[base + gy * 4 + gx - 1]
  } else if mb_x > 0 {
    self.states[mb_idx - 1].nz[base + gy * 4 + 3]
  } else {
    64
  }
  let top = if gy > 0 {
    self.cur_nz[base + (gy - 1) * 4 + gx]
  } else if mb_y > 0 {
    self.states[mb_idx - self.mb_width].nz[base + 3 * 4 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
fn H264IntraEncoder::nc_block0(
  self : H264IntraEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  /// §421: plane base of the mirror (0 luma, 16/32 the 4:4:4 chroma planes).
  base~ : Int32 = 0,
) -> Int32 {
  let left = if mb_x > 0 { self.states[mb_idx - 1].nz[base + 3] } else { 64 }
  let top = if mb_y > 0 {
    self.states[mb_idx - self.mb_width].nz[base + 12]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
fn H264IntraEncoder::nc_chroma(
  self : H264IntraEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  c : Int32,
  i : Int32,
) -> Int32 {
  let base = 16 + 16 * c
  if self.pps.chroma_format == 2 {
    // `h264_nc_chroma_422`'s scan8 cache layout: the left neighbour of a
    // column-0 block is the left macroblock's same-row right block, the
    // top of a row-0 block is the top macroblock's bottom row.
    let left = if (i & 1) == 1 {
      self.cur_nz[base + i - 1]
    } else if mb_x > 0 {
      self.states[mb_idx - 1].nz[base + i + 1]
    } else {
      64
    }
    let top = if i >= 2 {
      self.cur_nz[base + i - 2]
    } else if mb_y > 0 {
      self.states[mb_idx - self.mb_width].nz[base + 6 + i]
    } else {
      64
    }
    return h264_pred_non_zero_count(left, top)
  }
  let gx = i % 2
  let gy = i / 2
  let left = if gx > 0 {
    self.cur_nz[base + i - 1]
  } else if mb_x > 0 {
    self.states[mb_idx - 1].nz[base + 1 + 2 * gy]
  } else {
    64
  }
  let top = if gy > 0 {
    self.cur_nz[base + i - 2]
  } else if mb_y > 0 {
    self.states[mb_idx - self.mb_width].nz[base + 2 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
/// The `h264_pred_intra_mode` mirror: minimum of the signalled neighbour
/// modes (non-I4x4 neighbours count as DC).
fn H264IntraEncoder::pred_mode(
  self : H264IntraEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  gx : Int32,
  gy : Int32,
) -> Int32 {
  let left = if gx > 0 {
    self.cur_modes[gy * 4 + gx - 1]
  } else if mb_x > 0 {
    let li = self.states[mb_idx - 1]
    if li.intra4x4 {
      li.modes[gy * 4 + 3]
    } else {
      2
    }
  } else {
    -1
  }
  let top = if gy > 0 {
    self.cur_modes[(gy - 1) * 4 + gx]
  } else if mb_y > 0 {
    let ti = self.states[mb_idx - self.mb_width]
    if ti.intra4x4 {
      ti.modes[3 * 4 + gx]
    } else {
      2
    }
  } else {
    -1
  }
  if left < 0 || top < 0 {
    2
  } else if left < top {
    left
  } else {
    top
  }
}

///|
/// SAD between source and reconstruction over one 8-wide chroma block
/// (8x8 at 4:2:0, 8x16 at 4:2:2). */
fn H264IntraEncoder::chroma_sad(
  self : H264IntraEncoder,
  src : Array[Int32],
  rec : Array[Int32],
  cbase : Int32,
) -> Int32 {
  let mut sad = 0
  let rows = if self.pps.chroma_format == 2 { 16 } else { 8 }
  for row = 0; row < rows; row = row + 1 {
    for col = 0; col < 8; col = col + 1 {
      let d = src[cbase + row * self.cstride + col] -
        rec[cbase + row * self.cstride + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// SAD between source and reconstruction over a 4x4 block of the luma
/// plane at (off, ystride). */
fn h264_enc_sad4(
  src : Array[Int32],
  rec : Array[Int32],
  off : Int32,
  stride : Int32,
) -> Int32 {
  let mut sad = 0
  for row = 0; row < 4; row = row + 1 {
    for col = 0; col < 4; col = col + 1 {
      let d = src[off + row * stride + col] - rec[off + row * stride + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// SAD between source and reconstruction over an 8x8 block of a plane at
/// (off, stride). */
fn h264_enc_sad8(
  src : Array[Int32],
  rec : Array[Int32],
  off : Int32,
  stride : Int32,
) -> Int32 {
  let mut sad = 0
  for row = 0; row < 8; row = row + 1 {
    for col = 0; col < 8; col = col + 1 {
      let d = src[off + row * stride + col] - rec[off + row * stride + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// Choose the chroma mode: evaluate every candidate on both planes (each
/// `h264_pred8x8` overwrites the 8x8 region), then re-run the winner. */
fn H264IntraEncoder::pick_chroma(
  self : H264IntraEncoder,
  cbase : Int32,
  top : Bool,
  left : Bool,
) -> Int32 {
  // Mirror of the decoder: candidates are the raw signalling modes, the
  // prediction runs on the checked effective mode.
  let mut best_sig = 0
  let mut best_eff = 0
  let mut best_cost = -1
  for sig = 0; sig < 4; sig = sig + 1 {
    let eff = match h264_check_intra_pred_mode(sig, top, left) {
      Ok(v) => v
      Err(_) => -1
    }
    if eff < 0 {
      continue
    }
    let ok_u = if self.pps.chroma_format == 2 {
      h264_pred8x16(
        self.rec_u,
        cbase,
        self.cstride,
        eff,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    } else {
      h264_pred8x8(
        self.rec_u,
        cbase,
        self.cstride,
        eff,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    }
    let ok_v = if self.pps.chroma_format == 2 {
      h264_pred8x16(
        self.rec_v,
        cbase,
        self.cstride,
        eff,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    } else {
      h264_pred8x8(
        self.rec_v,
        cbase,
        self.cstride,
        eff,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    }
    if ok_u is Ok(_) && ok_v is Ok(_) {
      let cost = self.chroma_sad(self.src_u, self.rec_u, cbase) +
        self.chroma_sad(self.src_v, self.rec_v, cbase)
      if best_cost < 0 || cost < best_cost {
        best_cost = cost
        best_sig = sig
        best_eff = eff
      }
    }
  }
  let repred = if self.pps.chroma_format == 2 {
    fn(plane : Array[Int32], mode : Int32) -> Result[Unit, String] {
      h264_pred8x16(
        plane,
        cbase,
        self.cstride,
        mode,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    }
  } else {
    fn(plane : Array[Int32], mode : Int32) -> Result[Unit, String] {
      h264_pred8x8(
        plane,
        cbase,
        self.cstride,
        mode,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    }
  }
  ignore(repred(self.rec_u, best_eff))
  ignore(repred(self.rec_v, best_eff))
  best_sig
}

///|
fn H264IntraEncoder::encode_macroblock(
  self : H264IntraEncoder,
  mb_x : Int32,
  mb_y : Int32,
  r : H264Rbsp,
) -> Result[Unit, String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  let state = self.states[mb_idx]
  // §421: 4:4:4 has its own macroblock layout (three luma-shaped planes, no
  // chroma prediction mode, no chroma DC).
  if self.pps.chroma_format == 3 {
    return self.encode_macroblock_444(mb_x, mb_y, r)
  }
  // The nC mirror persists per macroblock (see the P encoder's note).
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = state.nz[i]
  }
  let top_avail = mb_y > 0
  let left_avail = mb_x > 0
  // Adaptive quantisation: this MB's QP offset rides `mb_qp_delta`.
  self.mb_qp = self.p.qp
  self.mb_dqp = 0
  if self.aq_on {
    let adj = h264_aq_adj(self.aq_act[mb_idx], self.aq_avg, self.aq_strength)
    let mut mq = self.p.qp + adj + h264_roi_off_at(self.roi_off, mb_idx)
    if mq < 0 {
      mq = 0
    }
    if mq > 51 {
      mq = 51
    }
    self.mb_qp = mq
    self.mb_dqp = mq - self.prev_qp
    self.chroma_qp = h264_get_chroma_qp(
      self.pps,
      0,
      self.p.qp_ext(mq),
      bit_depth=self.p.bit_depth,
    )
  }
  // `qp` is the *extended* quantiser QP (user QP + 6*(bit_depth-8)): the
  // quantiser, `h264_build_dequant4` and the 8x8/DC helpers all index the
  // shared tables by it, so no call site below needs its own conversion.
  // `mb_qp`/`mb_dqp` stay in user units (deltas are offset-invariant).
  let qp = self.p.qp_ext(self.mb_qp)
  // Chroma first: the winning prediction stays in the reconstruction
  // planes for the residual pass below.
  let cf = self.pps.chroma_format
  let nblk = 4 * cf
  let crow = if cf == 2 { 16 } else { 8 }
  let cbase = mb_y * crow * self.cstride + mb_x * 8
  let chroma_mode = self.pick_chroma(cbase, top_avail, left_avail)
  // Chroma residuals (before the luma decision, but written later).
  let qmul_c = [
    h264_build_dequant4(self.pps, 1, self.chroma_qp),
    h264_build_dequant4(self.pps, 2, self.chroma_qp),
  ]
  // 4:2:2's DC dequant reads the table three QP steps up (the 2x4
  // Hadamard gain compensation, `h264_mb.mbt`).
  let qmul_dc422 = if cf == 2 {
    [
      h264_build_dequant4(self.pps, 1, self.chroma_qp + 3),
      h264_build_dequant4(self.pps, 2, self.chroma_qp + 3),
    ]
  } else {
    [Array::make(16, 0), Array::make(16, 0)]
  }
  let chroma_dc_store : Array[Array[Int32]] = [
    Array::make(16, 0),
    Array::make(16, 0),
  ]
  let chroma_ac_store : Array[Array[Int32]] = [
    Array::make(16 * nblk, 0),
    Array::make(16 * nblk, 0),
  ]
  let chroma_dc_nz : Array[Bool] = [false, false]
  let chroma_ac_nz : Array[Int32] = Array::make(2 * nblk, 0)
  let mb : Array[Int32] = Array::make(768, 0)
  for c = 0; c < 2; c = c + 1 {
    let src = if c == 0 { self.src_u } else { self.src_v }
    let rec = if c == 0 { self.rec_u } else { self.rec_v }
    // DC: sums of the 4x4 residual blocks (raster order, x + 2*y).
    let sums : Array[Int32] = Array::make(nblk, 0)
    for i = 0; i < nblk; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let mut sum = 0
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          sum = sum +
            src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      sums[i] = sum
    }
    let dc_store : Array[Int32] = Array::make(16, 0)
    let dc_n = if cf == 2 {
      h264_enc_chroma422_dc_hadamard_quant(sums, dc_store, self.chroma_qp)
      8
    } else {
      ignore(
        h264_enc_chroma_dc_hadamard_quant(sums, dc_store, 0, self.chroma_qp),
      )
      4
    }
    chroma_dc_store[c] = dc_store
    let mut any_dc = false
    for s2 = 0; s2 < dc_n; s2 = s2 + 1 {
      if dc_store[s2] != 0 {
        any_dc = true
        break
      }
    }
    chroma_dc_nz[c] = any_dc
    // AC blocks.
    for i = 0; i < nblk; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, self.chroma_qp)
      // Storage position 0 is the DC slot the 2x2 DC block owns; the AC
      // transform must not touch it (the stream view starts at scan 1,
      // but the dequant fill and the DC slot share the array).
      levels[0] = 0
      for s = 0; s < 16; s = s + 1 {
        chroma_ac_store[c][16 * i + s] = levels[s]
      }
    }
    // Chroma DC slots hold the RAW levels (raster 0/16/32/48 at 4:2:0,
    // the 4:2:2 zigzag's byte offsets at 4:2:2): the decoder's DC
    // dequant_idct applies the dequant itself, and the local
    // reconstruction calls the same function.
    if cf == 2 {
      for k = 0; k < 8; k = k + 1 {
        let lv = dc_store[k]
        if lv != 0 {
          mb[256 + 256 * c + h264_chroma422_dc_scan[k]] = lv
        }
      }
    } else {
      for s = 0; s < 4; s = s + 1 {
        let lv = dc_store[s]
        if lv != 0 {
          mb[256 + 256 * c + 16 * s] = lv
        }
      }
    }
    for i = 0; i < nblk; i = i + 1 {
      for s = 0; s < 16; s = s + 1 {
        let lv = chroma_ac_store[c][16 * i + s]
        if lv != 0 {
          mb[256 + 256 * c + 16 * i + s] = h264_enc_dequant_level(
            lv,
            qmul_c[c][s],
            bit_depth=self.p.bit_depth,
          )
        }
      }
    }
  }
  // ---- luma ----
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let qmul_y = h264_build_dequant4(self.pps, 0, qp)
  let mut luma_cbp = 0
  let mut i16_mode = 0
  let mut use_i16 = false
  let luma_store : Array[Int32] = Array::make(256, 0)
  let luma_dc_store : Array[Int32] = Array::make(16, 0)
  let luma_nz : Array[Int32] = Array::make(16, 0)
  let i16_ac_nz : Array[Int32] = Array::make(16, 0)
  let mut i16_dc_total = 0
  let mut i16_cost = 0
  // I16 candidates (signalling mode; prediction on the checked value).
  let mut i16_eff = 0
  let mut i16_found = false
  for sig = 0; sig < 4; sig = sig + 1 {
    let eff = match h264_check_intra_pred_mode(sig, top_avail, left_avail) {
      Ok(v) => v
      Err(_) => -1
    }
    if eff < 0 {
      continue
    }
    let pred_ok = h264_pred16x16(
        self.rec_y,
        ybase,
        self.ystride,
        eff,
        top_avail,
        left_avail,
        bit_depth=self.p.bit_depth,
      )
      is Ok(_)
    if pred_ok {
      let mut sad = 0
      for row = 0; row < 16; row = row + 1 {
        for col = 0; col < 16; col = col + 1 {
          let d = self.src_y[ybase + row * self.ystride + col] -
            self.rec_y[ybase + row * self.ystride + col]
          sad = sad + (if d < 0 { -d } else { d })
        }
      }
      if !i16_found || sad < i16_cost {
        i16_found = true
        i16_cost = sad
        i16_mode = sig
        i16_eff = eff
      }
    }
  }
  // ---- luma I8x8 candidate (High-profile transform_8x8): evaluated on
  // the I16 pass's leftover state; the modes go to a scratch array so the
  // I4x4 pass's within-MB predictors still see zeroes (the shared pass
  // reconstructs from MB-border samples for the first block and its own
  // output for the rest, so it is deterministic across runs). ----
  let luma8_store : Array[Int32] = Array::make(256, 0)
  let i8_modes : Array[Int32] = Array::make(16, 0)
  let mut i8_cost = 0
  let mut luma_cbp8 = 0
  let mut i8_found = false
  if self.dct8x8 {
    match
      h264_enc_luma_i8_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        luma8_store,
        i8_modes,
        mb,
        h264_enc_i8_avail(mb_x, mb_y, self.mb_width),
        bit_depth=self.p.bit_depth,
      ) {
      Ok((cost, cbp)) => {
        i8_cost = cost
        luma_cbp8 = cbp
        i8_found = true
      }
      Err(e) => return Err(e)
    }
  }
  // I4x4: sequential decision + reconstruction (each block's prediction
  // reads the reconstructed samples of its top/left neighbours).
  let mut i4_cost = 0
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * self.ystride + gx * 4
    let blk_top = gy > 0 || top_avail
    let blk_left = gx > 0 || left_avail
    let topright = if gy == 0 {
      top_avail && (gx < 3 || mb_x < self.mb_width - 1)
    } else {
      gx == 0 || gx == 2 || (gx == 1 && gy % 2 == 0)
    }
    let mut best_sig = 0
    let mut best_eff : Int32 = -1
    let mut best_sad = -1
    for sig = 0; sig < 9; sig = sig + 1 {
      let eff = match h264_check_intra4x4_mode(sig, blk_top, blk_left) {
        Ok(v) => v
        Err(_) => -1
      }
      if eff < 0 {
        continue
      }
      let pred_err = h264_pred4x4(
          self.rec_y,
          off,
          self.ystride,
          eff,
          blk_top,
          blk_left,
          topright,
          bit_depth=self.p.bit_depth,
        )
        is Err(_)
      if pred_err {
        continue
      }
      let sad = h264_enc_sad4(self.src_y, self.rec_y, off, self.ystride)
      if best_sad < 0 || sad < best_sad {
        best_sad = sad
        best_sig = sig
        best_eff = eff
      }
    }
    if best_eff < 0 {
      return Err("h264 enc: no feasible intra4x4 mode")
    }
    // Re-run the winner so the plane holds the chosen prediction.
    match
      h264_pred4x4(
        self.rec_y,
        off,
        self.ystride,
        best_eff,
        blk_top,
        blk_left,
        topright,
        bit_depth=self.p.bit_depth,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    i4_cost = i4_cost + best_sad
    self.cur_modes[g] = best_sig
    // Residual -> quantise -> dequantise -> reconstruct.
    let res : Array[Int32] = Array::make(16, 0)
    for row = 0; row < 4; row = row + 1 {
      for col = 0; col < 4; col = col + 1 {
        res[row * 4 + col] = self.src_y[off + row * self.ystride + col] -
          self.rec_y[off + row * self.ystride + col]
      }
    }
    let levels = h264_enc_fdct_quant_res(res, 0, qp)
    let mut total = 0
    for s = 0; s < 16; s = s + 1 {
      luma_store[16 * i + s] = levels[s]
      if levels[s] != 0 {
        total = total + 1
        mb[16 * i + s] = h264_enc_dequant_level(
          levels[s],
          qmul_y[s],
          bit_depth=self.p.bit_depth,
        )
      }
    }
    luma_nz[g] = total
    self.cur_nz[g] = total
    if total != 0 {
      luma_cbp = luma_cbp | (1 << (i / 4))
      if total == 1 && mb[16 * i] != 0 {
        h264_idct_dc_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      } else {
        h264_idct_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      }
    }
  }
  // Decision (the CABAC intra encoder's rule minus the dead I16x16 branch):
  // I4x4 must beat I8x8 by ~3% in prediction SAD to justify its twelve
  // extra mode trees; ties keep the cheaper-signalled I8x8.
  let use_i8 = i8_found && !(100 * i4_cost < 97 * i8_cost)
  if use_i8 {
    // Redo the luma plane for I8x8: clear the I4x4 pass's coefficients and
    // the nC mirror's luma cells (the decoder reads fresh zero counts for
    // cells no residual writes) plus the signalled modes, then re-run the
    // deterministic 8x8 pass committing into cur_modes.
    self.stats.i8_mbs += 1
    for i = 0; i < 256; i = i + 1 {
      mb[i] = 0
    }
    for g = 0; g < 16; g = g + 1 {
      self.cur_nz[g] = 0
      self.cur_modes[g] = 0
    }
    match
      h264_enc_luma_i8_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        luma8_store,
        self.cur_modes,
        mb,
        h264_enc_i8_avail(mb_x, mb_y, self.mb_width),
        bit_depth=self.p.bit_depth,
      ) {
      Ok((cost, cbp)) => {
        i8_cost = cost
        luma_cbp8 = cbp
      }
      Err(e) => return Err(e)
    }
    luma_cbp = luma_cbp8
  }
  // Decision: I4x4 needs to beat I16 by ~6% to justify its overhead.
  use_i16 = false
  if use_i16 {
    // Redo the luma plane for I16: the I4x4 pass left its dequantised
    // coefficients and reconstruction in place - clear both.
    for i = 0; i < 256; i = i + 1 {
      mb[i] = 0
    }
    match
      h264_pred16x16(
        self.rec_y,
        ybase,
        self.ystride,
        i16_eff,
        top_avail,
        left_avail,
        bit_depth=self.p.bit_depth,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let sums : Array[Int32] = Array::make(16, 0)
    for g = 0; g < 16; g = g + 1 {
      let bx = h264_luma_block_x[g]
      let by = h264_luma_block_y[g]
      let off = ybase + by * 4 * self.ystride + bx * 4
      let mut sum = 0
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          sum = sum +
            self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      sums[by * 4 + bx] = sum
    }
    let dc_levels = h264_enc_luma_dc_hadamard_quant(
      sums, 0, 4, luma_dc_store, 0, qp,
    )
    ignore(dc_levels)
    i16_dc_total = 0
    for s = 0; s < 16; s = s + 1 {
      if luma_dc_store[s] != 0 {
        i16_dc_total = i16_dc_total + 1
      }
    }
    // AC blocks (all sixteen; writing is gated by the aggregate cbp).
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      // AC residual excludes the DC sample (block position 0).
      let res_ac : Array[Int32] = [
        0,
        res[1],
        res[2],
        res[3],
        res[4],
        res[5],
        res[6],
        res[7],
        res[8],
        res[9],
        res[10],
        res[11],
        res[12],
        res[13],
        res[14],
        res[15],
      ]
      let levels = h264_enc_fdct_quant_res(res_ac, 0, qp)
      // Zero the DC slot: the DC block owns it.
      let fixed : Array[Int32] = Array::make(16, 0)
      for s = 0; s < 16; s = s + 1 {
        if s != 0 {
          fixed[s] = levels[s]
        }
      }
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        luma_store[16 * i + s] = fixed[s]
        if fixed[s] != 0 {
          total = total + 1
          mb[16 * i + s] = h264_enc_dequant_level(
            fixed[s],
            qmul_y[s],
            bit_depth=self.p.bit_depth,
          )
        }
      }
      i16_ac_nz[g] = total
      self.cur_nz[g] = total
    }
    luma_cbp = 0
    for g = 0; g < 16; g = g + 1 {
      if i16_ac_nz[g] != 0 {
        luma_cbp = 15
      }
    }
    // Reconstruction: DC Hadamard inverse then per-block IDCT.
    if i16_dc_total > 0 {
      let dc_raw : Array[Int32] = Array::make(16, 0)
      for s = 0; s < 16; s = s + 1 {
        dc_raw[s] = luma_dc_store[s]
      }
      h264_luma_dc_dequant_idct(
        mb,
        0,
        dc_raw,
        0,
        qmul_y[0],
        bit_depth=self.p.bit_depth,
      )
    }
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let off = ybase + gy * 4 * self.ystride + gx * 4
      if i16_ac_nz[gy * 4 + gx] != 0 {
        h264_idct_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      } else if mb[16 * i] != 0 {
        h264_idct_dc_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      }
    }
  }
  // Chroma cbp decision (needed before reconstruction: below cbp 2 the
  // decoder never sees the AC levels, so neither may the local recon).
  let chroma_c_cbp = if chroma_ac_nz_count(chroma_ac_store) {
    2
  } else if chroma_dc_nz[0] || chroma_dc_nz[1] {
    1
  } else {
    0
  }
  if chroma_c_cbp < 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < nblk; i = i + 1 {
        for k = 0; k < 16; k = k + 1 {
          if k != 0 {
            mb[256 + 256 * c + 16 * i + k] = 0
          }
        }
      }
    }
  }
  // Chroma reconstruction.
  for c = 0; c < 2; c = c + 1 {
    let plane = if c == 0 { self.rec_u } else { self.rec_v }
    if chroma_dc_nz[c] {
      if cf == 2 {
        h264_chroma422_dc_dequant_idct(
          mb,
          256 + 256 * c,
          qmul_dc422[c][0],
          bit_depth=self.p.bit_depth,
        )
      } else {
        h264_chroma_dc_dequant_idct(
          mb,
          256 + 256 * c,
          qmul_c[c][0],
          bit_depth=self.p.bit_depth,
        )
      }
    }
    for i = 0; i < nblk; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let off = cbase + by * self.cstride + bx
      let bo = 256 + 256 * c + 16 * i
      // AC residuals only exist for the decoder when chroma cbp == 2;
      // below that its nz stays zero and only the DC path applies.
      let nzv = if chroma_c_cbp == 2 {
        chroma_block_nz(chroma_ac_store[c], i)
      } else {
        0
      }
      if nzv != 0 {
        h264_idct_add(
          plane,
          off,
          self.cstride,
          mb,
          bo,
          bit_depth=self.p.bit_depth,
        )
      } else if mb[bo] != 0 {
        h264_idct_dc_add(
          plane,
          off,
          self.cstride,
          mb,
          bo,
          bit_depth=self.p.bit_depth,
        )
      }
    }
  }
  // ---- syntax ----
  if use_i16 {
    // `h264_i16x16_cbp` = [0, 16, 32, 15, 31, 47]: groups 0..2 are the
    // no-luma-AC classes (chroma 0/DC/AC), groups 3..5 add luma AC.
    let group = if luma_cbp != 0 { 3 + chroma_c_cbp } else { chroma_c_cbp }
    // The I16 mode field of mb_type is ordered V/H/DC/Plane (spec
    // Table 7-11; the decoder's `h264_i16x16_pred` maps it back), while
    // the encoder tracks the pred8 numbering DC/H/V/Plane.
    let spec_mode = match i16_mode {
      0 => 2 // DC
      1 => 1 // H
      2 => 0 // V
      _ => 3 // Plane
    }
    r.put_ue(1 + spec_mode + 4 * group)
    r.put_ue(chroma_mode)
    r.put_se(self.mb_dqp) // mb_qp_delta
    self.prev_qp = self.mb_qp
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
    // DC block (16 coefficients, full scan).
    let dc_scan : Array[Int32] = scan_view_at(
      luma_dc_store, 0, h264_zigzag_scan_t, 0, 16,
    )
    ignore(
      h264_enc_write_residual(
        r,
        dc_scan,
        16,
        self.nc_block0(mb_idx, mb_x, mb_y),
      ),
    )
    if luma_cbp != 0 {
      for i = 0; i < 16; i = i + 1 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let view = scan_view_at(luma_store, i, h264_zigzag_scan_t, 1, 15)
        let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
        self.cur_nz[gy * 4 + gx] = h264_enc_write_residual(r, view, 15, nc)
      }
    }
  } else {
    r.put_ue(0) // mb_type: I_NxN
    // transform_size_8x8_flag: present for every I_NxN macroblock once the
    // PPS enables the mode (the decoder reads it before the pred modes).
    if self.dct8x8 {
      r.put_bit(if use_i8 { 1 } else { 0 })
    }
    // One prediction mode per 4x4 block, or per 8x8 block (the z-order
    // 0/4/8/12 grid cells; cur_modes carries the 2x2 replication).
    let mode_step = if use_i8 { 4 } else { 1 }
    for i = 0; i < 16; i = i + mode_step {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let predicted = self.pred_mode(mb_idx, mb_x, mb_y, gx, gy)
      let mode = self.cur_modes[g]
      if mode == predicted {
        r.put_bit(1)
      } else {
        r.put_bit(0)
        let rem = if mode > predicted { mode - 1 } else { mode }
        r.put(rem, 3)
      }
    }
    r.put_ue(chroma_mode)
    let cbp = luma_cbp | (chroma_c_cbp << 4)
    let code = h264_enc_cbp_golomb(cbp)
    r.put_ue(code)
    if cbp != 0 {
      r.put_se(self.mb_dqp) // mb_qp_delta
      self.prev_qp = self.mb_qp
      if self.mb_dqp != 0 {
        self.stats.dqp_mbs += 1
      }
    }
    if use_i8 {
      // 8x8DCT luma residual: each coded quadrant is four interleaved
      // 16-coefficient CAVLC lists (`zigzag_scan8x8_cavlc`: one global
      // zigzag, sub-list element k is position 4*k + sub), each with the
      // nC of its own 4x4 grid cell; afterwards the quadrant's leader cell
      // accumulates the quadrant total (`nnz[0] += nnz[1] + nnz[8] +
      // nnz[9]` in `decode_luma_residual`).
      for q = 0; q < 4; q = q + 1 {
        if (luma_cbp & (1 << q)) != 0 {
          for sub = 0; sub < 4; sub = sub + 1 {
            let index = 4 * q + sub
            let gx = h264_luma_block_x[index]
            let gy = h264_luma_block_y[index]
            let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
            let view = h264_cavlc8_sub_view(luma8_store, q, sub)
            self.cur_nz[gy * 4 + gx] = h264_enc_write_residual(r, view, 16, nc)
          }
          let leader = h264_luma_block_grid[4 * q]
          self.cur_nz[leader] = self.cur_nz[leader] +
            self.cur_nz[leader + 1] +
            self.cur_nz[leader + 4] +
            self.cur_nz[leader + 5]
        }
      }
    } else {
      for i8 = 0; i8 < 4; i8 = i8 + 1 {
        if (luma_cbp & (1 << i8)) != 0 {
          for i4 = 0; i4 < 4; i4 = i4 + 1 {
            let i = i8 * 4 + i4
            let gx = h264_luma_block_x[i]
            let gy = h264_luma_block_y[i]
            let view = scan_view_at(luma_store, i, h264_zigzag_scan_t, 0, 16)
            let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
            // cur_nz already set during the quantise pass.
            ignore(h264_enc_write_residual(r, view, 16, nc))
          }
        }
      }
    }
  }
  // Chroma residual writing (both paths, identical position in the syntax).
  // `§420`: the 4:2:2 DC block codes EIGHT levels with the chroma422 VLC
  // tables (already zigzag-ordered by the quantiser), the AC loop covers
  // the doubled per-plane block count.
  if chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
      if cf == 2 {
        let dc8 : Array[Int32] = Array::make(8, 0)
        for k = 0; k < 8; k = k + 1 {
          dc8[k] = chroma_dc_store[c][k]
        }
        ignore(h264_enc_write_residual(r, dc8, 8, 0))
      } else {
        let dc4 : Array[Int32] = [
          chroma_dc_store[c][0],
          chroma_dc_store[c][1],
          chroma_dc_store[c][2],
          chroma_dc_store[c][3],
        ]
        ignore(h264_enc_write_residual(r, dc4, 4, 0))
      }
    }
  }
  if chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < nblk; i = i + 1 {
        let view = scan_view_at(
          chroma_ac_store[c],
          i,
          h264_zigzag_scan_t,
          1,
          15,
        )
        let nc = self.nc_chroma(mb_idx, mb_x, mb_y, c, i)
        chroma_ac_nz[nblk * c + i] = h264_enc_write_residual(r, view, 15, nc)
        self.cur_nz[16 + 16 * c + i] = chroma_ac_nz[nblk * c + i]
      }
    }
  }
  // Commit the per-MB mirror state.
  for i = 0; i < 48; i = i + 1 {
    state.nz[i] = self.cur_nz[i]
  }
  for i = 0; i < 16; i = i + 1 {
    state.modes[i] = self.cur_modes[i]
  }
  state.intra4x4 = !use_i16
  state.transform_8x8 = use_i8
  state.qp = self.p.qp_ext(self.mb_qp)
  Ok(())
}

///|
/// nz total of one chroma AC block (stored levels). */
fn chroma_block_nz(store : Array[Int32], i : Int32) -> Int32 {
  let mut total = 0
  for s = 0; s < 16; s = s + 1 {
    if store[16 * i + s] != 0 {
      total = total + 1
    }
  }
  total
}

///|
fn chroma_ac_nz_count(store : Array[Array[Int32]]) -> Bool {
  for c = 0; c < 2; c = c + 1 {
    for i = 0; i < store[c].length(); i = i + 1 {
      if store[c][i] != 0 {
        return true
      }
    }
  }
  false
}

///|
/// Zigzag view of one 16-level block inside `store` at block index
/// `block_i`: `out[k] = store[16 * block_i + scan[scan_start + k]]`. */
fn scan_view_at(
  store : Array[Int32],
  block_i : Int32,
  scan : Array[Int32],
  scan_start : Int32,
  max_coeff : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(max_coeff, 0)
  for k = 0; k < max_coeff; k = k + 1 {
    out[k] = store[16 * block_i + scan[scan_start + k]]
  }
  out
}

///|
/// Scan view of one 64-level 8x8DCT block inside `store` at block index
/// `block_i`: `out[k] = store[64 * block_i + scan[k]]` (no scan_start -
/// the 8x8 block always codes its full scan from position 0). */
fn scan8_view_at(
  store : Array[Int32],
  block_i : Int32,
  scan : Array[Int32],
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(64, 0)
  for k = 0; k < 64; k = k + 1 {
    out[k] = store[64 * block_i + scan[k]]
  }
  out
}

///|
/// Inverse of `h264_golomb_to_intra4x4_cbp`: the codeNum for a packed cbp. */
fn h264_enc_cbp_golomb(cbp : Int32) -> Int32 {
  for i = 0; i < 48; i = i + 1 {
    if h264_golomb_to_intra4x4_cbp[i] == cbp {
      return i
    }
  }
  // Unreachable for encoder-produced cbp values.
  0
}

///|
/// §421: the 4:4:4 cbp code (`golomb_to_intra4x4_cbp_gray`, 16 entries —
/// one 4-bit luma pattern shared by all three planes).
fn h264_enc_cbp_golomb_gray(cbp : Int32) -> Int32 {
  for i = 0; i < 16; i = i + 1 {
    if h264_golomb_to_intra4x4_cbp_gray[i] == cbp {
      return i
    }
  }
  0
}
