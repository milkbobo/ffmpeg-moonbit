///|
fn vp9_display_md5(bytes : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, bytes, bytes.length())
  vp9_kf_hex(digest, 16)
}

///|
fn vp9_display_superframe(frames : Array[Bytes]) -> Bytes {
  let bytes : Array[Byte] = []
  for frame in frames { for byte in frame { bytes.push(byte) } }
  let marker = (0xc8 | (frames.length() - 1)).to_byte()
  bytes.push(marker)
  for frame in frames {
    bytes.push((frame.length() & 255).to_byte())
    bytes.push((frame.length() >> 8).to_byte())
  }
  bytes.push(marker)
  Bytes::from_array(bytes[:])
}

///|
test "vp9 display: all eight slots reproduce the decoded keyframe" {
  let decoder = vp9_decoder_new()
  decoder.decode_frame(vp9_kf_qfull_frames[0]).unwrap()
  // 0x90 = truncated profile-2 keyframe probe; profile 2 headers now parse
  // (10/12-bit support), and this 1-byte packet dies later in the parser
  assert_true(decoder.decode_packet(b"\x90") is Err(_))
  for slot in 0..<8 {
    let packet = Bytes::from_array([(0x88 | slot).to_byte()])
    let frames = decoder.decode_packet(packet).unwrap()
    assert_eq(frames.length(), 1)
    assert_eq(frames[0].width, 64)
    assert_eq(frames[0].height, 48)
    assert_eq(vp9_display_md5(frames[0].data), vp9_kf_qfull_md5[0])
  }
}

///|
test "vp9 display: hidden keyframe refreshes references without output" {
  let hidden = vp9_kf_qfull_frames[0].to_array()
  hidden[0] = (hidden[0].to_int() & 0xfd).to_byte()
  let decoder = vp9_decoder_new()
  assert_eq(decoder.decode_packet(Bytes::from_array(hidden[:])).unwrap().length(), 0)
  let frames = decoder.decode_packet(b"\x8f").unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(vp9_display_md5(frames[0].data), vp9_kf_qfull_md5[0])
  let decoder2 = vp9_decoder_new()
  let packet = vp9_display_superframe([Bytes::from_array(hidden[:]), b"\x88"])
  let frames2 = decoder2.decode_packet(packet).unwrap()
  assert_eq(frames2.length(), 1)
  assert_eq(frames2[0].data, frames[0].data)
}

///|
test "vp9 display: superframe outputs retain their own resized pixels" {
  let decoder = vp9_decoder_new()
  let frames = decoder.decode_packet(vp9_display_superframe([
    vp9_kf_qfull_frames[0], vp9_kf_small_frames[0], b"\x8b",
  ])).unwrap()
  assert_eq(frames.length(), 3)
  assert_eq((frames[0].width, frames[0].height), (64, 48))
  assert_eq(vp9_display_md5(frames[0].data), vp9_kf_qfull_md5[0])
  for i in 1..<3 {
    assert_eq((frames[i].width, frames[i].height), (70, 36))
    assert_eq(vp9_display_md5(frames[i].data), vp9_kf_small_md5[0])
  }
}
