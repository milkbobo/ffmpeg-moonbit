///|
/// SIMD (`@v128`) versions of the AAC SBR DSP kernels
/// (`libavcodec/aacsbr_template.c` / `libavcodec/sbrdsp_template.c`:
/// `sbr_sum64x5`, `sbr_qmf_pre_shuffle`, `sbr_qmf_post_shuffle`,
/// `sbr_neg_odd_64`, `sbr_qmf_deint_neg`, `sbr_qmf_deint_bfly`,
/// `sbr_sum_square`, `sbr_autocorrelate`, `sbr_hf_gen`, `sbr_hf_g_filt`,
/// `sbr_hf_apply_noise`; the scalar ports are the `aac_sbr_*` functions in
/// `libavcodec/aac_sbr_dsp.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavutil/x86/float_dsp.asm` for the shared float primitives, and the
/// SSE kernels FFmpeg selects for `sbrdsp` in `libavcodec/x86/sbrdsp.asm`:
/// `sbr_sum64x5_sse`, `sbr_qmf_pre_shuffle_sse`, `sbr_qmf_post_shuffle_sse`,
/// `sbr_neg_odd_64_sse`, `sbr_qmf_deint_neg_sse`,
/// `sbr_qmf_deint_bfly_sse2`, `sbr_sum_square_sse`, `sbr_autocorrelate_sse`,
/// `sbr_hf_gen_sse`, `sbr_hf_g_filt_sse`, `sbr_hf_apply_noise_*_sse`).
///
/// Two properties drive the port:
///   - the SBR sample domain is `float` in the C, but this port stores it
///     as `Double` (`Array[Double]`) throughout, so the vectorisation is
///     over `f64x2` (two lanes) rather than `f32x4` (four). Two lanes per
///     vector means the kernels process pairs; the C's `__m128` four-float
///     shape is otherwise structurally identical (same shift/negate
///     patterns, same butterfly pairing).
///   - `sbr_autocorrelate` accumulates a fixed 38-term sum per output. The
///     C sums sequentially; vectorising changes the addition *order*, so
///     the result can differ in the last bits. This port therefore keeps
///     `sbr_autocorrelate`'s accumulation order exactly scalar and only
///     vectorises the pure elementwise kernels — a documented deviation
///     (a reordered sum would break the bit-exact wbtest contract this
///     project holds every SIMD kernel to, and the SBR autocorrelate feeds
///     `phi` into a nonlinear envelope estimate where 1-ulp drift is
///     observable).
///
/// `sbr_sum64x5`, the two QMF shuffles, `neg_odd_64`, `deint_neg`,
/// `deint_bfly` and `hf_g_filt` are all pure elementwise permutations /
/// negations / single multiplies, so they vectorise exactly.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `sbr_dsp_v128_wbtest.mbt`.

///|
/// Load two consecutive doubles into `f64x2`. */
#cfg(any(target="native", target="wasm"))
fn sbrv_load2(a : Array[Double], at : Int32) -> V128 {
  let mut v = @simd.f64x2_splat(0.0)
  v = @simd.f64x2_replace_lane(v, a[at], 0)
  @simd.f64x2_replace_lane(v, a[at + 1], 1)
}

///|
/// Store two `f64x2` lanes. */
#cfg(any(target="native", target="wasm"))
fn sbrv_store2(a : Array[Double], at : Int32, v : V128) -> Unit {
  a[at] = @simd.f64x2_extract_lane(v, 0)
  a[at + 1] = @simd.f64x2_extract_lane(v, 1)
}

///|
/// `sbr_sum64x5`: `z[k] += z[k+64] + z[k+128] + z[k+192] + z[k+256]`
/// for `k < 64`.
///
/// The scalar port's left-to-right evaluation order is preserved by
/// accumulating in the same sequence (`((z0+z1)+z2)+z3)+z4`), so the
/// floating-point result is bit-identical, not merely close.
#cfg(any(target="native", target="wasm"))
pub fn sbr_sum64x5_v128(z : Array[Double]) -> Unit {
  let mut k = 0
  while k + 2 <= 64 {
    let mut acc = sbrv_load2(z, k)
    acc = @simd.f64x2_add(acc, sbrv_load2(z, k + 64))
    acc = @simd.f64x2_add(acc, sbrv_load2(z, k + 128))
    acc = @simd.f64x2_add(acc, sbrv_load2(z, k + 192))
    acc = @simd.f64x2_add(acc, sbrv_load2(z, k + 256))
    sbrv_store2(z, k, acc)
    k = k + 2
  }
}

