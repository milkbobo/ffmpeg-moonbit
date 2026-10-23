///|
/// H.264 / AVC SEI decoding + common H.264/HEVC SEI messages.
///
/// Ported from `libavcodec/h264_sei.c` (H.264 SEI message loop and the
/// H.264-specific pic_timing / recovery_point / buffering_period /
/// green_metadata messages) and `libavcodec/h2645_sei.c` (the common
/// H.264+HEVC message set: user data registered/unregistered, display
/// orientation, frame packing arrangement, film grain characteristics,
/// alternative transfer, ambient viewing environment, mastering display
/// colour volume, content light level).
///
/// Copyright (c) 2003 Michael Niedermayer <michaelni@gmx.at>
/// Copyright (C) 2012 - 2013 Guillaume Martres
/// Copyright (C) 2012 - 2013 Gildas Cocherel
/// Copyright (C) 2013 Vittorio Giovara
///
/// This file is part of FFmpeg and is LGPL-2.1-or-later; see the C sources
/// for the full license header.
///
/// Implementation deviations from the C:
/// - The AVFrame/AVCodecContext side-data plumbing lives in
///   `h264_side_data.mbt` (`sei_to_frame`); this file only decodes the
///   messages into the structs below.
/// - Diagnostic av_log calls (unknown type, overread, verbose T35) are
///   dropped; errors keep the exact `EINVAL` semantics of the C.

///|
/// `sei.h` SEI type constants used by the dispatch below. */
pub let sei_type_buffering_period : Int32 = 0

///|
pub let sei_type_pic_timing : Int32 = 1

///|
pub let sei_type_user_data_registered_itu_t_t35 : Int32 = 4

///|
pub let sei_type_user_data_unregistered : Int32 = 5

///|
pub let sei_type_recovery_point : Int32 = 6

///|
pub let sei_type_film_grain_characteristics : Int32 = 19

///|
pub let sei_type_frame_packing_arrangement : Int32 = 45

///|
pub let sei_type_display_orientation : Int32 = 47

///|
pub let sei_type_green_metadata : Int32 = 56

///|
pub let sei_type_mastering_display_colour_volume : Int32 = 137

///|
pub let sei_type_content_light_level_info : Int32 = 144

///|
pub let sei_type_alternative_transfer_characteristics : Int32 = 147

///|
pub let sei_type_ambient_viewing_environment : Int32 = 148

///|
/// `sei_num_clock_ts_table[h264_sei.c]`. */
let sei_num_clock_ts_table : Array[Int32] = [1, 1, 1, 2, 2, 3, 3, 2, 3]

///|
/// `H264SEITimeCode`. */
pub struct SeiTimeCode {
  mut full : Int32
  mut frame : Int32
  mut seconds : Int32
  mut minutes : Int32
  mut hours : Int32
  mut dropframe : Int32
}

///|
fn new_sei_time_code() -> SeiTimeCode {
  { full: 0, frame: 0, seconds: 0, minutes: 0, hours: 0, dropframe: 0, }
}

///|
/// `H264_SEI_PicStructType` from `h264_sei.h`. */
pub let h264_sei_pic_struct_frame : Int32 = 0

///|
pub let h264_sei_pic_struct_frame_doubling : Int32 = 7

///|
pub let h264_sei_pic_struct_frame_tripling : Int32 = 8

///|
/// `H264SEIPictureTiming`. `decode_picture_timing` only stashes the payload;
/// `ff_h264_sei_process_picture_timing` parses it against an SPS. */
pub struct SeiPictureTiming {
  mut payload : Bytes?
  mut payload_size_bytes : Int32
  mut present : Int32
  mut pic_struct : Int32
  mut ct_type : Int32
  mut dpb_output_delay : Int32
  mut cpb_removal_delay : Int32
  timecode : Array[SeiTimeCode]
  mut timecode_cnt : Int32
}

///|
/// `H264SEIRecoveryPoint`. */
pub struct SeiRecoveryPoint {
  mut recovery_frame_cnt : Int32
}

///|
/// `H264SEIBufferingPeriod`. */
pub struct SeiBufferingPeriod {
  mut present : Int32
  initial_cpb_removal_delay : Array[Int32]
}

///|
/// `H264SEIGreenMetaData`. */
pub struct SeiGreenMetaData {
  mut green_metadata_type : Int32
  mut period_type : Int32
  mut num_seconds : Int32
  mut num_pictures : Int32
  mut percent_non_zero_macroblocks : Int32
  mut percent_intra_coded_macroblocks : Int32
  mut percent_six_tap_filtering : Int32
  mut percent_alpha_point_deblocking_instance : Int32
  mut xsd_metric_type : Int32
  mut xsd_metric_value : Int32
}

