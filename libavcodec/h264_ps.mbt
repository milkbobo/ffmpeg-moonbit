///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/h264_ps.c`, `h264_ps.h` and the
/// extradata walker of `libavcodec/h264_parse.c`
/// (`ff_h264_decode_seq_parameter_set`, `ff_h264_decode_picture_parameter_set`,
/// `decode_vui_parameters`, scaling matrices, and `ff_h264_decode_extradata`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope / deviations from the C:
///   * The `AVCodecContext` knobs that change parsing are not modelled:
///     `AV_CODEC_FLAG2_IGNORE_CROP` (crop is always applied), the `SMV2`
///     codec-tag `num_ref_frames` floor, and `strict_std_compliance` (the
///     level-derived `num_reorder_frames` is computed only when
///     `ref_frame_count != 0`, matching the default compliance).
///   * The decoder-derived tables `dequant4_coeff`/`dequant8_coeff` and
///     `chroma_qp_table` are not built; they are only consumed by the H.264
///     reconstruction path and add no syntax information.
///   * `ps->sps`/`ps->pps` active-set bookkeeping and RefStruct reference
///     counting are omitted (MoonBit manages memory); the per-id lists are
///     kept and a repeated SPS/PPS replaces the entry.
///   * Extradata SPS decoding does not perform the C's "re-parse the raw,
///     still-escaped NAL" fallback for non-conforming files.
///   * Logging is dropped, as elsewhere in this port.

// ---------------------------------------------------------------------------
// limits and data tables
// ---------------------------------------------------------------------------

///| `MAX_SPS_COUNT`. */
pub let max_sps_count : Int = 32

///| `MAX_PPS_COUNT`. */
pub let max_pps_count : Int = 256

///| `H264_MAX_DPB_FRAMES`. */
let h264_max_dpb_frames : Int = 16

///| `MAX_LOG2_MAX_FRAME_NUM`. */
let max_log2_max_frame_num : Int = 16

///| `MIN_LOG2_MAX_FRAME_NUM`. */
let min_log2_max_frame_num : Int = 4

///| `default_scaling4[2][16]`. */
let default_scaling4 : Array[Array[Int]] = [
  [6, 13, 20, 28, 13, 20, 28, 32, 20, 28, 32, 37, 28, 32, 37, 42],
  [10, 14, 20, 24, 14, 20, 24, 27, 20, 24, 27, 30, 24, 27, 30, 34],
]

///| `default_scaling8[2][64]`. */
let default_scaling8 : Array[Array[Int]] = [
  [
    6, 10, 13, 16, 18, 23, 25, 27, 10, 11, 16, 18, 23, 25, 27, 29, 13, 16, 18,
    23, 25, 27, 29, 31, 16, 18, 23, 25, 27, 29, 31, 33, 18, 23, 25, 27, 29, 31,
    33, 36, 23, 25, 27, 29, 31, 33, 36, 38, 25, 27, 29, 31, 33, 36, 38, 40, 27,
    29, 31, 33, 36, 38, 40, 42,
  ],
  [
    9, 13, 15, 17, 19, 21, 22, 24, 13, 13, 17, 19, 21, 22, 24, 25, 15, 17, 19,
    21, 22, 24, 25, 27, 17, 19, 21, 22, 24, 25, 27, 28, 19, 21, 22, 24, 25, 27,
    28, 30, 21, 22, 24, 25, 27, 28, 30, 32, 22, 24, 25, 27, 28, 30, 32, 33, 24,
    25, 27, 28, 30, 32, 33, 35,
  ],
]

///| `ff_zigzag_scan[16]` (mathtables.c). */
let ff_zigzag_scan : Array[Int] = [
  0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15,
]

///| `ff_zigzag_direct[64]` (mathtables.c). */
let ff_zigzag_direct : Array[Int] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40,
  48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
  54, 47, 55, 62, 63,
]

///| `level_max_dpb_mbs[][2]`. */
let level_max_dpb_mbs : Array[(Int, Int)] = [
  (10, 396), (11, 900), (12, 2376), (13, 2376), (20, 2376), (21, 4752),
  (22, 8100), (30, 8100), (31, 18000), (32, 20480), (40, 32768), (41, 32768),
  (42, 34816), (50, 110400), (51, 184320), (52, 184320),
]

// ---------------------------------------------------------------------------
// parameter set structures
// ---------------------------------------------------------------------------

