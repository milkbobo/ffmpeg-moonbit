///|
/// Reference MV construction: port of dav1d 1.5.1 `src/refmvs.c`
/// (`dav1d_refmvs_find` and helpers) plus `get_gmv_2d`/`fix_mv_precision`
/// from `src/env.h`. MVs are (y, x) in 1/8-pel units; the invalid marker
/// is dav1d's `INVALID_MV`.

///|
/// dav1d `INVALID_MV` as a (y, x) pair.
let av1_rmv_invalid : (Int, Int) = (0x8000, 0x8000)

///|
fn av1_rmv_is_invalid(mv : (Int, Int)) -> Bool {
  mv is (0x8000, 0x8000)
}

///|
fn av1_rmv_clip(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// `apply_sign` from dav1d intops.h.
fn av1_rmv_apply_sign(v : Int, sign : Int) -> Int {
  if sign < 0 { -v } else { v }
}

///|
/// `fix_int_mv_precision` (`x - (x >> 15)` emulates the unsigned
/// rounding of the int16 storage).
fn av1_rmv_fix_int(mv : (Int, Int)) -> (Int, Int) {
  let (y, x) = mv
  ((y - (y >> 15) + 3) & -8, (x - (x >> 15) + 3) & -8)
}

///|
/// `fix_mv_precision`.
fn av1_rmv_fix_precision(
  mv : (Int, Int),
  force_integer_mv : Bool,
  hp : Bool,
) -> (Int, Int) {
  let (y, x) = mv
  if force_integer_mv {
    av1_rmv_fix_int(mv)
  } else if !hp {
    ((y - (y >> 15)) & -2, (x - (x >> 15)) & -2)
  } else {
    mv
  }
}

///|
/// `mv_projection` (AV1 spec 7.9.3 rounding).
let av1_rmv_div_mult : FixedArray[Int] = [
  0, 16384, 8192, 5461, 4096, 3276, 2730, 2340, 2048, 1820, 1638, 1489,
  1365, 1260, 1170, 1092, 1024, 963, 910, 862, 819, 780, 744, 712, 682,
  655, 630, 606, 585, 564, 546, 528,
]

///|
fn av1_rmv_projection(
  mv : (Int, Int),
  num : Int,
  den : Int,
) -> (Int, Int) {
  let frac = num * av1_rmv_div_mult[den]
  let (yv, xv) = mv
  let yy = yv * frac
  let xx = xv * frac
  (
    av1_rmv_clip((yy + 8192 + (yy >> 31)) >> 14, -0x3fff, 0x3fff),
    av1_rmv_clip((xx + 8192 + (xx >> 31)) >> 14, -0x3fff, 0x3fff),
  )
}

///|
/// `get_gmv_2d`: block-center global MV. `gm_type` is dav1d
/// Dav1dWarpedMotionType (0 identity, 1 translation, 2 rot-zoom,
/// 3 affine).
fn av1_rmv_get_gmv_2d(
  gm_type : Int,
  mat : FixedArray[Int],
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  hp : Bool,
  force_integer_mv : Bool,
) -> (Int, Int) {
  if gm_type == 0 {
    return (0, 0)
  }
  if gm_type == 1 {
    let res = (mat[0] >> 13, mat[1] >> 13)
    if force_integer_mv {
      return av1_rmv_fix_int(res)
    }
    return res
  }
  let x = bx4 * 4 + bw4 * 2 - 1
  let y = by4 * 4 + bh4 * 2 - 1
  let xc = (mat[2] - 65536) * x + mat[3] * y + mat[0]
  let yc = (mat[5] - 65536) * y + mat[4] * x + mat[1]
  let shift = 16 - (3 - (if hp { 0 } else { 1 }))
  let round = 1 << (shift - 1)
  let no_hp = if hp { 0 } else { 1 }
  let abs_yc = if yc < 0 { -yc } else { yc }
  let abs_xc = if xc < 0 { -xc } else { xc }
  let res = (
    av1_rmv_apply_sign(((abs_yc + round) >> shift) << no_hp, yc),
    av1_rmv_apply_sign(((abs_xc + round) >> shift) << no_hp, xc),
  )
  if force_integer_mv {
    return av1_rmv_fix_int(res)
  }
  res
}

///|
/// dav1d `refmvs_block` (spatial context on the 4x4 grid).
pub(all) struct Av1Rb {
  ref0 : Int // 0 = none, 1..7 = refidx+1
  ref1 : Int // -1 = single-ref block, 0 = none, 1..7
  bs : Int
  mf : Int // bit0: globalmv variant, bit1: newmv
  mv0 : (Int, Int)
  mv1 : (Int, Int)
}

///|
/// dav1d `refmvs_temporal_block`.
pub(all) struct Av1Rtb {
  mv : (Int, Int)
  ref_ : Int // 0 = invalid
}

///|
/// dav1d `refmvs_candidate`.
pub(all) struct Av1Rcand {
  mut mv0 : (Int, Int)
  mut mv1 : (Int, Int)
  mut weight : Int
}

///|
/// Frame-level parameters of `refmvs_frame` consumed by find().
pub(all) struct Av1Rf {
  iw4 : Int
  ih4 : Int
  sign_bias : FixedArray[Int] // [7], 0/1
  pocdiff : FixedArray[Int] // [7]
  hp : Bool
  force_integer_mv : Bool
  use_ref_frame_mvs : Bool
  gm_types : FixedArray[Int] // [7]
  gm_matrices : FixedArray[FixedArray[Int]] // [7][6]
}

///|
fn av1_rmv_add_spatial(
  stack : FixedArray[Av1Rcand],
  cnt : Ref[Int],
  weight : Int,
  b : Av1Rb,
  ref0 : Int,
  ref1 : Int,
  gmv0 : (Int, Int),
  gmv1 : (Int, Int),
  have_newmv_match : Ref[Bool],
  have_refmv_match : Ref[Bool],
) -> Unit {
  if av1_rmv_is_invalid(b.mv0) {
    return // intra block
  }
  if ref1 == -1 {
    for n in 0..<2 {
      let bref = if n == 0 { b.ref0 } else { b.ref1 }
      if bref == ref0 {
        let bmv = if n == 0 { b.mv0 } else { b.mv1 }
        let cand_mv = if (b.mf & 1) != 0 && !av1_rmv_is_invalid(gmv0) {
          gmv0
        } else {
          bmv
        }
        have_refmv_match.val = true
        have_newmv_match.val = have_newmv_match.val || ((b.mf >> 1) != 0)
        let last = cnt.val
        for m in 0..<last {
          if stack[m].mv0 == cand_mv {
            stack[m].weight = stack[m].weight + weight
            return
          }
        }
        if last < 8 {
          stack[last] = { mv0: cand_mv, mv1: (0, 0), weight }
          cnt.val = last + 1
        }
        return
      }
    }
  } else if b.ref0 == ref0 && b.ref1 == ref1 {
    let cand0 = if (b.mf & 1) != 0 && !av1_rmv_is_invalid(gmv0) {
      gmv0
    } else {
      b.mv0
    }
    let cand1 = if (b.mf & 1) != 0 && !av1_rmv_is_invalid(gmv1) {
      gmv1
    } else {
      b.mv1
    }
    have_refmv_match.val = true
    have_newmv_match.val = have_newmv_match.val || ((b.mf >> 1) != 0)
    let last = cnt.val
    for n in 0..<last {
      if stack[n].mv0 == cand0 && stack[n].mv1 == cand1 {
        stack[n].weight = stack[n].weight + weight
        return
      }
    }
    if last < 8 {
      stack[last] = { mv0: cand0, mv1: cand1, weight }
      cnt.val = last + 1
    }
  }
}

///|
/// `scan_row`: scans the row above the block; `row` is that absolute row.
/// Returns `weight >> 1` (or 1 in the multi-block path).
fn av1_rmv_scan_row(
  stack : FixedArray[Av1Rcand],
  cnt : Ref[Int],
  ref0 : Int,
  ref1 : Int,
  gmv0 : (Int, Int),
  gmv1 : (Int, Int),
  row : FixedArray[Av1Rb],
  bx4 : Int,
  bw4 : Int,
  w4 : Int,
  max_rows : Int,
  step : Int,
  have_newmv_match : Ref[Bool],
  have_refmv_match : Ref[Bool],
) -> Int {
  let first_bs = row[bx4].bs
  let cand_bw4 = av1_block_dimensions[first_bs * 4].to_int()
  let inner = if bw4 < cand_bw4 { bw4 } else { cand_bw4 }
  let len = if step > inner { step } else { inner }
  if bw4 <= cand_bw4 {
    let dim1 = av1_block_dimensions[first_bs * 4 + 1].to_int()
    let m = 2 * max_rows
    let weight = if bw4 == 1 {
      2
    } else {
      let a = if dim1 < 2 { 2 } else { dim1 }
      let b = if m < 2 { 2 } else { m }
      if a < b { a } else { b }
    }
    av1_rmv_add_spatial(
      stack, cnt, len * weight, row[bx4], ref0, ref1, gmv0, gmv1,
      have_newmv_match, have_refmv_match,
    )
    return weight >> 1
  }
  let mut x = 0
  let mut cbw = cand_bw4
  let mut l = len
  for ;; {
    av1_rmv_add_spatial(
      stack, cnt, l * 2, row[bx4 + x], ref0, ref1, gmv0, gmv1,
      have_newmv_match, have_refmv_match,
    )
    x = x + l
    if x >= w4 {
      return 1
    }
    cbw = av1_block_dimensions[row[bx4 + x].bs * 4].to_int()
    l = if step > cbw { step } else { cbw }
  }
}

///|
/// `scan_col`: scans the column left of the block via absolute row index.
fn av1_rmv_scan_col(
  stack : FixedArray[Av1Rcand],
  cnt : Ref[Int],
  ref0 : Int,
  ref1 : Int,
  gmv0 : (Int, Int),
  gmv1 : (Int, Int),
  rows : FixedArray[FixedArray[Av1Rb]],
  row_start : Int,
  bx4 : Int,
  bh4 : Int,
  h4 : Int,
  max_cols : Int,
  step : Int,
  have_newmv_match : Ref[Bool],
  have_refmv_match : Ref[Bool],
) -> Int {
  let first_bs = rows[row_start][bx4].bs
  let cand_bh4 = av1_block_dimensions[first_bs * 4 + 1].to_int()
  let inner = if bh4 < cand_bh4 { bh4 } else { cand_bh4 }
  let len = if step > inner { step } else { inner }
  if bh4 <= cand_bh4 {
    let dim0 = av1_block_dimensions[first_bs * 4].to_int()
    let m = 2 * max_cols
    let weight = if bh4 == 1 {
      2
    } else {
      let a = if dim0 < 2 { 2 } else { dim0 }
      let b = if m < 2 { 2 } else { m }
      if a < b { a } else { b }
    }
    av1_rmv_add_spatial(
      stack, cnt, len * weight, rows[row_start][bx4], ref0, ref1, gmv0,
      gmv1, have_newmv_match, have_refmv_match,
    )
    return weight >> 1
  }
  let mut y = 0
  let mut cbh = cand_bh4
  let mut l = len
  for ;; {
    av1_rmv_add_spatial(
      stack, cnt, l * 2, rows[row_start + y][bx4], ref0, ref1, gmv0, gmv1,
      have_newmv_match, have_refmv_match,
    )
    y = y + l
    if y >= h4 {
      return 1
    }
    cbh = av1_block_dimensions[rows[row_start + y][bx4].bs * 4 + 1].to_int()
    l = if step > cbh { step } else { cbh }
  }
}

///|
/// `add_temporal_candidate`; `globalmv_ctx` is only probed at (0,0).
fn av1_rmv_add_temporal(
  rf : Av1Rf,
  stack : FixedArray[Av1Rcand],
  cnt : Ref[Int],
  rb : Av1Rtb,
  ref0 : Int,
  ref1 : Int,
  gmv0 : (Int, Int),
  globalmv_ctx : Ref[Int]?,
) -> Unit {
  if av1_rmv_is_invalid(rb.mv) {
    return
  }
  let mv = av1_rmv_fix_precision(
    av1_rmv_projection(rb.mv, rf.pocdiff[ref0 - 1], rb.ref_),
    rf.force_integer_mv,
    rf.hp,
  )
  let last = cnt.val
  if ref1 == -1 {
    if globalmv_ctx is Some(g) {
      let (gy, gx) = gmv0
      let (my, mx) = mv
      let dy = if my - gy < 0 { -(my - gy) } else { my - gy }
      let dx = if mx - gx < 0 { -(mx - gx) } else { mx - gx }
      g.val = if dy >= 16 || dx >= 16 { 1 } else { 0 }
    }
    for n in 0..<last {
      if stack[n].mv0 == mv {
        stack[n].weight = stack[n].weight + 2
        return
      }
    }
    if last < 8 {
      stack[last] = { mv0: mv, mv1: (0, 0), weight: 2 }
      cnt.val = last + 1
    }
  } else {
    let mv_p1 = av1_rmv_fix_precision(
      av1_rmv_projection(rb.mv, rf.pocdiff[ref1 - 1], rb.ref_),
      rf.force_integer_mv,
      rf.hp,
    )
    for n in 0..<last {
      if stack[n].mv0 == mv && stack[n].mv1 == mv_p1 {
        stack[n].weight = stack[n].weight + 2
        return
      }
    }
    if last < 8 {
      stack[last] = { mv0: mv, mv1: mv_p1, weight: 2 }
      cnt.val = last + 1
    }
  }
}

///|
/// `add_compound_extended_candidate`: fills `same[0..3]` (same0, same1,
/// diff0, diff1) with counts in `same_count[0..3]`.
fn av1_rmv_add_compound_extended(
  stack : FixedArray[Av1Rcand],
  same_base : Int,
  same_count : FixedArray[Int],
  cand_b : Av1Rb,
  sign0 : Int,
  sign1 : Int,
  ref0 : Int,
  ref1 : Int,
  sign_bias : FixedArray[Int],
) -> Unit {
  for n in 0..<2 {
    let cand_ref = if n == 0 { cand_b.ref0 } else { cand_b.ref1 }
    if cand_ref <= 0 {
      break
    }
    let cand_mv = if n == 0 { cand_b.mv0 } else { cand_b.mv1 }
    if cand_ref == ref0 {
      if same_count[0] < 2 {
        stack[same_base + same_count[0]].mv0 = cand_mv
        same_count[0] = same_count[0] + 1
      }
      if same_count[3] < 2 {
        let m = if (sign1 ^ sign_bias[cand_ref - 1]) != 0 {
          (-cand_mv.0, -cand_mv.1)
        } else {
          cand_mv
        }
        stack[same_base + 2 + same_count[3]].mv1 = m
        same_count[3] = same_count[3] + 1
      }
    } else if cand_ref == ref1 {
      if same_count[1] < 2 {
        stack[same_base + same_count[1]].mv1 = cand_mv
        same_count[1] = same_count[1] + 1
      }
      if same_count[2] < 2 {
        let m = if (sign0 ^ sign_bias[cand_ref - 1]) != 0 {
          (-cand_mv.0, -cand_mv.1)
        } else {
          cand_mv
        }
        stack[same_base + 2 + same_count[2]].mv0 = m
        same_count[2] = same_count[2] + 1
      }
    } else {
      let i_cand_mv = (-cand_mv.0, -cand_mv.1)
      if same_count[2] < 2 {
        stack[same_base + 2 + same_count[2]].mv0 = if (sign0 ^ sign_bias[cand_ref - 1]) != 0 {
          i_cand_mv
        } else {
          cand_mv
        }
        same_count[2] = same_count[2] + 1
      }
      if same_count[3] < 2 {
        stack[same_base + 2 + same_count[3]].mv1 = if (sign1 ^ sign_bias[cand_ref - 1]) != 0 {
          i_cand_mv
        } else {
          cand_mv
        }
        same_count[3] = same_count[3] + 1
      }
    }
  }
}

///|
/// `add_single_extended_candidate`.
fn av1_rmv_add_single_extended(
  stack : FixedArray[Av1Rcand],
  cnt : Ref[Int],
  cand_b : Av1Rb,
  sign : Int,
  sign_bias : FixedArray[Int],
) -> Unit {
  for n in 0..<2 {
    let cand_ref = if n == 0 { cand_b.ref0 } else { cand_b.ref1 }
    if cand_ref <= 0 {
      break
    }
    let mut cand_mv = if n == 0 { cand_b.mv0 } else { cand_b.mv1 }
    if (sign ^ sign_bias[cand_ref - 1]) != 0 {
      cand_mv = (-cand_mv.0, -cand_mv.1)
    }
    let last = cnt.val
    let mut m = 0
    while m < last {
      if cand_mv == stack[m].mv0 {
        break
      }
      m = m + 1
    }
    if m == last {
      stack[m] = { mv0: cand_mv, mv1: (0, 0), weight: 2 }
      cnt.val = last + 1
    }
  }
}

///|
/// Result of `av1_refmvs_find`.
pub struct Av1RefmvsResult {
  cands : FixedArray[Av1Rcand]
  cnt : Int
  ctx : Int
}

///|
/// MV pair of candidate `n` (requires `n < cnt`).
pub fn Av1RefmvsResult::candidate(
  self : Av1RefmvsResult,
  n : Int,
) -> ((Int, Int), (Int, Int)) {
  (self.cands[n].mv0, self.cands[n].mv1)
}

///|
/// Sorting weight of candidate `n` (diagnostics).
pub fn Av1RefmvsResult::candidate_weight(
  self : Av1RefmvsResult,
  n : Int,
) -> Int {
  self.cands[n].weight
}

///|
/// `dav1d_refmvs_find`. `rows` is the 37-row spatial context buffer
/// (dav1d `rt->r`, absolute indices 0..36; the current sbrow's main area
/// starts at `(by4 & 31) + 5`). `rp` is the 16×`rp_stride` temporal
/// projection buffer for this sbrow (row `y` at `((by8 & 15)) * stride`).
pub fn av1_refmvs_find(
  rf : Av1Rf,
  rows : FixedArray[FixedArray[Av1Rb]],
  rp : FixedArray[Av1Rtb],
  rp_stride : Int,
  tile_col_start4 : Int,
  tile_col_end4 : Int,
  tile_row_start4 : Int,
  tile_row_end4 : Int,
  ref0 : Int,
  ref1 : Int,
  bs : Int,
  top_has_right : Bool,
  by4 : Int,
  bx4 : Int,
  initial_globalmv_ctx? : Int = 0,
) -> Av1RefmvsResult {
  let bw4 = av1_block_dimensions[bs * 4].to_int()
  let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
  let w4 = if bw4 < 16 {
    if bw4 < tile_col_end4 - bx4 { bw4 } else { tile_col_end4 - bx4 }
  } else if tile_col_end4 - bx4 < 16 {
    tile_col_end4 - bx4
  } else {
    16
  }
  let h4 = if bh4 < 16 {
    if bh4 < tile_row_end4 - by4 { bh4 } else { tile_row_end4 - by4 }
  } else if tile_row_end4 - by4 < 16 {
    tile_row_end4 - by4
  } else {
    16
  }
  let stack : FixedArray[Av1Rcand] = FixedArray::makei(
    8,
    _ => { mv0: (0, 0), mv1: (0, 0), weight: 0 },
  )
  let cnt = Ref(0)
  let have_newmv = Ref(false)
  let have_row_mvs = Ref(false)
  let have_col_mvs = Ref(false)
  let mut gmv0 = av1_rmv_invalid
  let mut gmv1 = av1_rmv_invalid
  let mut tgmv0 = (0, 0)
  let mut tgmv1 = (0, 0)
  if ref0 > 0 {
    tgmv0 = av1_rmv_get_gmv_2d(
      rf.gm_types[ref0 - 1], rf.gm_matrices[ref0 - 1], bx4, by4, bw4, bh4,
      rf.hp, rf.force_integer_mv,
    )
    gmv0 = if rf.gm_types[ref0 - 1] > 1 { tgmv0 } else { av1_rmv_invalid }
  }
  if ref1 > 0 {
    tgmv1 = av1_rmv_get_gmv_2d(
      rf.gm_types[ref1 - 1], rf.gm_matrices[ref1 - 1], bx4, by4, bw4, bh4,
      rf.hp, rf.force_integer_mv,
    )
    gmv1 = if rf.gm_types[ref1 - 1] > 1 { tgmv1 } else { av1_rmv_invalid }
  }
  // top
  let none : Int = -1 // ~0 sentinel
  let mut n_rows = none
  let mut n_cols = none
  let top_row = (by4 & 31) - 1 + 5
  if by4 > tile_row_start4 {
    let half = (by4 - tile_row_start4 + 1) >> 1
    let cap = 2 + (if bh4 > 1 { 1 } else { 0 })
    let max_rows = if half < cap { half } else { cap }
    n_rows = av1_rmv_scan_row(
      stack, cnt, ref0, ref1, gmv0, gmv1, rows[top_row], bx4, bw4, w4,
      max_rows, if bw4 >= 16 { 4 } else { 1 }, have_newmv, have_row_mvs,
    )
  }
  // left
  let left_row = (by4 & 31) + 5
  if bx4 > tile_col_start4 {
    let half = (bx4 - tile_col_start4 + 1) >> 1
    let cap = 2 + (if bw4 > 1 { 1 } else { 0 })
    let max_cols = if half < cap { half } else { cap }
    n_cols = av1_rmv_scan_col(
      stack, cnt, ref0, ref1, gmv0, gmv1, rows, left_row, bx4 - 1, bh4, h4,
      max_cols, if bh4 >= 16 { 4 } else { 1 }, have_newmv, have_col_mvs,
    )
  }
  // top-right
  if n_rows != none && top_has_right {
    let mb = if bw4 > bh4 { bw4 } else { bh4 }
    if mb <= 16 && bw4 + bx4 < tile_col_end4 {
      av1_rmv_add_spatial(
        stack, cnt, 4, rows[top_row][bx4 + bw4], ref0, ref1, gmv0, gmv1,
        have_newmv, have_row_mvs,
      )
    }
  }
  let nearest_match = (if have_col_mvs.val { 1 } else { 0 }) +
    (if have_row_mvs.val { 1 } else { 0 })
  let nearest_cnt = cnt.val
  for n in 0..<nearest_cnt {
    stack[n].weight = stack[n].weight + 640
  }
  // temporal
  let mut globalmv_ctx = initial_globalmv_ctx
  if rf.use_ref_frame_mvs {
    let by8 = by4 >> 1
    let bx8 = bx4 >> 1
    let rbi = (by8 & 15) * rp_stride + bx8
    let step_h = if bw4 >= 16 { 2 } else { 1 }
    let step_v = if bh4 >= 16 { 2 } else { 1 }
    let w8a = (w4 + 1) >> 1
    let h8a = (h4 + 1) >> 1
    let w8 = if w8a < 8 { w8a } else { 8 }
    let h8 = if h8a < 8 { h8a } else { 8 }
    let gctx = Ref(globalmv_ctx)
    let mut rb_row = rbi
    let mut y = 0
    while y < h8 {
      let mut x = 0
      while x < w8 {
        let probe : Ref[Int]? = if x == 0 && y == 0 {
          Some(gctx)
        } else {
          None
        }
        av1_rmv_add_temporal(
          rf, stack, cnt, rp[rb_row + x], ref0, ref1, tgmv0, probe,
        )
        x = x + step_h
      }
      rb_row = rb_row + rp_stride * step_v
      y = y + step_v
    }
    globalmv_ctx = gctx.val
    let mb = if bw4 > bh4 { bw4 } else { bh4 }
    let mn = if bw4 < bh4 { bw4 } else { bh4 }
    if mn >= 2 && mb < 16 {
      let bh8 = bh4 >> 1
      let bw8 = bw4 >> 1
      let bot_cap_a = tile_row_end4 >> 1
      let bot_cap_b = (by8 & -8) + 8
      let has_bottom = by8 + bh8 < (if bot_cap_a < bot_cap_b {
        bot_cap_a
      } else {
        bot_cap_b
      })
      let col_cap_a = tile_col_start4 >> 1
      let col_x_cap = if col_cap_a > (bx8 & -8) {
        col_cap_a
      } else {
        bx8 & -8
      }
      if has_bottom && bx8 - 1 >= col_x_cap {
        av1_rmv_add_temporal(
          rf, stack, cnt, rp[rbi + bh8 * rp_stride - 1], ref0, ref1, tgmv0,
          None,
        )
      }
      let end_cap_a = tile_col_end4 >> 1
      let end_cap_b = (bx8 & -8) + 8
      let end_cap = if end_cap_a < end_cap_b { end_cap_a } else { end_cap_b }
      if bx8 + bw8 < end_cap {
        if has_bottom {
          av1_rmv_add_temporal(
            rf, stack, cnt, rp[rbi + bh8 * rp_stride + bw8], ref0, ref1,
            tgmv0, None,
          )
        }
        let row_cap_a = tile_row_end4 >> 1
        let row_cap_b = (by8 & -8) + 8
        let row_cap = if row_cap_a < row_cap_b {
          row_cap_a
        } else {
          row_cap_b
        }
        if by8 + bh8 - 1 < row_cap {
          av1_rmv_add_temporal(
            rf, stack, cnt, rp[rbi + bh8 * rp_stride + bw8 - rp_stride],
            ref0, ref1, tgmv0, None,
          )
        }
      }
    }
  }
  // top-left (part of "secondary")
  let dummy_newmv = Ref(false)
  // C tests (n_rows | n_cols) != ~0U: both edges must be available.
  // In particular, never read the neighbouring tile at its left border.
  if n_rows != none && n_cols != none {
    av1_rmv_add_spatial(
      stack, cnt, 4, rows[top_row][bx4 - 1], ref0, ref1, gmv0, gmv1,
      dummy_newmv, have_row_mvs,
    )
  }
  // secondary top & left edges (8x8 resolution)
  for n in 2..=3 {
    if n > n_rows && n <= 2 + (if bh4 > 1 { 1 } else { 0 }) {
      // max_rows may have been capped; dav1d compares against the cap
      let half = (by4 - tile_row_start4 + 1) >> 1
      let cap = 2 + (if bh4 > 1 { 1 } else { 0 })
      let max_rows = if half < cap { half } else { cap }
      if n <= max_rows {
        let src = (((by4 & 31) - 2 * n + 1) | 1) + 5
        n_rows = n_rows + av1_rmv_scan_row(
          stack, cnt, ref0, ref1, gmv0, gmv1, rows[src], (bx4 | 1) + 1 - 1,
          bw4, w4, 1 + max_rows - n, if bw4 >= 16 { 4 } else { 2 },
          dummy_newmv, have_row_mvs,
        )
      }
    }
    if n > n_cols && n <= 2 + (if bw4 > 1 { 1 } else { 0 }) {
      let half = (bx4 - tile_col_start4 + 1) >> 1
      let cap = 2 + (if bw4 > 1 { 1 } else { 0 })
      let max_cols = if half < cap { half } else { cap }
      if n <= max_cols {
        let src = ((by4 & 31) | 1) + 5
        n_cols = n_cols + av1_rmv_scan_col(
          stack, cnt, ref0, ref1, gmv0, gmv1, rows, src, (bx4 - n * 2 + 1) | 1,
          bh4, h4, 1 + max_cols - n, if bh4 >= 16 { 4 } else { 2 },
          dummy_newmv, have_col_mvs,
        )
      }
    }
  }
  // context
  let ref_match_count = (if have_col_mvs.val { 1 } else { 0 }) +
    (if have_row_mvs.val { 1 } else { 0 })
  let (refmv_ctx, newmv_ctx) = match nearest_match {
    0 => {
      let r = if ref_match_count < 2 { ref_match_count } else { 2 }
      (r, if ref_match_count > 0 { 1 } else { 0 })
    }
    1 => {
      let r3 = ref_match_count * 3
      (if r3 < 4 { r3 } else { 4 }, 3 - (if have_newmv.val { 1 } else { 0 }))
    }
    _ => (5, 5 - (if have_newmv.val { 1 } else { 0 }))
  }
  // sort: nearest segment, then the secondary segment
  let mut len = nearest_cnt
  while len != 0 {
    let mut last = 0
    for n in 1..<len {
      if stack[n - 1].weight < stack[n].weight {
        let tmp = stack[n - 1]
        stack[n - 1] = stack[n]
        stack[n] = tmp
        last = n
      }
    }
    len = last
  }
  len = cnt.val
  while len > nearest_cnt {
    let mut last = nearest_cnt
    for n in (nearest_cnt + 1)..<len {
      if stack[n - 1].weight < stack[n].weight {
        let tmp = stack[n - 1]
        stack[n - 1] = stack[n]
        stack[n] = tmp
        last = n
      }
    }
    len = last
  }
  let mut ctx_out = 0
  if ref1 > 0 {
    if cnt.val < 2 {
      let sign0 = rf.sign_bias[ref0 - 1]
      let sign1 = rf.sign_bias[ref1 - 1]
      let sz4 = if w4 < h4 { w4 } else { h4 }
      // dav1d: `same` aliases the mvstack tail at *cnt (4 slots).
      let same_base = cnt.val
      let same_count : FixedArray[Int] = FixedArray::make(4, 0)
      if n_rows != none {
        let mut x = 0
        while x < sz4 {
          let cand_b = rows[top_row][bx4 + x]
          av1_rmv_add_compound_extended(
            stack, same_base, same_count, cand_b, sign0, sign1, ref0, ref1,
            rf.sign_bias,
          )
          x = x + av1_block_dimensions[cand_b.bs * 4].to_int()
        }
      }
      if n_cols != none {
        let mut y = 0
        while y < sz4 {
          let cand_b = rows[left_row + y][bx4 - 1]
          av1_rmv_add_compound_extended(
            stack, same_base, same_count, cand_b, sign0, sign1, ref0, ref1,
            rf.sign_bias,
          )
          y = y + av1_block_dimensions[cand_b.bs * 4 + 1].to_int()
        }
      }
      // merge same/diff pairs, fill the other component with tgmv
      for n in 0..<2 {
        let mut m = same_count[n]
        if m >= 2 {
          continue
        }
        let l = same_count[2 + n]
        if l != 0 {
          let mv = if n == 0 {
            stack[same_base + 2].mv0
          } else {
            stack[same_base + 2].mv1
          }
          if n == 0 {
            stack[same_base + m].mv0 = mv
          } else {
            stack[same_base + m].mv1 = mv
          }
          m = m + 1
          if m == 2 {
            continue
          }
          if l == 2 {
            let mv2 = if n == 0 {
              stack[same_base + 3].mv0
            } else {
              stack[same_base + 3].mv1
            }
            if n == 0 {
              stack[same_base + 1].mv0 = mv2
            } else {
              stack[same_base + 1].mv1 = mv2
            }
            continue
          }
        }
        while m < 2 {
          let t = if n == 0 { tgmv0 } else { tgmv1 }
          if n == 0 {
            stack[same_base + m].mv0 = t
          } else {
            stack[same_base + m].mv1 = t
          }
          m = m + 1
        }
      }
      // If the first extended equals the non-extended one, promote the
      // second extended (dav1d: mvstack[1].mv = mvstack[2].mv).
      if cnt.val == 1 &&
        stack[0].mv0 == stack[same_base].mv0 &&
        stack[0].mv1 == stack[same_base].mv1 {
        stack[1].mv0 = stack[same_base + 1].mv0
        stack[1].mv1 = stack[same_base + 1].mv1
      }
      // weight-2 padding from the first same slot up to 2 candidates
      stack[cnt.val].weight = 2
      if cnt.val < 1 {
        stack[1].weight = 2
      }
      cnt.val = 2
    }
    // clamping (both MVs of each candidate)
    let left = -(bx4 + bw4 + 4) * 32
    let right = (rf.iw4 - bx4 + 4) * 32
    let top = -(by4 + bh4 + 4) * 32
    let bottom = (rf.ih4 - by4 + 4) * 32
    for n in 0..<cnt.val {
      let c = stack[n]
      stack[n].mv0 = (
        av1_rmv_clip(c.mv0.0, top, bottom),
        av1_rmv_clip(c.mv0.1, left, right),
      )
      stack[n].mv1 = (
        av1_rmv_clip(c.mv1.0, top, bottom),
        av1_rmv_clip(c.mv1.1, left, right),
      )
    }
    ctx_out = match refmv_ctx >> 1 {
      0 => if newmv_ctx < 1 { newmv_ctx } else { 1 }
      1 => 1 + (if newmv_ctx < 3 { newmv_ctx } else { 3 })
      _ => {
        let v = 3 + newmv_ctx
        if v < 4 {
          4
        } else if v > 7 {
          7
        } else {
          v
        }
      }
    }
    return { cands: stack, cnt: cnt.val, ctx: ctx_out }
  }
  if cnt.val < 2 && ref0 > 0 {
    let sign = rf.sign_bias[ref0 - 1]
    let sz4 = if w4 < h4 { w4 } else { h4 }
    if n_rows != none {
      let mut x = 0
      while x < sz4 && cnt.val < 2 {
        let cand_b = rows[top_row][bx4 + x]
        av1_rmv_add_single_extended(
          stack, cnt, cand_b, sign, rf.sign_bias,
        )
        x = x + av1_block_dimensions[cand_b.bs * 4].to_int()
      }
    }
    if n_cols != none {
      let mut y = 0
      while y < sz4 && cnt.val < 2 {
        let cand_b = rows[left_row + y][bx4 - 1]
        av1_rmv_add_single_extended(
          stack, cnt, cand_b, sign, rf.sign_bias,
        )
        y = y + av1_block_dimensions[cand_b.bs * 4 + 1].to_int()
      }
    }
  }
  // clamping (mv0 only)
  if cnt.val != 0 {
    let left = -(bx4 + bw4 + 4) * 32
    let right = (rf.iw4 - bx4 + 4) * 32
    let top = -(by4 + bh4 + 4) * 32
    let bottom = (rf.ih4 - by4 + 4) * 32
    for n in 0..<cnt.val {
      let c = stack[n]
      stack[n].mv0 = (
        av1_rmv_clip(c.mv0.0, top, bottom),
        av1_rmv_clip(c.mv0.1, left, right),
      )
    }
  }
  for n in cnt.val..<2 {
    stack[n].mv0 = tgmv0
  }
  ctx_out = (refmv_ctx << 4) | (globalmv_ctx << 3) | newmv_ctx
  { cands: stack, cnt: cnt.val, ctx: ctx_out }
}

///|
/// Public probe of `av1_rmv_projection` for vector tests.
pub fn av1_rmv_projection_probe(
  mv : (Int, Int),
  num : Int,
  den : Int,
) -> (Int, Int) {
  av1_rmv_projection(mv, num, den)
}

///|
/// Public probe of `av1_rmv_get_gmv_2d` for vector tests.
pub fn av1_rmv_get_gmv_2d_probe(
  gm_type : Int,
  mat : FixedArray[Int],
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  hp : Bool,
  force_integer_mv : Bool,
) -> (Int, Int) {
  av1_rmv_get_gmv_2d(
    gm_type, mat, bx4, by4, bw4, bh4, hp, force_integer_mv,
  )
}

///|
/// Per-frame refmvs scalars produced by `dav1d_refmvs_init_frame`.
pub struct Av1RefmvsFrameInit {
  sign_bias : FixedArray[Int] // [7]
  mfmv_sign : FixedArray[Int] // [7]
  pocdiff : FixedArray[Int] // [7]
  mfmv_ref : FixedArray[Int] // [3]
  mfmv_ref2cur : FixedArray[Int] // [3], INT_MIN sentinel = far
  mfmv_ref2ref : FixedArray[FixedArray[Int]] // [3][7]
  n_mfmvs : Int
  use_ref_frame_mvs : Bool
}

///|
/// Public constructor for `Av1RefmvsFrameInit`, used by state-machine
/// parity vectors that do not derive the temporal reference selection from
/// order hints.
pub fn av1_refmvs_frame_init_probe(
  sign_bias : FixedArray[Int],
  mfmv_sign : FixedArray[Int],
  pocdiff : FixedArray[Int],
  mfmv_ref : FixedArray[Int],
  mfmv_ref2cur : FixedArray[Int],
  mfmv_ref2ref : FixedArray[FixedArray[Int]],
  n_mfmvs : Int,
  use_ref_frame_mvs : Bool,
) -> Av1RefmvsFrameInit {
  {
    sign_bias,
    mfmv_sign,
    pocdiff,
    mfmv_ref,
    mfmv_ref2cur,
    mfmv_ref2ref,
    n_mfmvs,
    use_ref_frame_mvs,
  }
}

///|
/// `dav1d_refmvs_init_frame` (single tile/frame thread): sign biases,
/// poc deltas and the temporal-MV reference selection (last/bwd/altref2/
/// altref/last2 with ref2cur/ref2ref projection distances).
pub fn av1_refmvs_init_frame(
  order_hint_bits : Int,
  frame_offset : Int,
  hdr_use_ref_frame_mvs : Bool,
  ref_poc : FixedArray[Int],
  ref_has_tmvs : FixedArray[Bool],
  ref_ref_poc : FixedArray[FixedArray[Int]],
) -> Av1RefmvsFrameInit {
  let sign_bias = FixedArray::make(7, 0)
  let mfmv_sign = FixedArray::make(7, 0)
  let pocdiff = FixedArray::make(7, 0)
  for i in 0..<7 {
    let d1 = av1_get_poc_diff(order_hint_bits, ref_poc[i], frame_offset)
    sign_bias[i] = if d1 > 0 { 1 } else { 0 }
    mfmv_sign[i] = if d1 < 0 { 1 } else { 0 }
    let d2 = av1_get_poc_diff(order_hint_bits, frame_offset, ref_poc[i])
    pocdiff[i] = if d2 < -31 {
      -31
    } else if d2 > 31 {
      31
    } else {
      d2
    }
  }
  // temporal MV reference selection
  let mfmv_ref = FixedArray::make(3, 0)
  let mfmv_ref2cur = FixedArray::make(3, 0)
  let mfmv_ref2ref : FixedArray[FixedArray[Int]] = FixedArray::makei(
    3,
    _ => FixedArray::make(7, 0),
  )
  let mut n_mfmvs = 0
  let mut use_ref = false
  if hdr_use_ref_frame_mvs && order_hint_bits != 0 {
    let mut total = 2
    // last (slot 0), unless alt-of-last == gold (unscaled mixing)
    if ref_has_tmvs[0] && ref_ref_poc[0][6] != ref_poc[3] {
      mfmv_ref[n_mfmvs] = 0
      n_mfmvs = n_mfmvs + 1
      total = 3
    }
    // bwd (slot 4), altref2 (slot 5): must be past frames
    if ref_has_tmvs[4] &&
      av1_get_poc_diff(order_hint_bits, ref_poc[4], frame_offset) > 0 {
      mfmv_ref[n_mfmvs] = 4
      n_mfmvs = n_mfmvs + 1
    }
    if ref_has_tmvs[5] &&
      av1_get_poc_diff(order_hint_bits, ref_poc[5], frame_offset) > 0 {
      mfmv_ref[n_mfmvs] = 5
      n_mfmvs = n_mfmvs + 1
    }
    if n_mfmvs < total &&
      ref_has_tmvs[6] &&
      av1_get_poc_diff(order_hint_bits, ref_poc[6], frame_offset) > 0 {
      mfmv_ref[n_mfmvs] = 6
      n_mfmvs = n_mfmvs + 1
    }
    if n_mfmvs < total && ref_has_tmvs[1] {
      mfmv_ref[n_mfmvs] = 1
      n_mfmvs = n_mfmvs + 1
    }
    for n in 0..<n_mfmvs {
      let rpoc = ref_poc[mfmv_ref[n]]
      let diff1 = av1_get_poc_diff(order_hint_bits, rpoc, frame_offset)
      if diff1 < -31 || diff1 > 31 {
        mfmv_ref2cur[n] = -2147483647 - 1 // INT_MIN
      } else {
        mfmv_ref2cur[n] = if mfmv_ref[n] < 4 { -diff1 } else { diff1 }
        for m in 0..<7 {
          let rrpoc = ref_ref_poc[mfmv_ref[n]][m]
          let diff2 = av1_get_poc_diff(order_hint_bits, rpoc, rrpoc)
          mfmv_ref2ref[n][m] = if diff2 < 0 || diff2 > 31 {
            0
          } else {
            diff2
          }
        }
      }
    }
    use_ref = n_mfmvs > 0
  }
  {
    sign_bias,
    mfmv_sign,
    pocdiff,
    mfmv_ref,
    mfmv_ref2cur,
    mfmv_ref2ref,
    n_mfmvs,
    use_ref_frame_mvs: use_ref,
  }
}
