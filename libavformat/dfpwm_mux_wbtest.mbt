///|
test "DFPWM WAV and Wave64 export match FFmpeg through container alignment" {
  for
    (wave64, rate, offset, count, file_md5, pcm_md5) in [
      (
        false, 32000, 80, 8344, "0c449bfb1704bb6bfb8506410b501027", "d7194dca879a0ad2df7ff177ad9a2c3a",
      ),
      (
        true, 48000, 160, 8384, "29c88138622e6f1ebb58c34575e014e4", "10df2db52edce2247bac8fad02515061",
      ),
    ] {
    let source = wav_muxer_new(rate, 1, 16).unwrap()
    let samples = Array::makei(8340, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let data = decode_audio_file(source.finish()).to_wav_dfpwm(wave64~)
    assert_eq(telephony_md5(data), file_md5)
    let track = if wave64 {
      av_w64_open(data).unwrap()
    } else {
      av_wav_open(data).unwrap()
    }
    assert_eq(track.format.codec, "dfpwm")
    assert_eq(track.format.sample_rate, rate)
    assert_eq(track.format.byte_rate, rate / 8)
    assert_eq(track.data_offset, offset.to_int64())
    let audio = decode_audio_file(data)
    assert_eq(audio.samples()[0].length(), count)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
