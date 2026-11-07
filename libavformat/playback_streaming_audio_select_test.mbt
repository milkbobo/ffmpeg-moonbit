///|
/// Black-box tests for picking an audio language: `audio_renditions()` lists the
/// variant's `EXT-X-MEDIA:TYPE=AUDIO` group without fetching, `select_audio`
/// swaps the delegated sub-session, and `decode_audio` follows whatever is
/// active.

///|
fn asel_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A VOD media playlist of `count` 3-second segments. The duration is the
/// observable that tells one rendition's sub-session from another's, without
/// needing real audio samples.
fn asel_playlist(prefix : String, count : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n")
  for i = 0; i < count; i = i + 1 {
    sb.write_string("#EXTINF:3.0,\n\{prefix}\{i}.aac\n")
  }
  sb.write_string("#EXT-X-ENDLIST\n")
  sb.to_string()
}

///|
/// A master playlist with two audio renditions in one group. French comes first
/// and English carries `DEFAULT=YES`, so "default wins over position" is
/// observable from the selected index alone. English's playlist holds two
/// segments and French's one, which makes the active sub-session identifiable.
fn asel_master() -> String {
  "#EXTM3U\n" +
  "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Francais\"," +
  "DEFAULT=NO,AUTOSELECT=YES,LANGUAGE=\"fr\",URI=\"afr.m3u8\"\n" +
  "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\"," +
  "DEFAULT=YES,AUTOSELECT=YES,LANGUAGE=\"en\",URI=\"aen.m3u8\"\n" +
  "#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO=\"aud\"\nv/video.m3u8\n"
}

///|
fn asel_fetch(
  files : Map[String, String],
  seen : Array[String],
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    seen.push(uri)
    match files.get(uri) {
      Some(text) => Ok(asel_bytes(text))
      None => Err("404: \{uri}")
    }
  }
}

///|
fn asel_count(seen : Array[String], uri : String) -> Int32 {
  let mut n = 0
  for s in seen {
    if s == uri {
      n = n + 1
    }
  }
  n
}

///|
fn asel_hls_files() -> Map[String, String] {
  let files : Map[String, String] = Map([])
  files["https://cdn.test/hls/master.m3u8"] = asel_master()
  files["https://cdn.test/hls/v/video.m3u8"] = asel_playlist("v", 1)
  files["https://cdn.test/hls/aen.m3u8"] = asel_playlist("aen", 2)
  files["https://cdn.test/hls/afr.m3u8"] = asel_playlist("afr", 1)
  files
}

