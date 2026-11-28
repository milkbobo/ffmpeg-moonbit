///|
/// Write a 48 kHz SMPTE 302M audio-only MPEG-TS with the BSSD registration.
pub fn DecodedAudio::to_ts_s302m(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  guard self.sample_rate == 48000 else {
    raise UnsupportedCodec("SMPTE 302M export requires 48000 Hz")
  }
  let channels = self.channels
  let encoder = match @libavcodec.S302mEncoder::new(channels, bits) {
    Ok(value) => value
    Err(error) => raise UnsupportedCodec(error)
  }
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("s302m: no PCM samples") }
  let mux = ts_muxer_new(
    video=false,
    audio_stream_type=0x06,
    audio_registration=b"BSSD",
  )
  for start = 0; start < frames; {
    let count = (frames - start).min(1024)
    let pcm = Array::makei(count * channels, i => {
      let sample = self.samples[i % channels][start + i / channels]
      playback_pcm_quantize(sample, bits) << (32 - bits)
    })
    let packet = match encoder.encode(pcm[:]) {
      Ok(value) => value
      Err(error) => raise DecodeError(error)
    }
    let pts = (start.to_int64() * 15L + 4L) / 8L
    mux.write_audio(pts, packet)
    continue start + count
  }
  mux.finish()
}
