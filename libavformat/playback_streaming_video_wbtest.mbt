///|
/// White-box video-line tests. The H.264 access units, avcC and reference
/// frame MD5s come from the repository's real x264 fMP4 fixtures, so the
/// streaming video path is checked against actual decoded pictures rather
/// than synthetic byte blobs.

///|
/// Split the five real H.264 samples into two fMP4 media segments and return
/// the init segment plus both media segments.
fn streaming_video_fmp4_fixture() -> (Bytes, Bytes, Bytes) {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let spec = fn(from : Int32, count : Int32, seq : Int32) -> Bytes {
    let list : Array[Fmp4Sample] = []
    for i in from..<(from + count) {
      list.push(fmp4_sample(samples[i], 9000, i == 0))
    }
    fmp4_media_segment(1, seq, from.to_int64() * 9000L, list).unwrap()
  }
  (init, spec(0, 3, 1), spec(3, 2, 2))
}

///|
/// HLS fMP4 playlist with an `EXT-X-MAP` init section and two media segments.
fn streaming_video_playlist() -> String {
  hls_write_media_playlist(
    [("v0.m4s", 0.3), ("v1.m4s", 0.2)],
    version=6,
    map_uri=Some("video-init.mp4"),
  )
}

///|
fn streaming_video_fetch(
  init : Bytes,
  first : Bytes,
  second : Bytes,
) -> MediaFetch {
  (uri, _, _) => {
    if uri == "video-init.mp4" {
      Ok(init)
    } else if uri == "v0.m4s" {
      Ok(first)
    } else if uri == "v1.m4s" {
      Ok(second)
    } else {
      Err("unexpected video URI: \{uri}")
    }
  }
}

///|
fn streaming_video_session(
  init : Bytes,
  first : Bytes,
  second : Bytes,
) -> StreamingMedia raise MediaError {
  let text = streaming_video_playlist()
  let bytes : Array[Byte] = []
  for c in text {
    bytes.push(c.to_int().to_byte())
  }
  StreamingMedia::open(
    Bytes::from_array(bytes),
    streaming_video_fetch(init, first, second),
  )
}

///|
test "streaming: decode_video spans fMP4 segments with real H.264 frames" {
  let (init, first, second) = streaming_video_fmp4_fixture()
  let media = streaming_video_session(init, first, second)
  let frames = media.decode_video()
  assert_eq(frames.length(), 5)
  assert_eq(media.streams().length(), 1)
  assert_eq(media.streams()[0].codec_id, "h264")
  assert_eq(media.streams()[0].width, 64)
  assert_eq(media.streams()[0].height, 48)
  for f in frames {
    assert_eq(f.width(), 64)
    assert_eq(f.height(), 48)
    assert_eq(f.yuv_bytes().length(), 64 * 48 * 3 / 2)
  }
}

///|
test "streaming: decode_video matches FFmpeg reference frame MD5s" {
  let (init, first, second) = streaming_video_fmp4_fixture()
  let frames = streaming_video_session(init, first, second).decode_video()
  assert_eq(frames.length(), fmp4_h264_refs.length())
  let hex = "0123456789abcdef"
  for i = 0; i < frames.length(); i = i + 1 {
    let yuv = frames[i].yuv_bytes()
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, yuv, yuv.length())
    let text = StringBuilder()
    for byte in digest {
      text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
      text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
    }
    assert_eq(text.to_string(), fmp4_h264_refs[i], msg="frame \{i}")
  }
}

///|
test "streaming: decode_video survives a discontinuity by rebuilding the decoder" {
  let (init, first, second) = streaming_video_fmp4_fixture()
  // The second segment restarts from an IDR-less sample set after a
  // discontinuity; a rebuilt decoder must still emit pictures rather than
  // aborting on a stale reference frame list.
  let text =
    #|#EXTM3U
    #|#EXT-X-VERSION:6
    #|#EXT-X-TARGETDURATION:1
    #|#EXT-X-MAP:URI="video-init.mp4"
    #|#EXTINF:0.3,
    #|v0.m4s
    #|#EXT-X-DISCONTINUITY
    #|#EXTINF:0.2,
    #|v1.m4s
    #|#EXT-X-ENDLIST
    #|
  let bytes : Array[Byte] = []
  for c in text {
    bytes.push(c.to_int().to_byte())
  }
  let media = StreamingMedia::open(
    Bytes::from_array(bytes),
    streaming_video_fetch(init, first, second),
  )
  let frames = media.decode_video()
  assert_eq(frames.length(), 5)
  for f in frames {
    assert_eq(f.yuv_bytes().length(), 64 * 48 * 3 / 2)
  }
}

///|
test "streaming: decode_video rejects a playlist with no video stream" {
  let media = StreamingMedia::open(b"#EXTM3U\n#EXT-X-ENDLIST", (_, _, _) => {
    Err("no resources")
  })
  try media.decode_video() catch {
    UnsupportedCodec(msg) => assert_true(msg.contains("no video stream"))
    _ => fail("expected UnsupportedCodec")
  } noraise {
    _ => fail("expected UnsupportedCodec")
  }
}

///|
test "streaming: audio-only playlist is refused by decode_video" {
  // Build a one-segment AAC/TS playlist inside this white-box test so no
  // cross-file helper is needed.
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let mux = ts_muxer_new(video=false)
  for frame in 0..<2 {
    let samples = Array::makei(1024, i => 0.2 * (i % 17 - 8).to_double() / 8.0)
    mux.write_audio(
      frame.to_int64() * 1920L,
      encoder.encode_frame([samples]).unwrap(),
    )
  }
  let ts = mux.finish()
  let media = StreamingMedia::open(
    b"#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:0.064,\na.ts\n#EXT-X-ENDLIST",
    (_, _, _) => Ok(ts),
  )
  try media.decode_video() catch {
    UnsupportedCodec(msg) => assert_true(msg.contains("no video stream"))
    _ => fail("expected UnsupportedCodec")
  } noraise {
    _ => fail("expected UnsupportedCodec")
  }
}
