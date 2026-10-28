///|
test "telephony: G.726 rejects invalid code sizes" {
  assert_true(@libavcodec.g726_decoder_new(1) is Err(_))
  assert_true(@libavcodec.g726_decoder_new(6) is Err(_))
  let dec = @libavcodec.g726_decoder_new(4).unwrap()
  assert_eq(dec.decode(b"").length(), 0)
}
