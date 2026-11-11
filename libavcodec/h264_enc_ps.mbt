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
/// Constrained-buffer (VBV/CPB) configuration shared by the SPS VUI, the
/// buffering-period/picture-timing SEIs and the per-picture quantiser
/// search. `maxrate`/`bufsize` are bits per second and bits; they are
/// rounded down to the multiples the SPS HRD syntax can express, and the
/// declared values are what the rate control actually tracks.
pub struct H264Vbv {
  bufsize : Int32
  fps : Int32
  /// Initial CPB fullness in bits (`vbv_init` percent of `bufsize`).
  init_bits : Int32
  /// Nominal bits removed by one picture (`maxrate / fps`).
  rate_bits : Int32
  bit_rate_scale : Int32
  bit_rate_value_minus1 : Int32
  cpb_size_scale : Int32
  cpb_size_value_minus1 : Int32
  /// `initial_cpb_removal_delay` in 90 kHz units, and its buffering-period
  /// offset partner (both written at
  /// `initial_cpb_removal_delay_length = 24` bits).
  init_delay : Int32
  init_delay_offset : Int32
  /// Syntax-element widths in bits (constant for a whole stream).
  initial_cpb_removal_delay_length : Int32
  cpb_removal_delay_length : Int32
  dpb_output_delay_length : Int32
}

///|
/// Validate and derive the CPB configuration. `maxrate`/`bufsize` are
/// rounded down to multiples of 64/16 bits (HRD units with scale 0); the
/// declared (rounded) values feed both the SPS and the simulation, so the
/// stream never claims more than the user asked for.
fn h264_vbv_new(
  maxrate : Int32,
  bufsize : Int32,
  fps : Int32,
  init_pct : Int32,
) -> Result[H264Vbv, String] {
  if maxrate <= 0 || bufsize <= 0 || fps <= 0 {
    return Err("h264 enc: vbv needs positive maxrate, bufsize and fps")
  }
  if maxrate < 64 || bufsize < 16 {
    return Err("h264 enc: vbv maxrate/bufsize below the HRD resolution")
  }
  if init_pct < 1 || init_pct > 100 {
    return Err("h264 enc: vbv_init must be 1..100")
  }
  if fps > 1_000_000_000 {
    return Err("h264 enc: vbv fps out of range")
  }
  let bit_rate_scale = 0
  let bit_rate_value_minus1 = maxrate / 64 - 1
  let cpb_size_scale = 0
  let cpb_size_value_minus1 = bufsize / 16 - 1
  let declared_rate = (bit_rate_value_minus1 + 1) << 6
  let declared_size = (cpb_size_value_minus1 + 1) << 4
  let rate_bits = declared_rate / fps
  if rate_bits < 1 {
    return Err("h264 enc: vbv maxrate below one bit per picture")
  }
  // One nominal picture plus the smallest filler-data NAL (6 bytes: start
  // code, header, trailing byte) must fit. Without that slack a nearly
  // empty bucket could need filler to stop the next arrival overflowing
  // but be unable to spare six bytes to carry it, leaving the CPB up to
  // 47 bits over its declared size. Subtracting rather than adding avoids
  // wrapping `rate_bits + 48` for a near-Int32.max maxrate.
  if declared_size - 48 < rate_bits {
    return Err("h264 enc: vbv bufsize must hold one picture plus 48 bits")
  }
  let init_bits = (declared_size.to_int64() * init_pct.to_int64() / 100L).to_int()
  if init_bits < 1 {
    return Err("h264 enc: vbv initial fullness is zero")
  }
  let init_delay64 = init_bits.to_int64() * 90000L / declared_rate.to_int64()
  if init_delay64 > 0xFFFFFFL {
    return Err("h264 enc: vbv initial delay exceeds 24 bits")
  }
  let init_delay = init_delay64.to_int()
  Ok({
    bufsize: declared_size,
    fps,
    init_bits,
    rate_bits,
    bit_rate_scale,
    bit_rate_value_minus1,
    cpb_size_scale,
    cpb_size_value_minus1,
    init_delay,
    init_delay_offset: if init_delay < 90000 {
      90000 - init_delay
    } else {
      0
    },
    initial_cpb_removal_delay_length: 24,
    cpb_removal_delay_length: 16,
    dpb_output_delay_length: 4,
  })
}

///|
/// VUI for a CPB-constrained stream: timing info at one frame = two
/// `num_units_in_tick` clocks (the frame-doubling convention), CBR NAL HRD
/// with one CPB and no reordering.
fn h264_enc_sps_vui(r : H264Rbsp, v : H264Vbv) -> Unit {
  r.put_bit(1) // vui_parameters_present_flag
  r.put_bit(0) // aspect_ratio_info_present_flag
  r.put_bit(0) // overscan_info_present_flag
  r.put_bit(0) // video_signal_type_present_flag
  r.put_bit(0) // chroma_loc_info_present_flag
  r.put_bit(1) // timing_info_present_flag
  r.put(1, 32) // num_units_in_tick
  r.put(v.fps * 2, 32) // time_scale: one frame = two ticks
  r.put_bit(1) // fixed_frame_rate_flag
  r.put_bit(1) // nal_hrd_parameters_present_flag
  r.put_ue(0) // cpb_cnt_minus1
  r.put(v.bit_rate_scale, 4)
  r.put(v.cpb_size_scale, 4)
  r.put_ue(v.bit_rate_value_minus1)
  r.put_ue(v.cpb_size_value_minus1)
  r.put_bit(1) // cbr_flag
  r.put(v.initial_cpb_removal_delay_length - 1, 5)
  r.put(v.cpb_removal_delay_length - 1, 5)
  r.put(v.dpb_output_delay_length - 1, 5)
  r.put(0, 5) // time_offset_length
  r.put_bit(0) // vcl_hrd_parameters_present_flag
  r.put_bit(0) // low_delay_hrd_flag
  r.put_bit(0) // pic_struct_present_flag
  r.put_bit(1) // bitstream_restriction_flag
  r.put_bit(0) // motion_vectors_over_pic_boundaries_flag
  r.put_ue(0) // max_bytes_per_pic_denom
  r.put_ue(0) // max_bits_per_mb_denom
  r.put_ue(15) // log2_max_mv_length_horizontal
  r.put_ue(15) // log2_max_mv_length_vertical
  r.put_ue(0) // max_num_reorder_frames: IPPP
  r.put_ue(1) // max_dec_frame_buffering
}

