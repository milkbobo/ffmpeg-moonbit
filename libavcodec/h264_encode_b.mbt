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
/// dry-run writer by default, or the live CABAC writer with full rollback
/// when `cabac_rd` is enabled.

///|
/// The decided B macroblock plan (kinds 0..3 of Table 7-11, plus the
/// sub-partitioned kinds 4..22 under the `b_parts` opt-in).
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
  /// Intra16x16 inside the B slice (the `intra_in_b` opt-in, kinds
  /// 24..47): the signalled luma mode (encoder numbering DC/H/V/Plane),
  /// the availability-checked effective mode the prediction runs on, and
  /// the signalled chroma prediction mode.
  BI16(Int32, Int32, Int32)
  /// Intra_NxN (4x4) inside the B slice (the `intra4x4_in_b` opt-in,
  /// kind 23): the sixteen signalled `pred4x4` modes on the 4x4 grid
  /// (grid-indexed) and the signalled chroma prediction mode.
  BI4(Array[Int32], Int32)
  /// Intra 8x8 inside the B slice (the `dct8x8` opt-in, kind 23 with
  /// `transform_size_8x8_flag = 1`): the four signalled `pred8x8l` modes
  /// in block order and the signalled chroma prediction mode.
  BI8(Array[Int32], Int32)
  /// Sub-partitioned kinds 4..21 (the B_L0_16x8 .. B_Bi_8x16 two-partition
  /// kinds) and 22 (B_8x8): the kind, the four sub-macroblock types (kind
  /// 22 only, 0 elsewhere) and the quarter-pel MV of every (partition,
  /// list) pair whose mask bit is set, in the decode walk order — list 0's
  /// partitions first, then list 1's, partitions in `h264_b_partitions`
  /// order. The commit walk may adjust entries (clipping an mvd into the
  /// syntax's reachable square), so the array is the single source of
  /// truth for every writer.
  BParts(Int32, Array[Int32], Array[(Int32, Int32)])
}

///|
/// Access-unit delimiter for pictures that may contain B slices:
/// primary_pic_type 2 (I/P/B), nal_ref_idc 0 (H.264 7.4.1).
fn h264_enc_aud_b() -> Bytes {
  b"\x00\x00\x00\x01\x09\x50"
}

///|
/// B-capable SPS RBSP (Main profile, profile_idc 77; High profile 100
/// under `dct8x8` for the 8x8DCT signalling): identical to the Main SPS
/// except `pic_order_cnt_type = 0` (every slice carries
/// `pic_order_cnt_lsb`, 4 bits — the display order travels in the stream)
/// and `max_num_ref_frames = 2` (one past and one future reference). The
/// High variant inserts the chroma_format_idc block (as
/// `h264_enc_sps_body_high`) and drops the constraint flags.
fn h264_enc_sps_rbsp_b(p : H264EncParams, dct8x8~ : Bool = false) -> Bytes {
  let r = H264Rbsp::new()
  if dct8x8 {
    r.put(100, 8) // profile_idc: High
    r.put(0, 8) // constraint_set0..5 + reserved_zero_2bits
  } else {
    r.put(77, 8) // profile_idc: Main
    r.put(0x40, 8) // constraint_set1 (A.2.2)
  }
  r.put(p.level_idc, 8)
  r.put_ue(0) // seq_parameter_set_id
  if dct8x8 {
    r.put_ue(1) // chroma_format_idc: 4:2:0
    r.put_ue(0) // bit_depth_luma_minus8
    r.put_ue(0) // bit_depth_chroma_minus8
    r.put_bit(0) // qpprime_y_zero_transform_bypass_flag
    r.put_bit(0) // seq_scaling_matrix_present_flag
  }
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
fn h264_enc_write_sps_b(p : H264EncParams, dct8x8~ : Bool = false) -> Bytes {
  let body = h264_enc_sps_rbsp_b(p, dct8x8~)
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
/// Integer +-16 then 3x3 subpel motion search of a `w` x `h` block at MB
/// offset (`ox`, `oy`) against an explicit reference plane (the B lists'
/// planes), seeded at the zero MV and the prediction. Returns the
/// quarter-pel MV and its SAD.
fn H264PEncoder::me_b_part(
  self : H264PEncoder,
  ref_plane : Array[Int32],
  mb_x : Int32,
  mb_y : Int32,
  ox : Int32,
  oy : Int32,
  w : Int32,
  h : Int32,
  pmvx : Int32,
  pmvy : Int32,
) -> (Int32, Int32, Int32) {
  let src_row = mb_y * 16 + oy
  let src_col = mb_x * 16 + ox
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
      w,
      h,
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
      w~,
      h~,
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
/// Residual coding of one Intra16x16 B macroblock (the `intra_in_b`
/// opt-in): lays the luma prediction of `eff` and the chroma prediction of
/// `chroma_sig` into the reconstruction planes, then codes the I16x16
/// residual — the Hadamard luma DC block (matrix 0), the cbp-gated 4x4 AC
/// blocks with their DC slot forced empty, and the chroma residual with
/// the intra matrices 1/2. The nC mirror follows the intra syntax (fresh
/// zero counts; the luma AC counts are written only when the cbp signals
/// AC, chroma's only when `cbp&0x20`).
fn H264PEncoder::code_b_mb_i16_residuals(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  eff : Int32,
  chroma_sig : Int32,
  qp : Int32,
) -> H264PMbCode {
  self.predict_i16_planes(mb_x, mb_y, eff, chroma_sig)
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = 0
  }
  let qmul_y = h264_build_dequant4(self.pps, 0, qp)
  let luma_store : Array[Int32] = Array::make(256, 0)
  let luma_dc_store : Array[Int32] = Array::make(16, 0)
  let i16_ac_nz : Array[Int32] = Array::make(16, 0)
  let mut luma_cbp = 0
  let mb : Array[Int32] = Array::make(768, 0)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  // Luma DC: the residual DC of every 4x4 block through the Hadamard.
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
  ignore(h264_enc_luma_dc_hadamard_quant(sums, 0, 4, luma_dc_store, 0, qp))
  let mut any_ac = false
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
      let lv = if s == 0 { 0 } else { levels[s] }
      luma_store[16 * i + s] = lv
      if lv != 0 {
        total = total + 1
        mb[16 * i + s] = h264_enc_dequant_level(lv, qmul_y[s])
      }
    }
    i16_ac_nz[g] = total
    if total != 0 {
      any_ac = true
    }
  }
  if any_ac {
    luma_cbp = 15
    for g = 0; g < 16; g = g + 1 {
      self.cur_nz[g] = i16_ac_nz[g]
    }
  }
  let (chroma_dc_store, chroma_ac_store, chroma_c_cbp) = self.code_b_mb_chroma_intra(
    mb_x, mb_y, chroma_sig, mb,
  )
  // `h264_recon_mb`'s I16 order: scatter the Hadamard DC first, then the
  // per-block IDCT (or the DC-only add for blocks with no AC levels).
  let mut dc_total = 0
  for s = 0; s < 16; s = s + 1 {
    if luma_dc_store[s] != 0 {
      dc_total = dc_total + 1
    }
  }
  if dc_total > 0 {
    let dc_raw : Array[Int32] = Array::make(16, 0)
    for s = 0; s < 16; s = s + 1 {
      dc_raw[s] = luma_dc_store[s]
    }
    h264_luma_dc_dequant_idct(mb, 0, dc_raw, 0, qmul_y[0], bit_depth=8)
  }
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * self.ystride + gx * 4
    if i16_ac_nz[g] != 0 {
      h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
    } else if mb[16 * i] != 0 {
      h264_idct_dc_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
    }
  }
  {
    luma_cbp,
    chroma_c_cbp,
    luma_store,
    luma_dc_store,
    chroma_dc_store,
    chroma_ac_store,
    dct8: false,
    luma8_store: Array::make(256, 0),
  }
}

///|
/// The intra chroma chain shared by the B slice's I16x16 and Intra_NxN
/// candidates: lay `chroma_sig`'s prediction into the chroma
/// reconstruction planes, code the Hadamard DC and the AC residuals with
/// the intra matrices 1/2, follow the intra nC semantics (counts written
/// only when cbp&0x20) and reconstruct into the planes. Fills the chroma
/// sections of the shared `mb` dequant buffer.
fn H264PEncoder::code_b_mb_chroma_intra(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  chroma_sig : Int32,
  mb : Array[Int32],
) -> (Array[Array[Int32]], Array[Array[Int32]], Int32) {
  self.predict_intra_chroma(mb_x, mb_y, chroma_sig)
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
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
  // Intra chroma nC: the counts are only touched when cbp&0x20 (ccb == 2);
  // the zero seed survives otherwise.
  if chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
        self.cur_nz[16 + 16 * c + i] = chroma_ac_nz_mirror[16 + 16 * c + i]
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
  (chroma_dc_store, chroma_ac_store, chroma_c_cbp)
}

