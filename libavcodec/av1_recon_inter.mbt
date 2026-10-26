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
  width : Int
  height : Int
}

///|
/// Predicted luma/chroma planes for one block (row-major).
pub(all) struct Av1ReconPlanes {
  y : FixedArray[Int32]
  u : FixedArray[Int32]
  v : FixedArray[Int32]
  w : Int
  h : Int
  cw : Int
  ch : Int
}

///|
/// dav1d `jnt_weights` entry: the WEIGHTED_AVG weight for `ref0` against
/// `ref1`, from their order hints relative to the current picture.
pub fn av1_jnt_comp_weight(
  order_hint_bits : Int,
  cur_poc : Int,
  ref0_poc : Int,
  ref1_poc : Int,
) -> Int {
  let d1 = av1_abs_i(
    av1_get_poc_diff(order_hint_bits, ref0_poc, cur_poc),
  )
  let d0 = av1_abs_i(
    av1_get_poc_diff(order_hint_bits, ref1_poc, cur_poc),
  )
  let d1 = if d1 > 31 { 31 } else { d1 }
  let d0 = if d0 > 31 { 31 } else { d0 }
  let order = if d0 <= d1 { 1 } else { 0 }
  let quant_dist_weight : FixedArray[Int] = [2, 3, 2, 5, 2, 7]
  let quant_dist_lookup : FixedArray[Int] = [9, 7, 11, 5, 12, 4, 13, 3]
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
  if v < 0 { -v } else { v }
}

///|
fn av1_recon_layout(ss_h : Int, ss_v : Int) -> Int {
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
  mv : (Int, Int),
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let (mvy, mvx) = mv
  match b.warp {
    Some(matrix) if b.motion_mode == 2 && b.warp_type == 3 =>
      @av1_mc_core.av1_mc_warp_predict_plane(
        plane.src, plane.stride, plane.width, plane.height, bx4, by4, bw4, bh4,
        ss_h, ss_v, bitdepth, matrix, b.warp_alpha, b.warp_beta,
        b.warp_gamma, b.warp_delta,
      )
    _ =>
      @av1_mc_core.av1_mc_predict_plane(
        plane.src, plane.stride, plane.width, plane.height, cur_w, cur_h, bx4, by4,
        bw4, bh4, mvy, mvx, ss_h, ss_v, b.filter2d, bitdepth,
      )
  }
}

///|
/// Prepare one compound reference plane at `prep` precision.
fn av1_recon_prep_plane(
  plane : Av1ReconRefPlane,
  mv : (Int, Int),
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
  filter2d : Int,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let (mvy, mvx) = mv
  @av1_mc_core.av1_mc_prepare_plane(
    plane.src, plane.stride, plane.width, plane.height, cur_w, cur_h, bx4, by4,
    bw4, bh4, mvy, mvx, ss_h, ss_v, filter2d, bitdepth,
  )
}

///|
fn av1_recon_compound_plane(
  b : Av1InterBlock,
  ref0 : Av1ReconRefPlane,
  ref1 : Av1ReconRefPlane,
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
  bitdepth : Int32,
  jnt_weight : Int,
  mask : FixedArray[Int32],
) -> FixedArray[Int32] {
  let p0 = av1_recon_prep_plane(
    ref0, b.mv0, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v, b.filter2d,
    bitdepth,
  )
  let p1 = av1_recon_prep_plane(
    ref1, b.mv1, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v, b.filter2d,
    bitdepth,
  )
  let w = (bw4 * (4 >> ss_h))
  let h = (bh4 * (4 >> ss_v))
  @av1_mc_core.av1_mc_compound_blend(
    p0, p1, b.comp_type, b.mask_sign, jnt_weight, mask, w, h, ss_h,
    ss_v, bitdepth,
  )
}


///|
/// Neighbour data needed by OBMC: the refmvs row ring, filter contexts and
/// tile-relative block bounds.
pub(all) struct Av1ReconObmc {
  rows : FixedArray[FixedArray[Av1Rb]]
  nstate : Av1InterTileState
  w4 : Int
  h4 : Int
  have_top : Bool
  have_left : Bool
}

///|
fn av1_recon_imin(a : Int, b : Int) -> Int {
  if a < b { a } else { b }
}

