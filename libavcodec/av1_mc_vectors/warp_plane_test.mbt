///|
/// Warp plane predictor wiring: identity copies, integer translation shifts,
/// and chroma subsampling phases follow dav1d `warp_affine`'s 8x8 loop.

///|
fn warp_plane_pattern(w : Int32, h : Int32) -> FixedArray[Int32] {
  FixedArray::makei(w * h, i => (i % w * 3 + i / w * 5 + 7) % 256)
}

///|
fn warp_plane_identity() -> FixedArray[Int32] {
  [0, 0, 65536, 0, 0, 65536]
}

///|
fn warp_plane_clamp(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
test "warp plane identity copies the luma block" {
  let w = 64
  let h = 48
  let src = warp_plane_pattern(w, h)
  let dst = @av1_mc_core.av1_mc_warp_predict_plane(
    src,
    w,
    w,
    h,
    3,
    2,
    2,
    2,
    0,
    0,
    8,
    warp_plane_identity(),
    0,
    0,
    0,
    0,
  )
  for y in 0..<8 {
    for x in 0..<8 {
      assert_eq(dst[y * 8 + x], src[(2 * 4 + y) * w + 3 * 4 + x])
    }
  }
}

///|
test "warp plane translation shifts and clamps at edges" {
  let w = 64
  let h = 48
  let src = warp_plane_pattern(w, h)
  let mat : FixedArray[Int32] = [8 * 65536, -8 * 65536, 65536, 0, 0, 65536]
  let dst = @av1_mc_core.av1_mc_warp_predict_plane(
    src, w, w, h, 0, 0, 2, 2, 0, 0, 8, mat, 0, 0, 0, 0,
  )
  for y in 0..<8 {
    for x in 0..<8 {
      let sx = warp_plane_clamp(x + 8, 0, w - 1)
      let sy = warp_plane_clamp(y - 8, 0, h - 1)
      assert_eq(dst[y * 8 + x], src[sy * w + sx])
    }
  }
}

///|
test "warp plane chroma uses subsampled phasing" {
  let cw = 32
  let ch = 24
  let src = warp_plane_pattern(cw, ch)
  let dst = @av1_mc_core.av1_mc_warp_predict_plane(
    src,
    cw,
    cw * 2,
    ch * 2,
    3,
    2,
    4,
    4,
    1,
    1,
    8,
    warp_plane_identity(),
    0,
    0,
    0,
    0,
  )
  for y in 0..<8 {
    for x in 0..<8 {
      assert_eq(dst[y * 8 + x], src[(2 * 2 + y) * cw + 3 * 2 + x])
    }
  }
}
