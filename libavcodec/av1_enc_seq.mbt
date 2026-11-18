///|
/// AV1 sequence-header OBU writer (§438b) — the write-side twin of
/// `av1_parse_sequence_header` / `av1_parse_sequence_payload` /
/// `av1_parse_color_config` (libavformat/av1.c bit order). The minimal,
/// useful surface for a wasm-side AV1 encoder: a still-picture or
/// general-purpose sequence header for profile 0 (4:2:0), 8/10-bit,
/// optional monochrome, with the inter tool-set (order hint, compound
/// modes, warping) left OFF — tile data slices turn them on when their
/// write sides land. The parser in `av1.mbt` is the acceptance oracle:
/// every written stream must round-trip field-for-field.

///|
/// The writer-facing sequence configuration. `level` is `seq_level_idx`
/// (0..31; the tier bit rides along only when level > 7, spec 5.5.2).
pub(all) struct Av1SeqEncConfig {
  width : Int32
  height : Int32
  /// 8 or 10 (profile 0; the bitdepth flag decides).
  bit_depth : Int32
  monochrome : Bool
  /// `seq_level_idx[0]`, 0..31.
  level : Int32
  /// Still-picture header (`reduced_still_picture_header = 1`): no
  /// operating points, no frame ids, inter tools skipped by the parser.
  still_picture : Bool
}

///|
/// Default configuration: 8-bit 4:2:0, level 0 (2.0), general header.
pub fn Av1SeqEncConfig::default(
  width~ : Int32,
  height~ : Int32,
) -> Av1SeqEncConfig {
  {
    width,
    height,
    bit_depth: 8,
    monochrome: false,
    level: 0,
    still_picture: false,
  }
}

///|
/// `leb128` writer (the OBU size field): 7-bit little-endian groups,
/// MSB continuation.
fn av1_enc_leb128(r : H264Rbsp, v : Int32) -> Unit {
  let mut value = v
  while true {
    let byte = value & 0x7F
    value = value >> 7
    if value == 0 {
      r.put(byte, 8)
      break
    }
    r.put(byte | 0x80, 8)
  }
}

///|
/// Bits needed to hold `v` (v >= 0; at least 1).
fn av1_enc_bit_length(v : Int32) -> Int32 {
  let mut n = 1
  let mut x = v >> 1
  while x > 0 {
    n = n + 1
    x = x >> 1
  }
  n
}

///|
/// One OBU wrapper: header byte (`forbidden=0 | type | ext=0 |
/// has_size=1`), leb128 size, payload.
fn av1_enc_obu(obu_type : Int32, payload : Bytes) -> Bytes {
  let r = H264Rbsp::new()
  r.put((obu_type << 3) | 0x02, 8)
  av1_enc_leb128(r, payload.length())
  let head = r.finish_raw_of()
  let out : Array[Byte] = []
  for b in head {
    out.push(b)
  }
  for b in payload {
    out.push(b)
  }
  Bytes::from_array(out[:])
}

///|
/// Write the sequence-header payload bits (everything inside the OBU).
fn av1_enc_write_sequence_payload(
  r : H264Rbsp,
  config : Av1SeqEncConfig,
) -> Result[Unit, String] {
  if config.width < 1 ||
    config.height < 1 ||
    config.width > 65536 ||
    config.height > 65536 {
    return Err("av1 enc: invalid geometry \{config.width}x\{config.height}")
  }
  if config.bit_depth != 8 && config.bit_depth != 10 {
    return Err(
      "av1 enc: profile 0 supports 8 or 10 bits (got \{config.bit_depth})",
    )
  }
  if config.level < 0 || config.level > 31 {
    return Err("av1 enc: seq_level_idx out of range (got \{config.level})")
  }
  // The reduced (still-picture) header carries the level inline and
  // skips the operating-point/inter-tool syntax; the general header
  // writes one operating point with every inter capability OFF and the
  // "chosen" screen-content/integer-MV selectors (2/2), which is what
  // real encoders emit and keeps the frame header free to decide.
  let reduced = config.still_picture
  r.put(0, 3) // seq_profile = 0 (4:2:0)
  r.put_bit(if reduced { 1 } else { 0 }) // still_picture
  r.put_bit(if reduced { 1 } else { 0 }) // reduced_still_picture_header
  if reduced {
    r.put(config.level, 5)
  } else {
    r.put_bit(0) // timing_info_present_flag
    r.put_bit(0) // initial_display_delay_present_flag
    r.put(0, 5) // operating_points_cnt_minus_1 = 0
    r.put(0, 12) // operating_point_idc[0] = 0
    r.put(config.level, 5) // seq_level_idx[0]
    if config.level > 7 {
      r.put_bit(0) // decoder_model for this op absent; tier = 0
    }
  }
  let wb = av1_enc_bit_length(config.width - 1)
  let hb = av1_enc_bit_length(config.height - 1)
  r.put(wb - 1, 4)
  r.put(hb - 1, 4)
  r.put(config.width - 1, wb)
  r.put(config.height - 1, hb)
  if !reduced {
    r.put_bit(0) // frame_id_numbers_present_flag
  }
  r.put_bit(0) // use_128x128_superblock
  r.put_bit(0) // enable_filter_intra
  r.put_bit(0) // enable_intra_edge_filter
  if !reduced {
    r.put_bit(0) // enable_interintra
    r.put_bit(0) // enable_masked_compound
    r.put_bit(0) // enable_warped_motion
    r.put_bit(0) // enable_dual_filter
    r.put_bit(0) // enable_order_hint
    r.put_bit(1) // seq_choose_screen_content_tools -> force = 2
    r.put_bit(1) // seq_choose_integer_mv -> force = 2
  }
  r.put_bit(0) // enable_superres
  r.put_bit(0) // enable_cdef
  r.put_bit(0) // enable_restoration
  // color_config (profile 0). The parser reads `mono_chrome` for every
  // profile but 1 — the bit is ALWAYS present here.
  r.put_bit(if config.bit_depth == 10 { 1 } else { 0 }) // high_bitdepth
  r.put_bit(if config.monochrome { 1 } else { 0 }) // mono_chrome
  r.put_bit(0) // color_description_present_flag -> unspecified 2/2/2
  if config.monochrome {
    r.put_bit(0) // color_range = studio
  } else {
    r.put_bit(0) // color_range = studio
    // profile 0: subsampling x=y=1 implied, chroma_sample_position(2).
    r.put(0, 2)
  }
  r.put_bit(0) // separate_uv_delta_q
  r.put_bit(0) // film_grain_params_present
  r.trailing_bits()
  Ok(())
}

///|
/// The complete sequence-header OBU (header byte, leb128 size, payload
/// with trailing bits). Acceptance = `av1_parse_sequence_header` reads
/// every field back.
pub fn av1_enc_write_sequence_header_obu(
  config : Av1SeqEncConfig,
) -> Result[Bytes, String] {
  let r = H264Rbsp::new()
  match av1_enc_write_sequence_payload(r, config) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok(av1_enc_obu(1, r.finish_raw_of()))
}
