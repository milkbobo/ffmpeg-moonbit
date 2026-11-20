///|
fn ac3_spx_test_frame() -> Bytes {
  let bits = BitWriter::new()
  bits.put(0x0B77U, 16)
  bits.put(0U, 5) // independent substream zero
  bits.put(31U, 11) // 64-byte frame
  bits.put(0U, 4) // 48 kHz, one block
  bits.put(2U, 4) // mono, no LFE
  bits.put(16U, 5) // E-AC-3 bsid
  bits.put(31U, 5) // dialnorm
  bits.put(0U, 5) // compression, mix/info metadata, converter sync, additional BSI
  bits.put(1U, 10) // default block syntax, SPX attenuation present
  bits.put(1U, 2) // D15 exponents
  bits.put(0U, 1) // converter channel exponent strategy
  bits.put(0U, 10) // minimum SNR offset: BAP 0, dither
  bits.put(1U, 1) // channel has SPX attenuation
  bits.put(8U, 5)

  bits.put(0U, 1) // no dynamic range word
  bits.put(1U, 1) // enable spectral extension
  bits.put(0U, 9) // bins 25–48 copied into 49–84, default band structure
  bits.put(8U, 5) // noise blend
  bits.put(0U, 2) // master exponent
  for _ in 0..<3 {
    bits.put(4U, 4)
    bits.put(0U, 2)
  }
  bits.put(10U, 4) // initial channel exponent
  for _ in 0..<16 {
    bits.put(62U, 7) // three zero exponent deltas
  }
  bits.put(0U, 3) // gain range and converter SNR offset flag
  let frame = bits.finish()
  frame + Bytes::make(64 - frame.length(), b'\x00')
}

///|
test "E-AC-3 SPX: mono dither, wrap, attenuation and coordinates" {
  let frame = ac3_spx_test_frame()
  let decoder = ac3_decoder_new()
  let out = decoder.decode_frame(frame).unwrap()
  assert_eq(decoder.spx.start, 49)
  assert_eq(decoder.spx.end, 85)
  assert_eq(decoder.spx.bands.val, 3)
  assert_eq(decoder.spx.attenuation[1], 8)
  assert_eq(out.samples[0].length(), 256)
  // FFmpeg libavcodec 62.28.102 (PyAV), E-AC-3 decoder, planar f32 LE.
  let expected = @libavutil.av_base64_decode(
    b"aUr/tPytHbUNWouy0opmNZSWnzVWOVc1C7+BNQgQazamkRA3ZjRmN/m8fjej10o3H1AKN4rVGzeX74k3i+u+N783jje18eO23aMt" +
    b"uKcekrjQqKC4BhaAuM29GLhhFqC3xHWEt1B8rbc+Isa3eWWityfXArdtFU43gKc3OPrnpzgDGcU42QRLOJ9SjbheyVS5xhKGueAu" +
    b"Ebl3rQ85S+fiOckbEjowF9E5fWyKN7GvzLmDFyO6ajAhugBI8rlVvaG50xtmuZgvHbmVXxS4qpjPOA3fEzlxbrQ39V0ouaIyOLko" +
    b"oQE57EQcOl+ZWzqMSf05el7muWy3urpRCu26o6SmuvQR6rhTKnw6HIKzOgQujjq8dxg6Mny8OSiL+znqLA46mMwEOchkPLotBbq6" +
    b"zZOwumNN27miskE6xCyiOnL5KTqIpCW6Fu/dukHr8LoyU5G6CKI/uXs7eTkk6Ue3LTwIuv5DSLoZ8iG6nrLeuWvRHrpkL526wMbp" +
    b"ugCT87ol5Ky6UjYXug1jVblp+N25E1ZvuhBsj7oNGS+6uyyeOHYz6Tniw8+44KG+uo6sObtb71K7CaEFu0BQxDlqMzs76piDOwGL" +
    b"STsrXug5qwEdu3RhdLtk9TO7gVRDuQRHBzvo1hY7S7bCOd3JA7uA+B27z9jVOQF0qztKShI8PQ4MPNNXaDtNQWu7d2MRvIGxG7w+" +
    b"Fbu79j3vubA0NTvuARs7v9bquXOPOrttliu7rht+OUshcDvcQKc7A3pcO0llJ7rZ+5S7narHu4fDkbtt6hy67lJbOx7AsTvusKA7" +
    b"KngpOx7CPTk63Vq6S5MYuf2grTqrOxI7xfj6OjlxbzoV2ew5sr2sOqZUSzs7fpM71NCROxgKSjuSZtI6PRaYOjcg5DpehRE7b1TM" +
    b"OgXGGjiZSEe6Qk8eOvsqeDv5sdQ7wazKO9WJHDvZTCa7Xlekux5lS7sCvO46M2DHO+j12TsxL2U7pNEnuoG8OrvbyCu78O4Fu8WV" +
    b"YbtJI9u7aDEQvIFD07v7qUw65SoYPGIyYjyNUzo855JwO0iAirvHsPu799i7u52Oo7qDIvQ685rqOkZFhLlqUeS6A+6ouhLC/jk+" +
    b"gA47IIFcO8v8ozt/FgI89oU3PCwXRTz5agM89xa9uXYaGLzzrmK8RPA7vHV2frueo4k7LUUIPFk06DvG1CU730gAu3pahrt2XXe7" +
    b"ynMSu5c9MrqV9PU5yzemOsJR3Tqa+NM6m3WxOlDE6zpo9Hc7A9zlO3jaHzwqwCE8oZzWO0binTr3vF27oUeou2MmiruhVDK7pvY1" +
    b"u8F0mrtbTuK7r8Hwuw3es7tDIjC7xcJtuoW1dbp/mOi6VbPduo+nOTiv1R075SdlOw==",
    1024,
  ).unwrap()
  for i in 0..<256 {
    let at = i * 4
    let bits = expected[at].to_uint() |
      (expected[at + 1].to_uint() << 8) |
      (expected[at + 2].to_uint() << 16) |
      (expected[at + 3].to_uint() << 24)
    let sample = Float::reinterpret_from_uint(bits).to_double()
    assert_true((out.samples[0][i] - sample).abs() < 0.000000005)
  }
}
