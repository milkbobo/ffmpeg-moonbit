///|
/// SMPTE 302M header and unpacking, following FFmpeg s302m.c.
/// Copyright Laurent Aimar (2008) and Baptiste Coudurier (2009).
/// LGPL-2.1-or-later.
pub struct S302mHeader {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  samples : Int32
}

///|
/// Parse a complete SMPTE 302M packet. Sample counts are per channel.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.parse_s302m_header(b"") is Err(_))
/// }
/// ```
pub fn parse_s302m_header(data : Bytes) -> Result[S302mHeader, String] {
  if data.length() <= 4 {
    return Err("s302m: truncated packet")
  }
  let size = (data[0].to_int() << 8) | data[1].to_int()
  if size != data.length() - 4 {
    return Err("s302m: incorrect payload length")
  }
  let channels = (data[2].to_int() >> 6) * 2 + 2
  let bits = 16 + ((data[3].to_int() >> 4) & 3) * 4
  if bits > 24 {
    return Err("s302m: unsupported sample depth")
  }
  let align = channels * (bits + 4) / 8
  if size % align != 0 {
    return Err("s302m: incomplete sample frame")
  }
  Ok({ sample_rate: 48000, channels, bits, samples: size / align, })
}

///|
fn s302m_has_non_pcm_burst(samples : Array[Int32], bits : Int32) -> Bool {
  let (pa, pb) = match bits {
    16 => (0xf8720000U, 0x4e1f0000U)
    20 => (0x6f872000U, 0x54e1f000U)
    _ => (0x96f87200U, 0xa54e1f00U)
  }
  // Like FFmpeg, search for the stereo preamble after leading zero pairs.
  for i = 0; i < samples.length() - 6; i = i + 2 {
    if samples[i] != 0 ||
      samples[i + 1] != 0 ||
      samples[i + 2] != 0 ||
      samples[i + 3] != 0 {
      break
    }
    if samples[i + 4].reinterpret_as_uint() == pa &&
      samples[i + 5].reinterpret_as_uint() == pb {
      return true
    }
  }
  false
}

///|
/// Unpack PCM channel pairs to interleaved, left-aligned signed 32-bit
/// samples. Stereo non-PCM bursts detected by the reference check are errors.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.decode_s302m_pcm(b"") is Err(_))
/// }
/// ```
pub fn decode_s302m_pcm(
  data : Bytes,
) -> Result[(S302mHeader, Array[Int32]), String] {
  let header = match parse_s302m_header(data) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let bits = header.bits
  let stride = (bits + 4) / 4
  let mask = (1UL << bits) - 1UL
  let shift = 32 - bits
  let pcm = Array(capacity=header.samples * header.channels)
  for pos = 4; pos < data.length(); pos = pos + stride {
    // Reverse each transmitted byte, then read the PCM words as little-endian
    // bitfields. Four auxiliary bits follow each sample in the pair.
    let mut pair = 0UL
    for i in 0..<stride {
      let byte = reverse_byte_bits[data[pos + i].to_int()].to_uint64()
      pair = pair | (byte << (8 * i))
    }
    pcm.push((pair & mask).to_int() << shift)
    pcm.push(((pair >> (bits + 4)) & mask).to_int() << shift)
  }
  if header.channels == 2 && s302m_has_non_pcm_burst(pcm, bits) {
    return Err("s302m: unsupported non-PCM burst")
  }
  Ok((header, pcm))
}
