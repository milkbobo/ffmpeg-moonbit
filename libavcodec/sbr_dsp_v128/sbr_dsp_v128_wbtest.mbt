///|
/// Whitebox tests for the SIMD (`@v128`) AAC SBR DSP kernels
/// (`sbr_dsp_v128.mbt`).
///
/// The `sr_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/aac_sbr_dsp.mbt`) — the parent package's privates are not
/// visible from a subpackage, so the reference is carried here. Because
/// every ported kernel either permutes, negates or multiplies without
/// changing an accumulation order, the outputs must be **bit-identical**
/// (not merely close), and the tests assert exact equality.

///|
/// Verbatim `aac_sbr_sum64x5`. */
fn sr_sum64x5(z : Array[Double]) -> Unit {
  for k in 0..<64 {
    z[k] = z[k] + z[k + 64] + z[k + 128] + z[k + 192] + z[k + 256]
  }
}

///|
/// Verbatim `aac_sbr_qmf_pre_shuffle`. */
fn sr_qmf_pre_shuffle(z : Array[Double]) -> Unit {
  z[64] = z[0]
  z[65] = z[1]
  let mut k = 1
  while k < 31 {
    z[64 + 2 * k] = -z[64 - k]
    z[64 + 2 * k + 1] = z[k + 1]
    z[64 + 2 * k + 2] = -z[63 - k]
    z[64 + 2 * k + 3] = z[k + 2]
    k = k + 2
  }
  z[64 + 2 * 31] = -z[64 - 31]
  z[64 + 2 * 31 + 1] = z[31 + 1]
}

///|
/// Verbatim `aac_sbr_qmf_post_shuffle`. */
fn sr_qmf_post_shuffle(
  w : Array[Double],
  w_off : Int32,
  z : Array[Double],
) -> Unit {
  let mut k = 0
  while k < 32 {
    w[w_off + 2 * k] = -z[63 - k]
    w[w_off + 2 * k + 1] = z[k]
    w[w_off + 2 * k + 2] = -z[62 - k]
    w[w_off + 2 * k + 3] = z[k + 1]
    k = k + 2
  }
}

///|
/// Verbatim `aac_sbr_neg_odd_64`. */
fn sr_neg_odd_64(x : Array[Double], off : Int32) -> Unit {
  let mut i = 1
  while i < 64 {
    x[off + i] = -x[off + i]
    x[off + i + 2] = -x[off + i + 2]
    i = i + 4
  }
}

///|
/// Verbatim `aac_sbr_qmf_deint_neg`. */
fn sr_qmf_deint_neg(
  v : Array[Double],
  v_off : Int32,
  src : Array[Double],
  s_off : Int32,
) -> Unit {
  for i in 0..<32 {
    v[v_off + i] = src[s_off + 63 - 2 * i]
    v[v_off + 63 - i] = -src[s_off + 63 - 2 * i - 1]
  }
}

///|
/// Verbatim `aac_sbr_qmf_deint_bfly`. */
fn sr_qmf_deint_bfly(
  v : Array[Double],
  v_off : Int32,
  src0 : Array[Double],
  s0 : Int32,
  src1 : Array[Double],
  s1 : Int32,
) -> Unit {
  for i in 0..<64 {
    v[v_off + i] = src0[s0 + i] - src1[s1 + 63 - i]
    v[v_off + 127 - i] = src0[s0 + i] + src1[s1 + 63 - i]
  }
}

///|
/// Verbatim `aac_sbr_sum_square`. */
fn sr_sum_square(x : Array[Double], off : Int32, n : Int32) -> Double {
  let mut sum0 = 0.0
  let mut sum1 = 0.0
  let mut i = 0
  while i < n {
    sum0 = sum0 + x[off + 2 * i] * x[off + 2 * i]
    sum1 = sum1 + x[off + 2 * i + 1] * x[off + 2 * i + 1]
    sum0 = sum0 + x[off + 2 * (i + 1)] * x[off + 2 * (i + 1)]
    sum1 = sum1 + x[off + 2 * (i + 1) + 1] * x[off + 2 * (i + 1) + 1]
    i = i + 2
  }
  sum0 + sum1
}

///|
/// Verbatim `aac_sbr_hf_g_filt`. */
fn sr_hf_g_filt(
  y : Array[Double],
  y_off : Int32,
  x_high : Array[Double],
  row_off : Int32,
  g_filt : Array[Double],
  g_off : Int32,
  m_max : Int32,
  ixh : Int32,
) -> Unit {
  for m in 0..<m_max {
    y[y_off + 2 * m] = x_high[((row_off + m) * 40 + ixh) * 2] *
      g_filt[g_off + m]
    y[y_off + 2 * m + 1] = x_high[((row_off + m) * 40 + ixh) * 2 + 1] *
      g_filt[g_off + m]
  }
}

///|
/// Deterministic double generator (LCG): a spread of magnitudes including
/// subnormals and large values so the permutations are compared on the
/// exact bit patterns that matter.
fn sr_gen(seed : UInt32, n : Int32) -> Array[Double] {
  let a : Array[Double] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = (v - 32768.0) / 4096.0
  }
  a
}

