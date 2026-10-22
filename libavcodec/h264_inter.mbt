///|
/// MoonBit port of the H.264 inter (P slice) macroblock layer from FFmpeg
/// 9.0.2: the CABAC halves of `decode_cabac_mb_skip`, `decode_cabac_mb_type`
/// (P branch), `decode_cabac_p_mb_sub_type`, `decode_cabac_mb_ref`,
/// `decode_cabac_mb_mvd`, the inter `cbp`/residual path of
/// `ff_h264_decode_mb_cabac` and `ff_h264_decode_mb_cavlc`, and the inter
/// reconstruction (`mc_part_std` in `h264_mb.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: progressive frame pictures, 8-bit 4:2:0, single L0 list with
/// reordering and missing-reference substitution, explicit weighted
/// prediction, no B slices.

///| One motion compensation operation: luma rectangle (x, y, w, h) within the

///|
/// macroblock with a quarter-pel MV and an L0 reference index. */
priv struct H264McOp {
  x : Int32
  y : Int32
  w : Int32
  h : Int32
  mvx : Int32
  mvy : Int32
  ref_idx : Int32
}

///|
/// `decode_cabac_mb_skip`: context 11 + (left non-skip) + (top non-skip),
/// both neighbours counted only when they are decoded and in the same slice
/// (single-slice pictures: any decoded neighbour).
fn h264_cabac_mb_skip(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let mut c = 0
  if ctx.mb_aff {
    let top_pair = (mb_y & -2) * ctx.mb_width + mb_x
    let mut left = top_pair - 1
    if (mb_y & 1) == 1 && h264_same_slice(ctx, left) &&
      ctx.mb_field == ctx.infos[left].field_mb {
      left = left + ctx.mb_width
    }
    let top = if ctx.mb_field {
      let t = top_pair - ctx.mb_width
      if (mb_y & 1) == 0 && h264_same_slice(ctx, t) && ctx.infos[t].field_mb {
        t - ctx.mb_width
      } else {
        t
      }
    } else {
      mb_x + (mb_y - 1) * ctx.mb_width
    }
    if mb_x > 0 && h264_same_slice(ctx, left) &&
      (ctx.infos[left].mb_type_bits & h264_mb_type_skip) == 0 {
      c = c + 1
    }
    if h264_same_slice(ctx, top) && (ctx.infos[top].mb_type_bits & h264_mb_type_skip) == 0 {
      c = c + 1
    }
  } else {
    if h264_has_left(ctx, mb_idx) {
      let l = ctx.infos[mb_idx - 1]
      if l.mb_type_bits != 0 && (l.mb_type_bits & h264_mb_type_skip) == 0 {
        c = c + 1
      }
    }
    if h264_has_top(ctx, mb_idx) {
      let t = ctx.infos[h264_top_index(ctx, mb_idx)]
      if t.mb_type_bits != 0 && (t.mb_type_bits & h264_mb_type_skip) == 0 {
        c = c + 1
      }
    }
  }
  cabac.get_cabac(states, (if ctx.slice_type_nos == 1 { 24 } else { 11 }) + c)
}
///|
/// `decode_cabac_mb_type`, P branch: contexts 14..17. Returns
/// `Ok(type)` 0..3 for P_L0_16x16 / P_L0_16x8 / P_L0_8x16 / P_8x8, or
/// `Err(intra_mb_type)` when the context-14 branch selects intra (the
/// `decode_cabac_intra_mb_type(sl, 17, 0)` continuation).
fn h264_cabac_p_mb_type(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Int32, Int32] {
  if cabac.get_cabac(states, 14) == 0 {
    // P-type
    if cabac.get_cabac(states, 15) == 0 {
      // P_L0_D16x16, P_8x8
      Ok(3 * cabac.get_cabac(states, 16))
    } else {
      // P_L0_D8x16, P_L0_D16x8
      Ok(2 - cabac.get_cabac(states, 17))
    }
  } else {
    Err(h264_cabac_intra_mb_type(cabac, states, ctx, mb_idx, mb_x, mb_y, 17, 0))
  }
}

///|
/// `decode_cabac_p_mb_sub_type`: 0 is sub-8x8, 1 sub-8x4, 2 sub-4x8, 3
/// sub-4x4 (the `ff_h264_p_sub_mb_type_info` raw indices).
fn h264_cabac_p_sub_type(cabac : CabacContext, states : Array[Int32]) -> Int32 {
  if cabac.get_cabac(states, 21) != 0 {
    0 // 8x8
  } else if cabac.get_cabac(states, 22) == 0 {
    1 // 8x4
  } else if cabac.get_cabac(states, 23) != 0 {
    2 // 4x8
  } else {
    3 // 4x4
  }
}

///|
/// `decode_cabac_mb_ref` for L0: contexts 54..57, the neighbour refs read
/// from the block at (`bx`, `by`) the way `ref_cache[scan8[n] ± ...]` does.
fn h264_cabac_mb_ref(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
  ref_count : Int32,
) -> Result[Int32, String] {
  let (refa, _, _) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, bx - 1, by)
  let (refb, _, _) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, bx, by - 1)
  let mut refv = 0
  let mut c = 0
  if refa > 0 && (ctx.slice_type_nos != 1 || !h264_b_direct_neighbor(ctx, mb_idx, mb_x, mb_y, bx - 1, by)) {
    c = c + 1
  }
  if refb > 0 && (ctx.slice_type_nos != 1 || !h264_b_direct_neighbor(ctx, mb_idx, mb_x, mb_y, bx, by - 1)) {
    c = c + 2
  }
  while cabac.get_cabac(states, 54 + c) != 0 {
    refv = refv + 1
    c = (c >> 2) + 4
    if refv >= 32 {
      return Err("invalid CABAC ref_idx")
    }
  }
  if refv >= ref_count {
    return Err("reference \{refv} >= \{ref_count}")
  }
  Ok(refv)
}

