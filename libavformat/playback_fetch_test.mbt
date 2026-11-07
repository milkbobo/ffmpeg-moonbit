///|
/// Black-box tests for the local-file MediaFetch adapter.

///|
test "fetch: path key strips scheme, host, query and fragment" {
  let cases : Array[(String, String)] = [
    ("seg0.ts", "seg0.ts"),
    ("./audio/seg1.ts", "seg1.ts"),
    ("/var/media/seg2.m4s", "seg2.m4s"),
    ("https://cdn.test/vod/seg3.ts", "seg3.ts"),
    ("//cdn.test/vod/seg4.ts", "seg4.ts"),
    ("https://cdn.test/vod/seg5.ts?token=a/b", "seg5.ts"),
    ("seg6.ts?next=https://cdn.test/a/../b", "seg6.ts"),
    ("seg7.ts#frag/ment", "seg7.ts"),
    ("https://cdn.test/vod/seg8.m4s?q=1#f", "seg8.m4s"),
  ]
  for (uri, expected) in cases {
    assert_eq(@libavformat.media_fetch_path_key(uri), Ok(expected))
  }
}

///|
test "fetch: unsafe resource names are rejected" {
  for
    uri in [
      "", "https://cdn.test/vod/", "..", ".", "a/..", "https://cdn.test/%2Fetc/passwd",
      "https://cdn.test/x%5Cy", "seg\\evil.ts",
    ] {
    assert_true(@libavformat.media_fetch_path_key(uri) is Err(_))
  }
}

///|
test "fetch: map adapter resolves by filename and applies byte ranges" {
  let resources : Map[String, Bytes] = {
    "seg.ts": b"0123456789",
    "init.mp4": b"abcdef",
  }
  let fetch = @libavformat.media_fetch_from_map(resources)
  assert_eq(fetch("seg.ts", 0L, -1L), Ok(b"0123456789"))
  assert_eq(
    fetch("https://cdn.test/vod/seg.ts?token=a/b", 0L, -1L),
    Ok(b"0123456789"),
  )
  assert_eq(fetch("seg.ts", 3L, 4L), Ok(b"3456"))
  assert_eq(fetch("seg.ts", 7L, -1L), Ok(b"789"))
  assert_eq(fetch("seg.ts", 10L, 0L), Ok(b""))
  assert_eq(fetch("init.mp4", 1L, 3L), Ok(b"bcd"))
}

///|
test "fetch: invalid ranges and unknown resources return errors" {
  let resources : Map[String, Bytes] = { "seg.ts": b"0123456789" }
  let fetch = @libavformat.media_fetch_from_map(resources)
  assert_true(fetch("missing.ts", 0L, -1L) is Err(_))
  assert_true(fetch("seg.ts", -1L, 2L) is Err(_))
  assert_true(fetch("seg.ts", 0L, -2L) is Err(_))
  assert_true(fetch("seg.ts", 11L, -1L) is Err(_))
  assert_true(fetch("seg.ts", 8L, 4L) is Err(_))
  assert_true(fetch("https://cdn.test/vod/", 0L, -1L) is Err(_))
}

///|
test "fetch: reader sees only the bare filename" {
  let seen : Array[String] = []
  let fetch = @libavformat.media_fetch_from_reader(key => {
    seen.push(key)
    Ok(b"payload")
  })
  assert_eq(fetch("https://cdn.test/a/b/seg.ts?x=1", 0L, -1L), Ok(b"payload"))
  assert_eq(fetch("init.mp4", 0L, 7L), Ok(b"payload"))
  assert_eq(seen, ["seg.ts", "init.mp4"])
}

///|
test "fetch: adapter feeds a real HLS StreamingMedia session" {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let mux = @libavformat.ts_muxer_new(video=false)
  for frame in 0..<2 {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    mux.write_audio(
      frame.to_int64() * 1920L,
      encoder.encode_frame([samples]).unwrap(),
    )
  }
  let ts = mux.finish()
  let resources : Map[String, Bytes] = { "a.ts": ts }
  let fetch = @libavformat.media_fetch_from_map(resources)
  let playlist =
    #|#EXTM3U
    #|#EXT-X-TARGETDURATION:1
    #|#EXTINF:0.064,
    #|https://cdn.test/vod/a.ts?token=x/y
    #|#EXT-X-ENDLIST
    #|
  let bytes : Array[Byte] = []
  for c in playlist {
    bytes.push(c.to_int().to_byte())
  }
  let media = @libavformat.StreamingMedia::open(Bytes::from_array(bytes), fetch)
  let audio = media.decode_audio()
  assert_eq(audio.codec_id, "aac")
  assert_eq(audio.samples[0].length(), 2 * 1024)
}