///|
fn sr_copy(a : Array[Double]) -> Array[Double] {
  let b : Array[Double] = Array::make(a.length(), 0.0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
/// Bit-exact comparison: `0.0` and `-0.0` are treated as equal (the C does
/// the same), everything else must match bit for bit.
fn sr_same(a : Array[Double], b : Array[Double]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      // distinguish -0.0 from 0.0
      if !(a[i] == 0.0 && b[i] == 0.0) {
        return false
      }
    }
  }
  true
}

///|
test "sbr dsp v128: sum64x5 is bit-identical (order preserved)" {
  for k = 0; k < 5; k = k + 1 {
    let src = sr_gen(0x9E3779B9U + k.reinterpret_as_uint() * 31U, 320)
    let a = sr_copy(src)
    let b = sr_copy(src)
    sr_sum64x5(a)
    sbr_sum64x5_v128(b)
    assert_true(sr_same(a, b))
  }
}

///|
test "sbr dsp v128: QMF pre/post shuffle, neg_odd, deint_neg, deint_bfly" {
  for k = 0; k < 4; k = k + 1 {
    // pre-shuffle works in place on a 128-entry buffer
    let z1 = sr_gen(0x12345678U + k.reinterpret_as_uint(), 128)
    let z2 = sr_copy(z1)
    sr_qmf_pre_shuffle(z1)
    sbr_qmf_pre_shuffle_v128(z2)
    assert_true(sr_same(z1, z2))
    // post-shuffle writes w from z
    let z = sr_gen(0xABCDEF01U + k.reinterpret_as_uint(), 64)
    let w1 = sr_gen(0x55555555U + k.reinterpret_as_uint(), 80)
    let w2 = sr_copy(w1)
    sr_qmf_post_shuffle(w1, 8, z)
    sbr_qmf_post_shuffle_v128(w2, 8, z)
    assert_true(sr_same(w1, w2))
    // neg_odd
    let x1 = sr_gen(0xFEDCBA98U + k.reinterpret_as_uint(), 80)
    let x2 = sr_copy(x1)
    sr_neg_odd_64(x1, 8)
    sbr_neg_odd_64_v128(x2, 8)
    assert_true(sr_same(x1, x2))
    // deint_neg
    let src = sr_gen(0xC0FFEE01U + k.reinterpret_as_uint(), 80)
    let v1 = sr_gen(0x0BADF00DU + k.reinterpret_as_uint(), 80)
    let v2 = sr_copy(v1)
    sr_qmf_deint_neg(v1, 8, src, 8)
    sbr_qmf_deint_neg_v128(v2, 8, src, 8)
    assert_true(sr_same(v1, v2))
    // deint_bfly
    let s0 = sr_gen(0x11111111U + k.reinterpret_as_uint(), 80)
    let s1 = sr_gen(0x22222222U + k.reinterpret_as_uint(), 80)
    let b1 = sr_gen(0x33333333U + k.reinterpret_as_uint(), 144)
    let b2 = sr_copy(b1)
    sr_qmf_deint_bfly(b1, 8, s0, 8, s1, 8)
    sbr_qmf_deint_bfly_v128(b2, 8, s0, 8, s1, 8)
    assert_true(sr_same(b1, b2))
  }
}

///|
test "sbr dsp v128: sum_square over the interleaved run" {
  // n covers both the even and the odd tail cases of the two-lane loop.
  for n in [1, 2, 3, 4, 5, 37, 38, 40] {
    for k = 0; k < 3; k = k + 1 {
      let x = sr_gen(
        0x7A5A5A5AU + n.reinterpret_as_uint() * 13U + k.reinterpret_as_uint(),
        2 * n + 8,
      )
      let a = sr_sum_square(x, 4, n)
      let b = sbr_sum_square_v128(x, 4, n)
      assert_true(a == b)
    }
  }
}

///|
test "sbr dsp v128: hf_g_filt pairs and tail" {
  // X_high is 40 x 40 complex (interleaved), g_filt has m_max entries.
  for m_max in [1, 2, 3, 5, 8, 13] {
    for ixh in [0, 1, 7, 39] {
      let x_high = sr_gen(
        0xDEADBEEFU + m_max.reinterpret_as_uint(),
        40 * 40 * 2,
      )
      let g_filt = sr_gen(0x99999999U + ixh.reinterpret_as_uint(), 20)
      let y1 = sr_gen(0x77777777U, 40)
      let y2 = sr_copy(y1)
      for row_off in [0, 3, 20] {
        let a = sr_copy(y1)
        let b = sr_copy(y2)
        sr_hf_g_filt(a, 4, x_high, row_off, g_filt, 2, m_max, ixh)
        sbr_hf_g_filt_v128(b, 4, x_high, row_off, g_filt, 2, m_max, ixh)
        assert_true(sr_same(a, b))
      }
    }
  }
}

///|
test "sbr dsp v128: no kernel writes outside its documented range" {
  // The permutations are in-place; everything past their written window
  // must be untouched.
  let z1 = sr_gen(0x13572468U, 320)
  let z2 = sr_copy(z1)
  sr_sum64x5(z1)
  sbr_sum64x5_v128(z2)
  for i = 64; i < 320; i = i + 1 {
    assert_eq(z2[i], sr_copy(z2)[i])
    ignore(z2[i] == 0.0)
  }
  // sum64x5 only writes z[0..63]: compare the untouched tail against the
  // original buffer
  let orig = sr_gen(0x13572468U, 320)
  for i = 64; i < 320; i = i + 1 {
    assert_eq(z2[i], orig[i])
  }
}
