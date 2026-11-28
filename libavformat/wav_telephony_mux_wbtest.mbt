///|
test "G.722 and G.726 WAV match FFmpeg including the fact count and RIFF padding" {
  for
    (g722, bits, file_md5, pcm_md5) in [
      (
        true, 4, "15d7c1200822fe25f7d525e8f85df78c", "73bad2d50d5a793329ab09d20e27e47b",
      ),
      (
        false, 2, "3f20d98f118486d4655abc5b6457dc45", "a8622374d71132d20f3cdbbfedc52279",
      ),
      (
        false, 3, "85d54c54065c59d6b83e9f254a3a2826", "3b148688a7fcd1c2de6b2c46eb1692ca",
      ),
      (
        false, 4, "0bad985b75a2c5f9576663607663212a", "2f899aa61a6b2b6c08e1a218da3380cf",
      ),
      (
        false, 5, "43a8080206426618882792b81bdc8002", "7edab67605bab50eefbf5e1743e12b9a",
      ),
    ] {
    let source = wav_muxer_new(if g722 { 16000 } else { 8000 }, 1, 16).unwrap()
    let samples = Array::makei(5203, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let audio = decode_audio_file(source.finish())
    let data = if g722 { audio.to_wav_g722() } else { audio.to_wav_g726(bits) }
    assert_eq(telephony_md5(data), file_md5)
    assert_eq(data.length() % 2, 0)
    let track = av_wav_open(data).unwrap()
    assert_eq(track.format.bits_per_sample, bits)
    assert_eq(track.sample_count, 5203L)
    let pcm = decode_audio_file(data).to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
