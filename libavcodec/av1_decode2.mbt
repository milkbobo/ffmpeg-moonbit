///|
/// `get_uv_inter_txtp` from dav1d `env.h`: chroma inherits the luma transform
/// type unless the chroma tx is too large or a directional type is not
/// representable.
fn av1_get_uv_inter_txtp(tx : Int32, ytxtp : Int) -> Int {
  if av1_txfm_max(tx) == 3 {
    if ytxtp == 9 { 9 } else { 0 }
  } else if av1_txfm_min(tx) == 2 &&
    ((1 << ytxtp) & ((1 << 14) | (1 << 15) | (1 << 12) | (1 << 13))) != 0 {
    0
  } else {
    ytxtp
  }
}

///|
/// Transform-type selection from dav1d `decode_coefs` (non-lossless only).
/// Inter luma uses `txtp_inter1/2/3`; chroma derives from the luma type via
/// `get_uv_inter_txtp`, intra chroma from the uv-mode LUT.
pub fn av1_decode_txtp(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  intra : Bool,
  plane : Int,
  tx : Int32,
  qidx_zero : Bool,
  reduced_txtp_set : Bool,
  y_mode : Int,
  y_angle : Int,
  uv_mode : Int,
  luma_txtp : Int,
) -> Int {
  if av1_txfm_max(tx) + (if intra { 1 } else { 0 }) >= 4 {
    return 0 // DCT_DCT
  }
  if plane != 0 {
    if intra {
      return av1_txtp_from_uvmode[uv_mode].to_int()
    }
    return av1_get_uv_inter_txtp(tx, luma_txtp)
  }
  if qidx_zero {
    return 0
  }
  let t_dim_min = av1_txfm_min(tx)
  if intra {
    let y_mode_nofilt = if y_mode == av1_filter_pred {
      av1_filter_mode_to_y_mode[y_angle].to_int()
    } else {
      y_mode
    }
    if reduced_txtp_set || t_dim_min == 2 {
      let idx = msac.decode_symbol_adapt(
        cdf.txtp_intra2, (t_dim_min * 13 + y_mode_nofilt) * 8, 4,
      )
      av1_tx_types_per_set[idx].to_int()
    } else {
      let idx = msac.decode_symbol_adapt(
        cdf.txtp_intra1, (t_dim_min * 13 + y_mode_nofilt) * 8, 6,
      )
      av1_tx_types_per_set[idx + 5].to_int()
    }
  } else if reduced_txtp_set || av1_txfm_max(tx) == 3 {
    let idx = msac.decode_bool_adapt(
      cdf.txtp_inter3, t_dim_min * 2,
    ).reinterpret_as_int()
    if idx != 0 { 0 } else { 9 } // DCT_DCT : IDTX
  } else if t_dim_min == 2 {
    let idx = msac.decode_symbol_adapt(cdf.txtp_inter2, 0, 11)
    av1_tx_types_per_set[idx + 12].to_int()
  } else {
    let idx = msac.decode_symbol_adapt(cdf.txtp_inter1, t_dim_min * 16, 15)
    av1_tx_types_per_set[idx + 24].to_int()
  }
}

