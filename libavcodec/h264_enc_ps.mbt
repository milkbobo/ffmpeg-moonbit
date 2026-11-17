///|
/// SPS/PPS serialisation for the H.264 encoder: the write-side twin of
/// `h264_ps.mbt`'s parsers. Slice 1 targets the encoder's own baseline
/// configuration - Baseline profile, 4:2:0, 8-bit, frame pictures, POC type
/// 2 (no POC syntax in slice headers), a single slice group, CAVLC, and
/// deblocking control syntax only when the `§433` alpha/beta offsets are
/// nonzero - so every optional branch the parsers support is written in its
/// default-off form unless explicitly opted in.

///|
/// Encoder parameter-set configuration. */
priv struct H264EncParams {
  /// Visible geometry; must be even for 4:2:0 chroma.
  width : Int32
  height : Int32
  /// Slice QP (also `pic_init_qp`), in 8-bit units 0..51 at every bit
  /// depth (§412: the stream's QP is this plus `qp_bd_offset`).
  qp : Int32
  /// Level for `level_idc` (pure metadata for the decoders under test).
  level_idc : Int32
  /// Luma/chroma bit depth, 8 (default streams) / 9 / 10 (`§412`).
  bit_depth : Int32
  /// `§415`: P-slice reference count signalled to the decoders (1 = the
  /// single-reference streams; SPS `max_num_ref_frames` and the PPS
  /// `num_ref_idx_l0_default_active_minus1` derive from it).
  nrefs : Int32
  /// `§426`: sample aspect ratio riding the SPS VUI (Extended_SAR after
  /// gcd normalisation); 0/0 keeps the aspect-ratio VUI off.
  sar : (Int32, Int32)
  /// `§433`: slice-level deblocking offsets in div2 units (-6..=6, x264
  /// `--deblock alpha:beta`). Either nonzero turns on the PPS
  /// `deblocking_filter_control_present_flag` and every slice header carries
  /// `disable_deblocking_filter_idc = 0` plus both offsets; 0/0 keeps the
  /// parameter sets and slice headers byte-identical.
  deblock_alpha : Int32
  deblock_beta : Int32
  /// `§434`: opt-in explicit weighted prediction for B slices
  /// (`weighted_bipred_idc = 1`, x264 `--weightp` plus B frames). The PPS
  /// carries the flag and both lists' weight tables ride every B slice
  /// header; `false` keeps the byte-identical unweighted path.
  weightp_b : Bool
}

///|
fn H264EncParams::mb_width(self : H264EncParams) -> Int32 {
  (self.width + 15) / 16
}

///|
/// User-space QP -> the extended QP the stream and the shared dequant
/// tables use.
fn H264EncParams::qp_ext(self : H264EncParams, qp : Int32) -> Int32 {
  h264_enc_qp_ext(qp, self.bit_depth)
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
/// The `aspect_ratio_info` fields of the VUI: the generic Extended_SAR
/// (idc 255, two 16-bit fractions) after gcd normalisation. 0/0 (or a
/// degenerate fraction) keeps the flag off - the byte stream stays
/// identical to the pre-`§426` default.
fn h264_enc_vui_aspect_ratio(r : H264Rbsp, sar : (Int32, Int32)) -> Unit {
  let (num, den) = sar
  if num > 0 && den > 0 {
    let g = h264_enc_gcd(num, den)
    r.put_bit(1) // aspect_ratio_info_present_flag
    r.put(255, 8) // aspect_ratio_idc: Extended_SAR
    r.put(num / g, 16) // sar_width
    r.put(den / g, 16) // sar_height
  } else {
    r.put_bit(0) // aspect_ratio_info_present_flag
  }
}

///|
fn h264_enc_gcd(a : Int32, b : Int32) -> Int32 {
  let mut x = if a < 0 { -a } else { a }
  let mut y = if b < 0 { -b } else { b }
  while y != 0 {
    let t = x % y
    x = y
    y = t
  }
  if x == 0 {
    1
  } else {
    x
  }
}

///|
/// VUI for a CPB-constrained stream: timing info at one frame = two
/// `num_units_in_tick` clocks (the frame-doubling convention), CBR NAL HRD
/// with one CPB and no reordering.
fn h264_enc_sps_vui(
  r : H264Rbsp,
  v : H264Vbv,
  b_frames~ : Bool = false,
  sar~ : (Int32, Int32) = (0, 0),
) -> Unit {
  r.put_bit(1) // vui_parameters_present_flag
  h264_enc_vui_aspect_ratio(r, sar)
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
  r.put_ue(if b_frames { 1 } else { 0 }) // max_num_reorder_frames
  r.put_ue(if b_frames { 2 } else { 1 }) // max_dec_frame_buffering
}

///|
/// The SPS RBSP bytes (no NAL header, no emulation prevention) - what the
/// parsers consume directly. `dct8x8` switches the profile to High (100),
/// the profile family `transform_8x8_mode` requires; `bit_depth > 8`
/// switches it to High 10 (110), which carries the same chroma/bit-depth
/// block (`§412`).
fn h264_enc_sps_rbsp(
  p : H264EncParams,
  dct8x8~ : Bool = false,
  vbv~ : H264Vbv? = None,
  chroma_format~ : Int32 = 1,
) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
    h264_enc_sps_body_high(r, p, vbv~, chroma_format~)
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
  chroma_format~ : Int32 = 1,
) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
    h264_enc_sps_body_high(r, p, vbv~, chroma_format~)
  } else {
    h264_enc_sps_body(r, p, vbv~)
  }
  r.trailing_bits()
  h264_enc_nal(r, 3, 7)
}

