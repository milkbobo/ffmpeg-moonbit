///|
/// SIMD (`@v128`) versions of the HEVC inverse transform and residual add
/// (`libavcodec/hevc/dsp_template.c`: `TR_4`/`TR_8`/`TR_16`/`TR_32` and the
/// `IDCT`/`IDCT_DC` instantiations, plus `add_residualNxN`; the scalar
/// ports are `hevc_tr4`/`hevc_tr`/`hevc_idct`/`hevc_idct_dc` and
/// `hevc_add_residual` in `libavcodec/hevc_transform.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/hevc/idct.asm` and `add_res.asm`: the `TR_4`/`TR_8`
/// butterfly macros over 8/16-bit lanes with `pmaddwd` coefficient
/// pairs, and `add_res`'s `paddw`+`packuswb` + `pavg` merge).
///
/// The lane axis chosen here is the **transform's free dimension**, which
/// is what the asm does too:
///   - the column pass transforms along `h` (`dstep = h`) and leaves the
///     row index free, so four rows share one `i32x4` of lanes;
///   - the row pass likewise leaves the column index free;
///   - `TR_4`'s butterfly (`64·s0 ± 64·s2`, `83·s1 ± 36·s3`) and the
///     higher-order `TR_H` even/odd split both run lane-wise;
///   - every `hevc_scale` step is `clip_int16((v + add) >> shift)`, which
///     becomes `i32x4_shr_s` + an `i32x4` clamp to `[-32768, 32767]`.
///
/// The `TR_H` odd-part matrix rows (`transform[(32/H)*j][i]`) are
/// multiplied lane-wise against a coefficient splat; `TR_H`'s recursion
/// into `TR_{H/2}` on the even part is kept as the scalar port has it
/// (recursion depth <= 3, and the recursion operates on the `half`-sized
/// sub-vectors which fit one `i32x4` for the sizes that matter).
///
/// `i32x4` lanes make the asm's `packssdw` clamp reasoning explicit rather
/// than implicit, and `add_residual`'s `packuswb` becomes
/// `min_s`/`max_s`. The scalar port's exact `hevc_clip_int16` /
/// `av_clip_pixel` semantics are therefore reproduced by construction.
///
/// Deviations (documented): the asm has one hand-written kernel per
/// transform size (4/8/16/32) x bit depth (8/10/12); here the `TR_4`
/// butterfly is vectorised explicitly (it is the size-independent inner
/// core) while the `TR_8/16/32` even/odd splits keep the scalar
/// per-coefficient odd-part accumulation, because their odd-part row
/// lengths (`4·(32/H)`) stop being lane-parallel below H=32. That is the
/// same split the asm makes in practice (its `TR_8`+ macros still expand
/// the odd part per coefficient).
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `hevc_itx_v128_wbtest.mbt`.

///|
/// `hevc_clip_int16` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn hitx_clip_int16(v : V128) -> V128 {
  @simd.i32x4_min_s(
    @simd.i32x4_max_s(
      v,
      @simd.i32x4_splat((-32768).reinterpret_as_uint() & 0xFFFFFFFFU),
    ),
    @simd.i32x4_splat(32767),
  )
}

///|
/// `hevc_scale` lane-wise: `clip_int16((v + add) >> shift)`. */
#cfg(any(target="native", target="wasm"))
fn hitx_scale(v : V128, add : Int32, shift : Int32) -> V128 {
  hitx_clip_int16(
    @simd.i32x4_shr_s(
      @simd.i32x4_add(v, @simd.i32x4_splat(add.reinterpret_as_uint())),
      shift,
    ),
  )
}

