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
fn h264_truncate_annexb_slice(data : Bytes, target : Int32) -> Bytes {
  let starts : Array[(Int32, Int32)] = []
  for i = 0; i + 3 <= data.length(); i = i + 1 {
    if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
      starts.push((if i > 0 && data[i - 1] == 0 { i - 1 } else { i }, i + 3))
    }
  }
  starts.push((data.length(), data.length()))
  let out : Array[Byte] = []
  let mut slice_number = 0
  for i = 0; i + 1 < starts.length(); i = i + 1 {
    let kind = data[starts[i].1].to_int() & 31
    let end = if (kind == 1 || kind == 5) && slice_number == target {
      starts[i].0 + (starts[i + 1].0 - starts[i].0) * 3 / 4
    } else {
      starts[i + 1].0
    }
    for j = starts[i].0; j < end; j = j + 1 { out.push(data[j]) }
    if kind == 1 || kind == 5 { slice_number += 1 }
  }
  Bytes::from_array(out[:])
}

///|
fn h264_drop_annexb_nal(data : Bytes, target : Int32) -> Bytes {
  let starts : Array[Int32] = []
  for i = 0; i + 3 <= data.length(); i = i + 1 {
    if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
      starts.push(if i > 0 && data[i - 1] == 0 { i - 1 } else { i })
    }
  }
  starts.push(data.length())
  let out : Array[Byte] = []
  for i = 0; i + 1 < starts.length(); i = i + 1 {
    if i != target {
      for j = starts[i]; j < starts[i + 1]; j = j + 1 { out.push(data[j]) }
    }
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
test "h264: progressive missing slices use spatial or temporal concealment" {
  let data = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  let nals = ff_h2645_packet_split(data, 4, H264, false).unwrap().nals
  let parameters = nals.filter(fn(nal) { nal.nal_type == 7 || nal.nal_type == 8 })
  let slices = nals.filter(fn(nal) { nal.nal_type == 1 || nal.nal_type == 5 })
  let dec = new_h264_decoder()
  dec.set_error_concealment(true)
  ignore(dec.decode_avc_sample(h264_picture_avc_sample(parameters), 4, false).unwrap())
  let first = dec.decode_avc_sample(
    h264_picture_avc_sample([slices[0], slices[2]]), 4, false,
  ).unwrap().unwrap()
  assert_true(first.damaged_macroblocks > 0)
  assert_eq(h264_yuv_md5(first), "f2000c094cc46f3fd48b801afc7751ae")
  assert_true(first.damaged_macroblocks < first.infos.length())
  let second = dec.decode_avc_sample(
    h264_picture_avc_sample([slices[3], slices[4]]), 4, false,
  ).unwrap().unwrap()
  assert_true(second.damaged_macroblocks > 0)
  let gb = BitReader::with_size(slices[5].data, slices[5].size_bits)
  gb.skip(8)
  let missing_start = gb.read_ue()
  let x = (missing_start % (second.ystride / 16)) * 16 + 8
  let y = (missing_start / (second.ystride / 16)) * 16 + 8
  let offset = y * second.ystride + x
  assert_eq(second.y[offset], first.y[offset])
  assert_eq(dec.prev_frame_num, 1)
  let leading = new_h264_decoder()
  leading.set_error_concealment(true)
  ignore(
    leading
    .decode_avc_sample(h264_picture_avc_sample(parameters), 4, false)
    .unwrap(),
  )
  let leading_gap = leading.decode_avc_sample(
    h264_picture_avc_sample([slices[1], slices[2]]), 4, false,
  ).unwrap().unwrap()
  assert_true(leading_gap.damaged_macroblocks > 0)
}

///|
test "h264: truncated P slice keeps decoded macroblocks and conceals the rest" {
  let data = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  let nals = ff_h2645_packet_split(data, 4, H264, false).unwrap().nals
  let parameters = nals.filter(fn(nal) { nal.nal_type == 7 || nal.nal_type == 8 })
  let slices = nals.filter(fn(nal) { nal.nal_type == 1 || nal.nal_type == 5 })
  let dec = new_h264_decoder()
  dec.set_error_concealment(true)
  ignore(dec.decode_avc_sample(h264_picture_avc_sample(parameters), 4, false).unwrap())
  let first = dec.decode_avc_sample(
    h264_picture_avc_sample(slices[:3].to_owned()), 4, false,
  ).unwrap().unwrap()
  assert_eq(first.damaged_macroblocks, 0)
  assert_eq(h264_yuv_md5(first), h264_slices1_md5[0])
  let source = slices[5]
  let short_data = source.data[:source.data.length() * 3 / 4].to_owned()
  let damaged : H2645Nal = {
    ..source,
    data: short_data,
    size_bits: short_data.length() * 8,
  }
  let second = dec.decode_avc_sample(
    h264_picture_avc_sample([slices[3], slices[4], damaged]), 4, false,
  ).unwrap().unwrap()
  assert_true(second.damaged_macroblocks > 0)
  assert_true(second.damaged_macroblocks < second.infos.length())
  assert_eq(dec.prev_frame_num, 1)
}

///|
test "h264: Annex B truncated P slice matches FFmpeg 9.0.2 recovery" {
  let source = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  let damaged = h264_truncate_annexb_slice(source, 5)
  let dec = new_h264_decoder()
  dec.set_error_concealment(true)
  let frames = dec.decode_annexb(damaged, false).unwrap()
  assert_eq(frames.length(), 6)
  let expected = [
    "b4fb3105bb8ab58dc1205e07761b4c15",
    "6aa75a1271a4325296c00a318bf8b9ef",
    "fcac29de986b09107e0d2998fdccf063",
    "cc9d77072e71b75f6147f6c952ac3030",
    "02469a7f9e019d64583a69588db0e3eb",
    "cfb063482f8b5263ca288f95c8379162",
  ]
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(h264_yuv_md5(frames[i]), expected[i])
  }
}

