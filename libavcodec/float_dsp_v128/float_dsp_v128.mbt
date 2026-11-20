///|
/// SIMD (`@v128`) versions of the shared `AVFloatDSPContext` primitives
/// (`libavutil/float_dsp.c` and `libavutil/float_dsp.h`:
/// `vector_fmul`, `vector_dmul`, `vector_fmac_scalar`, `vector_fmul_scalar`,
/// `vector_dmac_scalar`, `vector_dmul_scalar`, `vector_fmul_window`,
/// `vector_fmul_add`, `vector_fmul_reverse`, `butterflies_float`,
/// `scalarproduct_float`, `scalarproduct_double`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavutil/x86/float_dsp.asm`: `vector_fmul`, `vector_dmul`,
/// `vector_fmac_scalar`, `vector_fmul_scalar`, `vector_dmac_scalar`,
/// `vector_dmul_scalar`, `vector_fmul_window`, `vector_fmul_add`,
/// `vector_fmul_reverse`, `scalarproduct_float`, `scalarproduct_double`,
/// `butterflies_float`).
///
/// This is the **shared layer** the remaining audio slices build on, so it
/// exposes both precisions:
///   - `f32` kernels run on `f32x4` (four lanes), matching the C's `float`;
///   - `f64` kernels run on `f64x2` (two lanes), matching the C's `double`.
///
/// **Ordering is the whole story here.** These primitives are called inside
/// codec inner loops where FFmpeg's own C and SIMD paths already differ in
/// the last bits (that is why `avpriv_float_dsp_alloc` takes a
/// `bit_exact` flag). This port holds every kernel to *bit-exactness
/// against the scalar port* — which is achievable for all the elementwise
/// kernels (mul, mul-add, scalar variants, window, reverse, butterflies)
/// because each output is a single fixed-order expression.
///
/// The two **dot products** (`scalarproduct_float`/`_double`) are the
/// exception: the C sums sequentially, so reordering changes the result on
/// inputs where the rounding differs. Both therefore keep the exact scalar
/// accumulation order; the `f32x4` body only performs the elementwise
/// products and the sum is folded in the same left-to-right sequence. This
/// is the same ruling §480/§481/§483 made for their running sums, applied
/// here to the layer that everything else depends on.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `float_dsp_v128_wbtest.mbt`.

///|
/// Load four `f32` lanes from an `Array[Float]`. */
#cfg(any(target="native", target="wasm"))
fn fdv_load4(a : Array[Float], at : Int32) -> V128 {
  @v128.f32x4_const(a[at], a[at + 1], a[at + 2], a[at + 3])
}

///|
/// Store four `f32` lanes. */
#cfg(any(target="native", target="wasm"))
fn fdv_store4(a : Array[Float], at : Int32, v : V128) -> Unit {
  a[at] = @v128.f32x4_extract_lane(v, 0)
  a[at + 1] = @v128.f32x4_extract_lane(v, 1)
  a[at + 2] = @v128.f32x4_extract_lane(v, 2)
  a[at + 3] = @v128.f32x4_extract_lane(v, 3)
}

///|
/// `vector_fmul`: `dst[i] = src0[i] * src1[i]`.
#cfg(any(target="native", target="wasm"))
pub fn vector_fmul_v128(
  dst : Array[Float],
  src0 : Array[Float],
  src1 : Array[Float],
  len : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    fdv_store4(
      dst,
      i,
      @v128.f32x4_mul(fdv_load4(src0, i), fdv_load4(src1, i)),
    )
    i = i + 4
  }
  while i < len {
    dst[i] = src0[i] * src1[i]
    i = i + 1
  }
}

///|
/// `vector_fmac_scalar`: `dst[i] += src[i] * mul`.
#cfg(any(target="native", target="wasm"))
pub fn vector_fmac_scalar_v128(
  dst : Array[Float],
  src : Array[Float],
  mul : Float,
  len : Int32,
) -> Unit {
  let m = @v128.f32x4_splat(mul)
  let mut i = 0
  while i + 4 <= len {
    fdv_store4(
      dst,
      i,
      @v128.f32x4_add(fdv_load4(dst, i), @v128.f32x4_mul(fdv_load4(src, i), m)),
    )
    i = i + 4
  }
  while i < len {
    dst[i] = dst[i] + src[i] * mul
    i = i + 1
  }
}

///|
/// `vector_fmul_scalar`: `dst[i] = src[i] * mul`.
#cfg(any(target="native", target="wasm"))
pub fn vector_fmul_scalar_v128(
  dst : Array[Float],
  src : Array[Float],
  mul : Float,
  len : Int32,
) -> Unit {
  let m = @v128.f32x4_splat(mul)
  let mut i = 0
  while i + 4 <= len {
    fdv_store4(dst, i, @v128.f32x4_mul(fdv_load4(src, i), m))
    i = i + 4
  }
  while i < len {
    dst[i] = src[i] * mul
    i = i + 1
  }
}