///|
/// `H2645SEIUnregistered`. `x264_build` is 0 while unknown. */
pub struct SeiUnregistered {
  buf_ref : Array[Bytes]
  mut nb_buf_ref : Int32
  mut x264_build : Int32
}

///|
/// `H2645SEIDisplayOrientation`. */
pub struct SeiDisplayOrientation {
  mut present : Int32
  mut anticlockwise_rotation : Int32
  mut hflip : Int32
  mut vflip : Int32
}

///|
/// `H2645SEIFramePacking`. `arrangement_cancel_flag` is -1 before the first
/// message is received (H.264 only; kept in sync with the C field). */
pub struct SeiFramePacking {
  mut present : Int32
  mut arrangement_id : Int32
  mut arrangement_cancel_flag : Int32
  mut arrangement_type : Int32
  mut arrangement_repetition_period : Int32
  mut content_interpretation_type : Int32
  mut quincunx_sampling_flag : Int32
  mut current_frame_is_frame0_flag : Int32
}

///|
/// `H2645SEIAlternativeTransfer`. */
pub struct SeiAlternativeTransfer {
  mut present : Int32
  mut preferred_transfer_characteristics : Int32
}

///|
/// `H2645SEIAmbientViewingEnvironment`. */
pub struct SeiAmbientViewingEnvironment {
  mut present : Int32
  mut ambient_illuminance : UInt32
  mut ambient_light_x : Int32
  mut ambient_light_y : Int32
}

///|
/// `H2645SEIFilmGrainCharacteristics`. `comp_model_value` keeps the C's
/// int16_t truncation on store. */
pub struct SeiFilmGrainCharacteristics {
  mut present : Int32
  mut model_id : Int32
  mut separate_colour_description_present_flag : Int32
  mut bit_depth_luma : Int32
  mut bit_depth_chroma : Int32
  mut full_range : Int32
  mut color_primaries : Int32
  mut transfer_characteristics : Int32
  mut matrix_coeffs : Int32
  mut blending_mode_id : Int32
  mut log2_scale_factor : Int32
  comp_model_present_flag : Array[Int32]
  num_intensity_intervals : Array[Int32]
  num_model_values : Array[Int32]
  intensity_interval_lower_bound : Array[Array[Int32]]
  intensity_interval_upper_bound : Array[Array[Int32]]
  comp_model_value : Array[Array[Array[Int32]]]
  mut repetition_period : Int32
  mut persistence_flag : Int32
}

///|
fn new_sei_film_grain_characteristics() -> SeiFilmGrainCharacteristics {
  let comp_present : Array[Int32] = Array::make(3, 0)
  let num_ii : Array[Int32] = Array::make(3, 0)
  let num_mv : Array[Int32] = Array::make(3, 0)
  let lower : Array[Array[Int32]] = []
  let upper : Array[Array[Int32]] = []
  let values : Array[Array[Array[Int32]]] = []
  for _c = 0; _c < 3; _c = _c + 1 {
    lower.push(Array::make(256, 0))
    upper.push(Array::make(256, 0))
    let per_c : Array[Array[Int32]] = []
    for _i = 0; _i < 256; _i = _i + 1 {
      per_c.push(Array::make(6, 0))
    }
    values.push(per_c)
  }
  {
    present: 0,
    model_id: 0,
    separate_colour_description_present_flag: 0,
    bit_depth_luma: 0,
    bit_depth_chroma: 0,
    full_range: 0,
    color_primaries: 0,
    transfer_characteristics: 0,
    matrix_coeffs: 0,
    blending_mode_id: 0,
    log2_scale_factor: 0,
    comp_model_present_flag: comp_present,
    num_intensity_intervals: num_ii,
    num_model_values: num_mv,
    intensity_interval_lower_bound: lower,
    intensity_interval_upper_bound: upper,
    comp_model_value: values,
    repetition_period: 0,
    persistence_flag: 0,
  }
}

///|
/// `H2645SEIMasteringDisplay`. `present` uses the C's 2 = decoded-and-
/// persisting semantics (decremented on IRAP by the decoder, not here). */
pub struct SeiMasteringDisplay {
  mut present : Int32
  display_primaries : Array[Array[Int32]]
  white_point : Array[Int32]
  mut max_luminance : UInt32
  mut min_luminance : UInt32
}

///|
/// `H2645SEIContentLight`. Same `present = 2` semantics as mastering display. */
pub struct SeiContentLight {
  mut present : Int32
  mut max_content_light_level : Int32
  mut max_pic_average_light_level : Int32
}

