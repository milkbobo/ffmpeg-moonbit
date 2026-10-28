///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/h2645_parse.c`: the shared
/// H.264/HEVC NAL-unit splitter (`ff_h2645_extract_rbsp` and
/// `ff_h2645_packet_split`) plus the two NAL header layouts.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope / deviations from the C:
///   * `H2645RBSP`'s bump allocator and the `skipped_bytes_pos` bookkeeping
///     (used by hwaccel/bitstream filters to map RBSP offsets back to the
///     escaped stream) are not modelled; the unescaped NAL is returned as its
///     own `Bytes`.
///   * NAL units are copied out instead of aliasing the input buffer, so the
///     `data == raw_data` fast path has no observable equivalent.
///   * The NALFF path re-syncs by reading the next length field after a short
///     `consumed`; the C instead rescans for a start code inside the declared
///     NAL length. Well-formed files are identical.
///   * Zero-padding reads are handled by `BitReader` itself, so the
///     `AV_INPUT_BUFFER_PADDING_SIZE` memset is not needed.

///|
/// Which codec's NAL header layout to use. */
pub enum H2645Codec {
  H264
  Hevc
}

///|
/// `H264_NAL_SPS`. */
pub let h264_nal_sps : Int32 = 7

///|
/// `H264_NAL_PPS`. */
pub let h264_nal_pps : Int32 = 8

///|
/// `H264_NAL_IDR_SLICE`. */
pub let h264_nal_idr_slice : Int32 = 5

///|
/// `HEVC_NAL_VPS`. */
pub let hevc_nal_vps : Int32 = 32

///|
/// `HEVC_NAL_SPS`. */
pub let hevc_nal_sps : Int32 = 33

///|
/// `HEVC_NAL_PPS`. */
pub let hevc_nal_pps : Int32 = 34

///|
/// `HEVC_NAL_SEI_PREFIX`. */
pub let hevc_nal_sei_prefix : Int32 = 39

///|
/// One parsed NAL unit (`H2645NAL`). */
pub struct H2645Nal {
  /// Unescaped RBSP, including the NAL header.
  data : Bytes
  /// SODB size: excludes the stop bit and trailing zero bytes.
  size_bits : Int32
  /// Bytes of the escaped source consumed by this NAL.
  raw_size : Int32
  /// RBSP positions of the removed emulation-prevention bytes (the index of
  /// the second zero of each `00 00 03`, as in the C `skipped_bytes_pos`).
  skipped_bytes_pos : Array[Int32]
  /// `nal_unit_type` / H.264's 5-bit type.
  nal_type : Int32
  /// H.264 `nal_ref_idc` (0 for HEVC).
  ref_idc : Int32
  /// HEVC `nuh_temporal_id_plus1 - 1` (0 for H.264).
  temporal_id : Int32
  /// HEVC `nuh_layer_id` (0 for H.264).
  nuh_layer_id : Int32
}

///|
/// `H2645Packet`: the NALs of one input packet, in order. */
pub struct H2645Packet {
  nals : Array[H2645Nal]
}

///|
/// Result of `ff_h2645_extract_rbsp`. */
pub struct RbspExtract {
  data : Bytes
  /// `si` from the C: bytes of the input belonging to this NAL.
  consumed : Int32
  /// Number of removed `emulation_prevention_three_byte`s.
  skipped : Int32
  /// RBSP positions of the removed bytes (index of the second zero).
  skipped_pos : Array[Int32]
}

///|
/// `ff_h2645_extract_rbsp`: strip emulation prevention bytes and stop at the
/// next Annex B start code. `src` may contain more than one NAL (the Annex B
/// path passes the rest of the packet); `consumed` says where this one ended.
pub fn ff_h2645_extract_rbsp(src : Bytes) -> RbspExtract {
  let length = src.length()
  let mut first = -1
  let mut first_is_start_code = false
  let mut i = 0
  while i + 2 < length {
    if src[i] == b'\x00' &&
      src[i + 1] == b'\x00' &&
      (src[i + 2] == b'\x03' || src[i + 2] == b'\x01') {
      first = i
      first_is_start_code = src[i + 2] == b'\x01'
      break
    }
    i = i + 1
  }
  if first < 0 {
    return { data: src, consumed: length, skipped: 0, skipped_pos: [], }
  }
  if first_is_start_code {
    return {
      data: src.clamped_view(start=0, end=first).to_owned(),
      consumed: first,
      skipped: 0,
      skipped_pos: [],
    }
  }
  // Unescape from the first 00 00 03; a later 00 00 01 ends the NAL (the C's
  // `goto nsc`), and 00 00 0x (x > 3) is copied through.
  let out = FixedArray::make(length, b'\x00')
  let mut si = 0
  let mut di = 0
  while si < first {
    out[di] = src[si]
    di = di + 1
    si = si + 1
  }
  let mut skipped = 0
  let skipped_pos : Array[Int32] = []
  while si + 2 < length {
    if src[si + 2] > b'\x03' {
      out[di] = src[si]
      out[di + 1] = src[si + 1]
      di = di + 2
      si = si + 2
    } else if src[si] == b'\x00' &&
      src[si + 1] == b'\x00' &&
      src[si + 2] != b'\x00' {
      if src[si + 2] == b'\x03' {
        out[di] = b'\x00'
        out[di + 1] = b'\x00'
        di = di + 2
        si = si + 3
        skipped = skipped + 1
        skipped_pos.push(di - 1)
        continue
      } else {
        // next start code
        return {
          data: Bytes::from_array(out[:di]),
          consumed: si,
          skipped,
          skipped_pos,
        }
      }
    }
    out[di] = src[si]
    di = di + 1
    si = si + 1
  }
  while si < length {
    out[di] = src[si]
    di = di + 1
    si = si + 1
  }
  { data: Bytes::from_array(out[:di]), consumed: si, skipped, skipped_pos, }
}

