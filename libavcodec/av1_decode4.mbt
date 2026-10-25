///|
/// `sm_flag`: smooth-mode bit for the angle parameter.
fn av1_sm_flag(bctx : Av1BlockContext, idx : Int32) -> Int32 {
  if bctx.intra[idx] == 0 {
    return 0
  }
  let m = bctx.mode[idx]
  if m == av1_smooth_pred || m == av1_smooth_h_pred || m == av1_smooth_v_pred {
    av1_angle_smooth_edge_flag
  } else {
    0
  }
}

///|
fn av1_sm_uv_flag(bctx : Av1BlockContext, idx : Int32) -> Int32 {
  let m = bctx.uvmode[idx]
  if m == av1_smooth_pred || m == av1_smooth_h_pred || m == av1_smooth_v_pred {
    av1_angle_smooth_edge_flag
  } else {
    0
  }
}

///|
/// cfl_allowed_mask from dav1d tables.h (bit = dav1d `enum BlockSize`).
let av1_cfl_allowed_mask : Int32 = (1 << 7) |
  (1 << 8) |
  (1 << 9) |
  (1 << 11) |
  (1 << 12) |
  (1 << 13) |
  (1 << 14) |
  (1 << 15) |
  (1 << 16) |
  (1 << 17) |
  (1 << 18) |
  (1 << 19) |
  (1 << 20) |
  (1 << 21) // BS_32x32, 32x16, 32x8, 16x32, 16x16, 16x8, 16x4,
// 8x32, 8x16, 8x8, 8x4, 4x16, 4x8, 4x4

///|
/// `order_palette` + `read_pal_indices` from decode.c.
fn Av1TileCtx::read_pal_indices(
  self : Av1TileCtx,
  pal_idx : FixedArray[Byte],
  pal_sz : Int32,
  pl : Int32,
  w4 : Int32,
  h4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
) -> Unit {
  let stride = bw4 * 4
  let pal_tmp = self.pal_idx_uv // reused as the temp scan buffer
  pal_tmp[0] = self.msac.decode_uniform(pal_sz.reinterpret_as_uint()).to_byte()
  let color_map_base = (pl * 7 + (pal_sz - 2)) * 5 * 8
  let order = FixedArray::make(64 * 8, 0)
  let pctx = FixedArray::make(64, 0)
  for i in 1..<(4 * (w4 + h4) - 1) {
    // diagonals ("wave-front")
    let first = av1_imin(i, w4 * 4 - 1)
    let last = av1_imax(0, i - h4 * 4 + 1)
    // order_palette over the diagonal (j from first down to last)
    let mut have_top = i > first
    let mut m = 0
    let mut j = first
    while j >= last {
      let have_left = j > 0
      let base = (i - j) * stride + j
      let mut mask = 0
      let mut o_idx = 0
      let add = (v : Int32) => {
        order[m * 8 + o_idx] = v
        o_idx = o_idx + 1
        mask = mask | (1 << v)
      }
      if !have_left {
        pctx[m] = 0
        add(pal_tmp[base - stride].to_int())
      } else if !have_top {
        pctx[m] = 0
        add(pal_tmp[base - 1].to_int())
      } else {
        let lv = pal_tmp[base - 1].to_int()
        let t = pal_tmp[base - stride].to_int()
        let tl = pal_tmp[base - (stride + 1)].to_int()
        let same_t_l = t == lv
        let same_t_tl = t == tl
        let same_l_tl = lv == tl
        let same_all = same_t_l && same_t_tl && same_l_tl
        if same_all {
          pctx[m] = 4
          add(t)
        } else if same_t_l {
          pctx[m] = 3
          add(t)
          add(tl)
        } else if same_t_tl || same_l_tl {
          pctx[m] = 2
          add(tl)
          add(if same_t_tl { lv } else { t })
        } else {
          pctx[m] = 1
          add(av1_imin(t, lv))
          add(av1_imax(t, lv))
          add(tl)
        }
      }
      let mut bit = 0
      let mut mm = 1
      while mm < 0x100 {
        if (mask & mm) == 0 {
          order[m * 8 + o_idx] = bit
          o_idx = o_idx + 1
        }
        mm = mm << 1
        bit = bit + 1
      }
      have_top = true
      m = m + 1
      j = j - 1
    }
    // decode symbols along the diagonal
    let mut j2 = first
    let mut m2 = 0
    while j2 >= last {
      let color_idx = self.msac.decode_symbol_adapt(
        self.cdf.color_map,
        color_map_base + pctx[m2] * 8,
        pal_sz - 1,
      )
      pal_tmp[(i - j2) * stride + j2] = order[m2 * 8 + color_idx].to_byte()
      m2 = m2 + 1
      j2 = j2 - 1
    }
  }
  // pal_idx_finish_c: pack pairs and replicate invisible right/bottom edges.
  let dst_stride = bw4 * 2
  let visible_stride = w4 * 2
  for y in 0..<(h4 * 4) {
    for x in 0..<visible_stride {
      let a = pal_tmp[y * stride + x * 2].to_int()
      let b = pal_tmp[y * stride + x * 2 + 1].to_int()
      pal_idx[y * dst_stride + x] = (a | (b << 4)).to_byte()
    }
    if visible_stride < dst_stride {
      let last = pal_tmp[y * stride + w4 * 4 - 1].to_int() * 0x11
      for x in visible_stride..<dst_stride {
        pal_idx[y * dst_stride + x] = last.to_byte()
      }
    }
  }
  if h4 < bh4 {
    let last_row = (h4 * 4 - 1) * dst_stride
    for y in (h4 * 4)..<(bh4 * 4) {
      for x in 0..<dst_stride {
        pal_idx[y * dst_stride + x] = pal_idx[last_row + x]
      }
    }
  }
}