///|
/// `decode_cabac_mb_mvd`: `base` is 40 (x) or 47 (y), `amvd` the summed
/// absolute neighbour mvd component. Returns the signed difference; the
/// clamped absolute value feeds the next `amvd` (the C's `*mvda`).
fn h264_cabac_mb_mvd(
  cabac : CabacContext,
  states : Array[Int32],
  base : Int32,
  amvd : Int32,
) -> Result[(Int32, Int32), String] {
  // `ctxbase + ((amvd-3)>>31) + ((amvd-33)>>31) + 2`, i.e. 0/1/2.
  let ctxi = if amvd > 32 { 2 } else if amvd > 2 { 1 } else { 0 }
  if cabac.get_cabac(states, base + ctxi) == 0 {
    return Ok((0, 0))
  }
  let mut mvd = 1
  let mut ctxbase = base + 3
  while mvd < 9 && cabac.get_cabac(states, ctxbase) != 0 {
    if mvd < 4 {
      ctxbase = ctxbase + 1
    }
    mvd = mvd + 1
  }
  let mut mvd_abs = mvd
  if mvd >= 9 {
    let mut k = 3
    while cabac.get_cabac_bypass() != 0 {
      mvd = mvd + (1 << k)
      k = k + 1
      if k > 24 {
        return Err("overflow in decode_cabac_mb_mvd")
      }
    }
    while k > 0 {
      k = k - 1
      mvd = mvd + (cabac.get_cabac_bypass() << k)
    }
    mvd_abs = if mvd < 70 { mvd } else { 70 }
  }
  Ok((cabac.get_cabac_bypass_sign(-mvd), mvd_abs))
}

///|
/// Read one `mvd_l0` pair for the 4x4 block at (`bx`, `by`), predicting from
/// `pmv` (`DECODE_CABAC_MB_MVD`). Returns `(mvx, mvy, mvd_absx, mvd_absy)`.
fn h264_cabac_read_mvd(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
  pmvx : Int32,
  pmvy : Int32,
) -> Result[(Int32, Int32, Int32, Int32), String] {
  let (lamvd0, lamvd1) = h264_mvd_fetch(ctx, mb_idx, mb_x, mb_y, bx - 1, by)
  let (tamvd0, tamvd1) = h264_mvd_fetch(ctx, mb_idx, mb_x, mb_y, bx, by - 1)
  let r0 = h264_cabac_mb_mvd(cabac, states, 40, lamvd0 + tamvd0)
  let r1 = h264_cabac_mb_mvd(cabac, states, 47, lamvd1 + tamvd1)
  guard r0 is Ok((mvd0, abs0)) else { return Err("mvd overflow") }
  guard r1 is Ok((mvd1, abs1)) else { return Err("mvd overflow") }
  Ok((pmvx + mvd0, pmvy + mvd1, abs0, abs1))
}

///|
/// Fill a partition's `ref_idx` before the remaining reference indices are
/// decoded: `decode_cabac_mb_ref`'s neighbour contexts read the values already
/// parsed for earlier partitions of the same macroblock.
fn h264_write_back_ref(
  ctx : H264DecCtx,
  mb_idx : Int32,
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
  refi : Int32,
) -> Unit {
  let info = ctx.infos[mb_idx]
  let refs = if ctx.active_list == 0 { info.ref_idx } else { info.ref_idx1 }
  for y = 0; y < bh; y = y + 1 {
    for x = 0; x < bw; x = x + 1 {
      refs[(by + y) * 4 + bx + x] = refi
    }
  }
}

///|
/// Write a partition's MV/ref back over its 4x4 blocks (`fill_rectangle` on
/// the mv/ref caches plus `write_back_motion`).
fn h264_write_back_part(
  ctx : H264DecCtx,
  mb_idx : Int32,
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
  mvx : Int32,
  mvy : Int32,
  refi : Int32,
  mvd_absx : Int32,
  mvd_absy : Int32,
) -> Unit {
  let info = ctx.infos[mb_idx]
  let mv = if ctx.active_list == 0 { info.mv } else { info.mv1 }
  let refs = if ctx.active_list == 0 { info.ref_idx } else { info.ref_idx1 }
  let mvd = if ctx.active_list == 0 { info.mvd } else { info.mvd1 }
  for y = 0; y < bh; y = y + 1 {
    for x = 0; x < bw; x = x + 1 {
      let i = (by + y) * 4 + bx + x
      mv[2 * i] = h264_i16(mvx)
      mv[2 * i + 1] = h264_i16(mvy)
      refs[i] = refi
      mvd[2 * i] = mvd_absx
      mvd[2 * i + 1] = mvd_absy
    }
  }
}

///|
/// `weight_h264_pixels*`: in-place explicit weighted prediction over a
/// rectangle.
fn h264_weight_rect(
  plane : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
  log2_denom : Int32,
  weight : Int32,
  offset : Int32,

  bit_depth? : Int32 = 8,
) -> Unit {
  let mut off2 = offset << (bit_depth - 8 + log2_denom)
  if log2_denom != 0 {
    off2 = off2 + (1 << (log2_denom - 1))
  }
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let i = off + y * stride + x
      plane[i] = h264_clip8((plane[i] * weight + off2) >> log2_denom, bit_depth=bit_depth)
    }
  }
}

