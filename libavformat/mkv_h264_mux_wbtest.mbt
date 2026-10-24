///|
/// MKV/H.264 muxer tests: emitted files are parsed back by `av_matroska_open`.

///|
let mkv_h264_avcc_b64 : Bytes = b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///|
test "mkv muxer: H.264 track and avcC round-trip" {
  let avcc = @libavutil.av_base64_decode(mkv_h264_avcc_b64, 1024).unwrap()
  let mux = mkv_h264_muxer_new(64, 48, avcc).unwrap()
  mux.write_packet(b"\x00\x00\x01\x02", duration=33, keyframe=true).unwrap()
  mux.write_packet(b"\x00\x00\x01\x03", duration=33).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_false(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "V_MPEG4/ISO/AVC")
  assert_eq(track.codec_priv.unwrap(), avcc)
  assert_eq(track.video.pixel_width, 64UL)
  assert_eq(track.video.pixel_height, 48UL)
  assert_eq(mkv.packets.length(), 2)
  assert_eq(mkv.packets[0].pts, 0L)
  assert_eq(mkv.packets[1].pts, 33L)
  assert_true(mkv.packets[0].is_keyframe)
  assert_false(mkv.packets[1].is_keyframe)
}
