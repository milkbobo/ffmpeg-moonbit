///|
/// HEVC inter prediction, ported from FFmpeg 9.0.2
/// `libavcodec/hevc/mvs.c` (`derive_spatial_merge_candidates`,
/// `ff_hevc_luma_mv_merge_mode`, `ff_hevc_luma_mv_mvp_mode`,
/// `temporal_luma_motion_vector`, `derive_temporal_colocated_mvs`) and
/// `libavcodec/hevc/hevcdec.c` (`hls_prediction_unit`).
///
/// Single-slice pictures only, so the per-CTB `rpl_tab` of the C collapses to
/// one reference picture list per frame.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Part modes (`enum PartMode`). */
pub let hevc_part_2nx2n : Int32 = 0

///|
pub let hevc_part_2nxn : Int32 = 1

///|
pub let hevc_part_nx2n : Int32 = 2

///|
pub let hevc_part_nxn : Int32 = 3

///|
pub let hevc_part_2nxnu : Int32 = 4

///|
pub let hevc_part_2nxnd : Int32 = 5

///|
pub let hevc_part_nlx2n : Int32 = 6

///|
pub let hevc_part_nrx2n : Int32 = 7

///|
/// Prediction-unit context shared by the merge/AMVP derivation. */
pub struct HevcInterCtx {
  sps : HevcSps
  pps : HevcPps
  sh : HevcSliceHeader
  /// Current picture POC (`s->poc`).
  poc : Int32
  /// Current frame's per-min-PU motion field.
  tab_mvf : Array[HevcMvField]
  rpl : Array[HevcRefPicList]
  /// The collocated frame for temporal MV prediction (may be absent).
  collocated : HevcRefFrame?
  cabac : HevcCabac
  na : HevcNeighbourAvail
  mut ctb_left : Bool
  mut ctb_up : Bool
  mut ctb_up_left : Bool
  mut ctb_up_right : Bool
  mut end_of_tiles_x : Int32
  mut end_of_tiles_y : Int32
  mut ct_depth : Int32
  mut part_mode : Int32
  /// `lc->cu.x` / `lc->cu.y` (used by the merge singleMCLFlag path).
  mut cu_x : Int32
  mut cu_y : Int32
  /// Merge flag of the most recently parsed PU (`lc->pu.merge_flag`).
  mut last_merge_flag : Bool
}

///|
/// `ff_hevc_set_neighbour_available` (mvs.c variant, keeping `sap`). */
fn HevcInterCtx::set_neighbour_available(
  self : HevcInterCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
) -> Unit {
  let ctb_size = 1 << self.sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  self.na.cand_up = self.ctb_up || y0b != 0
  self.na.cand_left = self.ctb_left || x0b != 0
  self.na.cand_up_left = if x0b != 0 || y0b != 0 {
    self.na.cand_left && self.na.cand_up
  } else {
    self.ctb_up_left
  }
  let up_right_sap = if x0b + n_pb_w == ctb_size {
    self.ctb_up_right && y0b == 0
  } else {
    self.na.cand_up
  }
  self.na.cand_up_right_sap = up_right_sap
  self.na.cand_up_right = up_right_sap && x0 + n_pb_w < self.end_of_tiles_x
  self.na.cand_bottom_left = if y0 + n_pb_h >= self.end_of_tiles_y {
    false
  } else {
    self.na.cand_left
  }
}

///|
/// 6.4.1 z-scan block availability (`z_scan_block_avail`). */
fn hevc_z_scan_block_avail(
  sps : HevcSps,
  pps : HevcPps,
  x_curr : Int32,
  y_curr : Int32,
  x_n : Int32,
  y_n : Int32,
) -> Bool {
  let x_curr_ctb = x_curr >> sps.log2_ctb_size
  let y_curr_ctb = y_curr >> sps.log2_ctb_size
  let x_n_ctb = x_n >> sps.log2_ctb_size
  let y_n_ctb = y_n >> sps.log2_ctb_size
  if y_n_ctb < y_curr_ctb || x_n_ctb < x_curr_ctb {
    return true
  }
  let curr = hevc_min_tb_addr_zs(
    sps,
    pps,
    (x_curr >> sps.log2_min_tb_size) & sps.tb_mask,
    (y_curr >> sps.log2_min_tb_size) & sps.tb_mask,
  )
  let n = hevc_min_tb_addr_zs(
    sps,
    pps,
    (x_n >> sps.log2_min_tb_size) & sps.tb_mask,
    (y_n >> sps.log2_min_tb_size) & sps.tb_mask,
  )
  n <= curr
}