///|
/// `get_bit_length`: SODB size in bits, removing the stop bit and trailing
/// zeros. `min_size` is 1 for H.264 (1-byte NAL header) and 2 for HEVC.
pub fn get_bit_length(
  data : Bytes,
  min_size : Int32,
  skip_trailing_zeros : Bool,
) -> Int32 {
  let mut size = data.length()
  while skip_trailing_zeros && size > 0 && data[size - 1] == b'\x00' {
    size = size - 1
  }
  if size == 0 {
    return 0
  }
  let mut trailing_padding = 0
  if size <= min_size {
    if data.length() < min_size {
      return -1
    }
    size = min_size
  } else {
    let v = data[size - 1].to_int()
    if v != 0 {
      trailing_padding = ctz8(v) + 1
    }
  }
  size * 8 - trailing_padding
}

///|
/// `hevc_parse_nal_header` / `h264_parse_nal_header`. The reader must be
/// positioned at the start of the NAL.
fn parse_nal_header(
  gb : BitReader,
  codec : H2645Codec,
) -> Result[H2645Nal, String] {
  match codec {
    H264 => {
      if gb.read1() != 0 {
        return Err("EINVAL")
      }
      let ref_idc = gb.read(2).reinterpret_as_int()
      let nal_type = gb.read(5).reinterpret_as_int()
      Ok({
        data: b"",
        size_bits: 0,
        raw_size: 0,
        skipped_bytes_pos: [],
        nal_type,
        ref_idc,
        temporal_id: 0,
        nuh_layer_id: 0,
      })
    }
    Hevc => {
      if gb.read1() != 0 {
        return Err("EINVAL")
      }
      let nal_type = gb.read(6).reinterpret_as_int()
      let nuh_layer_id = gb.read(6).reinterpret_as_int()
      let temporal_id = gb.read(3).reinterpret_as_int() - 1
      if temporal_id < 0 {
        return Err("EINVAL")
      }
      Ok({
        data: b"",
        size_bits: 0,
        raw_size: 0,
        skipped_bytes_pos: [],
        nal_type,
        ref_idc: 0,
        temporal_id,
        nuh_layer_id,
      })
    }
  }
}

///|
/// Enum equality helper (`H2645Codec` has no derived `Eq`). */
fn h2645_is_hevc(codec : H2645Codec) -> Bool {
  match codec {
    Hevc => true
    H264 => false
  }
}

///|
/// Turn one extracted RBSP into an `H2645Nal`, or `None` for an empty /
/// unparsable NAL (the C skips such NALs without failing the packet).
fn build_nal(
  data : Bytes,
  consumed : Int32,
  skipped_pos : Array[Int32],
  codec : H2645Codec,
) -> H2645Nal? {
  let min_size = if h2645_is_hevc(codec) { 2 } else { 1 }
  let size_bits = get_bit_length(data, min_size, true)
  if data.length() <= 0 || size_bits <= 0 {
    return None
  }
  let gb = BitReader::with_size(data, size_bits)
  match parse_nal_header(gb, codec) {
    Err(_) => None
    Ok(nal) =>
      Some({
        data,
        size_bits,
        raw_size: consumed,
        skipped_bytes_pos: skipped_pos,
        nal_type: nal.nal_type,
        ref_idc: nal.ref_idc,
        temporal_id: nal.temporal_id,
        nuh_layer_id: nal.nuh_layer_id,
      })
  }
}

