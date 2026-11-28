///|
test "CAF float and G.711 exports match FFmpeg 9.0.2" {
  let wav = wav_muxer_new(32000, 2, 16).unwrap()
  let samples = Array::makei(5203 * 2, i => {
    let n = i / 2
    let value = if i % 2 == 0 { 19 * n + 37 } else { 73 * n + 11 }
    (value % 256 - 128) * 256
  })
  wav.write_samples(samples[:])
  let input = decode_audio_file(wav.finish())
  for
    (codec, hash) in [
      ("pcm_f32le", "607b825f9933a4e031df6d3365754117"),
      ("pcm_f32be", "186acdc819a2d52b37ac66b56716d278"),
      ("pcm_f64le", "48eeb627b42ec2c8fa9cb5ee35ffddc7"),
      ("pcm_f64be", "c9cd00be14e8bfb359b2a17677ec9bab"),
      ("pcm_alaw", "6e463c1c6ae7c0a819d2aa48aef338fd"),
      ("pcm_mulaw", "05153f89768b336d1c0736adefecc987"),
    ] {
    let data = input.to_caf_samples(codec)
    assert_eq(caf_md5(data), hash, msg=codec)
    let audio = decode_audio_file(data)
    assert_eq(audio.codec_id(), codec)
    assert_eq(audio.samples()[0].length(), 5203)
  }
}

///|
test "CAF float64 keeps precision and reads 5.1 from a bitmap or a layout tag" {
  let mask = 0x60fU
  let wav = wav_muxer_new(96000, 6, 16, channel_mask=mask).unwrap()
  wav.write_samples([0, 0, 0, 0, 0, 0][:])
  let input = decode_audio_file(wav.finish())
  let samples = Array::makei(6, ch => {
    let sample = (ch.to_double() + 0.123456789123) / 8.0
    [sample, -sample]
  })
  let audio = { ..input, samples, }
  let data = audio.to_caf_samples("pcm_f64be")
  assert_eq(caf_tag(data, 52), "chan")
  assert_eq(caf_u32be(data, 64), 0x10000U)
  let tagged = data[:64].to_owned() +
    b"\x00\x79\x00\x06\x00\x00\x00\x00" +
    data[72:].to_owned()
  for fixture in [data, tagged] {
    assert_eq(av_caf_open(fixture).unwrap().channel_mask, mask)
    let decoded = decode_audio_file(fixture)
    assert_eq(decoded.samples(), samples)
    let output = av_wav_open(decoded.to_wav_s16()).unwrap()
    assert_eq(output.format.channel_mask, mask)
  }
}
