///|
/// Escape and length-prefix decoded NALs for an AVC sample, using the same
/// independent bitstream writer as the existing synthetic H.264 regressions.
fn h264_picture_avc_sample(nals : Array[H2645Nal]) -> Bytes {
  let out : Array[Byte] = []
  for nal in nals {
    let escaped = psyn_stream([(nal.nal_type, nal.ref_idc, nal.data[1:].to_owned().to_array())])
    let size = escaped.length() - 4
    for shift in [24, 16, 8, 0] { out.push(((size >> shift) & 255).to_byte()) }
    for i in 4..<escaped.length() { out.push(escaped[i]) }
  }
  Bytes::from_array(out[:])
}

///|
test "h264: AVC multi-slice samples reject overlap/incomplete pictures without changing references" {
  let data = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  let nals = ff_h2645_packet_split(data, 4, H264, false).unwrap().nals
  let parameters = nals.filter(fn(nal) { nal.nal_type == 7 || nal.nal_type == 8 })
  let slices = nals.filter(fn(nal) { nal.nal_type == 1 || nal.nal_type == 5 })
  assert_eq(slices.length(), 18)
  let decoder = new_h264_decoder()
  assert_true(decoder.decode_avc_sample(h264_picture_avc_sample(parameters), 4, false) is Ok(None))
  let overlap = h264_picture_avc_sample([slices[0], slices[0], slices[1], slices[2]])
  assert_true(decoder.decode_avc_sample(overlap, 4, false) is Err("overlapping H.264 slices"))
  assert_eq(decoder.refs.length(), 0)
  let first = decoder.decode_avc_sample(h264_picture_avc_sample([slices[0], slices[1], slices[2]]), 4, false).unwrap().unwrap()
  assert_eq(h264_yuv_md5(first), h264_slices1_md5[0])
  let poc = decoder.prev_poc_lsb
  let frame_num = decoder.prev_frame_num
  let before = decoder.refs.copy()
  let incomplete = h264_picture_avc_sample([slices[3], slices[4]])
  assert_true(decoder.decode_avc_sample(incomplete, 4, false) is Err("incomplete H.264 picture"))
  assert_eq(decoder.prev_poc_lsb, poc)
  assert_eq(decoder.prev_frame_num, frame_num)
  assert_eq(decoder.refs.length(), before.length())
  for i in 0..<before.length() { assert_eq(decoder.refs[i].pic.y, before[i].pic.y) }
  let second = decoder.decode_avc_sample(h264_picture_avc_sample([slices[3], slices[4], slices[5]]), 4, false).unwrap().unwrap()
  assert_eq(h264_yuv_md5(second), h264_slices1_md5[1])
}

///|
test "h264: original C CABAC PCM escapes reconstruct both macroblocks" {
  let data = @libavutil.av_base64_decode(h264_pcm_escape_b64, 10000).unwrap()
  let frame = h264_decode_annexb_frames(data, true).unwrap()[0]
  assert_eq(frame.width, 32)
  assert_eq(frame.y[0], 20)
  assert_eq(frame.y[16], 40)
  assert_eq(frame.y[15], 35)
  assert_eq(frame.y[31], 55)
  assert_eq(h264_yuv_md5(frame), h264_pcm_escape_unf_md5[0])
}