///|
/// `find_next_start_code`, returning the index just past the `00 00 01`.
/// `-1` means no start code before the end.
fn find_next_start_code(buf : Bytes, from : Int32) -> Int32 {
  let end = buf.length()
  if from + 3 >= end {
    return -1
  }
  let mut i = 0
  while from + i + 3 < end {
    if buf[from + i] == b'\x00' &&
      buf[from + i + 1] == b'\x00' &&
      buf[from + i + 2] == b'\x01' {
      return from + i + 3
    }
    i = i + 1
  }
  -1
}

///|
/// Annex B splitter: scan for start codes and skip bytes before the first one,
/// matching `ff_h2645_packet_split` with `next_avc = length`.
fn packet_split_annexb(
  buf : Bytes,
  codec : H2645Codec,
) -> Result[H2645Packet, String] {
  let nals : Array[H2645Nal] = []
  let mut pos = 0
  while buf.length() - pos >= 4 {
    let next_pos = find_next_start_code(buf, pos)
    if next_pos < 0 {
      if nals.length() > 0 {
        break
      }
      return Err("EINVAL") // no start code is found
    }
    pos = next_pos
    if pos >= buf.length() {
      // C: bytes_left == 0 → success if we already produced NALs.
      if nals.length() > 0 {
        break
      }
      return Err("EINVAL")
    }
    let src = buf.clamped_view(start=pos, end=buf.length()).to_owned()
    let r = ff_h2645_extract_rbsp(src)
    pos = pos + r.consumed
    match build_nal(r.data, r.consumed, r.skipped_pos, codec) {
      Some(nal) =>
        if h2645_is_hevc(codec) && nal.nuh_layer_id == 63 {
          () // C: continue, the layer is skipped
        } else {
          nals.push(nal)
        }
      None => ()
    }
  }
  Ok({ nals, })
}

///|
/// Length-prefixed (ISO/IEC 14496-15 `avcC`/`hvcC` style) splitter.
/// `nal_length_size` is 1, 2 or 4 in practice; the C does not validate it.
fn packet_split_nalff(
  buf : Bytes,
  nal_length_size : Int32,
  codec : H2645Codec,
) -> Result[H2645Packet, String] {
  if nal_length_size <= 0 || nal_length_size > 4 {
    return Err("EINVAL")
  }
  let nals : Array[H2645Nal] = []
  let mut pos = 0
  while buf.length() - pos >= 4 {
    if pos + nal_length_size > buf.length() {
      return Err("EINVAL")
    }
    let mut nalsize = 0
    for i = 0; i < nal_length_size; i = i + 1 {
      nalsize = (nalsize << 8) | buf[pos + i].to_int()
    }
    pos = pos + nal_length_size
    if nalsize <= 0 || nalsize > buf.length() - pos {
      return Err("EINVAL")
    }
    let src = buf.clamped_view(start=pos, end=pos + nalsize).to_owned()
    let r = ff_h2645_extract_rbsp(src)
    pos = pos + r.consumed
    match build_nal(r.data, r.consumed, r.skipped_pos, codec) {
      Some(nal) =>
        if h2645_is_hevc(codec) && nal.nuh_layer_id == 63 {
          ()
        } else {
          nals.push(nal)
        }
      None => ()
    }
    // A short `consumed` means an embedded start code; skip any bytes left in
    // the declared NAL so the next length field is read at the right place.
    let rest = nalsize - r.consumed
    if rest > 0 {
      pos = pos + rest
    }
  }
  Ok({ nals, })
}

///|
/// `ff_h2645_packet_split`: split one packet into unescaped NAL units.
/// `is_nalff` selects length-prefixed input (MP4/MKV extradata and samples)
/// over Annex B.
pub fn ff_h2645_packet_split(
  buf : Bytes,
  nal_length_size : Int32,
  codec : H2645Codec,
  is_nalff : Bool,
) -> Result[H2645Packet, String] {
  if is_nalff {
    packet_split_nalff(buf, nal_length_size, codec)
  } else {
    packet_split_annexb(buf, codec)
  }
}

///|
/// `ff_h2645_unit_requires_zero_byte` (H.264 §B.1.2 / H.265 §B.2.2): whether
/// the given NAL type needs an extra zero byte when written as Annex B.
pub fn ff_h2645_unit_requires_zero_byte(
  codec : H2645Codec,
  nal_type : Int32,
  nal_unit_index : Int32,
) -> Bool {
  if nal_unit_index == 0 {
    return true
  }
  match codec {
    H264 => nal_type == h264_nal_sps || nal_type == h264_nal_pps
    Hevc =>
      nal_type == hevc_nal_vps ||
      nal_type == hevc_nal_sps ||
      nal_type == hevc_nal_pps
  }
}
