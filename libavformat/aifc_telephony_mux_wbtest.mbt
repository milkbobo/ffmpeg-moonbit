///|
test "AIFF-C G.722 and G.726LE match FFmpeg with a short final packet" {
  for
    (g722, rate, size, codec, file_md5, pcm_md5) in [
      (
        true, 16000, 2604, "adpcm_g722", "70fe6cf43257f7de4ad7e3af7c33015d", "94c1c1eeeaa2003445d3b88f316fbf8c",
      ),
      (
        false, 8000, 3255, "adpcm_g726le", "434c7a7d7784a45dd4c09cb2f9e77259", "3915b60092f444e931af41e8df7b0737",
      ),
    ] {
    let source = wav_muxer_new(rate, 1, 16).unwrap()
    let samples = Array::makei(5207, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let audio = decode_audio_file(source.finish())
    let data = if g722 { audio.to_aifc_g722() } else { audio.to_aifc_g726le() }
    assert_eq(telephony_md5(data), file_md5)
    assert_eq(data.length() % 2, 0)
    let track = av_aiff_open(data).unwrap()
    assert_eq(track.format.codec, codec)
    assert_eq(track.format.sample_rate, rate)
    assert_eq(track.data_size, size.to_int64())
    assert_eq(track.sample_count, 5208L)
    let pcm = decode_audio_file(data).to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
