///|
/// Whitebox tests for the SIMD (`@v128`) H.264 deblocking filter kernels
/// (`h264_deblock_v128.mbt`).
///
/// The `dr_*` functions are verbatim transcriptions of the scalar port
/// (`libavcodec/h264_deblock.mbt`: `h264_lf_luma`, `h264_lf_luma_intra`,
/// `h264_lf_chroma`, `h264_lf_chroma_intra`) — the parent package's
/// privates are not visible from a subpackage, so the reference is carried
/// here and the SIMD kernels must match it bit-for-bit on every input:
/// same samples touched, same clipping/clamping, same skip conditions.

///|
fn dr_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn dr_clip_pixel(v : Int32, bit_depth : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    v
  }
}

///|
fn dr_abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// Verbatim `h264_lf_luma` body for one 4-sample group (one `tc0`). */
fn dr_lf_luma1(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc0 : Int32,
  bit_depth : Int32,
) -> Unit {
  let mut p = start
  if tc0 < 0 {
    return
  }
  for _d = 0; _d < along; _d = _d + 1 {
    let p0 = data[p - xstep]
    let p1 = data[p - 2 * xstep]
    let p2 = data[p - 3 * xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    let q2 = data[p + 2 * xstep]
    if dr_abs(p0 - q0) < alpha &&
      dr_abs(p1 - p0) < beta &&
      dr_abs(q1 - q0) < beta {
      let mut tc = tc0
      if dr_abs(p2 - p0) < beta {
        if tc0 != 0 {
          data[p - 2 * xstep] = dr_clip_pixel(
            p1 + dr_clip(((p2 + ((p0 + q0 + 1) >> 1)) >> 1) - p1, -tc0, tc0),
            bit_depth,
          )
        }
        tc = tc + 1
      }
      if dr_abs(q2 - q0) < beta {
        if tc0 != 0 {
          data[p + xstep] = dr_clip_pixel(
            q1 + dr_clip(((q2 + ((p0 + q0 + 1) >> 1)) >> 1) - q1, -tc0, tc0),
            bit_depth,
          )
        }
        tc = tc + 1
      }
      let i_delta = dr_clip(((q0 - p0) * 4 + (p1 - q1) + 4) >> 3, -tc, tc)
      data[p - xstep] = dr_clip_pixel(p0 + i_delta, bit_depth)
      data[p] = dr_clip_pixel(q0 - i_delta, bit_depth)
    }
    p = p + ystep
  }
}

///|
/// Verbatim `h264_lf_luma`. */
fn dr_lf_luma(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc0 : Int32,
  bit_depth : Int32,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dr_lf_luma1(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      tc0,
      bit_depth,
    )
  }
}

