///|
fn dash_period_test_rep() -> String {
  "<AdaptationSet><Representation><SegmentTemplate duration=\"1\" media=\"s$Number$.m4s\"/></Representation></AdaptationSet>"
}

///|
test "DASH implicit Period starts follow preceding durations" {
  let rep = dash_period_test_rep()
  let text = "<MPD mediaPresentationDuration=\"PT8S\"><Period duration=\"PT2S\">" +
    rep +
    "</Period><Period duration=\"PT3S\">" +
    rep +
    "</Period><Period>" +
    rep +
    "</Period></MPD>"
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  for i, expected in [(0.0, 2.0), (2.0, 3.0), (5.0, 3.0)] {
    let period = mpd.periods[i]
    assert_eq((period.start, period.duration), expected)
    assert_eq(
      period.adaptation_sets[0].representations[0].segments.length(),
      expected.1.to_int(),
    )
  }
}

///|
test "DASH omitted Period duration stops at the next explicit start" {
  let rep = dash_period_test_rep()
  let text = "<MPD mediaPresentationDuration=\"PT5S\"><Period>" +
    rep +
    "</Period><Period start=\"PT2S\">" +
    rep +
    "</Period></MPD>"
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  assert_eq(mpd.periods[0].duration, 2.0)
  assert_eq(mpd.periods[1].duration, 3.0)
  assert_eq(
    mpd.periods[0].adaptation_sets[0].representations[0].segments.length(),
    2,
  )
}

///|
test "DASH known later boundary resolves a missing intermediate start" {
  let rep = dash_period_test_rep()
  let text = "<MPD mediaPresentationDuration=\"PT6S\"><Period>" +
    rep +
    "</Period><Period duration=\"PT2S\">" +
    rep +
    "</Period><Period start=\"PT5S\">" +
    rep +
    "</Period></MPD>"
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  assert_eq((mpd.periods[0].start, mpd.periods[0].duration), (0.0, 3.0))
  assert_eq((mpd.periods[1].start, mpd.periods[1].duration), (3.0, 2.0))
  assert_eq((mpd.periods[2].start, mpd.periods[2].duration), (5.0, 1.0))
}

///|
test "DASH unknown Period durations do not claim the whole MPD duration" {
  let rep = dash_period_test_rep()
  let text = "<MPD type=\"dynamic\"><Period>" +
    rep +
    "</Period><Period>" +
    rep +
    "</Period></MPD>"
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  for period in mpd.periods {
    assert_eq(period.duration, 0.0)
    assert_eq(period.adaptation_sets[0].representations[0].segments.length(), 0)
  }
}

///|
test "DASH MPD end resolves trailing duration while explicit zero stays zero" {
  let rep = dash_period_test_rep()
  let text = "<MPD mediaPresentationDuration=\"PT5S\"><Period>" +
    rep +
    "</Period><Period duration=\"PT2S\">" +
    rep +
    "</Period></MPD>"
  let mpd = @libavformat.av_dash_parse(text).unwrap()
  assert_eq((mpd.periods[0].start, mpd.periods[0].duration), (0.0, 3.0))
  assert_eq((mpd.periods[1].start, mpd.periods[1].duration), (3.0, 2.0))
  let zero = @libavformat.av_dash_parse(
    "<MPD mediaPresentationDuration=\"PT5S\"><Period duration=\"PT0S\"/><Period/></MPD>",
  ).unwrap()
  assert_eq(zero.periods[0].duration, 0.0)
  assert_eq((zero.periods[1].start, zero.periods[1].duration), (0.0, 5.0))
}
