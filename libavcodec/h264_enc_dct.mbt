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
/// The JVT forward-quant multiply factors (`quant_mf`, Table 7-5 family):
/// `level = (|W| * MF[qp%6][class] + 2^(qbits-1)) >> qbits` with
/// `qbits = 15 + qp/6` and `W` the unnormalised H.264 core-transform
/// coefficient (the shift-free butterflies below). `class` is the position
/// class `(p&1) + ((p>>2)&1)` (even-even / mixed / odd-odd). These are the
/// standard tables (verified against x264 `common/set.c`'s
/// `quant4_scale` value-for-value) - NOT round(2^17/dequant_init): the
/// mixed/odd classes carry the odd-row norm corrections (MF*init is
/// 2^17 x {1, 0.8, 0.64} by class), which that round-trip misses.
let h264_enc_mf : FixedArray[FixedArray[Int32]] = [
  [13107, 8066, 5243],
  [11916, 7496, 4664],
  [10082, 6554, 4194],
  [9362, 5496, 3547],
  [8192, 4906, 3161],
  [7282, 4352, 2804],
]

///|
/// Quantise one coefficient (Int64 intermediate: a full-scale luma DC
/// Hadamard coefficient times the largest factor overflows Int32). */
fn h264_enc_quant_val(
  coef : Int32,
  qp : Int32,
  pos_class : Int32,
  extra_shift~ : Int32 = 0,
) -> Int32 {
  let rem = qp % 6
  let div = qp / 6
  let qbits = 15 + div + extra_shift
  let mf = h264_enc_mf[rem][pos_class]
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
/// One 1-D stage of the H.264 integer core transform (shift-free, the
/// transform `Cf X Cf^T` every encoder pairs with `ff_h264_idct_add`):
/// even outputs are the plain butterflies, odd outputs carry the factor-2
/// terms (`2*(x0-x3) + (x1-x2)` / `(x0-x3) - 2*(x1-x2)`), the transpose
/// of the IDCT's `>> 1` steps. NOT a Hadamard - the factor 2 is what makes
/// this the exact (unnormalised) inverse of the decoder's transform.
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
  dst[dst_off + stride] = 2 * d03 + d12
  dst[dst_off + 2 * stride] = s03 - s12
  dst[dst_off + 3 * stride] = d03 - 2 * d12
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
    let level = h264_enc_quant_val(tmp[p], qp, cls, extra_shift=2)
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
    let level = h264_enc_quant_val(t[i], qp, 0, extra_shift=1)
    out[out_off + i] = level
    levels[i] = level
  }
  levels
}

