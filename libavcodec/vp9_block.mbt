///|
/// MoonBit port of the VP9 block layer from FFmpeg 9.0.2
/// `libavcodec/vp9block.c`: partition tree walk (`decode_sb`), block mode
/// syntax (`decode_mode`, keyframe path), coefficient decoding
/// (`decode_coeffs`) and the per-block driver (`ff_vp9_decode_block`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Scope notes: segmentation is fully supported (qmul/filter-level features);
/// inter-frame blocks are rejected (`intra_only`/inter slices are a later
/// slice), so the inter branches of `decode_mode` are not ported yet.  The
/// `counts` statistics are only consumed by probability adaptation, which
/// belongs to the inter-frame slice, and are therefore omitted.

///|
const VP9_BS_8x8 : Int32 = 9

///|
/// `enum BlockLevel`: BL_64X64=0 .. BL_8X8=3. */
const VP9_BL_8X8 : Int32 = 3

///|
/// `enum BlockPartition`. */
const VP9_PARTITION_NONE : Int32 = 0
const VP9_PARTITION_H : Int32 = 1
const VP9_PARTITION_V : Int32 = 2

///|
/// `enum TxfmMode`: TX_4X4=0 .. TX_32X32=3, TX_SWITCHABLE=4. */
const VP9_TX_SWITCHABLE : Int32 = 4

///|
/// Per-block syntax state (`VP9Block`). */
pub struct Vp9Block {
  mut seg_id : Int32
  mut intra : Int32
  mode : FixedArray[Int32]
  mut uvmode : Int32
  mut skip : Int32
  mut bs : Int32
  mut tx : Int32
  mut uvtx : Int32
}

///|
fn vp9_block_new() -> Vp9Block {
  {
    seg_id: 0,
    intra: 1,
    mode: FixedArray::make(4, 0),
    uvmode: 0,
    skip: 0,
    bs: 0,
    tx: 0,
    uvtx: 0,
  }
}

///|
/// `vp89_rac_get_tree` over a flat tree table and a flat probability array. */
fn vp9_rac_get_tree_flat(
  c : Vp9RangeDecoder,
  tree : Array[Int32],
  probs : Array[Int32],
  pbase : Int32,
) -> Int32 {
  let mut i = 0
  while true {
    let bit = vp9_rac_get_prob(c, probs[pbase + i])
    i = tree[i * 2 + bit]
    if i <= 0 {
      break
    }
  }
  -i
}

///|
/// Keyframe y-mode tree walk with `ff_vp9_default_kf_ymode_probs[above][left]`
/// probabilities ([10][10][9] table flattened row-major). */
fn vp9_rac_get_tree_kf_ymode(
  c : Vp9RangeDecoder,
  above : Int32,
  left : Int32,
) -> Int32 {
  let base = (above * 10 + left) * 9
  vp9_rac_get_tree_flat(c, vp9_intramode_tree, vp9_kf_ymode_probs, base)
}