///|
/// High-family SPS body (profile_idc 100 High / 110 High 10 / 244 Hi444PP):
/// the High family inserts the chroma_format_idc / bit-depth block after
/// seq_parameter_set_id; no scaling matrix is signalled (seq flag 0), so the
/// flat-16 default lists stay active on both sides. No constraint flags: the
/// PPS-tail skip of `more_rbsp_data_in_pps` only applies to profiles 66/77/88
/// with a constraint set.
fn h264_enc_sps_body_high(
  r : H264Rbsp,
  p : H264EncParams,
  vbv~ : H264Vbv? = None,
  chroma_format~ : Int32 = 1,
) -> Unit {
  r.put(h264_enc_profile_idc(p.bit_depth, 100, chroma=chroma_format), 8)
  r.put(0, 8) // constraint_set0..5 + reserved_zero_2bits
  r.put(p.level_idc, 8)
  r.put_ue(0) // seq_parameter_set_id
  r.put_ue(chroma_format) // chroma_format_idc: 4:2:0 / 4:2:2 / 4:4:4
  if chroma_format == 3 {
    // §421: `separate_colour_plane_flag`. The parser reads this bit for
    // `chroma_format_idc == 3` (and rejects 1), so it must be present or
    // every following syntax element shifts by one bit.
    r.put_bit(0)
  }
  r.put_ue(p.bit_depth - 8) // bit_depth_luma_minus8
  r.put_ue(p.bit_depth - 8) // bit_depth_chroma_minus8
  r.put_bit(0) // qpprime_y_zero_transform_bypass_flag
  r.put_bit(0) // seq_scaling_matrix_present_flag
  r.put_ue(0) // log2_max_frame_num_minus4 -> 4-bit frame_num
  r.put_ue(2) // pic_order_cnt_type = 2 (no POC syntax)
  r.put_ue(p.nrefs) // max_num_ref_frames
  r.put_bit(0) // gaps_in_frame_num_value_allowed_flag
  r.put_ue(p.mb_width() - 1)
  r.put_ue(p.mb_height() - 1)
  r.put_bit(1) // frame_mbs_only_flag
  r.put_bit(1) // direct_8x8_inference_flag
  let crop = p.width % 16 != 0 || p.height % 16 != 0
  r.put_bit(if crop { 1 } else { 0 })
  if crop {
    r.put_ue(0) // frame_crop_left_offset
    r.put_ue(
      (p.mb_width() * 16 - p.width) / (if chroma_format == 3 { 1 } else { 2 }),
    )
    r.put_ue(0) // frame_crop_top_offset
    r.put_ue(
      (p.mb_height() * 16 - p.height) / (if chroma_format == 1 { 2 } else { 1 }),
    )
  }
  match vbv {
    None =>
      // `§426`: a SAR alone still needs a VUI - emit the aspect-ratio-only
      // one (all other VUI flags off). Without a SAR the stream stays
      // byte-identical to the pre-`§426` default (no VUI at all).
      if p.sar.0 > 0 && p.sar.1 > 0 {
        r.put_bit(1) // vui_parameters_present_flag
        h264_enc_vui_aspect_ratio(r, p.sar)
        r.put_bit(0) // overscan_info_present_flag
        r.put_bit(0) // video_signal_type_present_flag
        r.put_bit(0) // chroma_loc_info_present_flag
        r.put_bit(0) // timing_info_present_flag
        r.put_bit(0) // nal_hrd_parameters_present_flag
        r.put_bit(0) // vcl_hrd_parameters_present_flag
        r.put_bit(0) // pic_struct_present_flag
        r.put_bit(0) // bitstream_restriction_flag
      } else {
        r.put_bit(0) // vui_parameters_present_flag
      }
    Some(v) => h264_enc_sps_vui(r, v, sar=p.sar)
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
  r.put_ue(p.nrefs) // max_num_ref_frames
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
    None =>
      // `§426`: a SAR alone still needs a VUI - emit the aspect-ratio-only
      // one (all other VUI flags off). Without a SAR the stream stays
      // byte-identical to the pre-`§426` default (no VUI at all).
      if p.sar.0 > 0 && p.sar.1 > 0 {
        r.put_bit(1) // vui_parameters_present_flag
        h264_enc_vui_aspect_ratio(r, p.sar)
        r.put_bit(0) // overscan_info_present_flag
        r.put_bit(0) // video_signal_type_present_flag
        r.put_bit(0) // chroma_loc_info_present_flag
        r.put_bit(0) // timing_info_present_flag
        r.put_bit(0) // nal_hrd_parameters_present_flag
        r.put_bit(0) // vcl_hrd_parameters_present_flag
        r.put_bit(0) // pic_struct_present_flag
        r.put_bit(0) // bitstream_restriction_flag
      } else {
        r.put_bit(0) // vui_parameters_present_flag
      }
    Some(v) => h264_enc_sps_vui(r, v, sar=p.sar)
  }
}

