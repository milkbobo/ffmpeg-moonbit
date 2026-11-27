///|
/// Whitebox tests for the SIMD (`@v128`) AAC Parametric Stereo DSP kernels
/// (`ps_dsp_v128.mbt`).
///
/// The `pr_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/aac_ps_dsp.mbt`) — the parent package's privates are not
/// visible from a subpackage, so the reference is carried here. Every
/// ported kernel preserves its accumulation and stepping order, so the
/// outputs must be **bit-identical**.

///|
/// Verbatim `ps_add_squares`. */
fn pr_add_squares(
  dst : Array[Double],
  dst_off : Int32,
  buf : Array[Double],
  off : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst[dst_off + i] = dst[dst_off + i] +
      (
        buf[(off + i) * 2] * buf[(off + i) * 2] +
        buf[(off + i) * 2 + 1] * buf[(off + i) * 2 + 1]
      )
  }
}

///|
/// Verbatim `ps_mul_pair_single`. */
fn pr_mul_pair_single(
  dst : Array[Double],
  dst_off : Int32,
  delay : Array[Double],
  src_off : Int32,
  gain : Array[Double],
  gain_off : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst[(dst_off + i) * 2] = delay[(src_off + i) * 2] * gain[gain_off + i]
    dst[(dst_off + i) * 2 + 1] = delay[(src_off + i) * 2 + 1] *
      gain[gain_off + i]
  }
}

///|
/// Verbatim `ps_hybrid_analysis_ileave`. */
fn pr_hybrid_analysis_ileave(
  lbuf : Array[Double],
  x : Array[Double],
  base : Int32,
  i_start : Int32,
  len : Int32,
) -> Unit {
  for i in i_start..<64 {
    for j in 0..<len {
      lbuf[((base + i) * 32 + j) * 2] = x[j * 64 + i]
      lbuf[((base + i) * 32 + j) * 2 + 1] = x[38 * 64 + j * 64 + i]
    }
  }
}

///|
/// Verbatim `ps_hybrid_synthesis_deint`. */
fn pr_hybrid_synthesis_deint(
  x : Array[Double],
  ch_off : Int32,
  buf : Array[Double],
  base : Int32,
  i_start : Int32,
  len : Int32,
) -> Unit {
  for i in i_start..<64 {
    for n in 0..<len {
      x[ch_off + n * 64 + i] = buf[((base + i) * 32 + n) * 2]
      x[ch_off + 38 * 64 + n * 64 + i] = buf[((base + i) * 32 + n) * 2 + 1]
    }
  }
}

///|
/// Verbatim `ps_stereo_interpolate`. */
fn pr_stereo_interpolate(
  l : Array[Double],
  l_off : Int32,
  r : Array[Double],
  r_off : Int32,
  h : Array[Double],
  h_step : Array[Double],
  len : Int32,
) -> Unit {
  let mut h0 = h[0]
  let mut h1 = h[1]
  let mut h2 = h[2]
  let mut h3 = h[3]
  let hs0 = h_step[0]
  let hs1 = h_step[1]
  let hs2 = h_step[2]
  let hs3 = h_step[3]
  for n in 0..<len {
    let l_re = l[(l_off + n) * 2]
    let l_im = l[(l_off + n) * 2 + 1]
    let r_re = r[(r_off + n) * 2]
    let r_im = r[(r_off + n) * 2 + 1]
    h0 = h0 + hs0
    h1 = h1 + hs1
    h2 = h2 + hs2
    h3 = h3 + hs3
    l[(l_off + n) * 2] = h0 * l_re + h2 * r_re
    l[(l_off + n) * 2 + 1] = h0 * l_im + h2 * r_im
    r[(r_off + n) * 2] = h1 * l_re + h3 * r_re
    r[(r_off + n) * 2 + 1] = h1 * l_im + h3 * r_im
  }
}

