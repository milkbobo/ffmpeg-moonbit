///|
/// DPB/history expectations follow FFmpeg 9.0.2 h264_field_start and
/// ff_h264_execute_ref_pic_marking; pixel goldens live in the realdata file.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
fn h264_gap_seed(source : Bytes) -> (H264Decoder, H264SliceHeader, H264Sps) {
  let data = @libavutil.av_base64_decode(source, 1000000).unwrap()
  let dec = new_h264_decoder()
  let slices : Array[H2645Nal] = []
  for nal in ff_h2645_packet_split(data, 4, H264, false).unwrap().nals {
    if nal.nal_type == 5 {
      ignore(dec.decode_nals([nal], false).unwrap())
    } else if nal.nal_type == 1 {
      slices.push(nal)
    } else {
      ignore(dec.decode_nals([nal], false).unwrap())
    }
  }
  let gb = BitReader::with_size(slices[0].data, slices[0].size_bits)
  gb.skip(8)
  let sh = ff_h264_decode_slice_header(gb, 1, slices[0].ref_idc, dec.ps).unwrap()
  (dec, sh, dec.ps.sps_list[sh.sps_id].unwrap())
}

///|
fn h264_gap_decode_state(source : Bytes) -> (H264Decoder, Array[H264Frame]) {
  let dec = new_h264_decoder()
  let frames = dec
    .decode_annexb(@libavutil.av_base64_decode(source, 1000000).unwrap(), false)
    .unwrap()
  (dec, frames)
}

///|
test "h264 gaps: references have distinct numbers and shared buffer identity" {
  let (dec, sh, sps) = h264_gap_seed(gap_poc2_b64())
  let original = dec.refs[0]
  let serial = dec.picture_serial
  let poc = dec.prev_poc_lsb
  dec.synthesize_frame_num_gaps(sh, sps, false).unwrap()
  assert_eq(dec.refs.map(fn(entry) { entry.frame_num }), [2, 1, 0])
  assert_eq(dec.prev_frame_num, 2)
  assert_eq(dec.picture_serial, serial + 2)
  assert_eq(dec.prev_poc_lsb, poc)
  assert_eq(dec.refs[0].pic.poc, original.pic.poc + 4)
  assert_eq(dec.refs[1].pic.field_poc_top, 2147483647)
  assert_eq(dec.refs[1].pic.field_poc_bottom, 2147483647)
  for gap in dec.refs[:2] {
    assert_true(gap.pic.identity != original.pic.identity)
    assert_eq(gap.buffer_identity, original.buffer_identity)
    assert_eq(gap.pic.y, original.pic.y)
    assert_true(gap.infos.all(fn(info) { info.mb_type_bits == 0 }))
    assert_false(gap.gray)
    assert_false(gap.invalid_gap)
  }
  // Local arrays do not alias even though deblocking preserves C's buffer
  // equivalence. Mutating a concealed picture must not corrupt its source.
  let first = original.pic.y[0]
  dec.refs[0].pic.y[0] = first ^ 1
  assert_eq(original.pic.y[0], first)
  assert_eq(dec.refs[1].pic.y[0], first)
  dec.synthesize_frame_num_gaps(sh, sps, false).unwrap()
  assert_eq(dec.picture_serial, serial + 2)
}

///|
test "h264 gaps: large and wrapped gaps allocate at most DPB capacity" {
  let (dec, sh, sps) = h264_gap_seed(gap_large_b64())
  let serial = dec.picture_serial
  dec.synthesize_frame_num_gaps(sh, sps, false).unwrap()
  assert_eq(dec.refs.map(fn(entry) { entry.frame_num }), [11, 10, 9, 8])
  assert_eq(dec.picture_serial, serial + 4)
  let (wide, header, params) = h264_gap_seed(gap_large_b64())
  wide
  .synthesize_frame_num_gaps(
    { ..header, frame_num: 65535, },
    { ..params, log2_max_frame_num: 16, },
    false,
  )
  .unwrap()
  assert_eq(wide.refs.map(fn(entry) { entry.frame_num }), [
    65534, 65533, 65532, 65531,
  ])
  assert_eq(wide.picture_serial, serial + 4)
  let (wrap, header, params) = h264_gap_seed(gap_large_b64())
  wrap.prev_frame_num = 14
  wrap.prev_frame_num_offset = 32
  wrap
  .synthesize_frame_num_gaps({ ..header, frame_num: 1, }, params, false)
  .unwrap()
  assert_eq(wrap.refs[0].frame_num, 0)
  assert_eq(wrap.refs[1].frame_num, 15)
  assert_eq(wrap.prev_frame_num, 0)
  assert_eq(wrap.prev_frame_num_offset, 32)
}

