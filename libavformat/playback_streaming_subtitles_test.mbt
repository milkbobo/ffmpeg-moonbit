///|
/// Black-box tests for HLS subtitle renditions (`SUBTITLES="group"` plus
/// `EXT-X-MEDIA:TYPE=SUBTITLES` and WebVTT segments).
///
/// The subtitle side reuses the rendition selection the audio path already has,
/// so these tests concentrate on what is different: which member of the group
/// wins, how the segment timeline decides whether cue times are absolute or
/// segment-relative, and that a broken cue list fails the open rather than
/// quietly playing a video with no captions.

///|
fn subs_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A VOD media playlist over `uris`, each segment `duration` seconds long.
/// `duration` matters: the collector uses `EXTINF` to place a segment that
/// was authored with segment-relative cue times.
fn subs_playlist(uris : Array[String], duration : Double) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n")
  for uri in uris {
    sb.write_string("#EXTINF:\{duration},\n\{uri}\n")
  }
  sb.write_string("#EXT-X-ENDLIST\n")
  sb.to_string()
}

///|
/// A master playlist with the given `EXT-X-MEDIA` lines (verbatim, so tests can
/// vary `TYPE`/`DEFAULT`/`URI`) over one variant that names `group` as its
/// subtitle group (`""` = no `SUBTITLES` attribute at all).
fn subs_master(media_lines : Array[String], group : String) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n")
  for line in media_lines {
    sb.write_string(line)
    sb.write_string("\n")
  }
  sb.write_string("#EXT-X-STREAM-INF:BANDWIDTH=200000,")
  sb.write_string("CODECS=\"avc1.42E01E,mp4a.40.2\"")
  if group != "" {
    sb.write_string(",SUBTITLES=\"" + group + "\"")
  }
  sb.write_string("\nv/video.m3u8\n")
  sb.to_string()
}

///|
fn subs_media_line(
  type_ : String,
  group : String,
  name : String,
  uri : String,
  language : String,
  is_default : Bool,
) -> String {
  let d = if is_default { "YES" } else { "NO" }
  "#EXT-X-MEDIA:TYPE=" +
  type_ +
  ",GROUP-ID=\"" +
  group +
  "\",NAME=\"" +
  name +
  "\",DEFAULT=" +
  d +
  ",AUTOSELECT=YES" +
  (if language == "" { "" } else { ",LANGUAGE=\"" + language + "\"" }) +
  (if uri == "" { "" } else { ",URI=\"" + uri + "\"" })
}

///|
/// A fetch hook over an explicit URI table. Exact URIs (not basenames) so that
/// "which rendition did it resolve to" is directly observable, and every
/// request is recorded for the same reason.
fn subs_fetch(
  files : Array[(String, String)],
  seen : Array[String],
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    seen.push(uri)
    for entry in files {
      if entry.0 == uri {
        return Ok(subs_bytes(entry.1))
      }
    }
    Err("404: \{uri}")
  }
}

///|
/// The variant playlist every case uses: one segment, never fetched unless a
/// test drains packets.
fn subs_variant() -> String {
  subs_playlist(["v0.ts"], 1.0)
}

///|
/// The headline case: a variant that declares `SUBTITLES="subs"` exposes the
/// rendition's cues, with the rendition metadata carried through.
test "hls subtitles: a variant with SUBTITLES collects the rendition's cues" {
  let master = subs_master(
    [
      subs_media_line("SUBTITLES", "subs", "English", "subs.m3u8", "en", true),
    ],
    "subs",
  )
  let seg0 =
    #|WEBVTT
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|hello
    #|
    #|00:00:01.000 --> 00:00:02.000
    #|world
  let seg1 =
    #|WEBVTT
    #|
    #|00:00:03.000 --> 00:00:04.000
    #|again
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
      ("https://cdn.test/hls/subs.m3u8", subs_playlist(["en0.vtt", "en1.vtt"], 3.0)),
      ("https://cdn.test/hls/en0.vtt", seg0),
      ("https://cdn.test/hls/en1.vtt", seg1),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  // The subtitle rendition resolves against the master, like the audio one.
  assert_eq(media.variant_uri(), Some("https://cdn.test/hls/v/video.m3u8"))
  let track = match media.subtitles() {
    Some(t) => t
    None => fail("expected a subtitle track")
  }
  assert_eq(track.language(), "en")
  assert_eq(track.name(), "English")
  assert_eq(track.forced(), false)
  assert_eq(track.source_uri(), "https://cdn.test/hls/subs.m3u8")
  assert_eq(track.cue_count(), 3)
  let summary = {
    let parts : Array[String] = []
    for cue in track.cues() {
      parts.push("\{cue.start_ms()}-\{cue.end_ms()}:\{cue.text()}")
    }
    parts.join("|")
  }
  assert_eq(summary, "0-1000:hello|1000-2000:world|3000-4000:again")
}

