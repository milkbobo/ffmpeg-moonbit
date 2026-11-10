///|
/// Forward transform and quantisation for the H.264 encoder: the exact
/// transpose of the decoder's integer IDCT (`h264_idct.mbt`) so the
/// quantise/dequantise pair inverts within one quantisation step, plus the
/// standard 8-bit quantisation multiply factors (the `quant8_fix` values
/// every H.264 implementation pairs with FFmpeg's dequant tables).
///
/// Coefficient blocks are stored in FFmpeg's transposed layout (see
/// `h264_cavlc.mbt`'s header): storage position `s = (p >> 2) | ((p << 2) &
/// 0xF)` for spec (row-major) position `p`, so the scan tables, `qmul`
/// arrays and `h264_idct_add` all consume them unchanged.

///|
/// Forward-quant multiply factor for `[qp % 6][position_class]`, derived
/// from this decoder's dequantisation: one level maps to a reconstruction
/// step of `dequant4_init[rem][cls] << (qp/6)` (the `h264_build_dequant4`
/// tables times the IDCT `>> 6` scale), so
/// `level = (|Y| * (2^17/init)) >> (21 + qp/6 + extra_shift)` reproduces
/// it with the unshifted forward transform below (the extra 16 in the
/// shift cancels the transform's DC gain). Three position classes
/// (`(x&1) + ((x>>2)&1)`).
fn h264_enc_mf(rem : Int32, cls : Int32) -> Int32 {
  match (rem, cls) {
    (0, 0) => 13107
    (0, 1) => 10082
    (0, _) => 8192
    (1, 0) => 11916
    (1, 1) => 9362
    (1, _) => 7282
    (2, 0) => 10082
    (2, 1) => 8192
    (2, _) => 6554
    (3, 0) => 9362
    (3, 1) => 7282
    (3, _) => 5704
    (4, 0) => 8192
    (4, 1) => 6554
    (4, _) => 5243
    (5, 0) => 7282
    (5, 1) => 5704
    (_, _) => 4559
  }
}

///|
/// Quantise one coefficient (Int64 intermediate: a full-scale luma DC
/// Hadamard coefficient times the largest factor overflows Int32). */
fn h264_enc_quant_val(
  coef : Int32,
  qp : Int32,
  pos_class : Int32,
  extra_shift~ : Int32 = 1,
) -> Int32 {
  let rem = qp % 6
  let div = qp / 6
  let qbits = 16 + div + extra_shift
  let mf = h264_enc_mf(rem, pos_class)
  if coef == 0 {
    return 0
  }
  let mag = if coef < 0 { -coef } else { coef }
  let v = (mag * mf + (1 << (qbits - 1))) >> qbits
  if coef < 0 {
    -v
  } else {
    v
  }
}

///|
/// One 1-D stage of the canonical (shift-free) forward transform: the pure
/// integer butterfly whose inverse carries the `>> 1` steps. The DC gain is
/// exactly the 16-sample sum, which is the convention the quantisation
/// multiply factors are tuned against.
fn h264_enc_fdct1d(
  src : Array[Int32],
  src_off : Int32,
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
) -> Unit {
  // s03 = x0 + x3, d03 = x0 - x3, s12 = x1 + x2, d12 = x1 - x2
  let s03 = src[src_off] + src[src_off + 3 * stride]
  let d03 = src[src_off] - src[src_off + 3 * stride]
  let s12 = src[src_off + stride] + src[src_off + 2 * stride]
  let d12 = src[src_off + stride] - src[src_off + 2 * stride]
  dst[dst_off] = s03 + s12
  dst[dst_off + stride] = d03 + d12
  dst[dst_off + 2 * stride] = s03 - s12
  dst[dst_off + 3 * stride] = d03 - d12
}

///|
/// Forward 4x4 transform + quantisation of a row-major residual block (16
/// samples at `res[res_off..]`, row stride 4). Returns the levels indexed
/// by transposed storage position. */
fn h264_enc_fdct_quant_res(
  res : Array[Int32],
  res_off : Int32,
  qp : Int32,
) -> Array[Int32] {
  let tmp : Array[Int32] = Array::make(16, 0)
  let col : Array[Int32] = Array::make(16, 0)
  for row = 0; row < 4; row = row + 1 {
    h264_enc_fdct1d(res, res_off + row * 4, tmp, row * 4, 1)
  }
  for c = 0; c < 4; c = c + 1 {
    h264_enc_fdct1d(tmp, c, col, c, 4)
  }
  let levels : Array[Int32] = Array::make(16, 0)
  for p = 0; p < 16; p = p + 1 {
    let s = (p >> 2) | ((p << 2) & 0xF)
    let cls = (p & 1) + ((p >> 2) & 1)
    levels[s] = h264_enc_quant_val(col[p], qp, cls)
  }
  levels
}

