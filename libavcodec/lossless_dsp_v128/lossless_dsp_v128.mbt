///|
/// SIMD (`@v128`) versions of the lossless-audio DSP kernels:
///
///   - FLAC stereo decorrelation (`libavcodec/flacdsp_template.c`:
///     `flac_decorrelate_indep/ls/rs/ms_{16,32}`), against
///     `libavcodec/x86/flacdsp.asm` (`flac_decorrelate_*_16`,
///     `flac_decorrelate_*_32`);
///   - FLAC LPC reconstruction (`libavcodec/flacdsp_lpc_template.c`:
///     `flac_lpc_32_q12/15`), against `x86/flacdsp.asm` (`flac_lpc_%2`);
///   - AC-3 `float_to_fixed24` (`libavcodec/ac3dsp.c`), against
///     `libavcodec/x86/ac3dsp.asm`.
///
/// The scalar ports are `flac_lpc_predict` in `libavcodec/flac_decode.mbt`
/// and the decorrelation inline in the same file.
///
/// **Two distinct lane domains**, deliberately kept separate:
///
///   - the **decorrelation** kernels are pure `i32` arithmetic on
///     `unsigned`/`int` values, so they run on `i32x4` lanes. The C mixes
///     `unsigned` and `int` deliberately (`unsigned a = in[0][i]` then
///     `a -= b >> 1` in the ms case) — the `@v128` port reproduces that by
///     doing the whole thing in `i32x4` with wrapping ops, which is
///     bit-identical to the C's two's-complement behaviour. The `<< shift`
///     at the end is a left shift on an `unsigned`, i.e. a wrapping `i32`
///     shift, so no masking is needed.
///   - the **LPC** kernels accumulate a dot product whose intermediate the
///     C stores in `int` (32-bit, wrapping). Reordering that accumulation
///     would change the wrapped value in exactly the cases where it wraps,
///     so the accumulation order is **kept scalar** and only the
///     per-sample add/indexing is expressed with `i64x2` where it is
///     provably order-free (the `lpc32` wide path). This is the same call
///     §480/§481 made for their running sums.
///
/// `float_to_fixed24` is `av_clip_int24(lrintf(f * (1 << 24)))`; the vector
/// body scales in `f32x4`, rounds with `f32x4_nearest`, converts with
/// `i32x4_trunc_sat_f32x4_s` and clamps to the int24 range — the asm's
/// `cvtps2dq` + `packssdw` shape.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `lossless_dsp_v128_wbtest.mbt`.

///|
/// Load four `i32x4` lanes. */
#cfg(any(target="native", target="wasm"))
fn ldv_load4(a : Array[Int32], at : Int32) -> V128 {
  @v128.i32x4_const(
    a[at].reinterpret_as_uint(),
    a[at + 1].reinterpret_as_uint(),
    a[at + 2].reinterpret_as_uint(),
    a[at + 3].reinterpret_as_uint(),
  )
}

///|
/// Store four `i32x4` lanes. */
#cfg(any(target="native", target="wasm"))
fn ldv_store4(a : Array[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    a[at + i] = @v128.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// The `indep` case reduces to a shifted copy per channel.
#cfg(any(target="native", target="wasm"))
pub fn flac_decorrelate_indep_v128(
  out : Array[Int32],
  out_off : Int32,
  in0 : Array[Int32],
  in_off : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    ldv_store4(
      out,
      out_off + i,
      @v128.i32x4_shl(ldv_load4(in0, in_off + i), shift),
    )
    i = i + 4
  }
  while i < len {
    out[out_off + i] = in0[in_off + i] << shift
    i = i + 1
  }
}

///|
/// `flac_decorrelate_ls`: `out0 = a`, `out1 = a - b` (both shifted).
#cfg(any(target="native", target="wasm"))
pub fn flac_decorrelate_ls_v128(
  out0 : Array[Int32],
  o0 : Int32,
  out1 : Array[Int32],
  o1 : Int32,
  in0 : Array[Int32],
  i0 : Int32,
  in1 : Array[Int32],
  i1 : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    let a = ldv_load4(in0, i0 + i)
    let b = ldv_load4(in1, i1 + i)
    ldv_store4(out0, o0 + i, @v128.i32x4_shl(a, shift))
    ldv_store4(out1, o1 + i, @v128.i32x4_shl(@v128.i32x4_sub(a, b), shift))
    i = i + 4
  }
  while i < len {
    let a = in0[i0 + i]
    let b = in1[i1 + i]
    out0[o0 + i] = a << shift
    out1[o1 + i] = (a - b) << shift
    i = i + 1
  }
}

///|
/// `flac_decorrelate_rs`: `out0 = a + b`, `out1 = b`.
#cfg(any(target="native", target="wasm"))
pub fn flac_decorrelate_rs_v128(
  out0 : Array[Int32],
  o0 : Int32,
  out1 : Array[Int32],
  o1 : Int32,
  in0 : Array[Int32],
  i0 : Int32,
  in1 : Array[Int32],
  i1 : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    let a = ldv_load4(in0, i0 + i)
    let b = ldv_load4(in1, i1 + i)
    ldv_store4(out0, o0 + i, @v128.i32x4_shl(@v128.i32x4_add(a, b), shift))
    ldv_store4(out1, o1 + i, @v128.i32x4_shl(b, shift))
    i = i + 4
  }
  while i < len {
    let a = in0[i0 + i]
    let b = in1[i1 + i]
    out0[o0 + i] = (a + b) << shift
    out1[o1 + i] = b << shift
    i = i + 1
  }
}

