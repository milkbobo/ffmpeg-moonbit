///|
/// Whitebox tests for the SIMD (`@v128`) VP9 intra prediction kernels
/// (`vp9_ipred_v128.mbt`).
///
/// The `ir_*` functions are verbatim transcriptions of the scalar port's
/// **generic** predictors (`libavcodec/vp9_dsp.mbt`: `vp9_pred_vert`,
/// `_hor`, `_dc`, `_dc_left`, `_dc_top`, `_dc_const`,
/// `_diag_downleft`, `_diag_downright`, `_vert_right`, `_hor_down`,
/// `_vert_left`, `_hor_up`, `_tm`) — the parent package's privates are not
/// visible from a subpackage, so the reference is carried here. The scalar
/// port additionally has hand-unrolled 4x4 forms; the wbtest asserts the
/// SIMD kernel against the generic form for every size, which also pins
/// that those two scalar forms agree.

///|
let ir_dc : Int32 = 0
///|
let ir_v : Int32 = 1
///|
let ir_h : Int32 = 2
///|
let ir_dl : Int32 = 3
///|
let ir_dr : Int32 = 4
///|
let ir_vr : Int32 = 5
///|
let ir_hd : Int32 = 6
///|
let ir_vl : Int32 = 7
///|
let ir_hu : Int32 = 8
///|
let ir_tm : Int32 = 9
///|
let ir_left_dc : Int32 = 10
///|
let ir_top_dc : Int32 = 11
///|
let ir_dc_128 : Int32 = 12
///|
let ir_dc_127 : Int32 = 13
///|
let ir_dc_255 : Int32 = 14

///|
fn ir_clip(v : Int32, pixel_max : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > pixel_max {
    pixel_max
  } else {
    v
  }
}

