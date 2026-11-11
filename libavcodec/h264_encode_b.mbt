///|
/// Pure-MoonBit H.264 B-frame encoder (`§393`): bidirectionally predicted
/// pictures between the I/P reference chain, with frame reordering carried
/// by POC (type 0) so decoders reorder to display order.
///
/// Porting discipline (the same mirroring as the P slices): the encoder
/// keeps a real `H264DecCtx` mirror per B picture whose reference lists
/// hold the actual past/future reconstructions, and every decision the
/// syntax depends on runs through the DECODER'S OWN functions —
/// `h264_b_direct` (spatial direct, the colocated history is the future
/// P's motion state), `h264_pred_motion`, `h264_write_back_ref`,
/// `h264_write_back_part` and `h264_b_compensate` (MC with the (a+b+1)>>1
/// average) — so the local reconstruction is, by construction, what the
/// decoder produces.
///
/// Scope (v1): B macroblock kinds 0..3 — B_Direct_16x16, B_L1_16x16,
/// B_Bi_16x16, B_L0_16x16 — plus the B skip run (skip = direct with no
/// residual). 16x8/8x16/8x8 sub-partitioning, intra-in-B, weighted
/// prediction and B under VBV/ABR stay outside. Both entropy coders write
/// the same decisions; the mode decision prices candidates with the CAVLC
/// dry-run writer (`cabac_rd` is rejected with `b_slices`).

///|
/// The decided B macroblock plan (kinds 0..3 of Table 7-11).
priv enum H264BPlan {
  /// B_Skip: direct macroblock, no residual, extends `mb_skip_run`.
  BSkip
  /// B_Direct_16x16 (kind 0): residual-coding direct macroblock.
  BDirect16
  /// B_L1_16x16 (kind 1): single future MV.
  BL1x16(Int32, Int32)
  /// B_Bi_16x16 (kind 2): one past and one future MV.
  BBi16(Int32, Int32, Int32, Int32)
  /// B_L0_16x16 (kind 3): single past MV.
  BL0x16(Int32, Int32)
}

///|
/// Access-unit delimiter for pictures that may contain B slices:
/// primary_pic_type 2 (I/P/B), nal_ref_idc 0 (H.264 7.4.1).
fn h264_enc_aud_b() -> Bytes {
  b"\x00\x00\x00\x01\x09\x50"
}

///|
/// B-capable SPS RBSP (Main profile, profile_idc 77): identical to the
/// Main SPS except `pic_order_cnt_type = 0` (every slice carries
/// `pic_order_cnt_lsb`, 4 bits — the display order travels in the stream)
/// and `max_num_ref_frames = 2` (one past and one future reference).
fn h264_enc_sps_rbsp_b(p : H264EncParams) -> Bytes {
  let r = H264Rbsp::new()
  r.put(77, 8) // profile_idc: Main
  r.put(0x40, 8) // constraint_set1 (A.2.2)
  r.put(p.level_idc, 8)
  r.put_ue(0) // seq_parameter_set_id
  r.put_ue(0) // log2_max_frame_num_minus4 -> 4-bit frame_num
  r.put_ue(0) // pic_order_cnt_type = 0
  r.put_ue(0) // log2_max_pic_order_cnt_lsb_minus4 -> 4-bit POC LSB
  r.put_ue(2) // max_num_ref_frames
  r.put_bit(0) // gaps_in_frame_num_value_allowed_flag
  r.put_ue(p.mb_width() - 1)
  r.put_ue(p.mb_height() - 1)
  r.put_bit(1) // frame_mbs_only_flag
  r.put_bit(1) // direct_8x8_inference_flag (required for spatial direct)
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
/// The B SPS as a NAL unit (nal_unit_type 7, ref_idc 3).
fn h264_enc_write_sps_b(p : H264EncParams) -> Bytes {
  let body = h264_enc_sps_rbsp_b(p)
  let out : Array[Byte] = [
    b'\x00',
    b'\x00',
    b'\x00',
    b'\x01',
    ((3 << 5) | 7).to_byte(),
  ]
  for i = 0; i < body.length(); i = i + 1 {
    out.push(body[i])
  }
  Bytes::from_array(out[:])
}

///|
/// Colocated motion history of a coded P (or I) picture, in the decoder's
/// `H264MbInfo` form: the per-4x4 MVs and reference indexes the spatial
/// direct mode of the NEXT B picture samples (`h264_colocated_sample`).
/// Only the fields the colocated reads are filled (luma MV/ref, the intra
/// bit); list-1 slots stay at their fresh defaults (a P picture has none).
fn h264_b_colocated_from_states(
  states : Array[H264PMbState],
) -> Array[H264MbInfo] {
  let infos : Array[H264MbInfo] = []
  for st in states {
    let info = h264_new_mb_info()
    for i = 0; i < 32; i = i + 1 {
      info.mv[i] = st.mv[i]
    }
    for i = 0; i < 16; i = i + 1 {
      info.ref_idx[i] = st.ref_idx[i]
    }
    if st.intra {
      info.mb_type_bits = h264_mb_type_intra16x16
    } else if st.has_data || st.intra {
      info.mb_type_bits = h264_mb_type_16x16
    } else {
      info.mb_type_bits = h264_mb_type_skip
    }
    infos.push(info)
  }
  infos
}

///|
/// A reference-picture wrapper around coded reconstruction planes.
fn h264_b_refpic(
  y : Array[Int32],
  u : Array[Int32],
  v : Array[Int32],
  ystride : Int32,
  cstride : Int32,
  pheight : Int32,
  poc : Int32,
  identity : Int32,
) -> H264RefPic {
  {
    identity,
    y,
    u,
    v,
    ystride,
    cstride,
    width: ystride,
    height: pheight,
    cwidth: cstride,
    cheight: pheight / 2,
    poc,
    field_poc_top: poc,
    field_poc_bottom: poc,
    base_y: 0,
    base_u: 0,
    base_v: 0,
    parity: 0,
  }
}

///|
/// The B picture's decoder-context mirror: fresh `H264MbInfo` entries,
/// `slice_type_nos = 1`, list 0 = the past reference, list 1 = the future
/// reference, the colocated history = the future picture's motion state,
/// and the reconstruction planes SHARED with the encoder (`h264_b_comp
/// ensate` motion-compensates straight into them). Spatial direct with
/// 8x8 inference, single active reference per list.
fn h264_b_mirror_new(
  mb_width : Int32,
  mb_height : Int32,
  pps : H264Pps,
  qp : Int32,
  ystride : Int32,
  cstride : Int32,
  past : H264RefPic,
  future : H264RefPic,
  colocated : Array[H264MbInfo],
  rec_y : Array[Int32],
  rec_u : Array[Int32],
  rec_v : Array[Int32],
  cur_poc : Int32,
) -> H264DecCtx {
  let infos : Array[H264MbInfo] = []
  for _k = 0; _k < mb_width * mb_height; _k = _k + 1 {
    infos.push(h264_new_mb_info())
  }
  {
    bit_depth: 8,
    chroma_format: 1,
    chroma_hshift: 1,
    chroma_vshift: 1,
    si_slice: false,
    slice_num: 0,
    active_list: 0,
    ref_list1: [future],
    ref_count1: 1,
    direct_spatial: true,
    direct_8x8: true,
    colocated,
    reference_buffers: Map([]),
    colocated_mbaff: false,
    colocated_field_picture: false,
    poc: cur_poc,
    poc_top: cur_poc,
    poc_bottom: cur_poc,
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
    y: rec_y,
    u: rec_u,
    v: rec_v,
    ystride,
    cstride,
    infos,
    failed_mb: -1,
    qscale: qp,
    last_qscale_diff: 0,
    slice_type_nos: 1,
    cur_mb_is_intra: false,
    ref_count0: 1,
    ref_list0: [past],
    mb_skip_run: -1,
    pwt: new_h264_pred_weight(),
  }
}

///|
/// Snapshot of the mirror fields one B macroblock's trial mutates: the
/// per-4x4 motion slots of both lists (direct writes them before the
/// winner is known). Restored when a non-direct plan wins.
priv struct H264BMbSnapshot {
  mv : Array[Int32]
  mv1 : Array[Int32]
  ref_idx : Array[Int32]
  ref_idx1 : Array[Int32]
  mvd : Array[Int32]
  mvd1 : Array[Int32]
  direct : Array[Bool]
}

///|
fn h264_b_mb_snapshot(info : H264MbInfo) -> H264BMbSnapshot {
  let mv = Array::make(32, 0)
  let mv1 = Array::make(32, 0)
  let ref_idx = Array::make(16, 0)
  let ref_idx1 = Array::make(16, 0)
  let mvd = Array::make(32, 0)
  let mvd1 = Array::make(32, 0)
  let direct = Array::make(16, false)
  for i = 0; i < 32; i = i + 1 {
    mv[i] = info.mv[i]
    mv1[i] = info.mv1[i]
    mvd[i] = info.mvd[i]
    mvd1[i] = info.mvd1[i]
  }
  for i = 0; i < 16; i = i + 1 {
    ref_idx[i] = info.ref_idx[i]
    ref_idx1[i] = info.ref_idx1[i]
    direct[i] = info.direct[i]
  }
  { mv, mv1, ref_idx, ref_idx1, mvd, mvd1, direct, }
}

///|
fn h264_b_mb_restore(info : H264MbInfo, snap : H264BMbSnapshot) -> Unit {
  for i = 0; i < 32; i = i + 1 {
    info.mv[i] = snap.mv[i]
    info.mv1[i] = snap.mv1[i]
    info.mvd[i] = snap.mvd[i]
    info.mvd1[i] = snap.mvd1[i]
  }
  for i = 0; i < 16; i = i + 1 {
    info.ref_idx[i] = snap.ref_idx[i]
    info.ref_idx1[i] = snap.ref_idx1[i]
    info.direct[i] = snap.direct[i]
  }
}

///|
/// Motion-compensate one whole 16x16 macroblock from a single list's MV
/// into the reconstruction planes (the unidirectional candidates).
fn H264PEncoder::mc_b_uni_into_rec(
  self : H264PEncoder,
  mirror : H264DecCtx,
  list : Int32,
  mb_x : Int32,
  mb_y : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  let pred = h264_b_prediction(
    mirror, list, 0, mb_x, mb_y, 0, 0, 16, 16, mvx, mvy,
  )
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      self.rec_y[ybase + row * self.ystride + col] = pred[0][row * 16 + col]
    }
  }
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  for c = 0; c < 2; c = c + 1 {
    let plane = if c == 0 { self.rec_u } else { self.rec_v }
    let src = pred[c + 1]
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        plane[cbase + row * self.cstride + col] = src[row * 8 + col]
      }
    }
  }
}

