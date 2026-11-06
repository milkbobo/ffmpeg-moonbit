///|
/// Whitebox tests for the `mathematics` port.
/// Expected values are taken from the FFmpeg sources themselves
/// (libavutil/mathematics.c / mathematics.h and their unit tests).
test "av_gcd" {
  assert_eq(av_gcd(693, 609), 21)
  assert_eq(av_gcd(0, 5), 5)
  assert_eq(av_gcd(5, 0), 5)
  assert_eq(av_gcd(17, 5), 1)
  assert_eq(av_gcd(-6, 4), 2)
  assert_eq(av_gcd(-6, -4), 2)
  assert_eq(av_gcd(1099511627776L, 137438953472L), 137438953472L)
}

///|
test "av_log2" {
  assert_eq(av_log2(1), 0)
  assert_eq(av_log2(2), 1)
  assert_eq(av_log2(3), 1)
  assert_eq(av_log2(255), 7)
  assert_eq(av_log2(256), 8)
  assert_eq(av_log2(0xFFFFFFFF), 31)
}

///|
test "av_rescale_rnd rounding modes" {
  assert_eq(av_rescale_rnd(3, 1, 2, av_round_up), 2)
  assert_eq(av_rescale_rnd(3, 1, 2, av_round_down), 1)
  assert_eq(av_rescale_rnd(3, 1, 2, av_round_near_inf), 2)
  assert_eq(av_rescale_rnd(3, 1, 2, av_round_zero), 1)
  assert_eq(av_rescale_rnd(-3, 1, 2, av_round_up), -1)
  assert_eq(av_rescale_rnd(-3, 1, 2, av_round_down), -2)
  assert_eq(av_rescale_rnd(-3, 1, 2, av_round_near_inf), -2)
  assert_eq(av_rescale(3, 1, 2), 2)
}

///|
test "av_rescale_rnd large operands use the split multiply" {
  // 1 * 2^32 / 2^31 == 2, exercising the b/c > INT_MAX branch.
  assert_eq(av_rescale_rnd(1, 4294967296L, 2147483648L, av_round_near_inf), 2)
  // INT64_MAX * 2 / 3 truncates toward zero to 6148914691236517204.
  assert_eq(
    av_rescale_rnd(9223372036854775807L, 2, 3, av_round_zero),
    6148914691236517204L,
  )
}

///|
test "av_rescale_q" {
  assert_eq(av_rescale_q(1000, av_make_q(1, 1000), av_make_q(1, 1)), 1)
  assert_eq(av_rescale_q(1, av_make_q(1, 25), av_make_q(1, 1000)), 40)
}

///|
test "av_compare_mod" {
  assert_eq(av_compare_mod(0x11, 0x02, 0x10), -1)
  assert_eq(av_compare_mod(0x11, 0x02, 0x20), 15)
  assert_eq(av_compare_mod(3, 5, 16), -2)
}

///|
test "av_sat_add64 saturates both ways" {
  assert_eq(av_sat_add64(1L, 2L), 3L)
  assert_eq(av_sat_add64(int64_max, 1L), int64_max)
  assert_eq(av_sat_add64(int64_min, -1L), int64_min)
}

///|
test "av_add_stable reproduces FFmpeg's AAC-in-TS timestamp walk" {
  // 1024-sample frames at 44.1 kHz on the 90 kHz clock: the pts sequence
  // the real mpegts demuxer reports for one PES (2089.8 ticks per frame).
  let tb = av_make_q(1, 90000)
  let inc = av_make_q(1024, 44100)
  let expected : Array[Int64] = [
    128090, 130179, 132269, 134359, 136449, 138539, 140628,
  ]
  let mut ts = 126000L
  for want in expected {
    ts = av_add_stable(tb, ts, inc, 1L)
    assert_eq(ts, want)
  }
  // An exact tick count takes the plain addition path.
  assert_eq(av_add_stable(av_make_q(1, 1000), 5L, av_make_q(1, 10), 1L), 105L)
  // An increment below one tick cannot move the timestamp.
  assert_eq(av_add_stable(tb, 7L, av_make_q(1, 180000), 1L), 7L)
}
