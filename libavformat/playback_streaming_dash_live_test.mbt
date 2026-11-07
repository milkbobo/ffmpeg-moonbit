///|
/// Black-box tests for live DASH MPD refresh. Segments come from the
/// repository's own AAC encoder and fMP4 writer; the MPD text is built here so
/// `type="dynamic"`, the sliding window and its `SegmentTimeline` can be
/// advanced deterministically without any network access.

///|
/// Encode `frames` AAC frames once and hand back the fMP4 initialization
/// segment plus a builder for a media segment covering two frames each.
fn dash_live_fixture(frames : Int32) -> (Bytes, (Int32) -> Bytes) {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let units : Array[Bytes] = []
  for frame in 0..<frames {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    units.push(encoder.encode_frame([samples]).unwrap())
  }
  let init = @libavformat.fmp4_aac_init_segment(48000, 1).unwrap()
  let build = fn(from : Int32) -> Bytes {
    let samples : Array[@libavformat.Fmp4Sample] = []
    for i in from..<(from + 2) {
      samples.push(@libavformat.fmp4_sample(units[i][7:].to_owned(), 1024, true))
    }
    @libavformat.fmp4_media_segment(
      1,
      from / 2 + 1,
      from.to_int64() * 1024L,
      samples,
    ).unwrap()
  }
  (init, build)
}

///|
/// Build a dynamic MPD whose single audio representation lists `count`
/// segments of 2048 ticks (two AAC frames) starting at 0, numbered from
/// `start_number`.
fn dash_live_mpd(start_number : Int64, first_time : Int64, count : Int64) -> String {
  let sb = StringBuilder()
  sb.write_string(
    "<MPD type=\"dynamic\" profiles=\"urn:mpeg:dash:profile:isoff-live:2011\">",
  )
  sb.write_string("<Period><AdaptationSet mimeType=\"audio/mp4\" ")
  sb.write_string("contentType=\"audio\" lang=\"und\">")
  sb.write_string("<Representation id=\"a1\" bandwidth=\"64000\" ")
  sb.write_string("codecs=\"mp4a.40.2\" audioSamplingRate=\"48000\">")
  sb.write_string("<SegmentTemplate timescale=\"48000\" ")
  sb.write_string("initialization=\"init.mp4\" media=\"seg-$Number$.m4s\" ")
  sb.write_string("startNumber=\"\{start_number}\"><SegmentTimeline>")
  sb.write_string(
    "<S t=\"\{first_time}\" d=\"2048\" r=\"\{count - 1L}\"/></SegmentTimeline>",
  )
  sb.write_string("</SegmentTemplate></Representation></AdaptationSet></Period>")
  sb.write_string("</MPD>")
  sb.to_string()
}

///|
fn dash_live_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Serve `init.mp4` and `seg-<n>.m4s` from the fixture builder. Anything else
/// is a fixture bug, not a session-under-test bug.
fn dash_live_fetch(
  init : Bytes,
  build : (Int32) -> Bytes,
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    let mut name = uri
    let mut last_slash = -1
    for i = 0; i < name.length(); i = i + 1 {
      if name[i] == '/'.to_int().to_uint16() {
        last_slash = i
      }
    }
    if last_slash >= 0 {
      name = name[last_slash + 1:].to_owned()
    }
    if name == "init.mp4" {
      return Ok(init)
    }
    if !name.has_prefix("seg-") || !name.has_suffix(".m4s") {
      return Err("unexpected URI: \{uri}")
    }
    let digits = name[4:name.length() - 4]
    let mut n = 0
    let mut valid = digits.length() > 0
    for c in digits {
      let v = c.to_int() - '0'.to_int()
      if v < 0 || v > 9 || n > (2147483647 - v) / 10 {
        valid = false
        break
      }
      n = n * 10 + v
    }
    if !valid || n < 1 {
      return Err("unknown segment: \{name}")
    }
    Ok(build((n - 1) * 2))
  }
}

///|
fn dash_live_drain(
  media : @libavformat.StreamingMedia,
) -> Array[@libavformat.StreamingPacket] raise {
  let out : Array[@libavformat.StreamingPacket] = []
  while true {
    match media.next_packet() {
      Some(p) => out.push(p)
      None => break
    }
  }
  out
}

