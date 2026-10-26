///|
/// Compound prediction finishing: average, joint-weighted average, wedge and
/// segment masks use dav1d's input order (`mask_sign` swaps tmp[0]/tmp[1]).

///|
fn compound_prep(seed : Int) -> (FixedArray[Int32], FixedArray[Int32]) {
  let a = FixedArray::makei(64, i => ((i * 7 + seed) % 256))
  let b = FixedArray::makei(64, i => ((i * 11 + seed * 3 + 40) % 256))
  (a, b)
}

///|
test "compound average and weighted average dispatch" {
  let (a, b) = compound_prep(3)
  let avg = @av1_mc_core.av1_mc_compound_blend(
    a, b, 2, 0, 0, [], 8, 8, 0, 0, 8,
  )
  assert_eq(avg, @av1_mc_core.av1_mc_avg(a, b, 8))
  let wavg = @av1_mc_core.av1_mc_compound_blend(
    a, b, 1, 1, 9, [], 8, 8, 0, 0, 8,
  )
  // weighted average ignores mask_sign and uses the dav1d weight directly
  assert_eq(wavg, @av1_mc_core.av1_mc_w_avg(a, b, 9, 8))
}

///|
test "compound wedge and segment swap inputs on mask sign" {
  let (a, b) = compound_prep(5)
  let mask = @av1_mc_core.av1_wedge_mask(0, 17, 0, 6)
  let w0 = @av1_mc_core.av1_mc_compound_blend(
    a, b, 4, 0, 0, mask, 8, 8, 0, 0, 8,
  )
  assert_eq(w0, @av1_mc_core.av1_mc_mask(a, b, mask, 8))
  let w1 = @av1_mc_core.av1_mc_compound_blend(
    a, b, 4, 1, 0, mask, 8, 8, 0, 0, 8,
  )
  assert_eq(w1, @av1_mc_core.av1_mc_mask(b, a, mask, 8))
  let (s0, _) = @av1_mc_core.av1_mc_diffwtd_mask(a, b, 8, 8, 0, 0, 0, 8)
  assert_eq(
    @av1_mc_core.av1_mc_compound_blend(a, b, 3, 0, 0, [], 8, 8, 0, 0, 8),
    s0,
  )
  let (s1, _) = @av1_mc_core.av1_mc_diffwtd_mask(b, a, 8, 8, 1, 0, 0, 8)
  assert_eq(
    @av1_mc_core.av1_mc_compound_blend(a, b, 3, 1, 0, [], 8, 8, 0, 0, 8),
    s1,
  )
}

///|
test "warp prepare plane matches the prep kernel" {
  let w = 64
  let h = 48
  let src = FixedArray::makei(w * h, i => ((i * 3 + i / w * 5) % 256))
  let mat : FixedArray[Int32] = [0, 0, 65536, 0, 0, 65536]
  let prep = @av1_mc_core.av1_mc_warp_prepare_plane(
    src, w, w, h, 2, 1, 2, 2, 0, 0, 8, mat, 0, 0, 0, 0,
  )
  let direct = @av1_mc_core.av1_mc_warp_affine_8x8t(
    src, w, w, h, 2 * 4, 1 * 4, [0, 0, 0, 0], 0, 0, 8,
  )
  for i in 0..<64 {
    assert_eq(prep[i], direct[i])
  }
}
