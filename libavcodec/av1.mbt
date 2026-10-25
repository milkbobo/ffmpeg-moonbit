///|
/// MoonBit port of the FFmpeg 9.0.2 AV1 header layer:
/// `libavcodec/av1_parse.h` (`parse_obu_header`, `get_obu_bit_length`),
/// `libavformat/av1.c` (`parse_sequence_header`, `parse_color_config`,
/// `ff_av1_parse_seq_header`) and the `av1C` configuration-record path.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: OBU framing (LEB128 size), sequence-header fields (profile, level,
/// tier, bit depth, monochrome/chroma, colour description, max frame size) from
/// either an `av1C` record or an OBU stream. Frame header / tile decoding and
/// the AV1 pixel pipeline are out of scope.

///|
pub struct Av1SequenceParameters {
  mut profile : Int32
  /// `seq_level_idx[0]`.
  mut level : Int32
  mut tier : Int32
  mut bitdepth : Int32
  mut monochrome : Bool
  mut chroma_subsampling_x : Bool
  mut chroma_subsampling_y : Bool
  mut chroma_sample_position : Int32
  mut color_description_present_flag : Bool
  mut color_primaries : Int32
  mut transfer_characteristics : Int32
  mut matrix_coefficients : Int32
  mut color_range : Int32
  /// `max_frame_width_minus_1 + 1` (0 for `av1C` records).
  mut width : Int32
  mut height : Int32
  mut reduced_still_picture_header : Bool
  mut frame_id_numbers_present : Bool
  mut delta_frame_id_length : Int32
  mut additional_frame_id_length : Int32
  mut enable_order_hint : Bool
  mut order_hint_bits : Int32
  /// 0 = off, 1 = on, 2 = choose per frame.
  mut seq_force_screen_content_tools : Int32
  mut seq_force_integer_mv : Int32
  mut enable_superres : Bool
  mut enable_cdef : Bool
  mut enable_restoration : Bool
  mut use_128x128_superblock : Bool
  mut separate_uv_delta_q : Bool
  mut film_grain_params_present : Bool
  /// `enable_filter_intra` (FILTER_PRED availability).
  mut enable_filter_intra : Bool
  /// `enable_intra_edge_filter` (intra edge filter/upsample availability).
  mut enable_intra_edge_filter : Bool
}

