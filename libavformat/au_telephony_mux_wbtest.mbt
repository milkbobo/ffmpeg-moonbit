///|
test "Sun AU exports G.722 and labels each G.726LE width for decoding" {
  for
    (bits, tag, file_md5, pcm_md5) in [
      (
        0, 24U, "33652b83afbc04682373dd6d38411b35", "73bad2d50d5a793329ab09d20e27e47b",
      ),
      (
        2, 0x37323632U, "5370f108d852d0e662d5fd066585a9a4", "a8622374d71132d20f3cdbbfedc52279",
      ),
      (
        3, 25U, "a48204166024797189186960a6d1cdbc", "3b148688a7fcd1c2de6b2c46eb1692ca",
      ),
      (
        4, 23U, "1b63e19f3271a9c97a125d95d1aa6cc7", "2f899aa61a6b2b6c08e1a218da3380cf",
      ),
      (
        5, 26U, "10a9a039103da08a8ee58489ef6bce86", "7edab67605bab50eefbf5e1743e12b9a",
      ),
    ] {
    let rate = if bits == 0 { 16000 } else { 8000 }
    let source = wav_muxer_new(rate, 1, 16).unwrap()
    let samples = Array::makei(5203, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let audio = decode_audio_file(source.finish())
    let au = if bits == 0 {
      audio.to_au_g722()
    } else {
      audio.to_au_g726le(bits)
    }
    assert_eq(telephony_md5(au), file_md5)
    let track = av_au_open(au).unwrap()
    assert_eq(track.data_offset, 32L)
    assert_eq(track.format.codec_tag, tag)
    assert_eq(track.format.sample_rate, rate)
    let pcm = decode_audio_file(au).to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
