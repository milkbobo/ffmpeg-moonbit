///|
/// Single-threaded frame wiring for the previously validated inter syntax,
/// prediction, residual and LF primitives (dav1d 1.5.1 decode.c).
priv struct Av1InterFrameCtx {
  prepared : Av1RefmvsPreparedFrame
  y : FixedArray[Av1ReconRefPlane]
  u : FixedArray[Av1ReconRefPlane]
  v : FixedArray[Av1ReconRefPlane]
  scaled : FixedArray[Bool]
  global_motion : FixedArray[Av1WarpedMotion?]
}

///|
fn Av1TileCtx::decode_inter_block(
  self : Av1TileCtx,
  bs : Int32,
  edge_flags : Int32,
  seg_id : Int32,
  seg_pred : Int32,
  skip_mode : Bool,
  skip : Bool,
) -> Unit raise Av1DecError {
  let f = self.f
  let hdr = f.hdr
  guard f.inter is Some(frame) && self.rstate is Some(rstate) else {
    raise Av1DecError::Unsupported("av1: missing inter references")
  }
  let bx = self.bx
  let by = self.by
  let bx4 = bx & 31
  let by4 = by & 31
  let bw4 = av1_bdim(bs, 0)
  let bh4 = av1_bdim(bs, 1)
  let w4 = av1_imin(bw4, f.bw - bx)
  let h4 = av1_imin(bh4, f.bh - by)
  let has_chroma = !f.seq.monochrome &&
    (bw4 > f.ss_h || (bx & 1) != 0) &&
    (bh4 > f.ss_v || (by & 1) != 0)
  let a = f.a[self.a_idx]
  let l = f.l
  let neighbors = f.inter_a[self.a_idx]
  let b = av1_inter_read_block(self.msac, self.cdf, rstate, neighbors, {
    bs,
    bx4: bx,
    by4: by,
    bx4_ctx: bx4,
    by4_ctx: by4,
    w4,
    h4,
    tile_col_start4: self.col_start,
    tile_col_end4: self.col_end,
    tile_row_start4: self.row_start,
    tile_row_end4: self.row_end,
    top_has_right: (edge_flags & av1_edge_i444_top_has_right) != 0,
    have_top: by > self.row_start,
    have_left: bx > self.col_start,
    skip_mode,
    skip_ref0: if hdr.skip_mode_refs.length() == 2 {
      hdr.skip_mode_refs[0]
    } else {
      0
    },
    skip_ref1: if hdr.skip_mode_refs.length() == 2 {
      hdr.skip_mode_refs[1]
    } else {
      0
    },
    seg_present: hdr.segmentation_enabled,
    seg_ref: if hdr.segmentation_enabled {
      hdr.seg_ref[seg_id]
    } else {
      -1
    },
    seg_globalmv: hdr.segmentation_enabled && hdr.seg_globalmv[seg_id],
    seg_skip: hdr.segmentation_enabled && hdr.seg_skip[seg_id],
    switchable_comp_refs: hdr.reference_select,
    inter_intra: f.seq.enable_interintra,
    masked_compound: f.seq.enable_masked_compound,
    jnt_comp: f.seq.enable_jnt_comp,
    dual_filter: f.seq.enable_dual_filter,
    switchable_filter: hdr.interpolation_filter == 3,
    subpel_filter_mode: if hdr.interpolation_filter == 3 {
      0
    } else {
      hdr.interpolation_filter
    },
    switchable_motion_mode: hdr.is_motion_mode_switchable,
    warp_motion: hdr.allow_warped_motion,
    order_hint_bits: f.seq.order_hint_bits,
    cur_order_hint: hdr.order_hint,
    ref_order_hint: frame.prepared.ref_poc,
    ref_scaled: frame.scaled,
  })
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
  let obmc : Av1ReconObmc = {
    rows: rstate.tile.rows,
    nstate: neighbors,
    w4,
    h4,
    have_top: by > self.row_start,
    have_left: bx > self.col_start,
  }
  let intra = if b.interintra.kind != 0 {
    Some(self.interintra_prediction(bs, b.interintra.mode))
  } else {
    None
  }
  let weight = if b.ref1 >= 0 {
    av1_jnt_comp_weight(
      f.seq.order_hint_bits,
      hdr.order_hint,
      frame.prepared.ref_poc[b.ref0],
      frame.prepared.ref_poc[b.ref1],
    )
  } else {
    8
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
    l_ccoef: l.ccoef,
  }
  match
    av1_recon_b_inter(
      ctx,
      bs,
      b,
      seg_id,
      skip,
      tx.max_ytx,
      tx.split0,
      tx.split1,
      tx.uvtx,
      frame.y,
      frame.u,
      frame.v,
      hdr.width,
      hdr.height,
      bx,
      by,
      weight,
      intra,
      Some(obmc),
      global_motion=Some(frame.global_motion),
    ) {
    Ok(_) => ()
    Err(e) => raise Av1DecError::Unsupported(e)
  }
  if f.lf_y_active {
    let global = b.mode == (if b.ref1 >= 0 { 6 } else { 2 })
    // Existing LF primitive expects a segment table with its selected
    // ref/mode level at offset zero within each direction's 16 entries.
    let levels = FixedArray::make(64, 0)
    for dir in 0..<4 {
      levels[dir * 16] = self.lf_lvl_cur[seg_id * 64 +
        dir * 16 +
        (b.ref0 + 1) * 2 +
        (if global { 0 } else { 1 })]
    }
    let mask = f.lf_mask[(by >> 5) * f.sb128w + (bx >> 5)]
    av1_create_lf_mask_inter(
      f.lf_level,
      levels,
      f.b4_stride,
      f.w4,
      f.h4,
      f.ss_h,
      f.ss_v,
      mask.fy,
      mask.fuv,
      bx,
      by,
      skip,
      bs,
      if f.seg_lossless[seg_id] {
        0
      } else {
        tx.max_ytx
      },
      [tx.split0.reinterpret_as_int(), tx.split1.reinterpret_as_int()],
      if f.seg_lossless[seg_id] {
        0
      } else {
        tx.uvtx
      },
      a.tx_lpf_y,
      bx4,
      l.tx_lpf_y,
      by4,
      a.tx_lpf_uv,
      bx4 >> f.ss_h,
      l.tx_lpf_uv,
      by4 >> f.ss_v,
      has_chroma,
      0,
    )
  }
  for
    (edge, off, len, dim, pal_off) in [
      (a, bx4, bw4, av1_bdim(bs, 2), 0),
      (l, by4, bh4, av1_bdim(bs, 3), 32),
    ] {
    for i in 0..<len {
      edge.seg_pred[off + i] = seg_pred
      edge.skip_mode[off + i] = if skip_mode { 1 } else { 0 }
      edge.intra[off + i] = 0
      edge.skip[off + i] = if skip { 1 } else { 0 }
      edge.pal_sz[off + i] = 0
      self.pal_sz_uv[pal_off + off + i] = 0
      edge.tx_intra[off + i] = dim
      edge.mode[off + i] = b.mode
    }
  }
  if has_chroma {
    for i in 0..<((bw4 + f.ss_h) >> f.ss_h) {
      a.uvmode[(bx4 >> f.ss_h) + i] = av1_dc_pred
    }
    for i in 0..<((bh4 + f.ss_v) >> f.ss_v) {
      l.uvmode[(by4 >> f.ss_v) + i] = av1_dc_pred
    }
  }
  neighbors.set_block(bx, by, bw4, bh4, {
    intra: false,
    comp_type: b.comp_type,
    ref0: b.ref0,
    ref1: b.ref1,
    filter0: b.filter0,
    filter1: b.filter1,
  })
}

