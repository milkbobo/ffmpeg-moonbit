///|
/// Whitebox tests for the SIMD (`@v128`) Adler-32 (`adler32_v128.mbt`).
///
/// The SIMD path must agree with the scalar authoritative port
/// (`av_adler32_update`) on every input; the scalar port is itself verified
/// against FFmpeg's own vector (`libavutil/tests/adler32.c`: `0x50E6E508`) and
/// the Adler-32 spec examples. Here the SIMD path is additionally checked
/// against the published Adler-32("Wikipedia") = 0x11E60398 vector and by
/// exhaustive equality with the scalar path over generated buffers.

///| Deterministic byte-buffer generator (LCG). */
fn simd_gen_bytes(seed : UInt, n : Int) -> Bytes {
  let a : Array[Byte] = Array::make(n, b'\x00')
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFF).to_byte()
  }
  Bytes::from_array(a)
}

test "adler32 simd: published vector and equality with the scalar port" {
  // Published Adler-32 test vector.
  assert_eq(av_adler32_update_v128(1, b"Wikipedia", 9), 0x11E60398)
  assert_eq(
    av_adler32_update_v128(1, b"Wikipedia", 9),
    av_adler32_update(1, b"Wikipedia", 9),
  )
  // Empty input keeps the initial value.
  assert_eq(av_adler32_update_v128(1, b"", 0), 1)
  assert_eq(av_adler32_update_v128(1, b"", 0), av_adler32_update(1, b"", 0))
  // Short inputs (below one SIMD block) and boundary lengths around 16.
  for n = 0; n < 40; n = n + 1 {
    let b = simd_gen_bytes(0x9E3779B9U + n.reinterpret_as_uint(), n)
    assert_eq(av_adler32_update_v128(1, b, n), av_adler32_update(1, b, n))
    // continuing from a non-trivial running checksum
    let ad = av_adler32_update(1, simd_gen_bytes(7U, n), n)
    assert_eq(av_adler32_update_v128(ad, b, n), av_adler32_update(ad, b, n))
  }
}

test "adler32 simd: equality with the scalar port on long buffers" {
  for k = 0; k < 60; k = k + 1 {
    let n = 1 + (k * k * 37) % 20000
    let b = simd_gen_bytes(0xDEADBEEFU + k.reinterpret_as_uint(), n)
    assert_eq(av_adler32_update_v128(1, b, n), av_adler32_update(1, b, n))
  }
  // Very long, stresses the NMAX modulus boundaries (5552 and multiples).
  for n = 5540; n < 5570; n = n + 1 {
    let b = simd_gen_bytes(0xA5A5A5A5U, n)
    assert_eq(av_adler32_update_v128(1, b, n), av_adler32_update(1, b, n))
  }
}