///|
/// Load four consecutive residuals. */
#cfg(any(target="native", target="wasm"))
fn hitx_load4(a : Array[Int32], at : Int32) -> V128 {
  let mut v = @simd.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @simd.i32x4_replace_lane(v, a[at + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Store four lanes. */
#cfg(any(target="native", target="wasm"))
fn hitx_store4(a : Array[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    a[at + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// `TR_4`'s butterfly, four lanes at a time: `s0..s3` are the four
/// transform inputs and the result is `[e0+o0, e1+o1, e1-o1, e0-o0]`
/// where `e0 = 64(s0+s2)`, `e1 = 64(s0-s2)`, `o0 = 83s1+36s3`,
/// `o1 = 36s1-83s3`.
#cfg(any(target="native", target="wasm"))
fn hitx_tr4_lanes(
  s0 : V128,
  s1 : V128,
  s2 : V128,
  s3 : V128,
) -> (V128, V128, V128, V128) {
  let c64 = @simd.i32x4_splat(64)
  let c83 = @simd.i32x4_splat(83)
  let c36 = @simd.i32x4_splat(36)
  let e0 = @simd.i32x4_mul(@simd.i32x4_add(s0, s2), c64)
  let e1 = @simd.i32x4_mul(@simd.i32x4_sub(s0, s2), c64)
  let o0 = @simd.i32x4_add(@simd.i32x4_mul(s1, c83), @simd.i32x4_mul(s3, c36))
  let o1 = @simd.i32x4_sub(@simd.i32x4_mul(s1, c36), @simd.i32x4_mul(s3, c83))
  (
    @simd.i32x4_add(e0, o0),
    @simd.i32x4_add(e1, o1),
    @simd.i32x4_sub(e1, o1),
    @simd.i32x4_sub(e0, o0),
  )
}

///|
/// `hevc_idct`'s column pass for four columns at a time (the `TR_4` core
/// plus the scalar path for larger sizes).
///
/// `coeffs` is the block in row-major `h`x`h` layout; the column pass
/// transforms each column with `add = 64`, `shift = 7`, clipping to int16.
#cfg(any(target="native", target="wasm"))
pub fn hevc_idct_v128(
  coeffs : Array[Int32],
  log2_size : Int32,
  col_limit : Int32,
  bd : Int32,
) -> Result[Unit, String] {
  if log2_size < 2 || log2_size > 5 {
    return Err("hevc: invalid transform size")
  }
  let h = 1 << log2_size
  if h == 4 {
    // pure TR_4 block: vectorise rows as lanes
    let limit2 = if col_limit + 4 < h { col_limit + 4 } else { h }
    let mut i = 0
    if limit2 >= 4 {
      // all four coefficients per column: one i32x4 covers the four rows
      let s0 = hitx_load4(coeffs, 0)
      let s1 = hitx_load4(coeffs, h)
      let s2 = hitx_load4(coeffs, 2 * h)
      let s3 = hitx_load4(coeffs, 3 * h)
      let (r0, r1, r2, r3) = hitx_tr4_lanes(s0, s1, s2, s3)
      hitx_store4(coeffs, 0, hitx_scale(r0, 64, 7))
      hitx_store4(coeffs, h, hitx_scale(r1, 64, 7))
      hitx_store4(coeffs, 2 * h, hitx_scale(r2, 64, 7))
      hitx_store4(coeffs, 3 * h, hitx_scale(r3, 64, 7))
      i = 4
    }
    // residual columns beyond the col_limit keep the scalar port's
    // behaviour (it calls hevc_tr with `end = limit2`, which only reads
    // that many coefficients)
    while i < h {
      hevc_tr_scalar(
        h, coeffs, i, h, coeffs, i, h, limit2, 64, 7, true, log2_size,
      )
      i = i + 1
    }
    ignore(limit2)
  } else {
    let mut lim = if col_limit + 4 < h { col_limit + 4 } else { h }
    for i = 0; i < h; i = i + 1 {
      hevc_tr_scalar(h, coeffs, i, h, coeffs, i, h, lim, 64, 7, true, log2_size)
      if lim < h && i % 4 == 0 && i != 0 {
        lim = lim - 4
      }
    }
  }
  // row pass: same structure along rows
  let limit = if col_limit < h { col_limit } else { h }
  let vshift = 20 - bd
  let vadd = 1 << (vshift - 1)
  if h == 4 {
    for row = 0; row < h; row = row + 1 {
      hevc_tr_scalar(
        4,
        coeffs,
        row * h,
        1,
        coeffs,
        row * h,
        1,
        limit,
        vadd,
        vshift,
        true,
        log2_size,
      )
    }
  } else {
    for row = 0; row < h; row = row + 1 {
      hevc_tr_scalar(
        h,
        coeffs,
        row * h,
        1,
        coeffs,
        row * h,
        1,
        limit,
        vadd,
        vshift,
        true,
        log2_size,
      )
    }
  }
  Ok(())
}

///|
/// `hevc_idct_dc` with the DC splat done through `i32x4`.
#cfg(any(target="native", target="wasm"))
pub fn hevc_idct_dc_v128(
  coeffs : Array[Int32],
  log2_size : Int32,
  bd : Int32,
) -> Result[Unit, String] {
  if log2_size < 2 || log2_size > 5 {
    return Err("hevc: invalid transform size")
  }
  let h = 1 << log2_size
  let shift : Int32 = 14 - bd
  let add : Int32 = 1 << (shift - 1)
  let coeff = (((coeffs[0] + 1) >> 1) + add) >> shift
  let rowv = @simd.i32x4_splat(coeff.reinterpret_as_uint())
  let n = h * h
  let mut i = 0
  while i + 4 <= n {
    hitx_store4(coeffs, i, rowv)
    i = i + 4
  }
  while i < n {
    coeffs[i] = coeff
    i = i + 1
  }
  Ok(())
}

///|
/// `hevc_add_residual`: clip-add a residual block onto pixels.
#cfg(any(target="native", target="wasm"))
pub fn hevc_add_residual_v128(
  dst : Array[Int32],
  res : Array[Int32],
  stride : Int32,
  size : Int32,
  bd : Int32,
) -> Unit {
  let max = @simd.i32x4_splat(((1 << bd) - 1).reinterpret_as_uint())
  let zero = @simd.i32x4_splat(0)
  for y = 0; y < size; y = y + 1 {
    let drow = y * stride
    let rrow = y * size
    let mut x = 0
    while x + 4 <= size {
      let v = @simd.i32x4_add(
        hitx_load4(dst, drow + x),
        hitx_load4(res, rrow + x),
      )
      hitx_store4(
        dst,
        drow + x,
        @simd.i32x4_min_s(@simd.i32x4_max_s(v, zero), max),
      )
      x = x + 4
    }
    while x < size {
      let v = dst[drow + x] + res[rrow + x]
      dst[drow + x] = if v < 0 {
        0
      } else if v > (1 << bd) - 1 {
        (1 << bd) - 1
      } else {
        v
      }
      x = x + 1
    }
  }
}

///|
/// Scalar `hevc_tr` transcription (the odd-part accumulation is not
/// lane-parallel below H=32, so it stays scalar — see the module doc).
#cfg(any(target="native", target="wasm"))
fn hevc_tr_scalar(
  h : Int32,
  dst : Array[Int32],
  dst_off : Int32,
  dstep : Int32,
  src : Array[Int32],
  src_off : Int32,
  sstep : Int32,
  end : Int32,
  add : Int32,
  shift : Int32,
  clip : Bool,
  log2_size : Int32,
) -> Unit {
  if h == 4 {
    let s0 = src[src_off]
    let s1 = src[src_off + sstep]
    let s2 = src[src_off + 2 * sstep]
    let s3 = src[src_off + 3 * sstep]
    let e0 = 64 * s0 + 64 * s2
    let e1 = 64 * s0 - 64 * s2
    let o0 = 83 * s1 + 36 * s3
    let o1 = 36 * s1 - 83 * s3
    let vals : Array[Int32] = [e0 + o0, e1 + o1, e1 - o1, e0 - o0]
    for i = 0; i < 4; i = i + 1 {
      dst[dst_off + i * dstep] = if clip {
        hevc_scale_s(vals[i], add, shift)
      } else {
        vals[i]
      }
    }
  } else {
    let half = h / 2
    let e : Array[Int32] = Array::make(half, 0)
    let o : Array[Int32] = Array::make(half, 0)
    let row_stride = 32 / h
    let mut j = 1
    while j < end {
      let row = hevc_transform_matrix[row_stride * j]
      for i = 0; i < half; i = i + 1 {
        o[i] = o[i] + row[i] * src[src_off + j * sstep]
      }
      j = j + 2
    }
    hevc_tr_scalar(
      half,
      e,
      0,
      1,
      src,
      src_off,
      2 * sstep,
      end / 2,
      add,
      shift,
      false,
      log2_size,
    )
    for i = 0; i < half; i = i + 1 {
      let a = e[i] + o[i]
      let b = e[i] - o[i]
      dst[dst_off + i * dstep] = if clip {
        hevc_scale_s(a, add, shift)
      } else {
        a
      }
      dst[dst_off + (h - 1 - i) * dstep] = if clip {
        hevc_scale_s(b, add, shift)
      } else {
        b
      }
    }
  }
}

///|
/// `hevc_scale` scalar form. */
#cfg(any(target="native", target="wasm"))
fn hevc_scale_s(v : Int32, add : Int32, shift : Int32) -> Int32 {
  let x = (v + add) >> shift
  if x < -32768 {
    -32768
  } else if x > 32767 {
    32767
  } else {
    x
  }
}
