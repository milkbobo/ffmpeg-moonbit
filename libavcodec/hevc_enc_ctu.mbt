///|
/// HEVC intra encoder slice data: the CTB loop, coding quadtree, coding
/// unit and transform unit, mirroring `hevc_intra_decode.mbt`'s I-slice
/// path bin for bin. Slice-1 scope: CTB 32 (no forced splits - the picture
/// is padded to CTB multiples), PART_2Nx2N only, one TU per CU
/// (`max_transform_hierarchy_depth_intra = 0`), chroma DM (mode 4), flat
/// QP (`cu_qp_delta_enabled_flag = 0`), SAO/deblocking off, no PCM or
/// transquant bypass. Every bin the decoder reads, the encoder writes at
/// the same position; prediction and reconstruction go through the
/// decoder's own kernels, so the local reconstruction is the decoder's
/// output by construction.

///|
/// Per-frame encoder state. */
priv struct HevcEncCtx {
  sps : HevcSps
  pps : HevcPps
  qp : Int32
  src_y : FixedArray[Int32]
  src_u : FixedArray[Int32]
  src_v : FixedArray[Int32]
  pic : HevcPicture
  cabac : HevcEncCabac
  tab_ipm : Array[Int32]
  tab_ct_depth : Array[Int32]
  qp_y_tab : Array[Int32]
  na : HevcNeighbourAvail
  mut ctb_left : Bool
  mut ctb_up : Bool
  mut ctb_up_left : Bool
  mut ctb_up_right : Bool
  mut end_of_tiles_y : Int32
  /// Current CTB raster index (the end-of-slice decision reads it).
  mut rs : Int32
  // --- inter (P slice) state; all-intra frames leave it at the defaults ---
  /// `hevc_slice_i` or `hevc_slice_p`.
  slice_type : Int32
  /// Previous frame's reconstruction (the L0 reference), padded size.
  ref_pic : HevcPicture
  /// Future frame's reconstruction (the L1 reference) for a B slice; an empty
  /// picture for I/P slices.
  ref_pic_l1 : HevcPicture
  /// This frame's per-min-PU motion field (`tab_mvf`).
  tab_mvf : Array[HevcMvField]
  /// Per-min-CB `skip_flag` (the skip-flag context reads it).
  skip_flag : Array[Int32]
  /// Shared inter-prediction context used for the merge/AMVP derivation; the
  /// encoder keeps its neighbour availability in sync with `na`/`ctb_*`.
  inter : HevcInterCtx
  mut cur_x : Int32
  mut cur_y : Int32
  /// Per-min-TB luma cbf, mirroring the decoder's `cbf_luma_tab`; the
  /// boundary-strength derivation reads it.
  cbf_luma_tab : Array[Int32]
  /// Boundary strengths (raster, one entry per 4x4 grid point) that
  /// `hevc_bs_derive` fills and `hevc_deblock_picture` consumes.
  vertical_bs : Array[Int32]
  horizontal_bs : Array[Int32]
  bs_width : Int32
}

///|
/// CTB loop for an intra (`hevc_slice_i`), P (`hevc_slice_p`) or B
/// (`hevc_slice_b`) picture. `ref_pic` is the L0 reference; `ref_pic_l1` is the
/// L1 reference of a B slice and is unused otherwise. `sh` is the parsed-back
/// slice header, whose switches the CTU path reads (merge candidate count,
/// deblocking, ...). */

