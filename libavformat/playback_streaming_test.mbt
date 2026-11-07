///|
/// Black-box tests for the adaptive-streaming playback facade. All media
/// bytes come from this repository's own AAC encoder and TS/fMP4 muxers, so
/// the packet and PCM assertions exercise real containers rather than
/// hand-written byte blobs.

///|
/// ASCII playlist text as bytes (playlist syntax is ASCII by spec).
fn streaming_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Encode `frames` sine-wave AAC frames, returning the raw ADTS access units
/// and the float PCM the decoder should reproduce.
fn streaming_make_aac(frames : Int32) -> (Array[Bytes], Array[Double]) {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let direct = @libavcodec.new_aac_decoder_from_asc(b"\x11\x88").unwrap()
  let units : Array[Bytes] = []
  let expected : Array[Double] = []
  for frame in 0..<frames {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    let packet = encoder.encode_frame([samples]).unwrap()
    let decoded = direct.decode_frame(packet[7:].to_owned()).unwrap()
    for sample in decoded[0].samples {
      expected.push(sample)
    }
    units.push(packet)
  }
  (units, expected)
}

///|
/// Wrap a slice of AAC access units into one standalone MPEG-TS segment.
fn streaming_ts_segment(units : ArrayView[Bytes], first : Int64) -> Bytes {
  let mux = @libavformat.ts_muxer_new(video=false)
  for i, unit in units {
    mux.write_audio(first + i.to_int64() * 1920L, unit)
  }
  mux.finish()
}

///|
/// Build a VOD HLS playlist naming `count` segments.
fn streaming_hls_playlist(count : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n")
  for i in 0..<count {
    sb.write_string("#EXTINF:0.064,\nseg\{i}.ts\n")
  }
  sb.write_string("#EXT-X-ENDLIST\n")
  sb.to_string()
}

///|
test "streaming: HLS empty playlist ends without any fetch" {
  let calls = Ref(0)
  let media = @libavformat.StreamingMedia::open(
    streaming_bytes("#EXTM3U\n#EXT-X-ENDLIST"),
    (_, _, _) => {
      calls.val += 1
      Err("unexpected fetch")
    },
  )
  assert_eq(media.format_name(), "hls")
  assert_eq(media.kind(), @libavformat.StreamingKind::Hls)
  assert_true(media.duration_seconds() is None)
  assert_true(media.next_packet() is None)
  assert_true(media.next_packet() is None)
  assert_eq(calls.val, 0)
}

///|
test "streaming: unknown playlist bytes are FormatNotFound" {
  try
    @libavformat.StreamingMedia::open(b"not a playlist", (_, _, _) => {
      Err("unused")
    })
  catch {
    @libavformat.FormatNotFound => ()
    other => fail("unexpected error: \{other.message()}")
  } noraise {
    _ => fail("expected FormatNotFound")
  }
}

///|
test "streaming: HLS master playlist is rejected with a clear error" {
  let master =
    #|#EXTM3U
    #|#EXT-X-STREAM-INF:BANDWIDTH=128000
    #|low.m3u8
    #|
  try
    @libavformat.StreamingMedia::open(streaming_bytes(master), (_, _, _) => {
      Err("unused")
    })
  catch {
    @libavformat.DemuxError(msg) => assert_true(msg.contains("master playlist"))
    _ => fail("expected DemuxError")
  } noraise {
    _ => fail("expected DemuxError")
  }
}

