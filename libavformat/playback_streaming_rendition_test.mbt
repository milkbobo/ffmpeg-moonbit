///|
/// Black-box tests for HLS separate audio renditions (`EXT-X-MEDIA` with
/// `TYPE=AUDIO`). A variant that declares `AUDIO="group"` carries no audio of
/// its own; `decode_audio` has to follow the rendition playlist instead.
///
/// The fixtures deliberately give the variant and the rendition *different*
/// segment counts, so "which playlist produced this PCM" is observable from
/// the sample count alone - no video encoder is needed to build a video-only
/// variant.

///|
/// One AAC frame per TS segment, so packet and sample counts are exact.
fn rendition_segments(count : Int32) -> Array[Bytes] {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let out : Array[Bytes] = []
  for frame in 0..<count {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    let mux = @libavformat.ts_muxer_new(video=false)
    mux.write_audio(0L, encoder.encode_frame([samples]).unwrap())
    out.push(mux.finish())
  }
  out
}

///|
fn rendition_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A VOD media playlist naming `uris` in order.
fn rendition_playlist(uris : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n")
  for uri in uris {
    sb.write_string("#EXTINF:0.064,\n\{uri}\n")
  }
  sb.write_string("#EXT-X-ENDLIST\n")
  sb.to_string()
}

///|
/// A master playlist with one `EXT-X-MEDIA` audio line (verbatim, so tests can
/// vary `DEFAULT`/`URI`) and one variant that names `group` (empty = no
/// `AUDIO` attribute at all).
fn rendition_master(media_line : String, group : String) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n")
  if media_line != "" {
    sb.write_string(media_line)
    sb.write_string("\n")
  }
  sb.write_string("#EXT-X-STREAM-INF:BANDWIDTH=200000,")
  sb.write_string("CODECS=\"avc1.42E01E,mp4a.40.2\"")
  if group != "" {
    sb.write_string(",AUDIO=\"" + group + "\"")
  }
  sb.write_string("\nv/video.m3u8\n")
  sb.to_string()
}

///|
/// The canonical audio rendition line used by most cases.
fn rendition_audio_line(uri : String, is_default : Bool) -> String {
  let d = if is_default { "YES" } else { "NO" }
  "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\"," +
  "DEFAULT=" +
  d +
  ",AUTOSELECT=YES,URI=\"" +
  uri +
  "\""
}

///|
/// A fetch hook that serves the master, the variant playlist, the rendition
/// playlist and their segments by basename, recording every URI it was asked
/// for so URI resolution can be asserted.
fn rendition_fetch(
  master : String,
  audio_playlist : String,
  variant_playlist : String,
  variant_segments : Array[Bytes],
  audio_segments : Array[Bytes],
  seen : Array[String],
) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    seen.push(uri)
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
    if name == "master.m3u8" {
      return Ok(rendition_bytes(master))
    }
    if name == "video.m3u8" {
      return Ok(rendition_bytes(variant_playlist))
    }
    if name == "audio.m3u8" {
      return Ok(rendition_bytes(audio_playlist))
    }
    if name.has_prefix("v") && name.has_suffix(".ts") {
      let digits = name[1:name.length() - 3]
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
      if valid && n < variant_segments.length() {
        return Ok(variant_segments[n])
      }
      return Err("unknown variant segment: \{name}")
    }
    if name.has_prefix("a") && name.has_suffix(".ts") {
      let digits = name[1:name.length() - 3]
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
      if valid && n < audio_segments.length() {
        return Ok(audio_segments[n])
      }
      return Err("unknown audio segment: \{name}")
    }
    Err("unexpected URI: \{uri}")
  }
}

