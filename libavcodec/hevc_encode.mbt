///|
/// Pure-MoonBit HEVC (H.265) intra encoder, slice 1 of the port: IDR
/// pictures as single I slices (CABAC, Main/Main10, 4:2:0 8/10-bit, flat QP).
/// The porting discipline mirrors the H.264
/// encoder's: parameter sets are written then re-parsed by the decoder's
/// own `hevc_ps.mbt`, prediction and reconstruction call the decoder's
/// `hevc_intra_predict` / `hevc_idct*` / dequant kernels so the local
/// reconstruction equals the decoder's output by construction, CABAC bins
/// invert `hevc_cabac_syntax.mbt` / `hevc_decode_residual` bin for bin,
/// and the slice header mirrors `ff_hevc_decode_slice_header` field order.
///
/// wasm-only (§437a discipline): no C bindings of any kind; tests run on
/// the wasm / wasm-gc targets.

///|
/// One encoded frame: Annex B NALs plus the encoder's local reconstruction
/// (padded to the CTB-aligned picture size; the conformance window crops the
/// visible area). */
pub struct HevcEncodedFrame {
  /// VPS/SPS/PPS + slice NALs when `with_ps`, otherwise the slice NAL alone;
  /// Annex B start codes.
  annexb : Bytes
  recon_y : Array[Int32]
  recon_u : Array[Int32]
  recon_v : Array[Int32]
  ystride : Int32
  cstride : Int32
  /// The CTB-aligned (padded) picture dimensions.
  width : Int32
  height : Int32
  qp : Int32
  poc : Int32
  is_idr : Bool
  /// `hevc_slice_i` / `hevc_slice_p` / `hevc_slice_b` of the coded picture.
  slice_type : Int32
}

///|
/// One encoded sequence: the Annex B stream plus every frame's local
/// reconstruction, in coding order. */
pub struct HevcEncodedSequence {
  annexb : Bytes
  frames : Array[HevcEncodedFrame]
}

///|
/// HEVC NAL wrapper: forbidden_zero 0, nal_type(6), layer 0, temporal_id
/// plus one (1) — the two-byte header Annex B streams use. Emulation
/// prevention applies to the RBSP after the header (header bytes are
/// never zero). */
fn hevc_enc_nal(rbsp : Bytes, nal_type : Int32) -> Bytes {
  let out : Array[Byte] = [
    b'\x00',
    b'\x00',
    b'\x00',
    b'\x01',
    (nal_type << 1).to_byte(),
    b'\x01',
  ]
  let escaped = h264_enc_escape(rbsp)
  for i in 0..<escaped.length() {
    out.push(escaped[i])
  }
  Bytes::from_array(out)
}

///|
/// Profile tier level, one sub-layer: the 88-bit general PTL plus level_idc.
/// 4:2:0 at 8/10 bits writes Main (1) or Main10 (2) with the 43 reserved bits;
/// anything else — 4:2:2/4:4:4 at any depth, or 12-bit — writes the
/// Range-Extensions profile (4) with its nine constraint flags followed by 34
/// reserved bits, which is what `decode_profile_tier_level` reads back for
/// `profile_idc == 4`. */
fn hevc_enc_ptl(
  rbsp : H264Rbsp,
  level_idc : Int32,
  bit_depth : Int32,
  chroma_format_idc : Int32,
) -> Unit {
  // Main and Main10 top out at 10-bit 4:2:0, so 12-bit needs Rext even for
  // 4:2:0.
  let rext = chroma_format_idc != 1 || bit_depth > 10
  let profile_idc : Int32 = if rext {
    av_profile_hevc_rext
  } else if bit_depth == 10 {
    2
  } else {
    1
  }
  rbsp.put(0, 2) // general_profile_space
  rbsp.put_bit(0) // general_tier_flag
  rbsp.put(profile_idc, 5)
  // A Rext stream is only compatible with Rext; the Main/Main10 pair also
  // advertises Main compatibility, as x265 does.
  for i in 0..<32 {
    rbsp.put_bit(if i == profile_idc || (!rext && i == 1) { 1 } else { 0 })
  }
  rbsp.put_bit(1) // general_progressive_source_flag
  rbsp.put_bit(0) // general_interlaced_source_flag
  rbsp.put_bit(1) // general_non_packed_constraint_flag
  rbsp.put_bit(1) // general_frame_only_constraint_flag
  if rext {
    // XXX_constraint_flags, ordered as `decode_profile_tier_level` reads them.
    rbsp.put_bit(1) // max_12bit_constraint_flag
    rbsp.put_bit(if bit_depth <= 10 { 1 } else { 0 }) // max_10bit_constraint_flag
    rbsp.put_bit(if bit_depth <= 8 { 1 } else { 0 }) // max_8bit_constraint_flag
    rbsp.put_bit(if chroma_format_idc <= 2 { 1 } else { 0 }) // max_422chroma
    rbsp.put_bit(if chroma_format_idc <= 1 { 1 } else { 0 }) // max_420chroma
    rbsp.put_bit(if chroma_format_idc == 0 { 1 } else { 0 }) // max_monochrome
    rbsp.put_bit(0) // intra_constraint_flag (inter slices are allowed)
    rbsp.put_bit(0) // one_picture_only_constraint_flag
    rbsp.put_bit(0) // lower_bit_rate_constraint_flag
    for _ in 0..<34 {
      rbsp.put_bit(0) // XXX_reserved_zero_34bits
    }
  } else {
    for _ in 0..<43 {
      rbsp.put_bit(0)
    }
  }
  rbsp.put_bit(0) // general_inbld_flag / reserved
  rbsp.put(level_idc, 8)
}

