///|
/// HEVC CABAC syntax-element decoding from FFmpeg 9.0.2
/// `libavcodec/hevc/cabac.c`. Context offsets follow the `CABAC_ELEMS`
/// enumeration order; residual coding lives in `hevc_residual.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Out of scope: SAO merge/type syntax, inter motion syntax, tiles/WPP.

///|
/// HEVC CABAC context offsets (`CABAC_ELEMS`). */
pub let hevc_cabac_sao_merge_flag : Int32 = 0

///|
pub let hevc_cabac_sao_type_idx : Int32 = 1

///|
pub let hevc_cabac_split_coding_unit_flag : Int32 = 2

///|
pub let hevc_cabac_cu_transquant_bypass_flag : Int32 = 5

///|
pub let hevc_cabac_skip_flag : Int32 = 6

///|
pub let hevc_cabac_cu_qp_delta : Int32 = 9

///|
pub let hevc_cabac_pred_mode_flag : Int32 = 12

///|
pub let hevc_cabac_part_mode : Int32 = 13

///|
pub let hevc_cabac_prev_intra_luma_pred_flag : Int32 = 17

///|
pub let hevc_cabac_intra_chroma_pred_mode : Int32 = 18

///|
pub let hevc_cabac_no_residual_data_flag : Int32 = 36

///|
pub let hevc_cabac_merge_flag : Int32 = 20

///|
pub let hevc_cabac_merge_idx : Int32 = 21

///|
pub let hevc_cabac_inter_pred_idc : Int32 = 22

///|
pub let hevc_cabac_ref_idx_l0 : Int32 = 27

///|
pub let hevc_cabac_ref_idx_l1 : Int32 = 29

///|
pub let hevc_cabac_abs_mvd_greater0_flag : Int32 = 31

///|
pub let hevc_cabac_abs_mvd_greater1_flag : Int32 = 33

///|
pub let hevc_cabac_mvp_lx_flag : Int32 = 35

///|
pub let hevc_cabac_split_transform_flag : Int32 = 37

///|
pub let hevc_cabac_cbf_luma : Int32 = 40

///|
pub let hevc_cabac_cbf_cb_cr : Int32 = 42

///|
pub let hevc_cabac_transform_skip_flag : Int32 = 47

///|
pub let hevc_cabac_last_sig_x_prefix : Int32 = 53

///|
pub let hevc_cabac_last_sig_y_prefix : Int32 = 71

///|
pub let hevc_cabac_sig_coeff_group_flag : Int32 = 89

///|
pub let hevc_cabac_sig_coeff_flag : Int32 = 93

///|
pub let hevc_cabac_coeff_abs_greater1 : Int32 = 137

///|
pub let hevc_cabac_coeff_abs_greater2 : Int32 = 161

///|
/// `CABAC_MAX_BIN`. */
pub let hevc_cabac_max_bin : Int32 = 31

///|
/// Arithmetic decoder plus the per-slice context states.
pub struct HevcCabac {
  cc : CabacContext
  states : Array[Int32]
  /// C `lc->stat_coeff[4]`: persistent Rice adaptation per sb_type
  /// (luma/chroma x transform-skip-or-bypass). Zeroed for independent
  /// slices and tile starts; inherited across dependent/WPP boundaries.
  stat_coeff : Array[Int32]
}

///|
pub fn hevc_cabac_new(
  data : Bytes,
  offset : Int32,
  states : Array[Int32],
  stat_coeff~ : Array[Int32] = Array::make(4, 0),
) -> Result[HevcCabac, String] {
  match ff_init_cabac_decoder(data, offset) {
    Ok(cc) => Ok({ cc, states, stat_coeff, })
    Err(e) => Err(e)
  }
}

///|
fn HevcCabac::bin(self : HevcCabac, ctx : Int32) -> Int32 {
  self.cc.get_cabac(self.states, ctx)
}

///|
fn HevcCabac::bypass(self : HevcCabac) -> Int32 {
  self.cc.get_cabac_bypass()
}

///|
fn HevcCabac::terminate(self : HevcCabac) -> Bool {
  let r = self.cc.get_cabac_terminate() != 0
  r
}

