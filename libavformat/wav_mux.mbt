///|
/// Minimal in-memory WAV/PCM writer following FFmpeg 9.0.2 `wavenc.c`
/// (`wav_write_header`, `wav_write_trailer`) for the PCM sample formats the
/// demuxer already understands.  The payload is accumulated in memory and the
/// RIFF sizes are patched by `finish`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2001 Fabrice Bellard.
/// This port keeps the same license.

///|
pub struct WavMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  data : Array[Byte]
}

///|
/// Create a PCM WAV writer. Only signed 16/24/32-bit samples are written.
pub fn wav_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
) -> Result[WavMuxer, String] {
  if sample_rate <= 0 || channels <= 0 {
    return Err("EINVAL: invalid WAV sample rate or channel count")
  }
  if bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: WAV muxer supports 16/24/32-bit PCM")
  }
  Ok({
    sample_rate,
    channels,
    bits,
    data: [],
  })
}

///|
fn wav_mux_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push((v & 0xFF).to_byte())
  dst.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn wav_mux_u32(dst : Array[Byte], v : UInt32) -> Unit {
  for i in 0..<4 {
    dst.push(((v >> (8 * i)) & 0xFFU).to_byte())
  }
}

///|
fn wav_mux_tag(dst : Array[Byte], tag : String) -> Unit {
  for c in tag {
    dst.push(c.to_int().to_byte())
  }
}

///|
/// Append interleaved samples. Values are written little-endian in the low
/// `bits` bits; callers provide samples already in the PCM range.
pub fn WavMuxer::write_samples(
  self : WavMuxer,
  samples : ArrayView[Int32],
) -> Unit {
  let bytes = self.bits / 8
  for sample in samples {
    let v = sample.reinterpret_as_uint()
    for i in 0..<bytes {
      self.data.push(((v >> (8 * i)) & 0xFFU).to_byte())
    }
  }
}

///|
/// Finish the RIFF/WAVE file. The muxer should not be written to afterwards.
pub fn WavMuxer::finish(self : WavMuxer) -> Bytes {
  let data_size = self.data.length()
  let pad = data_size & 1
  let out : Array[Byte] = []
  let block_align = self.channels * (self.bits / 8)
  let byte_rate = self.sample_rate * block_align
  wav_mux_tag(out, "RIFF")
  wav_mux_u32(out, (36 + data_size + pad).reinterpret_as_uint())
  wav_mux_tag(out, "WAVE")
  wav_mux_tag(out, "fmt ")
  wav_mux_u32(out, 16U)
  wav_mux_u16(out, 1) // WAVE_FORMAT_PCM
  wav_mux_u16(out, self.channels)
  wav_mux_u32(out, self.sample_rate.reinterpret_as_uint())
  wav_mux_u32(out, byte_rate.reinterpret_as_uint())
  wav_mux_u16(out, block_align)
  wav_mux_u16(out, self.bits)
  wav_mux_tag(out, "data")
  wav_mux_u32(out, data_size.reinterpret_as_uint())
  out.append(self.data)
  if pad != 0 {
    out.push(b'\x00')
  }
  Bytes::from_array(out)
}