///|
/// Write the VPS NAL RBSP. */
fn hevc_enc_vps(
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Bytes {
  let rbsp = H264Rbsp::new()
  rbsp.put(0, 4) // vps_video_parameter_set_id
  rbsp.put_bit(1) // vps_base_layer_internal_flag
  rbsp.put_bit(1) // vps_base_layer_available_flag
  rbsp.put(0, 6) // vps_max_layers_minus1
  rbsp.put(0, 3) // vps_max_sub_layers_minus1
  rbsp.put_bit(1) // vps_temporal_id_nesting_flag
  rbsp.put(0xFFFF, 16) // vps_reserved_0xffff_16bits
  hevc_enc_ptl(rbsp, 30, bit_depth, chroma_format_idc) // Level 1
  rbsp.put_bit(1) // vps_sub_layer_ordering_info_present_flag
  rbsp.put_ue(3) // vps_max_dec_pic_buffering_minus1 -> 4
  rbsp.put_ue(0) // vps_max_num_reorder_pics
  rbsp.put_ue(0) // vps_max_latency_increase_plus1
  rbsp.put(0, 6) // vps_max_layer_id
  rbsp.put_ue(0) // vps_num_layer_sets_minus1
  rbsp.put_bit(0) // vps_timing_info_present_flag
  rbsp.put_bit(0) // vps_extension_flag
  rbsp.trailing_bits()
  rbsp.finish_raw_of()
}

///|
/// Write the SPS NAL RBSP for the padded picture size. `pad_w`/`pad_h` are
/// min-CB aligned; the conformance window crops the visible area (offsets are
/// coded in chroma units, i.e. divided by the format's sub-sampling factors).
/// `inter` enables the P-slice tools: one short-term RPS entry (`-1`, used) and
/// the temporal-MVP flag off. `chroma_format_idc` 0/1/2/3 selects monochrome,
/// 4:2:0, 4:2:2 and 4:4:4; 4:2:2 and 4:4:4 additionally switch the PTL to the
/// Range-Extensions profile. */
fn hevc_enc_sps(
  pad_w : Int32,
  pad_h : Int32,
  crop_right : Int32,
  crop_bottom : Int32,
  inter : Bool,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Bytes {
  let rbsp = H264Rbsp::new()
  rbsp.put(0, 4) // sps_video_parameter_set_id
  rbsp.put(0, 3) // sps_max_sub_layers_minus1
  rbsp.put_bit(1) // sps_temporal_id_nesting_flag
  hevc_enc_ptl(rbsp, 30, bit_depth, chroma_format_idc)
  rbsp.put_ue(0) // sps_seq_parameter_set_id
  rbsp.put_ue(chroma_format_idc)
  if chroma_format_idc == 3 {
    rbsp.put_bit(0) // separate_colour_plane_flag
  }
  rbsp.put_ue(pad_w)
  rbsp.put_ue(pad_h)
  let horiz_mult = hevc_sub_width_c[chroma_format_idc]
  let vert_mult = hevc_sub_height_c[chroma_format_idc]
  let crop_r = crop_right / horiz_mult
  let crop_b = crop_bottom / vert_mult
  if crop_r != 0 || crop_b != 0 {
    rbsp.put_bit(1) // conformance_window_flag
    rbsp.put_ue(0) // left offset
    rbsp.put_ue(crop_r) // right offset (chroma units)
    rbsp.put_ue(0) // top offset
    rbsp.put_ue(crop_b)
  } else {
    rbsp.put_bit(0)
  }
  rbsp.put_ue(bit_depth - 8) // bit_depth_luma_minus8
  rbsp.put_ue(bit_depth - 8) // bit_depth_chroma_minus8
  rbsp.put_ue(4) // log2_max_pic_order_cnt_lsb_minus4 -> 8
  rbsp.put_bit(1) // sps_sub_layer_ordering_info_present_flag
  rbsp.put_ue(3) // sps_max_dec_pic_buffering_minus1 -> 4
  rbsp.put_ue(0) // sps_max_num_reorder_pics
  rbsp.put_ue(0) // sps_max_latency_increase_plus1
  rbsp.put_ue(0) // log2_min_luma_coding_block_size_minus3 -> 8
  rbsp.put_ue(2) // log2_diff_max_min_luma_coding_block_size -> CTB 32
  rbsp.put_ue(0) // log2_min_luma_transform_block_size_minus2 -> 4
  rbsp.put_ue(3) // log2_diff_max_min_luma_transform_block_size -> 32
  rbsp.put_ue(0) // max_transform_hierarchy_depth_inter
  rbsp.put_ue(0) // max_transform_hierarchy_depth_intra
  rbsp.put_bit(0) // scaling_list_enabled_flag
  rbsp.put_bit(0) // amp_enabled_flag
  rbsp.put_bit(1) // sample_adaptive_offset_enabled_flag (SAO on)
  rbsp.put_bit(0) // pcm_enabled_flag
  if inter {
    // One explicit (non-predicted) short-term RPS: the immediately preceding
    // picture (delta POC -1), used by P slices. B slices carry their own inline
    // RPS (one negative + one positive picture), so the SPS index stays 0 bits
    // wide and the P-slice bitstream is unchanged by B support.
    rbsp.put_ue(1) // num_short_term_ref_pic_sets
    rbsp.put_ue(1) // num_negative_pics of st_rps[0]
    rbsp.put_ue(0) // num_positive_pics of st_rps[0]
    rbsp.put_ue(0) // delta_poc_s0_minus1 -> delta_poc_s0 = -1
    rbsp.put_bit(1) // used_by_curr_pic_s0_flag
  } else {
    rbsp.put_ue(0) // num_short_term_ref_pic_sets
  }
  rbsp.put_bit(0) // long_term_ref_pics_present_flag
  rbsp.put_bit(0) // sps_temporal_mvp_enabled_flag
  rbsp.put_bit(1) // strong_intra_smoothing_enabled_flag
  rbsp.put_bit(0) // vui_parameters_present_flag
  rbsp.put_bit(0) // sps_extension_present_flag
  rbsp.trailing_bits()
  rbsp.finish_raw_of()
}

///|
/// Write the PPS NAL RBSP with the slice's base QP. `inter` turns on the P-slice
/// switches: `cabac_init_present_flag` stays 0 (so no CABAC init bin is coded)
/// and `lists_modification_present_flag` stays 0 (single reference). */
fn hevc_enc_pps(qp : Int32, inter : Bool) -> Bytes {
  ignore(inter)
  let rbsp = H264Rbsp::new()
  rbsp.put_ue(0) // pps_pic_parameter_set_id
  rbsp.put_ue(0) // pps_seq_parameter_set_id
  rbsp.put_bit(0) // dependent_slice_segments_enabled_flag
  rbsp.put_bit(0) // output_flag_present_flag
  rbsp.put(0, 3) // num_extra_slice_header_bits
  rbsp.put_bit(0) // sign_data_hiding_enabled_flag
  rbsp.put_bit(0) // cabac_init_present_flag
  rbsp.put_ue(0) // num_ref_idx_l0_default_active_minus1 -> 1
  rbsp.put_ue(0) // num_ref_idx_l1_default_active_minus1 -> 1
  rbsp.put_se(qp - 26) // init_qp_minus26
  rbsp.put_bit(0) // constrained_intra_pred_flag
  rbsp.put_bit(0) // transform_skip_enabled_flag
  rbsp.put_bit(0) // cu_qp_delta_enabled_flag
  rbsp.put_se(0) // pps_cb_qp_offset
  rbsp.put_se(0) // pps_cr_qp_offset
  rbsp.put_bit(0) // pps_slice_chroma_qp_offsets_present_flag
  rbsp.put_bit(0) // weighted_pred_flag
  rbsp.put_bit(0) // weighted_bipred_flag
  rbsp.put_bit(0) // transquant_bypass_enabled_flag
  rbsp.put_bit(0) // tiles_enabled_flag
  rbsp.put_bit(0) // entropy_coding_sync_enabled_flag
  rbsp.put_bit(0) // pps_loop_filter_across_slices_enabled_flag
  rbsp.put_bit(1) // deblocking_filter_control_present_flag
  rbsp.put_bit(0) // deblocking_filter_override_enabled_flag
  // Deblocking ON. With override_enabled = 0 the slice header codes no extra
  // bins, and the PPS offsets (both 0) apply to every CTB.
  rbsp.put_bit(0) // pps_deblocking_filter_disabled_flag
  rbsp.put_se(0) // pps_beta_offset_div2
  rbsp.put_se(0) // pps_tc_offset_div2
  rbsp.put_bit(0) // pps_scaling_list_data_present_flag
  rbsp.put_bit(0) // lists_modification_present_flag
  rbsp.put_ue(0) // log2_parallel_merge_level_minus2 -> 2
  rbsp.put_bit(0) // slice_segment_header_extension_present_flag
  rbsp.put_bit(0) // pps_extension_present_flag
  rbsp.trailing_bits()
  rbsp.finish_raw_of()
}

///|
/// Slice segment header: the write-side twin of
/// `ff_hevc_decode_slice_header` with this encoder's PPS/SPS switches.
/// `slice_type` is `hevc_slice_i` (IDR NAL type 19, so no POC/RPS syntax) or
/// `hevc_slice_p` (TRAIL_R NAL type 1, which codes POC LSB, the SPS RPS flag,
/// the reference-list count flag and the merge-candidate count).
/// Returns the byte-aligned raw RBSP; the CABAC payload is appended after. */
fn hevc_enc_slice_header(
  sps : HevcSps,
  pps : HevcPps,
  qp : Int32,
  slice_type : Int32,
  poc~ : Int32 = 0,
  rps_delta~ : Int32 = -1,
) -> Bytes {
  let rbsp = H264Rbsp::new()
  rbsp.put_bit(1) // first_slice_segment_in_pic_flag
  if slice_type == hevc_slice_i {
    rbsp.put_bit(0) // no_output_of_prior_pics_flag (IRAP)
  }
  rbsp.put_ue(0) // slice_pic_parameter_set_id
  rbsp.put_ue(slice_type)
  // SAO flags follow the short-term RPS block and precede the reference-count
  // syntax, mirroring `ff_hevc_decode_slice_header`.
  let mut sao_done = false
  if slice_type != hevc_slice_i {
    // Non-IDR picture: POC LSB, then the short-term RPS.
    rbsp.put(poc & ((1 << sps.log2_max_poc_lsb) - 1), sps.log2_max_poc_lsb)
    if slice_type == hevc_slice_b {
      // Inline RPS: one negative picture (POC-1) and one positive picture
      // (POC+1). The decoder's `hevc_slice_rpl` builds L0 from the negative
      // list and L1 from the positive list, so the two reference lists are
      // distinct without any `ref_pic_list_modification` bins.
      rbsp.put_bit(0) // short_term_ref_pic_set_sps_flag = 0 (inline)
      rbsp.put_bit(0) // inter_ref_pic_set_prediction_flag
      rbsp.put_ue(1) // num_negative_pics
      rbsp.put_ue(1) // num_positive_pics
      rbsp.put_ue(0) // delta_poc_s0_minus1 -> -1
      rbsp.put_bit(1) // used_by_curr_pic_s0_flag
      rbsp.put_ue(0) // delta_poc_s1_minus1 -> +1
      rbsp.put_bit(1) // used_by_curr_pic_s1_flag
    } else if rps_delta == -1 {
      rbsp.put_bit(1) // short_term_ref_pic_set_sps_flag (st_rps[0])
    } else {
      // Non-consecutive P reference (a B picture is coded in between): an
      // inline RPS with a single negative picture at `rps_delta`.
      rbsp.put_bit(0) // short_term_ref_pic_set_sps_flag = 0 (inline)
      rbsp.put_bit(0) // inter_ref_pic_set_prediction_flag
      rbsp.put_ue(1) // num_negative_pics
      rbsp.put_ue(0) // num_positive_pics
      rbsp.put_ue(-rps_delta - 1) // delta_poc_s0_minus1
      rbsp.put_bit(1) // used_by_curr_pic_s0_flag
    }
    if sps.sao_enabled != 0 {
      rbsp.put_bit(1) // slice_sao_luma_flag
      if sps.chroma_format_idc != 0 {
        rbsp.put_bit(0) // slice_sao_chroma_flag
      }
      sao_done = true
    }
    rbsp.put_bit(0) // num_ref_idx_active_override_flag (PPS default = 1)
    if slice_type == hevc_slice_b {
      rbsp.put_bit(0) // mvd_l1_zero_flag (L1 MVDs are coded)
    }
    rbsp.put_ue(0) // five_minus_max_num_merge_cand -> 5 candidates
  }
  if !sao_done && sps.sao_enabled != 0 {
    rbsp.put_bit(1) // slice_sao_luma_flag
    if sps.chroma_format_idc != 0 {
      rbsp.put_bit(0) // slice_sao_chroma_flag
    }
  }
  rbsp.put_se(qp - 26 - pps.pic_init_qp_minus26) // slice_qp_delta
  // deblocking: control present + no override + pps disabled -> no bits;
  // loop-filter-across-slices off -> no bit; tiles/WPP off -> no entry
  // points; header extension off.
  rbsp.put_bit(1) // alignment_bit_equal_to_one
  rbsp.align_zero()
  rbsp.finish_raw_of()
}

///|
/// Encode one frame into parameter-set/slice NALs plus the local
/// reconstruction. `y`/`u`/`v` are visible-size row-major Int32 planes;
/// `bit_depth` selects Main 8-bit, Main10 10-bit or Range-Extensions 12-bit
/// coding. */
fn hevc_enc_frame_ex(
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  width : Int32,
  height : Int32,
  qp : Int32,
  with_ps : Bool,
  slice_type : Int32,
  poc : Int32,
  ref_pic : HevcPicture,
  sequence_inter : Bool,
  bit_depth : Int32,
  chroma_format_idc : Int32,
  ref_pic_l1~ : HevcPicture = hevc_picture_new(0, 0, 0, 0),
  rps_delta~ : Int32 = -1,
) -> Result[HevcEncodedFrame, String] {
  if qp < 0 || qp > 51 {
    return Err("hevc enc: qp out of range")
  }
  if width <= 0 || height <= 0 {
    return Err("hevc enc: empty frame")
  }
  let pad_w = (width + 31) / 32 * 32
  let pad_h = (height + 31) / 32 * 32
  let horiz_mult = hevc_sub_width_c[chroma_format_idc]
  let vert_mult = hevc_sub_height_c[chroma_format_idc]
  let cw = pad_w / horiz_mult
  let ch = pad_h / vert_mult
  let inter = slice_type != hevc_slice_i
  // The SPS must describe the whole sequence, not just this picture: a stream
  // whose first picture is an I slice still needs the short-term RPS for the
  // P slices that follow. `sequence_inter` is threaded in by the caller.
  let inter_sps = inter || sequence_inter
  // Parameter sets are always written, then parsed back with the decoder's
  // own reader, so every frame exercises the writer/reader mirror.
  let vps_nal = hevc_enc_nal(hevc_enc_vps(bit_depth~, chroma_format_idc~), 32)
  let sps_nal = hevc_enc_nal(
    hevc_enc_sps(
      pad_w,
      pad_h,
      pad_w - width,
      pad_h - height,
      inter_sps,
      bit_depth~,
      chroma_format_idc~,
    ),
    33,
  )
  let pps_nal = hevc_enc_nal(hevc_enc_pps(qp, inter_sps), 34)
  let ps = new_hevc_param_sets()
  match
    ff_hevc_decode_extradata(
      hevc_enc_concat([vps_nal, sps_nal, pps_nal]),
      ps,
      true,
    ) {
    Ok(_) => ()
    Err(e) => return Err("hevc enc: parameter sets do not round-trip: \{e}")
  }
  let sps = match ps.sps_list[0] {
    Some(s) => s
    None => return Err("hevc enc: SPS missing after round-trip")
  }
  let pps = match ps.pps_list[0] {
    Some(p) => p
    None => return Err("hevc enc: PPS missing after round-trip")
  }
  let nal_type = if slice_type == hevc_slice_i { 19 } else { 1 }
  let header = hevc_enc_slice_header(sps, pps, qp, slice_type, poc~, rps_delta~)
  let sh = match hevc_enc_parse_slice_header(header, nal_type, ps) {
    Ok(h) => h
    Err(e) => return Err("hevc enc: slice header does not round-trip: \{e}")
  }
  // Pad the source planes by edge replication.
  let sy : FixedArray[Int32] = FixedArray::make(pad_w * pad_h, 0)
  let su : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  let sv : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  hevc_enc_pad_plane(y, sy, width, height, pad_w, pad_h)
  hevc_enc_pad_plane(u, su, width / horiz_mult, height / vert_mult, cw, ch)
  hevc_enc_pad_plane(v, sv, width / horiz_mult, height / vert_mult, cw, ch)
  let pic = hevc_picture_new(pad_w, pad_h, cw, ch)
  // SAO needs the *deblocked* reconstruction to decide its per-CTB offsets, but
  // the parameters must be coded before the CTB data. Run the CTU loop twice:
  // pass 1 codes with every CTB's SAO type "off" (valid syntax, correctly sized
  // parameter arrays) and produces the deblocked reconstruction, the decision
  // then reads it, and pass 2 re-codes with the real parameters in place. Every
  // pixel-level decision is deterministic and independent of the CABAC state,
  // so pass 2's reconstruction is identical to pass 1's apart from SAO itself.
  let sao_off = hevc_sao_params_new(sps.ctb_size, sps.ctb_width)

  match
    hevc_enc_ctu_loop_slice(
      sps,
      pps,
      sh,
      qp,
      sy,
      su,
      sv,
      pic,
      slice_type,
      ref_pic,
      ref_pic_l1~,
      sao=sao_off,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let sao = if sps.sao_enabled != 0 && sh.slice_sao_luma_flag {
    hevc_enc_sao_decide(sps, sy, pic)
  } else {
    hevc_sao_params_new(sps.ctb_size, sps.ctb_width)
  }
  // Pass 2 rebuilds the reconstruction from scratch, now with SAO applied.
  let pic = hevc_picture_new(pad_w, pad_h, cw, ch)
  let payload = match
    hevc_enc_ctu_loop_slice(
      sps,
      pps,
      sh,
      qp,
      sy,
      su,
      sv,
      pic,
      slice_type,
      ref_pic,
      ref_pic_l1~,
      sao~,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let rbsp : Array[Byte] = []
  for i in 0..<header.length() {
    rbsp.push(header[i])
  }
  for i in 0..<payload.length() {
    rbsp.push(payload[i])
  }
  let parts : Array[Bytes] = []
  if with_ps {
    parts.push(vps_nal)
    parts.push(sps_nal)
    parts.push(pps_nal)
  }
  parts.push(hevc_enc_nal(Bytes::from_array(rbsp), nal_type))
  Ok({
    annexb: hevc_enc_concat(parts),
    recon_y: pic.y,
    recon_u: pic.cb,
    recon_v: pic.cr,
    ystride: pad_w,
    cstride: cw,
    width: pad_w,
    height: pad_h,
    qp,
    poc,
    is_idr: slice_type == hevc_slice_i,
    slice_type,
  })
}

///|
/// Parse a written slice header back with the decoder's own
/// `ff_hevc_decode_slice_header`. `rbsp` is the *raw* (unescaped) header RBSP
/// from `hevc_enc_slice_header`, read with its exact bit length: going through
/// `ff_h2645_packet_split` would trim the trailing alignment bits, which a
/// header-only NAL cannot afford even though a real slice NAL can. */
fn hevc_enc_parse_slice_header(
  rbsp : Bytes,
  nal_type : Int32,
  ps : HevcParamSets,
) -> Result[HevcSliceHeader, String] {
  let gb = BitReader::with_size(rbsp, rbsp.length() * 8)
  ff_hevc_decode_slice_header(gb, nal_type, ps, 0)
}

///|
/// Concatenate NAL chunks. */
fn hevc_enc_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for i in 0..<part.length() {
      out.push(part[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// Edge-replicate a `w` x `h` plane into the padded `pw` x `ph` buffer. */
fn hevc_enc_pad_plane(
  src : FixedArray[Int32],
  dst : FixedArray[Int32],
  w : Int32,
  h : Int32,
  pw : Int32,
  ph : Int32,
) -> Unit {
  for y in 0..<ph {
    let sy = if y < h { y } else { h - 1 }
    for x in 0..<pw {
      let sx = if x < w { x } else { w - 1 }
      dst[y * pw + x] = src[sy * w + sx]
    }
  }
}

///|
/// Validate plane sizes and the coding bit depth for the encoder entry. The
/// luma plane is always `width` x `height`; the chroma planes are
/// `width / horiz_mult` x `height / vert_mult`, with the sub-sampling factors
/// of `chroma_format_idc` (1 -> 2x2, 2 -> 2x1, 3 -> 1x1). */
fn hevc_enc_guard_frame(
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  width : Int32,
  height : Int32,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Result[Unit, String] {
  if bit_depth != 8 && bit_depth != 10 && bit_depth != 12 {
    return Err("hevc enc: bit_depth must be 8, 10 or 12")
  }
  if chroma_format_idc < 1 || chroma_format_idc > 3 {
    return Err("hevc enc: chroma_format_idc must be 1, 2 or 3")
  }
  let horiz_mult = hevc_sub_width_c[chroma_format_idc]
  let vert_mult = hevc_sub_height_c[chroma_format_idc]
  let cw = width / horiz_mult
  let ch = height / vert_mult
  if width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0 {
    return Err("hevc enc: dimensions must be even and positive")
  }
  if y.length() < width * height || u.length() < cw * ch || v.length() < cw * ch {
    return Err("hevc enc: plane too small")
  }
  Ok(())
}

///|
/// Encode a sequence of frames into one Annex B stream. Every picture is an
/// IDR I slice (the §448 contract); use `hevc_encode_sequence` for an I/P/B
/// stream with inter prediction. All frames share one VPS/SPS/PPS; `qp` is the
/// flat per-picture QP (0..51). `bit_depth = 10` selects Main10 and
/// `bit_depth = 12` plus `chroma_format_idc` 2/3 selects Range Extensions; the
/// defaults remain 4:2:0 8-bit Main. `crf >= 0` (0.0..=51.0) replaces the flat
/// QP with the §458 quality-driven per-picture QPs and makes `qp` a no-op. */
pub fn hevc_encode_frames(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  crf~ : Double = -1.0,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Result[Bytes, String] {
  match
    hevc_encode_sequence(
      frames,
      width~,
      height~,
      qp~,
      crf~,
      inter=false,
      bit_depth~,
      chroma_format_idc~,
    ) {
    Ok(seq) => Ok(seq.annexb)
    Err(e) => Err(e)
  }
}

///|
/// Encode a sequence and return both the stream and every frame's local
/// reconstruction. With `inter = true` (the default) the first picture is an
/// IDR I slice and every later picture a P slice referencing its immediate
/// predecessor; with `inter = false` every picture is an IDR I slice.
/// `b_slices` enables the alternating I/P/B coding order. `bit_depth = 10`
/// selects Main10 and `bit_depth = 12` selects Range Extensions for all slice
/// types; `chroma_format_idc` 2/3 selects 4:2:2/4:4:4 under the Range
/// Extensions profile. 4:2:0 8-bit Main remains the default. `crf >= 0`
/// (0.0..=51.0) replaces the flat `qp` with the §458 causal per-picture QPs
/// (display-order temporal complexity against the running mean); under CRF
/// the `qp` argument is ignored. */
pub fn hevc_encode_sequence(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  crf~ : Double = -1.0,
  inter~ : Bool = true,
  b_slices~ : Bool = false,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Result[HevcEncodedSequence, String] {
  if frames.length() == 0 {
    return Err("hevc enc: no frames")
  }
  if crf > 51.0 {
    return Err("hevc enc: crf must be in 0.0..=51.0")
  }
  for f in frames {
    match
      hevc_enc_guard_frame(
        f.0,
        f.1,
        f.2,
        width,
        height,
        bit_depth~,
        chroma_format_idc~,
      ) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  let out : Array[Byte] = []
  let encoded : Array[HevcEncodedFrame] = []
  let mut ref_pic = hevc_picture_new(0, 0, 0, 0)
  // Display order == POC order; the coding order is the identity unless B
  // slices are enabled. With B slices the order becomes I0, P2, B1, P4, B3, ...
  // (each pair of pictures codes its future P first, then the B that sits
  // between them), so a B slice always has both of its references available.
  let n = frames.length()
  let order : Array[Int32] = []
  let with_ps : Array[Bool] = []
  if inter && b_slices && n >= 3 {
    // Even indices are anchors (I0, P2, P4, ...). Each B at an odd index `a+1`
    // sits between the anchors `a` and `a+2`, so the anchor after it must be
    // coded first. A trailing odd picture (even frame count) has no future
    // anchor and is coded as a P instead.
    order.push(0)
    with_ps.push(true)
    let mut a = 0
    while a + 2 < n {
      order.push(a + 2)
      with_ps.push(false)
      order.push(a + 1)
      with_ps.push(false)
      a = a + 2
    }
    if a + 1 < n {
      order.push(a + 1)
      with_ps.push(false)
    }
  } else {
    for i in 0..<n {
      order.push(i)
      with_ps.push(i == 0)
    }
  }
  // §458: under CRF the per-display-position QPs replace the flat qp. The
  // controller is display-causal, so the B-slice coding reordering never
  // reorders it — the loop looks frames up by display index.
  let qps = if crf >= 0.0 {
    hevc_enc_crf_qps(frames, width, height, crf)
  } else {
    []
  }
  // Reference bookkeeping: `ref_pic` is the most recently coded anchor (L0 for
  // P and B slices) and `ref_pic_l1` the future anchor a B slice points at.
  let mut prev_anchor = hevc_picture_new(0, 0, 0, 0)
  for k in 0..<order.length() {
    let i = order[k]
    let (y, u, v) = frames[i]
    let pic_qp = if crf >= 0.0 { qps[i] } else { qp }
    // A B slice needs a coded anchor on both sides of it.
    let is_b_interleaved = inter && b_slices && n >= 3
    let is_b = is_b_interleaved && i % 2 == 1 && i + 1 < n
    let slice_type = if !inter || i == 0 {
      hevc_slice_i
    } else if is_b {
      hevc_slice_b
    } else {
      hevc_slice_p
    }
    // A B picture sits between two anchors: L0 is the previous anchor and L1
    // the one that was just coded ahead of it.
    let l0 = if is_b { prev_anchor } else { ref_pic }
    let l1 = if is_b { ref_pic } else { hevc_picture_new(0, 0, 0, 0) }

    // The L0 reference of an interleaved P anchor sits two display steps
    // back: the B picture between it and the previous anchor (display i-1)
    // exists whenever the anchor itself does — the schedule parks it right
    // after the anchor in coding order. This includes the final anchor of an
    // odd-length sequence (its `i + 1` is past the end, but the B behind it
    // at `i - 1` is what makes the gap two). A trailing P (odd display
    // position, no B between it and the previous anchor) has the picture
    // right before it as L0, so it keeps the default delta of -1. B slices
    // carry their own inline RPS (handled inside the header writer), so only
    // the P case needs an explicit delta.
    let anchor_gap_two = is_b_interleaved && i % 2 == 0
    let rps_delta = if slice_type == hevc_slice_p && anchor_gap_two {
      -2
    } else {
      -1
    }
    let frame = match
      hevc_enc_frame_ex(
        y,
        u,
        v,
        width,
        height,
        pic_qp,
        with_ps[k],
        slice_type,
        i,
        l0,
        inter,
        bit_depth,
        chroma_format_idc,
        ref_pic_l1=l1,
        rps_delta~,
      ) {
      Ok(f) => f
      Err(e) => return Err(e)
    }
    for b in frame.annexb {
      out.push(b)
    }
    let recon = {
      width: frame.width,
      height: frame.height,
      cw: frame.width / hevc_sub_width_c[chroma_format_idc],
      ch: frame.height / hevc_sub_height_c[chroma_format_idc],
      y: frame.recon_y.copy(),
      cb: frame.recon_u.copy(),
      cr: frame.recon_v.copy(),
    }
    if !is_b {
      // An anchor: it becomes the next picture's L0 reference. The anchor
      // before it moves to `prev_anchor` so a following B can reach it.
      if slice_type == hevc_slice_p || slice_type == hevc_slice_i {
        if ref_pic.width > 0 {
          prev_anchor = ref_pic
        }
        ref_pic = recon
      }
    }
    encoded.push(frame)
  }
  Ok({ annexb: Bytes::from_array(out), frames: encoded, })
}

///|
/// Encode a single intra frame, returning the Annex B NALs (VPS/SPS/PPS +
/// slice) and the local reconstruction for round-trip assertions. */
pub fn hevc_encode_intra_frame(
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Result[HevcEncodedFrame, String] {
  match
    hevc_enc_guard_frame(y, u, v, width, height, bit_depth~, chroma_format_idc~) {
    Err(e) => Err(e)
    Ok(_) =>
      hevc_enc_frame_ex(
        y,
        u,
        v,
        width,
        height,
        qp,
        true,
        hevc_slice_i,
        0,
        hevc_picture_new(0, 0, 0, 0),
        false,
        bit_depth,
        chroma_format_idc,
      )
  }
}