///|
/// `ff_hevc_split_coding_unit_flag_decode`. */
fn HevcCabac::split_coding_unit_flag(
  self : HevcCabac,
  ctb_left : Bool,
  ctb_up : Bool,
  tab_ct_depth : Array[Int32],
  sps : HevcSps,
  ct_depth : Int32,
  x0 : Int32,
  y0 : Int32,
) -> Int32 {
  let ctb_size = 1 << sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  let x_cb = x0 >> sps.log2_min_cb_size
  let y_cb = y0 >> sps.log2_min_cb_size
  let mut depth_left = 0
  let mut depth_top = 0
  if ctb_left || x0b != 0 {
    depth_left = tab_ct_depth[y_cb * sps.min_cb_width + x_cb - 1]
  }
  if ctb_up || y0b != 0 {
    depth_top = tab_ct_depth[(y_cb - 1) * sps.min_cb_width + x_cb]
  }
  let inc = (if depth_left > ct_depth { 1 } else { 0 }) +
    (if depth_top > ct_depth { 1 } else { 0 })
  let r = self.bin(hevc_cabac_split_coding_unit_flag + inc)
  r
}

///|
/// `ff_hevc_part_mode_decode` for any pred mode. `pred_mode` is 1 for intra. */
fn HevcCabac::part_mode_decode(
  self : HevcCabac,
  log2_cb_size : Int32,
  min_cb : Int32,
  amp_enabled : Bool,
  pred_mode_intra : Bool,
) -> Int32 {
  let r = if self.bin(hevc_cabac_part_mode) != 0 {
    0
  } else if log2_cb_size == min_cb {
    if pred_mode_intra {
      3
    } else if self.bin(hevc_cabac_part_mode + 1) != 0 {
      1
    } else if log2_cb_size == 3 {
      2
    } else if self.bin(hevc_cabac_part_mode + 2) != 0 {
      2
    } else {
      3
    }
  } else if !amp_enabled {
    if self.bin(hevc_cabac_part_mode + 1) != 0 {
      1
    } else {
      2
    }
  } else if self.bin(hevc_cabac_part_mode + 1) != 0 {
    if self.bin(hevc_cabac_part_mode + 3) != 0 {
      1
    } else if self.bypass() != 0 {
      hevc_part_2nxnd
    } else {
      hevc_part_2nxnu
    }
  } else if self.bin(hevc_cabac_part_mode + 3) != 0 {
    2
  } else if self.bypass() != 0 {
    hevc_part_nrx2n
  } else {
    hevc_part_nlx2n
  }
  r
}

///|
/// `ff_hevc_skip_flag_decode`. */
fn HevcCabac::skip_flag(
  self : HevcCabac,
  skip_flag : Array[Int32],
  x0b : Int32,
  y0b : Int32,
  x_cb : Int32,
  y_cb : Int32,
  min_cb_width : Int32,
  ctb_left : Bool,
  ctb_up : Bool,
) -> Int32 {
  let mut inc = 0
  if ctb_left || x0b != 0 {
    if skip_flag[y_cb * min_cb_width + x_cb - 1] != 0 {
      inc = inc + 1
    }
  }
  if ctb_up || y0b != 0 {
    if skip_flag[(y_cb - 1) * min_cb_width + x_cb] != 0 {
      inc = inc + 1
    }
  }
  let r = self.bin(hevc_cabac_skip_flag + inc)
  r
}

///|
/// `ff_hevc_pred_mode_decode`: 0 = MODE_INTER, 1 = MODE_INTRA. */
fn HevcCabac::pred_mode_flag(self : HevcCabac) -> Int32 {
  let r = self.bin(hevc_cabac_pred_mode_flag)
  r
}

///|
/// `ff_hevc_merge_flag_decode`. */
fn HevcCabac::merge_flag(self : HevcCabac) -> Int32 {
  self.bin(hevc_cabac_merge_flag)
}

///|
/// `ff_hevc_merge_idx_decode`. */
fn HevcCabac::merge_idx(self : HevcCabac, max_num_merge_cand : Int32) -> Int32 {
  let mut i = self.bin(hevc_cabac_merge_idx)
  if i != 0 {
    while i < max_num_merge_cand - 1 && self.bypass() != 0 {
      i = i + 1
    }
  }
  i
}