///|
/// Forward-quant multiply factors for the 8x8 transform (`[rem][spec pos]`):
/// the standard `quant8_scale` class table (verified against x264
/// `common/set.c` value-for-value) applied through the same
/// `((x>>1)&12)|(x&3)` scan mapping as the dequant table, with
/// `qbits = 16 + qp/6` (x264's `quant_8x8`). The per-class products with
/// `dequant8_scale` are 2^18 x {1, 0.8859^2, 1.6^2, 0.8859, 1.6, 1.6*.8859}
/// - the 8x8 basis-norm corrections; a plain `round(2^19/init8)` misses
/// them (it is right only for DC) and skews every AC class by up to 2.6x.
/// Each row is its OWN array: `FixedArray::make(6, row)` would alias one
/// row six times and every `qp % 6` would silently quantise with the last
/// remainder's factors (the §385 defect this replaces).
let h264_enc_mf8 : Array[Array[Int32]] = {
  let scale : FixedArray[FixedArray[Int32]] = [
    [13107, 11428, 20972, 12222, 16777, 15481],
    [11916, 10826, 19174, 11058, 14980, 14290],
    [10082, 8943, 15978, 9675, 12710, 11985],
    [9362, 8228, 14913, 8931, 11984, 11259],
    [8192, 7346, 13159, 7740, 10486, 9777],
    [7282, 6428, 11570, 6830, 9118, 8640],
  ]
  let t : Array[Array[Int32]] = []
  for rem = 0; rem < 6; rem = rem + 1 {
    let row : Array[Int32] = Array::make(64, 0)
    for x = 0; x < 64; x = x + 1 {
      let cls = h264_dequant8_init_scan[((x >> 1) & 12) | (x & 3)]
      row[x] = scale[rem][cls]
    }
    t.push(row)
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
  let qbits = 16 + div
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

///|
/// The shared High-profile I8x8 luma pass of the CAVLC and CABAC intra
/// encoders: per 8x8 block (z-order 0..3), pick the best availability-checked
/// `pred8x8l` mode by SAD, predict, forward-transform + quantise, dequantise
/// into `mb` and reconstruct through `h264_idct8_add`. The 0..3 block order
/// mirrors the decoder's reconstruction, so each block predicts from exactly
/// the neighbours the decoder will use. Fills `store` (4 x 64 transposed
/// levels) and the raw signalled modes into `modes` (2x2 replication, the
/// decoder's fill); returns `(cost, cbp)` with the summed PREDICTION SAD of
/// the four winning modes (the same metric the I4x4/I16x16 decisions use -
/// a post-quantisation SAD would not be comparable to them) and one cbp bit
/// per non-empty block.
///
/// `avail(bx8, by8)` provides the reconstruction-side availability of one
/// 8x8 block as `(top, left, topright, topleft)` - `h264_recon_full_plane`'s
/// I8x8-branch semantics. The CABAC encoder derives it from its decoder
/// mirror; the CAVLC intra encoder (single slice, no constrained intra
/// prediction) uses the geometric form.
fn h264_enc_luma_i8_pass(
  src_y : Array[Int32],
  rec_y : Array[Int32],
  ystride : Int32,
  mb_x : Int32,
  mb_y : Int32,
  pps : H264Pps,
  qp : Int32,
  store : Array[Int32],
  modes : Array[Int32],
  mb : Array[Int32],
  avail : (Int32, Int32) -> (Bool, Bool, Bool, Bool),
  fixed_modes~ : Array[Int32] = [],
) -> Result[(Int32, Int32), String] {
  let qmul8 = h264_build_dequant8(pps, 0, qp)
  let ybase = mb_y * 16 * ystride + mb_x * 16
  let mut cost = 0
  let mut cbp = 0
  for i8 = 0; i8 < 4; i8 = i8 + 1 {
    let bx8 = i8 % 2
    let by8 = i8 / 2
    let off = ybase + by8 * 8 * ystride + bx8 * 8
    let (top, left, topright, topleft) = avail(bx8, by8)
    let replay = fixed_modes.length() == 4
    let mut best_sig = 0
    let mut best_eff : Int32 = -1
    let mut best_sad = -1
    if replay {
      // Re-predict with the plan's signalled modes (the availability check
      // redoes the raw -> effective mapping exactly like the search did).
      best_sig = fixed_modes[i8]
      best_eff = match h264_check_intra4x4_mode(best_sig, top, left) {
        Ok(v) => v
        Err(_) => -1
      }
      if best_eff < 0 {
        return Err("h264 enc: replayed intra8x8 mode infeasible")
      }
      best_sad = 0 // unused
    } else {
      for sig = 0; sig < 9; sig = sig + 1 {
        let eff = match h264_check_intra4x4_mode(sig, top, left) {
          Ok(v) => v
          Err(_) => -1
        }
        if eff < 0 {
          continue
        }
        if h264_pred8x8l(
            rec_y,
            off,
            ystride,
            eff,
            top,
            left,
            topright,
            topleft~,
            bit_depth=8,
          )
          is Err(_) {
          continue
        }
        let sad = h264_enc_sad8(src_y, rec_y, off, ystride)
        if best_sad < 0 || sad < best_sad {
          best_sad = sad
          best_sig = sig
          best_eff = eff
        }
      }
    }
    if best_eff < 0 {
      return Err("h264 enc: no feasible intra8x8 mode")
    }
    match
      h264_pred8x8l(
        rec_y,
        off,
        ystride,
        best_eff,
        top,
        left,
        topright,
        topleft~,
        bit_depth=8,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    // Decision metric: the winning mode's prediction SAD (the plane holds
    // the bare prediction right here, before any residual is added).
    cost = cost + h264_enc_sad8(src_y, rec_y, off, ystride)
    for dy = 0; dy < 2; dy = dy + 1 {
      for dx = 0; dx < 2; dx = dx + 1 {
        modes[(by8 * 2 + dy) * 4 + bx8 * 2 + dx] = best_sig
      }
    }
    let res : Array[Int32] = Array::make(64, 0)
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        res[row * 8 + col] = src_y[off + row * ystride + col] -
          rec_y[off + row * ystride + col]
      }
    }
    let levels = h264_enc_fdct8_quant_res(res, 0, qp)
    let mut total = 0
    for s = 0; s < 64; s = s + 1 {
      store[64 * i8 + s] = levels[s]
      if levels[s] != 0 {
        total = total + 1
        mb[64 * i8 + s] = h264_enc_dequant_level(levels[s], qmul8[s])
      }
    }
    if total != 0 {
      cbp = cbp | (1 << i8)
      // `h264_idct8_add4`'s nz shortcut: a lone DC level takes the flat
      // DC add, anything else the full inverse transform.
      if total == 1 && mb[64 * i8] != 0 {
        h264_idct8_dc_add(rec_y, off, ystride, mb, 64 * i8, bit_depth=8)
      } else {
        h264_idct8_add(rec_y, off, ystride, mb, 64 * i8, bit_depth=8)
      }
    }
  }
  Ok((cost, cbp))
}

///|
/// The shared I4x4 luma pass of the P-slice intra encoder: per 4x4 block
/// (z-order 0..15), pick the best availability-checked `pred4x4` mode by
/// SAD, predict, forward-transform + quantise, dequantise into `mb` and
/// reconstruct through `h264_idct_add`. The block order mirrors the
/// decoder's reconstruction, so each block predicts from exactly the
/// neighbours the decoder will use. Fills `store` (16 x 16 levels) and the
/// signalled modes into `modes` (one cell per 4x4 grid position); returns
/// `(cost, cbp)` with the summed PREDICTION SAD of the winning modes and one
/// cbp bit per non-empty quadrant. `fixed_modes` (16 grid-indexed modes)
/// replays a decided plan instead of searching.
fn h264_enc_luma_i4_pass(
  src_y : Array[Int32],
  rec_y : Array[Int32],
  ystride : Int32,
  mb_x : Int32,
  mb_y : Int32,
  pps : H264Pps,
  qp : Int32,
  store : Array[Int32],
  modes : Array[Int32],
  mb : Array[Int32],
  avail : (Int32, Int32) -> (Bool, Bool, Bool),
  fixed_modes~ : Array[Int32] = [],
) -> Result[(Int32, Int32), String] {
  let qmul_y = h264_build_dequant4(pps, 0, qp)
  let ybase = mb_y * 16 * ystride + mb_x * 16
  let mut cost = 0
  let mut cbp = 0
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * ystride + gx * 4
    let (top, left, topright) = avail(gx, gy)
    let replay = fixed_modes.length() == 16
    let mut best_sig = 0
    let mut best_eff : Int32 = -1
    let mut best_sad = -1
    if replay {
      best_sig = fixed_modes[g]
      best_eff = match h264_check_intra4x4_mode(best_sig, top, left) {
        Ok(v) => v
        Err(_) => -1
      }
      if best_eff < 0 {
        return Err("h264 enc: replayed intra4x4 mode infeasible")
      }
      best_sad = 0 // unused
    } else {
      for sig = 0; sig < 9; sig = sig + 1 {
        let eff = match h264_check_intra4x4_mode(sig, top, left) {
          Ok(v) => v
          Err(_) => -1
        }
        if eff < 0 {
          continue
        }
        if h264_pred4x4(
            rec_y,
            off,
            ystride,
            eff,
            top,
            left,
            topright,
            bit_depth=8,
          )
          is Err(_) {
          continue
        }
        let sad = h264_enc_sad4(src_y, rec_y, off, ystride)
        if best_sad < 0 || sad < best_sad {
          best_sad = sad
          best_sig = sig
          best_eff = eff
        }
      }
    }
    if best_eff < 0 {
      return Err("h264 enc: no feasible intra4x4 mode")
    }
    match
      h264_pred4x4(
        rec_y,
        off,
        ystride,
        best_eff,
        top,
        left,
        topright,
        bit_depth=8,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    cost = cost + h264_enc_sad4(src_y, rec_y, off, ystride)
    modes[g] = best_sig
    let res : Array[Int32] = Array::make(16, 0)
    for row = 0; row < 4; row = row + 1 {
      for col = 0; col < 4; col = col + 1 {
        res[row * 4 + col] = src_y[off + row * ystride + col] -
          rec_y[off + row * ystride + col]
      }
    }
    let levels = h264_enc_fdct_quant_res(res, 0, qp)
    let mut total = 0
    for s = 0; s < 16; s = s + 1 {
      store[16 * i + s] = levels[s]
      if levels[s] != 0 {
        total = total + 1
        mb[16 * i + s] = h264_enc_dequant_level(levels[s], qmul_y[s])
      }
    }
    if total != 0 {
      cbp = cbp | (1 << (i / 4))
      if total == 1 && mb[16 * i] != 0 {
        h264_idct_dc_add(rec_y, off, ystride, mb, 16 * i, bit_depth=8)
      } else {
        h264_idct_add(rec_y, off, ystride, mb, 16 * i, bit_depth=8)
      }
    }
  }
  Ok((cost, cbp))
}

///|
/// Geometric I4x4 availability for a single-slice picture (no constrained
/// intra prediction): the 4x4 form of `h264_enc_i8_avail`, matching the
/// intra encoder's per-block top/left/topright derivation.
fn h264_enc_i4_avail(
  mb_x : Int32,
  mb_y : Int32,
  mb_width : Int32,
) -> (Int32, Int32) -> (Bool, Bool, Bool) {
  fn(gx : Int32, gy : Int32) -> (Bool, Bool, Bool) {
    let top = gy > 0 || mb_y > 0
    let left = gx > 0 || mb_x > 0
    let topright = if gy == 0 {
      top && (gx < 3 || mb_x < mb_width - 1)
    } else {
      gx == 0 || gx == 2 || (gx == 1 && gy % 2 == 0)
    }
    (top, left, topright)
  }
}

///|
/// Geometric availability for a single-slice all-intra picture (the CAVLC
/// intra encoder): every macroblock decoded before this one in raster order
/// is an intra neighbour, so availability reduces to frame geometry.
fn h264_enc_i8_avail(
  mb_x : Int32,
  mb_y : Int32,
  mb_width : Int32,
) -> (Int32, Int32) -> (Bool, Bool, Bool, Bool) {
  fn(bx8 : Int32, by8 : Int32) -> (Bool, Bool, Bool, Bool) {
    let top = by8 > 0 || mb_y > 0
    let left = bx8 > 0 || mb_x > 0
    // The topright samples of a top-row block sit above the MB's own
    // right half for bx8 = 0 and above the top-right MB for bx8 = 1;
    // an inner-row block sees its same-MB left neighbour.
    let topright = if by8 == 0 {
      top && (bx8 == 0 || mb_x < mb_width - 1)
    } else {
      bx8 == 0
    }
    // `h264_intra_topleft`'s geometric form: same-MB / top MB / left MB /
    // top-left MB corner samples.
    let topleft = if bx8 > 0 {
      by8 > 0 || mb_y > 0
    } else if by8 > 0 {
      mb_x > 0
    } else {
      mb_x > 0 && mb_y > 0
    }
    (top, left, topright, topleft)
  }
}

///|
/// The `sub`-th interleaved CAVLC coefficient list of 8x8DCT quadrant `q`:
/// list element k is the transposed-8x8 zigzag position `4*k + sub` of the
/// quadrant's 64 levels (`zigzag_scan8x8_cavlc` - the lists share one
/// global zigzag order, unlike CABAC's four independent block scans).
fn h264_cavlc8_sub_view(
  store : Array[Int32],
  q : Int32,
  sub : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(16, 0)
  for k = 0; k < 16; k = k + 1 {
    out[k] = store[64 * q + h264_zigzag_scan8x8[4 * k + sub]]
  }
  out
}