///|
/// `is_diff_mer`. */
fn hevc_is_diff_mer(
  pps : HevcPps,
  x_n : Int32,
  y_n : Int32,
  x_p : Int32,
  y_p : Int32,
) -> Bool {
  let plevel = pps.log2_parallel_merge_level
  x_n >> plevel == x_p >> plevel && y_n >> plevel == y_p >> plevel
}

///|
/// `compare_mv_ref_idx`: same pred flag, ref indices and MVs. */
fn hevc_compare_mv_ref_idx(a : HevcMvField, b : HevcMvField) -> Bool {
  if a.pred_flag == b.pred_flag {
    if a.pred_flag == hevc_pf_bi {
      return a.ref_idx0 == b.ref_idx0 &&
        a.mv0.x == b.mv0.x &&
        a.mv0.y == b.mv0.y &&
        a.ref_idx1 == b.ref_idx1 &&
        a.mv1.x == b.mv1.x &&
        a.mv1.y == b.mv1.y
    } else if a.pred_flag == hevc_pf_l0 {
      return a.ref_idx0 == b.ref_idx0 &&
        a.mv0.x == b.mv0.x &&
        a.mv0.y == b.mv0.y
    } else if a.pred_flag == hevc_pf_l1 {
      return a.ref_idx1 == b.ref_idx1 &&
        a.mv1.x == b.mv1.x &&
        a.mv1.y == b.mv1.y
    }
  }
  false
}

///|
/// `derive_temporal_colocated_mvs`. */
fn hevc_derive_temporal_colocated_mvs(
  ctx : HevcInterCtx,
  temp_col : HevcMvField,
  ref_idx_lx : Int32,
  mv_lx_col : HevcMv,
  x_list : Int32,
  col_pic : Int32,
  col_frame : HevcRefFrame,
) -> Bool {
  if temp_col.pred_flag == hevc_pf_intra {
    return false
  }
  let check = fn(l : Int32) -> Bool {
    hevc_check_mvset(
      mv_lx_col,
      if l == 0 {
        temp_col.mv0
      } else {
        temp_col.mv1
      },
      col_pic,
      ctx.poc,
      ctx.rpl[x_list],
      ref_idx_lx,
      if l == 0 {
        col_frame.rpl0
      } else {
        col_frame.rpl1
      },
      if l == 0 {
        temp_col.ref_idx0
      } else {
        temp_col.ref_idx1
      },
    )
  }
  if (temp_col.pred_flag & hevc_pf_l0) == 0 {
    return check(1)
  } else if temp_col.pred_flag == hevc_pf_l0 {
    return check(0)
  }
  let mut check_diffpicount = 0
  for j in 0..<2 {
    let rpl = ctx.rpl[j]
    for i in 0..<rpl.nb_refs() {
      if rpl.poc(i) > ctx.poc {
        check_diffpicount = check_diffpicount + 1
        break
      }
    }
  }
  if check_diffpicount == 0 {
    check(x_list)
  } else if ctx.sh.collocated_list == 1 {
    check(0)
  } else {
    check(1)
  }
}

///|
/// 8.5.3.1.7 temporal luma motion vector prediction. */
fn hevc_temporal_luma_motion_vector(
  ctx : HevcInterCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  ref_idx_lx : Int32,
  mv_lx_col : HevcMv,
  x_list : Int32,
) -> Bool {
  let col_frame = match ctx.collocated {
    Some(r) => r
    None => {
      mv_lx_col.x = 0
      mv_lx_col.y = 0
      return false
    }
  }
  let sps = ctx.sps
  let tab_mvf = col_frame.tab_mvf
  let col_pic = col_frame.poc
  let l2pu = sps.log2_min_pu_size
  let mut available = false
  let x_br = x0 + n_pb_w
  let y_br = y0 + n_pb_h
  if y0 >> sps.log2_ctb_size == y_br >> sps.log2_ctb_size &&
    y_br < sps.height &&
    x_br < sps.width {
    let x = x_br & -16
    let y = y_br & -16
    let temp_col = tab_mvf[(y >> l2pu) * sps.min_pu_width + (x >> l2pu)]
    available = hevc_derive_temporal_colocated_mvs(
      ctx, temp_col, ref_idx_lx, mv_lx_col, x_list, col_pic, col_frame,
    )
  }
  if !available {
    let x = (x0 + (n_pb_w >> 1)) & -16
    let y = (y0 + (n_pb_h >> 1)) & -16
    let temp_col = tab_mvf[(y >> l2pu) * sps.min_pu_width + (x >> l2pu)]
    available = hevc_derive_temporal_colocated_mvs(
      ctx, temp_col, ref_idx_lx, mv_lx_col, x_list, col_pic, col_frame,
    )
  }
  available
}

