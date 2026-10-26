///|
/// Inter block prediction assembly: single-reference put/warp, compound
/// `prep` plus avg/w_avg/wedge/seg blending, and dav1d's joint-compound
/// distance weights. Residual reconstruction, OBMC and inter-intra are
/// separate steps.

///|
/// One reference picture plane. `width`/`height` are the reference frame's
/// luma dimensions; `src` is the plane at its own subsampling.
pub(all) struct Av1ReconRefPlane {
  src : FixedArray[Int32]
  stride : Int32
  width : Int32
  height : Int32
}

///|
/// Predicted luma/chroma planes for one block (row-major).
pub(all) struct Av1ReconPlanes {
  y : FixedArray[Int32]
  u : FixedArray[Int32]
  v : FixedArray[Int32]
  w : Int32
  h : Int32
  cw : Int32
  ch : Int32
}

///|
/// dav1d `jnt_weights` entry: the WEIGHTED_AVG weight for `ref0` against
/// `ref1`, from their order hints relative to the current picture.
pub fn av1_jnt_comp_weight(
  order_hint_bits : Int32,
  cur_poc : Int32,
  ref0_poc : Int32,
  ref1_poc : Int32,
) -> Int32 {
  let d1 = av1_abs_i(av1_get_poc_diff(order_hint_bits, ref0_poc, cur_poc))
  let d0 = av1_abs_i(av1_get_poc_diff(order_hint_bits, ref1_poc, cur_poc))
  let d1 = if d1 > 31 { 31 } else { d1 }
  let d0 = if d0 > 31 { 31 } else { d0 }
  let order = if d0 <= d1 { 1 } else { 0 }
  let quant_dist_weight : FixedArray[Int32] = [2, 3, 2, 5, 2, 7]
  let quant_dist_lookup : FixedArray[Int32] = [9, 7, 11, 5, 12, 4, 13, 3]
  let mut k = 0
  while k < 3 {
    let c0 = quant_dist_weight[k * 2 + order]
    let c1 = quant_dist_weight[k * 2 + (1 - order)]
    let d0_c0 = d0 * c0
    let d1_c1 = d1 * c1
    if (d0 > d1 && d0_c0 < d1_c1) || (d0 <= d1 && d0_c0 > d1_c1) {
      break
    }
    k = k + 1
  }
  quant_dist_lookup[k * 2 + order]
}

