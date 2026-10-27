///|
/// MoonBit port of the HEVC slice segment header from FFmpeg 9.0.2
/// `libavcodec/hevc/hevcdec.c` (`hls_slice_header`) for the first slice segment
/// of a picture, using the parameter sets from `hevc_ps.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: first_slice flag, IRAP `no_output_of_prior_pics_flag`, PPS lookup,
/// slice address (independently coded non-first slices), extra header bits,
/// slice type, output flag, colour plane, POC LSB (plus full POC derivation
/// against the caller's temporal-id-0 POC), short/long-term RPS, temporal-MVP
/// flag, SAO flags, P/B reference counts, collocated picture selection, the
/// prediction weight table, and the QP/chroma-QP/deblocking fields up to the
/// slice header extension. `header_bits` gives the bit position where the
/// CABAC payload starts.
///
/// Dependent segments inherit the independent header through `previous`.
/// Out of scope: reference-list modification (rejected), CABAC, and slice data.

///|
/// The weight/offset tables of `pred_weight_table` (C `SliceHeader`). */
pub struct HevcPredWeight {
  mut luma_log2_weight_denom : Int32
  mut chroma_log2_weight_denom : Int32
  luma_weight_l0 : Array[Int32]
  luma_offset_l0 : Array[Int32]
  luma_weight_l1 : Array[Int32]
  luma_offset_l1 : Array[Int32]
  chroma_weight_l0 : Array[Array[Int32]]
  chroma_offset_l0 : Array[Array[Int32]]
  chroma_weight_l1 : Array[Array[Int32]]
  chroma_offset_l1 : Array[Array[Int32]]
}

///|
fn new_hevc_pred_weight() -> HevcPredWeight {
  {
    luma_log2_weight_denom: 0,
    chroma_log2_weight_denom: 0,
    luma_weight_l0: Array::make(16, 1),
    luma_offset_l0: Array::make(16, 0),
    luma_weight_l1: Array::make(16, 1),
    luma_offset_l1: Array::make(16, 0),
    chroma_weight_l0: {
      let arr : Array[Array[Int32]] = []
      for _ in 0..<16 {
        arr.push(Array::make(2, 1))
      }
      arr
    },
    chroma_offset_l0: {
      let arr : Array[Array[Int32]] = []
      for _ in 0..<16 {
        arr.push(Array::make(2, 0))
      }
      arr
    },
    chroma_weight_l1: {
      let arr : Array[Array[Int32]] = []
      for _ in 0..<16 {
        arr.push(Array::make(2, 1))
      }
      arr
    },
    chroma_offset_l1: {
      let arr : Array[Array[Int32]] = []
      for _ in 0..<16 {
        arr.push(Array::make(2, 0))
      }
      arr
    },
  }
}