///|
/// `l0_l1_cand_idx` for combined bi-predictive merge candidates. */
let hevc_l0_l1_cand_idx : FixedArray[(Int32, Int32)] = [
  (0, 1),
  (1, 0),
  (0, 2),
  (2, 0),
  (1, 2),
  (2, 1),
  (0, 3),
  (3, 0),
  (1, 3),
  (3, 1),
  (2, 3),
  (3, 2),
]

///|
/// 8.5.3.1.2 spatial merging candidates; fills `mergecand_list` and returns
/// the number of candidates derived before the zero-MV padding. */
fn hevc_derive_spatial_merge_candidates(
  ctx : HevcInterCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  single_mcl_flag : Bool,
  part_idx : Int32,
  mergecand_list : Array[HevcMvField],
) -> Unit {
  let sps = ctx.sps
  let pps = ctx.pps
  let sh = ctx.sh
  let tab_mvf = ctx.tab_mvf
  let l2pu = sps.log2_min_pu_size
  let cand_bottom_left = ctx.na.cand_bottom_left
  let cand_left = ctx.na.cand_left
  let cand_up_left = ctx.na.cand_up_left
  let cand_up = ctx.na.cand_up
  let cand_up_right = ctx.na.cand_up_right_sap
  let x_a1 = x0 - 1
  let y_a1 = y0 + n_pb_h - 1
  let x_b1 = x0 + n_pb_w - 1
  let y_b1 = y0 - 1
  let x_b0 = x0 + n_pb_w
  let y_b0 = y0 - 1
  let x_a0 = x0 - 1
  let y_a0 = y0 + n_pb_h
  let x_b2 = x0 - 1
  let y_b2 = y0 - 1
  let nb_refs = if sh.slice_type == hevc_slice_p {
    sh.num_ref_idx_l0_active
  } else {
    let a = sh.num_ref_idx_l0_active
    let b = sh.num_ref_idx_l1_active
    if a < b {
      a
    } else {
      b
    }
  }
  let mut zero_idx = 0
  let mut nb_merge_cand = 0
  let mut nb_orig_merge_cand = 0
  let available = fn(cand : Bool, x_v : Int32, y_v : Int32) -> Bool {
    cand &&
    tab_mvf[(y_v >> l2pu) * sps.min_pu_width + (x_v >> l2pu)].pred_flag !=
    hevc_pf_intra
  }
  let mvf = fn(x_v : Int32, y_v : Int32) -> HevcMvField {
    tab_mvf[(y_v >> l2pu) * sps.min_pu_width + (x_v >> l2pu)]
  }
  let push = fn(src : HevcMvField) -> Unit {
    mergecand_list[nb_merge_cand].copy_from(src)
    nb_merge_cand = nb_merge_cand + 1
  }
  let is_available_a1 = if (
      !single_mcl_flag &&
      part_idx == 1 &&
      (
        ctx.part_mode == hevc_part_nx2n ||
        ctx.part_mode == hevc_part_nlx2n ||
        ctx.part_mode == hevc_part_nrx2n
      )
    ) ||
    hevc_is_diff_mer(pps, x_a1, y_a1, x0, y0) {
    false
  } else {
    available(cand_left, x_a1, y_a1)
  }
  if is_available_a1 {
    push(mvf(x_a1, y_a1))
  }
  let is_available_b1 = if (
      !single_mcl_flag &&
      part_idx == 1 &&
      (
        ctx.part_mode == hevc_part_2nxn ||
        ctx.part_mode == hevc_part_2nxnu ||
        ctx.part_mode == hevc_part_2nxnd
      )
    ) ||
    hevc_is_diff_mer(pps, x_b1, y_b1, x0, y0) {
    false
  } else {
    available(cand_up, x_b1, y_b1)
  }
  if is_available_b1 &&
    !(is_available_a1 &&
    hevc_compare_mv_ref_idx(mvf(x_b1, y_b1), mvf(x_a1, y_a1))) {
    push(mvf(x_b1, y_b1))
  }
  let is_available_b0 = available(cand_up_right, x_b0, y_b0) &&
    x_b0 < sps.width &&
    hevc_z_scan_block_avail(sps, pps, x0, y0, x_b0, y_b0) &&
    !hevc_is_diff_mer(pps, x_b0, y_b0, x0, y0)
  if is_available_b0 &&
    !(is_available_b1 &&
    hevc_compare_mv_ref_idx(mvf(x_b0, y_b0), mvf(x_b1, y_b1))) {
    push(mvf(x_b0, y_b0))
  }
  let is_available_a0 = available(cand_bottom_left, x_a0, y_a0) &&
    y_a0 < sps.height &&
    hevc_z_scan_block_avail(sps, pps, x0, y0, x_a0, y_a0) &&
    !hevc_is_diff_mer(pps, x_a0, y_a0, x0, y0)
  if is_available_a0 &&
    !(is_available_a1 &&
    hevc_compare_mv_ref_idx(mvf(x_a0, y_a0), mvf(x_a1, y_a1))) {
    push(mvf(x_a0, y_a0))
  }
  let is_available_b2 = available(cand_up_left, x_b2, y_b2) &&
    !hevc_is_diff_mer(pps, x_b2, y_b2, x0, y0)
  if is_available_b2 &&
    !(is_available_a1 &&
    hevc_compare_mv_ref_idx(mvf(x_b2, y_b2), mvf(x_a1, y_a1))) &&
    !(is_available_b1 &&
    hevc_compare_mv_ref_idx(mvf(x_b2, y_b2), mvf(x_b1, y_b1))) &&
    nb_merge_cand != 4 {
    push(mvf(x_b2, y_b2))
  }
  if sh.slice_temporal_mvp_enabled_flag && nb_merge_cand < sh.max_num_merge_cand {
    let mv_l0_col = hevc_mv_new()
    let mv_l1_col = hevc_mv_new()
    let available_l0 = hevc_temporal_luma_motion_vector(
      ctx, x0, y0, n_pb_w, n_pb_h, 0, mv_l0_col, 0,
    )
    let available_l1 = if sh.slice_type == hevc_slice_b {
      hevc_temporal_luma_motion_vector(
        ctx, x0, y0, n_pb_w, n_pb_h, 0, mv_l1_col, 1,
      )
    } else {
      false
    }
    if available_l0 || available_l1 {
      mergecand_list[nb_merge_cand].pred_flag = (if available_l0 {
          1
        } else {
          0
        }) +
        (if available_l1 { 2 } else { 0 })
      mergecand_list[nb_merge_cand].ref_idx0 = 0
      mergecand_list[nb_merge_cand].ref_idx1 = 0
      mergecand_list[nb_merge_cand].mv0.x = mv_l0_col.x
      mergecand_list[nb_merge_cand].mv0.y = mv_l0_col.y
      mergecand_list[nb_merge_cand].mv1.x = mv_l1_col.x
      mergecand_list[nb_merge_cand].mv1.y = mv_l1_col.y
      nb_merge_cand = nb_merge_cand + 1
    }
  }
  nb_orig_merge_cand = nb_merge_cand
  if sh.slice_type == hevc_slice_b &&
    nb_orig_merge_cand > 1 &&
    nb_orig_merge_cand < sh.max_num_merge_cand {
    let mut comb_idx = 0
    while nb_merge_cand < sh.max_num_merge_cand &&
          comb_idx < nb_orig_merge_cand * (nb_orig_merge_cand - 1) {
      let pair = hevc_l0_l1_cand_idx[comb_idx]
      let l0_cand = mergecand_list[pair.0]
      let l1_cand = mergecand_list[pair.1]
      if (l0_cand.pred_flag & hevc_pf_l0) != 0 &&
        (l1_cand.pred_flag & hevc_pf_l1) != 0 &&
        (
          ctx.rpl[0].poc(l0_cand.ref_idx0) != ctx.rpl[1].poc(l1_cand.ref_idx1) ||
          l0_cand.mv0.x != l1_cand.mv1.x ||
          l0_cand.mv0.y != l1_cand.mv1.y
        ) {
        mergecand_list[nb_merge_cand].ref_idx0 = l0_cand.ref_idx0
        mergecand_list[nb_merge_cand].ref_idx1 = l1_cand.ref_idx1
        mergecand_list[nb_merge_cand].pred_flag = hevc_pf_bi
        mergecand_list[nb_merge_cand].mv0.x = l0_cand.mv0.x
        mergecand_list[nb_merge_cand].mv0.y = l0_cand.mv0.y
        mergecand_list[nb_merge_cand].mv1.x = l1_cand.mv1.x
        mergecand_list[nb_merge_cand].mv1.y = l1_cand.mv1.y
        nb_merge_cand = nb_merge_cand + 1
      }
      comb_idx = comb_idx + 1
    }
  }
  while nb_merge_cand < sh.max_num_merge_cand {
    mergecand_list[nb_merge_cand].pred_flag = hevc_pf_l0 +
      (if sh.slice_type == hevc_slice_b { 2 } else { 0 })
    mergecand_list[nb_merge_cand].mv0.x = 0
    mergecand_list[nb_merge_cand].mv0.y = 0
    mergecand_list[nb_merge_cand].mv1.x = 0
    mergecand_list[nb_merge_cand].mv1.y = 0
    mergecand_list[nb_merge_cand].ref_idx0 = if zero_idx < nb_refs {
      zero_idx
    } else {
      0
    }
    mergecand_list[nb_merge_cand].ref_idx1 = if zero_idx < nb_refs {
      zero_idx
    } else {
      0
    }
    nb_merge_cand = nb_merge_cand + 1
    zero_idx = zero_idx + 1
  }
}

