///|
test "NIST SPHERE preserves 32-bit PCM in both byte orders" {
  let codes = [0x80000001U, 0x7fffffffU, 0x12345678U, 0x89abcdefU]
  let wav = wav_muxer_new(32000, 2, 32).unwrap()
  wav.write_samples(codes.map(value => value.reinterpret_as_int())[:])
  let input = decode_audio_file(wav.finish())
  for (codec, be) in [("pcm_s32le", false), ("pcm_s32be", true)] {
    let data = input.to_sphere(codec~)
    let track = sphere_open(data).unwrap()
    assert_eq(track.frames[0].pos, 1024L)
    for i in 0..<codes.length() {
      let code = wav_u32(data[:], 1024 + i * 4, be)
      assert_eq(code, codes[i].to_int64())
    }
    let decoded = decode_audio_file(data)
    assert_eq(decoded.format_name(), "nistsphere")
    assert_eq(decoded.codec_id(), codec)
    assert_eq(decoded.sample_rate(), 32000)
    assert_eq(decoded.samples(), input.samples())
    assert_true(
      sphere_open(data[:data.length() - 1].to_owned())
      is Err("sphere: incomplete PCM frame"),
    )
  }
}

///|
test "NIST SPHERE accepts variable header sizes and legacy mu-law byte format" {
  let out : Array[Byte] = []
  wav_mux_tag(
    out, "NIST_1A\n    512\nsample_rate\t-i 8000\nchannel_count -i 1\nsample_sig_bits -i 8\nsample_byte_format -s6 mu-law\nend_head\n",
  )
  for _ in out.length()..<512 {
    out.push(0)
  }
  out.append([0xff, 0x00, 0x80])
  let audio = decode_audio_file(Bytes::from_array(out))
  assert_eq(audio.codec_id(), "pcm_mulaw")
  assert_eq(audio.samples(), [[0.0, -32124.0 / 32768.0, 32124.0 / 32768.0]])
  let encoded = audio.to_sphere(codec="pcm_mulaw")
  assert_eq(encoded[1024:], b"\xff\x00\x80")
}