///|
/// Residual coding of one Intra_NxN (4x4) B macroblock (the
/// `intra4x4_in_b` opt-in): the shared sequential pass replays the plan's
/// sixteen signalled modes — each block predicted from the reconstruction
/// built so far, quantised with the intra matrix 0 and reconstructed in
/// place — then the shared intra chroma chain. The nC mirror carries every
/// block's count (the decoder's intra seed is zero, so uncoded blocks read
/// fresh zeros).
fn H264PEncoder::code_b_mb_i4_residuals(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  raw_modes : Array[Int32],
  chroma_sig : Int32,
  qp : Int32,
) -> H264PMbCode {
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = 0
  }
  let luma_store : Array[Int32] = Array::make(256, 0)
  let mb : Array[Int32] = Array::make(768, 0)
  let scratch_modes : Array[Int32] = Array::make(16, 0)
  let mut luma_cbp = 0
  match
    h264_enc_luma_i4_pass(
      self.src_y,
      self.rec_y,
      self.ystride,
      mb_x,
      mb_y,
      self.pps,
      qp,
      luma_store,
      scratch_modes,
      mb,
      h264_enc_i4_avail(mb_x, mb_y, self.mb_width),
      fixed_modes=raw_modes,
    ) {
    Ok((_, cbp)) => luma_cbp = cbp
    Err(e) => abort("h264 enc b: I4 replay failed: \{e}")
  }
  for i = 0; i < 16; i = i + 1 {
    let g = h264_luma_block_y[i] * 4 + h264_luma_block_x[i]
    let mut total = 0
    for s = 0; s < 16; s = s + 1 {
      if luma_store[16 * i + s] != 0 {
        total = total + 1
      }
    }
    self.cur_nz[g] = total
  }
  let (chroma_dc_store, chroma_ac_store, chroma_c_cbp) = self.code_b_mb_chroma_intra(
    mb_x, mb_y, chroma_sig, mb,
  )
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
/// Residual coding of one Intra 8x8 B macroblock (the `dct8x8` opt-in,
/// kind 23 with `transform_size_8x8_flag = 1`): the shared sequential pass
/// replays the plan's four `pred8x8l` modes — each 8x8 block predicted
/// from the reconstruction built so far, transformed with the 8x8 DCT,
/// quantised with the intra matrix 0 and reconstructed in place — then
/// the shared intra chroma chain. The luma nC mirror stays at the intra
/// zero seed; the syntax layer fills it progressively.
fn H264PEncoder::code_b_mb_i8_residuals(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  raw_modes : Array[Int32],
  chroma_sig : Int32,
  qp : Int32,
) -> H264PMbCode {
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = 0
  }
  let luma_store : Array[Int32] = Array::make(256, 0)
  let luma8_store : Array[Int32] = Array::make(256, 0)
  let mb : Array[Int32] = Array::make(768, 0)
  let scratch_modes : Array[Int32] = Array::make(16, 0)
  let mut luma_cbp = 0
  match
    h264_enc_luma_i8_pass(
      self.src_y,
      self.rec_y,
      self.ystride,
      mb_x,
      mb_y,
      self.pps,
      qp,
      luma8_store,
      scratch_modes,
      mb,
      h264_enc_i8_avail(mb_x, mb_y, self.mb_width),
      fixed_modes=raw_modes,
    ) {
    Ok((_, cbp)) => luma_cbp = cbp
    Err(e) => abort("h264 enc b: I8 replay failed: \{e}")
  }
  let (chroma_dc_store, chroma_ac_store, chroma_c_cbp) = self.code_b_mb_chroma_intra(
    mb_x, mb_y, chroma_sig, mb,
  )
  {
    luma_cbp,
    chroma_c_cbp,
    luma_store,
    luma_dc_store: Array::make(16, 0),
    chroma_dc_store,
    chroma_ac_store,
    dct8: true,
    luma8_store,
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
    BParts(kind, _, _) => kind
    BI16(_, _, _) => 23
    BI4(_, _) => 23
    BI8(_, _) => 23
    BSkip => 0
  }
}

///|
/// Reset the mirror's current-macroblock motion slot to the state
/// `h264_decode_b_mb`'s macroblock entry sees on the per-picture fresh
/// infos: zero MVs and mvds, `LIST_NOT_USED` (-1) references on both
/// lists (the decoder's own entry reset), no direct flags. The
/// sub-partition write paths replay the decoder's refs-then-mvds order on
/// top of exactly this state, so every mvd prediction sees the same
/// neighbours the decoder reads — including the not-yet-written cells of
/// later partitions, whose stale (zero MV, -1 ref) values participate in
/// the median through `mv_fetch`'s same-macroblock path.
fn h264_b_slot_reset(mirror : H264DecCtx, mb_idx : Int32) -> Unit {
  let info = mirror.infos[mb_idx]
  for i = 0; i < 32; i = i + 1 {
    info.mv[i] = 0
    info.mv1[i] = 0
    info.mvd[i] = 0
    info.mvd1[i] = 0
  }
  for i = 0; i < 16; i = i + 1 {
    info.ref_idx[i] = -1
    info.ref_idx1[i] = -1
    info.direct[i] = false
  }
}

///|
/// The decoder's sub-partition mvd pass (`h264_decode_b_mb`'s per-list
/// loop), replayed on `mirror` whose current-macroblock slot already
/// holds the plan's reference state: per B_8x8 group the reference
/// preamble (direct groups restore their hidden top-left cell from the
/// sibling the way the decoder does, inter groups write their 2x2
/// reference), then per partition the prediction — `pred_16x8` /
/// `pred_8x16` for the two-partition kinds 4..21 (the decoder skips
/// `pred_motion` for exactly those kinds), `pred_motion` per part for
/// B_8x8 — handed to `visit` with the walk index of the (partition,
/// list) pair. The walk index enumerates list 0's masked partitions
/// first, then list 1's, matching `H264BPlan::BParts`' mvs order.
fn h264_b_mvd_walk(
  mirror : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  kind : Int32,
  parts : Array[H264BPart],
  direct : Array[Bool],
  visit : (H264BPart, Int32, Int32, Int32) -> Unit,
) -> Unit {
  let info = mirror.infos[mb_idx]
  let mut mi = 0
  for list in 0..<2 {
    mirror.active_list = list
    for group in 0..<(if kind == 22 { 4 } else { 1 }) {
      let gx = (group & 1) * 2
      let gy = (group >> 1) * 2
      if kind == 22 {
        let cache = if list == 0 { info.ref_idx } else { info.ref_idx1 }
        if direct[group] {
          cache[gy * 4 + gx] = cache[gy * 4 + gx + 1]
        } else {
          h264_write_back_ref(mirror, mb_idx, gx, gy, 2, 2, 0)
        }
      }
      for part in parts {
        if kind == 22 && part.group != group {
          continue
        }
        if (part.mask & (1 << list)) == 0 {
          continue
        }
        let (pmvx, pmvy) = if kind < 22 {
          if (kind & 1) == 0 {
            h264_pred_16x8_motion(mirror, mb_idx, mb_x, mb_y, part.group, 0)
          } else {
            h264_pred_8x16_motion(mirror, mb_idx, mb_x, mb_y, part.group, 0)
          }
        } else {
          h264_pred_motion(
            mirror,
            mb_idx,
            mb_x,
            mb_y,
            part.x,
            part.y,
            part.w,
            0,
          )
        }
        visit(part, mi, pmvx, pmvy)
        mi = mi + 1
      }
    }
  }
  mirror.active_list = 0
}

///|
/// Commit a sub-partitioned B plan (kinds 4..22) into the mirror in the
/// decoder's `h264_decode_b_mb` order: a fresh slot, the direct groups'
/// spatial motion (`h264_b_direct` on the plan's own direct flags), the
/// B_8x8 right-hand groups' hidden top-left references, the per-list
/// reference write-backs of the two-partition kinds, then the per-list
/// mvds against the decoder's own predictors. Every mvd is clipped into
/// the syntax's reachable square and the plan's MV entry adjusted with
/// the clip, so the mirror, the emitted bitstream and the reconstruction
/// stay one consistent decision.
fn h264_b_commit_parts(
  mirror : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  skip : Bool,
) -> Unit {
  let (kind, subs, mvs) = match plan {
    BParts(k, s, m) => (k, s, m)
    _ => abort("h264 enc b: commit_parts on a 16x16 plan")
  }
  let info = mirror.infos[mb_idx]
  h264_b_slot_reset(mirror, mb_idx)
  let (groups, parts, direct, mb_bits) = h264_b_partitions(kind, subs)
  info.mb_type_bits = mb_bits | (if skip { h264_mb_type_skip } else { 0 })
  if direct.any(fn(value) { value }) {
    match h264_b_direct(mirror, mb_idx, direct) {
      Ok(_) => ()
      Err(e) => abort("h264 enc b: parts direct failed: \{e}")
    }
  }
  if kind == 22 {
    // The decoder hides the right-hand groups' top-left reference until
    // that group's motion pass; predictions that would read it fall back
    // to the above-left cell instead.
    for block in [2, 10] {
      info.ref_idx[block] = -2
      info.ref_idx1[block] = -2
    }
  }
  if kind < 22 {
    // References first, list by list, partition by partition (the
    // decoder's ref loop for the two-partition kinds; B_8x8's references
    // are written by the per-group preamble of the mvd pass below, which
    // is where the decoder's own kind-22 cache mutations happen).
    for list in 0..<2 {
      mirror.active_list = list
      for part in groups {
        if (part.mask & (1 << list)) == 0 {
          continue
        }
        h264_write_back_ref(mirror, mb_idx, part.x, part.y, part.w, part.h, 0)
      }
    }
  }
  h264_b_mvd_walk(mirror, mb_idx, mb_x, mb_y, kind, parts, direct, (
    part,
    mi,
    pmvx,
    pmvy,
  ) => {
    let (mvx, mvy) = mvs[mi]
    let dx = (mvx - pmvx).max(-70).min(70)
    let dy = (mvy - pmvy).max(-70).min(70)
    if dx != mvx - pmvx || dy != mvy - pmvy {
      mvs[mi] = (pmvx + dx, pmvy + dy)
    }
    h264_write_back_part(
      mirror,
      mb_idx,
      part.x,
      part.y,
      part.w,
      part.h,
      pmvx + dx,
      pmvy + dy,
      0,
      dx.abs(),
      dy.abs(),
    )
  })
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
  match plan {
    BI16(_, _, _) => {
      // The decoder's intra branch leaves the motion cells untouched (the
      // per-picture fresh values) and marks the macroblock intra; the
      // residual tail's own state (cbp_all/chroma_mode) is written by the
      // syntax writer.
      h264_b_slot_reset(mirror, mb_idx)
      info.mb_type_bits = h264_mb_type_intra16x16
      info.intra4x4 = false
      return
    }
    BI4(_, _) => {
      h264_b_slot_reset(mirror, mb_idx)
      info.mb_type_bits = h264_mb_type_intra4x4
      info.intra4x4 = true
      return
    }
    BI8(_, _) => {
      h264_b_slot_reset(mirror, mb_idx)
      info.mb_type_bits = h264_mb_type_intra4x4
      info.intra4x4 = true
      info.transform_8x8 = true
      return
    }
    _ => ()
  }
  let kind = h264_b_plan_kind(plan)
  if kind >= 4 {
    h264_b_commit_parts(mirror, mb_idx, mb_x, mb_y, plan, skip)
    return
  }
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
  match plan {
    BI16(_, _, _) => {
      self.write_b_mb_i16_syntax(mirror, mb_x, mb_y, plan, coded, r)
      return
    }
    BI4(_, _) => {
      self.write_b_mb_i4_syntax(mirror, mb_x, mb_y, plan, coded, r)
      return
    }
    BI8(_, _) => {
      self.write_b_mb_i8_syntax(mirror, mb_x, mb_y, plan, coded, r)
      return
    }
    _ => ()
  }
  if kind >= 4 {
    self.write_b_mb_parts_syntax(mirror, mb_x, mb_y, plan, coded, r)
    return
  }
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
  self.write_b_residual_tail_cavlc(mirror, mb_idx, mb_x, mb_y, coded, r, true)
}

