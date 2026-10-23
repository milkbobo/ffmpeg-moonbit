///|
/// MoonBit port of the H.264 decoded picture buffer bookkeeping needed for
/// P-picture decoding, after FFmpeg 9.0.2 `libavcodec/h264dec.c` /
/// `h264_slice.c` (`ff_h264_execute_ref_pic_marking`'s sliding window and
/// the default `ff_h264_build_ref_list0` ordering) plus the POC type 0/2
/// tracking from `h264_slice.c: h264_field_start` / `ff_h264_init_poc`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: progressive, MBAFF frame and PAFF field I/P/B, POC 0/1/2 and frame_num wrap,
/// MMCO 1..6 and IDR long references, MBAFF top/bottom field reference views.
/// Default/reordered L0 includes short/long references. Complementary fields
/// share planes and motion history; frame_num-gap synthesis remains unsupported.

///|
/// One short/long-term reference entry; POC belongs to the picture planes.
struct H264DpbEntry {
  mbaff : Bool
  field_picture : Bool
  infos : Array[H264MbInfo]
  frame_num : Int32
  long_index : Int32
  pic : H264RefPic
  /// Reference mask of the coded picture: `PICT_TOP_FIELD` (1),
  /// `PICT_BOTTOM_FIELD` (2) or both (3 for frame-coded pictures and for
  /// complete complementary field pairs).
  reference : Int32
}

///|
/// A decoded first field waiting for its complementary second field
/// (`h->first_field` / `h->cur_pic_ptr` in FFmpeg).
struct H264PendingField {
  frame : H264Frame
  structure : Int32
  frame_num : Int32
  poc_top : Int32
  poc_bottom : Int32
  ref_idc : Int32
  identity : Int32
}

///|
pub struct H264Decoder {
  mut picture_serial : Int32
  mut epoch : Int32
  /// Parameter sets, updated by in-band SPS/PPS NALs.
  ps : H264ParamSets
  refs : Array[H264DpbEntry]
  /// `h->first_field`: first field of a potential complementary pair.
  mut pending_field : H264PendingField?
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
    pending_field: None,
    prev_poc_msb: 0,
    prev_poc_lsb: 0,
    prev_frame_num: 0,
    prev_frame_num_offset: 0,
  }
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
  if slices.is_empty() {
    Ok(None)
  } else {
    self.decode_picture(slices, skip_lf)
  }
}

