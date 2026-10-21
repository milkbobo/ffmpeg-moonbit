///|
/// MoonBit port of the H.264 CABAC macroblock layer from FFmpeg 9.0.2
/// `libavcodec/h264_cabac.c`: `decode_cabac_intra_mb_type`,
/// `decode_cabac_mb_intra4x4_pred_mode`, `decode_cabac_mb_chroma_pre_mode`,
/// `decode_cabac_mb_cbp_luma`, `decode_cabac_mb_cbp_chroma`,
/// `get_cabac_cbf_ctx`, `decode_cabac_residual_internal` and
/// `ff_h264_decode_mb_cabac` (intra path).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2003
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Scope: 8-bit 4:2:0 progressive I slices, single slice per picture, one
/// reference frame list. Explicitly rejected (Err, never a panic): I_PCM in a
/// CABAC slice, 8x8DCT, field/MBAFF coding, 4:2:2/4:4:4 and high bit depth.
///
/// Neighbour bookkeeping: the C keeps `left_type`/`top_type`/`left_cbp`/
/// `top_cbp` in `H264SliceContext` plus an `non_zero_count_cache` with a
/// one-cell border. This port stores the same information per macroblock in
/// `H264MbInfo` (`mb_type_bits`, `cbp_all`, `nz`) and derives the CABAC
/// contexts directly from it; `h264_cabac_*_cbp` reproduce
/// `fill_decode_caches()`'s `left_cbp`/`top_cbp` packing, including the
/// `0x7CF` "unavailable neighbour inside an intra slice" defaults.
///
/// `nz` layout note: FFmpeg's `non_zero_count[mb]` is raster ordered (luma
/// `y*4+x`, then 2x2 chroma), which is exactly the layout the CAVLC port uses,
/// so the same array serves both entropy decoders. CABAC block indices are
/// z-ordered, so the residual writer maps them with `h264_luma_block_grid`.

///|
/// `MB_TYPE_INTRA4x4`. */
let h264_mb_type_intra4x4 : Int32 = 0x0001

///|
/// `MB_TYPE_INTRA16x16`. */
let h264_mb_type_intra16x16 : Int32 = 0x0002

///|
/// `MB_TYPE_INTRA_PCM`. */
let h264_mb_type_intra_pcm : Int32 = 0x0004

///|
/// `ff_h264_i_mb_type_info[i].pred_mode` (`h264data.c`). */
let h264_i_mb_type_pred : Array[Int32] = [
  0, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 0, 3, 0,
]

///|
/// `ff_h264_i_mb_type_info[i].cbp`. */
let h264_i_mb_type_cbp : Array[Int32] = [
  0, 0, 0, 0, 0, 16, 16, 16, 16, 32, 32, 32, 32, 15, 15, 15, 15, 31, 31, 31, 31,
  47, 47, 47, 47, 0,
]

///|
/// `base_ctx[14]` of `get_cabac_cbf_ctx`. */
let h264_cabac_cbf_base_ctx : Array[Int32] = [
  85, 89, 93, 97, 101, 1012, 460, 464, 468, 1016, 472, 476, 480, 1020,
]

///|
/// `significant_coeff_flag_offset[0][14]` (MB_FIELD == 0). */
let h264_cabac_significant_coeff_offset : Array[Int32] = [
  105 + 0,
  105 + 15,
  105 + 29,
  105 + 44,
  105 + 47,
  402,
  484 + 0,
  484 + 15,
  484 + 29,
  660,
  528 + 0,
  528 + 15,
  528 + 29,
  718,
]

///|
/// `last_coeff_flag_offset[0][14]` (MB_FIELD == 0). */
let h264_cabac_last_coeff_flag_offset : Array[Int32] = [
  166 + 0,
  166 + 15,
  166 + 29,
  166 + 44,
  166 + 47,
  417,
  572 + 0,
  572 + 15,
  572 + 29,
  690,
  616 + 0,
  616 + 15,
  616 + 29,
  748,
]