///|
/// The PPS RBSP bytes (parsers consume these directly). `dct8x8` appends the
/// High-profile tail (`transform_8x8_mode_flag`); the reader only enters
/// the tail when more_rbsp_data remains, so the baseline stream above must
/// stay byte-identical when the flag is off.
fn h264_enc_pps_rbsp(
  p : H264EncParams,
  dct8x8~ : Bool = false,
  weightp~ : Bool = false,
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset (x264 `chroma-qp-offset`, -12..12);
  /// written to both `chroma_qp_index_offset` fields, 0 keeps the bytes
  /// identical to the pre-`§432` PPS.
  chroma_qp_offset~ : Int32 = 0,
) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_pps_body(r, p, dct8x8~, weightp~, chroma_format~, chroma_qp_offset~)
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Write the PPS NAL (nal_unit_type 8, ref_idc 3). */
fn h264_enc_write_pps(
  p : H264EncParams,
  dct8x8~ : Bool = false,
  weightp~ : Bool = false,
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset (see `h264_enc_pps_rbsp`).
  chroma_qp_offset~ : Int32 = 0,
) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_pps_body(r, p, dct8x8~, weightp~, chroma_format~, chroma_qp_offset~)
  r.trailing_bits()
  h264_enc_nal(r, 3, 8)
}