///|
pub struct HevcSliceHeader {
  first_slice_segment_in_pic_flag : Bool
  no_output_of_prior_pics_flag : Bool
  dependent_slice_segment_flag : Bool
  /// CTB raster-scan address of the first CTB in this slice segment.
  slice_segment_address : Int32
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
  slice_loop_filter_across_slices_enabled_flag : Bool
  /// WPP/tile substream count and per-entry byte offsets (offset + 1).
  num_entry_point_offsets : Int32
  entry_point_offsets : Array[Int32]
  /// Fully derived POC (IDR = 0).
  mut poc : Int32
  /// The resolved short-term RPS of this slice (SPS entry copied or parsed).
  st_rps : HevcStRps
  /// Long-term RPS with absolute POCs (`decode_lt_rps`).
  lt_rps : HevcLongTermRps
  /// 0 = L0, 1 = L1 (C `sh->collocated_list`).
  collocated_list : Int32
  /// Prediction weight table (all-default when the weighted flag is off).
  pw : HevcPredWeight
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
/// `pred_weight_table` (C `hevcdec.c`), storing luma/chroma weights and the
/// remapped chroma offsets into `pw`. */
fn hevc_parse_pred_weight_table(
  gb : BitReader,
  pw : HevcPredWeight,
  chroma : Bool,
  nb_l0 : Int32,
  nb_l1 : Int32,
  slice_is_b : Bool,
) -> Result[Unit, String] {
  let luma_denom = gb.read_ue_long().to_int()
  if luma_denom < 0 || luma_denom > 7 {
    return Err("hevc: invalid luma_log2_weight_denom")
  }
  pw.luma_log2_weight_denom = luma_denom
  if chroma {
    let chroma_denom = luma_denom + gb.read_se()
    if chroma_denom < 0 || chroma_denom > 7 {
      return Err("hevc: invalid chroma_log2_weight_denom")
    }
    pw.chroma_log2_weight_denom = chroma_denom
  }
  let hevc_clip_s17 = fn(v : Int32) -> Int32 {
    if v < -(1 << 17) {
      -(1 << 17)
    } else if v > 1 << 17 {
      1 << 17
    } else {
      v
    }
  }
  let lists : Array[
    (
      Array[Int32],
      Array[Int32],
      Array[Array[Int32]],
      Array[Array[Int32]],
      Int32,
    ),
  ] = [
    (
      pw.luma_weight_l0,
      pw.luma_offset_l0,
      pw.chroma_weight_l0,
      pw.chroma_offset_l0,
      nb_l0,
    ),
  ]
  if slice_is_b {
    lists.push(
      (
        pw.luma_weight_l1,
        pw.luma_offset_l1,
        pw.chroma_weight_l1,
        pw.chroma_offset_l1,
        nb_l1,
      ),
    )
  }
  for entry in lists {
    let (luma_weight, luma_offset, chroma_weight, chroma_offset, nb) = entry
    let luma_flags = gb.read(nb).reinterpret_as_int()
    let chroma_flags = if chroma { gb.read(nb).reinterpret_as_int() } else { 0 }
    for i in 0..<nb {
      let flag_bit = 1 << (nb - 1 - i)
      if (luma_flags & flag_bit) != 0 {
        let delta = gb.read_se()
        luma_weight[i] = (1 << pw.luma_log2_weight_denom) + delta
        luma_offset[i] = gb.read_se()
      } else {
        luma_weight[i] = 1 << pw.luma_log2_weight_denom
        luma_offset[i] = 0
      }
      if (chroma_flags & flag_bit) != 0 {
        for j in 0..<2 {
          let delta_w = gb.read_se()
          let delta_o = hevc_clip_s17(gb.read_se())
          chroma_weight[i][j] = (1 << pw.chroma_log2_weight_denom) + delta_w
          let o = delta_o -
            ((128 * chroma_weight[i][j]) >> pw.chroma_log2_weight_denom) +
            128
          chroma_offset[i][j] = if o < -128 {
            -128
          } else if o > 127 {
            127
          } else {
            o
          }
        }
      } else {
        for j in 0..<2 {
          chroma_weight[i][j] = 1 << pw.chroma_log2_weight_denom
          chroma_offset[i][j] = 0
        }
      }
    }
  }
  Ok(())
}

///|
/// `decode_lt_rps` (hevcdec.c): long-term RPS with absolute POCs. Returns
/// `(num_long_term_sps, num_long_term_pics)`. */
fn hevc_decode_lt_rps(
  gb : BitReader,
  rps : HevcLongTermRps,
  sps : HevcSps,
  cur_poc : Int32,
  poc_lsb : Int32,
) -> Result[(Int32, Int32), String] {
  rps.nb_refs = 0
  if sps.long_term_ref_pics_present == 0 {
    return Ok((0, 0))
  }
  let max_poc_lsb = 1 << sps.log2_max_poc_lsb
  let mut prev_delta_msb = 0
  let mut nb_sps = 0
  if sps.num_long_term_ref_pics_sps > 0 {
    nb_sps = gb.read_ue_long().to_int()
    if nb_sps > sps.num_long_term_ref_pics_sps {
      return Err("hevc: invalid long-term RPS")
    }
  }
  let nb_sh = gb.read_ue_long().to_int()
  if nb_sh < 0 || nb_sps + nb_sh > 16 {
    return Err("hevc: invalid long-term RPS")
  }
  rps.nb_refs = nb_sh + nb_sps
  for i in 0..<rps.nb_refs {
    if i < nb_sps {
      let mut lt_idx_sps = 0
      if sps.num_long_term_ref_pics_sps > 1 {
        let bits = hevc_ceil_log2(sps.num_long_term_ref_pics_sps)
        lt_idx_sps = gb.read(bits).reinterpret_as_int()
      }
      rps.poc[i] = sps.lt_ref_pic_poc_lsb_sps[lt_idx_sps]
      rps.used[i] = (sps.used_by_curr_pic_lt & (1U << lt_idx_sps)) != 0U
    } else {
      rps.poc[i] = gb.read(sps.log2_max_poc_lsb).reinterpret_as_int()
      rps.used[i] = gb.read1() != 0
    }
    rps.poc_msb_present[i] = gb.read1() != 0
    if rps.poc_msb_present[i] {
      let mut delta = gb.read_ue_long().to_int()
      if i != 0 && i != nb_sps {
        delta += prev_delta_msb
      }
      let poc = rps.poc[i] + cur_poc - delta * max_poc_lsb - poc_lsb
      rps.poc[i] = poc
      prev_delta_msb = delta
    }
  }
  Ok((nb_sps, nb_sh))
}

///|
/// Parse a slice segment header. `gb` is positioned after the 16-bit NAL
/// header; `poc_tid0` is the decoder's most recent temporal-id-0 POC
/// (`s->poc_tid0`).
/// Dependent segments require `previous` from the same picture and PPS;
/// only their address, entry points, extension and alignment are newly read.
pub fn ff_hevc_decode_slice_header(
  gb : BitReader,
  nal_type : Int32,
  ps : HevcParamSets,
  poc_tid0 : Int32,
  previous? : HevcSliceHeader,
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
  let mut slice_segment_address = 0
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
      slice_segment_address = gb.read(addr_bits).reinterpret_as_int()
    }
    if slice_segment_address >= ctbs {
      return Err("hevc: invalid slice segment address")
    }
    if dependent {
      let prev = match previous {
        Some(h) if h.pps_id == pps_id => h
        _ => return Err("hevc: independent slice segment missing")
      }
      if slice_segment_address == 0 ||
        pps.ctb_addr_rs_to_ts[slice_segment_address] == 0 {
        return Err("hevc: impossible dependent slice segment")
      }
      let (num_entry_point_offsets, entry_point_offsets, header_bits) = match
        hevc_slice_header_tail(gb, pps) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      return Ok({
        ..prev,
        first_slice_segment_in_pic_flag: false,
        no_output_of_prior_pics_flag: no_output,
        dependent_slice_segment_flag: true,
        slice_segment_address,
        num_entry_point_offsets,
        entry_point_offsets,
        header_bits,
      })
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
    gb.read(2).reinterpret_as_int()
  } else {
    0
  }
  let mut poc_lsb = 0
  let mut st_flag = false
  let mut st_idx = 0
  let mut num_lt_sps = 0
  let mut num_lt_pics = 0
  let mut temporal_mvp = false
  let mut poc = 0
  let st_rps = new_hevc_st_rps()
  let lt_rps = new_hevc_long_term_rps()
  if !hevc_is_idr(nal_type) {
    poc_lsb = gb.read(sps.log2_max_poc_lsb).reinterpret_as_int()
    poc = ff_hevc_compute_poc2(
      sps.log2_max_poc_lsb,
      poc_tid0,
      poc_lsb,
      nal_type,
    )
    st_flag = gb.read1() != 0
    if st_flag {
      if sps.nb_st_rps == 0 {
        return Err("hevc: no short-term RPS in SPS")
      }
      let bits = hevc_ceil_log2(sps.nb_st_rps)
      if bits > 0 {
        st_idx = gb.read(bits).reinterpret_as_int()
      }
      let src = sps.st_rps[st_idx]
      st_rps.delta_poc = src.delta_poc
      st_rps.used = src.used
      st_rps.num_negative_pics = src.num_negative_pics
      st_rps.num_delta_pocs = src.num_delta_pocs
      st_rps.rps_idx_num_delta_pocs = src.rps_idx_num_delta_pocs
      st_rps.use_delta = src.use_delta
    } else {
      match
        ff_hevc_decode_short_term_rps(
          gb,
          st_rps,
          sps.st_rps,
          sps.nb_st_rps,
          0,
          true,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    match hevc_decode_lt_rps(gb, lt_rps, sps, poc, poc_lsb) {
      Ok(v) => {
        num_lt_sps = v.0
        num_lt_pics = v.1
      }
      Err(e) => return Err(e)
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
  let mut collocated_list = 0
  let mut max_merge_cand = 0
  let pw = new_hevc_pred_weight()
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
      collocated_list = if collocated_from_l0 { 0 } else { 1 }
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
        hevc_parse_pred_weight_table(
          gb,
          pw,
          sps.chroma_format_idc != 0,
          nb_l0,
          nb_l1,
          slice_type == hevc_slice_b,
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
  let mut loop_filter_across_slices = pps.seq_loop_filter_across_slices_enabled_flag !=
    0
  if pps.seq_loop_filter_across_slices_enabled_flag != 0 &&
    (sao_luma || sao_chroma || !disable_dbf) {
    loop_filter_across_slices = gb.read1() != 0
  }
  let (num_entry_point_offsets, entry_point_offsets, header_bits) = match
    hevc_slice_header_tail(gb, pps) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  Ok({
    first_slice_segment_in_pic_flag: first_slice,
    no_output_of_prior_pics_flag: no_output,
    dependent_slice_segment_flag: dependent,
    slice_segment_address,
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
    slice_loop_filter_across_slices_enabled_flag: loop_filter_across_slices,
    num_entry_point_offsets,
    entry_point_offsets,
    poc,
    st_rps,
    lt_rps,
    collocated_list,
    pw,
    header_bits,
  })
}

///|
/// Syntax present in both independent and dependent segment headers.
fn hevc_slice_header_tail(
  gb : BitReader,
  pps : HevcPps,
) -> Result[(Int32, Array[Int32], Int32), String] {
  let mut num_entry_point_offsets = 0
  let entry_point_offsets : Array[Int32] = []
  if pps.tiles_enabled_flag != 0 || pps.entropy_coding_sync_enabled_flag != 0 {
    let n = gb.read_ue_long().to_int()
    if n < 0 || n > 4096 {
      return Err("hevc: invalid num_entry_point_offsets")
    }
    num_entry_point_offsets = n
    if n > 0 {
      let offset_len = gb.read_ue_long().to_int() + 1
      if offset_len < 1 || offset_len > 24 {
        return Err("hevc: invalid entry_point_offset length")
      }
      for _ in 0..<n {
        entry_point_offsets.push(gb.read(offset_len).reinterpret_as_int() + 1)
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
  // `alignment_bit_equal_to_one` + byte alignment (C: `align_get_bits`).
  if gb.read1() == 0 && gb.bits_left() >= 0 {
    return Err("hevc: alignment_bit_equal_to_one=0")
  }
  gb.align()
  if gb.bits_left() < 0 {
    return Err("hevc: truncated slice header")
  }
  Ok((num_entry_point_offsets, entry_point_offsets, gb.count()))
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
  let mut previous : HevcSliceHeader? = None
  for nal in pkt.nals {
    if nal.nal_type <= 31 {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(16)
      match ff_hevc_decode_slice_header(gb, nal.nal_type, ps, 0, previous?) {
        Ok(h) => {
          previous = Some(h)
          out.push(h)
        }
        Err(e) => return Err(e)
      }
    }
  }
  Ok(out)
}