///|
/// Motion-compensate the bidirectional candidate: both lists' predictors
/// averaged with the decoder's `(a + b + 1) >> 1` round.
fn H264PEncoder::mc_b_bi_into_rec(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
) -> Unit {
  let a = h264_b_prediction(mirror, 0, 0, mb_x, mb_y, 0, 0, 16, 16, mv0x, mv0y)
  let b = h264_b_prediction(mirror, 1, 0, mb_x, mb_y, 0, 0, 16, 16, mv1x, mv1y)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let i = row * 16 + col
      self.rec_y[ybase + row * self.ystride + col] = (a[0][i] + b[0][i] + 1) >>
        1
    }
  }
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  for c = 0; c < 2; c = c + 1 {
    let plane = if c == 0 { self.rec_u } else { self.rec_v }
    let sa = a[c + 1]
    let sb = b[c + 1]
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        let i = row * 8 + col
        plane[cbase + row * self.cstride + col] = (sa[i] + sb[i] + 1) >> 1
      }
    }
  }
}

///|
/// Integer +-16 then 3x3 subpel motion search of a 16x16 block against an
/// explicit reference plane (the B lists' planes), seeded at the zero MV
/// and the prediction. Returns the quarter-pel MV and its SAD.
fn H264PEncoder::me_b_16x16(
  self : H264PEncoder,
  ref_plane : Array[Int32],
  mb_x : Int32,
  mb_y : Int32,
  pmvx : Int32,
  pmvy : Int32,
) -> (Int32, Int32, Int32) {
  let src_row = mb_y * 16
  let src_col = mb_x * 16
  let mcbuf : Array[Int32] = Array::make(256, 0)
  fn sad_at(
    self : H264PEncoder,
    mcbuf : Array[Int32],
    ref_plane : Array[Int32],
    qx : Int32,
    qy : Int32,
    src_row : Int32,
    src_col : Int32,
  ) -> Int32 {
    h264_mc_luma(
      mcbuf,
      0,
      16,
      ref_plane,
      src_col + (qx >> 2),
      src_row + (qy >> 2),
      self.ystride,
      16,
      16,
      qx & 3,
      qy & 3,
      self.pwidth,
      self.pheight,
      bit_depth=8,
    )
    h264_p_sad_mc(
      self.src_y,
      mcbuf,
      src_row,
      src_col,
      self.ystride,
      self.pheight,
      self.pwidth,
      w=16,
      h=16,
    )
  }
  // Integer search seeded at zero and the predictor (first seed wins ties).
  let mut best_x = 0
  let mut best_y = 0
  let mut best_sad = sad_at(self, mcbuf, ref_plane, 0, 0, src_row, src_col)
  let seeds = [(pmvx >> 2, pmvy >> 2)]
  for s in seeds {
    let sx = if s.0 < -16 { -16 } else if s.0 > 16 { 16 } else { s.0 }
    let sy = if s.1 < -16 { -16 } else if s.1 > 16 { 16 } else { s.1 }
    let sad = sad_at(self, mcbuf, ref_plane, sx * 4, sy * 4, src_row, src_col)
    if sad < best_sad {
      best_sad = sad
      best_x = sx
      best_y = sy
    }
  }
  for dy = -16; dy <= 16; dy = dy + 1 {
    for dx = -16; dx <= 16; dx = dx + 1 {
      if dx == 0 && dy == 0 {
        continue
      }
      let sad = sad_at(self, mcbuf, ref_plane, dx * 4, dy * 4, src_row, src_col)
      if sad < best_sad {
        best_sad = sad
        best_x = dx
        best_y = dy
      }
    }
  }
  // Subpel refinement over the 3x3 quarter-pel neighbourhood.
  let mut best_qx = best_x * 4
  let mut best_qy = best_y * 4
  let mut best_qsad = best_sad
  for sy = -1; sy <= 1; sy = sy + 1 {
    for sx = -1; sx <= 1; sx = sx + 1 {
      if sx == 0 && sy == 0 {
        continue
      }
      let qx = best_x * 4 + sx
      let qy = best_y * 4 + sy
      if qx >= 0 && qy >= 0 {
        let sad = sad_at(self, mcbuf, ref_plane, qx, qy, src_row, src_col)
        if sad < best_qsad {
          best_qsad = sad
          best_qx = qx
          best_qy = qy
        }
      }
    }
  }
  // The mvd syntax clips its magnitude at 70 (both entropy coders), so the
  // decoder cannot represent an MV further than 70 quarter-pels from the
  // prediction; clamp the search result onto that reachable square.
  let lim = 70
  if best_qx - pmvx > lim {
    best_qx = pmvx + lim
  }
  if pmvx - best_qx > lim {
    best_qx = pmvx - lim
  }
  if best_qy - pmvy > lim {
    best_qy = pmvy + lim
  }
  if pmvy - best_qy > lim {
    best_qy = pmvy - lim
  }
  (best_qx, best_qy, best_qsad)
}

