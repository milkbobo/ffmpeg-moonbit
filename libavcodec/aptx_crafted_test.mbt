///|
test "aptx: complete blocks decode, trailing bytes are ignored" {
  let empty = @libavcodec.ff_aptx_decode(b"\x00\x00\x00").unwrap()
  assert_eq(empty.samples.length(), 0)
  let empty_hd = @libavcodec.ff_aptx_decode(b"\x00\x00\x00\x00\x00", hd=true).unwrap()
  assert_eq(empty_hd.samples.length(), 0)
  let one_block = @libavcodec.ff_aptx_decode(b"\x00\x00\x00\x00").unwrap()
  assert_eq(one_block.samples.length(), 8)
  for v in one_block.samples {
    assert_eq(v, 0)
  }
}
