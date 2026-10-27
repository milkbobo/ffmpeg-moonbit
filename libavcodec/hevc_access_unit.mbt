///|
/// HEVC access-unit assembly and POC tracking, following FFmpeg 9.0.2
/// `libavcodec/hevc/parser.c` (`hevc_parse_slice_header`,
/// `hevc_find_frame_end`) and `libavcodec/hevc/ps.h`
/// (`ff_hevc_compute_poc`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// A new access unit starts at a VCL NAL whose first bit is
/// `first_slice_segment_in_pic_flag == 1`; parameter sets/SEI before it belong
/// to the upcoming unit. POC follows the C: IDR pictures are 0, others use
/// `ff_hevc_compute_poc2` against the last temporal-id-0 POC. Non-VCL NALs are
/// not decoded (SEI is skipped).
///
/// Out of scope: multi-layer POC (`nuh_layer_id > 0`), EOS/EOB handling, and
/// slice data.

///|
pub struct HevcAccessUnit {
  /// Index of the first NAL belonging to this unit (including leading VPS/SPS/PPS/SEI).
  first_nal : Int32
  nal_count : Int32
  /// Picture order count (IDR = 0).
  poc : Int32
  slice_type : Int32
  is_idr : Bool
  is_irap : Bool
  is_keyframe : Bool
  temporal_id : Int32
}

///|
/// Leading slice fields needed for access-unit grouping. */
fn hevc_peek_slice_info(
  gb : BitReader,
  nal_type : Int32,
  ps : HevcParamSets,
) -> Result[(Bool, Int32, Int32, Bool, Bool, Int32), String] {
  let first_slice = gb.read1() != 0
  if hevc_is_irap(nal_type) {
    ignore(gb.read1()) // no_output_of_prior_pics_flag
  }
  let pps_id = gb.read_ue_long()
  if pps_id >= hevc_max_pps_count.to_uint64() {
    return Err("hevc: PPS id out of range")
  }
  let pps = match ps.pps_list[pps_id.to_int()] {
    Some(p) => p
    None => return Err("hevc: missing PPS")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("hevc: missing SPS")
  }
  if !first_slice {
    if pps.dependent_slice_segments_enabled_flag != 0 {
      if gb.read1() != 0 {
        // Dependent headers carry neither slice type nor POC. The access
        // unit retains those fields from its first independent segment.
        return Ok(
          (
            false,
            0,
            0,
            hevc_is_idr(nal_type),
            hevc_is_irap(nal_type),
            sps.log2_max_poc_lsb,
          ),
        )
      }
    }
    let bits = hevc_ceil_log2(sps.ctb_width * sps.ctb_height)
    if bits > 0 {
      gb.skip(bits)
    }
  }
  for _ in 0..<pps.num_extra_slice_header_bits {
    ignore(gb.read1())
  }
  let slice_type = gb.read_ue_long()
  if slice_type > 2UL {
    return Err("hevc: invalid slice type")
  }
  if pps.output_flag_present_flag != 0 {
    ignore(gb.read1())
  }
  if sps.separate_colour_plane != 0 {
    gb.skip(2)
  }
  let idr = hevc_is_idr(nal_type)
  let mut poc_lsb = 0
  if !idr {
    poc_lsb = gb.read(sps.log2_max_poc_lsb).reinterpret_as_int()
  }
  Ok(
    (
      first_slice,
      slice_type.to_int(),
      poc_lsb,
      idr,
      hevc_is_irap(nal_type),
      sps.log2_max_poc_lsb,
    ),
  )
}

///|
/// Split an Annex B / length-prefixed HEVC stream into access units.
pub fn ff_hevc_split_access_units(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
) -> Result[Array[HevcAccessUnit], String] {
  let ps = new_hevc_param_sets()
  match ff_hevc_decode_extradata(data, ps, true) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let pkt = match ff_h2645_packet_split(data, nal_length_size, Hevc, is_nalff) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let out : Array[HevcAccessUnit] = []
  let mut poc_tid0 = 0
  let mut have_vcl = false
  let mut au_start = 0
  let mut last_vcl = 0
  let mut cur_poc = 0
  let mut cur_type = 0
  let mut cur_idr = false
  let mut cur_irap = false
  let mut cur_tid = 0
  for i, nal in pkt.nals {
    if nal.nal_type > 31 {
      continue
    }
    let gb = BitReader::with_size(nal.data, nal.size_bits)
    gb.skip(16)
    let (first_slice, slice_type, poc_lsb, idr, irap, log2_poc) = match
      hevc_peek_slice_info(gb, nal.nal_type, ps) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if first_slice {
      if have_vcl {
        out.push({
          first_nal: au_start,
          nal_count: last_vcl - au_start + 1,
          poc: cur_poc,
          slice_type: cur_type,
          is_idr: cur_idr,
          is_irap: cur_irap,
          is_keyframe: cur_irap,
          temporal_id: cur_tid,
        })
        au_start = last_vcl + 1
      }
      have_vcl = true
      cur_idr = idr
      cur_irap = irap
      cur_type = slice_type
      cur_tid = nal.temporal_id
      if idr {
        cur_poc = 0
      } else {
        cur_poc = ff_hevc_compute_poc2(
          log2_poc,
          poc_tid0,
          poc_lsb,
          nal.nal_type,
        )
      }
      // parser.c: update the temporal-id-0 POC after the picture.
      let excluded = nal.nal_type == 0 ||
        nal.nal_type == 2 ||
        nal.nal_type == 6 ||
        nal.nal_type == 8 ||
        nal.nal_type == 9
      if nal.temporal_id == 0 && !excluded {
        poc_tid0 = cur_poc
      }
    }
    last_vcl = i
  }
  if have_vcl {
    out.push({
      first_nal: au_start,
      nal_count: last_vcl - au_start + 1,
      poc: cur_poc,
      slice_type: cur_type,
      is_idr: cur_idr,
      is_irap: cur_irap,
      is_keyframe: cur_irap,
      temporal_id: cur_tid,
    })
  }
  Ok(out)
}