///|
fn av1_abs_i(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
fn av1_recon_layout(ss_h : Int32, ss_v : Int32) -> Int32 {
  if ss_h == 0 {
    0
  } else if ss_v == 0 {
    1
  } else {
    2
  }
}

///|
/// Predict one plane of a single-reference block.
fn av1_recon_single_plane(
  b : Av1InterBlock,
  plane : Av1ReconRefPlane,
  mv : (Int32, Int32),
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let (mvy, mvx) = mv
  match b.warp {
    Some(matrix) if b.motion_mode == 2 &&
      b.warp_type > 1 &&
      (bw4 + ss_h) >> ss_h > 1 &&
      (bh4 + ss_v) >> ss_v > 1 =>
      @av1_mc_core.av1_mc_warp_predict_plane(
        plane.src,
        plane.stride,
        plane.width,
        plane.height,
        bx4,
        by4,
        bw4,
        bh4,
        ss_h,
        ss_v,
        bitdepth,
        matrix,
        b.warp_alpha,
        b.warp_beta,
        b.warp_gamma,
        b.warp_delta,
      )
    _ =>
      @av1_mc_core.av1_mc_predict_plane(
        plane.src,
        plane.stride,
        plane.width,
        plane.height,
        cur_w,
        cur_h,
        bx4,
        by4,
        bw4,
        bh4,
        mvy,
        mvx,
        ss_h,
        ss_v,
        b.filter2d,
        bitdepth,
      )
  }
}

///|
/// Prepare one compound reference plane at `prep` precision.
fn av1_recon_prep_plane(
  plane : Av1ReconRefPlane,
  mv : (Int32, Int32),
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  filter2d : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let (mvy, mvx) = mv
  @av1_mc_core.av1_mc_prepare_plane(
    plane.src,
    plane.stride,
    plane.width,
    plane.height,
    cur_w,
    cur_h,
    bx4,
    by4,
    bw4,
    bh4,
    mvy,
    mvx,
    ss_h,
    ss_v,
    filter2d,
    bitdepth,
  )
}

///|
fn av1_recon_compound_plane(
  b : Av1InterBlock,
  ref0 : Av1ReconRefPlane,
  ref1 : Av1ReconRefPlane,
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  bitdepth : Int32,
  jnt_weight : Int32,
  mask : FixedArray[Int32],
  global0 : Av1WarpedMotion?,
  global1 : Av1WarpedMotion?,
  segment_layout : (Int32, Int32)?,
) -> (FixedArray[Int32], FixedArray[Int32]) {
  let prepare = (
    plane : Av1ReconRefPlane,
    mv : (Int32, Int32),
    global : Av1WarpedMotion?,
  ) => {
    match global {
      Some(wm) if b.mode == 6 &&
        (bw4 + ss_h) >> ss_h > 1 &&
        (bh4 + ss_v) >> ss_v > 1 =>
        @av1_mc_core.av1_mc_warp_prepare_plane(
          plane.src,
          plane.stride,
          plane.width,
          plane.height,
          bx4,
          by4,
          bw4,
          bh4,
          ss_h,
          ss_v,
          bitdepth,
          wm.matrix,
          wm.alpha,
          wm.beta,
          wm.gamma,
          wm.delta,
        )
      _ =>
        av1_recon_prep_plane(
          plane,
          mv,
          cur_w,
          cur_h,
          bx4,
          by4,
          bw4,
          bh4,
          ss_h,
          ss_v,
          b.filter2d,
          bitdepth,
        )
    }
  }
  let p0 = prepare(ref0, b.mv0, global0)
  let p1 = prepare(ref1, b.mv1, global1)
  let w = bw4 * (4 >> ss_h)
  let h = bh4 * (4 >> ss_v)
  if b.comp_type == 3 {
    // Generate the segment mask from luma once; chroma reuses that mask
    // after subsampling, rather than deriving another mask from chroma.
    let (a, c) = if b.mask_sign == 0 { (p0, p1) } else { (p1, p0) }
    return match segment_layout {
      Some((sx, sy)) =>
        @av1_mc_core.av1_mc_diffwtd_mask(
          a,
          c,
          w,
          h,
          b.mask_sign,
          sx,
          sy,
          bitdepth,
        )
      None => (@av1_mc_core.av1_mc_mask(a, c, mask, bitdepth), mask)
    }
  }
  (
    @av1_mc_core.av1_mc_compound_blend(
      p0,
      p1,
      b.comp_type,
      b.mask_sign,
      jnt_weight,
      mask,
      w,
      h,
      ss_h,
      ss_v,
      bitdepth,
    ),
    mask,
  )
}

///|
/// Neighbour data needed by OBMC: the refmvs row ring, filter contexts and
/// tile-relative block bounds.
pub(all) struct Av1ReconObmc {
  rows : FixedArray[FixedArray[Av1Rb]]
  nstate : Av1InterTileState
  w4 : Int32
  h4 : Int32
  have_top : Bool
  have_left : Bool
}

///|
fn av1_recon_imin(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn av1_recon_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn av1_recon_ulog2(v : Int32) -> Int32 {
  let mut x = v
  let mut n = 0
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
fn av1_recon_block_w(b : Av1Rb) -> Int32 {
  av1_block_dimensions[b.bs * 4].to_int()
}

///|
fn av1_recon_block_h(b : Av1Rb) -> Int32 {
  av1_block_dimensions[b.bs * 4 + 1].to_int()
}

///|
/// Predict one overlap region and blend it into the destination sub-block.
/// `horizontal` selects dav1d `blend_h` (top neighbour) over `blend_v`
/// (left neighbour).
fn av1_recon_obmc_region(
  dst : FixedArray[Int32],
  dst_w : Int32,
  dst_x : Int32,
  dst_y : Int32,
  refs : FixedArray[Av1ReconRefPlane],
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  bitdepth : Int32,
  nb : Av1Rb,
  filter2d : Int32,
  horizontal : Bool,
) -> Unit {
  let h_mul = 4 >> ss_h
  let v_mul = 4 >> ss_v
  let rw = bw4 * h_mul
  let rh = bh4 * v_mul
  let plane = refs[nb.ref0 - 1]
  let (mvy, mvx) = nb.mv0
  let lap = @av1_mc_core.av1_mc_predict_plane(
    plane.src,
    plane.stride,
    plane.width,
    plane.height,
    cur_w,
    cur_h,
    bx4,
    by4,
    bw4,
    bh4,
    mvy,
    mvx,
    ss_h,
    ss_v,
    filter2d,
    bitdepth,
  )
  let sub = FixedArray::makei(rw * rh, i => {
    dst[(dst_y + i / rw) * dst_w + dst_x + i % rw]
  })
  let blended = if horizontal {
    @av1_mc_core.av1_mc_obmc_horizontal(sub, lap, rw, rh)
  } else {
    @av1_mc_core.av1_mc_obmc_vertical(sub, lap, rw, rh)
  }
  for i in 0..<(rw * rh) {
    dst[(dst_y + i / rw) * dst_w + dst_x + i % rw] = blended[i]
  }
}

///|
/// dav1d `obmc()` for one plane: top and left neighbour overlaps.
fn av1_recon_obmc_plane(
  dst : FixedArray[Int32],
  refs : FixedArray[Av1ReconRefPlane],
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  bitdepth : Int32,
  chroma : Bool,
  obmc : Av1ReconObmc,
) -> FixedArray[Int32] {
  let h_mul = 4 >> ss_h
  let v_mul = 4 >> ss_v
  let dst_w = bw4 * h_mul
  let dst_h = bh4 * v_mul
  let out = FixedArray::makei(dst_w * dst_h, i => dst[i])
  let r = (by4 & 31) + 5
  let top_ok = obmc.have_top && (!chroma || bw4 * h_mul + bh4 * v_mul >= 16)
  if top_ok {
    let cap = av1_recon_imin(av1_recon_ulog2(bw4), 4)
    let mut i = 0
    let mut x = 0
    while x < obmc.w4 && i < cap {
      let nb = obmc.rows[r - 1][bx4 + x + 1]
      let step = av1_recon_clip(av1_recon_block_w(nb), 2, 16)
      if nb.ref0 > 0 {
        let ow4 = av1_recon_imin(step, bw4)
        let oh4 = av1_recon_imin(bh4, 16) >> 1
        let filter2d = av1_inter_filter2d(
          obmc.nstate.top[(bx4 & 31) + x + 1].filter0,
          obmc.nstate.top[(bx4 & 31) + x + 1].filter1,
        )
        av1_recon_obmc_region(
          out,
          dst_w,
          x * h_mul,
          0,
          refs,
          cur_w,
          cur_h,
          bx4 + x,
          by4,
          ow4,
          (oh4 * 3 + 3) >> 2,
          ss_h,
          ss_v,
          bitdepth,
          nb,
          filter2d,
          true,
        )
        i = i + 1
      }
      x = x + step
    }
  }
  if obmc.have_left {
    let cap = av1_recon_imin(av1_recon_ulog2(bh4), 4)
    let mut i = 0
    let mut y = 0
    while y < obmc.h4 && i < cap {
      let nb = obmc.rows[r + y + 1][bx4 - 1]
      let step = av1_recon_clip(av1_recon_block_h(nb), 2, 16)
      if nb.ref0 > 0 {
        let ow4 = av1_recon_imin(bw4, 16) >> 1
        let oh4 = av1_recon_imin(step, bh4)
        let filter2d = av1_inter_filter2d(
          obmc.nstate.left[(by4 & 31) + y + 1].filter0,
          obmc.nstate.left[(by4 & 31) + y + 1].filter1,
        )
        av1_recon_obmc_region(
          out,
          dst_w,
          0,
          y * v_mul,
          refs,
          cur_w,
          cur_h,
          bx4,
          by4 + y,
          ow4,
          oh4,
          ss_h,
          ss_v,
          bitdepth,
          nb,
          filter2d,
          false,
        )
        i = i + 1
      }
      y = y + step
    }
  }
  out
}

///|
/// Blend an inter-intra prediction: the mask weights the intra samples
/// (dav1d `II_MASK`, with the wedge variant for wedge inter-intra).
fn av1_recon_interintra_blend(
  inter : FixedArray[Int32],
  intra : FixedArray[Int32],
  b : Av1InterBlock,
  layout : Int32,
) -> FixedArray[Int32] {
  let mask = if b.interintra.kind == 1 {
    @av1_mc_core.av1_ii_mask(layout, b.bs, b.interintra.mode)
  } else {
    @av1_mc_core.av1_wedge_mask(layout, b.bs, 0, b.interintra.wedge_idx)
  }
  @av1_mc_core.av1_mc_blend_pixels(inter, intra, mask)
}

///|
/// Chroma sub8x8 derivation (dav1d `recon_b_inter`): 4x4/4x8/8x4 luma blocks
/// take chroma motion from the left/top/top-left neighbours and combine
/// 2x2 (or half-block) chroma predictions. Returns None when the block is
/// not a sub8x8 shape or the required neighbour motion is missing.
fn av1_recon_sub8x8_chroma(
  b_ref0 : Int32,
  b_mv : (Int32, Int32),
  b_filter2d : Int32,
  refs : FixedArray[Av1ReconRefPlane],
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_v : Int32,
  bitdepth : Int32,
  neigh : Av1ReconObmc,
) -> FixedArray[Int32]? {
  let ss_h = 1
  if bw4 != ss_h && bh4 != ss_v {
    return None
  }
  let r = (by4 & 31) + 5
  let has_left = neigh.have_left && bx4 > 0
  let has_top = neigh.have_top && by4 > 0
  let l_nb = if has_left { Some(neigh.rows[r][bx4 - 1]) } else { None }
  let t_nb = if has_top { Some(neigh.rows[r - 1][bx4]) } else { None }
  let tl_nb = if has_left && has_top {
    Some(neigh.rows[r - 1][bx4 - 1])
  } else {
    None
  }
  let ok_left = match l_nb {
    Some(n) => n.ref0 > 0
    None => false
  }
  let ok_top = match t_nb {
    Some(n) => n.ref0 > 0
    None => false
  }
  let ok_tl = match tl_nb {
    Some(n) => n.ref0 > 0
    None => false
  }
  if (bw4 == ss_h && !ok_left) ||
    (bh4 == ss_v && !ok_top) ||
    (bw4 == ss_h && bh4 == ss_v && !ok_tl) {
    return None
  }
  let h_mul = 2
  let v_mul = 4 >> ss_v
  // Sub8x8 chroma is predicted for the covering 8x8 luma unit: a 4-wide
  // quadrant pair plus the other axis' full extent.
  let cw = if bw4 == ss_h { 4 } else { bw4 * h_mul }
  let ch = if bh4 == ss_v { 4 } else { bh4 * v_mul }
  let dst = FixedArray::make(cw * ch, 0)
  let mut h_off = 0
  let mut v_off = 0
  let place = (pred : FixedArray[Int32], ox : Int32, oy : Int32) => {
    let pw = bw4 * h_mul
    let ph = bh4 * v_mul
    for yy in 0..<ph {
      for xx in 0..<pw {
        dst[(oy + yy) * cw + ox + xx] = pred[yy * pw + xx]
      }
    }
  }
  let predict_from = (nb : Av1Rb, px : Int32, py : Int32, filter2d : Int32) => {
    let plane = refs[nb.ref0 - 1]
    let (mvy, mvx) = nb.mv0
    @av1_mc_core.av1_mc_predict_plane(
      plane.src,
      plane.stride,
      plane.width,
      plane.height,
      cur_w,
      cur_h,
      px,
      py,
      bw4,
      bh4,
      mvy,
      mvx,
      ss_h,
      ss_v,
      filter2d,
      bitdepth,
    )
  }
  if bw4 == ss_h && bh4 == ss_v {
    let nb = match tl_nb {
      Some(n) => n
      None => return None
    }
    let f = av1_inter_filter2d(
      neigh.nstate.top[if (bx4 & 31) > 0 { (bx4 & 31) - 1 } else { 0 }].filter0,
      neigh.nstate.top[if (bx4 & 31) > 0 { (bx4 & 31) - 1 } else { 0 }].filter1,
    )
    place(predict_from(nb, bx4 - 1, by4 - 1, f), 0, 0)
    v_off = 2
    h_off = 2
  }
  if bw4 == ss_h {
    let nb = match l_nb {
      Some(n) => n
      None => return None
    }
    let f = av1_inter_filter2d(
      neigh.nstate.left[by4 & 31].filter0,
      neigh.nstate.left[by4 & 31].filter1,
    )
    place(predict_from(nb, bx4 - 1, by4, f), 0, v_off)
    h_off = 2
  }
  if bh4 == ss_v {
    let nb = match t_nb {
      Some(n) => n
      None => return None
    }
    let f = av1_inter_filter2d(
      neigh.nstate.top[bx4 & 31].filter0,
      neigh.nstate.top[bx4 & 31].filter1,
    )
    place(predict_from(nb, bx4, by4 - 1, f), h_off, 0)
    v_off = 2
  }
  place(
    {
      let plane = refs[b_ref0]
      let (mvy, mvx) = b_mv
      @av1_mc_core.av1_mc_predict_plane(
        plane.src,
        plane.stride,
        plane.width,
        plane.height,
        cur_w,
        cur_h,
        bx4,
        by4,
        bw4,
        bh4,
        mvy,
        mvx,
        ss_h,
        ss_v,
        b_filter2d,
        bitdepth,
      )
    },
    h_off,
    v_off,
  )
  Some(dst)
}

///|
/// Predict all planes for one inter block, including frame-level global
/// warp when the reference is unscaled and its shear parameters are valid.
pub fn av1_recon_predict_block(
  b : Av1InterBlock,
  ref_y : FixedArray[Av1ReconRefPlane],
  ref_u : FixedArray[Av1ReconRefPlane],
  ref_v : FixedArray[Av1ReconRefPlane],
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  bitdepth : Int32,
  jnt_weight : Int32,
  intra : Av1ReconPlanes?,
  obmc : Av1ReconObmc?,
  mono~ : Bool = false,
  global_motion~ : FixedArray[Av1WarpedMotion?]? = None,
) -> Result[Av1ReconPlanes, String] {
  if b.interintra.kind != 0 && intra is None {
    return Err("av1 recon: inter-intra needs an intra prediction")
  }
  if b.motion_mode == 1 && obmc is None {
    return Err("av1 recon: OBMC needs neighbour state")
  }
  let single = b.ref1 < 0
  let global0 = match global_motion {
    Some(g) => g[b.ref0]
    None => None
  }
  let global1 = match global_motion {
    Some(g) if b.ref1 >= 0 => g[b.ref1]
    _ => None
  }
  let single_b = match global0 {
    Some(wm) if single && b.mode == 2 =>
      {
        ..b,
        motion_mode: 2,
        warp: Some(wm.matrix),
        warp_type: wm.typ,
        warp_alpha: wm.alpha,
        warp_beta: wm.beta,
        warp_gamma: wm.gamma,
        warp_delta: wm.delta,
      }
    _ => b
  }
  let sub8x8 = !mono && single && ss_h == 1 && (bw4 == 1 || bh4 == ss_v)
  if sub8x8 && obmc is None {
    return Err("av1 recon: chroma sub8x8 needs neighbours")
  }
  let w = bw4 * 4
  let h = bh4 * 4
  let cw = bw4 * (4 >> ss_h)
  let ch = bh4 * (4 >> ss_v)
  let (y0, segment_mask) = if single {
    (
      av1_recon_single_plane(
        single_b,
        ref_y[b.ref0],
        b.mv0,
        cur_w,
        cur_h,
        bx4,
        by4,
        bw4,
        bh4,
        0,
        0,
        bitdepth,
      ),
      FixedArray::make(0, 0),
    )
  } else {
    av1_recon_compound_plane(
      b,
      ref_y[b.ref0],
      ref_y[b.ref1],
      cur_w,
      cur_h,
      bx4,
      by4,
      bw4,
      bh4,
      0,
      0,
      bitdepth,
      jnt_weight,
      av1_recon_wedge_mask(b, 0),
      global0,
      global1,
      Some((ss_h, ss_v)),
    )
  }
  let u0 = if mono {
    FixedArray::make(0, 0)
  } else if single {
    let sub = match obmc {
      Some(o) if sub8x8 =>
        av1_recon_sub8x8_chroma(
          b.ref0,
          b.mv0,
          b.filter2d,
          ref_u,
          cur_w,
          cur_h,
          bx4,
          by4,
          bw4,
          bh4,
          ss_v,
          bitdepth,
          o,
        )
      _ => None
    }
    match sub {
      Some(p) => p
      None =>
        av1_recon_single_plane(
          single_b,
          ref_u[b.ref0],
          b.mv0,
          cur_w,
          cur_h,
          if bw4 == ss_h {
            bx4 & (-1 - ss_h)
          } else {
            bx4
          },
          if bh4 == ss_v {
            by4 & (-1 - ss_v)
          } else {
            by4
          },
          bw4 << (if bw4 == ss_h { 1 } else { 0 }),
          bh4 << (if bh4 == ss_v { 1 } else { 0 }),
          ss_h,
          ss_v,
          bitdepth,
        )
    }
  } else {
    av1_recon_compound_plane(
      b,
      ref_u[b.ref0],
      ref_u[b.ref1],
      cur_w,
      cur_h,
      bx4,
      by4,
      bw4,
      bh4,
      ss_h,
      ss_v,
      bitdepth,
      jnt_weight,
      if b.comp_type == 3 {
        segment_mask
      } else {
        av1_recon_wedge_mask(b, av1_recon_layout(ss_h, ss_v))
      },
      global0,
      global1,
      None,
    ).0
  }
  let v0 = if mono {
    FixedArray::make(0, 0)
  } else if single {
    let sub = match obmc {
      Some(o) if sub8x8 =>
        av1_recon_sub8x8_chroma(
          b.ref0,
          b.mv0,
          b.filter2d,
          ref_v,
          cur_w,
          cur_h,
          bx4,
          by4,
          bw4,
          bh4,
          ss_v,
          bitdepth,
          o,
        )
      _ => None
    }
    match sub {
      Some(p) => p
      None =>
        av1_recon_single_plane(
          single_b,
          ref_v[b.ref0],
          b.mv0,
          cur_w,
          cur_h,
          if bw4 == ss_h {
            bx4 & (-1 - ss_h)
          } else {
            bx4
          },
          if bh4 == ss_v {
            by4 & (-1 - ss_v)
          } else {
            by4
          },
          bw4 << (if bw4 == ss_h { 1 } else { 0 }),
          bh4 << (if bh4 == ss_v { 1 } else { 0 }),
          ss_h,
          ss_v,
          bitdepth,
        )
    }
  } else {
    av1_recon_compound_plane(
      b,
      ref_v[b.ref0],
      ref_v[b.ref1],
      cur_w,
      cur_h,
      bx4,
      by4,
      bw4,
      bh4,
      ss_h,
      ss_v,
      bitdepth,
      jnt_weight,
      if b.comp_type == 3 {
        segment_mask
      } else {
        av1_recon_wedge_mask(b, av1_recon_layout(ss_h, ss_v))
      },
      global0,
      global1,
      None,
    ).0
  }
  let y1 = match obmc {
    Some(o) if b.motion_mode == 1 =>
      av1_recon_obmc_plane(
        y0, ref_y, cur_w, cur_h, bx4, by4, bw4, bh4, 0, 0, bitdepth, false, o,
      )
    _ => y0
  }
  let u1 = match obmc {
    Some(o) if b.motion_mode == 1 && !mono =>
      av1_recon_obmc_plane(
        u0, ref_u, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v, bitdepth, true,
        o,
      )
    _ => u0
  }
  let v1 = match obmc {
    Some(o) if b.motion_mode == 1 && !mono =>
      av1_recon_obmc_plane(
        v0, ref_v, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v, bitdepth, true,
        o,
      )
    _ => v0
  }
  let cw_out = if mono {
    0
  } else if sub8x8 && single && bw4 == ss_h {
    4
  } else {
    cw
  }
  let ch_out = if mono {
    0
  } else if sub8x8 && single && bh4 == ss_v {
    4
  } else {
    ch
  }
  let layout = av1_recon_layout(ss_h, ss_v)
  let (y, u, v) = match intra {
    Some(ip) if b.interintra.kind != 0 && !mono =>
      (
        av1_recon_interintra_blend(y1, ip.y, b, 0),
        av1_recon_interintra_blend(u1, ip.u, b, layout),
        av1_recon_interintra_blend(v1, ip.v, b, layout),
      )
    Some(ip) if b.interintra.kind != 0 =>
      (av1_recon_interintra_blend(y1, ip.y, b, 0), u1, v1)
    _ => (y1, u1, v1)
  }
  { y, u, v, w, h, cw: cw_out, ch: ch_out, } |> Ok
}

///|
/// Wedge mask for one plane: luma uses sign 0 (dav1d `WEDGE_MASK(0, ...)`),
/// chroma uses the block's mask sign.
fn av1_recon_wedge_mask(b : Av1InterBlock, layout : Int32) -> FixedArray[Int32] {
  if b.comp_type != 4 {
    return []
  }
  let sign = if layout == 0 { 0 } else { b.mask_sign }
  @av1_mc_core.av1_wedge_mask(layout, b.bs, sign, b.wedge_idx)
}

///|
/// Frame planes, coefficient scratch, sequence geometry and neighbour
/// coefficient contexts used by inter block reconstruction.
pub(all) struct Av1ReconInterCtx {
  coef : Av1CoefState
  cf : FixedArray[Int32]
  y : FixedArray[Int32]
  u : FixedArray[Int32]
  v : FixedArray[Int32]
  y_stride : Int32
  uv_stride : Int32
  bw : Int32
  bh : Int32
  ss_h : Int32
  ss_v : Int32
  bpc : Int32
  pixel_max : Int32
  mono : Bool
  a_lcoef : FixedArray[Int32]
  l_lcoef : FixedArray[Int32]
  a_ccoef : FixedArray[Int32]
  l_ccoef : FixedArray[Int32]
}

///|
/// `recon_b_inter` prediction + residual half: predict all planes into the
/// frame buffers, then either reset the coefficient contexts (skip) or run
/// the inter coefficient walk applying inverse transforms in place.
/// `tx_max`/`split0`/`split1`/`uvtx` come from `read_vartx_tree`.
pub fn av1_recon_b_inter(
  ctx : Av1ReconInterCtx,
  bs : Int32,
  b : Av1InterBlock,
  seg_id : Int32,
  skip : Bool,
  tx_max : Int32,
  split0 : UInt32,
  split1 : UInt32,
  uvtx : Int32,
  ref_y : FixedArray[Av1ReconRefPlane],
  ref_u : FixedArray[Av1ReconRefPlane],
  ref_v : FixedArray[Av1ReconRefPlane],
  cur_w : Int32,
  cur_h : Int32,
  bx4 : Int32,
  by4 : Int32,
  jnt_weight : Int32,
  intra : Av1ReconPlanes?,
  obmc : Av1ReconObmc?,
  global_motion~ : FixedArray[Av1WarpedMotion?]? = None,
) -> Result[Unit, String] {
  let bw4 = av1_block_dimensions[bs * 4].to_int()
  let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
  let has_chroma = !ctx.mono &&
    (bw4 > ctx.ss_h || (bx4 & 1) != 0) &&
    (bh4 > ctx.ss_v || (by4 & 1) != 0)
  let planes = match
    av1_recon_predict_block(
      b,
      ref_y,
      ref_u,
      ref_v,
      cur_w,
      cur_h,
      bx4,
      by4,
      bw4,
      bh4,
      ctx.ss_h,
      ctx.ss_v,
      ctx.bpc,
      jnt_weight,
      intra,
      obmc,
      mono=ctx.mono,
      global_motion~,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  // write the predicted block into the frame planes
  let y_off = 4 * (by4 * ctx.y_stride + bx4)
  for yy in 0..<planes.h {
    for xx in 0..<planes.w {
      ctx.y[y_off + yy * ctx.y_stride + xx] = planes.y[yy * planes.w + xx]
    }
  }
  if has_chroma {
    let uv_off = 4 * ((by4 >> ctx.ss_v) * ctx.uv_stride + (bx4 >> ctx.ss_h))
    for yy in 0..<planes.ch {
      for xx in 0..<planes.cw {
        ctx.u[uv_off + yy * ctx.uv_stride + xx] = planes.u[yy * planes.cw + xx]
        ctx.v[uv_off + yy * ctx.uv_stride + xx] = planes.v[yy * planes.cw + xx]
      }
    }
  }
  let abx = bx4 & 31
  let aby = by4 & 31
  if skip {
    for i in 0..<bw4 {
      ctx.a_lcoef[abx + i] = 0x40
    }
    for i in 0..<bh4 {
      ctx.l_lcoef[aby + i] = 0x40
    }
    if has_chroma {
      let cbw4 = (bw4 + ctx.ss_h) >> ctx.ss_h
      let cbh4 = (bh4 + ctx.ss_v) >> ctx.ss_v
      for pl in 0..<2 {
        let base = pl * 32 + (abx >> ctx.ss_h)
        for i in 0..<cbw4 {
          ctx.a_ccoef[base + i] = 0x40
        }
        let lbase = pl * 32 + (aby >> ctx.ss_v)
        for i in 0..<cbh4 {
          ctx.l_ccoef[lbase + i] = 0x40
        }
      }
    }
    return Ok(())
  }
  let reader : Av1CoefReader = {
    decode: (a_arr, a_off, l_arr, l_off, tx, plane, _intra, luma_txtp) => {
      let (eob, txtp, res_ctx) = av1_decode_coefs(
        ctx.coef,
        a_arr,
        a_off,
        l_arr,
        l_off,
        tx,
        bs,
        seg_id,
        0,
        0,
        0,
        false,
        plane,
        ctx.cf,
        luma_txtp~,
      )
      (eob, txtp, res_ctx)
    },
  }
  let apply_y = (rx, ry, tx, txtp, eob) => {
    av1_itxfm_add(
      ctx.y,
      4 * ((by4 + ry) * ctx.y_stride + bx4 + rx),
      ctx.y_stride,
      ctx.cf,
      eob,
      tx,
      txtp,
      ctx.pixel_max,
    )
  }
  let apply_uv = (pl, cx, cy, tx, txtp, eob) => {
    let plane = if pl == 0 { ctx.u } else { ctx.v }
    av1_itxfm_add(
      plane,
      4 * (((by4 >> ctx.ss_v) + cy) * ctx.uv_stride + (bx4 >> ctx.ss_h) + cx),
      ctx.uv_stride,
      ctx.cf,
      eob,
      tx,
      txtp,
      ctx.pixel_max,
    )
  }
  let w4 = av1_imin(bw4, ctx.bw - bx4)
  let h4 = av1_imin(bh4, ctx.bh - by4)
  let cw4 = (w4 + ctx.ss_h) >> ctx.ss_h
  let ch4 = (h4 + ctx.ss_v) >> ctx.ss_v
  let txtp_map = FixedArray::make(1024, b'\x00')
  av1_read_inter_residual(
    reader,
    bs,
    tx_max,
    split0,
    split1,
    uvtx,
    w4,
    h4,
    cw4,
    ch4,
    ctx.ss_h,
    ctx.ss_v,
    has_chroma,
    bx4,
    by4,
    ctx.bw,
    ctx.bh,
    ctx.a_lcoef,
    ctx.l_lcoef,
    ctx.a_ccoef,
    ctx.l_ccoef,
    txtp_map,
    Some(apply_y),
    Some(apply_uv),
  )
  Ok(())
}
