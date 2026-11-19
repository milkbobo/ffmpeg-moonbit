///|
/// Forward transform and quantisation for the HEVC encoder, slice 1
/// (intra, 4:2:0 8-bit, flat QP). The decoder's inverse pipeline is
/// normative ground truth (`hevc_transform.mbt`): the core inverse is the
/// fixed 6-bit basis matrix applied in correlation form twice with total
/// shift 7 + (20 - bd) = 19, i.e. `r = M^T * dq * M / 2^19` in matrix
/// product form (DST for 4x4 luma: `r = DST * dq * DST^T / 2^19`). The
/// forward here is its algebraic inverse up to the basis' column-norm
/// scale: `dq = 2^19 * (M^T)^-1 * r * M^-1 ~= (M * r * M^T) * SCALE >>
/// SHIFT` with one (SCALE, SHIFT) per size derived offline from the exact
/// uniform column norms (gain error < 1e-6; pinned by round-trip tests).
/// Dequantisation (`dq = (level * scale * 16 + add) >> shift`) then inverts
/// into `level ~= dq * 2^(bd + log2 - 9) / scale`, so quantisation is a
/// single divide against the decoder's own `hevc_level_scale` - whatever
/// levels are coded, the encoder's reconstruction runs the *decoder's*
/// dequant + idct + add kernels, so recon == decode holds by construction.

///|
/// Forward DCT-II normalisation: `dq = (M * r * M^T) * SCALE >> SHIFT`
/// per transform size (derived from the uniform column norms 16377 /
/// 32747 / 65520 / 131142 of the size-N basis submatrices). */
let hevc_enc_fdct_scale : FixedArray[Int32] = [524736, 131240, 32784, 8183]

///|
/// Companion shift for `hevc_enc_fdct_scale` (index = log2_size - 2). */
let hevc_enc_fdct_shift : FixedArray[Int32] = [28, 28, 28, 28]

///|
/// Forward DST-VII normalisation for 4x4 luma intra. The DST row norms are
/// not uniform (16398 x3, 16428 x1), so the scale folds per (row, col)
/// norm class of the residual index: class = (row == 1 ? 1 : 0) << 1 |
/// (col == 1 ? 1 : 0). `dq = (DST^T * r * DST) per-term * SCALE >> SHIFT`
/// - the per-term form multiplies each `DST[j][k] * DST[l][i] * r[j][l]`
/// accumulation term by the class constant of (j, l). */
let hevc_enc_fdst_scale : FixedArray[Int32] = [523393, 522437, 522437, 521483]

///|
/// Companion shift for `hevc_enc_fdst_scale`. */
let hevc_enc_fdst_shift : Int32 = 28

///|
/// The size-N HEVC core-transform basis: row `j` of the size-N matrix is
/// row `(j * 32) / N` of the 32-point `hevc_transform_matrix` (the C's
/// `row_stride = 32 / H` decimation), all N columns. */
fn hevc_enc_basis(n : Int32, j : Int32, k : Int32) -> Int32 {
  hevc_transform_matrix[j * (32 / n)][k]
}

///|
/// Forward DCT-II of an n x n residual block (row-major, `r[y * n + x]`),
/// returning dq-domain coefficients (what `hevc_idct` consumes). */
fn hevc_enc_fdct(r : FixedArray[Int32], n : Int32) -> FixedArray[Int32] {
  let log2 = match n {
    4 => 2
    8 => 3
    16 => 4
    _ => 5
  }
  let t : FixedArray[Int64] = FixedArray::make(n * n, 0L)
  let p : FixedArray[Int64] = FixedArray::make(n * n, 0L)
  // rows: t[y][i] = sum_x M[i][x] * r[y][x]  (= r * M^T)
  for y in 0..<n {
    for i in 0..<n {
      let mut acc = 0L
      for x in 0..<n {
        let v = r[y * n + x].to_int64()
        if v != 0L {
          acc = acc + hevc_enc_basis(n, i, x).to_int64() * v
        }
      }
      t[y * n + i] = acc
    }
  }
  // columns: p[k][i] = sum_y M[k][y] * t[y][i]  (= M * t)
  for k in 0..<n {
    for i in 0..<n {
      let mut acc = 0L
      for y in 0..<n {
        let v = t[y * n + i]
        if v != 0L {
          acc = acc + hevc_enc_basis(n, k, y).to_int64() * v
        }
      }
      p[k * n + i] = acc
    }
  }
  let scale = hevc_enc_fdct_scale[log2 - 2].to_int64()
  let shift = hevc_enc_fdct_shift[log2 - 2]
  let add : Int64 = 1L << (shift - 1)
  let out : FixedArray[Int32] = FixedArray::make(n * n, 0)
  for i in 0..<(n * n) {
    let v = (p[i] * scale + add) >> shift
    out[i] = hevc_clip_int16(v.to_int())
  }
  out
}

