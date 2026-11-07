///|
/// White-box tests for the timeline normalization guards. These construct a
/// session directly so the saturation and index limits can be reached
/// without crafting a corrupt media file.

///|
test "streaming: sat add/sub clamp instead of wrapping at Int64 extremes" {
  let max = 9223372036854775807L
  let min = -9223372036854775808L
  assert_eq(streaming_sat_add(max, 1L), max)
  assert_eq(streaming_sat_add(min, -1L), min)
  assert_eq(streaming_sat_add(max, -1L), max - 1L)
  assert_eq(streaming_sat_add(min, 1L), min + 1L)
  assert_eq(streaming_sat_sub(min, 1L), min)
  assert_eq(streaming_sat_sub(max, -1L), max)
  assert_eq(streaming_sat_sub(max, 1L), max - 1L)
  assert_eq(streaming_sat_sub(min, -1L), min + 1L)
}

///|
test "streaming: a hostile stream index is refused, not allocated" {
  let playlist = av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
  let reader = hls_segment_reader_new(playlist, (_, _, _) => Err("unused")).unwrap()
  let media = streaming_from_reader(Hls, "hls", HlsReader(reader), None)
  try
    media.streaming_normalize({
      stream_index: 4096,
      data: b"",
      pts: 0L,
      keyframe: false,
    })
  catch {
    DemuxError(msg) => assert_true(msg.contains("out of range"))
    _ => fail("expected DemuxError")
  } noraise {
    _ => fail("expected DemuxError for hostile stream index")
  }
  assert_eq(media.last_pts.length(), 0)
}

///|
test "streaming: normalization places a restarted segment after the last pts" {
  let playlist = av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
  let reader = hls_segment_reader_new(playlist, (_, _, _) => Err("unused")).unwrap()
  let media = streaming_from_reader(Hls, "hls", HlsReader(reader), None)
  let mk = fn(pts : Int64) -> MediaPacket {
    { stream_index: 0, data: b"x", pts, keyframe: false, }
  }
  let a = media.streaming_normalize(mk(100L))
  let b = media.streaming_normalize(mk(200L))
  assert_eq(a.pts, 100L)
  assert_eq(b.pts, 200L)
  // New segment restarts at 0: with a 100-tick step it must land at 300.
  media.streaming_reset_segment()
  let c = media.streaming_normalize(mk(0L))
  assert_eq(c.pts, 300L)
  let d = media.streaming_normalize(mk(100L))
  assert_eq(d.pts, 400L)
}
