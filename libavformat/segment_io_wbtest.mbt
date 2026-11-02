///|
fn segment_test_fetch(files : Array[(String, Bytes)]) -> MediaFetch {
  (uri, offset, length) => {
    for (name, b64) in files {
      if uri == name {
        let data = match @libavutil.av_base64_decode(b64, 1048576) {
          Ok(value) => value
          Err(e) => return Err(e)
        }
        if offset < 0L || offset > data.length().to_int64() {
          return Err("bad fixture range")
        }
        let end = if length < 0L {
          data.length().to_int64()
        } else {
          offset + length
        }
        if end > data.length().to_int64() {
          return Err("bad fixture range")
        }
        return Ok(data[offset.to_int():end.to_int()].to_owned())
      }
    }
    Err("missing resource: " + uri)
  }
}

///|
fn segment_test_decode_mp4(bytes : Bytes) -> Array[@libavcodec.H264Frame] raise {
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  let samples : Array[Bytes] = []
  for sample in track.samples {
    let offset = sample.offset.to_int()
    samples.push(
      bytes[offset:offset + sample.size.reinterpret_as_int()].to_owned(),
    )
  }
  @libavcodec.h264_decode_avc_frames(track.extradata.unwrap(), samples, false).unwrap()
}

///|
test "HLS callback -> TS demux -> H264: four real frames match FFmpeg MD5" {
  let playlist = av_hls_parse(
    segments_ts_manifest,
    base_uri="https://example.test/segments_ts/list.m3u8",
  ).unwrap()
  let reader = hls_segment_reader_new(
    playlist,
    segment_test_fetch(segments_ts_files),
  ).unwrap()
  let mut frame_index = 0
  for _ in 0..<2 {
    let bytes = reader.next().unwrap().unwrap().bytes()
    let ts = av_mpegts_open(bytes).unwrap()
    let elementary : Array[Byte] = []
    for packet in ts.packets {
      if ts.streams[packet.stream_index].codec == "h264" {
        for byte in packet.payload {
          elementary.push(byte)
        }
      }
    }
    let frames = @libavcodec.h264_decode_annexb_frames(
      Bytes::from_array(elementary[:]),
      false,
    ).unwrap()
    assert_eq(frames.length(), 2)
    for frame in frames {
      assert_eq(
        h264_frame_md5(frame),
        segments_ts_md5[frame_index],
        msg="TS frame \{frame_index}",
      )
      frame_index += 1
    }
  }
  assert_eq(frame_index, 4)
  assert_true(reader.next().unwrap() is None)
}

///|
test "HLS callback -> fMP4 init+fragment -> H264: four real frames match FFmpeg MD5" {
  let playlist = av_hls_parse(
    segments_mp4_manifest,
    base_uri="https://example.test/segments_mp4/list.m3u8",
  ).unwrap()
  let reader = hls_segment_reader_new(
    playlist,
    segment_test_fetch(segments_mp4_files),
  ).unwrap()
  let mut frame_index = 0
  for _ in 0..<2 {
    let frames = segment_test_decode_mp4(
      reader.next().unwrap().unwrap().bytes(),
    )
    assert_eq(frames.length(), 2)
    for frame in frames {
      assert_eq(
        h264_frame_md5(frame),
        segments_mp4_md5[frame_index],
        msg="MP4 frame \{frame_index}",
      )
      frame_index += 1
    }
  }
  assert_eq(frame_index, 4)
  assert_true(reader.next().unwrap() is None)
}

///|
fn segment_test_raw_fetch(files : Array[(String, Bytes)]) -> MediaFetch {
  (uri, offset, length) => {
    for (name, data) in files {
      if uri == name {
        if offset < 0L || offset > data.length().to_int64() {
          return Err("bad fixture range")
        }
        let end = if length < 0L {
          data.length().to_int64()
        } else {
          offset + length
        }
        if end > data.length().to_int64() {
          return Err("bad fixture range")
        }
        return Ok(data[offset.to_int():end.to_int()].to_owned())
      }
    }
    Err("missing resource: " + uri)
  }
}

