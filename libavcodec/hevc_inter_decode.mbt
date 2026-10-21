///|
/// HEVC P/B slice decoding: prediction-unit motion compensation, MV-based
/// deblocking boundary strengths and the frame-level DPB driver, ported from
/// FFmpeg 9.0.2 `libavcodec/hevc/hevcdec.c` (`hls_prediction_unit` MC calls,
/// `hevc_frame_start`, `ff_hevc_deblocking_boundary_strengths` from
/// `filter.c`, `boundary_strength`) and `libavcodec/hevc/refs.c`.
///
/// Supported: 8/10/12-bit 4:2:0/4:2:2/4:4:4, single- and multi-slice pictures with WPP
/// and/or uniform/non-uniform tiles, closed-GOP streams whose reference
/// pictures are all present (missing refs are generated grey), weighted and
/// unweighted uni/bi prediction. WPP follows FFmpeg's single-thread semantics:
/// each CTB row is decoded as a substream whose CABAC is rewound after the
/// terminate bin and seeded from the state saved after the previous row's
/// second CTB. Tiles are decoded in tile-scan order with a fresh CABAC state
/// at each tile boundary. Rejected upstream: dependent slices, reference-list
/// modification, tiles combined with WPP, PCM, RDPCM,
/// current-picture referencing.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `intra_prediction_unit_default_value` (hevcdec.c): DC modes in `tab_ipm`
/// and, for intra CUs, `PF_INTRA` in `tab_mvf`. */
fn HevcIntraDecoder::intra_prediction_unit_default_value(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
) -> Unit {
  let sps = self.sps
  let x_pu = x0 >> sps.log2_min_pu_size
  let y_pu = y0 >> sps.log2_min_pu_size
  let mut size_in_pus = (1 << log2_cb_size) >> sps.log2_min_pu_size
  if size_in_pus < 1 {
    size_in_pus = 1
  }
  for j in 0..<size_in_pus {
    for i in 0..<size_in_pus {
      self.tab_ipm[(y_pu + j) * sps.min_pu_width + x_pu + i] = 1
      if self.cu_pred_mode == hevc_mode_intra {
        self.tab_mvf[(y_pu + j) * sps.min_pu_width + x_pu + i].pred_flag = hevc_pf_intra
      }
    }
  }
}

