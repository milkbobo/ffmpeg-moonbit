///|
/// FFmpeg 9.0.2 h264_parse.c ff_h264_init_poc, frame-picture path.
/// LGPL-2.1-or-later. Int64 intermediates retain C's overflow validation.
fn H264Decoder::picture_order(
  self : H264Decoder,
  sps : H264Sps,
  sh : H264SliceHeader,
  ref_idc : Int32,
  idr : Bool,
) -> Result[(Int32, Int32, Int32, Int32, Int32), String] {
  let max_frame = 1 << sps.log2_max_frame_num
  let offset = if idr {
    0
  } else {
    self.prev_frame_num_offset +
    (if sh.frame_num < self.prev_frame_num { max_frame } else { 0 })
  }
  let mut msb = 0
  let mut top : Int64 = 0L
  let mut bottom : Int64 = 0L
  if sps.poc_type == 0 {
    let max_lsb = 1 << sps.log2_max_poc_lsb
    let previous = if idr { 0 } else { self.prev_poc_lsb }
    msb = if idr { 0 } else { self.prev_poc_msb }
    if sh.pic_order_cnt_lsb < previous &&
      previous - sh.pic_order_cnt_lsb >= max_lsb / 2 {
      msb += max_lsb
    } else if sh.pic_order_cnt_lsb > previous &&
      sh.pic_order_cnt_lsb - previous > max_lsb / 2 {
      msb -= max_lsb
    }
    top = msb.to_int64() + sh.pic_order_cnt_lsb.to_int64()
    bottom = top + sh.delta_pic_order_cnt_bottom.to_int64()
  } else if sps.poc_type == 1 {
    let mut absolute = if sps.poc_cycle_length == 0 {
      0L
    } else {
      offset.to_int64() + sh.frame_num.to_int64()
    }
    if ref_idc == 0 && absolute > 0L {
      absolute -= 1L
    }
    let mut expected = 0L
    if absolute > 0L {
      let cycle = sps.poc_cycle_length.to_int64()
      let mut delta = 0L
      for i in 0..<sps.poc_cycle_length {
        delta += sps.offset_for_ref_frame[i].to_int64()
      }
      expected = (absolute - 1L) / cycle * delta
      for i in 0..<(((absolute - 1L) % cycle).to_int() + 1) {
        expected += sps.offset_for_ref_frame[i].to_int64()
      }
    }
    if ref_idc == 0 {
      expected += sps.offset_for_non_ref_pic.to_int64()
    }
    top = expected + sh.delta_pic_order_cnt[0].to_int64()
    bottom = top +
      sps.offset_for_top_to_bottom_field.to_int64() +
      sh.delta_pic_order_cnt[1].to_int64()
  } else {
    top = 2L * (offset.to_int64() + sh.frame_num.to_int64()) -
      (if ref_idc == 0 { 1L } else { 0L })
    bottom = top
  }
  guard top >= -2147483648L &&
    top <= 2147483647L &&
    bottom >= -2147483648L &&
    bottom <= 2147483647L else {
    return Err("H.264 picture order overflow")
  }
  Ok((top.min(bottom).to_int(), top.to_int(), bottom.to_int(), msb, offset))
}
