///|
/// DASH SegmentTemplate writer round-trips through `av_dash_parse`.

///|
test "dash muxer: SegmentTemplate MPD expands like a real manifest" {
  let text = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "video",
        "video/mp4",
        "avc1.64001f",
        "v1",
        1000000L,
        1000L,
        2000L,
        "init-$RepresentationID$.mp4",
        "seg-$Number%03d$.m4s",
        width=640,
        height=360,
        start_number=5L,
      ),
    ],
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

///|
test "dash muxer: video and audio AdaptationSets are written and parsed" {
  let text = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "video",
        "video/mp4",
        "avc1.42c01e",
        "v1",
        200000L,
        90000L,
        45000L,
        "video-init.mp4",
        "video-$Number$.m4s",
        width=64,
        height=48,
      ),
      DashAdaptation::new(
        "audio",
        "audio/mp4",
        "mp4a.40.2",
        "a1",
        64000L,
        44100L,
        5120L,
        "audio-init.mp4",
        "audio-$Number$.m4s",
        sample_rate=44100,
        lang="en",
      ),
    ],
    media_duration_seconds=0.5,
  )
  let mpd = av_dash_parse(text).unwrap()
  assert_eq(mpd.periods[0].adaptation_sets.length(), 2)
  let video = mpd.periods[0].adaptation_sets[0]
  let audio = mpd.periods[0].adaptation_sets[1]
  assert_eq(video.content_type, "video")
  assert_eq(video.representations[0].width, 64)
  assert_eq(video.representations[0].height, 48)
  assert_eq(audio.content_type, "audio")
  assert_eq(audio.lang, "en")
  assert_eq(audio.codecs, "mp4a.40.2")
  assert_eq(audio.representations[0].audio_sampling_rate, 44100)
  assert_eq(audio.representations[0].codec, "aac")
  assert_eq(audio.representations[0].initialization, "audio-init.mp4")
  assert_eq(audio.representations[0].segments[0].uri, "audio-1.m4s")
}

///|
test "dash muxer: WebVTT AdaptationSet omits codecs and initialization" {
  let text = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "text",
        "text/vtt",
        "",
        "subs",
        256L,
        1000L,
        10000L,
        "",
        "sub$Number$.vtt",
        lang="en",
      ),
    ],
    media_duration_seconds=10.0,
  )
  assert_true(text.contains("contentType=\"text\""))
  assert_true(text.contains("mimeType=\"text/vtt\""))
  assert_true(text.contains("lang=\"en\""))
  assert_true(text.contains("media=\"sub$Number$.vtt\""))
  assert_false(text.contains("codecs="))
  assert_false(text.contains("initialization="))
  assert_true(text.contains("<Representation id=\"subs\" bandwidth=\"256\""))
}
