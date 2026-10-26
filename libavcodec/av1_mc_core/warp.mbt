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

///|
/// Warp-predict a whole plane: dav1d `recon_tmpl.c` `warp_affine` 8x8
/// sub-block iteration. `matrix` is the 16.16 affine model and
/// `alpha/beta/gamma/delta` are its shear parameters; `bx4/by4` are luma
/// 4x4 block coordinates and `ss_h/ss_v` select the chroma plane.
pub fn av1_mc_warp_predict_plane(
  src : FixedArray[Int32],
  stride : Int32,
  ref_w : Int,
  ref_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
  bitdepth : Int32,
  matrix : FixedArray[Int32],
  alpha : Int,
  beta : Int,
  gamma : Int,
  delta : Int,
) -> FixedArray[Int32] {
  let h_mul = 4 >> ss_h
  let v_mul = 4 >> ss_v
  let width = (ref_w + ss_h) >> ss_h
  let height = (ref_h + ss_v) >> ss_v
  let w = bw4 * h_mul
  let h = bh4 * v_mul
  let dst = FixedArray::make(w * h, 0)
  let abcd : FixedArray[Int32] = [
    matrix[2] - 0x10000, matrix[3], matrix[4], matrix[5] - 0x10000,
  ]
  let mut y = 0
  while y < h {
    let src_y = by4 * 4 + ((y + 4) << ss_v)
    let mat3_y : Int64 = matrix[3].to_int64() * src_y.to_int64() +
      matrix[0].to_int64()
    let mat5_y : Int64 = matrix[5].to_int64() * src_y.to_int64() +
      matrix[1].to_int64()
    let mut x = 0
    while x < w {
      let src_x = bx4 * 4 + ((x + 4) << ss_h)
      let mvx : Int64 = (matrix[2].to_int64() * src_x.to_int64() + mat3_y) >> ss_h
      let mvy : Int64 = (matrix[4].to_int64() * src_x.to_int64() + mat5_y) >> ss_v
      let dx = (mvx >> 16).to_int() - 4
      let mx = ((mvx & 0xffffL).to_int() - alpha * 4 - beta * 7) & -64
      let dy = (mvy >> 16).to_int() - 4
      let my = ((mvy & 0xffffL).to_int() - gamma * 4 - delta * 4) & -64
      let block = av1_mc_warp_affine_8x8(
        src, stride, width, height, dx, dy, abcd, mx, my, bitdepth,
      )
      for yy in 0..<8 {
        for xx in 0..<8 {
          dst[(y + yy) * w + x + xx] = block[yy * 8 + xx]
        }
      }
      x = x + 8
    }
    y = y + 8
  }
  dst
}