///|
/// `ff_hevc_inter_pred_idc_decode`: returns 0 = PRED_L0, 1 = PRED_L1,
/// 2 = PRED_BI (C `enum InterPredIdc`). */
fn HevcCabac::inter_pred_idc(
  self : HevcCabac,
  ct_depth : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
) -> Int32 {
  if n_pb_w + n_pb_h == 12 {
    return self.bin(hevc_cabac_inter_pred_idc + 4)
  }
  if self.bin(hevc_cabac_inter_pred_idc + ct_depth) != 0 {
    return 2
  }
  self.bin(hevc_cabac_inter_pred_idc + 4)
}

///|
/// `ff_hevc_ref_idx_lx_decode`. */
fn HevcCabac::ref_idx_lx(self : HevcCabac, num_ref_idx_lx : Int32) -> Int32 {
  let max = num_ref_idx_lx - 1
  let max_ctx = if max < 2 { max } else { 2 }
  // Both reference lists share REF_IDX_L0 contexts (FFmpeg cabac.c).
  let base = hevc_cabac_ref_idx_l0
  let mut i = 0
  while i < max_ctx && self.bin(base + i) != 0 {
    i = i + 1
  }
  if i == 2 {
    while i < max && self.bypass() != 0 {
      i = i + 1
    }
  }
  i
}

///|
/// `ff_hevc_mvp_lx_flag_decode`. */
fn HevcCabac::mvp_lx_flag(self : HevcCabac) -> Int32 {
  self.bin(hevc_cabac_mvp_lx_flag)
}

///|
/// `ff_hevc_no_residual_syntax_flag_decode` (`rqt_root_cbf`). */
fn HevcCabac::no_residual_flag(self : HevcCabac) -> Int32 {
  self.bin(hevc_cabac_no_residual_data_flag)
}

///|
/// `ff_hevc_hls_mvd_coding`: returns `(mvd_x, mvd_y)`. */
fn HevcCabac::mvd_coding(self : HevcCabac) -> (Int32, Int32) {
  let mut x = self.bin(hevc_cabac_abs_mvd_greater0_flag)
  let mut y = self.bin(hevc_cabac_abs_mvd_greater0_flag)
  if x != 0 {
    x = x + self.bin(hevc_cabac_abs_mvd_greater1_flag + 1)
  }
  if y != 0 {
    y = y + self.bin(hevc_cabac_abs_mvd_greater1_flag + 1)
  }
  let mvx = if x == 2 {
    self.mvd_decode()
  } else if x == 1 {
    self.cc.get_cabac_bypass_sign(-1)
  } else {
    0
  }
  let mvy = if y == 2 {
    self.mvd_decode()
  } else if y == 1 {
    self.cc.get_cabac_bypass_sign(-1)
  } else {
    0
  }
  (mvx, mvy)
}

///|
/// `mvd_decode`: EG1-style bypass magnitude with bypass sign. */
fn HevcCabac::mvd_decode(self : HevcCabac) -> Int32 {
  let mut ret = 2
  let mut k = 1
  while k < 31 && self.bypass() != 0 {
    ret = ret + (1 << k)
    k = k + 1
  }
  if k == 31 {
    return 0
  }
  while k > 0 {
    k = k - 1
    ret = ret + (self.bypass() << k)
  }
  self.cc.get_cabac_bypass_sign(-ret)
}

///|
/// `ff_hevc_prev_intra_luma_pred_flag_decode`. */
fn HevcCabac::prev_intra_luma_pred_flag(self : HevcCabac) -> Int32 {
  let r = self.bin(hevc_cabac_prev_intra_luma_pred_flag)
  r
}

///|
/// `ff_hevc_mpm_idx_decode`. */
fn HevcCabac::mpm_idx(self : HevcCabac) -> Int32 {
  let mut i = 0
  while i < 2 && self.bypass() != 0 {
    i = i + 1
  }
  i
}

///|
/// `ff_hevc_rem_intra_luma_pred_mode_decode`. */
fn HevcCabac::rem_intra_luma_pred_mode(self : HevcCabac) -> Int32 {
  let mut value = self.bypass()
  for _ in 0..<4 {
    value = (value << 1) | self.bypass()
  }
  value
}

///|
/// `ff_hevc_intra_chroma_pred_mode_decode`. */
fn HevcCabac::intra_chroma_pred_mode(self : HevcCabac) -> Int32 {
  let r = if self.bin(hevc_cabac_intra_chroma_pred_mode) == 0 {
    4
  } else {
    (self.bypass() << 1) | self.bypass()
  }
  r
}

