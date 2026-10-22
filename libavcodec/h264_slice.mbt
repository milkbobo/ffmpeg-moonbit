///|
/// H.264 slice header parsing (FFmpeg 9.0.2 `h264_slice.c`,
/// `ff_h264_decode_slice_header`): I/P/B/SP/SI header syntax. Pixel decoding
/// remains a separate layer and currently supports progressive I/P.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Supported: first_mb_in_slice, slice_type, PPS/SPS lookup, frame_num,
/// field flags, POC 0/1/2, reference marking, L0/L1 list modification and
/// explicit weights, B direct flag, SP/SI QS and deblocking controls.

///|
/// Explicit prediction weights for L0/L1; implicit B weights are derived later.
pub struct H264PredWeight {
  mut luma_log2_weight_denom : Int32
  mut chroma_log2_weight_denom : Int32
  mut use_weight : Int32
  mut use_weight_chroma : Int32
  luma_weight_l0 : Array[Int32]
  luma_offset_l0 : Array[Int32]
  /// `[ref][component]` (0 = Cb, 1 = Cr).
  chroma_weight_l0 : Array[Array[Int32]]
  chroma_offset_l0 : Array[Array[Int32]]
  luma_weight_l1 : Array[Int32]
  luma_offset_l1 : Array[Int32]
  chroma_weight_l1 : Array[Array[Int32]]
  chroma_offset_l1 : Array[Array[Int32]]
}

///|
/// Neutral weight table (`weighted_pred_flag == 0`). */
pub fn new_h264_pred_weight() -> H264PredWeight {
  let lw : Array[Int32] = Array::make(16, 1)
  let lo : Array[Int32] = Array::make(16, 0)
  let cw : Array[Array[Int32]] = []
  let co : Array[Array[Int32]] = []
  for i = 0; i < 16; i = i + 1 {
    cw.push([1, 1])
    co.push([0, 0])
  }
  {
    luma_log2_weight_denom: 0,
    chroma_log2_weight_denom: 0,
    use_weight: 0,
    use_weight_chroma: 0,
    luma_weight_l0: lw,
    luma_offset_l0: lo,
    chroma_weight_l0: cw,
    chroma_offset_l0: co,
    luma_weight_l1: Array::make(16, 1),
    luma_offset_l1: Array::make(16, 0),
    chroma_weight_l1: [for _ in 0..<16 => [1, 1]],
    chroma_offset_l1: [for _ in 0..<16 => [0, 0]],
  }
}

///|
/// Decoded fields of an H.264 slice header. */
pub struct H264SliceHeader {
  first_mb_in_slice : Int32
  /// Raw `slice_type` (I = 2 or 7, SI = 4 or 9).
  slice_type : Int32
  /// `slice_type % 5` (0 P, 1 B, 2 I, 3 SP, 4 SI).
  slice_type_nos : Int32
  pps_id : Int32
  sps_id : Int32
  frame_num : Int32
  field_pic_flag : Int32
  bottom_field_flag : Int32
  idr_pic_id : Int32
  /// `pic_order_cnt_lsb` (POC type 0 only; -1 otherwise).
  pic_order_cnt_lsb : Int32
  delta_pic_order_cnt_bottom : Int32
  delta_pic_order_cnt : Array[Int32]
  no_output_of_prior_pics : Bool
  long_term_reference : Bool
  adaptive_ref_marking : Bool
  /// MMCO opcode, short difference-minus-one/long pic number, long index/max+1.
  mmco : Array[(Int32, Int32, Int32)]
  slice_qp_delta : Int32
  /// Slice QP (`pps->init_qp + slice_qp_delta`).
  qscale : Int32
  disable_deblocking_filter_idc : Int32
  slice_alpha_c0_offset : Int32
  slice_beta_offset : Int32
  /// `num_ref_idx_l0_active` (P slices; 1 for I slices).
  num_ref_idx_l0_active : Int32
  num_ref_idx_l1_active : Int32
  direct_spatial_mv_pred : Bool
  sp_for_switch : Bool
  slice_qs_delta : Int32
  /// `cabac_init_idc` (0 when absent or CAVLC).
  cabac_init_flag : Int32
  /// `pred_weight_table` (all-default when `weighted_pred_flag == 0`).
  pwt : H264PredWeight
  /// `ref_pic_list_modification` for L0 (`modification_of_pic_nums_idc`
  /// 0/1/2 with their operand; the idc == 3 terminator is not stored).
  ref_mod_l0_ops : Array[Int32]
  ref_mod_l0_vals : Array[Int32]
  ref_mod_l1_ops : Array[Int32]
  ref_mod_l1_vals : Array[Int32]
}