///|
test "h264: damaged slice recovery follows FFmpeg 9.0.2 across six frames" {
  let data = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  let nals = ff_h2645_packet_split(data, 4, H264, false).unwrap().nals
  let parameters = nals.filter(fn(nal) { nal.nal_type == 7 || nal.nal_type == 8 })
  let slices = nals.filter(fn(nal) { nal.nal_type == 1 || nal.nal_type == 5 })
  let expected_i = [
    "f2000c094cc46f3fd48b801afc7751ae",
    "7897003d89fb85b5c49586ecc4b9a2fd",
    "a93556815dfee312edf32d7d3f450bec",
    "ff4a7a346d5da0783fe3ee9a9cc07df8",
    "8cb40eaeaf0f4383cc6e80f82857462b",
    "4f06f66b138d79152ea332d61de5e1ac",
  ]
  let expected_p = [
    "b4fb3105bb8ab58dc1205e07761b4c15",
    "6aa75a1271a4325296c00a318bf8b9ef",
    "fcac29de986b09107e0d2998fdccf063",
    "cc9d77072e71b75f6147f6c952ac3030",
    "02469a7f9e019d64583a69588db0e3eb",
    "cfb063482f8b5263ca288f95c8379162",
  ]
  for mode = 0; mode < 2; mode = mode + 1 {
    let dec = new_h264_decoder()
    dec.set_error_concealment(true)
    ignore(dec.decode_avc_sample(h264_picture_avc_sample(parameters), 4, false).unwrap())
    for picture = 0; picture < 6; picture = picture + 1 {
      let group = slices[picture * 3:picture * 3 + 3].to_owned()
      let kept = if mode == 0 && picture == 0 {
        [group[0], group[2]]
      } else if mode == 1 && picture == 1 {
        [group[0], group[1]]
      } else {
        group
      }
      let frame = dec.decode_avc_sample(
        h264_picture_avc_sample(kept), 4, false,
      ).unwrap().unwrap()
      assert_eq(
        h264_yuv_md5(frame),
        if mode == 0 { expected_i[picture] } else { expected_p[picture] },
      )
    }
  }
}

///|
test "h264: missing B slice matches FFmpeg 9.0.2 display output" {
  let source = @libavutil.av_base64_decode(
    h264_b_slices_cabac_b64, 1000000,
  ).unwrap()
  let damaged = h264_drop_annexb_nal(source, 10)
  let dec = new_h264_decoder()
  dec.set_error_concealment(true)
  let frames = h264_display_order(dec.decode_annexb(damaged, false).unwrap())
  let expected = [
    "7f7ae5343ecab3499625f3701786b3e8",
    "6cab5a4a38dc57cbe77f192052560ded",
    "31820dd76504c35036d70edc86a425a9",
    "a7886041489f4a6d01b734757975482d",
    "f54ec40a3c06c39f53d5d13201a34d24",
    "9c69bb0879bc47704f0970c62292d77c",
    "8590289688a5c796b61d6a101c79846c",
    "4e0e3a7c386fb5f4dc2069db81ae7806",
    "b2b33b8842d9e33faf97ecdbb8637525",
    "ec3069c2cb1d633286e5d7a586cd31f3",
    "eba2efc695310dfc6fc52711429b6a7b",
    "75d51e8d2911d6c9b66e6d2ff3f3156b",
    "be2308c9d9eca671ee10b1b1df36040c",
  ]
  assert_eq(frames.length(), expected.length())
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(h264_yuv_md5(frames[i]), expected[i])
  }
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
