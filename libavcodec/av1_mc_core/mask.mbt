///|
/// Masked compound prediction from dav1d 1.5.1 `src/mc_tmpl.c`:
/// `mask_c`, `blend_c` and `w_mask_c` (444/422/420 variants).

///|
/// Blend two packed `prep` blocks using a 0..64 mask for the first block.
pub fn av1_mc_mask(
  a : FixedArray[Int32], b : FixedArray[Int32], mask : FixedArray[Int32],
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(a.length(), 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
  let rnd = (32 << ib) + bias * 64
  let max_pixel = (1 << bitdepth) - 1
  for i in 0..<a.length() {
    let m = mask[i]
    dst[i] = av1_mc_clip(
      (a[i] * m + b[i] * (64 - m) + rnd) >> (ib + 6),
      0, max_pixel,
    )
  }
  dst
}

///|
/// Blend two packed pixel blocks; `mask` weights the second block (dav1d
/// `blend_c`, used by OBMC). Both input blocks are already clipped pixels.
pub fn av1_mc_blend_pixels(
  a : FixedArray[Int32], b : FixedArray[Int32], mask : FixedArray[Int32],
) -> FixedArray[Int32] {
  let dst = FixedArray::make(a.length(), 0)
  for i in 0..<a.length() {
    let m = mask[i]
    dst[i] = (a[i] * (64 - m) + b[i] * m + 32) >> 6
  }
  dst
}

///|
/// Difference-weighted compound prediction. Returns packed pixels and a
/// subsampled mask. `ss_hor/ss_ver` are (0,0), (1,0), or (1,1); dimensions
/// must be even where subsampled. `sign` is dav1d's 0/1 rounding adjustment.
pub fn av1_mc_diffwtd_mask(
  a : FixedArray[Int32], b : FixedArray[Int32],
  w : Int32, h : Int32, sign : Int32,
  ss_hor : Int32, ss_ver : Int32, bitdepth : Int32,
) -> (FixedArray[Int32], FixedArray[Int32]) {
  let dst = FixedArray::make(w * h, 0)
  let mask_w = w >> ss_hor
  let mask = FixedArray::make(mask_w * (h >> ss_ver), 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
  let rnd = (32 << ib) + bias * 64
  let max_pixel = (1 << bitdepth) - 1
  let mask_sh = bitdepth + ib - 4
  let mask_rnd = 1 << (mask_sh - 5)
  for y in 0..<h {
    for x in 0..<w {
      let i = y * w + x
      let diff = a[i] - b[i]
      let abs_diff = if diff < 0 { -diff } else { diff }
      let m = av1_mc_clip(38 + ((abs_diff + mask_rnd) >> mask_sh), 0, 64)
      dst[i] = av1_mc_clip(
        (a[i] * m + b[i] * (64 - m) + rnd) >> (ib + 6),
        0, max_pixel,
      )
      if ss_hor == 0 {
        mask[y * mask_w + x] = m
      } else if (x & 1) != 0 {
        let prev_i = i - 1
        let prev_diff = a[prev_i] - b[prev_i]
        let prev_abs = if prev_diff < 0 { -prev_diff } else { prev_diff }
        let prev_m = av1_mc_clip(
          38 + ((prev_abs + mask_rnd) >> mask_sh), 0, 64,
        )
        let mi = (y >> ss_ver) * mask_w + (x >> 1)
        if ss_ver == 0 {
          mask[mi] = (prev_m + m + 1 - sign) >> 1
        } else if (y & 1) == 0 {
          mask[mi] = prev_m + m
        } else {
          mask[mi] = (prev_m + m + mask[mi] + 2 - sign) >> 2
        }
      }
    }
  }
  (dst, mask)
}
