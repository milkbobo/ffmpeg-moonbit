///|
/// SIMD (`@v128`) versions of the split-radix FFT combine kernels from
/// FFmpeg's `libavutil/tx_template.c` (`BF`, `BUTTERFLIES`, `TRANSFORM`,
/// `ff_tx_fft_sr_combine`), against `libavutil/x86/tx_float.asm`
/// (`FFT4`, `SPLIT_RADIX_COMBINE`, `SPLIT_RADIX_COMBINE_64`).
///
/// The scalar port is `libavcodec/aac_mdct_tx/aac_mdct_tx.mbt`
/// (`aac_mtx_bf`, `aac_mtx_butterflies`, `aac_mtx_transform`,
/// `aac_mtx_combine`, `aac_mtx_fft4`).
///
/// **Why the combine is the right slice, and `fft4` is not.** The
/// split-radix combine processes four *independent* complex slots per
/// iteration — `z+0`, `z+2`, `z+4`, `z+6`, each with its own twiddle — which
/// is a genuine 4-wide SIMD axis and is exactly how `SPLIT_RADIX_COMBINE`
/// maps onto four `xmm` registers. `ff_tx_fft4_ns`, by contrast, is 16
/// scalar add/subs over the *same* four slots with heavy cross-lane
/// mixing: expressing it in `f32x4` needs more shuffles than arithmetic,
/// so it stays scalar here (documented deviation). That is not a
/// capability gap — it is the same judgement the asm makes, whose `FFT4`
/// macro is a register-rotation over scalars rather than a packed op.
///
/// **Precision**: the scalar port models the C's `float` by rounding every
/// intermediate through binary32 (`mtx_f32`), so the vector body uses
/// `f32x4` exclusively — every `f32x4` op is already binary32, keeping the
/// result bit-identical by construction. `f64x2` would drift.
///
/// **Bit-exactness**: the combine's `t` loop is a set of independent
/// butterflies with no running sum, so vectorising across `t` is
/// order-free. The twiddle table walk stays scalar (it is index
/// arithmetic, not floating-point).
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `tx_float_v128_wbtest.mbt`.

///|
/// `mtx_f32`: round to binary32 (the C's `float` assignment). */
#cfg(any(target="native", target="wasm"))
fn txv_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
/// Gather four `f32` values at arbitrary positions into one `f32x4`. */
#cfg(any(target="native", target="wasm"))
fn txv_gather(
  a : Array[Double],
  i0 : Int32,
  i1 : Int32,
  i2 : Int32,
  i3 : Int32,
) -> V128 {
  @v128.f32x4_const(
    Float::from_double(a[i0]),
    Float::from_double(a[i1]),
    Float::from_double(a[i2]),
    Float::from_double(a[i3]),
  )
}

///|
/// `BUTTERFLIES` (`tx_template.c:540`) on four slots at once.
///
/// Lane `k` is one complex slot. `t1/t2` are the (already twiddled) real /
/// imaginary parts of the third input and `t5/t6` the fourth; the C's
/// `t3 = t5 - t1`, `t5 = t5 + t1`, `t4 = t2 - t6`, `t6 = t2 + t6` are the
/// four intermediate pairs. Returns the eight outputs in the C's store
/// order: `(zr[a2], zr[a0], zi[a3], zi[a1], zr[a3], zr[a1], zi[a2], zi[a0])`.
#cfg(any(target="native", target="wasm"))
fn txv_butterflies(
  r0 : V128,
  i0 : V128,
  r1 : V128,
  i1 : V128,
  t1 : V128,
  t2 : V128,
  t5_in : V128,
  t6_in : V128,
) -> (V128, V128, V128, V128, V128, V128, V128, V128) {
  let t3 = @v128.f32x4_sub(t5_in, t1)
  let t5 = @v128.f32x4_add(t5_in, t1)
  let a2r = @v128.f32x4_sub(r0, t5)
  let a0r = @v128.f32x4_add(r0, t5)
  let a3i = @v128.f32x4_sub(i1, t3)
  let a1i = @v128.f32x4_add(i1, t3)
  let t4 = @v128.f32x4_sub(t2, t6_in)
  let t6 = @v128.f32x4_add(t2, t6_in)
  let a3r = @v128.f32x4_sub(r1, t4)
  let a1r = @v128.f32x4_add(r1, t4)
  let a2i = @v128.f32x4_sub(i0, t6)
  let a0i = @v128.f32x4_add(i0, t6)
  (a2r, a0r, a3i, a1i, a3r, a1r, a2i, a0i)
}