///|
/// `coeff_abs_level_m1_offset[14]`. */
let h264_cabac_coeff_abs_level_m1_offset : Array[Int32] = [
  227 + 0,
  227 + 10,
  227 + 20,
  227 + 30,
  227 + 39,
  426,
  952 + 0,
  952 + 10,
  952 + 20,
  708,
  982 + 0,
  982 + 10,
  982 + 20,
  766,
]

///|
/// `coeff_abs_level1_ctx[8]`. */
let h264_cabac_coeff_abs_level1_ctx : Array[Int32] = [1, 2, 3, 4, 0, 0, 0, 0]

///|
/// `coeff_abs_levelgt1_ctx[0][8]` (non 4:2:2). */
let h264_cabac_coeff_abs_levelgt1_ctx : Array[Int32] = [5, 5, 5, 5, 6, 7, 8, 9]

///|
/// `coeff_abs_level_transition[2][8]`. */
let h264_cabac_coeff_abs_level_transition : Array[Array[Int32]] = [
  [1, 2, 3, 3, 4, 5, 6, 7],
  [4, 4, 4, 4, 5, 6, 7, 7],
]

///|
/// `get_cabac_cbf_ctx`: coded-block-flag context. `cat` is the C's residual
/// category (0 luma DC, 1 luma AC in I16x16, 2 luma 4x4, 3 chroma DC,
/// 4 chroma AC) and `n` the block index in the C's numbering
/// (luma 0..15 z-order, chroma 16 + 16*c + i, DC 48 + p / 49 + c).
fn h264_cabac_cbf_ctx(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  cat : Int32,
  n : Int32,
  nz : Array[Int32],
) -> Int32 {
  let mut nza = 0
  let mut nzb = 0
  let left_cbp = h264_cabac_left_cbp(ctx, mb_idx, mb_x)
  let top_cbp = h264_cabac_top_cbp(ctx, mb_idx, mb_y)
  if cat == 0 {
    // Luma DC: `n - LUMA_DC_BLOCK_INDEX` is 0 for 4:2:0 (single plane).
    nza = left_cbp & 0x100
    nzb = top_cbp & 0x100
  } else if cat == 3 {
    let idx = n - 49 // CHROMA_DC_BLOCK_INDEX
    nza = (left_cbp >> (6 + idx)) & 0x01
    nzb = (top_cbp >> (6 + idx)) & 0x01
  } else {
    let is_luma = cat == 1 || cat == 2
    let w = if is_luma { 4 } else { 2 }
    let r = if is_luma { h264_luma_block_grid[n & 15] } else { (n - 16) & 15 }
    let base = if is_luma { 0 } else { 16 + 16 * ((n - 16) / 16) }
    let x = r % w
    let y = r / w
    nza = if x > 0 {
      nz[base + r - 1]
    } else if mb_x > 0 {
      ctx.infos[mb_idx - 1].nz[base + y * w + (w - 1)]
    } else if ctx.cur_mb_is_intra {
      64
    } else {
      0
    }
    // The top neighbour of a first-row block is the macroblock above's bottom
    // row: luma `nz[3*4 + x]`, chroma `nz[1*2 + x]`.
    nzb = if y > 0 {
      nz[base + r - w]
    } else if mb_y > 0 {
      ctx.infos[mb_idx - ctx.mb_width].nz[base + (w - 1) * w + x]
    } else if ctx.cur_mb_is_intra {
      64
    } else {
      0
    }
  }
  let mut c = 0
  if nza > 0 {
    c = c + 1
  }
  if nzb > 0 {
    c = c + 2
  }
  h264_cabac_cbf_base_ctx[cat] + c
}

///|
/// `fill_decode_caches()`'s `left_cbp`: `cbp_table[left] & 0x7F0` keeps the
/// chroma/DC flags, `left_block[0] & ~1 == 0` contributes the luma bit of the
/// top-left 8x8 and `left_block[2] & ~1 == 2` the bottom-left one shifted into
/// bit 3.
fn h264_cabac_left_cbp(ctx : H264DecCtx, mb_idx : Int32, mb_x : Int32) -> Int32 {
  if mb_x > 0 {
    let l = ctx.infos[mb_idx - 1].cbp_all
    (l & 0x7F0) | ((l >> 0) & 2) | (((l >> 2) & 2) << 2)
    // Unavailable neighbour: `IS_INTRA(cur mb_type) ? 0x7CF : 0x00F`.
  } else if ctx.cur_mb_is_intra {
    0x7CF
  } else {
    0x00F
  }
}

