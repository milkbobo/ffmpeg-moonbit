///|
/// Write a single-octave Amiga voice with signed 8-bit or 16-bit planar PCM.
pub fn DecodedAudio::to_svx(
  self : DecodedAudio,
  bits~ : Int32 = 8,
) -> Bytes raise MediaError {
  guard bits == 8 || bits == 16 else {
    raise UnsupportedCodec("SVX export requires 8 or 16 bits per sample")
  }
  guard (self.channels == 1 || self.channels == 2) &&
    self.sample_rate > 0 &&
    self.sample_rate <= 65535 else {
    raise UnsupportedCodec("SVX export requires mono or stereo at 1–65535 Hz")
  }
  let frames = self.samples[0].length()
  let body_size = frames.to_int64() *
    self.channels.to_int64() *
    (bits / 8).to_int64()
  let pad = body_size & 1L
  let header_size = if self.channels == 2 { 60 } else { 48 }
  guard frames > 0 && body_size + pad <= (0x7fffffff - header_size).to_int64() else {
    raise DecodeError("svx: invalid PCM length")
  }
  let size = body_size.to_int()
  let total = header_size + size + pad.to_int()
  let out : Array[Byte] = Array(capacity=total)
  wav_mux_tag(out, "FORM")
  aiff_mux_u32be(out, (total - 8).reinterpret_as_uint())
  wav_mux_tag(out, if bits == 8 { "8SVX" } else { "16SV" })
  wav_mux_tag(out, "VHDR")
  aiff_mux_u32be(out, 20U)
  aiff_mux_u32be(out, frames.reinterpret_as_uint())
  aiff_mux_u32be(out, 0U) // repeat samples
  aiff_mux_u32be(out, 0U) // samples per cycle
  aiff_mux_u16be(out, self.sample_rate)
  out.append([1, 0]) // one octave, uncompressed
  aiff_mux_u32be(out, 0x10000U) // unity volume
  if self.channels == 2 {
    wav_mux_tag(out, "CHAN")
    aiff_mux_u32be(out, 4U)
    aiff_mux_u32be(out, 6U) // left and right
  }
  wav_mux_tag(out, "BODY")
  aiff_mux_u32be(out, size.reinterpret_as_uint())
  for plane in self.samples {
    for sample in plane {
      let pcm = playback_pcm_quantize(sample, bits)
      if bits == 8 {
        out.push(pcm.to_byte())
      } else {
        aiff_mux_u16be(out, pcm)
      }
    }
  }
  if pad != 0L {
    out.push(0)
  }
  Bytes::from_array(out)
}
