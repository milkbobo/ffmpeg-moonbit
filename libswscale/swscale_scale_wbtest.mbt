///|
/// `SwsScaleAlgo` currently has a single variant, so this pins the fact
/// that a built context reports back what it was asked for instead of
/// leaving callers to assume bicubic.
test "swscale scale: context reports its algorithm" {
  let s = SwsPlanarScaler::new(src_w=64, src_h=48, dst_w=48, dst_h=36)
  assert_true(s.algo() is Bicubic)
}
