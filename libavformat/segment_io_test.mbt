///|
test "HLS reader: ranges, cached init, GAP, discontinuity and retry" {
  let text =
    #|#EXTM3U
    #|#EXT-X-MEDIA-SEQUENCE:10
    #|#EXT-X-MAP:URI="../init.mp4",BYTERANGE="4@2"
    #|#EXT-X-BYTERANGE:3@5
    #|#EXTINF:1,
    #|shared.bin
    #|#EXT-X-DISCONTINUITY
    #|#EXT-X-GAP
    #|#EXTINF:1,
    #|missing.ts
    #|#EXT-X-BYTERANGE:2@8
    #|#EXTINF:1,
    #|shared.bin
    #|#EXT-X-ENDLIST
  let playlist = @libavformat.av_hls_parse(text, base_uri="https://example.test/v/list.m3u8").unwrap()
  let calls : Array[String] = []
  let retry = Ref(true)
  let reader = @libavformat.hls_segment_reader_new(playlist, (uri, offset, length) => {
    calls.push("\{uri} \{offset} \{length}")
    if uri == "https://example.test/init.mp4" { return Ok(b"INIT") }
    if offset == 5L { return Ok(b"abc") }
    if retry.val { retry.val = false; return Err("temporary transport failure") }
    Ok(b"de")
  }).unwrap()
  let first = reader.next().unwrap().unwrap()
  assert_eq(first.sequence, 10L)
  assert_eq(first.bytes(), b"INITabc")
  assert_false(first.discontinuity)
  assert_true(reader.next() is Err("temporary transport failure"))
  let second = reader.next().unwrap().unwrap()
  assert_eq(second.sequence, 12L)
  assert_true(second.discontinuity)
  assert_eq(second.bytes(), b"INITde")
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, [
    "https://example.test/init.mp4 2 4",
    "https://example.test/v/shared.bin 5 3",
    "https://example.test/v/shared.bin 8 2",
    "https://example.test/v/shared.bin 8 2",
  ])
}

///|
test "HLS reader: initialization retains its key across same-URI key rotation" {
  // NIST SP 800-38A F.2.1, AES-128 CBC block 1.
  let key : Bytes = b"\x2b\x7e\x15\x16\x28\xae\xd2\xa6\xab\xf7\x15\x88\x09\xcf\x4f\x3c"
  let cipher : Bytes = b"\x76\x49\xab\xac\x81\x19\xb2\x46\xce\xe9\x8e\x9b\x12\xe9\x19\x7d"
  let plain : Bytes = b"\x6b\xc1\xbe\xe2\x2e\x40\x9f\x96\xe9\x3d\x7e\x11\x73\x93\x17\x2a"
  let text =
    #|#EXTM3U
    #|#EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x000102030405060708090a0b0c0d0e0f
    #|#EXT-X-MAP:URI="init"
    #|#EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x000102030405060708090a0b0c0d0e0f
    #|#EXTINF:1,
    #|one
    #|#EXTINF:1,
    #|two
  let playlist = @libavformat.av_hls_parse(text, base_uri="https://example.test/a/list").unwrap()
  let key_calls = Ref(0)
  let init_calls = Ref(0)
  let reader = @libavformat.hls_segment_reader_new(playlist, (uri, _, _) => {
    if uri == "https://example.test/a/key" { key_calls.val += 1; Ok(key) }
    else {
      if uri == "https://example.test/a/init" { init_calls.val += 1 }
      Ok(cipher)
    }
  }).unwrap()
  for sequence in 0..<2 {
    let segment = reader.next().unwrap().unwrap()
    assert_eq(segment.sequence, sequence.to_int64())
    assert_eq(segment.initialization, plain)
    assert_eq(segment.media, plain)
  }
  assert_eq(key_calls.val, 2)
  assert_eq(init_calls.val, 1)
}