///|
/// A `type="dynamic"` MPD opens as a live session and still ends at the last
/// segment of its window - there is no `mediaPresentationDuration` to report.
test "dash live: dynamic MPD opens as live and drains its window" {
  let (init, build) = dash_live_fixture(6)
  let text = dash_live_mpd(1L, 0L, 3L)
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(text),
    dash_live_fetch(init, build),
  )
  assert_eq(media.format_name(), "dash")
  assert_true(media.is_live())
  assert_true(media.duration_seconds() is None)
  let packets = dash_live_drain(media)
  assert_eq(packets.length(), 6)
  assert_eq(packets[0].segment_sequence, 1L)
  assert_eq(packets[4].segment_sequence, 3L)
  assert_eq(media.reload_count(), 0)
}

///|
/// A static MPD is not live: it must never pick up a refresh budget.
test "dash live: static MPD is not live" {
  let (init, build) = dash_live_fixture(4)
  let text = dash_live_mpd(1L, 0L, 2L).replace(
    old="type=\"dynamic\"",
    new="type=\"static\" mediaPresentationDuration=\"PT0.09S\"",
  )
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(text),
    dash_live_fetch(init, build),
    playlist_fetch=Some(dash_live_fetch(init, build)),
    max_reloads=4,
  )
  assert_false(media.is_live())
  let packets = dash_live_drain(media)
  assert_eq(packets.length(), 4)
  assert_eq(media.reload_count(), 0)
}

///|
/// A refreshed MPD that appended segments continues the same timeline: no
/// repeat of what was already played, no gap, monotonic pts.
test "dash live: reload continues after the last played segment" {
  let (init, build) = dash_live_fixture(12)
  let fetch = dash_live_fetch(init, build)
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(dash_live_mpd(1L, 0L, 3L)),
    fetch,
  )
  let first = dash_live_drain(media)
  assert_eq(first.length(), 6)
  assert_true(media.next_packet() is None)
  // The window grew to five segments without dropping anything.
  let refreshed = @libavformat.av_dash_parse(dash_live_mpd(1L, 0L, 5L)).unwrap()
  media.reload_dash(refreshed)
  assert_eq(media.reload_count(), 1)
  let rest = dash_live_drain(media)
  assert_eq(rest.length(), 4)
  assert_eq(rest[0].segment_sequence, 4L)
  assert_false(rest[0].discontinuity)
  let mut previous = first[first.length() - 1].pts
  for p in rest {
    assert_true(p.pts > previous)
    previous = p.pts
  }
}

///|
/// A sliding window that dropped the segments we already played but kept the
/// presentation continuous must not be flagged as a discontinuity.
test "dash live: sliding window keeps the timeline continuous" {
  let (init, build) = dash_live_fixture(12)
  let fetch = dash_live_fetch(init, build)
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(dash_live_mpd(1L, 0L, 3L)),
    fetch,
  )
  let first = dash_live_drain(media)
  assert_eq(first.length(), 6)
  // Window now lists segments 4 and 5 only, starting exactly where we left.
  let refreshed = @libavformat.av_dash_parse(
    dash_live_mpd(4L, 6144L, 2L),
  ).unwrap()
  media.reload_dash(refreshed)
  let rest = dash_live_drain(media)
  assert_eq(rest.length(), 4)
  assert_eq(rest[0].segment_sequence, 4L)
  assert_false(rest[0].discontinuity)
}

///|
/// A window that expired segments we never played leaves a hole in the
/// presentation; the next segment must be flagged so the decoder resets.
test "dash live: expired gap is flagged as a discontinuity" {
  let (init, build) = dash_live_fixture(16)
  let fetch = dash_live_fetch(init, build)
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(dash_live_mpd(1L, 0L, 3L)),
    fetch,
  )
  let first = dash_live_drain(media)
  assert_eq(first.length(), 6)
  // Expected next start was 6144 (t=4096 + 2048); the window jumps to 10240.
  let refreshed = @libavformat.av_dash_parse(
    dash_live_mpd(6L, 10240L, 2L),
  ).unwrap()
  media.reload_dash(refreshed)
  let rest = dash_live_drain(media)
  assert_eq(rest.length(), 4)
  assert_eq(rest[0].segment_sequence, 6L)
  assert_true(rest[0].discontinuity)
  // Only the first segment of the jump carries the flag.
  assert_false(rest[2].discontinuity)
}

