///|
/// DASH WebVTT round-trip through the writer and the reference reader:
/// text AdaptationSets carry no initialization, so each SegmentList /
/// SegmentTimeline segment is a self-contained `WEBVTT` file.

///|
test "dash: WebVTT SegmentList round-trip" {
  let vtt1 = hls_write_vtt_segment([
    hls_vtt_cue_new(0L, 1000L, "Hello"),
    hls_vtt_cue_new(1200L, 2000L, "World\nline"),
  ])
  let vtt2 = hls_write_vtt_segment([hls_vtt_cue_new(2100L, 3200L, "Second")])
  let files : Map[String, Bytes] = Map([])
  files["sub1.vtt"] = utf8_from_string(vtt1)
  files["sub2.vtt"] = utf8_from_string(vtt2)
  let mpd_text = dash_write_segment_list_mpd(
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
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let fetch : MediaFetch = (uri, _, _) => {
    match files.get(uri) {
      Some(bytes) => Ok(bytes)
      None => Err("unexpected uri \{uri}")
    }
  }
  let reader = dash_segment_reader_new(rep, fetch)
  for expected in [vtt1, vtt2] {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => fail("missing WebVTT segment")
      Err(e) => fail("segment read failed: \{e}")
    }
    assert_eq(segment.initialization.length(), 0)
    assert_eq(segment.bytes(), utf8_from_string(expected))
  }
  assert_true(reader.next().unwrap() is None)
}

///|
test "dash: WebVTT SegmentTimeline round-trip" {
  let vtt1 = hls_write_vtt_segment([hls_vtt_cue_new(0L, 2000L, "One")])
  let vtt2 = hls_write_vtt_segment([hls_vtt_cue_new(2000L, 4000L, "Two")])
  let files : Map[String, Bytes] = Map([])
  files["sub0.vtt"] = utf8_from_string(vtt1)
  files["sub2000.vtt"] = utf8_from_string(vtt2)
  let mpd_text = dash_write_timeline_mpd(
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
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments[0].uri, "sub0.vtt")
  assert_eq(rep.segments[1].uri, "sub2000.vtt")
  let fetch : MediaFetch = (uri, _, _) => {
    match files.get(uri) {
      Some(bytes) => Ok(bytes)
      None => Err("unexpected uri \{uri}")
    }
  }
  let reader = dash_segment_reader_new(rep, fetch)
  for expected in [vtt1, vtt2] {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => fail("missing WebVTT segment")
      Err(e) => fail("segment read failed: \{e}")
    }
    assert_eq(segment.initialization.length(), 0)
    assert_eq(segment.bytes(), utf8_from_string(expected))
  }
  assert_true(reader.next().unwrap() is None)
}
