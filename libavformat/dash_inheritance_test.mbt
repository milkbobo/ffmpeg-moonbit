///|
test "DASH local template inherits attributes and parent timeline" {
  let text =
    #|<MPD mediaPresentationDuration="PT6S"><Period>
    #|<SegmentTemplate timescale="1000" startNumber="5" initialization="init-$RepresentationID$.mp4" media="parent-$Number$.m4s">
    #|<SegmentTimeline><S t="100" d="2000" r="2"/></SegmentTimeline></SegmentTemplate>
    #|<AdaptationSet><SegmentTemplate media="audio-$Time$.m4s"/>
    #|<Representation id="a"><SegmentTemplate startNumber="9"/></Representation>
    #|</AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(
    text,
    base_uri="https://example.test/v/main.mpd",
  ).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.timescale, 1000L)
  assert_eq(rep.start_number, 9L)
  assert_eq(rep.initialization, "https://example.test/v/init-a.mp4")
  assert_eq(rep.segments.length(), 3)
  assert_eq(rep.segments[0].number, 9L)
  assert_eq(rep.segments[2].number, 11L)
  assert_eq(rep.segments[2].time, 4100L)
  assert_eq(rep.segments[2].uri, "https://example.test/v/audio-4100.m4s")
}

///|
test "DASH local timeline replaces all parent entries" {
  let text =
    #|<MPD><Period><SegmentTemplate timescale="10" media="t$Time$.m4s">
    #|<SegmentTimeline><S d="10" r="9"/></SegmentTimeline></SegmentTemplate>
    #|<AdaptationSet><Representation><SegmentTemplate>
    #|<SegmentTimeline><S t="30" d="20"/><S d="40"/></SegmentTimeline>
    #|</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments.length(), 2)
  assert_eq(rep.segments[0].uri, "t30.m4s")
  assert_eq(rep.segments[1].uri, "t50.m4s")
  assert_eq(rep.segments[1].duration, 40L)
}

///|
test "DASH SegmentList merges timing and init but replaces parent URL list" {
  let text =
    #|<MPD><Period><SegmentList timescale="90" duration="180" startNumber="5">
    #|<Initialization sourceURL="init.mp4"/><SegmentURL media="parent.m4s"/>
    #|</SegmentList><AdaptationSet><SegmentList duration="90"/>
    #|<Representation><SegmentList startNumber="10">
    #|<SegmentURL media="one.m4s"/><SegmentURL media="two.m4s"/>
    #|</SegmentList></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.timescale, 90L)
  assert_eq(rep.initialization, "init.mp4")
  assert_eq(rep.segments.length(), 2)
  assert_eq(rep.segments[0].number, 10L)
  assert_eq(rep.segments[1].number, 11L)
  assert_eq(rep.segments[1].time, 90L)
  assert_eq(rep.segments[1].duration, 90L)
  let calls : Array[String] = []
  let reader = @libavformat.dash_segment_reader_new(rep, (uri, _, _) => {
    calls.push(uri)
    match uri {
      "init.mp4" => Ok(b"INIT")
      "one.m4s" => Ok(b"one")
      "two.m4s" => Ok(b"two")
      _ => Err("unexpected resource")
    }
  })
  assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITone")
  assert_eq(reader.next().unwrap().unwrap().bytes(), b"INITtwo")
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, ["init.mp4", "one.m4s", "two.m4s"])
}

///|
test "DASH local list without URLs inherits all parent URLs" {
  let text =
    #|<MPD><Period><SegmentList duration="2"><SegmentURL media="one"/><SegmentURL media="two"/></SegmentList>
    #|<AdaptationSet><Representation><SegmentList startNumber="7"/></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments.length(), 2)
  assert_eq(rep.segments[0].number, 7L)
  assert_eq(rep.segments[1].uri, "two")
}

///|
test "DASH local SegmentBase inherits initialization" {
  let text =
    #|<MPD><Period><SegmentBase indexRange="0-43"><Initialization range="0-7"/></SegmentBase>
    #|<AdaptationSet><Representation><BaseURL>file.mp4</BaseURL>
    #|<SegmentBase indexRange="8-51"/></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.index_range, "8-51")
  assert_eq(rep.initialization, "file.mp4")
  assert_eq(rep.initialization_range, "0-7")
  assert_eq(rep.segments.length(), 0)
}
