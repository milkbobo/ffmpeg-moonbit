///|
/// MoonBit port of the HEVC slice segment header from FFmpeg 9.0.2
/// `libavcodec/hevc/hevcdec.c` (`hls_slice_header`) for the first slice segment
/// of a picture, using the parameter sets from `hevc_ps.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: first_slice flag, IRAP `no_output_of_prior_pics_flag`, PPS lookup,
/// slice address (independently coded non-first slices), extra header bits,
/// slice type, output flag, colour plane, POC LSB, short/long-term RPS
/// selection, temporal-MVP flag, SAO flags, and for I slices the QP/chroma-QP/
/// deblocking fields up to the slice header extension. `header_bits` gives the
/// bit position where the CABAC payload starts.
///
/// Out of scope: dependent slice segments (rejected), P/B reference-list
/// construction and prediction-weight tables (rejected after SAO, since they
/// need the DPB), CABAC, and the slice data itself.

///|
pub struct HevcSliceHeader {
  first_slice_segment_in_pic_flag : Bool
  no_output_of_prior_pics_flag : Bool
  dependent_slice_segment_flag : Bool
  pps_id : Int32
  slice_type : Int32
  num_ref_idx_l0_active : Int32
  num_ref_idx_l1_active : Int32
  mvd_l1_zero_flag : Bool
  cabac_init_flag : Bool
  collocated_ref_idx : Int32
  max_num_merge_cand : Int32
  pic_output_flag : Bool
  colour_plane_id : Int32
  pic_order_cnt_lsb : Int32
  short_term_ref_pic_set_sps_flag : Bool
  short_term_ref_pic_set_idx : Int32
  num_long_term_sps : Int32
  num_long_term_pics : Int32
  slice_temporal_mvp_enabled_flag : Bool
  slice_sao_luma_flag : Bool
  slice_sao_chroma_flag : Bool
  slice_qp_delta : Int32
  slice_cb_qp_offset : Int32
  slice_cr_qp_offset : Int32
  disable_deblocking_filter_flag : Bool
  beta_offset : Int32
  tc_offset : Int32
  /// Bit offset just past the slice header (CABAC starts here).
  header_bits : Int32
}

///|
/// HEVC slice types (`HEVC_SLICE_B/P/I`). */
pub let hevc_slice_b : Int32 = 0

///|
pub let hevc_slice_p : Int32 = 1

///|
pub let hevc_slice_i : Int32 = 2

///|
fn hevc_is_irap(nal_type : Int32) -> Bool {
  nal_type >= 16 && nal_type <= 23
}

///|
fn hevc_is_idr(nal_type : Int32) -> Bool {
  nal_type == 19 || nal_type == 20
}

