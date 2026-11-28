///|
/// Write an audio-only HDMV MPEG-TS containing 16- or 24-bit Blu-ray LPCM.
pub fn DecodedAudio::to_ts_bluray_lpcm(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  let channels = self.channels
  let encoder = match
    @libavcodec.BlurayLpcmEncoder::new(
      channels,
      self.sample_rate,
      bits,
      channel_mask=self.channel_mask,
    ) {
    Ok(value) => value
    Err(error) => raise UnsupportedCodec(error)
  }
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("pcm_bluray: no PCM samples") }
  let mux = ts_muxer_new(
    video=false,
    audio_pid=0x1100,
    audio_stream_type=0x80,
    program_registration=b"HDMV",
  )
  let block_size = if bits == 16 { 240 } else { 360 }
  let rate = self.sample_rate.to_int64()
  for start = 0; start < frames; {
    let count = (frames - start).min(block_size)
    let pcm = Array::makei(count * channels, i => {
      let sample = self.samples[i % channels][start + i / channels]
      playback_pcm_quantize(sample, bits)
    })
    let packet = match encoder.encode(pcm[:]) {
      Ok(value) => value
      Err(error) => raise DecodeError(error)
    }
    let pts = (start.to_int64() * 90000L + rate / 2L) / rate
    mux.write_audio(pts, packet)
    continue start + count
  }
  mux.finish()
}