///|
/// Residual coding of one B macroblock: the reconstruction planes must
/// already hold the plan's prediction (direct compensation, unidirectional
/// or bidirectional MC). The transform/quantise/reconstruct chain and the
/// `cur_nz` mirror semantics are the inter ones of `code_mb_residuals`
/// (4x4 transform only — B v1 never sets `transform_size_8x8_flag`).
fn H264PEncoder::code_b_mb_residuals(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  qp : Int32,
) -> H264PMbCode {
  let mb_idx = mb_y * self.mb_width + mb_x
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = self.states[mb_idx].nz[i]
  }
  let qmul_y = h264_build_dequant4(self.pps, 3, qp)
  let luma_store : Array[Int32] = Array::make(256, 0)
  let mut luma_cbp = 0
  let mb : Array[Int32] = Array::make(768, 0)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * self.ystride + gx * 4
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
    self.cur_nz[g] = total
    if total != 0 {
      luma_cbp = luma_cbp | (1 << (i / 4))
    }
  }
  let qmul_c = [
    h264_build_dequant4(self.pps, 4, self.chroma_qp),
    h264_build_dequant4(self.pps, 5, self.chroma_qp),
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
  let chroma_ac_nz_mirror : Array[Int32] = Array::make(48, 0)
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
    ignore(h264_enc_chroma_dc_hadamard_quant(sums, dc_store, 0, self.chroma_qp))
    chroma_dc_store[c] = dc_store
    chroma_dc_nz[c] = dc_store[0] != 0 ||
      dc_store[1] != 0 ||
      dc_store[2] != 0 ||
      dc_store[3] != 0
    for s = 0; s < 4; s = s + 1 {
      if dc_store[s] != 0 {
        mb[256 + 256 * c + 16 * s] = dc_store[s]
      }
    }
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
      levels[0] = 0
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        chroma_ac_store[c][16 * i + s] = levels[s]
        if levels[s] != 0 {
          total = total + 1
          mb[256 + 256 * c + 16 * i + s] = h264_enc_dequant_level(
            levels[s],
            qmul_c[c][s],
          )
        }
      }
      chroma_ac_nz_mirror[16 + 16 * c + i] = total
    }
  }
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
  // Inter nC semantics: the AC counts follow the syntax (zero when the
  // cbp does not code AC), the DC flags ride `cbp_all`.
  for c = 0; c < 2; c = c + 1 {
    for i = 0; i < 4; i = i + 1 {
      self.cur_nz[16 + 16 * c + i] = if chroma_c_cbp == 2 {
        chroma_ac_nz_mirror[16 + 16 * c + i]
      } else {
        0
      }
    }
  }
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
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let off = ybase + gy * 4 * self.ystride + gx * 4
    if self.cur_nz[gy * 4 + gx] != 0 {
      h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
    } else if mb[16 * i] != 0 {
      h264_idct_dc_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
    }
  }
  {
    luma_cbp,
    chroma_c_cbp,
    luma_store,
    luma_dc_store: Array::make(16, 0),
    chroma_dc_store,
    chroma_ac_store,
    dct8: false,
    luma8_store: Array::make(256, 0),
  }
}

///|
/// The encoder-numbered kind of a B plan. The partition list masks in
/// `h264_b_partitions` are the kind VALUE (`mask: kind`, bit 0 = list 0):
/// kind 1 carries list 0 only (B_L0_16x16), kind 2 list 1 only
/// (B_L1_16x16) and kind 3 both (B_Bi_16x16).
fn h264_b_plan_kind(plan : H264BPlan) -> Int32 {
  match plan {
    BDirect16 => 0
    BL0x16(_, _) => 1
    BL1x16(_, _) => 2
    BBi16(_, _, _, _) => 3
    BSkip => 0
  }
}

