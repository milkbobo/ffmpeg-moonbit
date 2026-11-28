///|
test "AIFF-C ADP4 matches FFmpeg and preserves the final encoded sample pairs" {
  for
    (channels, file_md5, pcm_md5) in [
      (
        1, "a0ed733742c9f790ba504ecfd7428ffc", "384d60d384599b8da19d0f5f5f42c691",
      ),
      (
        2, "bdf11ceed70e98b675ddd8b2000cb9b3", "45eaf7d55d38935385cadf65e8695d45",
      ),
    ] {
    let src = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    src.write_samples(samples[:])
    let data = decode_audio_file(src.finish()).to_aifc_adp4()
    assert_eq(telephony_md5(data), file_md5)
    assert_eq(data.length() % 2, 0)
    let track = av_aiff_open(data).unwrap()
    assert_eq(track.format.codec, "adpcm_ima_ws")
    assert_eq(track.sample_count, 8346L)
    let pcm = decode_audio_file(data).to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