///|
/// `H264SEIContext`: the H.264-specific messages plus the common
/// `H2645SEI` set (including the ITU-T T.35 slot, `itut35.mbt`). */
pub struct H264SeiContext {
  unregistered : SeiUnregistered
  frame_packing : SeiFramePacking
  display_orientation : SeiDisplayOrientation
  alternative_transfer : SeiAlternativeTransfer
  ambient_viewing_environment : SeiAmbientViewingEnvironment
  mastering_display : SeiMasteringDisplay
  content_light : SeiContentLight
  mut film_grain_characteristics : SeiFilmGrainCharacteristics?
  picture_timing : SeiPictureTiming
  recovery_point : SeiRecoveryPoint
  buffering_period : SeiBufferingPeriod
  green_metadata : SeiGreenMetaData
  itut_t35 : ItutT35Meta
}

///|
/// New context with the C's zero init followed by `ff_h264_sei_uninit`
/// (recovery_frame_cnt = -1, cpb_removal_delay = -1). */
pub fn new_h264_sei_context() -> H264SeiContext {
  let ctx = {
    unregistered: { buf_ref: [], nb_buf_ref: 0, x264_build: 0, },
    frame_packing: {
      present: 0,
      arrangement_id: 0,
      arrangement_cancel_flag: 0,
      arrangement_type: 0,
      arrangement_repetition_period: 0,
      content_interpretation_type: 0,
      quincunx_sampling_flag: 0,
      current_frame_is_frame0_flag: 0,
    },
    display_orientation: {
      present: 0,
      anticlockwise_rotation: 0,
      hflip: 0,
      vflip: 0,
    },
    alternative_transfer: { present: 0, preferred_transfer_characteristics: 0, },
    ambient_viewing_environment: {
      present: 0,
      ambient_illuminance: 0U,
      ambient_light_x: 0,
      ambient_light_y: 0,
    },
    mastering_display: {
      present: 0,
      display_primaries: [[0, 0], [0, 0], [0, 0]],
      white_point: [0, 0],
      max_luminance: 0U,
      min_luminance: 0U,
    },
    content_light: {
      present: 0,
      max_content_light_level: 0,
      max_pic_average_light_level: 0,
    },
    film_grain_characteristics: None,
    picture_timing: {
      payload: None,
      payload_size_bytes: 0,
      present: 0,
      pic_struct: 0,
      ct_type: 0,
      dpb_output_delay: 0,
      cpb_removal_delay: 0,
      timecode: [new_sei_time_code(), new_sei_time_code(), new_sei_time_code()],
      timecode_cnt: 0,
    },
    recovery_point: { recovery_frame_cnt: 0, },
    buffering_period: {
      present: 0,
      initial_cpb_removal_delay: Array::make(32, 0),
    },
    green_metadata: {
      green_metadata_type: 0,
      period_type: 0,
      num_seconds: 0,
      num_pictures: 0,
      percent_non_zero_macroblocks: 0,
      percent_intra_coded_macroblocks: 0,
      percent_six_tap_filtering: 0,
      percent_alpha_point_deblocking_instance: 0,
      xsd_metric_type: 0,
      xsd_metric_value: 0,
    },
    itut_t35: new_itut_t35_meta(),
  }
  ctx.sei_uninit()
  ctx
}

///|
/// `ff_h264_sei_uninit` (including `ff_h2645_sei_reset`'s T.35 unref):
/// reset at the beginning of a frame. */
pub fn H264SeiContext::sei_uninit(self : H264SeiContext) -> Unit {
  self.recovery_point.recovery_frame_cnt = -1
  self.picture_timing.dpb_output_delay = 0
  self.picture_timing.cpb_removal_delay = -1
  self.picture_timing.present = 0
  self.buffering_period.present = 0
  self.frame_packing.present = 0
  self.display_orientation.present = 0
  self.unregistered.buf_ref.clear()
  self.unregistered.nb_buf_ref = 0
  self.unregistered.x264_build = 0
  self.ambient_viewing_environment.present = 0
  self.mastering_display.present = 0
  self.content_light.present = 0
  self.film_grain_characteristics = None
  itut_t35_unref(self.itut_t35)
}

///|
/// Byte cursor standing in for `GetByteContext` over a SEI payload
/// (everything here is byte-aligned until a bit-level message starts). */
priv struct SeiByteCursor {
  data : Bytes
  mut pos : Int32
}

///|
fn sei_cur_new(data : Bytes) -> SeiByteCursor {
  { data, pos: 0, }
}

///|
fn SeiByteCursor::left(self : SeiByteCursor) -> Int32 {
  self.data.length() - self.pos
}

///|
/// `bytestream2_skipu`. */
fn SeiByteCursor::skip(self : SeiByteCursor, n : Int32) -> Unit {
  self.pos = (self.pos + n).min(self.data.length())
}

///|
fn SeiByteCursor::peek(self : SeiByteCursor) -> Int32 {
  if self.pos >= self.data.length() {
    return 0
  }
  self.data[self.pos].to_int()
}

///|
fn SeiByteCursor::get(self : SeiByteCursor) -> Int32 {
  if self.pos >= self.data.length() {
    return 0
  }
  let b = self.data[self.pos].to_int()
  self.pos = self.pos + 1
  b
}

