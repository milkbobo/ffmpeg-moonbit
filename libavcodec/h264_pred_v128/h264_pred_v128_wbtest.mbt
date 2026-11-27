///|
/// Whitebox tests for the SIMD (`@v128`) H.264 16x16 / 8x8 intra
/// prediction kernels (`h264_pred_v128.mbt`).
///
/// The `pr_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/h264_pred.mbt`: `h264_pred16x16`, `h264_pred8x8`) — the
/// parent package's privates are not visible from a subpackage, so the
/// reference is carried here. Both kernels must agree on every mode, on
/// every top/left availability combination the C accepts, and on the error
/// cases (missing edge → `Err`).

///|
/// `true` when the call succeeded (both kernels return `Result`).
fn pr_ok(r : Result[Unit, String]) -> Bool {
  match r {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn pr_clip8(x : Int32, bit_depth : Int32) -> Int32 {
  if x < 0 {
    0
  } else if x > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    x
  }
}

///|
let pr_dc : Int32 = 0

///|
let pr_hor : Int32 = 1

///|
let pr_vert : Int32 = 2

///|
let pr_plane : Int32 = 3

///|
let pr_left_dc : Int32 = 4

///|
let pr_top_dc : Int32 = 5

///|
let pr_128_dc : Int32 = 6

///|
/// Verbatim `h264_pred16x16`. */
fn pr_pred16x16(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
  bit_depth : Int32,
) -> Result[Unit, String] {
  if mode == pr_vert {
    if !top {
      return Err("no top")
    }
    for j = 0; j < 16; j = j + 1 {
      for i = 0; i < 16; i = i + 1 {
        dst[off + j * stride + i] = dst[off - stride + i]
      }
    }
  } else if mode == pr_hor {
    if !left {
      return Err("no left")
    }
    for j = 0; j < 16; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      for i = 0; i < 16; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == pr_dc ||
    mode == pr_left_dc ||
    mode == pr_top_dc ||
    mode == pr_128_dc {
    let mut dc = 1 << (bit_depth - 1)
    if mode == pr_dc {
      let mut sum = 0
      if top {
        for i = 0; i < 16; i = i + 1 {
          sum = sum + dst[off - stride + i]
        }
      }
      if left {
        for i = 0; i < 16; i = i + 1 {
          sum = sum + dst[off - 1 + i * stride]
        }
      }
      dc = if top && left {
        (sum + 16) >> 5
      } else if top || left {
        (sum + 8) >> 4
      } else {
        1 << (bit_depth - 1)
      }
    } else if mode == pr_left_dc {
      if !left {
        return Err("no left")
      }
      let mut sum = 0
      for i = 0; i < 16; i = i + 1 {
        sum = sum + dst[off - 1 + i * stride]
      }
      dc = (sum + 8) >> 4
    } else if mode == pr_top_dc {
      if !top {
        return Err("no top")
      }
      let mut sum = 0
      for i = 0; i < 16; i = i + 1 {
        sum = sum + dst[off - stride + i]
      }
      dc = (sum + 8) >> 4
    }
    for j = 0; j < 16; j = j + 1 {
      for i = 0; i < 16; i = i + 1 {
        dst[off + j * stride + i] = dc
      }
    }
  } else if mode == pr_plane {
    if !top || !left {
      return Err("no edge")
    }
    let mut h = dst[off - stride + 8] - dst[off - stride + 6]
    let mut v = dst[off + 8 * stride - 1] - dst[off + 6 * stride - 1]
    for k = 2; k <= 8; k = k + 1 {
      h = h + k * (dst[off - stride + 7 + k] - dst[off - stride + 7 - k])
      v = v +
        k * (dst[off + (7 + k) * stride - 1] - dst[off + (7 - k) * stride - 1])
    }
    h = (5 * h + 32) >> 6
    v = (5 * v + 32) >> 6
    let mut a = 16 * (dst[off + 15 * stride - 1] + dst[off - stride + 15] + 1) -
      7 * (v + h)
    for j = 0; j < 16; j = j + 1 {
      let mut b = a
      a = a + v
      for i4 = 0; i4 < 4; i4 = i4 + 1 {
        let p = off + j * stride + 4 * i4
        dst[p] = pr_clip8(b >> 5, bit_depth)
        dst[p + 1] = pr_clip8((b + h) >> 5, bit_depth)
        dst[p + 2] = pr_clip8((b + 2 * h) >> 5, bit_depth)
        dst[p + 3] = pr_clip8((b + 3 * h) >> 5, bit_depth)
        b = b + 4 * h
      }
    }
  } else {
    return Err("bad mode")
  }
  Ok(())
}

///|
/// Verbatim `h264_pred8x8`. */
fn pr_pred8x8(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
  bit_depth : Int32,
) -> Result[Unit, String] {
  if mode == pr_vert {
    if !top {
      return Err("no top")
    }
    for j = 0; j < 8; j = j + 1 {
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = dst[off - stride + i]
      }
    }
  } else if mode == pr_hor {
    if !left {
      return Err("no left")
    }
    for j = 0; j < 8; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == pr_dc {
    if !top || !left {
      return Err("no edge")
    }
    let mut dc0 = 0
    let mut dc1 = 0
    let mut dc2 = 0
    for i = 0; i < 4; i = i + 1 {
      dc0 = dc0 + dst[off - 1 + i * stride] + dst[off - stride + i]
      dc1 = dc1 + dst[off - stride + 4 + i]
      dc2 = dc2 + dst[off - 1 + (i + 4) * stride]
    }
    let v0 = (dc0 + 4) >> 3
    let v1 = (dc1 + 2) >> 2
    let v2 = (dc2 + 2) >> 2
    let v3 = (dc1 + dc2 + 4) >> 3
    for j = 0; j < 8; j = j + 1 {
      let lv = if j < 4 { v0 } else { v2 }
      let rv = if j < 4 { v1 } else { v3 }
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = lv
        dst[off + j * stride + 4 + i] = rv
      }
    }
  } else if mode == pr_left_dc {
    if !left {
      return Err("no left")
    }
    let mut dc0 = 0
    let mut dc1 = 0
    for i = 0; i < 4; i = i + 1 {
      dc0 = dc0 + dst[off - 1 + i * stride]
      dc1 = dc1 + dst[off - 1 + (i + 4) * stride]
    }
    let v0 = (dc0 + 2) >> 2
    let v1 = (dc1 + 2) >> 2
    for j = 0; j < 8; j = j + 1 {
      let v = if j < 4 { v0 } else { v1 }
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == pr_top_dc {
    if !top {
      return Err("no top")
    }
    let mut dc0 = 0
    let mut dc1 = 0
    for i = 0; i < 4; i = i + 1 {
      dc0 = dc0 + dst[off - stride + i]
      dc1 = dc1 + dst[off - stride + 4 + i]
    }
    let v0 = (dc0 + 2) >> 2
    let v1 = (dc1 + 2) >> 2
    for j = 0; j < 8; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = v0
        dst[off + j * stride + 4 + i] = v1
      }
    }
  } else if mode == pr_128_dc {
    for j = 0; j < 8; j = j + 1 {
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = 1 << (bit_depth - 1)
      }
    }
  } else if mode == pr_plane {
    if !top || !left {
      return Err("no edge")
    }
    let mut h = dst[off - stride + 4] - dst[off - stride + 2]
    let mut v = dst[off + 4 * stride - 1] - dst[off + 2 * stride - 1]
    for k = 2; k <= 4; k = k + 1 {
      h = h + k * (dst[off - stride + 3 + k] - dst[off - stride + 3 - k])
      v = v +
        k * (dst[off + (3 + k) * stride - 1] - dst[off + (3 - k) * stride - 1])
    }
    h = (17 * h + 16) >> 5
    v = (17 * v + 16) >> 5
    let mut a = 16 * (dst[off + 7 * stride - 1] + dst[off - stride + 7] + 1) -
      3 * (v + h)
    for j = 0; j < 8; j = j + 1 {
      let b = a
      a = a + v
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = pr_clip8((b + i * h) >> 5, bit_depth)
      }
    }
  } else {
    return Err("bad mode")
  }
  Ok(())
}

