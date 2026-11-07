///|
test "DASH SegmentList inherits variable timeline and preserves byte ranges" {
  let text =
    #|<MPD><Period><SegmentList timescale="1000" startNumber="7">
    #|<Initialization sourceURL="all.mp4" range="0-3"/>
    #|<SegmentTimeline><S t="5000" d="1000"/><S d="2000"/></SegmentTimeline>
    #|</SegmentList><AdaptationSet><Representation><SegmentList>
    #|<SegmentURL media="all.mp4" mediaRange="4-6"/>
    #|<SegmentURL media="all.mp4" mediaRange="7-8"/>
    #|</SegmentList></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments[0].time, 5000L)
  assert_eq(rep.segments[0].duration, 1000L)
  assert_eq(rep.segments[1].time, 6000L)
  assert_eq(rep.segments[1].duration, 2000L)
  assert_eq(rep.segments[1].number, 8L)
  let file = b"INITabcde"
  let calls : Array[(Int64, Int64)] = []
  let reader = @libavformat.dash_segment_reader_new(rep, (uri, offset, length) => {
    if uri != "all.mp4" {
      return Err("unexpected URI")
    }
    calls.push((offset, length))
    Ok(file[offset.to_int():offset.to_int() + length.to_int()].to_owned())
  })
  assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITabc")
  assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITde")
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, [(0L, 4L), (4L, 3L), (7L, 2L)])
}

///|
test "DASH SegmentList final open repeat is bounded by available URLs" {
  let text =
    #|<MPD type="dynamic"><Period><AdaptationSet><Representation><SegmentList>
    #|<SegmentTimeline><S t="10" d="3" r="-1"/></SegmentTimeline>
    #|<SegmentURL media="one"/><SegmentURL media="two"/><SegmentURL media="three"/>
    #|</SegmentList></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let segments = mpd.periods[0].adaptation_sets[0].representations[0].segments
  assert_eq(segments.length(), 3)
  assert_eq(segments[2].time, 16L)
  assert_eq(segments[2].uri, "three")
}

///|
test "DASH SegmentList timeline count mismatch returns an error" {
  for repeat in [0L, 2L, 4294967296L] {
    let text = "<MPD><Period><AdaptationSet><Representation><SegmentList><SegmentTimeline><S d=\"1\" r=\"\{repeat}\"/></SegmentTimeline><SegmentURL media=\"one\"/><SegmentURL media=\"two\"/></SegmentList></Representation></AdaptationSet></Period></MPD>"
    assert_true(
      @libavformat.av_dash_parse(text)
      is Err("dash: SegmentTimeline does not match SegmentURL count"),
    )
  }
}

///|
test "DASH empty SegmentList timeline waits without fetching" {
  let text =
    #|<MPD type="dynamic"><Period><AdaptationSet><Representation><SegmentList>
    #|<Initialization sourceURL="init.mp4"/>
    #|<SegmentTimeline><S t="10" d="3" r="-1"/></SegmentTimeline>
    #|</SegmentList></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let reader = @libavformat.dash_segment_reader_new(rep, (_, _, _) => {
    Err("unexpected fetch")
  })
  assert_true(reader.next().unwrap() is None)
}

///|
test "DASH SegmentList presentation offset bounds timeline repeats" {
  let text =
    #|<MPD mediaPresentationDuration="PT6S"><Period><AdaptationSet><Representation>
    #|<SegmentList presentationTimeOffset="100" timescale="1">
    #|<SegmentTimeline><S t="100" d="2" r="-1"/></SegmentTimeline>
    #|<SegmentURL media="one"/><SegmentURL media="two"/><SegmentURL media="three"/>
    #|</SegmentList></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  assert_eq(
    mpd.periods[0].adaptation_sets[0].representations[0].segments[2].time,
    104L,
  )
}
