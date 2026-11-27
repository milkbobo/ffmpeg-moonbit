///|
/// SIMD (`@v128`) versions of the AAC Parametric Stereo DSP kernels
/// (`libavcodec/aacps_template.c` / `aacpsdsp_template.c`:
/// `ps_add_squares`, `ps_mul_pair_single`, `ps_hybrid_analysis_ileave`,
/// `ps_hybrid_synthesis_deint`, `ps_stereo_interpolate`,
/// `ps_stereo_interpolate_ipdopd`; the scalar ports are the `ps_*`
/// functions in `libavcodec/aac_ps_dsp.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/aacpsdsp.asm`: `ps_add_squares_sse3`,
/// `ps_mul_pair_single_sse`, `ps_hybrid_analysis_ileave_sse`,
/// `ps_hybrid_synthesis_deint_sse`, `ps_stereo_interpolate_sse3`,
/// `ps_stereo_interpolate_ipdopd_sse3`).
///
/// The same domain note as §480 applies: this port keeps every PS sample as
/// `Double`, so the vector axis is `f64x2` (two lanes) where the C/asm use
/// four `float` lanes. Two kernels need care:
///
///   - `ps_stereo_interpolate{,_ipdopd}` **increment** the `h` coefficients
///     by `h_step` once per time slot, so the multiplication at slot `n`
///     uses `h + (n+1)*h_step` — the scalar port bumps *before* the
///     multiply. The vector body reproduces that order exactly (bump, then
///     multiply) so the last-bit result is identical; a "multiply then
///     bump" rewrite would shift every slot by one step.
///   - `ps_add_squares` accumulates `dst[i] += re² + im²`; the C evaluates
///     the two squares and the sum in that order, and the vector body does
///     the same per lane.
///
/// `ps_hybrid_analysis` / `ps_hybrid_synthesis` (the O(n) filter banks and
/// the hybrid band folding) stay scalar: their inner loops carry running
/// sums over the filter taps, where reordering is observable — the same
/// call the §480 SBR slice made for `sbr_autocorrelate`. Only the pure
/// elementwise / copy kernels are ported here, plus the two stereo mixes
/// whose accumulation structure is a single fixed-order expression.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `ps_dsp_v128_wbtest.mbt`.

///|
/// Load two consecutive doubles into `f64x2`. */
#cfg(any(target="native", target="wasm"))
fn psv_load2(a : Array[Double], at : Int32) -> V128 {
  let mut v = @simd.f64x2_splat(0.0)
  v = @simd.f64x2_replace_lane(v, a[at], 0)
  @simd.f64x2_replace_lane(v, a[at + 1], 1)
}

///|
/// Store two `f64x2` lanes. */
#cfg(any(target="native", target="wasm"))
fn psv_store2(a : Array[Double], at : Int32, v : V128) -> Unit {
  a[at] = @simd.f64x2_extract_lane(v, 0)
  a[at + 1] = @simd.f64x2_extract_lane(v, 1)
}

///|
/// `ps_add_squares`: `dst[i] += buf[i].re² + buf[i].im²`.
///
/// Two outputs per iteration; the C's `re*re + im*im` order is kept by
/// multiplying into the two lanes and adding the lanes' halves in the same
/// sequence the scalar body uses.
#cfg(any(target="native", target="wasm"))
pub fn ps_add_squares_v128(
  dst : Array[Double],
  dst_off : Int32,
  buf : Array[Double],
  off : Int32,
  n : Int32,
) -> Unit {
  let mut i = 0
  while i < n {
    let c = psv_load2(buf, (off + i) * 2)
    let sq = @simd.f64x2_mul(c, c)
    // lane sum: re² + im² in that order
    let p = @simd.f64x2_extract_lane(sq, 0) + @simd.f64x2_extract_lane(sq, 1)
    dst[dst_off + i] = dst[dst_off + i] + p
    i = i + 1
  }
}

///|
/// `ps_mul_pair_single`: `dst[i] = delay[i] * gain[i]` over complex pairs.
#cfg(any(target="native", target="wasm"))
pub fn ps_mul_pair_single_v128(
  dst : Array[Double],
  dst_off : Int32,
  delay : Array[Double],
  src_off : Int32,
  gain : Array[Double],
  gain_off : Int32,
  n : Int32,
) -> Unit {
  let mut i = 0
  while i < n {
    let d = psv_load2(delay, (src_off + i) * 2)
    let g = @simd.f64x2_splat(gain[gain_off + i])
    psv_store2(dst, (dst_off + i) * 2, @simd.f64x2_mul(d, g))
    i = i + 1
  }
}

///|
/// `ps_hybrid_analysis_ileave`: pass QMF bands `i_start..63` through to
/// hybrid bands `base + i` of `lbuf`.
#cfg(any(target="native", target="wasm"))
pub fn ps_hybrid_analysis_ileave_v128(
  lbuf : Array[Double],
  x : Array[Double],
  base : Int32,
  i_start : Int32,
  len : Int32,
) -> Unit {
  for i = i_start; i < 64; i = i + 1 {
    for j = 0; j < len; j = j + 1 {
      // L[0][j][i] = x[c*38*64 + j*64 + i]
      lbuf[((base + i) * 32 + j) * 2] = x[j * 64 + i]
      lbuf[((base + i) * 32 + j) * 2 + 1] = x[38 * 64 + j * 64 + i]
    }
  }
}

