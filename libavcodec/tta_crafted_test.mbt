///|
/// Malformed TTA headers are rejected; valid headers with missing frames fail
/// the seek-table/size checks instead of decoding garbage.

///|
fn tta_test_header(
  format : Int32,
  channels : Int32,
  bps : Int32,
  sample_rate : Int32,
  data_length : UInt32,
) -> Array[Byte] {
  let out : Array[Byte] = [b'T', b'T', b'A', b'1']
  out.push((format & 0xFF).to_byte())
  out.push(((format >> 8) & 0xFF).to_byte())
  out.push((channels & 0xFF).to_byte())
  out.push(((channels >> 8) & 0xFF).to_byte())
  out.push((bps & 0xFF).to_byte())
  out.push(((bps >> 8) & 0xFF).to_byte())
  for i = 0; i < 4; i = i + 1 {
    out.push(((sample_rate.reinterpret_as_uint() >> (8 * i)) & 0xFF).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((data_length >> (8 * i)) & 0xFF).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(b'\x00')
  }
  out
}

///|
test "tta: rejects malformed headers and truncated files" {
  let bad_magic = @libavcodec.ff_tta_decode(b"TTA2")
  assert_true(bad_magic is Err(_))
  let encrypted = Bytes::from_array(tta_test_header(2, 2, 16, 8000, 1000U))
  assert_true(@libavcodec.ff_tta_decode(encrypted) is Err(_))
  let bad_format = Bytes::from_array(tta_test_header(3, 2, 16, 8000, 1000U))
  assert_true(@libavcodec.ff_tta_decode(bad_format) is Err(_))
  let bad_bps = Bytes::from_array(tta_test_header(1, 2, 32, 8000, 1000U))
  assert_true(@libavcodec.ff_tta_decode(bad_bps) is Err(_))
  let bad_rate = Bytes::from_array(tta_test_header(1, 2, 16, 0, 1000U))
  assert_true(@libavcodec.ff_tta_decode(bad_rate) is Err(_))
  let no_frames = Bytes::from_array(tta_test_header(1, 2, 16, 8000, 1000U))
  assert_true(@libavcodec.ff_tta_decode(no_frames) is Err(_))
}
