///|
/// Pure-MoonBit H.264 CABAC encoder, slice 3 of the port: Main profile
/// (profile_idc 77), 4:2:0, single slice, P-slice reference history.
///
/// Porting discipline (same as the CAVLC slices): the arithmetic encoder
/// core mirrors the reference encoder already verified bit-exactly against
/// this repository's CABAC decoder (`h264_psynth_wbtest.mbt`, which itself
/// mirrors FFmpeg's `tests/cabac.c`), and every context derivation is NOT
/// re-implemented — the writer maintains a real `H264DecCtx` mirror whose
/// `H264MbInfo` entries are updated exactly like the decoder's parse would
/// update them (fresh per picture, `nz` cleared per macroblock, `cbp_all`
/// committed before the residual bins with the DC flags OR-ed in by the
/// residual writer), so the decoder's own helpers — `h264_cabac_cbf_ctx`,
/// `h264_cabac_left_cbp`, `h264_pred_motion`, `h264_pred_pskip_motion`,
/// `h264_mvd_fetch`, `h264_write_back_part` — price every bin with the same
/// context the decoder reads it back with.
///
/// Scope: I slices code I_NxN (mb_type 0) and I16x16 (mb_type 1..24 — the
/// `decode_cabac_intra_mb_type` I-slice continuation, whose terminate bin
/// rejecting Intra_PCM is written as a zero). The mode decision picks
/// I16x16 unless the I4x4 pass's SAD beats it by ~6%; the I16 cbp is
/// derived from mb_type's group, so no cbp bins exist there. I_PCM stays
/// a CAVLC-path feature. P slices code P_Skip plus the four inter
/// partitions with the same rate-distortion plan decision as the CAVLC
/// encoder (`decide_plan`). Multiple L0 references code `ref_idx` before
/// motion differences and preserve each partition's index in the mirror;
/// `mb_qp_delta` carries the opt-in adaptive-quantisation offset against
/// the mirror's running qscale (the decoder reads it when cbp != 0 or the
/// macroblock is I16x16; with AQ off it is always the zero bin).

///|
/// CABAC arithmetic encoder core: the verified mirror of the reference
/// `put_cabac` engine (low/range/outstanding-bit bookkeeping, the
/// terminating bin's `((low >> 7) & 3) | 1` flush, and the redundant
/// leading zero dropped when the bit list is packed into bytes).
priv struct H264CabacEnc {
  mut low : Int32
  mut range : Int32
  mut outstanding : Int32
  bits : Array[Int32]
}

///|
fn h264_cabac_enc_new() -> H264CabacEnc {
  { low: 0, range: 0x1FE, outstanding: 0, bits: [], }
}

///|
fn H264CabacEnc::put_bit(self : H264CabacEnc, b : Int32) -> Unit {
  self.bits.push(b)
  while self.outstanding > 0 {
    self.bits.push(1 - b)
    self.outstanding = self.outstanding - 1
  }
}

///|
fn H264CabacEnc::renorm(self : H264CabacEnc) -> Unit {
  while self.range < 0x100 {
    if self.low < 0x100 {
      self.put_bit(0)
    } else if self.low < 0x200 {
      self.outstanding = self.outstanding + 1
      self.low = self.low - 0x100
    } else {
      self.put_bit(1)
      self.low = self.low - 0x200
    }
    self.range = self.range + self.range
    self.low = self.low + self.low
  }
}

///|
/// One regular decision bin at context `ctx_idx` (`put_cabac`). */
fn H264CabacEnc::decision(
  self : H264CabacEnc,
  states : Array[Int32],
  ctx_idx : Int32,
  bit : Int32,
) -> Unit {
  let range_lps = h264_cabac_lps_range(self.range, states[ctx_idx])
  if bit == (states[ctx_idx] & 1) {
    self.range = self.range - range_lps
    states[ctx_idx] = h264_cabac_mlps_state(states[ctx_idx])
  } else {
    self.low = self.low + (self.range - range_lps)
    self.range = range_lps
    states[ctx_idx] = h264_cabac_tables[h264_cabac_mlps_state_offset +
      127 -
      states[ctx_idx]]
  }
  self.renorm()
}

///|
/// One bypass bin (`put_cabac_bypass`). */
fn H264CabacEnc::bypass(self : H264CabacEnc, bit : Int32) -> Unit {
  self.low = self.low + self.low
  if bit != 0 {
    self.low = self.low + self.range
  }
  if self.low < 0x200 {
    self.put_bit(0)
  } else if self.low < 0x400 {
    self.outstanding = self.outstanding + 1
    self.low = self.low - 0x200
  } else {
    self.put_bit(1)
    self.low = self.low - 0x400
  }
}

///|
/// The terminating bin (`put_cabac_terminate`): `bit` 1 also flushes the
/// engine — this is both the `end_of_slice_flag` of the last macroblock and
/// the rbsp stop bit of the slice. */
fn H264CabacEnc::terminate(self : H264CabacEnc, bit : Int32) -> Unit {
  self.range = self.range - 2
  if bit == 0 {
    self.renorm()
  } else {
    self.low = self.low + self.range
    self.range = 2
    self.renorm()
    self.put_bit(self.low >> 9)
    let v = ((self.low >> 7) & 3) | 1
    self.bits.push((v >> 1) & 1)
    self.bits.push(v & 1)
  }
}

///|
/// Pack the bit list into CABAC payload bytes: the leading redundant zero
/// of `low` is dropped (the decoder's initialisation supplies it), the rest
/// is packed MSB-first and zero-padded to the byte. The final bit is the
/// terminating flush's stop bit, so a parser strips exactly the trailing
/// zero padding.
fn H264CabacEnc::to_bytes(self : H264CabacEnc) -> Array[Byte] {
  let n = (self.bits.length() - 1 + 7) / 8
  let out : Array[Byte] = Array::make(n, b'\x00')
  for i = 1; i < self.bits.length(); i = i + 1 {
    let j = i - 1
    if self.bits[i] != 0 {
      out[j / 8] = (out[j / 8].to_int() | (1 << (7 - j % 8))).to_byte()
    }
  }
  out
}

///|
/// Fresh per-picture decoder-context mirror (`H264DecCtx` built exactly
/// like the decoder's picture allocation: fresh `H264MbInfo` entries, one
/// slice, frame MBs, 4:2:0 8-bit). `slice_type_nos` is 2 for I and 0 for P.
fn h264_cabac_mirror_new(
  mb_width : Int32,
  mb_height : Int32,
  pps : H264Pps,
  /// Slice QP in *extended* units (user QP + `6*(bit_depth-8)`), the form
  /// the shared deblock/chroma helpers index their tables by (`§412`).
  qp : Int32,
  slice_type_nos : Int32,
  ystride : Int32,
  cstride : Int32,
  pheight : Int32,
  bit_depth~ : Int32 = 8,
) -> H264DecCtx {
  let infos : Array[H264MbInfo] = []
  for _k = 0; _k < mb_width * mb_height; _k = _k + 1 {
    infos.push(h264_new_mb_info())
  }
  // `§420`: the mirror must adopt the PPS's chroma geometry, otherwise the
  // nz/cbp neighbours and the CABAC chroma syntax are derived for 4:2:0.
  let cf = pps.chroma_format
  let chroma_plane_h = if cf == 2 { pheight } else { pheight / 2 }
  let refpic : H264RefPic = {
    identity: 0,
    y: Array::make(ystride * pheight, 0),
    u: Array::make(cstride * chroma_plane_h, 0),
    v: Array::make(cstride * chroma_plane_h, 0),
    ystride,
    cstride,
    width: ystride,
    height: pheight,
    cwidth: cstride,
    cheight: chroma_plane_h,
    poc: 0,
    field_poc_top: 0,
    field_poc_bottom: 0,
    base_y: 0,
    base_u: 0,
    base_v: 0,
    parity: 0,
  }
  {
    bit_depth,
    chroma_format: cf,
    chroma_hshift: 1,
    chroma_vshift: if cf == 2 {
      0
    } else {
      1
    },
    si_slice: false,
    slice_num: 0,
    active_list: 0,
    ref_list1: [],
    ref_count1: 1,
    direct_spatial: true,
    direct_8x8: true,
    colocated: [],
    reference_buffers: Map([]),
    colocated_mbaff: false,
    colocated_field_picture: false,
    poc: 0,
    poc_top: 0,
    poc_bottom: 0,
    long_pocs: [],
    pps,
    mb_width,
    mb_height,
    field_picture: false,
    bottom_field: false,
    mb_aff: false,
    mb_field: false,
    prev_mb_skipped: false,
    next_mb_skipped: false,
    y: Array::make(ystride * pheight, 0),
    u: Array::make(cstride * chroma_plane_h, 0),
    v: Array::make(cstride * chroma_plane_h, 0),
    ystride,
    cstride,
    infos,
    failed_mb: -1,
    qscale: qp,
    last_qscale_diff: 0,
    slice_type_nos,
    cur_mb_is_intra: slice_type_nos == 2,
    ref_count0: 1,
    ref_list0: [refpic],
    mb_skip_run: -1,
    pwt: new_h264_pred_weight(),
  }
}

///|
/// `mb_skip_flag` context: `11 + (left coded non-skip) + (top coded
/// non-skip)` — the encoder-side twin of `h264_cabac_mb_skip`'s frame-MB
/// branch (the decoder's own function reads a `CabacContext`, so the
/// context derivation is mirrored here and only here).
fn h264_cabacw_skip_ctx(ctx : H264DecCtx, mb_idx : Int32) -> Int32 {
  let mut c = 0
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
  11 + c
}

///|
/// Encode one `mvd` component: the exact twin of `h264_cabac_mb_mvd`.
/// `base` is 40 (x) or 47 (y), `amvd` the summed absolute neighbour mvd,
/// `mvd` the signed difference to code. Returns the clamped absolute value
/// the decoder stores into the mvd cache.
fn h264_cabacw_mvd_one(
  enc : H264CabacEnc,
  states : Array[Int32],
  base : Int32,
  amvd : Int32,
  mvd : Int32,
) -> Int32 {
  let ctxi = if amvd > 32 { 2 } else if amvd > 2 { 1 } else { 0 }
  let mag = if mvd < 0 { -mvd } else { mvd }
  if mag == 0 {
    enc.decision(states, base + ctxi, 0)
    return 0
  }
  enc.decision(states, base + ctxi, 1)
  let mut ctxbase = base + 3
  let mut v = 1
  while v < 9 && v < mag {
    enc.decision(states, ctxbase, 1)
    if v < 4 {
      ctxbase = ctxbase + 1
    }
    v = v + 1
  }
  let mut abs_v = mag
  if mag < 9 {
    enc.decision(states, ctxbase, 0)
  } else {
    // Escape: the decoder's context loop leaves mvd == 9 without reading
    // another context bin; the escape is a unary prefix of bypass bins
    // (terminated by a zero bin unless the 23-cap hit) followed by k data
    // bits, MSB first: |mvd| = 9 + sum(2^i) + rest.
    let mut k = 3
    let mut rest = mag - 9
    while 1 << k <= rest {
      enc.bypass(1)
      rest = rest - (1 << k)
      k = k + 1
    }
    enc.bypass(0)
    while k > 0 {
      k = k - 1
      enc.bypass((rest >> k) & 1)
    }
    abs_v = if mag < 70 { mag } else { 70 }
  }
  // Sign bypass: a 1 bin selects the negative value
  // (`get_cabac_bypass_sign(cabac, -mvd)`).
  enc.bypass(if mvd < 0 { 1 } else { 0 })
  abs_v
}

///|
/// Encode one P sub-macroblock type (`decode_cabac_p_mb_sub_type` twin). */
fn h264_cabacw_sub_type(
  enc : H264CabacEnc,
  states : Array[Int32],
  sub : Int32,
) -> Unit {
  match sub {
    0 => enc.decision(states, 21, 1)
    1 => {
      enc.decision(states, 21, 0)
      enc.decision(states, 22, 0)
    }
    2 => {
      enc.decision(states, 21, 0)
      enc.decision(states, 22, 1)
      enc.decision(states, 23, 1)
    }
    _ => {
      enc.decision(states, 21, 0)
      enc.decision(states, 22, 1)
      enc.decision(states, 23, 0)
    }
  }
}

///|
/// `decode_cabac_mb_dqp` write side: the zero bin at ctx
/// 60 + (last_qscale_diff != 0), or the unary ladder - first continuation
/// bin at 62, the rest at 63 - for the signed code `2*|d|-1` when `d > 0`
/// and `2*|d|` when `d < 0`. Mirrors the decoder's `last_qscale_diff` and
/// the wrapped `qscale` update (a no-op in range).
fn h264_cabacw_dqp(
  enc : H264CabacEnc,
  states : Array[Int32],
  ctx : H264DecCtx,
  delta : Int32,
) -> Unit {
  let off = if ctx.last_qscale_diff != 0 { 1 } else { 0 }
  if delta == 0 {
    enc.decision(states, 60 + off, 0)
    ctx.last_qscale_diff = 0
    return
  }
  enc.decision(states, 60 + off, 1)
  let code = if delta > 0 { 2 * delta - 1 } else { -2 * delta }
  if code == 1 {
    enc.decision(states, 62, 0)
  } else {
    enc.decision(states, 62, 1)
    let mut i = 2
    while i < code {
      enc.decision(states, 63, 1)
      i = i + 1
    }
    enc.decision(states, 63, 0)
  }
  ctx.last_qscale_diff = delta
  let mut q = ctx.qscale + delta
  if q < 0 {
    q = q + h264_max_qp(ctx) + 1
  } else if q > h264_max_qp(ctx) {
    q = q - h264_max_qp(ctx) - 1
  }
  ctx.qscale = q
}

///|
/// Encode the coded-block-pattern bins: the exact twin of
/// `decode_cabac_mb_cbp_luma` + `decode_cabac_mb_cbp_chroma` (the packed
/// neighbour cbp comes from the decoder's own `h264_cabac_left_cbp` /
/// `h264_cabac_top_cbp`).
fn h264_cabacw_cbp(
  enc : H264CabacEnc,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  cbp : Int32,
  code_chroma : Bool,
) -> Unit {
  let cbp_a = h264_cabac_left_cbp(ctx, mb_idx, mb_x)
  let cbp_b = h264_cabac_top_cbp(ctx, mb_idx, mb_y)
  let mut c = 0
  if (cbp_a & 0x02) == 0 {
    c = c + 1
  }
  if (cbp_b & 0x04) == 0 {
    c = c + 2
  }
  enc.decision(states, 73 + c, cbp & 1)
  c = 0
  if (cbp & 0x01) == 0 {
    c = c + 1
  }
  if (cbp_b & 0x08) == 0 {
    c = c + 2
  }
  enc.decision(states, 73 + c, (cbp >> 1) & 1)
  c = 0
  if (cbp_a & 0x08) == 0 {
    c = c + 1
  }
  if (cbp & 0x01) == 0 {
    c = c + 2
  }
  enc.decision(states, 73 + c, (cbp >> 2) & 1)
  c = 0
  if (cbp & 0x04) == 0 {
    c = c + 1
  }
  if (cbp & 0x02) == 0 {
    c = c + 2
  }
  enc.decision(states, 73 + c, (cbp >> 3) & 1)
  if code_chroma {
    let ca = (cbp_a >> 4) & 0x03
    let cb = (cbp_b >> 4) & 0x03
    let chroma = (cbp >> 4) & 0x03
    let mut c2 = 0
    if ca > 0 {
      c2 = c2 + 1
    }
    if cb > 0 {
      c2 = c2 + 2
    }
    if chroma == 0 {
      enc.decision(states, 77 + c2, 0)
    } else {
      enc.decision(states, 77 + c2, 1)
      let mut c3 = 4
      if ca == 2 {
        c3 = c3 + 1
      }
      if cb == 2 {
        c3 = c3 + 2
      }
      enc.decision(states, 77 + c3, if chroma == 2 { 1 } else { 0 })
    }
  }
}

///|
/// Encode one residual block: the exact twin of `h264_cabac_residual` —
/// coded-block-flag bin (context from the decoder's own
/// `h264_cabac_cbf_ctx`), the significance map in scan order, then the
/// absolute levels in reverse scan order (level-1 context, greater-than-1
/// ladder, escape prefix, bypass sign). Updates the mirror's nz slots and
/// the packed `cbp_all` DC flags exactly like the decoder's parse.
fn h264_cabacw_residual(
  enc : H264CabacEnc,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  cat : Int32,
  n : Int32,
  view : Array[Int32],
  max_coeff : Int32,
  is_dc : Bool,
) -> Unit {
  let nz = ctx.infos[mb_idx].nz
  let mut count = 0
  for k = 0; k < max_coeff; k = k + 1 {
    if view[k] != 0 {
      count = count + 1
    }
  }
  let mut last_pos = -1
  for k = 0; k < max_coeff; k = k + 1 {
    if view[k] != 0 {
      last_pos = k
    }
  }
  // Coded-block flag. 8x8DCT luma (cat 5) in 4:2:0 is the one implied
  // case - the luma CBP bit already said "coded", so no bin exists
  // (`!is_8x8 || cat != 5 || CHROMA444` on the decode side) and the block
  // is guaranteed non-empty (a zero block under a set CBP bit would make
  // the decoder's significance parse fail with EINVAL).
  let is_8x8 = max_coeff == 64
  if !is_8x8 || cat != 5 || ctx.chroma_format == 3 {
    let cbf_ctx = h264_cabac_cbf_ctx(ctx, mb_idx, mb_x, mb_y, cat, n, nz)
    enc.decision(states, cbf_ctx, if count > 0 { 1 } else { 0 })
    if count == 0 {
      // `fill_rectangle(non_zero_count_cache[...], 0)`: the block's nz slot
      // is zeroed for the AC/grid categories, DC blocks leave it alone.
      if !is_dc {
        if is_8x8 {
          let i8 = (n & 15) / 4
          let x0 = i8 % 2 * 2
          let y0 = i8 / 2 * 2
          let base = 16 * h264_cabac_cat_plane(cat)
          for dy in 0..<2 {
            for dx in 0..<2 {
              nz[base + (y0 + dy) * 4 + x0 + dx] = 0
            }
          }
        } else if cat == 1 || cat == 2 || cat >= 6 {
          nz[16 * h264_cabac_cat_plane(cat) + h264_luma_block_grid[n & 15]] = 0
        } else {
          nz[n] = 0
        }
      }
      return
    }
  }
  let sig_base = h264_cabac_significant_coeff_offset[cat]
  let last_base = h264_cabac_last_coeff_flag_offset[cat]
  // `§420`: the 4:2:2 chroma DC significance/last flags use the special
  // three-context table (`h264_cabac_sig_coeff_offset_dc`) — the decoder's
  // `DECODE_SIGNIFICANCE(7, ...)` twin, positions 0..6 with the eighth
  // implied.
  let is_dc422 = is_dc && cat == 3 && max_coeff == 8
  // Significance map: sig/last bins for positions 0..max-2; the last scan
  // position is implied when no `last` flag fired. 8x8 luma contexts are a
  // compressed function of the scan position (`significant_coeff_flag_offset_8x8`
  // / `last_coeff_flag_offset_8x8`), not the position itself.
  let coefs = max_coeff - 1
  let mut q = 0
  while q < coefs {
    let off = if is_dc422 { h264_cabac_sig_coeff_offset_dc[q] } else { q }
    let sig_ctx = sig_base +
      (if is_dc422 { off } else if is_8x8 { h264_cabac_sig8[q] } else { q })
    let last_ctx = last_base +
      (if is_dc422 { off } else if is_8x8 { h264_cabac_last8[q] } else { q })
    if view[q] != 0 {
      enc.decision(states, sig_ctx, 1)
      if q == last_pos {
        enc.decision(states, last_ctx, 1)
        // `last = max_coeff` on the decode side: stop.
        q = coefs
        continue
      } else {
        enc.decision(states, last_ctx, 0)
      }
    } else {
      enc.decision(states, sig_ctx, 0)
    }
    q = q + 1
  }
  // Position max_coeff-1 implicit: reached only when last_pos == coefs.
  // (Nothing to emit — the decoder records it unconditionally.)
  // Record the non-zero counts like the decoder's parse.
  if is_dc {
    if cat == 3 {
      ctx.infos[mb_idx].cbp_all = ctx.infos[mb_idx].cbp_all | (0x40 << (n - 49))
    } else {
      ctx.infos[mb_idx].cbp_all = ctx.infos[mb_idx].cbp_all |
        (0x100 << (n - 48))
    }
  } else if is_8x8 {
    // `fill_rectangle(non_zero_count_cache[scan8[n]], 2, 2, 8, count)`:
    // the whole 2x2 quadrant of the plane's grid carries the block's count.
    let i8 = (n & 15) / 4
    let x0 = i8 % 2 * 2
    let y0 = i8 / 2 * 2
    let base = 16 * h264_cabac_cat_plane(cat)
    for dy in 0..<2 {
      for dx in 0..<2 {
        nz[base + (y0 + dy) * 4 + x0 + dx] = count
      }
    }
  } else if cat == 1 || cat == 2 || cat >= 6 {
    nz[16 * h264_cabac_cat_plane(cat) + h264_luma_block_grid[n & 15]] = count
  } else {
    nz[n] = count
  }
  // Absolute levels, reverse scan order.
  let abs_base = h264_cabac_coeff_abs_level_m1_offset[cat]
  // `§420`: the 4:2:2 chroma DC escape ladder reads the second table row
  // (`coeff_abs_levelgt1_ctx[1][8]`, the decoder's `is_dc422` branch).
  let gt1 = h264_cabac_coeff_abs_levelgt1_ctx[if is_dc422 { 1 } else { 0 }]
  let mut node_ctx = 0
  let mut cc = count
  while cc > 0 {
    cc = cc - 1
    // The cc-th significant position in scan order.
    let mut pos = -1
    let mut seen = 0
    for k = 0; k < max_coeff; k = k + 1 {
      if view[k] != 0 {
        if seen == cc {
          pos = k
          break
        }
        seen = seen + 1
      }
    }
    let level = if view[pos] < 0 { -view[pos] } else { view[pos] }
    let ctx1 = abs_base + h264_cabac_coeff_abs_level1_ctx[node_ctx]
    if level == 1 {
      enc.decision(states, ctx1, 0)
      node_ctx = h264_cabac_coeff_abs_level_transition[0][node_ctx]
    } else {
      enc.decision(states, ctx1, 1)
      // `ctx2` reads the OLD node_ctx, then the transition updates it.
      let ctx2 = abs_base + gt1[node_ctx]
      node_ctx = h264_cabac_coeff_abs_level_transition[1][node_ctx]
      let mut v = 2
      while v < 15 && v < level {
        enc.decision(states, ctx2, 1)
        v = v + 1
      }
      if level < 15 {
        enc.decision(states, ctx2, 0)
      } else {
        // Escape (level >= 15): the ladder saturated at 15. The decoder's
        // semantics (`decode_cabac_residual_internal`): jj one-bits, a zero,
        // then jj bypass data bits shifting a seed of 1 — the value is
        // 14 + (1 followed by jj bits) = 14 + [2^jj, 2^(jj+1)).
        let e = level - 14
        let mut jj = 0
        let mut t = e >> 1
        while t > 0 {
          jj = jj + 1
          t = t >> 1
        }
        for i = 0; i < jj; i = i + 1 {
          enc.bypass(1)
        }
        enc.bypass(0)
        let mut k = jj
        while k > 0 {
          k = k - 1
          enc.bypass((e >> k) & 1)
        }
      }
    }
    enc.bypass(if view[pos] < 0 { 1 } else { 0 })
  }
}