///|
test "HLS reader: range response, unsupported encryption and encrypted map IV errors" {
  let playlist = @libavformat.av_hls_parse("#EXTM3U\n#EXT-X-BYTERANGE:4@0\n#EXTINF:1,\na.ts").unwrap()
  let reader = @libavformat.hls_segment_reader_new(playlist, (_, _, _) => Ok(b"abc")).unwrap()
  assert_true(reader.next() is Err("segment: response length does not match byte range"))
  let encrypted = @libavformat.av_hls_parse("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=key\n#EXT-X-MAP:URI=init\n#EXTINF:1,\na.m4s").unwrap()
  let reader = @libavformat.hls_segment_reader_new(encrypted, (_, _, _) => Ok(b"" )).unwrap()
  assert_true(reader.next() is Err("hls: encrypted initialization requires an explicit IV"))
  let sample = @libavformat.av_hls_parse("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=key\n#EXTINF:1,\na.ts").unwrap()
  let reader = @libavformat.hls_segment_reader_new(sample, (_, _, _) => Ok(b"" )).unwrap()
  assert_true(reader.next() is Err("hls: only identity AES-128 encryption is supported"))
}

///|
test "DASH reader: SegmentList byte ranges, init caching and retry" {
  let manifest =
    #|<MPD mediaPresentationDuration="PT2S"><Period><AdaptationSet>
    #|<Representation id="v" mimeType="video/mp4"><SegmentList duration="1">
    #|<Initialization sourceURL="all.mp4" range="0-3"/>
    #|<SegmentURL media="all.mp4" mediaRange="4-6"/>
    #|<SegmentURL media="all.mp4" mediaRange="7-8"/>
    #|</SegmentList></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(manifest, base_uri="https://example.test/stream/main.mpd").unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let calls : Array[String] = []
  let retry = Ref(true)
  let reader = @libavformat.dash_segment_reader_new(rep, (uri, offset, length) => {
    calls.push("\{uri} \{offset} \{length}")
    if offset == 0L { Ok(b"INIT") } else if offset == 4L { Ok(b"abc") }
    else if retry.val { retry.val = false; Err("temporary failure") } else { Ok(b"de") }
  })
  assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITabc")
  assert_true(reader.next() is Err("temporary failure"))
  assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITde")
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, [
    "https://example.test/stream/all.mp4 0 4",
    "https://example.test/stream/all.mp4 4 3",
    "https://example.test/stream/all.mp4 7 2",
    "https://example.test/stream/all.mp4 7 2",
  ])
}

///|
test "DASH SegmentList inherits timescale numbering timing and byte ranges" {
  let manifest =
    #|<MPD><Period><SegmentList timescale="90" duration="180" startNumber="5">
    #|<Initialization sourceURL="all.mp4" range="0-3"/>
    #|<SegmentURL media="all.mp4" mediaRange="4-6"/>
    #|<SegmentURL media="all.mp4" mediaRange="7-8"/>
    #|</SegmentList><AdaptationSet><Representation id="v"/></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(manifest).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.timescale, 90L)
  assert_eq(rep.start_number, 5L)
  assert_eq(rep.initialization_range, "0-3")
  assert_eq(rep.segments.length(), 2)
  assert_eq(rep.segments[0].number, 5L)
  assert_eq(rep.segments[1].number, 6L)
  assert_eq(rep.segments[1].time, 180L)
  assert_eq(rep.segments[1].duration, 180L)
}

///|
test "DASH reader: invalid range is rejected without a fetch" {
  for range in ["3-1", "-1-8", "0-9223372036854775807", "abc", "0-"] {
    let manifest = "<MPD><Period><AdaptationSet><Representation><SegmentList><SegmentURL media=\"file\" mediaRange=\"" + range + "\"/></SegmentList></Representation></AdaptationSet></Period></MPD>"
    let mpd = @libavformat.av_dash_parse(manifest).unwrap()
    let rep = mpd.periods[0].adaptation_sets[0].representations[0]
    let calls = Ref(0)
    let reader = @libavformat.dash_segment_reader_new(rep, (_, _, _) => {
      calls.val += 1
      Ok(b"")
    })
    assert_true(reader.next() is Err("dash: invalid resource byte range"))
    assert_eq(calls.val, 0)
  }
}
