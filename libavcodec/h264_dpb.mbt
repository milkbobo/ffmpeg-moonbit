///|
/// MoonBit port of the H.264 decoded picture buffer bookkeeping needed for
/// P-picture decoding, after FFmpeg 9.0.2 `libavcodec/h264dec.c` /
/// `h264_slice.c` (`ff_h264_execute_ref_pic_marking`'s sliding window and
/// the default `ff_h264_build_ref_list0` ordering) plus the POC type 0/2
/// tracking from `h264_slice.c: h264_field_start` / `ff_h264_init_poc`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: progressive I/P/B, POC 0/1/2 and frame_num wrap, MMCO 1..6 and IDR
/// long references. Default/reordered L0 includes short/long references.
/// Field pictures and frame_num-gap synthesis remain unsupported.

///|
/// One short/long-term reference entry; POC belongs to the picture planes.
struct H264DpbEntry {
  infos : Array[H264MbInfo]
  frame_num : Int32
  long_index : Int32
  pic : H264RefPic
}

///|
/// Decoder state across pictures: the parameter sets and the sliding-window
/// short-term reference buffer.
pub struct H264Decoder {
  mut picture_serial : Int32
  mut epoch : Int32
  /// Parameter sets, updated by in-band SPS/PPS NALs.
  ps : H264ParamSets
  refs : Array[H264DpbEntry]
  /// `PrevPicOrderCntMsb` / `PrevPicOrderCntLsb` (POC type 0).
  mut prev_poc_msb : Int32
  mut prev_poc_lsb : Int32
  /// `PrevRefFrameNum` (POC type 2 / sliding window).
  mut prev_frame_num : Int32
  mut prev_frame_num_offset : Int32
}

///|
/// Create a decoder with an empty reference buffer. */
pub fn new_h264_decoder() -> H264Decoder {
  {
    picture_serial: 0,
    epoch: 0,
    ps: new_h264_param_sets(),
    refs: [],
    prev_poc_msb: 0,
    prev_poc_lsb: 0,
    prev_frame_num: 0,
    prev_frame_num_offset: 0,
  }
}

///|
/// Default P L0: descending FrameNumWrap, then ascending LongTermPicNum.
fn H264Decoder::ref_list0(
  self : H264Decoder,
  count : Int32,
  mod_ops : Array[Int32],
  mod_vals : Array[Int32],
  curr_frame_num : Int32,
  max_pic_num : Int32,
  order? : Array[H264DpbEntry] = [],
) -> Result[Array[H264RefPic], String] {
  let list : Array[H264RefPic] = []
  if self.refs.length() == 0 {
    return Ok(list)
  }
  let entries = if order.is_empty() { [..self.refs] } else { order.copy() }
  // P default short list uses descending FrameNumWrap, then ascending long index.
  if order.is_empty() { entries.sort_by(fn(a, b) {
    if a.long_index >= 0 && b.long_index >= 0 { a.long_index.compare(b.long_index) }
    else if a.long_index >= 0 { 1 }
    else if b.long_index >= 0 { -1 }
    else {
      let aw = if a.frame_num > curr_frame_num { a.frame_num - max_pic_num } else { a.frame_num }
      let bw = if b.frame_num > curr_frame_num { b.frame_num - max_pic_num } else { b.frame_num }
      bw.compare(aw)
    }
  }) }
  // `ff_h264_build_ref_list`'s missing-reference pass uses `default_ref =
  // ref_list[0]`, so pad the default list to the coded reference count.
  let base : Array[H264DpbEntry] = []
  for i = 0; i < count; i = i + 1 {
    if i < entries.length() {
      base.push(entries[i])
    } else {
      base.push(entries[0])
    }
  }
  let mut pred = curr_frame_num
  for k = 0; k < mod_ops.length(); k = k + 1 {
    let op = mod_ops[k]
    let diff = mod_vals[k] + 1
    if k >= count || (op != 2 && diff > max_pic_num) {
      return Err("EINVAL")
    }
    if op != 2 {
      pred = if op == 0 { pred - diff } else { pred + diff }
      pred = pred & (max_pic_num - 1)
    }
    let mut found = -1
    for i = 0; i < entries.length(); i = i + 1 {
      if (op == 2 && entries[i].long_index == mod_vals[k]) ||
        (op != 2 && entries[i].long_index < 0 && entries[i].frame_num == pred) {
        found = i
        break
      }
    }
    if found < 0 {
      return Err("reference picture missing during reorder")
    }
    let entry = entries[found]
    // Shift the previous occupant (and any duplicate) as in the C.
    let mut i = k
    while i + 1 < count {
      if base[i].frame_num == entry.frame_num && base[i].long_index == entry.long_index {
        break
      }
      i = i + 1
    }
    while i > k {
      base[i] = base[i - 1]
      i = i - 1
    }
    base[k] = entry
  }
  for e in base {
    list.push(e.pic)
  }
  Ok(list)
}

///|
/// Decode one coded-slice NAL (plus any SPS/PPS NALs of the same access
/// unit) into a picture, updating the reference buffer. Returns `None` for
/// access units without a slice (parameter sets only).
fn H264Decoder::decode_nals(
  self : H264Decoder,
  nals : Array[H2645Nal],
  skip_lf : Bool,
) -> Result[H264Frame?, String] {
  let slices : Array[H2645Nal] = []
  for k = 0; k < nals.length(); k = k + 1 {
    let nal = nals[k]
    if nal.nal_type == h264_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_seq_parameter_set(gb, self.ps, false) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_pps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_picture_parameter_set(gb, self.ps, gb.size_bits()) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_idr_slice || nal.nal_type == 1 {
      slices.push(nal)
    }
  }
  if slices.is_empty() { Ok(None) } else {
    match self.decode_picture(slices, skip_lf) { Ok(frame) => Ok(Some(frame)); Err(error) => Err(error) }
  }
}