///|
/// 8.5.3.1.1 luma MVs for merge mode. */
fn hevc_luma_mv_merge_mode(
  ctx : HevcInterCtx,
  x0_in : Int32,
  y0_in : Int32,
  n_pb_w_in : Int32,
  n_pb_h_in : Int32,
  log2_cb_size : Int32,
  part_idx_in : Int32,
  merge_idx : Int32,
  mv : HevcMvField,
) -> Unit {
  let pps = ctx.pps
  let mut single_mcl_flag = false
  let n_cs = 1 << log2_cb_size
  let mut x0 = x0_in
  let mut y0 = y0_in
  let mut n_pb_w = n_pb_w_in
  let mut n_pb_h = n_pb_h_in
  let mut part_idx = part_idx_in
  if pps.log2_parallel_merge_level > 2 && n_cs == 8 {
    single_mcl_flag = true
    x0 = ctx.cu_x
    y0 = ctx.cu_y
    n_pb_w = n_cs
    n_pb_h = n_cs
    part_idx = 0
  }
  let n_pb_w2 = n_pb_w_in
  let n_pb_h2 = n_pb_h_in
  ctx.set_neighbour_available(x0, y0, n_pb_w, n_pb_h)
  let mergecand_list : Array[HevcMvField] = []
  for _ in 0..<5 {
    mergecand_list.push(hevc_mv_field_new())
  }
  hevc_derive_spatial_merge_candidates(
    ctx, x0, y0, n_pb_w, n_pb_h, single_mcl_flag, part_idx, mergecand_list,
  )
  if mergecand_list[merge_idx].pred_flag == hevc_pf_bi &&
    n_pb_w2 + n_pb_h2 == 12 {
    mergecand_list[merge_idx].pred_flag = hevc_pf_l0
  }
  mv.copy_from(mergecand_list[merge_idx])
}

