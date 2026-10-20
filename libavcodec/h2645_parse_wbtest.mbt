///|
/// White-box tests for the H.264/HEVC NAL splitter.
///
/// Synthetic layouts follow ITU-T H.264 §B.1.1 (Annex B byte stream, NAL
/// header 1 byte) and ITU-T H.265 §B.2.1 (NAL header 2 bytes); the
/// emulation-prevention rule is H.264 §7.4.1 / H.265 §7.4.2. SODB sizes are
/// hand-derived from `get_bit_length` (remove trailing zero bytes, then the
/// stop bit and its trailing zeros).
test "h2645: rbsp removes emulation prevention bytes" {
  let r = ff_h2645_extract_rbsp(b"\x67\x42\x00\x00\x03\x1E\x80")
  assert_eq(r.consumed, 7)
  assert_eq(r.skipped, 1)
  assert_eq(r.data, b"\x67\x42\x00\x00\x1E\x80")
}

///|
test "h2645: rbsp without escapes is unchanged" {
  let r = ff_h2645_extract_rbsp(b"\x67\x42\x00\x1E")
  assert_eq(r.consumed, 4)
  assert_eq(r.skipped, 0)
  assert_eq(r.data, b"\x67\x42\x00\x1E")
}

///|
test "h2645: rbsp stops in front of a later start code" {
  // 67 42 [00 00 03] 1E | 00 00 01 68 CE 80
  let r = ff_h2645_extract_rbsp(b"\x67\x42\x00\x00\x03\x1E\x00\x00\x01\x68\xCE")
  assert_eq(r.consumed, 6)
  assert_eq(r.skipped, 1)
  assert_eq(r.data, b"\x67\x42\x00\x00\x1E")
}

///|
test "h2645: get_bit_length removes stop bit and trailing zeros" {
  // 1-byte NAL header, last byte 0x1E = ...1 1110: stop bit at bit 3 (LSB
  // numbering from the end) → 1 zero + the stop bit removed.
  assert_eq(get_bit_length(b"\x67\x42\x00\x1E", 1, true), 30)
  // 0x80: stop bit only, 7 trailing zeros removed with it.
  assert_eq(get_bit_length(b"\x68\xCE\x80", 1, true), 16)
  // skip_trailing_zeros=false keeps zero bytes: 0x1E still gives -2.
  assert_eq(get_bit_length(b"\x67\x00\x1E", 1, false), 22)
  // ...and a zero final byte contributes no stop-bit padding.
  assert_eq(get_bit_length(b"\x67\x00\x00", 1, false), 24)
  // too short for the codec's NAL header
  assert_eq(get_bit_length(b"\x67", 2, true), -1)
}

///|
test "h2645: Annex B splits two NAL units" {
  let buf = b"\x00\x00\x00\x01\x67\x42\x00\x1E\x00\x00\x01\x68\xCE\x80"
  let pkt = ff_h2645_packet_split(buf, 4, H264, false).unwrap()
  assert_eq(pkt.nals.length(), 2)
  assert_eq(pkt.nals[0].nal_type, 7)
  assert_eq(pkt.nals[0].ref_idc, 3)
  assert_eq(pkt.nals[0].data, b"\x67\x42\x00\x1E")
  assert_eq(pkt.nals[0].size_bits, 30)
  assert_eq(pkt.nals[1].nal_type, 8)
  assert_eq(pkt.nals[1].data, b"\x68\xCE\x80")
  assert_eq(pkt.nals[1].size_bits, 16)
}

///|
test "h2645: Annex B skips leading garbage" {
  let buf = b"\x12\x34\x00\x00\x01\x67\x42\x00\x1E\x00\x00\x01\x68\xCE\x80"
  let pkt = ff_h2645_packet_split(buf, 4, H264, false).unwrap()
  assert_eq(pkt.nals.length(), 2)
  assert_eq(pkt.nals[0].nal_type, 7)
}

///|
test "h2645: Annex B without a start code is invalid" {
  let pkt = ff_h2645_packet_split(b"\x12\x34\x56\x78\x9A", 4, H264, false)
  match pkt {
    Err(e) => assert_eq(e, "EINVAL")
    Ok(_) => assert_true(false)
  }
}

///|
test "h2645: length-prefixed H.264 NALs" {
  // 2-byte lengths: 4 and 3
  let buf = b"\x00\x04\x67\x42\x00\x1E\x00\x03\x68\xCE\x80"
  let pkt = ff_h2645_packet_split(buf, 2, H264, true).unwrap()
  assert_eq(pkt.nals.length(), 2)
  assert_eq(pkt.nals[0].nal_type, 7)
  assert_eq(pkt.nals[1].nal_type, 8)
  assert_eq(pkt.nals[1].data, b"\x68\xCE\x80")
}

///|
test "h2645: length-prefixed NAL size overruns are rejected" {
  let buf = b"\x00\x09\x67\x42\x00\x1E"
  match ff_h2645_packet_split(buf, 2, H264, true) {
    Err(e) => assert_eq(e, "EINVAL")
    Ok(_) => assert_true(false)
  }
}

///|
test "h2645: HEVC NAL header (type/layer/temporal id)" {
  // 40 01 = forbidden 0, type 32 (VPS), layer 0, temporal_id_plus1 1.
  // 42 01 = type 33 (SPS), 44 01 = type 34 (PPS).
  let buf = b"\x00\x00\x01\x40\x01\x0C\x01\xFF\x00\x00\x01\x42\x01\x01\x60" +
    b"\x00\x00\x01\x44\x01\xC0\xF1\x80"
  let pkt = ff_h2645_packet_split(buf, 4, Hevc, false).unwrap()
  assert_eq(pkt.nals.length(), 3)
  assert_eq(pkt.nals[0].nal_type, 32)
  assert_eq(pkt.nals[0].nuh_layer_id, 0)
  assert_eq(pkt.nals[0].temporal_id, 0)
  assert_eq(pkt.nals[1].nal_type, 33)
  assert_eq(pkt.nals[2].nal_type, 34)
}

///|
test "h2645: HEVC temporal_id 0 is invalid (plus1 == 0)" {
  // 40 00: temporal_id_plus1 = 0
  let buf = b"\x00\x00\x01\x40\x00\x00\x00\x01\x40\x01\x0C\x01\xFF"
  let pkt = ff_h2645_packet_split(buf, 4, Hevc, false).unwrap()
  // the invalid first NAL is skipped, the valid one kept
  assert_eq(pkt.nals.length(), 1)
  assert_eq(pkt.nals[0].nal_type, 32)
}

///|
test "h2645: unit requires zero byte" {
  assert_true(ff_h2645_unit_requires_zero_byte(H264, 1, 0))
  assert_true(!ff_h2645_unit_requires_zero_byte(H264, 1, 1))
  assert_true(ff_h2645_unit_requires_zero_byte(H264, 7, 2))
  assert_true(ff_h2645_unit_requires_zero_byte(H264, 8, 2))
  assert_true(!ff_h2645_unit_requires_zero_byte(H264, 5, 2))
  assert_true(ff_h2645_unit_requires_zero_byte(Hevc, 32, 3))
  assert_true(!ff_h2645_unit_requires_zero_byte(Hevc, 39, 3))
}