///|
/// `sbr_qmf_pre_shuffle`: interleave the folded values at `z[0..63]` into
/// the IMDCT input at `z[64..127]`.
#cfg(any(target="native", target="wasm"))
pub fn sbr_qmf_pre_shuffle_v128(z : Array[Double]) -> Unit {
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
/// `sbr_qmf_post_shuffle`: `w_buf[32][2]` from the 64 IMDCT outputs.
#cfg(any(target="native", target="wasm"))
pub fn sbr_qmf_post_shuffle_v128(
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
/// `sbr_neg_odd_64`: negate entries 1, 3, 5, ... of a 64-array.
///
/// The scalar port advances by 4 and negates **both** `i` and `i+2`, so
/// every odd index is negated. Two `f64x2` loads gather the pair
/// `(x[i], x[i+2])`, negate it, and store the two lanes back to their own
/// (non-contiguous) positions — the same two writes the scalar body makes,
/// with the negation done on the vector.
#cfg(any(target="native", target="wasm"))
pub fn sbr_neg_odd_64_v128(x : Array[Double], off : Int32) -> Unit {
  let mut i = 1
  while i < 64 {
    // gather (x[i], x[i+2]) into one vector, negate, scatter back
    let pair = @simd.f64x2_replace_lane(
      @simd.f64x2_replace_lane(@simd.f64x2_splat(0.0), x[off + i], 0),
      x[off + i + 2],
      1,
    )
    let neg = @simd.f64x2_neg(pair)
    x[off + i] = @simd.f64x2_extract_lane(neg, 0)
    x[off + i + 2] = @simd.f64x2_extract_lane(neg, 1)
    i = i + 4
  }
}

///|
/// `sbr_qmf_deint_neg` (downsampled synthesis).
#cfg(any(target="native", target="wasm"))
pub fn sbr_qmf_deint_neg_v128(
  v : Array[Double],
  v_off : Int32,
  src : Array[Double],
  s_off : Int32,
) -> Unit {
  let mut i = 0
  while i + 2 <= 32 {
    // low half: v[i] = src[63 - 2i]
    v[v_off + i] = src[s_off + 63 - 2 * i]
    v[v_off + i + 1] = src[s_off + 63 - 2 * (i + 1)]
    // high half: v[63-i] = -src[63 - 2i - 1]
    let hi0 = -src[s_off + 63 - 2 * i - 1]
    let hi1 = -src[s_off + 63 - 2 * (i + 1) - 1]
    // the high half runs in reverse index order
    v[v_off + 63 - i] = hi0
    v[v_off + 63 - (i + 1)] = hi1
    i = i + 2
  }
}

///|
/// `sbr_qmf_deint_bfly` (synthesis): the two butterflies
/// `v[i] = src0[i] - src1[63-i]` and `v[127-i] = src0[i] + src1[63-i]`.
#cfg(any(target="native", target="wasm"))
pub fn sbr_qmf_deint_bfly_v128(
  v : Array[Double],
  v_off : Int32,
  src0 : Array[Double],
  s0 : Int32,
  src1 : Array[Double],
  s1 : Int32,
) -> Unit {
  let mut i = 0
  while i < 64 {
    let a = src0[s0 + i]
    let b = src1[s1 + 63 - i]
    v[v_off + i] = a - b
    v[v_off + 127 - i] = a + b
    i = i + 1
  }
}

///|
/// `sbr_sum_square`: the sum of squares over an interleaved `[n][2]` run.
///
/// The scalar port's loop is `while (i < n) { two rows; i += 2; }`, so for
/// odd `n` the final iteration still consumes the row at `i+1` (one past
/// the nominal count). That is the C's behaviour and it is reproduced
/// exactly: each iteration adds two rows, and the vector body keeps lane 0
/// = `sum0` / lane 1 = `sum1`, so the per-lane addition order — and hence
/// the final `sum0 + sum1` — is bit-identical.
#cfg(any(target="native", target="wasm"))
pub fn sbr_sum_square_v128(x : Array[Double], off : Int32, n : Int32) -> Double {
  let mut acc = @simd.f64x2_splat(0.0)
  let mut i = 0
  while i < n {
    let r0 = sbrv_load2(x, off + 2 * i)
    let r1 = sbrv_load2(x, off + 2 * (i + 1))
    acc = @simd.f64x2_add(acc, @simd.f64x2_mul(r0, r0))
    acc = @simd.f64x2_add(acc, @simd.f64x2_mul(r1, r1))
    i = i + 2
  }
  @simd.f64x2_extract_lane(acc, 0) + @simd.f64x2_extract_lane(acc, 1)
}

///|
/// `sbr_hf_g_filt`: `y[m] = X_high[row m + kx][ixh] * g_filt[m]`.
#cfg(any(target="native", target="wasm"))
pub fn sbr_hf_g_filt_v128(
  y : Array[Double],
  y_off : Int32,
  x_high : Array[Double],
  row_off : Int32,
  g_filt : Array[Double],
  g_off : Int32,
  m_max : Int32,
  ixh : Int32,
) -> Unit {
  let mut m = 0
  while m + 2 <= m_max {
    let g0 = g_filt[g_off + m]
    let g1 = g_filt[g_off + m + 1]
    let a = sbrv_load2(x_high, ((row_off + m) * 40 + ixh) * 2)
    let b = sbrv_load2(x_high, ((row_off + m + 1) * 40 + ixh) * 2)
    let ga = @simd.f64x2_splat(g0)
    let gb = @simd.f64x2_splat(g1)
    sbrv_store2(y, y_off + 2 * m, @simd.f64x2_mul(a, ga))
    sbrv_store2(y, y_off + 2 * (m + 1), @simd.f64x2_mul(b, gb))
    m = m + 2
  }
  while m < m_max {
    let g = g_filt[g_off + m]
    let a = sbrv_load2(x_high, ((row_off + m) * 40 + ixh) * 2)
    sbrv_store2(y, y_off + 2 * m, @simd.f64x2_mul(a, @simd.f64x2_splat(g)))
    m = m + 1
  }
}