///|
/// `av_ceil_log2`. */
fn hevc_ceil_log2(v : Int32) -> Int32 {
  if v <= 1 {
    return 0
  }
  let mut n = 0
  let mut x = v - 1
  while x > 0 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `pred_weight_table`: consume the luma/chroma weight flags and deltas. The
/// values are not retained (the pixel decoder will need them later).
fn hevc_skip_pred_weight_table(
  gb : BitReader,
  chroma : Bool,
  nb_l0 : Int32,
  nb_l1 : Int32,
) -> Result[Unit, String] {
  ignore(gb.read_ue_long()) // luma_log2_weight_denom
  if chroma {
    ignore(gb.read_ue_long()) // delta_chroma_log2_weight_denom
  }
  let total = nb_l0 + nb_l1
  let luma_flags : Array[Bool] = []
  for _ in 0..<total {
    luma_flags.push(gb.read1() != 0)
  }
  for i in 0..<total {
    if luma_flags[i] {
      ignore(gb.read_se()) // delta_luma_weight
      ignore(gb.read_se()) // luma_offset
    }
  }
  if chroma {
    let chroma_flags : Array[Bool] = []
    for _ in 0..<total {
      chroma_flags.push(gb.read1() != 0)
    }
    for i in 0..<total {
      if chroma_flags[i] {
        ignore(gb.read_se()) // delta_chroma_weight_cb
        ignore(gb.read_se()) // delta_chroma_offset_cb
        ignore(gb.read_se()) // delta_chroma_weight_cr
        ignore(gb.read_se()) // delta_chroma_offset_cr
      }
    }
  }
  Ok(())
}

///|
/// Parse a slice segment header. `gb` is positioned after the 16-bit NAL header.
pub fn ff_hevc_decode_slice_header(
  gb : BitReader,
  nal_type : Int32,
  ps : HevcParamSets,
) -> Result[HevcSliceHeader, String] {
  let first_slice = gb.read1() != 0
  let no_output = if hevc_is_irap(nal_type) { gb.read1() != 0 } else { false }
  let pps_id_u = gb.read_ue_long()
  if pps_id_u >= hevc_max_pps_count.to_uint64() {
    return Err("hevc: PPS id out of range")
  }
  let pps_id = pps_id_u.to_int()
  let pps = match ps.pps_list[pps_id] {
    Some(p) => p
    None => return Err("hevc: missing PPS")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("hevc: missing SPS")
  }
  let mut dependent = false
  if !first_slice {
    if pps.dependent_slice_segments_enabled_flag != 0 {
      dependent = gb.read1() != 0
    }
    let ctbs = sps.ctb_width * sps.ctb_height
    if ctbs <= 0 {
      return Err("hevc: invalid CTB grid")
    }
    let addr_bits = hevc_ceil_log2(ctbs)
    if addr_bits > 0 {
      gb.skip(addr_bits)
    }
    if dependent {
      return Err("PATCHWELCOME: dependent HEVC slice segment")
    }
  }
  for _ in 0..<pps.num_extra_slice_header_bits {
    ignore(gb.read1())
  }
  let slice_type_u = gb.read_ue_long()
  if slice_type_u > 2UL {
    return Err("hevc: invalid slice type")
  }
  let slice_type = slice_type_u.to_int()
  let pic_output = if pps.output_flag_present_flag != 0 {
    gb.read1() != 0
  } else {
    true
  }
  let colour_plane_id = if sps.separate_colour_plane != 0 {
    gb.read(2).to_int()
  } else {
    0
  }
  let mut poc_lsb = 0
  let mut st_flag = false
  let mut st_idx = 0
  let mut num_lt_sps = 0
  let mut num_lt_pics = 0
  let mut temporal_mvp = false
  if !hevc_is_idr(nal_type) {
    poc_lsb = gb.read(sps.log2_max_poc_lsb).to_int()
    st_flag = gb.read1() != 0
    if st_flag {
      if sps.nb_st_rps == 0 {
        return Err("hevc: no short-term RPS in SPS")
      }
      let bits = hevc_ceil_log2(sps.nb_st_rps)
      if bits > 0 {
        st_idx = gb.read(bits).to_int()
      }
    } else {
      let slice_rps = new_hevc_st_rps()
      match
        ff_hevc_decode_short_term_rps(
          gb,
          slice_rps,
          sps.st_rps,
          sps.nb_st_rps,
          0,
          true,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    if sps.long_term_ref_pics_present != 0 {
      num_lt_sps = gb.read_ue_long().to_int()
      num_lt_pics = gb.read_ue_long().to_int()
      if num_lt_sps < 0 || num_lt_pics < 0 || num_lt_sps + num_lt_pics > 32 {
        return Err("hevc: invalid long-term RPS")
      }
      let lt_bits = hevc_ceil_log2(sps.num_long_term_ref_pics_sps)
      for i in 0..<(num_lt_sps + num_lt_pics) {
        if i < num_lt_sps && lt_bits > 0 {
          gb.skip(lt_bits)
        }
        ignore(gb.read1()) // used_by_curr_pic_lt_flag
        if gb.read1() != 0 {
          ignore(gb.read_ue_long()) // delta_poc_msb_cycle_lt
        }
      }
    }
    if sps.temporal_mvp_enabled != 0 {
      temporal_mvp = gb.read1() != 0
    }
  }
  let mut sao_luma = false
  let mut sao_chroma = false
  if sps.sao_enabled != 0 {
    sao_luma = gb.read1() != 0
    if sps.chroma_format_idc != 0 {
      sao_chroma = gb.read1() != 0
    }
  }
  let mut nb_l0 = 0
  let mut nb_l1 = 0
  let mut mvd_l1_zero = false
  let mut cabac_init = false
  let mut collocated_ref_idx = 0
  let mut max_merge_cand = 0
  if slice_type != hevc_slice_i {
    nb_l0 = pps.num_ref_idx_l0_default_active
    if slice_type == hevc_slice_b {
      nb_l1 = pps.num_ref_idx_l1_default_active
    }
    if gb.read1() != 0 {
      nb_l0 = gb.read_ue_long().to_int() + 1
      if slice_type == hevc_slice_b {
        nb_l1 = gb.read_ue_long().to_int() + 1
      }
    }
    if nb_l0 < 1 || nb_l0 > 16 || nb_l1 < 0 || nb_l1 > 16 {
      return Err("hevc: invalid reference count")
    }
    if pps.lists_modification_present_flag != 0 {
      // Needs the RPS-derived frame reference count; not ported yet.
      return Err("PATCHWELCOME: HEVC reference list modification")
    }
    if slice_type == hevc_slice_b {
      mvd_l1_zero = gb.read1() != 0
    }
    if pps.cabac_init_present_flag != 0 {
      cabac_init = gb.read1() != 0
    }
    if temporal_mvp {
      let collocated_from_l0 = if slice_type == hevc_slice_b {
        gb.read1() != 0
      } else {
        true
      }
      let collocated_nb = if collocated_from_l0 { nb_l0 } else { nb_l1 }
      if collocated_nb > 1 {
        collocated_ref_idx = gb.read_ue_long().to_int()
        if collocated_ref_idx >= collocated_nb {
          return Err("hevc: invalid collocated_ref_idx")
        }
      }
    }
    let weighted = (pps.weighted_pred_flag != 0 && slice_type == hevc_slice_p) ||
      (pps.weighted_bipred_flag != 0 && slice_type == hevc_slice_b)
    if weighted {
      match
        hevc_skip_pred_weight_table(
          gb,
          sps.chroma_format_idc != 0,
          nb_l0,
          nb_l1,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    max_merge_cand = 5 - gb.read_ue_long().to_int()
    if max_merge_cand < 1 || max_merge_cand > 5 {
      return Err("hevc: invalid merge candidate count")
    }
    if sps.motion_vector_resolution_control_idc == 2 {
      ignore(gb.read1()) // use_integer_mv_flag
    }
  }
  let slice_qp_delta = gb.read_se()
  let mut cb_qp_offset = 0
  let mut cr_qp_offset = 0
  if pps.pic_slice_level_chroma_qp_offsets_present_flag != 0 {
    cb_qp_offset = gb.read_se()
    cr_qp_offset = gb.read_se()
  }
  if pps.pps_slice_act_qp_offsets_present_flag != 0 {
    ignore(gb.read_se()) // slice_act_y_qp_offset
    ignore(gb.read_se())
    ignore(gb.read_se())
  }
  if pps.chroma_qp_offset_list_enabled_flag != 0 {
    ignore(gb.read1()) // cu_chroma_qp_offset_enabled_flag
  }
  let mut disable_dbf = pps.disable_dbf != 0
  let mut beta_offset = pps.beta_offset
  let mut tc_offset = pps.tc_offset
  if pps.deblocking_filter_control_present_flag != 0 {
    let mut override_flag = false
    if pps.deblocking_filter_override_enabled_flag != 0 {
      override_flag = gb.read1() != 0
    }
    if override_flag {
      disable_dbf = gb.read1() != 0
      if !disable_dbf {
        beta_offset = gb.read_se() * 2
        tc_offset = gb.read_se() * 2
      }
    }
  }
  if pps.slice_header_extension_present_flag != 0 {
    let ext_bits = gb.read_ue_long()
    if ext_bits > 1024UL {
      return Err("hevc: slice header extension too large")
    }
    gb.skip(ext_bits.to_int() * 8)
  }
  Ok({
    first_slice_segment_in_pic_flag: first_slice,
    no_output_of_prior_pics_flag: no_output,
    dependent_slice_segment_flag: dependent,
    pps_id,
    slice_type,
    num_ref_idx_l0_active: nb_l0,
    num_ref_idx_l1_active: nb_l1,
    mvd_l1_zero_flag: mvd_l1_zero,
    cabac_init_flag: cabac_init,
    collocated_ref_idx,
    max_num_merge_cand: max_merge_cand,
    pic_output_flag: pic_output,
    colour_plane_id,
    pic_order_cnt_lsb: poc_lsb,
    short_term_ref_pic_set_sps_flag: st_flag,
    short_term_ref_pic_set_idx: st_idx,
    num_long_term_sps: num_lt_sps,
    num_long_term_pics: num_lt_pics,
    slice_temporal_mvp_enabled_flag: temporal_mvp,
    slice_sao_luma_flag: sao_luma,
    slice_sao_chroma_flag: sao_chroma,
    slice_qp_delta,
    slice_cb_qp_offset: cb_qp_offset,
    slice_cr_qp_offset: cr_qp_offset,
    disable_deblocking_filter_flag: disable_dbf,
    beta_offset,
    tc_offset,
    header_bits: gb.count(),
  })
}

///|
/// Parse parameter sets and every VCL slice header in an Annex B or
/// length-prefixed HEVC stream.
pub fn ff_hevc_parse_slice_headers(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
) -> Result[Array[HevcSliceHeader], String] {
  let ps = new_hevc_param_sets()
  match ff_hevc_decode_extradata(data, ps, true) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let pkt = match ff_h2645_packet_split(data, nal_length_size, Hevc, is_nalff) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let out : Array[HevcSliceHeader] = []
  for nal in pkt.nals {
    if nal.nal_type <= 31 {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(16)
      match ff_hevc_decode_slice_header(gb, nal.nal_type, ps) {
        Ok(h) => out.push(h)
        Err(e) => return Err(e)
      }
    }
  }
  Ok(out)
}
