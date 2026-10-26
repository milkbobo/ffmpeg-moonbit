///|
/// Warp-motion neighbour search and affine derivation: port of dav1d 1.5.1
/// `find_matching_ref` and `derive_warpmv` from `src/decode.c`, operating on
/// the refmvs row ring (`t->rt.r[(by4 & 31) + 5]`).

///|
fn av1_inter_warp_max(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn av1_inter_warp_abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
fn av1_inter_warp_bs_w(b : Av1Rb) -> Int32 {
  av1_block_dimensions[b.bs * 4].to_int()
}

///|
fn av1_inter_warp_bs_h(b : Av1Rb) -> Int32 {
  av1_block_dimensions[b.bs * 4 + 1].to_int()
}

///|
fn av1_inter_warp_ctz(v : UInt32) -> Int32 {
  let mut x = v
  let mut n = 0
  while (x & 1) == 0 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `find_matching_ref`: collect the top/left/top-left/top-right neighbours
/// that use the same single reference. `masks[0]` holds the top run (bit 32
/// = top-right), `masks[1]` the left run (bit 32 = top-left).
pub fn av1_inter_find_matching_ref(
  rows : FixedArray[FixedArray[Av1Rb]],
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  w4 : Int32,
  h4 : Int32,
  have_left : Bool,
  have_top : Bool,
  top_has_right : Bool,
  tile_col_end4 : Int32,
  ref_ : Int32,
) -> (UInt64, UInt64) {
  let r = (by4 & 31) + 5
  let mut masks0 : UInt64 = 0
  let mut masks1 : UInt64 = 0
  let mut count = 0
  let mut have_topleft = have_top && have_left
  let mut have_topright = av1_inter_warp_max(bw4, bh4) < 32 &&
    have_top &&
    bx4 + bw4 < tile_col_end4 &&
    top_has_right
  let matches = (b : Av1Rb) => b.ref0 == ref_ + 1 && b.ref1 == -1
  if have_top {
    let top = rows[r - 1]
    let b0 = top[bx4]
    if matches(b0) {
      masks0 = masks0 | 1UL
      count = 1
    }
    let mut aw4 = av1_inter_warp_bs_w(b0)
    if aw4 >= bw4 {
      let off = bx4 & (aw4 - 1)
      if off != 0 {
        have_topleft = false
      }
      if aw4 - off > bw4 {
        have_topright = false
      }
    } else {
      let mut xidx = bx4
      let mut mask : UInt32 = 1 << aw4
      let mut x = aw4
      while x < w4 {
        xidx = xidx + aw4
        let b = top[xidx]
        if matches(b) {
          masks0 = masks0 | mask.to_uint64()
          count = count + 1
          if count >= 8 {
            return (masks0, masks1)
          }
        }
        aw4 = av1_inter_warp_bs_w(b)
        mask = mask << aw4
        x = x + aw4
      }
    }
  }
  if have_left {
    let b0 = rows[r][bx4 - 1]
    if matches(b0) {
      masks1 = masks1 | 1UL
      count = count + 1
      if count >= 8 {
        return (masks0, masks1)
      }
    }
    let mut lh4 = av1_inter_warp_bs_h(b0)
    if lh4 >= bh4 {
      if (by4 & (lh4 - 1)) != 0 {
        have_topleft = false
      }
    } else {
      let mut yidx = 0
      let mut mask : UInt32 = 1 << lh4
      let mut y = lh4
      while y < h4 {
        yidx = yidx + lh4
        let b = rows[r + yidx][bx4 - 1]
        if matches(b) {
          masks1 = masks1 | mask.to_uint64()
          count = count + 1
          if count >= 8 {
            return (masks0, masks1)
          }
        }
        lh4 = av1_inter_warp_bs_h(b)
        mask = mask << lh4
        y = y + lh4
      }
    }
  }
  if have_topleft && matches(rows[r - 1][bx4 - 1]) {
    masks1 = masks1 | (1UL << 32)
    count = count + 1
    if count >= 8 {
      return (masks0, masks1)
    }
  }
  if have_topright && matches(rows[r - 1][bx4 + bw4]) {
    masks0 = masks0 | (1UL << 32)
  }
  (masks0, masks1)
}

///|
/// Derived warp model for `MM_WARP`.
pub(all) struct Av1WarpDeriveResult {
  typ : Int32
  matrix : FixedArray[Int32]
  alpha : Int32
  beta : Int32
  gamma : Int32
  delta : Int32
}

///|
/// `derive_warpmv`: sample the matching neighbour MVs, keep those within
/// `4 * clip(max(bw4, bh4), 4, 28)` of the block MV, and least-squares fit
/// an affine model. `typ` is 3 (affine) only when the fit and shear checks
/// both pass, otherwise 0 (identity).
pub fn av1_inter_derive_warpmv(
  rows : FixedArray[FixedArray[Av1Rb]],
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  masks0 : UInt64,
  masks1 : UInt64,
  mv : (Int32, Int32),
) -> Av1WarpDeriveResult {
  let r = (by4 & 31) + 5
  let pts = FixedArray::make(8 * 4, 0)
  let np = Ref(0)
  let add = (dx : Int32, dy : Int32, sx : Int32, sy : Int32, b : Av1Rb) => {
    let n = np.val
    let ix = 16 * (2 * dx + sx * av1_inter_warp_bs_w(b)) - 8
    let iy = 16 * (2 * dy + sy * av1_inter_warp_bs_h(b)) - 8
    let (by_mv, bx_mv) = b.mv0
    pts[n * 4] = ix
    pts[n * 4 + 1] = iy
    pts[n * 4 + 2] = ix + bx_mv
    pts[n * 4 + 3] = iy + by_mv
    np.val = n + 1
  }
  if (masks0 & 0xffffffffUL) == 1UL && masks1 >> 32 == 0UL {
    let b = rows[r - 1][bx4]
    let off = bx4 & (av1_inter_warp_bs_w(b) - 1)
    add(-off, 0, 1, -1, b)
  } else {
    let mut off = 0
    let mut xmask = (masks0 & 0xffffffffUL).to_uint()
    while np.val < 8 && xmask != 0 {
      let tz = av1_inter_warp_ctz(xmask)
      off = off + tz
      xmask = xmask >> tz
      add(off, 0, 1, -1, rows[r - 1][bx4 + off])
      xmask = xmask & (xmask - 1)
    }
  }
  if np.val < 8 && masks1 == 1UL {
    let b0 = rows[r][bx4 - 1]
    let off = by4 & (av1_inter_warp_bs_h(b0) - 1)
    add(0, -off, -1, 1, rows[r - off][bx4 - 1])
  } else {
    let mut off = 0
    let mut ymask = (masks1 & 0xffffffffUL).to_uint()
    while np.val < 8 && ymask != 0 {
      let tz = av1_inter_warp_ctz(ymask)
      off = off + tz
      ymask = ymask >> tz
      add(0, off, -1, 1, rows[r + off][bx4 - 1])
      ymask = ymask & (ymask - 1)
    }
  }
  if np.val < 8 && masks1 >> 32 != 0UL {
    add(0, 0, -1, -1, rows[r - 1][bx4 - 1])
  }
  if np.val < 8 && masks0 >> 32 != 0UL {
    add(bw4, 0, 1, -1, rows[r - 1][bx4 + bw4])
  }
  let (mvy, mvx) = mv
  let thresh = 4 * av1_warp_clip(av1_inter_warp_max(bw4, bh4), 4, 28)
  let mvd = FixedArray::make(8, 0)
  let mut ret = 0
  for i in 0..<np.val {
    mvd[i] = av1_inter_warp_abs(pts[i * 4 + 2] - pts[i * 4] - mvx) +
      av1_inter_warp_abs(pts[i * 4 + 3] - pts[i * 4 + 1] - mvy)
    if mvd[i] > thresh {
      mvd[i] = -1
    } else {
      ret = ret + 1
    }
  }
  if ret == 0 {
    ret = 1
  } else {
    let mut i = 0
    let mut j = np.val - 1
    let mut k = 0
    while k < np.val - ret {
      while mvd[i] != -1 {
        i = i + 1
      }
      while mvd[j] == -1 {
        j = j - 1
      }
      if i > j {
        break
      }
      mvd[i] = mvd[j]
      for c in 0..<4 {
        pts[i * 4 + c] = pts[j * 4 + c]
      }
      k = k + 1
      i = i + 1
      j = j - 1
    }
  }
  let wm = av1_warpmv_default()
  let mut typ = 0
  if !av1_warpmv_find_affine_int(pts, ret, bw4, bh4, mv, bx4, by4, wm) {
    if !av1_warpmv_get_shear_params(wm) {
      typ = 3
    }
  }
  {
    typ,
    matrix: wm.matrix,
    alpha: wm.alpha,
    beta: wm.beta,
    gamma: wm.gamma,
    delta: wm.delta,
  }
}
