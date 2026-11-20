///|
/// §468b: encoder-side deblocking filter.
///
/// The decoder runs the in-loop deblocking filter after reconstructing a
/// frame, so an encoder that writes a non-zero `loop_filter_level` must
/// apply the SAME filter to its own reconstruction, or its "expected"
/// planes stop matching the decoded picture. The decoder's frame-level
/// driver (`Av1FrameCtx::loop_filter_frame`) is bound to the private frame
/// context, so this file provides an equivalent driver over plain
/// parameters, reusing the same low-level kernels (`av1_lf_h_y` /
/// `av1_lf_v_y` / `av1_lf_h_uv` / `av1_lf_v_uv`) and the same mask
/// builders (`av1_mask_edges_intra` / `av1_mask_edges_chroma`).
///
/// Scope: the pure-MoonBit encoder always emits ONE tile, 64x64
/// superblocks split into four 32x32 PARTITION_NONE intra blocks coded at
/// TX_32X32 with skip=0, 4:2:0, 8-bit. That fixed shape removes the tile
/// boundary fixups and the multi-tile bookkeeping the decoder driver
/// needs, while every mask/level computation still goes through the
/// shared helpers so the filtered result matches the decoder bit for bit.

///|
/// Apply the deblocking filter to a reconstructed frame in place.
///
/// `planes` holds the three component planes with the given strides;
/// `hdr` supplies the loop-filter levels, sharpness and delta flags.
/// Returns `true` when any filtering ran (i.e. the levels were non-zero).
///
/// The block layout is the encoder's fixed one: `sb_cols` x `sb_rows`
/// 64x64 superblocks, each four 32x32 PARTITION_NONE blocks, coded intra
/// at `ytx` / `uvtx` with skip=0.
pub fn av1_enc_deblock_frame(
  y : FixedArray[Int32],
  y_stride : Int32,
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  uv_stride : Int32,
  width : Int32,
  height : Int32,
  hdr : Av1FrameHeader,
  ytx : Int32,
  uvtx : Int32,
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
  // Levels + filter LUT.
  let lf_level = FixedArray::make(8 * 64 * 64, 0)
  av1_calc_lf_values(lf_level, hdr, FixedArray::make(4, 0))
  let lf_lut = av1_filter_lut_new()
  av1_calc_eih(lf_lut, hdr.loop_filter_sharpness)
  // Masks: one Av1Filter per 64x64 superblock (single tile).
  let masks : Array[Av1Filter] = []
  for _ in 0..<(sb_cols * sb_rows) {
    masks.push(av1_filter_new())
  }
  // Above/left tx-LPF context banks. The decoder's `tx_lpf_y` / `tx_lpf_uv`
  // start at 0 (NOT -1 — that is the separate `tx_intra` bank).
  let a_tx_y = FixedArray::make(32, 0)
  let a_tx_uv = FixedArray::make(32, 0)
  let l_tx_y = FixedArray::make(32, 0)
  let l_tx_uv = FixedArray::make(32, 0)
  let lvl_y = FixedArray::make(4, 0)
  lvl_y[0] = level_at(hdr, 0)
  lvl_y[1] = level_at(hdr, 1)
  lvl_y[2] = level_at(hdr, 2)
  lvl_y[3] = level_at(hdr, 3)
  let sb_pos : Array[(Int32, Int32)] = [(0, 0), (8, 0), (0, 8), (8, 8)]
  for sby in 0..<sb_rows {
    for i in 0..<32 {
      l_tx_y[i] = 0
      l_tx_uv[i] = 0
    }
    let by = sby * 16
    let mask = masks[sby * sb_cols]
    for sb in sb_pos {
      let bx = sb.0
      let yy = sb.1
      av1_mask_edges_intra(mask.fy, yy, bx, 8, 8, ytx, a_tx_y, bx, l_tx_y, yy)
      if has_chroma {
        av1_mask_edges_chroma(
          mask.fuv,
          yy >> ss_v,
          bx >> ss_h,
          (8 + ss_h) >> ss_h,
          (8 + ss_v) >> ss_v,
          false, // skip_inter: our intra blocks are never skip
          uvtx,
          a_tx_uv,
          bx >> ss_h,
          l_tx_uv,
          yy >> ss_v,
          ss_h,
          ss_v,
        )
      }
      // Fill the per-4x4 level cache for this 32x32 block.
      let by_abs = by + yy
      for ly in 0..<8 {
        for lx in 0..<8 {
          let o = ((by_abs + ly) * b4_stride + (bx + lx)) * 4
          lf_level[o + 0] = lvl_y[0]
          lf_level[o + 1] = lvl_y[1]
          lf_level[o + 2] = lvl_y[2]
          lf_level[o + 3] = lvl_y[3]
        }
      }
    }
  }
  // Run the filter, superblock row by superblock row (columns then rows).
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
    // columns
    for x in 0..<sb_cols {
      let mask = masks[sby * sb_cols + x]
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
    // rows
    for x in 0..<sb_cols {
      let mask = masks[sby * sb_cols + x]
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

///|
/// Read one loop-filter level from the header (0 when absent).
fn level_at(hdr : Av1FrameHeader, i : Int32) -> Int32 {
  if i < hdr.loop_filter_level.length() {
    hdr.loop_filter_level[i]
  } else {
    0
  }
}

///|
fn deblock_cols_y(
  dst : FixedArray[Int32],
  stride : Int32,
  b4_stride : Int32,
  lvl : FixedArray[Int32],
  lut : Av1FilterLut,
  bpc : Int32,
  have_left : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  dst_off : Int32,
  w : Int32,
  endy4 : Int32,
) -> Unit {
  let hm = FixedArray::make(3, (0 : UInt32))
  for x in 0..<w {
    if !have_left && x == 0 {
      continue
    }
    // starty4 is always 0 for the encoder's 64x64 superblock rows.
    hm[0] = mask.fy[av1_fy_i(0, x, 0, 0)]
    hm[1] = mask.fy[av1_fy_i(0, x, 1, 0)]
    hm[2] = mask.fy[av1_fy_i(0, x, 2, 0)]
    if endy4 > 16 {
      hm[0] = hm[0] | (mask.fy[av1_fy_i(0, x, 0, 1)] << 16)
      hm[1] = hm[1] | (mask.fy[av1_fy_i(0, x, 1, 1)] << 16)
      hm[2] = hm[2] | (mask.fy[av1_fy_i(0, x, 2, 1)] << 16)
    }
    av1_lf_h_y(
      dst,
      dst_off + x * 4,
      stride,
      hm,
      lvl,
      lvl_off + x * 4,
      b4_stride,
      lut,
      bpc,
    )
  }
}

///|
fn deblock_rows_y(
  dst : FixedArray[Int32],
  stride : Int32,
  b4_stride : Int32,
  lvl : FixedArray[Int32],
  lut : Av1FilterLut,
  bpc : Int32,
  have_top : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  dst_off : Int32,
  w : Int32,
  endy4 : Int32,
) -> Unit {
  let vm = FixedArray::make(4, (0 : UInt32))
  for y in 0..<endy4 {
    if !have_top && y == 0 {
      continue
    }
    vm[0] = mask.fy[av1_fy_i(1, y, 0, 0)] |
      (mask.fy[av1_fy_i(1, y, 0, 1)] << 16)
    vm[1] = mask.fy[av1_fy_i(1, y, 1, 0)] |
      (mask.fy[av1_fy_i(1, y, 1, 1)] << 16)
    vm[2] = mask.fy[av1_fy_i(1, y, 2, 0)] |
      (mask.fy[av1_fy_i(1, y, 2, 1)] << 16)
    av1_lf_v_y(
      dst,
      dst_off + y * 4 * stride,
      stride,
      vm,
      lvl,
      lvl_off + y * b4_stride * 4 + 1,
      b4_stride,
      lut,
      bpc,
    )
  }
  ignore(w)
}

///|
fn deblock_cols_uv(
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  stride : Int32,
  b4_stride : Int32,
  lvl : FixedArray[Int32],
  lut : Av1FilterLut,
  bpc : Int32,
  ss_h : Int32,
  ss_v : Int32,
  have_left : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  u_off : Int32,
  w : Int32,
  endy4 : Int32,
) -> Unit {
  let hm = FixedArray::make(3, (0 : UInt32))
  for x in 0..<w {
    if !have_left && x == 0 {
      continue
    }
    hm[0] = mask.fuv[av1_fuv_i(0, x, 0, 0)]
    hm[1] = mask.fuv[av1_fuv_i(0, x, 1, 0)]
    if endy4 > 16 >> ss_v {
      hm[0] = hm[0] | (mask.fuv[av1_fuv_i(0, x, 0, 1)] << (16 >> ss_v))
      hm[1] = hm[1] | (mask.fuv[av1_fuv_i(0, x, 1, 1)] << (16 >> ss_v))
    }
    av1_lf_h_uv(
      u,
      u_off + x * 4,
      stride,
      hm,
      lvl,
      lvl_off + x * 4 + 2,
      b4_stride,
      lut,
      bpc,
    )
    av1_lf_h_uv(
      v,
      u_off + x * 4,
      stride,
      hm,
      lvl,
      lvl_off + x * 4 + 3,
      b4_stride,
      lut,
      bpc,
    )
  }
  ignore(ss_h)
}

///|
fn deblock_rows_uv(
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  stride : Int32,
  b4_stride : Int32,
  lvl : FixedArray[Int32],
  lut : Av1FilterLut,
  bpc : Int32,
  ss_h : Int32,
  ss_v : Int32,
  have_top : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  u_off : Int32,
  w : Int32,
  endy4 : Int32,
) -> Unit {
  let vm = FixedArray::make(3, (0 : UInt32))
  for y in 0..<endy4 {
    if !have_top && y == 0 {
      continue
    }
    vm[0] = mask.fuv[av1_fuv_i(1, y, 0, 0)] |
      (mask.fuv[av1_fuv_i(1, y, 0, 1)] << (16 >> ss_h))
    vm[1] = mask.fuv[av1_fuv_i(1, y, 1, 0)] |
      (mask.fuv[av1_fuv_i(1, y, 1, 1)] << (16 >> ss_h))
    av1_lf_v_uv(
      u,
      u_off + y * 4 * stride,
      stride,
      vm,
      lvl,
      lvl_off + y * b4_stride * 4 + 2,
      b4_stride,
      lut,
      bpc,
    )
    av1_lf_v_uv(
      v,
      u_off + y * 4 * stride,
      stride,
      vm,
      lvl,
      lvl_off + y * b4_stride * 4 + 3,
      b4_stride,
      lut,
      bpc,
    )
  }
  ignore(w)
  ignore(ss_v)
}
