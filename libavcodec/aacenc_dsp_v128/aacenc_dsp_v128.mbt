///|
/// SIMD (`@v128`) versions of misc audio DSP kernels:
///
///   - AAC encoder: `abs_pow34_v` and `quantize_bands`
///     (`libavcodec/aacencdsp.c`; scalar ports `aac_two_abs_pow34`,
///     `aac_two_quantize_bands` in `libavcodec/aac_twoloop.mbt`), against
///     `libavcodec/x86/aacencdsp.asm` (`abs_pow34_sse`,
///     `quantize_bands_sse`);
///   - `scalarproduct_int16` (the `audiodsp` / `fixed_dsp` dot product),
///     against `libavcodec/x86/audiodsp.asm` and
///     `libavutil/x86/fixed_dsp.asm`;
///   - AC-3 `extract_exponents` (`libavcodec/ac3dsp.c`), against
///     `libavcodec/x86/ac3dsp.asm`.
///
/// **Domain note (AAC encoder)**: the C is `float` throughout (`sqrtf`,
/// `fabsf`, a `float` multiply-add), and the scalar port models that by
/// rounding *every* intermediate to binary32. This port therefore uses
/// `f32x4` lanes — each `f32x4` op is already binary32, so the result is
/// bit-identical to the scalar port by construction. Using `f64x2` here
/// would drift: double-precision intermediates do not match
/// `sqrtf`-rounded ones.
///
/// `abs_pow34` is `sqrtf(a * sqrtf(a))` with `a = fabsf(in[i])`; the asm
/// does the two `sqrt` steps with an `andps` mask in between, the same
/// three-step shape.
///
/// `quantize_bands` is `(int)min(scaled*Q34 + rounding, maxval)`, negated
/// for negative inputs under a signed codebook. The vector body multiplies
/// and adds in `f32x4`, saturates with `f32x4_min`, truncates with
/// `i32x4_trunc_sat_f32x4_s`, and applies the sign with a masked negate.
///
/// **`scalarproduct_int16`**: samples live in the port's `Array[Int32]`
/// planes but are `int16` in value; the vector body narrows to `i16x8`,
/// uses `i32x4_dot_i16x8_s` (the `pmaddwd` structure) and folds the four
/// `i32` partials into a scalar `Int64`. The partials are extracted and
/// sign-extended **individually** — accumulating them in `i64x2` lanes and
/// reinterpreting would lose a negative partial's sign (this was caught by
/// the extreme-value case in the wbtest).
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `aacenc_dsp_v128_wbtest.mbt`.

///|
/// `f32x4` from four doubles, rounding each to binary32 (the rounding the
/// scalar port's `aac_two_f32` performs).
#cfg(any(target="native", target="wasm"))
fn aev_load4(a : Array[Double], at : Int32) -> V128 {
  @simd.f32x4_const(
    Float::from_double(a[at]),
    Float::from_double(a[at + 1]),
    Float::from_double(a[at + 2]),
    Float::from_double(a[at + 3]),
  )
}

///|
/// Store four `f32x4` lanes back as doubles (a float widens to double
/// without loss).
#cfg(any(target="native", target="wasm"))
fn aev_store4(a : Array[Double], at : Int32, v : V128) -> Unit {
  a[at] = @simd.f32x4_extract_lane(v, 0).to_double()
  a[at + 1] = @simd.f32x4_extract_lane(v, 1).to_double()
  a[at + 2] = @simd.f32x4_extract_lane(v, 2).to_double()
  a[at + 3] = @simd.f32x4_extract_lane(v, 3).to_double()
}

///|
/// `sqrtf(x)` for a single double, rounded through binary32. */
#cfg(any(target="native", target="wasm"))
fn aev_sqrtf(x : Double) -> Double {
  let f = Float::from_double(x)
  @simd.f32x4_extract_lane(@simd.f32x4_sqrt(@simd.f32x4_splat(f)), 0).to_double()
}

///|
/// `abs_pow34_v`: `out[i] = sqrtf(|in[i]| * sqrtf(|in[i]|))`, all in
/// binary32.
#cfg(any(target="native", target="wasm"))
pub fn aac_abs_pow34_v128(
  input : Array[Double],
  size : Int32,
  out : Array[Double],
) -> Unit {
  let mut i = 0
  while i + 4 <= size {
    let x = @simd.f32x4_abs(aev_load4(input, i))
    let inner = @simd.f32x4_sqrt(x)
    aev_store4(out, i, @simd.f32x4_sqrt(@simd.f32x4_mul(x, inner)))
    i = i + 4
  }
  while i < size {
    let a = Float::from_double(input[i].abs())
    let inner = aev_sqrtf(a.to_double())
    let prod = Float::from_double(a.to_double() * inner)
    out[i] = aev_sqrtf(prod.to_double())
    i = i + 1
  }
}

///|
/// The C's `0.4054f` rounding constant (`aacencdsp.c`). */
#cfg(any(target="native", target="wasm"))
let aev_c_quant : Double = 0.40540000796318054