///|
test "streaming: HLS multi-segment packets keep one monotonic timeline" {
  let (units, _) = streaming_make_aac(6)
  let seg0 = streaming_ts_segment(units[:3], 0L)
  let seg1 = streaming_ts_segment(units[3:], 0L)
  let fetched : Array[String] = []
  let media = @libavformat.StreamingMedia::open(
    streaming_bytes(streaming_hls_playlist(2)),
    (uri, _, _) => {
      fetched.push(uri)
      if uri == "seg0.ts" {
        Ok(seg0)
      } else if uri == "seg1.ts" {
        Ok(seg1)
      } else {
        Err("unexpected segment URI: \{uri}")
      }
    },
  )
  let packets : Array[@libavformat.StreamingPacket] = []
  while true {
    match media.next_packet() {
      Some(p) => packets.push(p)
      None => break
    }
  }
  assert_eq(packets.length(), 6)
  assert_eq(fetched, ["seg0.ts", "seg1.ts"])
  assert_eq(media.format_name(), "hls")
  assert_eq(media.streams().length(), 1)
  assert_eq(media.streams()[0].codec_id, "aac")
  assert_eq(media.duration_seconds(), Some(0.128))
  // Three AAC frames per segment: the second segment restarts its PES
  // timestamps at 0, so normalization must lift it past the first segment.
  let mut previous = -1L
  for p in packets {
    assert_true(p.pts > previous)
    previous = p.pts
  }
  assert_eq(packets[0].segment_sequence, 0L)
  assert_eq(packets[3].segment_sequence, 1L)
  assert_eq(packets[3].pts, packets[2].pts + (packets[2].pts - packets[1].pts))
  for p in packets {
    assert_false(p.discontinuity)
  }
  assert_true(media.next_packet() is None)
}

///|
test "streaming: HLS decode_audio joins segments without losing samples" {
  let (units, expected) = streaming_make_aac(6)
  let seg0 = streaming_ts_segment(units[:3], 0L)
  let seg1 = streaming_ts_segment(units[3:], 0L)
  let media = @libavformat.StreamingMedia::open(
    streaming_bytes(streaming_hls_playlist(2)),
    (uri, _, _) => {
      if uri == "seg0.ts" {
        Ok(seg0)
      } else if uri == "seg1.ts" {
        Ok(seg1)
      } else {
        Err("unexpected segment URI")
      }
    },
  )
  let audio = media.decode_audio()
  assert_eq(audio.codec_id, "aac")
  assert_eq(audio.sample_rate, 48000)
  assert_eq(audio.channels, 1)
  assert_eq(audio.format_name, "hls")
  assert_eq(audio.samples[0].length(), 6 * 1024)
  assert_eq(audio.samples[0], expected)
}

///|
test "streaming: HLS discontinuity is flagged on the first packet only" {
  let (units, _) = streaming_make_aac(4)
  let seg0 = streaming_ts_segment(units[:2], 0L)
  let seg1 = streaming_ts_segment(units[2:], 0L)
  let playlist =
    #|#EXTM3U
    #|#EXT-X-TARGETDURATION:1
    #|#EXTINF:0.064,
    #|seg0.ts
    #|#EXT-X-DISCONTINUITY
    #|#EXTINF:0.064,
    #|seg1.ts
    #|#EXT-X-ENDLIST
    #|
  let media = @libavformat.StreamingMedia::open(streaming_bytes(playlist), (
    uri,
    _,
    _,
  ) => if uri == "seg0.ts" { Ok(seg0) } else { Ok(seg1) })
  let packets : Array[@libavformat.StreamingPacket] = []
  while true {
    match media.next_packet() {
      Some(p) => packets.push(p)
      None => break
    }
  }
  assert_eq(packets.length(), 4)
  assert_false(packets[0].discontinuity)
  assert_false(packets[1].discontinuity)
  assert_true(packets[2].discontinuity)
  assert_false(packets[3].discontinuity)
  // A discontinuity must not rewind the presentation timeline.
  assert_true(packets[2].pts > packets[1].pts)
}

///|
test "streaming: failed fetch is retryable and never drops a segment" {
  let (units, _) = streaming_make_aac(4)
  let seg0 = streaming_ts_segment(units[:2], 0L)
  let seg1 = streaming_ts_segment(units[2:], 0L)
  let attempts = Ref(0)
  let media = @libavformat.StreamingMedia::open(
    streaming_bytes(streaming_hls_playlist(2)),
    (uri, _, _) => {
      if uri == "seg0.ts" {
        Ok(seg0)
      } else {
        attempts.val += 1
        if attempts.val == 1 {
          Err("transient network error")
        } else {
          Ok(seg1)
        }
      }
    },
  )
  assert_eq(media.next_packet().unwrap().stream_index, 0)
  assert_eq(media.next_packet().unwrap().stream_index, 0)
  try media.next_packet() catch {
    @libavformat.DemuxError(_) => ()
    other => fail("unexpected error: \{other.message()}")
  } noraise {
    _ => fail("expected DemuxError from the failed fetch")
  }
  // The cursor stayed on segment 1: both of its frames still arrive.
  let rest : Array[@libavformat.StreamingPacket] = []
  while true {
    match media.next_packet() {
      Some(p) => rest.push(p)
      None => break
    }
  }
  assert_eq(rest.length(), 2)
  assert_eq(rest[0].segment_sequence, 1L)
  assert_eq(attempts.val, 2)
}