///|
/// Verbatim `vp9_intra_pred`, generic forms only. */
fn ir_intra_pred(
  n : Int32,
  mode : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  left : FixedArray[Int32],
  top : FixedArray[Int32],
  pixel_mid : Int32,
  pixel_max : Int32,
) -> Unit {
  if mode == ir_v {
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = top[1 + x]
      }
    }
  } else if mode == ir_h {
    for y in 0..<n {
      let v = left[n - 1 - y]
      for x in 0..<n {
        p[off + x + y * stride] = v
      }
    }
  } else if mode == ir_dc {
    let mut sum = n
    for i in 0..<n {
      sum += left[i] + top[1 + i]
    }
    let dc = sum >>
      (if n == 16 { 5 } else if n == 32 { 6 } else if n == 8 { 4 } else { 3 })
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = dc
      }
    }
  } else if mode == ir_left_dc {
    let mut sum = n >> 1
    for i in 0..<n {
      sum += left[i]
    }
    let dc = sum >>
      (if n == 16 { 4 } else if n == 32 { 5 } else if n == 8 { 3 } else { 2 })
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = dc
      }
    }
  } else if mode == ir_top_dc {
    let mut sum = n >> 1
    for i in 0..<n {
      sum += top[1 + i]
    }
    let dc = sum >>
      (if n == 16 { 4 } else if n == 32 { 5 } else if n == 8 { 3 } else { 2 })
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = dc
      }
    }
  } else if mode == ir_dc_128 {
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = pixel_mid
      }
    }
  } else if mode == ir_dc_127 {
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = pixel_mid - 1
      }
    }
  } else if mode == ir_dc_255 {
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = pixel_mid + 1
      }
    }
  } else if mode == ir_tm {
    let tl = top[0]
    for y in 0..<n {
      let l_m_tl = left[n - 1 - y] - tl
      for x in 0..<n {
        p[off + x + y * stride] = ir_clip(top[1 + x] + l_m_tl, pixel_max)
      }
    }
  } else if mode == ir_dl {
    let v : FixedArray[Int32] = FixedArray::make(n, 0)
    for i in 0..<(n - 2) {
      v[i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
    }
    v[n - 2] = (top[n - 1] + top[n] * 3 + 2) >> 2
    for j in 0..<n {
      for i in 0..<(n - 1 - j) {
        p[off + i + j * stride] = v[j + i]
      }
      for i in (n - 1 - j)..<n {
        p[off + i + j * stride] = top[n]
      }
    }
  } else if mode == ir_dr {
    let v : FixedArray[Int32] = FixedArray::make(n + n - 1, 0)
    for i in 0..<(n - 2) {
      v[i] = (left[i] + left[i + 1] * 2 + left[i + 2] + 2) >> 2
      v[n + 1 + i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
    }
    v[n - 2] = (left[n - 2] + left[n - 1] * 2 + top[0] + 2) >> 2
    v[n - 1] = (left[n - 1] + top[0] * 2 + top[1] + 2) >> 2
    v[n] = (top[0] + top[1] * 2 + top[2] + 2) >> 2
    for j in 0..<n {
      for i in 0..<n {
        p[off + i + j * stride] = v[n - 1 - j + i]
      }
    }
  } else if mode == ir_vr {
    let ve : FixedArray[Int32] = FixedArray::make(n + n / 2 - 1, 0)
    let vo : FixedArray[Int32] = FixedArray::make(n + n / 2 - 1, 0)
    for i in 0..<(n / 2 - 2) {
      vo[i] = (left[i * 2 + 3] + left[i * 2 + 2] * 2 + left[i * 2 + 1] + 2) >> 2
      ve[i] = (left[i * 2 + 4] + left[i * 2 + 3] * 2 + left[i * 2 + 2] + 2) >> 2
    }
    vo[n / 2 - 2] = (left[n - 1] + left[n - 2] * 2 + left[n - 3] + 2) >> 2
    ve[n / 2 - 2] = (top[0] + left[n - 1] * 2 + left[n - 2] + 2) >> 2
    ve[n / 2 - 1] = (top[0] + top[1] + 1) >> 1
    vo[n / 2 - 1] = (left[n - 1] + top[0] * 2 + top[1] + 2) >> 2
    for i in 0..<(n - 1) {
      ve[n / 2 + i] = (top[1 + i] + top[2 + i] + 1) >> 1
      vo[n / 2 + i] = (top[i] + top[1 + i] * 2 + top[2 + i] + 2) >> 2
    }
    for j in 0..<(n / 2) {
      for i in 0..<n {
        p[off + i + j * 2 * stride] = ve[n / 2 - 1 - j + i]
        p[off + i + (j * 2 + 1) * stride] = vo[n / 2 - 1 - j + i]
      }
    }
  } else if mode == ir_vl {
    let ve : FixedArray[Int32] = FixedArray::make(n - 1, 0)
    let vo : FixedArray[Int32] = FixedArray::make(n - 1, 0)
    for i in 0..<(n - 2) {
      ve[i] = (top[1 + i] + top[2 + i] + 1) >> 1
      vo[i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
    }
    ve[n - 2] = (top[n - 1] + top[n] + 1) >> 1
    vo[n - 2] = (top[n - 1] + top[n] * 3 + 2) >> 2
    for j in 0..<(n / 2) {
      for i in 0..<(n - j - 1) {
        p[off + i + j * 2 * stride] = ve[j + i]
        p[off + i + (j * 2 + 1) * stride] = vo[j + i]
      }
      for i in (n - j - 1)..<n {
        p[off + i + j * 2 * stride] = top[n]
        p[off + i + (j * 2 + 1) * stride] = top[n]
      }
    }
  } else if mode == ir_hd {
    let v : FixedArray[Int32] = FixedArray::make(n * 3 - 2, 0)
    for i in 0..<(n - 2) {
      v[i * 2] = (left[i + 1] + left[i] + 1) >> 1
      v[i * 2 + 1] = (left[i + 2] + left[i + 1] * 2 + left[i] + 2) >> 2
      v[n * 2 + i] = (top[i] + top[1 + i] * 2 + top[2 + i] + 2) >> 2
    }
    v[n * 2 - 2] = (top[0] + left[n - 1] + 1) >> 1
    v[n * 2 - 4] = (left[n - 1] + left[n - 2] + 1) >> 1
    v[n * 2 - 1] = (top[1] + top[0] * 2 + left[n - 1] + 2) >> 2
    v[n * 2 - 3] = (top[0] + left[n - 1] * 2 + left[n - 2] + 2) >> 2
    for j in 0..<n {
      for i in 0..<n {
        p[off + i + j * stride] = v[n * 2 - 2 - j * 2 + i]
      }
    }
  } else if mode == ir_hu {
    let v : FixedArray[Int32] = FixedArray::make(n * 2 - 2, 0)
    for i in 0..<(n - 2) {
      v[i * 2] = (left[i] + left[i + 1] + 1) >> 1
      v[i * 2 + 1] = (left[i] + left[i + 1] * 2 + left[i + 2] + 2) >> 2
    }
    v[n * 2 - 4] = (left[n - 2] + left[n - 1] + 1) >> 1
    v[n * 2 - 3] = (left[n - 2] + left[n - 1] * 3 + 2) >> 2
    for j in 0..<(n / 2) {
      for i in 0..<n {
        p[off + i + j * stride] = v[j * 2 + i]
      }
    }
    for j in (n / 2)..<n {
      for i in 0..<(n * 2 - 2 - j * 2) {
        p[off + i + j * stride] = v[j * 2 + i]
      }
      for i in (n * 2 - 2 - j * 2)..<n {
        p[off + i + j * stride] = left[n - 1]
      }
    }
  } else {
    for y in 0..<n {
      for x in 0..<n {
        p[off + x + y * stride] = pixel_mid + 1
      }
    }
  }
}

///|
/// Deterministic generator (LCG). */
fn ir_gen(seed : UInt32, n : Int32, max : Int32) -> FixedArray[Int32] {
  let a : FixedArray[Int32] = FixedArray::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
fn ir_copy(a : FixedArray[Int32]) -> FixedArray[Int32] {
  let b : FixedArray[Int32] = FixedArray::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn ir_same(a : FixedArray[Int32], b : FixedArray[Int32]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
test "vp9 ipred v128: all modes x all sizes x bit depths" {
  let modes : Array[Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  let stride : Int32 = 40
  let plane_n = stride * 40
  for (pixel_max, pixel_mid) in [(255, 128), (1023, 512), (4095, 2048)] {
    for n in [4, 8, 16, 32] {
      for mode in modes {
        for k = 0; k < 3; k = k + 1 {
          let seed = 0x9E3779B9U +
            n.reinterpret_as_uint() * 17U +
            mode.reinterpret_as_uint() * 5U +
            k.reinterpret_as_uint()
          let left = ir_gen(seed, 32, pixel_max)
          let top = ir_gen(seed + 7777U, 65, pixel_max)
          let base = ir_gen(seed + 999U, plane_n, pixel_max)
          let e1 = ir_copy(base)
          let e2 = ir_copy(base)
          let off = 8 * stride + 8
          ir_intra_pred(
            n, mode, e1, off, stride, left, top, pixel_mid, pixel_max,
          )
          vp9_intra_pred_v128(
            n, mode, e2, off, stride, left, top, pixel_mid, pixel_max,
          )
          assert_true(ir_same(e1, e2))
        }
      }
    }
  }
}

///|
test "vp9 ipred v128: extreme edge values clip symmetrically" {
  // tm is the only mode that can leave the [0, pixel_max] range before
  // clipping; feed it both rails.
  let stride : Int32 = 40
  let plane_n = stride * 40
  let off = 8 * stride + 8
  for (pixel_max, pixel_mid) in [(255, 128), (1023, 512)] {
    for n in [4, 8, 16, 32] {
      for (lfill, tfill) in [(0, pixel_max), (pixel_max, 0), (0, 0)] {
        let left : FixedArray[Int32] = FixedArray::make(32, lfill)
        let top : FixedArray[Int32] = FixedArray::make(65, tfill)
        let base = ir_gen(0xABCDEF01U, plane_n, pixel_max)
        let e1 = ir_copy(base)
        let e2 = ir_copy(base)
        ir_intra_pred(n, ir_tm, e1, off, stride, left, top, pixel_mid, pixel_max)
        vp9_intra_pred_v128(
          n, ir_tm, e2, off, stride, left, top, pixel_mid, pixel_max,
        )
        assert_true(ir_same(e1, e2))
        // every produced sample must be inside range
        for y = 0; y < n; y = y + 1 {
          for x = 0; x < n; x = x + 1 {
            let v = e2[off + y * stride + x]
            assert_true(v >= 0)
            assert_true(v <= pixel_max)
          }
        }
      }
    }
  }
}

///|
test "vp9 ipred v128: writes stay inside the n x n block" {
  let stride : Int32 = 56
  let plane_n = stride * 56
  let off = 12 * stride + 8
  for n in [4, 8, 16, 32] {
    for mode in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14] {
      let left = ir_gen(0x1111U, 32, 255)
      let top = ir_gen(0x2222U, 65, 255)
      let base = ir_gen(0x3333U, plane_n, 255)
      let e2 = ir_copy(base)
      vp9_intra_pred_v128(n, mode, e2, off, stride, left, top, 128, 255)
      for r = 0; r < 56; r = r + 1 {
        for c = 0; c < 56; c = c + 1 {
          let idx = r * stride + c
          let inside = r >= 12 && r < 12 + n && c >= 8 && c < 8 + n
          if !inside {
            assert_eq(e2[idx], base[idx])
          }
        }
      }
    }
  }
}