///|
/// Forward 4x4 Hadamard of the Intra16x16 DC residual (row-major DC values
/// of the 16 sub-blocks at `src` grid), quantised into the transposed
/// 16-slot `out` DC block. Returns the level array in scan order. */
fn h264_enc_luma_dc_hadamard_quant(
  src : Array[Int32],
  src_off : Int32,
  src_stride : Int32,
  out : Array[Int32],
  out_off : Int32,
  qp : Int32,
) -> Array[Int32] {
  let tmp : Array[Int32] = Array::make(16, 0)
  for row = 0; row < 4; row = row + 1 {
    let a = src[src_off + row * src_stride]
    let b = src[src_off + row * src_stride + 1]
    let c = src[src_off + row * src_stride + 2]
    let d = src[src_off + row * src_stride + 3]
    tmp[row * 4] = a + b + c + d
    tmp[row * 4 + 1] = a + b - c - d
    tmp[row * 4 + 2] = a - b - c + d
    tmp[row * 4 + 3] = a - b + c - d
  }
  for col = 0; col < 4; col = col + 1 {
    let a = tmp[col]
    let b = tmp[4 + col]
    let c = tmp[8 + col]
    let d = tmp[12 + col]
    tmp[col] = a + b + c + d
    tmp[4 + col] = a + b - c - d
    tmp[8 + col] = a - b - c + d
    tmp[12 + col] = a - b + c - d
  }
  // DC block position classes follow the luma grid: the DC block occupies
  // scan position 0 only for quantisation class purposes (flat class 0 for
  // row/col-even, 1 otherwise) matching the decoder's dequant of the block.
  let levels : Array[Int32] = Array::make(16, 0)
  for p = 0; p < 16; p = p + 1 {
    let s = (p >> 2) | ((p << 2) & 0xF)
    let cls = (p & 1) + ((p >> 2) & 1)
    let level = h264_enc_quant_val(tmp[p], qp, cls, extra_shift=1)
    out[out_off + s] = level
    levels[s] = level
  }
  levels
}

///|
/// Forward 2x2 Hadamard of one chroma plane's DC residual (the four
/// sub-block DC values in scan order 0/1/2/3 at `src[0..3]`), quantised
/// into `out[0..3]` (scan order). Returns the four levels. */
fn h264_enc_chroma_dc_hadamard_quant(
  src : Array[Int32],
  out : Array[Int32],
  out_off : Int32,
  qp : Int32,
) -> Array[Int32] {
  let a = src[0]
  let b = src[1]
  let c = src[2]
  let d = src[3]
  let t : Array[Int32] = [
    a + b + c + d,
    a + b - c - d,
    a - b - c + d,
    a - b + c - d,
  ]
  // The chroma DC block quantises with the luma-class-0 factor (the
  // decoder's chroma DC dequant uses `qmul = build_dequant4(...)[0]`).
  let levels : Array[Int32] = Array::make(4, 0)
  for i = 0; i < 4; i = i + 1 {
    let level = h264_enc_quant_val(t[i], qp, 0, extra_shift=5)
    out[out_off + i] = level
    levels[i] = level
  }
  levels
}

///|
/// Forward-quant multiply factors for the 8x8 transform (`[rem][spec pos]`).
/// Calibrated against this decoder's `h264_build_dequant8` under the same
/// invariant the 4x4 table has at flat scaling - the dequantised
/// coefficient equals the unshifted forward-transform output
/// (`step_quant == step_dequant`): `qmul8 = init8 * 16 << (qp/6)` against
/// `qbits = 17 + qp/6`, so `mf8 = round(2^19 / init8)`. These are exactly
/// x264's `quant8_mf` values (26214/29127/16384/... for rem 0).
let h264_enc_mf8 : FixedArray[FixedArray[Int32]] = {
  let t : FixedArray[FixedArray[Int32]] = FixedArray::make(
    6,
    FixedArray::make(64, 0),
  )
  for rem = 0; rem < 6; rem = rem + 1 {
    for x = 0; x < 64; x = x + 1 {
      let init = h264_dequant8_init[rem][h264_dequant8_init_scan[((x >> 1) & 12) |
        (x & 3)]]
      t[rem][x] = (524288 + init / 2) / init
    }
  }
  t
}