///|
/// Refreshing with an MPD that has not moved is not an error: the cursor
/// stays parked and the session survives, so the caller can poll again.
test "dash live: stale window parks the cursor without damage" {
  let (init, build) = dash_live_fixture(8)
  let fetch = dash_live_fetch(init, build)
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(dash_live_mpd(1L, 0L, 3L)),
    fetch,
  )
  let first = dash_live_drain(media)
  assert_eq(first.length(), 6)
  let stale = @libavformat.av_dash_parse(dash_live_mpd(1L, 0L, 3L)).unwrap()
  media.reload_dash(stale)
  assert_eq(media.reload_count(), 1)
  assert_true(media.next_packet() is None)
  // A later refresh with a grown window still works.
  let grown = @libavformat.av_dash_parse(dash_live_mpd(1L, 0L, 4L)).unwrap()
  media.reload_dash(grown)
  let rest = dash_live_drain(media)
  assert_eq(rest.length(), 2)
  assert_eq(rest[0].segment_sequence, 4L)
}

///|
/// With a control-plane fetch hook the window advances on its own once the
/// segments run out, bounded by `max_reloads`.
test "dash live: mpd_fetch auto-refreshes the window" {
  let (init, build) = dash_live_fixture(12)
  let segment_fetch = dash_live_fetch(init, build)
  let mut polls = 0
  let mpd_fetch : @libavformat.MediaFetch = (_, _, _) => {
    polls = polls + 1
    // Each poll widens the window by one segment, up to four.
    let count = if polls > 3 { 4L } else { 3L + polls.to_int64() }
    Ok(dash_live_bytes(dash_live_mpd(1L, 0L, count)))
  }
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(dash_live_mpd(1L, 0L, 3L)),
    segment_fetch,
    playlist_fetch=Some(mpd_fetch),
    max_reloads=3,
  )
  assert_true(media.is_live())
  let packets = dash_live_drain(media)
  // Three segments from the first window plus one gained per refresh.
  assert_eq(packets.length(), 12)
  assert_eq(media.reload_count(), 3)
  assert_eq(polls, 3)
}

///|
/// Only same-kind refreshes are accepted: an HLS session refuses `reload_dash`
/// and a DASH session refuses the HLS `reload`.
test "dash live: cross-kind refresh is refused" {
  let (init, build) = dash_live_fixture(6)
  let fetch = dash_live_fetch(init, build)
  let dash = @libavformat.StreamingMedia::open(
    dash_live_bytes(dash_live_mpd(1L, 0L, 2L)),
    fetch,
  )
  let hls = @libavformat.StreamingMedia::open(
    dash_live_bytes("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\ns0.ts\n"),
    (_, _, _) => Err("no resources"),
  )
  let mpd = @libavformat.av_dash_parse(dash_live_mpd(1L, 0L, 3L)).unwrap()
  let playlist = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\ns0.ts\n",
  ).unwrap()
  // reload_dash on an HLS session.
  let dash_on_hls = try {
    hls.reload_dash(mpd)
    false
  } catch {
    @libavformat.MediaError::DemuxError(_) => true
    _ => false
  }
  assert_true(dash_on_hls)
  // HLS reload on a DASH session.
  let hls_on_dash = try {
    dash.reload(playlist)
    false
  } catch {
    @libavformat.MediaError::DemuxError(_) => true
    _ => false
  }
  assert_true(hls_on_dash)
  // Neither rejected call moved anything.
  assert_eq(dash.reload_count(), 0)
  assert_eq(hls.reload_count(), 0)
}

///|
/// A single-file `SegmentBase` representation has no segment list to continue
/// through, so a refresh is refused rather than resuming at byte zero.
test "dash live: SegmentBase representation cannot be refreshed" {
  let (_, build) = dash_live_fixture(4)
  let text = "<MPD type=\"dynamic\"><Period><AdaptationSet>"
  let text = text +
    "<Representation id=\"a1\" bandwidth=\"64000\" codecs=\"mp4a.40.2\">"
  let text = text + "<BaseURL>all.mp4</BaseURL>"
  let text = text + "<SegmentBase indexRange=\"0-1023\">"
  let text = text + "<Initialization range=\"0-511\"/></SegmentBase>"
  let text = text + "</Representation></AdaptationSet></Period></MPD>"
  let media = @libavformat.StreamingMedia::open(
    dash_live_bytes(text),
    dash_live_fetch(b"", build),
  )
  assert_true(media.is_live())
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let refused = try {
    media.reload_dash(mpd)
    false
  } catch {
    @libavformat.MediaError::DemuxError(_) => true
    _ => false
  }
  assert_true(refused)
  assert_eq(media.reload_count(), 0)
}
