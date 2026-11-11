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
/// parsers consume directly. `dct8x8` switches the profile to High (100),
/// the profile family `transform_8x8_mode` requires.
fn h264_enc_sps_rbsp(p : H264EncParams, dct8x8~ : Bool = false) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 {
    h264_enc_sps_body_high(r, p)
  } else {
    h264_enc_sps_body(r, p)
  }
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Write the SPS NAL (nal_unit_type 7, ref_idc 3). */
fn h264_enc_write_sps(p : H264EncParams, dct8x8~ : Bool = false) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 {
    h264_enc_sps_body_high(r, p)
  } else {
    h264_enc_sps_body(r, p)
  }
  r.trailing_bits()
  h264_enc_nal(r, 3, 7)
}

///|
/// High-profile SPS body (profile_idc 100): the High family inserts the
/// chroma_format_idc block after seq_parameter_set_id; no scaling matrix is
/// signalled (seq flag 0), so the flat-16 default lists stay active on both
/// sides. No constraint flags: the PPS-tail skip of `more_rbsp_data_in_pps`
/// only applies to profiles 66/77/88 with a constraint set.
fn h264_enc_sps_body_high(r : H264Rbsp, p : H264EncParams) -> Unit {
  r.put(100, 8) // profile_idc: High
  r.put(0, 8) // constraint_set0..5 + reserved_zero_2bits
  r.put(p.level_idc, 8)
  r.put_ue(0) // seq_parameter_set_id
  r.put_ue(1) // chroma_format_idc: 4:2:0
  r.put_ue(0) // bit_depth_luma_minus8
  r.put_ue(0) // bit_depth_chroma_minus8
  r.put_bit(0) // qpprime_y_zero_transform_bypass_flag
  r.put_bit(0) // seq_scaling_matrix_present_flag
  r.put_ue(0) // log2_max_frame_num_minus4 -> 4-bit frame_num
  r.put_ue(2) // pic_order_cnt_type = 2 (no POC syntax)
  r.put_ue(1) // max_num_ref_frames
  r.put_bit(0) // gaps_in_frame_num_value_allowed_flag
  r.put_ue(p.mb_width() - 1)
  r.put_ue(p.mb_height() - 1)
  r.put_bit(1) // frame_mbs_only_flag
  r.put_bit(1) // direct_8x8_inference_flag
  let crop = p.width % 16 != 0 || p.height % 16 != 0
  r.put_bit(if crop { 1 } else { 0 })
  if crop {
    r.put_ue(0) // frame_crop_left_offset
    r.put_ue((p.mb_width() * 16 - p.width) / 2)
    r.put_ue(0) // frame_crop_top_offset
    r.put_ue((p.mb_height() * 16 - p.height) / 2)
  }
  r.put_bit(0) // vui_parameters_present_flag
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
/// The PPS RBSP bytes (parsers consume these directly). `dct8x8` appends the
/// High-profile tail (`transform_8x8_mode_flag`); the reader only enters
/// the tail when more_rbsp_data remains, so the baseline stream above must
/// stay byte-identical when the flag is off.
fn h264_enc_pps_rbsp(p : H264EncParams, dct8x8~ : Bool = false) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_pps_body(r, p, dct8x8~)
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Write the PPS NAL (nal_unit_type 8, ref_idc 3). */
fn h264_enc_write_pps(p : H264EncParams, dct8x8~ : Bool = false) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_pps_body(r, p, dct8x8~)
  r.trailing_bits()
  h264_enc_nal(r, 3, 8)
}

///|
fn h264_enc_pps_body(
  r : H264Rbsp,
  p : H264EncParams,
  dct8x8~ : Bool = false,
) -> Unit {
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
  if dct8x8 {
    r.put_bit(1) // transform_8x8_mode_flag
    r.put_bit(0) // pic_scaling_matrix_present_flag
    r.put_se(0) // second_chroma_qp_index_offset
  }
}

///|
/// Per-macroblock luma activity (mean absolute deviation about the MB mean,
/// integer) plus the picture average - the adaptive-quantisation input.
fn h264_aq_measure(
  src_y : Array[Int32],
  ystride : Int32,
  mb_width : Int32,
  mb_height : Int32,
) -> (Array[Int32], Int32) {
  let n = mb_width * mb_height
  let act : Array[Int32] = Array::make(n, 0)
  let mut total = 0
  for mb = 0; mb < n; mb = mb + 1 {
    let mbx = mb % mb_width
    let mby = mb / mb_width
    let base = mby * 16 * ystride + mbx * 16
    let mut sum = 0
    for row = 0; row < 16; row = row + 1 {
      for col = 0; col < 16; col = col + 1 {
        sum = sum + src_y[base + row * ystride + col]
      }
    }
    let mean = sum / 256
    let mut dev = 0
    for row = 0; row < 16; row = row + 1 {
      for col = 0; col < 16; col = col + 1 {
        let d = src_y[base + row * ystride + col] - mean
        dev = dev + (if d < 0 { -d } else { d })
      }
    }
    act[mb] = dev / 256
    total = total + act[mb]
  }
  (act, total / n)
}

///|
/// The +-1 adaptive-quantisation rule: texture 25% above the picture
/// average takes one QP step up (detail masks quantisation noise), 25%
/// below takes one step down (flat blocks show every artefact); the middle
/// band stays. Zero QP offset when the whole picture is uniform.
fn h264_aq_adj(act : Int32, avg : Int32) -> Int32 {
  if avg <= 0 {
    return 0
  }
  if act * 4 > avg * 5 {
    1
  } else if act * 4 < avg * 3 {
    -1
  } else {
    0
  }
}