///|
test "streaming: three HLS segments stay monotonic and fully decode" {
  let (units, expected) = streaming_make_aac(6)
  let seg = [
    streaming_ts_segment(units[:2], 0L),
    streaming_ts_segment(units[2:4], 0L),
    streaming_ts_segment(units[4:], 0L),
  ]
  let media = @libavformat.StreamingMedia::open(
    streaming_bytes(streaming_hls_playlist(3)),
    (uri, _, _) => {
      if uri == "seg0.ts" {
        Ok(seg[0])
      } else if uri == "seg1.ts" {
        Ok(seg[1])
      } else if uri == "seg2.ts" {
        Ok(seg[2])
      } else {
        Err("unexpected URI: \{uri}")
      }
    },
  )
  let pts : Array[Int64] = []
  let sequences : Array[Int64] = []
  while true {
    match media.next_packet() {
      Some(p) => {
        pts.push(p.pts)
        sequences.push(p.segment_sequence)
      }
      None => break
    }
  }
  assert_eq(pts.length(), 6)
  for i = 1; i < pts.length(); i = i + 1 {
    assert_true(pts[i] > pts[i - 1])
  }
  assert_eq(sequences, [0L, 0L, 1L, 1L, 2L, 2L])
  let decoded = @libavformat.StreamingMedia::open(
    streaming_bytes(streaming_hls_playlist(3)),
    (uri, _, _) => {
      if uri == "seg0.ts" {
        Ok(seg[0])
      } else if uri == "seg1.ts" {
        Ok(seg[1])
      } else if uri == "seg2.ts" {
        Ok(seg[2])
      } else {
        Err("unexpected URI")
      }
    },
  ).decode_audio()
  assert_eq(decoded.samples[0].length(), 6 * 1024)
  assert_eq(decoded.samples[0], expected)
}

///|
test "streaming: discontinuity resets the decoder but keeps all PCM" {
  let (units, _) = streaming_make_aac(4)
  let seg0 = streaming_ts_segment(units[:2], 0L)
  let seg1 = streaming_ts_segment(units[2:], 0L)
  let playlist =
    #|#EXTM3U
    #|#EXT-X-TARGETDURATION:1
    #|#EXTINF:0.064,
    #|seg0.ts
    #|#EXT-X-DISCONTINUITY
    #|#EXTINF:0.064,
    #|seg1.ts
    #|#EXT-X-ENDLIST
    #|
  let media = @libavformat.StreamingMedia::open(streaming_bytes(playlist), (
    uri,
    _,
    _,
  ) => if uri == "seg0.ts" { Ok(seg0) } else { Ok(seg1) })
  let audio = media.decode_audio()
  assert_eq(audio.samples[0].length(), 4 * 1024)
  // Directly decoding the concatenated TS through the file facade is the
  // same codec path with no flush; a reset only affects overlap samples.
  let joined = seg0 + seg1
  let reference = @libavformat.decode_audio_file(joined)
  assert_eq(audio.samples[0].length(), reference.samples[0].length())
}

///|
test "streaming: DASH indexes are validated instead of clamped" {
  let mpd = @libavformat.av_dash_parse(
    "<MPD><Period><AdaptationSet><Representation/></AdaptationSet></Period></MPD>",
  ).unwrap()
  for (p, a, r) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
    try
      @libavformat.StreamingMedia::open_dash(
        mpd,
        (_, _, _) => Err("unused"),
        period=p,
        adaptation_set=a,
        representation=r,
      )
    catch {
      @libavformat.DemuxError(_) => ()
      _ => fail("expected DemuxError for out-of-range index")
    } noraise {
      _ => fail("expected DemuxError for out-of-range index")
    }
  }
}

