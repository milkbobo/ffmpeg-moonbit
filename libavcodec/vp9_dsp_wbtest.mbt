///|
/// Regression expectations follow vp9dsp_template.c's integer formulas.
test "vp9 dsp: DC scaling and coefficient scratch clearing" {
  for tx in 0..<4 {
    let n = 4 << tx
    let pixels = FixedArray::make(n * n, 128)
    let block = FixedArray::make(n * n, 0)
    block[0] = if tx == 3 { 128 } else { 32 << tx }
    vp9_itxfm_add(tx, 0, pixels, 0, n, block, 0, 1, 8, 255)
    for value in pixels { assert_eq(value, 129) }
    assert_eq(block[0], 0)
    block[1] = 64
    vp9_itxfm_add(tx, 0, pixels, 0, n, block, 0, 2, 8, 255)
    for value in block { assert_eq(value, 0) }
  }
}

///|
test "vp9 dsp: HOR_UP 4x4 fills every sample with the C coordinates" {
  let pixels = FixedArray::make(16, -1)
  let left : FixedArray[Int32] = [10, 20, 30, 40]
  vp9_pred_hor_up_4x4(pixels, 0, 4, left)
  let expected : FixedArray[Int32] = [
    15, 20, 25, 30,
    25, 30, 35, 38,
    35, 38, 40, 40,
    40, 40, 40, 40,
  ]
  for i in 0..<16 { assert_eq(pixels[i], expected[i]) }
}

///|
test "vp9 dsp: loop filter clamps signed intermediates to the bit depth" {
  for value in [-300, -129, -128, -65, -64, 0, 63, 64, 127, 128, 300] {
    assert_eq(vp9_clip_intp2(value, 7), value.clamp(min=-128, max=127))
    assert_eq(vp9_clip_intp2(value, 9), value.clamp(min=-512, max=511))
  }
}