///|
/// Main-profile SPS RBSP (profile_idc 77, no constraint flags — CABAC
/// breaks Baseline compatibility). Everything else matches the CAVLC SPS.
fn h264_enc_sps_rbsp_main(p : H264EncParams, vbv~ : H264Vbv? = None) -> Bytes {
  let r = H264Rbsp::new()
  r.put(77, 8) // profile_idc: Main
  // constraint_set1 (Annex A.2.2, Main): the parser's
  // `more_rbsp_data_in_pps` skips the High-profile PPS tail for profiles
  // 66/77/88 only when one of the constraint set flags is set, and A.2.2
  // is the constraint set this stream actually satisfies (CABAC breaks
  // A.2.1 Baseline compatibility).
  r.put(0x40, 8)
  r.put(p.level_idc, 8)
  r.put_ue(0) // seq_parameter_set_id
  r.put_ue(0) // log2_max_frame_num_minus4
  r.put_ue(2) // pic_order_cnt_type = 2
  r.put_ue(p.nrefs) // max_num_ref_frames
  r.put_bit(0) // gaps_in_frame_num_value_allowed_flag
  r.put_ue(p.mb_width() - 1)
  r.put_ue(p.mb_height() - 1)
  r.put_bit(1) // frame_mbs_only_flag
  r.put_bit(1) // direct_8x8_inference_flag (required in Main)
  let crop = p.width % 16 != 0 || p.height % 16 != 0
  r.put_bit(if crop { 1 } else { 0 })
  if crop {
    r.put_ue(0)
    r.put_ue((p.mb_width() * 16 - p.width) / 2)
    r.put_ue(0)
    r.put_ue((p.mb_height() * 16 - p.height) / 2)
  }
  match vbv {
    None =>
      if p.sar.0 > 0 && p.sar.1 > 0 {
        r.put_bit(1) // vui_parameters_present_flag
        h264_enc_vui_aspect_ratio(r, p.sar)
        r.put_bit(0) // overscan_info_present_flag
        r.put_bit(0) // video_signal_type_present_flag
        r.put_bit(0) // chroma_loc_info_present_flag
        r.put_bit(0) // timing_info_present_flag
        r.put_bit(0) // nal_hrd_parameters_present_flag
        r.put_bit(0) // vcl_hrd_parameters_present_flag
        r.put_bit(0) // pic_struct_present_flag
        r.put_bit(0) // bitstream_restriction_flag
      } else {
        r.put_bit(0) // vui_parameters_present_flag
      }
    Some(v) => h264_enc_sps_vui(r, v, sar=p.sar)
  }
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// High-profile SPS RBSP for `transform_8x8` (profile_idc 100): the shared
/// `h264_enc_sps_body_high` body.
fn h264_enc_sps_rbsp_high(
  p : H264EncParams,
  vbv~ : H264Vbv? = None,
  chroma_format~ : Int32 = 1,
) -> Bytes {
  let r = H264Rbsp::new()
  h264_enc_sps_body_high(r, p, vbv~, chroma_format~)
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// CABAC PPS RBSP: identical to the CAVLC PPS except
/// `entropy_coding_mode_flag = 1`. With `dct8x8` the High-profile tail is
/// appended: `transform_8x8_mode_flag`, no PPS scaling matrix and a zero
/// `second_chroma_qp_index_offset` (the reader only enters the tail when
/// more_rbsp_data remains, so the Main-profile stream above must stay
/// byte-identical when the flag is off).
fn h264_enc_pps_rbsp_cabac(
  p : H264EncParams,
  dct8x8~ : Bool = false,
  weightp~ : Bool = false,
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset (see `h264_enc_pps_rbsp`).
  chroma_qp_offset~ : Int32 = 0,
) -> Bytes {
  let r = H264Rbsp::new()
  r.put_ue(0) // pic_parameter_set_id
  r.put_ue(0) // seq_parameter_set_id
  r.put_bit(1) // entropy_coding_mode_flag: CABAC
  r.put_bit(0) // bottom_field_pic_order_in_frame_present_flag
  r.put_ue(0) // num_slice_groups_minus1
  r.put_ue(p.nrefs - 1) // num_ref_idx_l0_default_active_minus1
  r.put_ue(0) // num_ref_idx_l1_default_active_minus1
  r.put_bit(if weightp { 1 } else { 0 }) // weighted_pred_flag
  // `§434`: explicit B weights need both lists in every B slice header.
  r.put(if p.weightp_b { 1 } else { 0 }, 2) // weighted_bipred_idc
  // `§412`: user-space QP difference, see `h264_enc_pps_body`.
  r.put_se(p.qp - 26) // pic_init_qp_minus26
  r.put_se(0) // pic_init_qs_minus26
  r.put_se(chroma_qp_offset) // chroma_qp_index_offset
  // `§433`: nonzero alpha/beta offsets opt into the slice-level deblocking
  // syntax (see `h264_enc_pps_body`).
  r.put_bit(if p.deblock_alpha != 0 || p.deblock_beta != 0 { 1 } else { 0 }) // deblocking_filter_control_present_flag
  r.put_bit(0) // constrained_intra_pred_flag
  r.put_bit(0) // redundant_pic_cnt_present_flag
  // High family (100 High / 110 High 10) always carries the PPS tail.
  if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
    r.put_bit(if dct8x8 { 1 } else { 0 }) // transform_8x8_mode_flag
    r.put_bit(0) // pic_scaling_matrix_present_flag
    r.put_se(chroma_qp_offset) // second_chroma_qp_index_offset
  }
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// Wrap a finished slice RBSP (already byte-aligned header + CABAC payload
/// bytes) in a NAL unit with emulation prevention.
fn h264_cabac_nal(
  header : Bytes,
  cabac : Array[Byte],
  ref_idc : Int32,
  unit_type : Int32,
) -> Bytes {
  let raw : Array[Byte] = []
  for i = 0; i < header.length(); i = i + 1 {
    raw.push(header[i])
  }
  for b in cabac {
    raw.push(b)
  }
  let payload = h264_enc_escape(Bytes::from_array(raw[:]))
  let out : Array[Byte] = [
    b'\x00',
    b'\x00',
    b'\x00',
    b'\x01',
    ((ref_idc << 5) | unit_type).to_byte(),
  ]
  for i = 0; i < payload.length(); i = i + 1 {
    out.push(payload[i])
  }
  Bytes::from_array(out[:])
}

///|
/// Per-picture state of the intra CABAC encoder. The decision and
/// reconstruction orchestration mirrors the CAVLC intra encoder (its I16x16
/// branch is dead there and absent here); the syntax layer is CABAC.
priv struct H264CabacIEnc {
  p : H264EncParams
  pps : H264Pps
  mut chroma_qp : Int32
  src_y : Array[Int32]
  src_u : Array[Int32]
  src_v : Array[Int32]
  rec_y : Array[Int32]
  rec_u : Array[Int32]
  rec_v : Array[Int32]
  ystride : Int32
  cstride : Int32
  mb_width : Int32
  ctx : H264DecCtx
  enc : H264CabacEnc
  states : Array[Int32]
  /// Raw (signalled) intra4x4 modes of the macroblock being coded.
  cur_modes : Array[Int32]
  /// Opt-in High-profile transform_8x8 (I_NxN may become I8x8).
  dct8x8 : Bool
  /// Shared decision counters (I8x8 usage).
  stats : H264EncStats
  /// This macroblock's QP / `mb_qp_delta` (adaptive quantisation; both
  /// stay at the picture QP with AQ off).
  mut mb_qp : Int32
  mut mb_dqp : Int32
  /// Per-MB luma activity and the picture average (`aq_on` false: unused).
  mut aq_act : Array[Int32]
  mut aq_avg : Int32
  aq_on : Bool
  aq_strength : Int32
  /// `§429`: per-MB ROI QP offsets (empty = no ROI; only applied with AQ on).
  roi_off : Array[Int32]
  /// `§423`: filter the reconstruction (and the reference planes) exactly as
  /// a conforming decoder will, before returning it.
  deblock : Bool
}

///|
/// Encode one IDR I-frame with CABAC entropy coding (Main profile by
/// default; `dct8x8` switches the SPS to High and the PPS to
/// `transform_8x8_mode_flag = 1`). Same contract as `h264_encode_intra_frame`;
/// the PPS carries `entropy_coding_mode_flag = 1`.
pub fn h264_encode_intra_frame_cabac(
  y : Bytes,
  u : Bytes,
  v : Bytes,
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  dct8x8~ : Bool = false,
  stats~ : H264EncStats = H264EncStats::new(),
  pps_qp~ : Int32 = -1,
  aq~ : Bool = false,
  aq_strength~ : Int32 = 1,
  /// `§429`: per-macroblock ROI quantisation offsets (see
  /// `h264_encode_intra_frame`); ignored when `aq=false`.
  roi~ : Array[H264Roi] = [],
  vbv~ : H264Vbv? = None,
  /// HRD ticks since the preceding buffering period (zero at stream start).
  idr_cpb_delay~ : Int32 = 0,
  b_seq~ : Bool = false,
  /// `§410`: explicit P weighted prediction (the PPS carries
  /// `weighted_pred_flag = 1`; the P slice headers carry the table).
  weightp~ : Bool = false,
  /// `§434`: opt-in explicit B weighted prediction (PPS weighted_bipred_idc).
  weightp_b~ : Bool = false,
  /// `§412`/`§419`: 8 (default), 9, 10, 12 or 14 bits (`yuv420p10le` input above 8).
  bit_depth~ : Int32 = 8,
  /// `§415`: the sequence's P-slice reference count (parameter sets).
  multi_ref~ : Int32 = 1,
  /// `§420`: chroma format (see the CAVLC intra entry).
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset -12..12 (x264 `chroma-qp-offset`, see
  /// `h264_encode_intra_frame`).
  chroma_qp_offset~ : Int32 = 0,
  /// `§423`: in-loop deblocking, default on (see `h264_encode_intra_frame`).
  deblock~ : Bool = true,
  /// `§433`: slice deblocking alpha/beta offsets in div2 units (-6..=6,
  /// x264 `--deblock alpha:beta`); either nonzero opts the PPS into
  /// deblocking control. Requires `deblock=true`.
  deblock_alpha~ : Int32 = 0,
  deblock_beta~ : Int32 = 0,
  /// `§426`: sample aspect ratio for the SPS VUI (0/0 = unset).
  sar~ : (Int32, Int32) = (0, 0),
  /// `§427`: A53 caption triples / one unregistered SEI payload (see
  /// `h264_encode_intra_frame`).
  a53~ : Bytes? = None,
  sei_unregistered~ : Bytes? = None,
  /// `§428`: stereo frame packing layout (see `h264_encode_intra_frame`).
  stereo3d~ : Int32 = 0,
  /// `§431`: `false` codes a non-IDR open-GOP keyframe instead of the
  /// sequence's IDR (see `h264_encode_intra_frame`).
  idr~ : Bool = true,
  /// `§431`: `frame_num` of a non-IDR I picture (ignored when `idr`).
  frame_num~ : Int32 = 0,
  /// `§431`: `pic_order_cnt_lsb` of a non-IDR I picture (`b_seq` only).
  poc_lsb~ : Int32 = 0,
) -> Result[H264EncodedFrame, String] {
  if aq_strength < 0 || aq_strength > 6 {
    return Err("h264 enc: aq_strength must be in 0..=6")
  }
  if chroma_format < 1 || chroma_format > 3 {
    return Err("h264 enc: chroma_format must be 1, 2 or 3")
  }
  if chroma_qp_offset < -12 || chroma_qp_offset > 12 {
    return Err("h264 enc: chroma_qp_offset must be in -12..=12")
  }
  match h264_enc_deblock_offsets_ok(deblock, deblock_alpha, deblock_beta) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0 {
    return Err("h264 enc: invalid geometry \{width}x\{height}")
  }
  if qp < 0 || qp > 51 {
    return Err("h264 enc: qp out of range")
  }
  if !h264_enc_bit_depth_ok(bit_depth) {
    return Err(
      "h264 enc: unsupported bit depth \{bit_depth} (8, 9, 10, 12 or 14)",
    )
  }
  let chroma_w = if chroma_format == 3 { width } else { width / 2 }
  let chroma_h = if chroma_format == 1 { height / 2 } else { height }
  if y.length() != h264_enc_plane_bytes(width, height, bit_depth) ||
    u.length() != h264_enc_plane_bytes(chroma_w, chroma_h, bit_depth) ||
    v.length() != h264_enc_plane_bytes(chroma_w, chroma_h, bit_depth) {
    return Err("h264 enc: plane size mismatch")
  }
  let p = {
    width,
    height,
    qp,
    level_idc,
    bit_depth,
    nrefs: multi_ref,
    sar,
    deblock_alpha,
    deblock_beta,
    weightp_b,
  }
  // Parameter sets carry the SEQUENCE base QP (`pic_init_qp`); this
  // picture's own QP travels in `slice_qp_delta` (rate control).
  let p_ps = {
    width,
    height,
    qp: if pps_qp < 0 {
      qp
    } else {
      pps_qp
    },
    level_idc,
    bit_depth,
    nrefs: multi_ref,
    sar,
    deblock_alpha,
    deblock_beta,
    weightp_b,
  }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = if chroma_format == 3 { mb_width * 16 } else { mb_width * 8 }
  let pheight = mb_height * 16
  let chroma_plane_h = if chroma_format == 1 { pheight / 2 } else { pheight }
  let ps = new_h264_param_sets()
  let sps_rbsp = if b_seq {
    h264_enc_sps_rbsp_b(p, dct8x8~, vbv~, chroma_format~)
  } else if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
    h264_enc_sps_rbsp_high(p, vbv~, chroma_format~)
  } else {
    h264_enc_sps_rbsp_main(p, vbv~)
  }
  let sps_nal = {
    let raw = sps_rbsp
    let out : Array[Byte] = [
      b'\x00',
      b'\x00',
      b'\x00',
      b'\x01',
      ((3 << 5) | 7).to_byte(),
    ]
    let escaped = h264_enc_escape(raw)
    for i = 0; i < escaped.length(); i = i + 1 {
      out.push(escaped[i])
    }
    Bytes::from_array(out[:])
  }
  let pps_nal = {
    let raw = h264_enc_pps_rbsp_cabac(
      p_ps,
      dct8x8~,
      weightp~,
      chroma_format~,
      chroma_qp_offset~,
    )
    let out : Array[Byte] = [
      b'\x00',
      b'\x00',
      b'\x00',
      b'\x01',
      ((3 << 5) | 8).to_byte(),
    ]
    let escaped = h264_enc_escape(raw)
    for i = 0; i < escaped.length(); i = i + 1 {
      out.push(escaped[i])
    }
    Bytes::from_array(out[:])
  }
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_rbsp), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = h264_enc_pps_rbsp_cabac(
    p_ps,
    dct8x8~,
    weightp~,
    chroma_format~,
    chroma_qp_offset~,
  )
  match
    ff_h264_decode_picture_parameter_set(
      BitReader::new(pps_raw),
      ps,
      pps_raw.length() * 8,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: PPS round-trip failed: \{e}")
  }
  let pps = match ps.pps_list[0] {
    Some(v) => v
    None => return Err("h264 enc: no PPS after round-trip")
  }
  let chroma_qp = h264_get_chroma_qp(pps, 0, p.qp_ext(qp), bit_depth~)
  // `§429`: ROI offsets ride the same `mb_qp_delta` mechanism as AQ.
  let roi_off = match
    h264_roi_offsets_for(roi, aq, mb_width, mb_height, bit_depth) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let self_ : H264CabacIEnc = {
    p,
    pps,
    chroma_qp,
    src_y: h264_enc_load_plane(y, width, height, ystride, pheight, bit_depth~),
    src_u: h264_enc_load_plane(
      u,
      chroma_w,
      chroma_h,
      cstride,
      chroma_plane_h,
      bit_depth~,
    ),
    src_v: h264_enc_load_plane(
      v,
      chroma_w,
      chroma_h,
      cstride,
      chroma_plane_h,
      bit_depth~,
    ),
    rec_y: Array::make(ystride * pheight, 0),
    rec_u: Array::make(cstride * chroma_plane_h, 0),
    rec_v: Array::make(cstride * chroma_plane_h, 0),
    ystride,
    cstride,
    mb_width,
    ctx: h264_cabac_mirror_new(
      mb_width,
      mb_height,
      pps,
      p.qp_ext(qp),
      2,
      ystride,
      cstride,
      pheight,
      bit_depth~,
    ),
    enc: h264_cabac_enc_new(),
    states: ff_h264_init_cabac_states(p.qp_ext(qp), bit_depth, 2, 0),
    cur_modes: Array::make(16, 0),
    dct8x8,
    stats,
    mb_qp: qp,
    mb_dqp: 0,
    aq_act: [],
    aq_avg: 0,
    aq_on: aq,
    aq_strength,
    roi_off,
    deblock,
  }
  if aq {
    let (act, avg) = h264_aq_measure(self_.src_y, ystride, mb_width, mb_height)
    self_.aq_act = act
    self_.aq_avg = avg
  }
  // Slice header.
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(7) // slice_type: I (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num (log2_max_frame_num = 4)
  if idr {
    r.put_ue(0) // idr_pic_id
  }
  if b_seq {
    // `§431`: a non-IDR I picture keeps the sequence's POC (open GOP).
    r.put(if idr { 0 } else { poc_lsb & 15 }, 4) // pic_order_cnt_lsb
  }
  if idr {
    r.put_bit(0) // no_output_of_prior_pics_flag
    r.put_bit(0) // long_term_reference_flag
  } else {
    r.put_bit(0) // adaptive_ref_pic_marking_mode_flag
  }
  // POC type 2 (b_seq off) has no picture order syntax at all.
  r.put_se(qp - p_ps.qp) // slice_qp_delta
  // `§433`: slice-level deblocking syntax when the PPS opted in.
  if pps.deblocking_filter_parameters_present != 0 {
    r.put_ue(0) // disable_deblocking_filter_idc
    r.put_se(p.deblock_alpha) // slice_alpha_c0_offset_div2
    r.put_se(p.deblock_beta) // slice_beta_offset_div2
  }
  while r.bw.nbits != 0 {
    r.put_bit(1) // cabac_alignment_one_bit
  }
  let header = r.finish_raw_of()
  for mb_y = 0; mb_y < mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < mb_width; mb_x = mb_x + 1 {
      match self_.encode_macroblock(mb_x, mb_y) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      let last = mb_y == mb_height - 1 && mb_x == mb_width - 1
      self_.enc.terminate(if last { 1 } else { 0 })
    }
  }
  let slice_nal = h264_cabac_nal(
    header,
    self_.enc.to_bytes(),
    3,
    if idr {
      5
    } else {
      1
    },
  )
  // `§423`: the CABAC encoder already maintains the decoder-mirror MB info
  // (qp/nz/mb_type/transform_8x8), so filtering reuses it directly.
  if self_.deblock {
    h264_enc_deblock_picture(
      self_.rec_y,
      self_.rec_u,
      self_.rec_v,
      self_.ystride,
      self_.cstride,
      mb_width,
      mb_height,
      self_.ctx.infos,
      self_.pps,
      bit_depth,
      alpha=p.deblock_alpha,
      beta=p.deblock_beta,
    )
  }
  let au : Array[Bytes] = []
  if idr {
    au.push(sps_nal)
    au.push(pps_nal)
    match vbv {
      None => ()
      Some(v) => {
        au.push(h264_enc_sei_buffering_period(v))
        au.push(
          h264_enc_sei_pic_timing(
            v,
            idr_cpb_delay,
            dpb_output_delay=if b_seq { 2 } else { 0 },
          ),
        )
      }
    }
  }
  match h264_enc_sei_side_data_nals(a53, sei_unregistered) {
    Ok(nals) =>
      for nal in nals {
        au.push(nal)
      }
    Err(e) => return Err(e)
  }
  if idr && stereo3d != 0 {
    match h264_enc_sei_frame_packing(stereo3d) {
      Ok(nal) => au.push(nal)
      Err(e) => return Err(e)
    }
  }
  au.push(slice_nal)
  Ok({
    annexb: h264_enc_concat(au),
    recon_y: self_.rec_y,
    recon_u: self_.rec_u,
    recon_v: self_.rec_v,
    ystride: self_.ystride,
    cstride: self_.cstride,
    width,
    height,
    qp,
    mb_modes: {
      let out : Array[Array[Int32]] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        let info = self_.ctx.infos[k]
        let arr : Array[Int32] = Array::make(16, 0)
        for i = 0; i < 16; i = i + 1 {
          arr[i] = info.modes[i]
        }
        out.push(arr)
      }
      out
    },
    mb_intra4x4: {
      let out : Array[Bool] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        out.push(self_.ctx.infos[k].intra4x4)
      }
      out
    },
    mb_tf8: {
      let out : Array[Bool] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        out.push(self_.ctx.infos[k].transform_8x8)
      }
      out
    },
    mb_nz: {
      let out : Array[Array[Int32]] = []
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        let info = self_.ctx.infos[k]
        let nz : Array[Int32] = Array::make(48, 0)
        for i = 0; i < 48; i = i + 1 {
          nz[i] = info.nz[i]
        }
        out.push(nz)
      }
      out
    },
  })
}

