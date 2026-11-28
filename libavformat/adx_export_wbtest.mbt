///|
test "CRI ADX export matches FFmpeg including final padding and terminal block" {
  for
    (channels, file_md5, pcm_md5) in [
      (
        1, "100ee178a0e88c06539b86eed0c48687", "7ef8bd8e28df4d7c21f77534d6004d5a",
      ),
      (
        2, "3b695b9566bf42633c666a38cbac5c56", "6c8030eca3f437cafa78318ceb57fb07",
      ),
    ] {
    let source = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let adx = decode_audio_file(source.finish()).to_adx()
    assert_eq(telephony_md5(adx), file_md5)
    let track = av_adx_open(adx).unwrap()
    assert_eq(track.frames.length(), 261)
    assert_eq(track.frames[260].pts, 8320L)
    assert_eq(track.total_samples, 8352L)
    assert_eq(
      adx[adx.length() - 18:adx.length() - 14].to_owned(),
      b"\x80\x01\x00\x0e",
    )
    let audio = decode_audio_file(adx)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.sample_rate(), 22050)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}

///|
test "CRI ADX silence encodes to zero-scale blocks" {
  let source = wav_muxer_new(44100, 2, 16).unwrap()
  source.write_samples(Array::make(64, 0)[:])
  let data = decode_audio_file(source.finish()).to_adx()
  assert_eq(data[36:72].to_owned(), Bytes::make(36, 0))
}