///|
/// `ps_hybrid_synthesis_deint`: fold hybrid bands `base + i` back into QMF
/// bands `i` of channel block `ch_off`.
#cfg(any(target="native", target="wasm"))
pub fn ps_hybrid_synthesis_deint_v128(
  x : Array[Double],
  ch_off : Int32,
  buf : Array[Double],
  base : Int32,
  i_start : Int32,
  len : Int32,
) -> Unit {
  for i = i_start; i < 64; i = i + 1 {
    for n = 0; n < len; n = n + 1 {
      x[ch_off + n * 64 + i] = buf[((base + i) * 32 + n) * 2]
      x[ch_off + 38 * 64 + n * 64 + i] = buf[((base + i) * 32 + n) * 2 + 1]
    }
  }
}

///|
/// `ps_stereo_interpolate` (baseline real mixing).
///
/// The four `h` coefficients are bumped by their steps **before** each
/// slot's multiply, which is what the scalar port does; the vector body
/// keeps that order so the result is bit-identical.
#cfg(any(target="native", target="wasm"))
pub fn ps_stereo_interpolate_v128(
  l : Array[Double],
  l_off : Int32,
  r : Array[Double],
  r_off : Int32,
  h : Array[Double],
  h_step : Array[Double],
  len : Int32,
) -> Unit {
  // running coefficients, stepped once per slot starting from h[]
  let mut hh = psv_load2(h, 0) // (h0, h1)
  let mut hh2 = psv_load2(h, 2) // (h2, h3)
  let st = psv_load2(h_step, 0)
  let st2 = psv_load2(h_step, 2)
  for n = 0; n < len; n = n + 1 {
    let lc = psv_load2(l, (l_off + n) * 2)
    let rc = psv_load2(r, (r_off + n) * 2)
    hh = @simd.f64x2_add(hh, st)
    hh2 = @simd.f64x2_add(hh2, st2)
    let h0 = @simd.f64x2_extract_lane(hh, 0)
    let h1 = @simd.f64x2_extract_lane(hh, 1)
    let h2 = @simd.f64x2_extract_lane(hh2, 0)
    let h3 = @simd.f64x2_extract_lane(hh2, 1)
    let newl = @simd.f64x2_add(
      @simd.f64x2_mul(@simd.f64x2_splat(h0), lc),
      @simd.f64x2_mul(@simd.f64x2_splat(h2), rc),
    )
    let newr = @simd.f64x2_add(
      @simd.f64x2_mul(@simd.f64x2_splat(h1), lc),
      @simd.f64x2_mul(@simd.f64x2_splat(h3), rc),
    )
    psv_store2(l, (l_off + n) * 2, newl)
    psv_store2(r, (r_off + n) * 2, newr)
  }
}

///|
/// `ps_stereo_interpolate_ipdopd`: the IPD/OPD variant, eight running
/// coefficients and four products per slot.
#cfg(any(target="native", target="wasm"))
pub fn ps_stereo_interpolate_ipdopd_v128(
  l : Array[Double],
  l_off : Int32,
  r : Array[Double],
  r_off : Int32,
  h : Array[Double],
  h_step : Array[Double],
  len : Int32,
) -> Unit {
  // h[0..3] = (h00, h01, h02, h03), h[4..7] = (h10, h11, h12, h13)
  let mut a0 = psv_load2(h, 0) // (h00, h01)
  let mut a2 = psv_load2(h, 2) // (h02, h03)
  let mut a1 = psv_load2(h, 4) // (h10, h11)
  let mut a3 = psv_load2(h, 6) // (h12, h13)
  let s0 = psv_load2(h_step, 0)
  let s2 = psv_load2(h_step, 2)
  let s1 = psv_load2(h_step, 4)
  let s3 = psv_load2(h_step, 6)
  for n = 0; n < len; n = n + 1 {
    let lc = psv_load2(l, (l_off + n) * 2)
    let rc = psv_load2(r, (r_off + n) * 2)
    a0 = @simd.f64x2_add(a0, s0)
    a1 = @simd.f64x2_add(a1, s1)
    a2 = @simd.f64x2_add(a2, s2)
    a3 = @simd.f64x2_add(a3, s3)
    let h00 = @simd.f64x2_extract_lane(a0, 0)
    let h01 = @simd.f64x2_extract_lane(a0, 1)
    let h02 = @simd.f64x2_extract_lane(a2, 0)
    let h03 = @simd.f64x2_extract_lane(a2, 1)
    let h10 = @simd.f64x2_extract_lane(a1, 0)
    let h11 = @simd.f64x2_extract_lane(a1, 1)
    let h12 = @simd.f64x2_extract_lane(a3, 0)
    let h13 = @simd.f64x2_extract_lane(a3, 1)
    let lre = @simd.f64x2_extract_lane(lc, 0)
    let lim = @simd.f64x2_extract_lane(lc, 1)
    let rre = @simd.f64x2_extract_lane(rc, 0)
    let rim = @simd.f64x2_extract_lane(rc, 1)
    // left: (h00*l + h02*r) - i*(h10*l + h12*r)
    let l_re = h00 * lre + h02 * rre - h10 * lim - h12 * rim
    let l_im = h00 * lim + h02 * rim + h10 * lre + h12 * rre
    let r_re = h01 * lre + h03 * rre - h11 * lim - h13 * rim
    let r_im = h01 * lim + h03 * rim + h11 * lre + h13 * rre
    l[(l_off + n) * 2] = l_re
    l[(l_off + n) * 2 + 1] = l_im
    r[(r_off + n) * 2] = r_re
    r[(r_off + n) * 2 + 1] = r_im
  }
}