///|
/// Little-endian 16-bit peek, `bytestream2_peek_ne16`. */
fn SeiByteCursor::peek_le16(self : SeiByteCursor) -> Int32 {
  if self.pos + 1 >= self.data.length() {
    return 0
  }
  self.data[self.pos].to_int() | (self.data[self.pos + 1].to_int() << 8)
}

///|
/// Big-endian `bytestream2_get_be16u`. */
fn SeiByteCursor::get_be16(self : SeiByteCursor) -> Int32 {
  if self.pos + 1 >= self.data.length() {
    self.pos = self.data.length()
    return 0
  }
  let v = (self.data[self.pos].to_int() << 8) | self.data[self.pos + 1].to_int()
  self.pos = self.pos + 2
  v
}

///|
/// Big-endian `bytestream2_get_be32u`. */
fn SeiByteCursor::get_be32(self : SeiByteCursor) -> UInt32 {
  let mut v : UInt32 = 0
  for _i = 0; _i < 4; _i = _i + 1 {
    v = (v << 8) | self.get().reinterpret_as_uint()
  }
  v
}

///|
/// Payload byte slice, `bytestream2_get_bufferu`. */
fn SeiByteCursor::get_buffer(self : SeiByteCursor, size : Int32) -> Bytes {
  let b = self.data.clamped_view(start=self.pos, end=self.pos + size).to_owned()
  self.pos = self.pos + size
  b
}

///|
/// `decode_picture_timing` (h264_sei.c): stash the payload for
/// `ff_h264_sei_process_picture_timing`. */
fn decode_picture_timing(
  h : SeiPictureTiming,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  let size = cur.left()
  if size > 40 {
    return Err("EINVAL")
  }
  h.payload = Some(cur.get_buffer(size))
  h.payload_size_bytes = size
  h.present = 1
  Ok(0)
}

///|
/// `ff_h264_sei_process_picture_timing`: parse the stashed payload against
/// an SPS (H.264 C.1.2 / C.2.2 / D.1.2). */
pub fn H264SeiContext::sei_process_picture_timing(
  self : H264SeiContext,
  sps : H264Sps,
) -> Result[Int32, String] {
  let h = self.picture_timing
  let payload = match h.payload {
    Some(p) => p
    None => return Err("EINVAL")
  }
  let gb = BitReader::new(payload)
  if sps.nal_hrd_parameters_present_flag != 0 ||
    sps.vcl_hrd_parameters_present_flag != 0 {
    h.cpb_removal_delay = gb
      .read(sps.cpb_removal_delay_length)
      .reinterpret_as_int()
    h.dpb_output_delay = gb
      .read(sps.dpb_output_delay_length)
      .reinterpret_as_int()
  }
  if sps.pic_struct_present_flag != 0 {
    h.pic_struct = gb.read(4).reinterpret_as_int()
    h.ct_type = 0
    if h.pic_struct > h264_sei_pic_struct_frame_tripling {
      return Err("EINVAL")
    }
    let num_clock_ts = sei_num_clock_ts_table[h.pic_struct]
    h.timecode_cnt = 0
    for _i = 0; _i < num_clock_ts; _i = _i + 1 {
      if gb.read1().reinterpret_as_int() != 0 {
        let tc = h.timecode[h.timecode_cnt]
        h.timecode_cnt = h.timecode_cnt + 1
        h.ct_type = h.ct_type | (1 << gb.read(2).reinterpret_as_int())
        // nuit_field_based_flag
        gb.skip(1)
        let counting_type = gb.read(5).reinterpret_as_int()
        let full_timestamp_flag = gb.read1().reinterpret_as_int()
        // discontinuity_flag
        gb.skip(1)
        let cnt_dropped_flag = gb.read1().reinterpret_as_int()
        if cnt_dropped_flag != 0 && counting_type > 1 && counting_type < 7 {
          tc.dropframe = 1
        }
        tc.frame = gb.read(8).reinterpret_as_int()
        if full_timestamp_flag != 0 {
          tc.full = 1
          tc.seconds = gb.read(6).reinterpret_as_int()
          tc.minutes = gb.read(6).reinterpret_as_int()
          tc.hours = gb.read(5).reinterpret_as_int()
        } else {
          tc.seconds = 0
          tc.minutes = 0
          tc.hours = 0
          tc.full = 0
          if gb.read1().reinterpret_as_int() != 0 {
            tc.seconds = gb.read(6).reinterpret_as_int()
            if gb.read1().reinterpret_as_int() != 0 {
              tc.minutes = gb.read(6).reinterpret_as_int()
              if gb.read1().reinterpret_as_int() != 0 {
                tc.hours = gb.read(5).reinterpret_as_int()
              }
            }
          }
        }
        if sps.time_offset_length > 0 {
          gb.skip(sps.time_offset_length)
        }
      }
    }
  }
  Ok(0)
}