///|
fn av1_recon_clip(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn av1_recon_ulog2(v : Int) -> Int {
  let mut x = v
  let mut n = 0
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
fn av1_recon_block_w(b : Av1Rb) -> Int {
  av1_block_dimensions[b.bs * 4].to_int()
}

///|
fn av1_recon_block_h(b : Av1Rb) -> Int {
  av1_block_dimensions[b.bs * 4 + 1].to_int()
}

///|
/// Predict one overlap region and blend it into the destination sub-block.
/// `horizontal` selects dav1d `blend_h` (top neighbour) over `blend_v`
/// (left neighbour).
fn av1_recon_obmc_region(
  dst : FixedArray[Int32],
  dst_w : Int,
  dst_x : Int,
  dst_y : Int,
  refs : FixedArray[Av1ReconRefPlane],
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
  bitdepth : Int32,
  nb : Av1Rb,
  filter2d : Int,
  horizontal : Bool,
) -> Unit {
  let h_mul = 4 >> ss_h
  let v_mul = 4 >> ss_v
  let rw = bw4 * h_mul
  let rh = bh4 * v_mul
  let plane = refs[nb.ref0 - 1]
  let (mvy, mvx) = nb.mv0
  let lap = @av1_mc_core.av1_mc_predict_plane(
    plane.src, plane.stride, plane.width, plane.height, cur_w, cur_h, bx4, by4,
    bw4, bh4, mvy, mvx, ss_h, ss_v, filter2d, bitdepth,
  )
  let sub = FixedArray::makei(
    rw * rh,
    i => dst[(dst_y + i / rw) * dst_w + dst_x + i % rw],
  )
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
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
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
  let top_ok = obmc.have_top &&
    (!chroma || bw4 * h_mul + bh4 * v_mul >= 16)
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
          obmc.nstate.top[bx4 + x + 1].filter0,
          obmc.nstate.top[bx4 + x + 1].filter1,
        )
        av1_recon_obmc_region(
          out, dst_w, x * h_mul, 0, refs, cur_w, cur_h, bx4 + x, by4, ow4,
          (oh4 * 3 + 3) >> 2, ss_h, ss_v, bitdepth, nb, filter2d, true,
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
          obmc.nstate.left[by4 + y + 1].filter0,
          obmc.nstate.left[by4 + y + 1].filter1,
        )
        av1_recon_obmc_region(
          out, dst_w, 0, y * v_mul, refs, cur_w, cur_h, bx4, by4 + y, ow4,
          oh4, ss_h, ss_v, bitdepth, nb, filter2d, false,
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
  layout : Int,
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
  b_ref0 : Int,
  b_mv : (Int, Int),
  b_filter2d : Int,
  refs : FixedArray[Av1ReconRefPlane],
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_v : Int,
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
  if (bw4 == ss_h && !ok_left) || (bh4 == ss_v && !ok_top) ||
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
  let place = (pred : FixedArray[Int32], ox : Int, oy : Int) => {
    let pw = bw4 * h_mul
    let ph = bh4 * v_mul
    for yy in 0..<ph {
      for xx in 0..<pw {
        dst[(oy + yy) * cw + ox + xx] = pred[yy * pw + xx]
      }
    }
  }
  let predict_from = (
    nb : Av1Rb,
    px : Int,
    py : Int,
    filter2d : Int,
  ) => {
    let plane = refs[nb.ref0 - 1]
    let (mvy, mvx) = nb.mv0
    @av1_mc_core.av1_mc_predict_plane(
      plane.src, plane.stride, plane.width, plane.height, cur_w, cur_h, px,
      py, bw4, bh4, mvy, mvx, ss_h, ss_v, filter2d, bitdepth,
    )
  }
  if bw4 == ss_h && bh4 == ss_v {
    let nb = match tl_nb {
      Some(n) => n
      None => return None
    }
    let f = av1_inter_filter2d(
      neigh.nstate.top[if bx4 > 0 { bx4 - 1 } else { 0 }].filter0,
      neigh.nstate.top[if bx4 > 0 { bx4 - 1 } else { 0 }].filter1,
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
      neigh.nstate.left[by4].filter0, neigh.nstate.left[by4].filter1,
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
      neigh.nstate.top[bx4].filter0, neigh.nstate.top[bx4].filter1,
    )
    place(predict_from(nb, bx4, by4 - 1, f), h_off, 0)
    v_off = 2
  }
  place({
    let plane = refs[b_ref0]
    let (mvy, mvx) = b_mv
    @av1_mc_core.av1_mc_predict_plane(
      plane.src, plane.stride, plane.width, plane.height, cur_w, cur_h, bx4,
      by4, bw4, bh4, mvy, mvx, ss_h, ss_v, b_filter2d, bitdepth,
    )
  }, h_off, v_off)
  Some(dst)
}

///|
/// Predict all planes for one inter block. Compound global-warp is not wired
/// yet.
pub fn av1_recon_predict_block(
  b : Av1InterBlock,
  ref_y : FixedArray[Av1ReconRefPlane],
  ref_u : FixedArray[Av1ReconRefPlane],
  ref_v : FixedArray[Av1ReconRefPlane],
  cur_w : Int,
  cur_h : Int,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  ss_h : Int,
  ss_v : Int,
  bitdepth : Int32,
  jnt_weight : Int,
  intra : Av1ReconPlanes?,
  obmc : Av1ReconObmc?,
) -> Result[Av1ReconPlanes, String] {
  if b.interintra.kind != 0 && intra is None {
    return Err("av1 recon: inter-intra needs an intra prediction")
  }
  if b.motion_mode == 1 && obmc is None {
    return Err("av1 recon: OBMC needs neighbour state")
  }
  let single = b.ref1 < 0
  let sub8x8 = single && ss_h == 1 && (bw4 == 1 || bh4 == ss_v)
  if sub8x8 && obmc is None {
    return Err("av1 recon: chroma sub8x8 needs neighbours")
  }
  let w = bw4 * 4
  let h = bh4 * 4
  let cw = bw4 * (4 >> ss_h)
  let ch = bh4 * (4 >> ss_v)
  let y0 = if single {
    av1_recon_single_plane(
      b, ref_y[b.ref0], b.mv0, cur_w, cur_h, bx4, by4, bw4, bh4, 0, 0,
      bitdepth,
    )
  } else {
    av1_recon_compound_plane(
      b, ref_y[b.ref0], ref_y[b.ref1], cur_w, cur_h, bx4, by4, bw4, bh4, 0,
      0, bitdepth, jnt_weight, av1_recon_wedge_mask(b, 0),
    )
  }
  let u0 = if single {
    let sub = match obmc {
      Some(o) if sub8x8 =>
        av1_recon_sub8x8_chroma(
          b.ref0, b.mv0, b.filter2d, ref_u, cur_w, cur_h, bx4, by4, bw4, bh4,
          ss_v, bitdepth, o,
        )
      _ => None
    }
    match sub {
      Some(p) => p
      None =>
        av1_recon_single_plane(
          b, ref_u[b.ref0], b.mv0, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h,
          ss_v, bitdepth,
        )
    }
  } else {
    av1_recon_compound_plane(
      b, ref_u[b.ref0], ref_u[b.ref1], cur_w, cur_h, bx4, by4, bw4, bh4,
      ss_h, ss_v, bitdepth, jnt_weight,
      av1_recon_wedge_mask(b, av1_recon_layout(ss_h, ss_v)),
    )
  }
  let v0 = if single {
    let sub = match obmc {
      Some(o) if sub8x8 =>
        av1_recon_sub8x8_chroma(
          b.ref0, b.mv0, b.filter2d, ref_v, cur_w, cur_h, bx4, by4, bw4, bh4,
          ss_v, bitdepth, o,
        )
      _ => None
    }
    match sub {
      Some(p) => p
      None =>
        av1_recon_single_plane(
          b, ref_v[b.ref0], b.mv0, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h,
          ss_v, bitdepth,
        )
    }
  } else {
    av1_recon_compound_plane(
      b, ref_v[b.ref0], ref_v[b.ref1], cur_w, cur_h, bx4, by4, bw4, bh4,
      ss_h, ss_v, bitdepth, jnt_weight,
      av1_recon_wedge_mask(b, av1_recon_layout(ss_h, ss_v)),
    )
  }
  let y1 = match obmc {
    Some(o) if b.motion_mode == 1 =>
      av1_recon_obmc_plane(
        y0, ref_y, cur_w, cur_h, bx4, by4, bw4, bh4, 0, 0, bitdepth, false, o,
      )
    _ => y0
  }
  let u1 = match obmc {
    Some(o) if b.motion_mode == 1 =>
      av1_recon_obmc_plane(
        u0, ref_u, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v, bitdepth,
        true, o,
      )
    _ => u0
  }
  let v1 = match obmc {
    Some(o) if b.motion_mode == 1 =>
      av1_recon_obmc_plane(
        v0, ref_v, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v, bitdepth,
        true, o,
      )
    _ => v0
  }
  let cw_out = if sub8x8 && single && bw4 == ss_h {
    4
  } else {
    cw
  }
  let ch_out = if sub8x8 && single && bh4 == ss_v {
    4
  } else {
    ch
  }
  let layout = av1_recon_layout(ss_h, ss_v)
  let (y, u, v) = match intra {
    Some(ip) if b.interintra.kind != 0 =>
      (
        av1_recon_interintra_blend(y1, ip.y, b, 0),
        av1_recon_interintra_blend(u1, ip.u, b, layout),
        av1_recon_interintra_blend(v1, ip.v, b, layout),
      )
    _ => (y1, u1, v1)
  }
  { y, u, v, w, h, cw: cw_out, ch: ch_out } |> Ok
}

///|
/// Wedge mask for one plane: luma uses sign 0 (dav1d `WEDGE_MASK(0, ...)`),
/// chroma uses the block's mask sign.
fn av1_recon_wedge_mask(b : Av1InterBlock, layout : Int) -> FixedArray[Int32] {
  if b.comp_type != 4 {
    return []
  }
  let sign = if layout == 0 { 0 } else { b.mask_sign }
  @av1_mc_core.av1_wedge_mask(layout, b.bs, sign, b.wedge_idx)
}