///|
/// `av_clip_uintp2(x, 8)`. */
fn vp9_clip_u8(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// `av_clip_uintp2(x, 6)`. */
fn vp9_clip_u6(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 63 {
    63
  } else {
    v
  }
}

///|
/// `decode_mode`, keyframe/intra-only path (the inter branches of the C are
/// part of a later slice). */
fn Vp9Decoder::decode_mode(self : Vp9Decoder) -> Unit {
  let b = self.b
  let h = self.header
  let row = self.b_row
  let col = self.b_col
  let row7 = row & 7
  // max_tx_for_bl_bp: BS 0..3 -> TX_32X32, 4..6 -> TX_16X16, 7..9 -> TX_8X8,
  // 10..12 -> TX_4X4
  let max_tx = match b.bs {
    bs if bs <= 3 => 3
    bs if bs <= 6 => 2
    bs if bs <= 9 => 1
    _ => 0
  }
  let bwh8 = vp9_bwh8_at(b.bs)
  let bw4 = bwh8[0]
  let bh4 = bwh8[1]
  let have_a = row > 0
  let have_l = col > self.tile_col_start
  // left_ctx / above_ctx LUTs from decode_mode
  let left_ctx_tbl : Array[Int32] = [
    0x0, 0x8, 0x0, 0x8, 0xc, 0x8, 0xc, 0xe, 0xc, 0xe, 0xf, 0xe, 0xf,
  ]
  let above_ctx_tbl : Array[Int32] = [
    0x0, 0x0, 0x8, 0x8, 0x8, 0xc, 0xc, 0xc, 0xe, 0xe, 0xe, 0xf, 0xf,
  ]
  if !h.segmentation.enabled {
    b.seg_id = 0
  } else {
    // keyframes always take the direct branch of the C
    b.seg_id = if !h.segmentation.update_map {
      0
    } else {
      vp9_rac_get_tree_flat(
        self.rac,
        vp9_segmentation_tree,
        vp9_seg_tree_probs(self.header),
        0,
      )
    }
  }
  if h.segmentation.enabled && (h.segmentation.update_map || h.keyframe) {
    self.set_seg_map(row, col, bw4, bh4, b.seg_id)
  }
  b.skip = if h.segmentation.enabled &&
    h.segmentation.features[b.seg_id].skip_enabled {
    1
  } else {
    0
  }
  if b.skip == 0 {
    let cidx = self.left_skip[row7] + self.above_skip[col]
    b.skip = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_SKIP + cidx])
  }
  b.intra = 1
  if (b.intra != 0 || b.skip == 0) && self.tx_mode == VP9_TX_SWITCHABLE {
    let mut cidx = 0
    if have_a {
      if have_l {
        let av = if self.above_skip[col] != 0 {
          max_tx
        } else {
          self.above_txfm[col]
        }
        let lv = if self.left_skip[row7] != 0 {
          max_tx
        } else {
          self.left_txfm[row7]
        }
        cidx = if av + lv > max_tx {
          1
        } else {
          0
        }
      } else {
        cidx = if self.above_skip[col] != 0 {
          1
        } else if self.above_txfm[col] * 2 > max_tx {
          1
        } else {
          0
        }
      }
    } else if have_l {
      cidx = if self.left_skip[row7] != 0 {
        1
      } else if self.left_txfm[row7] * 2 > max_tx {
        1
      } else {
        0
      }
    } else {
      cidx = 1
    }
    match max_tx {
      3 => {
        b.tx = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX32P + cidx * 3])
        if b.tx != 0 {
          b.tx += vp9_rac_get_prob(
            self.rac,
            self.prob[VP9_PC_TX32P + cidx * 3 + 1],
          )
          if b.tx == 2 {
            b.tx += vp9_rac_get_prob(
              self.rac,
              self.prob[VP9_PC_TX32P + cidx * 3 + 2],
            )
          }
        }
      }
      2 => {
        b.tx = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX16P + cidx * 2])
        if b.tx != 0 {
          b.tx += vp9_rac_get_prob(
            self.rac,
            self.prob[VP9_PC_TX16P + cidx * 2 + 1],
          )
        }
      }
      1 => b.tx = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX8P + cidx])
      _ => b.tx = 0
    }
  } else {
    b.tx = vp9_min(max_tx, self.tx_mode)
  }
  // keyframe y-mode + uv-mode
  let amode = self.above_mode
  let lmode = self.left_mode
  let a0 = col * 2
  let l0 = row7 * 2
  if b.bs > VP9_BS_8x8 {
    // sub-8x8 partitions: four modes for the four 4x4 quadrants
    b.mode[0] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0], lmode[l0])
    amode[a0] = b.mode[0]
    if b.bs != 10 {
      // BS_8x4 = 10
      b.mode[1] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0 + 1], b.mode[0])
      lmode[l0] = b.mode[1]
      amode[a0 + 1] = b.mode[1]
    } else {
      lmode[l0] = b.mode[0]
      amode[a0 + 1] = b.mode[0]
      b.mode[1] = b.mode[0]
    }
    if b.bs != 11 {
      // BS_4x8 = 11
      b.mode[2] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0], lmode[l0 + 1])
      amode[a0] = b.mode[2]
      if b.bs != 10 {
        b.mode[3] = vp9_rac_get_tree_kf_ymode(
          self.rac,
          amode[a0 + 1],
          b.mode[2],
        )
        lmode[l0 + 1] = b.mode[3]
        amode[a0 + 1] = b.mode[3]
      } else {
        lmode[l0 + 1] = b.mode[2]
        amode[a0 + 1] = b.mode[2]
        b.mode[3] = b.mode[2]
      }
    } else {
      b.mode[2] = b.mode[0]
      lmode[l0 + 1] = b.mode[1]
      amode[a0 + 1] = b.mode[1]
      b.mode[3] = b.mode[1]
    }
  } else {
    b.mode[0] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0], lmode[l0])
    b.mode[1] = b.mode[0]
    b.mode[2] = b.mode[0]
    b.mode[3] = b.mode[0]
    let aw = vp9_bwh4_at(b.bs)[0]
    let lh = vp9_bwh4_at(b.bs)[1]
    for i in 0..<aw {
      amode[a0 + i] = b.mode[0]
    }
    for i in 0..<lh {
      lmode[l0 + i] = b.mode[0]
    }
  }
  b.uvmode = vp9_rac_get_tree_flat(
    self.rac,
    vp9_intramode_tree,
    vp9_kf_uvmode_probs,
    b.mode[3] * 9,
  )
  // SET_CTXS (keyframe: skip/txfm/partition only)
  let left_ctx_v = left_ctx_tbl[b.bs]
  let above_ctx_v = above_ctx_tbl[b.bs]
  for i in 0..<bw4 {
    self.above_skip[col + i] = b.skip
    self.above_txfm[col + i] = b.tx
    self.above_partition[col + i] = above_ctx_v
  }
  for i in 0..<bh4 {
    self.left_skip[row7 + i] = b.skip
    self.left_txfm[row7 + i] = b.tx
    self.left_partition[row7 + i] = left_ctx_v
  }
}