///|
/// `mv_mp_mode_mx`. */
fn HevcInterCtx::mp_mx(
  self : HevcInterCtx,
  x : Int32,
  y : Int32,
  pred_flag_index : Int32,
  mx : HevcMv,
  ref_idx_curr : Int32,
  ref_idx : Int32,
) -> Bool {
  let sps = self.sps
  let f = self.tab_mvf[(y >> sps.log2_min_pu_size) * sps.min_pu_width +
    (x >> sps.log2_min_pu_size)]
  let rpl = self.rpl[pred_flag_index]
  let idx = if pred_flag_index == 0 { f.ref_idx0 } else { f.ref_idx1 }
  if (f.pred_flag & (1 << pred_flag_index)) != 0 &&
    rpl.poc(idx) == self.rpl[ref_idx_curr].poc(ref_idx) {
    let mv = if pred_flag_index == 0 { f.mv0 } else { f.mv1 }
    mx.x = mv.x
    mx.y = mv.y
    return true
  }
  false
}

///|
/// `dist_scale`. */
fn HevcInterCtx::dist_scale(
  self : HevcInterCtx,
  mv : HevcMv,
  x : Int32,
  y : Int32,
  elist : Int32,
  ref_idx_curr : Int32,
  ref_idx : Int32,
) -> Unit {
  let sps = self.sps
  let f = self.tab_mvf[(y >> sps.log2_min_pu_size) * sps.min_pu_width +
    (x >> sps.log2_min_pu_size)]
  let eidx = if elist == 0 { f.ref_idx0 } else { f.ref_idx1 }
  let ref_pic_elist = self.rpl[elist].poc(eidx)
  let ref_pic_curr = self.rpl[ref_idx_curr].poc(ref_idx)
  if ref_pic_elist != ref_pic_curr {
    let mut poc_diff = self.poc - ref_pic_elist
    if poc_diff == 0 {
      poc_diff = 1
    }
    hevc_mv_scale(mv, mv, poc_diff, self.poc - ref_pic_curr)
  }
}

