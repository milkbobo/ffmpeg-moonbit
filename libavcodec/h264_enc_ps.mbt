///|
/// SPS/PPS serialisation for the H.264 encoder: the write-side twin of
/// `h264_ps.mbt`'s parsers. Slice 1 targets the encoder's own baseline
/// configuration - Baseline profile, 4:2:0, 8-bit, frame pictures, POC type
/// 2 (no POC syntax in slice headers), a single slice group, CAVLC, no
/// deblocking control syntax - so every optional branch the parsers support
/// is written in its default-off form.

///|
/// Encoder parameter-set configuration. */
priv struct H264EncParams {
  /// Visible geometry; must be even for 4:2:0 chroma.
  width : Int32
  height : Int32
  /// Slice QP (also `pic_init_qp`), 0..51.
  qp : Int32
  /// Level for `level_idc` (pure metadata for the decoders under test).
  level_idc : Int32
}

///|
fn H264EncParams::mb_width(self : H264EncParams) -> Int32 {
  (self.width + 15) / 16
}

///|
fn H264EncParams::mb_height(self : H264EncParams) -> Int32 {
  (self.height + 15) / 16
}

///|
/// The SPS RBSP bytes (no NAL header, no emulation prevention) - what the
/// parsers consume directly. */
fn h264_enc_sps_rbsp(p : H264EncParams) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_sps_body(r, p)
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Write the SPS NAL (nal_unit_type 7, ref_idc 3). */
fn h264_enc_write_sps(p : H264EncParams) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_sps_body(r, p)
  r.trailing_bits()
  h264_enc_nal(r, 3, 7)
}

///|
fn h264_enc_sps_body(r : H264Rbsp, p : H264EncParams) -> Unit {
  r.put(66, 8) // profile_idc: Baseline
  r.put(0xE0, 8) // constraint_set0/1/2 flags
  r.put(p.level_idc, 8)
  r.put_ue(0) // seq_parameter_set_id
  r.put_ue(0) // log2_max_frame_num_minus4 -> 4-bit frame_num
  r.put_ue(2) // pic_order_cnt_type = 2 (no POC syntax)
  r.put_ue(1) // max_num_ref_frames
  r.put_bit(0) // gaps_in_frame_num_value_allowed_flag
  r.put_ue(p.mb_width() - 1)
  r.put_ue(p.mb_height() - 1)
  r.put_bit(1) // frame_mbs_only_flag
  r.put_bit(1) // direct_8x8_inference_flag
  // frame_cropping: 96x64-style geometry is macroblock aligned, but keep
  // the general path for odd sizes.
  let crop = p.width % 16 != 0 || p.height % 16 != 0
  r.put_bit(if crop { 1 } else { 0 })
  if crop {
    // Spec order: left, right, top, bottom. The encoder only ever crops
    // the right/bottom edges (4:2:0: units of 2 luma samples).
    r.put_ue(0) // frame_crop_left_offset
    r.put_ue((p.mb_width() * 16 - p.width) / 2) // frame_crop_right_offset
    r.put_ue(0) // frame_crop_top_offset
    r.put_ue((p.mb_height() * 16 - p.height) / 2) // frame_crop_bottom_offset
  }
  r.put_bit(0) // vui_parameters_present_flag
}

///|
/// The PPS RBSP bytes (parsers consume these directly). */
fn h264_enc_pps_rbsp(p : H264EncParams) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_pps_body(r, p)
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Write the PPS NAL (nal_unit_type 8, ref_idc 3). */
fn h264_enc_write_pps(p : H264EncParams) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_pps_body(r, p)
  r.trailing_bits()
  h264_enc_nal(r, 3, 8)
}

///|
fn h264_enc_pps_body(r : H264Rbsp, p : H264EncParams) -> Unit {
  r.put_ue(0) // pic_parameter_set_id
  r.put_ue(0) // seq_parameter_set_id
  r.put_bit(0) // entropy_coding_mode_flag: CAVLC
  r.put_bit(0) // bottom_field_pic_order_in_frame_present_flag
  r.put_ue(0) // num_slice_groups_minus1
  r.put_ue(0) // num_ref_idx_l0_default_active_minus1
  r.put_ue(0) // num_ref_idx_l1_default_active_minus1
  r.put_bit(0) // weighted_pred_flag
  r.put(0, 2) // weighted_bipred_idc
  r.put_se(p.qp - 26) // pic_init_qp_minus26
  r.put_se(0) // pic_init_qs_minus26
  r.put_se(0) // chroma_qp_index_offset
  r.put_bit(0) // deblocking_filter_control_present_flag
  r.put_bit(0) // constrained_intra_pred_flag
  r.put_bit(0) // redundant_pic_cnt_present_flag
}
