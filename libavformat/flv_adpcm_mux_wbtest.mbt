///|
test "Flash ADPCM FLV matches FFmpeg across tags and a padded final block" {
  for
    (channels, file_md5, pcm_md5) in [
      (
        1, "819cdc29796f2ff2ec8ec9dc5d2cdedd", "74d6b018aec82b77b84202887843e633",
      ),
      (
        2, "e071ac3af47c568c2bf85086fdb2f98b", "c213b8d33499a7e3e2eb35c14f754b92",
      ),
    ] {
    let wav = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    wav.write_samples(samples[:])
    let flv = decode_audio_file(wav.finish()).to_flv_adpcm()
    assert_eq(telephony_md5(flv), file_md5)
    let track = av_flv_audio_open(flv).unwrap()
    assert_eq(track.codec, "adpcm_swf")
    assert_eq(track.sample_rate, 22050)
    assert_eq(track.channels, channels)
    assert_eq(track.packets.map(packet => packet.pts), [0L, 186L, 372L])
    let audio = decode_audio_file(flv)
    assert_eq(audio.samples()[0].length(), 12288)
    let pcm = audio.to_wav_s16()
    let wave = av_wav_open(pcm).unwrap()
    assert_eq(
      telephony_md5(pcm[wave.data_offset.to_int():].to_owned()),
      pcm_md5,
    )
  }
}
