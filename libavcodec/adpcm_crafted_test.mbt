///|
/// Malformed ADPCM blocks and unsupported parameter combinations are rejected
/// before any predictor state can produce garbage.

///|
test "adpcm: rejects unsupported parameters" {
  let bad_codec = @libavcodec.adpcm_decoder_new("adpcm_foo", 1)
  assert_true(bad_codec is Err(_))
  let too_many = @libavcodec.adpcm_decoder_new("adpcm_ms", 3)
  assert_true(too_many is Err(_))
  let no_channels = @libavcodec.adpcm_decoder_new("adpcm_yamaha", 0)
  assert_true(no_channels is Err(_))
}

///|
test "adpcm: rejects malformed block headers" {
  let ima = @libavcodec.adpcm_decoder_new("adpcm_ima_wav", 1, block_align=16).unwrap()
  // predictor 0, invalid step index 89, reserved byte, then nibbles.
  let bad_ima = b"\x00\x00\x59\x00\x12\x34\x56\x78\x9a\xbc\xde\xf0\x11\x22\x33\x44"
  assert_true(ima.decode_block(bad_ima) is Err(_))
  let short_ima = ima.decode_block(b"\x00\x00\x01")
  assert_true(short_ima is Err(_))
  let ms = @libavcodec.adpcm_decoder_new("adpcm_ms", 1, block_align=16).unwrap()
  // block_predictor 7 is out of range (valid 0..6).
  let bad_ms = b"\x07\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_true(ms.decode_block(bad_ms) is Err(_))
  let short_ms = ms.decode_block(b"\x00\x10\x00\x00\x00")
  assert_true(short_ms is Err(_))
  let yamaha = @libavcodec.adpcm_decoder_new("adpcm_yamaha", 2).unwrap()
  let short_yamaha = yamaha.decode_block(b"\x00")
  assert_true(short_yamaha is Err(_))
}