///|
/// The CAVLC inter residual tail shared by every B macroblock kind: the
/// cbp codeword, `mb_qp_delta`, cbp-gated 4x4 luma and the chroma
/// residual (4x4 transform only — B never sets `transform_size_8x8_flag`).
fn H264PEncoder::write_b_residual_tail_cavlc(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  coded : H264PMbCode,
  r : H264Rbsp,
  dct8_allowed : Bool,
) -> Unit {
  ignore(mirror)
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  r.put_ue(h264_enc_inter_cbp_golomb(cbp))
  if self.dct8x8 && dct8_allowed && (cbp & 15) != 0 {
    // transform_size_8x8_flag: the B inter residual stays 4x4 even under
    // the dct8x8 High-profile signalling.
    r.put_bit(0)
  }
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
/// Write one Intra_NxN (4x4) B macroblock's CAVLC syntax
/// (`intra4x4_in_b`): the mb_type codeword 23 (the I-slice intra table's
/// I_NxN shifted by 23 — the decoder's `kind - 23` feeds the shared intra
/// path), the sixteen differentially-coded prediction modes, the chroma
/// prediction mode, the INTRA cbp codeword, the cbp-gated `mb_qp_delta`,
/// the sixteen cbp-gated 4x4 luma residuals and the chroma residual. No
/// `transform_size_8x8_flag` exists here (the B slices' PPS keeps 8x8DCT
/// off).
fn H264PEncoder::write_b_mb_i4_syntax(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
  r : H264Rbsp,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let (raw_modes, chroma_mode) = match plan {
    BI4(m, c) => (m, c)
    _ => abort("h264 enc b: i4 syntax on a non-I4 plan")
  }
  let info = mirror.infos[mb_idx]
  info.mb_type_bits = h264_mb_type_intra4x4
  info.intra4x4 = true
  info.chroma_mode = chroma_mode
  info.cbp_all = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  r.put_ue(23)
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let predicted = self.pred_nxn_mode(mb_idx, mb_x, mb_y, gx, gy, raw_modes)
    let mode = raw_modes[g]
    if mode == predicted {
      r.put_bit(1)
    } else {
      r.put_bit(0)
      r.put(if mode > predicted { mode - 1 } else { mode }, 3)
    }
  }
  r.put_ue(chroma_mode)
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  r.put_ue(h264_enc_cbp_golomb(cbp))
  if cbp != 0 {
    r.put_se(self.mb_dqp)
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
/// Write one Intra 8x8 B macroblock's CAVLC syntax (the `dct8x8` opt-in):
/// the mb_type codeword 23 (I_NxN), `transform_size_8x8_flag = 1` (the
/// decoder reads the flag unconditionally on the I_NxN branch once the
/// PPS enables the mode), the four differentially-coded `pred8x8l` modes
/// on the 2x2-replicated grid, the chroma prediction mode, the INTRA cbp
/// codeword, the cbp-gated `mb_qp_delta`, the cbp-gated 8x8 luma
/// residuals (four interleaved 16-coefficient sub-lists per quadrant) and
/// the chroma residual.
fn H264PEncoder::write_b_mb_i8_syntax(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
  r : H264Rbsp,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let (raw_modes, chroma_mode) = match plan {
    BI8(m, c) => (m, c)
    _ => abort("h264 enc b: i8 syntax on a non-I8 plan")
  }
  let info = mirror.infos[mb_idx]
  info.mb_type_bits = h264_mb_type_intra4x4
  info.intra4x4 = true
  info.transform_8x8 = true
  info.chroma_mode = chroma_mode
  info.cbp_all = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  r.put_ue(23)
  r.put_bit(1) // transform_size_8x8_flag
  let cur : Array[Int32] = Array::make(16, 0)
  for k = 0; k < 4; k = k + 1 {
    for dy in 0..<2 {
      for dx in 0..<2 {
        cur[(k / 2 * 2 + dy) * 4 + k % 2 * 2 + dx] = raw_modes[k]
      }
    }
  }
  for k = 0; k < 4; k = k + 1 {
    let predicted = self.pred_nxn_mode(
      mb_idx,
      mb_x,
      mb_y,
      k % 2 * 2,
      k / 2 * 2,
      cur,
    )
    let mode = raw_modes[k]
    if mode == predicted {
      r.put_bit(1)
    } else {
      r.put_bit(0)
      r.put(if mode > predicted { mode - 1 } else { mode }, 3)
    }
  }
  r.put_ue(chroma_mode)
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  r.put_ue(h264_enc_cbp_golomb(cbp))
  if cbp != 0 {
    r.put_se(self.mb_dqp)
    self.prev_qp = self.mb_qp
    if self.mb_dqp != 0 {
      self.stats.dqp_mbs += 1
    }
  }
  self.write_luma8_cavlc(r, mb_idx, mb_x, mb_y, coded)
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
/// Write one sub-partitioned B macroblock's CAVLC syntax (kinds 4..22):
/// the mb_type codeword, B_8x8's four sub-macroblock types, then the
/// per-list partition mvds emitted while REPLAYING the decoder's read
/// order on a fresh mirror slot — direct groups' spatial motion, the
/// reference write-backs, per-group reference preambles for B_8x8, and
/// each mvd against the decoder's own predictor (`pred_16x8` /
/// `pred_8x16` for the two-partition kinds, `pred_motion` per part for
/// B_8x8) with the write-back the decoder performs after reading it. The
/// replay makes every prediction see exactly the neighbours the decoder
/// sees, including the not-yet-written cells of later partitions.
fn H264PEncoder::write_b_mb_parts_syntax(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
  r : H264Rbsp,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let (kind, subs, mvs) = match plan {
    BParts(k, s, m) => (k, s, m)
    _ => abort("h264 enc b: parts syntax on a 16x16 plan")
  }
  let info = mirror.infos[mb_idx]
  h264_b_slot_reset(mirror, mb_idx)
  let (groups, parts, direct, mb_bits) = h264_b_partitions(kind, subs)
  info.mb_type_bits = mb_bits
  if direct.any(fn(value) { value }) {
    match h264_b_direct(mirror, mb_idx, direct) {
      Ok(_) => ()
      Err(e) => abort("h264 enc b: parts syntax direct failed: \{e}")
    }
  }
  if kind == 22 {
    for block in [2, 10] {
      info.ref_idx[block] = -2
      info.ref_idx1[block] = -2
    }
  }
  r.put_ue(kind)
  if kind == 22 {
    for s in subs {
      r.put_ue(s)
    }
  }
  // References: a single reference per list, so neither entropy coder
  // reads reference bits — only the mirror state advances.
  if kind < 22 {
    for list in 0..<2 {
      mirror.active_list = list
      for part in groups {
        if (part.mask & (1 << list)) == 0 {
          continue
        }
        h264_write_back_ref(mirror, mb_idx, part.x, part.y, part.w, part.h, 0)
      }
    }
  }
  h264_b_mvd_walk(mirror, mb_idx, mb_x, mb_y, kind, parts, direct, (
    part,
    mi,
    pmvx,
    pmvy,
  ) => {
    let (mvx, mvy) = mvs[mi]
    r.put_se(mvx - pmvx)
    r.put_se(mvy - pmvy)
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
      (mvx - pmvx).abs().min(70),
      (mvy - pmvy).abs().min(70),
    )
  })
  // The residual tail runs against the committed mirror (the walk ends in
  // the decoder's post-macroblock state). The 8x8 transform is only
  // signalled for partitions of at least 8x8.
  self.write_b_residual_tail_cavlc(
    mirror,
    mb_idx,
    mb_x,
    mb_y,
    coded,
    r,
    parts.all(fn(part) { part.w >= 2 && part.h >= 2 }),
  )
}

///|
/// Write one Intra16x16 B macroblock's CAVLC syntax (`intra_in_b`): the
/// mb_type codeword 24..47 (the I-slice intra table 1..24 shifted by 23 —
/// the decoder's `kind - 23` feeds the shared intra path), the chroma
/// prediction mode, the unconditional `mb_qp_delta`, the Hadamard luma DC
/// block, the cbp-gated 4x4 luma AC blocks and the chroma residual. No cbp
/// codeword exists for I16x16 — the decoder derives the group from
/// mb_type.
fn H264PEncoder::write_b_mb_i16_syntax(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
  r : H264Rbsp,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let (sig, chroma_mode) = match plan {
    BI16(s, _, c) => (s, c)
    _ => abort("h264 enc b: i16 syntax on a non-I16 plan")
  }
  let info = mirror.infos[mb_idx]
  info.mb_type_bits = h264_mb_type_intra16x16
  info.intra4x4 = false
  info.chroma_mode = chroma_mode
  info.cbp_all = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  let group = if coded.luma_cbp != 0 {
    3 + coded.chroma_c_cbp
  } else {
    coded.chroma_c_cbp
  }
  // Encoder pred16 numbering DC/H/V/Plane -> spec Table 7-11 V/H/DC/Plane.
  let spec_mode = match sig {
    0 => 2
    1 => 1
    2 => 0
    _ => 3
  }
  r.put_ue(23 + 1 + spec_mode + 4 * group)
  r.put_ue(chroma_mode)
  r.put_se(self.mb_dqp)
  self.prev_qp = self.mb_qp
  if self.mb_dqp != 0 {
    self.stats.dqp_mbs += 1
  }
  let dc_scan : Array[Int32] = scan_view_at(
    coded.luma_dc_store,
    0,
    h264_zigzag_scan_t,
    0,
    16,
  )
  ignore(
    h264_enc_write_residual(r, dc_scan, 16, self.nc_block0(mb_idx, mb_x, mb_y)),
  )
  if coded.luma_cbp != 0 {
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let view = scan_view_at(coded.luma_store, i, h264_zigzag_scan_t, 1, 15)
      let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
      let n = h264_enc_write_residual(r, view, 15, nc)
      self.cur_nz[gy * 4 + gx] = n
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
/// SAD of a sub-rectangle of the macroblock luma (the per-group direct
/// cost of the B_8x8 candidate).
fn H264PEncoder::b_region_sad(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  ox : Int32,
  oy : Int32,
  w : Int32,
  h : Int32,
) -> Int32 {
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut sad = 0
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let d = self.src_y[ybase + (oy + row) * self.ystride + ox + col] -
        self.rec_y[ybase + (oy + row) * self.ystride + ox + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// SAD of a sub-rectangle against the bidirectional average of two fixed
/// MVs (the per-group Bi cost of the B_8x8 candidate; the decoder's
/// `(a + b + 1) >> 1` round).
fn H264PEncoder::b_bi_part_sad(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  ox : Int32,
  oy : Int32,
  w : Int32,
  h : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
) -> Int32 {
  let a = h264_b_prediction(mirror, 0, 0, mb_x, mb_y, ox, oy, w, h, mv0x, mv0y)
  let b = h264_b_prediction(mirror, 1, 0, mb_x, mb_y, ox, oy, w, h, mv1x, mv1y)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut sad = 0
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let i = row * w + col
      let p = (a[0][i] + b[0][i] + 1) >> 1
      let d = self.src_y[ybase + (oy + row) * self.ystride + ox + col] - p
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// Price one non-skip B candidate through the live CABAC writer. Restore
/// arithmetic state, contexts, motion, residual neighbour state and counters
/// so neither the next candidate nor the final write observes the trial.
/// The CAVLC estimate remains the fallback when CABAC pricing is disabled.
/// The 16x16 kinds commit their motion into the mirror first (and roll it
/// back after); the sub-partitioned kinds' write path replays the decoder's
/// read order on a fresh slot by itself, so only the residual-mirror and
/// counter state needs the rollback.
fn H264PEncoder::price_b_bits(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  coded : H264PMbCode,
  fallback : Int64,
) -> Int64 {
  let (enc, states) = match (self.price_enc, self.price_states) {
    (Some(e), Some(s)) => (e, s)
    _ => return fallback
  }
  let mb_idx = mb_y * self.mb_width + mb_x
  let info = mirror.infos[mb_idx]
  let kind = h264_b_plan_kind(plan)
  let motion = h264_b_mb_snapshot(info)
  let snap_motion = kind < 4
  let nz = info.nz.copy()
  let cbp = info.cbp_all
  let mb_type = info.mb_type_bits
  let chroma_mode = info.chroma_mode
  let was_intra = mirror.cur_mb_is_intra
  let was_intra4x4 = info.intra4x4
  let was_tf8 = info.transform_8x8
  let modes = info.modes.copy()
  let qp = info.qp
  let qscale = mirror.qscale
  let qdiff = mirror.last_qscale_diff
  let active = mirror.active_list
  let dqp_mbs = self.stats.dqp_mbs
  let low = enc.low
  let range = enc.range
  let outstanding = enc.outstanding
  let nbits = enc.bits.length()
  let saved_states = states.copy()
  if snap_motion {
    h264_b_commit_mb(mirror, mb_idx, mb_x, mb_y, plan, false)
  }
  for i in 0..<48 {
    info.nz[i] = 0
  }
  enc.decision(
    states,
    h264_cabacw_b_skip_ctx(mirror, mb_y * self.mb_width + mb_x),
    0,
  )
  self.write_b_mb_syntax_cabac(mirror, enc, states, mb_x, mb_y, plan, coded)
  let bits = enc.bits.length() - nbits
  enc.low = low
  enc.range = range
  enc.outstanding = outstanding
  enc.bits.truncate(nbits)
  for i in 0..<states.length() {
    states[i] = saved_states[i]
  }
  if snap_motion {
    h264_b_mb_restore(info, motion)
  }
  for i in 0..<48 {
    info.nz[i] = nz[i]
  }
  info.cbp_all = cbp
  info.mb_type_bits = mb_type
  info.chroma_mode = chroma_mode
  mirror.cur_mb_is_intra = was_intra
  info.intra4x4 = was_intra4x4
  info.transform_8x8 = was_tf8
  for i in 0..<16 {
    info.modes[i] = modes[i]
  }
  info.qp = qp
  mirror.qscale = qscale
  mirror.last_qscale_diff = qdiff
  mirror.active_list = active
  self.stats.dqp_mbs = dqp_mbs
  bits.to_int64()
}

///|
/// Sub-partitioned candidate evaluation (kinds 4..22): commit the plan
/// through the decoder's own mutation order (the walk also clips every
/// mvd into the syntax's reachable square, adjusting the plan's MVs),
/// compensate with the decoder's own per-4x4 MC, code the residuals and
/// price the exact syntax (SSD plus the lambda-weighted bit count, the
/// live CABAC writer's bits when `cabac_rd` is on). Returns the cost and
/// the coded residuals of this candidate.
fn H264PEncoder::eval_b_parts(
  self : H264PEncoder,
  mirror : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264BPlan,
  qp : Int32,
  lam : Int64,
) -> Result[(Int64, H264PMbCode), String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  h264_b_commit_mb(mirror, mb_idx, mb_x, mb_y, plan, false)
  match h264_b_compensate(mirror, mb_idx) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc b: parts MC failed: \{e}")
  }
  let coded = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let ssd = self.b_mb_ssd(mb_x, mb_y)
  let cw = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, plan, coded, cw)
  let bits = (cw.bw.buf.length() * 8 + cw.bw.nbits).to_int64()
  let cost = ssd.to_int64() * 1024L +
    lam * self.price_b_bits(mirror, mb_x, mb_y, plan, coded, bits)
  Ok((cost, coded))
}

///|
/// Select direct, L0, L1 or bidirectional prediction and commit the winner.
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
  // Per-group SADs of the direct trial's reconstruction — the B_8x8
  // candidate's per-group direct cost, captured before any other
  // candidate overwrites the reconstruction.
  let direct_group_sads : Array[Int32] = if self.b_parts {
    [
      self.b_region_sad(mb_x, mb_y, 0, 0, 8, 8),
      self.b_region_sad(mb_x, mb_y, 8, 0, 8, 8),
      self.b_region_sad(mb_x, mb_y, 0, 8, 8, 8),
      self.b_region_sad(mb_x, mb_y, 8, 8, 8, 8),
    ]
  } else {
    [0, 0, 0, 0]
  }
  // Candidates: direct-with-residual, L0, L1, Bi. The predictors of the
  // single-partition kinds never read the current macroblock, so the
  // direct trial's state may stay while they are priced.
  mirror.active_list = 0
  let (p0x, p0y) = h264_pred_motion(mirror, mb_idx, mb_x, mb_y, 0, 0, 4, 0)
  mirror.active_list = 1
  let (p1x, p1y) = h264_pred_motion(mirror, mb_idx, mb_x, mb_y, 0, 0, 4, 0)
  mirror.active_list = 0
  let (mv0x, mv0y, _sad0) = self.me_b_part(
    past_y, mb_x, mb_y, 0, 0, 16, 16, p0x, p0y,
  )
  let (mv1x, mv1y, _sad1) = self.me_b_part(
    fut_y, mb_x, mb_y, 0, 0, 16, 16, p1x, p1y,
  )
  let lam = h264_rd_lambda(qp).to_int64()
  fn bits_of(cw : H264Rbsp) -> Int64 {
    (cw.bw.buf.length() * 8 + cw.bw.nbits).to_int64()
  }
  // Direct candidate (reconstruction already in place from the trial).
  let ssd_d = self.b_mb_ssd(mb_x, mb_y)
  let coded_d = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_d = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, BDirect16, coded_d, cw_d)
  let cost_d = ssd_d.to_int64() * 1024L +
    lam *
    self.price_b_bits(mirror, mb_x, mb_y, BDirect16, coded_d, bits_of(cw_d))
  // L0 candidate.
  self.mc_b_uni_into_rec(mirror, 0, mb_x, mb_y, mv0x, mv0y)
  let ssd_0 = self.b_mb_ssd(mb_x, mb_y)
  let coded_0 = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_0 = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, BL0x16(mv0x, mv0y), coded_0, cw_0)
  let cost_0 = ssd_0.to_int64() * 1024L +
    lam *
    self.price_b_bits(
      mirror,
      mb_x,
      mb_y,
      BL0x16(mv0x, mv0y),
      coded_0,
      bits_of(cw_0),
    )
  // L1 candidate.
  self.mc_b_uni_into_rec(mirror, 1, mb_x, mb_y, mv1x, mv1y)
  let ssd_1 = self.b_mb_ssd(mb_x, mb_y)
  let coded_1 = self.code_b_mb_residuals(mb_x, mb_y, qp)
  let cw_1 = H264Rbsp::new()
  self.write_b_mb_syntax(mirror, mb_x, mb_y, BL1x16(mv1x, mv1y), coded_1, cw_1)
  let cost_1 = ssd_1.to_int64() * 1024L +
    lam *
    self.price_b_bits(
      mirror,
      mb_x,
      mb_y,
      BL1x16(mv1x, mv1y),
      coded_1,
      bits_of(cw_1),
    )
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
  let cost_b = ssd_b.to_int64() * 1024L +
    lam *
    self.price_b_bits(
      mirror,
      mb_x,
      mb_y,
      BBi16(mv0x, mv0y, mv1x, mv1y),
      coded_b,
      bits_of(cw_b),
    )
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
  // ---- Sub-partitioned candidates (opt-in `b_parts`) ----
  if self.b_parts {
    // Per-partition ME for the two-partition kinds: top/bottom 16x8 and
    // left/right 8x16, both lists, seeded at the mirror's whole-macroblock
    // prediction (a hint only; the commit walk clips every mvd into the
    // syntax's reachable square against the real per-partition predictor).
    mirror.active_list = 0
    let (t0x, t0y, ts0) = self.me_b_part(
      past_y, mb_x, mb_y, 0, 0, 16, 8, p0x, p0y,
    )
    let (b0x, b0y, bs0) = self.me_b_part(
      past_y, mb_x, mb_y, 0, 8, 16, 8, p0x, p0y,
    )
    let (l0x, l0y, ls0) = self.me_b_part(
      past_y, mb_x, mb_y, 0, 0, 8, 16, p0x, p0y,
    )
    let (r0x, r0y, rs0) = self.me_b_part(
      past_y, mb_x, mb_y, 8, 0, 8, 16, p0x, p0y,
    )
    mirror.active_list = 1
    let (t1x, t1y, ts1) = self.me_b_part(
      fut_y, mb_x, mb_y, 0, 0, 16, 8, p1x, p1y,
    )
    let (b1x, b1y, bs1) = self.me_b_part(
      fut_y, mb_x, mb_y, 0, 8, 16, 8, p1x, p1y,
    )
    let (l1x, l1y, ls1) = self.me_b_part(
      fut_y, mb_x, mb_y, 0, 0, 8, 16, p1x, p1y,
    )
    let (r1x, r1y, rs1) = self.me_b_part(
      fut_y, mb_x, mb_y, 8, 0, 8, 16, p1x, p1y,
    )
    mirror.active_list = 0
    // The nine per-partition list combinations per orientation
    // (`h264_b_partitions`' mask table; bit 0 = list 0, bit 1 = list 1).
    // The full RD evaluation costs a commit + compensate + residual pass
    // per combination, so the combinations are first ranked by a cheap
    // SAD + lambda*bits estimate and only the best three of each
    // orientation go through `eval_b_parts`.
    let mask_table : Array[(Int32, Int32)] = [
      (1, 1),
      (2, 2),
      (1, 2),
      (2, 1),
      (1, 3),
      (2, 3),
      (3, 1),
      (3, 2),
      (3, 3),
    ]
    // Per-partition SADs by list option: [L0, L1, Bi] (the Bi predictor
    // averages the two ME results, the decoder's (a + b + 1) >> 1 round).
    let t_sads = [
      ts0,
      ts1,
      self.b_bi_part_sad(mirror, mb_x, mb_y, 0, 0, 16, 8, t0x, t0y, t1x, t1y),
    ]
    let b_sads = [
      bs0,
      bs1,
      self.b_bi_part_sad(mirror, mb_x, mb_y, 0, 8, 16, 8, b0x, b0y, b1x, b1y),
    ]
    let l_sads = [
      ls0,
      ls1,
      self.b_bi_part_sad(mirror, mb_x, mb_y, 0, 0, 8, 16, l0x, l0y, l1x, l1y),
    ]
    let r_sads = [
      rs0,
      rs1,
      self.b_bi_part_sad(mirror, mb_x, mb_y, 8, 0, 8, 16, r0x, r0y, r1x, r1y),
    ]
    fn mask_sad(sads : Array[Int32], mask : Int32) -> Int32 {
      if mask == 3 {
        sads[2]
      } else if mask == 2 {
        sads[1]
      } else {
        sads[0]
      }
    }
    fn mask_pairs(mask : Int32) -> Int32 {
      (if (mask & 1) != 0 { 1 } else { 0 }) +
      (if (mask & 2) != 0 { 1 } else { 0 })
    }
    // Rough per-combination costs, stably ordered by (cost, kind) so the
    // ranking is deterministic. The composite key keeps both within Int64.
    fn rank(rough : Array[(Int64, Int32)]) -> Array[Int32] {
      let order : Array[Int32] = []
      for c in 0..<9 {
        order.push(c)
      }
      for a in 0..<9 {
        for b2 = a + 1; b2 < 9; b2 = b2 + 1 {
          let ka = rough[order[a]].0 * 16L + rough[order[a]].1.to_int64()
          let kb = rough[order[b2]].0 * 16L + rough[order[b2]].1.to_int64()
          if kb < ka {
            let t = order[a]
            order[a] = order[b2]
            order[b2] = t
          }
        }
      }
      order
    }
    let rough_h : Array[(Int64, Int32)] = []
    let rough_v : Array[(Int64, Int32)] = []
    for c in 0..<9 {
      let (m0, m1) = mask_table[c]
      let pairs = (mask_pairs(m0) + mask_pairs(m1)) * 20
      rough_h.push(
        (
          (mask_sad(t_sads, m0) + mask_sad(b_sads, m1)).to_int64() +
          lam * pairs.to_int64(),
          c,
        ),
      )
      rough_v.push(
        (
          (mask_sad(l_sads, m0) + mask_sad(r_sads, m1)).to_int64() +
          lam * pairs.to_int64(),
          c,
        ),
      )
    }
    let order_h = rank(rough_h)
    let order_v = rank(rough_v)
    for k in 0..<3 {
      let c = order_h[k]
      let (m0, m1) = mask_table[c]
      // 16x8 (even kinds): top, bottom.
      let mvs_h : Array[(Int32, Int32)] = []
      if (m0 & 1) != 0 {
        mvs_h.push((t0x, t0y))
      }
      if (m1 & 1) != 0 {
        mvs_h.push((b0x, b0y))
      }
      if (m0 & 2) != 0 {
        mvs_h.push((t1x, t1y))
      }
      if (m1 & 2) != 0 {
        mvs_h.push((b1x, b1y))
      }
      let plan_h = BParts(4 + 2 * c, [], mvs_h)
      match self.eval_b_parts(mirror, mb_x, mb_y, plan_h, qp, lam) {
        Ok((cost_h, coded_h)) =>
          if cost_h < cost {
            plan = plan_h
            cost = cost_h
            coded = coded_h
          }
        Err(e) => return Err(e)
      }
      let cv = order_v[k]
      let (v0, v1) = mask_table[cv]
      // 8x16 (odd kinds): left, right.
      let mvs_v : Array[(Int32, Int32)] = []
      if (v0 & 1) != 0 {
        mvs_v.push((l0x, l0y))
      }
      if (v1 & 1) != 0 {
        mvs_v.push((r0x, r0y))
      }
      if (v0 & 2) != 0 {
        mvs_v.push((l1x, l1y))
      }
      if (v1 & 2) != 0 {
        mvs_v.push((r1x, r1y))
      }
      let plan_v = BParts(5 + 2 * cv, [], mvs_v)
      match self.eval_b_parts(mirror, mb_x, mb_y, plan_v, qp, lam) {
        Ok((cost_v, coded_v)) =>
          if cost_v < cost {
            plan = plan_v
            cost = cost_v
            coded = coded_v
          }
        Err(e) => return Err(e)
      }
    }
    // ---- B_8x8: per-group sub-macroblock decision ----
    // Each 8x8 group picks among direct and L0/L1/Bi at 8x8, 8x4, 4x8 and
    // 4x4 by summed partition SAD plus a lambda-weighted motion-bit
    // estimate (the assembled plan is priced exactly afterwards).
    let subs : Array[Int32] = [0, 0, 0, 0]
    let g_mvs0 : Array[Array[(Int32, Int32)]] = [[], [], [], []]
    let g_mvs1 : Array[Array[(Int32, Int32)]] = [[], [], [], []]
    for g in 0..<4 {
      let gx8 = (g & 1) * 8
      let gy8 = (g >> 1) * 8
      let shape_rects : Array[(Int32, Array[(Int32, Int32, Int32, Int32)])] = [
        // Sub-macroblock shapes in `h264_b_partitions`' expansion order
        // (rows outer, columns inner).
        (0, [(gx8, gy8, 8, 8)]),
        (1, [(gx8, gy8, 8, 4), (gx8, gy8 + 4, 8, 4)]),
        (2, [(gx8, gy8, 4, 8), (gx8 + 4, gy8, 4, 8)]),
        (
          3,
          [
            (gx8, gy8, 4, 4),
            (gx8 + 4, gy8, 4, 4),
            (gx8, gy8 + 4, 4, 4),
            (gx8 + 4, gy8 + 4, 4, 4),
          ],
        ),
      ]
      let mut best_sub = 0
      let mut best_cost = direct_group_sads[g].to_int64()
      let mut best_r0 : Array[(Int32, Int32)] = []
      let mut best_r1 : Array[(Int32, Int32)] = []
      for entry in shape_rects {
        let (shape, rects) = entry
        let m0 : Array[(Int32, Int32)] = []
        let m1 : Array[(Int32, Int32)] = []
        let mut sad_l0 = 0
        let mut sad_l1 = 0
        for rect in rects {
          let (ox, oy, w, h) = rect
          mirror.active_list = 0
          let (pm0x, pm0y) = h264_pred_motion(
            mirror,
            mb_idx,
            mb_x,
            mb_y,
            (gx8 + ox) / 4,
            (gy8 + oy) / 4,
            w / 4,
            0,
          )
          let (mx, my, ms) = self.me_b_part(
            past_y, mb_x, mb_y, ox, oy, w, h, pm0x, pm0y,
          )
          m0.push((mx, my))
          sad_l0 = sad_l0 + ms
          mirror.active_list = 1
          let (pm1x, pm1y) = h264_pred_motion(
            mirror,
            mb_idx,
            mb_x,
            mb_y,
            (gx8 + ox) / 4,
            (gy8 + oy) / 4,
            w / 4,
            0,
          )
          let (nx, ny, ns) = self.me_b_part(
            fut_y, mb_x, mb_y, ox, oy, w, h, pm1x, pm1y,
          )
          m1.push((nx, ny))
          sad_l1 = sad_l1 + ns
        }
        mirror.active_list = 0
        let mut sad_bi = 0
        for i in 0..<rects.length() {
          let (ox, oy, w, h) = rects[i]
          sad_bi = sad_bi +
            self.b_bi_part_sad(
              mirror,
              mb_x,
              mb_y,
              ox,
              oy,
              w,
              h,
              m0[i].0,
              m0[i].1,
              m1[i].0,
              m1[i].1,
            )
        }
        let (s_l0, s_l1, s_bi) = match shape {
          0 => (1, 2, 3)
          1 => (4, 6, 8)
          2 => (5, 7, 9)
          _ => (10, 11, 12)
        }
        let pairs = rects.length()
        // ~20 bits per mvd pair (two components), lambda-weighted.
        let bit_cost = lam * (20 * pairs).to_int64()
        let cost_l0 = sad_l0.to_int64() + bit_cost
        let cost_l1 = sad_l1.to_int64() + bit_cost
        let cost_bi = sad_bi.to_int64() + lam * (40 * pairs).to_int64()
        if cost_l0 < best_cost {
          best_cost = cost_l0
          best_sub = s_l0
          best_r0 = m0
          best_r1 = []
        }
        if cost_l1 < best_cost {
          best_cost = cost_l1
          best_sub = s_l1
          best_r0 = []
          best_r1 = m1
        }
        if cost_bi < best_cost {
          best_cost = cost_bi
          best_sub = s_bi
          best_r0 = m0
          best_r1 = m1
        }
      }
      subs[g] = best_sub
      g_mvs0[g] = best_r0
      g_mvs1[g] = best_r1
    }
    // Assemble the plan's mvs array in the decode walk order (list 0's
    // masked partitions first, then list 1's).
    let (_, parts22, _direct22, _) = h264_b_partitions(22, subs)
    let mvs88 : Array[(Int32, Int32)] = []
    let idx : Array[Int32] = [0, 0, 0, 0]
    for list in 0..<2 {
      for part in parts22 {
        if (part.mask & (1 << list)) == 0 {
          continue
        }
        let g = part.group
        let i = idx[g]
        idx[g] = i + 1
        let mv = if list == 0 { g_mvs0[g][i] } else { g_mvs1[g][i] }
        mvs88.push(mv)
      }
    }
    let plan_88 = BParts(22, subs, mvs88)
    match self.eval_b_parts(mirror, mb_x, mb_y, plan_88, qp, lam) {
      Ok((cost_88, coded_88)) =>
        if cost_88 < cost {
          plan = plan_88
          cost = cost_88
          coded = coded_88
        }
      Err(e) => return Err(e)
    }
  }
  // ---- Intra16x16 candidate (opt-in `intra_in_b`) ----
  // A scene change inside the B picture can leave every inter/direct
  // candidate with a large residual; coding the macroblock against its own
  // current-frame neighbours then wins the same SSD + lambda*bits race.
  // Added last, so ties stay with the inter candidates.
  if self.intra_in_b {
    match self.pick_i16(mb_x, mb_y) {
      Some((sig, eff)) => {
        let cbase = mb_y * 8 * self.cstride + mb_x * 8
        let chroma_mode = self.pick_chroma(cbase, mb_y > 0, mb_x > 0)
        let coded_i = self.code_b_mb_i16_residuals(
          mb_x, mb_y, eff, chroma_mode, qp,
        )
        let ssd_i = self.b_mb_ssd(mb_x, mb_y)
        let cw_i = H264Rbsp::new()
        self.write_b_mb_syntax(
          mirror,
          mb_x,
          mb_y,
          BI16(sig, eff, chroma_mode),
          coded_i,
          cw_i,
        )
        let bits_i = (cw_i.bw.buf.length() * 8 + cw_i.bw.nbits).to_int64()
        let cost_i = ssd_i.to_int64() * 1024L +
          lam *
          self.price_b_bits(
            mirror,
            mb_x,
            mb_y,
            BI16(sig, eff, chroma_mode),
            coded_i,
            bits_i,
          )
        if cost_i < cost {
          plan = BI16(sig, eff, chroma_mode)
          cost = cost_i
          coded = coded_i
        }
      }
      None => ()
    }
  }
  // ---- Intra_NxN (4x4) candidate (opt-in `intra4x4_in_b`) ----
  // The shared sequential pass picks the sixteen pred4x4 modes on its own
  // reconstruction; the finest intra granularity for detailed textures
  // neither the 16x16 predictors nor the inter candidates can follow.
  if self.intra4x4_in_b {
    let scratch_store : Array[Int32] = Array::make(256, 0)
    let scratch_modes : Array[Int32] = Array::make(16, 0)
    let scratch_mb : Array[Int32] = Array::make(768, 0)
    if h264_enc_luma_i4_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        scratch_store,
        scratch_modes,
        scratch_mb,
        h264_enc_i4_avail(mb_x, mb_y, self.mb_width),
      )
      is Ok(_) {
      let raw_modes : Array[Int32] = Array::make(16, 0)
      for g in 0..<16 {
        raw_modes[g] = scratch_modes[g]
      }
      let cbase = mb_y * 8 * self.cstride + mb_x * 8
      let chroma_mode = self.pick_chroma(cbase, mb_y > 0, mb_x > 0)
      let coded_i = self.code_b_mb_i4_residuals(
        mb_x, mb_y, raw_modes, chroma_mode, qp,
      )
      let ssd_i = self.b_mb_ssd(mb_x, mb_y)
      let cw_i = H264Rbsp::new()
      self.write_b_mb_syntax(
        mirror,
        mb_x,
        mb_y,
        BI4(raw_modes, chroma_mode),
        coded_i,
        cw_i,
      )
      let bits_i = (cw_i.bw.buf.length() * 8 + cw_i.bw.nbits).to_int64()
      let cost_i = ssd_i.to_int64() * 1024L +
        lam *
        self.price_b_bits(
          mirror,
          mb_x,
          mb_y,
          BI4(raw_modes, chroma_mode),
          coded_i,
          bits_i,
        )
      if cost_i < cost {
        plan = BI4(raw_modes, chroma_mode)
        cost = cost_i
        coded = coded_i
      }
    }
  }
  // ---- Intra 8x8 candidate (opt-in `dct8x8`) ----
  // The shared sequential pass picks the four pred8x8l modes on its own
  // reconstruction; the 8x8DCT form for textured content the 16x16 and
  // 4x4 predictors cannot follow. Added after the 4x4 form, so ties stay
  // with the cheaper-to-signal finer partitioning.
  if self.dct8x8 {
    let scratch_store : Array[Int32] = Array::make(256, 0)
    let scratch_modes : Array[Int32] = Array::make(16, 0)
    let scratch_mb : Array[Int32] = Array::make(768, 0)
    if h264_enc_luma_i8_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        scratch_store,
        scratch_modes,
        scratch_mb,
        h264_enc_i8_avail(mb_x, mb_y, self.mb_width),
      )
      is Ok(_) {
      let raw_modes : Array[Int32] = [
        scratch_modes[0],
        scratch_modes[2],
        scratch_modes[8],
        scratch_modes[10],
      ]
      let cbase = mb_y * 8 * self.cstride + mb_x * 8
      let chroma_mode = self.pick_chroma(cbase, mb_y > 0, mb_x > 0)
      let coded_i = self.code_b_mb_i8_residuals(
        mb_x, mb_y, raw_modes, chroma_mode, qp,
      )
      let ssd_i = self.b_mb_ssd(mb_x, mb_y)
      let cw_i = H264Rbsp::new()
      self.write_b_mb_syntax(
        mirror,
        mb_x,
        mb_y,
        BI8(raw_modes, chroma_mode),
        coded_i,
        cw_i,
      )
      let bits_i = (cw_i.bw.buf.length() * 8 + cw_i.bw.nbits).to_int64()
      let cost_i = ssd_i.to_int64() * 1024L +
        lam *
        self.price_b_bits(
          mirror,
          mb_x,
          mb_y,
          BI8(raw_modes, chroma_mode),
          coded_i,
          bits_i,
        )
      if cost_i < cost {
        plan = BI8(raw_modes, chroma_mode)
        cost = cost_i
        coded = coded_i
      }
    }
  }
  ignore(cost)
  self.stats.b_mbs += 1
  match plan {
    BL1x16(_, _) => self.stats.bl1_mbs += 1
    BBi16(_, _, _, _) => self.stats.bi_mbs += 1
    BDirect16 => self.stats.bdirect_mbs += 1
    BI16(_, _, _) => self.stats.i16_mbs += 1
    BI4(_, _) => self.stats.i4p_mbs += 1
    BI8(_, _) => self.stats.i8p_mbs += 1
    BParts(kind, _, _) => {
      self.stats.bpart_mbs += 1
      if kind == 22 {
        self.stats.b8x8_mbs += 1
      }
    }
    _ => ()
  }
  if !(plan is BDirect16) &&
    !(plan is BParts(_, _, _)) &&
    !(plan is BI16(_, _, _)) &&
    !(plan is BI4(_, _)) &&
    !(plan is BI8(_, _)) {
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
    BParts(_, _, _) => {
      // The sub-partition commit replays the decoder's mutations on a
      // fresh slot; the decoder's own compensate re-establishes the
      // winning prediction from the committed per-4x4 motion.
      h264_b_commit_mb(mirror, mb_idx, mb_x, mb_y, plan, false)
      match h264_b_compensate(mirror, mb_idx) {
        Ok(_) => ()
        Err(e) => return Err("h264 enc b: parts re-MC failed: \{e}")
      }
    }
    BI16(_, _, _) => ()
    BI4(_, _) => ()
    BI8(_, _) => ()
  }
  if !(plan is BParts(_, _, _)) {
    h264_b_commit_mb(mirror, mb_idx, mb_x, mb_y, plan, false)
  }
  let coded_final = match plan {
    BI16(_, eff, cm) => self.code_b_mb_i16_residuals(mb_x, mb_y, eff, cm, qp)
    BI4(raw_modes, cm) =>
      self.code_b_mb_i4_residuals(mb_x, mb_y, raw_modes, cm, qp)
    BI8(raw_modes, cm) =>
      self.code_b_mb_i8_residuals(mb_x, mb_y, raw_modes, cm, qp)
    _ => self.code_b_mb_residuals(mb_x, mb_y, qp)
  }
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
  st.intra = plan is BI16(_, _, _) || plan is BI4(_, _) || plan is BI8(_, _)
  match plan {
    BI4(raw_modes, _) => {
      st.intra_nxn = true
      for g in 0..<16 {
        st.modes[g] = raw_modes[g]
      }
    }
    BI8(raw_modes, _) => {
      st.intra_nxn = true
      for k in 0..<4 {
        for dy in 0..<2 {
          for dx in 0..<2 {
            st.modes[(k / 2 * 2 + dy) * 4 + k % 2 * 2 + dx] = raw_modes[k]
          }
        }
      }
    }
    _ => st.intra_nxn = false
  }
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
            Some(c) => {
              self.write_b_mb_syntax(mirror, mb_x, mb_y, plan, c, r)
              // The syntax layer's nC mirror is the authoritative one
              // (Intra 8x8 fills it progressively): re-seed the persistent
              // state for the next macroblock's nC reads.
              for i in 0..<48 {
                self.states[mb_idx].nz[i] = self.cur_nz[i]
              }
            }
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
  match plan {
    BI16(_, _, _) => {
      self.write_b_mb_i16_syntax_cabac(
        mirror, enc, states, mb_x, mb_y, plan, coded,
      )
      return
    }
    BI4(_, _) => {
      self.write_b_mb_i4_syntax_cabac(
        mirror, enc, states, mb_x, mb_y, plan, coded,
      )
      return
    }
    BI8(_, _) => {
      self.write_b_mb_i8_syntax_cabac(
        mirror, enc, states, mb_x, mb_y, plan, coded,
      )
      return
    }
    _ => ()
  }
  // The decoder's non-intra B kinds reset the intra flag each macroblock
  // (`cur_mb_is_intra` drives the CABAC residual contexts).
  mirror.cur_mb_is_intra = false
  if kind >= 4 {
    self.write_b_mb_parts_syntax_cabac(
      mirror, enc, states, mb_x, mb_y, plan, coded,
    )
    return
  }
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
  self.write_b_residual_tail_cabac(
    mirror, enc, states, mb_idx, mb_x, mb_y, coded, true,
  )
}