///|
/// `decode_coefs` from dav1d recon_tmpl.c. Returns
/// `(eob, txtp, res_ctx)`; eob = -1 means all-skip.
fn Av1TileCtx::decode_coefs(
  self : Av1TileCtx,
  a : FixedArray[Int32],
  a_off : Int32,
  l : FixedArray[Int32],
  l_off : Int32,
  tx : Int32,
  bs : Int32,
  b : Av1IntraBlock,
  intra : Bool,
  plane : Int32,
  cf : FixedArray[Int32],
  luma_txtp? : Int = 0,
) -> (Int32, Int32, Int32) {
  let chroma = if plane != 0 { 1 } else { 0 }
  let lossless = self.f.seg_lossless[b.seg_id]
  let t_dim_ctx = av1_txfm_ctx(tx)
  let sctx = av1_get_skip_ctx(
    tx,
    bs,
    a,
    a_off,
    l,
    l_off,
    chroma == 1,
    self.f.ss_h,
    self.f.ss_v,
  )
  let all_skip = self.msac.decode_bool_adapt(
    self.cdf.coef_skip,
    (t_dim_ctx * 13 + sctx) * 2,
  )
  if all_skip != 0 {
    let txtp0 = if lossless { 16 } else { 0 }
    return (-1, txtp0, 0x40)
  }
  let txtp = if lossless {
    16 // WHT_WHT
  } else {
    av1_decode_txtp(
      self.msac, self.cdf, intra, plane, tx, self.f.seg_qidx[b.seg_id] == 0,
      self.f.hdr.reduced_tx_set, b.y_mode, b.y_angle, b.uv_mode, luma_txtp,
    )
  }
  let slw = av1_imin(av1_txfm_lw(tx), 3)
  let slh = av1_imin(av1_txfm_lh(tx), 3)
  let tx2dszctx = slw + slh
  let tx_class = av1_tx_type_class[txtp].to_int()
  let is_1d = if tx_class != 0 { 1 } else { 0 }
  let eob_bin = match tx2dszctx {
    0 =>
      self.msac.decode_symbol_adapt(
        self.cdf.eob_bin_16,
        (chroma * 2 + is_1d) * 8,
        4,
      )
    1 =>
      self.msac.decode_symbol_adapt(
        self.cdf.eob_bin_32,
        (chroma * 2 + is_1d) * 8,
        5,
      )
    2 =>
      self.msac.decode_symbol_adapt(
        self.cdf.eob_bin_64,
        (chroma * 2 + is_1d) * 8,
        6,
      )
    3 =>
      self.msac.decode_symbol_adapt(
        self.cdf.eob_bin_128,
        (chroma * 2 + is_1d) * 8,
        7,
      )
    4 =>
      self.msac.decode_symbol_adapt(
        self.cdf.eob_bin_256,
        (chroma * 2 + is_1d) * 16,
        8,
      )
    5 => self.msac.decode_symbol_adapt(self.cdf.eob_bin_512, chroma * 16, 9)
    _ => self.msac.decode_symbol_adapt(self.cdf.eob_bin_1024, chroma * 16, 10)
  }
  let eob = if eob_bin > 1 {
    let hi = self.msac.decode_bool_adapt(
      self.cdf.eob_hi_bit,
      ((t_dim_ctx * 2 + chroma) * 11 + eob_bin) * 2,
    )
    ((hi.reinterpret_as_int() | 2) << (eob_bin - 2)) |
    self.msac.decode_bools(eob_bin - 2).reinterpret_as_int()
  } else {
    eob_bin
  }
  let eob_cdf_base = (t_dim_ctx * 2 + chroma) * 4 * 4
  let hi_cdf_base = (av1_imin(t_dim_ctx, 3) * 2 + chroma) * 84
  let mut rc = 0
  let mut dc_tok = 0
  let levels = self.levels
  if eob != 0 {
    let lo_cdf_base = (t_dim_ctx * 2 + chroma) * 41 * 4
    // Per-class scan layout.
    let (stride, lo_ctx_tbl, clear_rows) = if tx_class == 0 {
      let nonsquare = if tx >= 5 { 1 } else { 0 }
      (4 << slh, nonsquare + (tx & nonsquare), (4 << slw) + 2)
    } else if tx_class == 1 {
      (16, 0, (4 << slh) + 2)
    } else {
      (16, 0, (4 << slw) + 2)
    }
    for i in 0..<(stride * clear_rows) {
      levels[i] = b'\x00'
    }
    let shift = if tx_class == 2 { slw + 2 } else { slh + 2 }
    let shift2 = if tx_class == 2 { slh + 2 } else { 0 }
    let mask = if tx_class == 2 { (4 << slw) - 1 } else { (4 << slh) - 1 }
    let mut ctx = 1 +
      (if eob > 2 << tx2dszctx { 1 } else { 0 }) +
      (if eob > 4 << tx2dszctx { 1 } else { 0 })
    let eob_tok = self.msac.decode_symbol_adapt(
      self.cdf.eob_base_tok,
      eob_cdf_base + ctx * 4,
      2,
    )
    let mut tok = eob_tok + 1
    let mut level_tok = tok * 0x41
    let mut mag = 0
    let mut x = 0
    let mut y = 0
    // eob position
    if tx_class == 0 {
      let r = av1_scan(tx, eob)
      rc = r
      x = r >> shift
      y = r & mask
    } else if tx_class == 1 {
      x = eob & mask
      y = eob >> shift
      rc = eob
    } else {
      x = eob & mask
      y = eob >> shift
      rc = (x << shift2) | y
    }
    if eob_tok == 2 {
      ctx = if (if tx_class == 0 { (x | y) > 1 } else { y != 0 }) {
        14
      } else {
        7
      }
      tok = self.msac.decode_hi_tok(self.cdf.br_tok, hi_cdf_base + ctx * 4)
      level_tok = tok + (3 << 6)
    }
    cf[rc] = tok << 11
    // dav1d's DECODE_COEFS_CLASS keeps levels in transposed layout
    // (x * stride + y) for every tx class; rc only coincides with it for
    // square transforms.
    let level_idx = x * stride + y
    levels[level_idx] = level_tok.to_byte()
    // ac coefficients
    let mut i = eob - 1
    while i > 0 {
      let rc_i = if tx_class == 0 {
        let r = av1_scan(tx, i)
        x = r >> shift
        y = r & mask
        r
      } else if tx_class == 1 {
        x = i & mask
        y = i >> shift
        i
      } else {
        x = i & mask
        y = i >> shift
        (x << shift2) | y
      }
      let lvl_idx = x * stride + y
      let (c2, mag2) = av1_get_lo_ctx(
        levels, lvl_idx, tx_class, lo_ctx_tbl, x, y, stride,
      )
      ctx = c2
      mag = mag2
      if tx_class == 0 {
        y = y | x
      }
      tok = self.msac.decode_symbol_adapt(
        self.cdf.base_tok,
        lo_cdf_base + ctx * 4,
        3,
      )
      if tok == 3 {
        mag = mag & 63
        ctx = (if y > (if tx_class == 0 { 1 } else { 0 }) { 14 } else { 7 }) +
          (if mag > 12 { 6 } else { (mag + 1) >> 1 })
        tok = self.msac.decode_hi_tok(self.cdf.br_tok, hi_cdf_base + ctx * 4)
        levels[lvl_idx] = (tok + (3 << 6)).to_byte()
        cf[rc_i] = (tok << 11) | rc
        rc = rc_i
      } else {
        // 0x1 for tok, 0x7ff as rc bitmask, 0x41 for level_tok
        let t = tok * 0x17ff41
        levels[lvl_idx] = t.to_byte()
        let t2 = (t >> 9) & (rc + av1_lnot(0x7ff))
        if t2 != 0 {
          rc = rc_i
        }
        cf[rc_i] = t2
      }
      i = i - 1
    }
    // dc
    if tx_class == 0 {
      ctx = 0
    } else {
      let (c0, m0) = av1_get_lo_ctx(levels, 0, tx_class, 0, 0, 0, stride)
      ctx = c0
      mag = m0
    }
    dc_tok = self.msac.decode_symbol_adapt(
      self.cdf.base_tok,
      lo_cdf_base + ctx * 4,
      3,
    )
    if dc_tok == 3 {
      if tx_class == 0 {
        mag = levels[0 * stride + 1].to_int() +
          levels[1 * stride + 0].to_int() +
          levels[1 * stride + 1].to_int()
      }
      mag = mag & 63
      ctx = if mag > 12 { 6 } else { (mag + 1) >> 1 }
      dc_tok = self.msac.decode_hi_tok(self.cdf.br_tok, hi_cdf_base + ctx * 4)
    }
  } else {
    // dc-only
    let tok_br = self.msac.decode_symbol_adapt(
      self.cdf.eob_base_tok,
      eob_cdf_base,
      2,
    )
    dc_tok = 1 + tok_br
    if tok_br == 2 {
      dc_tok = self.msac.decode_hi_tok(self.cdf.br_tok, hi_cdf_base)
    }
    rc = 0
  }
  // residual and sign (non-qmatrix path)
  let dq_base = b.seg_id * 6 + plane * 2
  let dq_tbl0 = self.dq_cur[dq_base + 0]
  let dq_tbl1 = self.dq_cur[dq_base + 1]
  let dq_shift = av1_imax(0, t_dim_ctx - 2)
  // ~(~127U << bpc): 8->32767, 10->131071, 12->524287
  let cf_max = (1 << (self.f.bpc + 7)) - 1
  let cul_level = Ref(0)
  let dc_sign_level = Ref(1 << 6)
  if dc_tok != 0 {
    let dc_sign_ctx = av1_get_dc_sign_ctx(tx, a, a_off, l, l_off)
    let dc_sign = self.msac.decode_bool_adapt(
      self.cdf.dc_sign,
      (chroma * 3 + dc_sign_ctx) * 2,
    )
    dc_sign_level.val = (dc_sign.reinterpret_as_int() - 1) & (2 << 6)
    let (dcv, dcul) = if dc_tok == 15 {
      let dkt_raw = self.msac.read_golomb() + 15
      let dkt = dkt_raw & 0xfffff
      let dq = ((dq_tbl0 * dkt) & 0xffffff) >> dq_shift
      (av1_imin(dq, cf_max + dc_sign.reinterpret_as_int()), dkt)
    } else {
      ((dq_tbl0 * dc_tok) >> dq_shift, dc_tok)
    }
    cul_level.val = dcul
    cf[0] = if dc_sign != 0 { -dcv } else { dcv }
  }
  if rc != 0 {
    let mut r = rc
    let ac_dq = dq_tbl1
    while r != 0 {
      let sign = self.msac.decode_bool_equi()
      let rc_tok = cf[r]
      let (tok, dq) = if rc_tok >= 15 << 11 {
        let t = (self.msac.read_golomb() + 15) & 0xfffff
        (t, ((ac_dq * t) & 0xffffff) >> dq_shift)
      } else {
        let t = rc_tok >> 11
        (t, (ac_dq * t) >> dq_shift)
      }
      cul_level.val = cul_level.val + tok
      let dq_sat = av1_imin(dq, cf_max + sign.reinterpret_as_int())
      cf[r] = if sign != 0 { -dq_sat } else { dq_sat }
      r = rc_tok & 0x3ff
    }
  }
  let res_ctx = av1_imin(cul_level.val, 63) | dc_sign_level.val
  (eob, txtp, res_ctx)
}

