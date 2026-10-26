///|
/// Substitute segmentation flags in a real header, retaining all later
/// syntax bits. This exercises the parser, including its lossless and
/// qindex derivations, rather than constructing the result under test.
fn av1_segment_header_packet(flags : Array[Int32]) -> Bytes {
  let source = @libavutil.av_base64_decode(av1_segment_inter_payload(), 64).unwrap()
  let bits : Array[Int32] = []
  for i in 0..<72 {
    bits.push((source[i >> 3].to_int() >> (7 - (i & 7))) & 1)
  }
  bits.append(flags)
  for i in 73..<(source.length() * 8) {
    bits.push((source[i >> 3].to_int() >> (7 - (i & 7))) & 1)
  }
  let size = (bits.length() + 7) >> 3
  let bytes : Array[Byte] = [0x32, size.to_byte()]
  for i in 0..<size {
    let mut value = 0
    for j in 0..<8 {
      value = value << 1
      if i * 8 + j < bits.length() {
        value += bits[i * 8 + j]
      }
    }
    bytes.push(value.to_byte())
  }
  Bytes::from_array(bytes)
}

///|
test "primary segmentation data inheritance and map flags" {
  let key = @libavutil.av_base64_decode(av1_segment_key_header(), 64).unwrap()
  let seq = @libavcodec.av1_parse_sequence_header(key).unwrap()
  let base = @libavcodec.av1_parse_frame_header(key, seq).unwrap()
  // Mirror the complete upstream seg_data, including inactive segments,
  // preskip and last_active; derived qindices belong to the new frame.
  let features : Array[Int32] = [1, 1, 1, 1]
  let altq = [-120, -10, 0, 10, 20, 30, 40, 255]
  let put = (value : Int32, width : Int32) => {
    for bit in 0..<width {
      features.push((value >> (width - bit - 1)) & 1)
    }
  }
  for i in 0..<8 {
    put(1, 1)
    put(altq[i], 9)
    for dir in 0..<4 {
      put(1, 1)
      put(i * 4 + dir - 16, 7)
    }
    put(if i == 5 { 1 } else { 0 }, 1)
    if i == 5 {
      put(3, 3)
    }
    put(if i == 6 { 1 } else { 0 }, 1)
    put(if i == 7 { 1 } else { 0 }, 1)
  }
  let defaults = Array::make(
    8,
    @libavcodec.av1_ref_slot_state_from_header(base),
  )
  let prev = @libavcodec.av1_parse_frame_header(
    av1_segment_header_packet(features),
    seq,
    ref_slots=defaults,
  ).unwrap()
  assert_true(prev.segmentation_update_data)
  assert_eq(prev.segmentation_alt_q, altq)
  let saved = @libavcodec.av1_ref_slot_state_from_header(prev)
  let slots = defaults.copy()
  assert_eq(prev.ref_frame_idx[0], 1)
  slots[prev.ref_frame_idx[0]] = saved
  for flags in [[1, 0, 0], [1, 1, 0, 0], [1, 1, 1, 0]] {
    let packet = av1_segment_header_packet(flags)
    let hdr = @libavcodec.av1_parse_frame_header(packet, seq, ref_slots=slots).unwrap()
    assert_eq(hdr.primary_ref_frame, 0)
    assert_eq(hdr.base_q_idx, 120)
    assert_true(hdr.segmentation_enabled)
    assert_eq(hdr.segmentation_update_map, flags[1] != 0)
    assert_eq(
      hdr.segmentation_temporal_update,
      flags.length() == 4 && flags[2] != 0,
    )
    assert_false(hdr.segmentation_update_data)
    assert_true(hdr.seg_preskip)
    assert_eq(hdr.seg_last_active, 7)
    assert_eq(hdr.segmentation_feature_mask, prev.segmentation_feature_mask)
    assert_eq(hdr.segmentation_alt_q, prev.segmentation_alt_q)
    assert_eq(hdr.seg_delta_lf, prev.seg_delta_lf)
    assert_eq(hdr.seg_ref, prev.seg_ref)
    assert_eq(hdr.seg_skip, prev.seg_skip)
    assert_eq(hdr.seg_globalmv, prev.seg_globalmv)
    assert_eq(hdr.seg_qidx, [0, 110, 120, 130, 140, 150, 160, 255])
    assert_true(hdr.seg_lossless[0])
    assert_false(hdr.coded_lossless)
    // Frame-local mutations must not overwrite the retained snapshot.
    hdr.segmentation_alt_q[0] = 99
    hdr.seg_delta_lf[0] = 99
    hdr.seg_ref[5] = 99
    hdr.seg_skip[6] = false
    hdr.seg_globalmv[7] = false
  }
  // The snapshot also owns its input arrays.
  prev.segmentation_alt_q[0] = 99
  let hdr = @libavcodec.av1_parse_frame_header(
    av1_segment_header_packet([1, 0, 0]),
    seq,
    ref_slots=slots,
  ).unwrap()
  assert_eq(hdr.segmentation_alt_q[0], -120)
  assert_eq(hdr.seg_delta_lf[0], -16)
  assert_eq(hdr.seg_ref[5], 3)
  assert_true(hdr.seg_skip[6])
  assert_true(hdr.seg_globalmv[7])
  let incomplete = Array::make(8, @libavcodec.av1_ref_slot_state(0, 160, 120))
  assert_true(
    @libavcodec.av1_parse_frame_header(
      av1_segment_header_packet([1, 0, 0]),
      seq,
      ref_slots=incomplete,
    )
    is Err(_),
  )
}