///|
/// `TRANSFORM` (`tx_template.c:554`): `CMUL` the two twiddled inputs by
/// `(wre, ±wim)`, then the butterfly block.
///
/// `wre`/`wim` are per-lane vectors (each slot has its own twiddle).
#cfg(any(target="native", target="wasm"))
fn txv_transform(
  r0 : V128,
  i0 : V128,
  r1 : V128,
  i1 : V128,
  zr2 : V128,
  zi2 : V128,
  zr3 : V128,
  zi3 : V128,
  wre : V128,
  wim : V128,
) -> (V128, V128, V128, V128, V128, V128, V128, V128) {
  let neg_wim = @v128.f32x4_neg(wim)
  // t1 = zr2*wre - zi2*(-wim);  t2 = zr2*(-wim) + zi2*wre
  let t1 = @v128.f32x4_sub(
    @v128.f32x4_mul(zr2, wre),
    @v128.f32x4_mul(zi2, neg_wim),
  )
  let t2 = @v128.f32x4_add(
    @v128.f32x4_mul(zr2, neg_wim),
    @v128.f32x4_mul(zi2, wre),
  )
  // t5 = zr3*wre - zi3*wim;  t6 = zr3*wim + zi3*wre
  let t5 = @v128.f32x4_sub(
    @v128.f32x4_mul(zr3, wre),
    @v128.f32x4_mul(zi3, wim),
  )
  let t6 = @v128.f32x4_add(
    @v128.f32x4_mul(zr3, wim),
    @v128.f32x4_mul(zi3, wre),
  )
  txv_butterflies(r0, i0, r1, i1, t1, t2, t5, t6)
}

///|
/// `ff_tx_fft_sr_combine` (`tx_template.c:562`) for `len = n/8`.
///
/// Four slots per iteration (`z+0/+2/+4/+6`), each with its own
/// `(wre, wim)` pair read from the cosine table; the vector body runs the
/// four butterflies lane-wise and stores the eight results back.
///
/// `tab[c + k]` supplies `wre` for slot `k` and `tab[w + (7 - k)]` its
/// `wim` — the C's `w` walks backwards by 8 per iteration, so the twiddle
/// index arithmetic is kept exactly as the scalar port has it.
#cfg(any(target="native", target="wasm"))
pub fn fft_sr_combine_v128(
  zr : Array[Double],
  zi : Array[Double],
  tab : Array[Double],
  off : Int32,
  len : Int32,
) -> Unit {
  let o1 = 2 * len
  let o2 = 4 * len
  let o3 = 6 * len
  let iters = len / 4
  for t = 0; t < iters; t = t + 1 {
    let z = off + t * 8
    let c = t * 8
    let w = o1 - 7 - t * 8
    // The C runs eight TRANSFORMs per t, in slot order
    //   0, 2, 4, 6, 1, 3, 5, 7
    // each with its own twiddle pair (tab[c+k], tab[w+(7-k)]). Grouping the
    // offsets 0..7 into one lane-set would need a cross-slot shuffle; the
    // four-slot groups the asm uses are (0,2,4,6) and (1,3,5,7), so run
    // those two groups as vectors and keep the rest identical.
    for group in 0..<2 {
      let base = if group == 0 { 0 } else { 1 }
      let ks : Array[Int32] = [
        base, base + 2, base + 4, base + 6,
      ]
      let r0 = txv_gather(zr, z + ks[0], z + ks[1], z + ks[2], z + ks[3])
      let i0 = txv_gather(zi, z + ks[0], z + ks[1], z + ks[2], z + ks[3])
      let r1 = txv_gather(
        zr, z + o1 + ks[0], z + o1 + ks[1], z + o1 + ks[2], z + o1 + ks[3],
      )
      let i1 = txv_gather(
        zi, z + o1 + ks[0], z + o1 + ks[1], z + o1 + ks[2], z + o1 + ks[3],
      )
      let zr2 = txv_gather(
        zr, z + o2 + ks[0], z + o2 + ks[1], z + o2 + ks[2], z + o2 + ks[3],
      )
      let zi2 = txv_gather(
        zi, z + o2 + ks[0], z + o2 + ks[1], z + o2 + ks[2], z + o2 + ks[3],
      )
      let zr3 = txv_gather(
        zr, z + o3 + ks[0], z + o3 + ks[1], z + o3 + ks[2], z + o3 + ks[3],
      )
      let zi3 = txv_gather(
        zi, z + o3 + ks[0], z + o3 + ks[1], z + o3 + ks[2], z + o3 + ks[3],
      )
      let wre = txv_gather(tab, c + ks[0], c + ks[1], c + ks[2], c + ks[3])
      let wim = txv_gather(
        tab,
        w + (7 - ks[0]),
        w + (7 - ks[1]),
        w + (7 - ks[2]),
        w + (7 - ks[3]),
      )
      let (a2r, a0r, a3i, a1i, a3r, a1r, a2i, a0i) = txv_transform(
        r0, i0, r1, i1, zr2, zi2, zr3, zi3, wre, wim,
      )
      store4(
        zr,
        z + o2 + ks[0], z + o2 + ks[1], z + o2 + ks[2], z + o2 + ks[3],
        a2r,
      )
      store4(
        zr,
        z + ks[0], z + ks[1], z + ks[2], z + ks[3],
        a0r,
      )
      store4(
        zi,
        z + o3 + ks[0], z + o3 + ks[1], z + o3 + ks[2], z + o3 + ks[3],
        a3i,
      )
      store4(
        zi,
        z + o1 + ks[0], z + o1 + ks[1], z + o1 + ks[2], z + o1 + ks[3],
        a1i,
      )
      store4(
        zr,
        z + o3 + ks[0], z + o3 + ks[1], z + o3 + ks[2], z + o3 + ks[3],
        a3r,
      )
      store4(
        zr,
        z + o1 + ks[0], z + o1 + ks[1], z + o1 + ks[2], z + o1 + ks[3],
        a1r,
      )
      store4(
        zi,
        z + o2 + ks[0], z + o2 + ks[1], z + o2 + ks[2], z + o2 + ks[3],
        a2i,
      )
      store4(
        zi,
        z + ks[0], z + ks[1], z + ks[2], z + ks[3],
        a0i,
      )
    }
  }
}

