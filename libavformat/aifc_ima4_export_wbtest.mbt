///|
test "AIFF-C IMA4 export matches FFmpeg including the padded final block" {
  for
    (channels, container_md5, pcm_md5) in [
      (
        1, "5990b8da3172d842cc959f766a9abbbc", "8378afef205ee9cece9b81afa568f739",
      ),
      (
        2, "15f5c9caf59f7464a5a4b645bab5477a", "4a33b2c4d253603f556b04ac0b2bda58",
      ),
    ] {
    let source = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let data = decode_audio_file(source.finish()).to_aifc_ima4()
    assert_eq(telephony_md5(data), container_md5)
    let track = av_aiff_open(data).unwrap()
    assert_eq(track.format.codec, "adpcm_ima_qt")
    assert_eq(track.format.block_align, channels * 34)
    assert_eq(track.packets.length(), 131)
    assert_eq(track.packets[130].pts, 8320L)
    assert_eq(track.sample_count, 8384L)
    let audio = decode_audio_file(data)
    assert_eq(audio.samples()[0].length(), 8384)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}

///|
test "CAF IMA4 export matches FFmpeg with mono and stereo channel layouts" {
  for
    (channels, container_md5, pcm_md5) in [
      (
        1, "48bc4f58f0ad328f03606dac50301232", "4e29e129835d07b17c4b253e27cfe6ee",
      ),
      (
        2, "2afed749c7ff929a167050c20b47e6cc", "24def114857c61fa22405fc466d1c347",
      ),
    ] {
    let source = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    source.write_samples(samples[:])
    let data = decode_audio_file(source.finish()).to_caf_ima4()
    assert_eq(telephony_md5(data), container_md5)
    let track = av_caf_open(data).unwrap()
    assert_eq(track.format.codec, "adpcm_ima_qt")
    assert_eq(track.format.block_align, channels * 34)
    assert_eq(track.format.frames_per_packet, 64)
    assert_eq(track.sample_count, 8346L)
    assert_eq(track.packets[130].duration, 26)
    let audio = decode_audio_file(data)
    assert_eq(audio.samples()[0].length(), 8346)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
  }
}
