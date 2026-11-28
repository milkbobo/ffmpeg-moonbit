///|
/// SMPTE 302M encoder derived from FFmpeg 9.0.2 s302menc.c.
/// LGPL-2.1-or-later.
pub struct S302mEncoder {
  priv channels : Int32
  priv bits : Int32
  priv mut framing_index : Int32
}

///|
pub fn S302mEncoder::new(
  channels : Int32,
  bits : Int32,
) -> Result[S302mEncoder, String] {
  guard channels == 2 || channels == 4 || channels == 6 || channels == 8 else {
    return Err("s302m: expected 2, 4, 6 or 8 channels")
  }
  guard bits == 16 || bits == 20 || bits == 24 else {
    return Err("s302m: expected 16, 20 or 24 bits per sample")
  }
  Ok({ channels, bits, framing_index: 0, })
}

///|
/// Encode one packet from interleaved, left-aligned signed 32-bit PCM at 48 kHz.
pub fn S302mEncoder::encode(
  self : S302mEncoder,
  samples : ArrayView[Int32],
) -> Result[Bytes, String] {
  let channels = self.channels
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("s302m: expected complete sample frames")
  }
  let bits = self.bits
  let pair_bytes = (bits + 4) / 4
  let pairs = samples.length() / 2
  guard pairs <= 0xffff / pair_bytes else {
    return Err("s302m: packet payload exceeds 65535 bytes")
  }
  let size = pairs * pair_bytes
  let out : Array[Byte] = Array(capacity=size + 4)
  out.append([
    (size >> 8).to_byte(),
    size.to_byte(),
    ((channels - 2) << 5).to_byte(),
    ((bits - 16) << 2).to_byte(),
  ])
  let shift = 32 - bits
  for start = 0; start < samples.length(); start = start + channels {
    let framing = if self.framing_index == 0 { 1UL << (bits + 3) } else { 0UL }
    for i = start; i < start + channels; i = i + 2 {
      let first = (samples[i].reinterpret_as_uint() >> shift).to_uint64()
      let second = (samples[i + 1].reinterpret_as_uint() >> shift).to_uint64()
      let pair = first | framing | (second << (bits + 4))
      for byte in 0..<pair_bytes {
        out.push(
          reverse_byte_bits[((pair >> (8 * byte)) & 255UL).to_int()].to_byte(),
        )
      }
    }
    self.framing_index = (self.framing_index + 1) % 192
  }
  Ok(Bytes::from_array(out))
}
