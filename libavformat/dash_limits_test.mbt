///|
test "DASH duration ceiling handles a very long single segment" {
  let text =
    #|<MPD mediaPresentationDuration="PT6S"><Period><AdaptationSet><Representation>
    #|<SegmentTemplate duration="9223372036854775807" media="s$Number$.m4s"/>
    #|</Representation></AdaptationSet></Period></MPD>
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  let segments = mpd.periods[0].adaptation_sets[0].representations[0].segments
  assert_eq(segments.length(), 1)
  assert_eq(segments[0].uri, "s1.m4s")
}

///|
test "DASH template invalid timescale defaults to one" {
  for scale in ["0", "-1", "invalid"] {
    let text = "<MPD mediaPresentationDuration=\"PT6S\"><Period><AdaptationSet><Representation><SegmentTemplate timescale=\"" +
      scale +
      "\" duration=\"2\" media=\"s$Number$.m4s\"/></Representation></AdaptationSet></Period></MPD>"
    let mpd = @libavformat.av_dash_parse(text).unwrap()
    let rep = mpd.periods[0].adaptation_sets[0].representations[0]
    assert_eq(rep.timescale, 1L)
    assert_eq(rep.segments.length(), 3)
  }
}

///|
test "DASH rejects unrepresentable timeline repeat counts and timestamps" {
  for
    entry in [
      "<S d=\"1\" r=\"4294967296\"/>", "<S d=\"1\" r=\"9223372036854775807\"/>",
      "<S t=\"9223372036854775806\" d=\"2\"/>", "<S t=\"-1\" d=\"2\"/>",
    ] {
    let text = "<MPD><Period><AdaptationSet><Representation><SegmentTemplate media=\"t$Time$.m4s\"><SegmentTimeline>" +
      entry +
      "</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>"
    assert_true(@libavformat.av_dash_parse(text) is Err(_))
  }
}

///|
test "DASH final maximum sequence is valid but wrapping sequences fail" {
  for mode in 0..<3 {
    for count in [1, 2] {
      let addressing = if mode == 1 {
        "<SegmentTemplate startNumber=\"9223372036854775807\" media=\"s$Number$.m4s\"><SegmentTimeline><S d=\"1\" r=\"\{count - 1}\"/></SegmentTimeline></SegmentTemplate>"
      } else if mode == 0 {
        "<SegmentTemplate startNumber=\"9223372036854775807\" duration=\"1\" media=\"s$Number$.m4s\"/>"
      } else {
        "<SegmentList startNumber=\"9223372036854775807\" duration=\"1\"><SegmentURL media=\"s9223372036854775807.m4s\"/>" +
        (if count == 2 { "<SegmentURL media=\"wrapped.m4s\"/>" } else { "" }) +
        "</SegmentList>"
      }
      let text = "<MPD mediaPresentationDuration=\"PT\{count}S\"><Period><AdaptationSet><Representation>" +
        addressing +
        "</Representation></AdaptationSet></Period></MPD>"
      let result = @libavformat.av_dash_parse(text)
      if count == 1 {
        let rep = result.unwrap().periods[0].adaptation_sets[0].representations[0]
        assert_eq(rep.segments[0].uri, "s9223372036854775807.m4s")
      } else {
        assert_true(result is Err(_))
      }
    }
  }
}
