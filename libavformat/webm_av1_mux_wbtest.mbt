///|
/// WebM/AV1 muxer tests: emitted files are parsed back by `av_matroska_open`.

///|
test "webm muxer: AV1 track and av1C round-trip" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  let mux = webm_av1_muxer_new(64, 48, av1c).unwrap()
  mux.write_packet(b"\x0A\x00", duration=33, keyframe=true).unwrap()
  mux.write_packet(b"\x0A\x01", duration=33).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "V_AV1")
  assert_eq(track.codec_priv.unwrap(), av1c)
  assert_eq(track.video.pixel_width, 64UL)
  assert_eq(track.video.pixel_height, 48UL)
  assert_eq(mkv.packets.length(), 2)
  assert_eq(mkv.packets[0].pts, 0L)
  assert_eq(mkv.packets[1].pts, 33L)
  assert_true(mkv.packets[0].is_keyframe)
  assert_false(mkv.packets[1].is_keyframe)
}

///|
test "webm muxer: AV1 with matroska DocType round-trips" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  let mux = webm_av1_muxer_new(64, 48, av1c, doctype="matroska").unwrap()
  mux.write_packet(b"\x0A\x0B\x0C", duration=33, keyframe=true).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_false(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "V_AV1")
  assert_eq(ff_mkv_codec_id(track.codec_id.unwrap()), "av1")
  assert_eq(track.codec_priv.unwrap(), av1c)
  assert_eq(mkv.packets.length(), 1)
  assert_eq(mkv.packets[0].data, b"\x0A\x0B\x0C")
}

///|
test "webm muxer: invalid DocType is rejected (AV1)" {
  match webm_av1_muxer_new(64, 48, b"\x81\x08\x4c\x00", doctype="ts") {
    Ok(_) => fail("ts DocType must fail")
    Err(_) => ()
  }
}