///|
/// `quantize_bands`: `(int)min(scaled*Q34 + rounding, maxval)`, negated
/// when `is_signed` and the input was negative.
#cfg(any(target="native", target="wasm"))
pub fn aac_quantize_bands_v128(
  out : Array[Int32],
  input : Array[Double],
  in_off : Int32,
  scaled : Array[Double],
  scaled_off : Int32,
  size : Int32,
  is_signed : Bool,
  maxval : Int32,
  q34 : Double,
) -> Unit {
  let qv = @simd.f32x4_splat(Float::from_double(q34))
  let rv = @simd.f32x4_splat(Float::from_double(aev_c_quant))
  let mav = @simd.f32x4_splat(Float::from_double(maxval.to_double()))
  let zero = @simd.f32x4_splat(0.0)
  let mut i = 0
  while i + 4 <= size {
    let s = aev_load4(scaled, scaled_off + i)
    let capped = @simd.f32x4_min(
      @simd.f32x4_add(@simd.f32x4_mul(s, qv), rv),
      mav,
    )
    let trunc = @simd.i32x4_trunc_sat_f32x4_s(capped)
    let outv = if is_signed {
      let neg = @simd.i32x4_neg(trunc)
      let mask = @simd.f32x4_lt(aev_load4(input, in_off + i), zero)
      @simd.v128_bitselect(neg, trunc, mask)
    } else {
      trunc
    }
    aev_store_i32x4(out, i, outv)
    i = i + 4
  }
  while i < size {
    let sc = Float::from_double(scaled[scaled_off + i])
    let qc = Float::from_double(sc.to_double() * q34_f32(q34))
    let capped = Float::from_double(qc.to_double() + aev_c_quant)
    let mut tmp = if capped.to_double() >= maxval.to_double() {
      maxval
    } else {
      capped.to_int()
    }
    if is_signed && input[in_off + i] < 0.0 {
      tmp = -tmp
    }
    out[i] = tmp
    i = i + 1
  }
}

///|
/// `q34` rounded to binary32 then widened. */
#cfg(any(target="native", target="wasm"))
fn q34_f32(q34 : Double) -> Double {
  Float::from_double(q34).to_double()
}

///|
/// Store four `i32x4` lanes to an `Array[Int32]`. */
#cfg(any(target="native", target="wasm"))
fn aev_store_i32x4(a : Array[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    a[at + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// Load four `i32x4` lanes. */
#cfg(any(target="native", target="wasm"))
fn aev_load_i32x4(a : Array[Int32], at : Int32) -> V128 {
  @simd.i32x4_const(
    a[at].reinterpret_as_uint(),
    a[at + 1].reinterpret_as_uint(),
    a[at + 2].reinterpret_as_uint(),
    a[at + 3].reinterpret_as_uint(),
  )
}

///|
/// Load eight `int16`-valued samples from an `Array[Int32]` as `i16x8`. */
#cfg(any(target="native", target="wasm"))
fn aev_load_i16x8(a : Array[Int32], at : Int32) -> V128 {
  @simd.i16x8_const(
    a[at].reinterpret_as_uint().to_uint16(),
    a[at + 1].reinterpret_as_uint().to_uint16(),
    a[at + 2].reinterpret_as_uint().to_uint16(),
    a[at + 3].reinterpret_as_uint().to_uint16(),
    a[at + 4].reinterpret_as_uint().to_uint16(),
    a[at + 5].reinterpret_as_uint().to_uint16(),
    a[at + 6].reinterpret_as_uint().to_uint16(),
    a[at + 7].reinterpret_as_uint().to_uint16(),
  )
}

///|
/// `scalarproduct_int16`: `sum(src1[i] * src2[i])` over `n` `int16`
/// samples, widened to `int64` like the C.
#cfg(any(target="native", target="wasm"))
pub fn aac_scalarproduct_int16_v128(
  s1 : Array[Int32],
  o1 : Int32,
  s2 : Array[Int32],
  o2 : Int32,
  n : Int32,
) -> Int64 {
  let mut total : Int64 = 0L
  let mut i = 0
  while i + 8 <= n {
    let a = aev_load_i16x8(s1, o1 + i)
    let b = aev_load_i16x8(s2, o2 + i)
    let d = @simd.i32x4_dot_i16x8_s(a, b)
    total = total +
      @simd.i32x4_extract_lane(d, 0).reinterpret_as_int().to_int64() +
      @simd.i32x4_extract_lane(d, 1).reinterpret_as_int().to_int64() +
      @simd.i32x4_extract_lane(d, 2).reinterpret_as_int().to_int64() +
      @simd.i32x4_extract_lane(d, 3).reinterpret_as_int().to_int64()
    i = i + 8
  }
  while i < n {
    total = total + s1[o1 + i].to_int64() * s2[o2 + i].to_int64()
    i = i + 1
  }
  total
}

///|
/// AC-3 `extract_exponents`: `clamp(27 - clz(|x|), 0, 24)` per sample.
///
/// `@v128` has no leading-zero-count intrinsic, so the bit scan is done
/// per lane after the `i32x4_abs`; the vector part still does the absolute
/// value and the extraction together, and the result matches the scalar
/// port exactly (including `|x| == 0` mapping to exponent 0).
#cfg(any(target="native", target="wasm"))
pub fn ac3_extract_exponents_v128(
  exp_out : Array[Int32],
  exp_in : Array[Int32],
  n : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= n {
    let v = @simd.i32x4_abs(aev_load_i32x4(exp_in, i))
    let mut k = 0
    while k < 4 {
      let x = @simd.i32x4_extract_lane(v, k).reinterpret_as_int()
      exp_out[i + k] = aev_exponent(x)
      k = k + 1
    }
    i = i + 4
  }
  while i < n {
    exp_out[i] = aev_exponent(exp_in[i].abs())
    i = i + 1
  }
}

///|
/// `clamp(27 - clz(x), 0, 24)` for a non-negative `x`. */
#cfg(any(target="native", target="wasm"))
fn aev_exponent(x : Int32) -> Int32 {
  let mut clz = 32
  let mut bit = 31
  while bit >= 0 {
    if ((x >> bit) & 1) != 0 {
      clz = 31 - bit
      break
    }
    bit = bit - 1
  }
  let e = 27 - clz
  if e < 0 {
    0
  } else if e > 24 {
    24
  } else {
    e
  }
}