///|
/// `vector_fmul_add`: `dst[i] = src0[i]*src1[i] + src2[i]`.
#cfg(any(target="native", target="wasm"))
pub fn vector_fmul_add_v128(
  dst : Array[Float],
  src0 : Array[Float],
  src1 : Array[Float],
  src2 : Array[Float],
  len : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    fdv_store4(
      dst,
      i,
      @v128.f32x4_add(
        @v128.f32x4_mul(fdv_load4(src0, i), fdv_load4(src1, i)),
        fdv_load4(src2, i),
      ),
    )
    i = i + 4
  }
  while i < len {
    dst[i] = src0[i] * src1[i] + src2[i]
    i = i + 1
  }
}

///|
/// `vector_fmul_reverse`: `dst[i] = src0[i] * src1[len-1-i]`.
#cfg(any(target="native", target="wasm"))
pub fn vector_fmul_reverse_v128(
  dst : Array[Float],
  src0 : Array[Float],
  src1 : Array[Float],
  len : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    // gather the four reversed samples into one vector
    let r = @v128.f32x4_const(
      src1[len - 1 - i],
      src1[len - 2 - i],
      src1[len - 3 - i],
      src1[len - 4 - i],
    )
    fdv_store4(dst, i, @v128.f32x4_mul(fdv_load4(src0, i), r))
    i = i + 4
  }
  while i < len {
    dst[i] = src0[i] * src1[len - 1 - i]
    i = i + 1
  }
}

///|
/// `vector_fmul_window`: the MDCT window product.
///
/// The C walks `i` from `-len` to `-1` with `j = len-1-i`; each iteration
/// produces two outputs. The vector body computes four `(i, j)` pairs per
/// step in two `f32x4` products, keeping the C's exact expression order
/// (`s0*wj - s1*wi` and `s0*wi + s1*wj`).
#cfg(any(target="native", target="wasm"))
pub fn vector_fmul_window_v128(
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
  // C: dst += len; win += len; src0 += len; loop i = -len .. -1
  let mut i = 0
  while i + 4 <= len {
    let mut lo = @v128.f32x4_splat(0.0)
    let mut hi = @v128.f32x4_splat(0.0)
    let mut k = 0
    while k < 4 {
      // C's i_c = -len + (i + k); j_c = len - 1 - (i + k)
      let ic = 0 - len + i + k
      let jc = len - 1 - (i + k)
      let s0 = src0[s0_off + len + ic]
      let s1 = src1[s1_off + jc]
      let wi = win[w_off + len + ic]
      let wj = win[w_off + jc]
      lo = @v128.f32x4_replace_lane(
        lo,
        Float::from_double(
          (Float::from_double(s0.to_double() * wj.to_double()) -
          Float::from_double(s1.to_double() * wi.to_double())).to_double(),
        ),
        k,
      )
      hi = @v128.f32x4_replace_lane(
        hi,
        Float::from_double(
          (Float::from_double(s0.to_double() * wi.to_double()) +
          Float::from_double(s1.to_double() * wj.to_double())).to_double(),
        ),
        k,
      )
      k = k + 1
    }
    // dst[len + ic] = lo[k], dst[jc] = hi[k]
    let mut k2 = 0
    while k2 < 4 {
      let ic = 0 - len + i + k2
      let jc = len - 1 - (i + k2)
      dst[dst_off + len + ic] = @v128.f32x4_extract_lane(lo, k2)
      dst[dst_off + jc] = @v128.f32x4_extract_lane(hi, k2)
      k2 = k2 + 1
    }
    i = i + 4
  }
  while i < len {
    let ic = 0 - len + i
    let jc = len - 1 - i
    let s0 = src0[s0_off + len + ic]
    let s1 = src1[s1_off + jc]
    let wi = win[w_off + len + ic]
    let wj = win[w_off + jc]
    dst[dst_off + len + ic] = s0 * wj - s1 * wi
    dst[dst_off + jc] = s0 * wi + s1 * wj
    i = i + 1
  }
}

///|
/// `butterflies_float`: `t = v1[i]-v2[i]; v1[i] += v2[i]; v2[i] = t`.
#cfg(any(target="native", target="wasm"))
pub fn butterflies_float_v128(
  v1 : Array[Float],
  v2 : Array[Float],
  len : Int32,
) -> Unit {
  let mut i = 0
  while i + 4 <= len {
    let a = fdv_load4(v1, i)
    let b = fdv_load4(v2, i)
    fdv_store4(v1, i, @v128.f32x4_add(a, b))
    fdv_store4(v2, i, @v128.f32x4_sub(a, b))
    i = i + 4
  }
  while i < len {
    let t = v1[i] - v2[i]
    v1[i] = v1[i] + v2[i]
    v2[i] = t
    i = i + 1
  }
}

