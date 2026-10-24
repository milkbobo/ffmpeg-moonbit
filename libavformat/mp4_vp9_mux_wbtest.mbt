///|
/// VP9-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
test "mp4 muxer: VP9 samples and vpcC round-trip" {
  // vpcC FullBox: version 1, flags 0, profile 0, level 0, 8-bit 4:2:0,
  // unspecified colour fields, no codec initialization data.
  let vpcc : Bytes = b"\x01\x00\x00\x00\x00\x00\x82\x02\x02\x02\x00\x00"
  let mux = mp4_vp9_muxer_new(64, 48, vpcc, timescale=90000).unwrap()
  mux.write_packet(b"\x82\x00\x01", duration=3000, keyframe=true).unwrap()
  mux.write_packet(b"\x82\x00\x02", duration=3000, keyframe=false).unwrap()
  let bytes = mux.finish()
  let track = av_mov_open(bytes).unwrap().tracks[0]
  assert_eq(track.codec, "vp09")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.samples.length(), 2)
  for i in 0..<2 {
    let sample = track.samples[i]
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i == 0)
  }
}
