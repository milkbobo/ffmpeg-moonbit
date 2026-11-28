///|
test "MP4 AAC-LC export preserves duration and decoded PCM from CAF" {
  for
    (channels, rate, count) in [
      (1, 48000, 1),
      (1, 44100, 1024),
      (2, 32000, 5203),
    ] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let source = decode_audio_file(wav.finish())
    let encoded = source.to_mp4_aac()
    let movie = av_mov_open(encoded).unwrap()
    let track = movie.tracks[0]
    assert_eq(movie.timescale, rate.reinterpret_as_uint())
    assert_eq(track.skip_samples, 1024)
    assert_eq(track.duration, count.to_uint64())
    let last = track.samples[track.samples.length() - 1]
    assert_eq(last.pts + last.duration.to_int64(), count.to_int64())
    let audio = decode_audio_file(encoded)
    assert_eq(audio.codec_id(), "aac")
    assert_eq(audio.channels(), channels)
    assert_eq(audio.sample_rate(), rate)
    for plane in audio.samples() {
      assert_eq(plane.length(), count)
    }
    assert_true(
      audio.samples() == decode_audio_file(source.to_caf_aac()).samples(),
    )
  }
}
