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
/// reference frame list. I/P paths and 8x8DCT are supported. Explicitly
/// rejected: I_PCM in a CABAC slice, field/MBAFF, 4:2:2/4:4:4 and high bit depth.
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
/// `significant_coeff_flag_offset[1][14]` (MB_FIELD == 1). */
let h264_cabac_significant_coeff_offset_field : Array[Int32] = [
  277 + 0,
  277 + 15,
  277 + 29,
  277 + 44,
  277 + 47,
  436,
  776 + 0,
  776 + 15,
  776 + 29,
  675,
  820 + 0,
  820 + 15,
  820 + 29,
  733,
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
/// `last_coeff_flag_offset[1][14]` (MB_FIELD == 1). */
let h264_cabac_last_coeff_flag_offset_field : Array[Int32] = [
  338 + 0,
  338 + 15,
  338 + 29,
  338 + 44,
  338 + 47,
  451,
  864 + 0,
  864 + 15,
  864 + 29,
  699,
  908 + 0,
  908 + 15,
  908 + 29,
  757,
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
/// `coeff_abs_levelgt1_ctx[0][8]` (non 4:2:2) and `[1][8]` (4:2:2 chroma DC). */
let h264_cabac_coeff_abs_levelgt1_ctx : Array[Array[Int32]] = [
  [5, 5, 5, 5, 6, 7, 8, 9],
  [5, 5, 5, 5, 6, 7, 8, 8],
]

///|
/// `sig_coeff_offset_dc[7]`: the 4:2:2 chroma DC significance/last contexts
/// (three contexts shared by both flags). */
let h264_cabac_sig_coeff_offset_dc : Array[Int32] = [0, 0, 1, 1, 2, 2, 2]

///|
/// The plane a residual category belongs to (`decode_cabac_luma_residual`'s
/// `ctx_cat` columns): cats 0/1/2/5 are luma, 6..9 plane 1, 10..13 plane 2;
/// cat 3/4 are the 4:2:0/4:2:2 chroma DC/AC.
fn h264_cabac_cat_plane(cat : Int32) -> Int32 {
  if cat >= 10 {
    2
  } else if cat >= 6 {
    1
  } else {
    0
  }
}

///|
/// `coeff_abs_level_transition[2][8]`. */
let h264_cabac_coeff_abs_level_transition : Array[Array[Int32]] = [
  [1, 2, 3, 3, 4, 5, 6, 7],
  [4, 4, 4, 4, 5, 6, 7, 7],
]

///|
/// `significant_coeff_flag_offset_8x8[0][63]` (8x8DCT luma). */
let h264_cabac_sig8 : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 5, 4, 4, 3, 3, 4, 4, 4, 5, 5, 4, 4, 4, 4, 3, 3, 6, 7, 7, 7, 8,
  9, 10, 9, 8, 7, 7, 6, 11, 12, 13, 11, 6, 7, 8, 9, 14, 10, 9, 8, 6, 11, 12, 13,
  11, 6, 9, 14, 10, 9, 11, 12, 13, 11, 14, 10, 12,
]

///|
/// `significant_coeff_flag_offset_8x8[1][63]` (field-coded 8x8DCT luma). */
let h264_cabac_sig8_field : FixedArray[Int32] = [
  0, 1, 1, 2, 2, 3, 3, 4, 5, 6, 7, 7, 7, 8, 4, 5, 6, 9, 10, 10, 8, 11, 12, 11, 9,
  9, 10, 10, 8, 11, 12, 11, 9, 9, 10, 10, 8, 11, 12, 11, 9, 9, 10, 10, 8, 13, 13,
  9, 9, 10, 10, 8, 13, 13, 9, 9, 10, 10, 14, 14, 14, 14, 14,
]

///|
/// `ff_h264_last_coeff_flag_offset_8x8[63]`: the 8x8 `last_coeff_flag`
/// contexts are a compressed function of the scan position, not the position
/// itself. */
let h264_cabac_last8 : FixedArray[Int32] = [
  0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6,
  6, 6, 7, 7, 7, 7, 8, 8, 8,
]

///|
/// `sl->neighbor_transform_size`: number of 8x8DCT neighbours (left + top)
/// selecting the context of the `transform_size_8x8_flag` bin.
fn h264_neighbor_transform_size(
  ctx : H264DecCtx,
  mb_idx : Int32,
  _mb_x : Int32,
  _mb_y : Int32,
) -> Int32 {
  let mut n = 0
  if h264_has_left(ctx, mb_idx) && ctx.infos[mb_idx - 1].transform_8x8 {
    n = n + 1
  }
  if h264_has_top(ctx, mb_idx) &&
    ctx.infos[h264_top_index(ctx, mb_idx)].transform_8x8 {
    n = n + 1
  }
  n
}

///|
/// `get_cabac_cbf_ctx`: coded-block-flag context. `cat` is the C's residual
/// category (0..5 the 4:2:0 cats; 6..13 the 4:4:4 per-plane luma cats of
/// `decode_cabac_luma_residual`'s `ctx_cat`) and `n` the block index in the
/// C's numbering (luma 0..15 z-order, chroma 16 + 16*c + i, DC 48 + p /
/// 49 + c).
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
  if cat == 0 || cat == 6 || cat == 10 {
    // Full-plane DC: bit 8 + p of the packed CBP (per plane in 4:4:4).
    let idx = n - 48
    nza = left_cbp & (0x100 << idx)
    nzb = top_cbp & (0x100 << idx)
  } else if cat == 3 {
    let idx = n - 49 // CHROMA_DC_BLOCK_INDEX
    nza = (left_cbp >> (6 + idx)) & 0x01
    nzb = (top_cbp >> (6 + idx)) & 0x01
  } else if cat == 4 && ctx.chroma_format != 2 {
    // 4:2:0 chroma AC: 2x2 block grid.
    let w = 2
    let r = (n - 16) & 15
    let base = 16 + 16 * ((n - 16) / 16)
    let x = r % w
    let y = r / w
    nza = if x > 0 {
      nz[base + r - 1]
    } else if h264_has_left(ctx, mb_idx) {
      ctx.infos[mb_idx - 1].nz[base + y * w + (w - 1)]
    } else if ctx.cur_mb_is_intra {
      64
    } else {
      0
    }
    nzb = if y > 0 {
      nz[base + r - w]
    } else if h264_has_top(ctx, mb_idx) {
      ctx.infos[h264_top_index(ctx, mb_idx)].nz[base + (w - 1) * w + x]
    } else if ctx.cur_mb_is_intra {
      64
    } else {
      0
    }
  } else if cat == 4 {
    // 4:2:2 chroma AC: `scan8` stacks the two 8x8s vertically (block i at
    // cache row 6 + i/2, column 4 + i%2); column-4 blocks read the left
    // macroblock's b1/b3/b5/b7, row-6 blocks the top macroblock's b6/b7
    // (`fill_decode_caches`'s `!chroma_y_shift` fill). An unavailable
    // neighbour is 0 in inter macroblocks, 64 in intra ones.
    let base = 16 + 16 * ((n - 16) / 16)
    let i = (n - 16) & 15
    let unavail = if ctx.cur_mb_is_intra { 64 } else { 0 }
    nza = if (i & 1) == 1 {
      nz[base + i - 1]
    } else if h264_has_left(ctx, mb_idx) {
      ctx.infos[mb_idx - 1].nz[base + i + 1]
    } else {
      unavail
    }
    nzb = if i >= 2 {
      nz[base + i - 2]
    } else if h264_has_top(ctx, mb_idx) {
      ctx.infos[h264_top_index(ctx, mb_idx)].nz[base + 6 + i]
    } else {
      unavail
    }
  } else {
    // Luma-grid categories (1/2/5 and the 4:4:4 per-plane 7..13).
    let w = 4
    let base = 16 * h264_cabac_cat_plane(cat)
    let r = h264_luma_block_grid[n & 15]
    let x = r % w
    let y = r / w
    // The 4:4:4 8x8DCT neighbour quirk (`ff_h264_decode_mb_cabac` after the
    // cbp): a 4x4 neighbour contributes no 8x8-level nnz, so its left/top
    // entries read as zero (64 only for an I_PCM neighbour).
    let quirk_zero = ctx.chroma_format == 3 && ctx.infos[mb_idx].transform_8x8
    nza = if x > 0 {
      nz[base + r - 1]
    } else if h264_has_left(ctx, mb_idx) {
      let left = ctx.infos[mb_idx - 1]
      if quirk_zero && !left.transform_8x8 {
        if (left.mb_type_bits & h264_mb_type_intra_pcm) != 0 {
          64
        } else {
          0
        }
      } else {
        left.nz[base + y * w + (w - 1)]
      }
    } else if ctx.cur_mb_is_intra {
      64
    } else {
      0
    }
    // The top neighbour of a first-row block is the macroblock above's bottom
    // row: `nz[3*4 + x]` of the plane's section.
    nzb = if y > 0 {
      nz[base + r - w]
    } else if h264_has_top(ctx, mb_idx) {
      let top = ctx.infos[h264_top_index(ctx, mb_idx)]
      if quirk_zero && !top.transform_8x8 {
        if (top.mb_type_bits & h264_mb_type_intra_pcm) != 0 {
          64
        } else {
          0
        }
      } else {
        top.nz[base + (w - 1) * w + x]
      }
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
fn h264_cabac_left_cbp(
  ctx : H264DecCtx,
  mb_idx : Int32,
  _mb_x : Int32,
) -> Int32 {
  if h264_has_left(ctx, mb_idx) {
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
fn h264_cabac_top_cbp(ctx : H264DecCtx, mb_idx : Int32, _mb_y : Int32) -> Int32 {
  if h264_has_top(ctx, mb_idx) {
    ctx.infos[h264_top_index(ctx, mb_idx)].cbp_all
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
  _mb_x : Int32,
) -> Int32 {
  if h264_has_left(ctx, mb_idx) {
    ctx.infos[mb_idx - 1].mb_type_bits
  } else {
    0
  }
}

///|
/// `sl->top_type`. */
fn h264_cabac_top_type(
  ctx : H264DecCtx,
  mb_idx : Int32,
  _mb_y : Int32,
) -> Int32 {
  if h264_has_top(ctx, mb_idx) {
    ctx.infos[h264_top_index(ctx, mb_idx)].mb_type_bits
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
  if top_type != 0 && ctx.infos[h264_top_index(ctx, mb_idx)].chroma_mode != 0 {
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
  let is_8x8 = max_coeff == 64
  // For 8x8DCT luma the coded-block flag is implied by the luma CBP bit —
  // except in 4:4:4, where every plane codes it (`(cat != 5 || CHROMA444)`).
  if !is_8x8 || cat != 5 || ctx.chroma_format == 3 {
    let cbf_ctx = h264_cabac_cbf_ctx(ctx, mb_idx, mb_x, mb_y, cat, n, nz)
    if cabac.get_cabac(states, cbf_ctx) == 0 {
      // Coded block flag is zero: no coefficients. Keep the neighbour arrays
      // in sync (`sl->non_zero_count_cache[...] = 0`).
      if !is_dc {
        if is_8x8 {
          // `fill_rectangle(non_zero_count_cache[scan8[n]], 2, 2, 8, 0)`:
          // the whole 2x2 quadrant of the plane's grid.
          let i8 = (n & 15) / 4
          let x0 = i8 % 2 * 2
          let y0 = i8 / 2 * 2
          let base = 16 * h264_cabac_cat_plane(cat)
          for dy in 0..<2 {
            for dx in 0..<2 {
              nz[base + (y0 + dy) * 4 + x0 + dx] = 0
            }
          }
        } else if cat == 1 || cat == 2 || cat >= 6 {
          let r = h264_luma_block_grid[n & 15]
          nz[16 * h264_cabac_cat_plane(cat) + r] = 0
        } else {
          nz[n] = 0
        }
      }
      return Ok(0)
    }
  }
  let sig_base = if ctx.mb_field {
    h264_cabac_significant_coeff_offset_field[cat]
  } else {
    h264_cabac_significant_coeff_offset[cat]
  }
  let last_base = if ctx.mb_field {
    h264_cabac_last_coeff_flag_offset_field[cat]
  } else {
    h264_cabac_last_coeff_flag_offset[cat]
  }
  let abs_base = h264_cabac_coeff_abs_level_m1_offset[cat]
  let index : Array[Int32] = Array::make(64, 0)
  let mut coeff_count = 0
  let mut node_ctx = 0
  let is_dc422 = is_dc && cat == 3 && max_coeff == 8
  if is_dc422 {
    // `DECODE_SIGNIFICANCE(7, sig_coeff_offset_dc[last], ...)`: the 2x4 DC
    // block codes at most 7 significance positions explicitly and implies
    // the eighth; both flags use the same three-context table.
    let mut last = 0
    while last < 7 {
      let off = h264_cabac_sig_coeff_offset_dc[last]
      if cabac.get_cabac(states, sig_base + off) != 0 {
        index[coeff_count] = last
        coeff_count = coeff_count + 1
        if cabac.get_cabac(states, last_base + off) != 0 {
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
  } else {
    // DECODE_SIGNIFICANCE(max_coeff - 1, last, last)
    let coefs = max_coeff - 1
    let mut last = 0
    while last < coefs {
      let sig_ctx = if is_8x8 {
        sig_base +
        (if ctx.mb_field {
          h264_cabac_sig8_field[last]
        } else {
          h264_cabac_sig8[last]
        })
      } else {
        sig_base + last
      }
      if cabac.get_cabac(states, sig_ctx) != 0 {
        index[coeff_count] = last
        coeff_count = coeff_count + 1
        let last_ctx = last_base +
          (if is_8x8 { h264_cabac_last8[last] } else { last })
        if cabac.get_cabac(states, last_ctx) != 0 {
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
  } else if is_8x8 {
    // `fill_rectangle(non_zero_count_cache[scan8[n]], 2, 2, 8, count)`; the
    // quadrant is the block index within its plane (`n & 15`).
    let i8 = (n & 15) / 4
    let x0 = i8 % 2 * 2
    let y0 = i8 / 2 * 2
    let base = 16 * h264_cabac_cat_plane(cat)
    for dy = 0; dy < 2; dy = dy + 1 {
      for dx = 0; dx < 2; dx = dx + 1 {
        nz[base + (y0 + dy) * 4 + x0 + dx] = coeff_count
      }
    }
  } else if cat == 1 || cat == 2 || cat >= 6 {
    nz[16 * h264_cabac_cat_plane(cat) + h264_luma_block_grid[n & 15]] = coeff_count
  } else {
    nz[n] = coeff_count
  }
  let gt1_ctxs = h264_cabac_coeff_abs_levelgt1_ctx[if is_dc422 { 1 } else { 0 }]
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
      let ctx2 = abs_base + gt1_ctxs[node_ctx]
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
/// `decode_cabac_luma_residual` for one full-size plane `p` (0 luma, 1/2 the
/// 4:4:4 chroma planes): the I16x16 DC block plus the CBP-gated AC blocks,
/// with the per-plane `ctx_cat` categories and dequant tables. `cqm_base` is
/// 0 for intra and 3 for inter macroblocks.
fn h264_cabac_luma_residual(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  is_i16x16 : Bool,
  cbp : Int32,
  p : Int32,
  chroma_qp : Int32,
  cqm_base : Int32,
  mb : Array[Int32],
  luma_dc : Array[Array[Int32]],
  luma_dc_nz : Array[Int32],
  nz : Array[Int32],
) -> Result[Unit, String] {
  // ctx_cat[4][3] of `decode_cabac_luma_residual`.
  let cat_dc = [0, 6, 10][p]
  let cat_ac16 = [1, 7, 11][p]
  let cat_ac4 = [2, 8, 12][p]
  let cat_ac8 = [5, 9, 13][p]
  let qscale = if p == 0 { ctx.qscale } else { chroma_qp }
  let mb_off = 256 * p
  if is_i16x16 {
    luma_dc_nz[p] = match
      h264_cabac_residual(
        cabac,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        luma_dc[p],
        0,
        cat_dc,
        48 + p,
        nz,
        h264_scan4(ctx),
        0,
        None,
        16,
        true,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if (cbp & 15) != 0 {
      let qmul = h264_build_dequant4(ctx.pps, p, qscale)
      for i = 0; i < 16; i = i + 1 {
        match
          h264_cabac_residual(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            mb,
            mb_off + 16 * i,
            cat_ac16,
            16 * p + i,
            nz,
            h264_scan4(ctx),
            1,
            Some(qmul),
            15,
            false,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
    return Ok(())
  }
  if ctx.infos[mb_idx].transform_8x8 {
    let qmul8 = h264_build_dequant8(ctx.pps, cqm_base + p, qscale)
    for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
      if (cbp & (1 << i8x8)) != 0 {
        match
          h264_cabac_residual(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            mb,
            mb_off + 64 * i8x8,
            cat_ac8,
            16 * p + 4 * i8x8,
            nz,
            h264_scan8x8(ctx),
            0,
            Some(qmul8),
            64,
            false,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
    return Ok(())
  }
  let qmul = h264_build_dequant4(ctx.pps, cqm_base + p, qscale)
  for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
    if (cbp & (1 << i8x8)) != 0 {
      for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
        let i = 4 * i8x8 + i4x4
        match
          h264_cabac_residual(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            mb,
            mb_off + 16 * i,
            cat_ac4,
            16 * p + i,
            nz,
            h264_scan4(ctx),
            0,
            Some(qmul),
            16,
            false,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
  }
  Ok(())
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
    let use8x8 = pps.transform_8x8_mode != 0 &&
      cabac.get_cabac(
        states,
        399 + h264_neighbor_transform_size(ctx, mb_idx, mb_x, mb_y),
      ) !=
      0
    if use8x8 {
      info.transform_8x8 = true
      for i = 0; i < 16; i = i + 4 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let pred = h264_pred_intra_mode(ctx, mb_idx, mb_x, mb_y, gx, gy, modes)
        let mode = h264_cabac_intra4x4_pred_mode(cabac, states, pred)
        for dy = 0; dy < 2; dy = dy + 1 {
          for dx = 0; dx < 2; dx = dx + 1 {
            modes[(gy + dy) * 4 + gx + dx] = mode
          }
        }
      }
    } else {
      for i = 0; i < 16; i = i + 1 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let pred = h264_pred_intra_mode(ctx, mb_idx, mb_x, mb_y, gx, gy, modes)
        modes[gy * 4 + gx] = h264_cabac_intra4x4_pred_mode(cabac, states, pred)
      }
    }
    // `ff_h264_check_intra4x4_pred_mode` remaps DC at unavailable edges, but
    // FFmpeg calls `write_back_intra_pred_mode()` *before* that check, so the
    // modes stored for the neighbouring macroblocks (and used as
    // `pred_intra_mode`) are the raw coded ones. Keep both: `modes` stays raw
    // for prediction and `info.modes`, `modes_ck` feeds the reconstruction.
    for gy = 0; gy < 4; gy = gy + 1 {
      for gx = 0; gx < 4; gx = gx + 1 {
        let g = gy * 4 + gx
        let top = gy > 0 || h264_intra_top(ctx, mb_idx)
        let left = gx > 0 || h264_intra_left(ctx, mb_idx)
        modes_ck[g] = match h264_check_intra4x4_mode(modes[g], top, left) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
  } else {
    pred16 = match
      h264_check_intra_pred_mode(
        pred16,
        h264_intra_top(ctx, mb_idx),
        h264_intra_left(ctx, mb_idx),
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  // Chroma prediction mode (`decode_cabac_mb_chroma_pre_mode`); 4:4:4 and
  // monochrome code none and `sl->chroma_pred_mode` keeps the DC_128
  // placeholder.
  let mut raw_chroma = 0
  let mut chroma_mode = 0
  if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
    raw_chroma = h264_cabac_chroma_pre_mode(
      cabac, states, ctx, mb_idx, mb_x, mb_y,
    )
    chroma_mode = match
      h264_check_intra_pred_mode(
        raw_chroma,
        h264_intra_top(ctx, mb_idx),
        h264_intra_left(ctx, mb_idx),
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  info.chroma_mode = raw_chroma
  if !is_i16x16 {
    // Decode in the C's order: luma CBP first, then chroma. Written as two
    // statements so the evaluation order cannot depend on operator rewriting.
    let cbp_luma = h264_cabac_mb_cbp_luma(
      cabac, states, ctx, mb_idx, mb_x, mb_y,
    )
    cbp = if ctx.chroma_format == 0 || ctx.chroma_format == 3 {
      cbp_luma
    } else {
      let cbp_chroma = h264_cabac_mb_cbp_chroma(
        cabac, states, ctx, mb_idx, mb_x, mb_y,
      )
      cbp_luma | (cbp_chroma << 4)
    }
  } else if (ctx.chroma_format == 0 || ctx.chroma_format == 3) && cbp > 15 {
    return Err("gray chroma")
  }
  info.cbp_all = cbp
  let mb : Array[Int32] = Array::make(768, 0)
  let luma_dc : Array[Array[Int32]] = [
    Array::make(16, 0),
    Array::make(16, 0),
    Array::make(16, 0),
  ]
  let luma_dc_nz : Array[Int32] = Array::make(3, 0)
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let mut chroma_qp0 = h264_get_chroma_qp(
    pps,
    0,
    ctx.qscale,
    bit_depth=ctx.bit_depth,
  )
  let mut chroma_qp1 = h264_get_chroma_qp(
    pps,
    1,
    ctx.qscale,
    bit_depth=ctx.bit_depth,
  )
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
        if val > 2 * h264_max_qp(ctx) {
          return Err("cabac decode of qscale diff failed")
        }
      }
      val = if (val & 0x01) != 0 { (val + 1) >> 1 } else { -((val + 1) >> 1) }
      ctx.last_qscale_diff = val
      let mut q = ctx.qscale + val
      if q < 0 {
        q = q + h264_max_qp(ctx) + 1
      } else if q > h264_max_qp(ctx) {
        q = q - h264_max_qp(ctx) - 1
      }
      ctx.qscale = q
      chroma_qp0 = h264_get_chroma_qp(pps, 0, q, bit_depth=ctx.bit_depth)
      chroma_qp1 = h264_get_chroma_qp(pps, 1, q, bit_depth=ctx.bit_depth)
    } else {
      ctx.last_qscale_diff = 0
    }
    let plane_count = if ctx.chroma_format == 3 { 3 } else { 1 }
    let chroma_qps = [0, chroma_qp0, chroma_qp1]
    for p = 0; p < plane_count; p = p + 1 {
      match
        h264_cabac_luma_residual(
          cabac,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          is_i16x16,
          cbp,
          p,
          chroma_qps[p],
          0,
          mb,
          luma_dc,
          luma_dc_nz,
          nz,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
      let num_c8x8 = ctx.chroma_format
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
              if num_c8x8 == 2 {
                h264_chroma422_dc_scan
              } else {
                h264_chroma_dc_scan
              },
              0,
              None,
              4 * num_c8x8,
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
          for i = 0; i < 4 * num_c8x8; i = i + 1 {
            match
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
                h264_scan4(ctx),
                1,
                Some(qmul_c),
                15,
                false,
              ) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
          }
        }
      }
    }
  } else {
    // C's residual-decode else branch (`h264_cabac.c` end of
    // `ff_h264_decode_mb_cabac`): all nz counts are zero (already cleared)
    // and the QP-delta context resets.
    ctx.last_qscale_diff = 0
  }
  let plane_dc_mul : Array[Int32] = [
    h264_build_dequant4(pps, 0, ctx.qscale)[0],
    h264_build_dequant4(pps, 1, chroma_qp0)[0],
    h264_build_dequant4(pps, 2, chroma_qp1)[0],
  ]
  match
    h264_recon_mb(
      ctx, mb_x, mb_y, is_i4x4, is_i16x16, pred16, chroma_mode, modes_ck, cbp, luma_dc_nz,
      chroma_dc_nz, chroma_qp0, chroma_qp1, plane_dc_mul, mb, luma_dc, nz,
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
/// `decode_cabac_field_decoding_flag` (`h264_cabac.c`): one context per MBAFF
/// pair, using the current/predicted flag and the MB above the pair.
fn h264_cabac_field_decoding_flag(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
) -> Bool {
  let mut context = if ctx.mb_field && mb_x > 0 { 1 } else { 0 }
  let above = mb_idx - ctx.mb_width * 2
  if above >= 0 &&
    ctx.infos[above].slice_num == ctx.slice_num &&
    ctx.infos[above].field_mb {
    context = context + 1
  }
  let bit = cabac.get_cabac(states, 70 + context)
  bit != 0
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
  if ctx.slice_type_nos == 1 {
    return h264_decode_b_mb(Cabac(cabac, states), ctx, mb_idx)
  }
  if ctx.slice_type_nos != 2 {
    let skip = if ctx.mb_aff && (mb_y & 1) == 1 && ctx.prev_mb_skipped {
      ctx.next_mb_skipped
    } else {
      h264_cabac_mb_skip(cabac, states, ctx, mb_idx, mb_x, mb_y) != 0
    }
    if skip {
      if ctx.mb_aff && (mb_y & 1) == 0 {
        ctx.infos[mb_idx].mb_type_bits = h264_mb_type_skip
        ctx.next_mb_skipped = h264_cabac_mb_skip(
            cabac,
            states,
            ctx,
            mb_idx + ctx.mb_width,
            mb_x,
            mb_y + 1,
          ) !=
          0
        if !ctx.next_mb_skipped {
          ctx.mb_field = h264_cabac_field_decoding_flag(
            cabac, states, ctx, mb_idx, mb_x,
          )
        }
      }
      ctx.infos[mb_idx].field_mb = ctx.mb_field
      ctx.prev_mb_skipped = true
      return h264_cabac_skip_mb(ctx, mb_idx, mb_x, mb_y)
    }
    if ctx.mb_aff && (mb_y & 1) == 0 {
      ctx.mb_field = h264_cabac_field_decoding_flag(
        cabac, states, ctx, mb_idx, mb_x,
      )
    }
    ctx.infos[mb_idx].field_mb = ctx.mb_field
    ctx.prev_mb_skipped = false
    return h264_decode_mb_cabac_p(cabac, states, ctx, mb_idx, mb_x, mb_y)
  }
  if ctx.mb_aff && (mb_y & 1) == 0 {
    ctx.mb_field = h264_cabac_field_decoding_flag(
      cabac, states, ctx, mb_idx, mb_x,
    )
  }
  ctx.infos[mb_idx].field_mb = ctx.mb_field
  ctx.prev_mb_skipped = false
  ctx.cur_mb_is_intra = true
  let coded_type = h264_cabac_intra_mb_type(
    cabac, states, ctx, mb_idx, mb_x, mb_y, 3, 1,
  )
  let mb_type = if ctx.si_slice && coded_type > 0 {
    coded_type - 1
  } else {
    coded_type
  }
  if mb_type == 25 {
    return h264_decode_pcm_cabac(cabac, ctx, mb_idx, mb_x, mb_y)
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
