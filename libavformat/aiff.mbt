///|
/// AIFF/AIFC demuxer, ported from FFmpeg 9.0.2 `libavformat/aiffdec.c` and
/// `aiff.c`: `FORM`/`COMM`/`SSND`, 80-bit extended sample rates, and
/// block-aligned PCM and Apple IMA4 packets.
///
/// Scope: AIFF PCM (8/16/24/32-bit big-endian), AIFC `NONE`/`twos` (big-endian
/// PCM), `sowt` (little-endian PCM), and `ima4` (`adpcm_ima_qt`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AiffFormat {
  /// FFmpeg codec name: `pcm_s8`, `pcm_s16be`, `pcm_s24be`, `pcm_s32be`
  /// (or `*le` for `sowt`), or `adpcm_ima_qt` for Apple IMA4.
  codec : String
  channels : Int32
  sample_rate : Int32
  /// Sample size in the COMM chunk (not the compressed IMA4 block size).
  bits : Int32
  block_align : Int32
}

///|
/// One demuxed packet, positioned in the container file.
pub struct AiffPacket {
  pos : Int64
  size : Int32
  /// Timestamp and duration are in samples per channel.
  pts : Int64
  duration : Int32
}

///|
pub struct AiffDemux {
  format : AiffFormat
  data_offset : Int64
  /// Number of bytes covered by the packets.
  data_size : Int64
  /// IMA4 uses the COMM block count times 64, even if the SSND size differs.
  /// PCM uses the COMM sample count bounded by the available complete frames.
  sample_count : Int64
  packets : Array[AiffPacket]
}

///|
fn aiff_u16be(data : Bytes, off : Int32) -> Int32 {
  (data[off].to_int() << 8) | data[off + 1].to_int()
}

///|
fn aiff_u32be(data : Bytes, off : Int32) -> UInt32 {
  (data[off].to_uint() << 24) |
  (data[off + 1].to_uint() << 16) |
  (data[off + 2].to_uint() << 8) |
  data[off + 3].to_uint()
}

