///|
test "Wave64 ADPCM matches FFmpeg blocks and trims only final-block padding" {
  for
    (codec, channels, per, file_md5, pcm_md5) in [
      (
        "adpcm_ima_wav", 1, 2041, "74787dbfb6e0645e48319f4bd9e414db", "b82e183577fb50405642f19d563a1bc7",
      ),
      (
        "adpcm_ms", 1, 2036, "20142160570940064cce43ba5cbdb225", "9f4cf5ac804cb25ef63c084dad711f7d",
      ),
      (
        "adpcm_yamaha", 1, 2048, "61e14636210c9f70986b6ea89801e20d", "7d0eea30eeaaf314065e50f6067cc4f7",
      ),
      (
        "adpcm_ima_wav", 2, 1017, "bff14f604bb2505852f5599cb5adcf70", "c010706da65b9af246b24f6e9b303705",
      ),
      (
        "adpcm_ms", 2, 1012, "30528b59d6481c90dafc9148a5187d19", "3f6c4ba5fd6b9ac932141515029e0b6a",
      ),
      (
        "adpcm_yamaha", 2, 1024, "d70f5b4de0453d0598e06ccdaf0c0e54", "344cf2b336c719b16f77f335416e5541",
      ),
    ] {
    let rate = if channels == 1 { 8000 } else { 32000 }
    let samples = Array::makei(5203 * channels, i => {
      let n = i / channels
      let value = if i % channels == 0 { 19 * n + 37 } else { 73 * n + 11 }
      (value % 256 - 128) * 256
    })
    let whole = av_wav_mux_adpcm(
      samples[:2 * per * channels],
      rate,
      channels,
      codec,
      wave64=true,
    ).unwrap()
    assert_eq(caf_md5(whole), file_md5)
    let data = av_wav_mux_adpcm(samples[:], rate, channels, codec, wave64=true).unwrap()
    let track = av_w64_open(data).unwrap()
    assert_eq(track.sample_count, 5203L)
    let audio = decode_audio_file(data)
    assert_eq(audio.codec_id(), codec)
    assert_eq(audio.samples()[0].length(), 5203)
    let wav = audio.to_wav_s16()
    let info = av_wav_open(wav).unwrap()
    let start = info.data_offset.to_int()
    assert_eq(
      caf_md5(wav[start:start + info.data_size.to_int()].to_owned()),
      pcm_md5,
    )

    let inconsistent = data.to_array()
    let fact = track.data_offset.to_int() - 32
    for i in 0..<8 {
      inconsistent[fact + i] = if i == 0 { 1 } else { 0 }
    }
    let untrimmed = decode_audio_file(Bytes::from_array(inconsistent))
    assert_eq(untrimmed.samples()[0].length(), (5203 + per - 1) / per * per)
  }
}
