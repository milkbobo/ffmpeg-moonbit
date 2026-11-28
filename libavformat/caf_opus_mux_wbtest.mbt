///|
test "CAF opus export keeps presentation length across encoder block boundaries" {
  for
    (channels, rate, count) in [
      (1, 48000, 1),
      (2, 48000, 960),
      (1, 32000, 5203),
    ] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let input = decode_audio_file(wav.finish())
    let expected = input.resample_to(48000).samples()[0].length()
    let encoded = input.to_caf_opus()
    let track = av_caf_open(encoded).unwrap()
    assert_eq(track.priming, 120)
    assert_eq(track.sample_count, expected.to_int64())
    assert_eq(track.packets[0].pts, -120L)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.codec_id(), "opus")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), 48000)
    for plane in decoded.samples() {
      assert_eq(plane.length(), expected)
    }
  }
}

///|
test "CAF opus remux checks mixed packet durations and can trim the final packet" {
  // CELT TOCs for a silent 10 ms frame and a silent 20 ms frame.
  let packets = [b"\xf0", b"\xf8", b"\xf8"]
  let encoded = av_caf_mux_opus(packets, 1, priming=120, valid_frames=1000L).unwrap()
  let track = av_caf_open(encoded).unwrap()
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[0].duration, 480)
  assert_eq(track.packets[1].pts, 360L)
  assert_eq(track.packets[1].duration, 640)
  let start = track.data_offset.to_int()
  assert_eq(encoded[start:], b"\xf0\xf8")
  assert_eq(decode_audio_file(encoded).samples()[0].length(), 1000)
  let broken = encoded.to_array()
  broken[start] = 0xf8
  assert_true(
    av_caf_open(Bytes::from_array(broken))
    is Err("caf: Opus packet duration does not match its description"),
  )
}