///|
/// Commit the winning plan's motion to the mirror in the decoder's
/// `h264_decode_b_mb` order: the reference write-backs first (per list,
/// per partition), then the per-list mvd write-backs with the prediction
/// computed from the committed state. Direct plans wrote their state via
/// `h264_b_direct` already; the mb_type bits come from the decoder's own
/// `h264_b_partitions` so every neighbour context sees identical values.
fn h264_b_commit_mb(
  mirror : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  skip : Bool,
) -> Unit {
  let info = mirror.infos[mb_idx]
  let kind = h264_b_plan_kind(plan)
  let (groups, _parts, _direct, mb_bits) = h264_b_partitions(kind, [])
  info.mb_type_bits = mb_bits | (if skip { h264_mb_type_skip } else { 0 })
  if plan is BDirect16 || plan is BSkip {
    // The direct trial already wrote the per-block motion; skip adds the
    // decoder's skip bookkeeping.
    if skip {
      info.cbp_all = 0
      mirror.last_qscale_diff = 0
      info.qp = mirror.qscale
    }
    return
  }
  for list in 0..<2 {
    mirror.active_list = list
    for part in groups {
      if (part.mask & (1 << list)) == 0 {
        continue
      }
      h264_write_back_ref(mirror, mb_idx, part.x, part.y, part.w, part.h, 0)
    }
  }
  for list in 0..<2 {
    mirror.active_list = list
    for part in groups {
      if (part.mask & (1 << list)) == 0 {
        continue
      }
      let (pmvx, pmvy) = h264_pred_motion(
        mirror,
        mb_idx,
        mb_x,
        mb_y,
        part.x,
        part.y,
        part.w,
        0,
      )
      let (mvx, mvy) = match plan {
        BBi16(a, b, c, d) => if list == 0 { (a, b) } else { (c, d) }
        BL0x16(a, b) => (a, b)
        BL1x16(a, b) => (a, b)
        _ => (0, 0)
      }
      let dx = (mvx - pmvx).abs().min(70)
      let dy = (mvy - pmvy).abs().min(70)
      h264_write_back_part(
        mirror,
        mb_idx,
        part.x,
        part.y,
        part.w,
        part.h,
        mvx,
        mvy,
        0,
        dx,
        dy,
      )
    }
  }
  mirror.active_list = 0
}

///|
/// Write one coded B macroblock's CAVLC syntax: the mb_type codeword, the
/// per-list partition mvds against the mirror's prediction, then the inter
/// residual tail shared with the P writer (cbp codeword, `mb_qp_delta`,
/// cbp-gated 4x4 luma and the chroma residual). The dry-run mode prices a
/// candidate into a throwaway buffer.
fn H264PEncoder::write_b_mb_syntax(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
  r : H264Rbsp,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let kind = h264_b_plan_kind(plan)
  let (groups, _parts, _direct, _mb_bits) = h264_b_partitions(kind, [])
  r.put_ue(kind)
  // Motion vector differences, list 0's partitions then list 1's, each
  // against the mirror's prediction (the committed reference state).
  for list in 0..<2 {
    mirror.active_list = list
    for part in groups {
      if (part.mask & (1 << list)) == 0 {
        continue
      }
      let (pmvx, pmvy) = h264_pred_motion(
        mirror,
        mb_idx,
        mb_x,
        mb_y,
        part.x,
        part.y,
        part.w,
        0,
      )
      let (mvx, mvy) = match plan {
        BBi16(a, b, c, d) => if list == 0 { (a, b) } else { (c, d) }
        BL0x16(a, b) => (a, b)
        BL1x16(a, b) => (a, b)
        _ => (0, 0)
      }
      r.put_se(mvx - pmvx)
      r.put_se(mvy - pmvy)
    }
  }
  mirror.active_list = 0
  // Inter residual tail: identical to the P writer's (4x4 transform only).
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  r.put_ue(h264_enc_inter_cbp_golomb(cbp))
  if cbp != 0 {
    r.put_se(self.mb_dqp) // mb_qp_delta
    self.prev_qp = self.mb_qp
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  }
  for i8 = 0; i8 < 4; i8 = i8 + 1 {
    if (coded.luma_cbp & (1 << i8)) != 0 {
      for i4 = 0; i4 < 4; i4 = i4 + 1 {
        let i = i8 * 4 + i4
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let view = scan_view_at(coded.luma_store, i, h264_zigzag_scan_t, 0, 16)
        let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
        ignore(h264_enc_write_residual(r, view, 16, nc))
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
      ignore(h264_enc_write_residual(r, dc4, 4, 0))
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
        let nc = self.nc_chroma(mb_idx, mb_x, mb_y, c, i)
        ignore(h264_enc_write_residual(r, view, 15, nc))
      }
    }
  }
}

///|
/// SSD of the source against the reconstruction over the macroblock luma.
fn H264PEncoder::b_mb_ssd(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut ssd = 0
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let d = self.src_y[ybase + row * self.ystride + col] -
        self.rec_y[ybase + row * self.ystride + col]
      ssd = ssd + d * d
    }
  }
  ssd
}

