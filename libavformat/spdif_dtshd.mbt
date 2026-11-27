///|
/// DTS type IV wrapper from FFmpeg `libavformat/spdifenc.c` (LGPL-2.1-or-later).
let spdif_dtshd_start_code : Bytes = b"\x01\x00\x00\x00\x00\x00\x00\x00\xfe\xfe"

///|
fn spdif_dtshd_core_burst(
  coded : BytesView,
  period : Int32,
  big_endian : Bool,
) -> SpdifBurst? {
  // The 16-bit length inside the payload is big-endian after carrier
  // normalization. Pd can additionally cover up to 15 zero padding bytes.
  guard coded.length() >= 12 && coded[:10] == spdif_dtshd_start_code[:] else {
    return None
  }
  let packet_end = 12 + wav_u16(coded, 10, true)
  guard packet_end <= coded.length() &&
    coded.length() - packet_end <= 15 &&
    coded[packet_end:].iter().all(byte => byte == 0) else {
    return None
  }
  let packet = coded[12:packet_end]
  guard @libavcodec.parse_dca_core_header(packet) is Ok(core) &&
    core.frame_size <= packet.length() else {
    return None
  }
  // An EXSS sync can be aligned to a word boundary after the core.
  let mut next = core.frame_size
  let padding = (packet.length() - next).min(3)
  for _ in 0..<padding {
    if packet[next] != 0 {
      break
    }
    next += 1
  }
  guard next == packet.length() || dts_has_extension(packet[next:]) else {
    return None
  }
  Some({
    codec: "dts",
    sample_rate: core.sample_rate,
    channels: core.channels,
    period,
    samples: core.samples,
    frames: [
      {
        pos: 12L,
        size: core.frame_size,
        pts: 0L,
        duration: core.samples,
        is_keyframe: true,
      },
    ],
    big_endian,
  })
}

///|
fn spdif_dtshd_exss_size(data : BytesView) -> Int32? {
  // Read the two size fields used by FFmpeg's DTS frame parser. The wide
  // header flag expands the header length and the EXSS frame length together.
  guard data.length() >= 10 else { return None }
  let bits = @libavcodec.BitReader::new(data[:10].to_owned())
  bits.skip(42)
  let wide = bits.read1() != 0U
  let header_size = bits.read(if wide { 12 } else { 8 }).reinterpret_as_int() +
    1
  let size = bits.read(if wide { 20 } else { 16 }).reinterpret_as_int() + 1
  if header_size >= 10 && size >= header_size && size <= data.length() {
    Some(size)
  } else {
    None
  }
}

///|
fn spdif_dtshd_subtype(
  rate : Int32,
  core : @libavcodec.DcaCoreHeader,
) -> Int32? {
  let carrier_samples = rate.to_int64() * core.samples.to_int64()
  let core_rate = core.sample_rate.to_int64()
  guard carrier_samples % core_rate == 0L else { return None }
  match carrier_samples / core_rate {
    512L => Some(0)
    1024L => Some(1)
    2048L => Some(2)
    4096L => Some(3)
    8192L => Some(4)
    16384L => Some(5)
    _ => None
  }
}

///|
fn spdif_mux_dtshd(
  data : Bytes,
  rate : Int32,
  big_endian : Bool,
) -> Result[Bytes, String] {
  guard !data.is_empty() else { return Err("spdif: no DTS core frames") }
  let out : Array[Byte] = []
  let mut start = 0
  let mut format = None
  while start < data.length() {
    let view = data[start:]
    guard view is [0x7f, 0xfe, 0x80, 0x01, ..] &&
      @libavcodec.parse_dca_core_header(view) is Ok(core) &&
      core.frame_size <= view.length() else {
      return Err("spdif: expected a complete 16-bit big-endian DTS core")
    }
    let config = (core.sample_rate, core.channels)
    if format is Some(first) && config != first {
      return Err("spdif: changing DTS stream format")
    }
    format = Some(config)
    guard spdif_dtshd_subtype(rate, core) is Some(subtype) else {
      return Err(
        "spdif: DTS carrier rate does not yield a supported burst period",
      )
    }
    let core_end = start + core.frame_size
    let mut end = dts_next_boundary(data[:], core_end)
    while dts_has_extension(data[end:]) {
      guard spdif_dtshd_exss_size(data[end:]) is Some(size) else {
        return Err("spdif: invalid or truncated DTS-HD extension")
      }
      end = dts_next_boundary(data[:], end + size)
    }
    let period = 2048 << subtype
    let packet_capacity = period - 8 - 12
    let packet_end = if end - start <= packet_capacity { end } else { core_end }
    guard packet_end - start <= packet_capacity else {
      return Err("spdif: DTS core exceeds type IV burst capacity")
    }
    let payload = spdif_dtshd_start_code.to_array()
    wav_mux_w16(payload, packet_end - start, true)
    for byte in data[start:packet_end] {
      payload.push(byte)
    }
    match
      spdif_write_burst(
        out,
        Bytes::from_array(payload)[:],
        0x11 | (subtype << 8),
        big_endian~,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    start = end
  }
  Ok(Bytes::from_array(out))
}