///|
/// Forward DST-VII of a 4x4 luma intra residual block (row-major), dq
/// domain (what `hevc_transform_4x4_luma` consumes). The DST butterfly
/// matrix rows: [29,74,84,55] / [55,74,-29,-84] / [74,0,-74,74] /
/// [84,-74,55,-29]. */
fn hevc_enc_fdst4(r : FixedArray[Int32]) -> FixedArray[Int32] {
  let dst : FixedArray[FixedArray[Int32]] = [
    [29, 74, 84, 55],
    [55, 74, -29, -84],
    [74, 0, -74, 74],
    [84, -74, 55, -29],
  ]
  // P[k][i] = sum_{j,l} DST[j][k] * r[j][l] * DST[l][i] with the (j,l)
  // norm-class constant folded into each accumulation term.
  let out : FixedArray[Int32] = FixedArray::make(16, 0)
  for k in 0..<4 {
    for i in 0..<4 {
      let mut acc = 0L
      for j in 0..<4 {
        for l in 0..<4 {
          let v = r[j * 4 + l].to_int64()
          if v != 0L {
            let cls = (if j == 1 { 1 } else { 0 }) * 2 +
              (if l == 1 { 1 } else { 0 })
            acc = acc +
              dst[j][k].to_int64() *
              v *
              dst[l][i].to_int64() *
              hevc_enc_fdst_scale[cls].to_int64()
          }
        }
      }
      let v = (acc + (1L << (hevc_enc_fdst_shift - 1))) >> hevc_enc_fdst_shift
      out[k * 4 + i] = hevc_clip_int16(v.to_int())
    }
  }
  out
}

///|
/// HEVC forward quantisation: invert the decoder's
/// `dq = (level * scale * 16 + add) >> shift` with
/// `shift = bd + log2 - 5`, `scale = hevc_level_scale[qp%6] << (qp/6)`:
/// `level = (|dq| * 2^(bd + log2 - 9) + rnd) / scale`, dead-zone-free
/// round-to-nearest, then clamped to the largest level the decoder's int16
/// dq clip cannot overflow. Returns the signed level. */
fn hevc_enc_quant_val(
  dq : Int32,
  qp : Int32,
  log2 : Int32,
  bd : Int32,
) -> Int32 {
  let mag = if dq < 0 { -dq } else { dq }
  if mag == 0 {
    return 0
  }
  let scale : Int64 = hevc_level_scale[qp % 6].to_int64() << (qp / 6)
  let num = mag.to_int64() << (bd + log2 - 9)
  let mut level = ((num + scale / 2) / scale).to_int()
  // Largest level keeping (level*scale*16) >> (bd+log2-5) within int16.
  let max_level = (32767L << (bd + log2 - 5)) / (16 * scale)
  if level.to_int64() > max_level {
    level = max_level.to_int()
  }
  if dq < 0 {
    -level
  } else {
    level
  }
}