///|
/// Inter reconstruction (`mc_part_std` + `hl_decode_mb` residual half):
/// motion compensate every operation in `mc_ops`, then add the residual
/// coefficients (`mb` in the shared 768-entry layout).
fn h264_recon_inter_mb(
  ctx : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  mc_ops : Array[H264McOp],
  cbp : Int32,
  mb : Array[Int32],
  nz : Array[Int32],
  chroma_qp0 : Int32,
  chroma_qp1 : Int32,
  chroma_dc_nz : Array[Int32],
) -> Result[Unit, String] {
  let mb_idx = mb_y * ctx.mb_width + mb_x
  let info = ctx.infos[mb_idx]
  let field = ctx.mb_field
  let parity = mb_y & 1
  let ystride = h264_mb_ystride(ctx)
  let cstride = h264_mb_cstride(ctx)
  let ybase = h264_mb_ybase(ctx, mb_x, mb_y)
  let cw = 16 >> ctx.chroma_hshift
  let chh = 16 >> ctx.chroma_vshift
  let cbase = h264_mb_cbase(ctx, mb_x, mb_y)
  // Field MBs are addressed in field rows: the top and bottom MB of a pair
  // share the pair's row origin (`y_offset = 8 * (mb_y >> MB_FIELD)`).
  let field_row = (mb_y >> 1) * 16
  let field_crow = (mb_y >> 1) * chh
  for op_idx = 0; op_idx < mc_ops.length(); op_idx = op_idx + 1 {
    let op = mc_ops[op_idx]
    let ref_entry = h264_ref_entry(ctx, op.ref_idx, field, parity)
    if ref_entry < 0 || ref_entry >= ctx.ref_list0.length() {
      return Err("reference \{op.ref_idx} not available")
    }
    let refpic = ctx.ref_list0[ref_entry]
    let mvx = op.mvx
    let mvy = op.mvy
    let src_y0 = if field { field_row } else { mb_y * 16 }
    h264_mc_luma(
      ctx.y,
      ybase + op.y * ystride + op.x,
      ystride,
      refpic.y,
      mb_x * 16 + op.x + (mvx >> 2),
      src_y0 + op.y + (mvy >> 2),
      refpic.ystride,
      op.w,
      op.h,
      mvx & 3,
      mvy & 3,
      refpic.width,
      refpic.height,
      sbase=refpic.base_y,
     bit_depth=ctx.bit_depth,)
    if ctx.chroma_format == 3 {
      // 4:4:4 chroma is motion compensated with the luma quarter-pel filter.
      for plane_pair in [(ctx.u, refpic.u, refpic.base_u), (ctx.v, refpic.v, refpic.base_v)] {
        let (plane, ref_plane, ref_base) = plane_pair
        h264_mc_luma(
          plane,
          cbase + op.y * cstride + op.x,
          cstride,
          ref_plane,
          mb_x * 16 + op.x + (mvx >> 2),
          src_y0 + op.y + (mvy >> 2),
          refpic.cstride,
          op.w,
          op.h,
          mvx & 3,
          mvy & 3,
          refpic.cwidth,
          refpic.cheight,
          sbase=ref_base,
         bit_depth=ctx.bit_depth,)
      }
    } else {
      let csx = op.x >> ctx.chroma_hshift
      let csy = op.y >> ctx.chroma_vshift
      let ccw = op.w >> ctx.chroma_hshift
      let cch = op.h >> ctx.chroma_vshift
      let src_cy = if field { field_crow + csy } else { mb_y * chh + csy }
      let chroma_my = if field && ctx.chroma_format == 1 {
        // Opposite-parity chroma has a half-pel vertical offset for 4:2:0
        // (`my += 2 * ((mb_y & 1) - (pic->reference - 1))`).
        mvy + 2 * (parity - (refpic.parity - 1))
      } else {
        mvy
      }
      for plane_pair in [(ctx.u, refpic.u, refpic.base_u), (ctx.v, refpic.v, refpic.base_v)] {
        let (plane, ref_plane, ref_base) = plane_pair
        h264_mc_chroma(
          plane,
          cbase + csy * cstride + csx,
          cstride,
          ref_plane,
          mb_x * cw + csx,
          src_cy,
          mvx,
          chroma_my,
          refpic.cstride,
          ccw,
          cch,
          refpic.cwidth,
          refpic.cheight,
          sbase=ref_base,
          vshift=ctx.chroma_vshift,
        )
      }
    }
    if ctx.pwt.use_weight != 0 {
      let refi = op.ref_idx
      h264_weight_rect(
        ctx.y,
        ybase + op.y * ystride + op.x,
        ystride,
        op.w,
        op.h,
        ctx.pwt.luma_log2_weight_denom,
        ctx.pwt.luma_weight_l0[refi],
        ctx.pwt.luma_offset_l0[refi],
       bit_depth=ctx.bit_depth,)
      if ctx.pwt.use_weight_chroma != 0 {
        for c = 0; c < 2; c = c + 1 {
          h264_weight_rect(
            if c == 0 { ctx.u } else { ctx.v },
            cbase + (op.y >> ctx.chroma_vshift) * cstride + (op.x >> ctx.chroma_hshift),
            cstride,
            op.w >> ctx.chroma_hshift,
            op.h >> ctx.chroma_vshift,
            ctx.pwt.chroma_log2_weight_denom,
            ctx.pwt.chroma_weight_l0[refi][c],
            ctx.pwt.chroma_offset_l0[refi][c],
           bit_depth=ctx.bit_depth,)
        }
      }
    }
  }
  // Residual: per-8x8 luma CBP bits, coefficients in z-ordered blocks.
  h264_inter_luma_add(ctx, ctx.y, ybase, ystride, cbp, mb, nz, 0, 0, info.transform_8x8)
  if ctx.chroma_format == 3 {
    h264_inter_luma_add(ctx, ctx.u, cbase, cstride, cbp, mb, nz, 16, 256, info.transform_8x8)
    h264_inter_luma_add(ctx, ctx.v, cbase, cstride, cbp, mb, nz, 32, 512, info.transform_8x8)
  } else if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
    h264_inter_chroma_residual(
      ctx, cbase, cstride, cbp, mb, nz, chroma_qp0, chroma_qp1, chroma_dc_nz,
    )
  }
  Ok(())
}