///|
/// The rendition list carries what a language menu needs, `DEFAULT=YES` decides
/// the starting track even when it is not listed first, and the non-default
/// rendition is never touched at open time.
test "audio select: HLS lists the AUDIO group and starts on DEFAULT" {
  let files = asel_hls_files()
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(asel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let renditions = media.audio_renditions()
  assert_eq(renditions.length(), 2)
  assert_eq(renditions[0].language(), "fr")
  assert_eq(renditions[0].name(), "Francais")
  assert_eq(renditions[0].is_default(), false)
  assert_eq(renditions[0].uri(), "https://cdn.test/hls/afr.m3u8")
  assert_eq(renditions[1].language(), "en")
  assert_eq(renditions[1].is_default(), true)
  // Position 0 is French, but the default flag wins.
  assert_eq(media.audio_selected(), 1)
  let track = media.audio_track().unwrap()
  assert_eq(track.duration_seconds(), Some(6.0))
  assert_eq(asel_count(seen, "https://cdn.test/hls/afr.m3u8"), 0)
}

///|
/// Switching opens the other rendition's playlist as the new sub-session and
/// points `audio_track` at it.
test "audio select: switching replaces the delegated sub-session" {
  let files = asel_hls_files()
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(asel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  media.select_audio(0)
  assert_eq(media.audio_selected(), 0)
  let track = media.audio_track().unwrap()
  assert_eq(track.duration_seconds(), Some(3.0))
  assert_eq(asel_count(seen, "https://cdn.test/hls/afr.m3u8"), 1)
}

///|
/// Re-applying the current selection must not restart the sub-session: a live
/// stream would fall back to the first window of its audio playlist.
test "audio select: re-selecting the active rendition is a no-op" {
  let files = asel_hls_files()
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(asel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  media.select_audio(0)
  let before = asel_count(seen, "https://cdn.test/hls/afr.m3u8")
  media.select_audio(0)
  assert_eq(asel_count(seen, "https://cdn.test/hls/afr.m3u8"), before)
  assert_eq(media.audio_selected(), 0)
}

///|
/// A selection that cannot be opened leaves the previous track playing.
test "audio select: a failing switch keeps the previous track" {
  let files = asel_hls_files()
  let seen : Array[String] = []
  let base = asel_fetch(files, seen)
  // The French rendition's playlist goes missing after the session opened.
  let broken : Array[Bool] = [false]
  let fetch : @libavformat.MediaFetch = (uri, offset, length) => {
    if broken[0] && uri.has_suffix("afr.m3u8") {
      return Err("gone")
    }
    base(uri, offset, length)
  }
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(asel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  broken[0] = true
  let message = try {
    media.select_audio(0)
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("audio rendition fetch failed"))
  assert_eq(media.audio_selected(), 1)
  assert_eq(media.audio_track().unwrap().duration_seconds(), Some(6.0))
}

///|
/// An out-of-range selection is refused instead of silently clamping.
test "audio select: out of range index is an error" {
  let files = asel_hls_files()
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(asel_master()),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let message = try {
    media.select_audio(2)
    ""
  } catch {
    @libavformat.MediaError::DemuxError(m) => m
    _ => ""
  }
  assert_true(message.contains("out of range"))
  assert_eq(media.audio_selected(), 1)
}

///|
/// A variant that carries its own audio has nothing to offer.
test "audio select: a variant without an AUDIO group offers no choices" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  files["https://cdn.test/hls/v/video.m3u8"] = asel_playlist("v", 1)
  let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200000\nv/video.m3u8\n"
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_eq(media.audio_renditions().length(), 0)
  assert_eq(media.audio_selected(), -1)
  assert_true(media.audio_track() is None)
}

///|
/// A group whose entries are all muxed (`URI`-less) has no selectable member:
/// the variant's own audio is already the one playing.
test "audio select: a group of muxed renditions offers no choices" {
  let files : Map[String, String] = Map([])
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  files["https://cdn.test/hls/v/video.m3u8"] = asel_playlist("v", 1)
  let master = "#EXTM3U\n" +
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\"," +
    "DEFAULT=YES,LANGUAGE=\"en\"\n" +
    "#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO=\"aud\"\nv/video.m3u8\n"
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_eq(media.audio_renditions().length(), 0)
  assert_eq(media.audio_selected(), -1)
  assert_true(media.audio_track() is None)
}

///|
/// The group is filtered by `TYPE`, not just by `GROUP-ID`: a subtitle member
/// that shares the audio group's id must not appear as an audio language, and
/// must never be fetched.
test "audio select: a same-group subtitle rendition is not an audio choice" {
  let files = asel_hls_files()
  files["https://cdn.test/hls/master.m3u8"] = "#EXTM3U\n" +
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\"," +
    "DEFAULT=YES,AUTOSELECT=YES,LANGUAGE=\"en\",URI=\"aen.m3u8\"\n" +
    "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"aud\",NAME=\"Subs\"," +
    "DEFAULT=NO,AUTOSELECT=YES,LANGUAGE=\"de\",URI=\"ade.m3u8\"\n" +
    "#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO=\"aud\"\nv/video.m3u8\n"
  files["https://cdn.test/hls/ade.m3u8"] = asel_playlist("ade", 1)
  let seen : Array[String] = []
  let fetch = asel_fetch(files, seen)
  let media = @libavformat.StreamingMedia::open(
    asel_bytes(files["https://cdn.test/hls/master.m3u8"]),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let renditions = media.audio_renditions()
  assert_eq(renditions.length(), 1)
  assert_eq(renditions[0].language(), "en")
  assert_eq(media.audio_selected(), 0)
  assert_eq(asel_count(seen, "https://cdn.test/hls/ade.m3u8"), 0)
}
