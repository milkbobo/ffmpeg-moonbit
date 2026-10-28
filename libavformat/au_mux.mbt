///|
/// Minimal Sun AU writer for signed big-endian PCM (8/16/24/32-bit),
/// following the encoding tags of FFmpeg's `libavformat/au.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AuMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  data : Array[Byte]
}

///|
fn au_mux_u32be(dst : Array[Byte], v : UInt32) -> Unit {
  dst.push(((v >> 24) & 0xFFU).to_byte())
  dst.push(((v >> 16) & 0xFFU).to_byte())
  dst.push(((v >> 8) & 0xFFU).to_byte())
  dst.push((v & 0xFFU).to_byte())
}

///|
pub fn au_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits~ : Int32 = 16,
) -> Result[AuMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 64 {
    return Err("EINVAL: invalid AU stream parameters")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: AU muxer supports 8/16/24/32-bit PCM")
  }
  Ok({ sample_rate, channels, bits, data: [], })
}

///|
pub fn AuMuxer::write_samples(
  self : AuMuxer,
  samples : ArrayView[Int32],
) -> Unit {
  let bytes = self.bits / 8
  for sample in samples {
    let v = sample.reinterpret_as_uint()
    for i = 0; i < bytes; i = i + 1 {
      self.data.push(((v >> (8 * (bytes - 1 - i))) & 0xFFU).to_byte())
    }
  }
}

///|
pub fn AuMuxer::finish(self : AuMuxer) -> Bytes {
  let out : Array[Byte] = [b'.', b's', b'n', b'd']
  au_mux_u32be(out, 24U) // header size
  au_mux_u32be(out, self.data.length().reinterpret_as_uint())
  let tag : UInt32 = if self.bits == 8 {
    2U
  } else if self.bits == 16 {
    3U
  } else if self.bits == 24 {
    4U
  } else {
    5U
  }
  au_mux_u32be(out, tag)
  au_mux_u32be(out, self.sample_rate.reinterpret_as_uint())
  au_mux_u32be(out, self.channels.reinterpret_as_uint())
  out.append(self.data)
  Bytes::from_array(out)
}
