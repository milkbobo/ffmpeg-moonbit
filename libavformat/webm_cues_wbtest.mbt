///|
/// WebM SeekHead/Cues writer: cue times follow the video keyframes and the
/// cue cluster positions point at the actual Cluster element.

///|
test "webm: VP9 Cues track keyframes and cluster position" {
  let mux = webm_vp9_muxer_new(64, 48).unwrap()
  mux.write_packet(b"one", duration=100, keyframe=true).unwrap()
  mux.write_packet(b"two", duration=100).unwrap()
  mux.write_packet(b"three", duration=100, keyframe=true).unwrap()
  let bytes = mux.finish()
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 2)
  assert_eq(cues.cues[0].time, 0L)
  assert_eq(cues.cues[1].time, 200L)
  assert_eq(cues.cues[0].track, 1L)
  assert_eq(cues.cues[0].cluster_position, cues.cues[1].cluster_position)
  let cluster_start = (cues.segment_data_start + cues.cues[0].cluster_position).to_int()
  assert_eq(bytes[cluster_start:cluster_start + 4], b"\x1f\x43\xb6\x75"[:])
  match mkv_seek_cue(cues, 250L) {
    Some(cue) => assert_eq(cue.time, 200L)
    None => fail("missing seek cue")
  }
}

///|
test "webm: A/V Cues only index video keyframes" {
  let mux = webm_av_muxer_new(64, 48).unwrap()
  mux.write_video(b"v0", 0L, 200, keyframe=true).unwrap()
  mux.write_audio(b"a0", 0L, 100).unwrap()
  mux.write_audio(b"a1", 100L, 100).unwrap()
  mux.write_video(b"v1", 200L, 200, keyframe=true).unwrap()
  let bytes = mux.finish()
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 2)
  assert_eq(cues.cues[0].time, 0L)
  assert_eq(cues.cues[1].time, 200L)
  for cue in cues.cues {
    assert_eq(cue.track, 1L)
  }
}