///|
/// `setctx_2d` on the current frame's segmentation map (8-px units). */
fn Vp9Decoder::set_seg_map(
  self : Vp9Decoder,
  row : Int32,
  col : Int32,
  w : Int32,
  h : Int32,
  v : Int32,
) -> Unit {
  let stride = self.sb_cols * 8
  for y in 0..<h {
    for x in 0..<w {
      self.seg_map[(row + y) * stride + col + x] = v
    }
  }
}



///|
/// int16 truncation (`dctcoef` is int16_t at 8 bpp). */
fn vp9_i16(v : Int32) -> Int32 {
  let w = v & 0xFFFF
  if w >= 0x8000 {
    w - 0x10000
  } else {
    w
  }
}

///|
/// `decode_coeffs_b_generic` for the 8-bit path.  `pbase` points at
/// `prob_coef[tx][pl][inter][0][0][0]` (the [6][6][11] slab); `qmul_dc` /
/// `qmul_ac` are the segmentation qmul pair.  Returns the coefficient
/// position the loop stopped at (0 = empty block). */
fn Vp9Decoder::decode_coeffs_b(
  self : Vp9Decoder,
  coef : FixedArray[Int32],
  cobase : Int32,
  n_coeffs : Int32,
  is_tx32x32 : Bool,
  pbase : Int32,
  nnz0 : Int32,
  scan : Array[Int32],
  nb : Array[Int32],
  qmul_dc : Int32,
  qmul_ac : Int32,
  btx : Int32,
) -> Int32 {
  let counts : FixedArray[Int32] = FixedArray::make(8, 0)
  match btx {
    0 => {
      counts[0] = 1
      counts[1] = 2
      counts[2] = 3
      counts[3] = 4
      counts[4] = 3
      counts[5] = 3
    }
    1 => {
      counts[0] = 1
      counts[1] = 2
      counts[2] = 3
      counts[3] = 4
      counts[4] = 11
      counts[5] = 43
    }
    2 => {
      counts[0] = 1
      counts[1] = 2
      counts[2] = 3
      counts[3] = 4
      counts[4] = 11
      counts[5] = 235
    }
    _ => {
      counts[0] = 1
      counts[1] = 2
      counts[2] = 3
      counts[3] = 4
      counts[4] = 11
      counts[5] = 1003
    }
  }
  let cache = self.cache
  for i in 0..<n_coeffs {
    cache[i] = 0
  }
  let pc = self.prob_coef
  let rac = self.rac
  let mut band = 0
  let mut band_left = counts[0]
  let mut nnz = nnz0
  let mut tp = pbase + nnz * 11
  let mut i = 0
  while true {
    // eob
    let eob_bit = vp9_rac_get_prob(rac, pc[tp])
    if eob_bit == 0 {
      break
    }
    // skip_eob: consume zero runs (no eob re-read between zeros)
    let mut not_zero = false
    while true {
      if vp9_rac_get_prob(rac, pc[tp + 1]) == 0 {
        band_left -= 1
        if band_left == 0 {
          band += 1
          band_left = counts[band]
        }
        cache[scan[i]] = 0
        nnz = (1 + cache[nb[i * 2]] + cache[nb[i * 2 + 1]]) >> 1
        tp = pbase + (band * 66 + nnz * 11)
        i += 1
        if i == n_coeffs {
          return i // invalid input; blocks should end with EOB
        }
      } else {
        not_zero = true
        break
      }
    }
    ignore(not_zero)
    let rc = scan[i]
    let mut val = 0
    if vp9_rac_get_prob(rac, pc[tp + 2]) == 0 {
      // one
      val = 1
      cache[rc] = 1
    } else if vp9_rac_get_prob(rac, pc[tp + 3]) == 0 {
      // 2, 3, 4
      if vp9_rac_get_prob(rac, pc[tp + 4]) == 0 {
        cache[rc] = 2
        val = 2
      } else {
        val = 3 + vp9_rac_get_prob(rac, pc[tp + 5])
        cache[rc] = 3
      }
    } else if vp9_rac_get_prob(rac, pc[tp + 6]) == 0 {
      // cat1/2
      cache[rc] = 4
      if vp9_rac_get_prob(rac, pc[tp + 7]) == 0 {
        val = vp9_rac_get_prob(rac, 159) + 5
      } else {
        val = (vp9_rac_get_prob(rac, 165) << 1) + 7
        val += vp9_rac_get_prob(rac, 145)
      }
    } else {
      // cat 3-6
      cache[rc] = 5
      if vp9_rac_get_prob(rac, pc[tp + 8]) == 0 {
        if vp9_rac_get_prob(rac, pc[tp + 9]) == 0 {
          val = 11 + (vp9_rac_get_prob(rac, 173) << 2)
          val += vp9_rac_get_prob(rac, 148) << 1
          val += vp9_rac_get_prob(rac, 140)
        } else {
          val = 19 + (vp9_rac_get_prob(rac, 176) << 3)
          val += vp9_rac_get_prob(rac, 155) << 2
          val += vp9_rac_get_prob(rac, 140) << 1
          val += vp9_rac_get_prob(rac, 135)
        }
      } else if vp9_rac_get_prob(rac, pc[tp + 10]) == 0 {
        val = (vp9_rac_get_prob(rac, 180) << 4) + 35
        val += vp9_rac_get_prob(rac, 157) << 3
        val += vp9_rac_get_prob(rac, 141) << 2
        val += vp9_rac_get_prob(rac, 134) << 1
        val += vp9_rac_get_prob(rac, 130)
      } else {
        val = 67
        val += vp9_rac_get_prob(rac, 254) << 13
        val += vp9_rac_get_prob(rac, 254) << 12
        val += vp9_rac_get_prob(rac, 254) << 11
        val += vp9_rac_get_prob(rac, 252) << 10
        val += vp9_rac_get_prob(rac, 249) << 9
        val += vp9_rac_get_prob(rac, 243) << 8
        val += vp9_rac_get_prob(rac, 230) << 7
        val += vp9_rac_get_prob(rac, 196) << 6
        val += vp9_rac_get_prob(rac, 177) << 5
        val += vp9_rac_get_prob(rac, 153) << 4
        val += vp9_rac_get_prob(rac, 140) << 3
        val += vp9_rac_get_prob(rac, 133) << 2
        val += vp9_rac_get_prob(rac, 130) << 1
        val += vp9_rac_get_prob(rac, 129)
      }
    }
    band_left -= 1
    if band_left == 0 {
      band += 1
      band_left = counts[band]
    }
    let q = if i != 0 {
      qmul_ac
    } else {
      qmul_dc
    }
    let sign = vp9_rac_get(rac)
    // C multiplies in 32-bit (wrapping) and stores into an int16_t
    let prod = (if sign != 0 {
      0U - val.reinterpret_as_uint()
    } else {
      val.reinterpret_as_uint()
    }) * q.reinterpret_as_uint()
    let mut v = prod.reinterpret_as_int()
    if is_tx32x32 {
      v = v / 2
    }
    coef[cobase + rc] = vp9_i16(v)
    nnz = (1 + cache[nb[i * 2]] + cache[nb[i * 2 + 1]]) >> 1
    tp = pbase + (band * 66 + nnz * 11)
    i += 1
    if i >= n_coeffs {
      break
    }
  }
  i
}

