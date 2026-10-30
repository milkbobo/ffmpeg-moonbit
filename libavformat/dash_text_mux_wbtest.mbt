///|
/// Text (WebVTT) AdaptationSets for the SegmentList and SegmentTimeline
/// writers: no codecs string, no initialization section, no bandwidth.

///|
test "dash muxer: WebVTT SegmentList omits codecs, initialization and bandwidth" {
  let text = dash_write_segment_list_mpd(
    [
      DashListAdaptation::new(
        "text",
        "text/vtt",
        "",
        "subs",
        0L,
        1000L,
        2000L,
        [
          DashListSegment::new(media="sub1.vtt"),
          DashListSegment::new(media="sub2.vtt"),
        ],
        lang="en",
      ),
    ],
    media_duration_seconds=4.0,
  )
  assert_true(text.contains("contentType=\"text\""))
  assert_true(text.contains("mimeType=\"text/vtt\""))
  assert_true(text.contains("lang=\"en\""))
  assert_false(text.contains("codecs="))
  assert_false(text.contains("<Initialization"))
  assert_false(text.contains("bandwidth="))
  let mpd = av_dash_parse(text).unwrap()
  let adapt = mpd.periods[0].adaptation_sets[0]
  assert_eq(adapt.content_type, "text")
  assert_eq(adapt.mime_type, "text/vtt")
  assert_eq(adapt.lang, "en")
  let rep = adapt.representations[0]
  assert_eq(rep.initialization, "")
  assert_eq(rep.segments.length(), 2)
  assert_eq(rep.segments[0].uri, "sub1.vtt")
  assert_eq(rep.segments[1].uri, "sub2.vtt")
}

///|
test "dash muxer: WebVTT SegmentTimeline omits codecs, initialization and bandwidth" {
  let text = dash_write_timeline_mpd(
    [
      DashTimelineAdaptation::new(
        "text",
        "text/vtt",
        "",
        "subs",
        0L,
        1000L,
        1L,
        "",
        "sub$Time$.vtt",
        [
          DashTimelineSegment::new(2000L, start=0L),
          DashTimelineSegment::new(2000L),
        ],
        lang="en",
      ),
    ],
    media_duration_seconds=4.0,
  )
  assert_true(text.contains("contentType=\"text\""))
  assert_true(text.contains("mimeType=\"text/vtt\""))
  assert_false(text.contains("codecs="))
  assert_false(text.contains("initialization="))
  assert_false(text.contains("bandwidth="))
  let mpd = av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.initialization, "")
  assert_eq(rep.segments.length(), 2)
  assert_eq(rep.segments[0].uri, "sub0.vtt")
  assert_eq(rep.segments[1].uri, "sub2000.vtt")
}
