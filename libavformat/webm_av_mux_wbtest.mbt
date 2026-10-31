///|
/// WebM A/V muxer tests: VP9 + Opus tracks are parsed back by
/// `av_matroska_open`.

///|
test "webm muxer: VP9 + Opus tracks interleave by timestamp" {
  let mux = webm_av_muxer_new(64, 48, channels=1, pre_skip=312).unwrap()
  mux.write_video(b"V0", 0L, 33, keyframe=true).unwrap()
  mux.write_video(b"V1", 33L, 33).unwrap()
  mux.write_video(b"V2", 66L, 33).unwrap()
  mux.write_audio(b"A0", 0L, 20).unwrap()
  mux.write_audio(b"A1", 20L, 20).unwrap()
  mux.write_audio(b"A2", 40L, 20).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_true(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.tracks[0].codec_id.unwrap(), "V_VP9")
  assert_eq(mkv.tracks[0].video.pixel_width, 64UL)
  assert_eq(mkv.tracks[1].codec_id.unwrap(), "A_OPUS")
  assert_eq(mkv.tracks[1].audio.channels, 1UL)
  assert_eq(mkv.packets.length(), 6)
  let pts : Array[Int64] = [0L, 0L, 20L, 33L, 40L, 66L]
  let streams : Array[Int32] = [0, 1, 1, 0, 1, 0]
  let payloads : Array[Bytes] = [b"V0", b"A0", b"A1", b"V1", b"A2", b"V2"]
  for i in 0..<6 {
    assert_eq(mkv.packets[i].pts, pts[i])
    assert_eq(mkv.packets[i].stream_index, streams[i])
    assert_eq(mkv.packets[i].data, payloads[i])
  }
  assert_true(mkv.packets[0].is_keyframe)
  assert_false(mkv.packets[3].is_keyframe)
}

///|
test "webm muxer: invalid packets are rejected" {
  let mux = webm_av_muxer_new(64, 48).unwrap()
  match mux.write_video(Bytes::new(0), 0L, 33) {
    Ok(_) => fail("empty video packet must fail")
    Err(_) => ()
  }
  match mux.write_audio(b"x", -1L, 20) {
    Ok(_) => fail("negative audio pts must fail")
    Err(_) => ()
  }
}

///|
test "webm muxer: Opus pre-skip/discard padding fields" {
  let mux = webm_av_muxer_new(
    64,
    48,
    channels=1,
    pre_skip=312,
    audio_discard_padding=648,
  ).unwrap()
  mux.write_video(b"V0", 0L, 33, keyframe=true).unwrap()
  mux.write_audio(b"A0", 0L, 20).unwrap()
  mux.write_audio(b"A1", 20L, 20).unwrap()
  mux.write_audio(b"A2", 40L, 20).unwrap()
  let bytes = mux.finish()
  let mkv = av_matroska_open(bytes).unwrap()
  let atrack = mkv.tracks[1]
  assert_true(atrack.codec_delay > 0UL)
  assert_eq(atrack.seek_preroll, 80000000UL)
  let audio_packets = mkv.packets.filter(p => p.stream_index == 1)
  assert_eq(audio_packets.length(), 3)
  assert_eq(audio_packets[0].pts, 0L)
  assert_true(audio_packets[2].discard_padding != 0L)
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 1)
  assert_eq(cues.cues[0].time, 0L)
}