///|
/// `mv_mp_mode_mx_lt`. */
fn HevcInterCtx::mp_mx_lt(
  self : HevcInterCtx,
  x : Int32,
  y : Int32,
  pred_flag_index : Int32,
  mx : HevcMv,
  ref_idx_curr : Int32,
  ref_idx : Int32,
) -> Bool {
  let sps = self.sps
  let f = self.tab_mvf[(y >> sps.log2_min_pu_size) * sps.min_pu_width +
    (x >> sps.log2_min_pu_size)]
  if (f.pred_flag & (1 << pred_flag_index)) != 0 {
    let fidx = if pred_flag_index == 0 { f.ref_idx0 } else { f.ref_idx1 }
    let curr_is_long_term = self.rpl[ref_idx_curr].is_long_term(ref_idx)
    let col_is_long_term = self.rpl[pred_flag_index].is_long_term(fidx)
    if col_is_long_term == curr_is_long_term {
      let mv = if pred_flag_index == 0 { f.mv0 } else { f.mv1 }
      mx.x = mv.x
      mx.y = mv.y
      if !curr_is_long_term {
        self.dist_scale(mx, x, y, pred_flag_index, ref_idx_curr, ref_idx)
      }
      return true
    }
  }
  false
}

///|
/// 8.5.3.1.7 AMVP (`ff_hevc_luma_mv_mvp_mode`). `mv.ref_idx[LX]` must be set. */
fn hevc_luma_mv_mvp_mode(
  ctx : HevcInterCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  mvp_lx_flag : Int32,
  lx : Int32,
  mv : HevcMvField,
) -> Unit {
  let sps = ctx.sps
  let sh = ctx.sh
  let tab_mvf = ctx.tab_mvf
  let l2pu = sps.log2_min_pu_size
  let mut is_scaled_flag_l0 = false
  let mut available_flag_lxa0 = true
  let mut available_flag_lxb0 = true
  let mut num_mvp_cand = 0
  let mvpcand0 = hevc_mv_new()
  let mvpcand1 = hevc_mv_new()
  let mx_a = hevc_mv_new()
  let mx_b = hevc_mv_new()
  let ref_idx_curr = lx
  let ref_idx = if lx == 0 { mv.ref_idx0 } else { mv.ref_idx1 }
  let pred_flag_index_l0 = lx
  let pred_flag_index_l1 = if lx == 0 { 1 } else { 0 }
  let cand_bottom_left = ctx.na.cand_bottom_left
  let cand_left = ctx.na.cand_left
  let cand_up_left = ctx.na.cand_up_left
  let cand_up = ctx.na.cand_up
  let cand_up_right = ctx.na.cand_up_right_sap
  let available = fn(cand : Bool, x_v : Int32, y_v : Int32) -> Bool {
    cand &&
    tab_mvf[(y_v >> l2pu) * sps.min_pu_width + (x_v >> l2pu)].pred_flag !=
    hevc_pf_intra
  }
  let x_a0 = x0 - 1
  let y_a0 = y0 + n_pb_h
  let is_available_a0 = available(cand_bottom_left, x_a0, y_a0) &&
    y_a0 < sps.height &&
    hevc_z_scan_block_avail(sps, ctx.pps, x0, y0, x_a0, y_a0)
  let x_a1 = x0 - 1
  let y_a1 = y0 + n_pb_h - 1
  let is_available_a1 = available(cand_left, x_a1, y_a1)
  if is_available_a0 || is_available_a1 {
    is_scaled_flag_l0 = true
  }
  let mut goto_b = false
  if is_available_a0 {
    if ctx.mp_mx(x_a0, y_a0, pred_flag_index_l0, mx_a, ref_idx_curr, ref_idx) {
      goto_b = true
    }
    if !goto_b &&
      ctx.mp_mx(x_a0, y_a0, pred_flag_index_l1, mx_a, ref_idx_curr, ref_idx) {
      goto_b = true
    }
  }
  if !goto_b && is_available_a1 {
    if ctx.mp_mx(x_a1, y_a1, pred_flag_index_l0, mx_a, ref_idx_curr, ref_idx) {
      goto_b = true
    }
    if !goto_b &&
      ctx.mp_mx(x_a1, y_a1, pred_flag_index_l1, mx_a, ref_idx_curr, ref_idx) {
      goto_b = true
    }
  }
  if !goto_b {
    if is_available_a0 {
      if ctx.mp_mx_lt(
          x_a0, y_a0, pred_flag_index_l0, mx_a, ref_idx_curr, ref_idx,
        ) {
        goto_b = true
      }
      if !goto_b &&
        ctx.mp_mx_lt(
          x_a0, y_a0, pred_flag_index_l1, mx_a, ref_idx_curr, ref_idx,
        ) {
        goto_b = true
      }
    }
    if !goto_b && is_available_a1 {
      if ctx.mp_mx_lt(
          x_a1, y_a1, pred_flag_index_l0, mx_a, ref_idx_curr, ref_idx,
        ) {
        goto_b = true
      }
      if !goto_b &&
        ctx.mp_mx_lt(
          x_a1, y_a1, pred_flag_index_l1, mx_a, ref_idx_curr, ref_idx,
        ) {
        goto_b = true
      }
    }
    if !goto_b {
      available_flag_lxa0 = false
    }
  }
  // b_candidates:
  let x_b0 = x0 + n_pb_w
  let y_b0 = y0 - 1
  let is_available_b0 = available(cand_up_right, x_b0, y_b0) &&
    x_b0 < sps.width &&
    hevc_z_scan_block_avail(sps, ctx.pps, x0, y0, x_b0, y_b0)
  let x_b1 = x0 + n_pb_w - 1
  let y_b1 = y0 - 1
  let is_available_b1 = available(cand_up, x_b1, y_b1)
  let x_b2 = x0 - 1
  let y_b2 = y0 - 1
  let is_available_b2 = available(cand_up_left, x_b2, y_b2)
  let mut goto_scalef = false
  if is_available_b0 {
    if ctx.mp_mx(x_b0, y_b0, pred_flag_index_l0, mx_b, ref_idx_curr, ref_idx) {
      goto_scalef = true
    }
    if !goto_scalef &&
      ctx.mp_mx(x_b0, y_b0, pred_flag_index_l1, mx_b, ref_idx_curr, ref_idx) {
      goto_scalef = true
    }
  }
  if !goto_scalef && is_available_b1 {
    if ctx.mp_mx(x_b1, y_b1, pred_flag_index_l0, mx_b, ref_idx_curr, ref_idx) {
      goto_scalef = true
    }
    if !goto_scalef &&
      ctx.mp_mx(x_b1, y_b1, pred_flag_index_l1, mx_b, ref_idx_curr, ref_idx) {
      goto_scalef = true
    }
  }
  if !goto_scalef && is_available_b2 {
    if ctx.mp_mx(x_b2, y_b2, pred_flag_index_l0, mx_b, ref_idx_curr, ref_idx) {
      goto_scalef = true
    }
    if !goto_scalef &&
      ctx.mp_mx(x_b2, y_b2, pred_flag_index_l1, mx_b, ref_idx_curr, ref_idx) {
      goto_scalef = true
    }
  }
  if !goto_scalef {
    available_flag_lxb0 = false
  }
  // scalef:
  if !is_scaled_flag_l0 {
    if available_flag_lxb0 {
      available_flag_lxa0 = true
      mx_a.x = mx_b.x
      mx_a.y = mx_b.y
    }
    available_flag_lxb0 = false
    if is_available_b0 {
      available_flag_lxb0 = ctx.mp_mx_lt(
        x_b0, y_b0, pred_flag_index_l0, mx_b, ref_idx_curr, ref_idx,
      )
      if !available_flag_lxb0 {
        available_flag_lxb0 = ctx.mp_mx_lt(
          x_b0, y_b0, pred_flag_index_l1, mx_b, ref_idx_curr, ref_idx,
        )
      }
    }
    if is_available_b1 && !available_flag_lxb0 {
      available_flag_lxb0 = ctx.mp_mx_lt(
        x_b1, y_b1, pred_flag_index_l0, mx_b, ref_idx_curr, ref_idx,
      )
      if !available_flag_lxb0 {
        available_flag_lxb0 = ctx.mp_mx_lt(
          x_b1, y_b1, pred_flag_index_l1, mx_b, ref_idx_curr, ref_idx,
        )
      }
    }
    if is_available_b2 && !available_flag_lxb0 {
      available_flag_lxb0 = ctx.mp_mx_lt(
        x_b2, y_b2, pred_flag_index_l0, mx_b, ref_idx_curr, ref_idx,
      )
      if !available_flag_lxb0 {
        available_flag_lxb0 = ctx.mp_mx_lt(
          x_b2, y_b2, pred_flag_index_l1, mx_b, ref_idx_curr, ref_idx,
        )
      }
    }
  }
  if available_flag_lxa0 {
    mvpcand0.x = mx_a.x
    mvpcand0.y = mx_a.y
    num_mvp_cand = num_mvp_cand + 1
  }
  if available_flag_lxb0 &&
    (!available_flag_lxa0 || mx_a.x != mx_b.x || mx_a.y != mx_b.y) {
    let slot = if num_mvp_cand == 0 { mvpcand0 } else { mvpcand1 }
    slot.x = mx_b.x
    slot.y = mx_b.y
    num_mvp_cand = num_mvp_cand + 1
  }
  if num_mvp_cand < 2 &&
    sh.slice_temporal_mvp_enabled_flag &&
    mvp_lx_flag == num_mvp_cand {
    let mv_col = hevc_mv_new()
    let available_col = hevc_temporal_luma_motion_vector(
      ctx, x0, y0, n_pb_w, n_pb_h, ref_idx, mv_col, lx,
    )
    if available_col {
      let slot = if num_mvp_cand == 0 { mvpcand0 } else { mvpcand1 }
      slot.x = mv_col.x
      slot.y = mv_col.y
      num_mvp_cand = num_mvp_cand + 1
    }
  }
  let chosen = if mvp_lx_flag == 0 { mvpcand0 } else { mvpcand1 }
  if lx == 0 {
    mv.mv0.x = chosen.x
    mv.mv0.y = chosen.y
  } else {
    mv.mv1.x = chosen.x
    mv.mv1.y = chosen.y
  }
}

