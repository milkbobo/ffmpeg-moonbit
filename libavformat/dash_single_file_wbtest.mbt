///|
test "DASH complete MP4 does not prepend its own initialization range" {
  let file = @libavutil.av_base64_decode(dash_sb_mp4_b64, 100000).unwrap()
  let mpd = av_dash_parse(
    "<MPD><Period><AdaptationSet><Representation><BaseURL>file.mp4</BaseURL><SegmentBase><Initialization range=\"0-816\"/></SegmentBase></Representation></AdaptationSet></Period></MPD>",
  ).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.initialization, "file.mp4")
  let calls : Array[(Int64, Int64)] = []
  let reader = dash_segment_reader_new(rep, (uri, offset, length) => {
    if uri != "file.mp4" {
      return Err("unexpected URI")
    }
    calls.push((offset, length))
    Ok(file)
  })
  let segment = reader.next().unwrap().unwrap()
  assert_eq(segment.initialization, b"")
  assert_eq(segment.bytes(), file)
  assert_eq(
    av_mov_open(segment.bytes()).unwrap().tracks[0].samples.length(),
    10,
  )
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, [(0L, -1L)])
}

///|
test "DASH empty inherited SegmentList performs no fetch" {
  for list_location in 0..<3 {
    let list = "<SegmentList><Initialization sourceURL=\"init.mp4\"/></SegmentList>"
    let mpd = av_dash_parse(
      "<MPD type=\"dynamic\"><Period>" +
      (if list_location == 0 { list } else { "" }) +
      "<AdaptationSet>" +
      (if list_location == 1 { list } else { "" }) +
      "<Representation>" +
      (if list_location == 2 { list } else { "" }) +
      "</Representation></AdaptationSet></Period></MPD>",
      base_uri="https://example.test/live/manifest.mpd",
    ).unwrap()
    let rep = mpd.periods[0].adaptation_sets[0].representations[0]
    assert_eq(rep.segments.length(), 0)
    let calls = Ref(0)
    let reader = dash_segment_reader_new(rep, (_, _, _) => {
      calls.val += 1
      Err("unexpected fetch")
    })
    assert_true(reader.next().unwrap() is None)
    assert_eq(calls.val, 0)
  }
}

///|
test "DASH retains external init and same-file byte-range initialization" {
  for ranged in [false, true] {
    let addressing = if ranged {
      "<SegmentList><Initialization sourceURL=\"file.mp4\" range=\"0-3\"/><SegmentURL media=\"file.mp4\" mediaRange=\"4-6\"/></SegmentList>"
    } else {
      "<SegmentBase><Initialization sourceURL=\"init.mp4\"/></SegmentBase>"
    }
    let mpd = av_dash_parse(
      "<MPD><Period><AdaptationSet><Representation><BaseURL>file.mp4</BaseURL>" +
      addressing +
      "</Representation></AdaptationSet></Period></MPD>",
    ).unwrap()
    let rep = mpd.periods[0].adaptation_sets[0].representations[0]
    let calls : Array[(String, Int64, Int64)] = []
    let reader = dash_segment_reader_new(rep, (uri, offset, length) => {
      calls.push((uri, offset, length))
      if uri == "init.mp4" || length == 4L {
        Ok(b"INIT")
      } else {
        Ok(b"abc")
      }
    })
    assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITabc")
    assert_true(reader.next().unwrap() is None)
    assert_eq(
      calls,
      if ranged {
        [("file.mp4", 0L, 4L), ("file.mp4", 4L, 3L)]
      } else {
        [("init.mp4", 0L, -1L), ("file.mp4", 0L, -1L)]
      },
    )
  }
}