///|
/// The luma-plane residual add of `hl_decode_mb_idct_luma` for inter
/// macroblocks: per-8x8 CBP bits, 8x8 or 4x4 transforms (`nz_base`/`mb_off`
/// select the 4:4:4 chroma planes).
fn h264_inter_luma_add(
  ctx : H264DecCtx,
  dst : Array[Int32],
  base : Int32,
  stride : Int32,
  cbp : Int32,
  mb : Array[Int32],
  nz : Array[Int32],
  nz_base : Int32,
  mb_off : Int32,
  transform_8x8 : Bool,
) -> Unit {
  if (cbp & 15) == 0 {
    return
  }
  if transform_8x8 {
    for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
      if (cbp & (1 << i8x8)) != 0 {
        let off = base + (i8x8 / 2) * 8 * stride + (i8x8 % 2) * 8
        h264_idct8_add4(dst, off, stride, mb, mb_off + 64 * i8x8, nz, i8x8, nz_base=nz_base, bit_depth=ctx.bit_depth)
      }
    }
  } else {
    for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
      if (cbp & (1 << i8x8)) != 0 {
        for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
          let i = i8x8 * 4 + i4x4
          let g = h264_luma_block_grid[i]
          if nz[nz_base + g] != 0 {
            let off = base + g / 4 * 4 * stride + g % 4 * 4
            h264_idct_add(dst, off, stride, mb, mb_off + 16 * i, bit_depth=ctx.bit_depth)
          }
        }
      }
    }
  }
}

///|
/// Chroma residual + DC fold for an inter macroblock, following the yuv420/422
/// branch of `ff_h264_decode_mb_cabac` and `hl_decode_mb`: inter chroma uses
/// dequant tables 4/5 (`c + 1 + 3`) instead of the intra tables 1/2.
fn h264_inter_chroma_residual(
  ctx : H264DecCtx,
  cbase : Int32,
  stride : Int32,
  _cbp : Int32,
  mb : Array[Int32],
  nz : Array[Int32],
  chroma_qp0 : Int32,
  chroma_qp1 : Int32,
  chroma_dc_nz : Array[Int32],
) -> Unit {
  let num_c8x8 = ctx.chroma_format
  for c = 0; c < 2; c = c + 1 {
    if chroma_dc_nz[c] != 0 {
      let mut cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
      // The 2x4 DC Hadamard's gain halves the dequant scale, compensated
      // by indexing the table three QP steps up (`h264_mb_template.c`).
      if num_c8x8 == 2 {
        cqp = cqp + 3
      }
      let qmul_dc = h264_build_dequant4(ctx.pps, 4 + c, cqp)[0]
      if num_c8x8 == 2 {
        h264_chroma422_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc, bit_depth=ctx.bit_depth)
      } else {
        h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc, bit_depth=ctx.bit_depth)
      }
    }
    let plane = if c == 0 { ctx.u } else { ctx.v }
    for i = 0; i < 4 * num_c8x8; i = i + 1 {
      // 4:2:2 blocks are two vertically stacked 8x8s: `i` is
      // `8 * i8x8 + i4x4` with i4x4 the 2x2 raster inside each 8x8.
      let bx = i % 2
      let by = i / 2
      let off = cbase + by * 4 * stride + bx * 4
      let g = 16 + 16 * c + i
      if nz[g] != 0 {
        h264_idct_add(plane, off, stride, mb, 256 + 256 * c + 16 * i, bit_depth=ctx.bit_depth)
      } else if mb[256 + 256 * c + 16 * i] != 0 {
        h264_idct_dc_add(plane, off, stride, mb, 256 + 256 * c + 16 * i, bit_depth=ctx.bit_depth)
      }
    }
  }
}

///|
/// `decode_mb_skip` + `pred_pskip_motion` reconstruction for one skipped P MB.
fn h264_cabac_skip_mb(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  let nz = info.nz
  let (mx, my) = h264_pred_pskip_motion(ctx, mb_idx, mb_x, mb_y)
  h264_write_back_part(ctx, mb_idx, 0, 0, 4, 4, mx, my, 0, 0, 0)
  info.mb_type_bits = h264_mb_type_16x16 |
    h264_mb_type_p0l0 |
    h264_mb_type_p1l0 |
    h264_mb_type_skip
  info.cbp_all = 0
  info.qp = ctx.qscale
  ctx.last_qscale_diff = 0
  let empty_mb : Array[Int32] = Array::make(768, 0)
  return h264_recon_inter_mb(
    ctx,
    mb_x,
    mb_y,
    [{ x: 0, y: 0, w: 16, h: 16, mvx: mx, mvy: my, ref_idx: 0, }],
    0,
    empty_mb,
    nz,
    h264_get_chroma_qp(ctx.pps, 0, ctx.qscale, bit_depth=ctx.bit_depth),
    h264_get_chroma_qp(ctx.pps, 1, ctx.qscale, bit_depth=ctx.bit_depth),
    Array::make(2, 0),
  )
}

