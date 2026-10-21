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
  if mb_x > 0 {
    let l = ctx.infos[mb_idx - 1]
    if l.mb_type_bits != 0 && (l.mb_type_bits & h264_mb_type_skip) == 0 {
      c = c + 1
    }
  }
  if mb_y > 0 {
    let t = ctx.infos[mb_idx - ctx.mb_width]
    if t.mb_type_bits != 0 && (t.mb_type_bits & h264_mb_type_skip) == 0 {
      c = c + 1
    }
  }
  cabac.get_cabac(states, 11 + c)
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
  if refa > 0 {
    c = c + 1
  }
  if refb > 0 {
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
  for y = 0; y < bh; y = y + 1 {
    for x = 0; x < bw; x = x + 1 {
      info.ref_idx[(by + y) * 4 + bx + x] = refi
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
  for y = 0; y < bh; y = y + 1 {
    for x = 0; x < bw; x = x + 1 {
      let i = (by + y) * 4 + bx + x
      info.mv[2 * i] = mvx
      info.mv[2 * i + 1] = mvy
      info.ref_idx[i] = refi
      info.mvd[2 * i] = mvd_absx
      info.mvd[2 * i + 1] = mvd_absy
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
) -> Unit {
  let mut off2 = offset << log2_denom
  if log2_denom != 0 {
    off2 = off2 + (1 << (log2_denom - 1))
  }
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let i = off + y * stride + x
      plane[i] = clip_uint8((plane[i] * weight + off2) >> log2_denom)
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
  qmul_luma : Array[Int32],
  chroma_dc_nz : Array[Int32],
) -> Result[Unit, String] {
  let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
  let cbase = mb_y * 8 * ctx.cstride + mb_x * 8
  for op_idx = 0; op_idx < mc_ops.length(); op_idx = op_idx + 1 {
    let op = mc_ops[op_idx]
    if op.ref_idx < 0 || op.ref_idx >= ctx.ref_list0.length() {
      return Err("reference \{op.ref_idx} not available")
    }
    let refpic = ctx.ref_list0[op.ref_idx]
    h264_mc_luma(
      ctx.y,
      ybase + op.y * ctx.ystride + op.x,
      ctx.ystride,
      refpic.y,
      mb_x * 16 + op.x + (op.mvx >> 2),
      mb_y * 16 + op.y + (op.mvy >> 2),
      refpic.ystride,
      op.w,
      op.h,
      op.mvx & 3,
      op.mvy & 3,
      refpic.width,
      refpic.height,
    )
    h264_mc_chroma(
      ctx.u,
      cbase + op.y / 2 * ctx.cstride + op.x / 2,
      ctx.cstride,
      refpic.u,
      mb_x * 8 + op.x / 2,
      mb_y * 8 + op.y / 2,
      op.mvx,
      op.mvy,
      refpic.cstride,
      op.w / 2,
      op.h / 2,
      refpic.width / 2,
      refpic.height / 2,
    )
    h264_mc_chroma(
      ctx.v,
      cbase + op.y / 2 * ctx.cstride + op.x / 2,
      ctx.cstride,
      refpic.v,
      mb_x * 8 + op.x / 2,
      mb_y * 8 + op.y / 2,
      op.mvx,
      op.mvy,
      refpic.cstride,
      op.w / 2,
      op.h / 2,
      refpic.width / 2,
      refpic.height / 2,
    )
    if ctx.pwt.use_weight != 0 {
      let refi = op.ref_idx
      h264_weight_rect(
        ctx.y,
        ybase + op.y * ctx.ystride + op.x,
        ctx.ystride,
        op.w,
        op.h,
        ctx.pwt.luma_log2_weight_denom,
        ctx.pwt.luma_weight_l0[refi],
        ctx.pwt.luma_offset_l0[refi],
      )
      if ctx.pwt.use_weight_chroma != 0 {
        for c = 0; c < 2; c = c + 1 {
          h264_weight_rect(
            if c == 0 { ctx.u } else { ctx.v },
            cbase + op.y / 2 * ctx.cstride + op.x / 2,
            ctx.cstride,
            op.w / 2,
            op.h / 2,
            ctx.pwt.chroma_log2_weight_denom,
            ctx.pwt.chroma_weight_l0[refi][c],
            ctx.pwt.chroma_offset_l0[refi][c],
          )
        }
      }
    }
  }
  // Residual: per-8x8 luma CBP bits, coefficients in z-ordered blocks.
  ignore(qmul_luma)
  if (cbp & 15) != 0 {
    for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
      if (cbp & (1 << i8x8)) != 0 {
        for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
          let i = i8x8 * 4 + i4x4
          let g = h264_luma_block_grid[i]
          if nz[g] != 0 {
            let off = ybase + g / 4 * 4 * ctx.ystride + g % 4 * 4
            h264_idct_add(ctx.y, off, ctx.ystride, mb, 16 * i)
          }
        }
      }
    }
  }
  h264_inter_chroma_residual(
    ctx, cbase, cbp, mb, nz, chroma_qp0, chroma_qp1, chroma_dc_nz,
  )
  Ok(())
}

///|
/// Chroma residual + DC fold for an inter macroblock, following the yuv420
/// branch of `ff_h264_decode_mb_cabac` and `hl_decode_mb`: inter chroma uses
/// dequant tables 4/5 (`c + 1 + 3`) instead of the intra tables 1/2.
fn h264_inter_chroma_residual(
  ctx : H264DecCtx,
  cbase : Int32,
  _cbp : Int32,
  mb : Array[Int32],
  nz : Array[Int32],
  chroma_qp0 : Int32,
  chroma_qp1 : Int32,
  chroma_dc_nz : Array[Int32],
) -> Unit {
  for c = 0; c < 2; c = c + 1 {
    if chroma_dc_nz[c] != 0 {
      let cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
      let qmul_dc = h264_build_dequant4(ctx.pps, 4 + c, cqp)[0]
      h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc)
    }
    let plane = if c == 0 { ctx.u } else { ctx.v }
    for i = 0; i < 4; i = i + 1 {
      let off = cbase + i / 2 * 4 * ctx.cstride + i % 2 * 4
      let g = 16 + 16 * c + i
      if nz[g] != 0 {
        h264_idct_add(plane, off, ctx.cstride, mb, 256 + 256 * c + 16 * i)
      } else if mb[256 + 256 * c + 16 * i] != 0 {
        h264_idct_dc_add(plane, off, ctx.cstride, mb, 256 + 256 * c + 16 * i)
      }
    }
  }
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
  let nz = info.nz
  let rc = ctx.ref_count0
  // decode_cabac_mb_skip
  if h264_cabac_mb_skip(cabac, states, ctx, mb_idx, mb_x, mb_y) != 0 {
    // decode_mb_skip + pred_pskip_motion
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
      h264_get_chroma_qp(ctx.pps, 0, ctx.qscale),
      h264_get_chroma_qp(ctx.pps, 1, ctx.qscale),
      [],
      Array::make(2, 0),
    )
  }
  // decode_cabac_mb_type (P branch)
  let mb_type = match
    h264_cabac_p_mb_type(cabac, states, ctx, mb_idx, mb_x, mb_y) {
    Ok(t) => t
    Err(intra) => {
      if intra == 25 {
        return Err("I_PCM in a CABAC slice is not supported")
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
  // cbp (inter): luma + chroma.
  let cbp_luma = h264_cabac_mb_cbp_luma(cabac, states, ctx, mb_idx, mb_x, mb_y)
  let cbp_chroma = h264_cabac_mb_cbp_chroma(
    cabac, states, ctx, mb_idx, mb_x, mb_y,
  )
  let cbp = cbp_luma | (cbp_chroma << 4)
  info.cbp_all = cbp
  let mb : Array[Int32] = Array::make(768, 0)
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let mut chroma_qp0 = h264_get_chroma_qp(ctx.pps, 0, ctx.qscale)
  let mut chroma_qp1 = h264_get_chroma_qp(ctx.pps, 1, ctx.qscale)
  let mut qmul_luma : Array[Int32] = []
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
        if val > 2 * 51 {
          return Err("cabac decode of qscale diff failed")
        }
      }
      val = if (val & 0x01) != 0 { (val + 1) >> 1 } else { -((val + 1) >> 1) }
      ctx.last_qscale_diff = val
      let mut q = ctx.qscale + val
      if q < 0 {
        q = q + 52
      } else if q > 51 {
        q = q - 52
      }
      ctx.qscale = q
      chroma_qp0 = h264_get_chroma_qp(ctx.pps, 0, q)
      chroma_qp1 = h264_get_chroma_qp(ctx.pps, 1, q)
    } else {
      ctx.last_qscale_diff = 0
    }
    qmul_luma = h264_build_dequant4(ctx.pps, 0, ctx.qscale)
    // Luma AC (cat 2), z-order blocks per 8x8 CBP bit.
    for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
      if (cbp & (1 << i8x8)) != 0 {
        for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
          let i = 4 * i8x8 + i4x4
          match
            h264_cabac_residual(
              cabac,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              mb,
              16 * i,
              2,
              i,
              nz,
              h264_zigzag_scan_t,
              0,
              Some(qmul_luma),
              16,
              false,
            ) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
    }
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
            h264_chroma_dc_scan,
            0,
            None,
            4,
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
        for i = 0; i < 4; i = i + 1 {
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
              h264_zigzag_scan_t,
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
  } else {
    ctx.last_qscale_diff = 0
  }
  info.qp = ctx.qscale
  return h264_recon_inter_mb(
    ctx, mb_x, mb_y, mc_ops, cbp, mb, nz, chroma_qp0, chroma_qp1, qmul_luma, chroma_dc_nz,
  )
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
    h264_get_chroma_qp(ctx.pps, 0, ctx.qscale),
    h264_get_chroma_qp(ctx.pps, 1, ctx.qscale),
    [],
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
  let pps = ctx.pps
  let info = ctx.infos[mb_idx]
  let nz = info.nz
  let rc = ctx.ref_count0
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
      refs[k] = match read_ref(gb, rc, 2 * x8, 2 * y8) {
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
  // Inter cbp: `ff_h264_golomb_to_inter_cbp`.
  let cbp_code = gb.read_ue31()
  if cbp_code < 0 || cbp_code > 47 {
    return Err("cbp out of range")
  }
  let cbp = h264_golomb_to_inter_cbp[cbp_code]
  info.cbp_all = cbp
  let mb : Array[Int32] = Array::make(768, 0)
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let mut chroma_qp0 = h264_get_chroma_qp(pps, 0, ctx.qscale)
  let mut chroma_qp1 = h264_get_chroma_qp(pps, 1, ctx.qscale)
  let mut qmul_luma : Array[Int32] = []
  if cbp != 0 {
    let dquant = gb.read_se()
    if dquant == -2147483648 {
      return Err("invalid mb_qp_delta")
    }
    let mut q = ctx.qscale + dquant
    if q < 0 || q > 51 {
      q = if q < 0 { q + 52 } else { q - 52 }
      if q < 0 || q > 51 {
        return Err("dquant out of range")
      }
    }
    ctx.qscale = q
    chroma_qp0 = h264_get_chroma_qp(pps, 0, q)
    chroma_qp1 = h264_get_chroma_qp(pps, 1, q)
    qmul_luma = h264_build_dequant4(pps, 0, q)
    for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
      if (cbp & (1 << i8x8)) != 0 {
        for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
          let i = i8x8 * 4 + i4x4
          let gx = h264_luma_block_x[i]
          let gy = h264_luma_block_y[i]
          let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz)
          let total = match
            h264_decode_residual(
              gb,
              mb,
              16 * i,
              h264_zigzag_scan_t,
              0,
              Some(qmul_luma),
              16,
              nc,
            ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          nz[gy * 4 + gx] = total
        }
      }
    }
    if (cbp & 0x30) != 0 {
      for c = 0; c < 2; c = c + 1 {
        chroma_dc_nz[c] = match
          h264_decode_residual(
            gb,
            mb,
            256 + 256 * c,
            h264_chroma_dc_scan,
            0,
            None,
            4,
            0,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
    if (cbp & 0x20) != 0 {
      for c = 0; c < 2; c = c + 1 {
        let cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
        let qmul_c = h264_build_dequant4(pps, 4 + c, cqp)
        for i = 0; i < 4; i = i + 1 {
          let nc = h264_nc_chroma(ctx, mb_idx, mb_x, mb_y, c, i, nz)
          let total = match
            h264_decode_residual(
              gb,
              mb,
              256 + 256 * c + 16 * i,
              h264_zigzag_scan_t,
              1,
              Some(qmul_c),
              15,
              nc,
            ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          nz[16 + 16 * c + i] = total
        }
      }
    }
  } else {
    ctx.last_qscale_diff = 0
  }
  info.qp = ctx.qscale
  return h264_recon_inter_mb(
    ctx, mb_x, mb_y, mc_ops, cbp, mb, nz, chroma_qp0, chroma_qp1, qmul_luma, chroma_dc_nz,
  )
}
