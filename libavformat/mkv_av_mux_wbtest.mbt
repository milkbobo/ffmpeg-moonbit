///|
/// MKV H.264+AAC muxer tests: both tracks are parsed back by
/// `av_matroska_open`.

///|
let mkv_av_avcc_b64 : Bytes = b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///|
test "mkv muxer: H.264 + AAC tracks interleave by timestamp" {
  let avcc = @libavutil.av_base64_decode(mkv_av_avcc_b64, 1024).unwrap()
  let mux = mkv_av_muxer_new(64, 48, avcc, 48000, channels=2).unwrap()
  mux.write_video(b"V0", 0L, 33, keyframe=true).unwrap()
  mux.write_video(b"V1", 33L, 33).unwrap()
  mux.write_audio(b"A0", 0L, 21).unwrap()
  mux.write_audio(b"A1", 21L, 21).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_false(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.tracks[0].codec_id.unwrap(), "V_MPEG4/ISO/AVC")
  assert_eq(mkv.tracks[0].codec_priv.unwrap(), avcc)
  assert_eq(mkv.tracks[1].codec_id.unwrap(), "A_AAC")
  assert_eq(mkv.tracks[1].codec_priv.unwrap().length(), 2)
  assert_eq(mkv.packets.length(), 4)
  let pts : Array[Int64] = [0L, 0L, 21L, 33L]
  let streams : Array[Int32] = [0, 1, 1, 0]
  let payloads : Array[Bytes] = [b"V0", b"A0", b"A1", b"V1"]
  for i in 0..<4 {
    assert_eq(mkv.packets[i].pts, pts[i])
    assert_eq(mkv.packets[i].stream_index, streams[i])
    assert_eq(mkv.packets[i].data, payloads[i])
  }
}

///|
test "mkv muxer: invalid A/V packets are rejected" {
  let avcc = @libavutil.av_base64_decode(mkv_av_avcc_b64, 1024).unwrap()
  let mux = mkv_av_muxer_new(64, 48, avcc, 48000).unwrap()
  match mux.write_audio(Bytes::new(0), 0L, 21) {
    Ok(_) => fail("empty audio packet must fail")
    Err(_) => ()
  }
}
