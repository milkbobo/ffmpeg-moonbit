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
/// share planes and motion history; frame_num gaps synthesize reference-only pictures.

///|
/// One short/long-term reference entry; POC belongs to the picture planes.
struct H264DpbEntry {
  buffer_identity : Int32
  invalid_gap : Bool
  gray : Bool
  bit_depth : Int32
  chroma_format : Int32
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
  /// The recovery point SEI seen at this field's picture start; the C sets
  /// `pic->sei_recovery_frame_cnt` in `h264_frame_start`, which only runs
  /// for frame pictures and first fields, so the pair keeps this value.
  sei_recovery_frame_cnt : Int32
}

///|
pub struct H264Decoder {
  mut conceal_errors : Bool
  mut picture_serial : Int32
  mut epoch : Int32
  mut non_gray : Bool
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
  /// `h->sei`: SEI state carried across access units; reset at an AU
  /// boundary unless a complementary second field is still expected.
  sei : H264SeiContext
  /// `h->has_recovery_point`.
  mut has_recovery_point : Bool
}

///|
/// Create a decoder with an empty reference buffer. */
pub fn new_h264_decoder() -> H264Decoder {
  {
    conceal_errors: false,
    picture_serial: 0,
    epoch: 0,
    non_gray: false,
    ps: new_h264_param_sets(),
    refs: [],
    pending_field: None,
    prev_poc_msb: 0,
    prev_poc_lsb: 0,
    prev_frame_num: -1,
    prev_frame_num_offset: 0,
    sei: new_h264_sei_context(),
    has_recovery_point: false,
  }
}

///|
/// Recover missing macroblocks in progressive frame pictures. The default
/// remains strict so callers can retry a failed sample with more slices.
pub fn H264Decoder::set_error_concealment(
  self : H264Decoder,
  enabled : Bool,
) -> Unit {
  self.conceal_errors = enabled
}

///|
/// Decode the SEI messages of one type-6 NAL (`decode_nal_units`'s
/// `H264_NAL_SEI` case; errors are not fatal without AV_EF_EXPLODE, so a
/// malformed message only leaves its partial state behind).
fn H264Decoder::decode_sei_nal(self : H264Decoder, nal : H2645Nal) -> Unit {
  let nbytes = (nal.size_bits - 8) / 8
  if nbytes <= 0 {
    return
  }
  let payload = nal.data.clamped_view(start=1, end=1 + nbytes).to_owned()
  let _ = self.sei.h264_sei_decode(payload, self.ps)
  self.has_recovery_point = self.has_recovery_point ||
    self.sei.recovery_point.recovery_frame_cnt != -1
}

///|
/// Decode one coded-slice NAL (plus any SPS/PPS/SEI NALs of the same access
/// unit) into a picture, updating the reference buffer. Returns `None` for
/// access units without a slice (parameter sets only) and for an unpaired
/// first field.
///
/// NAL boundary semantics (`h264dec.c: decode_nal_units`): the per-AU SEI
/// state is reset when a new access unit begins, unless a complementary
/// second field is still expected (`!h->first_field`); SEI NALs preceding
/// the first slice apply to this picture (the C exports them at
/// `h264_field_start` → `h264_export_frame_props`); SEI NALs after the
/// first slice only update state a later access unit may still see.
fn H264Decoder::decode_nals(
  self : H264Decoder,
  nals : Array[H2645Nal],
  skip_lf : Bool,
) -> Result[H264Frame?, String] {
  if self.pending_field is None {
    self.sei.sei_uninit()
  }
  let slices : Array[H2645Nal] = []
  let late_sei : Array[H2645Nal] = []
  let mut has_slice = false
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
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      let header = match
        ff_h264_decode_slice_header(gb, nal.nal_type, nal.ref_idc, self.ps) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      // h264_slice.c discards a redundant slice after parsing its header.
      // It must not replace the primary picture or update the DPB.
      if header.redundant_pic_count == 0 {
        if header.slice_type_nos == 3 || header.slice_type_nos == 4 {
          return Err("SP/SI reconstruction is not supported")
        }
        slices.push(nal)
        has_slice = true
      }
    } else if nal.nal_type == 2 || nal.nal_type == 3 || nal.nal_type == 4 {
      return Err("H.264 data partitioning is not supported")
    } else if nal.nal_type == 6 {
      if has_slice {
        late_sei.push(nal)
      } else {
        self.decode_sei_nal(nal)
      }
    }
  }
  if slices.is_empty() {
    return Ok(None)
  }
  let result = self.decode_picture(slices, skip_lf)
  // The export mirrors `h264_export_frame_props`, which runs at the picture
  // start of frame pictures and of second fields (`!FIELD_PICTURE ||
  // !h->first_field`): exactly the pictures `decode_picture` returns.
  match result {
    Ok(Some(frame)) => {
      // C: `cur->poc + (h->poc_offset << 5)`; this port has no poc_offset
      // (gap handling resets poc and bumps the epoch instead), so the seed
      // is the picture POC.
      let seed = frame.poc.reinterpret_as_uint()
      self.sei.sei_to_frame(
        frame.side_data,
        frame.vui,
        frame.bit_depth,
        frame.bit_depth,
        frame.width,
        frame.height,
        seed,
      )
      for k = 0; k < late_sei.length(); k = k + 1 {
        self.decode_sei_nal(late_sei[k])
      }
      Ok(Some(frame))
    }
    Ok(None) => {
      for k = 0; k < late_sei.length(); k = k + 1 {
        self.decode_sei_nal(late_sei[k])
      }
      Ok(None)
    }
    Err(e) => Err(e)
  }
}

