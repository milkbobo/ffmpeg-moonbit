///|
/// Whitebox tests for the `adler32` and `base64` ports.
/// Expected values come from libavutil/tests/adler32.c and the reference table
/// in libavutil/tests/base64.c.

///| libavutil/tests/adler32.c expects 0x50E6E508 for this input. */
test "av_adler32_update matches the ffmpeg unit test" {
  let len = 7001
  let buf : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    // data[i] = ((i * i) >> 3) + 123 * i
    buf[i] = (((i * i) >> 3) + 123 * i).reinterpret_as_uint().to_byte()
  }
  assert_eq(av_adler32_update(1, Bytes::from_array(buf[:]), len), 0x50E6E508)
}

test "av_adler32_update small inputs" {
  // "Wikipedia" from the Adler-32 specification.
  assert_eq(av_adler32_update(1, b"Wikipedia", 9), 0x11E60398)
  assert_eq(av_adler32_update(1, b"", 0), 1)
  // Chunked updates must match a single update.
  let one_shot = av_adler32_update(1, b"abc", 3)
  let chunked = av_adler32_update(av_adler32_update(1, b"ab", 2), b"c", 1)
  assert_eq(one_shot, chunked)
}

///|
/// decode/encode table from libavutil/tests/base64.c.
/// (input bytes, encoded bytes, encoded string)
test "av_base64 encode and round-trip" {
  let cases : Array[(Bytes, Bytes, String)] = [
    (b"", b"", ""),
    (b"1", b"MQ==", "MQ=="),
    (b"22", b"MjI=", "MjI="),
    (b"333", b"MzMz", "MzMz"),
    (b"4444", b"NDQ0NA==", "NDQ0NA=="),
    (b"55555", b"NTU1NTU=", "NTU1NTU="),
    (b"666666", b"NjY2NjY2", "NjY2NjY2"),
    (b"abc:def", b"YWJjOmRlZg==", "YWJjOmRlZg=="),
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let (data, enc, enc_str) = cases[i]
    // Expected value is an independent String literal, not a re-encoding.
    assert_eq(av_base64_encode(data), enc_str)
    assert_eq(av_base64_decode(enc, data.length()).unwrap(), data)
    if data.length() > 0 {
      // Truncated output buffer behaviour of the C implementation.
      let small = av_base64_decode(enc, data.length() - 1).unwrap()
      assert_eq(small.length(), data.length() - 1)
    }
  }
}

test "av_base64 rejects malformed input" {
  assert_true(av_base64_decode_syntax(b""))
  assert_true(av_base64_decode_syntax(b"MQ=="))
  assert_true(av_base64_decode_syntax(b"MzMz"))
  assert_true(!av_base64_decode_syntax(b"MQ=%"))
  assert_true(!av_base64_decode_syntax(b"MzM%"))
  assert_true(!av_base64_decode_syntax(b"Mz"))
  assert_true(!av_base64_decode_syntax(b"===="))
  assert_true(!av_base64_decode_syntax(b"MQ==A"))
}

test "av_base64_size" {
  assert_eq(av_base64_size(0), 0)
  assert_eq(av_base64_size(1), 4)
  assert_eq(av_base64_size(2), 4)
  assert_eq(av_base64_size(3), 4)
  assert_eq(av_base64_size(4), 8)
}