///|
/// `flac_decorrelate_ms`: `a -= b >> 1` (unsigned a, signed b),
/// `out0 = a + b`, `out1 = a`. All in wrapping `i32`, matching the C's
/// mixed `unsigned`/`int` two's-complement arithmetic.
#cfg(any(target="native", target="wasm"))
pub fn flac_decorrelate_ms_v128(
  out0 : Array[Int32],
  o0 : Int32,
  out1 : Array[Int32],
  o1 : Int32,
  in0 : Array[Int32],
  i0 : Int32,
  in1 : Array[Int32],
  i1 : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    let a0 = ldv_load4(in0, i0 + i)
    let b = ldv_load4(in1, i1 + i)
    // a -= b >> 1  (arithmetic shift on the signed b, then wrapping sub)
    let a = @v128.i32x4_sub(a0, @v128.i32x4_shr_s(b, 1))
    ldv_store4(out0, o0 + i, @v128.i32x4_shl(@v128.i32x4_add(a, b), shift))
    ldv_store4(out1, o1 + i, @v128.i32x4_shl(a, shift))
    i = i + 4
  }
  while i < len {
    let a0 = in0[i0 + i]
    let b = in1[i1 + i]
    let a = a0 - (b >> 1)
    out0[o0 + i] = (a + b) << shift
    out1[o1 + i] = a << shift
    i = i + 1
  }
}

///|
/// FLAC `lpc32` reconstruction: the wide (`Int64`) accumulator form.
///
/// Each output sample is `decoded[i] + (sum >> qlevel)` where `sum` is a
/// 64-bit dot product over the previous `pred_order` samples. The dot is
/// strictly sequential in the C (each term added in order, 64-bit so no
/// wrap), so summing it in any order is safe — here the terms are
/// accumulated in `i64x2` pairs, which cannot overflow either.
#cfg(any(target="native", target="wasm"))
pub fn flac_lpc32_v128(
  decoded : Array[Int32],
  coeffs : Array[Int32],
  pred_order : Int32,
  qlevel : Int32,
  blocksize : Int32,
) -> Unit {
  let mut i = pred_order
  while i < blocksize {
    let mut acc = @v128.i64x2_splat(0UL)
    let mut j = 0
    while j + 2 <= pred_order {
      let d = @v128.i64x2_const(
        (coeffs[j].to_int64() * decoded[i - pred_order + j].to_int64())
          .reinterpret_as_uint64(),
        (coeffs[j + 1].to_int64() * decoded[i - pred_order + j + 1].to_int64())
          .reinterpret_as_uint64(),
      )
      acc = @v128.i64x2_add(acc, d)
      j = j + 2
    }
    let mut sum : Int64 = @v128.i64x2_extract_lane(acc, 0).reinterpret_as_int64() +
      @v128.i64x2_extract_lane(acc, 1).reinterpret_as_int64()
    while j < pred_order {
      sum = sum +
        coeffs[j].to_int64() * decoded[i - pred_order + j].to_int64()
      j = j + 1
    }
    decoded[i] = (decoded[i].to_int64() + (sum >> qlevel)).to_int()
    i = i + 1
  }
}

///|
/// FLAC `lpc16` reconstruction: the C accumulates in a wrapping `int`
/// (`int s0`), so the per-term order is observable when the sum wraps.
/// The accumulation is kept exactly scalar and only the outer loop is
/// shared — documented deviation (see the module doc).
#cfg(any(target="native", target="wasm"))
pub fn flac_lpc16_v128(
  decoded : Array[Int32],
  coeffs : Array[Int32],
  pred_order : Int32,
  qlevel : Int32,
  blocksize : Int32,
) -> Unit {
  for i = pred_order; i < blocksize; i = i + 1 {
    let mut sum : Int32 = 0
    for j = 0; j < pred_order; j = j + 1 {
      sum = sum + coeffs[j] * decoded[i - pred_order + j]
    }
    decoded[i] = decoded[i] + (sum >> qlevel)
  }
}

///|
/// AC-3 `float_to_fixed24`: `av_clip_int24(lrintf(f * (1 << 24)))`.
///
/// The vector body scales in `f32x4`, rounds with `f32x4_nearest` (the
/// `lrintf` default round-to-nearest-even), converts with
/// `i32x4_trunc_sat_f32x4_s`, then clamps to `[-2^23, 2^23-1]` — the
/// `cvtps2dq` + `packssdw` shape of `ac3dsp.asm`.
#cfg(any(target="native", target="wasm"))
pub fn ac3_float_to_fixed24_v128(
  dst : Array[Int32],
  src : Array[Float],
  len : Int32,
) -> Unit {
  let scale = @v128.f32x4_splat(16777216.0)
  let lo = @v128.i32x4_splat((0 - 8388608).reinterpret_as_uint())
  let hi = @v128.i32x4_splat(8388607)
  let mut i = 0
  while i + 4 <= len {
    let f = @v128.f32x4_const(src[i], src[i + 1], src[i + 2], src[i + 3])
    let r = @v128.f32x4_nearest(@v128.f32x4_mul(f, scale))
    let c = @v128.i32x4_trunc_sat_f32x4_s(r)
    ldv_store4(
      dst,
      i,
      @v128.i32x4_min_s(@v128.i32x4_max_s(c, lo), hi),
    )
    i = i + 4
  }
  while i < len {
    let r = Float::from_double(src[i].to_double() * 16777216.0)
    let v = r.to_int()
    dst[i] = if v < -8388608 {
      -8388608
    } else if v > 8388607 {
      8388607
    } else {
      v
    }
    i = i + 1
  }
}