///|
/// Deterministic plane generator (LCG) with smooth gradients plus noise —
/// plane mode amplifies sample differences, so a spread of inputs matters.
fn pr_gen(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
fn pr_copy(a : Array[Int32]) -> Array[Int32] {
  let b : Array[Int32] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
test "h264 pred v128: 16x16 and 8x8 all modes, depths, availability" {
  let stride : Int32 = 32
  let plane_n = stride * 32
  let modes : Array[Int32] = [0, 1, 2, 3, 4, 5, 6]
  for bit_depth in [8, 10, 12] {
    let max = (1 << bit_depth) - 1
    for mode in modes {
      for
        (top, left) in [
          (true, true),
          (true, false),
          (false, true),
          (false, false),
        ] {
        for k = 0; k < 3; k = k + 1 {
          let src = pr_gen(
            0x9E3779B9U +
            mode.reinterpret_as_uint() * 31U +
            k.reinterpret_as_uint(),
            plane_n,
            max,
          )
          // 16x16
          let d1 = pr_copy(src)
          let d2 = pr_copy(src)
          let off = 8 * stride + 8
          let r1 = pr_pred16x16(d1, off, stride, mode, top, left, bit_depth)
          let r2 = h264_pred16x16_v128(
            d2,
            off,
            stride,
            mode,
            top,
            left,
            bit_depth~,
          )
          assert_eq(pr_ok(r2), pr_ok(r1))
          if pr_ok(r1) {
            let mut i = 0
            while i < plane_n {
              assert_eq(d2[i], d1[i])
              i = i + 1
            }
          }
          // 8x8
          let e1 = pr_copy(src)
          let e2 = pr_copy(src)
          let o2 = 8 * stride + 8
          let s1 = pr_pred8x8(e1, o2, stride, mode, top, left, bit_depth)
          let s2 = h264_pred8x8_v128(
            e2,
            o2,
            stride,
            mode,
            top,
            left,
            bit_depth~,
          )
          assert_eq(pr_ok(s2), pr_ok(s1))
          if pr_ok(s1) {
            let mut i = 0
            while i < plane_n {
              assert_eq(e2[i], e1[i])
              i = i + 1
            }
          }
        }
      }
    }
  }
}

///|
test "h264 pred v128: unsupported modes report the same error" {
  let stride : Int32 = 16
  let plane_n = stride * 16
  let src = pr_gen(0x12345678U, plane_n, 255)
  let d = pr_copy(src)
  assert_true(
    !pr_ok(
      h264_pred16x16_v128(
        d,
        8 * stride + 8,
        stride,
        99,
        true,
        true,
        bit_depth=8,
      ),
    ),
  )
  assert_true(
    !pr_ok(
      h264_pred8x8_v128(d, 8 * stride + 8, stride, 99, true, true, bit_depth=8),
    ),
  )
  // and the plane is untouched by the rejected call
  let mut i = 0
  while i < plane_n {
    assert_eq(d[i], src[i])
    i = i + 1
  }
}

///|
test "h264 pred v128: DC sums saturate at high bit depth and extremes" {
  // All-max / all-zero edges: the DC average must land on the port's exact
  // rounding, including the (sum + 16) >> 5 / (sum + 8) >> 4 split.
  let stride : Int32 = 32
  let plane_n = stride * 32
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    for fill in [0, max] {
      let src : Array[Int32] = Array::make(plane_n, fill)
      for mode in [pr_dc, pr_top_dc, pr_left_dc, pr_128_dc] {
        let d1 = pr_copy(src)
        let d2 = pr_copy(src)
        let off = 8 * stride + 8
        let r1 = pr_pred16x16(d1, off, stride, mode, true, true, bit_depth)
        let r2 = h264_pred16x16_v128(
          d2,
          off,
          stride,
          mode,
          true,
          true,
          bit_depth~,
        )
        assert_eq(pr_ok(r2), pr_ok(r1))
        let mut i = 0
        while i < plane_n {
          assert_eq(d2[i], d1[i])
          i = i + 1
        }
      }
    }
  }
}

///|
test "h264 pred v128: plane mode with steep and flat gradients" {
  // Terrain where h is large positive, large negative, or zero, so the
  // ramp's clip and the i*h term are both exercised.
  let stride : Int32 = 32
  let plane_n = stride * 32
  let off = 8 * stride + 8
  let shapes : Array[String] = ["flat", "ramp_up", "ramp_down", "checker"]
  for shape in shapes {
    for bit_depth in [8, 10] {
      let max = (1 << bit_depth) - 1
      let src : Array[Int32] = Array::make(plane_n, max / 2)
      if shape == "ramp_up" {
        for r = 0; r < 32; r = r + 1 {
          for c = 0; c < 32; c = c + 1 {
            src[r * stride + c] = (r * 3 + c * 5) % (max + 1)
          }
        }
      } else if shape == "ramp_down" {
        for r = 0; r < 32; r = r + 1 {
          for c = 0; c < 32; c = c + 1 {
            src[r * stride + c] = max - (r * 3 + c * 5) % (max + 1)
          }
        }
      } else if shape == "checker" {
        for r = 0; r < 32; r = r + 1 {
          for c = 0; c < 32; c = c + 1 {
            src[r * stride + c] = if (r + c) % 2 == 0 { 0 } else { max }
          }
        }
      }
      let d1 = pr_copy(src)
      let d2 = pr_copy(src)
      let r1 = pr_pred16x16(d1, off, stride, pr_plane, true, true, bit_depth)
      let r2 = h264_pred16x16_v128(
        d2,
        off,
        stride,
        pr_plane,
        true,
        true,
        bit_depth~,
      )
      assert_eq(pr_ok(r2), pr_ok(r1))
      let mut i = 0
      while i < plane_n {
        assert_eq(d2[i], d1[i])
        i = i + 1
      }
      let e1 = pr_copy(src)
      let e2 = pr_copy(src)
      let s1 = pr_pred8x8(e1, off, stride, pr_plane, true, true, bit_depth)
      let s2 = h264_pred8x8_v128(
        e2,
        off,
        stride,
        pr_plane,
        true,
        true,
        bit_depth~,
      )
      assert_eq(pr_ok(s2), pr_ok(s1))
      let mut j = 0
      while j < plane_n {
        assert_eq(e2[j], e1[j])
        j = j + 1
      }
    }
  }
}

///|
test "h264 pred v128: writes stay inside the predicted block" {
  // Every mode must leave the top row, the left column and the samples past
  // the block untouched (the scalar port's write footprint).
  let stride : Int32 = 32
  let plane_n = stride * 32
  let src = pr_gen(0xFEEDFACEU, plane_n, 255)
  let off = 8 * stride + 8
  for
    mode in [pr_vert, pr_hor, pr_dc, pr_top_dc, pr_left_dc, pr_128_dc, pr_plane] {
    let d2 = pr_copy(src)
    h264_pred16x16_v128(d2, off, stride, mode, true, true, bit_depth=8)
    |> ignore
    let mut r = 0
    while r < 32 {
      let mut c = 0
      while c < 32 {
        let idx = r * stride + c
        let inside = r >= 8 && r < 24 && c >= 8 && c < 24
        if !inside {
          assert_eq(d2[idx], src[idx])
        }
        c = c + 1
      }
      r = r + 1
    }
  }
}