///|
/// `SPS` from h264_ps.h. All decoder-visible syntax fields are present; the
/// derived dequant tables live on `PPS` in the C and are omitted here.
pub struct H264Sps {
  mut sps_id : Int
  mut profile_idc : Int
  mut level_idc : Int
  mut chroma_format_idc : Int
  mut transform_bypass : Int
  mut log2_max_frame_num : Int
  mut poc_type : Int
  mut log2_max_poc_lsb : Int
  mut delta_pic_order_always_zero_flag : Int
  mut offset_for_non_ref_pic : Int
  mut offset_for_top_to_bottom_field : Int
  mut poc_cycle_length : Int
  mut ref_frame_count : Int
  mut gaps_in_frame_num_allowed_flag : Int
  mut mb_width : Int
  mut mb_height : Int
  mut frame_mbs_only_flag : Int
  mut mb_aff : Int
  mut direct_8x8_inference_flag : Int
  mut crop : Int
  mut crop_left : Int
  mut crop_right : Int
  mut crop_top : Int
  mut crop_bottom : Int
  mut vui_parameters_present_flag : Int
  vui : H2645Vui
  mut timing_info_present_flag : Int
  mut num_units_in_tick : Int
  mut time_scale : Int
  mut fixed_frame_rate_flag : Int
  offset_for_ref_frame : Array[Int]
  mut bitstream_restriction_flag : Int
  mut num_reorder_frames : Int
  mut max_dec_frame_buffering : Int
  mut scaling_matrix_present : Int
  mut scaling_matrix_present_mask : Int
  scaling_matrix4 : Array[Array[Int]]
  scaling_matrix8 : Array[Array[Int]]
  mut nal_hrd_parameters_present_flag : Int
  mut vcl_hrd_parameters_present_flag : Int
  mut pic_struct_present_flag : Int
  mut time_offset_length : Int
  mut cpb_cnt : Int
  mut bit_rate_scale : Int
  bit_rate_value : Array[Int]
  cpb_size_value : Array[Int]
  mut cpr_flag : UInt
  mut initial_cpb_removal_delay_length : Int
  mut cpb_removal_delay_length : Int
  mut dpb_output_delay_length : Int
  mut bit_depth_luma : Int
  mut bit_depth_chroma : Int
  mut residual_color_transform_flag : Int
  mut constraint_set_flags : Int
  mut data : Bytes
  mut data_size : Int
}

///| `PPS` from h264_ps.h (decoder-derived tables omitted, see file header). */
pub struct H264Pps {
  mut pps_id : Int
  mut sps_id : Int
  mut cabac : Int
  mut pic_order_present : Int
  mut slice_group_count : Int
  mut mb_slice_group_map_type : Int
  mut ref_count_l0 : Int
  mut ref_count_l1 : Int
  mut weighted_pred : Int
  mut weighted_bipred_idc : Int
  mut init_qp : Int
  mut init_qs : Int
  mut chroma_qp_index_offset0 : Int
  mut chroma_qp_index_offset1 : Int
  mut deblocking_filter_parameters_present : Int
  mut constrained_intra_pred : Int
  mut redundant_pic_cnt_present : Int
  mut transform_8x8_mode : Int
  mut pic_scaling_matrix_present_flag : Int
  mut pic_scaling_matrix_present_mask : Int
  scaling_matrix4 : Array[Array[Int]]
  scaling_matrix8 : Array[Array[Int]]
  mut chroma_qp_diff : Int
  mut data : Bytes
  mut data_size : Int
}

///| `H264ParamSets`: the per-id parameter set lists. */
pub struct H264ParamSets {
  sps_list : Array[H264Sps?]
  pps_list : Array[H264Pps?]
}

///| Empty parameter set store (`H264ParamSets ps = {0}`). */
pub fn new_h264_param_sets() -> H264ParamSets {
  let sps : Array[H264Sps?] = Array::make(max_sps_count, None)
  let pps : Array[H264Pps?] = Array::make(max_pps_count, None)
  { sps_list: sps, pps_list: pps }
}

///| One SPS with the C's zero/default initialisers. */
fn new_h264_sps() -> H264Sps {
  {
    sps_id: 0,
    profile_idc: 0,
    level_idc: 0,
    chroma_format_idc: 0,
    transform_bypass: 0,
    log2_max_frame_num: 0,
    poc_type: 0,
    log2_max_poc_lsb: 0,
    delta_pic_order_always_zero_flag: 0,
    offset_for_non_ref_pic: 0,
    offset_for_top_to_bottom_field: 0,
    poc_cycle_length: 0,
    ref_frame_count: 0,
    gaps_in_frame_num_allowed_flag: 0,
    mb_width: 0,
    mb_height: 0,
    frame_mbs_only_flag: 0,
    mb_aff: 0,
    direct_8x8_inference_flag: 0,
    crop: 0,
    crop_left: 0,
    crop_right: 0,
    crop_top: 0,
    crop_bottom: 0,
    vui_parameters_present_flag: 0,
    vui: new_h2645_vui(),
    timing_info_present_flag: 0,
    num_units_in_tick: 0,
    time_scale: 0,
    fixed_frame_rate_flag: 0,
    offset_for_ref_frame: Array::make(256, 0),
    bitstream_restriction_flag: 0,
    num_reorder_frames: 0,
    max_dec_frame_buffering: 0,
    scaling_matrix_present: 0,
    scaling_matrix_present_mask: 0,
    scaling_matrix4: make_scaling4(),
    scaling_matrix8: make_scaling8(),
    nal_hrd_parameters_present_flag: 0,
    vcl_hrd_parameters_present_flag: 0,
    pic_struct_present_flag: 0,
    time_offset_length: 24,
    cpb_cnt: 0,
    bit_rate_scale: 0,
    bit_rate_value: Array::make(32, 0),
    cpb_size_value: Array::make(32, 0),
    cpr_flag: 0U,
    initial_cpb_removal_delay_length: 0,
    cpb_removal_delay_length: 0,
    dpb_output_delay_length: 0,
    bit_depth_luma: 0,
    bit_depth_chroma: 0,
    residual_color_transform_flag: 0,
    constraint_set_flags: 0,
    data: b"",
    data_size: 0,
  }
}