///|
fn av1_lnot(v : Int32) -> Int32 {
  -1 - v
}

///|
/// `read_pal_plane` from recon_tmpl.c.
fn Av1TileCtx::read_pal_plane(
  self : Av1TileCtx,
  pl : Int32,
  sz_ctx : Int32,
  bx4 : Int32,
  by4 : Int32,
) -> Int32 {
  let pal_sz = self.msac.decode_symbol_adapt(
      self.cdf.pal_sz,
      (pl * 7 + sz_ctx) * 8,
      6,
    ) +
    2
  let cache = FixedArray::make(16, 0)
  let used_cache = FixedArray::make(8, 0)
  let mut l_cache = if pl != 0 {
    self.pal_sz_uv[32 + by4]
  } else {
    self.f.l.pal_sz[by4]
  }
  let mut n_cache = 0
  let mut a_cache = if (by4 & 15) != 0 {
    if pl != 0 {
      self.pal_sz_uv[bx4]
    } else {
      self.f.a[self.a_idx].pal_sz[bx4]
    }
  } else {
    0
  }
  // al_pal: [2][32][3][8]
  let al = (d : Int32, i : Int32, p : Int32, k : Int32) => {
    self.al_pal[((d * 32 + i) * 3 + p) * 8 + k]
  }
  let mut li = 0
  let mut ai = 0
  // fill/sort cache (merge two sorted lists)
  while l_cache > 0 && a_cache > 0 {
    let lv = al(1, by4, pl, li)
    let av = al(0, bx4, pl, ai)
    if lv < av {
      if n_cache == 0 || cache[n_cache - 1] != lv {
        cache[n_cache] = lv
        n_cache = n_cache + 1
      }
      li = li + 1
      l_cache = l_cache - 1
    } else {
      if av == lv {
        li = li + 1
        l_cache = l_cache - 1
      }
      if n_cache == 0 || cache[n_cache - 1] != av {
        cache[n_cache] = av
        n_cache = n_cache + 1
      }
      ai = ai + 1
      a_cache = a_cache - 1
    }
  }
  while l_cache > 0 {
    let lv = al(1, by4, pl, li)
    if n_cache == 0 || cache[n_cache - 1] != lv {
      cache[n_cache] = lv
      n_cache = n_cache + 1
    }
    li = li + 1
    l_cache = l_cache - 1
  }
  while a_cache > 0 {
    let av = al(0, bx4, pl, ai)
    if n_cache == 0 || cache[n_cache - 1] != av {
      cache[n_cache] = av
      n_cache = n_cache + 1
    }
    ai = ai + 1
    a_cache = a_cache - 1
  }
  // find reused cache entries
  let mut n_used = 0
  let mut n = 0
  while n < n_cache && n_used < pal_sz {
    if self.msac.decode_bool_equi() != 0 {
      used_cache[n_used] = cache[n]
      n_used = n_used + 1
    }
    n = n + 1
  }
  // parse new entries into pal[pl]
  let pal_base = pl * 8
  let bpc = self.f.bpc
  let mut i = n_used
  if i < pal_sz {
    let mut prev = self.msac.decode_bools(bpc).reinterpret_as_int()
    self.pal[pal_base + i] = prev
    i = i + 1
    if i < pal_sz {
      let mut bits = bpc - 3 + self.msac.decode_bools(2).reinterpret_as_int()
      let max = (1 << bpc) - 1
      while i < pal_sz {
        let delta = self.msac.decode_bools(bits).reinterpret_as_int()
        prev = av1_imin(prev + delta + (if pl != 0 { 0 } else { 1 }), max)
        self.pal[pal_base + i] = prev
        i = i + 1
        if prev + (if pl != 0 { 0 } else { 1 }) >= max {
          while i < pal_sz {
            self.pal[pal_base + i] = max
            i = i + 1
          }
          break
        }
        bits = av1_imin(
          bits,
          1 +
          av1_ulog2(
            (max - prev - (if pl != 0 { 0 } else { 1 })).reinterpret_as_uint(),
          ),
        )
      }
    }
    // merge cache + new entries
    let mut nn = 0
    let mut m = n_used
    for k in 0..<pal_sz {
      if nn < n_used &&
        (m >= pal_sz || used_cache[nn] <= self.pal[pal_base + m]) {
        self.pal[pal_base + k] = used_cache[nn]
        nn = nn + 1
      } else {
        self.pal[pal_base + k] = self.pal[pal_base + m]
        m = m + 1
      }
    }
  } else {
    for k in 0..<n_used {
      self.pal[pal_base + k] = used_cache[k]
    }
  }
  pal_sz
}

