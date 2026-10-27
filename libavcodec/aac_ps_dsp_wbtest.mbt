///|
/// Regression for the matching-grid branches of FFmpeg's remap20/remap34.
test "PS matching parameter grids remain unchanged" {
  let par = Array::make(5 * 34, 0)
  for i in 0..<34 {
    par[i] = i
  }
  for count in [20, 11] {
    let mapped = ps_remap(par, count, 1, false, count == 20)
    for i in 0..<count {
      assert_eq(mapped[i], par[i])
    }
  }
  for count in [34, 17] {
    let mapped = ps_remap(par, count, 1, true, count == 34)
    for i in 0..<count {
      assert_eq(mapped[i], par[i])
    }
  }
}

///|
/// FFmpeg's hybrid synthesis deinterleaves the supplied channel buffer.
test "PS hybrid synthesis retains each channel's high bands" {
  let left = Array::make(91 * 32 * 2, 0.0)
  let right = Array::make(91 * 32 * 2, 0.0)
  let x = Array::make(2 * 2 * 38 * 64, 0.0)
  for is34 in [false, true] {
    let base = if is34 { 27 } else { 7 }
    let band = if is34 { 5 } else { 3 }
    let index = (base + band) * 32 * 2
    left[index] = 2.0
    right[index] = -3.0
    ps_hybrid_synthesis(x, 0, left, is34, 32)
    ps_hybrid_synthesis(x, 2 * 38 * 64, right, is34, 32)
    assert_eq(x[band], 2.0)
    assert_eq(x[2 * 38 * 64 + band], -3.0)
  }
}

///|
/// The C IPD/OPD kernel adds the decorrelated real contribution.
test "PS complex stereo interpolation adds both real contributions" {
  let l = [2.0, 3.0]
  let r = [5.0, 7.0]
  let h = [1.0, 2.0, 3.0, 4.0, 0.0, 0.0, 0.0, 0.0]
  let step = Array::make(8, 0.0)
  ps_stereo_interpolate_ipdopd(l, 0, r, 0, h, step, 1)
  assert_eq(l[0], 17.0)
  assert_eq(l[1], 24.0)
  assert_eq(r[0], 24.0)
  assert_eq(r[1], 34.0)
}
