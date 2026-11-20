///|
/// Whitebox tests for the SIMD (`@v128`) shared float DSP primitives
/// (`float_dsp_v128.mbt`).
///
/// The `fr_*` functions are verbatim transcriptions of the C reference
/// (`libavutil/float_dsp.c` and `libavutil/float_dsp.h`) — the parent
/// package's privates are not visible from a subpackage, so the reference is
/// carried here. Every elementwise kernel must be **bit-identical**; the two
/// dot products also assert bit-identical results because the port preserves
/// the C's sequential summation order.

///|
/// Verbatim `vector_fmul`. */
fn fr_vector_fmul(
  dst : Array[Float],
  src0 : Array[Float],
  src1 : Array[Float],
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = src0[i] * src1[i]
  }
}

///|
/// Verbatim `vector_fmac_scalar`. */
fn fr_vector_fmac_scalar(
  dst : Array[Float],
  src : Array[Float],
  mul : Float,
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = dst[i] + src[i] * mul
  }
}

///|
/// Verbatim `vector_fmul_scalar`. */
fn fr_vector_fmul_scalar(
  dst : Array[Float],
  src : Array[Float],
  mul : Float,
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = src[i] * mul
  }
}

///|
/// Verbatim `vector_fmul_add`. */
fn fr_vector_fmul_add(
  dst : Array[Float],
  src0 : Array[Float],
  src1 : Array[Float],
  src2 : Array[Float],
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = src0[i] * src1[i] + src2[i]
  }
}

///|
/// Verbatim `vector_fmul_reverse`. */
fn fr_vector_fmul_reverse(
  dst : Array[Float],
  src0 : Array[Float],
  src1 : Array[Float],
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = src0[i] * src1[len - 1 - i]
  }
}

///|
/// Verbatim `vector_fmul_window`. */
fn fr_vector_fmul_window(
  dst : Array[Float],
  dst_off : Int32,
  src0 : Array[Float],
  s0_off : Int32,
  src1 : Array[Float],
  s1_off : Int32,
  win : Array[Float],
  w_off : Int32,
  len : Int32,
) -> Unit {
  let mut i = 0 - len
  let mut j = len - 1
  while i < 0 {
    let s0 = src0[s0_off + len + i]
    let s1 = src1[s1_off + j]
    let wi = win[w_off + len + i]
    let wj = win[w_off + j]
    dst[dst_off + len + i] = s0 * wj - s1 * wi
    dst[dst_off + j] = s0 * wi + s1 * wj
    i = i + 1
    j = j - 1
  }
}

///|
/// Verbatim `butterflies_float`. */
fn fr_butterflies_float(v1 : Array[Float], v2 : Array[Float], len : Int32) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let t = v1[i] - v2[i]
    v1[i] = v1[i] + v2[i]
    v2[i] = t
  }
}

///|
/// Verbatim `scalarproduct_float`. */
fn fr_scalarproduct_float(v1 : Array[Float], v2 : Array[Float], len : Int32) -> Float {
  let mut p : Float = 0.0
  for i = 0; i < len; i = i + 1 {
    p = p + v1[i] * v2[i]
  }
  p
}

///|
/// Verbatim `vector_dmul`. */
fn fr_vector_dmul(
  dst : Array[Double],
  src0 : Array[Double],
  src1 : Array[Double],
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = src0[i] * src1[i]
  }
}

///|
/// Verbatim `vector_dmac_scalar`. */
fn fr_vector_dmac_scalar(
  dst : Array[Double],
  src : Array[Double],
  mul : Double,
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = dst[i] + src[i] * mul
  }
}

///|
/// Verbatim `vector_dmul_scalar`. */
fn fr_vector_dmul_scalar(
  dst : Array[Double],
  src : Array[Double],
  mul : Double,
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    dst[i] = src[i] * mul
  }
}

///|
/// Verbatim `scalarproduct_double`. */
fn fr_scalarproduct_double(v1 : Array[Double], v2 : Array[Double], len : Int32) -> Double {
  let mut p = 0.0
  for i = 0; i < len; i = i + 1 {
    p = p + v1[i] * v2[i]
  }
  p
}

///|
/// Deterministic `Float` generator (LCG) over a modest magnitude range so
/// products do not immediately overflow or flush to zero.
fn fr_gen(seed : UInt32, n : Int32) -> Array[Float] {
  let a : Array[Float] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = Float::from_double((v - 32768.0) / 8192.0)
  }
  a
}

///|
/// Deterministic `Double` generator (LCG). */
fn fr_gen_d(seed : UInt32, n : Int32) -> Array[Double] {
  let a : Array[Double] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = (v - 32768.0) / 8192.0
  }
  a
}

///|
fn fr_copy(a : Array[Float]) -> Array[Float] {
  let b : Array[Float] = Array::make(a.length(), 0.0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn fr_copy_d(a : Array[Double]) -> Array[Double] {
  let b : Array[Double] = Array::make(a.length(), 0.0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
/// Bit-exact comparison. `0.0` / `-0.0` are treated as equal; NaN never is.
fn fr_same(a : Array[Float], b : Array[Float]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      if !(a[i] == 0.0 && b[i] == 0.0) {
        return false
      }
    }
  }
  true
}

///|
fn fr_same_d(a : Array[Double], b : Array[Double]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      if !(a[i] == 0.0 && b[i] == 0.0) {
        return false
      }
    }
  }
  true
}