///|
/// `decode_b` for intra blocks (key/intra-only frames; intrabc rejected).
fn Av1TileCtx::decode_b(
  self : Av1TileCtx,
  _bl : Int32,
  bs : Int32,
  _bp : Int32,
  intra_edge_flags : Int32,
) -> Unit raise Av1DecError {
  let f = self.f
  let hdr = f.hdr
  if hdr.allow_intrabc {
    raise Av1DecError::Unsupported("PATCHWELCOME: AV1 intrabc")
  }
  if hdr.frame_type != av1_frame_key && hdr.frame_type != av1_frame_intra_only {
    raise Av1DecError::Unsupported("PATCHWELCOME: AV1 inter frame")
  }
  let bx4 = self.bx & 31
  let by4 = self.by & 31
  let ss_ver = f.ss_v
  let ss_hor = f.ss_h
  let cbx4 = bx4 >> ss_hor
  let cby4 = by4 >> ss_ver
  let bw4 = av1_bdim(bs, 0)
  let bh4 = av1_bdim(bs, 1)
  let w4 = av1_imin(bw4, f.bw - self.bx)
  let h4 = av1_imin(bh4, f.bh - self.by)
  let cbw4 = (bw4 + ss_hor) >> ss_hor
  let cbh4 = (bh4 + ss_ver) >> ss_ver
  let has_chroma = !f.seq.monochrome &&
    (bw4 > ss_hor || (self.bx & 1) != 0) &&
    (bh4 > ss_ver || (self.by & 1) != 0)
  let a = f.a[self.a_idx]
  let l = f.l
  // skip (segmentation not enabled for our streams; seg_id stays 0)
  let seg_id = 0
  if hdr.segmentation_enabled {
    raise Av1DecError::Unsupported(
      "PATCHWELCOME: AV1 segmentation in pixel path",
    )
  }
  let sctx = a.skip[bx4] + l.skip[by4]
  let skip = self.msac.decode_bool_adapt(self.cdf.skip, sctx * 2) != 0
  // cdef index (n_bits may be 0: no bits consumed)
  if !skip {
    // 64x64 SBs use one of the four 128-area slots; 128x128 SBs use the
    // quadrant index within the area (dav1d passes an already-offset pointer
    // for 64x64 SBs).
    let idx = ((self.bx & 16) >> 4) + ((self.by & 16) >> 3)
    if self.cur_sb_cdef_idx[idx] == -1 {
      let v = self.msac.decode_bools(hdr.cdef_bits).reinterpret_as_int()
      self.cur_sb_cdef_idx[idx] = v
      let lfm = f.lf_mask[(self.by >> 5) * f.sb128w + (self.bx >> 5)]
      lfm.cdef_idx[idx] = v
      if bw4 > 16 {
        self.cur_sb_cdef_idx[idx + 1] = v
        lfm.cdef_idx[idx + 1] = v
      }
      if bh4 > 16 {
        self.cur_sb_cdef_idx[idx + 2] = v
        lfm.cdef_idx[idx + 2] = v
      }
      if bw4 == 32 && bh4 == 32 {
        self.cur_sb_cdef_idx[idx + 3] = v
        lfm.cdef_idx[idx + 3] = v
      }
    }
  }
  // delta-q (not present in our streams; guard anyway)
  if hdr.delta_q_present {
    raise Av1DecError::Unsupported("PATCHWELCOME: AV1 delta_q in pixel path")
  }
  // intra block syntax
  let ymode_cdf_base = (
      av1_intra_mode_context[a.mode[bx4]].to_int() * 5 +
      av1_intra_mode_context[l.mode[by4]].to_int()
    ) *
    16
  let mut y_mode = self.msac.decode_symbol_adapt(
    self.cdf.kfym,
    ymode_cdf_base,
    av1_n_intra_pred_modes - 1,
  )
  let mut y_angle = 0
  if av1_bdim(bs, 2) + av1_bdim(bs, 3) >= 2 &&
    y_mode >= av1_vert_pred &&
    y_mode <= av1_vert_left_pred {
    let angle = self.msac.decode_symbol_adapt(
      self.cdf.angle_delta,
      (y_mode - av1_vert_pred) * 8,
      6,
    )
    y_angle = angle - 3
  }
  let mut uv_mode = av1_dc_pred
  let mut uv_angle = 0
  let mut cfl_alpha = (0, 0)
  let mut pal_sz = (0, 0)
  if has_chroma {
    let cfl_allowed = if f.seg_lossless[seg_id] {
      cbw4 == 1 && cbh4 == 1
    } else {
      (av1_cfl_allowed_mask & (1 << bs)) != 0
    }
    let nsym = av1_n_uv_intra_pred_modes - 1 - (if cfl_allowed { 0 } else { 1 })
    let uv_base = ((if cfl_allowed { 1 } else { 0 }) * 13 + y_mode) * 16
    uv_mode = self.msac.decode_symbol_adapt(self.cdf.uv_mode, uv_base, nsym)
    if uv_mode == av1_cfl_pred {
      let sign = self.msac.decode_symbol_adapt(self.cdf.cfl_sign, 0, 7) + 1
      let sign_u = (sign * 0x56) >> 8
      let sign_v = sign - sign_u * 3
      let au = if sign_u != 0 {
        let ctx = (if sign_u == 2 { 3 } else { 0 }) + sign_v
        let v = self.msac.decode_symbol_adapt(self.cdf.cfl_alpha, ctx * 16, 15) +
          1
        if sign_u == 1 {
          -v
        } else {
          v
        }
      } else {
        0
      }
      let av = if sign_v != 0 {
        let ctx = (if sign_v == 2 { 3 } else { 0 }) + sign_u
        let v = self.msac.decode_symbol_adapt(self.cdf.cfl_alpha, ctx * 16, 15) +
          1
        if sign_v == 1 {
          -v
        } else {
          v
        }
      } else {
        0
      }
      cfl_alpha = (au, av)
    } else if av1_bdim(bs, 2) + av1_bdim(bs, 3) >= 2 &&
      uv_mode >= av1_vert_pred &&
      uv_mode <= av1_vert_left_pred {
      let angle = self.msac.decode_symbol_adapt(
        self.cdf.angle_delta,
        (uv_mode - av1_vert_pred) * 8,
        6,
      )
      uv_angle = angle - 3
    }
  }
  // palette
  if hdr.allow_screen_content_tools &&
    av1_imax(bw4, bh4) <= 16 &&
    bw4 + bh4 >= 4 {
    let sz_ctx = av1_bdim(bs, 2) + av1_bdim(bs, 3) - 2
    if y_mode == av1_dc_pred {
      let pal_ctx = (if a.pal_sz[bx4] > 0 { 1 } else { 0 }) +
        (if l.pal_sz[by4] > 0 { 1 } else { 0 })
      let use_y_pal = self.msac.decode_bool_adapt(
        self.cdf.pal_y,
        (sz_ctx * 3 + pal_ctx) * 2,
      )
      if use_y_pal != 0 {
        pal_sz = (self.read_pal_plane(0, sz_ctx, bx4, by4), pal_sz.1)
        self.copy_pal_block_y(bx4, by4, bw4, bh4)
      }
    }
    if has_chroma && uv_mode == av1_dc_pred {
      let pal_ctx = if pal_sz.0 > 0 { 1 } else { 0 }
      let use_uv_pal = self.msac.decode_bool_adapt(self.cdf.pal_uv, pal_ctx * 2)
      if use_uv_pal != 0 {
        pal_sz = (pal_sz.0, self.read_pal_plane(1, sz_ctx, bx4, by4))
        self.read_pal_uv(pal_sz.1)
        self.copy_pal_block_uv(bx4, by4, bw4, bh4)
      }
    }
  }
  // filter intra
  if y_mode == av1_dc_pred &&
    pal_sz.0 == 0 &&
    av1_imax(av1_bdim(bs, 2), av1_bdim(bs, 3)) <= 3 &&
    f.seq.enable_filter_intra {
    let is_filter = self.msac.decode_bool_adapt(
      self.cdf.use_filter_intra,
      bs * 2,
    )
    if is_filter != 0 {
      y_mode = av1_filter_pred
      y_angle = self.msac.decode_symbol_adapt(self.cdf.filter_intra, 0, 4)
    }
  }
  // palette indices (dav1d reads them after filter_intra, before tx size)
  if pal_sz.0 != 0 {
    self.read_pal_indices(self.pal_idx_y, pal_sz.0, 0, w4, h4, bw4, bh4)
  }
  if has_chroma && pal_sz.1 != 0 {
    let cw4 = (w4 + ss_hor) >> ss_hor
    let ch4 = (h4 + ss_ver) >> ss_ver
    self.read_pal_indices(self.pal_idx_uv, pal_sz.1, 1, cw4, ch4, cbw4, cbh4)
  }
  // tx size
  let (tx, uvtx) = if f.seg_lossless[seg_id] {
    (0, 0)
  } else {
    let mut t0 = av1_max_txfm_size_for_bs[bs * 4].to_int()
    let uvt = av1_max_txfm_size_for_bs[bs * 4 + 1].to_int() // 4:2:0 column
    if hdr.tx_mode == 2 && av1_txfm_max(t0) > 0 {
      let tctx = (if l.tx_intra[by4] >= av1_txfm_lh(t0) { 1 } else { 0 }) +
        (if a.tx_intra[bx4] >= av1_txfm_lw(t0) { 1 } else { 0 })
      let tx_cdf_base = ((av1_txfm_max(t0) - 1) * 3 + tctx) * 4
      let depth = self.msac.decode_symbol_adapt(
        self.cdf.txsz,
        tx_cdf_base,
        av1_imin(av1_txfm_max(t0), 2),
      )
      let mut d = depth
      while d > 0 {
        t0 = av1_txfm_sub(t0)
        d = d - 1
      }
    }
    (t0, uvt)
  }
  let b : Av1IntraBlock = {
    seg_id,
    skip,
    y_mode,
    y_angle,
    uv_mode,
    uv_angle,
    cfl_alpha,
    pal_sz,
    tx,
    uvtx,
  }
  // reconstruction
  self.recon_b_intra(bs, intra_edge_flags, b)
  if f.lf_y_active {
    let lfm = f.lf_mask[(self.by >> 5) * f.sb128w + (self.bx >> 5)]
    f.create_lf_mask_intra(
      lfm,
      self.bx,
      self.by,
      bs,
      b.tx,
      b.uvtx,
      a.tx_lpf_y,
      bx4,
      l.tx_lpf_y,
      by4,
      a.tx_lpf_uv,
      cbx4,
      l.tx_lpf_uv,
      cby4,
      has_chroma,
      f.lf_lvl,
      seg_id,
    )
  }
  // CDEF noskip mask: 8x8 blocks that contain any coded coefficients.
  if !skip {
    let lfm = f.lf_mask[(self.by >> 5) * f.sb128w + (self.bx >> 5)]
    let mask : UInt = ((0xFFFFFFFFU >> (32 - bw4)) << (bx4 & 15))
    let bx_idx = (bx4 & 16) >> 4
    let mut row = by4 >> 1
    let mut y = 0
    while y < bh4 {
      let i = row * 2 + bx_idx
      lfm.noskip[i] = lfm.noskip[i] | mask
      if bw4 == 32 {
        lfm.noskip[row * 2 + 1] = lfm.noskip[row * 2 + 1] | mask
      }
      y = y + 2
      row = row + 1
    }
  }
  // update contexts
  let y_mode_nofilt = if y_mode == av1_filter_pred {
    av1_dc_pred
  } else {
    y_mode
  }
  let t_lw = av1_txfm_lw(tx)
  let t_lh = av1_txfm_lh(tx)
  for i in 0..<bw4 {
    a.tx_intra[bx4 + i] = t_lw
    a.tx[bx4 + i] = t_lw
    a.mode[bx4 + i] = y_mode_nofilt
    a.pal_sz[bx4 + i] = pal_sz.0
    a.seg_pred[bx4 + i] = 0
    a.skip_mode[bx4 + i] = 0
    a.intra[bx4 + i] = 1
    a.skip[bx4 + i] = if skip { 1 } else { 0 }
    self.pal_sz_uv[bx4 + i] = if has_chroma { pal_sz.1 } else { 0 }
  }
  for i in 0..<bh4 {
    l.tx_intra[by4 + i] = t_lh
    l.tx[by4 + i] = t_lh
    l.mode[by4 + i] = y_mode_nofilt
    l.pal_sz[by4 + i] = pal_sz.0
    l.seg_pred[by4 + i] = 0
    l.skip_mode[by4 + i] = 0
    l.intra[by4 + i] = 1
    l.skip[by4 + i] = if skip { 1 } else { 0 }
    self.pal_sz_uv[32 + by4 + i] = if has_chroma { pal_sz.1 } else { 0 }
  }
  if has_chroma {
    for i in 0..<cbw4 {
      a.uvmode[cbx4 + i] = if uv_mode == av1_cfl_pred {
        av1_dc_pred
      } else {
        uv_mode
      }
    }
    for i in 0..<cbh4 {
      l.uvmode[cby4 + i] = if uv_mode == av1_cfl_pred {
        av1_dc_pred
      } else {
        uv_mode
      }
    }
  }
}