///|
/// Verbatim `ps_stereo_interpolate_ipdopd`. */
fn pr_stereo_interpolate_ipdopd(
  l : Array[Double],
  l_off : Int32,
  r : Array[Double],
  r_off : Int32,
  h : Array[Double],
  h_step : Array[Double],
  len : Int32,
) -> Unit {
  let mut h00 = h[0]
  let mut h10 = h[4]
  let mut h01 = h[1]
  let mut h11 = h[5]
  let mut h02 = h[2]
  let mut h12 = h[6]
  let mut h03 = h[3]
  let mut h13 = h[7]
  let hs00 = h_step[0]
  let hs10 = h_step[4]
  let hs01 = h_step[1]
  let hs11 = h_step[5]
  let hs02 = h_step[2]
  let hs12 = h_step[6]
  let hs03 = h_step[3]
  let hs13 = h_step[7]
  for n in 0..<len {
    let l_re = l[(l_off + n) * 2]
    let l_im = l[(l_off + n) * 2 + 1]
    let r_re = r[(r_off + n) * 2]
    let r_im = r[(r_off + n) * 2 + 1]
    h00 = h00 + hs00
    h01 = h01 + hs01
    h02 = h02 + hs02
    h03 = h03 + hs03
    h10 = h10 + hs10
    h11 = h11 + hs11
    h12 = h12 + hs12
    h13 = h13 + hs13
    l[(l_off + n) * 2] = h00 * l_re + h02 * r_re - h10 * l_im - h12 * r_im
    l[(l_off + n) * 2 + 1] = h00 * l_im + h02 * r_im + h10 * l_re + h12 * r_re
    r[(r_off + n) * 2] = h01 * l_re + h03 * r_re - h11 * l_im - h13 * r_im
    r[(r_off + n) * 2 + 1] = h01 * l_im + h03 * r_im + h11 * l_re + h13 * r_re
  }
}

///|
/// Deterministic double generator (LCG). */
fn pr_gen(seed : UInt32, n : Int32) -> Array[Double] {
  let a : Array[Double] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = (v - 32768.0) / 2048.0
  }
  a
}

