///|
/// Black-box tests for DASH `text/vtt` subtitle AdaptationSets.
///
/// A DASH Period carries its subtitles as a sibling AdaptationSet, so the
/// facade has to find that set while opening an ordinary audio/video
/// Representation, and place each segment's cues on the presentation timeline
/// from the segment's own `time` rather than from accumulated durations.
///
/// Each text segment is a self-contained `WEBVTT` file, which is why the same
/// placement rule as the HLS rendition applies: cue times are absolute when
/// they can be, and segment-relative ones are shifted by the segment start.

///|
fn dsub_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A fetch hook over an explicit URI table, recording every request.
fn dsub_fetch(
  files : Array[(String, String)],
  seen : Array[String],
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    seen.push(uri)
    for entry in files {
      if entry.0 == uri {
        return Ok(dsub_bytes(entry.1))
      }
    }
    Err("404: \{uri}")
  }
}

///|
/// A video AdaptationSet that needs no real media: the tests never drain it.
fn dsub_video_set() -> String {
  "<AdaptationSet mimeType=\"video/mp4\" codecs=\"avc1.42E01E\">" +
  "<Representation id=\"v0\" bandwidth=\"200000\" width=\"64\" height=\"48\">" +
  "<SegmentTemplate timescale=\"1000\" initialization=\"v-init.mp4\" " +
  "media=\"v$Number$.m4s\"><SegmentTimeline><S t=\"0\" d=\"2000\" r=\"1\"/>" +
  "</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>"
}

///|
/// A `text/vtt` AdaptationSet over two 2-second segments.
fn dsub_text_set(media : String, timeline : String, lang : String) -> String {
  "<AdaptationSet mimeType=\"text/vtt\" lang=\"" + lang + "\">" +
  "<Representation id=\"sub-" + lang + "\" bandwidth=\"256\">" +
  "<SegmentTemplate timescale=\"1000\" media=\"" + media + "\">" +
  "<SegmentTimeline>" + timeline + "</SegmentTimeline>" +
  "</SegmentTemplate></Representation></AdaptationSet>"
}

///|
fn dsub_mpd(sets : String) -> String {
  "<MPD mediaPresentationDuration=\"PT4S\"><Period>" + sets + "</Period></MPD>"
}

///|
/// The two-second `$Number$` timeline used by most cases.
fn dsub_timeline() -> String {
  "<S t=\"0\" d=\"2000\" r=\"1\"/>"
}

///|
/// A cue list whose times restart at zero in every segment.
fn dsub_relative() -> String {
  "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nrel\n"
}