///|
test "streaming: DASH fMP4 init+media segments decode across the boundary" {
  let (units, _) = streaming_make_aac(4)
  let init = @libavformat.fmp4_aac_init_segment(48000, 1).unwrap()
  let to_fmp4 = fn(from : Int32) -> Bytes {
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
  let media0 = to_fmp4(0)
  let media1 = to_fmp4(2)
  let mpd_text = @libavformat.dash_write_segment_template_mpd(
    [
      @libavformat.DashAdaptation::new(
        "audio",
        "audio/mp4",
        "mp4a.40.2",
        "a1",
        64000L,
        48000L,
        2400L,
        "init.mp4",
        "seg-$Number$.m4s",
        sample_rate=48000,
      ),
    ],
    media_duration_seconds=0.1,
  )
  let mpd = @libavformat.av_dash_parse(mpd_text).unwrap()
  assert_eq(
    mpd.periods[0].adaptation_sets[0].representations[0].segments.length(),
    2,
  )
  let media = @libavformat.StreamingMedia::open(streaming_bytes(mpd_text), (
    uri,
    _,
    _,
  ) => {
    if uri == "init.mp4" {
      Ok(init)
    } else if uri == "seg-1.m4s" {
      Ok(media0)
    } else if uri == "seg-2.m4s" {
      Ok(media1)
    } else {
      Err("unexpected DASH URI: \{uri}")
    }
  })
  assert_eq(media.format_name(), "dash")
  assert_eq(media.kind(), @libavformat.StreamingKind::Dash)
  assert_eq(media.duration_seconds(), Some(0.1))
  let _ = mpd
  let packets : Array[@libavformat.StreamingPacket] = []
  while true {
    match media.next_packet() {
      Some(p) => packets.push(p)
      None => break
    }
  }
  assert_eq(packets.length(), 4)
  assert_eq(media.streams()[0].codec_id, "aac")
  let mut previous = -1L
  for p in packets {
    assert_true(p.pts > previous)
    previous = p.pts
  }
  assert_eq(packets[0].segment_sequence, 1L)
  assert_eq(packets[2].segment_sequence, 2L)
}

///|
test "streaming: DASH decode_audio keeps PCM across fMP4 segment boundary" {
  let (units, _) = streaming_make_aac(4)
  let init = @libavformat.fmp4_aac_init_segment(48000, 1).unwrap()
  let to_fmp4 = fn(from : Int32) -> Bytes {
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
  let media0 = to_fmp4(0)
  let media1 = to_fmp4(2)
  let mpd_text = @libavformat.dash_write_segment_template_mpd(
    [
      @libavformat.DashAdaptation::new(
        "audio",
        "audio/mp4",
        "mp4a.40.2",
        "a1",
        64000L,
        48000L,
        2400L,
        "init.mp4",
        "seg-$Number$.m4s",
        sample_rate=48000,
      ),
    ],
    media_duration_seconds=0.1,
  )
  let media = @libavformat.StreamingMedia::open(streaming_bytes(mpd_text), (
    uri,
    _,
    _,
  ) => {
    if uri == "init.mp4" {
      Ok(init)
    } else if uri == "seg-1.m4s" {
      Ok(media0)
    } else if uri == "seg-2.m4s" {
      Ok(media1)
    } else {
      Err("unexpected DASH URI: \{uri}")
    }
  })
  let audio = media.decode_audio()
  assert_eq(audio.codec_id, "aac")
  assert_eq(audio.sample_rate, 48000)
  assert_eq(audio.channels, 1)
  assert_eq(audio.format_name, "dash")
  assert_eq(audio.samples[0].length(), 4 * 1024)
  // The same four access units through the file facade must produce the same
  // samples, so the streaming path is not drifting from the container path.
  let joined = init + media0 + media1
  let reference = @libavformat.decode_audio_file(joined)
  assert_eq(audio.samples[0].length(), reference.samples[0].length())
  assert_eq(audio.samples[0], reference.samples[0])
}
