///|
/// LEGO Mindstorms RSO layout from FFmpeg 9.0.2 rsodec.c and rsoenc.c.
/// Copyright (c) 2010 Rafael Carre. LGPL-2.1-or-later.
fn rso_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 8 && pb_be16(data, 0) == 0x0100U else {
    return Err("rso: invalid header or unsupported codec")
  }
  let rate = pb_be16(data, 4).reinterpret_as_int()
  let size = pb_be16(data, 2).reinterpret_as_int()
  guard rate > 0 && data.length() > 8 && size <= data.length() - 8 else {
    return Err("rso: invalid sample rate or truncated PCM")
  }
  // FFmpeg's muxer saturates the length field for payloads over 65535 bytes.
  let end = if size == 0xffff || size == 0 { data.length() } else { 8 + size }
  Ok(raw_pcm_track(end, 8, "pcm_u8", rate, 1, 1))
}

///|
/// Write mono LEGO Mindstorms RSO with unsigned 8-bit PCM.
pub fn DecodedAudio::to_rso(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 && self.sample_rate > 0 && self.sample_rate <= 65535 else {
    raise UnsupportedCodec("RSO export requires mono audio at 1–65535 Hz")
  }
  let samples = self.samples[0]
  guard !samples.is_empty() && samples.length() <= 0x7fffffff - 8 else {
    raise DecodeError("rso: invalid PCM length")
  }
  let out : Array[Byte] = Array(capacity=8 + samples.length())
  aiff_mux_u16be(out, 0x0100)
  aiff_mux_u16be(out, samples.length().min(65535))
  aiff_mux_u16be(out, self.sample_rate)
  aiff_mux_u16be(out, 0)
  for sample in samples {
    out.push((playback_pcm_quantize(sample, 8) + 128).to_byte())
  }
  Bytes::from_array(out)
}
