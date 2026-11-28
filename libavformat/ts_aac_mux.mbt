///|
/// Encode mono or stereo PCM as AAC-LC in an audio-only MPEG-TS.
/// Set `latm=true` to use LOAS/LATM framing instead of ADTS.
///
/// ```mbt check
/// test {
///   let wav = @libavformat.wav_muxer_new(48000, 1, 16).unwrap()
///   wav.write_samples([0][:])
///   let source = @libavformat.decode_audio_file(wav.finish())
///   let stream = @libavformat.MediaFile::open(source.to_ts_aac(latm=true))
///   assert_eq(stream.streams()[0].codec_id, "aac_latm")
/// }
/// ```
pub fn DecodedAudio::to_ts_aac(
  self : DecodedAudio,
  latm~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("MPEG-TS AAC-LC export requires mono or stereo")
  }
  let mux = ts_muxer_new(
    video=false,
    service_type=0x02,
    audio_stream_type=if latm { 0x11 } else { 0x0f },
  )
  let rate = self.sample_rate.to_int64()
  let mut samples = 0L
  let write = fn(packet : Bytes) {
    let pts = @libavutil.av_rescale(samples, 90000L, rate)
    mux.write_audio(pts, packet)
    samples += 1024L
    Ok(())
  }
  if latm {
    let asc = Bytes::from_array(mp4_av_asc(self.sample_rate, self.channels))
    let loas = match LoasAacMuxer::new(asc) {
      Ok(value) => value
      Err(error) => raise DecodeError(error)
    }
    self.encode_aac_lc(payload => loas.write_framed(payload, write))
  } else {
    self.encode_aac_adts(write)
  }
  mux.finish_with_probe_padding()
}