///|
/// The headline case: `decode_audio` on a variant with `AUDIO="aud"` returns
/// the rendition's PCM, not `UnsupportedCodec`. The rendition has three
/// segments against the variant's one, so the sample count identifies which
/// playlist was decoded.
test "hls rendition: decode_audio follows the separate audio rendition" {
  let variant_segments = rendition_segments(1)
  let audio_segments = rendition_segments(3)
  let seen : Array[String] = []
  let master = rendition_master(rendition_audio_line("audio.m3u8", true), "aud")
  let fetch = rendition_fetch(
    master,
    rendition_playlist(["a0.ts", "a1.ts", "a2.ts"]),
    rendition_playlist(["v0.ts"]),
    variant_segments,
    audio_segments,
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    rendition_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  // The variant resolved to its own subdirectory, the rendition to the
  // master's directory - proving rendition URIs resolve against the master.
  assert_eq(media.variant_uri(), Some("https://cdn.test/hls/v/video.m3u8"))
  assert_true(media.audio_track() is Some(_))
  assert_eq(media.audio_track().unwrap().variant_uri(), None)
  let audio = media.decode_audio()
  assert_eq(audio.samples()[0].length(), 3 * 1024)
  assert_eq(audio.sample_rate(), 48000)
  assert_true(seen.contains("https://cdn.test/hls/audio.m3u8"))
}

///|
/// Without an `AUDIO` attribute there is no rendition, and the variant's own
/// audio keeps decoding as before.
test "hls rendition: a variant without AUDIO decodes its own audio" {
  let variant_segments = rendition_segments(2)
  let seen : Array[String] = []
  let master = rendition_master("", "")
  let fetch = rendition_fetch(
    master,
    rendition_playlist(["a0.ts"]),
    rendition_playlist(["v0.ts", "v0.ts"]),
    variant_segments,
    rendition_segments(1),
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    rendition_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_true(media.audio_track() is None)
  // The variant playlist fixture names two of the same segment, so the count
  // is the variant's own, not the rendition's one.
  let audio = media.decode_audio()
  assert_eq(audio.samples()[0].length(), 2 * 1024)
}

///|
/// A group whose only member has no `URI` is muxed into the variant itself;
/// nothing separate to open, so `audio_track` stays empty.
test "hls rendition: URI-less group is not opened separately" {
  let seen : Array[String] = []
  let master = rendition_master(
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",DEFAULT=YES", "aud",
  )
  let fetch = rendition_fetch(
    master,
    rendition_playlist(["a0.ts"]),
    rendition_playlist(["v0.ts"]),
    rendition_segments(1),
    rendition_segments(1),
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    rendition_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_true(media.audio_track() is None)
}

///|
/// With no `DEFAULT=YES` the first URI-bearing member of the group wins, which
/// is what `hls_read_header` falls back to.
test "hls rendition: first member is used when none is default" {
  let seen : Array[String] = []
  let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"A\"," +
    "URI=\"audio.m3u8\"\n" +
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"B\",URI=\"second.m3u8\"\n" +
    "#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO=\"aud\"\nv/video.m3u8\n"
  let fetch = rendition_fetch(
    master,
    rendition_playlist(["a0.ts"]),
    rendition_playlist(["v0.ts"]),
    rendition_segments(1),
    rendition_segments(1),
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    rendition_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  assert_true(media.audio_track() is Some(_))
  // The first member won; the second was never even fetched.
  assert_true(seen.contains("https://cdn.test/hls/audio.m3u8"))
  assert_false(seen.contains("https://cdn.test/hls/second.m3u8"))
}

///|
/// A rendition playlist that cannot be fetched fails the whole open instead of
/// silently falling back to silence.
test "hls rendition: a failing rendition fetch is an error" {
  let seen : Array[String] = []
  let master = rendition_master(rendition_audio_line("audio.m3u8", true), "aud")
  let fetch : @libavformat.MediaFetch = (uri, _, _) => {
    seen.push(uri)
    if uri.has_suffix("master.m3u8") {
      Ok(rendition_bytes(master))
    } else if uri.has_suffix("video.m3u8") {
      Ok(rendition_bytes(rendition_playlist(["v0.ts"])))
    } else {
      Err("404")
    }
  }
  let failed = try {
    let _media = @libavformat.StreamingMedia::open(
      rendition_bytes(master),
      fetch,
      base_uri="https://cdn.test/hls/master.m3u8",
    )
    false
  } catch {
    @libavformat.MediaError::DemuxError(m) => m.contains("audio rendition")
    _ => false
  }
  assert_true(failed)
}

///|
/// The variant session still yields its own packets while audio comes from the
/// rendition: `next_packet` is not redirected.
test "hls rendition: next_packet stays on the variant" {
  let seen : Array[String] = []
  let master = rendition_master(rendition_audio_line("audio.m3u8", true), "aud")
  let fetch = rendition_fetch(
    master,
    rendition_playlist(["a0.ts", "a1.ts", "a2.ts"]),
    rendition_playlist(["v0.ts"]),
    rendition_segments(1),
    rendition_segments(3),
    seen,
  )
  let media = @libavformat.StreamingMedia::open(
    rendition_bytes(master),
    fetch,
    base_uri="https://cdn.test/hls/master.m3u8",
  )
  let mut packets = 0
  while true {
    match media.next_packet() {
      Some(_) => packets = packets + 1
      None => break
    }
  }
  // One TS segment with one AAC frame: the variant's own count.
  assert_eq(packets, 1)
}