///|
/// `read_pal_uv` V-plane palette continuation.
fn Av1TileCtx::read_pal_uv(self : Av1TileCtx, pal_sz : Int32) -> Unit {
  let pal_base = 2 * 8
  let bpc = self.f.bpc
  if self.msac.decode_bool_equi() != 0 {
    let bits = bpc - 4 + self.msac.decode_bools(2).reinterpret_as_int()
    let mut prev = self.msac.decode_bools(bpc).reinterpret_as_int()
    self.pal[pal_base + 0] = prev
    let max = (1 << bpc) - 1
    for i in 1..<pal_sz {
      let mut delta = self.msac.decode_bools(bits).reinterpret_as_int()
      if delta != 0 && self.msac.decode_bool_equi() != 0 {
        delta = -delta
      }
      prev = (prev + delta) & max
      self.pal[pal_base + i] = prev
    }
  } else {
    for i in 0..<pal_sz {
      self.pal[pal_base + i] = self.msac
        .decode_bools(bpc)
        .reinterpret_as_int()
    }
  }
}

///|
/// `dav1d_copy_pal_block_y`: splat the luma palette across the block.
fn Av1TileCtx::copy_pal_block_y(
  self : Av1TileCtx,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
) -> Unit {
  for x in 0..<bw4 {
    for k in 0..<8 {
      self.al_pal[((0 * 32 + bx4 + x) * 3 + 0) * 8 + k] = self.pal[k]
    }
  }
  for y in 0..<bh4 {
    for k in 0..<8 {
      self.al_pal[((1 * 32 + by4 + y) * 3 + 0) * 8 + k] = self.pal[k]
    }
  }
}

///|
/// `dav1d_copy_pal_block_uv` (luma coordinates per aomedia bug 2183).
fn Av1TileCtx::copy_pal_block_uv(
  self : Av1TileCtx,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
) -> Unit {
  for pl in 1..<=2 {
    for x in 0..<bw4 {
      for k in 0..<8 {
        self.al_pal[((0 * 32 + bx4 + x) * 3 + pl) * 8 + k] = self.pal[pl * 8 +
          k]
      }
    }
    for y in 0..<bh4 {
      for k in 0..<8 {
        self.al_pal[((1 * 32 + by4 + y) * 3 + pl) * 8 + k] = self.pal[pl * 8 +
          k]
      }
    }
  }
}
