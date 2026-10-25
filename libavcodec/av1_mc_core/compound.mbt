///|
/// Unscaled compound-prediction intermediates and blend modes from dav1d
/// 1.5.1 `src/mc_tmpl.c`: `prep_8tap_c`, `prep_bilin_c`, `avg_c`, `w_avg_c`.
/// `prep` returns signed, biased intermediate samples rather than pixels.

///|
/// Prepare one reference block for compound prediction. Parameters and filter
/// types have the same meaning as `av1_mc_put_unscaled`.
pub fn av1_mc_prep_unscaled(
  src : FixedArray[Int32], stride : Int32, width : Int32, height : Int32,
  src_x : Int32, src_y : Int32, w : Int32, h : Int32,
  mx : Int32, my : Int32, filter_type : Int32, bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(w * h, 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
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
          ((16 - my) * top + my * bottom + 8) >> 4
        } else if mx != 0 {
          let b = av1_mc_sample(src, stride, width, height, sx + 1, sy)
          ((16 - mx) * a + mx * b + h_rnd) >> (4 - ib)
        } else if my != 0 {
          let b = av1_mc_sample(src, stride, width, height, sx, sy + 1)
          ((16 - my) * a + my * b + h_rnd) >> (4 - ib)
        } else {
          a << ib
        }
        dst[y * w + x] = v - bias
      }
    }
    return dst
  }
  let h_filter = if filter_type < 3 { 0 } else if filter_type < 6 { 2 } else { 1 }
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
            src, stride, width, height, sx, sy + tap - 3, mx, hf, false,
          )
          let mid = (horizontal + (1 << (5 - ib))) >> (6 - ib)
          sum += av1_mc_subpel_filters[voff + tap] * mid
        }
        (sum + 32) >> 6
      } else if mx != 0 {
        let sum = av1_mc_filter_sum(
          src, stride, width, height, sx, sy, mx, hf, false,
        )
        (sum + (1 << (5 - ib))) >> (6 - ib)
      } else if my != 0 {
        let sum = av1_mc_filter_sum(
          src, stride, width, height, sx, sy, my, vf, true,
        )
        (sum + (1 << (5 - ib))) >> (6 - ib)
      } else {
        av1_mc_sample(src, stride, width, height, sx, sy) << ib
      }
      dst[y * w + x] = v - bias
    }
  }
  dst
}

///|
/// Equal-weight compound average of two packed `prep` blocks.
pub fn av1_mc_avg(
  a : FixedArray[Int32], b : FixedArray[Int32], bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(a.length(), 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
  let max_pixel = (1 << bitdepth) - 1
  let rnd = (1 << ib) + bias * 2
  for i in 0..<a.length() {
    dst[i] = av1_mc_clip((a[i] + b[i] + rnd) >> (ib + 1), 0, max_pixel)
  }
  dst
}

///|
/// Distance-weighted compound average; `weight` is 0..16 for the first block.
pub fn av1_mc_w_avg(
  a : FixedArray[Int32], b : FixedArray[Int32], weight : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(a.length(), 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
  let max_pixel = (1 << bitdepth) - 1
  let rnd = (8 << ib) + bias * 16
  for i in 0..<a.length() {
    dst[i] = av1_mc_clip(
      (a[i] * weight + b[i] * (16 - weight) + rnd) >> (ib + 4),
      0, max_pixel,
    )
  }
  dst
}
