///|
/// Whitebox tests for the SIMD (`@v128`) base64 encoder (`base64_v128.mbt`).
///
/// `av_base64_encode_v128` is checked against:
///   * the RFC 4648 §10 test vectors (independent of FFmpeg),
///   * the scalar authoritative port `av_base64_encode`
///     (`libavutil/tests/base64.c` reference table), on every length from 0 up
///     to well past several SIMD blocks, including the 12-byte boundaries.

///|
/// Deterministic byte-buffer generator (LCG). */
fn b64v128_gen(seed : UInt32, n : Int32) -> Bytes {
  let a : Array[Byte] = Array::make(n, b'\x00')
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFF).to_byte()
  }
  Bytes::from_array(a)
}

///|
test "base64 simd: RFC 4648 test vectors" {
  assert_eq(av_base64_encode_v128(b""), "")
  assert_eq(av_base64_encode_v128(b"f"), "Zg==")
  assert_eq(av_base64_encode_v128(b"fo"), "Zm8=")
  assert_eq(av_base64_encode_v128(b"foo"), "Zm9v")
  assert_eq(av_base64_encode_v128(b"foob"), "Zm9vYg==")
  assert_eq(av_base64_encode_v128(b"fooba"), "Zm9vYmE=")
  assert_eq(av_base64_encode_v128(b"foobar"), "Zm9vYmFy")
}

///|
test "base64 simd: equals the scalar encoder for all short lengths" {
  for n = 0; n < 130; n = n + 1 {
    let b = b64v128_gen(0x1234ABCDU + n.reinterpret_as_uint(), n)
    assert_eq(av_base64_encode_v128(b), av_base64_encode(b))
  }
}

///|
test "base64 simd: equals the scalar encoder on long buffers" {
  for k = 0; k < 40; k = k + 1 {
    let n = 1 + k * k * 53 % 5000
    let b = b64v128_gen(0x0BADF00DU + k.reinterpret_as_uint(), n)
    assert_eq(av_base64_encode_v128(b), av_base64_encode(b))
  }
  // explicit 12-byte block boundaries and the <=3 byte padded remainders
  for n = 0; n < 40; n = n + 1 {
    let b = b64v128_gen(0xC0FFEEU, n)
    assert_eq(av_base64_encode_v128(b), av_base64_encode(b))
  }
  // bytes exercising the whole alphabet, including '+' and '/'
  let all : Array[Byte] = Array::make(256, b'\x00')
  for i = 0; i < 256; i = i + 1 {
    all[i] = (i & 0xFF).to_byte()
  }
  let buf = Bytes::from_array(all)
  assert_eq(av_base64_encode_v128(buf), av_base64_encode(buf))
}