///|
/// Verbatim `h264_lf_luma_intra`. */
fn dr_lf_luma_intra(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth : Int32,
) -> Unit {
  ignore(bit_depth)
  let mut p = start
  for _d = 0; _d < 4 * along; _d = _d + 1 {
    let p1 = data[p - 2 * xstep]
    let p0 = data[p - xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if dr_abs(p0 - q0) < alpha &&
      dr_abs(p1 - p0) < beta &&
      dr_abs(q1 - q0) < beta {
      let p2 = data[p - 3 * xstep]
      let q2 = data[p + 2 * xstep]
      if dr_abs(p0 - q0) < (alpha >> 2) + 2 {
        if dr_abs(p2 - p0) < beta {
          let p3 = data[p - 4 * xstep]
          data[p - xstep] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
          data[p - 2 * xstep] = (p2 + p1 + p0 + q0 + 2) >> 2
          data[p - 3 * xstep] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3
        } else {
          data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
        }
        if dr_abs(q2 - q0) < beta {
          let q3 = data[p + 3 * xstep]
          data[p] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3
          data[p + xstep] = (p0 + q0 + q1 + q2 + 2) >> 2
          data[p + 2 * xstep] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3
        } else {
          data[p] = (2 * q1 + q0 + p1 + 2) >> 2
        }
      } else {
        data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
        data[p] = (2 * q1 + q0 + p1 + 2) >> 2
      }
    }
    p = p + ystep
  }
}

///|
/// Verbatim `h264_lf_chroma` body for one 4-sample group (one `tc`). */
fn dr_lf_chroma1(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc : Int32,
  bit_depth : Int32,
) -> Unit {
  let mut p = start
  if tc <= 0 {
    return
  }
  for _d = 0; _d < along; _d = _d + 1 {
    let p0 = data[p - xstep]
    let p1 = data[p - 2 * xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if dr_abs(p0 - q0) < alpha &&
      dr_abs(p1 - p0) < beta &&
      dr_abs(q1 - q0) < beta {
      let delta = dr_clip(((q0 - p0) * 4 + (p1 - q1) + 4) >> 3, -tc, tc)
      data[p - xstep] = dr_clip_pixel(p0 + delta, bit_depth)
      data[p] = dr_clip_pixel(q0 - delta, bit_depth)
    }
    p = p + ystep
  }
}

///|
/// Verbatim `h264_lf_chroma`. */
fn dr_lf_chroma(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc : Int32,
  bit_depth : Int32,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dr_lf_chroma1(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      tc,
      bit_depth,
    )
  }
}

///|
/// Verbatim `h264_lf_chroma_intra`. */
fn dr_lf_chroma_intra(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth : Int32,
) -> Unit {
  ignore(bit_depth)
  let mut p = start
  for _d = 0; _d < 4 * along; _d = _d + 1 {
    let p0 = data[p - xstep]
    let p1 = data[p - 2 * xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if dr_abs(p0 - q0) < alpha &&
      dr_abs(p1 - p0) < beta &&
      dr_abs(q1 - q0) < beta {
      data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
      data[p] = (2 * q1 + q0 + p1 + 2) >> 2
    }
    p = p + ystep
  }
}

///|
/// Deterministic pixel-plane generator (LCG): mostly smooth runs with
/// occasional hard edges, so both the "flat, filter" and the "blocky,
/// skip" branches of every mask are exercised. */
fn dr_gen_plane(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  let mut base = max / 2
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let r = ((s >> 16) & 0xFF).reinterpret_as_int()
    if r < 96 {
      // hard step: forces |p0-q0| >= alpha on the next samples
      base = if base > max / 2 { 0 } else { max }
    } else {
      base = base + r % 5 - 2
      if base < 0 {
        base = 0
      } else if base > max {
        base = max
      }
    }
    a[i] = base
  }
  a
}

///|
/// Deterministic plane with small deltas only: everything passes the masks,
/// so the filtering branches run for nearly every sample. */
fn dr_gen_flat(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  let mid = max / 2
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let d = ((s >> 16) % 3).reinterpret_as_int()
    a[i] = mid + d - 1
  }
  a
}

