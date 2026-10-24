///|
/// WebM/VP9 muxer tests: emitted files are parsed back by `av_matroska_open`.

///|
test "webm muxer: VP9 track and SimpleBlocks round-trip" {
  let mux = webm_vp9_muxer_new(64, 48).unwrap()
  mux.write_packet(b"\x82\x00\x01", duration=33, keyframe=true).unwrap()
  mux.write_packet(b"\x82\x00\x02", duration=33, keyframe=false).unwrap()
  mux.write_packet(b"\x82\x00\x03", duration=34, keyframe=false).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_true(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "V_VP9")
  assert_eq(track.video.pixel_width, 64UL)
  assert_eq(track.video.pixel_height, 48UL)
  assert_eq(mkv.packets.length(), 3)
  let pts : Array[Int64] = [0L, 33L, 66L]
  for i in 0..<3 {
    assert_eq(mkv.packets[i].data.length(), 3)
    assert_eq(mkv.packets[i].pts, pts[i])
    assert_eq(mkv.packets[i].is_keyframe, i == 0)
  }
}

///|
test "webm muxer: invalid VP9 parameters are rejected" {
  match webm_vp9_muxer_new(0, 48) {
    Ok(_) => fail("zero width must fail")
    Err(_) => ()
  }
  let mux = webm_vp9_muxer_new(64, 48).unwrap()
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty packet must fail")
    Err(_) => ()
  }
}