///|
/// SAD of the source against the reconstruction over the macroblock luma
/// (the B_Skip predicate: a direct macroblock that already reconstructs
/// the source exactly has nothing to code).
fn H264PEncoder::b_mb_sad(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut sad = 0
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let d = self.src_y[ybase + row * self.ystride + col] -
        self.rec_y[ybase + row * self.ystride + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// One B macroblock's mode decision: the direct trial (skip predicate and
/// candidate), the three motion-compensated candidates, rate-distortion
/// selection with the CAVLC dry-run pricer. On return the mirror holds the
/// winning plan's decoder state, the reconstruction the winner's
/// prediction, and the caller receives the plan with its coded residual
/// stores (None for a skip). Mutates the mirror exactly like the decoder's
/// parse of the winning syntax.
fn H264PEncoder::decide_b_mb(
  self : H264PEncoder,
  mirror : H264DecCtx,
  past_y : Array[Int32],
  fut_y : Array[Int32],
  mb_x : Int32,
  mb_y : Int32,
  qp : Int32,
) -> Result[(H264BPlan, H264PMbCode?), String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  let info = mirror.infos[mb_idx]
  for i = 0; i < 48; i = i + 1 {
    info.nz[i] = 0
  }
  info.transform_8x8 = false
  // The decoder's per-MB list reset for non-intra B kinds.
  for i = 0; i < 16; i = i + 1 {
    info.ref_idx[i] = -1
    info.ref_idx1[i] = -1
  }
  // Direct trial: mirror state first (a losing trial is rolled back).
  let snap = h264_b_mb_snapshot(info)
  match h264_b_direct(mirror, mb_idx, [true, true, true, true]) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc b: direct failed: \{e}")
  }
  match h264_b_compensate(mirror, mb_idx) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc b: direct MC failed: \{e}")
  }
  let direct_sad = self.b_mb_sad(mb_x, mb_y)
  if direct_sad == 0 {
    // B_Skip: the direct macroblock reconstructs exactly; the mirror state
    // IS the skip state (the decoder's skip branch runs the same direct).
    self.stats.b_mbs += 1
    h264_b_commit_mb(mirror, mb_idx, mb_x, mb_y, BSkip, true)
    self.commit_b_mb_state(mb_idx, BSkip, mirror)
    return Ok((BSkip, None))
  }
  // Candidates: direct-with-residual, L0, L1, Bi. The predictors of the
  // single-partition kinds never read the current macroblock, so the
  // direct trial's state may stay while they are priced.
  mirror.active_list = 0
  let (p0x, p0y) = h264_pred_motion(mirror, mb_idx, mb_x, mb_y, 0, 0, 4, 0)
  mirror.active_list = 1
  let (p1x, p1y) = h264_pred_motion(mirror, mb_idx, mb_x, mb_y, 0, 0, 4, 0)
  mirror.active_list = 0
  let (mv0x, mv0y, _sad0) = self.me_b_16x16(past_y, mb_x, mb_y, p0x, p0y)
  let (mv1x, mv1y, _sad1) = self.me_b_16x16(fut_y, mb_x, mb_y, p1x, p1y)
  let lam = h264_rd_lambda(qp).to_int64()
  fn bits_of(cw : H264Rbsp) -> Int64 {
    (cw.bw.buf.length() * 8 + cw.bw.nbits).to_int64()
  }
  // Direct candidate (reconstruction already in place from the trial).
  let ssd_d = self.b_mb_ssd(mb_x, mb_y)
  let coded_d = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_d = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, BDirect16, coded_d, cw_d)
  let cost_d = ssd_d.to_int64() * 1024L + lam * bits_of(cw_d)
  // L0 candidate.
  self.mc_b_uni_into_rec(mirror, 0, mb_x, mb_y, mv0x, mv0y)
  let ssd_0 = self.b_mb_ssd(mb_x, mb_y)
  let coded_0 = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_0 = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, BL0x16(mv0x, mv0y), coded_0, cw_0)
  let cost_0 = ssd_0.to_int64() * 1024L + lam * bits_of(cw_0)
  // L1 candidate.
  self.mc_b_uni_into_rec(mirror, 1, mb_x, mb_y, mv1x, mv1y)
  let ssd_1 = self.b_mb_ssd(mb_x, mb_y)
  let coded_1 = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_1 = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, BL1x16(mv1x, mv1y), coded_1, cw_1)
  let cost_1 = ssd_1.to_int64() * 1024L + lam * bits_of(cw_1)
  // Bidirectional candidate.
  self.mc_b_bi_into_rec(mirror, mb_x, mb_y, mv0x, mv0y, mv1x, mv1y)
  let ssd_b = self.b_mb_ssd(mb_x, mb_y)
  let coded_b = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_b = H264Rbsp::new()
  self.write_b_mb_syntax(
    mirror,
    mb_x,
    mb_y,
    BBi16(mv0x, mv0y, mv1x, mv1y),
    coded_b,
    cw_b,
  )
  let cost_b = ssd_b.to_int64() * 1024L + lam * bits_of(cw_b)
  // Select (direct wins ties: it is the cheapest syntax).
  let mut plan = BDirect16
  let mut cost = cost_d
  let mut coded = coded_d
  if cost_0 < cost {
    plan = BL0x16(mv0x, mv0y)
    cost = cost_0
    coded = coded_0
  }
  if cost_1 < cost {
    plan = BL1x16(mv1x, mv1y)
    cost = cost_1
    coded = coded_1
  }
  if cost_b < cost {
    plan = BBi16(mv0x, mv0y, mv1x, mv1y)
    cost = cost_b
    coded = coded_b
  }
  ignore(cost)
  self.stats.b_mbs += 1
  match plan {
    BL1x16(_, _) => self.stats.bl1_mbs += 1
    BBi16(_, _, _, _) => self.stats.bi_mbs += 1
    BDirect16 => self.stats.bdirect_mbs += 1
    _ => ()
  }
  if !(plan is BDirect16) {
    h264_b_mb_restore(info, snap)
  }
  // Re-establish the winner's prediction.
  match plan {
    BDirect16 =>
      match h264_b_compensate(mirror, mb_idx) {
        Ok(_) => ()
        Err(e) => return Err("h264 enc b: direct re-MC failed: \{e}")
      }
    BL0x16(x, y) => self.mc_b_uni_into_rec(mirror, 0, mb_x, mb_y, x, y)
    BL1x16(x, y) => self.mc_b_uni_into_rec(mirror, 1, mb_x, mb_y, x, y)
    BBi16(a, b, c, d) => self.mc_b_bi_into_rec(mirror, mb_x, mb_y, a, b, c, d)
    BSkip => ()
  }
  h264_b_commit_mb(mirror, mb_idx, mb_x, mb_y, plan, false)
  let coded_final = self.code_b_mb_residuals(mb_x, mb_y, qp)
  ignore(coded)
  self.commit_b_mb_state(mb_idx, plan, mirror)
  Ok((plan, Some(coded_final)))
}

///|
/// Persist a coded B macroblock into the encoder-side per-MB mirror: the
/// motion state the next picture's colocated/nC machinery reads (nz from
/// the mirror's residual writer fills).
fn H264PEncoder::commit_b_mb_state(
  self : H264PEncoder,
  mb_idx : Int32,
  plan : H264BPlan,
  mirror : H264DecCtx,
) -> Unit {
  let st = self.states[mb_idx]
  let info = mirror.infos[mb_idx]
  for i = 0; i < 32; i = i + 1 {
    st.mv[i] = info.mv[i]
  }
  for i = 0; i < 16; i = i + 1 {
    st.ref_idx[i] = info.ref_idx[i]
  }
  st.intra = false
  st.has_data = !(plan is BSkip)
  // The nz mirror the NEXT macroblock's nC reads is the syntax-level one
  // (, filled by  / the skip zeroing) — the
  // decoder-mirror nz is only maintained by the CABAC residual writer.
  if plan is BSkip {
    for i = 0; i < 48; i = i + 1 {
      st.nz[i] = 0
    }
  } else {
    for i = 0; i < 48; i = i + 1 {
      st.nz[i] = self.cur_nz[i]
    }
  }
  st.intra_nxn = false
}

