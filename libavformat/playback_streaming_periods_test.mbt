///|
/// Black-box tests for DASH Period continuation. A multi-Period MPD has to
/// keep playing past the Period it was opened on; the fixtures build every
/// Period from the repository's own AAC encoder and fMP4 writer.

///|
/// `count` AAC frames worth of fMP4, plus the initialization segment.
fn period_fixture(frames : Int32) -> (Bytes, (Int32) -> Bytes) {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let units : Array[Bytes] = []
  for frame in 0..<frames {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    units.push(encoder.encode_frame([samples]).unwrap().unwrap())
  }
  let init = @libavformat.fmp4_aac_init_segment(48000, 1).unwrap()
  let build = fn(from : Int32) -> Bytes {
    let samples : Array[@libavformat.Fmp4Sample] = []
    for i in from..<(from + 2) {
      samples.push(
        @libavformat.fmp4_sample(units[i][7:].to_owned(), 1024, true),
      )
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
/// One Period element with a single audio Representation. `prefix` names the
/// segments so each Period fetches its own bytes; `count` is the number of
/// two-frame segments; `content` switches the AdaptationSet to a video one so
/// a Period that carries no audio can be expressed.
fn period_element(
  id : String,
  prefix : String,
  count : Int64,
  content~ : String = "audio",
) -> String {
  let mime = if content == "audio" { "audio/mp4" } else { "video/mp4" }
  let codecs = if content == "audio" { "mp4a.40.2" } else { "avc1.42E01E" }
  let sb = StringBuilder()
  sb.write_string("<Period id=\"\{id}\"><AdaptationSet mimeType=\"\{mime}\" ")
  sb.write_string("contentType=\"\{content}\" lang=\"und\">")
  sb.write_string("<Representation id=\"\{id}-a1\" bandwidth=\"64000\" ")
  sb.write_string("codecs=\"\{codecs}\" audioSamplingRate=\"48000\">")
  sb.write_string("<SegmentTemplate timescale=\"48000\" ")
  sb.write_string("initialization=\"\{prefix}-init.mp4\" ")
  sb.write_string("media=\"\{prefix}-$Number$.m4s\" startNumber=\"1\">")
  sb.write_string(
    "<SegmentTimeline><S t=\"0\" d=\"2048\" r=\"\{count - 1L}\"/>",
  )
  sb.write_string("</SegmentTimeline></SegmentTemplate>")
  sb.write_string("</Representation></AdaptationSet></Period>")
  sb.to_string()
}

///|
fn period_mpd(periods : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("<MPD type=\"static\" mediaPresentationDuration=\"PT1S\">")
  for p in periods {
    sb.write_string(p)
  }
  sb.write_string("</MPD>")
  sb.to_string()
}

///|
fn period_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Serve `<prefix>-init.mp4` and `<prefix>-<n>.m4s` for `p0`/`p1` from the
/// same fixture builder, so a Period switch is visible in the URIs.
fn period_fetch(
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
    if name.has_suffix("-init.mp4") {
      return Ok(init)
    }
    if !name.has_suffix(".m4s") {
      return Err("unexpected URI: \{uri}")
    }
    let stem = name[0:name.length() - 4]
    let dash_at = {
      let mut found = -1
      for i = 0; i < stem.length(); i = i + 1 {
        if stem[i] == '-'.to_int().to_uint16() {
          found = i
        }
      }
      found
    }
    if dash_at < 0 || dash_at + 1 >= stem.length() {
      return Err("unknown segment: \{name}")
    }
    let digits = stem[dash_at + 1:]
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
fn period_drain(
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
/// A two-Period MPD must play both Periods back to back, restarting the
/// segment cursor at the boundary and flagging it as a discontinuity.
test "dash periods: playback continues into the next Period" {
  let (init, build) = period_fixture(8)
  let text = period_mpd([
    period_element("p0", "p0", 2L),
    period_element("p1", "p1", 2L),
  ])
  let media = @libavformat.StreamingMedia::open(
    period_bytes(text),
    period_fetch(init, build),
  )
  assert_eq(media.period_index(), 0)
  let packets = period_drain(media)
  assert_eq(packets.length(), 8)
  // Both Periods number their segments from 1, so the sequence restarts.
  assert_eq(packets[0].segment_sequence, 1L)
  assert_eq(packets[2].segment_sequence, 2L)
  assert_eq(packets[4].segment_sequence, 1L)
  assert_eq(packets[6].segment_sequence, 2L)
  // Only the first segment of the new Period is flagged.
  assert_false(packets[0].discontinuity)
  assert_false(packets[2].discontinuity)
  assert_true(packets[4].discontinuity)
  assert_false(packets[6].discontinuity)
  assert_eq(media.period_index(), 1)
}

///|
/// A Period that carries no matching AdaptationSet ends playback there
/// instead of misreading a video-only Period as audio.
test "dash periods: a Period without the same content type stops playback" {
  let (init, build) = period_fixture(8)
  let text = period_mpd([
    period_element("p0", "p0", 2L),
    period_element("p1", "p1", 2L, content="video"),
  ])
  let media = @libavformat.StreamingMedia::open(
    period_bytes(text),
    period_fetch(init, build),
  )
  let packets = period_drain(media)
  // Only the first Period plays; the video Period is not consumed as audio.
  assert_eq(packets.length(), 4)
  assert_eq(media.period_index(), 0)
  assert_eq(media.streams()[0].codec_id, "aac")
}

///|
/// Three Periods chain through in order, and the last one is reached.
test "dash periods: three Periods chain through" {
  let (init, build) = period_fixture(12)
  let text = period_mpd([
    period_element("p0", "p0", 1L),
    period_element("p1", "p1", 1L),
    period_element("p2", "p2", 1L),
  ])
  let media = @libavformat.StreamingMedia::open(
    period_bytes(text),
    period_fetch(init, build),
  )
  let packets = period_drain(media)
  assert_eq(packets.length(), 6)
  assert_eq(media.period_index(), 2)
  // Every Period restarts its own timeline, so exactly two boundaries are
  // flagged discontinuities.
  let mut flags = 0
  for p in packets {
    if p.discontinuity {
      flags = flags + 1
    }
  }
  assert_eq(flags, 2)
}

///|
/// Opening on a later Period plays from there and never rewinds.
test "dash periods: opening on a later Period starts there" {
  let (init, build) = period_fixture(8)
  let mpd = @libavformat.av_dash_parse(
    period_mpd([period_element("p0", "p0", 2L), period_element("p1", "p1", 2L)]),
  ).unwrap()
  let media = @libavformat.StreamingMedia::open_dash(
    mpd,
    period_fetch(init, build),
    period=1,
  )
  assert_eq(media.period_index(), 1)
  let packets = period_drain(media)
  assert_eq(packets.length(), 4)
  assert_eq(media.period_index(), 1)
  // The first packet of a session is never a discontinuity marker.
  assert_false(packets[0].discontinuity)
}

///|
/// A single-Period MPD reports Period 0 throughout and ends normally.
test "dash periods: single Period MPD is unchanged" {
  let (init, build) = period_fixture(4)
  let media = @libavformat.StreamingMedia::open(
    period_bytes(period_mpd([period_element("p0", "p0", 2L)])),
    period_fetch(init, build),
  )
  let packets = period_drain(media)
  assert_eq(packets.length(), 4)
  assert_eq(media.period_index(), 0)
  assert_true(media.next_packet() is None)
}
