///|
/// Whitebox tests for the SIMD (`@v128`) AAC encoder / AC-3 misc audio DSP
/// kernels (`aacenc_dsp_v128.mbt`).
///
/// The `ar_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/aac_twoloop.mbt`: `aac_two_abs_pow34`,
/// `aac_two_quantize_bands`, and the `ff_ac3_extract_exponents` /
/// `scalarproduct_int16` semantics) — the parent package's privates are not
/// visible from a subpackage, so the reference is carried here.

///|
/// The scalar port's f32 rounding: every intermediate goes through
/// binary32, exactly like a C `float` assignment.
fn ar_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
fn ar_sqrtf(x : Double) -> Double {
  ar_f32(x.sqrt())
}

///|
/// The C's `0.4054f`.
let ar_c_quant : Double = 0.40540000796318054

///|
/// Verbatim `aac_two_abs_pow34`. */
fn ar_abs_pow34(input : Array[Double], size : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(size, 0.0)
  for i in 0..<size {
    let a = ar_f32(input[i].abs())
    let inner = ar_sqrtf(a)
    out[i] = ar_sqrtf(ar_f32(a * inner))
  }
  out
}

///|
/// Verbatim `aac_two_quantize_bands`. */
fn ar_quantize_bands(
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
  for i in 0..<size {
    let qc = ar_f32(ar_f32(scaled[scaled_off + i]) * ar_f32(q34))
    let capped = ar_f32(qc + ar_c_quant)
    let mut tmp = if capped >= maxval.to_double() {
      maxval
    } else {
      capped.to_int()
    }
    if is_signed && input[in_off + i] < 0.0 {
      tmp = -tmp
    }
    out[i] = tmp
  }
}

///|
/// Verbatim `ff_ac3_extract_exponents`. */
fn ar_extract_exponents(
  exp_out : Array[Int32],
  exp_in : Array[Int32],
  n : Int32,
) -> Unit {
  for i = 0; i < n; i = i + 1 {
    let x = exp_in[i].abs()
    let mut clz = 0
    let mut bit = 31
    let mut found = false
    while bit >= 0 {
      if !found && ((x >> bit) & 1) != 0 {
        clz = 31 - bit
        found = true
      }
      bit = bit - 1
    }
    if !found {
      clz = 32
    }
    let e = 27 - clz
    exp_out[i] = if e < 0 { 0 } else if e > 24 { 24 } else { e }
  }
}

///|
/// Verbatim `scalarproduct_int16`: the plain `int64` dot product.
fn ar_scalarproduct_int16(
  s1 : Array[Int32],
  o1 : Int32,
  s2 : Array[Int32],
  o2 : Int32,
  n : Int32,
) -> Int64 {
  let mut total : Int64 = 0L
  for i = 0; i < n; i = i + 1 {
    total = total + s1[o1 + i].to_int64() * s2[o2 + i].to_int64()
  }
  total
}

///|
/// Deterministic double generator (LCG) over positive magnitudes. */
fn ar_gen(seed : UInt32, n : Int32) -> Array[Double] {
  let a : Array[Double] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = (v + 1.0) / 4096.0
  }
  a
}

///|
fn ar_gen_i32(seed : UInt32, n : Int32, limit : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (2 * limit + 1) - limit
  }
  a
}

///|
test "aacenc dsp v128: abs_pow34 is bit-identical in f32" {
  for size in [1, 2, 3, 4, 5, 8, 37, 128] {
    for k = 0; k < 3; k = k + 1 {
      let input = ar_gen(
        0x9E3779B9U + size.reinterpret_as_uint() + k.reinterpret_as_uint(),
        size,
      )
      let a = ar_abs_pow34(input, size)
      let b : Array[Double] = Array::make(size, 0.0)
      aac_abs_pow34_v128(input, size, b)
      for i = 0; i < size; i = i + 1 {
        assert_true(a[i] == b[i])
      }
    }
  }
}

///|
test "aacenc dsp v128: abs_pow34 handles zeros and negatives" {
  let input : Array[Double] = [
    0.0, -0.0, -1.0, 1.0, -1.0e30, 1.0e-30, -3.5, 2.25,
  ]
  let a = ar_abs_pow34(input, 8)
  let b : Array[Double] = Array::make(8, 0.0)
  aac_abs_pow34_v128(input, 8, b)
  for i = 0; i < 8; i = i + 1 {
    assert_true(a[i] == b[i])
  }
  // |x| makes the sign irrelevant
  assert_true(b[2] == b[3])
}

