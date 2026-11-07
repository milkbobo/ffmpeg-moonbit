///|
/// Black-box tests for live subtitle refresh: a subtitle track collected at
/// `open` must keep up with a sliding window, appending only what is new.
///
/// Both sources are covered, because their progress keys differ: an HLS
/// rendition playlist is addressed by `EXT-X-MEDIA-SEQUENCE`, a DASH text
/// AdaptationSet by the segment's own URI (sequence numbers and times can both
/// restart when a duration-based window slides).

///|
fn slive_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// One cue per segment, always restarting at zero, so cue placement is the only
/// thing that decides the timestamps.
fn slive_vtt(text : String) -> String {
  "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n" + text + "\n"
}

///|
/// A media playlist. `sequence >= 0` emits `EXT-X-MEDIA-SEQUENCE` and omits
/// `EXT-X-ENDLIST`, which is the live shape.
fn slive_playlist(
  sequence : Int64,
  uris : Array[String],
  duration : Double,
) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n")
  if sequence >= 0L {
    sb.write_string("#EXT-X-MEDIA-SEQUENCE:\{sequence}\n")
  }
  for uri in uris {
    sb.write_string("#EXTINF:\{duration},\n\{uri}\n")
  }
  if sequence < 0L {
    sb.write_string("#EXT-X-ENDLIST\n")
  }
  sb.to_string()
}

///|
fn slive_master() -> String {
  "#EXTM3U\n" +
  "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\"," +
  "DEFAULT=YES,AUTOSELECT=YES,LANGUAGE=\"en\",URI=\"subs.m3u8\"\n" +
  "#EXT-X-STREAM-INF:BANDWIDTH=200000,SUBTITLES=\"subs\"\nv/video.m3u8\n"
}

///|
/// A fetch hook over a mutable URI table, so a test can swap what a URI serves
/// between two refreshes - which is exactly what a live window does.
fn slive_fetch(
  files : Map[String, String],
  seen : Array[String],
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    seen.push(uri)
    match files.get(uri) {
      Some(text) => Ok(slive_bytes(text))
      None => Err("404: \{uri}")
    }
  }
}

///|
/// A text AdaptationSet over an explicit `SegmentTimeline`, addressed by
/// `$Time$` - the shape a live window needs, since `$Number$` would renumber
/// the entries from `startNumber` on every refresh and collide.
fn slive_dash_text(timeline : String) -> String {
  "<AdaptationSet mimeType=\"text/vtt\" lang=\"en\">" +
  "<Representation id=\"sub-en\"><SegmentTemplate timescale=\"1000\" " +
  "media=\"sub$Time$.vtt\"><SegmentTimeline>" + timeline +
  "</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>"
}

///|
fn slive_dash_video() -> String {
  "<AdaptationSet mimeType=\"video/mp4\" codecs=\"avc1.42E01E\">" +
  "<Representation id=\"v0\" bandwidth=\"200000\"><SegmentTemplate " +
  "timescale=\"1000\" initialization=\"v-init.mp4\" media=\"v$Number$.m4s\">" +
  "<SegmentTimeline><S t=\"0\" d=\"2000\" r=\"1\"/></SegmentTimeline>" +
  "</SegmentTemplate></Representation></AdaptationSet>"
}

///|
fn slive_dash_mpd(sets : String) -> String {
  "<MPD mediaPresentationDuration=\"PT4S\"><Period>" + sets + "</Period></MPD>"
}

///|
fn slive_cues(track : @libavformat.SubtitleTrack) -> Array[Int64] {
  let out : Array[Int64] = []
  for cue in track.cues() {
    out.push(cue.start_ms())
  }
  out
}

///|
/// The headline case: a rendition playlist whose window advanced by one segment
/// appends exactly that segment's cues, continuing the timeline.
test "live subtitles: HLS refresh appends only the new window" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = slive_fetch(files, seen)
  files["https://cdn.test/hls/master.m3u8"] = slive_master()
  files["https://cdn.test/hls/v/video.m3u8"] = slive_playlist(-1L, ["v0.ts"], 1.0)
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(
    0L,
    ["s0.vtt", "s1.vtt"],
    3.0,
  )
  files["https://cdn.test/hls/s0.vtt"] = slive_vtt("a")
  files["https://cdn.test/hls/s1.vtt"] = slive_vtt("b")
  let media = @libavformat.StreamingMedia::open(
    slive_bytes(slive_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 3000L])
  // The window slides by one segment: s1 is still listed, s2 is new.
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(
    1L,
    ["s1.vtt", "s2.vtt"],
    3.0,
  )
  files["https://cdn.test/hls/s2.vtt"] = slive_vtt("c")
  assert_eq(media.refresh_subtitles(), 1)
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 3000L, 6000L])
  assert_eq(media.subtitle_refresh_failures(), 0)
}

///|
/// A refresh that finds nothing new appends nothing - the cursor is a position,
/// not a request to re-read.
test "live subtitles: HLS refresh is idempotent" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = slive_fetch(files, seen)
  files["https://cdn.test/hls/master.m3u8"] = slive_master()
  files["https://cdn.test/hls/v/video.m3u8"] = slive_playlist(-1L, ["v0.ts"], 1.0)
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(0L, ["s0.vtt"], 3.0)
  files["https://cdn.test/hls/s0.vtt"] = slive_vtt("a")
  let media = @libavformat.StreamingMedia::open(
    slive_bytes(slive_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_eq(media.refresh_subtitles(), 0)
  assert_eq(media.refresh_subtitles(), 0)
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L])
}