///|
/// `ff_hevc_split_transform_flag_decode`. */
fn HevcCabac::split_transform_flag(
  self : HevcCabac,
  log2_trafo_size : Int32,
) -> Int32 {
  let r = self.bin(hevc_cabac_split_transform_flag + 5 - log2_trafo_size)
  r
}

///|
/// `ff_hevc_cbf_cb_cr_decode`. */
fn HevcCabac::cbf_cb_cr(self : HevcCabac, trafo_depth : Int32) -> Int32 {
  let r = self.bin(hevc_cabac_cbf_cb_cr + trafo_depth)
  r
}

///|
/// `ff_hevc_cbf_luma_decode`. */
fn HevcCabac::cbf_luma(self : HevcCabac, trafo_depth : Int32) -> Int32 {
  let r = self.bin(hevc_cabac_cbf_luma + (if trafo_depth == 0 { 1 } else { 0 }))
  r
}

///|
/// `ff_hevc_sao_merge_flag_decode`. */
fn HevcCabac::sao_merge_flag(self : HevcCabac) -> Bool {
  let r = self.bin(hevc_cabac_sao_merge_flag) != 0
  r
}

///|
/// `ff_hevc_sao_type_idx_decode`: 0 = off, 1 = band, 2 = edge. */
fn HevcCabac::sao_type_idx(self : HevcCabac) -> Int32 {
  let r = if self.bin(hevc_cabac_sao_type_idx) == 0 {
    0
  } else if self.bypass() == 0 {
    1
  } else {
    2
  }
  r
}

///|
/// `ff_hevc_sao_offset_abs_decode`. */
fn HevcCabac::sao_offset_abs(self : HevcCabac, bit_depth : Int32) -> Int32 {
  let length = (1 << ((if bit_depth < 10 { bit_depth } else { 10 }) - 5)) - 1
  let mut i = 0
  while i < length && self.bypass() != 0 {
    i = i + 1
  }
  i
}

///|
/// `ff_hevc_sao_offset_sign_decode`. */
fn HevcCabac::sao_offset_sign(self : HevcCabac) -> Int32 {
  self.bypass()
}

///|
/// `ff_hevc_sao_band_position_decode`. */
fn HevcCabac::sao_band_position(self : HevcCabac) -> Int32 {
  let mut value = self.bypass()
  for _ in 0..<4 {
    value = (value << 1) | self.bypass()
  }
  value
}

///|
/// `hevc_transform_skip_flag_decode`: one context for luma, one for chroma. */
fn HevcCabac::transform_skip_flag(self : HevcCabac, c_idx : Int32) -> Bool {
  self.bin(hevc_cabac_transform_skip_flag + (if c_idx > 0 { 1 } else { 0 })) !=
  0
}

///|
/// `ff_hevc_sao_eo_class_decode`. */
fn HevcCabac::sao_eo_class(self : HevcCabac) -> Int32 {
  (self.bypass() << 1) | self.bypass()
}

///|
/// `ff_hevc_cu_qp_delta_abs`. */
fn HevcCabac::cu_qp_delta_abs(self : HevcCabac) -> Result[Int32, String] {
  let mut prefix = 0
  let mut inc = 0
  while prefix < 5 && self.bin(hevc_cabac_cu_qp_delta + inc) != 0 {
    prefix = prefix + 1
    inc = 1
  }
  let mut suffix = 0
  if prefix >= 5 {
    let mut k = 0
    while k < 7 && self.bypass() != 0 {
      suffix = suffix + (1 << k)
      k = k + 1
    }
    if k == 7 {
      return Err("hevc: CABAC_MAX_BIN in cu_qp_delta")
    }
    while k > 0 {
      k = k - 1
      suffix = suffix + (self.bypass() << k)
    }
  }
  let r = Ok(prefix + suffix)
  r
}

///|
/// `ff_hevc_cu_qp_delta_sign_flag`. */
fn HevcCabac::cu_qp_delta_sign_flag(self : HevcCabac) -> Int32 {
  self.bypass()
}

