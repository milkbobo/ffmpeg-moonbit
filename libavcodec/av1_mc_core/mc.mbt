///|
/// AV1 unscaled single-reference motion compensation. Port of dav1d 1.5.1
/// `src/mc_tmpl.c` `put_8tap_c` and `put_bilin_c`. Source coordinates refer
/// to the integer-pixel MV position; fractional phases are in sixteenths.
/// Out-of-frame taps repeat the nearest edge pixel, as dav1d's edge emulation
/// buffer does before calling these filters.

///|
fn av1_mc_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn av1_mc_sample(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  x : Int32,
  y : Int32,
) -> Int32 {
  src[av1_mc_clip(y, 0, height - 1) * stride + av1_mc_clip(x, 0, width - 1)]
}

///|
fn av1_mc_filter_sum(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  x : Int32,
  y : Int32,
  phase : Int32,
  filter : Int32,
  vertical : Bool,
) -> Int32 {
  let off = (filter * 15 + phase - 1) * 8
  let mut sum = 0
  for tap in 0..<8 {
    let sx = x + (if vertical { 0 } else { tap - 3 })
    let sy = y + (if vertical { tap - 3 } else { 0 })
    sum += av1_mc_subpel_filters[off + tap] *
      av1_mc_sample(src, stride, width, height, sx, sy)
  }
  sum
}

///|
/// `filter_type`: dav1d `Filter2d` 0..8 (all 8-tap combinations), 9 bilinear.
/// Output is a packed `w*h` block. The caller supplies a valid source plane.
pub fn av1_mc_put_unscaled(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  src_x : Int32,
  src_y : Int32,
  w : Int32,
  h : Int32,
  mx : Int32,
  my : Int32,
  filter_type : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(w * h, 0)
  let max_pixel = (1 << bitdepth) - 1
  let ib = if bitdepth == 12 { 2 } else { 4 }
  if filter_type == 9 {
    let h_rnd = if ib == 4 { 0 } else { 2 }
    for y in 0..<h {
      for x in 0..<w {
        let sx = src_x + x
        let sy = src_y + y
        let a = av1_mc_sample(src, stride, width, height, sx, sy)
        let v = if mx != 0 && my != 0 {
          let b = av1_mc_sample(src, stride, width, height, sx + 1, sy)
          let c = av1_mc_sample(src, stride, width, height, sx, sy + 1)
          let d = av1_mc_sample(src, stride, width, height, sx + 1, sy + 1)
          let top = ((16 - mx) * a + mx * b + h_rnd) >> (4 - ib)
          let bottom = ((16 - mx) * c + mx * d + h_rnd) >> (4 - ib)
          ((16 - my) * top + my * bottom + (1 << (3 + ib))) >> (4 + ib)
        } else if mx != 0 {
          let b = av1_mc_sample(src, stride, width, height, sx + 1, sy)
          let mid = ((16 - mx) * a + mx * b + h_rnd) >> (4 - ib)
          (mid + (1 << (ib - 1))) >> ib
        } else if my != 0 {
          let b = av1_mc_sample(src, stride, width, height, sx, sy + 1)
          ((16 - my) * a + my * b + 8) >> 4
        } else {
          a
        }
        dst[y * w + x] = av1_mc_clip(v, 0, max_pixel)
      }
    }
    return dst
  }
  let h_filter = if filter_type < 3 {
    0
  } else if filter_type < 6 {
    2
  } else {
    1
  }
  let v_filter = filter_type % 3
  let hf = if w > 4 { h_filter } else { 3 + (h_filter & 1) }
  let vf = if h > 4 { v_filter } else { 3 + (v_filter & 1) }
  for y in 0..<h {
    for x in 0..<w {
      let sx = src_x + x
      let sy = src_y + y
      let v = if mx != 0 && my != 0 {
        let mut sum = 0
        let voff = (vf * 15 + my - 1) * 8
        for tap in 0..<8 {
          let horizontal = av1_mc_filter_sum(
            src,
            stride,
            width,
            height,
            sx,
            sy + tap - 3,
            mx,
            hf,
            false,
          )
          let mid = (horizontal + (1 << (5 - ib))) >> (6 - ib)
          sum += av1_mc_subpel_filters[voff + tap] * mid
        }
        (sum + (1 << (5 + ib))) >> (6 + ib)
      } else if mx != 0 {
        let sum = av1_mc_filter_sum(
          src, stride, width, height, sx, sy, mx, hf, false,
        )
        (sum + 32 + (1 << (5 - ib))) >> 6
      } else if my != 0 {
        let sum = av1_mc_filter_sum(
          src, stride, width, height, sx, sy, my, vf, true,
        )
        (sum + 32) >> 6
      } else {
        av1_mc_sample(src, stride, width, height, sx, sy)
      }
      dst[y * w + x] = av1_mc_clip(v, 0, max_pixel)
    }
  }
  dst
}
