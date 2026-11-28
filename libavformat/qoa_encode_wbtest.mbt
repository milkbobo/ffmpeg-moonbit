///|
test "QOA export matches the reference encoder and preserves a partial last slice" {
  for
    (channels, file_md5, pcm_md5) in [
      (
        1, "c7871a5d954c09101f71876fd2fed4c5", "dfe5f712aa9c382faac2207ea89c093a",
      ),
      (
        2, "22b6aa3855a40ae6a3b6bb9200d6525a", "8dedf5fb1c73f80bcc28f68ec8e4c805",
      ),
    ] {
    let src = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    src.write_samples(samples[:])
    let data = decode_audio_file(src.finish()).to_qoa()
    assert_eq(telephony_md5(data), file_md5)
    let track = av_qoa_open(data).unwrap()
    assert_eq(track.frames.length(), 2)
    assert_eq(track.frames[0].duration, 5120)
    assert_eq((track.frames[1].pts, track.frames[1].duration), (5120L, 3226))
    let audio = decode_audio_file(data)
    assert_eq(audio.samples()[0].length(), 8346)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