///|
test "float dsp v128: elementwise f32 kernels bit-exact" {
  for len in [1, 2, 3, 4, 5, 8, 17, 64, 257] {
    let seed = 0x9E3779B9U + len.reinterpret_as_uint() * 31U
    let s0 = fr_gen(seed, len)
    let s1 = fr_gen(seed + 7U, len)
    let s2 = fr_gen(seed + 13U, len)
    let base = fr_gen(seed + 21U, len)
    // fmul
    let a = fr_copy(base)
    let b = fr_copy(base)
    fr_vector_fmul(a, s0, s1, len)
    vector_fmul_v128(b, s0, s1, len)
    assert_true(fr_same(a, b))
    // fmac_scalar
    let c = fr_copy(base)
    let d = fr_copy(base)
    fr_vector_fmac_scalar(c, s0, 1.5, len)
    vector_fmac_scalar_v128(d, s0, 1.5, len)
    assert_true(fr_same(c, d))
    // fmul_scalar
    let e = fr_copy(base)
    let f = fr_copy(base)
    fr_vector_fmul_scalar(e, s0, -2.25, len)
    vector_fmul_scalar_v128(f, s0, -2.25, len)
    assert_true(fr_same(e, f))
    // fmul_add
    let g = fr_copy(base)
    let h = fr_copy(base)
    fr_vector_fmul_add(g, s0, s1, s2, len)
    vector_fmul_add_v128(h, s0, s1, s2, len)
    assert_true(fr_same(g, h))
    // fmul_reverse
    let i1 = fr_copy(base)
    let j1 = fr_copy(base)
    fr_vector_fmul_reverse(i1, s0, s1, len)
    vector_fmul_reverse_v128(j1, s0, s1, len)
    assert_true(fr_same(i1, j1))
  }
}

///|
test "float dsp v128: butterflies and window" {
  for len in [1, 2, 3, 4, 5, 8, 17, 64] {
    let seed = 0x5A5A5A5AU + len.reinterpret_as_uint() * 17U
    let v1 = fr_gen(seed, len)
    let v2 = fr_gen(seed + 3U, len)
    let a1 = fr_copy(v1)
    let a2 = fr_copy(v2)
    fr_butterflies_float(a1, a2, len)
    let b1 = fr_copy(v1)
    let b2 = fr_copy(v2)
    butterflies_float_v128(b1, b2, len)
    assert_true(fr_same(a1, b1))
    assert_true(fr_same(a2, b2))
    // window: dst has len slots after the offset; src0/win need 2*len
    let s0 = fr_gen(seed + 11U, 2 * len)
    let s1 = fr_gen(seed + 19U, 2 * len)
    let win = fr_gen(seed + 23U, 2 * len)
    let dst_a = fr_gen(seed + 29U, 2 * len)
    let dst_b = fr_copy(dst_a)
    fr_vector_fmul_window(dst_a, 0, s0, 0, s1, 0, win, 0, len)
    vector_fmul_window_v128(dst_b, 0, s0, 0, s1, 0, win, 0, len)
    assert_true(fr_same(dst_a, dst_b))
  }
}

///|
test "float dsp v128: scalarproduct_float preserves summation order" {
  // Adversarial input: alternating large/small magnitudes make ANY
  // reordering of the sum observable, which is exactly what this kernel
  // must not do.
  let len : Int32 = 8
  let v1 : Array[Float] = [1.0e8, 1.0, -1.0e8, 1.0, 1.0e8, 1.0, -1.0e8, 1.0]
  let v2 : Array[Float] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let a = fr_scalarproduct_float(v1, v2, len)
  let b = scalarproduct_float_v128(v1, v2, len)
  assert_true(a == b)
  // and over a variety of lengths and random data
  for n in [1, 2, 3, 4, 5, 8, 17, 64, 257] {
    let seed = 0xABCDEF01U + n.reinterpret_as_uint()
    let x = fr_gen(seed, n)
    let y = fr_gen(seed + 5U, n)
    assert_true(fr_scalarproduct_float(x, y, n) == scalarproduct_float_v128(x, y, n))
  }
}

///|
test "float dsp v128: f64 kernels bit-exact" {
  for len in [1, 2, 3, 4, 5, 8, 17, 64] {
    let seed = 0x12345678U + len.reinterpret_as_uint() * 13U
    let s0 = fr_gen_d(seed, len)
    let s1 = fr_gen_d(seed + 7U, len)
    let base = fr_gen_d(seed + 11U, len)
    let a = fr_copy_d(base)
    let b = fr_copy_d(base)
    fr_vector_dmul(a, s0, s1, len)
    vector_dmul_v128(b, s0, s1, len)
    assert_true(fr_same_d(a, b))
    let c = fr_copy_d(base)
    let d = fr_copy_d(base)
    fr_vector_dmac_scalar(c, s0, 0.5, len)
    vector_dmac_scalar_v128(d, s0, 0.5, len)
    assert_true(fr_same_d(c, d))
    let e = fr_copy_d(base)
    let f = fr_copy_d(base)
    fr_vector_dmul_scalar(e, s0, -1.25, len)
    vector_dmul_scalar_v128(f, s0, -1.25, len)
    assert_true(fr_same_d(e, f))
    // scalarproduct_double keeps the sequential order too
    assert_true(
      fr_scalarproduct_double(s0, s1, len) ==
      scalarproduct_double_v128(s0, s1, len),
    )
  }
}

///|
test "float dsp v128: scalarproduct_double order sensitivity" {
  let len : Int32 = 6
  let v1 : Array[Double] = [1.0e16, 1.0, -1.0e16, 1.0, 1.0e16, 1.0]
  let v2 : Array[Double] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  assert_true(
    fr_scalarproduct_double(v1, v2, len) == scalarproduct_double_v128(v1, v2, len),
  )
}
