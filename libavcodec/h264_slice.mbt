///|
/// H.264 slice header parsing (FFmpeg 9.0.2 `h264_slice.c`,
/// `ff_h264_decode_slice_header`), currently for I/SI slices of a single
/// frame. This is the video-side slice-layer foundation; macroblock
/// reconstruction (CAVLC, intra prediction, transforms, deblocking) is the
/// next slice.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Supported: first_mb_in_slice, slice_type, PPS/SPS lookup, frame_num,
/// field flags, IDR POC and reference-marking fields, slice_qp_delta, and the
/// deblocking filter controls. P/B reference-list and prediction-weight
/// syntax is rejected explicitly rather than parsed partially.

///| Decoded fields of an H.264 slice header. */
pub struct H264SliceHeader {
  first_mb_in_slice : Int
  ///| Raw `slice_type` (I = 2 or 7, SI = 4 or 9).
  slice_type : Int
  ///| `slice_type % 5` (0 P, 1 B, 2 I, 3 SP, 4 SI).
  slice_type_nos : Int
  pps_id : Int
  sps_id : Int
  frame_num : Int
  field_pic_flag : Int
  bottom_field_flag : Int
  idr_pic_id : Int
  ///| `pic_order_cnt_lsb` (POC type 0 only; -1 otherwise).
  pic_order_cnt_lsb : Int
  delta_pic_order_cnt_bottom : Int
  slice_qp_delta : Int
  ///| Slice QP (`pps->init_qp + slice_qp_delta`).
  qscale : Int
  disable_deblocking_filter_idc : Int
  slice_alpha_c0_offset : Int
  slice_beta_offset : Int
}

///|
/// `ff_h264_decode_slice_header` for I/SI slices. `nal_type`/`nal_ref_idc`
/// come from the NAL header; `gb` must be positioned after that header.
pub fn ff_h264_decode_slice_header(
  gb : BitReader,
  nal_type : Int,
  nal_ref_idc : Int,
  ps : H264ParamSets
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
  if slice_type_nos != 2 && slice_type_nos != 4 {
    // P/B/SP reference-list and weight-table syntax is outside this slice.
    return Err("PATCHWELCOME")
  }
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
  if sps.poc_type == 0 {
    pic_order_cnt_lsb = gb.read(sps.log2_max_poc_lsb).reinterpret_as_int()
    if bottom_field_flag != 0 && sps.delta_pic_order_always_zero_flag == 0 {
      delta_pic_order_cnt_bottom = gb.read_se()
    }
  } else if sps.poc_type == 1 && sps.delta_pic_order_always_zero_flag == 0 {
    let _ = gb.read_se() // delta_pic_order_cnt[0]
    if bottom_field_flag != 0 {
      let _ = gb.read_se() // delta_pic_order_cnt[1]
    }
  }
  if pps.redundant_pic_cnt_present != 0 {
    let _ = gb.read_ue() // redundant_pic_cnt
  }
  // I/SI slices have no reference-list modification or weight table.
  // dec_ref_pic_marking
  if nal_ref_idc != 0 {
    if is_idr {
      let _ = gb.read1() // no_output_of_prior_pics_flag
      let _ = gb.read1() // long_term_reference_flag
    } else {
      let adaptive = gb.read1().reinterpret_as_int()
      if adaptive != 0 {
        while true {
          let mmco = gb.read_ue()
          if mmco < 0 {
            return Err("EINVAL")
          }
          if mmco == 0 {
            break
          }
          if mmco == 1 || mmco == 3 || mmco == 6 {
            let _ = gb.read_ue() // difference_of_pic_nums_minus1 / long_term_pic_num / ...
          }
          if mmco == 2 {
            let _ = gb.read_ue() // long_term_pic_num
          }
          if mmco == 3 || mmco == 6 {
            let _ = gb.read_ue() // long_term_frame_idx
          }
          if mmco == 4 {
            let _ = gb.read_ue() // max_long_term_frame_idx_plus1
          }
        }
      }
    }
  }
  if pps.cabac != 0 && slice_type_nos != 2 && slice_type_nos != 4 {
    let _ = gb.read_ue() // cabac_init_idc
  }
  let slice_qp_delta = gb.read_se()
  if slice_qp_delta == -2147483648 {
    return Err("EINVAL")
  }
  let mut slice_qs_delta = 0
  if slice_type_nos == 3 || slice_type_nos == 4 {
    if slice_type_nos == 4 {
      let _ = gb.read1() // sp_for_switch_flag
    }
    slice_qs_delta = gb.read_se()
  }
  let _ = slice_qs_delta
  let qscale = pps.init_qp + slice_qp_delta
  if qscale < 0 || qscale > 51 {
    return Err("EINVAL")
  }
  let mut disable_idc = 0
  let mut alpha = 0
  let mut beta = 0
  if pps.deblocking_filter_parameters_present != 0 {
    disable_idc = gb.read_ue()
    if disable_idc < 0 {
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
    slice_qp_delta,
    qscale,
    disable_deblocking_filter_idc: disable_idc,
    slice_alpha_c0_offset: alpha,
    slice_beta_offset: beta,
  })
}