///|
/// The CABAC I8x8 luma pass: the shared transform/mode/reconstruction pass
/// with the availability derived from the decoder-context mirror
/// (`h264_recon_full_plane`'s I8x8-branch helpers).
fn H264CabacIEnc::encode_luma_i8(
  self : H264CabacIEnc,
  mb_x : Int32,
  mb_y : Int32,
  store : Array[Int32],
  modes : Array[Int32],
  mb : Array[Int32],
) -> Result[(Int32, Int32), String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  h264_enc_luma_i8_pass(
    self.src_y,
    self.rec_y,
    self.ystride,
    mb_x,
    mb_y,
    self.pps,
    // The quantiser must be this macroblock's (possibly AQ-adjusted) QP:
    // the decoder dequantises the I8x8 blocks at the running slice QP, so
    // pricing/reconstructing at the base QP desynchronises the
    // reconstruction on every AQ-adjusted macroblock. The pass wants the
    // *extended* QP (`§412`), like every other quantiser entry point.
    self.p.qp_ext(self.mb_qp),
    store,
    modes,
    mb,
    fn(bx8, by8) {
      let top = by8 > 0 || mb_y > 0
      let left = bx8 > 0 || mb_x > 0
      let topright = if by8 == 0 {
        top &&
        (
          bx8 == 0 ||
          (
            mb_x < self.mb_width - 1 &&
            h264_intra_available(
              self.ctx,
              h264_topright_index(self.ctx, mb_idx),
            )
          )
        )
      } else {
        bx8 == 0
      }
      (top, left, topright, h264_intra_topleft(self.ctx, mb_idx, bx8, by8))
    },
    bit_depth=self.p.bit_depth,
  )
}