///|
/// Authors that write segment-relative cue times are moved onto the playlist
/// timeline. The rule keys off `EXTINF`: a segment whose last cue ends at or
/// before the segment's own start cannot have been absolute.
test "hls subtitles: segment-relative cue times are shifted onto the timeline" {
  let master = subs_master(
    [subs_media_line("SUBTITLES", "subs", "English", "subs.m3u8", "en", true)],
    "subs",
  )
  let relative =
    #|WEBVTT
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|rel
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
      // Three 3-second segments, each with a cue that starts at zero.
      (
        "https://cdn.test/hls/subs.m3u8",
        subs_playlist(["en0.vtt", "en1.vtt", "en2.vtt"], 3.0),
      ),
      ("https://cdn.test/hls/en0.vtt", relative),
      ("https://cdn.test/hls/en1.vtt", relative),
      ("https://cdn.test/hls/en2.vtt", relative),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let track = media.subtitles().unwrap()
  assert_eq(track.cue_count(), 3)
  let starts : Array[Int64] = []
  for cue in track.cues() {
    starts.push(cue.start_ms())
  }
  // 0, then one and two EXTINF durations later.
  assert_eq(starts, [0L, 3000L, 6000L])
}

///|
/// The other half of the same rule: a later segment that already carries
/// absolute times must not be shifted, even though its cues are the same
/// length as the relative case above.
test "hls subtitles: absolute cue times in a later segment are left alone" {
  let master = subs_master(
    [subs_media_line("SUBTITLES", "subs", "English", "subs.m3u8", "en", true)],
    "subs",
  )
  let first =
    #|WEBVTT
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|one
  let second =
    #|WEBVTT
    #|
    #|00:00:03.000 --> 00:00:04.000
    #|two
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
      ("https://cdn.test/hls/subs.m3u8", subs_playlist(["en0.vtt", "en1.vtt"], 3.0)),
      ("https://cdn.test/hls/en0.vtt", first),
      ("https://cdn.test/hls/en1.vtt", second),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let track = media.subtitles().unwrap()
  assert_eq(track.cue(0).unwrap().start_ms(), 0L)
  assert_eq(track.cue(1).unwrap().start_ms(), 3000L)
  // A cue index past the end is not a panic.
  assert_true(track.cue(2) is None)
}

///|
/// No `SUBTITLES` attribute means no subtitle work at all: the accessor is
/// `None` and no `.vtt` was ever requested.
test "hls subtitles: a variant without SUBTITLES has no subtitle track" {
  let master = subs_master([], "")
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_true(media.subtitles() is None)
  let mut vtt_requests = 0
  for uri in seen {
    if uri.has_suffix(".vtt") {
      vtt_requests = vtt_requests + 1
    }
  }
  assert_eq(vtt_requests, 0)
}

///|
/// A group that exists but holds no `TYPE=SUBTITLES` member is not a subtitle
/// rendition - an `AUDIO` member sharing the id must not be parsed as WebVTT.
test "hls subtitles: only members of type SUBTITLES in the named group count" {
  let master = subs_master(
    [
      // Right group, wrong type.
      subs_media_line("AUDIO", "subs", "English", "en.m3u8", "en", true),
      // Right type, wrong group.
      subs_media_line("SUBTITLES", "other", "German", "de.m3u8", "de", true),
    ],
    "subs",
  )
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_true(media.subtitles() is None)
  assert_true(!seen.contains("https://cdn.test/hls/de.m3u8"))
}