///|
test "h264 gaps: disallowed gaps expire while allowed gaps remain referenceable" {
  let (invalid, _) = h264_gap_decode_state(gap_invalid_b64())
  assert_eq(invalid.refs.map(fn(entry) { entry.frame_num }), [7, 0])
  let (valid, _) = h264_gap_decode_state(gap_valid_aging_b64())
  assert_eq(valid.refs.map(fn(entry) { entry.frame_num }), [7, 2, 1, 0])
  assert_true(valid.refs.all(fn(entry) { !entry.invalid_gap }))
}

///|
test "h264 gaps: gray starts use bit-depth midpoint and yield to a non-gray default" {
  for
    (source, midpoint) in [
      (gap_gray8_b64(), 128),
      (gap_gray10_b64(), 512),
      (gap_gray44412_b64(), 2048),
    ] {
    let (dec, frames) = h264_gap_decode_state(source)
    assert_eq(frames.length(), 2)
    assert_false(dec.non_gray)
    assert_true(dec.refs.all(fn(entry) { entry.gray }))
    assert_true(frames[0].y.all(fn(sample) { sample == midpoint }))
    assert_true(frames[0].u.all(fn(sample) { sample == midpoint }))
    assert_true(frames[0].v.all(fn(sample) { sample == midpoint }))
  }
  let (dec, frames) = h264_gap_decode_state(gap_gray_reorder_b64())
  assert_true(dec.non_gray)
  assert_true(dec.refs.any(fn(entry) { entry.frame_num == 3 && entry.gray }))
  assert_false(dec.refs[0].gray)
  // Reordering names the older gray picture, but noref_gray replaces it
  // with the default I picture (goldens were decoded by original FFmpeg).
  assert_eq(h264_yuv_md5(frames[2]), gap_gray_reorder_md5[2])
}

///|
test "h264 gaps: a pending PAFF field suppresses synthesis" {
  let (dec, sh, sps) = h264_gap_seed(gap_paff_b64())
  assert_true(dec.pending_field is Some(_))
  let serial = dec.picture_serial
  let count = dec.refs.length()
  dec.synthesize_frame_num_gaps(sh, sps, false).unwrap()
  assert_eq(dec.picture_serial, serial)
  assert_eq(dec.refs.length(), count)
  let (_, frames) = h264_gap_decode_state(gap_paff_b64())
  assert_eq(frames.length(), 3)
}

///|
test "h264 gaps: IDR and MMCO5 reset reference history without outputting dummies" {
  let (idr, frames) = h264_gap_decode_state(gap_idr_b64())
  assert_eq(frames.length(), 4)
  assert_eq(frames.map(fn(frame) { frame.epoch }), [0, 0, 1, 1])
  assert_true(idr.refs.all(fn(entry) { entry.buffer_identity != 1 }))
  let (reset, frames) = h264_gap_decode_state(gap_mmco5_b64())
  assert_eq(frames.map(fn(frame) { frame.poc }), [0, 0, 2, 8])
  assert_eq(frames.map(fn(frame) { frame.epoch }), [0, 1, 1, 1])
  assert_eq(reset.prev_frame_num, 4)
}

///|
test "h264 gaps: failed AVC picture rolls back dummy DPB and frame history before retry" {
  let data = @libavutil.av_base64_decode(gap_real_cabac_b64(), 1000000).unwrap()
  let nals = ff_h2645_packet_split(data, 4, H264, false).unwrap().nals
  let parameters = nals.filter(fn(nal) {
    nal.nal_type == 7 || nal.nal_type == 8
  })
  let slices = nals.filter(fn(nal) { nal.nal_type == 1 || nal.nal_type == 5 })
  let dec = new_h264_decoder()
  ignore(
    dec
    .decode_avc_sample(h264_picture_avc_sample(parameters), 4, false)
    .unwrap(),
  )
  ignore(
    dec
    .decode_avc_sample(h264_picture_avc_sample(slices[:3].to_owned()), 4, false)
    .unwrap(),
  )
  let references = dec.refs.map(fn(entry) {
    (entry.pic.identity, entry.frame_num, entry.buffer_identity)
  })
  let history = (
    dec.picture_serial,
    dec.prev_frame_num,
    dec.prev_frame_num_offset,
    dec.prev_poc_lsb,
  )
  let result = dec.decode_avc_sample(
    h264_picture_avc_sample(slices[3:5].to_owned()),
    4,
    false,
  )
  assert_true(result is Err("incomplete H.264 picture"))
  assert_eq(
    dec.refs.map(fn(entry) {
      (entry.pic.identity, entry.frame_num, entry.buffer_identity)
    }),
    references,
  )
  assert_eq(
    (
      dec.picture_serial,
      dec.prev_frame_num,
      dec.prev_frame_num_offset,
      dec.prev_poc_lsb,
    ),
    history,
  )
  let frame = dec
    .decode_avc_sample(
      h264_picture_avc_sample(slices[3:6].to_owned()),
      4,
      false,
    )
    .unwrap()
    .unwrap()
  assert_eq(h264_yuv_md5(frame), gap_real_cabac_md5[1])
}
