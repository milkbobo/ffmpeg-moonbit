///|
test "AIFF-C G.711 A-law and mu-law exports match FFmpeg" {
  for
    (mulaw, file_md5, pcm_md5) in [
      (
        false, "7997ab075ed83ca57eb47a89b3ae1c79", "5bec30e4af7556edb4e1f202c5a29b76",
      ),
      (
        true, "76dac5f8ad332ed54e1ef234933f784f", "42623ca508920cba7211e67627456b58",
      ),
    ] {
    let wav = wav_muxer_new(22050, 2, 16).unwrap()
    let samples = Array::makei(5207 * 2, i => i * 12289 % 65536 - 32768)
    wav.write_samples(samples[:])
    let data = decode_audio_file(wav.finish()).to_aifc_g711(mulaw~)
    assert_eq(telephony_md5(data), file_md5)
    let track = av_aiff_open(data).unwrap()
    assert_eq(track.sample_count, 5207L)
    assert_eq(track.format.codec, if mulaw { "pcm_mulaw" } else { "pcm_alaw" })
    let pcm = decode_audio_file(data).to_wav_s16()
    let wave = av_wav_open(pcm).unwrap()
    assert_eq(
      telephony_md5(pcm[wave.data_offset.to_int():].to_owned()),
      pcm_md5,
    )
  }
}