///|
/// `ff_h264_decode_slice_header`. `nal_type`/`nal_ref_idc`
/// come from the NAL header; `gb` must be positioned after that header.
pub fn ff_h264_decode_slice_header(
  gb : BitReader,
  nal_type : Int32,
  nal_ref_idc : Int32,
  ps : H264ParamSets,
) -> Result[H264SliceHeader, String] {
  let first_mb = gb.read_ue()
  if first_mb < 0 {
    return Err("EINVAL")
  }
  let slice_type = gb.read_ue()
  if slice_type < 0 || slice_type > 9 {
    return Err("EINVAL")
  }
  let slice_type_nos = slice_type % 5
  let is_b = slice_type_nos == 1
  let is_p = slice_type_nos == 0 || slice_type_nos == 3
  let pps_id = gb.read_ue()
  if pps_id < 0 || pps_id >= max_pps_count {
    return Err("EINVAL")
  }
  let pps = match ps.pps_list[pps_id] {
    Some(p) => p
    None => return Err("EINVAL")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("EINVAL")
  }
  if first_mb >= sps.mb_width * sps.mb_height {
    return Err("EINVAL")
  }
  let frame_num = gb.read(sps.log2_max_frame_num).reinterpret_as_int()
  let mut field_pic_flag = 0
  let mut bottom_field_flag = 0
  if sps.frame_mbs_only_flag == 0 {
    field_pic_flag = gb.read1().reinterpret_as_int()
    if field_pic_flag != 0 {
      bottom_field_flag = gb.read1().reinterpret_as_int()
    }
  }
  let is_idr = nal_type == 5
  let mut idr_pic_id = -1
  if is_idr {
    idr_pic_id = gb.read_ue()
    if idr_pic_id < 0 {
      return Err("EINVAL")
    }
  }
  let mut pic_order_cnt_lsb = -1
  let mut delta_pic_order_cnt_bottom = 0
  let delta_pic_order_cnt = [0, 0]
  if sps.poc_type == 0 {
    pic_order_cnt_lsb = gb.read(sps.log2_max_poc_lsb).reinterpret_as_int()
    if pps.pic_order_present != 0 && field_pic_flag == 0 {
      delta_pic_order_cnt_bottom = gb.read_se()
    }
  } else if sps.poc_type == 1 && sps.delta_pic_order_always_zero_flag == 0 {
    delta_pic_order_cnt[0] = gb.read_se()
    if pps.pic_order_present != 0 && field_pic_flag == 0 {
      delta_pic_order_cnt[1] = gb.read_se()
    }
  }
  if pps.redundant_pic_cnt_present != 0 {
    let _ = gb.read_ue() // redundant_pic_cnt
  }
  // Reference counts, direct flag and both reference-list modifications.
  let ref_mod_l0_ops : Array[Int32] = []
  let ref_mod_l0_vals : Array[Int32] = []
  let ref_mod_l1_ops : Array[Int32] = []
  let ref_mod_l1_vals : Array[Int32] = []
  let direct_spatial_mv_pred = is_b && gb.read1() != 0U
  let mut num_ref_idx_l0_active = 1
  let mut num_ref_idx_l1_active = 1
  if is_p || is_b {
    num_ref_idx_l0_active = pps.ref_count_l0
    num_ref_idx_l1_active = pps.ref_count_l1
    let ovr = gb.read1().reinterpret_as_int()
    if ovr != 0 {
      let n = gb.read_ue()
      if n < 0 {
        return Err("EINVAL")
      }
      num_ref_idx_l0_active = n + 1
      if is_b {
        let n = gb.read_ue()
        if n < 0 || n >= 16 { return Err("EINVAL") }
        num_ref_idx_l1_active = n + 1
      }
    }
    if num_ref_idx_l0_active > 16 || (is_b && num_ref_idx_l1_active > 16) {
      return Err("EINVAL")
    }
    for list in 0..<(if is_b { 2 } else { 1 }) {
      let ops = if list == 0 { ref_mod_l0_ops } else { ref_mod_l1_ops }
      let vals = if list == 0 { ref_mod_l0_vals } else { ref_mod_l1_vals }
      let mod_flag = gb.read1().reinterpret_as_int()
      if mod_flag != 0 {
      while true {
        let idc = gb.read_ue()
        if idc < 0 {
          return Err("EINVAL")
        }
        if idc == 3 {
          break
        }
        if idc > 2 || ops.length() >= 32 {
          return Err("EINVAL")
        }
        let val = gb.read_ue()
        if val < 0 {
          return Err("EINVAL")
        }
        ops.push(idc)
        vals.push(val)
      }
      }
    }
  }
  let pwt = new_h264_pred_weight()
  if (is_p && pps.weighted_pred != 0) || (is_b && pps.weighted_bipred_idc == 1) {
    // `ff_h264_pred_weight_table`, both coded reference lists.
    let luma_denom = gb.read_ue()
    pwt.luma_log2_weight_denom = if luma_denom < 0 || luma_denom > 7 {
      0
    } else {
      luma_denom
    }
    let luma_def = 1 << pwt.luma_log2_weight_denom
    let mut chroma_def = 1
    if sps.chroma_format_idc != 0 {
      let chroma_denom = gb.read_ue()
      pwt.chroma_log2_weight_denom = if chroma_denom < 0 || chroma_denom > 7 {
        0
      } else {
        chroma_denom
      }
      chroma_def = 1 << pwt.chroma_log2_weight_denom
    }
    for list in 0..<(if is_b { 2 } else { 1 }) {
      let count = if list == 0 { num_ref_idx_l0_active } else { num_ref_idx_l1_active }
      let lw = if list == 0 { pwt.luma_weight_l0 } else { pwt.luma_weight_l1 }
      let lo = if list == 0 { pwt.luma_offset_l0 } else { pwt.luma_offset_l1 }
      let cw = if list == 0 { pwt.chroma_weight_l0 } else { pwt.chroma_weight_l1 }
      let co = if list == 0 { pwt.chroma_offset_l0 } else { pwt.chroma_offset_l1 }
    for i = 0; i < count; i = i + 1 {
      if gb.read1().reinterpret_as_int() != 0 {
        let w = gb.read_se()
        let o = gb.read_se()
        if w < -128 || w > 127 || o < -128 || o > 127 {
          return Err("EINVAL")
        }
        lw[i] = w
        lo[i] = o
        if w != luma_def || o != 0 {
          pwt.use_weight = 1
        }
      } else {
        lw[i] = luma_def
        lo[i] = 0
      }
      if sps.chroma_format_idc != 0 {
        let has_chroma = gb.read1().reinterpret_as_int() != 0
        for j = 0; j < 2; j = j + 1 {
          if has_chroma {
            let w = gb.read_se()
            let o = gb.read_se()
            if w < -128 || w > 127 || o < -128 || o > 127 {
              return Err("EINVAL")
            }
            cw[i][j] = w
            co[i][j] = o
            if w != chroma_def || o != 0 {
              pwt.use_weight_chroma = 1
            }
          } else {
            cw[i][j] = chroma_def
            co[i][j] = 0
          }
        }
      }
    }
    }
    if pwt.use_weight_chroma != 0 {
      pwt.use_weight = 1
    }
  }
  // dec_ref_pic_marking
  let mut no_output_of_prior_pics = false
  let mut long_term_reference = false
  let mut adaptive_ref_marking = false
  let mmco : Array[(Int32, Int32, Int32)] = []
  if nal_ref_idc != 0 {
    if is_idr {
      no_output_of_prior_pics = gb.read1() != 0U
      long_term_reference = gb.read1() != 0U
    } else {
      let adaptive = gb.read1().reinterpret_as_int()
      if adaptive != 0 {
        adaptive_ref_marking = true
        while true {
          let opcode = gb.read_ue()
          if opcode < 0 || opcode > 6 || mmco.length() >= 66 {
            return Err("EINVAL")
          }
          if opcode == 0 {
            break
          }
          let short = if opcode == 1 || opcode == 2 || opcode == 3 { gb.read_ue() } else { 0 }
          let long = if opcode == 3 || opcode == 4 || opcode == 6 { gb.read_ue() } else { 0 }
          if short < 0 || long < 0 || (opcode == 2 && short >= 16) ||
            ((opcode == 3 || opcode == 6) && long >= 16) || (opcode == 4 && long > 16) {
            return Err("EINVAL")
          }
          mmco.push((opcode, short, long))
        }
      }
    }
  }
  let mut cabac_init_flag = 0
  if pps.cabac != 0 && slice_type_nos != 2 && slice_type_nos != 4 {
    cabac_init_flag = gb.read_ue()
    if cabac_init_flag < 0 || cabac_init_flag > 2 {
      return Err("EINVAL")
    }
  }
  let slice_qp_delta = gb.read_se()
  if slice_qp_delta == -2147483648 {
    return Err("EINVAL")
  }
  let mut slice_qs_delta = 0
  let mut sp_for_switch = false
  if slice_type_nos == 3 || slice_type_nos == 4 {
    if slice_type_nos == 3 {
      sp_for_switch = gb.read1() != 0U
    }
    slice_qs_delta = gb.read_se()
  }
  let qscale = pps.init_qp + slice_qp_delta
  if qscale < 0 || qscale > 51 {
    return Err("EINVAL")
  }
  let mut disable_idc = 0
  let mut alpha = 0
  let mut beta = 0
  if pps.deblocking_filter_parameters_present != 0 {
    disable_idc = gb.read_ue()
    if disable_idc < 0 || disable_idc > 2 {
      return Err("EINVAL")
    }
    if disable_idc != 1 {
      // `slice_alpha_c0_offset_div2` / `slice_beta_offset_div2`, then
      // `sl->slice_alpha_c0_offset = slice_alpha_c0_offset_div2 * 2`
      // (`h264_slice.c:1898-1910`).
      let alpha_div2 = gb.read_se()
      let beta_div2 = gb.read_se()
      if alpha_div2 > 6 || alpha_div2 < -6 || beta_div2 > 6 || beta_div2 < -6 {
        return Err("EINVAL")
      }
      alpha = alpha_div2 * 2
      beta = beta_div2 * 2
    }
  }
  Ok({
    first_mb_in_slice: first_mb,
    slice_type,
    slice_type_nos,
    pps_id,
    sps_id: pps.sps_id,
    frame_num,
    field_pic_flag,
    bottom_field_flag,
    idr_pic_id,
    pic_order_cnt_lsb,
    delta_pic_order_cnt_bottom,
    delta_pic_order_cnt,
    no_output_of_prior_pics,
    long_term_reference,
    adaptive_ref_marking,
    mmco,
    slice_qp_delta,
    qscale,
    disable_deblocking_filter_idc: disable_idc,
    slice_alpha_c0_offset: alpha,
    slice_beta_offset: beta,
    num_ref_idx_l0_active,
    num_ref_idx_l1_active,
    direct_spatial_mv_pred,
    sp_for_switch,
    slice_qs_delta,
    cabac_init_flag,
    pwt,
    ref_mod_l0_ops,
    ref_mod_l0_vals,
    ref_mod_l1_ops,
    ref_mod_l1_vals,
  })
}