///|
/// `reload` moves the media window, so it has to pull the rendition playlist
/// forward too - the caller should not have to know the subtitle is separate.
test "live subtitles: reload refreshes the rendition playlist" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = slive_fetch(files, seen)
  files["https://cdn.test/hls/master.m3u8"] = slive_master()
  files["https://cdn.test/hls/v/video.m3u8"] = slive_playlist(-1L, ["v0.ts"], 1.0)
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(0L, ["s0.vtt"], 3.0)
  files["https://cdn.test/hls/s0.vtt"] = slive_vtt("a")
  let media = @libavformat.StreamingMedia::open(
    slive_bytes(slive_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  // The window slid by one segment: s1 is now the playlist's first entry.
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(1L, ["s1.vtt"], 3.0)
  files["https://cdn.test/hls/s1.vtt"] = slive_vtt("b")
  let variant = @libavformat.av_hls_parse(
    slive_playlist(-1L, ["v0.ts"], 1.0),
    base_uri="https://cdn.test/hls/v/video.m3u8",
  ).unwrap()
  media.reload(variant)
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 3000L])
  assert_eq(media.subtitle_refresh_failures(), 0)
}

///|
/// A broken cue playlist must not fail the media reload: the window has already
/// moved, so the failure is counted and retried on the next refresh.
test "live subtitles: a failing refresh does not fail the reload" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let broken : Array[Bool] = [false]
  let base = slive_fetch(files, seen)
  let fetch : @libavformat.MediaFetch = (uri, offset, length) => {
    if broken[0] && uri.has_suffix("subs.m3u8") {
      return Err("gone")
    }
    base(uri, offset, length)
  }
  files["https://cdn.test/hls/master.m3u8"] = slive_master()
  files["https://cdn.test/hls/v/video.m3u8"] = slive_playlist(-1L, ["v0.ts"], 1.0)
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(0L, ["s0.vtt"], 3.0)
  files["https://cdn.test/hls/s0.vtt"] = slive_vtt("a")
  let media = @libavformat.StreamingMedia::open(
    slive_bytes(slive_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  broken[0] = true
  let variant = @libavformat.av_hls_parse(
    slive_playlist(-1L, ["v0.ts"], 1.0),
    base_uri="https://cdn.test/hls/v/video.m3u8",
  ).unwrap()
  // The media reload itself still completes.
  media.reload(variant)
  assert_eq(media.reload_count(), 1)
  assert_eq(media.subtitle_refresh_failures(), 1)
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L])
  // Once the source is back, the same call catches up.
  broken[0] = false
  files["https://cdn.test/hls/subs.m3u8"] = slive_playlist(1L, ["s1.vtt"], 3.0)
  files["https://cdn.test/hls/s1.vtt"] = slive_vtt("b")
  assert_eq(media.refresh_subtitles(), 1)
}

///|
/// A DASH window that advanced appends only the segments it has not seen. The
/// overlap segment is recognised by its URI even though its `time` also
/// appears in the new window.
test "live subtitles: DASH reload_dash appends only the new window" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = slive_fetch(files, seen)
  files["https://cdn.test/dash/sub0.vtt"] = slive_vtt("a")
  files["https://cdn.test/dash/sub2000.vtt"] = slive_vtt("b")
  files["https://cdn.test/dash/sub4000.vtt"] = slive_vtt("c")
  let first = slive_dash_mpd(
    slive_dash_video() + slive_dash_text("<S t=\"0\" d=\"2000\" r=\"1\"/>"),
  )
  let media = @libavformat.StreamingMedia::open(
    slive_bytes(first),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 2000L])
  // Before the MPD is replaced there is nothing new to read.
  assert_eq(media.refresh_subtitles(), 0)
  // Window advances one segment: sub2 overlaps, sub3 is new.
  let second = slive_dash_mpd(
    slive_dash_video() + slive_dash_text("<S t=\"2000\" d=\"2000\" r=\"1\"/>"),
  )
  media.reload_dash(
    @libavformat.av_dash_parse(
      second,
      base_uri="https://cdn.test/dash/manifest.mpd",
    ).unwrap(),
  )
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 2000L, 4000L])
  assert_eq(media.subtitle_refresh_failures(), 0)
}

///|
/// A duration-based `SegmentTemplate` restarts its times (and its numbers) when
/// the window slides, so the track's own position is what keeps the cue
/// timeline monotonic instead of stacking the new window on top of the old one.
test "live subtitles: DASH duration-based window continues the timeline" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = slive_fetch(files, seen)
  let duration_mpd = fn(start_number : Int64) -> String {
    slive_dash_mpd(
      slive_dash_video() +
      "<AdaptationSet mimeType=\"text/vtt\" lang=\"en\">" +
      "<Representation id=\"sub-en\"><SegmentTemplate timescale=\"1000\" " +
      "duration=\"2000\" startNumber=\"" + start_number.to_string() +
      "\" media=\"sub$Number$.vtt\"/></Representation></AdaptationSet>",
    )
  }
  for name in ["sub1.vtt", "sub2.vtt", "sub3.vtt", "sub4.vtt"] {
    files["https://cdn.test/dash/" + name] = slive_vtt(name)
  }
  let media = @libavformat.StreamingMedia::open(
    slive_bytes(duration_mpd(1L)),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 2000L])
  media.reload_dash(
    @libavformat.av_dash_parse(
      duration_mpd(3L),
      base_uri="https://cdn.test/dash/manifest.mpd",
    ).unwrap(),
  )
  // The new window reports times 0 and 2000 again; the cues still land after
  // what was already placed.
  assert_eq(slive_cues(media.subtitles().unwrap()), [0L, 2000L, 4000L, 6000L])
}
