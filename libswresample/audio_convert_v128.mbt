///|
/// SIMD (`@v128`) version of the libswresample float→s16 planar-to-packed
/// interleaver (`libswresample/audioconvert.c`'s `pack_2ch_flt_to_s16` /
/// `pack_6ch_*` family), against
/// `libswresample/x86/audio_convert.asm` (`PACK_2CH`, `CONV`,
/// `FLOAT_TO_INT16_N`, with the `flt2p15 = 32768.0` constant).
///
/// The scalar port is `Swr::flt_planar_to_s16_packed` and `swr_flt_to_s16`
/// in `libswresample/swresample_convert.mbt`.
///
/// **What the asm actually does, and the one place this port must differ.**
/// `audio_convert.asm` converts float→s16 with `cvtps2dq` after scaling by
/// `flt2p15 = 32768.0` — i.e. **truncation toward zero**. The C reference
/// (`audioconvert.c`) instead uses `av_clip_int16(lrintf(x * 32768))`,
/// i.e. **round-half-to-even**, and the scalar port deliberately implements
/// the C form (its module doc calls naive truncation out as "where naive
/// truncation loses a LSB").
///
/// This port therefore follows the **C/scalar** semantics, not the asm's,
/// and rounds with `f32x4_nearest` (round-half-to-even) before the
/// conversion. That keeps the project-wide "bit-identical to the scalar
/// port" contract; following the asm's truncation here would produce a
/// different (and, versus the C reference, wrong) 1-LSB result. The
/// deviation from the asm is documented rather than silently copied.
///
/// The interleave itself is the asm's `punpcklwd`/`punpckhwd` de-interleave
/// run backwards: two converted channels are packed into one interleaved
/// byte stream, which here is an `i16x8` interleave via `i8x16_shuffle` of
/// the two lane vectors' low halves.
///
/// Available on `native`, `wasm` and `wasm-gc`. Equal
/// outputs are asserted in `audio_convert_v128_wbtest.mbt`.

///|
/// `av_clip_int16` lane-wise. */
#cfg(any(target="native", target="wasm", target="wasm-gc"))
fn acv_clip_int16(v : V128) -> V128 {
  @simd.i32x4_min_s(
    @simd.i32x4_max_s(
      v,
      @simd.i32x4_splat((-32768).reinterpret_as_uint() & 0xFFFFFFFFU),
    ),
    @simd.i32x4_splat(32767),
  )
}

///|
/// `av_clip_int16(lrintf(x * 32768))` for two samples, kept in the `Double`
/// domain: the scalar port computes `x * 32768.0` in double and rounds that,
/// so a binary32 intermediate would change ties (and, for values with more
/// than 24 significant bits, the integer result). `f64x2` preserves it.
///
/// Returns the two results in `i32x4` lanes 0 and 1 (lanes 2/3 are zero).
#cfg(any(target="native", target="wasm", target="wasm-gc"))
fn acv_flt2_to_s16(a : Array[Double], at : Int32) -> V128 {
  let scale = @simd.f64x2_splat(32768.0)
  let r = @simd.f64x2_nearest(
    @simd.f64x2_mul(@simd.f64x2_const(a[at], a[at + 1]), scale),
  )
  let as_i32 = @simd.i32x4_trunc_sat_f64x2_s_zero(r)
  acv_clip_int16(as_i32)
}

///|
/// `Swr::flt_planar_to_s16_packed`: interleave `channels` planar double
/// planes into one packed s16 little-endian byte buffer.
///
/// Vectorised for the common 2-channel case (the asm's `PACK_2CH`), with
/// the general channel count and the tail handled scalar. The float→s16
/// step uses the C's round-half-to-even semantics throughout.
#cfg(any(target="native", target="wasm", target="wasm-gc"))
pub fn swr_flt_planar_to_s16_packed_v128(
  planar : Array[Array[Double]],
  channels : Int32,
  nb : Int32,
  out : Array[Int32],
) -> Unit {
  if channels == 2 {
    let mut i = 0
    // f64x2 handles two samples per step
    while i + 2 <= nb {
      let l = acv_flt2_to_s16(planar[0], i)
      let r = acv_flt2_to_s16(planar[1], i)
      // l holds (l0, l1) in i32 lanes 0/1, r holds (r0, r1); the output
      // order is l0, r0, l1, r1
      out[2 * i] = acv_low_i16(l, 0)
      out[2 * i + 1] = acv_low_i16(r, 0)
      out[2 * i + 2] = acv_low_i16(l, 1)
      out[2 * i + 3] = acv_low_i16(r, 1)
      i = i + 2
    }
    while i < nb {
      out[2 * i] = swr_flt_to_s16(planar[0][i])
      out[2 * i + 1] = swr_flt_to_s16(planar[1][i])
      i = i + 1
    }
  } else {
    for i = 0; i < nb; i = i + 1 {
      for ch = 0; ch < channels; ch = ch + 1 {
        out[i * channels + ch] = swr_flt_to_s16(planar[ch][i])
      }
    }
  }
}

///|
/// Extract the s16 held in the low half of `i32x4` lane `k`, sign-extended. */
#cfg(any(target="native", target="wasm", target="wasm-gc"))
fn acv_low_i16(v : V128, k : Int32) -> Int32 {
  let x = @simd.i32x4_extract_lane(v, k).reinterpret_as_int()
  x << 16 >> 16
}