///|
/// The SPS RBSP bytes (no NAL header, no emulation prevention) - what the
/// parsers consume directly. `dct8x8` switches the profile to High (100),
/// the profile family `transform_8x8_mode` requires.
fn h264_enc_sps_rbsp(
  p : H264EncParams,
  dct8x8~ : Bool = false,
  vbv~ : H264Vbv? = None,
) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 {
    h264_enc_sps_body_high(r, p, vbv~)
  } else {
    h264_enc_sps_body(r, p, vbv~)
  }
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Write the SPS NAL (nal_unit_type 7, ref_idc 3). */
fn h264_enc_write_sps(
  p : H264EncParams,
  dct8x8~ : Bool = false,
  vbv~ : H264Vbv? = None,
) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 {
    h264_enc_sps_body_high(r, p, vbv~)
  } else {
    h264_enc_sps_body(r, p, vbv~)
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
fn h264_enc_sps_body_high(
  r : H264Rbsp,
  p : H264EncParams,
  vbv~ : H264Vbv? = None,
) -> Unit {
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
  match vbv {
    None => r.put_bit(0) // vui_parameters_present_flag
    Some(v) => h264_enc_sps_vui(r, v)
  }
}

///|
fn h264_enc_sps_body(
  r : H264Rbsp,
  p : H264EncParams,
  vbv~ : H264Vbv? = None,
) -> Unit {
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
  match vbv {
    None => r.put_bit(0) // vui_parameters_present_flag
    Some(v) => h264_enc_sps_vui(r, v)
  }
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
/// Texture 25% above/below the picture average takes +/-strength QP
/// steps (0..6, default 1); the middle band and uniform pictures stay.
fn h264_aq_adj(act : Int32, avg : Int32, strength : Int32) -> Int32 {
  if avg <= 0 {
    return 0
  }
  if act * 4 > avg * 5 {
    strength
  } else if act * 4 < avg * 3 {
    -strength
  } else {
    0
  }
}

// ---------------------------------------------------------------------------
// SEI / filler writers for the CPB-constrained mode
// ---------------------------------------------------------------------------

///|
/// Wrap one SEI payload in a type-6 NAL. The `payload_size` counts only the
/// syntax bytes (zero-padded to a byte boundary); the `rbsp_trailing_bits`
/// that close the NAL are a separate byte, as in x264. FFmpeg strips the
/// trailing bits from the NAL before parsing the payload, so folding them
/// into `payload_size` would make every message look truncated by one byte.
fn h264_enc_sei_nal(payload_type : Int32, payload : H264Rbsp) -> Bytes {
  let data = payload.finish_raw_of()
  let r = H264Rbsp::new()
  r.put(payload_type, 8)
  r.put(data.length(), 8) // our payloads are far below the 255-byte step
  for i = 0; i < data.length(); i = i + 1 {
    r.put(data[i].to_int() & 0xFF, 8)
  }
  r.trailing_bits()
  h264_enc_nal(r, 0, 6)
}

///|
/// `buffering_period` SEI: declares the initial CPB fullness through the
/// 90 kHz removal delay (the offset keeps delay+offset inside one second,
/// the x264 convention this encoder mirrors).
fn h264_enc_sei_buffering_period(v : H264Vbv) -> Bytes {
  let p = H264Rbsp::new()
  p.put_ue(0) // seq_parameter_set_id
  p.put(v.init_delay, v.initial_cpb_removal_delay_length)
  p.put(v.init_delay_offset, v.initial_cpb_removal_delay_length)
  h264_enc_sei_nal(0, p)
}

///|
/// `pic_timing` SEI: the picture's CPB removal delay in
/// `num_units_in_tick` clocks (two per frame) and no DPB reordering delay.
fn h264_enc_sei_pic_timing(v : H264Vbv, cpb_removal_delay : Int32) -> Bytes {
  let p = H264Rbsp::new()
  p.put(cpb_removal_delay, v.cpb_removal_delay_length)
  p.put(0, v.dpb_output_delay_length)
  h264_enc_sei_nal(1, p)
}

///|
/// A filler-data NAL (type 12, ref_idc 0): `payload_len - 1` 0xFF bytes
/// followed by rbsp_trailing_bits. Only the byte length matters to the CPB
/// bookkeeping; decoders discard the NAL.
fn h264_enc_filler_nal(payload_len : Int32) -> Bytes {
  let n = if payload_len < 1 { 1 } else { payload_len }
  let out : Array[Byte] = [b'\x00', b'\x00', b'\x00', b'\x01', b'\x0c']
  for _i = 0; _i < n - 1; _i = _i + 1 {
    out.push(b'\xFF')
  }
  out.push(b'\x80')
  Bytes::from_array(out[:])
}