///|
/// The CABAC inter residual tail shared by every B macroblock kind: the
/// cbp bins, `mb_qp_delta`, cbp-gated 4x4 luma and the chroma residual.
fn H264PEncoder::write_b_residual_tail_cabac(
  self : H264PEncoder,
  mirror : H264DecCtx,
  enc : H264CabacEnc,
  states : Array[Int32],
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  coded : H264PMbCode,
  dct8_allowed : Bool,
) -> Unit {
  let info = mirror.infos[mb_idx]
  let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  h264_cabacw_cbp(enc, states, mirror, mb_idx, mb_x, mb_y, cbp, true)
  info.cbp_all = cbp
  if self.dct8x8 && dct8_allowed && (cbp & 15) != 0 {
    // transform_size_8x8_flag: the B inter residual stays 4x4 even under
    // the dct8x8 High-profile signalling.
    enc.decision(
      states,
      399 + h264_neighbor_transform_size(mirror, mb_idx, mb_x, mb_y),
      0,
    )
  }
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
/// The CABAC mb_type bins of a sub-partitioned B macroblock: through the
/// `30 = 1` branch, the four suffix bins (31, 32, 32, 32) carry
/// `kind - 3` for kinds 3..10, 14 for kind 11 (B_L0_8x16's (L1, L0)), 15
/// for kind 22 (B_8x8) and `(kind + 4) >> 1` plus a fifth continuation
/// bin for kinds 12..21 — the decoder's `(bits << 1) + bin - 4` escape.
fn h264_cabacw_b_parts_type(
  enc : H264CabacEnc,
  states : Array[Int32],
  tctx : Int32,
  kind : Int32,
) -> Unit {
  enc.decision(states, tctx, 1)
  enc.decision(states, 30, 1)
  let (bits, extra) = if kind <= 10 {
    (kind - 3, -1)
  } else if kind == 11 {
    (14, -1)
  } else if kind == 22 {
    (15, -1)
  } else {
    ((kind + 4) >> 1, (kind + 4) & 1)
  }
  enc.decision(states, 31, (bits >> 3) & 1)
  enc.decision(states, 32, (bits >> 2) & 1)
  enc.decision(states, 32, (bits >> 1) & 1)
  enc.decision(states, 32, bits & 1)
  if extra >= 0 {
    enc.decision(states, 32, extra)
  }
}

///|
/// The CABAC sub-macroblock-type bins of a B_8x8 partition, the encoder
/// twin of `h264_b_sub_type`'s read tree (contexts 36/37/38/39).
fn h264_cabacw_b_sub_type(
  enc : H264CabacEnc,
  states : Array[Int32],
  s : Int32,
) -> Unit {
  if s == 0 {
    enc.decision(states, 36, 0)
    return
  }
  enc.decision(states, 36, 1)
  if s <= 2 {
    enc.decision(states, 37, 0)
    enc.decision(states, 39, s - 1)
    return
  }
  enc.decision(states, 37, 1)
  if s <= 6 {
    // kind 3, then `3 + 2 * b1 + b2` over two further 39 bins.
    enc.decision(states, 38, 0)
    let v = s - 3
    enc.decision(states, 39, (v >> 1) & 1)
    enc.decision(states, 39, v & 1)
    return
  }
  enc.decision(states, 38, 1)
  if s <= 10 {
    // kind 7, then `7 + 2 * b1 + b2` over two further 39 bins.
    enc.decision(states, 39, 0)
    let v = s - 7
    enc.decision(states, 39, (v >> 1) & 1)
    enc.decision(states, 39, v & 1)
    return
  }
  // `11 + b` over the second 39 bin.
  enc.decision(states, 39, 1)
  enc.decision(states, 39, s - 11)
}

///|
/// Write one sub-partitioned B macroblock's CABAC syntax (kinds 4..22):
/// the mb_type and sub-macroblock-type bins, then the per-list partition
/// mvds emitted while REPLAYING the decoder's CABAC read order on a fresh
/// mirror slot (direct groups' spatial motion, the two-partition kinds'
/// reference write-backs, per-group reference preambles for B_8x8, each
/// mvd against the decoder's predictor and its `amvd` context from the
/// mirror's mvd cells) with the write-back the decoder performs after
/// reading it.
fn H264PEncoder::write_b_mb_parts_syntax_cabac(
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
  let (kind, subs, mvs) = match plan {
    BParts(k, s, m) => (k, s, m)
    _ => abort("h264 enc b: parts cabac on a 16x16 plan")
  }
  let info = mirror.infos[mb_idx]
  h264_b_slot_reset(mirror, mb_idx)
  let (groups, parts, direct, mb_bits) = h264_b_partitions(kind, subs)
  info.mb_type_bits = mb_bits
  if direct.any(fn(value) { value }) {
    match h264_b_direct(mirror, mb_idx, direct) {
      Ok(_) => ()
      Err(e) => abort("h264 enc b: parts cabac direct failed: \{e}")
    }
  }
  if kind == 22 {
    for block in [2, 10] {
      info.ref_idx[block] = -2
      info.ref_idx1[block] = -2
    }
  }
  h264_cabacw_b_parts_type(
    enc,
    states,
    h264_cabacw_b_type_ctx(mirror, mb_idx),
    kind,
  )
  if kind == 22 {
    for s in subs {
      h264_cabacw_b_sub_type(enc, states, s)
    }
  }
  // References: a single reference per list reads no ref bins; for B_8x8
  // the CABAC decoder's per-group cache dance writes the read reference
  // into three of the group's four cells (the top-left stays hidden until
  // the group's motion pass) — replicated for exactness.
  for list in 0..<2 {
    mirror.active_list = list
    for part in groups {
      if (part.mask & (1 << list)) == 0 {
        continue
      }
      if kind == 22 {
        h264_write_back_ref(mirror, mb_idx, part.x + 1, part.y, 1, 1, 0)
        h264_write_back_ref(mirror, mb_idx, part.x, part.y + 1, 2, 1, 0)
      } else {
        h264_write_back_ref(mirror, mb_idx, part.x, part.y, part.w, part.h, 0)
      }
    }
  }
  h264_b_mvd_walk(mirror, mb_idx, mb_x, mb_y, kind, parts, direct, (
    part,
    mi,
    pmvx,
    pmvy,
  ) => {
    let (mvx, mvy) = mvs[mi]
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
      (mvx - pmvx).abs().min(70),
      (mvy - pmvy).abs().min(70),
    )
  })
  self.write_b_residual_tail_cabac(
    mirror,
    enc,
    states,
    mb_idx,
    mb_x,
    mb_y,
    coded,
    parts.all(fn(part) { part.w >= 2 && part.h >= 2 }),
  )
}

