///|
/// WebVTT segment and master-playlist subtitle-rendition writers.

///|
test "hls subtitles: WebVTT segment layout" {
  let cues : Array[HlsVttCue] = [
    hls_vtt_cue_new(1050L, 2150L, "First cue"),
    hls_vtt_cue_new(3000L, 4500L, "Second\nline"),
  ]
  let vtt = hls_write_vtt_segment(cues)
  assert_eq(
    vtt,
    "WEBVTT\n\n" +
    "00:00:01.050 --> 00:00:02.150\nFirst cue\n\n" +
    "00:00:03.000 --> 00:00:04.500\nSecond\nline\n",
  )
}

///|
test "hls subtitles: master playlist names the subtitle group" {
  let variants : Array[HlsMasterVariant] = [
    HlsMasterVariant::new(
      "video.m3u8",
      800000,
      64,
      48,
      "avc1.42c00d",
      subtitle_group="subs",
    ),
  ]
  let renditions : Array[HlsMasterRendition] = [
    HlsMasterRendition::new(
      "SUBTITLES",
      "subs",
      "English",
      "subs.m3u8",
      language="en",
      is_default=true,
    ),
  ]
  let master = hls_write_master_playlist(variants, renditions~)
  assert_true(master.contains("TYPE=SUBTITLES"))
  assert_true(master.contains("GROUP-ID=\"subs\""))
  assert_true(master.contains("URI=\"subs.m3u8\""))
  assert_true(master.contains("SUBTITLES=\"subs\""))
  assert_true(master.contains("LANGUAGE=\"en\""))
}

///|
/// The writer and the reader are two halves of one contract: a WebVTT segment
/// this port emits for an HLS subtitle rendition must parse back to the same
/// cues, or a stream it produced itself would not be readable by it.

///|
/// Parse and unwrap, failing the test with the parser's own message.
fn vtt_cues(text : String) -> Array[HlsVttCue] raise Failure {
  match hls_vtt_parse(text) {
    Ok(cues) => cues
    Err(e) => fail("unexpected vtt parse error: \{e}")
  }
}

///|
/// `start-end:text` for every cue, so a whole document compares in one string.
fn vtt_summary(cues : Array[HlsVttCue]) -> String {
  let parts : Array[String] = []
  for cue in cues {
    parts.push("\{cue.start_ms}-\{cue.end_ms}:\{cue.text}")
  }
  parts.join("|")
}

///|
test "vtt reader round-trips the segment writer" {
  let cues : Array[HlsVttCue] = [
    hls_vtt_cue_new(0L, 1000L, "first line"),
    hls_vtt_cue_new(1500L, 2400L, "second\nwith a break"),
    // Past an hour, so the HH field is exercised as non-zero.
    hls_vtt_cue_new(3723456L, 3725456L, "late"),
  ]
  let text = hls_write_vtt_segment(cues)
  assert_eq(vtt_summary(vtt_cues(text)), vtt_summary(cues))
}

///|
test "vtt timestamps accept every documented shape" {
  // `HH:MM:SS.mmm`
  assert_eq(hls_vtt_parse_time("01:02:03.004"), Some(3723004L))
  // `MM:SS.mmm` - the WebVTT minimum.
  assert_eq(hls_vtt_parse_time("02:03.004"), Some(123004L))
  // `SS.mmm`, the lenient single-field form.
  assert_eq(hls_vtt_parse_time("03.004"), Some(3004L))
  // A comma decimal separator, as some writers emit.
  assert_eq(hls_vtt_parse_time("00:00:01,500"), Some(1500L))
  // No fraction at all.
  assert_eq(hls_vtt_parse_time("00:00:07"), Some(7000L))
  // Surrounding whitespace is not content.
  assert_eq(hls_vtt_parse_time(" 00:00:07.250 "), Some(7250L))
}

///|
test "vtt timestamps reject malformed fields" {
  assert_true(hls_vtt_parse_time("") is None)
  assert_true(hls_vtt_parse_time("abc") is None)
  assert_true(hls_vtt_parse_time("00:aa:01.000") is None)
  assert_true(hls_vtt_parse_time("00:00:01.00x") is None)
  // Four colon-separated fields is not a WebVTT timestamp.
  assert_true(hls_vtt_parse_time("00:00:00:01.000") is None)
}

///|
test "vtt document requires the WEBVTT signature" {
  match hls_vtt_parse("00:00:01.000 --> 00:00:02.000\nhi\n") {
    Ok(_) => fail("a document without the signature must be refused")
    Err(e) => assert_eq(e, "vtt: missing WEBVTT signature")
  }
  match hls_vtt_parse("   \n\t\n") {
    Ok(_) => fail("an empty document must be refused")
    Err(e) => assert_eq(e, "vtt: empty document")
  }
}

///|
test "vtt skips NOTE, STYLE, REGION and cue identifiers" {
  let text =
    #|WEBVTT
    #|
    #|NOTE this comment runs
    #|onto a second line
    #|
    #|STYLE
    #|::cue { color: red }
    #|
    #|REGION
    #|id:fred width:40%
    #|
    #|intro
    #|00:00:01.000 --> 00:00:02.000
    #|hello
  assert_eq(vtt_summary(vtt_cues(text)), "1000-2000:hello")
}

