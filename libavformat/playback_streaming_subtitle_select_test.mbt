///|
/// Black-box tests for picking a subtitle language: `subtitle_renditions()`
/// lists what is on offer without fetching cues, `select_subtitles` switches to
/// one of them, and the live refresh keeps following the selection.

///|
fn ssel_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
fn ssel_vtt(text : String) -> String {
  "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n" + text + "\n"
}

///|
fn ssel_playlist(uris : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n")
  for uri in uris {
    sb.write_string("#EXTINF:3.0,\n\{uri}\n")
  }
  sb.write_string("#EXT-X-ENDLIST\n")
  sb.to_string()
}

///|
/// A master playlist with two subtitle renditions in one group. French comes
/// first and English carries `DEFAULT=YES`, so "default wins over position" is
/// observable from the selected index alone.
fn ssel_master() -> String {
  "#EXTM3U\n" +
  "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"Francais\"," +
  "DEFAULT=NO,AUTOSELECT=YES,LANGUAGE=\"fr\",URI=\"fr.m3u8\"\n" +
  "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\"," +
  "DEFAULT=YES,AUTOSELECT=YES,LANGUAGE=\"en\",URI=\"en.m3u8\"\n" +
  "#EXT-X-STREAM-INF:BANDWIDTH=200000,SUBTITLES=\"subs\"\nv/video.m3u8\n"
}

///|
fn ssel_fetch(
  files : Map[String, String],
  seen : Array[String],
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    seen.push(uri)
    match files.get(uri) {
      Some(text) => Ok(ssel_bytes(text))
      None => Err("404: \{uri}")
    }
  }
}

///|
fn ssel_count(seen : Array[String], uri : String) -> Int {
  let mut n = 0
  for s in seen {
    if s == uri {
      n = n + 1
    }
  }
  n
}

///|
/// The two-language HLS fixture: everything a subtitle test needs to exist.
fn ssel_hls_files() -> Map[String, String] {
  let files : Map[String, String] = Map([])
  files["https://cdn.test/hls/master.m3u8"] = ssel_master()
  files["https://cdn.test/hls/v/video.m3u8"] = ssel_playlist(["v0.ts"])
  files["https://cdn.test/hls/en.m3u8"] = ssel_playlist(["en0.vtt"])
  files["https://cdn.test/hls/fr.m3u8"] = ssel_playlist(["fr0.vtt"])
  files["https://cdn.test/hls/en0.vtt"] = ssel_vtt("hello")
  files["https://cdn.test/hls/fr0.vtt"] = ssel_vtt("bonjour")
  files
}

