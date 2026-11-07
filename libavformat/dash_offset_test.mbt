///|
test "DASH presentation offset bounds open repeats without shifting Time URLs" {
  let text =
    #|<MPD mediaPresentationDuration="PT6S"><Period>
    #|<SegmentTemplate timescale="1000" presentationTimeOffset="10000" media="t$Time$.m4s">
    #|<SegmentTimeline><S t="10000" d="2000" r="-1"/></SegmentTimeline></SegmentTemplate>
    #|<AdaptationSet><Representation id="v"><SegmentTemplate startNumber="5"/></Representation></AdaptationSet>
    #|</Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments.length(), 3)
  assert_eq(rep.segments[0].number, 5L)
  assert_eq(rep.segments[0].time, 10000L)
  assert_eq(rep.segments[2].uri, "t14000.m4s")
}

///|
test "DASH next explicit timestamp bounds open repeats before period end" {
  let text =
    #|<MPD mediaPresentationDuration="PT10S"><Period><AdaptationSet><Representation>
    #|<SegmentTemplate timescale="1" presentationTimeOffset="100" media="t$Time$.m4s">
    #|<SegmentTimeline><S t="100" d="2" r="-1"/><S t="106" d="4"/></SegmentTimeline>
    #|</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let segments = mpd.periods[0].adaptation_sets[0].representations[0].segments
  assert_eq(segments.length(), 4)
  assert_eq(segments[2].time, 104L)
  assert_eq(segments[3].time, 106L)
}

///|
test "DASH invalid presentation offsets use zero" {
  for offset in ["-10", "invalid", ""] {
    let text = "<MPD><Period duration=\"PT6S\"><AdaptationSet><Representation><SegmentTemplate presentationTimeOffset=\"" +
      offset +
      "\" media=\"t$Time$.m4s\"><SegmentTimeline><S d=\"2\" r=\"-1\"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>"
    let mpd = @libavformat.av_dash_parse(text).unwrap()
    let segments = mpd.periods[0].adaptation_sets[0].representations[0].segments
    assert_eq(segments.length(), 3)
    assert_eq(segments[2].uri, "t4.m4s")
  }
}

///|
test "DASH unknown duration is not bounded by presentation offset alone" {
  let text =
    #|<MPD type="dynamic"><Period><AdaptationSet><Representation>
    #|<SegmentTemplate presentationTimeOffset="100" media="t$Time$.m4s">
    #|<SegmentTimeline><S d="2" r="-1"/></SegmentTimeline>
    #|</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  assert_eq(
    mpd.periods[0].adaptation_sets[0].representations[0].segments.length(),
    1,
  )
}

///|
test "DASH media time bound does not wrap near Int64 maximum" {
  let text =
    #|<MPD><Period duration="PT10S"><AdaptationSet><Representation>
    #|<SegmentTemplate presentationTimeOffset="9223372036854775803" media="t$Time$.m4s">
    #|<SegmentTimeline><S t="9223372036854775803" d="2" r="-1"/></SegmentTimeline>
    #|</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let segments = mpd.periods[0].adaptation_sets[0].representations[0].segments
  assert_eq(segments.length(), 2)
  assert_eq(segments[1].uri, "t9223372036854775805.m4s")
}
