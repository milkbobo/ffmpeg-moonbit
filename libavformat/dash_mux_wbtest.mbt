///|
/// DASH SegmentTemplate writer round-trips through `av_dash_parse`.

///|
test "dash muxer: SegmentTemplate MPD expands like a real manifest" {
  let text = dash_write_segment_template_mpd(
    id="v1",
    bandwidth=1000000L,
    codecs="avc1.64001f",
    width=640,
    height=360,
    timescale=1000L,
    duration=2000L,
    start_number=5L,
    initialization="init-$RepresentationID$.mp4",
    media_template="seg-$Number%03d$.m4s",
    segment_count=5,
    media_duration_seconds=10.0,
  )
  let mpd = av_dash_parse(text).unwrap()
  assert_eq(mpd.type_, "static")
  assert_eq(mpd.media_presentation_duration, 10.0)
  assert_eq(mpd.periods.length(), 1)
  let adapt = mpd.periods[0].adaptation_sets[0]
  assert_eq(adapt.codecs, "avc1.64001f")
  let rep = adapt.representations[0]
  assert_eq(rep.id, "v1")
  assert_eq(rep.width, 640)
  assert_eq(rep.height, 360)
  assert_eq(rep.initialization, "init-v1.mp4")
  assert_eq(rep.segments.length(), 5)
  assert_eq(rep.segments[0].number, 5L)
  assert_eq(rep.segments[0].uri, "seg-005.m4s")
  assert_eq(rep.segments[4].number, 9L)
  assert_eq(rep.segments[4].uri, "seg-009.m4s")
}