///| One PPS with the C's zero initialisers. */
fn new_h264_pps() -> H264Pps {
  {
    pps_id: 0,
    sps_id: 0,
    cabac: 0,
    pic_order_present: 0,
    slice_group_count: 0,
    mb_slice_group_map_type: 0,
    ref_count_l0: 0,
    ref_count_l1: 0,
    weighted_pred: 0,
    weighted_bipred_idc: 0,
    init_qp: 0,
    init_qs: 0,
    chroma_qp_index_offset0: 0,
    chroma_qp_index_offset1: 0,
    deblocking_filter_parameters_present: 0,
    constrained_intra_pred: 0,
    redundant_pic_cnt_present: 0,
    transform_8x8_mode: 0,
    pic_scaling_matrix_present_flag: 0,
    pic_scaling_matrix_present_mask: 0,
    scaling_matrix4: make_scaling4(),
    scaling_matrix8: make_scaling8(),
    chroma_qp_diff: 0,
    data: b"",
    data_size: 0,
  }
}

///| Six independent 16-entry matrices (an `Array::make` fill would alias). */
fn make_scaling4() -> Array[Array[Int]] {
  [
    Array::make(16, 16),
    Array::make(16, 16),
    Array::make(16, 16),
    Array::make(16, 16),
    Array::make(16, 16),
    Array::make(16, 16),
  ]
}