///|
/// Scan-table selection (`ff_vp9_scans[kind][txtp]`): returns the scan and
/// neighbour-LUT tables.  Index 4 of the C table is the lossless WHT which
/// reuses `default_scan_4x4`. */
fn vp9_scan_for(kind : Int32, txtp : Int32) -> (Array[Int32], Array[Int32]) {
  let t = txtp & 3
  match kind {
    0 =>
      // 4x4: default / col / row / default
      match t {
        1 => (vp9_col_scan_4x4, vp9_col_scan_4x4_nb)
        2 => (vp9_row_scan_4x4, vp9_row_scan_4x4_nb)
        _ => (vp9_default_scan_4x4, vp9_default_scan_4x4_nb)
      }
    1 =>
      match t {
        1 => (vp9_col_scan_8x8, vp9_col_scan_8x8_nb)
        2 => (vp9_row_scan_8x8, vp9_row_scan_8x8_nb)
        _ => (vp9_default_scan_8x8, vp9_default_scan_8x8_nb)
      }
    2 =>
      match t {
        1 => (vp9_col_scan_16x16, vp9_col_scan_16x16_nb)
        2 => (vp9_row_scan_16x16, vp9_row_scan_16x16_nb)
        _ => (vp9_default_scan_16x16, vp9_default_scan_16x16_nb)
      }
    3 => (vp9_default_scan_32x32, vp9_default_scan_32x32_nb)
    _ => (vp9_default_scan_4x4, vp9_default_scan_4x4_nb)
  }
}

