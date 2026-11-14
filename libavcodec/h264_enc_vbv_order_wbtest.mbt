///|
test "VBV solver raises the display picture belonging to an underflowing AU" {
  let v = match h264_vbv_new(64000, 8000, 25, 90) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let (qps, _) = match
    h264_vbv_solve(
      3,
      10,
      v,
      fn(qps) {
        // Coding order I0, P2, B1. Only P2 needs coarsening. Raising the
        // same-numbered display picture B1 cannot repair the second removal.
        Ok([100, if qps[2] < 20 { 1200 } else { 600 }, 100])
      },
      coding_order=h264_b_coding_order(3),
    ) {
    Ok(q) => q
    Err(e) => fail(e)
  }
  assert_eq(qps[0], 10)
  assert_eq(qps[1], 10)
  assert_true(qps[2] >= 20)
  assert_eq(h264_b_coding_order(7, gop_size=4), [0, 2, 1, 3, 4, 6, 5])
}