///|
/// inter-intra uses the current frame's edges, including the pre-filter
/// backup at SB-row boundaries (recon_tmpl.c:1620,1741).
fn Av1TileCtx::interintra_prediction(
  self : Av1TileCtx,
  bs : Int32,
  mode : Int32,
) -> Av1ReconPlanes {
  let f = self.f
  let bw4 = av1_bdim(bs, 0)
  let bh4 = av1_bdim(bs, 1)
  let cw4 = (bw4 + f.ss_h) >> f.ss_h
  let ch4 = (bh4 + f.ss_v) >> f.ss_v
  let predict = (pl : Int32, sx : Int32, sy : Int32, tw : Int32, th : Int32) => {
    let stride = if pl == 0 { f.y_stride } else { f.uv_stride }
    let x = self.bx >> sx
    let y = self.by >> sy
    let boundary = (self.by & (f.sb_step - 1)) == 0
    let sby = self.by >> f.sb_shift
    let angle = Ref(0)
    let m = av1_prepare_intra_edges(
      x,
      x > self.col_start >> sx,
      y,
      y > self.row_start >> sy,
      self.col_end >> sx,
      self.row_end >> sy,
      0,
      f.planes[pl],
      4 * (y * stride + x),
      stride,
      if boundary {
        Some(f.ipred_edge[pl])
      } else {
        None
      },
      f.sb128w * 128 * (sby - 1),
      if mode == 3 {
        av1_smooth_pred
      } else {
        mode
      },
      angle,
      tw,
      th,
      0,
      self.edge_buf,
      192,
      mid=f.mid,
    )
    let dst = FixedArray::make(tw * th * 16, 0)
    av1_ipred_predict(
      m,
      dst,
      0,
      tw * 4,
      self.edge_buf,
      192,
      tw * 4,
      th * 4,
      0,
      0,
      0,
      bd_max=f.pixel_max,
      mid=f.mid,
    )
    dst
  }
  {
    y: predict(0, 0, 0, bw4, bh4),
    u: if f.seq.monochrome {
      []
    } else {
      predict(1, f.ss_h, f.ss_v, cw4, ch4)
    },
    v: if f.seq.monochrome {
      []
    } else {
      predict(2, f.ss_h, f.ss_v, cw4, ch4)
    },
    w: bw4 * 4,
    h: bh4 * 4,
    cw: cw4 * 4,
    ch: ch4 * 4,
  }
}

///|
fn Av1TileCtx::finish_inter_block(
  self : Av1TileCtx,
  bs : Int32,
  seg_id : Int32,
  skip : Bool,
) -> Unit {
  let f = self.f
  let bw4 = av1_bdim(bs, 0)
  let bh4 = av1_bdim(bs, 1)
  if f.hdr.segmentation_enabled && f.hdr.segmentation_update_map {
    for y in 0..<av1_imin(bh4, f.bh - self.by) {
      for x in 0..<av1_imin(bw4, f.bw - self.bx) {
        f.cur_segmap[(self.by + y) * f.b4_stride + self.bx + x] = seg_id.to_byte()
      }
    }
  }
  if !skip {
    let bx4 = self.bx & 31
    let mask = f.lf_mask[(self.by >> 5) * f.sb128w + (self.bx >> 5)]
    let bits = 0xFFFFFFFFU >> (32 - bw4) << (bx4 & 15)
    for y = 0; y < bh4; y = y + 2 {
      let row = ((self.by & 31) + y) >> 1
      let i = row * 2 + ((bx4 & 16) >> 4)
      mask.noskip[i] = mask.noskip[i] | bits
      if bw4 == 32 {
        mask.noskip[row * 2 + 1] = mask.noskip[row * 2 + 1] | bits
      }
    }
  }
}