///|
/// `weightp` sets `weighted_pred_flag` (`§410`): with it the decoder expects
/// a `pred_weight_table()` in every P slice header, so the picture
/// encoders must emit one. Off, the PPS stays byte-identical.
fn h264_enc_pps_body(
  r : H264Rbsp,
  p : H264EncParams,
  dct8x8~ : Bool = false,
  weightp~ : Bool = false,
  /// `§420`: the High-family tail follows the SPS's profile family, so a
  /// 4:2:2 SPS (profile 122) needs it even at 8 bits with `dct8x8` off.
  chroma_format~ : Int32 = 1,
  /// `§432`: x264's single `chroma-qp-offset` feeds both offsets (Cb and
  /// Cr); the baseline PPS has no second field, where the parser copies the
  /// first one over (`h264_ps.c:811`).
  chroma_qp_offset~ : Int32 = 0,
) -> Unit {
  r.put_ue(0) // pic_parameter_set_id
  r.put_ue(0) // seq_parameter_set_id
  r.put_bit(0) // entropy_coding_mode_flag: CAVLC
  r.put_bit(0) // bottom_field_pic_order_in_frame_present_flag
  r.put_ue(0) // num_slice_groups_minus1
  r.put_ue(p.nrefs - 1) // num_ref_idx_l0_default_active_minus1
  r.put_ue(0) // num_ref_idx_l1_default_active_minus1
  r.put_bit(if weightp { 1 } else { 0 }) // weighted_pred_flag
  // `§434`: explicit B weights need both lists in every B slice header.
  r.put(if p.weightp_b { 1 } else { 0 }, 2) // weighted_bipred_idc
  // `§412`: `pic_init_qp_minus26` is the *user-space* QP difference — the
  // parser (FFmpeg `h264_ps.c:776`) adds `6 * (bit_depth - 8)` itself, so
  // re-adding it here would land the slice at user QP + 2*offset.
  r.put_se(p.qp - 26) // pic_init_qp_minus26
  r.put_se(0) // pic_init_qs_minus26
  r.put_se(chroma_qp_offset) // chroma_qp_index_offset
  // `§433`: nonzero alpha/beta offsets opt into the slice-level deblocking
  // syntax; the slice headers then carry idc 0 and both div2 offsets.
  r.put_bit(if p.deblock_alpha != 0 || p.deblock_beta != 0 { 1 } else { 0 }) // deblocking_filter_control_present_flag
  r.put_bit(0) // constrained_intra_pred_flag
  r.put_bit(0) // redundant_pic_cnt_present_flag
  // The High-family PPS tail must be written even with `transform_8x8` off:
  // the decoder enters it whenever the profile is High family and more
  // RBSP data remains (trailing bits included), so omitting it would
  // misparse the stop bit as `transform_8x8_mode_flag`.
  if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
    r.put_bit(if dct8x8 { 1 } else { 0 }) // transform_8x8_mode_flag
    r.put_bit(0) // pic_scaling_matrix_present_flag
    r.put_se(chroma_qp_offset) // second_chroma_qp_index_offset
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
  // `payload_size` in 255-byte steps: a 0xFF byte adds 255 and the next
  // byte still counts (`§427` — payloads above 254 need the extension;
  // everything below stays the single byte the earlier writers emitted).
  let mut size = data.length()
  while size >= 255 {
    r.put(0xFF, 8)
    size = size - 255
  }
  r.put(size, 8)
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
/// `num_units_in_tick` clocks (two per frame), plus its DPB output delay.
fn h264_enc_sei_pic_timing(
  v : H264Vbv,
  cpb_removal_delay : Int32,
  dpb_output_delay~ : Int32 = 0,
) -> Bytes {
  let p = H264Rbsp::new()
  p.put(cpb_removal_delay, v.cpb_removal_delay_length)
  p.put(dpb_output_delay, v.dpb_output_delay_length)
  h264_enc_sei_nal(1, p)
}

///|
/// `§427`: one `user_data_unregistered` SEI (type 5). The payload is the
/// caller's 16-byte `uuid_iso_iec_11578` followed by the user data; the
/// decoder exports the whole blob (`SeiUnregistered`, the same shape the
/// x264 binding of `§424b` forwards), so the round trip is byte-exact.
fn h264_enc_sei_unregistered(payload : Bytes) -> Result[Bytes, String] {
  if payload.length() < 16 {
    return Err(
      "h264 enc: unregistered SEI payload needs a 16-byte UUID prefix (\{payload.length()} bytes)",
    )
  }
  let p = H264Rbsp::new()
  for i = 0; i < payload.length(); i = i + 1 {
    p.put(payload[i].to_int() & 0xFF, 8)
  }
  Ok(h264_enc_sei_nal(5, p))
}

///|
/// `§427`: one ATSC A/53 closed-caption SEI (type 4, `user_data_registered_
/// itu_t_t35`) wrapping `cc` raw caption triples in the GA94 container
/// x264 emits: country 0xB5, provider 0x0031, "GA94", user_data_type_code
/// 3, `0x40|cc_count`, a reserved byte, the triples and the closing marker
/// byte. The decoder (`ff_parse_a53_cc`) returns exactly the `cc` triples.
fn h264_enc_sei_a53(cc : Bytes) -> Result[Bytes, String] {
  if cc.length() == 0 || cc.length() % 3 != 0 {
    return Err(
      "h264 enc: a53 captions must be cc_data triples (got \{cc.length()} bytes)",
    )
  }
  if cc.length() > 63 {
    return Err(
      "h264 enc: a53 captions cap at 21 triples / 63 bytes (got \{cc.length()} bytes)",
    )
  }
  let p = H264Rbsp::new()
  p.put(0xB5, 8) // itu_t_t35_country_code (United States)
  p.put(0x0031, 16) // itu_t_t35_provider_code (ATSC)
  p.put(0x47, 8) // "GA94"
  p.put(0x41, 8)
  p.put(0x39, 8)
  p.put(0x34, 8)
  p.put(0x03, 8) // user_data_type_code (cc_data)
  p.put(0x40 | (cc.length() / 3), 8) // process_cc_data_flag | cc_count
  p.put(0xFF, 8) // reserved
  for i = 0; i < cc.length(); i = i + 1 {
    p.put(cc[i].to_int() & 0xFF, 8)
  }
  p.put(0xFF, 8) // marker_bits closing the container
  Ok(h264_enc_sei_nal(4, p))
}

///|
/// `§427`: pick the side data of display position `i` from the parallel
/// arrays the batch entries accept (short/empty arrays mean "none").
fn h264_enc_sei_pick(arr : Array[Bytes?], i : Int32) -> Bytes? {
  if i < arr.length() {
    arr[i]
  } else {
    None
  }
}

///|
/// `§427`: build the 0..2 side-data SEI NALs of one picture (captions
/// first, then the unregistered payload — x264's order). The AU sites call
/// this right before the slice NAL.
fn h264_enc_sei_side_data_nals(
  a53 : Bytes?,
  sei_unregistered : Bytes?,
) -> Result[Array[Bytes], String] {
  let nals : Array[Bytes] = []
  match a53 {
    Some(cc) =>
      match h264_enc_sei_a53(cc) {
        Ok(nal) => nals.push(nal)
        Err(e) => return Err(e)
      }
    None => ()
  }
  match sei_unregistered {
    Some(payload) =>
      match h264_enc_sei_unregistered(payload) {
        Ok(nal) => nals.push(nal)
        Err(e) => return Err(e)
      }
    None => ()
  }
  Ok(nals)
}

///|
/// `§428`: one `frame_packing_arrangement` SEI (type 45), field order
/// mirrored from the decoder's parser. `stereo_type` is an
/// `AVStereo3DType` value (`av_stereo3d_*`, h264_side_data.mbt — every
/// layout except 2D); x264 semantics: the SEI rides IDR access units only
/// (following AUs carry none — the decoder resets its SEI state at every
/// access unit, so only the IDR picture exports `Stereo3d`).
fn h264_enc_sei_frame_packing(stereo_type : Int32) -> Result[Bytes, String] {
  // (arrangement_type, quincunx_sampling_flag)
  let mapped : (Int32, Int32) = match stereo_type {
    t if t == av_stereo3d_side_by_side => (3, 0)
    t if t == av_stereo3d_top_bottom => (4, 0)
    t if t == av_stereo3d_frame_sequence => (5, 0)
    t if t == av_stereo3d_checkerboard => (0, 0)
    t if t == av_stereo3d_side_by_side_quincunx => (3, 1)
    t if t == av_stereo3d_lines => (2, 0)
    t if t == av_stereo3d_columns => (1, 0)
    _ =>
      return Err(
        "h264 enc: unsupported stereo layout \{stereo_type} (av_stereo3d_* value, 0 = off)",
      )
  }
  let (arrangement_type, quincunx) = mapped
  let p = H264Rbsp::new()
  p.put_ue(0) // frame_packing_arrangement_id
  p.put(0, 1) // frame_packing_arrangement_cancel_flag
  p.put(arrangement_type, 7)
  p.put(quincunx, 1)
  p.put(1, 6) // content_interpretation_type: two views
  p.put(0, 1) // spatial_flipping_flag
  p.put(0, 1) // frame0_flipped_flag
  p.put(0, 1) // field_views_flag
  p.put(1, 1) // current_frame_is_frame0_flag
  p.put(0, 1) // frame0_self_contained_flag
  p.put(0, 1) // frame1_self_contained_flag
  if quincunx == 0 && arrangement_type != 5 {
    p.put(0, 16) // frame[01]_grid_position_[xy]
  }
  p.put(0, 8) // frame_packing_arrangement_reserved_byte
  p.put_ue(0) // frame_packing_arrangement_repetition_period
  p.put(0, 1) // frame_packing_arrangement_extension_flag
  Ok(h264_enc_sei_nal(45, p))
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
