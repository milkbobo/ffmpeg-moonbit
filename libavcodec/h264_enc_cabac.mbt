///|
/// Pure-MoonBit H.264 CABAC encoder, slice 3 of the port: Main profile
/// (profile_idc 77), 4:2:0 8-bit, flat QP, single slice, one reference.
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
/// encoder (`decide_plan`). Single L0 reference, so no `ref_idx` syntax;
/// flat QP, so `mb_qp_delta` is always the zero bin (the decoder reads it
/// when cbp != 0 or the macroblock is I16x16).

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
  qp : Int32,
  slice_type_nos : Int32,
  ystride : Int32,
  cstride : Int32,
  pheight : Int32,
) -> H264DecCtx {
  let infos : Array[H264MbInfo] = []
  for _k = 0; _k < mb_width * mb_height; _k = _k + 1 {
    infos.push(h264_new_mb_info())
  }
  let refpic : H264RefPic = {
    identity: 0,
    y: Array::make(ystride * pheight, 0),
    u: Array::make(cstride * (pheight / 2), 0),
    v: Array::make(cstride * (pheight / 2), 0),
    ystride,
    cstride,
    width: ystride,
    height: pheight,
    cwidth: cstride,
    cheight: pheight / 2,
    poc: 0,
    field_poc_top: 0,
    field_poc_bottom: 0,
    base_y: 0,
    base_u: 0,
    base_v: 0,
    parity: 0,
  }
  {
    bit_depth: 8,
    chroma_format: 1,
    chroma_hshift: 1,
    chroma_vshift: 1,
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
    u: Array::make(cstride * (pheight / 2), 0),
    v: Array::make(cstride * (pheight / 2), 0),
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
  // Coded-block flag (8x8DCT luma is the only implied case and this
  // encoder is 4x4-only).
  let cbf_ctx = h264_cabac_cbf_ctx(ctx, mb_idx, mb_x, mb_y, cat, n, nz)
  enc.decision(states, cbf_ctx, if count > 0 { 1 } else { 0 })
  if count == 0 {
    // `fill_rectangle(non_zero_count_cache[...], 0)`: the block's nz slot
    // is zeroed for the AC/grid categories, DC blocks leave it alone.
    if !is_dc {
      if cat == 1 || cat == 2 || cat >= 6 {
        nz[16 * h264_cabac_cat_plane(cat) + h264_luma_block_grid[n & 15]] = 0
      } else {
        nz[n] = 0
      }
    }
    return
  }
  let sig_base = h264_cabac_significant_coeff_offset[cat]
  let last_base = h264_cabac_last_coeff_flag_offset[cat]
  // Significance map: sig/last bins for positions 0..max-2; the last scan
  // position is implied when no `last` flag fired.
  let coefs = max_coeff - 1
  let mut q = 0
  while q < coefs {
    if view[q] != 0 {
      enc.decision(states, sig_base + q, 1)
      if q == last_pos {
        enc.decision(states, last_base + q, 1)
        // `last = max_coeff` on the decode side: stop.
        q = coefs
        continue
      } else {
        enc.decision(states, last_base + q, 0)
      }
    } else {
      enc.decision(states, sig_base + q, 0)
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
  } else if cat == 1 || cat == 2 || cat >= 6 {
    nz[16 * h264_cabac_cat_plane(cat) + h264_luma_block_grid[n & 15]] = count
  } else {
    nz[n] = count
  }
  // Absolute levels, reverse scan order.
  let abs_base = h264_cabac_coeff_abs_level_m1_offset[cat]
  let gt1 = h264_cabac_coeff_abs_levelgt1_ctx[0]
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
fn h264_enc_sps_rbsp_main(p : H264EncParams) -> Bytes {
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
  r.put_ue(1) // max_num_ref_frames
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
  r.put_bit(0) // vui_parameters_present_flag
  r.trailing_bits()
  r.finish_raw_of()
}

///|
/// CABAC PPS RBSP: identical to the CAVLC PPS except
/// `entropy_coding_mode_flag = 1`.
fn h264_enc_pps_rbsp_cabac(p : H264EncParams) -> Bytes {
  let r = H264Rbsp::new()
  r.put_ue(0) // pic_parameter_set_id
  r.put_ue(0) // seq_parameter_set_id
  r.put_bit(1) // entropy_coding_mode_flag: CABAC
  r.put_bit(0) // bottom_field_pic_order_in_frame_present_flag
  r.put_ue(0) // num_slice_groups_minus1
  r.put_ue(0) // num_ref_idx_l0_default_active_minus1
  r.put_ue(0) // num_ref_idx_l1_default_active_minus1
  r.put_bit(0) // weighted_pred_flag
  r.put(0, 2) // weighted_bipred_idc
  r.put_se(p.qp - 26) // pic_init_qp_minus26
  r.put_se(0) // pic_init_qs_minus26
  r.put_se(0) // chroma_qp_index_offset
  r.put_bit(0) // deblocking_filter_control_present_flag
  r.put_bit(0) // constrained_intra_pred_flag
  r.put_bit(0) // redundant_pic_cnt_present_flag
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
  chroma_qp : Int32
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
}

///|
/// Encode one IDR I-frame with CABAC entropy coding (Main profile). Same
/// contract as `h264_encode_intra_frame`; the PPS carries
/// `entropy_coding_mode_flag = 1` and the SPS is Main profile.
pub fn h264_encode_intra_frame_cabac(
  y : Bytes,
  u : Bytes,
  v : Bytes,
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
) -> Result[H264EncodedFrame, String] {
  if width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0 {
    return Err("h264 enc: invalid geometry \{width}x\{height}")
  }
  if qp < 0 || qp > 51 {
    return Err("h264 enc: qp out of range")
  }
  if y.length() != width * height ||
    u.length() != width / 2 * (height / 2) ||
    v.length() != width / 2 * (height / 2) {
    return Err("h264 enc: plane size mismatch")
  }
  let p = { width, height, qp, level_idc, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  let ps = new_h264_param_sets()
  let sps_nal = {
    let raw = h264_enc_sps_rbsp_main(p)
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
    let raw = h264_enc_pps_rbsp_cabac(p)
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
  match
    ff_h264_decode_seq_parameter_set(
      BitReader::new(h264_enc_sps_rbsp_main(p)),
      ps,
      false,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = h264_enc_pps_rbsp_cabac(p)
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
  let chroma_qp = h264_get_chroma_qp(pps, 0, qp)
  fn load_plane(
    src : Bytes,
    w : Int32,
    h : Int32,
    stride : Int32,
    plane_h : Int32,
  ) -> Array[Int32] {
    let plane : Array[Int32] = Array::make(stride * plane_h, 0)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        plane[row * stride + col] = src[row * w + col].to_int()
      }
    }
    plane
  }
  let self_ : H264CabacIEnc = {
    p,
    pps,
    chroma_qp,
    src_y: load_plane(y, width, height, ystride, pheight),
    src_u: load_plane(u, width / 2, height / 2, cstride, pheight / 2),
    src_v: load_plane(v, width / 2, height / 2, cstride, pheight / 2),
    rec_y: Array::make(ystride * pheight, 0),
    rec_u: Array::make(cstride * (pheight / 2), 0),
    rec_v: Array::make(cstride * (pheight / 2), 0),
    ystride,
    cstride,
    mb_width,
    ctx: h264_cabac_mirror_new(
      mb_width, mb_height, pps, qp, 2, ystride, cstride, pheight,
    ),
    enc: h264_cabac_enc_new(),
    states: ff_h264_init_cabac_states(qp, 8, 2, 0),
    cur_modes: Array::make(16, 0),
  }
  // Slice header (POC type 2: no POC syntax).
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(7) // slice_type: I (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(0, 4) // frame_num
  r.put_ue(0) // idr_pic_id
  r.put_bit(0) // no_output_of_prior_pics_flag
  r.put_bit(0) // long_term_reference_flag
  r.put_se(0) // slice_qp_delta
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
  let slice_nal = h264_cabac_nal(header, self_.enc.to_bytes(), 3, 5)
  Ok({
    annexb: h264_enc_concat([sps_nal, pps_nal, slice_nal]),
    recon_y: self_.rec_y,
    recon_u: self_.rec_u,
    recon_v: self_.rec_v,
    ystride: self_.ystride,
    cstride: self_.cstride,
    width,
    height,
    qp,
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
/// SAD between source and reconstruction over an 8x8 chroma block. */
fn H264CabacIEnc::chroma_sad(
  self : H264CabacIEnc,
  src : Array[Int32],
  rec : Array[Int32],
  cbase : Int32,
) -> Int32 {
  let mut sad = 0
  for row = 0; row < 8; row = row + 1 {
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
    let ok_u = h264_pred8x8(
      self.rec_u,
      cbase,
      self.cstride,
      eff,
      top,
      left,
      bit_depth=8,
    )
    let ok_v = h264_pred8x8(
      self.rec_v,
      cbase,
      self.cstride,
      eff,
      top,
      left,
      bit_depth=8,
    )
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
  ignore(
    h264_pred8x8(
      self.rec_u,
      cbase,
      self.cstride,
      best_eff,
      top,
      left,
      bit_depth=8,
    ),
  )
  ignore(
    h264_pred8x8(
      self.rec_v,
      cbase,
      self.cstride,
      best_eff,
      top,
      left,
      bit_depth=8,
    ),
  )
  best_sig
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
  let info = self.ctx.infos[mb_idx]
  // Macroblock-entry mirror (the decoder clears `nz` at parse start).
  for i = 0; i < 48; i = i + 1 {
    info.nz[i] = 0
  }
  self.ctx.cur_mb_is_intra = true
  self.ctx.qscale = self.p.qp
  self.ctx.last_qscale_diff = 0
  for i = 0; i < 16; i = i + 1 {
    self.cur_modes[i] = 0
  }
  let top_avail = mb_y > 0
  let left_avail = mb_x > 0
  let qp = self.p.qp
  // ---- chroma decisions + residuals ----
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
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
    Array::make(64, 0),
    Array::make(64, 0),
  ]
  let chroma_dc_nz : Array[Bool] = [false, false]
  let mb : Array[Int32] = Array::make(768, 0)
  for c = 0; c < 2; c = c + 1 {
    let src = if c == 0 { self.src_u } else { self.src_v }
    let rec = if c == 0 { self.rec_u } else { self.rec_v }
    let sums : Array[Int32] = Array::make(4, 0)
    for i = 0; i < 4; i = i + 1 {
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
    let dc_store : Array[Int32] = Array::make(4, 0)
    let dc_levels = h264_enc_chroma_dc_hadamard_quant(
      sums,
      dc_store,
      0,
      self.chroma_qp,
    )
    ignore(dc_levels)
    chroma_dc_store[c] = dc_store
    chroma_dc_nz[c] = dc_store[0] != 0 ||
      dc_store[1] != 0 ||
      dc_store[2] != 0 ||
      dc_store[3] != 0
    for i = 0; i < 4; i = i + 1 {
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
          )
        }
      }
    }
    for s = 0; s < 4; s = s + 1 {
      let lv = dc_store[s]
      if lv != 0 {
        mb[256 + 256 * c + 16 * s] = lv
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
        bit_depth=8,
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
          bit_depth=8,
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
        bit_depth=8,
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
        mb[16 * i + s] = h264_enc_dequant_level(levels[s], qmul_y[s])
      }
    }
    if total != 0 {
      luma_cbp = luma_cbp | (1 << (i / 4))
      if total == 1 && mb[16 * i] != 0 {
        h264_idct_dc_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      } else {
        h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      }
    }
  }
  // Decision: the I4x4 pass must beat I16x16 by ~6% to justify its 16-block
  // mode-signalling overhead; ties prefer I16x16 (its DC-only stream prices
  // into fewer CABAC bins, too).
  let use_i16 = i16_found && !(100 * i4_cost < 94 * i16_cost)
  if use_i16 {
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
        bit_depth=8,
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
          mb[16 * i + s] = h264_enc_dequant_level(lv, qmul_y[s])
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
      h264_luma_dc_dequant_idct(mb, 0, luma_dc_store, 0, qmul_y[0], bit_depth=8)
    }
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let off = ybase + gy * 4 * self.ystride + gx * 4
      if i16_ac_nz[gy * 4 + gx] != 0 {
        h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      } else if mb[16 * i] != 0 {
        h264_idct_dc_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      }
    }
  }
  // Chroma cbp decision (below 2 the decoder never sees the AC levels).
  let chroma_c_cbp = if chroma_dc_nz[0] || chroma_dc_nz[1] {
    let any_ac = chroma_ac_nz_count(chroma_ac_store)
    if any_ac {
      2
    } else {
      1
    }
  } else {
    0
  }
  if chroma_c_cbp < 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
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
      h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_c[c][0], bit_depth=8)
    }
    for i = 0; i < 4; i = i + 1 {
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
        h264_idct_add(plane, off, self.cstride, mb, bo, bit_depth=8)
      } else if mb[bo] != 0 {
        h264_idct_dc_add(plane, off, self.cstride, mb, bo, bit_depth=8)
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
    self.enc.decision(self.states, 60, 0)
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
  // Chroma AC residuals (cat 4, AC-only scan).
  if chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
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
  info.qp = qp
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
  h264_write_back_part(ctx, mb_idx, bx, by, bw, bh, mvx, mvy, 0, absx, absy)
  self.fill_part(bx, by, bw, bh, mvx, mvy)
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
  match plan {
    Skip => return
    // Unreachable while `h264_encode_frames_cabac` passes
    // `allow_intra=false`. Wiring this needs the P-slice intra mb_type
    // table (ctx_base 17, intra_slice 0) at both ends; keep the door shut
    // instead of silently emitting inter-shaped bins for an intra plan.
    I16(_, _, _) => return
    Part16x16(mvx, mvy) => {
      enc.decision(states, 14, 0)
      enc.decision(states, 15, 0)
      enc.decision(states, 16, 0)
      h264_write_back_ref(ctx, mb_idx, 0, 0, 4, 4, 0)
      let (pmvx, pmvy) = h264_pred_motion(ctx, mb_idx, mb_x, mb_y, 0, 0, 4, 0)
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
      for i = 0; i < 2; i = i + 1 {
        h264_write_back_ref(ctx, mb_idx, 0, 2 * i, 4, 2, 0)
      }
      for i = 0; i < 2; i = i + 1 {
        let by = 2 * i
        let (pmvx, pmvy) = h264_pred_16x8_motion(ctx, mb_idx, mb_x, mb_y, i, 0)
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
      for i = 0; i < 2; i = i + 1 {
        h264_write_back_ref(ctx, mb_idx, 2 * i, 0, 2, 4, 0)
      }
      for i = 0; i < 2; i = i + 1 {
        let bx = 2 * i
        let (pmvx, pmvy) = h264_pred_8x16_motion(ctx, mb_idx, mb_x, mb_y, i, 0)
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
      // The decoder's ref_cache dance: three non-top-left cells per 8x8
      // group plus the cleared top-left, then the top-left refill right
      // before each group's mvd loop.
      for k = 0; k < 4; k = k + 1 {
        let x8 = k % 2
        let y8 = k / 2
        h264_write_back_ref(ctx, mb_idx, 2 * x8 + 1, 2 * y8, 1, 1, 0)
        h264_write_back_ref(ctx, mb_idx, 2 * x8, 2 * y8 + 1, 1, 1, 0)
        h264_write_back_ref(ctx, mb_idx, 2 * x8 + 1, 2 * y8 + 1, 1, 1, 0)
        h264_clear_block(ctx, mb_idx, 2 * x8, 2 * y8)
      }
      let mut mi = 0
      for k = 0; k < 4; k = k + 1 {
        let x8 = k % 2
        let y8 = k / 2
        h264_write_back_ref(ctx, mb_idx, 2 * x8, 2 * y8, 1, 1, 0)
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
            0,
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
  h264_cabacw_cbp(enc, states, ctx, mb_idx, mb_x, mb_y, cbp, true)
  // Decoder writes `info.cbp_all = cbp` before the residual bins.
  info.cbp_all = cbp
  if cbp != 0 {
    enc.decision(states, 60, 0)
  }
  for i8 = 0; i8 < 4; i8 = i8 + 1 {
    if (coded.luma_cbp & (1 << i8)) != 0 {
      for i4 = 0; i4 < 4; i4 = i4 + 1 {
        let i = i8 * 4 + i4
        let view = scan_view_at(coded.luma_store, i, h264_zigzag_scan_t, 0, 16)
        h264_cabacw_residual(
          enc, states, ctx, mb_idx, mb_x, mb_y, 2, i, view, 16, false,
        )
      }
    }
  }
  if coded.chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
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
  if coded.chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
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
  let mirror = h264_cabac_mirror_new(
    self.mb_width,
    self.mb_height,
    self.pps,
    self.p.qp,
    0,
    self.ystride,
    self.cstride,
    self.pheight,
  )
  let enc = h264_cabac_enc_new()
  let states = ff_h264_init_cabac_states(self.p.qp, 8, 0, 0)
  // Slice header.
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(5) // slice_type: P (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num (log2_max_frame_num = 4)
  r.put_bit(0) // num_ref_idx_active_override_flag
  r.put_bit(0) // ref_pic_list_modification_flag_l0
  r.put_bit(0) // adaptive_ref_pic_marking_mode_flag
  r.put_ue(0) // cabac_init_idc
  r.put_se(0) // slice_qp_delta
  while r.bw.nbits != 0 {
    r.put_bit(1) // cabac_alignment_one_bit
  }
  let header = r.finish_raw_of()
  let qp = self.p.qp
  let n_mbs = self.mb_width * self.mb_height
  let mut mb = 0
  for mb_y = 0; mb_y < self.mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < self.mb_width; mb_x = mb_x + 1 {
      let mb_idx = mb_y * self.mb_width + mb_x
      let info = mirror.infos[mb_idx]
      for i = 0; i < 48; i = i + 1 {
        info.nz[i] = 0
      }
      mirror.cur_mb_is_intra = false
      mirror.qscale = qp
      mirror.last_qscale_diff = 0
      // P_Skip check with the prediction the decoder itself would derive.
      let (pmvx, pmvy) = h264_pred_pskip_motion(mirror, mb_idx, mb_x, mb_y)
      let (_, _, skip_sad) = self.me_fixed(mb_x, mb_y, 0, 0, 16, 16, pmvx, pmvy)
      // CABAC P-slice intra signalling (ctx_base 17) is not wired yet, so
      // this entry keeps the inter-only RD surface. `allow_intra=false`
      // makes the CAVLC-priced candidates byte-identical to §382.
      let plan = if skip_sad == 0 {
        Skip
      } else {
        self.decide_plan(mb_x, mb_y, false)
      }
      if plan is I16(_, _, _) {
        self.stats.i16_mbs += 1
      }
      if !(plan is Skip) {
        self.stats.coded_mbs += 1
      }
      let skip_ctx = h264_cabacw_skip_ctx(mirror, mb_idx)
      if plan is Skip {
        enc.decision(states, skip_ctx, 1)
        self.commit_skip(mb_idx, pmvx, pmvy)
        // Mirror `h264_cabac_skip_mb` exactly: the partition write-back
        // (mv/ref plus the mvd cache zeros), the decoder's four-bit skip
        // type (not the bare skip bit), cbp 0 and the slice qp.
        h264_write_back_part(mirror, mb_idx, 0, 0, 4, 4, pmvx, pmvy, 0, 0, 0)
        info.mb_type_bits = h264_mb_type_16x16 |
          h264_mb_type_p0l0 |
          h264_mb_type_p1l0 |
          h264_mb_type_skip
        info.cbp_all = 0
        info.qp = qp
      } else {
        enc.decision(states, skip_ctx, 0)
        let coded = self.code_mb_residuals(mb_x, mb_y, plan, qp)
        self.write_cabac_mb_syntax(mirror, enc, states, mb_x, mb_y, plan, coded)
        self.commit_plan_state(mb_idx, plan)
        // The CABAC writer's nz mirror is the syntax mirror; keep the
        // encoder-side mirror identical for the next frame's seeds.
        for i = 0; i < 48; i = i + 1 {
          self.states[mb_idx].nz[i] = info.nz[i]
        }
        info.qp = qp
      }
      mb = mb + 1
      // end_of_slice_flag: the terminating bin of the last macroblock
      // flushes the engine.
      enc.terminate(if mb == n_mbs { 1 } else { 0 })
    }
  }
  Ok(h264_cabac_nal(header, enc.to_bytes(), 3, 1))
}

///|
/// Encode a frame sequence with CABAC entropy coding (Main profile): the
/// first frame as an IDR I picture, every following frame as a P picture
/// referencing the previous frame's reconstruction. Returns the Annex B
/// stream.
pub fn h264_encode_frames_cabac(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  stats~ : H264EncStats = H264EncStats::new(),
) -> Result[Bytes, String] {
  if frames.length() == 0 {
    return Err("h264 enc: no frames")
  }
  let (y0, u0, v0) = frames[0]
  let first = match
    h264_encode_intra_frame_cabac(y0, u0, v0, width~, height~, qp~, level_idc~) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let p = { width, height, qp, level_idc, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  let ps = new_h264_param_sets()
  match
    ff_h264_decode_seq_parameter_set(
      BitReader::new(h264_enc_sps_rbsp_main(p)),
      ps,
      false,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = h264_enc_pps_rbsp_cabac(p)
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
  let chroma_qp = h264_get_chroma_qp(pps, 0, qp)
  fn load_plane(
    src : Bytes,
    w : Int32,
    h : Int32,
    stride : Int32,
    plane_h : Int32,
  ) -> Array[Int32] {
    let plane : Array[Int32] = Array::make(stride * plane_h, 0)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        plane[row * stride + col] = src[row * w + col].to_int()
      }
    }
    plane
  }
  let stream : Array[Bytes] = [first.annexb]
  let mut ref_y = Array::make(ystride * pheight, 0)
  let mut ref_u = Array::make(cstride * (pheight / 2), 0)
  let mut ref_v = Array::make(cstride * (pheight / 2), 0)
  for row = 0; row < pheight; row = row + 1 {
    for col = 0; col < ystride; col = col + 1 {
      ref_y[row * ystride + col] = first.recon_y[row * ystride + col]
    }
  }
  for row = 0; row < pheight / 2; row = row + 1 {
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
  for f = 1; f < frames.length(); f = f + 1 {
    let (y, u, v) = frames[f]
    let enc : H264PEncoder = {
      p,
      stats,
      pps,
      chroma_qp,
      src_y: load_plane(y, width, height, ystride, pheight),
      src_u: load_plane(u, width / 2, height / 2, cstride, pheight / 2),
      src_v: load_plane(v, width / 2, height / 2, cstride, pheight / 2),
      rec_y: Array::make(ystride * pheight, 0),
      rec_u: Array::make(cstride * (pheight / 2), 0),
      rec_v: Array::make(cstride * (pheight / 2), 0),
      ref_y,
      ref_u,
      ref_v,
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
    }
    let nal = match enc.encode_p_frame_cabac(f) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    stream.push(nal)
    let next_y = Array::make(ystride * pheight, 0)
    let next_u = Array::make(cstride * (pheight / 2), 0)
    let next_v = Array::make(cstride * (pheight / 2), 0)
    for row = 0; row < pheight; row = row + 1 {
      for col = 0; col < ystride; col = col + 1 {
        next_y[row * ystride + col] = enc.rec_y[row * ystride + col]
      }
    }
    for row = 0; row < pheight / 2; row = row + 1 {
      for col = 0; col < cstride; col = col + 1 {
        next_u[row * cstride + col] = enc.rec_u[row * cstride + col]
        next_v[row * cstride + col] = enc.rec_v[row * cstride + col]
      }
    }
    ref_y = next_y
    ref_u = next_u
    ref_v = next_v
  }
  let out : Array[Byte] = []
  for part in stream {
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Ok(Bytes::from_array(out[:]))
}