///|
/// The rendition list carries what a language menu needs, and `DEFAULT=YES`
/// decides the starting track even when it is not listed first.
test "subtitle select: HLS lists the group's renderings and starts on DEFAULT" {
  let files = ssel_hls_files()
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(ssel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let renditions = media.subtitle_renditions()
  assert_eq(renditions.length(), 2)
  assert_eq(renditions[0].language(), "fr")
  assert_eq(renditions[0].name(), "Francais")
  assert_eq(renditions[0].is_default(), false)
  assert_eq(renditions[0].uri(), "https://cdn.test/hls/fr.m3u8")
  assert_eq(renditions[1].language(), "en")
  assert_eq(renditions[1].is_default(), true)
  // Position 0 is French, but the default flag wins.
  assert_eq(media.subtitle_selected(), 1)
  assert_eq(media.subtitles().unwrap().language(), "en")
  assert_eq(media.subtitles().unwrap().cue(0).unwrap().text(), "hello")
}

///|
/// Switching fetches the other rendition and replaces the active track.
test "subtitle select: switching to another language replaces the track" {
  let files = ssel_hls_files()
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(ssel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  media.select_subtitles(0)
  assert_eq(media.subtitle_selected(), 0)
  let track = media.subtitles().unwrap()
  assert_eq(track.language(), "fr")
  assert_eq(track.name(), "Francais")
  assert_eq(track.cue_count(), 1)
  assert_eq(track.cue(0).unwrap().text(), "bonjour")
}

///|
/// Re-selecting the live track must not re-read it: that would reset the cursor
/// to the first window and lose whatever a live stream has published.
test "subtitle select: re-selecting the active track is a no-op" {
  let files = ssel_hls_files()
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(ssel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  media.select_subtitles(0)
  let before = ssel_count(seen, "https://cdn.test/hls/fr.m3u8")
  media.select_subtitles(0)
  assert_eq(ssel_count(seen, "https://cdn.test/hls/fr.m3u8"), before)
}

///|
/// A selection that cannot be opened leaves the previous track playing.
test "subtitle select: a failing switch keeps the previous track" {
  let files = ssel_hls_files()
  let seen : Array[String] = []
  let base = ssel_fetch(files, seen)
  // The French rendition's playlist goes missing after the session opened.
  let broken : Array[Bool] = [false]
  let fetch : @libavformat.MediaFetch = (uri, offset, length) => {
    if broken[0] && uri.has_suffix("fr.m3u8") {
      return Err("gone")
    }
    base(uri, offset, length)
  }
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(ssel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  broken[0] = true
  let message = try {
    media.select_subtitles(0)
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("subtitle rendition fetch failed"))
  assert_eq(media.subtitle_selected(), 1)
  assert_eq(media.subtitles().unwrap().language(), "en")
}

///|
/// An out-of-range selection is refused instead of silently clamping.
test "subtitle select: out of range index is an error" {
  let files = ssel_hls_files()
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(ssel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let message = try {
    media.select_subtitles(2)
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("out of range"))
  assert_eq(media.subtitle_selected(), 1)
}

///|
/// No `SUBTITLES` group means nothing to select: an empty list and `-1`.
test "subtitle select: a variant without SUBTITLES offers no choices" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  files["https://cdn.test/hls/master.m3u8"] =
    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200000\nv/video.m3u8\n"
  files["https://cdn.test/hls/v/video.m3u8"] = ssel_playlist(["v0.ts"])
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(files["https://cdn.test/hls/master.m3u8"]),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_eq(media.subtitle_renditions().length(), 0)
  assert_eq(media.subtitle_selected(), -1)
  assert_true(media.subtitles() is None)
}

///|
/// A DASH Period with two text sets (different `lang`) offers both, and the
/// first one is active by default because DASH has no `DEFAULT` flag.
test "subtitle select: DASH lists every parseable text set" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  files["https://cdn.test/dash/zh1.vtt"] = ssel_vtt("nihao")
  files["https://cdn.test/dash/en1.vtt"] = ssel_vtt("hello")
  let mpd = ssel_dash_mpd(ssel_dash_text("zh", "zh"), ssel_dash_text("en", "en"))
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  let renditions = media.subtitle_renditions()
  assert_eq(renditions.length(), 2)
  assert_eq(renditions[0].language(), "zh")
  assert_eq(renditions[1].language(), "en")
  assert_eq(renditions[1].name(), "sub-en")
  assert_eq(media.subtitle_selected(), 0)
  assert_eq(media.subtitles().unwrap().cue(0).unwrap().text(), "nihao")
  media.select_subtitles(1)
  assert_eq(media.subtitle_selected(), 1)
  assert_eq(media.subtitles().unwrap().language(), "en")
  assert_eq(media.subtitles().unwrap().cue(0).unwrap().text(), "hello")
}

///|
/// A TTML text set is not offered: it cannot be parsed, so listing it would
/// promise a track that `select_subtitles` could never open.
test "subtitle select: DASH does not offer a non-WebVTT text set" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  files["https://cdn.test/dash/en1.vtt"] = ssel_vtt("hello")
  let ttml =
    "<AdaptationSet mimeType=\"application/ttml+xml\" lang=\"de\">" +
    "<Representation id=\"sub-de\"><SegmentTemplate timescale=\"1000\" " +
    "media=\"de$Number$.ttml\"><SegmentTimeline><S t=\"0\" d=\"2000\" r=\"0\"/>" +
    "</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>"
  let mpd = ssel_dash_mpd(ttml, ssel_dash_text("en", "en"))
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(mpd),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  let renditions = media.subtitle_renditions()
  assert_eq(renditions.length(), 1)
  assert_eq(renditions[0].language(), "en")
}

///|
/// After a `reload_dash` the refresh must extend the **selected** track, not
/// re-pick the first text set - otherwise switching language would silently
/// stop updating.
test "subtitle select: live refresh follows the selected language" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = ssel_fetch(files, seen)
  files["https://cdn.test/dash/zh1.vtt"] = ssel_vtt("nihao")
  files["https://cdn.test/dash/en1.vtt"] = ssel_vtt("hello")
  files["https://cdn.test/dash/en2.vtt"] = ssel_vtt("again")
  let first = ssel_dash_mpd(
    ssel_dash_text_repeat("zh", "zh", 0),
    ssel_dash_text_repeat("en", "en", 0),
  )
  let media = @libavformat.StreamingMedia::open(
    ssel_bytes(first),
    fetch,
    base_uri="https://cdn.test/dash/manifest.mpd",
  )
  media.select_subtitles(1)
  assert_eq(media.subtitles().unwrap().cue_count(), 1)
  // The English track grows by one segment; Chinese stays as it was.
  let second = ssel_dash_mpd(
    ssel_dash_text_repeat("zh", "zh", 0),
    ssel_dash_text_repeat("en", "en", 1),
  )
  media.reload_dash(
    @libavformat.av_dash_parse(
      second,
      base_uri="https://cdn.test/dash/manifest.mpd",
    ).unwrap(),
  )
  let track = media.subtitles().unwrap()
  assert_eq(track.language(), "en")
  assert_eq(track.cue_count(), 2)
  assert_eq(track.cue(1).unwrap().text(), "again")
}

///|
/// A text AdaptationSet over one `$Number$` timeline of `repeat + 1` segments.
fn ssel_dash_text_repeat(lang : String, prefix : String, repeat : Int) -> String {
  "<AdaptationSet mimeType=\"text/vtt\" lang=\"" + lang + "\">" +
  "<Representation id=\"sub-" + lang + "\" bandwidth=\"256\">" +
  "<SegmentTemplate timescale=\"1000\" media=\"" + prefix +
  "$Number$.vtt\"><SegmentTimeline><S t=\"0\" d=\"2000\" r=\"" +
  repeat.to_string() + "\"/></SegmentTimeline></SegmentTemplate>" +
  "</Representation></AdaptationSet>"
}

///|
/// A single-segment text set, the shape most of the selection tests need.
fn ssel_dash_text(lang : String, prefix : String) -> String {
  ssel_dash_text_repeat(lang, prefix, 0)
}

///|
fn ssel_dash_video() -> String {
  "<AdaptationSet mimeType=\"video/mp4\" codecs=\"avc1.42E01E\">" +
  "<Representation id=\"v0\" bandwidth=\"200000\"><SegmentTemplate " +
  "timescale=\"1000\" initialization=\"v-init.mp4\" media=\"v$Number$.m4s\">" +
  "<SegmentTimeline><S t=\"0\" d=\"2000\" r=\"1\"/></SegmentTimeline>" +
  "</SegmentTemplate></Representation></AdaptationSet>"
}

///|
fn ssel_dash_mpd(a : String, b : String) -> String {
  "<MPD mediaPresentationDuration=\"PT4S\"><Period>" +
  ssel_dash_video() + a + b + "</Period></MPD>"
}