///|
/// HLS boundary: two `EXT-X-KEY` tags rotate the AES-128 key. The first
/// segment has no `IV` (implicit IV from `EXT-X-MEDIA-SEQUENCE`), the second
/// carries an explicit `IV` attribute. Each key is fetched once and cached.
test "HLS: AES-128 key rotation with implicit and explicit IVs" {
  let plain0 = b"first-segment-plain"
  let plain1 = b"second-segment-plain"
  let key1 = b"0123456789abcdef"
  let key2 = b"fedcba9876543210"
  let iv1 = hls_iv_from_sequence(7L)
  let iv2 = hls_parse_iv("0x000102030405060708090a0b0c0d0e0f").unwrap()
  let enc0 = hls_encrypt_aes128(key1, iv1, plain0).unwrap()
  let enc1 = hls_encrypt_aes128(key2, iv2, plain1).unwrap()
  let playlist_text =
    #|#EXTM3U
    #|#EXT-X-VERSION:3
    #|#EXT-X-TARGETDURATION:1
    #|#EXT-X-MEDIA-SEQUENCE:7
    #|#EXT-X-KEY:METHOD=AES-128,URI="key1.bin"
    #|#EXTINF:1.0,
    #|seg0.ts
    #|#EXT-X-KEY:METHOD=AES-128,URI="key2.bin",IV=0x000102030405060708090a0b0c0d0e0f
    #|#EXTINF:1.0,
    #|seg1.ts
    #|#EXT-X-ENDLIST
  let playlist = av_hls_parse(playlist_text).unwrap()
  assert_eq(playlist.keys.length(), 2)
  assert_eq(playlist.segments[0].key_index, 0)
  assert_eq(playlist.segments[1].key_index, 1)
  assert_eq(playlist.segments[0].media_sequence, 7L)
  assert_eq(playlist.segments[1].media_sequence, 8L)
  let reader = hls_segment_reader_new(
    playlist,
    segment_test_raw_fetch([
      ("key1.bin", key1),
      ("key2.bin", key2),
      ("seg0.ts", enc0),
      ("seg1.ts", enc1),
    ]),
  ).unwrap()
  let s0 = reader.next().unwrap().unwrap()
  assert_eq(s0.sequence, 7L)
  assert_eq(s0.media, plain0)
  let s1 = reader.next().unwrap().unwrap()
  assert_eq(s1.sequence, 8L)
  assert_eq(s1.media, plain1)
  assert_true(reader.next().unwrap() is None)
}

///|
/// HLS boundary: a live playlist has no `EXT-X-ENDLIST`. A transient fetch
/// failure leaves the cursor untouched, so the retry returns the same segment;
/// exhaustion then yields `None` rather than an error.
test "HLS: live playlist retries a failed segment and keeps the cursor" {
  let playlist_text =
    #|#EXTM3U
    #|#EXT-X-VERSION:3
    #|#EXT-X-TARGETDURATION:1
    #|#EXT-X-MEDIA-SEQUENCE:0
    #|#EXTINF:1.0,
    #|seg0.ts
    #|#EXTINF:1.0,
    #|seg1.ts
  let playlist = av_hls_parse(playlist_text).unwrap()
  assert_eq(playlist.endlist, false)
  let seg0 = b"seg-zero-bytes"
  let seg1 = b"seg-one-bytes"
  let calls : Array[Int32] = [0]
  let fetch : MediaFetch = (uri, offset, length) => {
    calls[0] += 1
    if calls[0] == 1 {
      return Err("transient network error")
    }
    if offset != 0L || length >= 0L {
      return Err("bad fixture range")
    }
    if uri == "seg0.ts" {
      return Ok(seg0)
    } else if uri == "seg1.ts" {
      return Ok(seg1)
    }
    Err("missing resource: " + uri)
  }
  let reader = hls_segment_reader_new(playlist, fetch).unwrap()
  match reader.next() {
    Err(e) => assert_true(e.contains("transient"))
    Ok(_) => fail("first read must fail")
  }
  let s0 = reader.next().unwrap().unwrap()
  assert_eq(s0.sequence, 0L)
  assert_eq(s0.media, seg0)
  let s1 = reader.next().unwrap().unwrap()
  assert_eq(s1.sequence, 1L)
  assert_eq(s1.media, seg1)
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls[0], 3)
}

///|
test "DASH callback -> fMP4 init+fragment -> H264: four real frames match FFmpeg MD5" {
  let mpd = av_dash_parse(
    segments_dash_manifest,
    base_uri="https://example.test/segments_dash/list.mpd",
  ).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let reader = dash_segment_reader_new(
    rep,
    segment_test_fetch(segments_dash_files),
  )
  let mut frame_index = 0
  for _ in 0..<2 {
    let frames = segment_test_decode_mp4(
      reader.next().unwrap().unwrap().bytes(),
    )
    assert_eq(frames.length(), 2)
    for frame in frames {
      assert_eq(
        h264_frame_md5(frame),
        segments_dash_md5[frame_index],
        msg="DASH frame \{frame_index}",
      )
      frame_index += 1
    }
  }
  assert_eq(frame_index, 4)
  assert_true(reader.next().unwrap() is None)
}