///|
/// SAD between source and reconstruction over an 8x8 chroma block. */
fn H264CabacIEnc::chroma_sad(
  self : H264CabacIEnc,
  src : Array[Int32],
  rec : Array[Int32],
  cbase : Int32,
) -> Int32 {
  let mut sad = 0
  let rows = if self.pps.chroma_format == 2 { 16 } else { 8 }
  for row = 0; row < rows; row = row + 1 {
    for col = 0; col < 8; col = col + 1 {
      let d = src[cbase + row * self.cstride + col] -
        rec[cbase + row * self.cstride + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// Choose the chroma mode: evaluate every candidate on both planes, then
/// re-run the winner (the CAVLC intra encoder's `pick_chroma` mirror).
fn H264CabacIEnc::pick_chroma(
  self : H264CabacIEnc,
  cbase : Int32,
  top : Bool,
  left : Bool,
) -> Int32 {
  let mut best_sig = 0
  let mut best_eff = 0
  let mut best_cost = -1
  for sig = 0; sig < 4; sig = sig + 1 {
    let eff = match h264_check_intra_pred_mode(sig, top, left) {
      Ok(v) => v
      Err(_) => -1
    }
    if eff < 0 {
      continue
    }
    let pred = self.chroma_pred_fn(cbase, top, left)
    let ok_u = pred(self.rec_u, eff)
    let ok_v = pred(self.rec_v, eff)
    if ok_u is Ok(_) && ok_v is Ok(_) {
      let cost = self.chroma_sad(self.src_u, self.rec_u, cbase) +
        self.chroma_sad(self.src_v, self.rec_v, cbase)
      if best_cost < 0 || cost < best_cost {
        best_cost = cost
        best_sig = sig
        best_eff = eff
      }
    }
  }
  let pred = self.chroma_pred_fn(cbase, top, left)
  ignore(pred(self.rec_u, best_eff))
  ignore(pred(self.rec_v, best_eff))
  best_sig
}

///|
/// The intra chroma prediction runner for this PPS's chroma format
/// (`h264_pred8x8` at 4:2:0, `h264_pred8x16` at 4:2:2), bound to one
/// macroblock's base/availability.
fn H264CabacIEnc::chroma_pred_fn(
  self : H264CabacIEnc,
  cbase : Int32,
  top : Bool,
  left : Bool,
) -> (Array[Int32], Int32) -> Result[Unit, String] {
  if self.pps.chroma_format == 2 {
    fn(plane : Array[Int32], mode : Int32) -> Result[Unit, String] {
      h264_pred8x16(
        plane,
        cbase,
        self.cstride,
        mode,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    }
  } else {
    fn(plane : Array[Int32], mode : Int32) -> Result[Unit, String] {
      h264_pred8x8(
        plane,
        cbase,
        self.cstride,
        mode,
        top,
        left,
        bit_depth=self.p.bit_depth,
      )
    }
  }
}

///|
/// `§421`: one 4:4:4 intra macroblock in CABAC. `ChromaArrayType == 3`
/// reuses the luma prediction modes and the luma residual categories
/// (cat 6/7/8 and 10/11/12) for the two chroma planes: no chroma prediction
/// mode bins, no chroma cbp bins, and one 4-bit cbp that gates the same 8x8
/// quadrant in every plane.
fn H264CabacIEnc::encode_macroblock_444(
  self : H264CabacIEnc,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  let info = self.ctx.infos[mb_idx]
  for i = 0; i < 48; i = i + 1 {
    info.nz[i] = 0
  }
  info.transform_8x8 = false
  self.ctx.cur_mb_is_intra = true
  self.mb_qp = self.p.qp
  self.mb_dqp = 0
  if self.aq_on {
    let adj = h264_aq_adj(self.aq_act[mb_idx], self.aq_avg, self.aq_strength)
    let mut mq = self.p.qp + adj + h264_roi_off_at(self.roi_off, mb_idx)
    if mq < 0 {
      mq = 0
    }
    if mq > 51 {
      mq = 51
    }
    self.mb_qp = mq
    self.mb_dqp = self.p.qp_ext(mq) - self.ctx.qscale
  }
  let qp = self.p.qp_ext(self.mb_qp)
  let cq0 = h264_get_chroma_qp(self.pps, 0, qp, bit_depth=self.p.bit_depth)
  let cq1 = h264_get_chroma_qp(self.pps, 1, qp, bit_depth=self.p.bit_depth)
  let plane_qp : Array[Int32] = [qp, cq0, cq1]
  let mb : Array[Int32] = Array::make(768, 0)
  let levels_all : Array[Int32] = Array::make(768, 0)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let top_avail = mb_y > 0
  let left_avail = mb_x > 0
  // ---- prediction-mode decision: luma SAD, shared by the three planes ----
  let mut cbp = 0
  if self.dct8x8 {
    cbp = match
      h264_enc_i8444_pass(
        [self.src_y, self.src_u, self.src_v],
        [self.rec_y, self.rec_u, self.rec_v],
        self.ystride,
        mb_x,
        mb_y,
        self.mb_width,
        self.pps,
        plane_qp,
        levels_all,
        self.cur_modes,
        self.p.bit_depth,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    self.stats.i8_mbs += 1
  } else {
    let effs : Array[Int32] = Array::make(16, 0)
    let topright_of : Array[Bool] = Array::make(16, false)
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      let blk_top = gy > 0 || top_avail
      let blk_left = gx > 0 || left_avail
      let topright = if gy == 0 {
        top_avail && (gx < 3 || mb_x < self.mb_width - 1)
      } else {
        gx == 0 || gx == 2 || (gx == 1 && gy % 2 == 0)
      }
      topright_of[g] = topright
      let mut best_sig = 0
      let mut best_eff : Int32 = -1
      let mut best_sad = -1
      for sig = 0; sig < 9; sig = sig + 1 {
        let eff = match h264_check_intra4x4_mode(sig, blk_top, blk_left) {
          Ok(v) => v
          Err(_) => -1
        }
        if eff < 0 {
          continue
        }
        let err = h264_pred4x4(
            self.rec_y,
            off,
            self.ystride,
            eff,
            blk_top,
            blk_left,
            topright,
            bit_depth=self.p.bit_depth,
          )
          is Err(_)
        if err {
          continue
        }
        let sad = h264_enc_sad4(self.src_y, self.rec_y, off, self.ystride)
        if best_sad < 0 || sad < best_sad {
          best_sad = sad
          best_sig = sig
          best_eff = eff
        }
      }
      if best_eff < 0 {
        return Err("h264 enc: no feasible intra4x4 mode")
      }
      self.cur_modes[g] = best_sig
      effs[g] = best_eff
    }
    // ---- per-block, per-plane: predict, transform, quantise, reconstruct ----
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let eff = effs[g]
      let topright = topright_of[g]
      let blk_top = gy > 0 || top_avail
      let blk_left = gx > 0 || left_avail
      let mut any = false
      for p = 0; p < 3; p = p + 1 {
        let src = if p == 0 {
          self.src_y
        } else if p == 1 {
          self.src_u
        } else {
          self.src_v
        }
        let rec = if p == 0 {
          self.rec_y
        } else if p == 1 {
          self.rec_u
        } else {
          self.rec_v
        }
        let stride = if p == 0 { self.ystride } else { self.cstride }
        let off = mb_y * 16 * stride + mb_x * 16 + gy * 4 * stride + gx * 4
        match
          h264_pred4x4(
            rec,
            off,
            stride,
            eff,
            blk_top,
            blk_left,
            topright,
            bit_depth=self.p.bit_depth,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        let res : Array[Int32] = Array::make(16, 0)
        for row = 0; row < 4; row = row + 1 {
          for col = 0; col < 4; col = col + 1 {
            res[row * 4 + col] = src[off + row * stride + col] -
              rec[off + row * stride + col]
          }
        }
        let levels = h264_enc_fdct_quant_res(res, 0, plane_qp[p])
        let qmul = h264_build_dequant4(self.pps, p, plane_qp[p])
        let mut total = 0
        for s = 0; s < 16; s = s + 1 {
          levels_all[256 * p + 16 * i + s] = levels[s]
          if levels[s] != 0 {
            total = total + 1
            mb[256 * p + 16 * i + s] = h264_enc_dequant_level(
              levels[s],
              qmul[s],
              bit_depth=self.p.bit_depth,
            )
          }
        }
        info.nz[16 * p + g] = total
        if total != 0 {
          any = true
          h264_idct_add(
            rec,
            off,
            stride,
            mb,
            256 * p + 16 * i,
            bit_depth=self.p.bit_depth,
          )
        }
      }
      if any {
        cbp = cbp | (1 << (i / 4))
      }
    }
  }
  // ---- syntax ----
  // I16/Intra_PCM neighbour count feeds the first mb_type bin.
  let mut c = 0
  if h264_has_left(self.ctx, mb_idx) &&
    (
      self.ctx.infos[mb_idx - 1].mb_type_bits &
      (h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)
    ) !=
    0 {
    c = c + 1
  }
  if h264_has_top(self.ctx, mb_idx) &&
    (
      self.ctx.infos[h264_top_index(self.ctx, mb_idx)].mb_type_bits &
      (h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)
    ) !=
    0 {
    c = c + 1
  }
  self.enc.decision(self.states, 3 + c, 0) // I_NxN
  if self.dct8x8 {
    self.enc.decision(
      self.states,
      399 + h264_neighbor_transform_size(self.ctx, mb_idx, mb_x, mb_y),
      1,
    )
  }
  for i = 0; i < 16; i = i + 1 {
    if self.dct8x8 && i % 4 != 0 {
      continue
    }
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let predicted = h264_pred_intra_mode(
      self.ctx,
      mb_idx,
      mb_x,
      mb_y,
      gx,
      gy,
      self.cur_modes,
    )
    let mode = self.cur_modes[g]
    if mode == predicted {
      self.enc.decision(self.states, 68, 1)
    } else {
      self.enc.decision(self.states, 68, 0)
      let rem = if mode > predicted { mode - 1 } else { mode }
      self.enc.decision(self.states, 69, rem & 1)
      self.enc.decision(self.states, 69, (rem >> 1) & 1)
      self.enc.decision(self.states, 69, (rem >> 2) & 1)
    }
  }
  // No chroma prediction mode bins in 4:4:4.
  info.transform_8x8 = self.dct8x8
  h264_cabacw_cbp(
    self.enc,
    self.states,
    self.ctx,
    mb_idx,
    mb_x,
    mb_y,
    cbp,
    false,
  )
  info.cbp_all = cbp
  if cbp != 0 {
    h264_cabacw_dqp(self.enc, self.states, self.ctx, self.mb_dqp)
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  } else {
    self.ctx.last_qscale_diff = 0
  }
  // Three planes, luma residual categories (cat 2/8/12 for 4x4 AC blocks).
  for p = 0; p < 3; p = p + 1 {
    let cat = if self.dct8x8 {
      if p == 0 {
        5
      } else if p == 1 {
        9
      } else {
        13
      }
    } else if p == 0 {
      2
    } else if p == 1 {
      8
    } else {
      12
    }
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      if (cbp & (1 << i8)) != 0 {
        if self.dct8x8 {
          let view = scan8_view_at(levels_all, 4 * p + i8, h264_zigzag_scan8x8)
          h264_cabacw_residual(
            self.enc,
            self.states,
            self.ctx,
            mb_idx,
            mb_x,
            mb_y,
            cat,
            16 * p + 4 * i8,
            view,
            64,
            false,
          )
          continue
        }
        for i4 = 0; i4 < 4; i4 = i4 + 1 {
          let i = i8 * 4 + i4
          let view = scan_view_at(
            levels_all,
            16 * p + i,
            h264_zigzag_scan_t,
            0,
            16,
          )
          h264_cabacw_residual(
            self.enc,
            self.states,
            self.ctx,
            mb_idx,
            mb_x,
            mb_y,
            cat,
            16 * p + i,
            view,
            16,
            false,
          )
        }
      }
    }
  }
  // Commit the mirror the way the decoder's parse would.
  info.mb_type_bits = h264_mb_type_intra4x4
  info.intra4x4 = true
  info.chroma_mode = 0
  info.qp = self.ctx.qscale
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = self.cur_modes[g]
  }
  Ok(())
}

///|
/// Encode one intra macroblock: mode decisions + reconstruction (the CAVLC
/// intra encoder's I_NxN flow) followed by the CABAC syntax layer.
fn H264CabacIEnc::encode_macroblock(
  self : H264CabacIEnc,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  if self.pps.chroma_format == 3 {
    return self.encode_macroblock_444(mb_x, mb_y)
  }
  let info = self.ctx.infos[mb_idx]
  // Macroblock-entry mirror (the decoder clears `nz` at parse start; the
  // transform size is a per-macroblock bit in FFmpeg's mb_type, so it
  // starts false here exactly like an unread MB_TYPE_8x8DCT bit).
  for i = 0; i < 48; i = i + 1 {
    info.nz[i] = 0
  }
  info.transform_8x8 = false
  self.ctx.cur_mb_is_intra = true
  // Adaptive quantisation: this MB's QP offset rides `mb_qp_delta`.
  // `ctx.qscale` / `last_qscale_diff` persist across macroblocks exactly
  // like the decoder's slice context (reset only at picture start).
  self.mb_qp = self.p.qp
  self.mb_dqp = 0
  if self.aq_on {
    let adj = h264_aq_adj(self.aq_act[mb_idx], self.aq_avg, self.aq_strength)
    let mut mq = self.p.qp + adj + h264_roi_off_at(self.roi_off, mb_idx)
    if mq < 0 {
      mq = 0
    }
    if mq > 51 {
      mq = 51
    }
    self.mb_qp = mq
    self.mb_dqp = self.p.qp_ext(mq) - self.ctx.qscale
    self.chroma_qp = h264_get_chroma_qp(
      self.pps,
      0,
      self.p.qp_ext(mq),
      bit_depth=self.p.bit_depth,
    )
  }
  for i = 0; i < 16; i = i + 1 {
    self.cur_modes[i] = 0
  }
  let top_avail = mb_y > 0
  let left_avail = mb_x > 0
  // Extended quantiser QP (`§412`): the quantiser, `h264_build_dequant4`
  // and the DC/8x8 helpers are all indexed by it. `mb_qp`/`mb_dqp` stay in
  // user units because `mb_qp_delta` is offset-invariant.
  let qp = self.p.qp_ext(self.mb_qp)
  // ---- chroma decisions + residuals ----
  let cf = self.pps.chroma_format
  let nblk = 4 * cf
  let crow = if cf == 2 { 16 } else { 8 }
  let cbase = mb_y * crow * self.cstride + mb_x * 8
  let chroma_mode = self.pick_chroma(cbase, top_avail, left_avail)
  let qmul_c = [
    h264_build_dequant4(self.pps, 1, self.chroma_qp),
    h264_build_dequant4(self.pps, 2, self.chroma_qp),
  ]
  let chroma_dc_store : Array[Array[Int32]] = [
    Array::make(16, 0),
    Array::make(16, 0),
  ]
  let chroma_ac_store : Array[Array[Int32]] = [
    Array::make(16 * nblk, 0),
    Array::make(16 * nblk, 0),
  ]
  let chroma_dc_nz : Array[Bool] = [false, false]
  let mb : Array[Int32] = Array::make(768, 0)
  for c = 0; c < 2; c = c + 1 {
    let src = if c == 0 { self.src_u } else { self.src_v }
    let rec = if c == 0 { self.rec_u } else { self.rec_v }
    let sums : Array[Int32] = Array::make(nblk, 0)
    for i = 0; i < nblk; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let mut sum = 0
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          sum = sum +
            src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      sums[i] = sum
    }
    let dc_store : Array[Int32] = Array::make(16, 0)
    let dc_n = if cf == 2 {
      h264_enc_chroma422_dc_hadamard_quant(sums, dc_store, self.chroma_qp)
      8
    } else {
      ignore(
        h264_enc_chroma_dc_hadamard_quant(sums, dc_store, 0, self.chroma_qp),
      )
      4
    }
    chroma_dc_store[c] = dc_store
    let mut any_dc = false
    for s2 = 0; s2 < dc_n; s2 = s2 + 1 {
      if dc_store[s2] != 0 {
        any_dc = true
        break
      }
    }
    chroma_dc_nz[c] = any_dc
    for i = 0; i < nblk; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, self.chroma_qp)
      levels[0] = 0 // storage position 0 is the DC slot
      for s = 0; s < 16; s = s + 1 {
        chroma_ac_store[c][16 * i + s] = levels[s]
        if levels[s] != 0 {
          mb[256 + 256 * c + 16 * i + s] = h264_enc_dequant_level(
            levels[s],
            qmul_c[c][s],
            bit_depth=self.p.bit_depth,
          )
        }
      }
    }
    if cf == 2 {
      for k = 0; k < 8; k = k + 1 {
        let lv = dc_store[k]
        if lv != 0 {
          mb[256 + 256 * c + h264_chroma422_dc_scan[k]] = lv
        }
      }
    } else {
      for s = 0; s < 4; s = s + 1 {
        let lv = dc_store[s]
        if lv != 0 {
          mb[256 + 256 * c + 16 * s] = lv
        }
      }
    }
  }
  // ---- luma I16x16 candidates: evaluated BEFORE the I4x4 pass (each
  // `pred16x16` overwrites the whole MB region, so every candidate must see
  // the same predecessor state) — same order as the CAVLC intra encoder. ----
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut i16_mode = 0
  let mut i16_eff = 0
  let mut i16_cost = 0
  let mut i16_found = false
  for sig = 0; sig < 4; sig = sig + 1 {
    let eff = match h264_check_intra_pred_mode(sig, top_avail, left_avail) {
      Ok(v) => v
      Err(_) => -1
    }
    if eff < 0 {
      continue
    }
    if h264_pred16x16(
        self.rec_y,
        ybase,
        self.ystride,
        eff,
        top_avail,
        left_avail,
        bit_depth=self.p.bit_depth,
      )
      is Ok(_) {
      let mut sad = 0
      for row = 0; row < 16; row = row + 1 {
        for col = 0; col < 16; col = col + 1 {
          let d = self.src_y[ybase + row * self.ystride + col] -
            self.rec_y[ybase + row * self.ystride + col]
          sad = sad + (if d < 0 { -d } else { d })
        }
      }
      if !i16_found || sad < i16_cost {
        i16_found = true
        i16_cost = sad
        i16_mode = sig
        i16_eff = eff
      }
    }
  }
  // ---- luma I8x8 candidate (High-profile transform_8x8): evaluated on
  // the I16x16 pass's leftover state. Only the MB borders matter for the
  // first 8x8 block; every later block predicts from blocks this pass
  // itself reconstructs (the decoder replays the same order), so the pass
  // is self-consistent regardless of what rec_y holds on entry. The modes
  // go to a scratch array: `cur_modes` must stay zeroed for the I4x4
  // pass's within-MB predictors (the decoder's parse starts from zeros
  // too). ----
  let luma8_store : Array[Int32] = Array::make(256, 0)
  let i8_modes : Array[Int32] = Array::make(16, 0)
  let mut i8_cost = 0
  let mut luma_cbp8 = 0
  let mut i8_found = false
  if self.dct8x8 {
    match self.encode_luma_i8(mb_x, mb_y, luma8_store, i8_modes, mb) {
      Ok((cost, cbp)) => {
        i8_cost = cost
        luma_cbp8 = cbp
        i8_found = true
      }
      Err(e) => return Err(e)
    }
  }
  // ---- luma I4x4: sequential decision + reconstruction ----
  let qmul_y = h264_build_dequant4(self.pps, 0, qp)
  let mut i4_cost = 0
  let mut luma_cbp = 0
  let luma_store : Array[Int32] = Array::make(256, 0)
  // I16x16 DC level store and its nonzero count (filled only by the I16
  // redo below; the committed mb_type values make the I16 branch live).
  let luma_dc_store : Array[Int32] = Array::make(16, 0)
  let mut luma_dc_total = 0
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * self.ystride + gx * 4
    let blk_top = gy > 0 || top_avail
    let blk_left = gx > 0 || left_avail
    let topright = if gy == 0 {
      top_avail && (gx < 3 || mb_x < self.mb_width - 1)
    } else {
      gx == 0 || gx == 2 || (gx == 1 && gy % 2 == 0)
    }
    let mut best_sig = 0
    let mut best_eff : Int32 = -1
    let mut best_sad = -1
    for sig = 0; sig < 9; sig = sig + 1 {
      let eff = match h264_check_intra4x4_mode(sig, blk_top, blk_left) {
        Ok(v) => v
        Err(_) => -1
      }
      if eff < 0 {
        continue
      }
      let pred_err = h264_pred4x4(
          self.rec_y,
          off,
          self.ystride,
          eff,
          blk_top,
          blk_left,
          topright,
          bit_depth=self.p.bit_depth,
        )
        is Err(_)
      if pred_err {
        continue
      }
      let sad = h264_enc_sad4(self.src_y, self.rec_y, off, self.ystride)
      if best_sad < 0 || sad < best_sad {
        best_sad = sad
        best_sig = sig
        best_eff = eff
      }
    }
    if best_eff < 0 {
      return Err("h264 enc: no feasible intra4x4 mode")
    }
    i4_cost = i4_cost + best_sad
    match
      h264_pred4x4(
        self.rec_y,
        off,
        self.ystride,
        best_eff,
        blk_top,
        blk_left,
        topright,
        bit_depth=self.p.bit_depth,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    self.cur_modes[g] = best_sig
    let res : Array[Int32] = Array::make(16, 0)
    for row = 0; row < 4; row = row + 1 {
      for col = 0; col < 4; col = col + 1 {
        res[row * 4 + col] = self.src_y[off + row * self.ystride + col] -
          self.rec_y[off + row * self.ystride + col]
      }
    }
    let levels = h264_enc_fdct_quant_res(res, 0, qp)
    let mut total = 0
    for s = 0; s < 16; s = s + 1 {
      luma_store[16 * i + s] = levels[s]
      if levels[s] != 0 {
        total = total + 1
        mb[16 * i + s] = h264_enc_dequant_level(
          levels[s],
          qmul_y[s],
          bit_depth=self.p.bit_depth,
        )
      }
    }
    if total != 0 {
      luma_cbp = luma_cbp | (1 << (i / 4))
      if total == 1 && mb[16 * i] != 0 {
        h264_idct_dc_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      } else {
        h264_idct_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      }
    }
  }
  // Decision, in the encoder's SAD metric (all three are prediction SADs):
  // first the Intra_NxN form - I4x4 must beat I8x8 by ~3% to justify its
  // twelve extra mode trees, ties keep the cheaper-signalled I8x8 - then
  // that form must beat I16x16 by ~6% (whose whole-MB syntax prices into
  // fewer bins on smooth content). The I8/I16 conflict of §385 (both flags
  // true: the reconstruction ran the I8x8 redo while the syntax layer
  // signalled Intra16x16) is structurally impossible now - use_i16 and
  // use_i8 are mutually exclusive by construction.
  let use_i8 = i8_found && !(100 * i4_cost < 97 * i8_cost)
  let nxn_cost = if use_i8 { i8_cost } else { i4_cost }
  let use_i16 = !use_i8 && i16_found && !(100 * nxn_cost < 94 * i16_cost)
  if use_i8 {
    // Redo the luma plane for I8x8: the I4x4 pass left its dequantised
    // coefficients and reconstruction in place - clear both, then re-run
    // the deterministic 8x8 pass committing into `cur_modes`. The pass
    // reproduces the evaluation exactly: its first block reads only
    // MB-border samples and every later block reads blocks the pass itself
    // just reconstructed.
    self.stats.i8_mbs += 1
    for i = 0; i < 256; i = i + 1 {
      mb[i] = 0
    }
    match self.encode_luma_i8(mb_x, mb_y, luma8_store, self.cur_modes, mb) {
      Ok((cost, cbp)) => {
        i8_cost = cost
        luma_cbp8 = cbp
      }
      Err(e) => return Err(e)
    }
    luma_cbp = luma_cbp8
  } else if use_i16 {
    // Redo the luma plane for I16: the I4x4 pass left its dequantised
    // coefficients and reconstruction in place - clear both.
    for i = 0; i < 256; i = i + 1 {
      mb[i] = 0
    }
    match
      h264_pred16x16(
        self.rec_y,
        ybase,
        self.ystride,
        i16_eff,
        top_avail,
        left_avail,
        bit_depth=self.p.bit_depth,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let sums : Array[Int32] = Array::make(16, 0)
    for g = 0; g < 16; g = g + 1 {
      let bx = h264_luma_block_x[g]
      let by = h264_luma_block_y[g]
      let off = ybase + by * 4 * self.ystride + bx * 4
      let mut sum = 0
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          sum = sum +
            self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      sums[by * 4 + bx] = sum
    }
    // The DC pool input equals the 4x4 transform's DC coefficient in this
    // fdct convention (a block's pixel sum), so the Hadamard pool here and
    // the decoder's Hadamard-inverse reconstruction share one transform
    // chain.
    ignore(h264_enc_luma_dc_hadamard_quant(sums, 0, 4, luma_dc_store, 0, qp))
    luma_dc_total = 0
    for s = 0; s < 16; s = s + 1 {
      if luma_dc_store[s] != 0 {
        luma_dc_total = luma_dc_total + 1
      }
    }
    // AC blocks: the FDCT runs over the FULL residual (the (0,0) sample
    // included) and only the DC level (scan position 0) is dropped — the
    // Hadamard DC pool owns it. Zeroing the DC sample before the transform
    // would corrupt every AC coefficient instead.
    let i16_ac_nz : Array[Int32] = Array::make(16, 0)
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let off = ybase + gy * 4 * self.ystride + gx * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, qp)
      for s = 0; s < 16; s = s + 1 {
        luma_store[16 * i + s] = levels[s]
      }
      luma_store[16 * i] = 0
      let mut total = 0
      for s = 1; s < 16; s = s + 1 {
        let lv = levels[s]
        if lv != 0 {
          total = total + 1
          mb[16 * i + s] = h264_enc_dequant_level(
            lv,
            qmul_y[s],
            bit_depth=self.p.bit_depth,
          )
        }
      }
      i16_ac_nz[gy * 4 + gx] = total
      if total != 0 {
        luma_cbp = luma_cbp | (1 << (i / 4))
      }
    }
    luma_cbp = if luma_cbp != 0 { 15 } else { 0 }
    // Reconstruction, mirror of `h264_recon_full_plane`'s Intra16x16 branch:
    // the Hadamard DC scatter happens BEFORE the per-block loop (the IDCT
    // integrates the scattered DC slot with the AC levels), then per block
    // an IDCT-add over any non-zero AC count, else a DC cover for the
    // dequantised DC slot the scatter left.
    if luma_dc_total > 0 {
      h264_luma_dc_dequant_idct(
        mb,
        0,
        luma_dc_store,
        0,
        qmul_y[0],
        bit_depth=self.p.bit_depth,
      )
    }
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let off = ybase + gy * 4 * self.ystride + gx * 4
      if i16_ac_nz[gy * 4 + gx] != 0 {
        h264_idct_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      } else if mb[16 * i] != 0 {
        h264_idct_dc_add(
          self.rec_y,
          off,
          self.ystride,
          mb,
          16 * i,
          bit_depth=self.p.bit_depth,
        )
      }
    }
  }
  // Chroma cbp decision (below 2 the decoder never sees the AC levels).
  let chroma_c_cbp = if chroma_ac_nz_count(chroma_ac_store) {
    2
  } else if chroma_dc_nz[0] || chroma_dc_nz[1] {
    1
  } else {
    0
  }
  if chroma_c_cbp < 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < nblk; i = i + 1 {
        for k = 0; k < 16; k = k + 1 {
          if k != 0 {
            mb[256 + 256 * c + 16 * i + k] = 0
          }
        }
      }
    }
  }
  // Chroma reconstruction.
  for c = 0; c < 2; c = c + 1 {
    let plane = if c == 0 { self.rec_u } else { self.rec_v }
    if chroma_dc_nz[c] {
      if cf == 2 {
        h264_chroma422_dc_dequant_idct(
          mb,
          256 + 256 * c,
          h264_build_dequant4(self.pps, 1 + c, self.chroma_qp + 3)[0],
          bit_depth=self.p.bit_depth,
        )
      } else {
        h264_chroma_dc_dequant_idct(
          mb,
          256 + 256 * c,
          qmul_c[c][0],
          bit_depth=self.p.bit_depth,
        )
      }
    }
    for i = 0; i < nblk; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let off = cbase + by * self.cstride + bx
      let bo = 256 + 256 * c + 16 * i
      let nzv = if chroma_c_cbp == 2 {
        chroma_block_nz(chroma_ac_store[c], i)
      } else {
        0
      }
      if nzv != 0 {
        h264_idct_add(
          plane,
          off,
          self.cstride,
          mb,
          bo,
          bit_depth=self.p.bit_depth,
        )
      } else if mb[bo] != 0 {
        h264_idct_dc_add(
          plane,
          off,
          self.cstride,
          mb,
          bo,
          bit_depth=self.p.bit_depth,
        )
      }
    }
  }
  // ---- CABAC syntax layer ----
  // `decode_cabac_intra_mb_type`'s I-slice first-bin context: 3 plus the
  // Intra16x16/Intra_PCM neighbour count.
  let mut c = 0
  if h264_has_left(self.ctx, mb_idx) &&
    (
      self.ctx.infos[mb_idx - 1].mb_type_bits &
      (h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)
    ) !=
    0 {
    c = c + 1
  }
  if h264_has_top(self.ctx, mb_idx) &&
    (
      self.ctx.infos[h264_top_index(self.ctx, mb_idx)].mb_type_bits &
      (h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)
    ) !=
    0 {
    c = c + 1
  }
  if use_i16 {
    // mb_type 1..24 (Intra16x16): the I-slice continuation. The first bin
    // selects I16x16, then the terminate bin — bit 0 rejects Intra_PCM
    // (mb_type 25) exactly as the decoder's `get_cabac_terminate` reads it.
    // The remaining bit word v = mb_type - 1 assembles as
    //   v = 12*b0 + 4*(b1 + b2) + 2*b3 + b4
    // from contexts RELATIVE to the decoder's `state += 2` advance (the
    // neighbour count `c` only feeds the FIRST bin), i.e. b0@6, b1@7,
    // b2@8 (read only when b1 = 1), b3@9, b4@10 for an I slice. v's low two
    // bits are the I16 prediction field (spec order V/H/DC/P) and its high
    // bits the cbp group `h264_i_mb_type_cbp`.
    self.enc.decision(self.states, 3 + c, 1)
    self.enc.terminate(0)
    // The I16 mode field of mb_type is ordered V/H/DC/P (spec Table 7-11;
    // `h264_i_mb_type_pred` maps it back), while the encoder tracks the
    // pred16 numbering DC/H/V/Plane.
    let spec_mode = match i16_mode {
      0 => 2 // DC
      1 => 1 // H
      2 => 0 // V
      _ => 3 // Plane
    }
    let group = if luma_cbp != 0 { 3 + chroma_c_cbp } else { chroma_c_cbp }
    let v = group * 4 + spec_mode
    let b0 = if v >= 12 { 1 } else { 0 }
    let rem = v / 4 - 3 * b0
    let b1 = if rem >= 1 { 1 } else { 0 }
    let b2 = if rem == 2 { 1 } else { 0 }
    let b3 = (spec_mode >> 1) & 1
    let b4 = spec_mode & 1
    self.enc.decision(self.states, 6, b0)
    self.enc.decision(self.states, 7, b1)
    if b1 == 1 {
      self.enc.decision(self.states, 8, b2)
    }
    self.enc.decision(self.states, 9, b3)
    self.enc.decision(self.states, 10, b4)
  } else {
    self.enc.decision(self.states, 3 + c, 0)
    // transform_size_8x8_flag: ctx 399 + the left/top 8x8DCT neighbour
    // count (`neighbor_transform_size`). Every I_NxN macroblock codes
    // the bit once the PPS enables the mode - the I4x4 form writes 0;
    // the mirror bit also feeds the next macroblock's context and the
    // deblock filter.
    if self.dct8x8 {
      self.enc.decision(
        self.states,
        399 + h264_neighbor_transform_size(self.ctx, mb_idx, mb_x, mb_y),
        if use_i8 {
          1
        } else {
          0
        },
      )
    }
    if use_i8 {
      info.transform_8x8 = true
      // One prediction mode per 8x8 block (the z-order block index's
      // 0/4/8/12 grid slots), the same ctx 68/69 bin tree as I4x4.
      for i = 0; i < 16; i = i + 4 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let g = gy * 4 + gx
        let predicted = h264_pred_intra_mode(
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          gx,
          gy,
          self.cur_modes,
        )
        let mode = self.cur_modes[g]
        if mode == predicted {
          self.enc.decision(self.states, 68, 1)
        } else {
          self.enc.decision(self.states, 68, 0)
          let rem = if mode > predicted { mode - 1 } else { mode }
          self.enc.decision(self.states, 69, rem & 1)
          self.enc.decision(self.states, 69, (rem >> 1) & 1)
          self.enc.decision(self.states, 69, (rem >> 2) & 1)
        }
      }
    } else {
      // Intra4x4 prediction modes.
      for i = 0; i < 16; i = i + 1 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let g = gy * 4 + gx
        let predicted = h264_pred_intra_mode(
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          gx,
          gy,
          self.cur_modes,
        )
        let mode = self.cur_modes[g]
        if mode == predicted {
          self.enc.decision(self.states, 68, 1)
        } else {
          self.enc.decision(self.states, 68, 0)
          let rem = if mode > predicted { mode - 1 } else { mode }
          // Three decision bins at ctx 69, least-significant bit first
          // (mode = b0 + 2*b1 + 4*b2 on the decode side).
          self.enc.decision(self.states, 69, rem & 1)
          self.enc.decision(self.states, 69, (rem >> 1) & 1)
          self.enc.decision(self.states, 69, (rem >> 2) & 1)
        }
      }
    }
  }
  // Chroma prediction mode.
  let mut cc = 0
  if h264_has_left(self.ctx, mb_idx) &&
    self.ctx.infos[mb_idx - 1].chroma_mode != 0 {
    cc = cc + 1
  }
  if h264_has_top(self.ctx, mb_idx) &&
    self.ctx.infos[h264_top_index(self.ctx, mb_idx)].chroma_mode != 0 {
    cc = cc + 1
  }
  if chroma_mode == 0 {
    self.enc.decision(self.states, 64 + cc, 0)
  } else {
    self.enc.decision(self.states, 64 + cc, 1)
    if chroma_mode == 1 {
      self.enc.decision(self.states, 67, 0)
    } else {
      self.enc.decision(self.states, 67, 1)
      if chroma_mode == 2 {
        self.enc.decision(self.states, 67, 0)
      } else {
        self.enc.decision(self.states, 67, 1)
      }
    }
  }
  // CBP: an Intra_NxN codes both patterns with the neighbour-packed
  // contexts; an Intra16x16 derives its whole pattern from mb_type's group
  // (`h264_i_mb_type_cbp`), so no cbp bins exist there.
  let cbp = luma_cbp | (chroma_c_cbp << 4)
  if !use_i16 {
    h264_cabacw_cbp(
      self.enc,
      self.states,
      self.ctx,
      mb_idx,
      mb_x,
      mb_y,
      cbp,
      true,
    )
  }
  // Decoder writes `info.cbp_all = cbp` before the residual bins.
  info.cbp_all = cbp
  if cbp != 0 || use_i16 {
    h264_cabacw_dqp(self.enc, self.states, self.ctx, self.mb_dqp)
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  } else {
    // The decoder's all-zero else branch resets the dqp context selector.
    self.ctx.last_qscale_diff = 0
  }
  if use_i16 {
    // The Hadamard DC block (cat 0, n 48, full zigzag scan) then the
    // sixteen luma AC blocks (cat 1, AC-only scan), the latter gated by the
    // all-groups luma cbp.
    let dc_view = scan_view_at(luma_dc_store, 0, h264_zigzag_scan_t, 0, 16)
    h264_cabacw_residual(
      self.enc,
      self.states,
      self.ctx,
      mb_idx,
      mb_x,
      mb_y,
      0,
      48,
      dc_view,
      16,
      true,
    )
    if luma_cbp != 0 {
      for i = 0; i < 16; i = i + 1 {
        let view = scan_view_at(luma_store, i, h264_zigzag_scan_t, 1, 15)
        h264_cabacw_residual(
          self.enc,
          self.states,
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          1,
          i,
          view,
          15,
          false,
        )
      }
    }
  } else if use_i8 {
    // Luma residuals (cbp-gated 8x8 blocks, cat 5, transposed 8x8 zigzag
    // scan, implied coded-block flag in 4:2:0).
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      if (luma_cbp & (1 << i8)) != 0 {
        let view = scan8_view_at(luma8_store, i8, h264_zigzag_scan8x8)
        h264_cabacw_residual(
          self.enc,
          self.states,
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          5,
          4 * i8,
          view,
          64,
          false,
        )
      }
    }
  } else {
    // Luma residuals (cbp-gated 4x4 blocks, cat 2, full scan).
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      if (luma_cbp & (1 << i8)) != 0 {
        for i4 = 0; i4 < 4; i4 = i4 + 1 {
          let i = i8 * 4 + i4
          let view = scan_view_at(luma_store, i, h264_zigzag_scan_t, 0, 16)
          h264_cabacw_residual(
            self.enc,
            self.states,
            self.ctx,
            mb_idx,
            mb_x,
            mb_y,
            2,
            i,
            view,
            16,
            false,
          )
        }
      }
    }
  }
  // Chroma DC residuals (cat 3): the four Hadamard levels in scan order
  // (`h264_chroma_dc_scan` maps scan position k to the DC slot at 16*k).
  if chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
      if nblk == 8 {
        let dc8 : Array[Int32] = Array::make(8, 0)
        for k = 0; k < 8; k = k + 1 {
          dc8[k] = chroma_dc_store[c][k]
        }
        h264_cabacw_residual(
          self.enc,
          self.states,
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          3,
          49 + c,
          dc8,
          8,
          true,
        )
      } else {
        let dc4 : Array[Int32] = [
          chroma_dc_store[c][0],
          chroma_dc_store[c][1],
          chroma_dc_store[c][2],
          chroma_dc_store[c][3],
        ]
        h264_cabacw_residual(
          self.enc,
          self.states,
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          3,
          49 + c,
          dc4,
          4,
          true,
        )
      }
    }
  }
  // Chroma AC residuals (cat 4, AC-only scan).
  if chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < nblk; i = i + 1 {
        let view = scan_view_at(
          chroma_ac_store[c],
          i,
          h264_zigzag_scan_t,
          1,
          15,
        )
        h264_cabacw_residual(
          self.enc,
          self.states,
          self.ctx,
          mb_idx,
          mb_x,
          mb_y,
          4,
          16 + 16 * c + i,
          view,
          15,
          false,
        )
      }
    }
  }
  // Commit the mirror the way the decoder's parse would.
  info.mb_type_bits = if use_i16 {
    h264_mb_type_intra16x16
  } else {
    h264_mb_type_intra4x4
  }
  info.intra4x4 = !use_i16
  info.chroma_mode = chroma_mode
  info.qp = self.ctx.qscale
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = self.cur_modes[g]
  }
  Ok(())
}