///|
/// Scatter four lanes to four positions. */
#cfg(any(target="native", target="wasm"))
fn store4(
  a : Array[Double],
  i0 : Int32,
  i1 : Int32,
  i2 : Int32,
  i3 : Int32,
  v : V128,
) -> Unit {
  a[i0] = @v128.f32x4_extract_lane(v, 0).to_double()
  a[i1] = @v128.f32x4_extract_lane(v, 1).to_double()
  a[i2] = @v128.f32x4_extract_lane(v, 2).to_double()
  a[i3] = @v128.f32x4_extract_lane(v, 3).to_double()
}

///|
/// `ff_tx_fft4_ns` (`tx_template.c:643`), scalar by documented deviation —
/// see the module doc for why the cross-lane mixing makes the packed form
/// more expensive than the scalar one (and why the asm makes the same
/// call). Kept public so callers can rely on one entry point.
#cfg(any(target="native", target="wasm"))
pub fn fft4_ns_v128(zr : Array[Double], zi : Array[Double], o : Int32) -> Unit {
  let t3 = txv_f32(zr[o + 0] - zr[o + 1])
  let t1 = txv_f32(zr[o + 0] + zr[o + 1])
  let t8 = txv_f32(zr[o + 3] - zr[o + 2])
  let t6 = txv_f32(zr[o + 3] + zr[o + 2])
  let d2r = txv_f32(t1 - t6)
  let d0r = txv_f32(t1 + t6)
  let t4 = txv_f32(zi[o + 0] - zi[o + 1])
  let t2 = txv_f32(zi[o + 0] + zi[o + 1])
  let t7 = txv_f32(zi[o + 2] - zi[o + 3])
  let t5 = txv_f32(zi[o + 2] + zi[o + 3])
  let d3i = txv_f32(t4 - t8)
  let d1i = txv_f32(t4 + t8)
  let d3r = txv_f32(t3 - t7)
  let d1r = txv_f32(t3 + t7)
  let d2i = txv_f32(t2 - t5)
  let d0i = txv_f32(t2 + t5)
  zr[o + 2] = d2r
  zr[o + 0] = d0r
  zi[o + 3] = d3i
  zi[o + 1] = d1i
  zr[o + 3] = d3r
  zr[o + 1] = d1r
  zi[o + 2] = d2i
  zi[o + 0] = d0i
}
