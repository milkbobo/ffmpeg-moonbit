///|
test "Ogg Vorbis export preserves the presentation count at block boundaries" {
  for count in [1, 1024, 1025, 5203] {
    let wav = wav_muxer_new(32000, 2, 16).unwrap()
    wav.write_samples(Array::makei(count * 2, i => (i % 73 - 36) * 400)[:])
    let input = decode_audio_file(wav.finish())
    let file = input.to_ogg_vorbis()
    let track = av_ogg_vorbis_open(file).unwrap()
    assert_eq(track.total_samples, count.to_int64())
    assert_eq(track.packets[0].granule, 0L)
    assert_eq(track.packets.length(), (count - 1) / 1024 + 2)
    assert_eq(track.comment_header[track.comment_header.length() - 1], 1)
    let decoded = decode_audio_file(file)
    assert_eq(decoded.codec_id(), "vorbis")
    assert_eq(decoded.sample_rate(), 32000)
    assert_eq(decoded.samples()[0].length(), count)
    assert_eq(decoded.samples()[1].length(), count)
  }
}

///|
test "Ogg Vorbis rejects a backward granule on the final page" {
  let file = av_ogg_encode_vorbis(
    [Array::make(1, 0.0), Array::make(1, 0.0)],
    48000,
  ).unwrap()
  let track = av_ogg_vorbis_open(file).unwrap()
  let cut = track.packets[0].pos.to_int()
  let out = file[:cut].to_owned().to_array()
  ogg_mux_page(out, track.serial, 3, 0, 1024L, track.packets[0].data)
  ogg_mux_page(out, track.serial, 4, 4, 512L, track.packets[1].data)
  assert_true(
    av_ogg_vorbis_open(Bytes::from_array(out))
    is Err("ogg: invalid final Vorbis granule"),
  )
}