///|
/// Code one partition's `mvd` pair against the mirror's predictors and
/// write the partition back into both mirrors (the decoder's
/// `h264_write_back_part` updates the mvd cache with the clamped absolute
/// values the amvd contexts of later partitions read; `fill_part` keeps the
/// CAVLC-side encoder mirror in sync).
fn H264PEncoder::cabac_mvd_partition(
  self : H264PEncoder,
  ctx : H264DecCtx,
  enc : H264CabacEnc,
  states : Array[Int32],
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
  pmvx : Int32,
  pmvy : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  let (lamvd0, lamvd1) = h264_mvd_fetch(ctx, mb_idx, mb_x, mb_y, bx - 1, by)
  let (tamvd0, tamvd1) = h264_mvd_fetch(ctx, mb_idx, mb_x, mb_y, bx, by - 1)
  let absx = h264_cabacw_mvd_one(enc, states, 40, lamvd0 + tamvd0, mvx - pmvx)
  let absy = h264_cabacw_mvd_one(enc, states, 47, lamvd1 + tamvd1, mvy - pmvy)
  h264_write_back_part(
    ctx,
    mb_idx,
    bx,
    by,
    bw,
    bh,
    mvx,
    mvy,
    self.cur_ref_mb,
    absx,
    absy,
  )
  self.fill_part(bx, by, bw, bh, mvx, mvy)
}

///|
/// Chroma residual bins of one coded macroblock: the two DC blocks (cat 3,
/// the four Hadamard levels in scan order) when the chroma cbp is non-zero,
/// then the eight AC blocks (cat 4, AC-only scan) when it is 2.
fn h264_cabacw_chroma(
  enc : H264CabacEnc,
  states : Array[Int32],
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  coded : H264PMbCode,
) -> Unit {
  let nblk = 4 * ctx.pps.chroma_format
  if coded.chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
      if nblk == 8 {
        let dc8 : Array[Int32] = Array::make(8, 0)
        for k = 0; k < 8; k = k + 1 {
          dc8[k] = coded.chroma_dc_store[c][k]
        }
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          3,
          49 + c,
          dc8,
          8,
          true,
        )
      } else {
        let dc4 : Array[Int32] = [
          coded.chroma_dc_store[c][0],
          coded.chroma_dc_store[c][1],
          coded.chroma_dc_store[c][2],
          coded.chroma_dc_store[c][3],
        ]
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          3,
          49 + c,
          dc4,
          4,
          true,
        )
      }
    }
  }
  if coded.chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      // 4:2:0 codes four chroma AC blocks, 4:2:2 eight (`4 * num_c8x8` on
      // the decode side, i.e. `4 * chroma_format`).
      for i = 0; i < 4 * ctx.pps.chroma_format; i = i + 1 {
        let view = scan_view_at(
          coded.chroma_ac_store[c],
          i,
          h264_zigzag_scan_t,
          1,
          15,
        )
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          4,
          16 + 16 * c + i,
          view,
          15,
          false,
        )
      }
    }
  }
}