///|
fn hevc_enc_ctu_loop_slice(
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  qp : Int32,
  sy : FixedArray[Int32],
  su : FixedArray[Int32],
  sv : FixedArray[Int32],
  pic : HevcPicture,
  slice_type : Int32,
  ref_pic : HevcPicture,
  ref_pic_l1~ : HevcPicture = hevc_picture_new(0, 0, 0, 0),
  sao~ : HevcSaoParams = hevc_sao_params_new(0, 1),
) -> Result[Array[Byte], String] {
  let states = ff_hevc_init_cabac_states(qp, slice_type, sh.cabac_init_flag)
  let tab_mvf : Array[HevcMvField] = []
  for _ in 0..<(sps.min_pu_width * sps.min_pu_height) {
    tab_mvf.push(hevc_mv_field_new())
  }
  let inter : HevcInterCtx = {
    sps,
    pps,
    sh,
    poc: sh.poc,
    tab_mvf,
    rpl: hevc_enc_make_rpl(
      sh.poc,
      slice_type,
      sh.poc + hevc_enc_l0_delta(sh),
      sh.poc + hevc_enc_l1_delta(sh),
    ),
    collocated: None,
    cabac: {
      cc: { low: 0, range: 0x1FE, bytes: b"", start: 0, pos: 0, },
      states: [],
      stat_coeff: Array::make(4, 0),
    },
    na: hevc_neighbour_avail(),
    ctb_left: false,
    ctb_up: false,
    ctb_up_left: false,
    ctb_up_right: false,
    end_of_tiles_x: sps.width,
    end_of_tiles_y: sps.height,
    ct_depth: 0,
    part_mode: hevc_part_2nx2n,
    cu_x: 0,
    cu_y: 0,
    last_merge_flag: false,
  }
  let ctx : HevcEncCtx = {
    sps,
    pps,
    qp,
    src_y: sy,
    src_u: su,
    src_v: sv,
    pic,
    cabac: { eng: hevc_cabac_enc_new(), states, trace: [], },
    tab_ipm: Array::make(sps.min_pu_width * sps.min_pu_height, 1),
    tab_ct_depth: Array::make(sps.min_cb_width * sps.min_cb_height, 0),
    qp_y_tab: Array::make(sps.min_cb_width * sps.min_cb_height, 0),
    na: hevc_neighbour_avail(),
    ctb_left: false,
    ctb_up: false,
    ctb_up_left: false,
    ctb_up_right: false,
    end_of_tiles_y: sps.height,
    rs: 0,
    slice_type,
    ref_pic,
    ref_pic_l1,
    tab_mvf,
    skip_flag: Array::make(sps.min_cb_width * sps.min_cb_height, 0),
    inter,
    cur_x: 0,
    cur_y: 0,
    cbf_luma_tab: Array::make(sps.min_tb_width * sps.min_tb_height, 0),
    vertical_bs: Array::make(
      ((sps.width >> 2) + 1) * ((sps.height >> 2) + 1),
      0,
    ),
    horizontal_bs: Array::make(
      ((sps.width >> 2) + 1) * ((sps.height >> 2) + 1),
      0,
    ),
    bs_width: (sps.width >> 2) + 1,
  }
  let mut more = true
  while more && ctx.rs < sps.ctb_size {
    let x_ctb = (ctx.rs % sps.ctb_width) << sps.log2_ctb_size
    let y_ctb = (ctx.rs / sps.ctb_width) << sps.log2_ctb_size
    ctx.ctb_left = x_ctb > 0
    ctx.ctb_up = y_ctb > 0
    ctx.ctb_up_left = x_ctb > 0 && y_ctb > 0
    ctx.ctb_up_right = y_ctb > 0
    ctx.end_of_tiles_y = if y_ctb + (1 << sps.log2_ctb_size) < sps.height {
      y_ctb + (1 << sps.log2_ctb_size)
    } else {
      sps.height
    }
    // SAO parameters are coded at the start of every CTB, before the coding
    // quadtree, exactly where the decoder parses them.
    hevc_enc_write_sao_ctb(
      ctx.cabac,
      sps,
      sh,
      sao,
      ctx.rs,
      ctx.rs % sps.ctb_width,
      ctx.rs / sps.ctb_width,
      ctx.ctb_left,
      ctx.ctb_up,
    )
    more = match hevc_enc_quadtree(ctx, x_ctb, y_ctb, sps.log2_ctb_size, 0) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    ctx.rs = ctx.rs + 1
  }
  // In-loop filters: deblocking runs over the whole picture once every CTB is
  // coded, using the same kernel and the same bS tables as the decoder, so the
  // encoder's reconstruction equals the decoder's output by construction.
  hevc_deblock_picture(
    ctx.pic,
    sps,
    pps,
    Array::make(sps.ctb_size, 0),
    Array::make(sps.ctb_size, 0),
    ctx.qp_y_tab,
    ctx.vertical_bs,
    ctx.horizontal_bs,
    ctx.bs_width,
  )
  // SAO runs after deblocking (HEVC in-loop filter order). Same kernel and the
  // same per-CTB parameters the bitstream carries, so recon == decoder output.
  hevc_sao_apply(
    ctx.pic,
    sps,
    pps,
    sao,
    Array::make(sps.ctb_size, 1),
    Array::make(sps.ctb_size, 0),
  )
  Ok(ctx.cabac.eng.to_bytes())
}