///|
/// `decode_recovery_point`. */
fn decode_recovery_point(
  h : SeiRecoveryPoint,
  gb : BitReader,
) -> Result[Int32, String] {
  let recovery_frame_cnt = gb.read_ue_long()
  if recovery_frame_cnt >= 1UL << max_log2_max_frame_num {
    return Err("EINVAL")
  }
  h.recovery_frame_cnt = recovery_frame_cnt.to_int()
  // exact_match_flag, broken_link_flag, changing_slice_group_idc[2]
  gb.skip(4)
  Ok(0)
}

///|
/// `decode_buffering_period`. `Err("EPSNOTFOUND")` carries the C's
/// AVERROR_PS_NOT_FOUND (non-fatal for the message loop). */
fn decode_buffering_period(
  h : SeiBufferingPeriod,
  gb : BitReader,
  ps : H264ParamSets,
) -> Result[Int32, String] {
  let sps_id = gb.read_ue31()
  if sps_id > 31 || ps.sps_list[sps_id] is None {
    if sps_id > 31 {
      return Err("EINVAL")
    }
    return Err("EPSNOTFOUND")
  }
  let sps = match ps.sps_list[sps_id] {
    Some(s) => s
    None => return Err("EPSNOTFOUND")
  }
  // NOTE: this is really so duplicated in the standard... See H.264, D.1.1
  if sps.nal_hrd_parameters_present_flag != 0 {
    for sched_sel_idx = 0
        sched_sel_idx < sps.cpb_cnt
        sched_sel_idx = sched_sel_idx + 1 {
      h.initial_cpb_removal_delay[sched_sel_idx] = gb
        .read(sps.initial_cpb_removal_delay_length)
        .reinterpret_as_int()
      // initial_cpb_removal_delay_offset
      gb.skip(sps.initial_cpb_removal_delay_length)
    }
  }
  if sps.vcl_hrd_parameters_present_flag != 0 {
    for sched_sel_idx = 0
        sched_sel_idx < sps.cpb_cnt
        sched_sel_idx = sched_sel_idx + 1 {
      h.initial_cpb_removal_delay[sched_sel_idx] = gb
        .read(sps.initial_cpb_removal_delay_length)
        .reinterpret_as_int()
      // initial_cpb_removal_delay_offset
      gb.skip(sps.initial_cpb_removal_delay_length)
    }
  }
  h.present = 1
  Ok(0)
}

///|
/// `decode_green_metadata`. */
fn decode_green_metadata(
  h : SeiGreenMetaData,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  h.green_metadata_type = cur.get()
  if h.green_metadata_type == 0 {
    h.period_type = cur.get()
    if h.period_type == 2 {
      h.num_seconds = cur.get_be16()
    } else if h.period_type == 3 {
      h.num_pictures = cur.get_be16()
    }
    h.percent_non_zero_macroblocks = cur.get()
    h.percent_intra_coded_macroblocks = cur.get()
    h.percent_six_tap_filtering = cur.get()
    h.percent_alpha_point_deblocking_instance = cur.get()
  } else if h.green_metadata_type == 1 {
    h.xsd_metric_type = cur.get()
    h.xsd_metric_value = cur.get_be16()
  }
  Ok(0)
}

///|
/// `decode_unregistered_user_data` (h2645_sei.c). Stores the payload bytes
/// and sniffs the x264 build string. */
fn decode_unregistered_user_data(
  h : SeiUnregistered,
  cur : SeiByteCursor,
  is_h264 : Bool,
) -> Result[Int32, String] {
  let size = cur.left()
  if size < 16 {
    return Err("EINVAL")
  }
  let user_data = cur.get_buffer(size)
  h.buf_ref.push(user_data)
  h.nb_buf_ref = h.nb_buf_ref + 1
  if is_h264 {
    // sscanf(user_data + 16, "x264 - core %d", &build)
    let mut build = 0
    let mut matched = false
    let prefix_ok = size >= 16 + 12 &&
      user_data[16].to_int() == 'x'.to_int() &&
      user_data[17].to_int() == '2'.to_int() &&
      user_data[18].to_int() == '6'.to_int() &&
      user_data[19].to_int() == '4'.to_int() &&
      user_data[20].to_int() == ' '.to_int() &&
      user_data[21].to_int() == '-'.to_int() &&
      user_data[22].to_int() == ' '.to_int() &&
      user_data[23].to_int() == 'c'.to_int() &&
      user_data[24].to_int() == 'o'.to_int() &&
      user_data[25].to_int() == 'r'.to_int() &&
      user_data[26].to_int() == 'e'.to_int() &&
      user_data[27].to_int() == ' '.to_int()
    if prefix_ok {
      // sscanf("%d") skips leading whitespace, then an optional sign
      let mut i = 28
      while i < size &&
            (
              user_data[i].to_int() == ' '.to_int() ||
              user_data[i].to_int() == '\t'.to_int()
            ) {
        i = i + 1
      }
      let mut neg = false
      if i < size &&
        (
          user_data[i].to_int() == '+'.to_int() ||
          user_data[i].to_int() == '-'.to_int()
        ) {
        neg = user_data[i].to_int() == '-'.to_int()
        i = i + 1
      }
      let start = i
      let mut v = 0
      while i < size &&
            user_data[i].to_int() >= '0'.to_int() &&
            user_data[i].to_int() <= '9'.to_int() {
        v = v * 10 + (user_data[i].to_int() - '0'.to_int())
        i = i + 1
      }
      if i > start {
        build = if neg { -v } else { v }
        matched = true
      }
    }
    if matched && build > 0 {
      h.x264_build = build
    }
    if matched &&
      build == 1 &&
      size >= 32 &&
      user_data[28].to_int() == '0'.to_int() &&
      user_data[29].to_int() == '0'.to_int() &&
      user_data[30].to_int() == '0'.to_int() &&
      user_data[31].to_int() == '0'.to_int() {
      h.x264_build = 67
    }
  }
  Ok(0)
}

