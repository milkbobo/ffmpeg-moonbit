///|
/// Minimal `wvpk` block header builder for the rejection tests.
fn wavpack_test_block(flags : UInt32, samples : UInt32) -> Bytes {
  let out : Array[Byte] = []
  for b in b"wvpk" {
    out.push(b)
  }
  // ckSize = 24: block size 32 (header 32 with no metadata).
  for v in [24U, 0U, 0U, 0U] {
    out.push((v & 0xFFU).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((0x410U >> (8 * i)) & 0xFFU).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((samples >> (8 * i)) & 0xFFU).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((0U >> (8 * i)) & 0xFFU).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((samples >> (8 * i)) & 0xFFU).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((flags >> (8 * i)) & 0xFFU).to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(b'\x00')
  }
  Bytes::from_array(out)
}

///|
test "wavpack: rejects unsupported and malformed streams" {
  assert_true(@libavcodec.ff_wavpack_decode(b"wvpk") is Err(_))
  assert_true(
    @libavcodec.ff_wavpack_decode(b"RIFF\x00\x00\x00\x00WAVE") is Err(_),
  )
  // Hybrid (0x08), float (0x80), DSD (0x80000000) and multi-block flags.
  let base = 0x1801U // INITIAL|FINAL, 16-bit stereo
  let hybrid = wavpack_test_block(base | 0x08U, 16U)
  assert_true(@libavcodec.ff_wavpack_decode(hybrid) is Err(_))
  let float_ = wavpack_test_block(base | 0x80U, 16U)
  assert_true(@libavcodec.ff_wavpack_decode(float_) is Err(_))
  let dsd = wavpack_test_block(base | 0x80000000U, 16U)
  assert_true(@libavcodec.ff_wavpack_decode(dsd) is Err(_))
  let multiblock = wavpack_test_block(0x801U, 16U)
  assert_true(@libavcodec.ff_wavpack_decode(multiblock) is Err(_))
  let eight_bit = wavpack_test_block(0x1800U, 16U)
  assert_true(@libavcodec.ff_wavpack_decode(eight_bit) is Err(_))
  // Valid flags but no metadata blocks.
  let no_metadata = wavpack_test_block(base, 16U)
  assert_true(@libavcodec.ff_wavpack_decode(no_metadata) is Err(_))
}