///|
/// Decode a complete picture before committing POC history and reference marking.
fn H264Decoder::decode_picture(
  self : H264Decoder,
  nals : Array[H2645Nal],
  skip_lf : Bool,
) -> Result[H264Frame?, String] {
  // Gap synthesis happens before reference-list resolution. Stage all DPB
  // and history updates so a rejected picture cannot leave dummy references
  // or an advanced frame_num behind.
  let next : H264Decoder = { ..self, refs: self.refs.copy(), }
  let output = match next.decode_picture_with_gaps(nals, skip_lf) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.refs.clear()
  self.refs.append(next.refs)
  self.pending_field = next.pending_field
  self.picture_serial = next.picture_serial
  self.epoch = next.epoch
  self.non_gray = next.non_gray
  self.prev_poc_msb = next.prev_poc_msb
  self.prev_poc_lsb = next.prev_poc_lsb
  self.prev_frame_num = next.prev_frame_num
  self.prev_frame_num_offset = next.prev_frame_num_offset
  Ok(output)
}

///|
fn H264Decoder::decode_picture_with_gaps(
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
  match self.synthesize_frame_num_gaps(sh, sps, is_idr) {
    Ok(_) => ()
    Err(error) => return Err(error)
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
  // Carried state of a pending first field: the recovery point SEI of its
  // access unit and the side data its picture start attached
  // (`h264_frame_start` / `alloc_picture` only run for frame pictures and
  // first fields).
  let mut pending_recovery = -1
  let mut pending_side_data : Array[H264FrameSideData] = []
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
          pending_recovery = pending.sei_recovery_frame_cnt
          pending_side_data = pending.frame.side_data
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
  let mut picture_gray = false
  fn refs_for(header : H264SliceHeader) -> Result[H264SliceRefs, String] {
    let reference_buffers = self.refs.map(fn(entry) {
      (entry.pic.identity, entry.buffer_identity)
    })
    let longs = self.refs
      .filter(fn(entry) { entry.long_index >= 0 })
      .map(fn(entry) { entry.pic.identity })
    if header.slice_type_nos == 1 {
      let result = self.b_references(
        header, sps, current_poc, poc_top, poc_bottom, longs, field_picture, structure,
      )
      if result is Ok(refs) {
        picture_gray = (refs.list0 + refs.list1).any(fn(pic) {
          self.reference_is_gray(pic)
        })
      }
      return result
    }
    if header.slice_type_nos != 0 && header.slice_type_nos != 3 {
      self.non_gray = true
      picture_gray = false
      return Ok({
        list0: [],
        list1: [],
        colocated: [],
        reference_buffers,
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
    picture_gray = list.any(fn(pic) { self.reference_is_gray(pic) })
    Ok({
      list0: list,
      list1: [],
      colocated: [],
      reference_buffers,
      colocated_mbaff: false,
      colocated_field_picture: false,
      long_pocs: longs,
      poc: current_poc,
      poc_top,
      poc_bottom,
    })
  }
  let frame = match
    h264_decode_picture_ex(
      nals, self.ps, refs_for, skip_lf, carry~, conceal_errors=self.conceal_errors,
      er_previous_infos=if self.refs.is_empty() {
        None
      } else {
        Some(self.refs[0].infos)
      },
    ) {
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
        gray=picture_gray,
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
    // `alloc_picture` attaches the AU's LCEVC payload at the picture start;
    // carry it on the pending frame so a pair's output keeps it (an
    // unmatched field drops it with the picture, like the C).
    match self.sei.itut_t35.lcevc {
      Some(lcevc) => {
        frame.side_data.push(Lcevc(lcevc))
        self.sei.itut_t35.lcevc = None
      }
      None => ()
    }
    self.pending_field = Some({
      frame,
      structure,
      frame_num: sh.frame_num,
      poc_top,
      poc_bottom,
      ref_idc: nal.ref_idc,
      identity,
      sei_recovery_frame_cnt: self.sei.recovery_point.recovery_frame_cnt,
    })
    Ok(None)
  } else {
    self.pending_field = None
    // `pic->sei_recovery_frame_cnt` comes from the first field's picture
    // start for a completed pair; frame pictures read the current state.
    frame.sei_recovery_frame_cnt = if paired {
      pending_recovery
    } else {
      self.sei.recovery_point.recovery_frame_cnt
    }
    if paired {
      for k = 0; k < pending_side_data.length(); k = k + 1 {
        frame.side_data.push(pending_side_data[k])
      }
    }
    Ok(
      Some({ ..frame, epoch: self.epoch, poc: if reset { 0 } else { poc_min }, }),
    )
  }
}

///|
/// Decode an Annex B stream (parameter sets plus an I/P/B picture sequence)
/// into frames in decoding order, grouping multiple slices per picture.
/// Complementary PAFF fields are paired before a frame is returned.
/// Slice header fields that delimit a picture. `h264_decode_picture_ex` rejects
/// a group whose slices disagree on them, so the Annex B grouper compares the
/// same set: a slice that differs starts a new picture even when
/// `first_mb_in_slice` is not zero, which happens when the first slices of the
/// picture were lost.
fn h264_same_picture(
  a : H264SliceHeader,
  a_type : Int32,
  a_ref_idc : Int32,
  b : H264SliceHeader,
  b_type : Int32,
  b_ref_idc : Int32,
) -> Bool {
  a.pps_id == b.pps_id &&
  a.frame_num == b.frame_num &&
  a.pic_order_cnt_lsb == b.pic_order_cnt_lsb &&
  a.idr_pic_id == b.idr_pic_id &&
  a.delta_pic_order_cnt_bottom == b.delta_pic_order_cnt_bottom &&
  a.delta_pic_order_cnt == b.delta_pic_order_cnt &&
  a.mmco == b.mmco &&
  a.long_term_reference == b.long_term_reference &&
  a.adaptive_ref_marking == b.adaptive_ref_marking &&
  a.no_output_of_prior_pics == b.no_output_of_prior_pics &&
  a.field_pic_flag == b.field_pic_flag &&
  a.bottom_field_flag == b.bottom_field_flag &&
  a_type == b_type &&
  a_ref_idc == b_ref_idc
}

///|
/// Parse a slice header only to fingerprint its picture. `None` means the
/// header could not be parsed yet (parameter sets still pending), in which case
/// the caller falls back to `first_mb_in_slice == 0`.
fn h264_probe_slice_header(nal : H2645Nal, ps : H264ParamSets) -> H264SliceHeader? {
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(8)
  match ff_h264_decode_slice_header(gb, nal.nal_type, nal.ref_idc, ps) {
    Ok(value) => Some(value)
    Err(_) => None
  }
}

///|
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
  // Fingerprint of the picture being accumulated, used to find its end.
  let mut anchor : H264SliceHeader? = None
  let mut anchor_type = 0
  let mut anchor_ref_idc = 0
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    let slice = nal.nal_type == 1 || nal.nal_type == 5
    let mut new_picture = false
    // Parameter sets must be live before a header probe can succeed. The
    // picture decoder parses the same NALs again when the group is flushed, so
    // this is idempotent.
    if nal.nal_type == h264_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_seq_parameter_set(gb, self.ps, false) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    } else if nal.nal_type == h264_nal_pps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match
        ff_h264_decode_picture_parameter_set(gb, self.ps, gb.size_bits()) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    if slice {
      let probe = h264_probe_slice_header(nal, self.ps)
      match (probe, anchor) {
        (Some(header), Some(current)) =>
          new_picture = !h264_same_picture(
            current,
            anchor_type,
            anchor_ref_idc,
            header,
            nal.nal_type,
            nal.ref_idc,
          )
        _ => {
          let gb = BitReader::with_size(nal.data, nal.size_bits)
          gb.skip(8)
          new_picture = has_slice && gb.read_ue() == 0
        }
      }
      if new_picture {
        match self.decode_nals(pending, skip_lf) {
          Ok(Some(frame)) => frames.push(frame)
          Ok(None) => ()
          Err(error) => return Err(error)
        }
        pending.clear()
        has_slice = false
        anchor = None
      }
      anchor = probe
      anchor_type = nal.nal_type
      anchor_ref_idc = nal.ref_idc
      pending.push(nal)
      has_slice = true
    } else {
      if has_slice &&
        (
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
        anchor = None
      }
      pending.push(nal)
    }
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