///|
/// Write one Intra16x16 B macroblock's CABAC syntax (`intra_in_b`): the
/// B mb_type tree lands on the suffix `bits = 13` (bins 31/32/32/32 =
/// 1/1/0/1), which the decoder routes into
/// `h264_cabac_intra_mb_type(ctx_base 32, intra_slice 0)` and adds 23 —
/// so the I16 mode field follows as the intra tree's b0..b4 at contexts
/// 33/34/34/35/35 with a terminate bin rejecting Intra_PCM. The chroma
/// tree, the unconditional `mb_qp_delta` bin and the residual categories
/// are the I-slice ones.
fn H264PEncoder::write_b_mb_i16_syntax_cabac(
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
  let (sig, chroma_mode) = match plan {
    BI16(s, _, c) => (s, c)
    _ => abort("h264 enc b: i16 cabac on a non-I16 plan")
  }
  let info = mirror.infos[mb_idx]
  info.mb_type_bits = h264_mb_type_intra16x16
  info.intra4x4 = false
  info.chroma_mode = chroma_mode
  info.cbp_all = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  let tctx = h264_cabacw_b_type_ctx(mirror, mb_idx)
  // bits = 13 selects the intra branch of the B mb_type tree.
  enc.decision(states, tctx, 1)
  enc.decision(states, 30, 1)
  enc.decision(states, 31, 1)
  enc.decision(states, 32, 1)
  enc.decision(states, 32, 0)
  enc.decision(states, 32, 1)
  // The intra tree at ctx_base 32: I_NxN bin, the PCM terminate, then the
  // I16x16 mode field.
  enc.decision(states, 32, 1)
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
  enc.decision(states, 33, b0)
  enc.decision(states, 34, b1)
  if b1 == 1 {
    enc.decision(states, 34, b2)
  }
  enc.decision(states, 35, b3)
  enc.decision(states, 35, b4)
  mirror.cur_mb_is_intra = true
  // Chroma prediction mode tree (identical to the I-slice writer).
  let mut cc = 0
  if h264_has_left(mirror, mb_idx) && mirror.infos[mb_idx - 1].chroma_mode != 0 {
    cc = cc + 1
  }
  if h264_has_top(mirror, mb_idx) &&
    mirror.infos[h264_top_index(mirror, mb_idx)].chroma_mode != 0 {
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
  h264_cabacw_dqp(enc, states, mirror, self.mb_dqp)
  if self.mb_dqp != 0 {
    self.stats.dqp_mbs += 1
  }
  let dc_view = scan_view_at(coded.luma_dc_store, 0, h264_zigzag_scan_t, 0, 16)
  h264_cabacw_residual(
    enc, states, mirror, mb_idx, mb_x, mb_y, 0, 48, dc_view, 16, true,
  )
  if coded.luma_cbp != 0 {
    for i = 0; i < 16; i = i + 1 {
      let view = scan_view_at(coded.luma_store, i, h264_zigzag_scan_t, 1, 15)
      h264_cabacw_residual(
        enc, states, mirror, mb_idx, mb_x, mb_y, 1, i, view, 15, false,
      )
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
/// Write one Intra 8x8 B macroblock's CABAC syntax (the `dct8x8` opt-in):
/// the B mb_type tree lands on the suffix `bits = 13` and the intra tree's
/// FIRST bin selects I_NxN — then `transform_size_8x8_flag = 1` (the
/// decoder reads the flag unconditionally on the I_NxN branch once the
/// PPS enables the mode, ctx 399 + the 8x8DCT neighbour count), the four
/// differentially-coded `pred8x8l` modes (ctx 68/69 through the decoder's
/// own `h264_pred_intra_mode`), the chroma tree, the intra cbp bins, the
/// cbp-gated `mb_qp_delta` and the I-slice residual categories (luma
/// cat 5, shared chroma writer).
fn H264PEncoder::write_b_mb_i8_syntax_cabac(
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
  let (raw_modes, chroma_mode) = match plan {
    BI8(m, c) => (m, c)
    _ => abort("h264 enc b: i8 cabac on a non-I8 plan")
  }
  let info = mirror.infos[mb_idx]
  info.mb_type_bits = h264_mb_type_intra4x4
  info.intra4x4 = true
  info.transform_8x8 = true
  info.chroma_mode = chroma_mode
  info.cbp_all = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  let tctx = h264_cabacw_b_type_ctx(mirror, mb_idx)
  // bits = 13 selects the intra branch of the B mb_type tree.
  enc.decision(states, tctx, 1)
  enc.decision(states, 30, 1)
  enc.decision(states, 31, 1)
  enc.decision(states, 32, 1)
  enc.decision(states, 32, 0)
  enc.decision(states, 32, 1)
  // The intra tree's first bin: 0 is I_NxN (kind 23).
  enc.decision(states, 32, 0)
  mirror.cur_mb_is_intra = true
  // transform_size_8x8_flag: read unconditionally on the I_NxN branch
  // once the PPS enables the mode.
  enc.decision(
    states,
    399 + h264_neighbor_transform_size(mirror, mb_idx, mb_x, mb_y),
    1,
  )
  info.transform_8x8 = true
  // One prediction mode per 8x8 block on the 2x2-replicated grid.
  let cur : Array[Int32] = Array::make(16, 0)
  for k = 0; k < 4; k = k + 1 {
    for dy in 0..<2 {
      for dx in 0..<2 {
        cur[(k / 2 * 2 + dy) * 4 + k % 2 * 2 + dx] = raw_modes[k]
      }
    }
  }
  for k = 0; k < 4; k = k + 1 {
    let predicted = h264_pred_intra_mode(
      mirror,
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
  let mut cc = 0
  if h264_has_left(mirror, mb_idx) && mirror.infos[mb_idx - 1].chroma_mode != 0 {
    cc = cc + 1
  }
  if h264_has_top(mirror, mb_idx) &&
    mirror.infos[h264_top_index(mirror, mb_idx)].chroma_mode != 0 {
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
  h264_cabacw_cbp(enc, states, mirror, mb_idx, mb_x, mb_y, cbp, true)
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
      let view = scan8_view_at(coded.luma8_store, i8, h264_zigzag_scan8x8)
      h264_cabacw_residual(
        enc,
        states,
        mirror,
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
  h264_cabacw_chroma(enc, states, mirror, mb_idx, mb_x, mb_y, coded)
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = cur[g]
  }
}

///|
/// Write one Intra_NxN (4x4) B macroblock's CABAC syntax
/// (`intra4x4_in_b`): the B mb_type tree lands on the suffix `bits = 13`
/// and the intra tree's FIRST bin selects I_NxN (mb_type 0, the +23
/// offset applied by the decoder) — no terminate or mode field follows.
/// Then the sixteen differentially-coded prediction modes (ctx 68/69 via
/// the decoder's own `h264_pred_intra_mode`), the chroma tree, the intra
/// cbp bins, the cbp-gated `mb_qp_delta` and the residual categories of
/// the I slices (luma cat 2, shared chroma writer).
fn H264PEncoder::write_b_mb_i4_syntax_cabac(
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
  let (raw_modes, chroma_mode) = match plan {
    BI4(m, c) => (m, c)
    _ => abort("h264 enc b: i4 cabac on a non-I4 plan")
  }
  let info = mirror.infos[mb_idx]
  info.mb_type_bits = h264_mb_type_intra4x4
  info.intra4x4 = true
  info.chroma_mode = chroma_mode
  info.cbp_all = coded.luma_cbp | (coded.chroma_c_cbp << 4)
  let tctx = h264_cabacw_b_type_ctx(mirror, mb_idx)
  // bits = 13 selects the intra branch of the B mb_type tree.
  enc.decision(states, tctx, 1)
  enc.decision(states, 30, 1)
  enc.decision(states, 31, 1)
  enc.decision(states, 32, 1)
  enc.decision(states, 32, 0)
  enc.decision(states, 32, 1)
  // The intra tree's first bin: 0 is I_NxN (kind 23).
  enc.decision(states, 32, 0)
  mirror.cur_mb_is_intra = true
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let predicted = h264_pred_intra_mode(
      mirror, mb_idx, mb_x, mb_y, gx, gy, raw_modes,
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
  if h264_has_left(mirror, mb_idx) && mirror.infos[mb_idx - 1].chroma_mode != 0 {
    cc = cc + 1
  }
  if h264_has_top(mirror, mb_idx) &&
    mirror.infos[h264_top_index(mirror, mb_idx)].chroma_mode != 0 {
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
  h264_cabacw_cbp(enc, states, mirror, mb_idx, mb_x, mb_y, cbp, true)
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
  h264_cabacw_chroma(enc, states, mirror, mb_idx, mb_x, mb_y, coded)
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = raw_modes[g]
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
  if self.cabac_rd {
    self.price_enc = Some(enc)
    self.price_states = Some(states)
  }
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
            Some(c) => {
              self.write_b_mb_syntax_cabac(
                mirror, enc, states, mb_x, mb_y, plan, c,
              )
              // The CABAC writer maintains the decoder-context nz; re-seed
              // the persistent state for the next macroblock's nC reads.
              let info = mirror.infos[mb_idx]
              for i in 0..<48 {
                self.states[mb_idx].nz[i] = info.nz[i]
              }
            }
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
  cabac_rd~ : Bool = false,
  /// Opt-in (`§395`): sub-partitioned B kinds 4..22 (16x8/8x16 and B_8x8
  /// with per-group sub decisions).
  b_parts~ : Bool = false,
  /// Opt-in (`§396`): Intra16x16 macroblocks inside the B slices.
  intra_in_b~ : Bool = false,
  /// Opt-in (`§397`): Intra_NxN (4x4) macroblocks inside the B slices.
  intra4x4_in_b~ : Bool = false,
  /// Opt-in (`§400`): High-profile 8x8DCT signalling — the IDR codes its
  /// Intra 8x8 macroblocks and the B slices gain the Intra 8x8 candidate;
  /// B inter macroblocks stay 4x4 with an explicit `transform_size_8x8_
  /// flag = 0` whenever the PPS enables the mode and the decoder reads it.
  dct8x8~ : Bool = false,
  /// Per-display-position QPs (the rate controls' lever). Empty, every
  /// picture codes at `qp` and the stream is byte-identical to the flat
  /// path; otherwise the IDR codes at `qps[0]` (also the PPS
  /// `pic_init_qp`), the picture at display position `f` at `qps[f]`.
  qps~ : Array[Int32] = [],
  /// VBV state (`§398`): when set, every access unit opens with a
  /// `pic_timing` SEI carrying the CPB removal delay.
  vbv~ : H264Vbv? = None,
  /// Per-access-unit filler NAL payloads (the VBV solver's schedule).
  fillers~ : Array[Int32] = [],
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
) -> Result[(Bytes, Array[Int32]), String] {
  let n = frames.length()
  let qps_arr = if qps.length() == n { qps } else { Array::make(n, qp) }
  let (y0, u0, v0) = frames[0]
  let first = match
    (if cabac {
      h264_encode_intra_frame_cabac(
        y0,
        u0,
        v0,
        width~,
        height~,
        qp=qps_arr[0],
        level_idc~,
        dct8x8~,
        stats~,
        pps_qp=qps_arr[0],
        aq~,
        aq_strength~,
        b_seq=true,
        vbv~,
      )
    } else {
      h264_encode_intra_frame(
        y0,
        u0,
        v0,
        width~,
        height~,
        qp=qps_arr[0],
        level_idc~,
        dct8x8~,
        stats~,
        pps_qp=qps_arr[0],
        aq~,
        aq_strength~,
        b_seq=true,
        vbv~,
      )
    }) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let p = { width, height, qp: qps_arr[0], level_idc, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  // Round-trip the B-capable parameter sets: the parsed PPS carries the
  // dequantisation tables the local reconstructions share with the decoder.
  let ps = new_h264_param_sets()
  let sps_rbsp = h264_enc_sps_rbsp_b(p, dct8x8~)
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_rbsp), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = if cabac {
    h264_enc_pps_rbsp_cabac(p, dct8x8~)
  } else {
    h264_enc_pps_rbsp(p, dct8x8~)
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
  let stream : Array[Bytes] = []
  let first_au : Array[Bytes] = [first.annexb]
  if fillers.length() > 0 && fillers[0] > 0 {
    first_au.push(h264_enc_filler_nal(fillers[0] - 5))
  }
  stream.push(h264_enc_concat(first_au))
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
    qp_f : Int32,
  ) -> H264PEncoder {
    let src_y_p = load_plane(y, width, height, ystride, pheight)
    let (act, act_avg) = if aq {
      h264_aq_measure(src_y_p, ystride, mb_width, mb_height)
    } else {
      (Array::make(mb_width * mb_height, 0), 0)
    }
    {
      p: { width, height, qp: qp_f, level_idc, },
      stats,
      pps,
      chroma_qp: h264_get_chroma_qp(pps, 0, qp_f),
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
      // The PPS carries transform_8x8_mode for the whole sequence, so the
      // B sequence's P frames must honour it too: the decoder derives
      // dct8x8_allowed from the PPS, not from anything the writer chooses.
      dct8x8,
      intra4x4_in_p: false,
      base_qp: qps_arr[0],
      mb_qp: qp_f,
      mb_dqp: 0,
      prev_qp: qp_f,
      aq_act: act,
      aq_avg: act_avg,
      aq_on: aq,
      aq_strength,
      cabac_rd,
      price_mirror: None,
      price_enc: None,
      price_states: None,
      b_parts: false,
      intra_in_b: false,
      intra4x4_in_b: false,
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
      let enc = new_p_encoder(y, u, v, ref_y, ref_u, ref_v, qps_arr[e + 1])
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
      let au : Array[Bytes] = []
      match vbv {
        None => ()
        Some(v) => au.push(h264_enc_sei_pic_timing(v, (e + 1) * 2))
      }
      au.push(p_nal)
      if fillers.length() > e + 1 && fillers[e + 1] > 0 {
        au.push(h264_enc_filler_nal(fillers[e + 1] - 5))
      }
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
        p: { width, height, qp: qps_arr[e], level_idc, },
        stats,
        pps,
        chroma_qp: h264_get_chroma_qp(pps, 0, qps_arr[e]),
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
        dct8x8,
        intra4x4_in_p: false,
        base_qp: qps_arr[0],
        mb_qp: qps_arr[e],
        mb_dqp: 0,
        prev_qp: qps_arr[e],
        aq_act: b_act,
        aq_avg: b_act_avg,
        aq_on: aq,
        aq_strength,
        cabac_rd,
        price_mirror: None,
        price_enc: None,
        price_states: None,
        b_parts,
        intra_in_b,
        intra4x4_in_b,
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
      let b_au : Array[Bytes] = []
      match vbv {
        None => ()
        Some(v) => b_au.push(h264_enc_sei_pic_timing(v, e * 2))
      }
      b_au.push(b_nal)
      if fillers.length() > e && fillers[e] > 0 {
        b_au.push(h264_enc_filler_nal(fillers[e] - 5))
      }
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
      let enc = new_p_encoder(y, u, v, ref_y, ref_u, ref_v, qps_arr[e])
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
      let au : Array[Bytes] = []
      match vbv {
        None => ()
        Some(v) => au.push(h264_enc_sei_pic_timing(v, e * 2))
      }
      au.push(p_nal)
      if fillers.length() > e && fillers[e] > 0 {
        au.push(h264_enc_filler_nal(fillers[e] - 5))
      }
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
  for q in qps_arr {
    stats.frame_qps.push(q)
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