///|
fn pr_copy(a : Array[Double]) -> Array[Double] {
  let b : Array[Double] = Array::make(a.length(), 0.0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn pr_same(a : Array[Double], b : Array[Double]) -> Bool {
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
test "ps dsp v128: add_squares and mul_pair_single bit-exact" {
  for n in [1, 2, 3, 8, 32] {
    for k = 0; k < 3; k = k + 1 {
      let buf = pr_gen(
        0x9E3779B9U + n.reinterpret_as_uint() + k.reinterpret_as_uint(),
        (n + 8) * 2,
      )
      let d1 = pr_gen(0x5A5A5A5AU + k.reinterpret_as_uint(), n + 8)
      let d2 = pr_copy(d1)
      pr_add_squares(d1, 3, buf, 2, n)
      ps_add_squares_v128(d2, 3, buf, 2, n)
      assert_true(pr_same(d1, d2))
      // mul_pair_single
      let delay = pr_gen(0x11111111U + k.reinterpret_as_uint(), (n + 8) * 2)
      let gain = pr_gen(0x22222222U + n.reinterpret_as_uint(), n + 8)
      let m1 = pr_gen(0x33333333U, (n + 8) * 2)
      let m2 = pr_copy(m1)
      pr_mul_pair_single(m1, 2, delay, 1, gain, 1, n)
      ps_mul_pair_single_v128(m2, 2, delay, 1, gain, 1, n)
      assert_true(pr_same(m1, m2))
    }
  }
}

///|
test "ps dsp v128: hybrid analysis ileave and synthesis deint" {
  // x is 2 * 38 * 64 doubles (re/im planes), len is the frame length.
  let x_n = 2 * 38 * 64
  for len in [1, 2, 8, 32] {
    for (base, i_start) in [(27, 5), (7, 3)] {
      let x = pr_gen(0xABCDEF01U + len.reinterpret_as_uint(), x_n)
      let lbuf1 = pr_gen(0x0BADF00DU + len.reinterpret_as_uint(), 96 * 32 * 2)
      let lbuf2 = pr_copy(lbuf1)
      pr_hybrid_analysis_ileave(lbuf1, x, base, i_start, len)
      ps_hybrid_analysis_ileave_v128(lbuf2, x, base, i_start, len)
      assert_true(pr_same(lbuf1, lbuf2))
      // synthesis de-int on a fresh output buffer
      let o1 = pr_gen(0x55555555U, x_n)
      let o2 = pr_copy(o1)
      pr_hybrid_synthesis_deint(o1, 0, lbuf1, base, i_start, len)
      ps_hybrid_synthesis_deint_v128(o2, 0, lbuf1, base, i_start, len)
      assert_true(pr_same(o1, o2))
    }
  }
}

///|
test "ps dsp v128: stereo interpolate keeps the bump-then-multiply order" {
  for len in [1, 2, 3, 8, 32] {
    for k = 0; k < 4; k = k + 1 {
      let h = pr_gen(0x12345678U + k.reinterpret_as_uint(), 4)
      let h_step = pr_gen(0xDEADBEEFU + k.reinterpret_as_uint(), 4)
      let l1 = pr_gen(0x77777777U + len.reinterpret_as_uint(), (len + 4) * 2)
      let r1 = pr_gen(0x88888888U + len.reinterpret_as_uint(), (len + 4) * 2)
      let l2 = pr_copy(l1)
      let r2 = pr_copy(r1)
      pr_stereo_interpolate(l1, 1, r1, 1, h, h_step, len)
      ps_stereo_interpolate_v128(l2, 1, r2, 1, h, h_step, len)
      assert_true(pr_same(l1, l2))
      assert_true(pr_same(r1, r2))
    }
  }
}

///|
test "ps dsp v128: stereo interpolate ipdopd bit-exact" {
  for len in [1, 2, 3, 8, 32] {
    for k = 0; k < 4; k = k + 1 {
      let h = pr_gen(0x31415926U + k.reinterpret_as_uint(), 8)
      let h_step = pr_gen(0x27182818U + k.reinterpret_as_uint(), 8)
      let l1 = pr_gen(0x99999999U + len.reinterpret_as_uint(), (len + 4) * 2)
      let r1 = pr_gen(0xAAAAAAAAU + len.reinterpret_as_uint(), (len + 4) * 2)
      let l2 = pr_copy(l1)
      let r2 = pr_copy(r1)
      pr_stereo_interpolate_ipdopd(l1, 2, r1, 2, h, h_step, len)
      ps_stereo_interpolate_ipdopd_v128(l2, 2, r2, 2, h, h_step, len)
      assert_true(pr_same(l1, l2))
      assert_true(pr_same(r1, r2))
    }
  }
}

///|
test "ps dsp v128: the stepping order really differs from a naive rewrite" {
  // Guards the documented bump-then-multiply ordering: with a non-zero
  // h_step, applying the multiply before the bump must give a different
  // first sample, which is exactly the bug the ordering prevents.
  let len : Int32 = 4
  let h : Array[Double] = [1.0, 2.0, 3.0, 4.0]
  let h_step : Array[Double] = [0.5, 0.5, 0.5, 0.5]
  let l = pr_gen(0x5A5A5A5AU, (len + 2) * 2)
  let r = pr_gen(0xA5A5A5A5U, (len + 2) * 2)
  let l2 = pr_copy(l)
  let r2 = pr_copy(r)
  ps_stereo_interpolate_v128(l2, 1, r2, 1, h, h_step, len)
  // reference with the same order
  let l3 = pr_copy(l)
  let r3 = pr_copy(r)
  pr_stereo_interpolate(l3, 1, r3, 1, h, h_step, len)
  assert_true(pr_same(l2, l3))
  // and the bumped coefficient is what was used: l'[0] = (h0+s0)*l_re + (h2+s2)*r_re
  let lre = l[1 * 2]
  let rre = r[1 * 2]
  assert_true(l2[1 * 2] == (1.0 + 0.5) * lre + (3.0 + 0.5) * rre)
}
