///|
/// §468c: encoder-side deblocking for INTER frames.
///
/// §468b covers intra key frames. Inter frames differ in two ways the mask
/// builder cares about: the block is a whole 64x64 PARTITION_NONE (not four
/// 32x32 intra blocks), and each superblock carries a `skip` flag plus a
/// var-tx split mask. The decoder's own `av1_create_lf_mask_inter` is
/// public and fully parameterised, so this file drives it directly and
/// then runs the same filter loop §468b uses.
///
/// The encoder's inter frames always use: 64x64 superblock, var-tx SPLIT
/// into four TX_32X32 leaves (so `tx_masks[0] = 1`, `tx_masks[1] = 0`),
/// chroma TX_32X32, 4:2:0, 8-bit.

///|
/// Apply the deblocking filter to a reconstructed INTER frame in place.
///
/// `skips[sb]` is the superblock's skip flag (raster order over the
/// `sb_cols` x `sb_rows` grid); a skipped superblock has no residual so the
/// mask builder omits the inner transform edges. Returns `true` when any
/// filtering ran.
pub fn av1_enc_deblock_frame_inter(
  y : FixedArray[Int32],
  y_stride : Int32,
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  uv_stride : Int32,
  width : Int32,
  height : Int32,
  hdr : Av1FrameHeader,
  skips : FixedArray[Bool],
  has_chroma : Bool,
  ss_h : Int32,
  ss_v : Int32,
  bpc : Int32,
) -> Bool {
  let lf_level_arr = hdr.loop_filter_level
  let lf_y_active = lf_level_arr.length() >= 2 &&
    (lf_level_arr[0] != 0 || lf_level_arr[1] != 0)
  let lf_u_active = lf_level_arr.length() > 2 && lf_level_arr[2] != 0
  let lf_v_active = lf_level_arr.length() > 3 && lf_level_arr[3] != 0
  if !lf_y_active && !lf_u_active && !lf_v_active {
    return false
  }
  let w4 = (width + 3) >> 2
  let h4 = (height + 3) >> 2
  let bw = 2 * ((width + 7) >> 3)
  let bh = 2 * ((height + 7) >> 3)
  let b4_stride = (bw + 31) & -32
  let sb_cols = bw >> 4
  let sb_rows = bh >> 4
  let n_sb = sb_cols * sb_rows
  if skips.length() != n_sb {
    return false
  }
  // Masks are indexed by 128-wide AREAS, not by 64x64 superblocks: with
  // `use_128x128_superblock = 0` the decoder still groups four 64x64 SBs
  // into one 128 area (`lf_mask[(by >> 5) * sb128w + (bx >> 5)]`), so the
  // two 64x64 SBs of a 128-wide area share one mask object.
  let sb128w = (bw + 31) >> 5
  let sb128h = (bh + 31) >> 5
  let n_area = sb128w * sb128h
  let lf_level = FixedArray::make(8 * 64 * 64, 0)
  av1_calc_lf_values(lf_level, hdr, FixedArray::make(4, 0))
  let lf_lut = av1_filter_lut_new()
  av1_calc_eih(lf_lut, hdr.loop_filter_sharpness)
  let masks : Array[Av1Filter] = []
  for _ in 0..<n_area {
    masks.push(av1_filter_new())
  }
  // Inter frames code a whole 64x64 block. A residual superblock splits
  // its var-tx tree into four TX_32X32 leaves (`tx_masks[0]` bit 0 set); a
  // SKIPPED superblock writes no var-tx symbols at all, so the decoder
  // fills the whole block as one TX_64X64 and its mask must use the
  // unsplit shape.
  let tx_masks_res : FixedArray[Int32] = [1, 0]
  let tx_masks_skip : FixedArray[Int32] = [0, 0]
  let ytx = 4 // TX_64X64: the block's max tx, which the tree splits from
  let uvtx = 3 // chroma TX_32X32
  let bs = av1_block_sizes[(1 * 10 + 0) * 2].to_int() // BL_64X64
  let a_tx_y = FixedArray::make(32, 0)
  let a_tx_uv = FixedArray::make(32, 0)
  let l_tx_y = FixedArray::make(32, 0)
  let l_tx_uv = FixedArray::make(32, 0)
  let lvl_y = FixedArray::make(4, 0)
  lvl_y[0] = level_at(hdr, 0)
  lvl_y[1] = level_at(hdr, 1)
  lvl_y[2] = level_at(hdr, 2)
  lvl_y[3] = level_at(hdr, 3)
  // The mask builder wants a 64-entry level table with each direction's
  // SELECTED ref/mode level at offset 0 of its 16-entry group (see
  // `av1_decode_inter`). Our frames always code reference LAST (ref0 = 0);
  // the mode differs per superblock:
  //   - a skipped SB codes GLOBALMV (mode 2) → index (0+1)*2 + 0 = 2
  //   - a residual SB codes NEWMV/NEARESTMV → index (0+1)*2 + 1 = 3
  // so the selection is per-SB, not per-frame.
  let levels_skip = FixedArray::make(64, 0)
  let levels_res = FixedArray::make(64, 0)
  for dir in 0..<4 {
    levels_skip[dir * 16] = lf_level[dir * 16 + 2]
    levels_res[dir * 16] = lf_level[dir * 16 + 3]
  }
  for sby in 0..<sb_rows {
    for i in 0..<32 {
      l_tx_y[i] = 0
      l_tx_uv[i] = 0
    }
    for sbx in 0..<sb_cols {
      let sb = sby * sb_cols + sbx
      let bx = sbx * 16
      let by = sby * 16
      let mask = masks[(by >> 5) * sb128w + (bx >> 5)]
      av1_create_lf_mask_inter(
        lf_level,
        if skips[sb] {
          levels_skip
        } else {
          levels_res
        },
        b4_stride,
        w4,
        h4,
        ss_h,
        ss_v,
        mask.fy,
        mask.fuv,
        bx,
        by,
        skips[sb],
        bs,
        ytx,
        if skips[sb] {
          tx_masks_skip
        } else {
          tx_masks_res
        },
        uvtx,
        a_tx_y,
        bx & 31,
        l_tx_y,
        by & 31,
        a_tx_uv,
        (bx & 31) >> ss_h,
        l_tx_uv,
        (by & 31) >> ss_v,
        has_chroma,
        0,
      )
    }
  }
  // Same filter loop as the intra driver.
  for sby in 0..<sb_rows {
    let endy4 = av1_imin(h4 - sby * 16, 16)
    if endy4 <= 0 {
      continue
    }
    let uv_endy4 = (endy4 + ss_v) >> ss_v
    let y_off = sby * 16 * 4 * y_stride
    let uv_off = ((sby * 16 * 4) >> ss_v) * uv_stride
    let row4 = sby * 16
    let lvl_off = row4 * b4_stride * 4
    let uv_row4 = row4 >> ss_v
    let uv_lvl_off = uv_row4 * b4_stride * 4
    for x in 0..<sb128w {
      let mask = masks[(sby >> 1) * sb128w + x]
      let w = av1_imin(32, w4 - x * 32)
      if lf_y_active {
        deblock_cols_y(
          y,
          y_stride,
          b4_stride,
          lf_level,
          lf_lut,
          bpc,
          x > 0,
          lvl_off + x * 32 * 4,
          mask,
          y_off + x * 128,
          w,
          endy4,
        )
      }
      if has_chroma && (lf_u_active || lf_v_active) {
        let cw = (w + ss_h) >> ss_h
        deblock_cols_uv(
          u,
          v,
          uv_stride,
          b4_stride,
          lf_level,
          lf_lut,
          bpc,
          ss_h,
          ss_v,
          x > 0,
          uv_lvl_off + x * (32 >> ss_h) * 4,
          mask,
          uv_off + x * (128 >> ss_h),
          cw,
          uv_endy4,
        )
      }
    }
    for x in 0..<sb128w {
      let mask = masks[(sby >> 1) * sb128w + x]
      let w = av1_imin(32, w4 - x * 32)
      if lf_y_active {
        deblock_rows_y(
          y,
          y_stride,
          b4_stride,
          lf_level,
          lf_lut,
          bpc,
          sby > 0,
          lvl_off + x * 32 * 4,
          mask,
          y_off + x * 128,
          w,
          endy4,
        )
      }
      if has_chroma && (lf_u_active || lf_v_active) {
        let cw = (w + ss_h) >> ss_h
        deblock_rows_uv(
          u,
          v,
          uv_stride,
          b4_stride,
          lf_level,
          lf_lut,
          bpc,
          ss_h,
          ss_v,
          sby > 0,
          uv_lvl_off + x * (32 >> ss_h) * 4,
          mask,
          uv_off + x * (128 >> ss_h),
          cw,
          uv_endy4,
        )
      }
    }
  }
  true
}