///|
/// `hls_prediction_unit` up to the motion field; the caller performs the MC
/// with `current_mv`. */
fn hevc_hls_prediction_unit(
  ctx : HevcInterCtx,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  log2_cb_size : Int32,
  part_idx : Int32,
  skip_flag : Bool,
  current_mv : HevcMvField,
) -> Unit {
  let sh = ctx.sh
  let mut merge_idx = 0
  let mut merge_flag = false
  if !skip_flag {
    merge_flag = ctx.cabac.merge_flag() != 0
  }
  ctx.last_merge_flag = merge_flag
  if skip_flag || merge_flag {
    if sh.max_num_merge_cand > 1 {
      merge_idx = ctx.cabac.merge_idx(sh.max_num_merge_cand)
    }
    hevc_luma_mv_merge_mode(
      ctx, x0, y0, n_pb_w, n_pb_h, log2_cb_size, part_idx, merge_idx, current_mv,
    )
  } else {
    ctx.set_neighbour_available(x0, y0, n_pb_w, n_pb_h)
    current_mv.pred_flag = 0
    let mut inter_pred_idc = 0
    if sh.slice_type == hevc_slice_b {
      inter_pred_idc = ctx.cabac.inter_pred_idc(ctx.ct_depth, n_pb_w, n_pb_h)
    }
    if inter_pred_idc != 1 {
      if sh.num_ref_idx_l0_active > 1 {
        current_mv.ref_idx0 = ctx.cabac.ref_idx_lx(sh.num_ref_idx_l0_active)
      }
      current_mv.pred_flag = hevc_pf_l0
      let (dx, dy) = ctx.cabac.mvd_coding()
      let mvp_flag = ctx.cabac.mvp_lx_flag()
      hevc_luma_mv_mvp_mode(
        ctx, x0, y0, n_pb_w, n_pb_h, mvp_flag, 0, current_mv,
      )
      current_mv.mv0.x = current_mv.mv0.x + dx
      current_mv.mv0.y = current_mv.mv0.y + dy
    }
    if inter_pred_idc != 0 {
      if sh.num_ref_idx_l1_active > 1 {
        current_mv.ref_idx1 = ctx.cabac.ref_idx_lx(sh.num_ref_idx_l1_active)
      }
      let (dx, dy) = if sh.mvd_l1_zero_flag && inter_pred_idc == 2 {
        (0, 0)
      } else {
        ctx.cabac.mvd_coding()
      }
      current_mv.pred_flag = current_mv.pred_flag + hevc_pf_l1
      let mvp_flag = ctx.cabac.mvp_lx_flag()
      hevc_luma_mv_mvp_mode(
        ctx, x0, y0, n_pb_w, n_pb_h, mvp_flag, 1, current_mv,
      )
      current_mv.mv1.x = current_mv.mv1.x + dx
      current_mv.mv1.y = current_mv.mv1.y + dy
    }
  }
}
