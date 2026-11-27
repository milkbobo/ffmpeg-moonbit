///|
test "DFPWM encodes and decodes FFmpeg's short PCM reference" {
  let input = b"\x80\x87\x8f\x96\x9e\xa5\xac\xb2\xb8\xbd\xc2\xc6\xca\xcd\xcf\xd1\xd2\xd2\xd2"
  let encoded = b"\xfe\xff\x07"
  let expected = b"\x7f\x80\x81\x82\x83\x84\x85\x86\x88\x8a\x8c\x8e\x90\x92\x94\x96\x98\x9a\x9c\x9b\x98\x94\x90\x8c"
  assert_eq(@libavcodec.encode_dfpwm(input[:]), encoded)
  let dec = @libavcodec.DfpwmDecoder::new()
  assert_eq(dec.decode(encoded[:1]), expected[:8].to_owned())
  assert_eq(dec.decode(encoded[1:]), expected[8:].to_owned())
  let wav = b"RIFFL\x00\x00\x00WAVEfmt (\x00\x00\x00\xfe\xff\x01\x00\x00\x7d\x00\x00\x80\x3e\x00\x00\x01\x00\x01\x00\x16\x00\x01\x00\x04\x00\x00\x00\x3a\xc1\xfa\x38\x81\x1d\x43\x61\xa4\x0d\xce\x53\xca\x60\x7c\xd1fact\x04\x00\x00\x00\x13\x00\x00\x00data\x03\x00\x00\x00\xfe\xff\x07\x00"
  let audio = decode_audio_file(wav)
  assert_eq(audio.codec_id(), "dfpwm")
  assert_eq(audio.sample_rate(), 32000)
  let expected_pcm = Array::makei(expected.length(), i => {
    (expected[i].to_int() - 128).to_double() / 128.0
  })
  assert_eq(audio.samples()[0], expected_pcm)
}

///|
test "raw DFPWM keeps timestamps and decoder state across packets" {
  let raw = Bytes::makei(1251, i => ((i * 17) ^ (i >> 2)).to_byte())
  let media = MediaFile::open(raw, filename="clip.dfpwm")
  assert_eq(media.format_name(), "dfpwm")
  let first = media.next_packet().unwrap()
  let second = media.next_packet().unwrap()
  assert_eq(first.data.length(), 512)
  assert_eq(second.pts, 4096L)
  let audio = decode_audio_file(raw, filename="clip.dfpwm")
  let expected = @libavcodec.DfpwmDecoder::new().decode(raw[:])
  assert_eq(audio.sample_rate(), 48000)
  assert_eq(audio.samples()[0].length(), 10008)
  for i in 0..<expected.length() {
    assert_eq(
      audio.samples()[0][i],
      (expected[i].to_int() - 128).to_double() / 128.0,
    )
  }
}