///|
/// OR-merge the above/left nnz contexts per TU group (`MERGE`): `base` is
/// the block's first slot (the C offsets the pointer), `end` the relative
/// length. */
fn vp9_merge_ctx(arr : FixedArray[Int32], base : Int32, end : Int32, step : Int32) -> Unit {
  let mut n = 0
  while n < end {
    let mut v = 0
    for k in 0..<step {
      v = v | arr[base + n + k]
    }
    arr[base + n] = if v != 0 {
      1
    } else {
      0
    }
    n += step
  }
}

///|
/// Splat the group leader nnz flag over its TU group (`SPLAT`): `base` is
/// the block's first slot, `end` the relative length. */
fn vp9_splat_ctx(arr : FixedArray[Int32], base : Int32, end : Int32, step : Int32) -> Unit {
  if step == 2 {
    let mut n = 1
    while n < end {
      arr[base + n] = arr[base + n - 1]
      n += 2
    }
  } else {
    let mut n = 0
    while n < end {
      let v = arr[base + n]
      let m = vp9_min(end - n - 1, step - 1)
      for k in 1..=m {
        arr[base + n + k] = v
      }
      n += step
    }
  }
}

///|
/// `decode_coeffs` (8 bpp): the y and uv TU coefficient loops.
/// `tx_kind` = 4*lossless + tx selects the scan tables. */
fn Vp9Decoder::decode_coeffs(self : Vp9Decoder) -> Int32 {
  let b = self.b
  let w4 = vp9_bwh8_at(b.bs)[0] << 1
  let h4 = vp9_bwh8_at(b.bs)[1] << 1
  let end_x = vp9_min(2 * (self.cols - self.b_col), w4)
  let end_y = vp9_min(2 * (self.rows - self.b_row), h4)
  let tx_kind = 4 * self.lossless() + b.tx
  let inter = 0 // keyframes only in this slice
  let p_y = vp9_coef_base(b.tx, 0, inter)
  let qmul0 = self.seg_qmul[b.seg_id * 4]
  let qmul1 = self.seg_qmul[b.seg_id * 4 + 1]
  let mut total_coeff = 0
  let step = 1 << b.tx
  let a = self.above_y_nnz
  let l = self.left_y_nnz
  let aoff = self.b_col * 2
  let loff = (self.b_row & 7) * 2
  if step >= 2 {
    vp9_merge_ctx(l, loff, end_y, step)
    vp9_merge_ctx(a, aoff, end_x, step)
  }
  let mut n = 0
  let mut y = 0
  while y < end_y {
    let mut x = 0
    while x < end_x {
      let mode_idx = if b.bs > VP9_BS_8x8 && b.tx == 0 {
        n
      } else {
        0
      }
      let txtp = vp9_intra_txfm_type[b.mode[mode_idx]]
      let pair = vp9_scan_for(tx_kind, txtp)
      let ret = self.decode_coeffs_b(
        self.block,
        16 * n,
        16 * step * step,
        b.tx == 3,
        p_y,
        a[aoff + x] + l[loff + y],
        pair.0,
        pair.1,
        qmul0,
        qmul1,
        b.tx,
      )
      let nz = if ret != 0 {
        1
      } else {
        0
      }
      a[aoff + x] = nz
      l[loff + y] = nz
      total_coeff = total_coeff | nz
      self.eob[n] = ret
      n += step * step
      x += step
    }
    y += step
  }
  if step >= 2 {
    vp9_splat_ctx(l, loff, end_y, step)
    vp9_splat_ctx(a, aoff, end_x, step)
  }
  // uv tokens
  let uvtx = b.uvtx
  let p_uv = vp9_coef_base(uvtx, 1, inter)
  let qmul2 = self.seg_qmul[b.seg_id * 4 + 2]
  let qmul3 = self.seg_qmul[b.seg_id * 4 + 3]
  let uvpair = vp9_scan_for(uvtx, 0)
  let uend_x = end_x >> self.ss_h
  let uend_y = end_y >> self.ss_v
  let ustep = 1 << uvtx
  for pl in 0..<2 {
    let ua = self.above_uv_nnz[pl]
    let ul = self.left_uv_nnz[pl]
    let uaoff = self.b_col << (1 - self.ss_h)
    let uloff = (self.b_row & 7) << (1 - self.ss_v)
    let ublock = if pl == 0 {
      self.uvblock0
    } else {
      self.uvblock1
    }
    let ueob = if pl == 0 {
      self.uveob0
    } else {
      self.uveob1
    }
    if ustep >= 2 {
      vp9_merge_ctx(ul, uloff, uend_y, ustep)
      vp9_merge_ctx(ua, uaoff, uend_x, ustep)
    }
    let mut n = 0
    let mut y = 0
    while y < uend_y {
      let mut x = 0
      while x < uend_x {
        let ret = self.decode_coeffs_b(
          ublock,
          16 * n,
          16 * ustep * ustep,
          uvtx == 3,
          p_uv,
          ua[uaoff + x] + ul[uloff + y],
          uvpair.0,
          uvpair.1,
          qmul2,
          qmul3,
          uvtx,
        )
        let nz = if ret != 0 {
          1
        } else {
          0
        }
        ua[uaoff + x] = nz
        ul[uloff + y] = nz
        total_coeff = total_coeff | nz
        ueob[n] = ret
        n += ustep * ustep
        x += ustep
      }
      y += ustep
    }
    if ustep >= 2 {
      vp9_splat_ctx(ul, uloff, uend_y, ustep)
      vp9_splat_ctx(ua, uaoff, uend_x, ustep)
    }
  }
  total_coeff
}
///|
/// `decode_sb`: partition tree recursion over one superblock position. */
fn Vp9Decoder::decode_sb(
  self : Vp9Decoder,
  row : Int32,
  col : Int32,
  lflvl_idx : Int32,
  yoff : Int32,
  uvoff : Int32,
  bl : Int32,
) -> Unit {
  let c = ((self.above_partition[col] >> (3 - bl)) & 1) |
    (((self.left_partition[row & 7] >> (3 - bl)) & 1) << 1)
  let pbase = (bl * 4 + c) * 3
  let hbs = 4 >> bl
  if bl == VP9_BL_8X8 {
    let bp = vp9_rac_get_tree_flat(
      self.rac,
      vp9_partition_tree,
      vp9_kf_partition_probs,
      pbase,
    )
    self.decode_block(row, col, lflvl_idx, yoff, uvoff, bl, bp)
  } else if col + hbs < self.cols {
    if row + hbs < self.rows {
      let bp = vp9_rac_get_tree_flat(
        self.rac,
        vp9_partition_tree,
        vp9_kf_partition_probs,
        pbase,
      )
      if bp == VP9_PARTITION_NONE {
        self.decode_block(row, col, lflvl_idx, yoff, uvoff, bl, bp)
      } else if bp == VP9_PARTITION_H {
        self.decode_block(row, col, lflvl_idx, yoff, uvoff, bl, bp)
        let yoff2 = yoff + (hbs * 8 * self.ystride)
        let uvoff2 = uvoff + ((hbs * 8 * self.uvstride) >> self.ss_v)
        self.decode_block(row + hbs, col, lflvl_idx, yoff2, uvoff2, bl, bp)
      } else if bp == VP9_PARTITION_V {
        self.decode_block(row, col, lflvl_idx, yoff, uvoff, bl, bp)
        let yoff2 = yoff + (hbs * 8)
        let uvoff2 = uvoff + ((hbs * 8) >> self.ss_h)
        self.decode_block(row, col + hbs, lflvl_idx, yoff2, uvoff2, bl, bp)
      } else {
        self.decode_sb(row, col, lflvl_idx, yoff, uvoff, bl + 1)
        self.decode_sb(
          row,
          col + hbs,
          lflvl_idx,
          yoff + (hbs * 8),
          uvoff + ((hbs * 8) >> self.ss_h),
          bl + 1,
        )
        let yoff2 = yoff + (hbs * 8 * self.ystride)
        let uvoff2 = uvoff + ((hbs * 8 * self.uvstride) >> self.ss_v)
        self.decode_sb(row + hbs, col, lflvl_idx, yoff2, uvoff2, bl + 1)
        self.decode_sb(
          row + hbs,
          col + hbs,
          lflvl_idx,
          yoff2 + (hbs * 8),
          uvoff2 + ((hbs * 8) >> self.ss_h),
          bl + 1,
        )
      }
    } else if vp9_rac_get_prob(self.rac, vp9_kf_partition_probs[pbase + 1]) != 0 {
      self.decode_sb(row, col, lflvl_idx, yoff, uvoff, bl + 1)
      self.decode_sb(
        row,
        col + hbs,
        lflvl_idx,
        yoff + (hbs * 8),
        uvoff + ((hbs * 8) >> self.ss_h),
        bl + 1,
      )
    } else {
      self.decode_block(row, col, lflvl_idx, yoff, uvoff, bl, VP9_PARTITION_H)
    }
  } else if row + hbs < self.rows {
    if vp9_rac_get_prob(self.rac, vp9_kf_partition_probs[pbase + 2]) != 0 {
      self.decode_sb(row, col, lflvl_idx, yoff, uvoff, bl + 1)
      self.decode_sb(
        row + hbs,
        col,
        lflvl_idx,
        yoff + (hbs * 8 * self.ystride),
        uvoff + ((hbs * 8 * self.uvstride) >> self.ss_v),
        bl + 1,
      )
    } else {
      self.decode_block(row, col, lflvl_idx, yoff, uvoff, bl, VP9_PARTITION_V)
    }
  } else {
    self.decode_sb(row, col, lflvl_idx, yoff, uvoff, bl + 1)
  }
}