///|
/// Emit the CABAC syntax of one coded P macroblock: the encoder-side twin
/// of `ff_h264_decode_mb_cabac`'s inter path (mb_type bins, sub-mb types,
/// mvd bypass pairs with the decoder's exact write-back order, cbp, dqp,
/// residuals).
fn H264PEncoder::write_cabac_mb_syntax(
  self : H264PEncoder,
  ctx : H264DecCtx,
  enc : H264CabacEnc,
  states : Array[Int32],
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
  coded : H264PMbCode,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let info = ctx.infos[mb_idx]
  let nblk = 4 * self.pps.chroma_format
  match plan {
    Skip => return
    I8(raw_modes, chroma_mode) => {
      // P-slice Intra_NxN: ctx 14 = 1 selects intra, then
      // `decode_cabac_intra_mb_type(ctx_base 17, intra_slice 0)` reads its
      // first bin at ctx 17 - 0 is I_NxN (no terminate bin on this path,
      // that one only follows a 1).
      enc.decision(states, 14, 1)
      enc.decision(states, 17, 0)
      ctx.cur_mb_is_intra = true
      // transform_size_8x8_flag: the I_NxN branch reads it unconditionally
      // once the PPS enables the mode (ctx 399 + 8x8DCT neighbour count).
      enc.decision(
        states,
        399 + h264_neighbor_transform_size(ctx, mb_idx, mb_x, mb_y),
        1,
      )
      info.transform_8x8 = true
      // One prediction mode per 8x8 block on the 2x2-replicated grid (the
      // decoder's fill), the same ctx 68/69 bin tree as Intra4x4.
      let cur : Array[Int32] = Array::make(16, 0)
      for k = 0; k < 4; k = k + 1 {
        for dy = 0; dy < 2; dy = dy + 1 {
          for dx = 0; dx < 2; dx = dx + 1 {
            cur[(k / 2 * 2 + dy) * 4 + k % 2 * 2 + dx] = raw_modes[k]
          }
        }
      }
      for k = 0; k < 4; k = k + 1 {
        let predicted = h264_pred_intra_mode(
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          k % 2 * 2,
          k / 2 * 2,
          cur,
        )
        let mode = raw_modes[k]
        if mode == predicted {
          enc.decision(states, 68, 1)
        } else {
          enc.decision(states, 68, 0)
          let rem = if mode > predicted { mode - 1 } else { mode }
          enc.decision(states, 69, rem & 1)
          enc.decision(states, 69, (rem >> 1) & 1)
          enc.decision(states, 69, (rem >> 2) & 1)
        }
      }
      // Chroma prediction mode tree (identical to the I-slice writer).
      if self.pps.chroma_format != 3 {
        let mut cc = 0
        if h264_has_left(ctx, mb_idx) && ctx.infos[mb_idx - 1].chroma_mode != 0 {
          cc = cc + 1
        }
        if h264_has_top(ctx, mb_idx) &&
          ctx.infos[h264_top_index(ctx, mb_idx)].chroma_mode != 0 {
          cc = cc + 1
        }
        if chroma_mode == 0 {
          enc.decision(states, 64 + cc, 0)
        } else {
          enc.decision(states, 64 + cc, 1)
          if chroma_mode == 1 {
            enc.decision(states, 67, 0)
          } else {
            enc.decision(states, 67, 1)
            enc.decision(states, 67, if chroma_mode == 2 { 0 } else { 1 })
          }
        }
      }
      // Intra_NxN codes both cbp patterns; mb_qp_delta only when cbp != 0
      // (unlike I16x16, whose dqp bin is unconditional).
      let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
      h264_cabacw_cbp(
        enc,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        cbp,
        self.pps.chroma_format != 3,
      )
      info.cbp_all = cbp
      if cbp != 0 {
        h264_cabacw_dqp(enc, states, ctx, self.mb_dqp)
        if self.mb_dqp != 0 {
          self.stats.dqp_mbs += 1
        }
      } else {
        ctx.last_qscale_diff = 0
      }
      // Luma residuals (cbp-gated 8x8 blocks, cat 5, intra matrices on
      // the decode side).
      for p in 0..<(if self.pps.chroma_format == 3 { 3 } else { 1 }) {
        for i8 = 0; i8 < 4; i8 = i8 + 1 {
          if (coded.luma_cbp & (1 << i8)) != 0 {
            let store = if self.pps.chroma_format == 3 {
              coded.planes_444
            } else {
              coded.luma8_store
            }
            let view = scan8_view_at(store, 4 * p + i8, h264_zigzag_scan8x8)
            h264_cabacw_residual(
              enc,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              if p == 0 {
                5
              } else if p == 1 {
                9
              } else {
                13
              },
              16 * p + 4 * i8,
              view,
              64,
              false,
            )
          }
        }
      }
      h264_cabacw_chroma(enc, states, ctx, mb_idx, mb_x, mb_y, coded)
      info.mb_type_bits = h264_mb_type_intra4x4
      info.intra4x4 = true
      info.chroma_mode = chroma_mode
      info.qp = ctx.qscale
      for g = 0; g < 16; g = g + 1 {
        info.modes[g] = cur[g]
      }
      return
    }
    I4(raw_modes, chroma_mode) => {
      // P-slice Intra_NxN (I4x4): ctx 14 = 1 selects intra, ctx 17 = 0 is
      // I_NxN. The transform flag is coded only when the PPS enables 8x8DCT
      // (the I4x4 form writes 0); then sixteen prediction modes on the 4x4
      // grid (ctx 68/69), the chroma tree, the intra cbp bins, mb_qp_delta
      // when cbp != 0, and the cbp-gated 4x4 luma residuals (cat 2).
      enc.decision(states, 14, 1)
      enc.decision(states, 17, 0)
      ctx.cur_mb_is_intra = true
      if self.dct8x8 {
        enc.decision(
          states,
          399 + h264_neighbor_transform_size(ctx, mb_idx, mb_x, mb_y),
          0,
        )
      }
      info.transform_8x8 = false
      for i = 0; i < 16; i = i + 1 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let g = gy * 4 + gx
        let predicted = h264_pred_intra_mode(
          ctx, mb_idx, mb_x, mb_y, gx, gy, raw_modes,
        )
        let mode = raw_modes[g]
        if mode == predicted {
          enc.decision(states, 68, 1)
        } else {
          enc.decision(states, 68, 0)
          let rem = if mode > predicted { mode - 1 } else { mode }
          enc.decision(states, 69, rem & 1)
          enc.decision(states, 69, (rem >> 1) & 1)
          enc.decision(states, 69, (rem >> 2) & 1)
        }
      }
      let mut cc = 0
      if h264_has_left(ctx, mb_idx) && ctx.infos[mb_idx - 1].chroma_mode != 0 {
        cc = cc + 1
      }
      if h264_has_top(ctx, mb_idx) &&
        ctx.infos[h264_top_index(ctx, mb_idx)].chroma_mode != 0 {
        cc = cc + 1
      }
      if chroma_mode == 0 {
        enc.decision(states, 64 + cc, 0)
      } else {
        enc.decision(states, 64 + cc, 1)
        if chroma_mode == 1 {
          enc.decision(states, 67, 0)
        } else {
          enc.decision(states, 67, 1)
          enc.decision(states, 67, if chroma_mode == 2 { 0 } else { 1 })
        }
      }
      let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
      h264_cabacw_cbp(enc, states, ctx, mb_idx, mb_x, mb_y, cbp, true)
      info.cbp_all = cbp
      if cbp != 0 {
        h264_cabacw_dqp(enc, states, ctx, self.mb_dqp)
        if self.mb_dqp != 0 {
          self.stats.dqp_mbs += 1
        }
      } else {
        ctx.last_qscale_diff = 0
      }
      for i8 = 0; i8 < 4; i8 = i8 + 1 {
        if (coded.luma_cbp & (1 << i8)) != 0 {
          for i4 = 0; i4 < 4; i4 = i4 + 1 {
            let i = i8 * 4 + i4
            let view = scan_view_at(
              coded.luma_store,
              i,
              h264_zigzag_scan_t,
              0,
              16,
            )
            h264_cabacw_residual(
              enc, states, ctx, mb_idx, mb_x, mb_y, 2, i, view, 16, false,
            )
          }
        }
      }
      h264_cabacw_chroma(enc, states, ctx, mb_idx, mb_x, mb_y, coded)
      info.mb_type_bits = h264_mb_type_intra4x4
      info.intra4x4 = true
      info.chroma_mode = chroma_mode
      info.qp = ctx.qscale
      for g = 0; g < 16; g = g + 1 {
        info.modes[g] = raw_modes[g]
      }
      return
    }
    I16(sig, _, chroma_mode) => {
      // P-slice intra branch of `decode_cabac_mb_type`: ctx 14 = 1 selects
      // intra, then `decode_cabac_intra_mb_type(ctx_base 17, intra_slice 0)`.
      // Unlike the I slice there is NO neighbour-count offset on the first
      // bin and NO `state += 2` advance: b0@18, b1@19, b2@19 (read only
      // when b1 = 1), b3@20, b4@20. `terminate(0)` rejects I_PCM (25).
      enc.decision(states, 14, 1)
      enc.decision(states, 17, 1)
      enc.terminate(0)
      let spec_mode = match sig {
        0 => 2 // DC
        1 => 1 // H
        2 => 0 // V
        _ => 3 // Plane
      }
      let group = if coded.luma_cbp != 0 {
        3 + coded.chroma_c_cbp
      } else {
        coded.chroma_c_cbp
      }
      let v = group * 4 + spec_mode // intra mb_type - 1
      let b0 = if v >= 12 { 1 } else { 0 }
      let rem = v / 4 - 3 * b0
      let b1 = if rem >= 1 { 1 } else { 0 }
      let b2 = if rem == 2 { 1 } else { 0 }
      let b3 = (spec_mode >> 1) & 1
      let b4 = spec_mode & 1
      enc.decision(states, 18, b0)
      enc.decision(states, 19, b1)
      if b1 == 1 {
        enc.decision(states, 19, b2)
      }
      enc.decision(states, 20, b3)
      enc.decision(states, 20, b4)
      ctx.cur_mb_is_intra = true
      // Chroma prediction mode tree (identical to the I-slice writer).
      let mut cc = 0
      if h264_has_left(ctx, mb_idx) && ctx.infos[mb_idx - 1].chroma_mode != 0 {
        cc = cc + 1
      }
      if h264_has_top(ctx, mb_idx) &&
        ctx.infos[h264_top_index(ctx, mb_idx)].chroma_mode != 0 {
        cc = cc + 1
      }
      if chroma_mode == 0 {
        enc.decision(states, 64 + cc, 0)
      } else {
        enc.decision(states, 64 + cc, 1)
        if chroma_mode == 1 {
          enc.decision(states, 67, 0)
        } else {
          enc.decision(states, 67, 1)
          enc.decision(states, 67, if chroma_mode == 2 { 0 } else { 1 })
        }
      }
      // I16x16 derives cbp from the mb_type group (no cbp bins); the dqp
      // bin is unconditional on the read side (`cbp != 0 || is_i16x16`).
      let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
      info.cbp_all = cbp
      h264_cabacw_dqp(enc, states, ctx, self.mb_dqp)
      if self.mb_dqp != 0 {
        self.stats.dqp_mbs += 1
      }
      let dc_view = scan_view_at(
        coded.luma_dc_store,
        0,
        h264_zigzag_scan_t,
        0,
        16,
      )
      h264_cabacw_residual(
        enc, states, ctx, mb_idx, mb_x, mb_y, 0, 48, dc_view, 16, true,
      )
      if coded.luma_cbp != 0 {
        for i = 0; i < 16; i = i + 1 {
          let view = scan_view_at(
            coded.luma_store,
            i,
            h264_zigzag_scan_t,
            1,
            15,
          )
          h264_cabacw_residual(
            enc, states, ctx, mb_idx, mb_x, mb_y, 1, i, view, 15, false,
          )
        }
      }
      if coded.chroma_c_cbp != 0 {
        for c = 0; c < 2; c = c + 1 {
          // `§420`: the 4:2:2 chroma DC block is a 2x4 Hadamard (eight
          // coefficients, `DECODE_SIGNIFICANCE(7, ...)`); 4:2:0 keeps four.
          if nblk == 8 {
            let dc8 : Array[Int32] = Array::make(8, 0)
            for k = 0; k < 8; k = k + 1 {
              dc8[k] = coded.chroma_dc_store[c][k]
            }
            h264_cabacw_residual(
              enc,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              3,
              49 + c,
              dc8,
              8,
              true,
            )
          } else {
            let dc4 : Array[Int32] = [
              coded.chroma_dc_store[c][0],
              coded.chroma_dc_store[c][1],
              coded.chroma_dc_store[c][2],
              coded.chroma_dc_store[c][3],
            ]
            h264_cabacw_residual(
              enc,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              3,
              49 + c,
              dc4,
              4,
              true,
            )
          }
        }
      }
      if coded.chroma_c_cbp == 2 {
        for c = 0; c < 2; c = c + 1 {
          // 4:2:0 four chroma AC blocks, 4:2:2 eight.
          for i = 0; i < 4 * ctx.pps.chroma_format; i = i + 1 {
            let view = scan_view_at(
              coded.chroma_ac_store[c],
              i,
              h264_zigzag_scan_t,
              1,
              15,
            )
            h264_cabacw_residual(
              enc,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              4,
              16 + 16 * c + i,
              view,
              15,
              false,
            )
          }
        }
      }
      info.mb_type_bits = h264_mb_type_intra16x16
      info.intra4x4 = false
      info.chroma_mode = chroma_mode
      info.qp = ctx.qscale
      return
    }
    Part16x16(mvx, mvy) => {
      enc.decision(states, 14, 0)
      enc.decision(states, 15, 0)
      enc.decision(states, 16, 0)
      h264_cabac_put_ref(
        self,
        enc,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        0,
        0,
        self.cur_ref_mb,
        self.nrefs,
      )
      h264_write_back_ref(ctx, mb_idx, 0, 0, 4, 4, self.cur_ref_mb)
      let (pmvx, pmvy) = h264_pred_motion(
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        0,
        0,
        4,
        self.cur_ref_mb,
      )
      self.cabac_mvd_partition(
        ctx, enc, states, mb_idx, mb_x, mb_y, 0, 0, 4, 4, pmvx, pmvy, mvx, mvy,
      )
      info.mb_type_bits = h264_mb_type_16x16 | h264_mb_type_p0l0
    }
    Part16x8(tx, ty, bx2, by2) => {
      // mb_type 1: ctx 14 = 0, ctx 15 = 1, ctx 17 = 1.
      enc.decision(states, 14, 0)
      enc.decision(states, 15, 1)
      enc.decision(states, 17, 1)
      // `§417`: each partition's reference index is written back BEFORE
      // the next partition's context derivation runs — the decoder
      // interleaves read and write-back exactly so, and the writer must
      // mirror that ordering (the `§415` batch-then-write-back form made
      // partition 1's context read a different neighbour state once
      // partition 0's ref was nonzero, desyncing the engine bins).
      h264_cabac_put_ref(
        self,
        enc,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        0,
        0,
        self.cur_ref_mb,
        self.nrefs,
      )
      h264_write_back_ref(ctx, mb_idx, 0, 0, 4, 2, self.cur_ref_mb)
      h264_cabac_put_ref(
        self,
        enc,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        0,
        2,
        self.cur_ref_mb,
        self.nrefs,
      )
      h264_write_back_ref(ctx, mb_idx, 0, 2, 4, 2, self.cur_ref_mb)
      for i = 0; i < 2; i = i + 1 {
        let by = 2 * i
        let (pmvx, pmvy) = h264_pred_16x8_motion(
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          i,
          self.cur_ref_mb,
        )
        let (mvx, mvy) = if i == 0 { (tx, ty) } else { (bx2, by2) }
        self.cabac_mvd_partition(
          ctx, enc, states, mb_idx, mb_x, mb_y, 0, by, 4, 2, pmvx, pmvy, mvx, mvy,
        )
      }
      info.mb_type_bits = h264_mb_type_16x8 |
        h264_mb_type_p0l0 |
        h264_mb_type_p1l0
    }
    Part8x16(lx, ly, rx, ry) => {
      // mb_type 2: ctx 14 = 0, ctx 15 = 1, ctx 17 = 0.
      enc.decision(states, 14, 0)
      enc.decision(states, 15, 1)
      enc.decision(states, 17, 0)
      h264_cabac_put_ref(
        self,
        enc,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        0,
        0,
        self.cur_ref_mb,
        self.nrefs,
      )
      h264_write_back_ref(ctx, mb_idx, 0, 0, 2, 4, self.cur_ref_mb)
      h264_cabac_put_ref(
        self,
        enc,
        states,
        ctx,
        mb_idx,
        mb_x,
        mb_y,
        2,
        0,
        self.cur_ref_mb,
        self.nrefs,
      )
      h264_write_back_ref(ctx, mb_idx, 2, 0, 2, 4, self.cur_ref_mb)
      for i = 0; i < 2; i = i + 1 {
        let bx = 2 * i
        let (pmvx, pmvy) = h264_pred_8x16_motion(
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          i,
          self.cur_ref_mb,
        )
        let (mvx, mvy) = if i == 0 { (lx, ly) } else { (rx, ry) }
        self.cabac_mvd_partition(
          ctx, enc, states, mb_idx, mb_x, mb_y, bx, 0, 2, 4, pmvx, pmvy, mvx, mvy,
        )
      }
      info.mb_type_bits = h264_mb_type_8x16 |
        h264_mb_type_p0l0 |
        h264_mb_type_p1l0
    }
    Part8x8(s0, s1, s2, s3, mvs) => {
      // mb_type 3 (P_8x8): ctx 14 = 0, ctx 15 = 0, ctx 16 = 1.
      enc.decision(states, 14, 0)
      enc.decision(states, 15, 0)
      enc.decision(states, 16, 1)
      let subs = [s0, s1, s2, s3]
      for k = 0; k < 4; k = k + 1 {
        h264_cabacw_sub_type(enc, states, subs[k])
      }
      // `§417`: one interleaved loop — the decoder reads group k's
      // reference index, writes back its three non-top-left cells and
      // clears the top-left, and only then derives group k+1's context
      // (which reads those cells). Batching the reads first (the `§415`
      // form) desynced the context indices for every group after the
      // first with a nonzero ref.
      for k = 0; k < 4; k = k + 1 {
        let x8 = k % 2
        let y8 = k / 2
        h264_cabac_put_ref(
          self,
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          2 * x8,
          2 * y8,
          self.cur_ref_mb,
          self.nrefs,
        )
        h264_write_back_ref(
          ctx,
          mb_idx,
          2 * x8 + 1,
          2 * y8,
          1,
          1,
          self.cur_ref_mb,
        )
        h264_write_back_ref(
          ctx,
          mb_idx,
          2 * x8,
          2 * y8 + 1,
          1,
          1,
          self.cur_ref_mb,
        )
        h264_write_back_ref(
          ctx,
          mb_idx,
          2 * x8 + 1,
          2 * y8 + 1,
          1,
          1,
          self.cur_ref_mb,
        )
        h264_clear_block(ctx, mb_idx, 2 * x8, 2 * y8)
      }
      let mut mi = 0
      for k = 0; k < 4; k = k + 1 {
        let x8 = k % 2
        let y8 = k / 2
        h264_write_back_ref(ctx, mb_idx, 2 * x8, 2 * y8, 1, 1, self.cur_ref_mb)
        let parts2 = h264_sub_partitions(subs[k], x8, y8)
        for part in parts2 {
          let (x, y, w, h) = part
          let mvx = mvs[mi]
          let mvy = mvs[mi + 1]
          mi = mi + 2
          let (pmvx, pmvy) = h264_pred_motion(
            ctx,
            mb_idx,
            mb_x,
            mb_y,
            x / 4,
            y / 4,
            w / 4,
            self.cur_ref_mb,
          )
          self.cabac_mvd_partition(
            ctx,
            enc,
            states,
            mb_idx,
            mb_x,
            mb_y,
            x / 4,
            y / 4,
            w / 4,
            h / 4,
            pmvx,
            pmvy,
            mvx,
            mvy,
          )
        }
      }
      info.mb_type_bits = h264_mb_type_8x8 |
        h264_mb_type_p0l0 |
        h264_mb_type_p1l0
    }
  }
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  h264_cabacw_cbp(
    enc,
    states,
    ctx,
    mb_idx,
    mb_x,
    mb_y,
    cbp,
    self.pps.chroma_format != 3,
  )
  // Decoder writes `info.cbp_all = cbp` before the residual bins.
  info.cbp_all = cbp
  // transform_size_8x8_flag sits between the cbp bins and mb_qp_delta: the
  // decoder reads it whenever dct8x8_allowed holds and the luma cbp is
  // non-zero (`h264_inter_residual_cabac`).
  if h264_p_dct8x8_allowed(self.dct8x8, plan) && (cbp & 15) != 0 {
    enc.decision(
      states,
      399 + h264_neighbor_transform_size(ctx, mb_idx, mb_x, mb_y),
      if coded.dct8 {
        1
      } else {
        0
      },
    )
    if coded.dct8 {
      info.transform_8x8 = true
    }
  }
  if cbp != 0 {
    h264_cabacw_dqp(enc, states, ctx, self.mb_dqp)
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  } else {
    ctx.last_qscale_diff = 0
  }
  if self.pps.chroma_format == 3 {
    // ChromaArrayType 3 shares the four CBP bits across three luma-shaped
    // planes, with separate CABAC residual contexts for Cb and Cr.
    for p in 0..<3 {
      let cat = if coded.dct8 {
        if p == 0 {
          5
        } else if p == 1 {
          9
        } else {
          13
        }
      } else if p == 0 {
        2
      } else if p == 1 {
        8
      } else {
        12
      }
      for i8 in 0..<4 {
        if (coded.luma_cbp & (1 << i8)) != 0 {
          if coded.dct8 {
            let view = scan8_view_at(
              coded.planes_444,
              4 * p + i8,
              h264_zigzag_scan8x8,
            )
            h264_cabacw_residual(
              enc,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              cat,
              16 * p + 4 * i8,
              view,
              64,
              false,
            )
            continue
          }
          for i4 in 0..<4 {
            let i = i8 * 4 + i4
            let view = scan_view_at(
              coded.planes_444,
              16 * p + i,
              h264_zigzag_scan_t,
              0,
              16,
            )
            h264_cabacw_residual(
              enc,
              states,
              ctx,
              mb_idx,
              mb_x,
              mb_y,
              cat,
              16 * p + i,
              view,
              16,
              false,
            )
          }
        }
      }
    }
  } else if coded.dct8 {
    // Luma residuals (cbp-gated 8x8 blocks, cat 5, transposed 8x8 zigzag
    // scan, implied coded-block flag in 4:2:0).
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      if (coded.luma_cbp & (1 << i8)) != 0 {
        let view = scan8_view_at(coded.luma8_store, i8, h264_zigzag_scan8x8)
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          5,
          4 * i8,
          view,
          64,
          false,
        )
      }
    }
  } else {
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      if (coded.luma_cbp & (1 << i8)) != 0 {
        for i4 = 0; i4 < 4; i4 = i4 + 1 {
          let i = i8 * 4 + i4
          let view = scan_view_at(
            coded.luma_store,
            i,
            h264_zigzag_scan_t,
            0,
            16,
          )
          h264_cabacw_residual(
            enc, states, ctx, mb_idx, mb_x, mb_y, 2, i, view, 16, false,
          )
        }
      }
    }
  }
  if coded.chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
      if nblk == 8 {
        let dc8 : Array[Int32] = Array::make(8, 0)
        for k = 0; k < 8; k = k + 1 {
          dc8[k] = coded.chroma_dc_store[c][k]
        }
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          3,
          49 + c,
          dc8,
          8,
          true,
        )
      } else {
        let dc4 : Array[Int32] = [
          coded.chroma_dc_store[c][0],
          coded.chroma_dc_store[c][1],
          coded.chroma_dc_store[c][2],
          coded.chroma_dc_store[c][3],
        ]
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          3,
          49 + c,
          dc4,
          4,
          true,
        )
      }
    }
  }
  if coded.chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      // 4:2:0 codes four chroma AC blocks, 4:2:2 eight (`4 * num_c8x8` on
      // the decode side, i.e. `4 * chroma_format`).
      for i = 0; i < 4 * ctx.pps.chroma_format; i = i + 1 {
        let view = scan_view_at(
          coded.chroma_ac_store[c],
          i,
          h264_zigzag_scan_t,
          1,
          15,
        )
        h264_cabacw_residual(
          enc,
          states,
          ctx,
          mb_idx,
          mb_x,
          mb_y,
          4,
          16 + 16 * c + i,
          view,
          15,
          false,
        )
      }
    }
  }
}

///|
/// Encode one P picture with CABAC entropy coding: same plan decisions as
/// the CAVLC encoder (rate-distortion over the CAVLC-priced candidates),
/// the P_Skip check and every syntax bin driven from the decoder-context
/// mirror.
fn H264PEncoder::encode_p_frame_cabac(
  self : H264PEncoder,
  frame_num : Int32,
  intra_in_p : Bool,
  poc_lsb~ : Int32 = -1,
) -> Result[Bytes, String] {
  // Fresh picture for the encoder mirror (same reset as `encode_p_frame`).
  for k = 0; k < self.states.length(); k = k + 1 {
    let st = self.states[k]
    for i = 0; i < 32; i = i + 1 {
      st.mv[i] = 0
    }
    for i = 0; i < 16; i = i + 1 {
      st.ref_idx[i] = -2
    }
    st.intra = false
    st.has_data = false
  }
  if self.weightp {
    // The primary reference is the history head — `ref_y` can lag it with
    // `b_slices` (the pending B picture keeps the past alive until it is
    // coded); the macroblock loop also predicts from `refs_[0]`.
    h264_enc_fit_p_weight(
      self.pwt,
      self.src_y,
      self.refs_y[0],
      self.src_u,
      self.refs_u[0],
      self.src_v,
      self.refs_v[0],
      self.ystride,
      self.cstride,
      self.p.width,
      self.p.height,
      bit_depth=self.p.bit_depth,
      chroma_h=if self.pps.chroma_format != 1 {
        self.pheight
      } else {
        self.pheight / 2
      },
    )
  }
  // `§412`: the mirror and the CABAC context init take the extended
  // quantiser QP — the *slice* QP (`p.qp`), not the PPS anchor `base_qp`
  // which only rides `slice_qp_delta`.
  // `§416`: entries beyond the fitted one carry the denom-neutral
  // pair so their pred_weight_table flags stay 0 (the decoder then
  // derives the identity transform itself). The slice's active count
  // follows the available history, including its initial warm-up.
  for i = 1; i < self.nrefs; i = i + 1 {
    self.pwt.luma_weight_l0[i] = 1 << self.pwt.luma_log2_weight_denom
    self.pwt.luma_offset_l0[i] = 0
    self.pwt.chroma_weight_l0[i][0] = 1 << self.pwt.chroma_log2_weight_denom
    self.pwt.chroma_offset_l0[i][0] = 0
    self.pwt.chroma_weight_l0[i][1] = 1 << self.pwt.chroma_log2_weight_denom
    self.pwt.chroma_offset_l0[i][1] = 0
  }
  let mirror = h264_cabac_mirror_new(
    self.mb_width,
    self.mb_height,
    self.pps,
    self.p.qp_ext(self.p.qp),
    0,
    self.ystride,
    self.cstride,
    self.pheight,
    bit_depth=self.p.bit_depth,
  )
  let enc = h264_cabac_enc_new()
  let states = ff_h264_init_cabac_states(
    self.p.qp_ext(self.p.qp),
    self.p.bit_depth,
    0,
    0,
  )
  // CABAC RD pricing (`§392`): publish this picture's mirror, engine and
  // context states so `eval_plan` can price every candidate through the
  // real writer with snapshot/rollback instead of the CAVLC dry run.
  if self.cabac_rd {
    self.price_mirror = Some(mirror)
    self.price_enc = Some(enc)
    self.price_states = Some(states)
  }
  // Slice header.
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(5) // slice_type: P (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num (log2_max_frame_num = 4)
  if poc_lsb >= 0 {
    r.put(poc_lsb & 15, 4) // pic_order_cnt_lsb (POC type 0 sequences)
  }
  self.put_active_refs(r)
  r.put_bit(0) // ref_pic_list_modification_flag_l0
  // pred_weight_table (`weightp`), before dec_ref_pic_marking.
  if self.weightp {
    h264_enc_put_pwt(r, self.pwt, nrefs=self.nrefs)
  }
  r.put_bit(0) // adaptive_ref_pic_marking_mode_flag
  r.put_ue(0) // cabac_init_idc
  r.put_se(self.p.qp - self.base_qp) // slice_qp_delta
  // `§433`: slice-level deblocking syntax when the PPS opted in.
  if self.pps.deblocking_filter_parameters_present != 0 {
    r.put_ue(0) // disable_deblocking_filter_idc
    r.put_se(self.p.deblock_alpha) // slice_alpha_c0_offset_div2
    r.put_se(self.p.deblock_beta) // slice_beta_offset_div2
  }
  while r.bw.nbits != 0 {
    r.put_bit(1) // cabac_alignment_one_bit
  }
  let header = r.finish_raw_of()
  let n_mbs = self.mb_width * self.mb_height
  let mut mb = 0
  for mb_y = 0; mb_y < self.mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < self.mb_width; mb_x = mb_x + 1 {
      let mb_idx = mb_y * self.mb_width + mb_x
      let info = mirror.infos[mb_idx]
      for i = 0; i < 48; i = i + 1 {
        info.nz[i] = 0
      }
      // Per-macroblock transform size (FFmpeg's MB_TYPE_8x8DCT mb_type bit):
      // false unless this MB's transform_size_8x8_flag is written as 1.
      info.transform_8x8 = false
      mirror.cur_mb_is_intra = false
      // Adaptive quantisation: this MB's QP offset rides `mb_qp_delta`
      // against the mirror's running qscale (the decoder accumulates dqp
      // across macroblocks; the mirror persists for the whole picture).
      self.mb_qp = self.p.qp
      self.mb_dqp = 0
      if self.aq_on {
        let adj = h264_aq_adj(
          self.aq_act[mb_idx],
          self.aq_avg,
          self.aq_strength,
        )
        let mut mq = self.p.qp + adj + h264_roi_off_at(self.roi_off, mb_idx)
        if mq < 0 {
          mq = 0
        }
        if mq > 51 {
          mq = 51
        }
        self.mb_qp = mq
        // `§412`: the running `qscale` lives in the extended QP space, so the
        // delta this MB signals has to as well.
        self.mb_dqp = self.p.qp_ext(mq) - mirror.qscale
        self.chroma_qp = h264_get_chroma_qp(
          self.pps,
          0,
          self.p.qp_ext(mq),
          bit_depth=self.p.bit_depth,
        )
      }
      // P_Skip check with the prediction the decoder itself would derive.
      // A previous macroblock may have selected an older reference.
      // P_Skip always uses slot 0, including its distortion estimate.
      self.cur_ref_mb = 0
      self.ref_y = self.refs_y[0]
      self.ref_u = self.refs_u[0]
      self.ref_v = self.refs_v[0]
      let (pmvx, pmvy) = h264_pred_pskip_motion(mirror, mb_idx, mb_x, mb_y)
      // `§430`: x264 trusts the mb_info hint unconditionally — a constant
      // macroblock is forced to P_Skip, skipping the motion search and the
      // RD candidates (the skip prediction above is what the decoder derives).
      let plan = if h264_hint_is_constant(self.hint_const, mb_idx) {
        Skip
      } else {
        let (_, _, skip_sad) = self.me_fixed(
          mb_x, mb_y, 0, 0, 16, 16, pmvx, pmvy,
        )
        // `intra_in_p` is opt-in: with it off the RD surface stays the
        // inter-only one from §382, so every pinned CABAC stream is unchanged.
        if skip_sad == 0 && self.me_fixed_ssd(mb_x, mb_y, pmvx, pmvy) == 0 {
          Skip
        } else {
          self.decide_plan(mb_x, mb_y, intra_in_p)
        }
      }
      if plan is I16(_, _, _) {
        self.stats.i16_mbs += 1
      }
      if plan is I8(_, _) {
        self.stats.i8p_mbs += 1
      }
      if plan is I4(_, _) {
        self.stats.i4p_mbs += 1
      }
      if !(plan is Skip) {
        self.stats.coded_mbs += 1
      }
      let skip_ctx = h264_cabacw_skip_ctx(mirror, mb_idx)
      if plan is Skip {
        enc.decision(states, skip_ctx, 1)
        self.commit_skip(mb_idx, pmvx, pmvy, qp=mirror.qscale)
        // Mirror `h264_cabac_skip_mb` exactly: the partition write-back
        // (mv/ref plus the mvd cache zeros), the decoder's four-bit skip
        // type (not the bare skip bit), cbp 0, the running qp and the
        // dqp-context reset of the C skip path.
        h264_write_back_part(mirror, mb_idx, 0, 0, 4, 4, pmvx, pmvy, 0, 0, 0)
        info.mb_type_bits = h264_mb_type_16x16 |
          h264_mb_type_p0l0 |
          h264_mb_type_p1l0 |
          h264_mb_type_skip
        info.cbp_all = 0
        mirror.last_qscale_diff = 0
        info.qp = mirror.qscale
      } else {
        enc.decision(states, skip_ctx, 0)
        let coded = self.code_mb_residuals(mb_x, mb_y, plan, self.mb_qp)
        if coded.dct8 {
          self.stats.i8_mbs += 1
        }
        self.write_cabac_mb_syntax(mirror, enc, states, mb_x, mb_y, plan, coded)
        let effective_dct8 = coded.dct8 &&
          (plan is I8(_, _) || coded.luma_cbp != 0)
        self.commit_plan_state(
          mb_idx,
          plan,
          dct8=effective_dct8,
          qp=mirror.qscale,
        )
        // The CABAC writer's nz mirror is the syntax mirror; keep the
        // encoder-side mirror identical for the next frame's seeds.
        for i = 0; i < 48; i = i + 1 {
          self.states[mb_idx].nz[i] = info.nz[i]
        }
        info.qp = mirror.qscale
      }
      mb = mb + 1
      // end_of_slice_flag: the terminating bin of the last macroblock
      // flushes the engine.
      enc.terminate(if mb == n_mbs { 1 } else { 0 })
    }
  }
  // `§423`: the CABAC mirror already holds every deblock-facing MB field
  // (qp/nz/mb_type/ref identity/mv); filter the reconstruction in place so
  // both the returned pixels and the next reference are filtered.
  if self.deblock {
    h264_enc_deblock_picture(
      self.rec_y,
      self.rec_u,
      self.rec_v,
      self.ystride,
      self.cstride,
      self.mb_width,
      self.mb_height,
      mirror.infos,
      self.pps,
      self.p.bit_depth,
      alpha=self.p.deblock_alpha,
      beta=self.p.deblock_beta,
    )
  }
  Ok(h264_cabac_nal(header, enc.to_bytes(), 3, 1))
}

