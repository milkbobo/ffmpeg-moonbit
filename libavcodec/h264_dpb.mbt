///|
/// MoonBit port of the H.264 decoded picture buffer bookkeeping needed for
/// P-picture decoding, after FFmpeg 9.0.2 `libavcodec/h264dec.c` /
/// `h264_slice.c` (`ff_h264_execute_ref_pic_marking`'s sliding window and
/// the default `ff_h264_build_ref_list0` ordering) plus the POC type 0/2
/// tracking from `h264_slice.c: h264_field_start` / `ff_h264_init_poc`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: I/P reference management only — no B pictures, no MMCO adaptive
/// marking (the syntax is consumed by the slice header parser and ignored),
/// no long-term references, no reordering of the output order.

///|
/// One short-term reference entry: POC plus the picture planes. */
struct H264DpbEntry {
  poc : Int32
  pic : H264RefPic
}

///|
/// Decoder state across pictures: the parameter sets and the sliding-window
/// short-term reference buffer.
pub struct H264Decoder {
  /// Parameter sets, updated by in-band SPS/PPS NALs.
  ps : H264ParamSets
  refs : Array[H264DpbEntry]
  /// `PrevPicOrderCntMsb` / `PrevPicOrderCntLsb` (POC type 0).
  mut prev_poc_msb : Int32
  mut prev_poc_lsb : Int32
  /// `PrevRefFrameNum` (POC type 2 / sliding window).
  mut prev_frame_num : Int32
}

///|
/// Create a decoder with an empty reference buffer. */
pub fn new_h264_decoder() -> H264Decoder {
  {
    ps: new_h264_param_sets(),
    refs: [],
    prev_poc_msb: 0,
    prev_poc_lsb: 0,
    prev_frame_num: 0,
  }
}

///|
/// The default L0 list for a P picture with no reordering syntax: the
/// short-term references in decreasing POC order (most recent first).
fn H264Decoder::ref_list0(
  self : H264Decoder,
  count : Int32,
) -> Array[H264RefPic] {
  let entries = [..self.refs]
  // Highest POC first (`ff_h264_build_ref_list0`'s default ordering).
  entries.sort_by((a, b) => b.poc.compare(a.poc))
  let list : Array[H264RefPic] = []
  for i = 0; i < entries.length() && i < count; i = i + 1 {
    list.push(entries[i].pic)
  }
  list
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
  let mut frame : H264Frame? = None
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
      if frame is Some(_) {
        return Err("multi-slice pictures are not supported")
      }
      frame = Some(
        match self.decode_slice(nal, skip_lf) {
          Ok(v) => v
          Err(e) => return Err(e)
        },
      )
    }
  }
  Ok(frame)
}

///|
/// Decode one coded slice and run the reference marking: IDR clears the
/// buffer (`no_output_of_prior_pics_flag` ignored), other reference pictures
/// enter it and the sliding window (`sps.ref_frame_count`) trims the oldest.
fn H264Decoder::decode_slice(
  self : H264Decoder,
  nal : H2645Nal,
  skip_lf : Bool,
) -> Result[H264Frame, String] {
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
  let mut poc = 0
  if sps.poc_type == 0 {
    let max_lsb = 1 << sps.log2_max_poc_lsb
    let lsb = sh.pic_order_cnt_lsb
    let mut msb = self.prev_poc_msb
    if lsb < self.prev_poc_lsb && self.prev_poc_lsb - lsb >= max_lsb / 2 {
      msb = msb + max_lsb
    } else if lsb > self.prev_poc_lsb && lsb - self.prev_poc_lsb > max_lsb / 2 {
      msb = msb - max_lsb
    }
    poc = msb + lsb
  } else if sps.poc_type == 2 {
    poc = 2 * sh.frame_num
  } else {
    return Err("POC type 1 is not supported")
  }
  if is_idr {
    poc = 0
    self.refs.clear()
    self.prev_poc_msb = 0
    self.prev_poc_lsb = 0
    self.prev_frame_num = 0
  }
  let refs = if sh.slice_type_nos == 0 {
    let list = self.ref_list0(sh.num_ref_idx_l0_active)
    if list.length() == 0 {
      return Err("no reference picture for a P slice")
    }
    list
  } else {
    []
  }
  let frame = match h264_decode_slice_ex(nal, self.ps, refs, skip_lf) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Reference marking (`ff_h264_execute_ref_pic_marking`, sliding window;
  // adaptive MMCO commands were consumed by the header parser and ignored).
  if nal.ref_idc != 0 {
    let pic : H264RefPic = {
      y: frame.y,
      u: frame.u,
      v: frame.v,
      ystride: frame.ystride,
      cstride: frame.cstride,
      // Plane dimensions (macroblock-aligned), the border-replication
      // bounds of motion compensation.
      width: frame.ystride,
      height: frame.pheight,
    }
    self.refs.insert(0, { poc, pic, })
    while self.refs.length() > sps.ref_frame_count {
      ignore(self.refs.pop())
    }
    self.prev_poc_msb = poc - sh.pic_order_cnt_lsb
    self.prev_poc_lsb = sh.pic_order_cnt_lsb
    self.prev_frame_num = sh.frame_num
  }
  Ok(frame)
}

///|
/// Decode an Annex B stream (parameter sets plus an I/P picture sequence)
/// into frames in decoding order. B slices, multi-slice pictures and
/// interlaced pictures are rejected by the slice decoder.
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
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    if nal.nal_type == h264_nal_sps {
      let g = BitReader::with_size(nal.data, nal.size_bits)
      g.skip(8)
      match ff_h264_decode_seq_parameter_set(g, self.ps, false) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_pps {
      let g = BitReader::with_size(nal.data, nal.size_bits)
      g.skip(8)
      match ff_h264_decode_picture_parameter_set(g, self.ps, g.size_bits()) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_idr_slice || nal.nal_type == 1 {
      frames.push(
        match self.decode_slice(nal, skip_lf) {
          Ok(v) => v
          Err(e) => return Err(e)
        },
      )
    }
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
