///|
/// Warp-affine 8x8 kernels, port of dav1d 1.5.1 `src/mc_tmpl.c`
/// `warp_affine_8x8_c` (pixels) and `warp_affine_8x8t_c` (`prep` samples).
/// `abcd` holds the affine model a/b/c/d; `mx`/`my` give the warp phase of
/// the block's top-left corner in 1/1024 units; the block anchors at
/// `(ox, oy)` in the source plane.

///|
/// One horizontal intermediate: 8-tap warp filter over columns
/// `ox+x-3 .. ox+x+4` of source row `oy+row-3`, at `ib` precision.
fn av1_mc_warp_h_mid(
  src : FixedArray[Int32], stride : Int32, width : Int32, height : Int32,
  ox : Int32, oy : Int32, row : Int32, x : Int32, fidx : Int32, ib : Int32,
) -> Int32 {
  let off = fidx * 8
  let mut sum = 0
  for tap in 0..<8 {
    sum += av1_mc_warp_filter[off + tap] *
      av1_mc_sample(src, stride, width, height, ox + x + tap - 3, oy + row - 3)
  }
  (sum + (1 << (6 - ib))) >> (7 - ib)
}

///|
/// Build the 15 horizontal intermediate rows shared by both warp kernels.
fn av1_mc_warp_mid_rows(
  src : FixedArray[Int32], stride : Int32, width : Int32, height : Int32,
  ox : Int32, oy : Int32, abcd : FixedArray[Int32], mx : Int32, ib : Int32,
) -> FixedArray[Int32] {
  let mid = FixedArray::make(15 * 8, 0)
  for m in 0..<15 {
    let row_mx = mx + m * abcd[1]
    for x in 0..<8 {
      mid[m * 8 + x] = av1_mc_warp_h_mid(
        src, stride, width, height, ox, oy, m, x,
        64 + ((row_mx + x * abcd[0] + 512) >> 10), ib,
      )
    }
  }
  mid
}

///|
/// Warp-affine predicted 8x8 pixel block.
pub fn av1_mc_warp_affine_8x8(
  src : FixedArray[Int32], stride : Int32, width : Int32, height : Int32,
  ox : Int32, oy : Int32, abcd : FixedArray[Int32], mx : Int32, my : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(8 * 8, 0)
  let max_pixel = (1 << bitdepth) - 1
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let mid = av1_mc_warp_mid_rows(
    src, stride, width, height, ox, oy, abcd, mx, ib,
  )
  for y in 0..<8 {
    let row_my = my + y * abcd[3]
    for x in 0..<8 {
      let off = (64 + ((row_my + x * abcd[2] + 512) >> 10)) * 8
      let mut acc = 0
      for tap in 0..<8 {
        acc += av1_mc_warp_filter[off + tap] * mid[(y + tap) * 8 + x]
      }
      dst[y * 8 + x] = av1_mc_clip(
        (acc + (1 << (6 + ib))) >> (7 + ib), 0, max_pixel,
      )
    }
  }
  dst
}

///|
/// Warp-affine 8x8 `prep` block: biased intermediate samples for compound
/// prediction (dav1d `warp_affine_8x8t_c`).
pub fn av1_mc_warp_affine_8x8t(
  src : FixedArray[Int32], stride : Int32, width : Int32, height : Int32,
  ox : Int32, oy : Int32, abcd : FixedArray[Int32], mx : Int32, my : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(8 * 8, 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
  let mid = av1_mc_warp_mid_rows(
    src, stride, width, height, ox, oy, abcd, mx, ib,
  )
  for y in 0..<8 {
    let row_my = my + y * abcd[3]
    for x in 0..<8 {
      let off = (64 + ((row_my + x * abcd[2] + 512) >> 10)) * 8
      let mut acc = 0
      for tap in 0..<8 {
        acc += av1_mc_warp_filter[off + tap] * mid[(y + tap) * 8 + x]
      }
      dst[y * 8 + x] = ((acc + 64) >> 7) - bias
    }
  }
  dst
}
