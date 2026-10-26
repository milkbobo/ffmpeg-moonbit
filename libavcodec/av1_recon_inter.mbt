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
/// Predict all planes for one inter block. Inter-intra, OBMC and compound
/// global-warp paths are not wired yet and return an error.
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
) -> Result[Av1ReconPlanes, String] {
  if b.interintra.kind != 0 {
    return Err("av1 recon: inter-intra pending")
  }
  if b.motion_mode == 1 {
    return Err("av1 recon: OBMC pending")
  }
  let single = b.ref1 < 0
  let w = bw4 * 4
  let h = bh4 * 4
  let cw = bw4 * (4 >> ss_h)
  let ch = bh4 * (4 >> ss_v)
  let y = if single {
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
  let u = if single {
    av1_recon_single_plane(
      b, ref_u[b.ref0], b.mv0, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v,
      bitdepth,
    )
  } else {
    av1_recon_compound_plane(
      b, ref_u[b.ref0], ref_u[b.ref1], cur_w, cur_h, bx4, by4, bw4, bh4,
      ss_h, ss_v, bitdepth, jnt_weight,
      av1_recon_wedge_mask(b, av1_recon_layout(ss_h, ss_v)),
    )
  }
  let v = if single {
    av1_recon_single_plane(
      b, ref_v[b.ref0], b.mv0, cur_w, cur_h, bx4, by4, bw4, bh4, ss_h, ss_v,
      bitdepth,
    )
  } else {
    av1_recon_compound_plane(
      b, ref_v[b.ref0], ref_v[b.ref1], cur_w, cur_h, bx4, by4, bw4, bh4,
      ss_h, ss_v, bitdepth, jnt_weight,
      av1_recon_wedge_mask(b, av1_recon_layout(ss_h, ss_v)),
    )
  }
  { y, u, v, w, h, cw, ch } |> Ok
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
