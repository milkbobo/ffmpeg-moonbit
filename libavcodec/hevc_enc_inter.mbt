///|
/// HEVC P-slice encoder, slice 2 of the port: inter CUs with a single L0
/// reference (the previous reconstructed picture), PART_2Nx2N only, a two-stage
/// integer + quarter-pel luma motion search, merge or AMVP signalling, and the
/// residual coded through the same TU path slice 1 uses for intra.
///
/// Mirror discipline (same as slice 1): every bin is written where
/// `hevc_decode_ctb`/`coding_quadtree`/`coding_unit` reads one; the merge
/// candidate list and the AMVP predictor come from the decoder's own
/// `hevc_derive_spatial_merge_candidates`/`hevc_luma_mv_mvp_mode`; motion
/// compensation — including the fractional-pel search metric — runs the
/// decoder's `hevc_luma_mc_uni`/`hevc_chroma_mc_uni` kernels, so the encoder's
/// reconstruction is the decoder's prediction by construction.
///
/// Out of scope for this slice: B slices, multiple references, sub-2Nx2N
/// partitions, temporal MVP, weighted prediction, and intra CUs inside a P
/// picture (every CU is coded inter, so this is not yet a mode-decision
/// encoder).

///|
/// Integer-pel search range in luma samples around the co-located position. */
let hevc_enc_me_range : Int32 = 16

///|
/// Reference lists for the encoder's inter context: one L0 entry (the previous
/// picture, POC `cur_poc - 1`) and an empty L1. The merge and AMVP derivations
/// read `rpl[list].poc(idx)` to decide whether a neighbour's MV applies to the
/// same reference; both list slots must exist even though a P slice only ever
/// codes L0.
fn hevc_enc_make_rpl(
  _cur_poc : Int32,
  slice_type : Int32,
  l0_poc : Int32,
  l1_poc : Int32,
) -> Array[HevcRefPicList] {
  let mk = fn(poc : Int32) -> HevcRefFrame {
    {
      slot: 0,
      poc,
      pic: hevc_picture_new(0, 0, 0, 0),
      tab_mvf: [],
      rpl0: hevc_ref_pic_list_new(),
      rpl1: hevc_ref_pic_list_new(),
      short_ref: true,
      long_ref: false,
      unavailable: false,
      in_use: true,
    }
  }
  let l0 = hevc_ref_pic_list_new()
  l0.push(l0_poc, false, mk(l0_poc))
  let l1 = hevc_ref_pic_list_new()
  if slice_type == hevc_slice_b {
    // The B slice's inline RPS lists the positive picture on L1.
    l1.push(l1_poc, false, mk(l1_poc))
  }
  [l0, l1]
}