///|
/// The headline case: an MPD whose Period carries a sibling `text/vtt` set
/// exposes that set's cues, placed on the presentation timeline.
test "dash subtitles: a text AdaptationSet is collected while opening video" {
  let mpd = dsub_mpd(
    dsub_video_set() + dsub_text_set("sub$Number$.vtt", dsub_timeline(), "en"),
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch(
    [
      ("https://cdn.test/dash/sub1.vtt", dsub_relative()),
      ("https://cdn.test/dash/sub2.vtt", dsub_relative()),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    dsub_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  let track = match media.subtitles() {
    Some(t) => t
    None => fail("expected a subtitle track")
  }
  assert_eq(track.language(), "en")
  // A DASH Representation has no display name; its id is the closest thing.
  assert_eq(track.name(), "sub-en")
  assert_eq(track.forced(), false)
  assert_eq(track.source_uri(), "https://cdn.test/dash/manifest.mpd")
  assert_eq(track.cue_count(), 2)
  // The second segment starts at 2000 ms, so its relative cue moves there.
  assert_eq(track.cue(0).unwrap().start_ms(), 0L)
  assert_eq(track.cue(1).unwrap().start_ms(), 2000L)
  assert_eq(track.cue(1).unwrap().text(), "rel")
}

///|
/// Segment start comes from `SegmentTimeline@t`, not from the segment index:
/// a `$Time$` template whose second entry starts at 180000 in a 90 kHz
/// timescale lands at 2000 ms.
test "dash subtitles: segment start follows the timeline time" {
  let mpd = dsub_mpd(
    dsub_video_set() +
    "<AdaptationSet mimeType=\"text/vtt\" lang=\"en\">" +
    "<Representation id=\"sub-en\"><SegmentTemplate timescale=\"90000\" " +
    "media=\"sub-$Time$.vtt\"><SegmentTimeline>" +
    "<S t=\"0\" d=\"180000\" r=\"1\"/></SegmentTimeline>" +
    "</SegmentTemplate></Representation></AdaptationSet>",
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch(
    [
      ("https://cdn.test/dash/sub-0.vtt", dsub_relative()),
      ("https://cdn.test/dash/sub-180000.vtt", dsub_relative()),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    dsub_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  let track = media.subtitles().unwrap()
  assert_eq(track.cue_count(), 2)
  // 180000 ticks at 90 kHz is exactly 2 s; the remainder path stays exact.
  assert_eq(track.cue(0).unwrap().start_ms(), 0L)
  assert_eq(track.cue(1).unwrap().start_ms(), 2000L)
}

///|
/// The other half of the placement rule: a segment that already carries
/// absolute times must not be shifted.
test "dash subtitles: absolute cue times are left alone" {
  let mpd = dsub_mpd(
    dsub_video_set() + dsub_text_set("sub$Number$.vtt", dsub_timeline(), "en"),
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch(
    [
      ("https://cdn.test/dash/sub1.vtt", dsub_relative()),
      (
        "https://cdn.test/dash/sub2.vtt",
        "WEBVTT\n\n00:00:02.000 --> 00:00:03.000\nabs\n",
      ),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    dsub_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  let track = media.subtitles().unwrap()
  assert_eq(track.cue(1).unwrap().start_ms(), 2000L)
  assert_eq(track.cue(1).unwrap().end_ms(), 3000L)
}

///|
/// A Period with no text set has no subtitle track, and nothing extra is
/// fetched.
test "dash subtitles: a Period without a text set has no track" {
  let mpd = dsub_mpd(dsub_video_set())
  let seen : Array[String] = []
  let fetch = dsub_fetch([], seen)
  let media = @libavformat.StreamingMedia::open(
    dsub_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  assert_true(media.subtitles() is None)
  assert_eq(seen.length(), 0)
}

///|
/// A text set in a format this port cannot parse (TTML) is skipped rather than
/// fed to the WebVTT reader - the A/V stream still opens.
test "dash subtitles: a non-WebVTT text set is skipped, not fatal" {
  let ttml =
    "<AdaptationSet mimeType=\"application/ttml+xml\" lang=\"en\">" +
    "<Representation id=\"ttml\"><SegmentTemplate timescale=\"1000\" " +
    "media=\"sub$Number$.ttml\"><SegmentTimeline>" +
    dsub_timeline() +
    "</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>"
  let mpd = dsub_mpd(dsub_video_set() + ttml)
  let seen : Array[String] = []
  let fetch = dsub_fetch([], seen)
  let media = @libavformat.StreamingMedia::open(
    dsub_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  assert_true(media.subtitles() is None)
  assert_eq(seen.length(), 0)
}

///|
/// Among several text sets, the first `text/vtt` one wins even when an
/// unparseable text set is listed before it.
test "dash subtitles: the first text/vtt set wins over other text sets" {
  let ttml =
    "<AdaptationSet mimeType=\"application/ttml+xml\" lang=\"de\">" +
    "<Representation id=\"ttml\"><SegmentTemplate timescale=\"1000\" " +
    "media=\"de$Number$.ttml\"><SegmentTimeline>" +
    dsub_timeline() +
    "</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>"
  let mpd = dsub_mpd(
    dsub_video_set() + ttml + dsub_text_set("sub$Number$.vtt", dsub_timeline(), "fr"),
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch(
    [
      ("https://cdn.test/dash/sub1.vtt", dsub_relative()),
      ("https://cdn.test/dash/sub2.vtt", dsub_relative()),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    dsub_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  assert_eq(media.subtitles().unwrap().language(), "fr")
  assert_true(!seen.contains("https://cdn.test/dash/de1.ttml"))
}

///|
/// When the caller selects the text set itself, the session *is* the subtitle
/// reader, so no second collection happens; selecting the video set of the
/// same MPD still finds the subtitles even though the text set is listed
/// first.
test "dash subtitles: the selected text set is not collected twice" {
  let mpd = dsub_mpd(
    dsub_text_set("sub$Number$.vtt", dsub_timeline(), "en") + dsub_video_set(),
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch(
    [
      ("https://cdn.test/dash/sub1.vtt", dsub_relative()),
      ("https://cdn.test/dash/sub2.vtt", dsub_relative()),
    ],
    seen,
  )
  // adaptation_set 0 is the text set: opening it collects nothing.
  let parsed = @libavformat.av_dash_parse(
    mpd,
    base_uri="https://cdn.test/dash/manifest.mpd",
  ).unwrap()
  let as_text = @libavformat.StreamingMedia::open_dash(parsed, fetch)
  assert_true(as_text.subtitles() is None)
  assert_eq(seen.length(), 0)
  // adaptation_set 1 is the video set: the text set beside it is collected.
  let as_video = @libavformat.StreamingMedia::open_dash(
    parsed,
    fetch,
    adaptation_set=1,
    mpd_uri="https://cdn.test/dash/manifest.mpd",
  )
  assert_eq(as_video.subtitles().unwrap().cue_count(), 2)
}

///|
/// A subtitle segment that is not WebVTT fails the open instead of quietly
/// playing a video with no captions.
test "dash subtitles: a broken segment fails the open" {
  let mpd = dsub_mpd(
    dsub_video_set() + dsub_text_set("sub$Number$.vtt", dsub_timeline(), "en"),
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch(
    [
      ("https://cdn.test/dash/sub1.vtt", "00:00:00.000 --> 00:00:01.000\nhi\n"),
      ("https://cdn.test/dash/sub2.vtt", dsub_relative()),
    ],
    seen,
  )
  let message = try {
    let _media = @libavformat.StreamingMedia::open(
      dsub_bytes(mpd),
      fetch,
      base_uri="https://cdn.test/dash/manifest.mpd",
    )
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("dash: subtitle track"))
  assert_true(message.contains("missing WEBVTT signature"))
}

///|
/// A subtitle segment that cannot be fetched is an error too.
test "dash subtitles: a failing segment fetch is an error" {
  let mpd = dsub_mpd(
    dsub_video_set() + dsub_text_set("sub$Number$.vtt", dsub_timeline(), "en"),
  )
  let seen : Array[String] = []
  let fetch = dsub_fetch([], seen)
  let message = try {
    let _media = @libavformat.StreamingMedia::open(
      dsub_bytes(mpd),
      fetch,
      base_uri="https://cdn.test/dash/manifest.mpd",
    )
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("subtitle track"))
  assert_true(message.contains("fetch failed"))
}