///|
/// `decode_display_orientation`. */
fn decode_display_orientation(
  h : SeiDisplayOrientation,
  gb : BitReader,
) -> Result[Int32, String] {
  // display_orientation_cancel_flag
  h.present = if gb.read1().reinterpret_as_int() == 0 { 1 } else { 0 }
  if h.present != 0 {
    h.hflip = gb.read1().reinterpret_as_int()
    h.vflip = gb.read1().reinterpret_as_int()
    h.anticlockwise_rotation = gb.read(16).reinterpret_as_int()
    // H.264: repetition period + extension flag; HEVC: persistence flag
  }
  Ok(0)
}

///|
/// `decode_frame_packing_arrangement`. */
fn decode_frame_packing_arrangement(
  h : SeiFramePacking,
  gb : BitReader,
  is_h264 : Bool,
) -> Result[Int32, String] {
  h.arrangement_id = gb.read_ue_long().to_int()
  h.arrangement_cancel_flag = gb.read1().reinterpret_as_int()
  h.present = if h.arrangement_cancel_flag == 0 { 1 } else { 0 }
  if h.present != 0 {
    h.arrangement_type = gb.read(7).reinterpret_as_int()
    h.quincunx_sampling_flag = gb.read1().reinterpret_as_int()
    h.content_interpretation_type = gb.read(6).reinterpret_as_int()
    // spatial_flipping_flag, frame0_flipped_flag, field_views_flag
    gb.skip(3)
    h.current_frame_is_frame0_flag = gb.read1().reinterpret_as_int()
    // frame0_self_contained_flag, frame1_self_contained_flag
    gb.skip(2)
    if h.quincunx_sampling_flag == 0 && h.arrangement_type != 5 {
      gb.skip(16) // frame[01]_grid_position_[xy]
    }
    gb.skip(8) // frame_packing_arrangement_reserved_byte
    if is_h264 {
      h.arrangement_repetition_period = gb.read_ue_long().to_int()
    } else {
      gb.skip(1) // frame_packing_arrangement_persistence_flag
    }
  }
  // H.264: frame_packing_arrangement_extension_flag;
  // HEVC: upsampled_aspect_ratio_flag
  gb.skip(1)
  Ok(0)
}

///|
/// `decode_alternative_transfer`. */
fn decode_alternative_transfer(
  h : SeiAlternativeTransfer,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  if cur.left() < 1 {
    return Err("EINVAL")
  }
  h.present = 1
  h.preferred_transfer_characteristics = cur.get()
  Ok(0)
}

///|
/// `decode_ambient_viewing_environment`. */
fn decode_ambient_viewing_environment(
  h : SeiAmbientViewingEnvironment,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  let max_ambient_light_value = 50000
  if cur.left() < 8 {
    return Err("EINVAL")
  }
  h.ambient_illuminance = cur.get_be32()
  if h.ambient_illuminance == 0U {
    return Err("EINVAL")
  }
  h.ambient_light_x = cur.get_be16()
  if h.ambient_light_x > max_ambient_light_value {
    return Err("EINVAL")
  }
  h.ambient_light_y = cur.get_be16()
  if h.ambient_light_y > max_ambient_light_value {
    return Err("EINVAL")
  }
  h.present = 1
  Ok(0)
}

///|
/// int16_t truncation used when storing `comp_model_value`. */
fn trunc_i16(v : Int32) -> Int32 {
  let mut x = v & 0xFFFF
  if x >= 0x8000 {
    x = x - 0x10000
  }
  x
}