///|
/// `ff_vp9_decode_block` (single-pass, keyframe slice). */
fn Vp9Decoder::decode_block(
  self : Vp9Decoder,
  row : Int32,
  col : Int32,
  lflvl_idx : Int32,
  yoff : Int32,
  uvoff : Int32,
  bl : Int32,
  bp : Int32,
) -> Unit {
  let b = self.b
  let bs = bl * 3 + bp
  let bwh8 = vp9_bwh8_at(bs)
  let w4 = bwh8[0]
  let h4 = bwh8[1]
  self.b_row = row
  self.b_col = col
  b.bs = bs
  self.decode_mode()
  b.uvtx = b.tx - (if (self.ss_h != 0 && w4 * 2 == (1 << b.tx)) ||
    (self.ss_v != 0 && h4 * 2 == (1 << b.tx)) {
    1
  } else {
    0
  })
  if b.uvtx < 0 {
    b.uvtx = 0
  }
  if b.skip == 0 {
    let _has_coeffs = self.decode_coeffs()
  } else {
    let row7 = row & 7
    let a0 = col * 2
    let l0 = row7 * 2
    let ubase = col << (1 - self.ss_h)
    let lbase = row7 << (1 - self.ss_v)
    let uw = w4 << (1 - self.ss_h)
    let uh = h4 << (1 - self.ss_v)
    for i in 0..<(w4 * 2) {
      self.above_y_nnz[a0 + i] = 0
    }
    for pl in 0..<2 {
      for i in 0..<uw {
        self.above_uv_nnz[pl][ubase + i] = 0
      }
    }
    for i in 0..<(h4 * 2) {
      self.left_y_nnz[l0 + i] = 0
    }
    for pl in 0..<2 {
      for i in 0..<uh {
        self.left_uv_nnz[pl][lbase + i] = 0
      }
    }
  }
  self.intra_recon(yoff, uvoff)
  // pick filter level and mark edges to filter (keyframes: intra row 0)
  if self.filter_level() > 0 {
    let lvl = self.seg_lflvl[b.seg_id * 8]
    if lvl > 0 {
      for y in 0..<h4 {
        for x in 0..<w4 {
          self.lf_level[lflvl_idx * 64 + ((row & 7) + y) * 8 + (col & 7) + x] = lvl
        }
      }
      let x_end = vp9_min(self.cols - col, w4)
      let y_end = vp9_min(self.rows - row, h4)
      self.mask_edges(lflvl_idx, 0, 0, 0, (row & 7), (col & 7), x_end, y_end, 0, 0, b.tx, 0)
      if self.ss_h != 0 || self.ss_v != 0 {
        let col_end = if (self.cols & 1) != 0 && col + w4 >= self.cols {
          self.cols & 7
        } else {
          0
        }
        let row_end = if (self.rows & 1) != 0 && row + h4 >= self.rows {
          self.rows & 7
        } else {
          0
        }
        self.mask_edges(
          lflvl_idx,
          1,
          self.ss_h,
          self.ss_v,
          (row & 7),
          (col & 7),
          x_end,
          y_end,
          col_end,
          row_end,
          b.uvtx,
          0,
        )
      }
    }
  }
}