///|
/// `ff_h264_decode_mb_cabac`, P-slice path. The caller has already cleared
/// the per-macroblock `nz` array. Returns after reconstructing the
/// macroblock, including the `mb_skip_flag` shortcut
/// (`decode_mb_skip` + `pred_pskip_motion`).
fn h264_decode_mb_cabac_p(
  cabac : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  let rc = h264_ref_count(ctx)
  let mut dct8x8_allowed = ctx.pps.transform_8x8_mode != 0
  // decode_cabac_mb_type (P branch)
  let mb_type = match
    h264_cabac_p_mb_type(cabac, states, ctx, mb_idx, mb_x, mb_y) {
    Ok(t) => t
    Err(intra) => {
      if intra == 25 {
        return h264_decode_pcm_cabac(cabac, ctx, mb_idx, mb_x, mb_y)
      }
      ctx.cur_mb_is_intra = true
      let modes : Array[Int32] = Array::make(16, 0)
      return h264_decode_mb_cabac_intra(
        cabac, states, ctx, mb_idx, mb_x, mb_y, intra, modes,
      )
    }
  }
  ctx.cur_mb_is_intra = false
  let mc_ops : Array[H264McOp] = []
  let mut mb_type_bits = 0
  // Motion: per-partition reference index, prediction and mvd.
  if mb_type == 0 {
    // P_L0_16x16
    let refi = if rc > 1 {
      match
        h264_cabac_mb_ref(cabac, states, ctx, mb_idx, mb_x, mb_y, 0, 0, rc) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    } else {
      0
    }
    h264_write_back_ref(ctx, mb_idx, 0, 0, 4, 4, refi)
    let (pmvx, pmvy) = h264_pred_motion(ctx, mb_idx, mb_x, mb_y, 0, 0, 4, refi)
    let (mvx, mvy, ax, ay) = match
      h264_cabac_read_mvd(
        cabac, states, ctx, mb_idx, mb_x, mb_y, 0, 0, pmvx, pmvy,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    h264_write_back_part(ctx, mb_idx, 0, 0, 4, 4, mvx, mvy, refi, ax, ay)
    mc_ops.push({ x: 0, y: 0, w: 16, h: 16, mvx, mvy, ref_idx: refi, })
    mb_type_bits = h264_mb_type_16x16 | h264_mb_type_p0l0
  } else if mb_type == 1 {
    // P_L0_L0_16x8
    let refs : Array[Int32] = [0, 0]
    for i = 0; i < 2; i = i + 1 {
      refs[i] = if rc > 1 {
        match
          h264_cabac_mb_ref(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            0,
            2 * i,
            rc,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      } else {
        0
      }
      h264_write_back_ref(ctx, mb_idx, 0, 2 * i, 4, 2, refs[i])
    }
    for i = 0; i < 2; i = i + 1 {
      let by = 2 * i
      let refi = refs[i]
      let (pmvx, pmvy) = h264_pred_16x8_motion(ctx, mb_idx, mb_x, mb_y, i, refi)
      let (mvx, mvy, ax, ay) = match
        h264_cabac_read_mvd(
          cabac, states, ctx, mb_idx, mb_x, mb_y, 0, by, pmvx, pmvy,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      h264_write_back_part(ctx, mb_idx, 0, by, 4, 2, mvx, mvy, refi, ax, ay)
      mc_ops.push({ x: 0, y: 8 * i, w: 16, h: 8, mvx, mvy, ref_idx: refi, })
    }
    mb_type_bits = h264_mb_type_16x8 | h264_mb_type_p0l0 | h264_mb_type_p1l0
  } else if mb_type == 2 {
    // P_L0_L0_8x16
    let refs : Array[Int32] = [0, 0]
    for i = 0; i < 2; i = i + 1 {
      refs[i] = if rc > 1 {
        match
          h264_cabac_mb_ref(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            2 * i,
            0,
            rc,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      } else {
        0
      }
      h264_write_back_ref(ctx, mb_idx, 2 * i, 0, 2, 4, refs[i])
    }
    for i = 0; i < 2; i = i + 1 {
      let bx = 2 * i
      let refi = refs[i]
      let (pmvx, pmvy) = h264_pred_8x16_motion(ctx, mb_idx, mb_x, mb_y, i, refi)
      let (mvx, mvy, ax, ay) = match
        h264_cabac_read_mvd(
          cabac, states, ctx, mb_idx, mb_x, mb_y, bx, 0, pmvx, pmvy,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      h264_write_back_part(ctx, mb_idx, bx, 0, 2, 4, mvx, mvy, refi, ax, ay)
      mc_ops.push({ x: 8 * i, y: 0, w: 8, h: 16, mvx, mvy, ref_idx: refi, })
    }
    mb_type_bits = h264_mb_type_8x16 | h264_mb_type_p0l0 | h264_mb_type_p1l0
  } else {
    // P_8x8: all four sub_mb_types, then all four reference indices, then
    // the mvd pairs (`ff_h264_decode_mb_cabac`).
    let sub_types : Array[Int32] = Array::make(4, 0)
    for k = 0; k < 4; k = k + 1 {
      sub_types[k] = h264_cabac_p_sub_type(cabac, states)
    }
    // P sub-partitions have no direct mode: only their dimensions matter.
    dct8x8_allowed = dct8x8_allowed &&
      sub_types[0] == 0 &&
      sub_types[1] == 0 &&
      sub_types[2] == 0 &&
      sub_types[3] == 0
    let refs : Array[Int32] = Array::make(4, 0)
    for k = 0; k < 4; k = k + 1 {
      let x8 = k % 2
      let y8 = k / 2
      refs[k] = if rc > 1 {
        match
          h264_cabac_mb_ref(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            2 * x8,
            2 * y8,
            rc,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      } else {
        0
      }
      h264_write_back_ref(ctx, mb_idx, 2 * x8, 2 * y8, 2, 2, refs[k])
    }
    for k = 0; k < 4; k = k + 1 {
      let x8 = k % 2
      let y8 = k / 2
      let refi = refs[k]
      let subs = h264_sub_partitions(sub_types[k], x8, y8)
      for pi = 0; pi < subs.length(); pi = pi + 1 {
        let (x, y, w, h) = subs[pi]
        let (pmvx, pmvy) = h264_pred_motion(
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          x / 4,
          y / 4,
          w / 4,
          refi,
        )
        let (mvx, mvy, ax, ay) = match
          h264_cabac_read_mvd(
            cabac,
            states,
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            x / 4,
            y / 4,
            pmvx,
            pmvy,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        h264_write_back_part(
          ctx,
          mb_idx,
          x / 4,
          y / 4,
          w / 4,
          h / 4,
          mvx,
          mvy,
          refi,
          ax,
          ay,
        )
        mc_ops.push({ x, y, w, h, mvx, mvy, ref_idx: refi, })
      }
    }
    mb_type_bits = h264_mb_type_8x8 | h264_mb_type_p0l0 | h264_mb_type_p1l0
  }
  info.mb_type_bits = mb_type_bits
  h264_inter_residual_cabac(cabac, states, ctx, mb_idx, mb_x, mb_y, mc_ops, dct8x8_allowed)
}

///|
/// Shared `decode_mb_skip` (`h264_mvpred.h`): a skipped P macroblock is
/// reconstructed from the P_SKIP MV prediction with reference 0, no
/// residual, `cbp` 0 and the slice QP.
fn h264_decode_mb_skip_common(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  let (mx, my) = h264_pred_pskip_motion(ctx, mb_idx, mb_x, mb_y)
  h264_write_back_part(ctx, mb_idx, 0, 0, 4, 4, mx, my, 0, 0, 0)
  info.mb_type_bits = h264_mb_type_16x16 |
    h264_mb_type_p0l0 |
    h264_mb_type_p1l0 |
    h264_mb_type_skip
  info.cbp_all = 0
  info.qp = ctx.qscale
  ctx.last_qscale_diff = 0
  return h264_recon_inter_mb(
    ctx,
    mb_x,
    mb_y,
    [{ x: 0, y: 0, w: 16, h: 16, mvx: mx, mvy: my, ref_idx: 0, }],
    0,
    Array::make(768, 0),
    info.nz,
    h264_get_chroma_qp(ctx.pps, 0, ctx.qscale, bit_depth=ctx.bit_depth),
    h264_get_chroma_qp(ctx.pps, 1, ctx.qscale, bit_depth=ctx.bit_depth),
    Array::make(2, 0),
  )
}

///|
/// `ff_h264_golomb_to_inter_cbp[48]` (`h264data.c`). */
let h264_golomb_to_inter_cbp : Array[Int32] = [
  0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13, 14, 6, 9, 31, 35, 37, 42,
  44, 33, 34, 36, 40, 39, 43, 45, 46, 17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29,
  30, 22, 25, 38, 41,
]

///|
/// `ff_h264_decode_mb_cavlc`, P-slice inter path. `mb_type_raw` is the
/// ue(v) `mb_type` 0..4 (0 P_L0_16x16, 1 P_L0_16x8, 2 P_L0_8x16, 3/4 P_8x8);
/// values >= 5 (intra) are handled by the caller.
fn h264_decode_mb_cavlc_p(
  gb : BitReader,
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  mb_type_raw : Int32,
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  let rc = h264_ref_count(ctx)
  ctx.cur_mb_is_intra = false
  let mc_ops : Array[H264McOp] = []
  let mut mb_type_bits = 0
  // Reads one L0 mvd pair (se(v), se(v)) for the block at (bx, by).
  fn read_mvd_se(
    gb : BitReader,
    _ctx : H264DecCtx,
    _mb_idx : Int32,
    _mb_x : Int32,
    _mb_y : Int32,
    _bx : Int32,
    _by : Int32,
    pmvx : Int32,
    pmvy : Int32,
  ) -> (Int32, Int32, Int32, Int32) {
    let mvx = pmvx + gb.read_se()
    let mvy = pmvy + gb.read_se()
    let ax = if mvx - pmvx < 0 { pmvx - mvx } else { mvx - pmvx }
    let ay = if mvy - pmvy < 0 { pmvy - mvy } else { mvy - pmvy }
    (mvx, mvy, if ax < 70 { ax } else { 70 }, if ay < 70 { ay } else { 70 })
  }
  // Reads one ref_idx_l0 when more than one reference is active;
  // `ref_count == 2` is a single inverted bit (`h264_cavlc.c`).
  fn read_ref(
    gb : BitReader,
    rc : Int32,
    bx : Int32,
    by : Int32,
  ) -> Result[Int32, String] {
    if rc <= 1 {
      return Ok(0)
    }
    let r = if rc == 2 {
      (gb.read1() ^ 1U).reinterpret_as_int()
    } else {
      gb.read_ue()
    }
    if r < 0 || r >= rc {
      return Err("ref_idx_l0 out of range at block (\{bx},\{by})")
    }
    Ok(r)
  }
  if mb_type_raw == 0 {
    let ref_idx = match read_ref(gb, rc, 0, 0) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let (pmvx, pmvy) = h264_pred_motion(
      ctx, mb_idx, mb_x, mb_y, 0, 0, 4, ref_idx,
    )
    let (mvx, mvy, ax, ay) = read_mvd_se(
      gb, ctx, mb_idx, mb_x, mb_y, 0, 0, pmvx, pmvy,
    )
    h264_write_back_part(ctx, mb_idx, 0, 0, 4, 4, mvx, mvy, ref_idx, ax, ay)
    mc_ops.push({ x: 0, y: 0, w: 16, h: 16, mvx, mvy, ref_idx, })
    mb_type_bits = h264_mb_type_16x16 | h264_mb_type_p0l0
  } else if mb_type_raw == 1 || mb_type_raw == 2 {
    // P_L0_16x8 (1) / P_L0_8x16 (2): both reference indices are read
    // before the mvd pairs (`h264_cavlc.c`).
    let refs : Array[Int32] = [0, 0]
    for i = 0; i < 2; i = i + 1 {
      if mb_type_raw == 1 {
        refs[i] = match read_ref(gb, rc, 0, 2 * i) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      } else {
        refs[i] = match read_ref(gb, rc, 2 * i, 0) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
    for i = 0; i < 2; i = i + 1 {
      let ref_idx = refs[i]
      if mb_type_raw == 1 {
        let by = 2 * i
        let (pmvx, pmvy) = h264_pred_16x8_motion(
          ctx, mb_idx, mb_x, mb_y, i, ref_idx,
        )
        let (mvx, mvy, ax, ay) = read_mvd_se(
          gb, ctx, mb_idx, mb_x, mb_y, 0, by, pmvx, pmvy,
        )
        h264_write_back_part(
          ctx, mb_idx, 0, by, 4, 2, mvx, mvy, ref_idx, ax, ay,
        )
        mc_ops.push({ x: 0, y: 8 * i, w: 16, h: 8, mvx, mvy, ref_idx, })
      } else {
        let bx = 2 * i
        let (pmvx, pmvy) = h264_pred_8x16_motion(
          ctx, mb_idx, mb_x, mb_y, i, ref_idx,
        )
        let (mvx, mvy, ax, ay) = read_mvd_se(
          gb, ctx, mb_idx, mb_x, mb_y, bx, 0, pmvx, pmvy,
        )
        h264_write_back_part(
          ctx, mb_idx, bx, 0, 2, 4, mvx, mvy, ref_idx, ax, ay,
        )
        mc_ops.push({ x: 8 * i, y: 0, w: 8, h: 16, mvx, mvy, ref_idx, })
      }
    }
    mb_type_bits = if mb_type_raw == 1 {
      h264_mb_type_16x8 | h264_mb_type_p0l0 | h264_mb_type_p1l0
    } else {
      h264_mb_type_8x16 | h264_mb_type_p0l0 | h264_mb_type_p1l0
    }
  } else {
    // P_8x8 (3, or 4 = P_8x8ref0): all four sub_mb_types, then all four
    // reference indices, then the mvd pairs (`h264_cavlc.c`).
    let sub_types : Array[Int32] = Array::make(4, 0)
    for k = 0; k < 4; k = k + 1 {
      let sub = gb.read_ue()
      if sub < 0 || sub > 3 {
        return Err("sub_mb_type out of range")
      }
      sub_types[k] = sub
    }
    let refs : Array[Int32] = Array::make(4, 0)
    for k = 0; k < 4; k = k + 1 {
      let x8 = k % 2
      let y8 = k / 2
      refs[k] = match read_ref(gb, if mb_type_raw == 4 { 1 } else { rc }, 2 * x8, 2 * y8) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    for k = 0; k < 4; k = k + 1 {
      let x8 = k % 2
      let y8 = k / 2
      let ref_idx = refs[k]
      let subs = h264_sub_partitions(sub_types[k], x8, y8)
      for pi = 0; pi < subs.length(); pi = pi + 1 {
        let (x, y, w, h) = subs[pi]
        let (pmvx, pmvy) = h264_pred_motion(
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          x / 4,
          y / 4,
          w / 4,
          ref_idx,
        )
        let (mvx, mvy, ax, ay) = read_mvd_se(
          gb,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          x / 4,
          y / 4,
          pmvx,
          pmvy,
        )
        h264_write_back_part(
          ctx,
          mb_idx,
          x / 4,
          y / 4,
          w / 4,
          h / 4,
          mvx,
          mvy,
          ref_idx,
          ax,
          ay,
        )
        mc_ops.push({ x, y, w, h, mvx, mvy, ref_idx, })
      }
    }
    mb_type_bits = h264_mb_type_8x8 | h264_mb_type_p0l0 | h264_mb_type_p1l0
  }
  info.mb_type_bits = mb_type_bits
  h264_inter_residual_cavlc(gb, ctx, mb_idx, mb_x, mb_y, mc_ops, mc_ops.all(fn(part) { part.w >= 8 && part.h >= 8 }))
}

///|
fn h264_inter_residual_cabac(
  cabac : CabacContext, states : Array[Int32], ctx : H264DecCtx,
  mb_idx : Int32, mb_x : Int32, mb_y : Int32, mc_ops : Array[H264McOp], dct8x8_allowed : Bool,
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  let nz = info.nz
  // cbp (inter): luma + chroma (4:4:4 and 4:0:0 code no chroma bits).
  let cbp_luma = h264_cabac_mb_cbp_luma(cabac, states, ctx, mb_idx, mb_x, mb_y)
  let cbp = if ctx.chroma_format == 0 || ctx.chroma_format == 3 {
    cbp_luma
  } else {
    let cbp_chroma = h264_cabac_mb_cbp_chroma(
      cabac, states, ctx, mb_idx, mb_x, mb_y,
    )
    cbp_luma | (cbp_chroma << 4)
  }
  info.cbp_all = cbp
  if dct8x8_allowed && (cbp & 15) != 0 {
    info.transform_8x8 = cabac.get_cabac(
      states,
      399 + h264_neighbor_transform_size(ctx, mb_idx, mb_x, mb_y),
    ) != 0
  }
  let mb : Array[Int32] = Array::make(768, 0)
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let mut chroma_qp0 = h264_get_chroma_qp(ctx.pps, 0, ctx.qscale, bit_depth=ctx.bit_depth)
  let mut chroma_qp1 = h264_get_chroma_qp(ctx.pps, 1, ctx.qscale, bit_depth=ctx.bit_depth)
  if cbp != 0 {
    // decode_cabac_mb_dqp (same contexts as the intra path).
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
      chroma_qp0 = h264_get_chroma_qp(ctx.pps, 0, q, bit_depth=ctx.bit_depth)
      chroma_qp1 = h264_get_chroma_qp(ctx.pps, 1, q, bit_depth=ctx.bit_depth)
    } else {
      ctx.last_qscale_diff = 0
    }
    let plane_count = if ctx.chroma_format == 3 { 3 } else { 1 }
    let chroma_qps = [0, chroma_qp0, chroma_qp1]
    for p = 0; p < plane_count; p = p + 1 {
      match
        h264_cabac_luma_residual(
          cabac, states, ctx, mb_idx, mb_x, mb_y, false, cbp, p,
          chroma_qps[p], 3, mb, [Array::make(16, 0), Array::make(16, 0), Array::make(16, 0)],
          Array::make(3, 0), nz,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
      let num_c8x8 = ctx.chroma_format
      // Chroma: inter dequant tables 4/5.
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
              if num_c8x8 == 2 { h264_chroma422_dc_scan } else { h264_chroma_dc_scan },
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
          let qmul_c = h264_build_dequant4(ctx.pps, 4 + c, cqp)
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
    ctx.last_qscale_diff = 0
  }
  info.qp = ctx.qscale
  return h264_recon_inter_mb(
    ctx, mb_x, mb_y, mc_ops, cbp, mb, nz, chroma_qp0, chroma_qp1, chroma_dc_nz,
  )
}

///|
fn h264_inter_residual_cavlc(
  gb : BitReader, ctx : H264DecCtx, mb_idx : Int32, mb_x : Int32, mb_y : Int32,
  mc_ops : Array[H264McOp], dct8x8_allowed : Bool,
) -> Result[Unit, String] {
  let pps = ctx.pps
  let info = ctx.infos[mb_idx]
  let nz = info.nz
  // Inter cbp: `ff_h264_golomb_to_inter_cbp` (gray variant for 4:4:4/4:0:0).
  let cbp_code = gb.read_ue31()
  let cbp = if ctx.chroma_format == 0 || ctx.chroma_format == 3 {
    if cbp_code < 0 || cbp_code > 15 {
      return Err("cbp out of range")
    }
    h264_golomb_to_inter_cbp_gray[cbp_code]
  } else {
    if cbp_code < 0 || cbp_code > 47 {
      return Err("cbp out of range")
    }
    h264_golomb_to_inter_cbp[cbp_code]
  }
  info.cbp_all = cbp
  info.transform_8x8 = ctx.pps.transform_8x8_mode != 0 && dct8x8_allowed &&
    (cbp & 15) != 0 && gb.read1() != 0U
  let mb : Array[Int32] = Array::make(768, 0)
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let mut chroma_qp0 = h264_get_chroma_qp(pps, 0, ctx.qscale, bit_depth=ctx.bit_depth)
  let mut chroma_qp1 = h264_get_chroma_qp(pps, 1, ctx.qscale, bit_depth=ctx.bit_depth)
  if cbp != 0 {
    let dquant = gb.read_se()
    if dquant == -2147483648 {
      return Err("invalid mb_qp_delta")
    }
    let mut q = ctx.qscale + dquant
    if q < 0 || q > h264_max_qp(ctx) {
      q = if q < 0 { q + h264_max_qp(ctx) + 1 } else { q - h264_max_qp(ctx) - 1 }
      if q < 0 || q > h264_max_qp(ctx) {
        return Err("dquant out of range")
      }
    }
    ctx.qscale = q
    chroma_qp0 = h264_get_chroma_qp(pps, 0, q, bit_depth=ctx.bit_depth)
    chroma_qp1 = h264_get_chroma_qp(pps, 1, q, bit_depth=ctx.bit_depth)
    let plane_count = if ctx.chroma_format == 3 { 3 } else { 1 }
    let chroma_qps = [0, chroma_qp0, chroma_qp1]
    for p = 0; p < plane_count; p = p + 1 {
      let plane_qp = if p == 0 { ctx.qscale } else { chroma_qps[p] }
      if info.transform_8x8 {
        match h264_cavlc_luma8(gb, ctx, mb_idx, mb_x, mb_y, cbp, 3 + p, plane_qp, 16 * p, 256 * p, mb) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      } else {
        for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
          if (cbp & (1 << i8x8)) != 0 {
            for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
              let i = i8x8 * 4 + i4x4
              let gx = h264_luma_block_x[i]
              let gy = h264_luma_block_y[i]
              let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz, base=16 * p)
              let total = match
                h264_decode_residual(
                  gb,
                  mb,
                  256 * p + 16 * i,
                  h264_scan4(ctx),
                  0,
                  Some(h264_build_dequant4(pps, 3 + p, plane_qp)),
                  16,
                  nc,
                 bit_depth=ctx.bit_depth,) {
                Ok(v) => v
                Err(e) => return Err(e)
              }
              nz[16 * p + gy * 4 + gx] = total
            }
          }
        }
      }
    }
    if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
      let num_c8x8 = ctx.chroma_format
      if (cbp & 0x30) != 0 {
        for c = 0; c < 2; c = c + 1 {
          chroma_dc_nz[c] = match
            h264_decode_residual(
              gb,
              mb,
              256 + 256 * c,
              if num_c8x8 == 2 { h264_chroma422_dc_scan } else { h264_chroma_dc_scan },
              0,
              None,
              4 * num_c8x8,
              0,
             bit_depth=ctx.bit_depth,) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
        }
      }
      if (cbp & 0x20) != 0 {
        for c = 0; c < 2; c = c + 1 {
          let cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
          let qmul_c = h264_build_dequant4(pps, 4 + c, cqp)
          for i = 0; i < 4 * num_c8x8; i = i + 1 {
            let nc = if num_c8x8 == 2 {
              h264_nc_chroma_422(ctx, mb_idx, c, i, nz)
            } else {
              h264_nc_chroma(ctx, mb_idx, mb_x, mb_y, c, i, nz)
            }
            let total = match
              h264_decode_residual(
                gb,
                mb,
                256 + 256 * c + 16 * i,
                h264_scan4(ctx),
                1,
                Some(qmul_c),
                15,
                nc,
               bit_depth=ctx.bit_depth,) {
              Ok(v) => v
              Err(e) => return Err(e)
            }
            nz[16 + 16 * c + i] = total
          }
        }
      }
    }
  } else {
    ctx.last_qscale_diff = 0
  }
  info.qp = ctx.qscale
  return h264_recon_inter_mb(
    ctx, mb_x, mb_y, mc_ops, cbp, mb, nz, chroma_qp0, chroma_qp1, chroma_dc_nz,
  )
}