///| Six independent 64-entry matrices. */
fn make_scaling8() -> Array[Array[Int]] {
  [
    Array::make(64, 16),
    Array::make(64, 16),
    Array::make(64, 16),
    Array::make(64, 16),
    Array::make(64, 16),
    Array::make(64, 16),
  ]
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

///| `av_image_check_size(w, h, ...)` for `AV_PIX_FMT_NONE`: the C derives
/// `stride = 8*w + 1024` and requires `stride*(h+128) < INT_MAX`. */
fn h264_image_check_size(w : Int, h : Int) -> Bool {
  if w <= 0 || h <= 0 {
    return false
  }
  let stride = 8L * w.to_int64() + 1024L
  stride < 2147483647L && stride * (h.to_int64() + 128L) < 2147483647L
}

///| Copy `sps->data`/`pps->data` semantics: `get_bits_bytesize(gb, 1)` bytes
/// from the start of the NAL, truncated to 4096, with the stop bit re-added
/// when the SODB ends on a byte boundary.
fn parameter_set_data(gb : BitReader, bit_length : Int) -> (Bytes, Int) {
  let n = gb.bytesize(true)
  let limit = if n > 4096 { 4096 } else { n }
  let raw = gb.bytes.clamped_view(start=0, end=limit).to_owned()
  if (bit_length & 7) == 0 && limit < 4096 {
    let out = FixedArray::make(limit + 1, b'\x00')
    for i = 0; i < limit; i = i + 1 {
      out[i] = raw[i]
    }
    out[limit] = b'\x80'
    (Bytes::from_array(out), limit + 1)
  } else {
    (raw, limit)
  }
}

///| `decode_scaling_list`: `jvt_list` is the preset fallback, `fallback_list`
/// the predicted matrix. Returns whether the list was present. */
fn decode_scaling_list(
  gb : BitReader,
  factors : Array[Int],
  size : Int,
  jvt_list : Array[Int],
  fallback_list : Array[Int]
) -> Result[Bool, String] {
  let present = gb.read1() != 0
  if !present {
    for i = 0; i < size; i = i + 1 {
      factors[i] = fallback_list[i]
    }
    return Ok(false)
  }
  let scan = if size == 16 { ff_zigzag_scan } else { ff_zigzag_direct }
  let mut last = 8
  let mut next = 8
  for i = 0; i < size; i = i + 1 {
    if next != 0 {
      let v = gb.read_se()
      if v < -128 || v > 127 {
        return Err("EINVAL")
      }
      next = (last + v) & 0xFF
    }
    if i == 0 && next == 0 {
      for j = 0; j < size; j = j + 1 {
        factors[j] = jvt_list[j]
      }
      break
    }
    last = if next != 0 { next } else { last }
    factors[scan[i]] = last
  }
  Ok(true)
}

///|
/// `decode_scaling_matrices`: fills `m4`/`m8` and returns `(mask, ret)`.
/// `transform_8x8_mode` is the PPS flag (ignored when `is_sps`).
fn decode_scaling_matrices(
  gb : BitReader,
  sps : H264Sps,
  is_sps : Bool,
  present_flag : Int,
  transform_8x8_mode : Bool,
  m4 : Array[Array[Int]],
  m8 : Array[Array[Int]]
) -> Result[(Int, Int), String] {
  let fallback_sps = !is_sps && sps.scaling_matrix_present != 0
  let fallback0 = if fallback_sps { sps.scaling_matrix4[0] } else { default_scaling4[0] }
  let fallback1 = if fallback_sps { sps.scaling_matrix4[3] } else { default_scaling4[1] }
  let fallback2 = if fallback_sps { sps.scaling_matrix8[0] } else { default_scaling8[0] }
  let fallback3 = if fallback_sps { sps.scaling_matrix8[3] } else { default_scaling8[1] }
  let mut mask = 0
  if present_flag == 0 {
    return Ok((0, 0))
  }
  let p0 = match decode_scaling_list(gb, m4[0], 16, default_scaling4[0], fallback0) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if p0 { mask = mask | (1 << 0) }
  let p1 = match decode_scaling_list(gb, m4[1], 16, default_scaling4[0], m4[0]) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if p1 { mask = mask | (1 << 1) }
  let p2 = match decode_scaling_list(gb, m4[2], 16, default_scaling4[0], m4[1]) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if p2 { mask = mask | (1 << 2) }
  let p3 = match decode_scaling_list(gb, m4[3], 16, default_scaling4[1], fallback1) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if p3 { mask = mask | (1 << 3) }
  let p4 = match decode_scaling_list(gb, m4[4], 16, default_scaling4[1], m4[3]) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if p4 { mask = mask | (1 << 4) }
  let p5 = match decode_scaling_list(gb, m4[5], 16, default_scaling4[1], m4[4]) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if p5 { mask = mask | (1 << 5) }
  if is_sps || transform_8x8_mode {
    let p6 = match decode_scaling_list(gb, m8[0], 64, default_scaling8[0], fallback2) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    if p6 { mask = mask | (1 << 6) }
    let p7 = match decode_scaling_list(gb, m8[3], 64, default_scaling8[1], fallback3) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    if p7 { mask = mask | (1 << 7) }
    if sps.chroma_format_idc == 3 {
      let p8 = match decode_scaling_list(gb, m8[1], 64, default_scaling8[0], m8[0]) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      if p8 { mask = mask | (1 << 8) }
      let p9 = match decode_scaling_list(gb, m8[4], 64, default_scaling8[1], m8[3]) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      if p9 { mask = mask | (1 << 9) }
      let p10 = match decode_scaling_list(gb, m8[2], 64, default_scaling8[0], m8[1]) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      if p10 { mask = mask | (1 << 10) }
      let p11 = match decode_scaling_list(gb, m8[5], 64, default_scaling8[1], m8[4]) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      if p11 { mask = mask | (1 << 11) }
    }
  }
  Ok((mask, if is_sps { 1 } else { 0 }))
}

///| `decode_hrd_parameters`. */
fn decode_hrd_parameters(gb : BitReader, sps : H264Sps) -> Result[Unit, String] {
  let cpb = gb.read_ue31()
  if cpb < 0 {
    return Err("EINVAL")
  }
  let cpb_count = cpb + 1
  if cpb_count > 32 {
    return Err("EINVAL")
  }
  sps.cpr_flag = 0U
  sps.bit_rate_scale = gb.read(4).reinterpret_as_int()
  let _ = gb.read(4) // cpb_size_scale
  for i = 0; i < cpb_count; i = i + 1 {
    sps.bit_rate_value[i] = (gb.read_ue_long() + 1UL).to_int()
    sps.cpb_size_value[i] = (gb.read_ue_long() + 1UL).to_int()
    sps.cpr_flag = sps.cpr_flag | (gb.read1() << i)
  }
  sps.initial_cpb_removal_delay_length = gb.read(5).reinterpret_as_int() + 1
  sps.cpb_removal_delay_length = gb.read(5).reinterpret_as_int() + 1
  sps.dpb_output_delay_length = gb.read(5).reinterpret_as_int() + 1
  sps.time_offset_length = gb.read(5).reinterpret_as_int()
  sps.cpb_cnt = cpb_count
  Ok(())
}

///| `decode_vui_parameters`. */
fn decode_vui_parameters(gb : BitReader, sps : H264Sps) -> Result[Unit, String] {
  ff_h2645_decode_common_vui_params(gb, sps.vui)
  // `show_bits1(gb) && get_bits_left(gb) < 10`: truncated VUI, accept as-is.
  if gb.show(1) == 1 && gb.bits_left() < 10 {
    return Ok(())
  }
  sps.timing_info_present_flag = gb.read1().reinterpret_as_int()
  if sps.timing_info_present_flag != 0 {
    let num_units = gb.read(32)
    let time_scale = gb.read(32)
    if num_units == 0U || time_scale == 0U {
      sps.timing_info_present_flag = 0
    } else {
      sps.num_units_in_tick = num_units.reinterpret_as_int()
      sps.time_scale = time_scale.reinterpret_as_int()
    }
    sps.fixed_frame_rate_flag = gb.read1().reinterpret_as_int()
  }
  sps.nal_hrd_parameters_present_flag = gb.read1().reinterpret_as_int()
  if sps.nal_hrd_parameters_present_flag != 0 {
    match decode_hrd_parameters(gb, sps) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  sps.vcl_hrd_parameters_present_flag = gb.read1().reinterpret_as_int()
  if sps.vcl_hrd_parameters_present_flag != 0 {
    match decode_hrd_parameters(gb, sps) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  if sps.nal_hrd_parameters_present_flag != 0 ||
    sps.vcl_hrd_parameters_present_flag != 0 {
    let _ = gb.read1() // low_delay_hrd_flag
  }
  sps.pic_struct_present_flag = gb.read1().reinterpret_as_int()
  if gb.bits_left() == 0 {
    return Ok(())
  }
  sps.bitstream_restriction_flag = gb.read1().reinterpret_as_int()
  if sps.bitstream_restriction_flag != 0 {
    let _ = gb.read1() // motion_vectors_over_pic_boundaries_flag
    let _ = gb.read_ue31() // max_bytes_per_pic_denom
    let _ = gb.read_ue31() // max_bits_per_mb_denom
    let _ = gb.read_ue31() // log2_max_mv_length_horizontal
    let _ = gb.read_ue31() // log2_max_mv_length_vertical
    sps.num_reorder_frames = gb.read_ue31()
    sps.max_dec_frame_buffering = gb.read_ue31()
    if gb.bits_left() < 0 {
      sps.num_reorder_frames = 0
      sps.bitstream_restriction_flag = 0
    }
    if sps.num_reorder_frames > 16 {
      sps.num_reorder_frames = 16
      return Err("EINVAL")
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// SPS / PPS
// ---------------------------------------------------------------------------

///|
/// `ff_h264_decode_seq_parameter_set`: parse an SPS from `gb` (positioned at
/// the byte after the NAL header) into `ps`.
pub fn ff_h264_decode_seq_parameter_set(
  gb : BitReader,
  ps : H264ParamSets,
  ignore_truncation : Bool
) -> Result[Unit, String] {
  let sps = new_h264_sps()
  // `get_bits_bytesize(gb, 1)` uses `size_in_bits`, not the bits left.
  let (data, data_size) = parameter_set_data(gb, gb.size_bits())
  sps.data = data
  sps.data_size = data_size

  sps.profile_idc = gb.read(8).reinterpret_as_int()
  let mut constraint_set_flags = 0
  constraint_set_flags = constraint_set_flags | (gb.read1() << 0).reinterpret_as_int()
  constraint_set_flags = constraint_set_flags | (gb.read1() << 1).reinterpret_as_int()
  constraint_set_flags = constraint_set_flags | (gb.read1() << 2).reinterpret_as_int()
  constraint_set_flags = constraint_set_flags | (gb.read1() << 3).reinterpret_as_int()
  constraint_set_flags = constraint_set_flags | (gb.read1() << 4).reinterpret_as_int()
  constraint_set_flags = constraint_set_flags | (gb.read1() << 5).reinterpret_as_int()
  gb.skip(2) // reserved_zero_2bits
  sps.level_idc = gb.read(8).reinterpret_as_int()
  let sps_id = gb.read_ue31()
  if sps_id < 0 || sps_id >= max_sps_count {
    return Err("EINVAL")
  }
  sps.sps_id = sps_id
  sps.time_offset_length = 24
  sps.constraint_set_flags = constraint_set_flags
  sps.vui.video_full_range_flag = -1
  sps.vui.matrix_coeffs = avcol_spc_unspecified
  sps.scaling_matrix_present = 0

  let profile = sps.profile_idc
  if profile == 100 || profile == 110 || profile == 122 || profile == 244 ||
    profile == 44 || profile == 83 || profile == 86 || profile == 118 ||
    profile == 128 || profile == 138 || profile == 144 {
    let chroma = gb.read_ue31()
    if chroma < 0 || chroma > 3 {
      return Err("EINVAL")
    }
    sps.chroma_format_idc = chroma
    if chroma == 3 {
      sps.residual_color_transform_flag = gb.read1().reinterpret_as_int()
      if sps.residual_color_transform_flag != 0 {
        return Err("EINVAL")
      }
    }
    sps.bit_depth_luma = gb.read_ue31() + 8
    sps.bit_depth_chroma = gb.read_ue31() + 8
    if sps.bit_depth_chroma != sps.bit_depth_luma {
      return Err("EINVAL")
    }
    if sps.bit_depth_luma < 8 || sps.bit_depth_luma > 14 ||
      sps.bit_depth_chroma < 8 || sps.bit_depth_chroma > 14 {
      return Err("EINVAL")
    }
    sps.transform_bypass = gb.read1().reinterpret_as_int()
    let present = gb.read1().reinterpret_as_int()
    let (mask, ret) = match decode_scaling_matrices(
      gb, sps, true, present, false, sps.scaling_matrix4, sps.scaling_matrix8,
    ) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    sps.scaling_matrix_present_mask = mask
    sps.scaling_matrix_present = sps.scaling_matrix_present | ret
  } else {
    sps.chroma_format_idc = 1
    sps.bit_depth_luma = 8
    sps.bit_depth_chroma = 8
  }

  let log2_max_frame_num_minus4 = gb.read_ue31()
  if log2_max_frame_num_minus4 < min_log2_max_frame_num - 4 ||
    log2_max_frame_num_minus4 > max_log2_max_frame_num - 4 {
    return Err("EINVAL")
  }
  sps.log2_max_frame_num = log2_max_frame_num_minus4 + 4
  sps.poc_type = gb.read_ue31()
  if sps.poc_type == 0 {
    let t = gb.read_ue31()
    if t < 0 || t > 12 {
      return Err("EINVAL")
    }
    sps.log2_max_poc_lsb = t + 4
  } else if sps.poc_type == 1 {
    sps.delta_pic_order_always_zero_flag = gb.read1().reinterpret_as_int()
    sps.offset_for_non_ref_pic = gb.read_se_long()
    sps.offset_for_top_to_bottom_field = gb.read_se_long()
    if sps.offset_for_non_ref_pic == -2147483648 ||
      sps.offset_for_top_to_bottom_field == -2147483648 {
      return Err("EINVAL")
    }
    sps.poc_cycle_length = gb.read_ue()
    if sps.poc_cycle_length < 0 || sps.poc_cycle_length >= 256 {
      return Err("EINVAL")
    }
    for i = 0; i < sps.poc_cycle_length; i = i + 1 {
      let v = gb.read_se_long()
      if v == -2147483648 {
        return Err("EINVAL")
      }
      sps.offset_for_ref_frame[i] = v
    }
  } else if sps.poc_type != 2 {
    return Err("EINVAL")
  }

  sps.ref_frame_count = gb.read_ue31()
  if sps.ref_frame_count < 0 || sps.ref_frame_count > h264_max_dpb_frames {
    return Err("EINVAL")
  }
  sps.gaps_in_frame_num_allowed_flag = gb.read1().reinterpret_as_int()
  let mb_width = gb.read_ue()
  let mb_height = gb.read_ue()
  if mb_width < 0 || mb_height < 0 {
    return Err("EINVAL")
  }
  sps.mb_width = mb_width + 1
  sps.mb_height = mb_height + 1
  sps.frame_mbs_only_flag = gb.read1().reinterpret_as_int()
  if sps.mb_height >= 2147483647 / 2 {
    return Err("EINVAL")
  }
  sps.mb_height = sps.mb_height * (2 - sps.frame_mbs_only_flag)
  if sps.frame_mbs_only_flag == 0 {
    sps.mb_aff = gb.read1().reinterpret_as_int()
  } else {
    sps.mb_aff = 0
  }
  if sps.mb_width >= 2147483647 / 16 || sps.mb_height >= 2147483647 / 16 ||
    !h264_image_check_size(16 * sps.mb_width, 16 * sps.mb_height) {
    return Err("EINVAL")
  }
  sps.direct_8x8_inference_flag = gb.read1().reinterpret_as_int()
  sps.crop = gb.read1().reinterpret_as_int()
  if sps.crop != 0 {
    let crop_left = gb.read_ue()
    let crop_right = gb.read_ue()
    let crop_top = gb.read_ue()
    let crop_bottom = gb.read_ue()
    if crop_left < 0 || crop_right < 0 || crop_top < 0 || crop_bottom < 0 {
      return Err("EINVAL")
    }
    let width = 16 * sps.mb_width
    let height = 16 * sps.mb_height
    let vsub = if sps.chroma_format_idc == 1 { 1 } else { 0 }
    let hsub = if sps.chroma_format_idc == 1 || sps.chroma_format_idc == 2 {
      1
    } else {
      0
    }
    let step_x = 1 << hsub
    let step_y = (2 - sps.frame_mbs_only_flag) << vsub
    let cl = crop_left.to_int64()
    let cr = crop_right.to_int64()
    let ct = crop_top.to_int64()
    let cb = crop_bottom.to_int64()
    let sx = step_x.to_int64()
    let sy = step_y.to_int64()
    let int_max4 = 2147483647L / 4L
    if cl > int_max4 / sx || cr > int_max4 / sx || ct > int_max4 / sy ||
      cb > int_max4 / sy || (cl + cr) * sx >= width.to_int64() ||
      (ct + cb) * sy >= height.to_int64() {
      return Err("EINVAL")
    }
    sps.crop_left = (cl * sx).to_int()
    sps.crop_right = (cr * sx).to_int()
    sps.crop_top = (ct * sy).to_int()
    sps.crop_bottom = (cb * sy).to_int()
  } else {
    sps.crop_left = 0
    sps.crop_right = 0
    sps.crop_top = 0
    sps.crop_bottom = 0
    sps.crop = 0
  }

  sps.vui.sar_num = 0
  sps.vui.sar_den = 1
  sps.vui_parameters_present_flag = gb.read1().reinterpret_as_int()
  if sps.vui_parameters_present_flag != 0 {
    match decode_vui_parameters(gb, sps) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  if gb.bits_left() < 0 && !ignore_truncation {
    return Err("EINVAL")
  }

  if sps.bitstream_restriction_flag == 0 && sps.ref_frame_count != 0 {
    sps.num_reorder_frames = h264_max_dpb_frames - 1
    for i = 0; i < level_max_dpb_mbs.length(); i = i + 1 {
      let (level, max_mbs) = level_max_dpb_mbs[i]
      if level == sps.level_idc {
        let computed = max_mbs / (sps.mb_width * sps.mb_height)
        sps.num_reorder_frames = if computed < sps.num_reorder_frames {
          computed
        } else {
          sps.num_reorder_frames
        }
        break
      }
    }
  }

  ps.sps_list[sps_id] = Some(sps)
  Ok(())
}

///|
/// `more_rbsp_data_in_pps`: profiles 66/77/88 with any constraint_set[0-2]
/// flag do not provide more RBSP data in the PPS.
fn more_rbsp_data_in_pps(sps : H264Sps) -> Bool {
  let profile = sps.profile_idc
  if (profile == 66 || profile == 77 || profile == 88) &&
    (sps.constraint_set_flags & 7) != 0 {
    return false
  }
  true
}

///|
/// `ff_h264_decode_picture_parameter_set`. `bit_length` is the NAL's SODB
/// length (used for the trailing extension check).
pub fn ff_h264_decode_picture_parameter_set(
  gb : BitReader,
  ps : H264ParamSets,
  bit_length : Int
) -> Result[Unit, String] {
  let pps_id = gb.read_ue()
  if pps_id < 0 || pps_id >= max_pps_count {
    return Err("EINVAL")
  }
  let pps = new_h264_pps()
  let (data, data_size) = parameter_set_data(gb, bit_length)
  pps.data = data
  pps.data_size = data_size
  pps.pps_id = pps_id
  pps.sps_id = gb.read_ue31()
  if pps.sps_id < 0 || pps.sps_id >= max_sps_count {
    return Err("EINVAL")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("EINVAL")
  }
  if sps.bit_depth_luma > 14 {
    return Err("EINVAL")
  } else if sps.bit_depth_luma == 11 || sps.bit_depth_luma == 13 {
    return Err("PATCHWELCOME")
  }

  pps.cabac = gb.read1().reinterpret_as_int()
  pps.pic_order_present = gb.read1().reinterpret_as_int()
  let slice_groups = gb.read_ue()
  if slice_groups < 0 {
    return Err("EINVAL")
  }
  pps.slice_group_count = slice_groups + 1
  if pps.slice_group_count > 1 {
    pps.mb_slice_group_map_type = gb.read_ue()
    return Err("PATCHWELCOME") // FMO unsupported
  }
  let ref0 = gb.read_ue()
  let ref1 = gb.read_ue()
  if ref0 < 0 || ref1 < 0 || ref0 > 31 || ref1 > 31 {
    return Err("EINVAL")
  }
  pps.ref_count_l0 = ref0 + 1
  pps.ref_count_l1 = ref1 + 1
  let qp_bd_offset = 6 * (sps.bit_depth_luma - 8)
  pps.weighted_pred = gb.read1().reinterpret_as_int()
  pps.weighted_bipred_idc = gb.read(2).reinterpret_as_int()
  pps.init_qp = gb.read_se() + 26 + qp_bd_offset
  pps.init_qs = gb.read_se() + 26 + qp_bd_offset
  pps.chroma_qp_index_offset0 = gb.read_se()
  if pps.chroma_qp_index_offset0 < -12 || pps.chroma_qp_index_offset0 > 12 {
    return Err("EINVAL")
  }
  pps.deblocking_filter_parameters_present = gb.read1().reinterpret_as_int()
  pps.constrained_intra_pred = gb.read1().reinterpret_as_int()
  pps.redundant_pic_cnt_present = gb.read1().reinterpret_as_int()

  pps.transform_8x8_mode = 0
  for i = 0; i < 6; i = i + 1 {
    for j = 0; j < 16; j = j + 1 {
      pps.scaling_matrix4[i][j] = sps.scaling_matrix4[i][j]
    }
    for j = 0; j < 64; j = j + 1 {
      pps.scaling_matrix8[i][j] = sps.scaling_matrix8[i][j]
    }
  }

  let bits_left = bit_length - gb.count()
  if bits_left > 0 && more_rbsp_data_in_pps(sps) {
    pps.transform_8x8_mode = gb.read1().reinterpret_as_int()
    pps.pic_scaling_matrix_present_flag = gb.read1().reinterpret_as_int()
    let (mask, _) = match decode_scaling_matrices(
      gb,
      sps,
      false,
      pps.pic_scaling_matrix_present_flag,
      pps.transform_8x8_mode != 0,
      pps.scaling_matrix4,
      pps.scaling_matrix8,
    ) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    pps.pic_scaling_matrix_present_mask = mask
    pps.chroma_qp_index_offset1 = gb.read_se()
    if pps.chroma_qp_index_offset1 < -12 ||
      pps.chroma_qp_index_offset1 > 12 {
      return Err("EINVAL")
    }
  } else {
    pps.chroma_qp_index_offset1 = pps.chroma_qp_index_offset0
  }
  if pps.chroma_qp_index_offset0 != pps.chroma_qp_index_offset1 {
    pps.chroma_qp_diff = 1
  }

  ps.pps_list[pps_id] = Some(pps)
  Ok(())
}

// ---------------------------------------------------------------------------
// extradata
// ---------------------------------------------------------------------------

///| `ff_h264_decode_extradata` results: which sample-entry form was found and
/// the NAL length field width for length-prefixed samples. */
pub struct H264ExtradataInfo {
  is_avc : Bool
  nal_length_size : Int
}

///| Decode SPS/PPS NALs from a split packet (the C's `decode_extradata_ps`). */
fn h264_decode_extradata_nals(
  pkt : H2645Packet,
  ps : H264ParamSets
) -> Result[Unit, String] {
  for i = 0; i < pkt.nals.length(); i = i + 1 {
    let nal = pkt.nals[i]
    if nal.nal_type == h264_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8) // NAL header; the C's nal->gb is positioned after it
      match ff_h264_decode_seq_parameter_set(gb, ps, false) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    } else if nal.nal_type == h264_nal_pps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_picture_parameter_set(gb, ps, nal.size_bits) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
  }
  Ok(())
}

///|
/// `ff_h264_decode_extradata`: accepts both an `avcC` record (configuration
/// version 1) and an Annex B parameter set blob, decoding every SPS/PPS.
pub fn ff_h264_decode_extradata(
  data : Bytes,
  ps : H264ParamSets
) -> Result[H264ExtradataInfo, String] {
  if data.length() <= 0 {
    return Err("EINVAL")
  }
  if data[0] == b'\x01' {
    if data.length() < 7 {
      return Err("EINVAL")
    }
    let mut p = 6
    let sps_count = (data[5].to_int() & 0x1F)
    for _ in 0..<sps_count {
      if p + 2 > data.length() {
        return Err("EINVAL")
      }
      let nalsize = ((data[p].to_int() << 8) | data[p + 1].to_int()) + 2
      if nalsize > data.length() - p {
        return Err("EINVAL")
      }
      let chunk = data.clamped_view(start=p, end=p + nalsize).to_owned()
      let pkt = match ff_h2645_packet_split(chunk, 2, H264, true) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      match h264_decode_extradata_nals(pkt, ps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      p = p + nalsize
    }
    if p + 1 > data.length() {
      return Err("EINVAL")
    }
    let pps_count = data[p].to_int()
    p = p + 1
    for _ in 0..<pps_count {
      if p + 2 > data.length() {
        return Err("EINVAL")
      }
      let nalsize = ((data[p].to_int() << 8) | data[p + 1].to_int()) + 2
      if nalsize > data.length() - p {
        return Err("EINVAL")
      }
      let chunk = data.clamped_view(start=p, end=p + nalsize).to_owned()
      let pkt = match ff_h2645_packet_split(chunk, 2, H264, true) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      match h264_decode_extradata_nals(pkt, ps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      p = p + nalsize
    }
    Ok({ is_avc: true, nal_length_size: (data[4].to_int() & 0x03) + 1 })
  } else {
    let pkt = match ff_h2645_packet_split(data, 0, H264, false) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    match h264_decode_extradata_nals(pkt, ps) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    Ok({ is_avc: false, nal_length_size: 0 })
  }
}
