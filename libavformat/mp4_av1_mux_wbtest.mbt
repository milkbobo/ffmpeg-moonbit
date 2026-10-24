///|
/// AV1-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
test "mp4 muxer: AV1 samples and av1C round-trip" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  let mux = mp4_av1_muxer_new(64, 48, av1c, timescale=90000).unwrap()
  mux.write_packet(b"\x0A\x0B\x0C", duration=3000, keyframe=true).unwrap()
  mux.write_packet(b"\x0D\x0E", duration=3000, keyframe=false).unwrap()
  mux.write_packet(b"\x0F\x10\x11", duration=3000, keyframe=true).unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  let track = movie.tracks[0]
  assert_eq(track.codec, "av01")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.timescale, 90000U)
  assert_eq(track.extradata.unwrap(), av1c)
  assert_eq(track.samples.length(), 3)
  let sizes : Array[Int32] = [3, 2, 3]
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.size, sizes[i].reinterpret_as_uint())
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i != 1)
  }
}

///|
test "mp4 muxer: invalid AV1 parameters are rejected" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  match mp4_av1_muxer_new(64, 0, av1c) {
    Ok(_) => fail("zero height must fail")
    Err(_) => ()
  }
  let mux = mp4_av1_muxer_new(64, 48, av1c).unwrap()
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty packet must fail")
    Err(_) => ()
  }
}