///|
/// Encode one B picture with CAVLC entropy: slice header (B, both lists
/// unmodified, spatial direct, non-reference), the macroblock loop with
/// `mb_skip_run`, and the trailing run of the last picture (spec 7.4.4).
fn H264PEncoder::encode_b_frame(
  self : H264PEncoder,
  mirror : H264DecCtx,
  past_y : Array[Int32],
  fut_y : Array[Int32],
  frame_num : Int32,
  poc_lsb : Int32,
  aq : Bool,
) -> Result[Bytes, String] {
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
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(6) // slice_type: B (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num
  r.put(poc_lsb & 15, 4) // pic_order_cnt_lsb
  r.put_bit(1) // direct_spatial_mv_pred_flag
  r.put_bit(0) // num_ref_idx_active_override_flag
  r.put_bit(0) // ref_pic_list_modification_flag_l0
  r.put_bit(0) // ref_pic_list_modification_flag_l1
  // nal_ref_idc == 0: no dec_ref_pic_marking.
  r.put_se(self.p.qp - self.base_qp) // slice_qp_delta
  let mut skip_run = 0
  for mb_y = 0; mb_y < self.mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < self.mb_width; mb_x = mb_x + 1 {
      let mb_idx = mb_y * self.mb_width + mb_x
      self.mb_qp = self.p.qp
      self.mb_dqp = 0
      if aq {
        let adj = h264_aq_adj(
          self.aq_act[mb_idx],
          self.aq_avg,
          self.aq_strength,
        )
        let mut mq = self.p.qp + adj
        if mq < 0 {
          mq = 0
        }
        if mq > 51 {
          mq = 51
        }
        self.mb_qp = mq
        self.mb_dqp = mq - self.prev_qp
        self.chroma_qp = h264_get_chroma_qp(self.pps, 0, mq)
      }
      match self.decide_b_mb(mirror, past_y, fut_y, mb_x, mb_y, self.mb_qp) {
        Ok((BSkip, _)) => skip_run = skip_run + 1
        Ok((plan, coded)) => {
          r.put_ue(skip_run)
          skip_run = 0
          match coded {
            Some(c) => self.write_b_mb_syntax(mirror, mb_x, mb_y, plan, c, r)
            None => ()
          }
        }
        Err(e) => return Err(e)
      }
    }
  }
  if skip_run > 0 {
    r.put_ue(skip_run)
  }
  r.trailing_bits()
  Ok(h264_enc_nal(r, 0, 1)) // non-reference slice: nal_ref_idc 0, type 1
}

///|
/// The B-slice skip-flag context: `24 + (left coded non-skip) + (top coded
/// non-skip)` — the encoder-side twin of `h264_cabac_mb_skip`'s B base
/// (`ctx_off = 24` for `slice_type_nos == 1`), with the same
/// "decoded and not skip" neighbour test.
fn h264_cabacw_b_skip_ctx(ctx : H264DecCtx, mb_idx : Int32) -> Int32 {
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
  24 + c
}

///|
/// The B-slice mb_type first-bin context: `27 + (left non-direct) + (top
/// non-direct)`, the mirror of `h264_b_cabac_type`'s neighbour count (an
/// existing neighbour whose mb_type lacks `MB_TYPE_DIRECT` adds one).
fn h264_cabacw_b_type_ctx(ctx : H264DecCtx, mb_idx : Int32) -> Int32 {
  let mut context = 0
  for
    n in [
      if h264_has_left(ctx, mb_idx) {
        mb_idx - 1
      } else {
        -1
      },
      if h264_has_top(ctx, mb_idx) {
        h264_top_index(ctx, mb_idx)
      } else {
        -1
      },
    ] {
    if n >= 0 && (ctx.infos[n].mb_type_bits & h264_mb_type_direct) == 0 {
      context += 1
    }
  }
  27 + context
}