///|
/// `fill_decode_caches()`'s `top_cbp`. */
fn h264_cabac_top_cbp(ctx : H264DecCtx, mb_idx : Int32, mb_y : Int32) -> Int32 {
  if mb_y > 0 {
    ctx.infos[mb_idx - ctx.mb_width].cbp_all
  } else if ctx.cur_mb_is_intra {
    0x7CF
  } else {
    0x00F
  }
}

///|
/// `decode_cabac_intra_mb_type`; `ctx_base` is 3 for I slices and 17 for the
/// intra branch of a P slice, `intra_slice` is 1 for I slices. */
fn h264_cabac_intra_mb_type(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  ctx_base : Int32,
  intra_slice : Int32,
) -> Int32 {
  let left_type = h264_cabac_left_type(ctx, mb_idx, mb_x)
  let top_type = h264_cabac_top_type(ctx, mb_idx, mb_y)
  let mut state = ctx_base
  if intra_slice != 0 {
    let mut c = 0
    if (left_type & (h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)) != 0 {
      c = c + 1
    }
    if (top_type & (h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)) != 0 {
      c = c + 1
    }
    if cabac.get_cabac(states, state + c) == 0 {
      return 0
    }
    state = state + 2
  } else if cabac.get_cabac(states, state) == 0 {
    return 0
  }
  if cabac.get_cabac_terminate() != 0 {
    return 25
  }
  let b0 = cabac.get_cabac(states, state + 1)
  let b1 = cabac.get_cabac(states, state + 2)
  let mut b2 = 0
  if b1 != 0 {
    b2 = cabac.get_cabac(states, state + 2 + intra_slice)
  }
  let b3 = cabac.get_cabac(states, state + 3 + intra_slice)
  let b4 = cabac.get_cabac(states, state + 3 + 2 * intra_slice)
  let mut mb_type = 1
  mb_type = mb_type + 12 * b0
  if b1 != 0 {
    mb_type = mb_type + 4 + 4 * b2
  }
  mb_type = mb_type + 2 * b3
  mb_type = mb_type + b4
  mb_type
}

///|
/// `sl->left_type[LTOP]`: `0` when unavailable. */
fn h264_cabac_left_type(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
) -> Int32 {
  if mb_x > 0 {
    ctx.infos[mb_idx - 1].mb_type_bits
  } else {
    0
  }
}

///|
/// `sl->top_type`. */
fn h264_cabac_top_type(ctx : H264DecCtx, mb_idx : Int32, mb_y : Int32) -> Int32 {
  if mb_y > 0 {
    ctx.infos[mb_idx - ctx.mb_width].mb_type_bits
  } else {
    0
  }
}

///|
/// `decode_cabac_mb_intra4x4_pred_mode`. */
fn h264_cabac_intra4x4_pred_mode(
  cabac : CabacContext,
  states : Array[Int32],
  pred_mode : Int32,
) -> Int32 {
  if cabac.get_cabac(states, 68) != 0 {
    return pred_mode
  }
  let mut mode = 0
  mode = mode + cabac.get_cabac(states, 69)
  mode = mode + 2 * cabac.get_cabac(states, 69)
  mode = mode + 4 * cabac.get_cabac(states, 69)
  if mode >= pred_mode {
    mode + 1
  } else {
    mode
  }
}

///|
/// `decode_cabac_mb_chroma_pre_mode`. */
fn h264_cabac_chroma_pre_mode(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let left_type = h264_cabac_left_type(ctx, mb_idx, mb_x)
  let top_type = h264_cabac_top_type(ctx, mb_idx, mb_y)
  let mut c = 0
  if left_type != 0 && ctx.infos[mb_idx - 1].chroma_mode != 0 {
    c = c + 1
  }
  if top_type != 0 && ctx.infos[mb_idx - ctx.mb_width].chroma_mode != 0 {
    c = c + 1
  }
  if cabac.get_cabac(states, 64 + c) == 0 {
    return 0
  }
  if cabac.get_cabac(states, 64 + 3) == 0 {
    return 1
  }
  if cabac.get_cabac(states, 64 + 3) == 0 {
    return 2
  }
  3
}