///|
/// `decode_film_grain_characteristics`. */
fn decode_film_grain_characteristics(
  h : SeiFilmGrainCharacteristics,
  gb : BitReader,
  is_h264 : Bool,
) -> Result[Int32, String] {
  // cancel flag
  h.present = if gb.read1().reinterpret_as_int() == 0 { 1 } else { 0 }
  if h.present != 0 {
    // C: memset(h, 0, sizeof(*h)) on the freshly allocated struct
    h.model_id = 0
    h.separate_colour_description_present_flag = 0
    h.bit_depth_luma = 0
    h.bit_depth_chroma = 0
    h.full_range = 0
    h.color_primaries = 0
    h.transfer_characteristics = 0
    h.matrix_coeffs = 0
    h.blending_mode_id = 0
    h.log2_scale_factor = 0
    for c = 0; c < 3; c = c + 1 {
      h.comp_model_present_flag[c] = 0
      h.num_intensity_intervals[c] = 0
      h.num_model_values[c] = 0
      for i = 0; i < 256; i = i + 1 {
        h.intensity_interval_lower_bound[c][i] = 0
        h.intensity_interval_upper_bound[c][i] = 0
        for j = 0; j < 6; j = j + 1 {
          h.comp_model_value[c][i][j] = 0
        }
      }
    }
    h.repetition_period = 0
    h.persistence_flag = 0

    h.model_id = gb.read(2).reinterpret_as_int()
    h.separate_colour_description_present_flag = gb.read1().reinterpret_as_int()
    if h.separate_colour_description_present_flag != 0 {
      h.bit_depth_luma = gb.read(3).reinterpret_as_int() + 8
      h.bit_depth_chroma = gb.read(3).reinterpret_as_int() + 8
      h.full_range = gb.read1().reinterpret_as_int()
      h.color_primaries = gb.read(8).reinterpret_as_int()
      h.transfer_characteristics = gb.read(8).reinterpret_as_int()
      h.matrix_coeffs = gb.read(8).reinterpret_as_int()
    }
    h.blending_mode_id = gb.read(2).reinterpret_as_int()
    h.log2_scale_factor = gb.read(4).reinterpret_as_int()
    for c = 0; c < 3; c = c + 1 {
      h.comp_model_present_flag[c] = gb.read1().reinterpret_as_int()
    }
    for c = 0; c < 3; c = c + 1 {
      if h.comp_model_present_flag[c] != 0 {
        h.num_intensity_intervals[c] = gb.read(8).reinterpret_as_int() + 1
        h.num_model_values[c] = gb.read(3).reinterpret_as_int() + 1
        if h.num_model_values[c] > 6 {
          return Err("EINVAL")
        }
        for i = 0; i < h.num_intensity_intervals[c]; i = i + 1 {
          h.intensity_interval_lower_bound[c][i] = gb
            .read(8)
            .reinterpret_as_int()
          h.intensity_interval_upper_bound[c][i] = gb
            .read(8)
            .reinterpret_as_int()
          for j = 0; j < h.num_model_values[c]; j = j + 1 {
            h.comp_model_value[c][i][j] = trunc_i16(gb.read_se_long())
          }
        }
      }
    }
    if !is_h264 {
      h.persistence_flag = gb.read1().reinterpret_as_int()
    } else {
      h.repetition_period = gb.read_ue_long().to_int()
    }
    h.present = 1
  }
  Ok(0)
}

///|
/// `decode_nal_sei_mastering_display_info`. */
fn decode_mastering_display_info(
  h : SeiMasteringDisplay,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  if cur.left() < 24 {
    return Err("EINVAL")
  }
  // Mastering primaries
  for i = 0; i < 3; i = i + 1 {
    h.display_primaries[i][0] = cur.get_be16()
    h.display_primaries[i][1] = cur.get_be16()
  }
  // White point (x, y)
  h.white_point[0] = cur.get_be16()
  h.white_point[1] = cur.get_be16()
  // Max and min luminance of mastering display
  h.max_luminance = cur.get_be32()
  h.min_luminance = cur.get_be32()
  // C initializes present to 2 so the value persists across the coded
  // video sequence; the IRAP decrement happens in the decoder layer.
  h.present = 2
  Ok(0)
}

///|
/// `decode_nal_sei_content_light_info`. */
fn decode_content_light_info(
  h : SeiContentLight,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  if cur.left() < 4 {
    return Err("EINVAL")
  }
  h.max_content_light_level = cur.get_be16()
  h.max_pic_average_light_level = cur.get_be16()
  h.present = 2
  Ok(0)
}