///|
/// Decode a complete picture before committing POC history and reference marking.
fn H264Decoder::decode_picture(
  self : H264Decoder,
  nals : Array[H2645Nal],
  skip_lf : Bool,
) -> Result[H264Frame, String] {
  let nal = nals[0]
  let is_idr = nal.nal_type == h264_nal_idr_slice
  // POC (h264_slice.c): type 0 tracks the MSB wraps, type 2 is 2*frame_num.
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(8)
  let sh = match
    ff_h264_decode_slice_header(gb, nal.nal_type, nal.ref_idc, self.ps) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pps = match self.ps.pps_list[sh.pps_id] {
    Some(p) => p
    None => return Err("missing PPS")
  }
  let sps = match self.ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("missing SPS")
  }
  let (poc, poc_msb, frame_offset) = match self.picture_order(sps, sh, nal.ref_idc, is_idr) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  fn refs_for(header : H264SliceHeader) -> Result[H264SliceRefs, String] {
    let longs = self.refs.filter(fn(entry) { entry.long_index >= 0 }).map(fn(entry) { entry.pic.identity })
    if header.slice_type_nos == 1 { return self.b_references(header, sps, poc, longs) }
    if header.slice_type_nos != 0 && header.slice_type_nos != 3 { return Ok({ list0: [], list1: [], colocated: [], long_pocs: longs, poc }) }
    let list = match
      self.ref_list0(
        header.num_ref_idx_l0_active,
        header.ref_mod_l0_ops,
        header.ref_mod_l0_vals,
        header.frame_num,
        1 << sps.log2_max_frame_num,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if list.length() == 0 {
      return Err("no reference picture for a P slice")
    }
    Ok({ list0: list, list1: [], colocated: [], long_pocs: longs, poc })
  }
  let frame = match h264_decode_picture_ex(nals, self.ps, refs_for, skip_lf) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Commit reference marking only after every slice reconstructed successfully.
  if nal.ref_idc != 0 {
    let pic : H264RefPic = {
      identity: self.picture_serial + 1,
      y: frame.y,
      u: frame.u,
      v: frame.v,
      ystride: frame.ystride,
      cstride: frame.cstride,
      // Plane dimensions (macroblock-aligned), the border-replication
      // bounds of motion compensation.
      width: frame.ystride,
      height: frame.pheight,
      cwidth: frame.ystride >> frame.chroma_hshift,
      cheight: frame.pheight >> frame.chroma_vshift,
      poc,
    }
    match self.mark_reference(pic, frame.infos, sh, sps, is_idr) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let reset = sh.mmco.any(fn(op) { op.0 == 5 })
    self.prev_poc_msb = if reset { 0 } else { poc_msb }
    self.prev_poc_lsb = if reset { poc_msb + sh.pic_order_cnt_lsb - poc } else { sh.pic_order_cnt_lsb }
  }
  let reset = sh.mmco.any(fn(op) { op.0 == 5 })
  self.prev_frame_num = if reset { 0 } else { sh.frame_num }
  self.prev_frame_num_offset = if reset { 0 } else { frame_offset }
  if (is_idr && self.picture_serial > 0) || reset { self.epoch += 1 }
  self.picture_serial += 1
  Ok({ ..frame, epoch: self.epoch, poc: if reset { 0 } else { frame.poc } })
}

///|
/// Decode an Annex B stream (parameter sets plus an I/P/B picture sequence)
/// into frames in decoding order, grouping multiple slices per picture.
/// Interlaced pictures remain unsupported.
pub fn H264Decoder::decode_annexb(
  self : H264Decoder,
  data : Bytes,
  skip_lf : Bool,
) -> Result[Array[H264Frame], String] {
  let pkt = match ff_h2645_packet_split(data, 4, H264, false) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let frames : Array[H264Frame] = []
  let pending : Array[H2645Nal] = []
  let mut has_slice = false
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    let slice = nal.nal_type == 1 || nal.nal_type == 5
    let first = if slice {
      let gb = BitReader::with_size(nal.data, nal.size_bits); gb.skip(8); gb.read_ue() == 0
    } else { false }
    if has_slice && (first || nal.nal_type == 6 || nal.nal_type == 7 || nal.nal_type == 8 || nal.nal_type == 9) {
      match self.decode_nals(pending, skip_lf) { Ok(Some(frame)) => frames.push(frame); Ok(None) => (); Err(error) => return Err(error) }
      pending.clear(); has_slice = false
    }
    pending.push(nal)
    has_slice = has_slice || slice
  }
  match self.decode_nals(pending, skip_lf) { Ok(Some(frame)) => frames.push(frame); Ok(None) => (); Err(error) => return Err(error) }
  Ok(frames)
}

///|
/// Decode one MP4-style access unit (`nal_length_size`-prefixed NALs) into a
/// picture; `None` when the unit carries only parameter sets.
pub fn H264Decoder::decode_avc_sample(
  self : H264Decoder,
  sample : Bytes,
  nal_length_size : Int32,
  skip_lf : Bool,
) -> Result[H264Frame?, String] {
  let pkt = match ff_h2645_packet_split(sample, nal_length_size, H264, true) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  self.decode_nals(pkt.nals, skip_lf)
}

///|
/// Convenience entry point: decode a whole Annex B stream with a fresh
/// decoder state (the DPB-scoped variant allows interleaved feeding).
pub fn h264_decode_annexb_frames(
  data : Bytes,
  skip_lf : Bool,
) -> Result[Array[H264Frame], String] {
  let dec = new_h264_decoder()
  dec.decode_annexb(data, skip_lf)
}