///|
test "vtt drops cue settings after the end timestamp" {
  // Settings are not rendered by anything downstream, and must not leak into
  // the end timestamp either: the end field is the first whitespace token.
  let text =
    #|WEBVTT
    #|
    #|00:00:01.000 --> 00:00:02.500 align:start position:10%,line:0
    #|left
  assert_eq(vtt_summary(vtt_cues(text)), "1000-2500:left")
}

///|
test "vtt joins a cue's lines" {
  let text =
    #|WEBVTT
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|a
    #|b
    #|
    #|00:00:02.000 --> 00:00:03.000
    #|c
  assert_eq(vtt_summary(vtt_cues(text)), "0-1000:a\nb|2000-3000:c")
}

///|
test "vtt accepts CRLF and a leading BOM" {
  let lf =
    #|WEBVTT
    #|
    #|00:00:01.000 --> 00:00:02.000
    #|hi
  let crlf = "\u{FEFF}" + lf.replace(old="\n", new="\r\n")
  assert_eq(vtt_summary(vtt_cues(crlf)), "1000-2000:hi")
}

///|
test "vtt rejects a cue that ends before it starts" {
  match hls_vtt_parse("WEBVTT\n\n00:00:05.000 --> 00:00:02.000\nbackwards\n") {
    Ok(_) => fail("a backwards cue must be refused")
    Err(e) => assert_eq(e, "vtt: cue ends before it starts (5000 -> 2000)")
  }
}

///|
test "vtt rejects a timing line with a broken bound" {
  match hls_vtt_parse("WEBVTT\n\n00:xx:05.000 --> 00:00:02.000\nhi\n") {
    Ok(_) => fail("a broken start timestamp must be refused")
    Err(e) => assert_eq(e, "vtt: bad cue start timestamp '00:xx:05.000'")
  }
  match hls_vtt_parse("WEBVTT\n\n00:00:05.000 --> nope\nhi\n") {
    Ok(_) => fail("a broken end timestamp must be refused")
    Err(e) => assert_eq(e, "vtt: bad cue end timestamp 'nope'")
  }
}

///|
test "vtt timestamp map converts 90kHz ticks to milliseconds" {
  let text =
    #|WEBVTT
    #|X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:10.000
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|hi
  let doc = match hls_vtt_parse_document(text) {
    Ok(d) => d
    Err(e) => fail("unexpected vtt parse error: \{e}")
  }
  // 900000 ticks at 90 kHz is 10 s; the local side says the same.
  let map = match doc.timestamp_map() {
    Some(m) => m
    None => fail("expected a timestamp map")
  }
  assert_eq(map.mpegts_ms(), 10000L)
  assert_eq(map.local_ms(), 10000L)
  // The map is reported, not applied: cue times stay as written.
  assert_eq(vtt_summary(doc.cues()), "0-1000:hi")
}

///|
test "vtt timestamp map ignores a NOTE body that spells the header" {
  let text =
    #|WEBVTT
    #|
    #|NOTE
    #|X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:10.000
    #|
    #|00:00:00.000 --> 00:00:01.000
    #|hi
  let doc = match hls_vtt_parse_document(text) {
    Ok(d) => d
    Err(e) => fail("unexpected vtt parse error: \{e}")
  }
  // The WEBVTT header region closed at the blank line, so this is a comment.
  assert_true(doc.timestamp_map() is None)
}

///|
test "vtt timestamp map tolerates one missing side" {
  let mpegts_only =
    #|WEBVTT
    #|X-TIMESTAMP-MAP=MPEGTS:180000
  let doc = match hls_vtt_parse_document(mpegts_only) {
    Ok(d) => d
    Err(e) => fail("unexpected vtt parse error: \{e}")
  }
  let map = match doc.timestamp_map() {
    Some(m) => m
    None => fail("expected a timestamp map")
  }
  assert_eq(map.mpegts_ms(), 2000L)
  assert_eq(map.local_ms(), 0L)
  // Nothing parseable at all is "no map declared", not an error.
  let garbage =
    #|WEBVTT
    #|X-TIMESTAMP-MAP=nonsense
  match hls_vtt_parse_document(garbage) {
    Ok(d) => assert_true(d.timestamp_map() is None)
    Err(e) => fail("unexpected vtt parse error: \{e}")
  }
}

///|
test "vtt segment duration rounds to the nearest millisecond" {
  assert_eq(hls_vtt_segment_ms(2.002), 2002L)
  assert_eq(hls_vtt_segment_ms(1.0004), 1000L)
  assert_eq(hls_vtt_segment_ms(1.0006), 1001L)
  // A missing or nonsensical EXTINF contributes nothing.
  assert_eq(hls_vtt_segment_ms(0.0), 0L)
  assert_eq(hls_vtt_segment_ms(-1.0), 0L)
}
