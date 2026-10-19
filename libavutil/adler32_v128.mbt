///|
/// SIMD (`@v128`) version of the Adler-32 checksum from `libavutil/adler32.c`.
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavutil/x86/`, SSE2/AVX2 alike): over a 16-byte block the two running
/// sums advance as
///
///   s1' = s1 + Σ b[i]
///   s2' = s2 + 16*s1 + Σ (16-i) * b[i]      (i = 0..15)
///
/// so the byte sum and the weighted sum are produced with two `pmaddwd`-style
/// dots (`@v128.i32x4_dot_i16x8_s`, the Wasm SIMD128 equivalent) per block.
///
/// This module is gated to `native`/`wasm`; other targets keep the scalar
/// `av_adler32_update` (see `adler32.mbt`). The two implementations are
/// asserted equal in `adler32_v128_wbtest.mbt`.

///| Horizontal sum of the four `i32x4` lanes. */
#cfg(any(target="native", target="wasm"))
fn adler_red4(v : V128) -> UInt {
  @v128.i32x4_extract_lane(v, 0) +
  @v128.i32x4_extract_lane(v, 1) +
  @v128.i32x4_extract_lane(v, 2) +
  @v128.i32x4_extract_lane(v, 3)
}

///|
/// `av_adler32_update` computed with 16-byte SIMD blocks.
/// `NMAX = 5552` mirrors zlib/FFmpeg's modulus discipline.
#cfg(any(target="native", target="wasm"))
pub fn av_adler32_update_v128(adler : UInt, buf : Bytes, len : Int) -> UInt {
  let ones = @v128.i16x8_const(1, 1, 1, 1, 1, 1, 1, 1)
  let w_lo = @v128.i16x8_const(16, 15, 14, 13, 12, 11, 10, 9)
  let w_hi = @v128.i16x8_const(8, 7, 6, 5, 4, 3, 2, 1)
  let mut s1 : UInt64 = (adler & 0xFFFF).to_uint64()
  let mut s2 : UInt64 = (adler >> 16).to_uint64()
  let mut p = 0
  let mut nmax = 5552
  while p + 16 <= len {
    match buf[p : p + 16] {
      [v128le(v), .. _] => {
        let lo = @v128.i16x8_extend_low_i8x16_u(v)
        let hi = @v128.i16x8_extend_high_i8x16_u(v)
        let bsum = adler_red4(
          @v128.i32x4_add(
            @v128.i32x4_dot_i16x8_s(lo, ones),
            @v128.i32x4_dot_i16x8_s(hi, ones),
          ),
        )
        let wsum = adler_red4(
          @v128.i32x4_add(
            @v128.i32x4_dot_i16x8_s(lo, w_lo),
            @v128.i32x4_dot_i16x8_s(hi, w_hi),
          ),
        )
        s2 = s2 + 16UL * s1 + wsum.to_uint64()
        s1 = s1 + bsum.to_uint64()
        nmax = nmax - 16
        if nmax <= 0 {
          s1 = s1 % adler_base
          s2 = s2 % adler_base
          nmax = 5552
        }
        p = p + 16
      }
      _ => break
    }
  }
  // scalar tail (and the whole buffer when len < 16)
  while p < len {
    let (a, b) = adler_do1(s1, s2, buf[p])
    s1 = a
    s2 = b
    p = p + 1
  }
  s1 = s1 % adler_base
  s2 = s2 % adler_base
  ((s2 << 16) | s1).to_uint()
}