///|
/// Edge-replicating coordinate clamp (`ff_emulated_edge_mc`'s border rule for
/// integer MVs). */
fn hevc_enc_clamp_i(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
/// Sum of absolute differences between a source block and the reference block
/// displaced by `mv` (quarter-pel units; this search passes multiples of
/// four). Out-of-picture samples replicate the border, matching the MC
/// kernel's edge emulation. */
fn hevc_enc_sad_mv(
  src : FixedArray[Int32],
  src_stride : Int32,
  refp : Array[Int32],
  ref_stride : Int32,
  rh : Int32,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Int64 {
  let dx = mvx >> 2
  let dy = mvy >> 2
  let mut sad = 0L
  for j in 0..<size {
    let ry = hevc_enc_clamp_i(y0 + j + dy, rh)
    for i in 0..<size {
      let rx = hevc_enc_clamp_i(x0 + i + dx, ref_stride)
      let d = src[(y0 + j) * src_stride + x0 + i] - refp[ry * ref_stride + rx]
      sad = sad + (if d < 0 { -d } else { d }).to_int64()
    }
  }
  sad
}

///|
/// Integer-pel motion search for one `size` x `size` luma block: exhaustive
/// over `[-range, range]`, ties going to the smaller displacement so a static
/// picture keeps MV 0. Returns the MV in quarter-pel units with its SAD. */
fn hevc_enc_me_search(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
) -> (Int32, Int32, Int64) {
  let refp = ctx.ref_pic.y
  let rw = ctx.ref_pic.width
  let rh = ctx.ref_pic.height
  let src = ctx.src_y
  let stride = ctx.sps.width
  let mut best_mvx = 0
  let mut best_mvy = 0
  let mut best = hevc_enc_sad_mv(src, stride, refp, rw, rh, x0, y0, size, 0, 0)
  let mut dy = -hevc_enc_me_range
  while dy <= hevc_enc_me_range {
    let mut dx = -hevc_enc_me_range
    while dx <= hevc_enc_me_range {
      if dx != 0 || dy != 0 {
        let cost = hevc_enc_sad_mv(
          src,
          stride,
          refp,
          rw,
          rh,
          x0,
          y0,
          size,
          dx * 4,
          dy * 4,
        )
        if cost < best {
          best = cost
          best_mvx = dx * 4
          best_mvy = dy * 4
        }
      }
      dx = dx + 1
    }
    dy = dy + 1
  }
  // Quarter-pel refinement around the best integer position: run the
  // decoder's own MC kernel on a scratch picture and score the *final*
  // prediction samples, so the search metric is exactly what the decoder
  // will reconstruct. Searching the 4x4 sub-pel grid is cheap (16 MC calls)
  // and a `top_left` tie keeps integer MVs stable on static content.
  let refp = ctx.ref_pic
  let bd = ctx.sps.bit_depth
  let scratch = hevc_picture_new(ctx.sps.width, ctx.sps.height, 0, 0)
  let mut fmvx = best_mvx
  let mut fmvy = best_mvy
  let mut fbest = best
  for fy in 0..<4 {
    for fx in 0..<4 {
      if fx != 0 || fy != 0 {
        let (mx, my) = (best_mvx + fx, best_mvy + fy)
        hevc_luma_mc_uni(
          refp.y,
          refp.width,
          refp.width,
          refp.height,
          scratch.y,
          scratch.width,
          x0,
          y0,
          mx,
          my,
          size,
          size,
          bd,
        )
        let mut cost = 0L
        for j in 0..<size {
          for i in 0..<size {
            let d = src[(y0 + j) * stride + x0 + i] -
              scratch.y[(y0 + j) * scratch.width + x0 + i]
            cost = cost + (if d < 0 { -d } else { d }).to_int64()
          }
        }
        if cost < fbest {
          fbest = cost
          fmvx = mx
          fmvy = my
        }
      }
    }
  }
  (fmvx, fmvy, fbest)
}

///|
/// Side-effect-free intra prediction search over all 35 luma modes for RD
/// comparison. Predictions go into a scratch picture (never `ctx.pic`), and
/// neither CABAC bins nor the mode tables are written. Returns the best mode
/// and its SAD with the same non-MPM regulariser the I-slice search uses.
fn hevc_enc_intra_eval(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  log2_cb_size : Int32,
) -> (Int32, Int64) {
  let sps = ctx.sps
  hevc_enc_set_na(ctx, x0, y0, size, size)
  let candidates = hevc_enc_mpm_candidates(ctx, x0, y0)
  let scratch = hevc_picture_new(sps.width, sps.height, 0, 0)
  let mut best_mode = 1
  let mut best_cost = -1L
  for mode in 0..<35 {
    hevc_intra_predict(
      scratch,
      sps,
      ctx.pps,
      ctx.na,
      x0,
      y0,
      log2_cb_size,
      0,
      mode,
    )
    let mut sad = 0L
    for j in 0..<size {
      for i in 0..<size {
        let d = scratch.y[(y0 + j) * sps.width + x0 + i] -
          ctx.src_y[(y0 + j) * sps.width + x0 + i]
        sad = sad + (if d < 0 { -d } else { d }).to_int64()
      }
    }
    let in_mpm = mode == candidates[0] ||
      mode == candidates[1] ||
      mode == candidates[2]
    let cost = sad + (if in_mpm { 0L } else { size.to_int64() })
    if best_cost < 0L || cost < best_cost {
      best_cost = cost
      best_mode = mode
    }
  }
  (best_mode, best_cost)
}

///|
/// Mark a P-slice intra CU's motion field as intra (`PF_INTRA`), matching the
/// decoder's `intra_prediction_unit_default_value`. Without this, stale MVs
/// from an earlier inter CU would leak into the next CU's merge candidate
/// list and deblocking boundary strengths.
fn hevc_enc_mvf_intra(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
) -> Unit {
  let sps = ctx.sps
  let l2pu = sps.log2_min_pu_size
  let x_pu = x0 >> l2pu
  let y_pu = y0 >> l2pu
  let n = size >> l2pu
  for j in 0..<n {
    for i in 0..<n {
      ctx.tab_mvf[(y_pu + j) * sps.min_pu_width + x_pu + i].pred_flag = hevc_pf_intra
    }
  }
}

///|
/// Push the encoder's CTB availability into the inter context, whose fields
/// are what the merge/AMVP derivations read. */
fn hevc_enc_sync_inter(ctx : HevcEncCtx) -> Unit {
  let ic = ctx.inter
  ic.ctb_left = ctx.ctb_left
  ic.ctb_up = ctx.ctb_up
  ic.ctb_up_left = ctx.ctb_up_left
  ic.ctb_up_right = ctx.ctb_up_right
  ic.end_of_tiles_x = ctx.sps.width
  ic.end_of_tiles_y = ctx.end_of_tiles_y
  ic.ct_depth = 0
  ic.part_mode = hevc_part_2nx2n
  ic.cu_x = ctx.cur_x
  ic.cu_y = ctx.cur_y
}

///|
/// Merge candidate list for a 2Nx2N PU: `mvs.c`'s `set_neighbour_available`
/// followed by `derive_spatial_merge_candidates`. */
fn hevc_enc_merge_candidates(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
) -> Array[HevcMvField] {
  hevc_enc_sync_inter(ctx)
  let ic = ctx.inter
  ic.set_neighbour_available(x0, y0, size, size)
  let list : Array[HevcMvField] = []
  for _ in 0..<5 {
    list.push(hevc_mv_field_new())
  }
  hevc_derive_spatial_merge_candidates(ic, x0, y0, size, size, false, 0, list)
  list
}

///|
/// Index of the first merge candidate predicting exactly `(mvx, mvy)` from L0
/// reference 0, or -1. Only an exact match is used, so the encoder never picks
/// a merge whose motion it cannot reproduce. */
fn hevc_enc_merge_match(
  list : Array[HevcMvField],
  mvx : Int32,
  mvy : Int32,
  max_cand : Int32,
) -> Int32 {
  let mut idx = -1
  let mut i = 0
  while i < max_cand && i < list.length() {
    let c = list[i]
    if c.pred_flag == hevc_pf_l0 &&
      c.ref_idx0 == 0 &&
      c.mv0.x == mvx &&
      c.mv0.y == mvy {
      idx = i
      break
    }
    i = i + 1
  }
  idx
}

///|
/// AMVP predictor for L0 (`ff_hevc_luma_mv_mvp_mode` with `ref_idx0 == 0`). */
fn hevc_enc_amvp(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  flag : Int32,
) -> (Int32, Int32) {
  hevc_enc_sync_inter(ctx)
  let ic = ctx.inter
  ic.set_neighbour_available(x0, y0, size, size)
  let mv = hevc_mv_field_new()
  mv.pred_flag = hevc_pf_l0
  mv.ref_idx0 = 0
  mv.ref_idx1 = 0
  hevc_luma_mv_mvp_mode(ic, x0, y0, size, size, flag, 0, mv)
  (mv.mv0.x, mv.mv0.y)
}

///|
/// AMVP predictor for L1 (`ff_hevc_luma_mv_mvp_mode` with `lx = 1`,
/// `ref_idx1 == 0`). */
fn hevc_enc_amvp_l1(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  flag : Int32,
) -> (Int32, Int32) {
  hevc_enc_sync_inter(ctx)
  let ic = ctx.inter
  ic.set_neighbour_available(x0, y0, size, size)
  let mv = hevc_mv_field_new()
  mv.pred_flag = hevc_pf_l1
  mv.ref_idx0 = 0
  mv.ref_idx1 = 0
  hevc_luma_mv_mvp_mode(ic, x0, y0, size, size, flag, 1, mv)
  (mv.mv1.x, mv.mv1.y)
}

///|
/// One P PU's motion compensation through the decoder's kernels (unweighted
/// uni L0; the reference list has a single entry, so `ref_idx0` is 0). */
fn hevc_enc_mc_l0(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  let sps = ctx.sps
  let bd = sps.bit_depth
  let refp = ctx.ref_pic
  let pic = ctx.pic
  hevc_luma_mc_uni(
    refp.y,
    refp.width,
    refp.width,
    refp.height,
    pic.y,
    pic.width,
    x0,
    y0,
    mvx,
    mvy,
    size,
    size,
    bd,
  )
  let hs = sps.hshift[1]
  let vs = sps.vshift[1]
  let csize_w = size >> hs
  let csize_h = size >> vs
  for c in 1..<3 {
    hevc_chroma_mc_uni(
      refp.plane(c),
      refp.cw,
      refp.cw,
      refp.ch,
      pic.plane(c),
      pic.cw,
      x0 >> hs,
      y0 >> vs,
      mvx,
      mvy,
      csize_w,
      csize_h,
      bd,
      hs,
      vs,
    )
  }
}

///|
/// One PU's motion compensation for a B slice through the decoder's kernels.
/// `pred_flag` selects L0 / L1 / BI exactly as `HevcMvField::pred_flag` does;
/// the caller supplies the two reference pictures and the per-list MVs.
fn hevc_enc_mc_b(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  pred_flag : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
) -> Unit {
  let sps = ctx.sps
  let bd = sps.bit_depth
  let ref0 = ctx.ref_pic
  let ref1 = ctx.ref_pic_l1
  let pic = ctx.pic
  if pred_flag == hevc_pf_l0 {
    hevc_enc_mc_l0(ctx, x0, y0, size, mv0x, mv0y)
    return
  }
  if pred_flag == hevc_pf_l1 {
    hevc_enc_mc_l1(ctx, x0, y0, size, mv1x, mv1y)
    return
  }
  // BI: average of the two uni predictions.
  hevc_luma_mc_bi(
    ref0.y,
    ref0.width,
    ref1.y,
    ref1.width,
    ref0.width,
    ref0.height,
    pic.y,
    pic.width,
    x0,
    y0,
    mv0x,
    mv0y,
    mv1x,
    mv1y,
    size,
    size,
    bd,
  )
  let hs = sps.hshift[1]
  let vs = sps.vshift[1]
  let csize_w = size >> hs
  let csize_h = size >> vs
  for c in 1..<3 {
    hevc_chroma_mc_bi(
      ref0.plane(c),
      ref0.cw,
      ref1.plane(c),
      ref1.cw,
      ref0.cw,
      ref0.ch,
      pic.plane(c),
      pic.cw,
      x0 >> hs,
      y0 >> vs,
      mv0x,
      mv0y,
      mv1x,
      mv1y,
      csize_w,
      csize_h,
      bd,
      hs,
      vs,
    )
  }
}

///|
/// Uni L1 motion compensation (the mirror of `hevc_enc_mc_l0`). */
fn hevc_enc_mc_l1(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  let sps = ctx.sps
  let bd = sps.bit_depth
  let refp = ctx.ref_pic_l1
  let pic = ctx.pic
  hevc_luma_mc_uni(
    refp.y,
    refp.width,
    refp.width,
    refp.height,
    pic.y,
    pic.width,
    x0,
    y0,
    mvx,
    mvy,
    size,
    size,
    bd,
  )
  let hs = sps.hshift[1]
  let vs = sps.vshift[1]
  let csize_w = size >> hs
  let csize_h = size >> vs
  for c in 1..<3 {
    hevc_chroma_mc_uni(
      refp.plane(c),
      refp.cw,
      refp.cw,
      refp.ch,
      pic.plane(c),
      pic.cw,
      x0 >> hs,
      y0 >> vs,
      mvx,
      mvy,
      csize_w,
      csize_h,
      bd,
      hs,
      vs,
    )
  }
}

///|
/// Motion search against an arbitrary reference picture (the P path's
/// `hevc_enc_me_search` is hard-wired to `ctx.ref_pic`). Integer full search
/// plus the same quarter-pel refinement, returning the best MV in quarter-pel
/// units.
fn hevc_enc_me_search_ref(
  ctx : HevcEncCtx,
  refp : HevcPicture,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
) -> (Int32, Int32) {
  let sps = ctx.sps
  let src = ctx.src_y
  let stride = sps.width
  let mut best_x = 0
  let mut best_y = 0
  let mut best = hevc_enc_sad_mv(
    src,
    stride,
    refp.y,
    refp.width,
    refp.height,
    x0,
    y0,
    size,
    0,
    0,
  )
  // Integer-pel full search over a +/- 8-pel window, step 4 quarter-pels.
  let mut dy = -32
  while dy <= 32 {
    let mut dx = -32
    while dx <= 32 {
      if dx != 0 || dy != 0 {
        let sad = hevc_enc_sad_mv(
          src,
          stride,
          refp.y,
          refp.width,
          refp.height,
          x0,
          y0,
          size,
          dx,
          dy,
        )
        if sad < best {
          best = sad
          best_x = dx
          best_y = dy
        }
      }
      dx = dx + 4
    }
    dy = dy + 4
  }
  // Quarter-pel refinement around the integer minimum, on a scratch picture.
  let scratch = hevc_picture_new(
    ctx.pic.width,
    ctx.pic.height,
    ctx.pic.cw,
    ctx.pic.ch,
  )
  let bd = sps.bit_depth
  let mut fx = best_x
  let mut fy = best_y
  for sy in -1..<=1 {
    for sx in -1..<=1 {
      let cx = best_x + sx
      let cy = best_y + sy
      if sx != 0 || sy != 0 {
        hevc_luma_mc_uni(
          refp.y,
          refp.width,
          refp.width,
          refp.height,
          scratch.y,
          scratch.width,
          x0,
          y0,
          cx,
          cy,
          size,
          size,
          bd,
        )
        let sad = hevc_enc_sad_mv(
          src,
          stride,
          scratch.y,
          scratch.width,
          scratch.height,
          x0,
          y0,
          size,
          0,
          0,
        )
        if sad < best {
          best = sad
          fx = cx
          fy = cy
        }
      }
    }
  }
  (fx, fy)
}

///|
/// Merge candidate list for a B slice: the spatial derivation fills
/// `pred_flag` with L0/L1/BI per candidate, so the list is reused verbatim.
fn hevc_enc_merge_match_b(
  list : Array[HevcMvField],
  pred_flag : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
  max_cand : Int32,
) -> Int32 {
  let mut idx = -1
  let mut i = 0
  while i < max_cand && i < list.length() {
    let c = list[i]
    if c.pred_flag == pred_flag && c.ref_idx0 == 0 && c.ref_idx1 == 0 {
      let ok0 = pred_flag == hevc_pf_l1 || (c.mv0.x == mv0x && c.mv0.y == mv0y)
      let ok1 = pred_flag == hevc_pf_l0 || (c.mv1.x == mv1x && c.mv1.y == mv1y)
      if ok0 && ok1 {
        idx = i
        break
      }
    }
    i = i + 1
  }
  idx
}

///|
/// Write one inter leaf TU's residual syntax and fold the reconstruction into
/// the picture. The cbf bins follow `hls_transform_tree`'s inter branch at
/// `trafo_depth == 0`: `cbf_cb`, then `cbf_cr`, then — only when one of them is
/// set — `cbf_luma`, which is otherwise implicitly 1. */
fn hevc_enc_code_residual_inter(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  luma_levels : FixedArray[Int32],
  cb_levels : Array[FixedArray[Int32]],
  cr_levels : Array[FixedArray[Int32]],
  log2_tb : Int32,
) -> Result[Unit, String] {
  let sps = ctx.sps
  let bd = sps.bit_depth
  let n = 1 << log2_tb
  let hs = sps.hshift[1]
  let vs = sps.vshift[1]
  let log2_c = log2_tb - hs
  let nc = 1 << log2_c
  let qp_c = hevc_enc_chroma_qp_fwd(sps, ctx.qp)
  let n_cb = cb_levels.length()
  let cbf_luma_real = hevc_enc_levels_nonzero(luma_levels)
  let cbf_cb : Array[Bool] = []
  let cbf_cr : Array[Bool] = []
  for i in 0..<n_cb {
    cbf_cb.push(hevc_enc_levels_nonzero(cb_levels[i]))
  }
  for i in 0..<n_cb {
    cbf_cr.push(hevc_enc_levels_nonzero(cr_levels[i]))
  }
  let mut any_chroma = false
  for i in 0..<n_cb {
    if cbf_cb[i] || cbf_cr[i] {
      any_chroma = true
    }
  }
  for i in 0..<n_cb {
    ctx.cabac.cbf_cb_cr(0, cbf_cb[i])
  }
  for i in 0..<n_cb {
    ctx.cabac.cbf_cb_cr(0, cbf_cr[i])
  }
  let cbf_luma = if any_chroma {
    ctx.cabac.cbf_luma(0, cbf_luma_real)
    cbf_luma_real
  } else {
    true
  }
  if cbf_luma {
    ctx.cabac.residual(luma_levels, n, hevc_scan_diag, 0)
    let recon = hevc_enc_recon_transform(
      luma_levels,
      n,
      ctx.qp + sps.qp_bd_offset,
      bd,
      false,
      hevc_enc_last_x(luma_levels, n, hevc_scan_diag),
      hevc_enc_last_y(luma_levels, n, hevc_scan_diag),
    )
    hevc_add_residual_at(ctx.pic, 0, x0, y0, fixed_to_array(recon), n, bd)
  }
  for c in 1..<3 {
    let levels = if c == 1 { cb_levels } else { cr_levels }
    let flags = if c == 1 { cbf_cb } else { cbf_cr }
    for i in 0..<n_cb {
      if flags[i] {
        ctx.cabac.residual(levels[i], nc, hevc_scan_diag, c)
        let recon = hevc_enc_recon_transform(
          levels[i],
          nc,
          qp_c + sps.qp_bd_offset,
          bd,
          false,
          hevc_enc_last_x(levels[i], nc, hevc_scan_diag),
          hevc_enc_last_y(levels[i], nc, hevc_scan_diag),
        )
        hevc_add_residual_at(
          ctx.pic,
          c,
          x0 >> hs,
          (y0 + (i << log2_c)) >> vs,
          fixed_to_array(recon),
          nc,
          bd,
        )
      }
    }
  }
  // cbf_luma_tab for the boundary-strength derivation (same marking rule the
  // decoder uses: every min-TB of a coded luma block).
  if cbf_luma {
    let min_tb = 1 << sps.log2_min_tb_size
    let mut j = 0
    while j < n {
      let mut i = 0
      while i < n {
        ctx.cbf_luma_tab[((y0 + j) >> sps.log2_min_tb_size) * sps.min_tb_width +
        ((x0 + i) >> sps.log2_min_tb_size)] = 1
        i = i + min_tb
      }
      j = j + min_tb
    }
  }
  hevc_bs_derive(
    sps,
    ctx.tab_mvf,
    ctx.cbf_luma_tab,
    ctx.inter.rpl,
    x0,
    y0,
    log2_tb,
    ctx.vertical_bs,
    ctx.horizontal_bs,
    ctx.bs_width,
  )
  Ok(())
}

///|
/// Fill a PU's motion field (`hls_prediction_unit`'s `tab_mvf` write-back). */
fn hevc_enc_fill_mvf(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  let sps = ctx.sps
  let l2pu = sps.log2_min_pu_size
  let x_pu = x0 >> l2pu
  let y_pu = y0 >> l2pu
  for j in 0..<(n_pb_h >> l2pu) {
    for i in 0..<(n_pb_w >> l2pu) {
      let f = ctx.tab_mvf[(y_pu + j) * sps.min_pu_width + x_pu + i]
      f.pred_flag = hevc_pf_l0
      f.ref_idx0 = 0
      f.ref_idx1 = 0
      f.mv0.x = mvx
      f.mv0.y = mvy
      f.mv1.x = 0
      f.mv1.y = 0
    }
  }
}

///|
/// Fill the per-min-PU motion field for a B PU with its chosen prediction
/// direction and per-list MVs, mirroring `hevc_enc_fill_mvf` for the L1/BI
/// cases (the deblocking boundary-strength derivation reads `pred_flag`).
fn hevc_enc_fill_mvf_b(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  pred_flag : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
) -> Unit {
  let sps = ctx.sps
  let l2pu = sps.log2_min_pu_size
  let x_pu = x0 >> l2pu
  let y_pu = y0 >> l2pu
  for j in 0..<(n_pb_h >> l2pu) {
    for i in 0..<(n_pb_w >> l2pu) {
      let f = ctx.tab_mvf[(y_pu + j) * sps.min_pu_width + x_pu + i]
      f.pred_flag = pred_flag
      f.ref_idx0 = 0
      f.ref_idx1 = 0
      f.mv0.x = if pred_flag != hevc_pf_l1 { mv0x } else { 0 }
      f.mv0.y = if pred_flag != hevc_pf_l1 { mv0y } else { 0 }
      f.mv1.x = if pred_flag != hevc_pf_l0 { mv1x } else { 0 }
      f.mv1.y = if pred_flag != hevc_pf_l0 { mv1y } else { 0 }
    }
  }
}

///|
/// `intra_prediction_unit_default_value`'s inter side: DC in `tab_ipm`. */
fn hevc_enc_default_ipm(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
) -> Unit {
  let sps = ctx.sps
  let l2pu = sps.log2_min_pu_size
  let x_pu = x0 >> l2pu
  let y_pu = y0 >> l2pu
  let n = size >> l2pu
  for j in 0..<n {
    for i in 0..<n {
      ctx.tab_ipm[(y_pu + j) * sps.min_pu_width + x_pu + i] = 1
    }
  }
}

///|
/// `hls_coding_unit` for a P slice with I+inter mode decision. Both candidates
/// are evaluated side-effect-free first: the inter candidate reuses the motion
/// search and merge/AMVP result, the intra candidate runs the 35-mode luma
/// search. Mode selection uses a Lagrangian `distortion + lambda * bit_hint`,
/// where `bit_hint` favours inter skip/merge (few bins) and lambda grows with
/// QP — a deterministic, decoder-independent RD criterion. The winner is then
/// committed through the matching write path so the picture holds exactly one
/// prediction and one residual. */
fn hevc_enc_coding_unit_inter(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
  cb_depth : Int32,
) -> Result[Unit, String] {
  let sps = ctx.sps
  let cb_size = 1 << log2_cb_size
  let ctb_size = 1 << sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  let x_cb = x0 >> sps.log2_min_cb_size
  let y_cb = y0 >> sps.log2_min_cb_size
  let len = cb_size >> sps.log2_min_cb_size
  let max_cand = ctx.inter.sh.max_num_merge_cand
  ctx.cur_x = x0
  ctx.cur_y = y0
  // --- RD mode decision (both candidates evaluated without side effects) ---
  let (mvx, mvy, inter_sad) = hevc_enc_me_search(ctx, x0, y0, cb_size)
  let cands = hevc_enc_merge_candidates(ctx, x0, y0, cb_size)
  let merge_idx = hevc_enc_merge_match(cands, mvx, mvy, max_cand)
  let (_, intra_sad) = hevc_enc_intra_eval(ctx, x0, y0, cb_size, log2_cb_size)
  // Inter's bit cost: a matching merge is cheapest (merge_idx only), an
  // AMVP+MVD costs a few more bins; intra costs pred_mode + intra mode +
  // chroma mode bins. lambda ~= 2^(qp/6) scales distortion into bit units.
  let lambda = 1 << (ctx.qp / 6)
  let inter_bits = if merge_idx >= 0 { 2 } else { 8 }
  let intra_bits = 10
  let inter_cost = inter_sad + inter_bits.to_int64() * lambda.to_int64()
  let intra_cost = intra_sad + intra_bits.to_int64() * lambda.to_int64()
  if intra_cost < inter_cost {
    // Commit an intra CU in a P slice: pred_mode_flag(1) then the I-slice
    // intra body (skip_flag was already coded as 0 above in the decoder's
    // read order — we write it here, before pred_mode).
    for y in 0..<len {
      for x in 0..<len {
        ctx.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = 0
      }
    }
    ctx.cabac.skip_flag(
      ctx.skip_flag,
      x0b,
      y0b,
      x_cb,
      y_cb,
      sps.min_cb_width,
      ctx.ctb_left,
      ctx.ctb_up,
      false,
    )
    ctx.cabac.pred_mode_flag(true)
    match hevc_enc_coding_unit(ctx, x0, y0, log2_cb_size, cb_depth) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    hevc_enc_mvf_intra(ctx, x0, y0, cb_size)
    // Post-CU bookkeeping must run on this path too: `qp_y_tab` feeds the
    // deblocking QP lookup, so an unfilled slot would filter with the wrong QP.
    for y in 0..<len {
      for x in 0..<len {
        ctx.qp_y_tab[(y_cb + y) * sps.min_cb_width + x_cb + x] = ctx.qp
        ctx.tab_ct_depth[(y_cb + y) * sps.min_cb_width + x_cb + x] = cb_depth
      }
    }
    return Ok(())
  }
  // --- inter commit path (unchanged from §450) ---
  // The motion search, merge candidate list, and merge match were computed
  // above for the RD decision; reuse them verbatim.
  // Prediction first: the residual decision below quantises against it.
  hevc_enc_mc_l0(ctx, x0, y0, cb_size, mvx, mvy)
  let hs = sps.hshift[1]
  let _vs = sps.vshift[1]
  let log2_c = log2_cb_size - hs
  let nc = 1 << log2_c
  let qp_c = hevc_enc_chroma_qp_fwd(sps, ctx.qp)
  let n_cb = if sps.chroma_format_idc == 2 { 2 } else { 1 }
  let luma_levels = hevc_enc_quant_plane(
    ctx,
    0,
    x0,
    y0,
    cb_size,
    cb_size,
    cb_size,
    ctx.qp,
    log2_cb_size,
    false,
  )
  let cb_levels : Array[FixedArray[Int32]] = []
  let cr_levels : Array[FixedArray[Int32]] = []
  for i in 0..<n_cb {
    cb_levels.push(
      hevc_enc_quant_plane(
        ctx,
        1,
        x0,
        y0 + (i << log2_c),
        nc,
        nc,
        nc,
        qp_c,
        log2_c,
        false,
      ),
    )
  }
  for i in 0..<n_cb {
    cr_levels.push(
      hevc_enc_quant_plane(
        ctx,
        2,
        x0,
        y0 + (i << log2_c),
        nc,
        nc,
        nc,
        qp_c,
        log2_c,
        false,
      ),
    )
  }
  let mut any_chroma = false
  for i in 0..<n_cb {
    if hevc_enc_levels_nonzero(cb_levels[i]) ||
      hevc_enc_levels_nonzero(cr_levels[i]) {
      any_chroma = true
    }
  }
  let has_residual = hevc_enc_levels_nonzero(luma_levels) || any_chroma
  let use_skip = !has_residual && merge_idx >= 0
  // skip_flag: clear the CB's slots first, exactly as `coding_unit` does.
  for y in 0..<len {
    for x in 0..<len {
      ctx.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = 0
    }
  }
  ctx.cabac.skip_flag(
    ctx.skip_flag,
    x0b,
    y0b,
    x_cb,
    y_cb,
    sps.min_cb_width,
    ctx.ctb_left,
    ctx.ctb_up,
    use_skip,
  )
  let skip_v = if use_skip { 1 } else { 0 }
  for y in 0..<len {
    for x in 0..<len {
      ctx.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = skip_v
    }
  }
  let mut use_merge = true
  if use_skip {
    // The skip branch implies merge and reads merge_idx only.
    if max_cand > 1 {
      ctx.cabac.merge_idx(merge_idx, max_cand)
    }
    // Skip CUs have no transform tree, so fill tab_mvf and derive bS here;
    // the decoder's `hls_prediction_unit` + implicit-cbf path does the same.
    hevc_enc_fill_mvf(ctx, x0, y0, cb_size, cb_size, mvx, mvy)
    hevc_bs_derive(
      sps,
      ctx.tab_mvf,
      ctx.cbf_luma_tab,
      ctx.inter.rpl,
      x0,
      y0,
      log2_cb_size,
      ctx.vertical_bs,
      ctx.horizontal_bs,
      ctx.bs_width,
    )
  } else {
    ctx.cabac.pred_mode_flag(false)
    ctx.cabac.part_mode_inter_2nx2n()
    use_merge = merge_idx >= 0
    ctx.cabac.merge_flag(use_merge)
    if use_merge {
      if max_cand > 1 {
        ctx.cabac.merge_idx(merge_idx, max_cand)
      }
    } else {
      // AMVP: signal the predictor flag with the smaller displacement.
      let (p0x, p0y) = hevc_enc_amvp(ctx, x0, y0, cb_size, 0)
      let (p1x, p1y) = hevc_enc_amvp(ctx, x0, y0, cb_size, 1)
      let d0 = (mvx - p0x).abs() + (mvy - p0y).abs()
      let d1 = (mvx - p1x).abs() + (mvy - p1y).abs()
      let flag = if d1 < d0 { 1 } else { 0 }
      let (px, py) = if flag == 1 { (p1x, p1y) } else { (p0x, p0y) }
      ctx.cabac.mvd_coding(mvx - px, mvy - py)
      ctx.cabac.mvp_lx_flag(flag)
    }
    // rqt_root_cbf is absent for a merge 2Nx2N PU.
    if !use_merge {
      ctx.cabac.no_residual_flag(has_residual)
    }
    // The decoder fills tab_mvf in `prediction_unit`, i.e. BEFORE the transform
    // tree derives boundary strengths from it. Mirror that order: an inter PU
    // must be marked L0 in tab_mvf before hevc_bs_derive runs inside the
    // residual coder, otherwise bS sees stale `pred_flag == intra` and the
    // deblocking filter diverges from the decoder.
    hevc_enc_fill_mvf(ctx, x0, y0, cb_size, cb_size, mvx, mvy)
    if has_residual {
      match
        hevc_enc_code_residual_inter(
          ctx, x0, y0, luma_levels, cb_levels, cr_levels, log2_cb_size,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else {
      // No transform tree: still derive bS from the (now inter) motion field
      // and the zero cbf, exactly as the decoder's transform-tree-less path.
      hevc_bs_derive(
        sps,
        ctx.tab_mvf,
        ctx.cbf_luma_tab,
        ctx.inter.rpl,
        x0,
        y0,
        log2_cb_size,
        ctx.vertical_bs,
        ctx.horizontal_bs,
        ctx.bs_width,
      )
    }
  }
  hevc_enc_default_ipm(ctx, x0, y0, cb_size)
  // Post-CU bookkeeping (`tab_ct_depth` prices the neighbours' split flags;
  // `qp_y_tab` feeds nothing while deblocking stays off).
  for y in 0..<len {
    for x in 0..<len {
      ctx.qp_y_tab[(y_cb + y) * sps.min_cb_width + x_cb + x] = ctx.qp
      ctx.tab_ct_depth[(y_cb + y) * sps.min_cb_width + x_cb + x] = cb_depth
    }
  }
  Ok(())
}

///|
/// SAD between the source block and a BI prediction built on a scratch picture
/// (the two uni predictions averaged exactly as `hevc_luma_mc_bi` does).
fn hevc_enc_sad_bi(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
) -> Int64 {
  let sps = ctx.sps
  let bd = sps.bit_depth
  let ref0 = ctx.ref_pic
  let ref1 = ctx.ref_pic_l1
  let scratch = hevc_picture_new(
    ctx.pic.width,
    ctx.pic.height,
    ctx.pic.cw,
    ctx.pic.ch,
  )
  hevc_luma_mc_bi(
    ref0.y,
    ref0.width,
    ref1.y,
    ref1.width,
    ref0.width,
    ref0.height,
    scratch.y,
    scratch.width,
    x0,
    y0,
    mv0x,
    mv0y,
    mv1x,
    mv1y,
    size,
    size,
    bd,
  )
  hevc_enc_sad_mv(
    ctx.src_y,
    sps.width,
    scratch.y,
    scratch.width,
    scratch.height,
    x0,
    y0,
    size,
    0,
    0,
  )
}

///|
/// Encode one B-slice CU (`hevc_slice_b`). Mirrors the P path's syntax order but
/// codes `inter_pred_idc` before the per-list motion data, and evaluates L0, L1
/// and BI against intra before committing.
fn hevc_enc_coding_unit_b(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
  cb_depth : Int32,
) -> Result[Unit, String] {
  let sps = ctx.sps
  let cb_size = 1 << log2_cb_size
  let ctb_size = 1 << sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  let x_cb = x0 >> sps.log2_min_cb_size
  let y_cb = y0 >> sps.log2_min_cb_size
  let len = cb_size >> sps.log2_min_cb_size
  let max_cand = ctx.inter.sh.max_num_merge_cand
  ctx.cur_x = x0
  ctx.cur_y = y0
  // --- Candidate evaluation (side-effect free) ---
  let (l0x, l0y, _) = hevc_enc_me_search(ctx, x0, y0, cb_size)
  let (l1x, l1y) = hevc_enc_me_search_ref(ctx, ctx.ref_pic_l1, x0, y0, cb_size)
  let sad_l0 = hevc_enc_sad_mv(
    ctx.src_y,
    sps.width,
    ctx.ref_pic.y,
    ctx.ref_pic.width,
    ctx.ref_pic.height,
    x0,
    y0,
    cb_size,
    l0x,
    l0y,
  )
  let sad_l1 = hevc_enc_sad_mv(
    ctx.src_y,
    sps.width,
    ctx.ref_pic_l1.y,
    ctx.ref_pic_l1.width,
    ctx.ref_pic_l1.height,
    x0,
    y0,
    cb_size,
    l1x,
    l1y,
  )
  let sad_bi = hevc_enc_sad_bi(ctx, x0, y0, cb_size, l0x, l0y, l1x, l1y)

  // Pick the cheapest prediction shape.
  let mut pred_flag = hevc_pf_l0
  let mut mv0x = l0x
  let mut mv0y = l0y
  let mut mv1x = 0
  let mut mv1y = 0
  let mut inter_sad = sad_l0
  if sad_l1 < inter_sad {
    pred_flag = hevc_pf_l1
    mv0x = 0
    mv0y = 0
    mv1x = l1x
    mv1y = l1y
    inter_sad = sad_l1
  }
  if sad_bi < inter_sad {
    pred_flag = hevc_pf_bi
    mv0x = l0x
    mv0y = l0y
    mv1x = l1x
    mv1y = l1y
    inter_sad = sad_bi
  }
  // Merge candidates: a candidate whose motion equals ours makes the PU a
  // single merge_idx bin instead of the full AMVP+MVD syntax.
  let cands = hevc_enc_merge_candidates(ctx, x0, y0, cb_size)
  let merge_idx = hevc_enc_merge_match_b(
    cands, pred_flag, mv0x, mv0y, mv1x, mv1y, max_cand,
  )
  let (_, intra_sad) = hevc_enc_intra_eval(ctx, x0, y0, cb_size, log2_cb_size)
  let lambda = 1 << (ctx.qp / 6)
  // BI costs one more bin (the "is BI" bin) than a uni prediction.
  let inter_bits = if merge_idx >= 0 {
    2
  } else if pred_flag == hevc_pf_bi {
    9
  } else {
    8
  }
  let intra_bits = 10
  let inter_cost = inter_sad + inter_bits.to_int64() * lambda.to_int64()
  let intra_cost = intra_sad + intra_bits.to_int64() * lambda.to_int64()
  if intra_cost < inter_cost {
    for y in 0..<len {
      for x in 0..<len {
        ctx.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = 0
      }
    }
    ctx.cabac.skip_flag(
      ctx.skip_flag,
      x0b,
      y0b,
      x_cb,
      y_cb,
      sps.min_cb_width,
      ctx.ctb_left,
      ctx.ctb_up,
      false,
    )
    ctx.cabac.pred_mode_flag(true)
    match hevc_enc_coding_unit(ctx, x0, y0, log2_cb_size, cb_depth) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    hevc_enc_mvf_intra(ctx, x0, y0, cb_size)
    for y in 0..<len {
      for x in 0..<len {
        ctx.qp_y_tab[(y_cb + y) * sps.min_cb_width + x_cb + x] = ctx.qp
        ctx.tab_ct_depth[(y_cb + y) * sps.min_cb_width + x_cb + x] = cb_depth
      }
    }
    return Ok(())
  }
  // --- inter commit ---
  hevc_enc_mc_b(ctx, x0, y0, cb_size, pred_flag, mv0x, mv0y, mv1x, mv1y)
  let hs = sps.hshift[1]
  let _vs = sps.vshift[1]
  let log2_c = log2_cb_size - hs
  let nc = 1 << log2_c
  let qp_c = hevc_enc_chroma_qp_fwd(sps, ctx.qp)
  let n_cb = if sps.chroma_format_idc == 2 { 2 } else { 1 }
  let luma_levels = hevc_enc_quant_plane(
    ctx,
    0,
    x0,
    y0,
    cb_size,
    cb_size,
    cb_size,
    ctx.qp,
    log2_cb_size,
    false,
  )
  let cb_levels : Array[FixedArray[Int32]] = []
  let cr_levels : Array[FixedArray[Int32]] = []
  for i in 0..<n_cb {
    cb_levels.push(
      hevc_enc_quant_plane(
        ctx,
        1,
        x0,
        y0 + (i << log2_c),
        nc,
        nc,
        nc,
        qp_c,
        log2_c,
        false,
      ),
    )
  }
  for i in 0..<n_cb {
    cr_levels.push(
      hevc_enc_quant_plane(
        ctx,
        2,
        x0,
        y0 + (i << log2_c),
        nc,
        nc,
        nc,
        qp_c,
        log2_c,
        false,
      ),
    )
  }
  let mut any_chroma = false
  for i in 0..<n_cb {
    if hevc_enc_levels_nonzero(cb_levels[i]) ||
      hevc_enc_levels_nonzero(cr_levels[i]) {
      any_chroma = true
    }
  }
  let has_residual = hevc_enc_levels_nonzero(luma_levels) || any_chroma
  let use_skip = !has_residual && merge_idx >= 0
  for y in 0..<len {
    for x in 0..<len {
      ctx.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = 0
    }
  }
  ctx.cabac.skip_flag(
    ctx.skip_flag,
    x0b,
    y0b,
    x_cb,
    y_cb,
    sps.min_cb_width,
    ctx.ctb_left,
    ctx.ctb_up,
    use_skip,
  )
  let skip_v = if use_skip { 1 } else { 0 }
  for y in 0..<len {
    for x in 0..<len {
      ctx.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = skip_v
    }
  }
  let mut use_merge = true

  if use_skip {
    if max_cand > 1 {
      ctx.cabac.merge_idx(merge_idx, max_cand)
    }
    hevc_enc_fill_mvf_b(
      ctx, x0, y0, cb_size, cb_size, pred_flag, mv0x, mv0y, mv1x, mv1y,
    )
    hevc_bs_derive(
      sps,
      ctx.tab_mvf,
      ctx.cbf_luma_tab,
      ctx.inter.rpl,
      x0,
      y0,
      log2_cb_size,
      ctx.vertical_bs,
      ctx.horizontal_bs,
      ctx.bs_width,
    )
    hevc_enc_default_ipm(ctx, x0, y0, cb_size)
    hevc_enc_b_post_cu(ctx, x0, y0, cb_size, cb_depth)
    return Ok(())
  }
  ctx.cabac.pred_mode_flag(false)
  ctx.cabac.part_mode_inter_2nx2n()
  use_merge = merge_idx >= 0
  ctx.cabac.merge_flag(use_merge)
  if use_merge {
    if max_cand > 1 {
      ctx.cabac.merge_idx(merge_idx, max_cand)
    }
  } else {
    ctx.cabac.inter_pred_idc(cb_depth, cb_size, cb_size, pred_flag)
    // L0 side.
    if pred_flag != hevc_pf_l1 {
      let (p0x, p0y) = hevc_enc_amvp(ctx, x0, y0, cb_size, 0)
      ctx.cabac.mvd_coding(mv0x - p0x, mv0y - p0y)
      let flag = if mv0x == p0x && mv0y == p0y { 0 } else { 0 }
      ctx.cabac.mvp_lx_flag(flag)
    }
    // L1 side: `mvd_l1_zero_flag` is 0 in our header, so the MVD is coded and
    // the decoder reconstructs `mv1 = mvp1 + mvd1`. Try both MVP candidates and
    // signal whichever reproduces our MV with the smaller MVD. The decoder
    // derives L1's predictors after it has written L0's motion into `tab_mvf`,
    // so mirror that ordering here before the L1 derivation runs.
    if pred_flag != hevc_pf_l0 {
      let (a1x, a1y) = hevc_enc_amvp_l1(ctx, x0, y0, cb_size, 0)
      let (b1x, b1y) = hevc_enc_amvp_l1(ctx, x0, y0, cb_size, 1)
      let da = hevc_enc_abs_diff(mv1x - a1x) + hevc_enc_abs_diff(mv1y - a1y)
      let db = hevc_enc_abs_diff(mv1x - b1x) + hevc_enc_abs_diff(mv1y - b1y)
      if db < da {
        ctx.cabac.mvd_coding(mv1x - b1x, mv1y - b1y)
        ctx.cabac.mvp_lx_flag(1)
      } else {
        ctx.cabac.mvd_coding(mv1x - a1x, mv1y - a1y)
        ctx.cabac.mvp_lx_flag(0)
      }
    }
  }
  if !use_merge {
    ctx.cabac.no_residual_flag(has_residual)
  }
  hevc_enc_fill_mvf_b(
    ctx, x0, y0, cb_size, cb_size, pred_flag, mv0x, mv0y, mv1x, mv1y,
  )
  if has_residual {
    match
      hevc_enc_code_residual_inter(
        ctx, x0, y0, luma_levels, cb_levels, cr_levels, log2_cb_size,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    hevc_bs_derive(
      sps,
      ctx.tab_mvf,
      ctx.cbf_luma_tab,
      ctx.inter.rpl,
      x0,
      y0,
      log2_cb_size,
      ctx.vertical_bs,
      ctx.horizontal_bs,
      ctx.bs_width,
    )
  }
  hevc_enc_default_ipm(ctx, x0, y0, cb_size)
  hevc_enc_b_post_cu(ctx, x0, y0, cb_size, cb_depth)
  Ok(())
}

///|
/// Per-CU bookkeeping shared by every B-slice CU shape. `tab_ct_depth` prices
/// the neighbours' `split_coding_unit_flag` contexts, so a B slice that skips
/// it desynchronises the CU quadtree from the decoder's after the first CU;
/// `qp_y_tab` is kept in step with the P path.
fn hevc_enc_b_post_cu(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  cb_size : Int32,
  cb_depth : Int32,
) -> Unit {
  let sps = ctx.sps
  let x_cb = x0 >> sps.log2_min_cb_size
  let y_cb = y0 >> sps.log2_min_cb_size
  let len = cb_size >> sps.log2_min_cb_size
  for y in 0..<len {
    for x in 0..<len {
      ctx.qp_y_tab[(y_cb + y) * sps.min_cb_width + x_cb + x] = ctx.qp
      ctx.tab_ct_depth[(y_cb + y) * sps.min_cb_width + x_cb + x] = cb_depth
    }
  }
}

///|
/// The L0 reference's POC delta, read back from the parsed slice header's RPS
/// (the first used negative entry). A P slice over a B picture has delta -2, a
/// plain P slice -1.
fn hevc_enc_l0_delta(sh : HevcSliceHeader) -> Int32 {
  let rps = sh.st_rps
  let mut i = 0
  while i < rps.num_delta_pocs {
    if (rps.used & (1U << i)) != 0U && i < rps.num_negative_pics {
      return rps.delta_poc[i]
    }
    i = i + 1
  }
  -1
}

///|
/// The L1 reference's POC delta: the first used positive entry (only a B slice
/// has one).
fn hevc_enc_l1_delta(sh : HevcSliceHeader) -> Int32 {
  let rps = sh.st_rps
  let mut i = rps.num_negative_pics
  while i < rps.num_delta_pocs {
    if (rps.used & (1U << i)) != 0U {
      return rps.delta_poc[i]
    }
    i = i + 1
  }
  0
}

///|
/// Absolute value of an `Int32` difference (the MVP selection compares the
/// magnitude of two candidate MVDs).
fn hevc_enc_abs_diff(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}