///|
/// Encode a frame sequence with CABAC entropy coding (Main profile): the
/// first frame as an IDR I picture, every following frame as a P picture
/// referencing the previous frame's reconstruction. Returns the Annex B
/// stream.
/// `aud=true` prefixes each access unit with a delimiter; ABR and VBV
/// account for its six bytes per picture. The default emits no delimiter.
/// `aq_strength` (0..6, default 1) controls AQ's +/- QP adjustment when
/// `aq=true`; zero strength produces the same bytes as disabling AQ.
pub fn h264_encode_frames_cabac(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  intra_in_p~ : Bool = false,
  intra4x4_in_p~ : Bool = false,
  /// Default on (`§403`): 8x8 transforms in I/P pictures (and I8x8 in B
  /// with `b_slices` since `§400`). Pass `dct8x8~=false` for the legacy
  /// 4x4-only streams.
  dct8x8~ : Bool = true,
  aq~ : Bool = false,
  aq_strength~ : Int32 = 1,
  /// Default on (`§403`, on top of `§392`): price the rate-distortion
  /// candidates with the real CABAC engine and context states instead of
  /// the CAVLC dry run. Pass `cabac_rd~=false` for the CAVLC-priced
  /// decisions.
  cabac_rd~ : Bool = true,
  aud~ : Bool = false,
  /// Default on (`§403`): code the odd display positions as B pictures
  /// (I, P2, B1, P4, B3, ... with POC type 0 reordering). Needs at least
  /// 2 frames; pass `b_slices~=false` for the legacy I/P-only streams.
  b_slices~ : Bool = true,
  /// Default on (`§403`, on top of `§395`): sub-partitioned B kinds —
  /// 16x8/8x16 two-partition kinds and B_8x8 with per-group
  /// sub-macroblock decisions. Requires `b_slices`.
  b_parts~ : Bool = true,
  /// Default on (`§403`, on top of `§396`): Intra16x16 macroblocks inside
  /// B slices (scene cuts). Requires `b_slices`.
  intra_in_b~ : Bool = true,
  /// Default on (`§403`, on top of `§397`): Intra_NxN (4x4) macroblocks
  /// inside B slices. Requires `b_slices`.
  intra4x4_in_b~ : Bool = true,
  target_bytes~ : Int32 = 0,
  vbv_maxrate~ : Int32 = 0,
  vbv_bufsize~ : Int32 = 0,
  fps~ : Int32 = 0,
  vbv_init~ : Int32 = 90,
  /// `§435`: constant rate factor (x264 `--crf`, 0.0..=51.0; negative =
  /// off; see `h264_encode_frames`). Byte-identical to the CAVLC entry's
  /// CRF decisions modulo the entropy coder.
  crf~ : Double = -1.0,
  recon~ : Array[Bytes] = [],
  stats~ : H264EncStats = H264EncStats::new(),
  /// `§410`: explicit P weighted prediction; default on since `§413`
  /// (`weightp=false` restores the pre-§410 byte-identical path).
  weightp~ : Bool = true,
  /// `§434`: opt-in explicit B weighted prediction (requires `b_slices`).
  weightp_b~ : Bool = false,
  /// `§412`/`§419`: 8 (default), 9, 10, 12 or 14 bits (`yuv420p10le` frames above 8).
  bit_depth~ : Int32 = 8,
  /// `§415`: P-slice multi-reference history depth (see
  /// `h264_encode_frames`). Requires `b_slices=false`; supports
  /// `target_bytes` or VBV.
  multi_ref~ : Int32 = 1,
  /// `§420`: chroma format (see `h264_encode_frames`).
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset -12..12 (x264 `chroma-qp-offset`);
  /// 0 keeps every stream byte-identical.
  chroma_qp_offset~ : Int32 = 0,
  /// `§423`: in-loop deblocking, default on (see `h264_encode_frames`).
  deblock~ : Bool = true,
  /// `§433`: slice deblocking alpha/beta offsets in div2 units (-6..=6,
  /// x264 `--deblock alpha:beta`); either nonzero opts the PPS into
  /// deblocking control. Requires `deblock=true`.
  deblock_alpha~ : Int32 = 0,
  deblock_beta~ : Int32 = 0,
  /// `§426`: sample aspect ratio for the SPS VUI (0/0 = unset).
  sar~ : (Int32, Int32) = (0, 0),
  /// `§427`: per-display-position side data (empty = none; when non-empty
  /// the length must match the frame count).
  a53~ : Array[Bytes?] = [],
  sei_unregistered~ : Array[Bytes?] = [],
  /// §428: stereo frame packing layout written with the IDR
  /// (0 = off; an av_stereo3d_* value).
  stereo3d~ : Int32 = 0,
  /// `§429`: per-macroblock ROI quantisation offsets for every picture
  /// (ignored when `aq=false`; see `h264_encode_intra_frame_cabac`).
  roi~ : Array[H264Roi] = [],
  /// `§430`: per-display-position motion hints (`H264VideoHint`); empty =
  /// none, when non-empty the length must match the frame count.
  hints~ : Array[H264VideoHint?] = [],
  /// `§431`: per-display-position type requests (`h264_pict_type_*`).
  /// Empty reproduces the default schedule byte for byte; non-empty must
  /// match the frame count. Forced types need a plain sequence (no
  /// `target_bytes` / VBV) and `b_slices` for `B`.
  pict_types~ : Array[Int32] = [],
) -> Result[Bytes, String] {
  if aq_strength < 0 || aq_strength > 6 {
    return Err("h264 enc: aq_strength must be in 0..=6")
  }
  if chroma_format < 1 || chroma_format > 3 {
    return Err("h264 enc: chroma_format must be 1, 2 or 3")
  }
  if chroma_qp_offset < -12 || chroma_qp_offset > 12 {
    return Err("h264 enc: chroma_qp_offset must be in -12..=12")
  }
  match h264_enc_deblock_offsets_ok(deblock, deblock_alpha, deblock_beta) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match h264_pict_types_validate(pict_types, frames.length()) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if h264_pict_types_forced(pict_types) &&
    (
      target_bytes > 0 ||
      vbv_maxrate > 0 ||
      vbv_bufsize > 0 ||
      fps > 0 ||
      crf >= 0.0
    ) {
    return Err(
      "h264 enc: pict_types is not supported with target_bytes or VBV (use the streaming encoder)",
    )
  }
  if crf > 51.0 {
    return Err("h264 enc: crf must be in 0.0..=51.0")
  }
  if crf >= 0.0 && target_bytes > 0 {
    return Err("h264 enc: crf and target_bytes are mutually exclusive")
  }
  if (a53.length() > 0 && a53.length() != frames.length()) ||
    (
      sei_unregistered.length() > 0 &&
      sei_unregistered.length() != frames.length()
    ) ||
    (hints.length() > 0 && hints.length() != frames.length()) {
    return Err(
      "h264 enc: side data arrays must be empty or match the frame count (\{frames.length()})",
    )
  }
  if !h264_enc_bit_depth_ok(bit_depth) {
    return Err(
      "h264 enc: unsupported bit depth \{bit_depth} (8, 9, 10, 12 or 14)",
    )
  }
  if frames.length() == 0 {
    return Err("h264 enc: no frames")
  }
  if multi_ref < 1 || multi_ref > 16 {
    return Err("h264 enc: multi_ref must be in 1..=16")
  }
  // `b_slices` defaults on (`§403`); a one-frame sequence can never hold a
  // B picture, so it degrades to the I-only stream instead of erroring.
  let b_slices = b_slices && frames.length() >= 2
  // `§435`: display-position CRF QPs (same causal recurrence as the
  // streaming encoder — see `h264_encode_frames`).
  let crf_qps = if crf >= 0.0 {
    h264_enc_crf_qps(frames, height, crf)
  } else {
    []
  }
  if b_slices {
    let vbv_b = if vbv_maxrate > 0 || vbv_bufsize > 0 || fps > 0 {
      if target_bytes > 0 {
        return Err("h264 enc: target_bytes and vbv are mutually exclusive")
      }
      match h264_vbv_new(vbv_maxrate, vbv_bufsize, fps, vbv_init) {
        Ok(v) => Some(v)
        Err(e) => return Err(e)
      }
    } else {
      None
    }
    if target_bytes > 0 {
      let qps = match
        h264_rc_solve(frames.length(), qp, target_bytes, fn(trial) {
          match
            h264_encode_frames_b(
              frames,
              width~,
              height~,
              qp~,
              level_idc~,
              aq~,
              aq_strength~,
              aud~,
              cabac=true,
              cabac_rd~,
              b_parts~,
              intra_in_b~,
              intra4x4_in_b~,
              dct8x8~,
              multi_ref~,
              chroma_format~,
              chroma_qp_offset~,
              qps=trial,
              recon=[],
              stats=H264EncStats::new(),
              weightp~,
              weightp_b~,
              bit_depth~,
              deblock~,
              deblock_alpha~,
              deblock_beta~,
              sar~,
              a53~,
              sei_unregistered~,
              stereo3d~,
              roi~,
              hints~,
            ) {
            Ok((bytes, _)) => Ok(bytes.length())
            Err(e) => Err(e)
          }
        }) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      return match
        h264_encode_frames_b(
          frames,
          width~,
          height~,
          qp~,
          level_idc~,
          aq~,
          aq_strength~,
          aud~,
          cabac=true,
          cabac_rd~,
          b_parts~,
          intra_in_b~,
          intra4x4_in_b~,
          dct8x8~,
          multi_ref~,
          chroma_format~,
          chroma_qp_offset~,
          qps~,
          recon~,
          stats~,
          weightp~,
          weightp_b~,
          bit_depth~,
          deblock~,
          deblock_alpha~,
          deblock_beta~,
          sar~,
          a53~,
          sei_unregistered~,
          stereo3d~,
          roi~,
          hints~,
        ) {
        Ok((bytes, _)) => Ok(bytes)
        Err(e) => Err(e)
      }
    }
    match vbv_b {
      Some(v) => {
        let (qps, sizes) = match
          h264_vbv_solve(
            frames.length(),
            qp,
            v,
            fn(trial) {
              match
                h264_encode_frames_b(
                  frames,
                  width~,
                  height~,
                  qp~,
                  level_idc~,
                  aq~,
                  aq_strength~,
                  aud~,
                  cabac=true,
                  cabac_rd~,
                  b_parts~,
                  intra_in_b~,
                  intra4x4_in_b~,
                  dct8x8~,
                  multi_ref~,
                  chroma_format~,
                  chroma_qp_offset~,
                  qps=trial,
                  recon=[],
                  stats=H264EncStats::new(),
                  vbv=Some(v),
                  weightp~,
                  weightp_b~,
                  bit_depth~,
                  deblock~,
                  deblock_alpha~,
                  deblock_beta~,
                  sar~,
                  a53~,
                  sei_unregistered~,
                  stereo3d~,
                  roi~,
                  hints~,
                ) {
                Ok((_, sizes)) => Ok(sizes)
                Err(e) => Err(e)
              }
            },
            coding_order=h264_b_coding_order(frames.length()),
            start_qps=crf_qps,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let fillers = h264_vbv_fillers(frames.length(), sizes, v)
        return match
          h264_encode_frames_b(
            frames,
            width~,
            height~,
            qp~,
            level_idc~,
            aq~,
            aq_strength~,
            aud~,
            cabac=true,
            cabac_rd~,
            b_parts~,
            intra_in_b~,
            intra4x4_in_b~,
            dct8x8~,
            multi_ref~,
            chroma_format~,
            chroma_qp_offset~,
            qps~,
            vbv=Some(v),
            fillers~,
            recon~,
            stats~,
            weightp~,
            weightp_b~,
            bit_depth~,
            deblock~,
            deblock_alpha~,
            deblock_beta~,
            sar~,
            a53~,
            sei_unregistered~,
            stereo3d~,
            roi~,
            hints~,
          ) {
          Ok((bytes, _)) => {
            stats.vbv_bits = bytes.length().to_int64() * 8L
            for f = 0; f < frames.length(); f = f + 1 {
              if fillers[f] > 0 {
                stats.vbv_fills += 1
                stats.vbv_filler_bytes += fillers[f]
              }
            }
            Ok(bytes)
          }
          Err(e) => Err(e)
        }
      }
      None => ()
    }
    return match
      h264_encode_frames_b(
        frames,
        width~,
        height~,
        qp~,
        level_idc~,
        aq~,
        aq_strength~,
        aud~,
        cabac=true,
        cabac_rd~,
        b_parts~,
        intra_in_b~,
        intra4x4_in_b~,
        dct8x8~,
        multi_ref~,
        chroma_format~,
        chroma_qp_offset~,
        qps=crf_qps,
        recon~,
        stats~,
        weightp~,
        weightp_b~,
        bit_depth~,
        deblock~,
        deblock_alpha~,
        deblock_beta~,
        sar~,
        a53~,
        sei_unregistered~,
        stereo3d~,
        roi~,
        hints~,
        pict_types~,
      ) {
      Ok((bytes, _)) => Ok(bytes)
      Err(e) => Err(e)
    }
  }
  let n = frames.length()
  // VBV/CBR is opt-in and cannot be combined with the average-bitrate
  // target; see the CAVLC entry for the shared contract.
  let vbv = if vbv_maxrate > 0 || vbv_bufsize > 0 || fps > 0 {
    if target_bytes > 0 {
      return Err("h264 enc: target_bytes and vbv are mutually exclusive")
    }
    match h264_vbv_new(vbv_maxrate, vbv_bufsize, fps, vbv_init) {
      Ok(v) => Some(v)
      Err(e) => return Err(e)
    }
  } else {
    None
  }
  match vbv {
    Some(v) =>
      return h264_encode_frames_vbv_cabac(
        frames,
        width~,
        height~,
        qp~,
        level_idc~,
        intra_in_p~,
        intra4x4_in_p~,
        dct8x8~,
        aq~,
        aq_strength~,
        cabac_rd~,
        aud~,
        vbv=v,
        crf_qps~,
        recon~,
        stats~,
        weightp~,
        bit_depth~,
        multi_ref~,
        chroma_format~,
        chroma_qp_offset~,
        deblock~,
        deblock_alpha~,
        deblock_beta~,
        sar~,
        a53~,
        sei_unregistered~,
        stereo3d~,
        roi~,
        hints~,
      )
    None => ()
  }
  // Same contract as the CAVLC entry's `target_bytes`: the two-pass
  // average-bitrate control over `h264_encode_frames_cabac_qps`, with `qp`
  // as the search start and the PPS base. Off, flat QP byte-identically.
  let qps = if target_bytes > 0 {
    match
      h264_rc_solve(n, qp, target_bytes, fn(trial) {
        match
          h264_encode_frames_cabac_qps(
            frames,
            width~,
            height~,
            base_qp=qp,
            qps=trial,
            level_idc~,
            intra_in_p~,
            intra4x4_in_p~,
            dct8x8~,
            aq~,
            aq_strength~,
            cabac_rd~,
            aud~,
            recon=[],
            stats=H264EncStats::new(),
            weightp~,
            bit_depth~,
            multi_ref~,
            chroma_format~,
            chroma_qp_offset~,
            deblock~,
            deblock_alpha~,
            deblock_beta~,
            sar~,
            a53~,
            sei_unregistered~,
            stereo3d~,
            roi~,
            hints~,
          ) {
          Ok((bytes, _)) => Ok(bytes.length())
          Err(e) => Err(e)
        }
      }) {
      Ok(q) => q
      Err(e) => return Err(e)
    }
  } else if crf >= 0.0 {
    crf_qps
  } else {
    Array::make(n, qp)
  }
  for q in qps {
    stats.frame_qps.push(q)
  }
  match
    h264_encode_frames_cabac_qps(
      frames,
      width~,
      height~,
      base_qp=qp,
      qps~,
      level_idc~,
      intra_in_p~,
      intra4x4_in_p~,
      dct8x8~,
      aq~,
      aq_strength~,
      cabac_rd~,
      aud~,
      recon~,
      stats~,
      weightp~,
      bit_depth~,
      multi_ref~,
      chroma_format~,
      chroma_qp_offset~,
      deblock~,
      deblock_alpha~,
      deblock_beta~,
      sar~,
      a53~,
      sei_unregistered~,
      stereo3d~,
      roi~,
      hints~,
      pict_types~,
    ) {
    Ok((bytes, _)) => Ok(bytes)
    Err(e) => Err(e)
  }
}

///|
/// The CABAC twin of `h264_encode_frames_vbv`: assign per-picture QPs under
/// the CPB constraint with real prefix encodes, then emit the stream with
/// filler-data NALs. See `h264_vbv_solve` / `h264_vbv_fillers`.
fn h264_encode_frames_vbv_cabac(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32,
  level_idc~ : Int32,
  intra_in_p~ : Bool,
  intra4x4_in_p~ : Bool,
  dct8x8~ : Bool,
  aq~ : Bool,
  aq_strength~ : Int32,
  cabac_rd~ : Bool,
  aud~ : Bool,
  vbv~ : H264Vbv,
  /// `§435`: CRF starting assignment (see `h264_encode_frames_vbv`).
  crf_qps~ : Array[Int32] = [],
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
  /// `§410`: explicit P weighted prediction (see `h264_encode_frames_cabac`).
  weightp~ : Bool = false,
  /// `§434`: explicit B weighted prediction (see `h264_encode_frames_cabac`).
  /// `§412`: bit depth (see `h264_encode_frames_cabac`).
  bit_depth~ : Int32 = 8,
  multi_ref~ : Int32 = 1,
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset (see `h264_encode_frames_cabac`).
  chroma_qp_offset~ : Int32 = 0,
  /// `§423`: in-loop deblocking (see `h264_encode_frames_cabac`).
  deblock~ : Bool = false,
  deblock_alpha~ : Int32 = 0,
  deblock_beta~ : Int32 = 0,
  /// `§426`: sample aspect ratio for the SPS VUI (0/0 = unset).
  sar~ : (Int32, Int32) = (0, 0),
  /// `§427`: per-display-position side data (see `h264_encode_frames_cabac`).
  a53~ : Array[Bytes?] = [],
  sei_unregistered~ : Array[Bytes?] = [],
  /// §428: stereo frame packing layout written with the IDR
  /// (0 = off; an av_stereo3d_* value).
  stereo3d~ : Int32 = 0,
  /// `§429`: ROI map for every picture (see `h264_encode_frames_cabac`).
  roi~ : Array[H264Roi] = [],
  /// `§430`: per-display-position motion hints (see
  /// `h264_encode_frames_cabac`).
  hints~ : Array[H264VideoHint?] = [],
) -> Result[Bytes, String] {
  let n = frames.length()
  let (qps, sizes) = match
    h264_vbv_solve(
      n,
      qp,
      vbv,
      fn(trial) {
        match
          h264_encode_frames_cabac_qps(
            frames,
            width~,
            height~,
            base_qp=qp,
            qps=trial,
            level_idc~,
            intra_in_p~,
            intra4x4_in_p~,
            dct8x8~,
            aq~,
            aq_strength~,
            cabac_rd~,
            aud~,
            recon=[],
            stats=H264EncStats::new(),
            vbv=Some(vbv),
            weightp~,
            bit_depth~,
            multi_ref~,
            chroma_format~,
            deblock~,
            deblock_alpha~,
            deblock_beta~,
            sar~,
            a53~,
            sei_unregistered~,
            stereo3d~,
            roi~,
            hints~,
          ) {
          Ok((_, sizes)) => Ok(sizes)
          Err(e) => Err(e)
        }
      },
      start_qps=crf_qps,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let fillers = h264_vbv_fillers(n, sizes, vbv)
  for q in qps {
    stats.frame_qps.push(q)
  }
  match
    h264_encode_frames_cabac_qps(
      frames,
      width~,
      height~,
      base_qp=qp,
      qps~,
      level_idc~,
      intra_in_p~,
      intra4x4_in_p~,
      dct8x8~,
      aq~,
      aq_strength~,
      cabac_rd~,
      recon~,
      stats~,
      vbv=Some(vbv),
      fillers~,
      aud~,
      weightp~,
      bit_depth~,
      multi_ref~,
      chroma_format~,
      chroma_qp_offset~,
      deblock~,
      deblock_alpha~,
      deblock_beta~,
      sar~,
      a53~,
      sei_unregistered~,
      stereo3d~,
      roi~,
      hints~,
    ) {
    Ok((bytes, _)) => {
      stats.vbv_bits = bytes.length().to_int64() * 8L
      for f = 0; f < n; f = f + 1 {
        if fillers[f] > 0 {
          stats.vbv_fills += 1
          stats.vbv_filler_bytes += fillers[f]
        }
      }
      Ok(bytes)
    }
    Err(e) => Err(e)
  }
}

///|
/// The CABAC sequence encoder proper: picture `f` codes at `qps[f]`
/// against the single PPS whose `pic_init_qp` is `base_qp`. Returns the
/// Annex B stream and the byte size of every access unit (the first
/// includes SPS + PPS).
fn h264_encode_frames_cabac_qps(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  base_qp~ : Int32,
  qps~ : Array[Int32],
  level_idc~ : Int32,
  intra_in_p~ : Bool,
  intra4x4_in_p~ : Bool,
  dct8x8~ : Bool,
  aq~ : Bool,
  aq_strength~ : Int32,
  cabac_rd~ : Bool = false,
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
  vbv~ : H264Vbv? = None,
  idr_cpb_delay~ : Int32 = 0,
  fillers~ : Array[Int32] = [],
  aud~ : Bool = false,
  /// `§410`: explicit P weighted prediction (see `h264_encode_frames_cabac`).
  weightp~ : Bool = false,
  /// `§434`: explicit B weighted prediction (see `h264_encode_frames_cabac`).
  /// `§412`: bit depth (see `h264_encode_frames_cabac`).
  bit_depth~ : Int32 = 8,
  /// `§415`: P-slice multi-reference history depth.
  multi_ref~ : Int32 = 1,
  /// `§420`: chroma format (see `h264_encode_frames_cabac`).
  chroma_format~ : Int32 = 1,
  /// `§432`: Cb/Cr chroma QP offset (see `h264_encode_frames_cabac`).
  chroma_qp_offset~ : Int32 = 0,
  /// `§423`: in-loop deblocking (see `h264_encode_frames_cabac`).
  deblock~ : Bool = false,
  deblock_alpha~ : Int32 = 0,
  deblock_beta~ : Int32 = 0,
  /// `§426`: sample aspect ratio for the SPS VUI (0/0 = unset).
  sar~ : (Int32, Int32) = (0, 0),
  /// `§427`: per-display-position side data (see `h264_encode_frames_cabac`).
  a53~ : Array[Bytes?] = [],
  sei_unregistered~ : Array[Bytes?] = [],
  /// §428: stereo frame packing layout written with the IDR
  /// (0 = off; an av_stereo3d_* value).
  stereo3d~ : Int32 = 0,
  /// `§429`: ROI map for every picture (see `h264_encode_frames_cabac`).
  roi~ : Array[H264Roi] = [],
  /// `§430`: per-display-position motion hints (see
  /// `h264_encode_frames_cabac`).
  hints~ : Array[H264VideoHint?] = [],
  /// `§431`: per-display-position type requests (see
  /// `h264_encode_frames_cabac`).
  pict_types~ : Array[Int32] = [],
) -> Result[(Bytes, Array[Int32]), String] {
  let (y0, u0, v0) = frames[0]
  let first = match
    h264_encode_intra_frame_cabac(
      y0,
      u0,
      v0,
      width~,
      height~,
      qp=qps[0],
      level_idc~,
      dct8x8~,
      stats~,
      pps_qp=base_qp,
      aq~,
      aq_strength~,
      vbv~,
      idr_cpb_delay~,
      weightp~,
      bit_depth~,
      multi_ref~,
      chroma_format~,
      chroma_qp_offset~,
      deblock~,
      deblock_alpha~,
      deblock_beta~,
      sar~,
      a53=h264_enc_sei_pick(a53, 0),
      sei_unregistered=h264_enc_sei_pick(sei_unregistered, 0),
      stereo3d~,
      roi~,
    ) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let p = {
    width,
    height,
    qp: base_qp,
    level_idc,
    bit_depth,
    nrefs: multi_ref,
    sar,
    deblock_alpha,
    deblock_beta,
    weightp_b: false,
  }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * (if chroma_format == 3 { 16 } else { 8 })
  let pheight = mb_height * 16
  // `§420`: 4:2:2 keeps the full chroma height, 4:2:0 halves it.
  let chroma_plane_h = if chroma_format != 1 { pheight } else { pheight / 2 }
  let chroma_w = if chroma_format == 3 { width } else { width / 2 }
  let chroma_h = if chroma_format == 1 { height / 2 } else { height }
  let ps = new_h264_param_sets()
  let sps_rbsp = if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
    h264_enc_sps_rbsp_high(p, vbv~, chroma_format~)
  } else {
    h264_enc_sps_rbsp_main(p, vbv~)
  }
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_rbsp), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = h264_enc_pps_rbsp_cabac(
    p,
    dct8x8~,
    weightp~,
    chroma_format~,
    chroma_qp_offset~,
  )
  match
    ff_h264_decode_picture_parameter_set(
      BitReader::new(pps_raw),
      ps,
      pps_raw.length() * 8,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: PPS round-trip failed: \{e}")
  }
  let pps = match ps.pps_list[0] {
    Some(v) => v
    None => return Err("h264 enc: no PPS after round-trip")
  }
  // `§429`: one ROI map expands to per-MB QP offsets (empty when AQ is off).
  let roi_off = match
    h264_roi_offsets_for(roi, aq, mb_width, mb_height, bit_depth) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let stream : Array[Bytes] = []
  if fillers.length() > 0 && fillers[0] > 0 {
    stream.push(
      h264_enc_concat([first.annexb, h264_enc_filler_nal(fillers[0] - 5)]),
    )
  } else {
    stream.push(first.annexb)
  }
  if aud {
    stream[0] = h264_enc_concat([h264_enc_aud(true), stream[0]])
  }
  let mut ref_y = Array::make(ystride * pheight, 0)
  let mut ref_u = Array::make(cstride * chroma_plane_h, 0)
  let mut ref_v = Array::make(cstride * chroma_plane_h, 0)
  let refs_y : Array[Array[Int32]] = []
  let refs_u : Array[Array[Int32]] = []
  let refs_v : Array[Array[Int32]] = []
  for row = 0; row < pheight; row = row + 1 {
    for col = 0; col < ystride; col = col + 1 {
      ref_y[row * ystride + col] = first.recon_y[row * ystride + col]
    }
  }
  for row = 0; row < chroma_plane_h; row = row + 1 {
    for col = 0; col < cstride; col = col + 1 {
      ref_u[row * cstride + col] = first.recon_u[row * cstride + col]
      ref_v[row * cstride + col] = first.recon_v[row * cstride + col]
    }
  }
  let states : Array[H264PMbState] = []
  for k = 0; k < mb_width * mb_height; k = k + 1 {
    states.push(new_h264_p_mb_state())
  }
  for k = 0; k < mb_width * mb_height; k = k + 1 {
    for i = 0; i < 48; i = i + 1 {
      states[k].nz[i] = first.mb_nz[k][i]
    }
  }
  refs_y.push(ref_y)
  refs_u.push(ref_u)
  refs_v.push(ref_v)
  // `§431`: this schedule codes in display order (no B pictures), so a
  // forced type replaces this position's writer. All-`Auto` keeps the
  // historical loop's frame numbering (`fn_counter == f`).
  let requests = if pict_types.length() == frames.length() {
    pict_types
  } else {
    Array::make(frames.length(), h264_pict_type_auto)
  }
  let plan = match h264_pict_type_plan(requests, false) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let mut fn_counter = 0
  for (f, kind) in plan[1:] {
    if kind == h264_pict_type_idr {
      // ---- mid-sequence IDR: repeated parameter sets, new GOP ----
      let (y, u, v) = frames[f]
      let intra = match
        h264_encode_intra_frame_cabac(
          y,
          u,
          v,
          width~,
          height~,
          qp=qps[f],
          level_idc~,
          dct8x8~,
          stats~,
          pps_qp=base_qp,
          aq~,
          aq_strength~,
          weightp~,
          bit_depth~,
          multi_ref~,
          chroma_format~,
          deblock~,
          deblock_alpha~,
          deblock_beta~,
          sar~,
          a53=h264_enc_sei_pick(a53, f),
          sei_unregistered=h264_enc_sei_pick(sei_unregistered, f),
          stereo3d~,
          roi~,
          idr=true,
        ) {
        Ok(e2) => e2
        Err(e2) => return Err(e2)
      }
      let au : Array[Bytes] = [intra.annexb]
      if fillers.length() > f && fillers[f] > 0 {
        au.push(h264_enc_filler_nal(fillers[f] - 5))
      }
      if aud {
        au.insert(0, h264_enc_aud(true))
      }
      stream.push(h264_enc_concat(au))
      ref_y = h264_b_copy_plane(intra.recon_y)
      ref_u = h264_b_copy_plane(intra.recon_u)
      ref_v = h264_b_copy_plane(intra.recon_v)
      refs_y.clear()
      refs_y.push(ref_y)
      refs_u.clear()
      refs_u.push(ref_u)
      refs_v.clear()
      refs_v.push(ref_v)
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        states[k] = new_h264_p_mb_state()
        for i = 0; i < 48; i = i + 1 {
          states[k].nz[i] = intra.mb_nz[k][i]
        }
      }
      fn_counter = 0
    } else if kind == h264_pict_type_keyframe {
      // ---- non-IDR open-GOP I picture: new prediction chain ----
      let (y, u, v) = frames[f]
      fn_counter = fn_counter + 1
      let intra = match
        h264_encode_intra_frame_cabac(
          y,
          u,
          v,
          width~,
          height~,
          qp=qps[f],
          level_idc~,
          dct8x8~,
          stats~,
          pps_qp=base_qp,
          aq~,
          aq_strength~,
          weightp~,
          bit_depth~,
          multi_ref~,
          chroma_format~,
          deblock~,
          deblock_alpha~,
          deblock_beta~,
          sar~,
          a53=h264_enc_sei_pick(a53, f),
          sei_unregistered=h264_enc_sei_pick(sei_unregistered, f),
          stereo3d~,
          roi~,
          idr=false,
          frame_num=fn_counter,
        ) {
        Ok(e2) => e2
        Err(e2) => return Err(e2)
      }
      let au : Array[Bytes] = [intra.annexb]
      if fillers.length() > f && fillers[f] > 0 {
        au.push(h264_enc_filler_nal(fillers[f] - 5))
      }
      if aud {
        au.insert(0, h264_enc_aud(true))
      }
      stream.push(h264_enc_concat(au))
      recon.push(
        h264_enc_pack_recon(
          intra.recon_y,
          intra.recon_u,
          intra.recon_v,
          width,
          height,
          ystride,
          cstride,
          bit_depth~,
          chroma_w~,
          chroma_h~,
        ),
      )
      let i_y = h264_b_copy_plane(intra.recon_y)
      let i_u = h264_b_copy_plane(intra.recon_u)
      let i_v = h264_b_copy_plane(intra.recon_v)
      ref_y = i_y
      ref_u = i_u
      ref_v = i_v
      refs_y.insert(0, i_y)
      refs_u.insert(0, i_u)
      refs_v.insert(0, i_v)
      if refs_y.length() > multi_ref {
        refs_y.truncate(multi_ref)
        refs_u.truncate(multi_ref)
        refs_v.truncate(multi_ref)
      }
      for k = 0; k < mb_width * mb_height; k = k + 1 {
        states[k] = new_h264_p_mb_state()
        for i = 0; i < 48; i = i + 1 {
          states[k].nz[i] = intra.mb_nz[k][i]
        }
      }
    } else {
      fn_counter = fn_counter + 1
      let (y, u, v) = frames[f]
      let src_y_p = h264_enc_load_plane(
        y,
        width,
        height,
        ystride,
        pheight,
        bit_depth~,
      )
      let (act, act_avg) = if aq {
        h264_aq_measure(src_y_p, ystride, mb_width, mb_height)
      } else {
        (Array::make(mb_width * mb_height, 0), 0)
      }
      // `§430`: this picture's motion hint expanded to per-MB skip flags.
      let hint_const = match
        h264_hint_constants(h264_hint_at(hints, f), mb_width, mb_height) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let enc : H264PEncoder = {
        p: {
          width,
          height,
          qp: qps[f],
          level_idc,
          bit_depth,
          nrefs: multi_ref,
          sar,
          deblock_alpha,
          deblock_beta,
          weightp_b: false,
        },
        stats,
        pps,
        chroma_qp: h264_get_chroma_qp(pps, 0, p.qp_ext(qps[f]), bit_depth~),
        src_y: src_y_p,
        src_u: h264_enc_load_plane(
          u,
          chroma_w,
          chroma_h,
          cstride,
          chroma_plane_h,
          bit_depth~,
        ),
        src_v: h264_enc_load_plane(
          v,
          chroma_w,
          chroma_h,
          cstride,
          chroma_plane_h,
          bit_depth~,
        ),
        rec_y: Array::make(ystride * pheight, 0),
        rec_u: Array::make(cstride * chroma_plane_h, 0),
        rec_v: Array::make(cstride * chroma_plane_h, 0),
        ref_y,
        ref_u,
        ref_v,
        refs_y,
        refs_u,
        refs_v,
        nrefs: refs_y.length(),
        cur_ref_mb: 0,
        ystride,
        cstride,
        pwidth: ystride,
        pheight,
        mb_width,
        mb_height,
        states,
        cur_nz: Array::make(48, 0),
        cur_mv: Array::make(32, 0),
        cur_ref: Array::make(16, -2),
        dct8x8,
        intra4x4_in_p,
        base_qp,
        mb_qp: qps[f],
        mb_dqp: 0,
        prev_qp: qps[f],
        aq_act: act,
        aq_avg: act_avg,
        aq_on: aq,
        aq_strength,
        roi_off,
        hint_const,
        cabac_rd,
        price_mirror: None,
        price_enc: None,
        price_states: None,
        b_parts: false,
        intra_in_b: false,
        intra4x4_in_b: false,
        weightp,
        pwt: new_h264_pred_weight(),
        deblock,
      }
      let nal = match enc.encode_p_frame_cabac(fn_counter, intra_in_p) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
      let au : Array[Bytes] = []
      match vbv {
        None => ()
        Some(v) => au.push(h264_enc_sei_pic_timing(v, f * 2))
      }
      match
        h264_enc_sei_side_data_nals(
          h264_enc_sei_pick(a53, f),
          h264_enc_sei_pick(sei_unregistered, f),
        ) {
        Ok(nals) =>
          for sei_nal in nals {
            au.push(sei_nal)
          }
        Err(e) => return Err(e)
      }
      au.push(nal)
      if fillers.length() > f && fillers[f] > 0 {
        au.push(h264_enc_filler_nal(fillers[f] - 5))
      }
      if aud {
        au.insert(0, h264_enc_aud(false))
      }
      stream.push(h264_enc_concat(au))
      recon.push(
        h264_enc_pack_recon(
          enc.rec_y,
          enc.rec_u,
          enc.rec_v,
          width,
          height,
          ystride,
          cstride,
          bit_depth~,
          chroma_w~,
          chroma_h~,
        ),
      )
      let next_y = Array::make(ystride * pheight, 0)
      let next_u = Array::make(cstride * chroma_plane_h, 0)
      let next_v = Array::make(cstride * chroma_plane_h, 0)
      for row = 0; row < pheight; row = row + 1 {
        for col = 0; col < ystride; col = col + 1 {
          next_y[row * ystride + col] = enc.rec_y[row * ystride + col]
        }
      }
      for row = 0; row < chroma_plane_h; row = row + 1 {
        for col = 0; col < cstride; col = col + 1 {
          next_u[row * cstride + col] = enc.rec_u[row * cstride + col]
          next_v[row * cstride + col] = enc.rec_v[row * cstride + col]
        }
      }
      ref_y = next_y
      ref_u = next_u
      ref_v = next_v
      // `§416`: the CABAC batch entry kept a single reference forever — the
      // P pictures never saw the multi-ref history the streaming entry (and
      // the CAVLC entry) maintain. Rotate exactly like them: newest first,
      // capped at the requested depth.
      refs_y.insert(0, next_y)
      refs_u.insert(0, next_u)
      refs_v.insert(0, next_v)
      if refs_y.length() > multi_ref {
        refs_y.truncate(multi_ref)
        refs_u.truncate(multi_ref)
        refs_v.truncate(multi_ref)
      }
    }
  }
  let out : Array[Byte] = []
  let sizes : Array[Int32] = []
  for part in stream {
    sizes.push(part.length())
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Ok((Bytes::from_array(out[:]), sizes))
}
