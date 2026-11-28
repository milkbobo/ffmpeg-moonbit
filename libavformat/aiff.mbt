///|
/// AIFF/AIFC demuxer, ported from FFmpeg 9.0.2 `libavformat/aiffdec.c` and
/// `aiff.c`: `FORM`/`COMM`/`SSND`, 80-bit extended sample rates, and
/// block-aligned PCM, Apple IMA4, and MACE packets.
///
/// Scope: AIFF PCM (8/16/24/32-bit big-endian), AIFC `NONE`/`twos` (big-endian
/// PCM), `sowt` (little-endian PCM), `raw `, `in24`, `in32`, big-endian
/// float PCM, G.711, Apple IMA4, MACE, GSM, G.722, G.726LE, SDX2, CBD2 and ADP4.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AiffFormat {
  /// FFmpeg codec name, such as `pcm_s16be`, `pcm_mulaw` or `adpcm_ima_qt`.
  codec : String
  channels : Int32
  sample_rate : Int32
  /// Sample size in COMM, or the coded width for G.726LE.
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
  /// Block codecs use the COMM block count times the samples per block.
  /// Westwood IMA and G.726LE derive the sample count from SSND.
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
      "ima4"
      | "MAC3"
      | "MAC6"
      | "sowt"
      | "NONE"
      | "twos"
      | "raw "
      | "in24"
      | "in32"
      | "alaw"
      | "ulaw"
      | "fl32"
      | "fl64"
      | "GSM "
      | "G722"
      | "G726"
      | "SDX2"
      | "CBD2"
      | "ADP4" as tag => tag
      tag => return Err("aiff: unsupported AIFC compression \{tag}")
    }
  } else {
    "NONE"
  }
  let ima4 = compression == "ima4"
  let g726 = compression == "G726"
  let gsm = compression == "GSM "
  let mace = compression == "MAC3" || compression == "MAC6"
  if mace && channels > 2 {
    return Err("aiff: invalid MACE channel count")
  }
  if (compression == "SDX2" || compression == "CBD2" || compression == "ADP4") &&
    channels > 2 {
    return Err("aiff: expected one or two channels for \{compression}")
  }
  if (gsm || compression == "G722" || g726) && channels != 1 {
    return Err("aiff: expected mono \{compression.trim()}")
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
  let (codec, bytes_per_channel, block_duration) = match compression {
    "ima4" => ("adpcm_ima_qt", 34, 64)
    "MAC3" => ("mace3", 2, 6)
    "MAC6" => ("mace6", 1, 6)
    "GSM " => ("gsm", 33, 160)
    "G722" => ("adpcm_g722", 1, 2)
    "G726" => ("adpcm_g726le", 5, 8)
    "raw " => ("pcm_u8", 1, 1)
    "in24" => ("pcm_s24be", 3, 1)
    "in32" => ("pcm_s32be", 4, 1)
    "SDX2" => ("sdx2_dpcm", 1, 1)
    "CBD2" => ("cbd2_dpcm", 1, 1)
    "ADP4" => ("adpcm_ima_ws", 1, 2)
    "alaw" | "ulaw" => (mov_codec_name(compression, ""), 1, 1)
    "fl32" => ("pcm_f32be", 4, 1)
    "fl64" => ("pcm_f64be", 8, 1)
    _ => {
      let suffix = if compression == "sowt" { "le" } else { "be" }
      match bits {
        8 => ("pcm_s8", 1, 1)
        16 | 24 | 32 => ("pcm_s\{bits}\{suffix}", bits / 8, 1)
        _ => return Err("aiff: unsupported sample size \{bits}")
      }
    }
  }
  let block_align = channels * bytes_per_channel
  let available_bytes = ssnd_payload_size - offset.to_int()
  let available_blocks = (available_bytes / block_align).to_int64()
  if gsm {
    guard available_bytes % block_align == 0 else {
      return Err("aiff: incomplete GSM block")
    }
    for block in 0..<available_blocks.to_int() {
      if (data[data_offset + block * block_align].to_int() & 0xf0) != 0xd0 {
        return Err("aiff: missing GSM frame magic")
      }
    }
  }
  let sample_count = if g726 {
    // The G726 tag fixes 5-bit little-endian codewords. COMM counts coded
    // blocks, so derive the decoded length from complete codewords.
    available_bytes.to_int64() * 8L / 5L
  } else if compression == "ADP4" {
    // The FFmpeg muxer can write a COMM count based on its encoder alignment,
    // rather than the channel-byte groups used by the decoder.
    available_blocks * block_duration.to_int64()
  } else if gsm {
    // Complete GSM blocks in SSND determine the playable sample count.
    available_blocks * block_duration.to_int64()
  } else if block_duration > 1 {
    num_frames * block_duration.to_int64()
  } else {
    num_frames.min(available_blocks)
  }
  // Unlike FFmpeg's zero-duration tail packets, expose only complete blocks.
  let packet_blocks = if block_duration > 1 {
    available_blocks
  } else {
    sample_count
  }
  // Use five-byte groups between packets, retaining complete codewords
  // in the final partial group as well.
  let data_size = if g726 {
    available_bytes.to_int64()
  } else {
    packet_blocks * block_align.to_int64()
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
    let duration = if g726 {
      size * 8 / 5
    } else {
      size / block_align * block_duration
    }
    packets.push({ pos, size, pts, duration, })
    pos = pos + size.to_int64()
    pts = pts + duration.to_int64()
    left = left - size.to_int64()
  }
  Ok({
    format: {
      codec,
      channels,
      sample_rate,
      bits: if g726 {
        5
      } else {
        bits
      },
      block_align,
    },
    data_offset: data_offset.to_int64(),
    data_size,
    sample_count,
    packets,
  })
}
