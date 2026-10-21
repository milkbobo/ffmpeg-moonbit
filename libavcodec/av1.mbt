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
    value = value | ((b & 0x7F).to_uint() << shift)
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
  let high_bitdepth = br.read(1).to_int()
  let mut twelve_bit = 0
  if seq.profile == 2 && high_bitdepth != 0 {
    twelve_bit = br.read(1).to_int()
  }
  seq.bitdepth = 8 + high_bitdepth * 2 + twelve_bit * 2
  seq.monochrome = if seq.profile == 1 { false } else { br.read(1) != 0 }
  seq.color_description_present_flag = br.read(1) != 0
  if seq.color_description_present_flag {
    seq.color_primaries = br.read(8).to_int()
    seq.transfer_characteristics = br.read(8).to_int()
    seq.matrix_coefficients = br.read(8).to_int()
  } else {
    seq.color_primaries = 2 // AVCOL_PRI_UNSPECIFIED
    seq.transfer_characteristics = 2 // AVCOL_TRC_UNSPECIFIED
    seq.matrix_coefficients = 2 // AVCOL_SPC_UNSPECIFIED
  }
  if seq.monochrome {
    seq.color_range = br.read(1).to_int()
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
    seq.color_range = br.read(1).to_int()
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
      seq.chroma_sample_position = br.read(2).to_int()
    }
  }
  ignore(br.read(1)) // separate_uv_delta_q
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
  seq.profile = br.read(3).to_int()
  ignore(br.read(1)) // still_picture
  let reduced = br.read(1) != 0
  seq.reduced_still_picture_header = reduced
  if reduced {
    seq.level = br.read(5).to_int()
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
        buffer_delay_length_minus_1 = br.read(5).to_int()
        br.skip(32 + 10 + 5) // num_units_in_decoding_tick, lengths
      }
    }
    let initial_display_delay_present = br.read(1) != 0
    let operating_points = br.read(5).to_int()
    for i in 0..<=operating_points {
      br.skip(12) // operating_point_idc
      let level = br.read(5).to_int()
      let tier = if level > 7 { br.read(1).to_int() } else { 0 }
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
  let width_bits = br.read(4).to_int() + 1
  let height_bits = br.read(4).to_int() + 1
  seq.width = br.read(width_bits).to_int() + 1
  seq.height = br.read(height_bits).to_int() + 1
  if !reduced {
    seq.frame_id_numbers_present = br.read(1) != 0
    if seq.frame_id_numbers_present {
      seq.delta_frame_id_length = br.read(4).to_int() + 2
      seq.additional_frame_id_length = br.read(3).to_int() + 1
    }
  }
  br.skip(3) // use_128x128_superblock, filter_intra, intra_edge_filter
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
      seq.seq_force_screen_content_tools = br.read(1).to_int()
    }
    if seq.seq_force_screen_content_tools != 0 {
      let choose_mv = br.read(1) != 0
      if choose_mv {
        seq.seq_force_integer_mv = 2
      } else {
        seq.seq_force_integer_mv = br.read(1).to_int()
      }
    }
    if seq.enable_order_hint {
      seq.order_hint_bits = br.read(3).to_int() + 1
    }
  }
  seq.enable_superres = br.read(1) != 0
  seq.enable_cdef = br.read(1) != 0
  seq.enable_restoration = br.read(1) != 0
  av1_parse_color_config(seq, br)
  ignore(br.read(1)) // film_grain_params_present
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
    seq.profile = br.read(3).to_int()
    seq.level = br.read(5).to_int()
    seq.tier = br.read(1).to_int()
    let high = br.read(1).to_int()
    let twelve = br.read(1).to_int()
    seq.bitdepth = 8 + high * 2 + twelve * 2
    seq.monochrome = br.read(1) != 0
    seq.chroma_subsampling_x = br.read(1) != 0
    seq.chroma_subsampling_y = br.read(1) != 0
    seq.chroma_sample_position = br.read(2).to_int()
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
  allow_intrabc : Bool
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
          frame_to_show_map_idx: br.read(3).to_int(),
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
          render_width: seq.width,
          render_height: seq.height,
          use_superres: false,
          allow_intrabc: false,
        })
      }
      let frame_type = br.read(2).to_int()
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
        br.read(seq.order_hint_bits).to_int()
      } else {
        0
      }
      let mut refresh = 0
      let primary_ref = 0
      if frame_type == av1_frame_key && show_frame {
        refresh = 0xFF
      } else if frame_type == av1_frame_key ||
        frame_type == av1_frame_intra_only {
        refresh = if seq.reduced_still_picture_header {
          0xFF
        } else {
          br.read(8).to_int()
        }
      } else {
        return Err("PATCHWELCOME: AV1 inter frame header")
      }
      let mut width = seq.width
      let mut height = seq.height
      if frame_size_override {
        let wb = br.read(4).to_int() + 1
        let hb = br.read(4).to_int() + 1
        width = br.read(wb).to_int() + 1
        height = br.read(hb).to_int() + 1
      }
      let mut render_width = width
      let mut render_height = height
      if br.read(1) != 0 {
        render_width = br.read(16).to_int() + 1
        render_height = br.read(16).to_int() + 1
      }
      let mut use_superres = false
      if seq.enable_superres && !frame_size_override {
        use_superres = br.read(1) != 0
        if use_superres {
          ignore(br.read(3))
        }
      }
      let allow_intrabc = if allow_sct &&
        (frame_type == av1_frame_key || frame_type == av1_frame_intra_only) {
        br.read(1) != 0
      } else {
        false
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
        allow_intrabc,
      })
    }
    pos = p + size
  }
  Err("av1: no frame header OBU")
}