///|
/// `scalarproduct_float`: left-to-right sum of `v1[i]*v2[i]`.
///
/// The products are computed four at a time in `f32x4`, but the **sum is
/// folded in the C's sequential order** — see the module doc for why
/// reordering is not allowed here.
#cfg(any(target="native", target="wasm"))
pub fn scalarproduct_float_v128(
  v1 : Array[Float],
  v2 : Array[Float],
  len : Int32,
) -> Float {
  let mut p : Float = 0.0
  let mut i = 0
  while i + 4 <= len {
    let pr = @v128.f32x4_mul(fdv_load4(v1, i), fdv_load4(v2, i))
    p = p + @v128.f32x4_extract_lane(pr, 0)
    p = p + @v128.f32x4_extract_lane(pr, 1)
    p = p + @v128.f32x4_extract_lane(pr, 2)
    p = p + @v128.f32x4_extract_lane(pr, 3)
    i = i + 4
  }
  while i < len {
    p = p + v1[i] * v2[i]
    i = i + 1
  }
  p
}

///|
/// `vector_dmul`: `dst[i] = src0[i] * src1[i]` on doubles.
#cfg(any(target="native", target="wasm"))
fn fdv_load2_f64(a : Array[Double], at : Int32) -> V128 {
  @v128.f64x2_const(a[at], a[at + 1])
}

///|
/// Store two `f64x2` lanes. */
#cfg(any(target="native", target="wasm"))
fn fdv_store2_f64(a : Array[Double], at : Int32, v : V128) -> Unit {
  a[at] = @v128.f64x2_extract_lane(v, 0)
  a[at + 1] = @v128.f64x2_extract_lane(v, 1)
}

///|
/// `vector_dmul`: `dst[i] = src0[i] * src1[i]`.
#cfg(any(target="native", target="wasm"))
pub fn vector_dmul_v128(
  dst : Array[Double],
  src0 : Array[Double],
  src1 : Array[Double],
  len : Int32,
) -> Unit {
  let mut i = 0
  while i + 2 <= len {
    fdv_store2_f64(
      dst,
      i,
      @v128.f64x2_mul(fdv_load2_f64(src0, i), fdv_load2_f64(src1, i)),
    )
    i = i + 2
  }
  while i < len {
    dst[i] = src0[i] * src1[i]
    i = i + 1
  }
}

///|
/// `vector_dmac_scalar`: `dst[i] += src[i] * mul`.
#cfg(any(target="native", target="wasm"))
pub fn vector_dmac_scalar_v128(
  dst : Array[Double],
  src : Array[Double],
  mul : Double,
  len : Int32,
) -> Unit {
  let m = @v128.f64x2_splat(mul)
  let mut i = 0
  while i + 2 <= len {
    fdv_store2_f64(
      dst,
      i,
      @v128.f64x2_add(
        fdv_load2_f64(dst, i),
        @v128.f64x2_mul(fdv_load2_f64(src, i), m),
      ),
    )
    i = i + 2
  }
  while i < len {
    dst[i] = dst[i] + src[i] * mul
    i = i + 1
  }
}

///|
/// `vector_dmul_scalar`: `dst[i] = src[i] * mul`.
#cfg(any(target="native", target="wasm"))
pub fn vector_dmul_scalar_v128(
  dst : Array[Double],
  src : Array[Double],
  mul : Double,
  len : Int32,
) -> Unit {
  let m = @v128.f64x2_splat(mul)
  let mut i = 0
  while i + 2 <= len {
    fdv_store2_f64(dst, i, @v128.f64x2_mul(fdv_load2_f64(src, i), m))
    i = i + 2
  }
  while i < len {
    dst[i] = src[i] * mul
    i = i + 1
  }
}

///|
/// `scalarproduct_double`: left-to-right sum of `v1[i]*v2[i]`.
#cfg(any(target="native", target="wasm"))
pub fn scalarproduct_double_v128(
  v1 : Array[Double],
  v2 : Array[Double],
  len : Int32,
) -> Double {
  let mut p : Double = 0.0
  let mut i = 0
  while i + 2 <= len {
    let pr = @v128.f64x2_mul(fdv_load2_f64(v1, i), fdv_load2_f64(v2, i))
    p = p + @v128.f64x2_extract_lane(pr, 0)
    p = p + @v128.f64x2_extract_lane(pr, 1)
    i = i + 2
  }
  while i < len {
    p = p + v1[i] * v2[i]
    i = i + 1
  }
  p
}