///|
/// Chroma QP for the encoder: the decoder's own `hevc_chroma_qp` with the
/// PPS/slice chroma offsets at zero, so the 4:2:0 table, the 4:2:2/4:4:4 clip
/// to 51 and the `qp_bd_offset` term all follow the decoder exactly. The
/// returned value already includes `sps.qp_bd_offset`; callers must not add it
/// again. */
fn hevc_enc_chroma_qp(sps : HevcSps, qp_y : Int32) -> Int32 {
  hevc_chroma_qp(qp_y, 0, sps.qp_bd_offset, sps.chroma_format_idc)
}

///|
/// The QP the forward quantiser works with: the chroma mapping without the
/// `qp_bd_offset` term, which is exactly the value the dequantiser's scale
/// table is indexed by before the bit-depth shift is folded in. Kept separate
/// from `hevc_enc_chroma_qp` so the 10-bit reconstruction path keeps the
/// §455 relationship (forward on the public QP, inverse on QP + offset). */
fn hevc_enc_chroma_qp_fwd(sps : HevcSps, qp_y : Int32) -> Int32 {
  hevc_enc_chroma_qp(sps, qp_y) - sps.qp_bd_offset
}

///|
/// Quantise an n x n dq-domain block into signed levels. */
fn hevc_enc_quant_block(
  dq : FixedArray[Int32],
  n : Int32,
  qp : Int32,
  bd : Int32,
) -> FixedArray[Int32] {
  let log2 = match n {
    2 => 1
    4 => 2
    8 => 3
    16 => 4
    _ => 5
  }
  let out : FixedArray[Int32] = FixedArray::make(n * n, 0)
  for i in 0..<(n * n) {
    out[i] = hevc_enc_quant_val(dq[i], qp, log2, bd)
  }
  out
}

///|
/// Dequantise levels exactly like the decoder's main path
/// (`dq = (level * scale * scale_m(=16) + add) >> shift`, int16 clip) and
/// run the decoder's inverse transform for the encoder's local
/// reconstruction. The transform branch mirrors `hevc_decode_residual`'s
/// selection: `is_dst4` (4x4 luma intra) takes the DST; otherwise
/// `max_xy == 0` takes the DC-only path; anything else the full IDCT with
/// the decoder's `col_limit = last_x + last_y + 4` tiering. Returns the
/// reconstructed residual block. */
fn hevc_enc_recon_transform(
  levels : FixedArray[Int32],
  n : Int32,
  qp : Int32,
  bd : Int32,
  is_dst4 : Bool,
  last_x : Int32,
  last_y : Int32,
) -> FixedArray[Int32] {
  let log2 = match n {
    2 => 1
    4 => 2
    8 => 3
    16 => 4
    _ => 5
  }
  let shift = bd + log2 - 5
  let add = 1 << (shift - 1)
  let scale = hevc_level_scale[qp % 6] << (qp / 6)
  let coeffs : Array[Int32] = Array::make(n * n, 0)
  for i in 0..<(n * n) {
    let mut dq = (
        levels[i].to_int64() * scale.to_int64() * 16L + add.to_int64()
      ) >>
      shift
    if dq < -32768L {
      dq = -32768L
    } else if dq > 32767L {
      dq = 32767L
    }
    coeffs[i] = dq.to_int()
  }
  if is_dst4 {
    hevc_transform_4x4_luma(coeffs, bd)
  } else if last_x == 0 && last_y == 0 {
    match hevc_idct_dc(coeffs, log2, bd) {
      Ok(_) => ()
      Err(_) => ()
    }
  } else {
    let max_xy = if last_x > last_y { last_x } else { last_y }
    let mut col_limit = last_x + last_y + 4
    if max_xy < 4 {
      col_limit = if col_limit < 4 { col_limit } else { 4 }
    } else if max_xy < 8 {
      col_limit = if col_limit < 8 { col_limit } else { 8 }
    } else if max_xy < 12 {
      col_limit = if col_limit < 24 { col_limit } else { 24 }
    }
    match hevc_idct(coeffs, log2, col_limit, bd) {
      Ok(_) => ()
      Err(_) => ()
    }
  }
  let out : FixedArray[Int32] = FixedArray::make(n * n, 0)
  for i in 0..<(n * n) {
    out[i] = coeffs[i]
  }
  out
}
