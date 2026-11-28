///|
/// Native SoX format from FFmpeg 9.0.2 soxdec.c and soxenc.c.
/// Copyright (c) 2009 Daniel Verkamp. LGPL-2.1-or-later.
fn probe_sox(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 28 &&
    (data[:4] == b".SoX" || data[:4] == b"XoS.") &&
    wav_u32(data[:], 4, false) != 0L &&
    wav_u32(data[:], 24, false) != 0L {
    probe_score_max
  } else {
    0
  }
}

///|
fn sox_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 32 && probe_sox(ProbeData::new(data)) > 0 else {
    return Err("sox: invalid header")
  }
  let be = data[:4] == b"XoS."
  let view = data[:]
  let header_size = wav_u32(view, 4, be)
  let channels = wav_u32(view, 24, be)
  let comment = wav_u32(view, 28, be)
  let start = header_size + 4L
  guard header_size >= 28L + comment &&
    start % 8L == 0L &&
    start < data.length().to_int64() &&
    channels >= 1L &&
    channels <= 65535L else {
    return Err("sox: invalid header extent or channel count")
  }
  let low = wav_u32(view, if be { 20 } else { 16 }, be)
  let high = wav_u32(view, if be { 16 } else { 20 }, be)
  let rate = ((high << 32) | low)
    .reinterpret_as_uint64()
    .reinterpret_as_double()
  guard rate >= 1.0 && rate <= 2147483647.0 else {
    return Err("sox: invalid sample rate")
  }
  let ch = channels.to_int()
  let align = ch * 4
  let payload_size = data.length() - start.to_int()
  guard payload_size % align == 0 else {
    return Err("sox: incomplete PCM frame")
  }
  let codec = if be { "pcm_s32be" } else { "pcm_s32le" }
  Ok(raw_pcm_track(data.length(), start.to_int(), codec, rate.to_int(), ch, 4))
}

///|
/// Write native SoX signed 32-bit PCM in the requested byte order.
pub fn DecodedAudio::to_sox(
  self : DecodedAudio,
  big_endian~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.sample_rate > 0 &&
    self.channels >= 1 &&
    self.channels <= 65535 &&
    !self.samples[0].is_empty() else {
    raise DecodeError("sox: invalid stream parameters or no audio samples")
  }
  let frames = self.samples[0].length()
  let samples = frames.to_int64() * self.channels.to_int64()
  guard samples <= (0x7fffffffL - 32L) / 4L else {
    raise DecodeError("sox: PCM exceeds output buffer limit")
  }
  let out = if big_endian { b"XoS.".to_array() } else { b".SoX".to_array() }
  wav_mux_w32(out, 28U, big_endian)
  let bits = self.sample_rate.to_double().reinterpret_as_uint64()
  if big_endian {
    caf_mux_u64be(out, samples.reinterpret_as_uint64())
    caf_mux_u64be(out, bits)
  } else {
    wav_mux_u64(out, samples)
    wav_mux_u64(out, bits.reinterpret_as_int64())
  }
  wav_mux_w32(out, self.channels.reinterpret_as_uint(), big_endian)
  wav_mux_w32(out, 0U, big_endian)
  for frame in 0..<frames {
    for plane in self.samples {
      wav_mux_w32(
        out,
        playback_pcm_quantize(plane[frame], 32).reinterpret_as_uint(),
        big_endian,
      )
    }
  }
  Bytes::from_array(out)
}
