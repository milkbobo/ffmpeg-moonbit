///|
/// Whitebox tests for the SIMD (`@v128`) HEVC inverse transform and
/// residual add (`hevc_itx_v128.mbt`).
///
/// The `ir_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/hevc_transform.mbt`: `hevc_tr4`, `hevc_tr`, `hevc_idct`,
/// `hevc_idct_dc`, `hevc_scale`, `hevc_clip_int16`, `hevc_add_residual`) —
/// the parent package's privates are not visible from a subpackage, so the
/// reference is carried here (the basis matrix is the `hevc_itx_matrix.mbt`
/// copy). Every size, bit depth and `col_limit` must agree bit-for-bit.

///|
fn ir_clip_int16(v : Int32) -> Int32 {
  if v < -32768 {
    -32768
  } else if v > 32767 {
    32767
  } else {
    v
  }
}

///|
fn ir_scale(v : Int32, add : Int32, shift : Int32) -> Int32 {
  ir_clip_int16((v + add) >> shift)
}

///|
/// Verbatim `hevc_tr4`. */
fn ir_tr4(
  dst : Array[Int32],
  dst_off : Int32,
  dstep : Int32,
  src : Array[Int32],
  src_off : Int32,
  sstep : Int32,
  add : Int32,
  shift : Int32,
  clip : Bool,
) -> Unit {
  let s0 = src[src_off]
  let s1 = src[src_off + sstep]
  let s2 = src[src_off + 2 * sstep]
  let s3 = src[src_off + 3 * sstep]
  let e0 = 64 * s0 + 64 * s2
  let e1 = 64 * s0 - 64 * s2
  let o0 = 83 * s1 + 36 * s3
  let o1 = 36 * s1 - 83 * s3
  let values : Array[Int32] = [e0 + o0, e1 + o1, e1 - o1, e0 - o0]
  for i = 0; i < 4; i = i + 1 {
    let v = values[i]
    dst[dst_off + i * dstep] = if clip { ir_scale(v, add, shift) } else { v }
  }
}

///|
/// Verbatim `hevc_tr`. */
fn ir_tr(
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
) -> Unit {
  if h == 4 {
    ir_tr4(dst, dst_off, dstep, src, src_off, sstep, add, shift, clip)
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
    ir_tr(half, e, 0, 1, src, src_off, 2 * sstep, end / 2, add, shift, false)
    for i = 0; i < half; i = i + 1 {
      let a = e[i] + o[i]
      let b = e[i] - o[i]
      dst[dst_off + i * dstep] = if clip { ir_scale(a, add, shift) } else { a }
      dst[dst_off + (h - 1 - i) * dstep] = if clip {
        ir_scale(b, add, shift)
      } else {
        b
      }
    }
  }
}

///|
/// Verbatim `hevc_idct`. */
fn ir_idct(
  coeffs : Array[Int32],
  log2_size : Int32,
  col_limit : Int32,
  bd : Int32,
) -> Unit {
  let h = 1 << log2_size
  let mut limit2 = if col_limit + 4 < h { col_limit + 4 } else { h }
  for i = 0; i < h; i = i + 1 {
    ir_tr(h, coeffs, i, h, coeffs, i, h, limit2, 64, 7, true)
    if limit2 < h && i % 4 == 0 && i != 0 {
      limit2 = limit2 - 4
    }
  }
  let limit = if col_limit < h { col_limit } else { h }
  let vshift = 20 - bd
  let vadd = 1 << (vshift - 1)
  for row = 0; row < h; row = row + 1 {
    ir_tr(h, coeffs, row * h, 1, coeffs, row * h, 1, limit, vadd, vshift, true)
  }
}

///|
/// Verbatim `hevc_idct_dc`. */
fn ir_idct_dc(coeffs : Array[Int32], log2_size : Int32, bd : Int32) -> Unit {
  let h = 1 << log2_size
  let shift : Int32 = 14 - bd
  let add : Int32 = 1 << (shift - 1)
  let coeff = (((coeffs[0] + 1) >> 1) + add) >> shift
  for i = 0; i < h * h; i = i + 1 {
    coeffs[i] = coeff
  }
}

///|
/// Verbatim `hevc_add_residual`. */
fn ir_add_residual(
  dst : Array[Int32],
  res : Array[Int32],
  stride : Int32,
  size : Int32,
  bd : Int32,
) -> Unit {
  let max = (1 << bd) - 1
  for y = 0; y < size; y = y + 1 {
    for x = 0; x < size; x = x + 1 {
      let v = dst[y * stride + x] + res[y * size + x]
      dst[y * stride + x] = if v < 0 { 0 } else if v > max { max } else { v }
    }
  }
}

