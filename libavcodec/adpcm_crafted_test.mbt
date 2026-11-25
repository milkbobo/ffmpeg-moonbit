///|
/// Malformed ADPCM blocks and unsupported parameter combinations are rejected
/// before any predictor state can produce garbage.

///|
test "adpcm: rejects unsupported parameters" {
  let bad_codec = @libavcodec.adpcm_decoder_new("adpcm_foo", 1)
  assert_true(bad_codec is Err(_))
  // MS ADPCM takes up to 6 channels (the planar layout above 2).
  let too_many = @libavcodec.adpcm_decoder_new("adpcm_ms", 7)
  assert_true(too_many is Err(_))
  // OKI and Yamaha are limited to stereo (the C's max_channels = 2).
  let oki_three = @libavcodec.adpcm_decoder_new("adpcm_ima_oki", 3)
  assert_true(oki_three is Err(_))
  let no_channels = @libavcodec.adpcm_decoder_new("adpcm_yamaha", 0)
  assert_true(no_channels is Err(_))
  // IMA WAV accepts 2..=5 bits per coded sample only.
  let bad_bits = @libavcodec.adpcm_decoder_new("adpcm_ima_wav", 1, bits_per_coded_sample=6)
  assert_true(bad_bits is Err(_))
  let bad_bits2 = @libavcodec.adpcm_decoder_new("adpcm_ima_wav", 1, bits_per_coded_sample=1)
  assert_true(bad_bits2 is Err(_))
  let ok6 = @libavcodec.adpcm_decoder_new("adpcm_ms", 6, block_align=48).unwrap()
  // 6 channels: one 7-byte header + 1 data byte per channel -> 4 samples
  let six = ok6.decode_block(Bytes::make(48, b'\x00')).unwrap()
  assert_eq(six.pcm_bytes().length(), 4 * 6 * 2)
  let ok_ima3 = @libavcodec.adpcm_decoder_new("adpcm_ima_wav", 2, bits_per_coded_sample=3).unwrap()
  // 2 channels, 3-bit codes: 4*ch header + one 12*ch byte group -> 33 samples
  let ima3 = ok_ima3.decode_block(Bytes::make(32, b'\x00')).unwrap()
  assert_eq(ima3.pcm_bytes().length(), 33 * 2 * 2)
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
  // An odd byte count leaves one nibble unpaired: like the C decoder, the
  // half sample is dropped rather than rejected.
  let half_yamaha = yamaha.decode_block(b"\x00")
  assert_true(half_yamaha is Ok(_))
}