///|
fn dr_copy(a : Array[Int32]) -> Array[Int32] {
  let b : Array[Int32] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
test "h264 deblock v128: luma inter equality, both orientations, depths" {
  let stride : Int32 = 40
  let plane_n = stride * 24
  // (alpha, beta, tc0) triples: skip-everything, filter-everything, and
  // mid-range values that mix per-lane outcomes.
  let params : Array[(Int32, Int32, Int32)] = [
    (0, 0, -1),
    (255, 18, 25),
    (255, 18, 0),
    (255, 18, 1),
    (4, 2, 1),
    (54, 12, 6),
    (192, 22, 13),
  ]
  for bit_depth in [8, 10, 12] {
    let max = (1 << bit_depth) - 1
    for (alpha, beta, tc0) in params {
      for k = 0; k < 4; k = k + 1 {
        let src = if k % 2 == 0 {
          dr_gen_plane(0x9E3779B9U + k.reinterpret_as_uint(), plane_n, max)
        } else {
          dr_gen_flat(0x5A5A5A5AU + k.reinterpret_as_uint(), plane_n, max)
        }
        // vertical edge: xstep = 1, ystep = stride
        let d1 = dr_copy(src)
        let d2 = dr_copy(src)
        let off = 6 * stride + 8
        dr_lf_luma(d1, off, 1, stride, 4, alpha, beta, tc0, bit_depth)
        h264_lf_luma_v128(d2, off, 1, stride, 4, alpha, beta, tc0, bit_depth~)
        let mut i = 0
        while i < plane_n {
          assert_eq(d2[i], d1[i])
          i = i + 1
        }
        // horizontal edge: xstep = stride, ystep = 1
        let h1 = dr_copy(src)
        let h2 = dr_copy(src)
        let hoff = 6 * stride + 8
        dr_lf_luma(h1, hoff, stride, 1, 4, alpha, beta, tc0, bit_depth)
        h264_lf_luma_v128(h2, hoff, stride, 1, 4, alpha, beta, tc0, bit_depth~)
        let mut j = 0
        while j < plane_n {
          assert_eq(h2[j], h1[j])
          j = j + 1
        }
      }
    }
  }
}

///|
test "h264 deblock v128: luma intra equality, both orientations, depths" {
  let stride : Int32 = 40
  let plane_n = stride * 24
  let params : Array[(Int32, Int32)] = [
    (255, 18),
    (4, 2),
    (54, 12),
    (192, 22),
    (255, 1),
    (16, 4),
  ]
  for bit_depth in [8, 10, 12] {
    let max = (1 << bit_depth) - 1
    for (alpha, beta) in params {
      for k = 0; k < 4; k = k + 1 {
        let src = if k % 2 == 0 {
          dr_gen_plane(0xDEADBEEFU + k.reinterpret_as_uint() * 3U, plane_n, max)
        } else {
          dr_gen_flat(0x12345670U + k.reinterpret_as_uint(), plane_n, max)
        }
        let d1 = dr_copy(src)
        let d2 = dr_copy(src)
        let off = 6 * stride + 8
        dr_lf_luma_intra(d1, off, 1, stride, 4, alpha, beta, bit_depth)
        h264_lf_luma_intra_v128(d2, off, 1, stride, 4, alpha, beta, bit_depth~)
        let mut i = 0
        while i < plane_n {
          assert_eq(d2[i], d1[i])
          i = i + 1
        }
        let h1 = dr_copy(src)
        let h2 = dr_copy(src)
        dr_lf_luma_intra(h1, off, stride, 1, 4, alpha, beta, bit_depth)
        h264_lf_luma_intra_v128(h2, off, stride, 1, 4, alpha, beta, bit_depth~)
        let mut j = 0
        while j < plane_n {
          assert_eq(h2[j], h1[j])
          j = j + 1
        }
      }
    }
  }
}

///|
test "h264 deblock v128: chroma inter/intra equality incl. 4:2:2 width 4" {
  let stride : Int32 = 32
  let plane_n = stride * 24
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    // along = 2 is the 4:2:0/4:2:2 default; along = 4 is the 4:2:2
    // horizontal-edge extension (`h264_h_loop_filter_chroma422`).
    for along in [2, 4] {
      for k = 0; k < 4; k = k + 1 {
        let src = if k % 2 == 0 {
          dr_gen_plane(0xC0FFEE01U + k.reinterpret_as_uint(), plane_n, max)
        } else {
          dr_gen_flat(0x0BADF00DU + k.reinterpret_as_uint(), plane_n, max)
        }
        // tc values: -1/0 skip (`tc0_table` bS==0), positive filters.
        for tc in [-1, 0, 1, 3, 9, 25] {
          let d1 = dr_copy(src)
          let d2 = dr_copy(src)
          let off = 6 * stride + 6
          dr_lf_chroma(d1, off, 1, stride, along, 255, 18, tc, bit_depth)
          h264_lf_chroma_v128(
            d2,
            off,
            1,
            stride,
            along,
            255,
            18,
            tc,
            bit_depth~,
          )
          let mut i = 0
          while i < plane_n {
            assert_eq(d2[i], d1[i])
            i = i + 1
          }
          let h1 = dr_copy(src)
          let h2 = dr_copy(src)
          dr_lf_chroma(h1, off, stride, 1, along, 255, 18, tc, bit_depth)
          h264_lf_chroma_v128(
            h2,
            off,
            stride,
            1,
            along,
            255,
            18,
            tc,
            bit_depth~,
          )
          let mut j = 0
          while j < plane_n {
            assert_eq(h2[j], h1[j])
            j = j + 1
          }
        }
        for (alpha, beta) in [(255, 18), (4, 2), (54, 12), (255, 1)] {
          let d1 = dr_copy(src)
          let d2 = dr_copy(src)
          let off = 6 * stride + 6
          dr_lf_chroma_intra(d1, off, 1, stride, along, alpha, beta, bit_depth)
          h264_lf_chroma_intra_v128(
            d2,
            off,
            1,
            stride,
            along,
            alpha,
            beta,
            bit_depth~,
          )
          let mut i = 0
          while i < plane_n {
            assert_eq(d2[i], d1[i])
            i = i + 1
          }
          let h1 = dr_copy(src)
          let h2 = dr_copy(src)
          dr_lf_chroma_intra(h1, off, stride, 1, along, alpha, beta, bit_depth)
          h264_lf_chroma_intra_v128(
            h2,
            off,
            stride,
            1,
            along,
            alpha,
            beta,
            bit_depth~,
          )
          let mut j = 0
          while j < plane_n {
            assert_eq(h2[j], h1[j])
            j = j + 1
          }
        }
      }
    }
  }
}

