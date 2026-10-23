///|
/// frame_num-gap synthesis from FFmpeg 9.0.2 h264_slice.c:h264_field_start
/// and h264_refs.c:ff_h264_execute_ref_pic_marking. Synthetic pictures enter
/// the DPB but are never returned as output frames. Pixel storage is copied
/// instead of aliasing the C's refcounted AVFrame buffers.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
fn H264Decoder::synthesize_frame_num_gaps(
  self : H264Decoder,
  sh : H264SliceHeader,
  sps : H264Sps,
  idr : Bool,
) -> Result[Unit, String] {
  if idr {
    return Ok(())
  }
  let max_frame = 1 << sps.log2_max_frame_num
  if sh.frame_num != self.prev_frame_num {
    let previous = if self.prev_frame_num > sh.frame_num {
      self.prev_frame_num - max_frame
    } else {
      self.prev_frame_num
    }
    if sh.frame_num - previous > sps.ref_frame_count {
      self.prev_frame_num = (sh.frame_num - sps.ref_frame_count - 1 + max_frame) &
        (max_frame - 1)
    }
  }
  // h->first_field suppresses the loop even when that pending field will
  // turn out to be unmatched. Complementary fields never invent a frame.
  if self.pending_field is Some(_) {
    return Ok(())
  }
  let field = sh.field_pic_flag != 0
  let structure = if field { sh.bottom_field_flag + 1 } else { 3 }
  while sh.frame_num != self.prev_frame_num &&
        sh.frame_num != ((self.prev_frame_num + 1) & (max_frame - 1)) {
    let previous : H264DpbEntry? = self.refs
      .search_by(fn(entry) { entry.long_index < 0 })
      .map(fn(index) { self.refs[index] })
    let number = (self.prev_frame_num + 1) & (max_frame - 1)
    let width = sps.mb_width * 16
    let height = sps.mb_height * 16
    let hshift = if sps.chroma_format_idc <= 2 { 1 } else { 0 }
    let vshift = if sps.chroma_format_idc <= 1 { 1 } else { 0 }
    let cwidth = width >> hshift
    let cheight = height >> vshift
    let compatible = match previous {
      Some(entry) =>
        entry.pic.width == width &&
        entry.pic.height == height &&
        entry.bit_depth == sps.bit_depth_luma &&
        entry.chroma_format == sps.chroma_format_idc
      None => false
    }
    let neutral = 1 << (sps.bit_depth_luma - 1)
    let (y, u, v, poc, gray) = if compatible && previous is Some(entry) {
      (
        entry.pic.y.copy(),
        entry.pic.u.copy(),
        entry.pic.v.copy(),
        entry.pic.poc + 2,
        entry.gray,
      )
    } else {
      (
        Array::make(width * height, neutral),
        Array::make(cwidth * cheight, neutral),
        Array::make(cwidth * cheight, neutral),
        0,
        true,
      )
    }
    self.picture_serial += 1
    let buffer_identity = if compatible && previous is Some(entry) {
      entry.buffer_identity
    } else {
      self.picture_serial
    }
    let pic : H264RefPic = {
      identity: self.picture_serial,
      y,
      u,
      v,
      ystride: width,
      cstride: cwidth,
      width,
      height,
      cwidth,
      cheight,
      poc,
      field_poc_top: 2147483647,
      field_poc_bottom: 2147483647,
      base_y: 0,
      base_u: 0,
      base_v: 0,
      parity: 0,
    }
    // AVFrame concealment copies pixels, not the previous picture's motion
    // history. Fresh zero motion/cache data must not masquerade as that MB.
    let infos = [
      for _ in 0..<(sps.mb_width * sps.mb_height) => {
        let info = h264_new_mb_info()
        for block in 0..<16 {
          info.ref_idx[block] = 0
          info.ref_idx1[block] = 0
        }
        info
      }
    ]
    let dummy = {
      ..sh,
      frame_num: number,
      adaptive_ref_marking: false,
      mmco: [],
      long_term_reference: false,
    }
    match
      self.mark_reference(
        pic,
        infos,
        dummy,
        sps,
        false,
        field,
        structure,
        false,
        gray~,
        invalid_gap=sps.gaps_in_frame_num_allowed_flag == 0,
        aging_frame_num=Some(sh.frame_num),
        buffer_identity=Some(buffer_identity),
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    // Do not advance POC/frame_num_offset as if the missing picture had
    // actually been decoded; h264_field_start advances only prev_frame_num.
    self.prev_frame_num = number
  }
  Ok(())
}

///|
fn H264Decoder::reference_is_gray(self : H264Decoder, pic : H264RefPic) -> Bool {
  self.refs.any(fn(entry) { entry.pic.identity == pic.identity && entry.gray })
}
