///|
/// SIMD (`@v128`) version of `av_base64_encode` from `libavutil/base64.c`.
///
/// Port of the vectorised encoding used by FFmpeg's `libavcodec/x86/base64.asm`
/// (and by MoonBit core's `encoding/base64/encode_v128.mbt`): 12 input bytes
/// become 16 characters per iteration.
///
/// The bit repacking is done on `i32x4` lanes, one lane per 3-byte group. A
/// `i8x16_swizzle` expands the packed 12 bytes into the lane layout
/// `[b0,b1,b2,0, b3,b4,b5,0, ...]` (index 16 swizzles to zero), so each 32-bit
/// lane holds `w = b0 | b1<<8 | b2<<16` and the four 6-bit fields are plain
/// uniform shifts/masks of `w`:
///
///   c0 = (w >> 2) & 0x3F
///   c1 = ((w & 3) << 4) | ((w >> 12) & 0x0F)
///   c2 = (((w >> 8) & 0x0F) << 2) | ((w >> 22) & 0x03)
///   c3 = (w >> 16) & 0x3F
///
/// The fields are narrowed `i32x4 -> i16x8 -> i8x16` and re-interleaved with
/// `i8x16_shuffle`, then mapped to the standard alphabet with branchless
/// comparisons (the four range deltas `+6 / -75 / -15 / +3` over the
/// `>25 / >51 / >61 / >62` boundaries).
///
/// Gated to `native`/`wasm`; other targets keep the scalar `av_base64_encode`.
/// Equal outputs are asserted in `base64_v128_wbtest.mbt`.

///|
/// Map 6-bit indices (0..63) to the standard base64 alphabet, branchless. */
#cfg(any(target="native", target="wasm"))
fn b64_ascii(idx : V128) -> V128 {
  // idx + 'A'
  let mut c = @v128.i8x16_add(idx, @v128.i8x16_splat(b'\x41'))
  // +6 for idx > 25  (lowercase range)
  c = @v128.i8x16_add(
    c,
    @v128.v128_and_(
      @v128.i8x16_gt_s(idx, @v128.i8x16_splat(b'\x19')),
      @v128.i8x16_splat(b'\x06'),
    ),
  )
  // -75 for idx > 51 (digit range)
  c = @v128.i8x16_sub(
    c,
    @v128.v128_and_(
      @v128.i8x16_gt_s(idx, @v128.i8x16_splat(b'\x33')),
      @v128.i8x16_splat(b'\x4b'),
    ),
  )
  // -15 for idx > 61 ('+')
  c = @v128.i8x16_sub(
    c,
    @v128.v128_and_(
      @v128.i8x16_gt_s(idx, @v128.i8x16_splat(b'\x3d')),
      @v128.i8x16_splat(b'\x0f'),
    ),
  )
  // +3 for idx > 62 ('/')
  c = @v128.i8x16_add(
    c,
    @v128.v128_and_(
      @v128.i8x16_gt_s(idx, @v128.i8x16_splat(b'\x3e')),
      @v128.i8x16_splat(b'\x03'),
    ),
  )
  c
}

///|
/// `av_base64_encode` computed with 12-byte SIMD blocks; the tail (full
/// 3-byte groups beyond the last full 12, plus the padded remainder) uses the
/// same scalar code as `av_base64_encode`, so the two agree bit for bit.
#cfg(any(target="native", target="wasm"))
pub fn av_base64_encode_v128(input : Bytes) -> String {
  let n = input.length()
  let out : FixedArray[Byte] = FixedArray::make(av_base64_size(n), b'=')
  let gather = @v128.i8x16_const(
    0, 1, 2, 16, 3, 4, 5, 16, 6, 7, 8, 16, 9, 10, 11, 16,
  )
  let m3f = @v128.i32x4_const(0x3F, 0x3F, 0x3F, 0x3F)
  let m0f = @v128.i32x4_const(0x0F, 0x0F, 0x0F, 0x0F)
  let m03 = @v128.i32x4_const(0x03, 0x03, 0x03, 0x03)
  let mut i = 0
  let mut o = 0
  while i + 16 <= n {
    match input[i:i + 16] {
      [v128le(v), ..] => {
        let w = @v128.i8x16_swizzle(v, gather)
        let c0 = @v128.v128_and_(@v128.i32x4_shr_u(w, 2), m3f)
        let c1 = @v128.v128_or_(
          @v128.i32x4_shl(@v128.v128_and_(w, m03), 4),
          @v128.v128_and_(@v128.i32x4_shr_u(w, 12), m0f),
        )
        let c2 = @v128.v128_or_(
          @v128.i32x4_shl(@v128.v128_and_(@v128.i32x4_shr_u(w, 8), m0f), 2),
          @v128.v128_and_(@v128.i32x4_shr_u(w, 22), m03),
        )
        let c3 = @v128.v128_and_(@v128.i32x4_shr_u(w, 16), m3f)
        let packed = @v128.i8x16_narrow_i16x8_u(
          @v128.i16x8_narrow_i32x4_u(c0, c1),
          @v128.i16x8_narrow_i32x4_u(c2, c3),
        )
        let ord = @v128.i8x16_shuffle(
          packed, packed, 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15,
        )
        @v128.v128_store(out, o, b64_ascii(ord))
        i = i + 12
        o = o + 16
      }
      _ => break
    }
  }
  while i + 3 <= n {
    let bits = (input[i].to_uint() << 16) |
      (input[i + 1].to_uint() << 8) |
      input[i + 2].to_uint()
    out[o] = b64_alphabet[((bits >> 18) & 0x3F).reinterpret_as_int()]
    out[o + 1] = b64_alphabet[((bits >> 12) & 0x3F).reinterpret_as_int()]
    out[o + 2] = b64_alphabet[((bits >> 6) & 0x3F).reinterpret_as_int()]
    out[o + 3] = b64_alphabet[(bits & 0x3F).reinterpret_as_int()]
    i = i + 3
    o = o + 4
  }
  let rem = n - i
  if rem == 1 {
    let bits = input[i].to_uint() << 16
    out[o] = b64_alphabet[((bits >> 18) & 0x3F).reinterpret_as_int()]
    out[o + 1] = b64_alphabet[((bits >> 12) & 0x3F).reinterpret_as_int()]
  } else if rem == 2 {
    let bits = (input[i].to_uint() << 16) | (input[i + 1].to_uint() << 8)
    out[o] = b64_alphabet[((bits >> 18) & 0x3F).reinterpret_as_int()]
    out[o + 1] = b64_alphabet[((bits >> 12) & 0x3F).reinterpret_as_int()]
    out[o + 2] = b64_alphabet[((bits >> 6) & 0x3F).reinterpret_as_int()]
  }
  ascii_to_string(out, out.length())
}