///|
/// Among group members, `DEFAULT=YES` wins. The non-default member is never
/// fetched, which is what makes the choice observable.
test "hls subtitles: DEFAULT=YES wins among the group's members" {
  let master = subs_master(
    [
      subs_media_line("SUBTITLES", "subs", "English", "en.m3u8", "en", false),
      subs_media_line("SUBTITLES", "subs", "Francais", "fr.m3u8", "fr", true),
    ],
    "subs",
  )
  let vtt =
    #|WEBVTT
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|bonjour
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
      ("https://cdn.test/hls/fr.m3u8", subs_playlist(["fr0.vtt"], 3.0)),
      ("https://cdn.test/hls/fr0.vtt", vtt),
      // Deliberately absent: asking for it would 404 and fail the open.
      ("https://cdn.test/hls/en.m3u8", subs_playlist(["en0.vtt"], 3.0)),
      ("https://cdn.test/hls/en0.vtt", vtt),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let track = media.subtitles().unwrap()
  assert_eq(track.language(), "fr")
  assert_eq(track.name(), "Francais")
  assert_true(!seen.contains("https://cdn.test/hls/en.m3u8"))
}

///|
/// A segment that is not WebVTT fails the open: playing on with no captions
/// would hide a broken rendition.
test "hls subtitles: a segment that is not WebVTT fails the open" {
  let master = subs_master(
    [subs_media_line("SUBTITLES", "subs", "English", "subs.m3u8", "en", true)],
    "subs",
  )
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
      ("https://cdn.test/hls/subs.m3u8", subs_playlist(["en0.vtt"], 3.0)),
      ("https://cdn.test/hls/en0.vtt", "00:00:00.000 --> 00:00:01.000\nhi\n"),
    ],
    seen,
  )
  let message = try {
    let _media = @libavformat.StreamingMedia::open(
      subs_bytes(master),
      fetch,
      base_uri="https://cdn.test/hls/master.m3u8",
    )
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("subtitle rendition"))
  assert_true(message.contains("missing WEBVTT signature"))
}

///|
/// A subtitle playlist that cannot be fetched is an error too, and the message
/// names the step that failed.
test "hls subtitles: a failing rendition fetch is an error" {
  let master = subs_master(
    [subs_media_line("SUBTITLES", "subs", "English", "subs.m3u8", "en", false)],
    "subs",
  )
  let seen : Array[String] = []
  let fetch : @libavformat.MediaFetch = (uri, _, _) => {
    seen.push(uri)
    if uri.has_suffix("master.m3u8") {
      Ok(subs_bytes(master))
    } else if uri.has_suffix("video.m3u8") {
      Ok(subs_bytes(subs_variant()))
    } else {
      Err("404")
    }
  }
  let message = try {
    let _media = @libavformat.StreamingMedia::open(
      subs_bytes(master),
      fetch,
      base_uri="https://cdn.test/hls/master.m3u8",
    )
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("subtitle rendition fetch failed"))
}

///|
/// A `NOTE` block that spells out the header name must not be read as the
/// segment's `X-TIMESTAMP-MAP`, and cues stay as written when it is present.
test "hls subtitles: X-TIMESTAMP-MAP does not move cue times" {
  let master = subs_master(
    [subs_media_line("SUBTITLES", "subs", "English", "subs.m3u8", "en", true)],
    "subs",
  )
  let seg =
    #|WEBVTT
    #|X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:10.000
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|mapped
  let seen : Array[String] = []
  let fetch = subs_fetch(
    [
      ("https://cdn.test/hls/master.m3u8", master),
      ("https://cdn.test/hls/v/video.m3u8", subs_variant()),
      ("https://cdn.test/hls/subs.m3u8", subs_playlist(["en0.vtt"], 3.0)),
      ("https://cdn.test/hls/en0.vtt", seg),
    ],
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    subs_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let cue = media.subtitles().unwrap().cue(0).unwrap()
  assert_eq(cue.start_ms(), 0L)
  assert_eq(cue.end_ms(), 1000L)
}
