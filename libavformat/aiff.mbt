///|
/// AIFF/AIFC demuxer, ported from FFmpeg 9.0.2 `libavformat/aiffdec.c` and
/// `aiff.c`: `FORM`/`COMM`/`SSND`, 80-bit extended sample rates, and
/// block-aligned PCM packets.
///
/// Scope: AIFF PCM (8/16/24/32-bit big-endian) and AIFC `NONE` (big-endian
/// PCM) / `sowt` (little-endian PCM). Compressed AIFC codecs are rejected.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AiffFormat {
  /// `pcm_s8`, `pcm_s16be`, `pcm_s24be`, `pcm_s32be` (or the `*_le` variants
  /// for AIFC `sowt`).
  codec : String
  channels : Int32
  sample_rate : Int32
  bits : Int32
  block_align : Int32
}

///|
/// One demuxed PCM packet, positioned in the container file.
pub struct AiffPacket {
  pos : Int64
  size : Int32
  pts : Int64
  duration : Int32
}

///|
pub struct AiffDemux {
  format : AiffFormat
  data_offset : Int64
  data_size : Int64
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
  while pos + 8 <= end {
    let id = aiff_tag_string(data, pos)
    let size = aiff_u32be(data, pos + 4).reinterpret_as_int()
    if size < 0 || pos + 8 + size > end {
      break
    }
    out.push((id, pos + 8, size))
    pos = pos + 8 + size + (size & 1)
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
/// Parse an AIFF/AIFC file into a stream description and PCM packets.
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
  let chunks = aiff_chunks(data, 12, data.length())
  let (comm_off, comm_size) = match aiff_chunk(chunks, "COMM") {
    Some(v) => v
    None => return Err("aiff: missing COMM chunk")
  }
  if comm_size < 18 {
    return Err("aiff: COMM chunk too short")
  }
  let channels = aiff_u16be(data, comm_off)
  let num_frames = aiff_u32be(data, comm_off + 2).reinterpret_as_int()
  let bits = aiff_u16be(data, comm_off + 6)
  let sample_rate = aiff_ext_to_int(data, comm_off + 8)
  if channels < 1 || channels > 32 {
    return Err("aiff: invalid channel count")
  }
  if sample_rate <= 0 {
    return Err("aiff: invalid sample rate")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("aiff: unsupported sample size \{bits}")
  }
  let mut little_endian = false
  if form_type == "AIFC" {
    if comm_size < 22 {
      return Err("aiff: AIFC COMM chunk too short")
    }
    let compression = aiff_tag_string(data, comm_off + 18)
    if compression == "sowt" {
      little_endian = true
    } else if compression != "NONE" && compression != "twos" {
      return Err("aiff: unsupported AIFC compression \{compression}")
    }
  }
  let (ssnd_off, ssnd_size) = match aiff_chunk(chunks, "SSND") {
    Some(v) => v
    None => return Err("aiff: missing SSND chunk")
  }
  if ssnd_size < 8 {
    return Err("aiff: SSND chunk too short")
  }
  let offset = aiff_u32be(data, ssnd_off).reinterpret_as_int()
  if offset < 0 || offset + 8 > ssnd_size {
    return Err("aiff: invalid SSND offset")
  }
  let data_offset = ssnd_off + 8 + offset
  let bytes_per_sample = bits / 8
  let block_align = channels * bytes_per_sample
  let mut sample_count = num_frames
  let available = (data.length() - data_offset) / block_align
  if sample_count < 0 || sample_count > available {
    sample_count = available
  }
  let data_size : Int64 = sample_count.to_int64() * block_align.to_int64()
  let codec = if bits == 8 {
    "pcm_s8"
  } else if little_endian {
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
  let max_size = 4096 / block_align * block_align
  let packet_size = if max_size > 0 { max_size } else { block_align }
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
    let duration = size / block_align
    packets.push({ pos, size, pts, duration, })
    pos = pos + size.to_int64()
    pts = pts + duration.to_int64()
    left = left - size.to_int64()
  }
  Ok({
    format: { codec, channels, sample_rate, bits, block_align, },
    data_offset: data_offset.to_int64(),
    data_size,
    sample_count: sample_count.to_int64(),
    packets,
  })
}
