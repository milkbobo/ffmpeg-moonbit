///|
/// OBMC overlap masks from dav1d 1.5.1 `src/tables.c`. The mask for an
/// overlap of size n starts at index n; valid sizes are 2, 4, 8, 16, 32.
let av1_mc_obmc_masks : FixedArray[Int32] = [
  0, 0, 19, 0, 25, 14, 5, 0,
  28, 22, 16, 11, 7, 3, 0, 0,
  30, 27, 24, 21, 18, 15, 12, 10,
  8, 6, 4, 3, 0, 0, 0, 0,
  31, 29, 28, 26, 24, 23, 21, 20,
  19, 17, 16, 14, 13, 12, 11, 9,
  8, 7, 6, 5, 4, 4, 3, 2,
  0, 0, 0, 0, 0, 0, 0, 0,
]

///|
/// Blend the left overlap of two packed pixel blocks with dav1d `blend_v_c`.
/// `w` is the overlap width (2, 4, 8, 16, or 32). The right quarter is copied
/// unchanged from `dst`.
pub fn av1_mc_obmc_vertical(
  dst : FixedArray[Int32], tmp : FixedArray[Int32], w : Int32, h : Int32,
) -> FixedArray[Int32] {
  let out = FixedArray::make(w * h, 0)
  let overlap = (w * 3) >> 2
  for y in 0..<h {
    for x in 0..<w {
      let i = y * w + x
      if x < overlap {
        let m = av1_mc_obmc_masks[w + x]
        out[i] = (dst[i] * (64 - m) + tmp[i] * m + 32) >> 6
      } else {
        out[i] = dst[i]
      }
    }
  }
  out
}

///|
/// Blend the top overlap of two packed pixel blocks with dav1d `blend_h_c`.
/// `h` is the overlap height (2, 4, 8, 16, or 32). The bottom quarter is
/// copied unchanged from `dst`.
pub fn av1_mc_obmc_horizontal(
  dst : FixedArray[Int32], tmp : FixedArray[Int32], w : Int32, h : Int32,
) -> FixedArray[Int32] {
  let out = FixedArray::make(w * h, 0)
  let overlap = (h * 3) >> 2
  for y in 0..<h {
    for x in 0..<w {
      let i = y * w + x
      if y < overlap {
        let m = av1_mc_obmc_masks[h + y]
        out[i] = (dst[i] * (64 - m) + tmp[i] * m + 32) >> 6
      } else {
        out[i] = dst[i]
      }
    }
  }
  out
}