///|
/// One 1-D stage of the forward 8x8 transform: the multiplier-free
/// butterfly that pairs with the decoder's `h264_idct8_add` (x264's
/// `DCT8_1D`, the H.264 High-profile transform_8x8 forward transform).
/// Shift-free like the 4x4 `h264_enc_fdct1d`: the inverse carries the
/// `>> 1` / `>> 2` steps, and the DC gain is the 8-sample sum.
fn h264_enc_fdct8_1d(
  src : Array[Int32],
  src_off : Int32,
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
) -> Unit {
  // s07 = x0+x7, d07 = x0-x7, ... (even sums / odd differences)
  let s07 = src[src_off] + src[src_off + 7 * stride]
  let s16 = src[src_off + stride] + src[src_off + 6 * stride]
  let s25 = src[src_off + 2 * stride] + src[src_off + 5 * stride]
  let s34 = src[src_off + 3 * stride] + src[src_off + 4 * stride]
  let d07 = src[src_off] - src[src_off + 7 * stride]
  let d16 = src[src_off + stride] - src[src_off + 6 * stride]
  let d25 = src[src_off + 2 * stride] - src[src_off + 5 * stride]
  let d34 = src[src_off + 3 * stride] - src[src_off + 4 * stride]
  let a0 = s07 + s34
  let a1 = s16 + s25
  let a2 = s07 - s34
  let a3 = s16 - s25
  dst[dst_off] = a0 + a1
  dst[dst_off + 4 * stride] = a0 - a1
  dst[dst_off + 2 * stride] = a2 + (a3 >> 1)
  dst[dst_off + 6 * stride] = (a2 >> 1) - a3
  let a4 = d16 + d25 + (d07 + (d07 >> 1))
  let a5 = d07 - d34 - (d25 + (d25 >> 1))
  let a6 = d07 + d34 - (d16 + (d16 >> 1))
  let a7 = d16 - d25 + (d34 + (d34 >> 1))
  dst[dst_off + stride] = a4 + (a7 >> 2)
  dst[dst_off + 3 * stride] = a5 + (a6 >> 2)
  dst[dst_off + 5 * stride] = a6 - (a5 >> 2)
  dst[dst_off + 7 * stride] = (a4 >> 2) - a7
}

///|
/// Forward 8x8 transform + quantisation of one row-major residual block
/// (64 samples at `res[res_off..]`, row stride 8). Returns the 64 levels
/// indexed by transposed storage position `(p >> 3) | ((p & 7) << 3)` of the
/// spec position `p` - the layout `h264_build_dequant8`, `h264_scan8x8` and
/// `h264_idct8_add` consume.
fn h264_enc_fdct8_quant_res(
  res : Array[Int32],
  res_off : Int32,
  qp : Int32,
) -> Array[Int32] {
  let tmp : Array[Int32] = Array::make(64, 0)
  let col : Array[Int32] = Array::make(64, 0)
  for row = 0; row < 8; row = row + 1 {
    h264_enc_fdct8_1d(res, res_off + row * 8, tmp, row * 8, 1)
  }
  for c = 0; c < 8; c = c + 1 {
    h264_enc_fdct8_1d(tmp, c, col, c, 8)
  }
  let rem = qp % 6
  let div = qp / 6
  let qbits = 16 + div + 1
  let levels : Array[Int32] = Array::make(64, 0)
  for p = 0; p < 64; p = p + 1 {
    let coef = col[p]
    if coef != 0 {
      let s = (p >> 3) | ((p & 7) << 3)
      let mag = if coef < 0 { -coef } else { coef }
      let v = (mag * h264_enc_mf8[rem][p] + (1 << (qbits - 1))) >> qbits
      levels[s] = if coef < 0 { -v } else { v }
    }
  }
  levels
}

///|
/// The decoder's own dequantisation of one level (`h264_dequant_level`):
/// `(level * qmul + 32) >> 6` with the 8-bit int16 wrap. The encoder's
/// coefficient-buffer fill must be this exact function - a raw product
/// diverges from the decoded block by 64x.
fn h264_enc_dequant_level(level : Int32, qmul : Int32) -> Int32 {
  if level == 0 {
    return 0
  }
  let prod = (level.reinterpret_as_uint() * qmul.reinterpret_as_uint() + 32) >>
    6
  let v = prod.reinterpret_as_int() << 16 >> 16
  v
}