///|
/// Decode a complete picture before committing POC history and reference marking.
fn H264Decoder::decode_picture(
  self : H264Decoder,
  nals : Array[H2645Nal],
  skip_lf : Bool,
) -> Result[H264Frame?, String] {
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
  let (poc_pic, top, bottom, poc_msb, frame_offset) = match
    self.picture_order(sps, sh, nal.ref_idc, is_idr) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let field_picture = sh.field_pic_flag != 0
  let structure = if field_picture {
    if sh.bottom_field_flag != 0 {
      2
    } else {
      1
    }
  } else {
    3
  }
  // Field pictures come in complementary pairs sharing one buffer. Pair this
  // field with a pending first field when the structure is complementary and
  // the frame_num matches (`h264_field_start`); a mismatched or duplicate
  // field leaves the previous one unmatched (it stays as a reference but is
  // never output).
  let mut carry : H264PictureCarry? = None
  let mut paired = false
  let mut pair_identity = -1
  let mut pending_top = 2147483647
  let mut pending_bottom = 2147483647
  if field_picture {
    match self.pending_field {
      Some(pending) =>
        if pending.structure != structure && pending.frame_num == sh.frame_num {
          // `h->droppable = nal->ref_idc == 0`: a pair may mix NAL ref_idc
          // values as long as both fields are references (or both are not).
          if (pending.ref_idc != 0) != (nal.ref_idc != 0) {
            return Err(
              "H.264 field pair mixes reference and non-reference fields",
            )
          }
          paired = true
          pair_identity = pending.identity
          pending_top = pending.poc_top
          pending_bottom = pending.poc_bottom
          carry = Some({
            y: pending.frame.y,
            u: pending.frame.u,
            v: pending.frame.v,
            infos: pending.frame.infos,
          })
        } else {
          self.pending_field = None
        }
      None => ()
    }
  } else {
    self.pending_field = None
  }
  let current_poc = if field_picture {
    if structure == 2 {
      bottom
    } else {
      top
    }
  } else {
    poc_pic
  }
  // `ff_h264_init_poc` stores only the current field's POC; the other field's
  // value stays INT_MAX until the complementary picture fills it in.
  let poc_top = if field_picture {
    if structure == 1 {
      current_poc
    } else {
      pending_top
    }
  } else {
    top
  }
  let poc_bottom = if field_picture {
    if structure == 2 {
      current_poc
    } else {
      pending_bottom
    }
  } else {
    bottom
  }
  let poc_min = poc_top.min(poc_bottom)
  fn refs_for(header : H264SliceHeader) -> Result[H264SliceRefs, String] {
    let longs = self.refs
      .filter(fn(entry) { entry.long_index >= 0 })
      .map(fn(entry) { entry.pic.identity })
    if header.slice_type_nos == 1 {
      return self.b_references(
        header, sps, current_poc, poc_top, poc_bottom, longs, field_picture, structure,
      )
    }
    if header.slice_type_nos != 0 && header.slice_type_nos != 3 {
      return Ok({
        list0: [],
        list1: [],
        colocated: [],
        colocated_mbaff: false,
        colocated_field_picture: false,
        long_pocs: longs,
        poc: current_poc,
        poc_top,
        poc_bottom,
      })
    }
    let curr_pic_num = if field_picture {
      2 * header.frame_num + 1
    } else {
      header.frame_num
    }
    let max_pic_num = if field_picture {
      1 << (sps.log2_max_frame_num + 1)
    } else {
      1 << sps.log2_max_frame_num
    }
    let list = match
      self.build_reference_list(
        self.refs,
        field_picture,
        structure,
        header.num_ref_idx_l0_active,
        header.ref_mod_l0_ops,
        header.ref_mod_l0_vals,
        curr_pic_num,
        max_pic_num,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if list.length() == 0 {
      return Err("no reference picture for a P slice")
    }
    Ok({
      list0: list,
      list1: [],
      colocated: [],
      colocated_mbaff: false,
      colocated_field_picture: false,
      long_pocs: longs,
      poc: current_poc,
      poc_top,
      poc_bottom,
    })
  }
  let frame = match
    h264_decode_picture_ex(nals, self.ps, refs_for, skip_lf, carry~) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Commit reference marking only after every slice reconstructed successfully.
  let identity = if paired { pair_identity } else { self.picture_serial + 1 }
  if nal.ref_idc != 0 {
    let pic : H264RefPic = {
      identity,
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
      poc: poc_min,
      field_poc_top: poc_top,
      field_poc_bottom: poc_bottom,
      base_y: 0,
      base_u: 0,
      base_v: 0,
      parity: 0,
    }
    match
      self.mark_reference(
        pic,
        frame.infos,
        sh,
        sps,
        is_idr,
        field_picture,
        structure,
        paired,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let reset = sh.mmco.any(fn(op) { op.0 == 5 })
    self.prev_poc_msb = if reset { 0 } else { poc_msb }
    self.prev_poc_lsb = if reset {
      poc_msb + sh.pic_order_cnt_lsb - current_poc
    } else {
      sh.pic_order_cnt_lsb
    }
  }
  let reset = sh.mmco.any(fn(op) { op.0 == 5 })
  self.prev_frame_num = if reset { 0 } else { sh.frame_num }
  self.prev_frame_num_offset = if reset { 0 } else { frame_offset }
  if (is_idr && self.picture_serial > 0) || reset {
    self.epoch += 1
  }
  self.picture_serial += 1
  if field_picture && !paired {
    // First field: keep the picture (and its reference marking) waiting for
    // the complementary field; it is never displayed on its own.
    self.pending_field = Some({
      frame,
      structure,
      frame_num: sh.frame_num,
      poc_top,
      poc_bottom,
      ref_idc: nal.ref_idc,
      identity,
    })
    Ok(None)
  } else {
    self.pending_field = None
    Ok(
      Some({ ..frame, epoch: self.epoch, poc: if reset { 0 } else { poc_min }, }),
    )
  }
}

///|
/// Decode an Annex B stream (parameter sets plus an I/P/B picture sequence)
/// into frames in decoding order, grouping multiple slices per picture.
/// Complementary PAFF fields are paired before a frame is returned.
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
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      gb.read_ue() == 0
    } else {
      false
    }
    if has_slice &&
      (
        first ||
        nal.nal_type == 6 ||
        nal.nal_type == 7 ||
        nal.nal_type == 8 ||
        nal.nal_type == 9
      ) {
      match self.decode_nals(pending, skip_lf) {
        Ok(Some(frame)) => frames.push(frame)
        Ok(None) => ()
        Err(error) => return Err(error)
      }
      pending.clear()
      has_slice = false
    }
    pending.push(nal)
    has_slice = has_slice || slice
  }
  match self.decode_nals(pending, skip_lf) {
    Ok(Some(frame)) => frames.push(frame)
    Ok(None) => ()
    Err(error) => return Err(error)
  }
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
