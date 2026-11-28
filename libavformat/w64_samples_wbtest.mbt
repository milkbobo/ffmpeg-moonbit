///|
test "Wave64 float64 and G.711 exports match FFmpeg without decoding alignment padding" {
  let wav = wav_muxer_new(8000, 1, 16).unwrap()
  let samples = Array::makei(5203, i => ((19 * i + 37) % 256 - 128) * 256)
  wav.write_samples(samples[:])
  let input = decode_audio_file(wav.finish())
  for
    (codec, hash, width) in [
      ("pcm_f64le", "fcc0b1f155af060326ce2444277be65c", 8),
      ("pcm_alaw", "9a94f2a9aa80ca8795e412a169f40af8", 1),
      ("pcm_mulaw", "7bc17ff32f18eaba3143f97bcd0f7258", 1),
    ] {
    let data = input.to_w64_samples(codec)
    assert_eq(caf_md5(data), hash, msg=codec)
    let info = av_w64_open(data).unwrap()
    assert_eq(info.data_size, (5203 * width).to_int64())
    let audio = decode_audio_file(data)
    assert_eq(audio.codec_id(), codec)
    assert_eq(audio.samples()[0].length(), 5203)
  }
}

///|
test "Wave64 float64 preserves precision and float32 drops a final alignment word" {
  let f64 = w64_muxer_new(48000, 1, 64, float=true).unwrap()
  let samples = [0.123456789123, -1.125, 0.49999999999]
  f64.write_float64_samples(samples[:])
  assert_eq(decode_audio_file(f64.finish()).samples(), [samples])

  let f32 = w64_muxer_new(48000, 1, 32, float=true).unwrap()
  f32.write_samples([0x3f000000, 0, -1090519040][:])
  assert_eq(decode_audio_file(f32.finish()).samples(), [[0.5, 0.0, -0.5]])
}