///|
/// `hls_prediction_unit`: parse the PU syntax, record the motion field and
/// run the motion compensation onto the current picture. */
fn HevcIntraDecoder::prediction_unit(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  log2_cb_size : Int32,
  part_idx : Int32,
  skip : Bool,
) -> Unit {
  let ctx = match self.inter {
    Some(c) => c
    None => return
  }
  ctx.part_mode = self.part_mode
  ctx.cu_x = self.cur_cu_x
  ctx.cu_y = self.cur_cu_y
  let current_mv = hevc_mv_field_new()
  hevc_hls_prediction_unit(
    ctx,
    x0,
    y0,
    n_pb_w,
    n_pb_h,
    log2_cb_size,
    part_idx,
    skip,
    current_mv,
  )
  self.pu_merge_flag = ctx.last_merge_flag
  let sps = self.sps
  let x_pu = x0 >> sps.log2_min_pu_size
  let y_pu = y0 >> sps.log2_min_pu_size
  for j in 0..<(n_pb_h >> sps.log2_min_pu_size) {
    for i in 0..<(n_pb_w >> sps.log2_min_pu_size) {
      self.tab_mvf[(y_pu + j) * sps.min_pu_width + x_pu + i].copy_from(current_mv)
    }
  }
  if self.rpl.length() < 2 {
    return
  }
  let sh = self.sh
  let pic = self.pic
  let stride_y = pic.width
  let cstride = pic.plane_stride(1)
  let cw = pic.width
  let ch = pic.height
  let chw = pic.cw
  let chh = pic.ch
  let x0_c = x0 >> sps.hshift[1]
  let y0_c = y0 >> sps.vshift[1]
  let n_pb_w_c = n_pb_w >> sps.hshift[1]
  let n_pb_h_c = n_pb_h >> sps.vshift[1]
  let weighted = (sh.slice_type == hevc_slice_p && self.pps.weighted_pred_flag != 0) ||
    (sh.slice_type == hevc_slice_b && self.pps.weighted_bipred_flag != 0)
  let bd = sps.bit_depth
  let pw = sh.pw
  if current_mv.pred_flag == hevc_pf_l0 {
    let ref0 = self.rpl[0].entries[current_mv.ref_idx0].frame
    let idx = current_mv.ref_idx0
    if !weighted {
      hevc_luma_mc_uni(
        ref0.pic.y,
        cw,
        cw,
        ch,
        pic.y,
        stride_y,
        x0,
        y0,
        current_mv.mv0.x,
        current_mv.mv0.y,
        n_pb_w,
        n_pb_h,
        bd,
      )
      hevc_chroma_mc_uni(
        ref0.pic.cb,
        cstride,
        chw,
        chh,
        pic.cb,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv0.x,
        current_mv.mv0.y,
        n_pb_w_c,
        n_pb_h_c,
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
      hevc_chroma_mc_uni(
        ref0.pic.cr,
        cstride,
        chw,
        chh,
        pic.cr,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv0.x,
        current_mv.mv0.y,
        n_pb_w_c,
        n_pb_h_c,
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
    } else {
      hevc_luma_mc_uni_w(
        ref0.pic.y,
        cw,
        cw,
        ch,
        pic.y,
        stride_y,
        x0,
        y0,
        current_mv.mv0.x,
        current_mv.mv0.y,
        n_pb_w,
        n_pb_h,
        pw.luma_log2_weight_denom,
        pw.luma_weight_l0[idx],
        pw.luma_offset_l0[idx],
        bd,
      )
      hevc_chroma_mc_uni_w(
        ref0.pic.cb,
        cstride,
        chw,
        chh,
        pic.cb,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv0.x,
        current_mv.mv0.y,
        n_pb_w_c,
        n_pb_h_c,
        pw.chroma_log2_weight_denom,
        pw.chroma_weight_l0[idx][0],
        pw.chroma_offset_l0[idx][0],
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
      hevc_chroma_mc_uni_w(
        ref0.pic.cr,
        cstride,
        chw,
        chh,
        pic.cr,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv0.x,
        current_mv.mv0.y,
        n_pb_w_c,
        n_pb_h_c,
        pw.chroma_log2_weight_denom,
        pw.chroma_weight_l0[idx][1],
        pw.chroma_offset_l0[idx][1],
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
    }
  } else if current_mv.pred_flag == hevc_pf_l1 {
    let ref1 = self.rpl[1].entries[current_mv.ref_idx1].frame
    let idx = current_mv.ref_idx1
    if !weighted {
      hevc_luma_mc_uni(
        ref1.pic.y,
        cw,
        cw,
        ch,
        pic.y,
        stride_y,
        x0,
        y0,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w,
        n_pb_h,
        bd,
      )
      hevc_chroma_mc_uni(
        ref1.pic.cb,
        cstride,
        chw,
        chh,
        pic.cb,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w_c,
        n_pb_h_c,
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
      hevc_chroma_mc_uni(
        ref1.pic.cr,
        cstride,
        chw,
        chh,
        pic.cr,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w_c,
        n_pb_h_c,
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
    } else {
      hevc_luma_mc_uni_w(
        ref1.pic.y,
        cw,
        cw,
        ch,
        pic.y,
        stride_y,
        x0,
        y0,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w,
        n_pb_h,
        pw.luma_log2_weight_denom,
        pw.luma_weight_l1[idx],
        pw.luma_offset_l1[idx],
        bd,
      )
      hevc_chroma_mc_uni_w(
        ref1.pic.cb,
        cstride,
        chw,
        chh,
        pic.cb,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w_c,
        n_pb_h_c,
        pw.chroma_log2_weight_denom,
        pw.chroma_weight_l1[idx][0],
        pw.chroma_offset_l1[idx][0],
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
      hevc_chroma_mc_uni_w(
        ref1.pic.cr,
        cstride,
        chw,
        chh,
        pic.cr,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w_c,
        n_pb_h_c,
        pw.chroma_log2_weight_denom,
        pw.chroma_weight_l1[idx][1],
        pw.chroma_offset_l1[idx][1],
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
    }
  } else if current_mv.pred_flag == hevc_pf_bi {
    let ref0 = self.rpl[0].entries[current_mv.ref_idx0].frame
    let ref1 = self.rpl[1].entries[current_mv.ref_idx1].frame
    let i0 = current_mv.ref_idx0
    let i1 = current_mv.ref_idx1
    if !weighted {
      hevc_luma_mc_bi(
        ref0.pic.y,
        cw,
        ref1.pic.y,
        cw,
        cw,
        ch,
        pic.y,
        stride_y,
        x0,
        y0,
        current_mv.mv0.x,
        current_mv.mv0.y,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w,
        n_pb_h,
        bd,
      )
      hevc_chroma_mc_bi(
        ref0.pic.cb,
        cstride,
        ref1.pic.cb,
        cstride,
        chw,
        chh,
        pic.cb,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv0.x,
        current_mv.mv0.y,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w_c,
        n_pb_h_c,
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
      hevc_chroma_mc_bi(
        ref0.pic.cr,
        cstride,
        ref1.pic.cr,
        cstride,
        chw,
        chh,
        pic.cr,
        cstride,
        x0_c,
        y0_c,
        current_mv.mv0.x,
        current_mv.mv0.y,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w_c,
        n_pb_h_c,
        bd,
        sps.hshift[1],
        sps.vshift[1],
      )
    } else {
      hevc_luma_mc_bi_w(
        ref0.pic.y,
        cw,
        ref1.pic.y,
        cw,
        cw,
        ch,
        pic.y,
        stride_y,
        x0,
        y0,
        current_mv.mv0.x,
        current_mv.mv0.y,
        current_mv.mv1.x,
        current_mv.mv1.y,
        n_pb_w,
        n_pb_h,
        pw.luma_log2_weight_denom,
        pw.luma_weight_l0[i0],
        pw.luma_weight_l1[i1],
        pw.luma_offset_l0[i0],
        pw.luma_offset_l1[i1],
        bd,
      )
      for c in 0..<2 {
        let ref0p = if c == 0 { ref0.pic.cb } else { ref0.pic.cr }
        let ref1p = if c == 0 { ref1.pic.cb } else { ref1.pic.cr }
        let dstp = if c == 0 { pic.cb } else { pic.cr }
        hevc_chroma_mc_bi_w(
          ref0p,
          cstride,
          ref1p,
          cstride,
          chw,
          chh,
          dstp,
          cstride,
          x0_c,
          y0_c,
          current_mv.mv0.x,
          current_mv.mv0.y,
          current_mv.mv1.x,
          current_mv.mv1.y,
          n_pb_w_c,
          n_pb_h_c,
          pw.chroma_log2_weight_denom,
          pw.chroma_weight_l0[i0][c],
          pw.chroma_weight_l1[i1][c],
          pw.chroma_offset_l0[i0][c],
          pw.chroma_offset_l1[i1][c],
          bd,
          sps.hshift[1],
          sps.vshift[1],
        )
      }
    }
  }
}

///|
/// `boundary_strength` (filter.c): POC-based reference comparison. */
fn hevc_boundary_strength(
  curr_rpl : Array[HevcRefPicList],
  neigh_rpl : Array[HevcRefPicList],
  curr : HevcMvField,
  neigh : HevcMvField,
) -> Int32 {
  if curr.pred_flag == hevc_pf_bi && neigh.pred_flag == hevc_pf_bi {
    if curr_rpl[0].poc(curr.ref_idx0) == neigh_rpl[0].poc(neigh.ref_idx0) &&
      curr_rpl[0].poc(curr.ref_idx0) == curr_rpl[1].poc(curr.ref_idx1) &&
      neigh_rpl[0].poc(neigh.ref_idx0) == neigh_rpl[1].poc(neigh.ref_idx1) {
      if ((neigh.mv0.x - curr.mv0.x).abs() >= 4 ||
        (neigh.mv0.y - curr.mv0.y).abs() >= 4 ||
        (neigh.mv1.x - curr.mv1.x).abs() >= 4 ||
        (neigh.mv1.y - curr.mv1.y).abs() >= 4) &&
        ((neigh.mv1.x - curr.mv0.x).abs() >= 4 ||
        (neigh.mv1.y - curr.mv0.y).abs() >= 4 ||
        (neigh.mv0.x - curr.mv1.x).abs() >= 4 ||
        (neigh.mv0.y - curr.mv1.y).abs() >= 4) {
        return 1
      }
      return 0
    } else if neigh_rpl[0].poc(neigh.ref_idx0) == curr_rpl[0].poc(curr.ref_idx0) &&
      neigh_rpl[1].poc(neigh.ref_idx1) == curr_rpl[1].poc(curr.ref_idx1) {
      if (neigh.mv0.x - curr.mv0.x).abs() >= 4 ||
        (neigh.mv0.y - curr.mv0.y).abs() >= 4 ||
        (neigh.mv1.x - curr.mv1.x).abs() >= 4 ||
        (neigh.mv1.y - curr.mv1.y).abs() >= 4 {
        return 1
      }
      return 0
    } else if neigh_rpl[1].poc(neigh.ref_idx1) == curr_rpl[0].poc(curr.ref_idx0) &&
      neigh_rpl[0].poc(neigh.ref_idx0) == curr_rpl[1].poc(curr.ref_idx1) {
      if (neigh.mv1.x - curr.mv0.x).abs() >= 4 ||
        (neigh.mv1.y - curr.mv0.y).abs() >= 4 ||
        (neigh.mv0.x - curr.mv1.x).abs() >= 4 ||
        (neigh.mv0.y - curr.mv1.y).abs() >= 4 {
        return 1
      }
      return 0
    }
    return 1
  } else if curr.pred_flag != hevc_pf_bi && neigh.pred_flag != hevc_pf_bi {
    let (a, ref_a) = if (curr.pred_flag & 1) != 0 {
      (curr.mv0, curr_rpl[0].poc(curr.ref_idx0))
    } else {
      (curr.mv1, curr_rpl[1].poc(curr.ref_idx1))
    }
    let (b, ref_b) = if (neigh.pred_flag & 1) != 0 {
      (neigh.mv0, neigh_rpl[0].poc(neigh.ref_idx0))
    } else {
      (neigh.mv1, neigh_rpl[1].poc(neigh.ref_idx1))
    }
    if ref_a == ref_b {
      if (a.x - b.x).abs() >= 4 || (a.y - b.y).abs() >= 4 {
        return 1
      }
      return 0
    }
    return 1
  }
  1
}

///|
/// `ff_hevc_deblocking_boundary_strengths` (filter.c) for a single-slice
/// picture. */
fn HevcIntraDecoder::deblocking_boundary_strengths(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  log2_trafo_size : Int32,
) -> Unit {
  let sps = self.sps
  let tab_mvf = self.tab_mvf
  let l2pu = sps.log2_min_pu_size
  let l2tu = sps.log2_min_tb_size
  let min_pu_width = sps.min_pu_width
  let min_tu_width = sps.min_tb_width
  let is_intra = tab_mvf[(y0 >> l2pu) * min_pu_width + (x0 >> l2pu)].pred_flag ==
    hevc_pf_intra
  let rpl = self.rpl
  let ctb_size = 1 << sps.log2_ctb_size
  let ctb_x = x0 >> sps.log2_ctb_size
  let ctb_y = y0 >> sps.log2_ctb_size
  let curr_rs = ctb_y * sps.ctb_width + ctb_x
  let pps = self.pps
  let mut upper_slice_edge = false
  let mut upper_tile_edge = false
  let mut up_rs = curr_rs
  if y0 > 0 && (y0 & 7) == 0 && (y0 % ctb_size) == 0 {
    up_rs = curr_rs - sps.ctb_width
    upper_slice_edge = self.ctb_slice_idx[up_rs] != self.slice_idx
    if pps.tiles_enabled_flag != 0 {
      upper_tile_edge = pps.tile_id[pps.ctb_addr_rs_to_ts[up_rs]] !=
        pps.tile_id[pps.ctb_addr_rs_to_ts[curr_rs]]
    }
  }
  let mut boundary_upper = y0 > 0 && (y0 & 7) == 0
  if boundary_upper &&
    ((upper_slice_edge &&
    !self.sh.slice_loop_filter_across_slices_enabled_flag) ||
    (upper_tile_edge && pps.loop_filter_across_tiles_enabled_flag == 0)) {
    boundary_upper = false
  }
  let mut left_slice_edge = false
  let mut left_tile_edge = false
  let mut left_rs = curr_rs
  if x0 > 0 && (x0 & 7) == 0 && (x0 % ctb_size) == 0 {
    left_rs = curr_rs - 1
    left_slice_edge = self.ctb_slice_idx[left_rs] != self.slice_idx
    if pps.tiles_enabled_flag != 0 {
      left_tile_edge = pps.tile_id[pps.ctb_addr_rs_to_ts[left_rs]] !=
        pps.tile_id[pps.ctb_addr_rs_to_ts[curr_rs]]
    }
  }
  let mut boundary_left = x0 > 0 && (x0 & 7) == 0
  if boundary_left &&
    ((left_slice_edge &&
    !self.sh.slice_loop_filter_across_slices_enabled_flag) ||
    (left_tile_edge && pps.loop_filter_across_tiles_enabled_flag == 0)) {
    boundary_left = false
  }
  let top_rpl = if upper_slice_edge || upper_tile_edge {
    self.slice_rpls[self.ctb_slice_idx[up_rs]]
  } else {
    rpl
  }
  let left_nb_rpl = if left_slice_edge || left_tile_edge {
    self.slice_rpls[self.ctb_slice_idx[left_rs]]
  } else {
    rpl
  }
  if boundary_upper {
    let yp_pu = (y0 - 1) >> l2pu
    let yq_pu = y0 >> l2pu
    let yp_tu = (y0 - 1) >> l2tu
    let yq_tu = y0 >> l2tu
    let mut i = 0
    while i < (1 << log2_trafo_size) {
      let x_pu = (x0 + i) >> l2pu
      let x_tu = (x0 + i) >> l2tu
      let top = tab_mvf[yp_pu * min_pu_width + x_pu]
      let curr = tab_mvf[yq_pu * min_pu_width + x_pu]
      let top_cbf = self.cbf_luma_tab[yp_tu * min_tu_width + x_tu]
      let curr_cbf = self.cbf_luma_tab[yq_tu * min_tu_width + x_tu]
      let bs = if curr.pred_flag == hevc_pf_intra || top.pred_flag == hevc_pf_intra {
        2
      } else if curr_cbf != 0 || top_cbf != 0 {
        1
      } else if rpl.length() >= 2 {
        hevc_boundary_strength(rpl, top_rpl, curr, top)
      } else {
        1
      }
      self.horizontal_bs[((x0 + i) + y0 * self.bs_width) >> 2] = bs
      i = i + 4
    }
  }
  if boundary_left {
    let xp_pu = (x0 - 1) >> l2pu
    let xq_pu = x0 >> l2pu
    let xp_tu = (x0 - 1) >> l2tu
    let xq_tu = x0 >> l2tu
    let mut i = 0
    while i < (1 << log2_trafo_size) {
      let y_pu = (y0 + i) >> l2pu
      let y_tu = (y0 + i) >> l2tu
      let left = tab_mvf[y_pu * min_pu_width + xp_pu]
      let curr = tab_mvf[y_pu * min_pu_width + xq_pu]
      let left_cbf = self.cbf_luma_tab[y_tu * min_tu_width + xp_tu]
      let curr_cbf = self.cbf_luma_tab[y_tu * min_tu_width + xq_tu]
      let bs = if curr.pred_flag == hevc_pf_intra || left.pred_flag == hevc_pf_intra {
        2
      } else if curr_cbf != 0 || left_cbf != 0 {
        1
      } else if rpl.length() >= 2 {
        hevc_boundary_strength(rpl, left_nb_rpl, curr, left)
      } else {
        1
      }
      self.vertical_bs[(x0 + (y0 + i) * self.bs_width) >> 2] = bs
      i = i + 4
    }
  }
  if log2_trafo_size > l2pu && !is_intra {
    // TU-internal PU boundaries.
    let mut j = 8
    while j < (1 << log2_trafo_size) {
      let yp_pu = (y0 + j - 1) >> l2pu
      let yq_pu = (y0 + j) >> l2pu
      let mut i = 0
      while i < (1 << log2_trafo_size) {
        let x_pu = (x0 + i) >> l2pu
        let top = tab_mvf[yp_pu * min_pu_width + x_pu]
        let curr = tab_mvf[yq_pu * min_pu_width + x_pu]
        let bs = if rpl.length() >= 2 {
          hevc_boundary_strength(rpl, rpl, curr, top)
        } else {
          1
        }
        self.horizontal_bs[((x0 + i) + (y0 + j) * self.bs_width) >> 2] = bs
        i = i + 4
      }
      j = j + 8
    }
    let mut j2 = 0
    while j2 < (1 << log2_trafo_size) {
      let y_pu = (y0 + j2) >> l2pu
      let mut i = 8
      while i < (1 << log2_trafo_size) {
        let xp_pu = (x0 + i - 1) >> l2pu
        let xq_pu = (x0 + i) >> l2pu
        let left = tab_mvf[y_pu * min_pu_width + xp_pu]
        let curr = tab_mvf[y_pu * min_pu_width + xq_pu]
        let bs = if rpl.length() >= 2 {
          hevc_boundary_strength(rpl, rpl, curr, left)
        } else {
          1
        }
        self.vertical_bs[((x0 + i) + (y0 + j2) * self.bs_width) >> 2] = bs
        i = i + 8
      }
      j2 = j2 + 4
    }
  }
}

///|
/// A decoded output frame. */
pub struct HevcDecodedFrame {
  pic : HevcPicture
  poc : Int32
  is_irap : Bool
}

///|
/// Frame-level HEVC decoder state (DPB + POC tracking across pictures). */
pub struct HevcDecoder {
  ps : HevcParamSets
  mut dpb : HevcDpb?
  mut poc_tid0 : Int32
  frames : Array[HevcDecodedFrame]
}

///|
pub fn hevc_decoder_new() -> HevcDecoder {
  {
    ps: new_hevc_param_sets(),
    dpb: None,
    poc_tid0: 0,
    frames: [],
  }
}

///|
/// `ff_hevc_slice_rpl` for a single-slice picture: concatenate the RPS
/// candidate lists (ST_CURR_BEF/ST_CURR_AFT/LT, ordered per list) into L0/L1. */
fn hevc_slice_rpl(
  dpb : HevcDpb,
  cur : HevcRefFrame,
  sh : HevcSliceHeader,
) -> Result[Unit, String] {
  let nb_list = if sh.slice_type == hevc_slice_b { 2 } else { 1 }
  if dpb.rps[hevc_rps_st_curr_bef].nb_refs() +
    dpb.rps[hevc_rps_st_curr_aft].nb_refs() +
    dpb.rps[hevc_rps_lt_curr].nb_refs() ==
    0 {
    return Err("hevc: zero refs in the frame RPS")
  }
  dpb.collocated = cur
  for list_idx in 0..<nb_list {
    let rpl_tmp = hevc_ref_pic_list_new()
    let cands : Array[(HevcRefPicList, Bool)] = if list_idx == 0 {
      [
        (dpb.rps[hevc_rps_st_curr_bef], false),
        (dpb.rps[hevc_rps_st_curr_aft], false),
        (dpb.rps[hevc_rps_lt_curr], true),
      ]
    } else {
      [
        (dpb.rps[hevc_rps_st_curr_aft], false),
        (dpb.rps[hevc_rps_st_curr_bef], false),
        (dpb.rps[hevc_rps_lt_curr], true),
      ]
    }
    let nb_target = if list_idx == 0 {
      sh.num_ref_idx_l0_active
    } else {
      sh.num_ref_idx_l1_active
    }
    while rpl_tmp.nb_refs() < nb_target && rpl_tmp.nb_refs() < 16 {
      for cand in cands {
        let (lst, is_lt) = cand
        for entry in lst.entries {
          if rpl_tmp.nb_refs() < 16 {
            rpl_tmp.push(entry.poc, is_lt, entry.frame)
          }
        }
      }
    }
    let target = if list_idx == 0 { cur.rpl0 } else { cur.rpl1 }
    target.clear()
    for i in 0..<nb_target {
      if i >= rpl_tmp.nb_refs() {
        break
      }
      let e = rpl_tmp.entries[i]
      target.push(e.poc, e.is_long_term, e.frame)
    }
    if sh.collocated_list == list_idx && sh.collocated_ref_idx < target.nb_refs() {
      dpb.collocated = target.entries[sh.collocated_ref_idx].frame
    }
  }
  Ok(())
}

///|
/// `ff_hevc_frame_rps`: rebuild the RPS candidate lists from the slice's
/// short/long-term RPS against the DPB. */
fn hevc_frame_rps(
  dpb : HevcDpb,
  sh : HevcSliceHeader,
  log2_max_poc_lsb : Int32,
) -> Unit {
  dpb.unref_missing_refs()
  for frame in dpb.slots {
    if frame.in_use && frame.slot != dpb.cur.slot {
      frame.short_ref = false
      frame.long_ref = false
    }
  }
  dpb.reset_rps()
  let st = sh.st_rps
  for i in 0..<st.num_delta_pocs {
    let poc = dpb.cur.poc + st.delta_poc[i]
    let used = (st.used & (1U << i)) != 0U
    let list = if !used {
      hevc_rps_st_foll
    } else if i < st.num_negative_pics {
      hevc_rps_st_curr_bef
    } else {
      hevc_rps_st_curr_aft
    }
    dpb.add_candidate_ref(list, poc, true, false, true, log2_max_poc_lsb, dpb.cur.poc)
  }
  let lt = sh.lt_rps
  for i in 0..<lt.nb_refs {
    let list = if lt.used[i] { hevc_rps_lt_curr } else { hevc_rps_lt_foll }
    dpb.add_candidate_ref(
      list,
      lt.poc[i],
      false,
      true,
      lt.poc_msb_present[i],
      log2_max_poc_lsb,
      dpb.cur.poc,
    )
  }
  dpb.release_unused()
}

///|
/// Decode every picture of an Annex B (or length-prefixed) HEVC stream.
/// Returns the frames in decode order with their POCs (sort by POC for
/// presentation order). */
pub fn ff_hevc_decode_frames(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
) -> Result[Array[HevcDecodedFrame], String] {
  ff_hevc_decode_frames_ex(data, is_nalff, nal_length_size, true)
}

///|
/// Like `ff_hevc_decode_frames`, optionally skipping the in-loop filters to
/// match `ffmpeg -skip_loop_filter all`. */
pub fn ff_hevc_decode_frames_ex(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
  apply_filters : Bool,
) -> Result[Array[HevcDecodedFrame], String] {
  let dec = hevc_decoder_new()
  let pkt = match ff_h2645_packet_split(data, nal_length_size, Hevc, is_nalff) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  // Group consecutive VCL NALs into one access unit: a VCL NAL whose
  // first_slice_segment_in_pic_flag is set starts a new picture.
  let mut au : Array[H2645Nal] = []
  let mut idx = 0
  let nnals = pkt.nals.length()
  while idx < nnals {
    let nal = pkt.nals[idx]
    if nal.nal_type > 31 {
      // Non-VCL: parameter sets feed the shared state.
      if nal.nal_type == hevc_nal_vps ||
        nal.nal_type == hevc_nal_sps ||
        nal.nal_type == hevc_nal_pps {
        let single : H2645Packet = { nals: [nal] }
        match hevc_decode_extradata_nals(single, dec.ps, true) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      idx = idx + 1
      continue
    }
    if hevc_nal_is_first_slice(nal) && au.length() > 0 {
      match hevc_decode_picture(dec, au, apply_filters) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      au = []
    }
    au.push(nal)
    idx = idx + 1
  }
  if au.length() > 0 {
    match hevc_decode_picture(dec, au, apply_filters) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(dec.frames)
}

///|
fn hevc_nal_is_first_slice(nal : H2645Nal) -> Bool {
  if nal.size_bits < 17 {
    return false
  }
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(16)
  gb.read1() != 0
}

///|
/// Build the per-slice CABAC/context state after `ff_hevc_slice_rpl` has run.
fn hevc_make_slice_state(
  dpb : HevcDpb,
  cur : HevcRefFrame,
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  nal : H2645Nal,
) -> Result[(Int32, HevcCabac, Array[HevcRefPicList], HevcInterCtx?), String] {
  let slice_qp = 26 + pps.pic_init_qp_minus26 + sh.slice_qp_delta
  let states = ff_hevc_init_cabac_states(
    slice_qp,
    sh.slice_type,
    sh.cabac_init_flag,
  )
  let data_offset = (sh.header_bits + 7) >> 3
  let cabac = match hevc_cabac_new(nal.data, data_offset, states) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  let rpl : Array[HevcRefPicList] = if sh.slice_type == hevc_slice_i {
    []
  } else {
    [cur.rpl0, cur.rpl1]
  }
  let inter_ctx : HevcInterCtx? = if sh.slice_type == hevc_slice_i {
    None
  } else {
    Some({
      sps,
      pps,
      sh,
      poc: sh.poc,
      tab_mvf: cur.tab_mvf,
      rpl,
      collocated: if sh.slice_temporal_mvp_enabled_flag {
        Some(dpb.collocated)
      } else {
        None
      },
      cabac,
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
    })
  }
  Ok((slice_qp, cabac, rpl, inter_ctx))
}

///|
/// Decode one CTB of the current slice; returns the C `more_data` flag.
fn hevc_decode_ctb(
  dec_slice : HevcIntraDecoder,
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  rs : Int32,
  ts : Int32,
  slice_start : Int32,
  ctb_size : Int32,
) -> Result[Bool, String] {
  let x_ctb = (rs % sps.ctb_width) << sps.log2_ctb_size
  let y_ctb = (rs / sps.ctb_width) << sps.log2_ctb_size
  let ctb_addr_in_slice = rs - slice_start
  let tiles = pps.tiles_enabled_flag != 0
  let mut left_tile = false
  let mut upper_tile = false
  let mut up_left_same_tile = true
  let mut up_right_same_tile = true
  if tiles {
    let curr_tile = pps.tile_id[ts]
    if x_ctb > 0 {
      left_tile = pps.tile_id[pps.ctb_addr_rs_to_ts[rs - 1]] != curr_tile
    }
    if y_ctb > 0 {
      upper_tile = pps.tile_id[pps.ctb_addr_rs_to_ts[rs - sps.ctb_width]] !=
        curr_tile
      if x_ctb > 0 {
        up_left_same_tile = pps.tile_id[pps.ctb_addr_rs_to_ts[rs - sps.ctb_width -
          1]] ==
          curr_tile
      }
      if x_ctb + ctb_size < sps.width {
        up_right_same_tile = pps.tile_id[pps.ctb_addr_rs_to_ts[rs + 1 -
          sps.ctb_width]] ==
          curr_tile
      } else {
        up_right_same_tile = false
      }
    }
  }
  dec_slice.ctb_left = x_ctb > 0 && ctb_addr_in_slice > 0 && !left_tile
  dec_slice.ctb_up = y_ctb > 0 &&
    ctb_addr_in_slice >= sps.ctb_width &&
    !upper_tile
  dec_slice.ctb_up_left = x_ctb > 0 &&
    y_ctb > 0 &&
    ctb_addr_in_slice - 1 >= sps.ctb_width &&
    up_left_same_tile
  dec_slice.ctb_up_right = y_ctb > 0 &&
    ctb_addr_in_slice + 1 >= sps.ctb_width &&
    up_right_same_tile
  if tiles {
    let ctb_x = x_ctb >> sps.log2_ctb_size
    let mut tx = 0
    for i in 0..<pps.num_tile_columns {
      if ctb_x < pps.col_bd[i + 1] {
        tx = i
        break
      }
    }
    dec_slice.end_of_tiles_x = pps.col_bd[tx + 1] << sps.log2_ctb_size
  } else {
    dec_slice.end_of_tiles_x = sps.width
  }
  dec_slice.end_of_tiles_y = if y_ctb + ctb_size < sps.height {
    y_ctb + ctb_size
  } else {
    sps.height
  }
  if tiles && ts > 0 && pps.tile_id[ts] != pps.tile_id[ts - 1] {
    dec_slice.first_qp_group = true
  }
  match dec_slice.inter {
    Some(ctx) => {
      ctx.ctb_left = dec_slice.ctb_left
      ctx.ctb_up = dec_slice.ctb_up
      ctx.ctb_up_left = dec_slice.ctb_up_left
      ctx.ctb_up_right = dec_slice.ctb_up_right
      ctx.end_of_tiles_x = dec_slice.end_of_tiles_x
      ctx.end_of_tiles_y = dec_slice.end_of_tiles_y
    }
    None => ()
  }
  dec_slice.ctb_slice_idx[rs] = dec_slice.slice_idx
  dec_slice.deblock_tc[rs] = sh.tc_offset
  dec_slice.deblock_beta[rs] = sh.beta_offset
  dec_slice.filter_slice_edges[rs] = if sh.slice_loop_filter_across_slices_enabled_flag {
    1
  } else {
    0
  }
  if sps.sao_enabled != 0 {
    hevc_sao_parse(
      dec_slice.cabac,
      sps,
      pps,
      sh,
      dec_slice.sao,
      rs,
      x_ctb,
      y_ctb,
      dec_slice.ctb_left,
      dec_slice.ctb_up,
    )
  }
  dec_slice.coding_quadtree(x_ctb, y_ctb, sps.log2_ctb_size, 0)
}

///|
fn hevc_decode_picture(
  dec : HevcDecoder,
  nals : Array[H2645Nal],
  apply_filters : Bool,
) -> Result[Unit, String] {
  let ps = dec.ps
  let first_nal = nals[0]
  let first_gb = BitReader::with_size(first_nal.data, first_nal.size_bits)
  first_gb.skip(16)
  let first_sh = match
    ff_hevc_decode_slice_header(
      first_gb,
      first_nal.nal_type,
      ps,
      dec.poc_tid0,
    ) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  if !first_sh.first_slice_segment_in_pic_flag {
    return Err("hevc: access unit does not start with a first slice segment")
  }
  let pps = match ps.pps_list[first_sh.pps_id] {
    Some(p) => p
    None => return Err("hevc: missing PPS")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("hevc: missing SPS")
  }
  if (sps.bit_depth != 8 && sps.bit_depth != 10 && sps.bit_depth != 12) ||
    sps.chroma_format_idc == 0 ||
    sps.separate_colour_plane != 0 {
    return Err("PATCHWELCOME: only 8/10/12-bit 4:2:0/4:2:2/4:4:4 HEVC is supported")
  }
  if sps.pcm_enabled != 0 {
    return Err("PATCHWELCOME: HEVC PCM is not supported")
  }
  if sps.implicit_rdpcm_enabled != 0 || sps.explicit_rdpcm_enabled != 0 {
    return Err("PATCHWELCOME: HEVC RDPCM is not supported")
  }
  if pps.transquant_bypass_enable_flag != 0 {
    return Err("PATCHWELCOME: HEVC transquant bypass is not supported")
  }
  if pps.cross_component_prediction_enabled_flag != 0 {
    return Err("PATCHWELCOME: HEVC cross-component prediction is not supported")
  }
  if pps.tiles_enabled_flag != 0 && pps.entropy_coding_sync_enabled_flag != 0 {
    return Err("PATCHWELCOME: HEVC tiles with WPP are not supported")
  }
  if pps.pps_curr_pic_ref_enabled_flag != 0 {
    return Err("PATCHWELCOME: HEVC current picture referencing is not supported")
  }
  // (Re)allocate the DPB when the picture geometry appears or changes.
  let cw = sps.width >> sps.hshift[1]
  let ch = sps.height >> sps.vshift[1]
  let dpb = match dec.dpb {
    Some(d) =>
      if d.width == sps.width &&
        d.height == sps.height &&
        d.cw == cw &&
        d.ch == ch {
        d
      } else {
        let d = hevc_dpb_new(
          sps.width,
          sps.height,
          cw,
          ch,
          sps.min_pu_width,
          sps.min_pu_height,
        )
        dec.dpb = Some(d)
        d
      }
    None => {
      let d = hevc_dpb_new(
        sps.width,
        sps.height,
        cw,
        ch,
        sps.min_pu_width,
        sps.min_pu_height,
      )
      dec.dpb = Some(d)
      d
    }
  }
  let first_nal_type = first_nal.nal_type
  let is_idr = first_nal_type == 19 || first_nal_type == 20
  let is_irap = first_nal_type >= 16 && first_nal_type <= 23
  if is_idr {
    dpb.clear_refs()
  }
  // 8.3.1: update the temporal-id-0 POC outside the N/R NAL types
  // (TRAIL_R/TSA_R/STSA_R still update, as in the C).
  let nal_type = first_nal_type
  if first_nal.temporal_id == 0 &&
    nal_type != 0 &&
    nal_type != 2 &&
    nal_type != 4 &&
    nal_type != 6 &&
    nal_type != 7 &&
    nal_type != 8 &&
    nal_type != 9 {
    dec.poc_tid0 = first_sh.poc
  }
  let cur = match dpb.set_new_ref(first_sh.poc) {
    Some(f) => f
    None => return Err("hevc: duplicate POC in a sequence")
  }
  hevc_frame_rps(dpb, first_sh, sps.log2_max_poc_lsb)
  if first_sh.slice_type != hevc_slice_i {
    match hevc_slice_rpl(dpb, cur, first_sh) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  let (first_qp, first_cabac, first_rpl, first_inter) = match
    hevc_make_slice_state(dpb, cur, sps, pps, first_sh, first_nal) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let dec_slice = hevc_intra_decoder_new(
    sps,
    pps,
    first_sh,
    first_cabac,
    first_qp,
    cur.pic,
    cur.tab_mvf,
    first_rpl,
    first_inter,
  )
  dec_slice.start_slice(first_sh, first_cabac, first_qp, first_rpl, first_inter)
  let ctb_size = 1 << sps.log2_ctb_size
  for i in 0..<nals.length() {
    let nal = nals[i]
    let sh = if i == 0 {
      first_sh
    } else {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(16)
      let h = match
        ff_hevc_decode_slice_header(gb, nal.nal_type, ps, dec.poc_tid0) {
        Ok(h) => h
        Err(e) => return Err(e)
      }
      if h.pps_id != first_sh.pps_id {
        return Err("hevc: PPS changed between slices")
      }
      // C ignores POC changes between slices of one picture.
      h.poc = first_sh.poc
      if h.slice_type != hevc_slice_i {
        match hevc_slice_rpl(dpb, cur, h) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      let (slice_qp, cabac, rpl, inter_ctx) = match
        hevc_make_slice_state(dpb, cur, sps, pps, h, nal) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      dec_slice.start_slice(h, cabac, slice_qp, rpl, inter_ctx)
      h
    }
    let slice_start = sh.slice_segment_address
    let wpp = pps.entropy_coding_sync_enabled_flag != 0 &&
      sh.num_entry_point_offsets > 0
    if wpp {
      if slice_start % sps.ctb_width != 0 {
        return Err("PATCHWELCOME: WPP slice starting mid-row")
      }
      let mut common_states = dec_slice.cabac.states.copy()
      let mut ended = false
      let mut row = 0
      let n_rows = sh.num_entry_point_offsets + 1
      while row < n_rows && !ended {
        if row > 0 {
          // C `ff_hevc_cabac_init` non-WPP path: consume the row's terminate
          // bin, rewind to the next byte, then load the saved context state.
          ignore(dec_slice.cabac.terminate())
          match dec_slice.cabac.cc.reinit() {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          let states = if sps.ctb_width == 1 {
            ff_hevc_init_cabac_states(
              dec_slice.slice_qp,
              sh.slice_type,
              sh.cabac_init_flag,
            )
          } else {
            common_states
          }
          for k in 0..<dec_slice.cabac.states.length() {
            dec_slice.cabac.states[k] = states[k]
          }
          dec_slice.restart_wpp_row()
        }
        let mut rs = slice_start + row * sps.ctb_width
        let mut col = 0
        let mut more = true
        while more && col < sps.ctb_width && rs < sps.ctb_size {
          more = match
            hevc_decode_ctb(dec_slice, sps, pps, sh, rs, rs, slice_start, ctb_size) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          if col == 1 {
            common_states = dec_slice.cabac.states.copy()
          }
          col = col + 1
          rs = rs + 1
        }
        if !more {
          ended = true
        }
        row = row + 1
      }
    } else if pps.tiles_enabled_flag != 0 {
      let start_ts = pps.ctb_addr_rs_to_ts[slice_start]
      let mut ts = start_ts
      let mut more = true
      while more && ts < sps.ctb_size {
        if ts > start_ts && pps.tile_id[ts] != pps.tile_id[ts - 1] {
          // C `ff_hevc_cabac_init` tile branch: align at the tile substream
          // boundary and restart with fresh context states.
          match dec_slice.cabac.cc.reinit() {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          let states = ff_hevc_init_cabac_states(
            dec_slice.slice_qp,
            sh.slice_type,
            sh.cabac_init_flag,
          )
          for k in 0..<dec_slice.cabac.states.length() {
            dec_slice.cabac.states[k] = states[k]
          }
          dec_slice.first_qp_group = true
        }
        let rs = pps.ctb_addr_ts_to_rs[ts]
        more = match
          hevc_decode_ctb(dec_slice, sps, pps, sh, rs, ts, slice_start, ctb_size) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        ts = ts + 1
      }
    } else {
      let mut rs = slice_start
      let mut more = true
      while more && rs < sps.ctb_size {
        more = match
          hevc_decode_ctb(dec_slice, sps, pps, sh, rs, rs, slice_start, ctb_size) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        rs = rs + 1
      }
    }
  }
  if apply_filters {
    hevc_deblock_picture(
      dec_slice.pic,
      sps,
      pps,
      dec_slice.deblock_tc,
      dec_slice.deblock_beta,
      dec_slice.qp_y_tab,
      dec_slice.vertical_bs,
      dec_slice.horizontal_bs,
      dec_slice.bs_width,
    )
    hevc_sao_apply(
      dec_slice.pic,
      sps,
      pps,
      dec_slice.sao,
      dec_slice.filter_slice_edges,
      dec_slice.ctb_slice_idx,
    )
  }
  dec.frames.push({
    pic: cur.pic.clone(),
    poc: cur.poc,
    is_irap,
  })
  Ok(())
}