///|
/// `decode_cabac_mb_cbp_luma`. */
fn h264_cabac_mb_cbp_luma(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let cbp_a = h264_cabac_left_cbp(ctx, mb_idx, mb_x)
  let cbp_b = h264_cabac_top_cbp(ctx, mb_idx, mb_y)
  let mut cbp = 0
  let mut c = 0
  if (cbp_a & 0x02) == 0 {
    c = c + 1
  }
  if (cbp_b & 0x04) == 0 {
    c = c + 2
  }
  cbp = cbp + cabac.get_cabac(states, 73 + c)
  c = 0
  if (cbp & 0x01) == 0 {
    c = c + 1
  }
  if (cbp_b & 0x08) == 0 {
    c = c + 2
  }
  cbp = cbp + (cabac.get_cabac(states, 73 + c) << 1)
  c = 0
  if (cbp_a & 0x08) == 0 {
    c = c + 1
  }
  if (cbp & 0x01) == 0 {
    c = c + 2
  }
  cbp = cbp + (cabac.get_cabac(states, 73 + c) << 2)
  c = 0
  if (cbp & 0x04) == 0 {
    c = c + 1
  }
  if (cbp & 0x02) == 0 {
    c = c + 2
  }
  cbp = cbp + (cabac.get_cabac(states, 73 + c) << 3)
  cbp
}

///|
/// `decode_cabac_mb_cbp_chroma`. */
fn h264_cabac_mb_cbp_chroma(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let cbp_a = (h264_cabac_left_cbp(ctx, mb_idx, mb_x) >> 4) & 0x03
  let cbp_b = (h264_cabac_top_cbp(ctx, mb_idx, mb_y) >> 4) & 0x03
  let mut c = 0
  if cbp_a > 0 {
    c = c + 1
  }
  if cbp_b > 0 {
    c = c + 2
  }
  if cabac.get_cabac(states, 77 + c) == 0 {
    return 0
  }
  let mut c2 = 4
  if cbp_a == 2 {
    c2 = c2 + 1
  }
  if cbp_b == 2 {
    c2 = c2 + 2
  }
  1 + cabac.get_cabac(states, 77 + c2)
}