///|
/// Deterministic generator (LCG) over `[-limit, limit]`. */
fn ir_gen(seed : UInt32, n : Int32, limit : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let r = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (2 * limit + 1)
    a[i] = r - limit
  }
  a
}

///|
fn ir_copy(a : Array[Int32]) -> Array[Int32] {
  let b : Array[Int32] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
test "hevc itx v128: idct over all sizes, depths and column limits" {
  for log2_size in [2, 3, 4, 5] {
    let h = 1 << log2_size
    let n = h * h
    for bd in [8, 10, 12] {
      for col_limit in [0, 1, 2, 3, 4, 8, 16, h] {
        if col_limit > h {
          continue
        }
        for k = 0; k < 3; k = k + 1 {
          let src = ir_gen(
            0x9E3779B9U +
            log2_size.reinterpret_as_uint() * 37U +
            bd.reinterpret_as_uint() * 101U +
            col_limit.reinterpret_as_uint() +
            k.reinterpret_as_uint(),
            n,
            512,
          )
          let a = ir_copy(src)
          let b = ir_copy(src)
          ir_idct(a, log2_size, col_limit, bd)
          let r = hevc_idct_v128(b, log2_size, col_limit, bd)
          assert_true(if r is Ok(_) { true } else { false })
          for i = 0; i < n; i = i + 1 {
            assert_eq(b[i], a[i])
          }
        }
      }
    }
  }
}

///|
test "hevc itx v128: DC-only idct and the error path" {
  for log2_size in [2, 3, 4, 5] {
    let h = 1 << log2_size
    let n = h * h
    for bd in [8, 10, 12] {
      for dc in [0, 1, -1, 512, -512, 32767, -32768, 4096] {
        let src : Array[Int32] = Array::make(n, 0)
        src[0] = dc
        let a = ir_copy(src)
        let b = ir_copy(src)
        ir_idct_dc(a, log2_size, bd)
        let r = hevc_idct_dc_v128(b, log2_size, bd)
        assert_true(if r is Ok(_) { true } else { false })
        for i = 0; i < n; i = i + 1 {
          assert_eq(b[i], a[i])
        }
      }
    }
  }
  // invalid sizes must report the same error on both sides
  let z : Array[Int32] = Array::make(16, 0)
  let r1 = hevc_idct_v128(z, 1, 4, 8)
  assert_true(if r1 is Err(_) { true } else { false })
  let r2 = hevc_idct_dc_v128(z, 6, 8)
  assert_true(if r2 is Err(_) { true } else { false })
}

///|
test "hevc itx v128: add_residual clips both rails" {
  for size in [4, 8, 16, 32] {
    let stride = size + 7
    for bd in [8, 10, 12] {
      let max = (1 << bd) - 1
      for k = 0; k < 3; k = k + 1 {
        let px = ir_gen(
          0x5A5A5A5AU + k.reinterpret_as_uint(),
          stride * size,
          max,
        )
        // residual magnitudes big enough to hit both clamps
        let res = ir_gen(
          0x12345678U + size.reinterpret_as_uint(),
          size * size,
          max * 2,
        )
        let a = ir_copy(px)
        let b = ir_copy(px)
        ir_add_residual(a, res, stride, size, bd)
        hevc_add_residual_v128(b, res, stride, size, bd)
        for i = 0; i < stride * size; i = i + 1 {
          assert_eq(b[i], a[i])
        }
        // every written sample stays in range
        for y = 0; y < size; y = y + 1 {
          for x = 0; x < size; x = x + 1 {
            let v = b[y * stride + x]
            assert_true(v >= 0)
            assert_true(v <= max)
          }
        }
      }
    }
  }
}

///|
test "hevc itx v128: transform preserves the scalar int16 stores" {
  // Full-range int16 coefficients stress every clip_int16 in both passes.
  for log2_size in [2, 3, 4] {
    let h = 1 << log2_size
    let n = h * h
    for bd in [8, 10] {
      for centre in [32767, -32768, 0] {
        let src : Array[Int32] = Array::make(n, centre)
        let a = ir_copy(src)
        let b = ir_copy(src)
        ir_idct(a, log2_size, h, bd)
        let r = hevc_idct_v128(b, log2_size, h, bd)
        assert_true(if r is Ok(_) { true } else { false })
        for i = 0; i < n; i = i + 1 {
          assert_eq(b[i], a[i])
        }
      }
    }
  }
}