///|
test "aacenc dsp v128: quantize_bands signed and unsigned" {
  for size in [1, 2, 3, 4, 5, 16, 49] {
    for is_signed in [true, false] {
      for maxval in [8191, 255, 15] {
        for k = 0; k < 3; k = k + 1 {
          let scaled = ar_gen(
            0xABCDEF01U + size.reinterpret_as_uint() + k.reinterpret_as_uint(),
            size + 4,
          )
          // inputs spanning both signs
          let input = ar_gen_i32(
            0x13572468U + k.reinterpret_as_uint(),
            size + 4,
            1000,
          )
          let input_f : Array[Double] = Array::make(size + 4, 0.0)
          for j = 0; j < size + 4; j = j + 1 {
            input_f[j] = input[j].to_double()
          }
          let q34 = ar_f32(1.0 / 1.0) * 0.0 + 1.5
          let a : Array[Int32] = Array::make(size, 0)
          let b : Array[Int32] = Array::make(size, 0)
          ar_quantize_bands(
            a, input_f, 1, scaled, 2, size, is_signed, maxval, q34,
          )
          aac_quantize_bands_v128(
            b, input_f, 1, scaled, 2, size, is_signed, maxval, q34,
          )
          for i = 0; i < size; i = i + 1 {
            assert_eq(b[i], a[i])
          }
        }
      }
    }
  }
}

///|
test "aacenc dsp v128: scalarproduct_int16 matches the int64 dot" {
  for n in [1, 2, 3, 7, 8, 9, 16, 64] {
    let s1 = ar_gen_i32(0x11111111U + n.reinterpret_as_uint(), n + 8, 32767)
    let s2 = ar_gen_i32(0x22222222U + n.reinterpret_as_uint(), n + 8, 32767)
    for off in [0, 1, 4] {
      let a = ar_scalarproduct_int16(s1, off, s2, off, n)
      let b = aac_scalarproduct_int16_v128(s1, off, s2, off, n)
      assert_true(a == b)
    }
  }
  // pmaddwd pair sums must stay inside i32: (-32768)^2 is 2^30, and a pair
  // sums to 2^31, which wraps. Use a magnitude that exercises the wide
  // accumulator without wrapping.
  let s1 : Array[Int32] = Array::make(8, 30000)
  let s2 : Array[Int32] = Array::make(8, -30000)
  assert_true(
    aac_scalarproduct_int16_v128(s1, 0, s2, 0, 8) ==
    ar_scalarproduct_int16(s1, 0, s2, 0, 8),
  )
}

///|
test "ac3 dsp v128: extract_exponents matches the bit scan" {
  for n in [1, 2, 3, 4, 5, 16, 32] {
    for k = 0; k < 3; k = k + 1 {
      let input = ar_gen_i32(
        0x77777777U + n.reinterpret_as_uint() + k.reinterpret_as_uint(),
        n,
        0x7FFFFFFF,
      )
      let a : Array[Int32] = Array::make(n, 0)
      let b : Array[Int32] = Array::make(n, 0)
      ar_extract_exponents(a, input, n)
      ac3_extract_exponents_v128(b, input, n)
      for i = 0; i < n; i = i + 1 {
        assert_eq(b[i], a[i])
        assert_true(b[i] >= 0)
        assert_true(b[i] <= 24)
      }
    }
  }
  // corner cases: |0| and |1| both clamp to 0 (clz 32 / 31 -> 27-clz < 0);
  // 2^30 gives 27-1 = 26 -> clamped to 24
  let corner : Array[Int32] = [0, 1, -1, 2, 3, 0x7FFFFFFF, 0x40000000, 24]
  let ca : Array[Int32] = Array::make(8, 0)
  let cb : Array[Int32] = Array::make(8, 0)
  ar_extract_exponents(ca, corner, 8)
  ac3_extract_exponents_v128(cb, corner, 8)
  for i = 0; i < 8; i = i + 1 {
    assert_eq(cb[i], ca[i])
  }
  assert_eq(cb[0], 0)
  assert_eq(cb[1], 0)
  assert_eq(cb[6], 24)
}