///|
/// `decode_cabac_residual_internal`: significance map, then levels in reverse
/// scan order, writing dequantised coefficients into `block[base + pos]`.
///
/// `scan` is the (transposed) zigzag table and `scan_start` mirrors the C's
/// `scantable` pointer offset (0 for DC/4x4 blocks, 1 for AC-only blocks).
/// `qmul` is `None` for the DC blocks, whose levels stay un-scaled and are
/// dequantised by the DC Hadamard afterwards.
fn h264_cabac_residual(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  block : Array[Int32],
  base : Int32,
  cat : Int32,
  n : Int32,
  nz : Array[Int32],
  scan : Array[Int32],
  scan_start : Int32,
  qmul : Array[Int32]?,
  max_coeff : Int32,
  is_dc : Bool,
) -> Result[Int32, String] {
  let cbf_ctx = h264_cabac_cbf_ctx(ctx, mb_idx, mb_x, mb_y, cat, n, nz)
  if cabac.get_cabac(states, cbf_ctx) == 0 {
    // Coded block flag is zero: no coefficients. Keep the neighbour arrays in
    // sync (`sl->non_zero_count_cache[...] = 0`).
    if !is_dc {
      if cat == 1 || cat == 2 {
        let r = h264_luma_block_grid[n & 15]
        nz[r] = 0
      } else {
        nz[n] = 0
      }
    }
    return Ok(0)
  }
  let sig_base = h264_cabac_significant_coeff_offset[cat]
  let last_base = h264_cabac_last_coeff_flag_offset[cat]
  let abs_base = h264_cabac_coeff_abs_level_m1_offset[cat]
  let index : Array[Int32] = Array::make(64, 0)
  let mut coeff_count = 0
  let mut node_ctx = 0
  // DECODE_SIGNIFICANCE(max_coeff - 1, last, last)
  let coefs = max_coeff - 1
  let mut last = 0
  while last < coefs {
    if cabac.get_cabac(states, sig_base + last) != 0 {
      index[coeff_count] = last
      coeff_count = coeff_count + 1
      if cabac.get_cabac(states, last_base + last) != 0 {
        last = max_coeff
        break
      }
    }
    last = last + 1
  }
  if last == max_coeff - 1 {
    index[coeff_count] = last
    coeff_count = coeff_count + 1
  }
  if coeff_count <= 0 {
    return Err("EINVAL")
  }
  // Record the non-zero count in the neighbour arrays.
  if is_dc {
    if cat == 3 {
      ctx.infos[mb_idx].cbp_all = ctx.infos[mb_idx].cbp_all | (0x40 << (n - 49))
    } else {
      ctx.infos[mb_idx].cbp_all = ctx.infos[mb_idx].cbp_all |
        (0x100 << (n - 48))
    }
  } else if cat == 1 || cat == 2 {
    nz[h264_luma_block_grid[n & 15]] = coeff_count
  } else {
    nz[n] = coeff_count
  }
  let mut cc = coeff_count
  while cc > 0 {
    cc = cc - 1
    let j = scan[scan_start + index[cc]]
    let ctx1 = abs_base + h264_cabac_coeff_abs_level1_ctx[node_ctx]
    if cabac.get_cabac(states, ctx1) == 0 {
      node_ctx = h264_cabac_coeff_abs_level_transition[0][node_ctx]
      block[base + j] = match qmul {
        None => cabac.get_cabac_bypass_sign(-1)
        Some(q) => (cabac.get_cabac_bypass_sign(-q[j]) + 32) >> 6
      }
    } else {
      let mut coeff_abs = 2
      let ctx2 = abs_base + h264_cabac_coeff_abs_levelgt1_ctx[node_ctx]
      node_ctx = h264_cabac_coeff_abs_level_transition[1][node_ctx]
      while coeff_abs < 15 && cabac.get_cabac(states, ctx2) != 0 {
        coeff_abs = coeff_abs + 1
      }
      if coeff_abs >= 15 {
        let mut jj = 0
        while cabac.get_cabac_bypass() != 0 && jj < 16 + 7 {
          jj = jj + 1
        }
        coeff_abs = 1
        while jj > 0 {
          jj = jj - 1
          coeff_abs = coeff_abs + coeff_abs + cabac.get_cabac_bypass()
        }
        coeff_abs = coeff_abs + 14
      }
      block[base + j] = match qmul {
        None => cabac.get_cabac_bypass_sign(-coeff_abs)
        Some(q) => (cabac.get_cabac_bypass_sign(-coeff_abs) * q[j] + 32) >> 6
      }
    }
  }
  Ok(coeff_count)
}

///|
/// `ff_h264_decode_mb_cabac`, intra and (later) P paths. Parses one
/// macroblock with the CABAC engine and reconstructs it through the shared
/// `h264_recon_mb` path.
///
/// `last_qscale_diff` lives in `H264DecCtx` because the C keeps it in
/// `H264SliceContext` across macroblocks (it selects a different `mb_qp_delta`
/// context on the first delta after a non-zero one).

///| Intra continuation shared by the I-slice dispatcher and the intra branch

///| of a P slice (the `decode_intra_mb` label in `ff_h264_decode_mb_cabac`).

///| `mb_type` is the already-decoded intra mb_type (0..24), `modes` the raw