///|
fn aiff_tag_string(data : Bytes, off : Int32) -> String {
  let out = StringBuilder()
  for i = 0; i < 4; i = i + 1 {
    out.write_char(data[off + i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// `2^e` for the exponent range used by 80-bit extended floats.
fn aiff_pow2(e : Int32) -> Double {
  let mut v = 1.0
  if e >= 0 {
    for _ in 0..<e {
      v = v * 2.0
    }
  } else {
    for _ in 0..<-e {
      v = v / 2.0
    }
  }
  v
}

///|
/// Decode the 80-bit IEEE 754 extended sample rate (`av_int2double`-style).
fn aiff_ext_to_int(data : Bytes, off : Int32) -> Int32 {
  let exp = aiff_u16be(data, off) & 0x7FFF
  let hi = aiff_u32be(data, off + 2)
  let lo = aiff_u32be(data, off + 6)
  if exp == 0 && hi == 0U && lo == 0U {
    return 0
  }
  let mant = hi.to_double() * 4294967296.0 + lo.to_double()
  let scale = aiff_pow2(exp - 16383 - 63)
  (mant * scale + 0.5).to_int()
}

///|
/// Iterate chunks of a `FORM` body. Returns `(id, payload_off, payload_size)`.
fn aiff_chunks(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> Array[(String, Int32, Int32)] {
  let out : Array[(String, Int32, Int32)] = []
  let mut pos = start
  while pos <= end - 8 {
    let id = aiff_tag_string(data, pos)
    let size = aiff_u32be(data, pos + 4).reinterpret_as_int()
    let payload = pos + 8
    if size < 0 || size > end - payload {
      break
    }
    out.push((id, payload, size))
    pos = payload + size
    if (size & 1) != 0 {
      if pos == end {
        break
      }
      pos += 1
    }
  }
  out
}

///|
fn aiff_chunk(
  chunks : Array[(String, Int32, Int32)],
  id : String,
) -> (Int32, Int32)? {
  for chunk in chunks {
    if chunk.0 == id {
      return Some((chunk.1, chunk.2))
    }
  }
  None
}

///|
/// Parse an AIFF/AIFC file into a stream description and packets.
pub fn av_aiff_open(data : Bytes) -> Result[AiffDemux, String] {
  if data.length() < 12 ||
    data[0] != b'F' ||
    data[1] != b'O' ||
    data[2] != b'R' ||
    data[3] != b'M' {
    return Err("aiff: missing FORM header")
  }
  let form_type = aiff_tag_string(data, 8)
  if form_type != "AIFF" && form_type != "AIFC" {
    return Err("aiff: unsupported form type \{form_type}")
  }
  let form_size = aiff_u32be(data, 4).to_int64()
  if form_size < 4L {
    return Err("aiff: FORM chunk too short")
  }
  let form_end = (form_size + 8L).min(data.length().to_int64()).to_int()
  let chunks = aiff_chunks(data, 12, form_end)
  let (comm_off, comm_size) = match aiff_chunk(chunks, "COMM") {
    Some(v) => v
    None => return Err("aiff: missing COMM chunk")
  }
  if comm_size < 18 {
    return Err("aiff: COMM chunk too short")
  }
  let channels = aiff_u16be(data, comm_off)
  let num_frames = aiff_u32be(data, comm_off + 2).to_int64()
  let bits = aiff_u16be(data, comm_off + 6)
  let sample_rate = aiff_ext_to_int(data, comm_off + 8)
  if channels < 1 || channels > 32 {
    return Err("aiff: invalid channel count")
  }
  if sample_rate <= 0 {
    return Err("aiff: invalid sample rate")
  }
  let compression = if form_type == "AIFC" {
    if comm_size < 22 {
      return Err("aiff: AIFC COMM chunk too short")
    }
    match aiff_tag_string(data, comm_off + 18) {
      ("ima4" | "sowt" | "NONE" | "twos") as tag => tag
      tag => return Err("aiff: unsupported AIFC compression \{tag}")
    }
  } else {
    "NONE"
  }
  let ima4 = compression == "ima4"
  if !ima4 && bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("aiff: unsupported sample size \{bits}")
  }
  let (ssnd_off, ssnd_size) = match aiff_chunk(chunks, "SSND") {
    Some(v) => v
    None => return Err("aiff: missing SSND chunk")
  }
  if ssnd_size < 8 {
    return Err("aiff: SSND chunk too short")
  }
  let offset = aiff_u32be(data, ssnd_off).to_int64()
  let ssnd_payload_size = ssnd_size - 8
  if offset > ssnd_payload_size.to_int64() {
    return Err("aiff: invalid SSND offset")
  }
  let data_offset = ssnd_off + 8 + offset.to_int()
  let block_align = if ima4 { 34 * channels } else { channels * (bits / 8) }
  let block_duration = if ima4 { 64 } else { 1 }
  let available_bytes = ssnd_payload_size - offset.to_int()
  let available_blocks = (available_bytes / block_align).to_int64()
  let sample_count = if ima4 {
    num_frames * block_duration.to_int64()
  } else {
    num_frames.min(available_blocks)
  }
  // Unlike FFmpeg's zero-duration tail packets, expose only complete blocks.
  let packet_blocks = if ima4 { available_blocks } else { sample_count }
  let data_size = packet_blocks * block_align.to_int64()
  let codec = if ima4 {
    "adpcm_ima_qt"
  } else if bits == 8 {
    "pcm_s8"
  } else if compression == "sowt" {
    if bits == 16 {
      "pcm_s16le"
    } else if bits == 24 {
      "pcm_s24le"
    } else {
      "pcm_s32le"
    }
  } else if bits == 16 {
    "pcm_s16be"
  } else if bits == 24 {
    "pcm_s24be"
  } else {
    "pcm_s32be"
  }
  let packet_size = if ima4 {
    block_align
  } else {
    4096 / block_align * block_align
  }
  let packets : Array[AiffPacket] = []
  let mut pos : Int64 = data_offset.to_int64()
  let mut left : Int64 = data_size
  let mut pts = 0L
  while left > 0L {
    let size = if left < packet_size.to_int64() {
      left.to_int()
    } else {
      packet_size
    }
    let duration = size / block_align * block_duration
    packets.push({ pos, size, pts, duration, })
    pos = pos + size.to_int64()
    pts = pts + duration.to_int64()
    left = left - size.to_int64()
  }
  Ok({
    format: { codec, channels, sample_rate, bits, block_align, },
    data_offset: data_offset.to_int64(),
    data_size,
    sample_count,
    packets,
  })
}
