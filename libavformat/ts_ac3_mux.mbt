///|
/// Remux an AC-3 elementary stream as ATSC AC-3 in audio-only MPEG-TS.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_ts_mux_ac3(b"") is Err(_))
/// }
/// ```
pub fn av_ts_mux_ac3(data : Bytes) -> Result[Bytes, String] {
  let track = match ac3_open(data, fixed_format=true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard track.codec == "ac3" else {
    return Err("mpegts: expected AC-3 syncframes")
  }
  let mux = ts_muxer_new(
    video=false,
    service_type=0x02,
    audio_stream_type=0x81,
    audio_registration=b"AC-3",
  )
  let rate = track.sample_rate.to_int64()
  let mut end = track.id3v2_size
  for frame in track.frames {
    guard frame.pos == end.to_int64() else {
      return Err("mpegts: AC-3 syncframes must be contiguous")
    }
    let next = end + frame.size
    let pts = @libavutil.av_rescale(frame.pts, 90000L, rate)
    mux.write_audio(pts, data[end:next].to_owned())
    end = next
  }
  guard end == data.length() else {
    return Err("mpegts: incomplete AC-3 stream")
  }
  Ok(mux.finish_with_probe_padding())
}

///|
/// Encode PCM as AC-3 in audio-only MPEG-TS at the source sample rate.
///
/// ```mbt check
/// test {
///   let wav = @libavformat.wav_muxer_new(48000, 1, 16).unwrap()
///   wav.write_samples([0][:])
///   let source = @libavformat.decode_audio_file(wav.finish())
///   let audio = @libavformat.decode_audio_file(source.to_ts_ac3())
///   assert_eq(audio.sample_rate(), 48000)
/// }
/// ```
pub fn DecodedAudio::to_ts_ac3(self : DecodedAudio) -> Bytes raise MediaError {
  match av_ts_mux_ac3(self.to_ac3()) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