///|
/// `HevcIntraDecoder::set_neighbour_available` mirror for the encoder. */
fn hevc_enc_set_na(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
) -> Unit {
  let ctb_size = 1 << ctx.sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  ctx.na.cand_up = ctx.ctb_up || y0b != 0
  ctx.na.cand_left = ctx.ctb_left || x0b != 0
  ctx.na.cand_up_left = if x0b != 0 || y0b != 0 {
    ctx.na.cand_left && ctx.na.cand_up
  } else {
    ctx.ctb_up_left
  }
  let up_right_sap = if x0b + n_pb_w == ctb_size {
    ctx.ctb_up_right && y0b == 0
  } else {
    ctx.na.cand_up
  }
  ctx.na.cand_up_right_sap = up_right_sap
  ctx.na.cand_up_right = up_right_sap && x0 + n_pb_w < ctx.sps.width
  ctx.na.cand_bottom_left = if y0 + n_pb_h >= ctx.end_of_tiles_y {
    false
  } else {
    ctx.na.cand_left
  }
}

///|
/// `hls_coding_quadtree` write side; returns the C `more_data` flag. With
/// the picture padded to CTB multiples no CB ever crosses an edge, so the
/// split flag is always coded. */
fn hevc_enc_quadtree(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
  cb_depth : Int32,
) -> Result[Bool, String] {
  let sps = ctx.sps
  let cb_size = 1 << log2_cb_size
  let ctb_size = 1 << sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  let x_cb = x0 >> sps.log2_min_cb_size
  let y_cb = y0 >> sps.log2_min_cb_size
  let depth_left = if ctx.ctb_left || x0b != 0 {
    ctx.tab_ct_depth[y_cb * sps.min_cb_width + x_cb - 1]
  } else {
    0
  }
  let depth_top = if ctx.ctb_up || y0b != 0 {
    ctx.tab_ct_depth[(y_cb - 1) * sps.min_cb_width + x_cb]
  } else {
    0
  }
  let split = if x0 + cb_size <= sps.width &&
    y0 + cb_size <= sps.height &&
    log2_cb_size > sps.log2_min_cb_size {
    let want = hevc_enc_split_decision(ctx, x0, y0, log2_cb_size)
    ctx.cabac.split_coding_unit_flag(depth_left, depth_top, cb_depth, want)
    want
  } else {
    // Crossing CBs cannot occur (picture padded to CTB multiples); the
    // min-CB floor ends the tree.
    log2_cb_size > sps.log2_min_cb_size
  }
  if split {
    let half = cb_size >> 1
    let x1 = x0 + half
    let y1 = y0 + half
    let mut more = match
      hevc_enc_quadtree(ctx, x0, y0, log2_cb_size - 1, cb_depth + 1) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if more && x1 < sps.width {
      more = match
        hevc_enc_quadtree(ctx, x1, y0, log2_cb_size - 1, cb_depth + 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    if more && y1 < sps.height {
      more = match
        hevc_enc_quadtree(ctx, x0, y1, log2_cb_size - 1, cb_depth + 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    if more && x1 < sps.width && y1 < sps.height {
      more = match
        hevc_enc_quadtree(ctx, x1, y1, log2_cb_size - 1, cb_depth + 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    if more {
      Ok(x1 + half < sps.width || y1 + half < sps.height)
    } else {
      Ok(false)
    }
  } else {
    let cu_result = if ctx.slice_type == hevc_slice_i {
      hevc_enc_coding_unit(ctx, x0, y0, log2_cb_size, cb_depth)
    } else if ctx.slice_type == hevc_slice_b {
      hevc_enc_coding_unit_b(ctx, x0, y0, log2_cb_size, cb_depth)
    } else {
      hevc_enc_coding_unit_inter(ctx, x0, y0, log2_cb_size, cb_depth)
    }
    match cu_result {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if ((x0 + cb_size) % ctb_size == 0 || x0 + cb_size >= sps.width) &&
      ((y0 + cb_size) % ctb_size == 0 || y0 + cb_size >= sps.height) {
      let last = ctx.rs == sps.ctb_size - 1
      ctx.cabac.end_of_slice(last)
      Ok(!last)
    } else {
      Ok(true)
    }
  }
}

///|
/// Split decision: split when the source block's mean absolute deviation
/// from its DC exceeds a fixed threshold (smooth regions stay large).
/// Deterministic, decoder-independent - the flag is whatever we write. */
fn hevc_enc_split_decision(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
) -> Bool {
  if log2_cb_size <= 3 {
    return false
  }
  let size = 1 << log2_cb_size
  let mut sum = 0L
  for y in 0..<size {
    for x in 0..<size {
      sum = sum + ctx.src_y[(y0 + y) * ctx.sps.width + x0 + x].to_int64()
    }
  }
  let mean = (sum >> (log2_cb_size << 1)).to_int()
  let mut sad = 0L
  for y in 0..<size {
    for x in 0..<size {
      let d = ctx.src_y[(y0 + y) * ctx.sps.width + x0 + x] - mean
      sad = sad + (if d < 0 { -d } else { d }).to_int64()
    }
  }
  sad >> (log2_cb_size << 1) > 6
}

///|
/// `hls_coding_unit` for an I slice: intra, 2Nx2N, one TU. */
fn hevc_enc_coding_unit(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
  cb_depth : Int32,
) -> Result[Unit, String] {
  let sps = ctx.sps
  let cb_size = 1 << log2_cb_size
  // Neighbour availability for the CU block (the mode search's trial
  // predictions and the final one all read it).
  hevc_enc_set_na(ctx, x0, y0, cb_size, cb_size)
  if log2_cb_size == sps.log2_min_cb_size {
    // Intra PART_NxN vs PART_2Nx2N: one bin, we always take 2Nx2N.
    ctx.cabac.part_mode_intra(false)
  }
  // Luma intra PU: derive MPM candidates, search, signal.
  let candidates = hevc_enc_mpm_candidates(ctx, x0, y0)
  let mode = hevc_enc_choose_luma_mode(ctx, x0, y0, cb_size, candidates)
  let mut in_mpm = false
  let mut mpm_idx = 0
  for i in 0..<3 {
    if candidates[i] == mode {
      in_mpm = true
      mpm_idx = i
    }
  }
  if in_mpm {
    ctx.cabac.prev_intra_luma_pred_flag(true)
    ctx.cabac.mpm_idx(mpm_idx)
  } else {
    // rem = mode minus the number of candidates strictly below it (the
    // decode maps rem back up past each sorted candidate); every
    // comparison is against the ORIGINAL mode.
    let mut rem = mode
    for i in 0..<3 {
      if mode > candidates[i] {
        rem = rem - 1
      }
    }
    ctx.cabac.prev_intra_luma_pred_flag(false)
    ctx.cabac.rem_intra_luma_pred_mode(rem)
  }
  // tab_ipm write-back (2Nx2N: size_in_pus x size_in_pus at min-PU grid).
  let x_pu = x0 >> sps.log2_min_pu_size
  let y_pu = y0 >> sps.log2_min_pu_size
  let size_in_pus = cb_size >> sps.log2_min_pu_size
  for i in 0..<size_in_pus {
    for j in 0..<size_in_pus {
      ctx.tab_ipm[(y_pu + i) * sps.min_pu_width + x_pu + j] = mode
    }
  }
  // Chroma: DM (derived from luma) - one zero bin. Monochrome codes none
  // (`hls_coding_unit` reads it only under ChromaArrayType != 0).
  if sps.chroma_format_idc != 0 {
    ctx.cabac.intra_chroma_pred_mode(4)
  }
  // Transform tree: a single leaf TU of the CU size (hierarchy depth 0).
  match hevc_enc_transform_unit(ctx, x0, y0, log2_cb_size, mode) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // Post-CU bookkeeping (qp_y_tab feeds nothing with deblocking off, but
  // tab_ct_depth prices the neighbours' split flags).
  let x_cb2 = x0 >> sps.log2_min_cb_size
  let y_cb2 = y0 >> sps.log2_min_cb_size
  let len = cb_size >> sps.log2_min_cb_size
  for y in 0..<len {
    for x in 0..<len {
      ctx.qp_y_tab[(y_cb2 + y) * sps.min_cb_width + x_cb2 + x] = ctx.qp
      ctx.tab_ct_depth[(y_cb2 + y) * sps.min_cb_width + x_cb2 + x] = cb_depth
    }
  }
  Ok(())
}

///|
/// `luma_intra_pred_mode`'s MPM candidate derivation (tab_ipm neighbours
/// with CTB-boundary availability). */
fn hevc_enc_mpm_candidates(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
) -> Array[Int32] {
  let sps = ctx.sps
  let x_pu = x0 >> sps.log2_min_pu_size
  let y_pu = y0 >> sps.log2_min_pu_size
  let x0b = x0 & ((1 << sps.log2_ctb_size) - 1)
  let y0b = y0 & ((1 << sps.log2_ctb_size) - 1)
  let mut cand_up = if ctx.ctb_up || y0b != 0 {
    ctx.tab_ipm[(y_pu - 1) * sps.min_pu_width + x_pu]
  } else {
    1
  }
  let cand_left = if ctx.ctb_left || x0b != 0 {
    ctx.tab_ipm[y_pu * sps.min_pu_width + x_pu - 1]
  } else {
    1
  }
  let y_ctb = y0 >> sps.log2_ctb_size << sps.log2_ctb_size
  if y0 - 1 < y_ctb {
    cand_up = 1
  }
  if cand_left == cand_up {
    if cand_left < 2 {
      [0, 1, 26]
    } else {
      [
        cand_left,
        2 + ((cand_left - 2 - 1 + 32) & 31),
        2 + ((cand_left - 2 + 1) & 31),
      ]
    }
  } else {
    let c2 = if cand_left != 0 && cand_up != 0 {
      0
    } else if cand_left != 1 && cand_up != 1 {
      1
    } else {
      26
    }
    [cand_left, cand_up, c2]
  }
}

///|
/// Luma mode search: all 35 modes predicted through the decoder's own
/// `hevc_intra_predict` on the reconstruction picture (trial writes only
/// touch the block itself; the block's reference samples live outside it),
/// cost by SAD against the source with a small non-MPM regulariser. The
/// final prediction is re-run for the chosen mode, so the picture holds
/// exactly the decoder's prediction afterwards. */
fn hevc_enc_choose_luma_mode(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  cb_size : Int32,
  candidates : Array[Int32],
) -> Int32 {
  let sps = ctx.sps
  let log2 = match cb_size {
    8 => 3
    16 => 4
    _ => 5
  }
  let mut best_mode = 1
  let mut best_cost = -1L
  for mode in 0..<35 {
    hevc_intra_predict(ctx.pic, sps, ctx.pps, ctx.na, x0, y0, log2, 0, mode)
    let mut sad = 0L
    for y in 0..<cb_size {
      let prow = y0 + y
      for x in 0..<cb_size {
        let d = ctx.pic.y[prow * sps.width + x0 + x] -
          ctx.src_y[prow * sps.width + x0 + x]
        sad = sad + (if d < 0 { -d } else { d }).to_int64()
      }
    }
    let in_mpm = mode == candidates[0] ||
      mode == candidates[1] ||
      mode == candidates[2]
    let cost = sad + (if in_mpm { 0L } else { cb_size.to_int64() })
    if best_cost < 0L || cost < best_cost {
      best_cost = cost
      best_mode = mode
    }
  }
  // Final prediction with the chosen mode.
  hevc_intra_predict(ctx.pic, sps, ctx.pps, ctx.na, x0, y0, log2, 0, best_mode)
  best_mode
}

///|
/// `hls_transform_unit` for the single leaf TU: predictions, forward
/// transform + quantisation, cbf signalling, residual bins and the
/// decoder-kernel reconstruction. Bin order matches the decoder's read
/// order (cbf_cb, cbf_cr, cbf_luma, then luma/cb/cr residuals); the
/// predictions are computation-only and happen before the bins as needed. */
fn hevc_enc_transform_unit(
  ctx : HevcEncCtx,
  x0 : Int32,
  y0 : Int32,
  log2_tb : Int32,
  luma_mode : Int32,
) -> Result[Unit, String] {
  let sps = ctx.sps
  let n = 1 << log2_tb
  let bd = sps.bit_depth
  hevc_enc_set_na(ctx, x0, y0, n, n)
  // Luma prediction is already in the picture (the mode search's final
  // pass). Luma residual + levels.
  let luma_levels = hevc_enc_quant_plane(
    ctx,
    0,
    x0,
    y0,
    n,
    n,
    n,
    ctx.qp,
    log2_tb,
    true,
  )
  // Chroma: `n_cb` transform blocks of `1 << log2_c` samples per side. 4:2:0
  // and 4:4:4 code one block per TU, 4:2:2 stacks two vertically
  // (`y_c = y0 + (i << log2_c)`) — the exact loop `hls_transform_unit` runs.
  // The decoder predicts block i only after block i-1's residual has been
  // added, so the local reconstruction is applied per block here as well.
  let hs = sps.hshift[1]
  let vs = sps.vshift[1]
  let log2_c = log2_tb - hs
  let nc = 1 << log2_c
  let qp_c = hevc_enc_chroma_qp_fwd(sps, ctx.qp)
  // 4:2:2 remaps the DM mode through the decoder's `tab_mode_idx` table.
  let tu_mode_c = if sps.chroma_format_idc == 2 {
    hevc_tab_mode_idx[luma_mode]
  } else {
    luma_mode
  }
  // The decoder only codes chroma for `log2_trafo_size > 2` unless 4:4:4; the
  // encoder's minimum TU is 8x8 luma, so this is always taken today.
  // Monochrome codes no chroma bins at all — the decoder's transform tree
  // gates them on `chroma_format_idc != 0`.
  let chroma_coded = sps.chroma_format_idc != 0 &&
    (log2_tb > 2 || sps.chroma_format_idc == 3)
  let n_cb = if sps.chroma_format_idc == 2 { 2 } else { 1 }
  let cb_levels : Array[FixedArray[Int32]] = []
  let cr_levels : Array[FixedArray[Int32]] = []
  let cbf_cb : Array[Bool] = []
  let cbf_cr : Array[Bool] = []
  for _ in 0..<n_cb {
    cbf_cb.push(false)
    cbf_cr.push(false)
  }
  if chroma_coded {
    // The decoder's `set_neighbour_available` passes the block size in LUMA
    // units: `1 << (log2_trafo_size_c + hshift/vshift)`.
    let trafo_size_h = 1 << (log2_c + hs)
    let trafo_size_v = 1 << (log2_c + vs)
    for i in 0..<n_cb {
      let y_c = y0 + (i << log2_c)
      hevc_enc_set_na(ctx, x0, y_c, trafo_size_h, trafo_size_v)
      hevc_intra_predict(
        ctx.pic,
        sps,
        ctx.pps,
        ctx.na,
        x0,
        y_c,
        log2_c,
        1,
        tu_mode_c,
      )
      let lv = hevc_enc_quant_plane(
        ctx, 1, x0, y_c, nc, nc, nc, qp_c, log2_c, true,
      )
      if hevc_enc_levels_nonzero(lv) {
        let recon = hevc_enc_recon_transform(
          lv,
          nc,
          qp_c + sps.qp_bd_offset,
          bd,
          false,
          hevc_enc_last_x(lv, nc, hevc_scan_diag),
          hevc_enc_last_y(lv, nc, hevc_scan_diag),
        )
        hevc_add_residual_at(
          ctx.pic,
          1,
          x0 >> hs,
          y_c >> vs,
          fixed_to_array(recon),
          nc,
          bd,
        )
      }
      cbf_cb[i] = hevc_enc_levels_nonzero(lv)
      cb_levels.push(lv)
    }
    for i in 0..<n_cb {
      let y_c = y0 + (i << log2_c)
      hevc_enc_set_na(ctx, x0, y_c, trafo_size_h, trafo_size_v)
      hevc_intra_predict(
        ctx.pic,
        sps,
        ctx.pps,
        ctx.na,
        x0,
        y_c,
        log2_c,
        2,
        tu_mode_c,
      )
      let lv = hevc_enc_quant_plane(
        ctx, 2, x0, y_c, nc, nc, nc, qp_c, log2_c, true,
      )
      if hevc_enc_levels_nonzero(lv) {
        let recon = hevc_enc_recon_transform(
          lv,
          nc,
          qp_c + sps.qp_bd_offset,
          bd,
          false,
          hevc_enc_last_x(lv, nc, hevc_scan_diag),
          hevc_enc_last_y(lv, nc, hevc_scan_diag),
        )
        hevc_add_residual_at(
          ctx.pic,
          2,
          x0 >> hs,
          y_c >> vs,
          fixed_to_array(recon),
          nc,
          bd,
        )
      }
      cbf_cr[i] = hevc_enc_levels_nonzero(lv)
      cr_levels.push(lv)
    }
  }
  let cbf_luma = hevc_enc_levels_nonzero(luma_levels)
  // Bins: cbf_cb (one per 4:2:2 block), cbf_cr, then cbf_luma — but only
  // when chroma is coded at all (the decoder's transform tree gates the
  // cbf_cb/cr bins on `chroma_format_idc != 0`; monochrome writes none).
  // A single TU at `trafo_depth == 0` never splits, so both 4:2:2 bins are
  // always coded.
  if chroma_coded {
    for i in 0..<n_cb {
      ctx.cabac.cbf_cb_cr(0, cbf_cb[i])
    }
    for i in 0..<n_cb {
      ctx.cabac.cbf_cb_cr(0, cbf_cr[i])
    }
  }
  ctx.cabac.cbf_luma(0, cbf_luma)
  // Scan indices follow the mode ranges. The decoder gates BOTH scans on the
  // LUMA `log2_trafo_size < 4`, so the chroma scan is selected from the chroma
  // mode but gated on `log2_tb` (they coincide for 4:2:0, not for 4:2:2).
  let scan_luma = hevc_enc_scan_for_mode(luma_mode, log2_tb)
  let scan_chroma = hevc_enc_scan_for_mode(tu_mode_c, log2_tb)
  if cbf_luma {
    ctx.cabac.residual(luma_levels, n, scan_luma, 0)
    let recon = hevc_enc_recon_transform(
      luma_levels,
      n,
      ctx.qp + sps.qp_bd_offset,
      bd,
      false,
      hevc_enc_last_x(luma_levels, n, scan_luma),
      hevc_enc_last_y(luma_levels, n, scan_luma),
    )
    hevc_add_residual_at(ctx.pic, 0, x0, y0, fixed_to_array(recon), n, bd)
  }
  if chroma_coded {
    for i in 0..<n_cb {
      if cbf_cb[i] {
        ctx.cabac.residual(cb_levels[i], nc, scan_chroma, 1)
      }
    }
    for i in 0..<n_cb {
      if cbf_cr[i] {
        ctx.cabac.residual(cr_levels[i], nc, scan_chroma, 2)
      }
    }
  }
  // cbf_luma_tab for the boundary-strength derivation: the decoder marks every
  // min-TB of a coded luma block. Do the same here.
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
/// Scan index selection for an intra TU (`hls_transform_unit`'s rule). */
fn hevc_enc_scan_for_mode(mode : Int32, log2_tb : Int32) -> Int32 {
  if log2_tb < 4 {
    if mode >= 6 && mode <= 14 {
      hevc_scan_vert
    } else if mode >= 22 && mode <= 30 {
      hevc_scan_horiz
    } else {
      hevc_scan_diag
    }
  } else {
    hevc_scan_diag
  }
}

///|
/// Forward transform + quantise the source-vs-prediction residual of one
/// plane block (the prediction is already in the picture plane). `w`/`h`
/// are the block's plane dimensions; `n` the square transform size.
/// `is_intra` selects the 4x4 luma DST, which only intra blocks use. */
fn hevc_enc_quant_plane(
  ctx : HevcEncCtx,
  c_idx : Int32,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
  n : Int32,
  qp : Int32,
  log2_tb : Int32,
  is_intra : Bool,
) -> FixedArray[Int32] {
  let sps = ctx.sps
  let hs = sps.hshift[c_idx]
  let vs = sps.vshift[c_idx]
  let px = x0 >> hs
  let py = y0 >> vs
  let plane = ctx.pic.plane(c_idx)
  let stride = ctx.pic.plane_stride(c_idx)
  let src = if c_idx == 0 {
    ctx.src_y
  } else if c_idx == 1 {
    ctx.src_u
  } else {
    ctx.src_v
  }
  let src_stride = ctx.sps.width >> hs
  let res : FixedArray[Int32] = FixedArray::make(n * n, 0)
  for y in 0..<h {
    for x in 0..<w {
      res[y * n + x] = src[(py + y) * src_stride + px + x] -
        plane[(py + y) * stride + px + x]
    }
  }
  let dq = if is_intra && c_idx == 0 && log2_tb == 2 {
    hevc_enc_fdst4(res)
  } else {
    hevc_enc_fdct(res, n)
  }
  hevc_enc_quant_block(dq, n, qp, sps.bit_depth)
}

///|
/// Whether any level in the block is non-zero. */
fn hevc_enc_levels_nonzero(levels : FixedArray[Int32]) -> Bool {
  for i in 0..<levels.length() {
    if levels[i] != 0 {
      return true
    }
  }
  false
}

///|
/// Last-significant-coefficient coordinates of a level block in the given
/// scan order (the reconstruction path mirrors the decoder's branch
/// selection with these). */
fn hevc_enc_last_x(
  levels : FixedArray[Int32],
  n : Int32,
  scan_idx : Int32,
) -> Int32 {
  hevc_enc_last_coord(levels, n, scan_idx, 0)
}

///|
fn hevc_enc_last_y(
  levels : FixedArray[Int32],
  n : Int32,
  scan_idx : Int32,
) -> Int32 {
  hevc_enc_last_coord(levels, n, scan_idx, 1)
}

///|
fn hevc_enc_last_coord(
  levels : FixedArray[Int32],
  n : Int32,
  scan_idx : Int32,
  which : Int32,
) -> Int32 {
  let mut scan_x_cg : Array[Int32] = hevc_scan_1x1
  let mut scan_y_cg : Array[Int32] = hevc_scan_1x1
  let mut scan_x_off : Array[Int32] = hevc_diag_scan4x4_x
  let mut scan_y_off : Array[Int32] = hevc_diag_scan4x4_y
  if scan_idx == hevc_scan_diag {
    if n == 8 {
      scan_x_cg = hevc_diag_scan2x2_x
      scan_y_cg = hevc_diag_scan2x2_y
    } else if n == 16 {
      scan_x_cg = hevc_diag_scan4x4_x
      scan_y_cg = hevc_diag_scan4x4_y
    } else if n == 32 {
      scan_x_cg = hevc_diag_scan8x8_x
      scan_y_cg = hevc_diag_scan8x8_y
    }
  } else if scan_idx == hevc_scan_horiz {
    scan_x_cg = hevc_horiz_scan2x2_x
    scan_y_cg = hevc_horiz_scan2x2_y
    scan_x_off = hevc_horiz_scan4x4_x
    scan_y_off = hevc_horiz_scan4x4_y
  } else {
    scan_x_cg = hevc_horiz_scan2x2_y
    scan_y_cg = hevc_horiz_scan2x2_x
    scan_x_off = hevc_horiz_scan4x4_y
    scan_y_off = hevc_horiz_scan4x4_x
  }
  // Scan positions p map to row-major levels[(y_cg<<2)+oy) * n + (x_cg<<2)+ox];
  // the LAST significant coefficient is the greatest p with a non-zero level.
  let total = n * n
  let mut last = -1
  for p in 0..<total {
    let x_c = (scan_x_cg[p >> 4] << 2) + scan_x_off[p & 15]
    let y_c = (scan_y_cg[p >> 4] << 2) + scan_y_off[p & 15]
    if levels[y_c * n + x_c] != 0 {
      last = p
    }
  }
  if last < 0 {
    return 0
  }
  let x = (scan_x_cg[last >> 4] << 2) + scan_x_off[last & 15]
  let y = (scan_y_cg[last >> 4] << 2) + scan_y_off[last & 15]
  // The decoder swaps for the vert scan before consuming the coordinates.
  if scan_idx == hevc_scan_vert {
    if which == 0 {
      y
    } else {
      x
    }
  } else if which == 0 {
    x
  } else {
    y
  }
}

///|
/// FixedArray -> Array helper for `hevc_add_residual_at`. */
fn fixed_to_array(f : FixedArray[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  for i in 0..<f.length() {
    out.push(f[i])
  }
  out
}
