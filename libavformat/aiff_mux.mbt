///|
/// Minimal AIFF PCM writer following FFmpeg 9.0.2 `aiffenc.c`: `FORM`/`AIFF`
/// with `COMM` and `SSND`, big-endian samples and the 80-bit extended sample
/// rate. The whole file is built in memory by `finish`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AiffMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  data : Array[Byte]
}

///|
fn aiff_mux_u16be(dst : Array[Byte], v : Int32) -> Unit {
  dst.push(((v >> 8) & 0xFF).to_byte())
  dst.push((v & 0xFF).to_byte())
}

///|
fn aiff_mux_u32be(dst : Array[Byte], v : UInt32) -> Unit {
  dst.push(((v >> 24) & 0xFFU).to_byte())
  dst.push(((v >> 16) & 0xFFU).to_byte())
  dst.push(((v >> 8) & 0xFFU).to_byte())
  dst.push((v & 0xFFU).to_byte())
}

///|
fn aiff_mux_tag(dst : Array[Byte], tag : String) -> Unit {
  for c in tag {
    dst.push(c.to_int().to_byte())
  }
}

///|
/// Encode a positive integer sample rate as an 80-bit extended float.
fn aiff_mux_ext80(rate : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut k = 0
  let mut v = rate
  while v > 1 {
    v = v >> 1
    k = k + 1
  }
  aiff_mux_u16be(out, 16383 + k)
  let mant = rate.to_int64() << (63 - k)
  for i = 0; i < 8; i = i + 1 {
    out.push(((mant >> (56 - 8 * i)) & 0xFFL).to_int().to_byte())
  }
  out
}

///|
/// Create an AIFF writer for 8/16/24/32-bit signed PCM. AIFF stores 8-bit
/// samples signed (unlike WAV).
pub fn aiff_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits~ : Int32 = 16,
) -> Result[AiffMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 32 {
    return Err("EINVAL: invalid AIFF stream parameters")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: AIFF muxer supports 8/16/24/32-bit PCM")
  }
  Ok({ sample_rate, channels, bits, data: [], })
}

///|
pub fn AiffMuxer::write_samples(
  self : AiffMuxer,
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
pub fn AiffMuxer::finish(self : AiffMuxer) -> Bytes {
  let block_align = self.channels * (self.bits / 8)
  let frames = self.data.length() / block_align
  let comm : Array[Byte] = []
  aiff_mux_u16be(comm, self.channels)
  aiff_mux_u32be(comm, frames.reinterpret_as_uint())
  aiff_mux_u16be(comm, self.bits)
  comm.append(aiff_mux_ext80(self.sample_rate))
  let ssnd : Array[Byte] = []
  aiff_mux_u32be(ssnd, 0U)
  aiff_mux_u32be(ssnd, 0U)
  ssnd.append(self.data)
  let out : Array[Byte] = []
  aiff_mux_tag(out, "FORM")
  aiff_mux_u32be(out, 0U) // patched below
  aiff_mux_tag(out, "AIFF")
  aiff_mux_tag(out, "COMM")
  aiff_mux_u32be(out, comm.length().reinterpret_as_uint())
  out.append(comm)
  aiff_mux_tag(out, "SSND")
  aiff_mux_u32be(out, ssnd.length().reinterpret_as_uint())
  out.append(ssnd)
  if (ssnd.length() & 1) != 0 {
    out.push(b'\x00')
  }
  let total = out.length()
  out[4] = (((total - 8) >> 24) & 0xFF).to_byte()
  out[5] = (((total - 8) >> 16) & 0xFF).to_byte()
  out[6] = (((total - 8) >> 8) & 0xFF).to_byte()
  out[7] = ((total - 8) & 0xFF).to_byte()
  Bytes::from_array(out)
}