///|
/// `last_significant_coeff_xy_prefix_decode`: returns `(x, y)` prefixes. */
fn HevcCabac::last_sig_xy_prefix(
  self : HevcCabac,
  c_idx : Int32,
  log2_size : Int32,
) -> (Int32, Int32) {
  let max = (log2_size << 1) - 1
  let ctx_offset = if c_idx == 0 {
    3 * (log2_size - 2) + ((log2_size - 1) >> 2)
  } else {
    15
  }
  let ctx_shift = if c_idx == 0 { (log2_size + 1) >> 2 } else { log2_size - 2 }
  let mut x = 0
  while x < max &&
        self.bin(hevc_cabac_last_sig_x_prefix + (x >> ctx_shift) + ctx_offset) !=
        0 {
    x = x + 1
  }
  let mut y = 0
  while y < max &&
        self.bin(hevc_cabac_last_sig_y_prefix + (y >> ctx_shift) + ctx_offset) !=
        0 {
    y = y + 1
  }
  (x, y)
}

///|
/// `last_significant_coeff_suffix_decode`. */
fn HevcCabac::last_sig_suffix(self : HevcCabac, prefix : Int32) -> Int32 {
  let length = (prefix >> 1) - 1
  let mut value = self.bypass()
  for _ in 1..<length {
    value = (value << 1) | self.bypass()
  }
  value
}

///|
/// `significant_coeff_group_flag_decode`. */
fn HevcCabac::sig_coeff_group_flag(
  self : HevcCabac,
  c_idx : Int32,
  ctx_cg : Int32,
) -> Int32 {
  let inc = (if ctx_cg < 1 { ctx_cg } else { 1 }) +
    (if c_idx > 0 { 2 } else { 0 })
  self.bin(hevc_cabac_sig_coeff_group_flag + inc)
}

///|
/// `significant_coeff_flag_decode`. */
fn HevcCabac::sig_coeff_flag(
  self : HevcCabac,
  x_c : Int32,
  y_c : Int32,
  offset : Int32,
  ctx_idx_map : Array[Int32],
  map_base : Int32,
) -> Int32 {
  self.bin(
    hevc_cabac_sig_coeff_flag +
    ctx_idx_map[map_base + (y_c << 2) + x_c] +
    offset,
  )
}

///|
/// `significant_coeff_flag_decode_0`. */
fn HevcCabac::sig_coeff_flag_0(self : HevcCabac, offset : Int32) -> Int32 {
  self.bin(hevc_cabac_sig_coeff_flag + offset)
}

///|
/// `coeff_abs_level_greater1_flag_decode`. */
fn HevcCabac::coeff_abs_greater1(
  self : HevcCabac,
  c_idx : Int32,
  inc : Int32,
) -> Int32 {
  self.bin(
    hevc_cabac_coeff_abs_greater1 + inc + (if c_idx > 0 { 16 } else { 0 }),
  )
}

///|
/// `coeff_abs_level_greater2_flag_decode`. */
fn HevcCabac::coeff_abs_greater2(
  self : HevcCabac,
  c_idx : Int32,
  inc : Int32,
) -> Int32 {
  self.bin(
    hevc_cabac_coeff_abs_greater2 + inc + (if c_idx > 0 { 4 } else { 0 }),
  )
}

///|
/// `coeff_abs_level_remaining_decode`. */
fn HevcCabac::coeff_abs_remaining(
  self : HevcCabac,
  rice_param : Int32,
) -> Result[Int32, String] {
  let mut prefix = 0
  while prefix < hevc_cabac_max_bin && self.bypass() != 0 {
    prefix = prefix + 1
  }
  let mut suffix = 0
  if prefix < 3 {
    for _ in 0..<rice_param {
      suffix = (suffix << 1) | self.bypass()
    }
    Ok((prefix << rice_param) + suffix)
  } else {
    let prefix_minus3 = prefix - 3
    if prefix == hevc_cabac_max_bin || prefix_minus3 + rice_param > 16 + 6 {
      return Err("hevc: CABAC_MAX_BIN in coeff_abs_level_remaining")
    }
    for _ in 0..<(prefix_minus3 + rice_param) {
      suffix = (suffix << 1) | self.bypass()
    }
    Ok((((1 << prefix_minus3) + 3 - 1) << rice_param) + suffix)
  }
}

///|
/// `coeff_sign_flag_decode` for `n` bits. */
fn HevcCabac::coeff_sign_flags(self : HevcCabac, n : Int32) -> Int32 {
  let mut ret = 0
  for _ in 0..<n {
    ret = (ret << 1) | self.bypass()
  }
  ret
}