///|
fn av1_leb128(data : BytesView, pos : Ref[Int32]) -> Int32 {
  let mut value : UInt32 = 0
  let mut shift = 0
  for ;; {
    if pos.val >= data.length() || shift > 28 {
      return -1
    }
    let b = data[pos.val].to_int()
    pos.val = pos.val + 1
    if shift == 28 && (b & 0xf8) != 0 { return -1 }
    value = value | ((b & 0x7F).reinterpret_as_uint() << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  value.reinterpret_as_int()
}

///|
/// `ff_ctz` for a non-zero byte. */
fn av1_ctz8(v : Int32) -> Int32 {
  let mut n = 0
  while ((v >> n) & 1) == 0 {
    n = n + 1
  }
  n
}

///|
/// `get_obu_bit_length`: strip trailing zero bytes and trailing_one_bit. */
fn av1_obu_bit_length(data : BytesView, start : Int32, size : Int32) -> Int32 {
  let mut n = size
  while n > 0 && data[start + n - 1] == b'\x00' {
    n = n - 1
  }
  if n == 0 {
    return 0
  }
  let last = data[start + n - 1].to_int()
  let bits = n * 8
  if last != 0 {
    bits - av1_ctz8(last) - 1
  } else {
    bits
  }
}

///|
/// `parse_color_config` from libavformat/av1.c. */
fn av1_parse_color_config(seq : Av1SequenceParameters, br : BitReader) -> Unit {
  let high_bitdepth = br.read(1).reinterpret_as_int()
  let mut twelve_bit = 0
  if seq.profile == 2 && high_bitdepth != 0 {
    twelve_bit = br.read(1).reinterpret_as_int()
  }
  seq.bitdepth = 8 + high_bitdepth * 2 + twelve_bit * 2
  seq.monochrome = if seq.profile == 1 { false } else { br.read(1) != 0 }
  seq.color_description_present_flag = br.read(1) != 0
  if seq.color_description_present_flag {
    seq.color_primaries = br.read(8).reinterpret_as_int()
    seq.transfer_characteristics = br.read(8).reinterpret_as_int()
    seq.matrix_coefficients = br.read(8).reinterpret_as_int()
  } else {
    seq.color_primaries = 2 // AVCOL_PRI_UNSPECIFIED
    seq.transfer_characteristics = 2 // AVCOL_TRC_UNSPECIFIED
    seq.matrix_coefficients = 2 // AVCOL_SPC_UNSPECIFIED
  }
  if seq.monochrome {
    seq.color_range = br.read(1).reinterpret_as_int()
    seq.chroma_subsampling_x = true
    seq.chroma_subsampling_y = true
    seq.chroma_sample_position = 0
    return
  }
  if seq.color_primaries == 1 &&
    seq.transfer_characteristics == 13 &&
    seq.matrix_coefficients == 0 {
    // BT.709 / sRGB / identity: RGB.
    seq.chroma_subsampling_x = false
    seq.chroma_subsampling_y = false
  } else {
    seq.color_range = br.read(1).reinterpret_as_int()
    if seq.profile == 0 {
      seq.chroma_subsampling_x = true
      seq.chroma_subsampling_y = true
    } else if seq.profile == 1 {
      seq.chroma_subsampling_x = false
      seq.chroma_subsampling_y = false
    } else if twelve_bit != 0 {
      seq.chroma_subsampling_x = br.read(1) != 0
      seq.chroma_subsampling_y = if seq.chroma_subsampling_x {
        br.read(1) != 0
      } else {
        false
      }
    } else {
      seq.chroma_subsampling_x = true
      seq.chroma_subsampling_y = false
    }
    if seq.chroma_subsampling_x && seq.chroma_subsampling_y {
      seq.chroma_sample_position = br.read(2).reinterpret_as_int()
    }
  }
  seq.separate_uv_delta_q = br.read(1) != 0
}

///|
/// `uvlc`: skip a universal variable-length code (exp-Golomb). */
fn av1_skip_uvlc(br : BitReader) -> Unit {
  let mut leading_zeros = 0
  while leading_zeros < 32 {
    if br.bits_left() < 1 || br.read(1) != 0 {
      break
    }
    leading_zeros = leading_zeros + 1
  }
  if leading_zeros < 32 {
    br.skip(leading_zeros)
  }
}

///|
/// `parse_sequence_header` over an OBU payload. */
fn av1_parse_sequence_payload(
  seq : Av1SequenceParameters,
  data : Bytes,
  size : Int32,
) -> Result[Unit, String] {
  let bits = av1_obu_bit_length(data, 0, size)
  if bits <= 0 {
    return Err("av1: empty sequence header")
  }
  let br = BitReader::with_size(data, bits)
  seq.profile = br.read(3).reinterpret_as_int()
  ignore(br.read(1)) // still_picture
  let reduced = br.read(1) != 0
  seq.reduced_still_picture_header = reduced
  if reduced {
    seq.level = br.read(5).reinterpret_as_int()
    seq.tier = 0
  } else {
    let mut decoder_model_info_present = false
    let mut buffer_delay_length_minus_1 = 0
    if br.read(1) != 0 {
      // timing_info_present_flag
      br.skip(64) // num_units_in_display_tick + time_scale
      if br.read(1) != 0 {
        av1_skip_uvlc(br) // num_ticks_per_picture_minus_1
      }
      decoder_model_info_present = br.read(1) != 0
      if decoder_model_info_present {
        buffer_delay_length_minus_1 = br.read(5).reinterpret_as_int()
        br.skip(32 + 10 + 5) // num_units_in_decoding_tick, lengths
      }
    }
    let initial_display_delay_present = br.read(1) != 0
    let operating_points = br.read(5).reinterpret_as_int()
    for i in 0..<=operating_points {
      br.skip(12) // operating_point_idc
      let level = br.read(5).reinterpret_as_int()
      let tier = if level > 7 { br.read(1).reinterpret_as_int() } else { 0 }
      if decoder_model_info_present && br.read(1) != 0 {
        br.skip(buffer_delay_length_minus_1 + 1)
        br.skip(buffer_delay_length_minus_1 + 1)
        ignore(br.read(1))
      }
      if initial_display_delay_present && br.read(1) != 0 {
        br.skip(4)
      }
      if i == 0 {
        seq.level = level
        seq.tier = tier
      }
    }
  }
  let width_bits = br.read(4).reinterpret_as_int() + 1
  let height_bits = br.read(4).reinterpret_as_int() + 1
  seq.width = br.read(width_bits).reinterpret_as_int() + 1
  seq.height = br.read(height_bits).reinterpret_as_int() + 1
  if !reduced {
    seq.frame_id_numbers_present = br.read(1) != 0
    if seq.frame_id_numbers_present {
      seq.delta_frame_id_length = br.read(4).reinterpret_as_int() + 2
      seq.additional_frame_id_length = br.read(3).reinterpret_as_int() + 1
    }
  }
  seq.use_128x128_superblock = br.read(1) != 0
  seq.enable_filter_intra = br.read(1) != 0
  seq.enable_intra_edge_filter = br.read(1) != 0
  if !reduced {
    br.skip(4)
    seq.enable_order_hint = br.read(1) != 0
    if seq.enable_order_hint {
      br.skip(2)
    }
    let choose_sct = br.read(1) != 0
    if choose_sct {
      seq.seq_force_screen_content_tools = 2
    } else {
      seq.seq_force_screen_content_tools = br.read(1).reinterpret_as_int()
    }
    if seq.seq_force_screen_content_tools != 0 {
      let choose_mv = br.read(1) != 0
      if choose_mv {
        seq.seq_force_integer_mv = 2
      } else {
        seq.seq_force_integer_mv = br.read(1).reinterpret_as_int()
      }
    }
    if seq.enable_order_hint {
      seq.order_hint_bits = br.read(3).reinterpret_as_int() + 1
    }
  }
  seq.enable_superres = br.read(1) != 0
  seq.enable_cdef = br.read(1) != 0
  seq.enable_restoration = br.read(1) != 0
  av1_parse_color_config(seq, br)
  seq.film_grain_params_present = br.read(1) != 0
  Ok(())
}

///|
/// `ff_av1_parse_seq_header`: accept either an `av1C` record or OBUs.
pub fn av1_parse_sequence_header(
  data : Bytes,
) -> Result[Av1SequenceParameters, String] {
  let seq : Av1SequenceParameters = {
    profile: 0,
    level: 0,
    tier: 0,
    bitdepth: 8,
    monochrome: false,
    chroma_subsampling_x: true,
    chroma_subsampling_y: true,
    chroma_sample_position: 0,
    color_description_present_flag: false,
    color_primaries: 2,
    transfer_characteristics: 2,
    matrix_coefficients: 2,
    color_range: 0,
    width: 0,
    height: 0,
    reduced_still_picture_header: false,
    frame_id_numbers_present: false,
    delta_frame_id_length: 0,
    additional_frame_id_length: 0,
    enable_order_hint: false,
    order_hint_bits: 0,
    seq_force_screen_content_tools: 0,
    seq_force_integer_mv: 0,
    enable_superres: false,
    enable_cdef: false,
    enable_restoration: false,
    use_128x128_superblock: false,
    separate_uv_delta_q: false,
    film_grain_params_present: false,
    enable_filter_intra: false,
    enable_intra_edge_filter: false,
  }
  if data.length() == 0 {
    return Err("av1: empty input")
  }
  if (data[0].to_int() & 0x80) != 0 {
    // av1C record (AV1CodecConfigurationRecord).
    if (data[0].to_int() & 0x7F) != 1 || data.length() < 4 {
      return Err("av1: invalid av1C record")
    }
    let br = BitReader::with_size(data, 32)
    br.skip(8)
    seq.profile = br.read(3).reinterpret_as_int()
    seq.level = br.read(5).reinterpret_as_int()
    seq.tier = br.read(1).reinterpret_as_int()
    let high = br.read(1).reinterpret_as_int()
    let twelve = br.read(1).reinterpret_as_int()
    seq.bitdepth = 8 + high * 2 + twelve * 2
    seq.monochrome = br.read(1) != 0
    seq.chroma_subsampling_x = br.read(1) != 0
    seq.chroma_subsampling_y = br.read(1) != 0
    seq.chroma_sample_position = br.read(2).reinterpret_as_int()
    return Ok(seq)
  }
  let mut pos = 0
  while pos < data.length() {
    let header = data[pos].to_int()
    if (header & 0x80) != 0 {
      return Err("av1: OBU forbidden bit set")
    }
    let obu_type = (header >> 3) & 0x0F
    let extension = (header & 0x04) != 0
    let has_size = (header & 0x02) != 0
    let p_ref = Ref(pos + 1)
    if extension {
      p_ref.val = p_ref.val + 1
    }
    if !has_size {
      return Err("av1: OBU without size")
    }
    let size = av1_leb128(data, p_ref)
    let p = p_ref.val
    if size < 0 || p + size > data.length() {
      return Err("av1: bad OBU size")
    }
    if obu_type == 1 {
      match av1_parse_sequence_payload(seq, data[p:p + size].to_owned(), size) {
        Ok(_) => return Ok(seq)
        Err(e) => return Err(e)
      }
    }
    pos = p + size
  }
  Err("av1: no sequence header OBU")
}

///|
/// AV1 uncompressed frame header fields (key/intra frames). */
pub struct Av1FrameHeader {
  show_existing_frame : Bool
  frame_to_show_map_idx : Int32
  frame_type : Int32
  show_frame : Bool
  showable_frame : Bool
  error_resilient_mode : Bool
  disable_cdf_update : Bool
  allow_screen_content_tools : Bool
  force_integer_mv : Bool
  frame_size_override_flag : Bool
  order_hint : Int32
  primary_ref_frame : Int32
  refresh_frame_flags : Int32
  width : Int32
  height : Int32
  render_width : Int32
  render_height : Int32
  use_superres : Bool
  /// `frame_width` before superres upscaling; equals `width` when
  /// `use_superres` is false.
  upscaled_width : Int32
  allow_intrabc : Bool
  frame_refs_short_signaling : Bool
  ref_frame_idx : Array[Int32]
  disable_frame_end_update_cdf : Bool
  tile_cols : Int32
  tile_rows : Int32
  tile_cols_log2 : Int32
  tile_rows_log2 : Int32
  context_update_tile_id : Int32
  tile_size_bytes_minus1 : Int32
  header_bits : Int32
  base_q_idx : Int32
  /// Quantization deltas (0 when absent). V mirrors U unless
  /// separate_uv_delta_q signalled a diff.
  dq_y_dc : Int32
  dq_u_dc : Int32
  dq_u_ac : Int32
  dq_v_dc : Int32
  dq_v_ac : Int32
  using_qmatrix : Bool
  segmentation_enabled : Bool
  segmentation_feature_mask : Array[Int32]
  segmentation_alt_q : Array[Int32]
  delta_q_present : Bool
  /// `delta_q_res` shift (0..=3), meaningful when `delta_q_present`.
  delta_q_res : Int32
  /// Per-block loop-filter deltas; only present when `delta_q_present` and
  /// not `allow_intrabc`.
  delta_lf_present : Bool
  delta_lf_res : Int32
  delta_lf_multi : Bool
  /// Derived: all plane qindices (base + deltas) are zero.
  coded_lossless : Bool
  /// Derived: `coded_lossless && upscaled_width == width`.
  all_lossless : Bool
  /// `lr_type[i]`: 0 = none, 1 = switchable, 2/3 = Wiener, 4..=6 = SGR.
  lr_type : Array[Int32]
  /// Restoration unit size log2: `[0]` luma, `[1]` chroma.
  lr_unit_size : Array[Int32]
  loop_filter_level : Array[Int32]
  loop_filter_sharpness : Int32
  /// `loop_filter_delta_enabled` plus the (defaulted) mode/ref deltas.
  loop_filter_delta_enabled : Bool
  loop_filter_ref_deltas : Array[Int32]
  loop_filter_mode_deltas : Array[Int32]
  cdef_damping_minus_3 : Int32
  cdef_bits : Int32
  cdef_y_pri_strength : Array[Int32]
  cdef_y_sec_strength : Array[Int32]
  cdef_uv_pri_strength : Array[Int32]
  cdef_uv_sec_strength : Array[Int32]
  tx_mode : Int32
  reduced_tx_set : Bool
  allow_high_precision_mv : Bool
  interpolation_filter : Int32
  is_motion_mode_switchable : Bool
  use_ref_frame_mvs : Bool
  reference_select : Bool
  allow_warped_motion : Bool
  is_global : Array[Bool]
  apply_grain : Bool
  grain_seed : Int32
  num_y_points : Int32
  num_cb_points : Int32
  num_cr_points : Int32
  chroma_scaling_from_luma : Bool
  grain_scaling_minus_8 : Int32
  ar_coeff_lag : Int32
  ar_coeff_shift_minus_6 : Int32
  grain_scale_shift : Int32
  cb_mult : Int32
  cb_luma_mult : Int32
  cb_offset : Int32
  cr_mult : Int32
  cr_luma_mult : Int32
  cr_offset : Int32
  overlap_flag : Bool
  clip_to_restricted_range : Bool
}

///|
/// `av1_frame_type`. */
pub let av1_frame_key : Int32 = 0

///|
pub let av1_frame_inter : Int32 = 1

///|
pub let av1_frame_intra_only : Int32 = 2

///|
pub let av1_frame_switch : Int32 = 3

///|
/// `cbs_av1_tile_log2`. */
fn av1_tile_log2(blksize : Int32, target : Int32) -> Int32 {
  let mut k = 0
  while blksize << k < target {
    k = k + 1
  }
  k
}

///|
/// Parse the first frame header OBU (type 3 or 6) of `data`. Key and
/// intra-only frames are supported; inter/switch headers need the reference
/// frame state and return PATCHWELCOME.
pub fn av1_parse_frame_header(
  data : Bytes,
  seq : Av1SequenceParameters,
) -> Result[Av1FrameHeader, String] {
  let mut pos = 0
  while pos < data.length() {
    let header = data[pos].to_int()
    if (header & 0x80) != 0 {
      return Err("av1: OBU forbidden bit set")
    }
    let obu_type = (header >> 3) & 0x0F
    let extension = (header & 0x04) != 0
    let has_size = (header & 0x02) != 0
    let p_ref = Ref(pos + 1 + (if extension { 1 } else { 0 }))
    if !has_size {
      return Err("av1: OBU without size")
    }
    let size = av1_leb128(data, p_ref)
    let p = p_ref.val
    if size < 0 || p + size > data.length() {
      return Err("av1: bad OBU size")
    }
    if obu_type == 3 || obu_type == 6 {
      let br = BitReader::with_size(data[p:p + size].to_owned(), size * 8)
      let show_existing = br.read(1) != 0
      if show_existing {
        return Ok({
          show_existing_frame: true,
          frame_to_show_map_idx: br.read(3).reinterpret_as_int(),
          frame_type: 0,
          show_frame: true,
          showable_frame: false,
          error_resilient_mode: false,
          disable_cdf_update: false,
          allow_screen_content_tools: false,
          force_integer_mv: false,
          frame_size_override_flag: false,
          order_hint: 0,
          primary_ref_frame: 0,
          refresh_frame_flags: 0,
          width: seq.width,
          height: seq.height,
          upscaled_width: seq.width,
          render_width: seq.width,
          render_height: seq.height,
          use_superres: false,
          allow_intrabc: false,
          frame_refs_short_signaling: false,
          ref_frame_idx: [],
          disable_frame_end_update_cdf: false,
          tile_cols: 1,
          tile_rows: 1,
          tile_cols_log2: 0,
          tile_rows_log2: 0,
          context_update_tile_id: 0,
          tile_size_bytes_minus1: 0,
          header_bits: 0,
          base_q_idx: 0,
          dq_y_dc: 0,
          dq_u_dc: 0,
          dq_u_ac: 0,
          dq_v_dc: 0,
          dq_v_ac: 0,
          using_qmatrix: false,
          segmentation_enabled: false,
          segmentation_feature_mask: [],
          segmentation_alt_q: [],
          delta_q_present: false,
          delta_q_res: 0,
          delta_lf_present: false,
          delta_lf_res: 0,
          delta_lf_multi: false,
          coded_lossless: false,
          all_lossless: false,
          lr_type: [],
          lr_unit_size: [],
          loop_filter_level: [],
          loop_filter_sharpness: 0,
          loop_filter_delta_enabled: false,
          loop_filter_ref_deltas: [1, 0, 0, 0, -1, 0, -1, -1],
          loop_filter_mode_deltas: [0, 0],
          cdef_damping_minus_3: 0,
          cdef_bits: 0,
          cdef_y_pri_strength: [],
          cdef_y_sec_strength: [],
          cdef_uv_pri_strength: [],
          cdef_uv_sec_strength: [],
          tx_mode: 0,
          reduced_tx_set: false,
          allow_high_precision_mv: false,
          interpolation_filter: 0,
          is_motion_mode_switchable: false,
          use_ref_frame_mvs: false,
          reference_select: false,
          allow_warped_motion: false,
          is_global: [],
          apply_grain: false,
          grain_seed: 0,
          num_y_points: 0,
          num_cb_points: 0,
          num_cr_points: 0,
          chroma_scaling_from_luma: false,
          grain_scaling_minus_8: 0,
          ar_coeff_lag: 0,
          ar_coeff_shift_minus_6: 0,
          grain_scale_shift: 0,
          cb_mult: 0,
          cb_luma_mult: 0,
          cb_offset: 0,
          cr_mult: 0,
          cr_luma_mult: 0,
          cr_offset: 0,
          overlap_flag: false,
          clip_to_restricted_range: false,
        })
      }
      let frame_type = br.read(2).reinterpret_as_int()
      let show_frame = br.read(1) != 0
      let showable = if show_frame { false } else { br.read(1) != 0 }
      let error_resilient = if frame_type == av1_frame_switch ||
        (frame_type == av1_frame_key && show_frame) {
        true
      } else {
        br.read(1) != 0
      }
      let disable_cdf_update = if !seq.reduced_still_picture_header {
        br.read(1) != 0
      } else {
        false
      }
      let allow_sct = if seq.seq_force_screen_content_tools == 2 {
        br.read(1) != 0
      } else {
        seq.seq_force_screen_content_tools == 1
      }
      let force_integer = if allow_sct {
        if seq.seq_force_integer_mv == 2 {
          br.read(1) != 0
        } else {
          seq.seq_force_integer_mv == 1
        }
      } else {
        false
      }
      if seq.frame_id_numbers_present {
        br.skip(seq.delta_frame_id_length + seq.additional_frame_id_length)
      }
      let frame_size_override = if seq.reduced_still_picture_header {
        false
      } else {
        br.read(1) != 0
      }
      let order_hint = if seq.enable_order_hint {
        br.read(seq.order_hint_bits).reinterpret_as_int()
      } else {
        0
      }
      let mut refresh = 0
      let mut primary_ref = 7
      let refs : Array[Int32] = []
      let mut short_sig = false
      if frame_type == av1_frame_key && show_frame {
        refresh = 0xFF
      } else if frame_type == av1_frame_key ||
        frame_type == av1_frame_intra_only {
        refresh = if seq.reduced_still_picture_header {
          0xFF
        } else {
          br.read(8).reinterpret_as_int()
        }
      } else {
        primary_ref = if error_resilient { 7 } else { br.read(3).reinterpret_as_int() }
        refresh = br.read(8).reinterpret_as_int()
        if seq.enable_order_hint {
          short_sig = br.read(1) != 0
        }
        if short_sig {
          br.skip(6) // last_frame_idx + gold_frame_idx
        } else {
          for _ in 0..<7 {
            refs.push(br.read(3).reinterpret_as_int())
            if seq.frame_id_numbers_present {
              br.skip(seq.delta_frame_id_length)
            }
          }
        }
      }
      let mut width = seq.width
      let mut height = seq.height
      if frame_size_override {
        let wb = br.read(4).reinterpret_as_int() + 1
        let hb = br.read(4).reinterpret_as_int() + 1
        width = br.read(wb).reinterpret_as_int() + 1
        height = br.read(hb).reinterpret_as_int() + 1
      }
      // superres_params() sits inside frame_size(), before render_size().
      let mut use_superres = false
      let upscaled_width = width
      if seq.enable_superres {
        use_superres = br.read(1) != 0
        if use_superres {
          let denom = br.read(3).reinterpret_as_int() + 9
          width = (upscaled_width * 8 + denom / 2) / denom
        }
      }
      let mut render_width = width
      let mut render_height = height
      if br.read(1) != 0 {
        render_width = br.read(16).reinterpret_as_int() + 1
        render_height = br.read(16).reinterpret_as_int() + 1
      }
      let mut allow_intrabc = false
      let mut allow_high_precision = false
      let mut interpolation_filter = 0
      let mut motion_mode_switchable = false
      let mut use_ref_mvs = false
      if frame_type == av1_frame_key || frame_type == av1_frame_intra_only {
        // allow_intrabc requires screen-content tools and no superres.
        allow_intrabc = if allow_sct && upscaled_width == width {
          br.read(1) != 0
        } else {
          false
        }
      } else {
        if !force_integer {
          allow_high_precision = br.read(1) != 0
        }
        let filter_switchable = br.read(1) != 0
        if filter_switchable {
          interpolation_filter = 3
        } else {
          interpolation_filter = br.read(2).reinterpret_as_int()
        }
        if !seq.reduced_still_picture_header {
          motion_mode_switchable = br.read(1) != 0
        }
        if seq.enable_order_hint && !error_resilient {
          use_ref_mvs = br.read(1) != 0
        }
      }
      let mut disable_frame_end = false
      let mut tile_cols = 1
      let mut tile_rows = 1
      let mut tile_cols_log2 = 0
      let mut tile_rows_log2 = 0
      let mut base_q_idx = 0
      let mut dq_y_dc = 0
      let mut dq_u_dc = 0
      let mut dq_u_ac = 0
      let mut dq_v_dc = 0
      let mut dq_v_ac = 0
      let mut using_qmatrix = false
      let mut context_update_tile_id = 0
      let mut tile_size_minus1 = 0
      {
        disable_frame_end = if !seq.reduced_still_picture_header {
          br.read(1) != 0
        } else {
          false
        }
        // tile_info (uniform spacing; non-uniform tiles are not ported yet).
        let mi_cols = 2 * ((width + 7) >> 3)
        let mi_rows = 2 * ((height + 7) >> 3)
        let sb_cols = if seq.use_128x128_superblock {
          (mi_cols + 31) >> 5
        } else {
          (mi_cols + 15) >> 4
        }
        let sb_rows = if seq.use_128x128_superblock {
          (mi_rows + 31) >> 5
        } else {
          (mi_rows + 15) >> 4
        }
        let sb_size = if seq.use_128x128_superblock { 7 } else { 6 }
        let max_tile_width_sb = 4096 >> sb_size
        let max_tile_area_sb = 9437184 >> (2 * sb_size)
        let min_log2_cols = av1_tile_log2(max_tile_width_sb, sb_cols)
        let max_log2_cols = av1_tile_log2(
          1,
          if sb_cols < 64 {
            sb_cols
          } else {
            64
          },
        )
        let max_log2_rows = av1_tile_log2(
          1,
          if sb_rows < 64 {
            sb_rows
          } else {
            64
          },
        )
        let min_log2_tiles = if min_log2_cols >
          av1_tile_log2(max_tile_area_sb, sb_cols * sb_rows) {
          min_log2_cols
        } else {
          av1_tile_log2(max_tile_area_sb, sb_cols * sb_rows)
        }
        let uniform_tiles = br.read(1) != 0
        if !uniform_tiles {
          return Err("PATCHWELCOME: AV1 non-uniform tile spacing")
        }
        tile_cols_log2 = min_log2_cols
        while tile_cols_log2 < max_log2_cols {
          if br.read1() == 0 {
            break
          }
          tile_cols_log2 = tile_cols_log2 + 1
        }
        let tile_width_sb = (sb_cols + (1 << tile_cols_log2) - 1) >>
          tile_cols_log2
        tile_cols = (sb_cols + tile_width_sb - 1) / tile_width_sb
        let mut min_log2_rows = min_log2_tiles - tile_cols_log2
        if min_log2_rows < 0 {
          min_log2_rows = 0
        }
        tile_rows_log2 = min_log2_rows
        while tile_rows_log2 < max_log2_rows {
          if br.read1() == 0 {
            break
          }
          tile_rows_log2 = tile_rows_log2 + 1
        }
        let tile_height_sb = (sb_rows + (1 << tile_rows_log2) - 1) >>
          tile_rows_log2
        tile_rows = (sb_rows + tile_height_sb - 1) / tile_height_sb
        if tile_cols_log2 > 0 || tile_rows_log2 > 0 {
          context_update_tile_id = br
            .read(tile_cols_log2 + tile_rows_log2)
            .reinterpret_as_int()
          tile_size_minus1 = br.read(2).reinterpret_as_int()
        }
        // quantization_params
        base_q_idx = br.read(8).reinterpret_as_int()
        let su7 = () => {
          let v = br.read(7).reinterpret_as_int()
          if (v & 0x40) != 0 {
            v - 0x80
          } else {
            v
          }
        }
        dq_y_dc = if br.read1() != 0 { su7() } else { 0 }
        if !seq.monochrome {
          let mut diff_uv = false
          if seq.separate_uv_delta_q {
            diff_uv = br.read1() != 0
          }
          dq_u_dc = if br.read1() != 0 { su7() } else { 0 }
          dq_u_ac = if br.read1() != 0 { su7() } else { 0 }
          dq_v_dc = dq_u_dc
          dq_v_ac = dq_u_ac
          if diff_uv {
            if br.read1() != 0 {
              dq_v_dc = su7()
            }
            if br.read1() != 0 {
              dq_v_ac = su7()
            }
          }
        }
        using_qmatrix = br.read1() != 0
        if using_qmatrix {
          br.skip(8)
          if seq.separate_uv_delta_q {
            br.skip(4)
          }
        }
      }
      let mut segmentation_enabled = false
      let mut segmentation_masks : Array[Int32] = []
      let mut segmentation_alt_qs : Array[Int32] = []
      let mut delta_q_present = false
      let mut delta_q_res = 0
      let mut delta_lf_present = false
      let mut delta_lf_res = 0
      let mut delta_lf_multi = false
      let lr_type : Array[Int32] = []
      let lr_unit_size : Array[Int32] = []
      let mut coded_lossless = false
      let mut all_lossless = false
      let loop_filter_level : Array[Int32] = []
      let mut loop_filter_sharpness = 0
      let mut loop_filter_delta_enabled = false
      let loop_filter_ref_deltas : Array[Int32] = [1, 0, 0, 0, -1, 0, -1, -1]
      let loop_filter_mode_deltas : Array[Int32] = [0, 0]
      let mut cdef_damping = 0
      let mut cdef_bits = 0
      let cdef_y_pri : Array[Int32] = []
      let cdef_y_sec : Array[Int32] = []
      let cdef_uv_pri : Array[Int32] = []
      let cdef_uv_sec : Array[Int32] = []
      let mut tx_mode = 0
      let mut reduced_tx_set = false
      let mut reference_select = false
      let mut allow_warped = false
      let global_motion : Array[Bool] = []
      let mut apply_grain = false
      let mut grain_seed = 0
      let mut num_y_points = 0
      let mut num_cb_points = 0
      let mut num_cr_points = 0
      let mut chroma_scaling_from_luma = false
      let mut grain_scaling_minus_8 = 0
      let mut ar_coeff_lag = 0
      let mut ar_coeff_shift_minus_6 = 0
      let mut grain_scale_shift = 0
      let mut cb_mult = 0
      let mut cb_luma_mult = 0
      let mut cb_offset = 0
      let mut cr_mult = 0
      let mut cr_luma_mult = 0
      let mut cr_offset = 0
      let mut overlap_flag = false
      let mut clip_to_restricted = false
      {
        segmentation_enabled = br.read1() != 0
        let seg_masks : Array[Int32] = []
        let seg_alt_q : Array[Int32] = []
        if segmentation_enabled {
          let mut update_map = true
          let mut update_data = true
          if primary_ref != 7 {
            update_map = br.read1() != 0
            if update_map {
              ignore(br.read1()) // segmentation_temporal_update
            }
            update_data = br.read1() != 0
          }
          if update_data {
            for _ in 0..<8 {
              let mut mask = 0
              let mut altq = 0
              for f in 0..<8 {
                if br.read1() != 0 {
                  mask = mask | (1 << f)
                  if f == 0 {
                    let v = br.read(9).reinterpret_as_int()
                    altq = if (v & 0x100) != 0 { v - 0x200 } else { v }
                  } else if f <= 4 {
                    br.skip(7)
                  } else if f == 5 {
                    br.skip(3)
                  }
                }
              }
              seg_masks.push(mask)
              seg_alt_q.push(altq)
            }
          }
        }
        segmentation_masks = seg_masks
        segmentation_alt_qs = seg_alt_q
        if base_q_idx > 0 {
          delta_q_present = br.read1() != 0
          if delta_q_present {
            delta_q_res = br.read(2).reinterpret_as_int()
          }
        }
        // delta_lf_params follow delta_q, suppressed by intrabc.
        if delta_q_present && !allow_intrabc {
          delta_lf_present = br.read1() != 0
          if delta_lf_present {
            delta_lf_res = br.read(2).reinterpret_as_int()
            delta_lf_multi = br.read1() != 0
          }
        }
        // coded_lossless: every plane qindex (base + deltas) is zero.
        coded_lossless = base_q_idx == 0 &&
          dq_y_dc == 0 &&
          dq_u_dc == 0 &&
          dq_u_ac == 0
        all_lossless = coded_lossless && upscaled_width == width
        // loop_filter_params are absent when lossless or intrabc.
        if !coded_lossless && !allow_intrabc {
          let lf0 = br.read(6).reinterpret_as_int()
          let lf1 = br.read(6).reinterpret_as_int()
          loop_filter_level.push(lf0)
          loop_filter_level.push(lf1)
          if !seq.monochrome && (lf0 != 0 || lf1 != 0) {
            loop_filter_level.push(br.read(6).reinterpret_as_int())
            loop_filter_level.push(br.read(6).reinterpret_as_int())
          }
          loop_filter_sharpness = br.read(3).reinterpret_as_int()
          let lf_delta_enabled = br.read1() != 0
          loop_filter_delta_enabled = lf_delta_enabled
          if lf_delta_enabled {
            let update = br.read1() != 0
            if update {
              for i in 0..<8 {
                if br.read1() != 0 {
                  loop_filter_ref_deltas[i] = br.read(7).reinterpret_as_int() <<
                    25 >>
                    25
                }
              }
              for i in 0..<2 {
                if br.read1() != 0 {
                  loop_filter_mode_deltas[i] = br.read(7).reinterpret_as_int() <<
                    25 >>
                    25
                }
              }
            }
          }
        }
        // cdef_params are absent when lossless, intrabc or disabled.
        if !coded_lossless && !allow_intrabc && seq.enable_cdef {
          cdef_damping = br.read(2).reinterpret_as_int()
          cdef_bits = br.read(2).reinterpret_as_int()
          for _ in 0..<(1 << cdef_bits) {
            cdef_y_pri.push(br.read(4).reinterpret_as_int())
            cdef_y_sec.push(br.read(2).reinterpret_as_int())
            if !seq.monochrome {
              cdef_uv_pri.push(br.read(4).reinterpret_as_int())
              cdef_uv_sec.push(br.read(2).reinterpret_as_int())
            }
          }
        }
        // lr_params: per-plane restoration type and unit sizing.
        let num_planes = if seq.monochrome { 1 } else { 3 }
        if !all_lossless && !allow_intrabc && seq.enable_restoration {
          let mut uses_lr = false
          let mut uses_chroma_lr = false
          for i in 0..<num_planes {
            let t = br.read(2).reinterpret_as_int()
            lr_type.push(t)
            if t != 0 {
              uses_lr = true
              if i > 0 {
                uses_chroma_lr = true
              }
            }
          }
          if uses_lr {
            // Log2 of the restoration unit size (dav1d obu.c).
            let mut u0 = 6 + (if seq.use_128x128_superblock { 1 } else { 0 })
            if br.read1() != 0 {
              u0 = u0 + 1
              if !seq.use_128x128_superblock {
                u0 = u0 + br.read1().reinterpret_as_int()
              }
            }
            let mut u1 = u0
            if uses_chroma_lr &&
              seq.chroma_subsampling_x &&
              seq.chroma_subsampling_y {
              if br.read1() != 0 {
                u1 = u1 - 1
              }
            }
            lr_unit_size.push(u0)
            lr_unit_size.push(u1)
          } else {
            lr_unit_size.push(8)
            lr_unit_size.push(8)
          }
        }
        if coded_lossless {
          tx_mode = 0 // ONLY_4X4
        } else if !seq.reduced_still_picture_header {
          tx_mode = if br.read1() != 0 { 2 } else { 1 }
        } else {
          tx_mode = 1
        }
        if frame_type == av1_frame_inter {
          reference_select = br.read1() != 0
        }
        // allow_warped_motion is suppressed for intra frames.
        if frame_type == av1_frame_inter && !error_resilient {
          allow_warped = br.read1() != 0
        }
        if !seq.reduced_still_picture_header {
          reduced_tx_set = br.read1() != 0
        }
        if frame_type == av1_frame_inter {
          for _ in 0..<7 {
            let g = br.read1() != 0
            global_motion.push(g)
            if g {
              return Err("PATCHWELCOME: AV1 global motion")
            }
          }
        }
        if seq.film_grain_params_present && (show_frame || showable) {
          apply_grain = br.read1() != 0
          if apply_grain {
            grain_seed = br.read(16).reinterpret_as_int()
            let update = if frame_type == av1_frame_inter {
              br.read1() != 0
            } else {
              true
            }
            if !update {
              return Err("PATCHWELCOME: AV1 grain from reference")
            }
            num_y_points = br.read(4).reinterpret_as_int()
            if num_y_points > 14 {
              return Err("av1: invalid grain points")
            }
            for _ in 0..<num_y_points {
              br.skip(16) // point_y_value + point_y_scaling
            }
            if !seq.monochrome {
              chroma_scaling_from_luma = br.read1() != 0
            }
            let skip_chroma = seq.monochrome ||
              chroma_scaling_from_luma ||
              (
                seq.chroma_subsampling_x &&
                seq.chroma_subsampling_y &&
                num_y_points == 0
              )
            if !skip_chroma {
              num_cb_points = br.read(4).reinterpret_as_int()
              if num_cb_points > 10 {
                return Err("av1: invalid cb grain points")
              }
              for _ in 0..<num_cb_points {
                br.skip(16)
              }
              num_cr_points = br.read(4).reinterpret_as_int()
              if num_cr_points > 10 {
                return Err("av1: invalid cr grain points")
              }
              for _ in 0..<num_cr_points {
                br.skip(16)
              }
            }
            grain_scaling_minus_8 = br.read(2).reinterpret_as_int()
            ar_coeff_lag = br.read(2).reinterpret_as_int()
            let num_pos_luma = 2 * ar_coeff_lag * (ar_coeff_lag + 1)
            let num_pos_chroma = if num_y_points > 0 {
              br.skip(8 * num_pos_luma)
              num_pos_luma + 1
            } else {
              num_pos_luma
            }
            if chroma_scaling_from_luma || num_cb_points > 0 {
              br.skip(8 * num_pos_chroma)
            }
            if chroma_scaling_from_luma || num_cr_points > 0 {
              br.skip(8 * num_pos_chroma)
            }
            ar_coeff_shift_minus_6 = br.read(2).reinterpret_as_int()
            grain_scale_shift = br.read(2).reinterpret_as_int()
            if num_cb_points > 0 {
              cb_mult = br.read(8).reinterpret_as_int()
              cb_luma_mult = br.read(8).reinterpret_as_int()
              cb_offset = br.read(9).reinterpret_as_int()
            }
            if num_cr_points > 0 {
              cr_mult = br.read(8).reinterpret_as_int()
              cr_luma_mult = br.read(8).reinterpret_as_int()
              cr_offset = br.read(9).reinterpret_as_int()
            }
            overlap_flag = br.read1() != 0
            clip_to_restricted = br.read1() != 0
          }
        }
      }
      return Ok({
        show_existing_frame: false,
        frame_to_show_map_idx: 0,
        frame_type,
        show_frame,
        showable_frame: showable,
        error_resilient_mode: error_resilient,
        disable_cdf_update,
        allow_screen_content_tools: allow_sct,
        force_integer_mv: force_integer,
        frame_size_override_flag: frame_size_override,
        order_hint,
        primary_ref_frame: primary_ref,
        refresh_frame_flags: refresh,
        width,
        height,
        render_width,
        render_height,
        use_superres,
        upscaled_width,
        allow_intrabc,
        frame_refs_short_signaling: short_sig,
        ref_frame_idx: refs,
        disable_frame_end_update_cdf: disable_frame_end,
        tile_cols,
        tile_rows,
        tile_cols_log2,
        tile_rows_log2,
        context_update_tile_id,
        tile_size_bytes_minus1: tile_size_minus1,
        header_bits: (br.count() + 7) / 8 * 8,
        base_q_idx,
        dq_y_dc,
        dq_u_dc,
        dq_u_ac,
        dq_v_dc,
        dq_v_ac,
        using_qmatrix,
        segmentation_enabled,
        segmentation_feature_mask: segmentation_masks,
        segmentation_alt_q: segmentation_alt_qs,
        delta_q_present,
        delta_q_res,
        delta_lf_present,
        delta_lf_res,
        delta_lf_multi,
        coded_lossless,
        all_lossless,
        lr_type,
        lr_unit_size,
        loop_filter_level,
        loop_filter_sharpness,
        loop_filter_delta_enabled,
        loop_filter_ref_deltas,
        loop_filter_mode_deltas,
        cdef_damping_minus_3: cdef_damping,
        cdef_bits,
        cdef_y_pri_strength: cdef_y_pri,
        cdef_y_sec_strength: cdef_y_sec,
        cdef_uv_pri_strength: cdef_uv_pri,
        cdef_uv_sec_strength: cdef_uv_sec,
        tx_mode,
        reduced_tx_set,
        allow_high_precision_mv: allow_high_precision,
        interpolation_filter,
        is_motion_mode_switchable: motion_mode_switchable,
        use_ref_frame_mvs: use_ref_mvs,
        reference_select,
        allow_warped_motion: allow_warped,
        is_global: global_motion,
        apply_grain,
        grain_seed,
        num_y_points,
        num_cb_points,
        num_cr_points,
        chroma_scaling_from_luma,
        grain_scaling_minus_8,
        ar_coeff_lag,
        ar_coeff_shift_minus_6,
        grain_scale_shift,
        cb_mult,
        cb_luma_mult,
        cb_offset,
        cr_mult,
        cr_luma_mult,
        cr_offset,
        overlap_flag,
        clip_to_restricted_range: clip_to_restricted,
      })
    }
    pos = p + size
  }
  Err("av1: no frame header OBU")
}

///|
/// AV1 tile-group header (the tile data itself is left to the decoder). */
pub struct Av1TileGroup {
  tile_start : Int32
  tile_end : Int32
  num_tiles : Int32
  header_bits : Int32
  /// Byte offset of the first tile payload within the OBU payload.
  data_offset : Int32
  /// Tile sizes in bytes (last tile size is implicit).
  tile_sizes : Array[Int32]
  /// Absolute offset of this OBU payload inside the input buffer.
  payload_offset : Int32
  /// Each tile's byte offset within the OBU payload (size prefixes excluded).
  tile_offsets : Array[Int32]
  /// Bytes of tile payload following the header.
  data_size : Int32
}

///|
/// Parse the tile-group header from OBU_TILE_GROUP or OBU_FRAME.
pub fn av1_parse_tile_group(
  data : Bytes,
  fh : Av1FrameHeader,
) -> Result[Av1TileGroup, String] {
  if fh.show_existing_frame || fh.tile_cols < 1 || fh.tile_cols > 64 ||
    fh.tile_rows < 1 || fh.tile_rows > 64 || fh.tile_cols_log2 < 0 ||
    fh.tile_cols_log2 > 6 || fh.tile_rows_log2 < 0 || fh.tile_rows_log2 > 6 ||
    fh.tile_size_bytes_minus1 < 0 || fh.tile_size_bytes_minus1 > 3 {
    return Err("av1: invalid tile layout")
  }
  if fh.tile_cols_log2 != av1_tile_log2(1, fh.tile_cols) ||
    fh.tile_rows_log2 != av1_tile_log2(1, fh.tile_rows) {
    return Err("av1: invalid tile layout")
  }
  let mut pos = 0
  while pos < data.length() {
    let header = data[pos].to_int()
    if (header & 0x80) != 0 { return Err("av1: OBU forbidden bit set") }
    if (header & 1) != 0 { return Err("av1: OBU reserved bit set") }
    let obu_type = (header >> 3) & 0x0F
    let extension = (header & 0x04) != 0
    let has_size = (header & 0x02) != 0
    if extension && pos + 1 >= data.length() { return Err("av1: truncated OBU extension") }
    if extension && (data[pos + 1].to_int() & 7) != 0 { return Err("av1: OBU extension reserved bits set") }
    let p_ref = Ref(pos + 1 + (if extension { 1 } else { 0 }))
    if !has_size {
      return Err("av1: OBU without size")
    }
    let size = av1_leb128(data, p_ref)
    let p = p_ref.val
    if size < 0 || size > data.length() - p {
      return Err("av1: bad OBU size")
    }
    if obu_type == 4 || obu_type == 6 {
      let payload = data[p:p + size].to_owned()
      let br = BitReader::with_size(payload, size * 8)
      if obu_type == 6 {
        let skip = fh.header_bits
        if skip < 0 || skip > size * 8 {
          return Err("av1: frame header overruns OBU")
        }
        br.skip(skip)
      }
      let num_tiles = fh.tile_cols * fh.tile_rows
      let mut start = 0
      let mut end = num_tiles - 1
      if num_tiles > 1 {
        if br.bits_left() < 1 { return Err("av1: truncated tile group header") }
        if br.read(1) != 0 {
          let bits = fh.tile_cols_log2 + fh.tile_rows_log2
          if br.bits_left() < 2 * bits { return Err("av1: truncated tile group header") }
          start = br.read(bits).reinterpret_as_int()
          end = br.read(bits).reinterpret_as_int()
          if start > end || end >= num_tiles {
            return Err("av1: invalid tile range")
          }
        }
      }
      let aligned = (br.count() + 7) / 8 * 8
      while br.count() < aligned {
        if br.read(1) != 0 { return Err("av1: nonzero tile group alignment bit") }
      }
      let sizes : Array[Int32] = []
      let offsets : Array[Int32] = []
      let total = payload.length()
      let count = end - start + 1
      let size_bytes = fh.tile_size_bytes_minus1 + 1
      let mut pbyte = aligned / 8
      for tile in 0..<count {
        if tile < count - 1 {
          if pbyte + size_bytes > total {
            return Err("av1: truncated tile size")
          }
          let mut v = 0U
          for b in 0..<size_bytes {
            v = v | (payload[pbyte + b].to_uint() << (8 * b))
          }
          pbyte = pbyte + size_bytes
          if v >= (total - pbyte).reinterpret_as_uint() {
            return Err("av1: tile sizes exceed OBU")
          }
          offsets.push(pbyte)
          sizes.push(v.reinterpret_as_int() + 1)
          // Size fields are interleaved with each tile's compressed data.
          pbyte += v.reinterpret_as_int() + 1
        } else {
          offsets.push(pbyte)
          sizes.push(total - pbyte)
        }
      }
      let data_offset = offsets[0]
      return Ok({
        tile_start: start,
        tile_end: end,
        num_tiles,
        header_bits: aligned,
        data_offset,
        tile_sizes: sizes,
        tile_offsets: offsets,
        payload_offset: p,
        data_size: if sizes.length() > 0 {
          let mut dsum = 0
          for sz in sizes {
            dsum = dsum + sz
          }
          dsum
        } else {
          total - data_offset
        },
      })
    }
    pos = p + size
  }
  Err("av1: no tile group OBU")
}
