///|
test "AVR PCM round-trips both signedness modes, depths, and channel counts" {
  for channels in [1, 2] {
    let sample_rate = if channels == 1 { 8000 } else { 32000 }
    let samples = Array::makei(5203 * channels, i => {
      let n = i / channels
      let value = if i % channels == 0 { 19 * n + 37 } else { 73 * n + 11 }
      (value % 256 - 128) * 256
    })
    let wav = wav_muxer_new(sample_rate, channels, 16).unwrap()
    wav.write_samples(samples[:])
    let input = decode_audio_file(wav.finish())
    for
      (bits, signed, codec) in [
        (8, true, "pcm_s8"),
        (8, false, "pcm_u8"),
        (16, true, "pcm_s16be"),
        (16, false, "pcm_u16be"),
      ] {
      let data = input.to_avr(bits~, signed~)
      assert_eq(pb_be32(data, 26), 5203U)
      let track = avr_open(data).unwrap()
      assert_eq(track.frames[0].pos, 128L)
      assert_eq(track.total_samples, 5203L)
      let audio = decode_audio_file(data)
      assert_eq(audio.format_name(), "avr")
      assert_eq(audio.codec_id(), codec)
      assert_eq(audio.channels(), channels)
      assert_eq(audio.sample_rate(), sample_rate)
      assert_eq(audio.samples(), input.samples())
    }
  }
}

///|
test "AVR unsigned 16-bit centers silence and ignores the replay-speed byte" {
  let wav = wav_muxer_new(44100, 1, 16).unwrap()
  wav.write_samples([-32768, -1, 0, 1, 32767][:])
  let input = decode_audio_file(wav.finish())
  let data = input.to_avr(signed=false)
  assert_eq(data[128:], b"\x00\x00\x7f\xff\x80\x00\x80\x01\xff\xff")
  let modified = data.to_array()
  modified[22] = 0xff
  let decoded = decode_audio_file(Bytes::from_array(modified))
  assert_eq(decoded.sample_rate(), 44100)
  assert_eq(decoded.samples(), input.samples())
  assert_true(
    avr_open(data[:data.length() - 1].to_owned())
    is Err("avr: invalid sample rate or incomplete PCM frame"),
  )
}
