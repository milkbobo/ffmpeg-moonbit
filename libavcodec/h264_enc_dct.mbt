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
/// Standard 8-bit forward-quant multiply factor for `[qp % 6][0..1]`
/// (class 0 = even row and column, class 1 = otherwise). Kept as a match
/// on literals - a top-level table would push the package's wasm init
/// function over V8's local-count limit.
fn h264_enc_mf(rem : Int, cls : Int) -> Int {
  match (rem, cls) {
    (0, 0) => 13107
    (0, _) => 8066
    (1, 0) => 11916
    (1, _) => 7490
    (2, 0) => 10082
    (2, _) => 6554
    (3, 0) => 9362
    (3, _) => 5825
    (4, 0) => 8192
    (4, _) => 5243
    (5, 0) => 7282
    (_, _) => 4559
  }
}

///|
/// Quantise one coefficient. The canonical pairing of the unshifted forward
/// transform with this decoder's dequant (`dequant4_init * 16 << (qp/6+2)`
/// and the `>> 6` IDCT scale, both verified in the calibration test) is
/// `(|c| * MF + half) >> (16 + qp/6 + extra_shift)`; `extra_shift` is 1 for
/// the Intra16x16 luma DC block (the `>> 8` Hadamard dequant scale).
fn h264_enc_quant_val(
  coef : Int,
  qp : Int,
  pos_class : Int,
  extra_shift~ : Int = 5,
) -> Int {
  // Pairing (derived against this decoder's dequant/IDCT and verified by
  // the reconstruction invariant test): 4x4 AC coefficients quantise at
  // shift 21 + qp/6, the Intra16x16 luma DC Hadamard block at 17 + qp/6
  // (extra_shift 1) and the chroma 2x2 DC block at 16 + qp/6 (extra 0).
  let rem = qp % 6
  let div = qp / 6
  let qbits = 16 + div + extra_shift
  let mf = h264_enc_mf(rem, pos_class)
  if coef == 0 {
    return 0
  }
  let mag = if coef < 0 { -coef } else { coef }
  ((mag * mf) + (1 << (qbits - 1))) >> qbits
}

///|
/// One 1-D stage of the canonical (shift-free) forward transform: the pure
/// integer butterfly whose inverse carries the `>> 1` steps. The DC gain is
/// exactly the 16-sample sum, which is the convention the quantisation
/// multiply factors are tuned against.
fn h264_enc_fdct1d(
  src : Array[Int],
  src_off : Int,
  dst : Array[Int],
  dst_off : Int,
  stride : Int,
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
  res : Array[Int],
  res_off : Int,
  qp : Int,
) -> Array[Int] {
  let tmp : Array[Int] = Array::make(16, 0)
  let col : Array[Int] = Array::make(16, 0)
  for row = 0; row < 4; row = row + 1 {
    h264_enc_fdct1d(res, res_off + row * 4, tmp, row * 4, 1)
  }
  for c = 0; c < 4; c = c + 1 {
    h264_enc_fdct1d(tmp, c, col, c, 4)
  }
  let levels : Array[Int] = Array::make(16, 0)
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
  src : Array[Int],
  src_off : Int,
  src_stride : Int,
  out : Array[Int],
  out_off : Int,
  qp : Int,
) -> Array[Int] {
  let tmp : Array[Int] = Array::make(16, 0)
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
  let levels : Array[Int] = Array::make(16, 0)
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
  src : Array[Int],
  out : Array[Int],
  out_off : Int,
  qp : Int,
) -> Array[Int] {
  let a = src[0]
  let b = src[1]
  let c = src[2]
  let d = src[3]
  let t : Array[Int] = [
    a + b + c + d,
    a + b - c - d,
    a - b - c + d,
    a - b + c - d,
  ]
  // The chroma DC block quantises with the luma-class-0 factor (the
  // decoder's chroma DC dequant uses `qmul = build_dequant4(...)[0]`).
  let levels : Array[Int] = Array::make(4, 0)
  for i = 0; i < 4; i = i + 1 {
    let level = h264_enc_quant_val(t[i], qp, 0, extra_shift=0)
    out[out_off + i] = level
    levels[i] = level
  }
  levels
}