///|
/// Intra4x4 mode scratch array. The caller has cleared `nz`.
fn h264_decode_mb_cabac_intra(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  mb_type : Int32,
  modes : Array[Int32],
) -> Result[Unit, String] {
  let pps = ctx.pps
  let info = ctx.infos[mb_idx]
  let nz = info.nz
  let modes_ck : Array[Int32] = Array::make(16, 0)
  // The caller decoded `mb_type` (`decode_cabac_intra_mb_type`, ctx_base 3
  // for an I slice / 17 for the intra branch of a P slice) and rejected 25
  // (I_PCM in a CABAC slice).
  if mb_type < 0 || mb_type > 25 {
    return Err("invalid CABAC mb_type")
  }
  let is_i4x4 = mb_type == 0
  let is_i16x16 = !is_i4x4
  let mut cbp = h264_i_mb_type_cbp[mb_type]
  let mut pred16 = h264_i_mb_type_pred[mb_type]
  if is_i4x4 {
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let pred = h264_pred_intra_mode(ctx, mb_idx, mb_x, mb_y, gx, gy, modes)
      modes[gy * 4 + gx] = h264_cabac_intra4x4_pred_mode(cabac, states, pred)
    }
    // `ff_h264_check_intra4x4_pred_mode` remaps DC at unavailable edges, but
    // FFmpeg calls `write_back_intra_pred_mode()` *before* that check, so the
    // modes stored for the neighbouring macroblocks (and used as
    // `pred_intra_mode`) are the raw coded ones. Keep both: `modes` stays raw
    // for prediction and `info.modes`, `modes_ck` feeds the reconstruction.
    for gy = 0; gy < 4; gy = gy + 1 {
      for gx = 0; gx < 4; gx = gx + 1 {
        let g = gy * 4 + gx
        let top = gy > 0 || mb_y > 0
        let left = gx > 0 || mb_x > 0
        modes_ck[g] = match h264_check_intra4x4_mode(modes[g], top, left) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
  } else {
    pred16 = match h264_check_intra_pred_mode(pred16, mb_y > 0, mb_x > 0) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  // Chroma prediction mode (`decode_cabac_mb_chroma_pre_mode`).
  let raw_chroma = h264_cabac_chroma_pre_mode(
    cabac, states, ctx, mb_idx, mb_x, mb_y,
  )
  info.chroma_mode = raw_chroma
  let chroma_mode = match
    h264_check_intra_pred_mode(raw_chroma, mb_y > 0, mb_x > 0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !is_i16x16 {
    // Decode in the C's order: luma CBP first, then chroma. Written as two
    // statements so the evaluation order cannot depend on operator rewriting.
    let cbp_luma = h264_cabac_mb_cbp_luma(
      cabac, states, ctx, mb_idx, mb_x, mb_y,
    )
    let cbp_chroma = h264_cabac_mb_cbp_chroma(
      cabac, states, ctx, mb_idx, mb_x, mb_y,
    )
    cbp = cbp_luma | (cbp_chroma << 4)
  }
  info.cbp_all = cbp
  let mb : Array[Int32] = Array::make(768, 0)
  let luma_dc : Array[Int32] = Array::make(16, 0)
  let mut luma_dc_nz = 0
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let mut chroma_qp0 = h264_get_chroma_qp(pps, 0, ctx.qscale)
  let mut chroma_qp1 = h264_get_chroma_qp(pps, 1, ctx.qscale)
  let mut qmul_luma : Array[Int32] = []
  if cbp != 0 || is_i16x16 {
    // `decode_cabac_mb_dqp`.
    if cabac.get_cabac(
        states,
        60 + (if ctx.last_qscale_diff != 0 { 1 } else { 0 }),
      ) !=
      0 {
      let mut val = 1
      let mut c = 2
      while cabac.get_cabac(states, 60 + c) != 0 {
        c = 3
        val = val + 1
        if val > 2 * 51 {
          return Err("cabac decode of qscale diff failed")
        }
      }
      val = if (val & 0x01) != 0 { (val + 1) >> 1 } else { -((val + 1) >> 1) }
      ctx.last_qscale_diff = val
      let mut q = ctx.qscale + val
      if q < 0 {
        q = q + 52
      } else if q > 51 {
        q = q - 52
      }
      ctx.qscale = q
      chroma_qp0 = h264_get_chroma_qp(pps, 0, q)
      chroma_qp1 = h264_get_chroma_qp(pps, 1, q)
    } else {
      ctx.last_qscale_diff = 0
    }
    qmul_luma = h264_build_dequant4(pps, 0, ctx.qscale)
    if is_i16x16 {
      luma_dc_nz = match
        h264_cabac_residual(
          cabac,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          luma_dc,
          0,
          0,
          48,
          nz,
          h264_zigzag_scan_t,
          0,
          None,
          16,
          true,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if (cbp & 15) != 0 {
        for i = 0; i < 16; i = i + 1 {
          let total = match
            h264_cabac_residual(
              cabac,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              mb,
              16 * i,
              1,
              i,
              nz,
              h264_zigzag_scan_t,
              1,
              Some(qmul_luma),
              15,
              false,
            ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          let _ = total
        }
      }
    } else {
      for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
        if (cbp & (1 << i8x8)) != 0 {
          for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
            let i = 4 * i8x8 + i4x4
            let total = match
              h264_cabac_residual(
                cabac,
                states,
                ctx,
                mb_idx,
                mb_x,
                mb_y,
                mb,
                16 * i,
                2,
                i,
                nz,
                h264_zigzag_scan_t,
                0,
                Some(qmul_luma),
                16,
                false,
              ) {
              Ok(v) => v
              Err(e) => return Err(e)
            }
            let _ = total
          }
        }
      }
    }
    if (cbp & 0x30) != 0 {
      for c = 0; c < 2; c = c + 1 {
        chroma_dc_nz[c] = match
          h264_cabac_residual(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            mb,
            256 + 256 * c,
            3,
            49 + c,
            nz,
            h264_chroma_dc_scan,
            0,
            None,
            4,
            true,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
    if (cbp & 0x20) != 0 {
      for c = 0; c < 2; c = c + 1 {
        let cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
        let qmul_c = h264_build_dequant4(pps, 1 + c, cqp)
        for i = 0; i < 4; i = i + 1 {
          let total = match
            h264_cabac_residual(
              cabac,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              mb,
              256 + 256 * c + 16 * i,
              4,
              16 + 16 * c + i,
              nz,
              h264_zigzag_scan_t,
              1,
              Some(qmul_c),
              15,
              false,
            ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          let _ = total
        }
      }
    }
  } else {
    // C's residual-decode else branch (`h264_cabac.c` end of
    // `ff_h264_decode_mb_cabac`): all nz counts are zero (already cleared)
    // and the QP-delta context resets.
    ctx.last_qscale_diff = 0
  }
  match
    h264_recon_mb(
      ctx, mb_x, mb_y, is_i4x4, is_i16x16, pred16, chroma_mode, modes_ck, cbp, luma_dc_nz,
      chroma_dc_nz, chroma_qp0, chroma_qp1, qmul_luma, mb, luma_dc, nz,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = modes[g]
  }
  info.intra4x4 = is_i4x4
  info.mb_type_bits = if is_i16x16 {
    h264_mb_type_intra16x16
  } else {
    h264_mb_type_intra4x4
  }
  // `cbp_all` was already written before the residual decode and the DC flags
  // were ORed into it there; do not overwrite it here.
  info.qp = ctx.qscale
  Ok(())
}

///|
/// `ff_h264_decode_mb_cabac` dispatcher: clears the per-macroblock
/// neighbour arrays, then routes to the P-slice inter decoder
/// (`h264_inter.mbt`) or the intra continuation. An I slice goes straight
/// to `decode_cabac_intra_mb_type(..., ctx_base = 3, intra_slice = 1)`.
fn h264_decode_mb_cabac(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let nz = ctx.infos[mb_idx].nz
  for i = 0; i < 48; i = i + 1 {
    nz[i] = 0
  }
  if ctx.slice_type_nos != 2 {
    return h264_decode_mb_cabac_p(cabac, states, ctx, mb_idx, mb_x, mb_y)
  }
  ctx.cur_mb_is_intra = true
  let mb_type = h264_cabac_intra_mb_type(
    cabac, states, ctx, mb_idx, mb_x, mb_y, 3, 1,
  )
  if mb_type == 25 {
    return Err("I_PCM in a CABAC slice is not supported")
  }
  h264_decode_mb_cabac_intra(
    cabac,
    states,
    ctx,
    mb_idx,
    mb_x,
    mb_y,
    mb_type,
    Array::make(16, 0),
  )
}