///|
test "h264 deblock v128: per-sub-block tc0 masks (skip some lanes)" {
  let stride : Int32 = 40
  let plane_n = stride * 24
  let max = 255
  // tc0 arrays that mix skip (-1) and filter entries, so the four
  // sub-blocks take different paths inside one call.
  let tc0_sets : Array[Array[Int32]] = [
    [-1, -1, -1, -1],
    [0, 0, 0, 0],
    [1, 1, 1, 1],
    [25, -1, 0, 3],
    [-1, 7, -1, 11],
    [13, 13, -1, -1],
  ]
  for tc0s in tc0_sets {
    for k = 0; k < 4; k = k + 1 {
      let src = if k % 2 == 0 {
        dr_gen_plane(0xABCDEF01U + k.reinterpret_as_uint(), plane_n, max)
      } else {
        dr_gen_flat(0xFEDCBA98U + k.reinterpret_as_uint(), plane_n, max)
      }
      let d1 = dr_copy(src)
      let d2 = dr_copy(src)
      let off = 8 * stride + 8
      for s = 0; s < 4; s = s + 1 {
        dr_lf_luma1(d1, off + s * 4 * stride, 1, stride, 4, 255, 18, tc0s[s], 8)
      }
      h264_deblock_luma_v128(d2, off, 1, stride, 4, 255, 18, tc0s, bit_depth=8)
      let mut i = 0
      while i < plane_n {
        assert_eq(d2[i], d1[i])
        i = i + 1
      }
    }
  }
}

///|
test "h264 deblock v128: no-op edges leave the plane untouched" {
  // alpha/beta below every difference: the masks never fire, so the whole
  // plane (including the samples left of the edge) must be identical.
  let stride : Int32 = 32
  let plane_n = stride * 26
  let src = dr_gen_plane(0x13572468U, plane_n, 255)
  let d1 = dr_copy(src)
  let d2 = dr_copy(src)
  let off = 6 * stride + 6
  h264_lf_luma_v128(d2, off, 1, stride, 4, 0, 0, 25, bit_depth=8)
  h264_lf_luma_intra_v128(d2, off, 1, stride, 4, 0, 0, bit_depth=8)
  h264_lf_chroma_v128(d2, off, 1, stride, 2, 0, 0, 25, bit_depth=8)
  h264_lf_chroma_intra_v128(d2, off, 1, stride, 2, 0, 0, bit_depth=8)
  let mut i = 0
  while i < plane_n {
    assert_eq(d2[i], src[i])
    i = i + 1
  }
  ignore(d1)
}

///|
test "h264 deblock v128: constant blocks are fixed points after filtering" {
  // A flat block cannot satisfy the |p0-q0| mask, so filtering it is a
  // no-op; a block with a known step is filtered to a checked value.
  let stride : Int32 = 16
  let plane_n = stride * 26
  let flat : Array[Int32] = Array::make(plane_n, 128)
  let d = dr_copy(flat)
  h264_lf_luma_v128(d, 8 * stride + 8, 1, stride, 4, 255, 18, 25, bit_depth=8)
  let mut i = 0
  while i < plane_n {
    assert_eq(d[i], 128)
    i = i + 1
  }
  // step edge 100 | 200 with tc0 = 1: |p2-p0| and |q2-q0| are both 0, so
  // tc = tc0 + 2 = 3 and both p1/q1 take the tc0-clamped nudge (101 / 199).
  // i_delta = ((200-100)*4 + (100-200) + 4) >> 3 = 38, clipped to
  // [-3, 3] -> 3, so p0 = 103 and q0 = 197.
  let step : Array[Int32] = Array::make(plane_n, 100)
  for r = 0; r < 26; r = r + 1 {
    for c = 8; c < 16; c = c + 1 {
      step[r * stride + c] = 200
    }
  }
  let s1 = dr_copy(step)
  let s2 = dr_copy(step)
  dr_lf_luma(s1, 8 * stride + 8, 1, stride, 4, 255, 250, 1, 8)
  h264_lf_luma_v128(s2, 8 * stride + 8, 1, stride, 4, 255, 250, 1, bit_depth=8)
  let mut j = 0
  while j < plane_n {
    assert_eq(s2[j], s1[j])
    j = j + 1
  }
  assert_eq(s2[8 * stride + 7], 103)
  assert_eq(s2[8 * stride + 8], 197)
  // p1/q1 take the strong branch: both |p2-p0|, |q2-q0| are 0 < 250, and
  // the nudge is clipped to tc0 = 1: p1 = 100 + 1 = 101, q1 = 200 - 1 = 199.
  assert_eq(s2[8 * stride + 6], 101)
  assert_eq(s2[8 * stride + 9], 199)
}
