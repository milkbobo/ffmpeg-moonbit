///|
/// AV1 intra block copy (`intrabc`) block decode, ported from dav1d 1.5.1
/// `decode.c` (the `IS_KEY_OR_INTRA` branch) and `recon_tmpl.c`
/// (`recon_b_inter` with the current frame as the reference and bilinear
/// MC). Only frames with `allow_intrabc` reach this path.

///|
fn Av1TileCtx::decode_intrabc_block(
  self : Av1TileCtx,
  bs : Int32,
  edge_flags : Int32,
  seg_id : Int32,
  seg_pred : Int32,
  skip : Bool,
) -> Unit raise Av1DecError {
  let f = self.f
  let hdr = f.hdr
  guard self.rstate is Some(rstate) else {
    raise Av1DecError::Unsupported("av1: missing intrabc refmvs state")
  }
  let bx = self.bx
  let by = self.by
  let bx4 = bx & 31
  let by4 = by & 31
  let bw4 = av1_bdim(bs, 0)
  let bh4 = av1_bdim(bs, 1)
  let has_chroma = !f.seq.monochrome &&
    (bw4 > f.ss_h || (bx & 1) != 0) &&
    (bh4 > f.ss_v || (by & 1) != 0)
  let a = f.a[self.a_idx]
  let l = f.l
  let sb128 = if f.seq.use_128x128_superblock { 1 } else { 0 }
  let stack = rstate.find(
    self.col_start,
    self.col_end,
    self.row_start,
    self.row_end,
    0,
    -1,
    bs,
    (edge_flags & av1_edge_i444_top_has_right) != 0,
    by,
    bx,
  )
  let mut mv = (0, 0)
  if stack.cnt > 0 && stack.cands[0].mv0 != av1_rmv_invalid {
    mv = stack.cands[0].mv0
  } else if stack.cnt > 1 && stack.cands[1].mv0 != av1_rmv_invalid {
    mv = stack.cands[1].mv0
  } else if by - (16 << sb128) < self.row_start {
    mv = (0 - (512 << sb128) - 2048, 0)
  } else {
    mv = (0 - (512 << sb128), 0)
  }
  let (mvy, mvx) = av1_read_mv_residual(self.msac, self.cdf, mv.0, mv.1, -1)
  // Clip the block vector to the decoded part of the current tile and keep
  // it clear of the current superblock (dav1d decode.c).
  let mut border_left = self.col_start * 4
  let mut border_top = self.row_start * 4
  if has_chroma {
    if bw4 < 2 && f.ss_h == 1 {
      border_left += 4
    }
    if bh4 < 2 && f.ss_v == 1 {
      border_top += 4
    }
  }
  let mut src_left = bx * 4 + (mvx >> 3)
  let mut src_top = by * 4 + (mvy >> 3)
  let mut src_right = src_left + bw4 * 4
  let mut src_bottom = src_top + bh4 * 4
  let border_right = ((self.col_end + (bw4 - 1)) & (0 - bw4)) * 4
  if src_left < border_left {
    src_right = src_right + (border_left - src_left)
    src_left = border_left
  } else if src_right > border_right {
    src_left = src_left - (src_right - border_right)
    src_right = border_right
  }
  if src_top < border_top {
    src_bottom = src_bottom + (border_top - src_top)
    src_top = border_top
  }
  let sbx = bx >> (4 + sb128) << (6 + sb128)
  let sby = by >> (4 + sb128) << (6 + sb128)
  let sb_size = 1 << (6 + sb128)
  if src_bottom > sby && src_right > sbx {
    if src_top - border_top >= src_bottom - sby {
      src_top = src_top - (src_bottom - sby)
      src_bottom = sby
    } else if src_left - border_left >= src_right - sbx {
      src_left = src_left - (src_right - sbx)
      src_right = sbx
    }
  }
  if src_bottom > sby + sb_size {
    src_top = src_top - (src_bottom - (sby + sb_size))
    src_bottom = sby + sb_size
  }
  if src_bottom > sby && src_right > sbx {
    raise Av1DecError::Unsupported("av1: invalid intrabc block vector")
  }
  let dv = ((src_top - by * 4) * 8, (src_left - bx * 4) * 8)
  let layout = if f.seq.monochrome {
    0
  } else if f.ss_h == 0 {
    3
  } else if f.ss_v == 0 {
    2
  } else {
    1
  }
  let tx = av1_read_vartx_tree(
    self.msac,
    self.cdf,
    bs,
    skip,
    f.seg_lossless[seg_id],
    hdr.tx_mode == 2,
    layout,
    a.tx,
    l.tx,
    bx,
    by,
    f.bw,
    f.bh,
  )
  let block : Av1InterBlock = {
    bs,
    ref0: 0,
    ref1: -1,
    comp_type: 0,
    wedge_idx: 0,
    mode: 0,
    drl_idx: 0,
    mv0: dv,
    mv1: (0, 0),
    interintra: { kind: 0, mode: 0, wedge_idx: 0, },
    motion_mode: 0,
    warp: None,
    warp_type: 0,
    warp_alpha: 0,
    warp_beta: 0,
    warp_gamma: 0,
    warp_delta: 0,
    mask0: 0UL,
    mask1: 0UL,
    find_ctx: 0,
    filter0: 0,
    filter1: 0,
    filter2d: 9, // FILTER_2D_BILINEAR
    mask_sign: 0,
    skip_mode: false,
    has_subpel_filter: true,
  }
  let ctx : Av1ReconInterCtx = {
    coef: self.coef_state(),
    cf: self.cf,
    y: f.planes[0],
    u: f.planes[1],
    v: f.planes[2],
    y_stride: f.y_stride,
    uv_stride: f.uv_stride,
    bw: f.bw,
    bh: f.bh,
    ss_h: f.ss_h,
    ss_v: f.ss_v,
    bpc: f.bpc,
    pixel_max: f.pixel_max,
    mono: f.seq.monochrome,
    a_lcoef: a.lcoef,
    l_lcoef: l.lcoef,
    a_ccoef: a.ccoef,
    l_ccoef: l.lcoef,
  }
  let ref_y : FixedArray[Av1ReconRefPlane] = [
    {
      src: f.planes[0],
      stride: f.y_stride,
      width: hdr.width,
      height: hdr.height,
    },
  ]
  let ref_u : FixedArray[Av1ReconRefPlane] = [
    {
      src: f.planes[1],
      stride: f.uv_stride,
      width: hdr.width,
      height: hdr.height,
    },
  ]
  let ref_v : FixedArray[Av1ReconRefPlane] = [
    {
      src: f.planes[2],
      stride: f.uv_stride,
      width: hdr.width,
      height: hdr.height,
    },
  ]
  match
    av1_recon_b_inter(
      ctx,
      bs,
      block,
      seg_id,
      skip,
      tx.max_ytx,
      tx.split0,
      tx.split1,
      tx.uvtx,
      ref_y,
      ref_u,
      ref_v,
      hdr.width,
      hdr.height,
      bx,
      by,
      8,
      None,
      None,
    ) {
    Ok(_) => ()
    Err(e) => raise Av1DecError::Unsupported("av1 intrabc: " + e)
  }
  // Segment map + neighbour contexts (dav1d set_ctx for intrabc blocks).
  if hdr.segmentation_enabled && hdr.segmentation_update_map {
    for y in 0..<av1_imin(bh4, f.bh - by) {
      for x in 0..<av1_imin(bw4, f.bw - bx) {
        f.cur_segmap[(by + y) * f.b4_stride + bx + x] = seg_id.to_byte()
      }
    }
  }
  let lw = av1_bdim(bs, 2)
  let lh = av1_bdim(bs, 3)
  for i in 0..<bw4 {
    a.tx_intra[bx4 + i] = lw
    a.mode[bx4 + i] = av1_dc_pred
    a.pal_sz[bx4 + i] = 0
    a.seg_pred[bx4 + i] = seg_pred
    a.skip_mode[bx4 + i] = 0
    a.intra[bx4 + i] = 0
    a.skip[bx4 + i] = if skip { 1 } else { 0 }
    self.pal_sz_uv[bx4 + i] = 0
  }
  for i in 0..<bh4 {
    l.tx_intra[by4 + i] = lh
    l.mode[by4 + i] = av1_dc_pred
    l.pal_sz[by4 + i] = 0
    l.seg_pred[by4 + i] = seg_pred
    l.skip_mode[by4 + i] = 0
    l.intra[by4 + i] = 0
    l.skip[by4 + i] = if skip { 1 } else { 0 }
    self.pal_sz_uv[32 + by4 + i] = 0
  }
  if has_chroma {
    let cbx4 = bx4 >> f.ss_h
    let cby4 = by4 >> f.ss_v
    let cbw4 = (bw4 + f.ss_h) >> f.ss_h
    let cbh4 = (bh4 + f.ss_v) >> f.ss_v
    for i in 0..<cbw4 {
      a.uvmode[cbx4 + i] = av1_dc_pred
    }
    for i in 0..<cbh4 {
      l.uvmode[cby4 + i] = av1_dc_pred
    }
  }
  rstate.splat(
    { ref0: 0, ref1: -1, bs, mf: 0, mv0: dv, mv1: (0, 0), },
    bx,
    by,
    bw4,
    bh4,
  )
}
