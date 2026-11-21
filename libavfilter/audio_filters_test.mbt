///|
test "trim removes only long edge silence across channels" {
  let a = [0.0, 0.0, 0.2, 0.0, 0.0, 0.2, 0.0, 0.0]
  let b = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0]
  assert_eq(@libavfilter.audio_trim_range([a, b], 0.001, 2), (2, 8))
  assert_eq(@libavfilter.audio_trim_range([a], 0.001, 2), (2, 6))
  assert_eq(@libavfilter.audio_trim_range([[0.0, 0.0]], 0.001, 2), (2, 2))
}

///|
test "fade endpoints and overlapping gain" {
  let samples = [[1.0, 1.0, 1.0, 1.0, 1.0]]
  @libavfilter.audio_fade(samples, 4, 4)
  assert_eq(samples[0], [0.0, 0.1875, 0.25, 0.1875, 0.0])
}

///|
test "mix upmixes mono and retains the longer tail" {
  let mixed = @libavfilter.audio_mix(
    [[0.25, -0.25]],
    [[0.5, 0.0, 0.25], [-0.5, 0.5, 0.25]],
    0.5,
  ).unwrap()
  assert_eq(mixed, [[0.5, -0.25, 0.125], [0.0, 0.0, 0.125]])
  assert_eq(@libavfilter.audio_apply_gain(mixed, 4.0, 0.75), 1.5)
  assert_eq(@libavfilter.audio_sample_peak(mixed), 0.75)
}
