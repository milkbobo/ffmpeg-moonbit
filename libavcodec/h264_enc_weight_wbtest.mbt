// Whitebox unit tests for the encoder's explicit weighted-prediction core
// (§410): the least-squares plane fit and its rounding into the
// `pred_weight_table()` code words.

///|
/// A plane of `w * h` values built from `f(x, y)`.
fn h264wp_plane(
  w : Int32,
  h : Int32,
  f : (Int32, Int32) -> Int32,
) -> Array[Int32] {
  let plane : Array[Int32] = Array::make(w * h, 0)
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      plane[y * w + x] = f(x, y)
    }
  }
  plane
}

///|
test "h264 enc weight: exact gain and offset are recovered" {
  // dst = floor(src * 26 / 32) + 3 over a textured source: the normal
  // equations recover a slope of 26/32 (weight 26 at denom 5) and the +3.
  let w = 24
  let h = 16
  let src = h264wp_plane(w, h, fn(x, y) {
    (x * 7 + y * 11 + x * y % 13 * 3) % 200 + 20
  })
  let dst = h264wp_plane(w, h, fn(x, y) {
    let s = (x * 7 + y * 11 + x * y % 13 * 3) % 200 + 20
    s * 26 / 32 + 3
  })
  let (weight, offset) = h264_enc_plane_weight(dst, w, src, w, w, h, 5)
  if weight < 24 || weight > 28 {
    fail("expected weight near 26, got \{weight}")
  }
  if offset < 1 || offset > 5 {
    fail("expected offset near 3, got \{offset}")
  }
}

///|
test "h264 enc weight: flat reference keeps a neutral slope but fits the offset" {
  let w = 8
  let h = 8
  let src = h264wp_plane(w, h, fn(_x, _y) { 100 })
  let dst = h264wp_plane(w, h, fn(_x, _y) { 120 })
  let (weight, offset) = h264_enc_plane_weight(dst, w, src, w, w, h, 5)
  // No slope exists (zero variance), so the neutral weight is emitted rather
  // than dividing by the degenerate denominator; the DC shift is still
  // exactly representable, and (1.0 * 100) + 20 reconstructs 120.
  inspect(weight, content="32")
  inspect(offset, content="20")
  inspect(weight * 100 / 32 + offset, content="120")
}

///|
test "h264 enc weight: identity reference stays neutral" {
  let w = 16
  let h = 16
  let src = h264wp_plane(w, h, fn(x, y) { (x * 5 + y * 3) % 251 })
  let (weight, offset) = h264_enc_plane_weight(src, w, src, w, w, h, 5)
  inspect(weight, content="32")
  inspect(offset, content="0")
}

///|
test "h264 enc weight: weights stay inside the PWT code-word range" {
  // A near-black destination against a bright source drives the slope far
  // below zero; the fit must clamp into -128..127 (the syntax range) and
  // the offset likewise.
  let w = 16
  let h = 16
  let src = h264wp_plane(w, h, fn(x, y) { 200 + (x + y) % 56 })
  let dst = h264wp_plane(w, h, fn(_x, _y) { 1 })
  let (weight, offset) = h264_enc_plane_weight(dst, w, src, w, w, h, 5)
  if weight < 0 || weight > 127 {
    fail("weight \{weight} outside the PWT range")
  }
  if offset < -128 || offset > 127 {
    fail("offset \{offset} outside the PWT range")
  }
}