///|
/// Write one coded B macroblock's CABAC bins: the mb_type tree (kinds
/// 0..3 of `h264_b_cabac_type`), the per-list mvd bins (contexts 40/47
/// shared by both lists), then the inter residual tail through the same
/// cbp/dqp/residual writers as the P path. The mirror state was committed
/// by the decision; the 16x16-shape predictors never read the current
/// macroblock, so the re-derived predictions match the decoder's
/// refs-then-mvds order exactly.
fn H264PEncoder::write_b_mb_syntax_cabac(
  self : H264PEncoder,
  mirror : H264DecCtx,
  enc : H264CabacEnc,
  states : Array[Int32],
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let kind = h264_b_plan_kind(plan)
  let tctx = h264_cabacw_b_type_ctx(mirror, mb_idx)
  match kind {
    0 => enc.decision(states, tctx, 0)
    1 => {
      enc.decision(states, tctx, 1)
      enc.decision(states, 30, 0)
      enc.decision(states, 32, 0)
    }
    2 => {
      enc.decision(states, tctx, 1)
      enc.decision(states, 30, 0)
      enc.decision(states, 32, 1)
    }
    _ => {
      // kind 3: 27=1, 30=1, then the 4-bin suffix
      // `bits = (b31<<3) + (b32<<2) + (b32<<1) + b32` with
      // `bits < 8 -> bits + 3`: kind 3 is the all-zero suffix. No
      // continuation bin (that only follows bits >= 8 outside 13..15).
      enc.decision(states, tctx, 1)
      enc.decision(states, 30, 1)
      enc.decision(states, 31, 0)
      enc.decision(states, 32, 0)
      enc.decision(states, 32, 0)
      enc.decision(states, 32, 0)
    }
  }
  let (groups, _parts, _direct, _mb_bits) = h264_b_partitions(kind, [])
  for list in 0..<2 {
    mirror.active_list = list
    for part in groups {
      if (part.mask & (1 << list)) == 0 {
        continue
      }
      let (pmvx, pmvy) = h264_pred_motion(
        mirror,
        mb_idx,
        mb_x,
        mb_y,
        part.x,
        part.y,
        part.w,
        0,
      )
      let (mvx, mvy) = match plan {
        BBi16(a, b, c, d) => if list == 0 { (a, b) } else { (c, d) }
        BL0x16(a, b) => (a, b)
        BL1x16(a, b) => (a, b)
        _ => (0, 0)
      }
      let (lamvd0, lamvd1) = h264_mvd_fetch(
        mirror,
        mb_idx,
        mb_x,
        mb_y,
        part.x - 1,
        part.y,
      )
      let (tamvd0, tamvd1) = h264_mvd_fetch(
        mirror,
        mb_idx,
        mb_x,
        mb_y,
        part.x,
        part.y - 1,
      )
      // The mvd contexts are per-COMPONENT (x 40.., y 47..) shared by both
      // lists; `h264_mvd_fetch` reads the active list's mvd mirror.
      let _ = h264_cabacw_mvd_one(enc, states, 40, lamvd0 + tamvd0, mvx - pmvx)
      let _ = h264_cabacw_mvd_one(enc, states, 47, lamvd1 + tamvd1, mvy - pmvy)
    }
  }
  mirror.active_list = 0
  let info = mirror.infos[mb_idx]
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  h264_cabacw_cbp(enc, states, mirror, mb_idx, mb_x, mb_y, cbp, true)
  info.cbp_all = cbp
  if cbp != 0 {
    h264_cabacw_dqp(enc, states, mirror, self.mb_dqp)
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  } else {
    mirror.last_qscale_diff = 0
  }
  for i8 = 0; i8 < 4; i8 = i8 + 1 {
    if (coded.luma_cbp & (1 << i8)) != 0 {
      for i4 = 0; i4 < 4; i4 = i4 + 1 {
        let i = i8 * 4 + i4
        let view = scan_view_at(coded.luma_store, i, h264_zigzag_scan_t, 0, 16)
        h264_cabacw_residual(
          enc, states, mirror, mb_idx, mb_x, mb_y, 2, i, view, 16, false,
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
        mirror,
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
          mirror,
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
/// Encode one B picture with CABAC entropy: the B-slice header (spatial
/// direct, both lists unmodified, cabac_init_idc 0, non-reference), the
/// same mode decisions as the CAVLC encoder (`decide_b_mb`), and every
/// syntax bin driven from the decoder-context mirror.
fn H264PEncoder::encode_b_frame_cabac(
  self : H264PEncoder,
  mirror : H264DecCtx,
  past_y : Array[Int32],
  fut_y : Array[Int32],
  frame_num : Int32,
  poc_lsb : Int32,
  aq : Bool,
) -> Result[Bytes, String] {
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
  let enc = h264_cabac_enc_new()
  let states = ff_h264_init_cabac_states(self.p.qp, 8, 1, 0)
  // Slice header.
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(6) // slice_type: B (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num
  r.put(poc_lsb & 15, 4) // pic_order_cnt_lsb
  r.put_bit(1) // direct_spatial_mv_pred_flag
  r.put_bit(0) // num_ref_idx_active_override_flag
  r.put_bit(0) // ref_pic_list_modification_flag_l0
  r.put_bit(0) // ref_pic_list_modification_flag_l1
  // nal_ref_idc == 0: no dec_ref_pic_marking.
  r.put_ue(0) // cabac_init_idc
  r.put_se(self.p.qp - self.base_qp) // slice_qp_delta
  while r.bw.nbits != 0 {
    r.put_bit(1) // cabac_alignment_one_bit
  }
  let header = r.finish_raw_of()
  let n_mbs = self.mb_width * self.mb_height
  let mut mb = 0
  for mb_y = 0; mb_y < self.mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < self.mb_width; mb_x = mb_x + 1 {
      let mb_idx = mb_y * self.mb_width + mb_x
      self.mb_qp = self.p.qp
      self.mb_dqp = 0
      if aq {
        let adj = h264_aq_adj(
          self.aq_act[mb_idx],
          self.aq_avg,
          self.aq_strength,
        )
        let mut mq = self.p.qp + adj
        if mq < 0 {
          mq = 0
        }
        if mq > 51 {
          mq = 51
        }
        self.mb_qp = mq
        self.mb_dqp = mq - mirror.qscale
        self.chroma_qp = h264_get_chroma_qp(self.pps, 0, mq)
      }
      match self.decide_b_mb(mirror, past_y, fut_y, mb_x, mb_y, self.mb_qp) {
        Ok((BSkip, _)) => {
          // CABAC has no skip RUN: one mb_skip_flag bin per macroblock.
          let sctx = h264_cabacw_b_skip_ctx(mirror, mb_idx)
          enc.decision(states, sctx, 1)
        }
        Ok((plan, coded)) => {
          let sctx = h264_cabacw_b_skip_ctx(mirror, mb_idx)
          enc.decision(states, sctx, 0)
          match coded {
            Some(c) =>
              self.write_b_mb_syntax_cabac(
                mirror, enc, states, mb_x, mb_y, plan, c,
              )
            None => ()
          }
        }
        Err(e) => return Err(e)
      }
      mb = mb + 1
      enc.terminate(if mb == n_mbs { 1 } else { 0 })
    }
  }
  Ok(h264_cabac_nal(header, enc.to_bytes(), 0, 1))
}

///|
/// Deep-copy a full plane (the reference hand-off between pictures).
fn h264_b_copy_plane(src : Array[Int32]) -> Array[Int32] {
  let out = Array::make(src.length(), 0)
  for i = 0; i < src.length(); i = i + 1 {
    out[i] = src[i]
  }
  out
}

///|
/// The B-slice sequence core (shared by the CAVLC and CABAC public
/// entries; `cabac` selects the entropy of every picture). Coding order:
/// I, P2, B1, P4, B3, ... — every B picture is coded after its future
/// reference, frame reordering is carried by POC type 0 (`poc_lsb =
/// display*2 & 15`; the IDR codes 0), and a non-reference B shares the
/// frame_num of the reference picture that follows it. Returns the stream
/// in CODING order; decoders reorder to display order via the POC.
fn h264_encode_frames_b(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32,
  level_idc~ : Int32,
  aq~ : Bool,
  aq_strength~ : Int32,
  aud~ : Bool,
  cabac~ : Bool,
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
) -> Result[Bytes, String] {
  let n = frames.length()
  let (y0, u0, v0) = frames[0]
  let first = match
    (if cabac {
      h264_encode_intra_frame_cabac(
        y0,
        u0,
        v0,
        width~,
        height~,
        qp~,
        level_idc~,
        stats~,
        pps_qp=qp,
        aq~,
        aq_strength~,
        b_seq=true,
      )
    } else {
      h264_encode_intra_frame(
        y0,
        u0,
        v0,
        width~,
        height~,
        qp~,
        level_idc~,
        stats~,
        pps_qp=qp,
        aq~,
        aq_strength~,
        b_seq=true,
      )
    }) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let p = { width, height, qp, level_idc, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  // Round-trip the B-capable parameter sets: the parsed PPS carries the
  // dequantisation tables the local reconstructions share with the decoder.
  let ps = new_h264_param_sets()
  let sps_rbsp = h264_enc_sps_rbsp_b(p)
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_rbsp), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = if cabac {
    h264_enc_pps_rbsp_cabac(p)
  } else {
    h264_enc_pps_rbsp(p)
  }
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
  if aud {
    stream[0] = h264_enc_concat([h264_enc_aud(true), stream[0]])
  }
  // The reference chain: the most recent reference picture's planes and
  // the encoder-side per-MB mirror (nz persistence across all pictures).
  let mut ref_y = h264_b_copy_plane(first.recon_y)
  let mut ref_u = h264_b_copy_plane(first.recon_u)
  let mut ref_v = h264_b_copy_plane(first.recon_v)
  let states : Array[H264PMbState] = []
  for _k = 0; _k < mb_width * mb_height; _k = _k + 1 {
    states.push(new_h264_p_mb_state())
  }
  for k = 0; k < mb_width * mb_height; k = k + 1 {
    for i = 0; i < 48; i = i + 1 {
      states[k].nz[i] = first.mb_nz[k][i]
    }
  }
  // frame_num of reference pictures: the IDR is 0, each following
  // reference picture increments (B pictures are non-reference and share
  // the frame_num of the reference that follows).
  let mut fn_counter = 0
  fn new_p_encoder(
    y : Bytes,
    u : Bytes,
    v : Bytes,
    ry : Array[Int32],
    ru : Array[Int32],
    rv : Array[Int32],
  ) -> H264PEncoder {
    let src_y_p = load_plane(y, width, height, ystride, pheight)
    let (act, act_avg) = if aq {
      h264_aq_measure(src_y_p, ystride, mb_width, mb_height)
    } else {
      (Array::make(mb_width * mb_height, 0), 0)
    }
    {
      p: { width, height, qp, level_idc, },
      stats,
      pps,
      chroma_qp: h264_get_chroma_qp(pps, 0, qp),
      src_y: src_y_p,
      src_u: load_plane(u, width / 2, height / 2, cstride, pheight / 2),
      src_v: load_plane(v, width / 2, height / 2, cstride, pheight / 2),
      rec_y: Array::make(ystride * pheight, 0),
      rec_u: Array::make(cstride * (pheight / 2), 0),
      rec_v: Array::make(cstride * (pheight / 2), 0),
      ref_y: ry,
      ref_u: ru,
      ref_v: rv,
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
      dct8x8: false,
      intra4x4_in_p: false,
      base_qp: qp,
      mb_qp: qp,
      mb_dqp: 0,
      prev_qp: qp,
      aq_act: act,
      aq_avg: act_avg,
      aq_on: aq,
      aq_strength,
      cabac_rd: false,
      price_mirror: None,
      price_enc: None,
      price_states: None,
    }
  }
  fn push_au(stream : Array[Bytes], parts : Array[Bytes]) -> Unit {
    stream.push(h264_enc_concat(parts))
  }
  let mut e = 1
  while e < n {
    if e + 1 < n {
      // ---- P picture at display position e+1 ----
      fn_counter = fn_counter + 1
      let (y, u, v) = frames[e + 1]
      let enc = new_p_encoder(y, u, v, ref_y, ref_u, ref_v)
      let p_nal = if cabac {
        match
          enc.encode_p_frame_cabac(
            fn_counter,
            false,
            poc_lsb=((e + 1) * 2) & 15,
          ) {
          Ok(x) => x
          Err(er) => return Err(er)
        }
      } else {
        match
          enc.encode_p_frame(fn_counter, false, poc_lsb=((e + 1) * 2) & 15) {
          Ok(x) => x
          Err(er) => return Err(er)
        }
      }
      let au : Array[Bytes] = [p_nal]
      if aud {
        au.insert(0, h264_enc_aud(false))
      }
      push_au(stream, au)
      recon.push(
        h264_enc_pack_recon(
          enc.rec_y,
          enc.rec_u,
          enc.rec_v,
          width,
          height,
          ystride,
          cstride,
        ),
      )
      let p_y = h264_b_copy_plane(enc.rec_y)
      let p_u = h264_b_copy_plane(enc.rec_u)
      let p_v = h264_b_copy_plane(enc.rec_v)
      let p_infos = h264_b_colocated_from_states(states)
      // ---- B picture at display position e ----
      let (by, bu, bv) = frames[e]
      let b_src_y = load_plane(by, width, height, ystride, pheight)
      let (b_act, b_act_avg) = if aq {
        h264_aq_measure(b_src_y, ystride, mb_width, mb_height)
      } else {
        (Array::make(mb_width * mb_height, 0), 0)
      }
      let b_enc : H264PEncoder = {
        p: { width, height, qp, level_idc, },
        stats,
        pps,
        chroma_qp: h264_get_chroma_qp(pps, 0, qp),
        src_y: b_src_y,
        src_u: load_plane(bu, width / 2, height / 2, cstride, pheight / 2),
        src_v: load_plane(bv, width / 2, height / 2, cstride, pheight / 2),
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
        dct8x8: false,
        intra4x4_in_p: false,
        base_qp: qp,
        mb_qp: qp,
        mb_dqp: 0,
        prev_qp: qp,
        aq_act: b_act,
        aq_avg: b_act_avg,
        aq_on: aq,
        aq_strength,
        cabac_rd: false,
        price_mirror: None,
        price_enc: None,
        price_states: None,
      }
      let past_pic = h264_b_refpic(
        ref_y,
        ref_u,
        ref_v,
        ystride,
        cstride,
        pheight,
        (e - 1) * 2,
        0,
      )
      let fut_pic = h264_b_refpic(
        p_y,
        p_u,
        p_v,
        ystride,
        cstride,
        pheight,
        (e + 1) * 2,
        1,
      )
      let mirror = h264_b_mirror_new(
        mb_width,
        mb_height,
        pps,
        qp,
        ystride,
        cstride,
        past_pic,
        fut_pic,
        p_infos,
        b_enc.rec_y,
        b_enc.rec_u,
        b_enc.rec_v,
        e * 2,
      )
      let b_nal = if cabac {
        match
          b_enc.encode_b_frame_cabac(
            mirror,
            ref_y,
            p_y,
            fn_counter,
            (e * 2) & 15,
            aq,
          ) {
          Ok(x) => x
          Err(er) => return Err(er)
        }
      } else {
        match
          b_enc.encode_b_frame(mirror, ref_y, p_y, fn_counter, (e * 2) & 15, aq) {
          Ok(x) => x
          Err(er) => return Err(er)
        }
      }
      let b_au : Array[Bytes] = [b_nal]
      if aud {
        b_au.insert(0, h264_enc_aud_b())
      }
      push_au(stream, b_au)
      recon.push(
        h264_enc_pack_recon(
          b_enc.rec_y,
          b_enc.rec_u,
          b_enc.rec_v,
          width,
          height,
          ystride,
          cstride,
        ),
      )
      // The new reference picture becomes the past of everything after
      // the B picture (which still reads the PREVIOUS reference as its
      // list 0: display e's B sits between e-1's and e+1's references).
      ref_y = p_y
      ref_u = p_u
      ref_v = p_v
      e = e + 2
    } else {
      // ---- trailing P picture (a lone last B has no future) ----
      fn_counter = fn_counter + 1
      let (y, u, v) = frames[e]
      let enc = new_p_encoder(y, u, v, ref_y, ref_u, ref_v)
      let p_nal = if cabac {
        match
          enc.encode_p_frame_cabac(fn_counter, false, poc_lsb=(e * 2) & 15) {
          Ok(x) => x
          Err(er) => return Err(er)
        }
      } else {
        match enc.encode_p_frame(fn_counter, false, poc_lsb=(e * 2) & 15) {
          Ok(x) => x
          Err(er) => return Err(er)
        }
      }
      let au : Array[Bytes] = [p_nal]
      if aud {
        au.insert(0, h264_enc_aud(false))
      }
      push_au(stream, au)
      recon.push(
        h264_enc_pack_recon(
          enc.rec_y,
          enc.rec_u,
          enc.rec_v,
          width,
          height,
          ystride,
          cstride,
        ),
      )
      e = e + 1
    }
  }
  for q = 0; q < n; q = q + 1 {
    stats.frame_qps.push(qp)
  }
  let out : Array[Byte] = []
  for part in stream {
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Ok(Bytes::from_array(out[:]))
}