///|
/// `decode_registered_user_data` (`h2645_sei.c`): hand the payload bytes to
/// the T.35 parser and store the recognized provider payload in the
/// context's `itut_t35` slot. `Ok(0)` = unsupported combination, ignored. */
fn decode_registered_user_data(
  h : H264SeiContext,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  let itut_t35 : ItutT35 = {
    country_code: 0,
    provider_code: 0,
    provider_oriented_code: 0,
    payload: b"",
  }
  let ret = itut_t35_parse_buffer(itut_t35, cur.get_buffer(cur.left()))
  match ret {
    Ok(v) => if v <= 0 {
      return Ok(0)
    }
    Err(e) => return Err(e)
  }
  itut_t35_parse_payload(h.itut_t35, itut_t35)
}

///|
/// `ff_h2645_sei_message_decode` (h2645_sei.c) for the common message set.
/// Returns `Err("EUNHANDLED")` for types outside the common set. */
fn h2645_sei_message_decode(
  h : H264SeiContext,
  type_ : Int32,
  is_h264 : Bool,
  gb : BitReader,
  cur : SeiByteCursor,
) -> Result[Int32, String] {
  match type_ {
    t if t == sei_type_user_data_registered_itu_t_t35 =>
      decode_registered_user_data(h, cur)
    t if t == sei_type_user_data_unregistered =>
      decode_unregistered_user_data(h.unregistered, cur, is_h264)
    t if t == sei_type_display_orientation =>
      decode_display_orientation(h.display_orientation, gb)
    t if t == sei_type_film_grain_characteristics => {
      let fgc = new_sei_film_grain_characteristics()
      h.film_grain_characteristics = Some(fgc)
      decode_film_grain_characteristics(fgc, gb, is_h264)
    }
    t if t == sei_type_frame_packing_arrangement =>
      decode_frame_packing_arrangement(h.frame_packing, gb, is_h264)
    t if t == sei_type_alternative_transfer_characteristics =>
      decode_alternative_transfer(h.alternative_transfer, cur)
    t if t == sei_type_ambient_viewing_environment =>
      decode_ambient_viewing_environment(h.ambient_viewing_environment, cur)
    t if t == sei_type_mastering_display_colour_volume =>
      decode_mastering_display_info(h.mastering_display, cur)
    t if t == sei_type_content_light_level_info =>
      decode_content_light_info(h.content_light, cur)
    _ => Err("EUNHANDLED")
  }
}

///|
/// `ff_h264_sei_decode` (h264_sei.c): parse every SEI message in a NAL
/// payload. `payload` is the RBSP payload after the NAL header, byte
/// aligned (the caller consumes the 1-byte NAL header of a type-6 NAL
/// exactly like `h264dec.c` does before calling in).
///
/// Returns `Ok(0)`, `Ok(-1)` when a buffering-period SPS was missing
/// (master_ret < 0 but the loop continued, like the C), or
/// `Err("EINVAL")` on a fatal error. */
pub fn H264SeiContext::h264_sei_decode(
  self : H264SeiContext,
  payload : Bytes,
  ps : H264ParamSets,
) -> Result[Int32, String] {
  let is_h264 = true
  let mut master_ret = 0
  let gbyte = sei_cur_new(payload)
  while gbyte.left() > 2 && gbyte.peek_le16() != 0 {
    let mut type_ = 0
    let mut size = 0
    // type: `type += peek_byte` while the consumed byte is 255
    while true {
      if gbyte.left() <= 0 {
        return Err("EINVAL")
      }
      type_ = type_ + gbyte.peek()
      if gbyte.get() != 255 {
        break
      }
    }
    while true {
      if gbyte.left() <= 0 {
        return Err("EINVAL")
      }
      size = size + gbyte.peek()
      if gbyte.get() != 255 {
        break
      }
    }
    if size > gbyte.left() {
      return Err("EINVAL")
    }
    let payload_bytes = gbyte.get_buffer(size)
    let gbyte_payload = sei_cur_new(payload_bytes)
    let gb_payload = BitReader::new(payload_bytes)
    let ret : Result[Int32, String] = match type_ {
      t if t == sei_type_pic_timing =>
        decode_picture_timing(self.picture_timing, gbyte_payload)
      t if t == sei_type_recovery_point =>
        decode_recovery_point(self.recovery_point, gb_payload)
      t if t == sei_type_buffering_period =>
        decode_buffering_period(self.buffering_period, gb_payload, ps)
      t if t == sei_type_green_metadata =>
        decode_green_metadata(self.green_metadata, gbyte_payload)
      _ =>
        match
          h2645_sei_message_decode(
            self, type_, is_h264, gb_payload, gbyte_payload,
          ) {
          Ok(v) => Ok(v)
          Err("EUNHANDLED") => Ok(0)
          Err(e) => Err(e)
        }
    }
    match ret {
      Ok(v) => {
        let _ = v
      }
      Err("EPSNOTFOUND") => master_ret = -1
      Err(e) => return Err(e)
    }
  }
  Ok(master_ret)
}
