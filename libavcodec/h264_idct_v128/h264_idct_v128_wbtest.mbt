///|
/// Whitebox tests for the SIMD (`@v128`) H.264 inverse-transform add
/// kernels (`h264_idct_v128.mbt`).
///
/// The `hr_*` functions are verbatim transcriptions of the scalar port
/// (`libavcodec/h264_idct.mbt`) — the parent package's privates are
/// not visible from a subpackage, so the reference is carried here and
/// the SIMD kernels must match it (dst region, coefficient clearing
/// and all) on every input.

///|
fn hr_u(x : Int32) -> UInt32 {
  x.reinterpret_as_uint()
}

///|
fn hr_s(x : UInt32) -> Int32 {
  x.reinterpret_as_int()
}

///|
fn hr_store(value : Int32, bit_depth : Int32) -> Int32 {
  if bit_depth == 8 {
    value << 16 >> 16
  } else {
    value
  }
}

///|
fn hr_storeu(value : UInt32, bit_depth : Int32) -> Int32 {
  hr_store(value.reinterpret_as_int(), bit_depth)
}

///|
fn hr_clip8(x : Int32, bit_depth : Int32) -> Int32 {
  if x < 0 {
    0
  } else if x > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    x
  }
}

///|
/// Verbatim `h264_idct_add`. */
fn hr_idct_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth : Int32,
) -> Unit {
  block[bo] = hr_store(block[bo] + 32, bit_depth)
  for i = 0; i < 4; i = i + 1 {
    let b = bo + i
    let z0 = hr_u(block[b]) + hr_u(block[b + 8])
    let z1 = hr_u(block[b]) - hr_u(block[b + 8])
    let z2 = hr_u(block[b + 4] >> 1) - hr_u(block[b + 12])
    let z3 = hr_u(block[b + 4]) + hr_u(block[b + 12] >> 1)
    block[b] = hr_storeu(z0 + z3, bit_depth)
    block[b + 4] = hr_storeu(z1 + z2, bit_depth)
    block[b + 8] = hr_storeu(z1 - z2, bit_depth)
    block[b + 12] = hr_storeu(z0 - z3, bit_depth)
  }
  for i = 0; i < 4; i = i + 1 {
    let b = bo + 4 * i
    let z0 = hr_u(block[b]) + hr_u(block[b + 2])
    let z1 = hr_u(block[b]) - hr_u(block[b + 2])
    let z2 = hr_u(block[b + 1] >> 1) - hr_u(block[b + 3])
    let z3 = hr_u(block[b + 1]) + hr_u(block[b + 3] >> 1)
    let p = dst_off + i
    dst[p] = hr_clip8(dst[p] + (hr_s(z0 + z3) >> 6), bit_depth)
    dst[p + stride] = hr_clip8(
      dst[p + stride] + (hr_s(z1 + z2) >> 6),
      bit_depth,
    )
    dst[p + 2 * stride] = hr_clip8(
      dst[p + 2 * stride] + (hr_s(z1 - z2) >> 6),
      bit_depth,
    )
    dst[p + 3 * stride] = hr_clip8(
      dst[p + 3 * stride] + (hr_s(z0 - z3) >> 6),
      bit_depth,
    )
  }
  for i = 0; i < 16; i = i + 1 {
    block[bo + i] = 0
  }
}

///|
/// Verbatim `h264_idct_dc_add`. */
fn hr_idct_dc_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth : Int32,
) -> Unit {
  let dc = (block[bo] + 32) >> 6
  block[bo] = 0
  for j = 0; j < 4; j = j + 1 {
    for i = 0; i < 4; i = i + 1 {
      let p = dst_off + j * stride + i
      dst[p] = hr_clip8(dst[p] + dc, bit_depth)
    }
  }
}

///|
/// Verbatim `h264_idct8_dc_add`. */
fn hr_idct8_dc_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth : Int32,
) -> Unit {
  let dc = (block[bo] + 32) >> 6
  block[bo] = 0
  for j = 0; j < 8; j = j + 1 {
    for i = 0; i < 8; i = i + 1 {
      let p = dst_off + j * stride + i
      dst[p] = hr_clip8(dst[p] + dc, bit_depth)
    }
  }
}

///|
/// Deterministic int16-domain coefficient generator (LCG). */
fn h4_gen_i16(seed : UInt32, n : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() << 16 >> 16
  }
  a
}

///|
/// Deterministic pixel-plane generator (LCG). */
fn h4_gen_px(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
test "h264 idct v128: idct_add equality across depths and strides" {
  let stride : Int32 = 37
  let plane_n = 37 * 24
  for bit_depth in [8, 10] {
    for k = 0; k < 60; k = k + 1 {
      let px = 1 << bit_depth
      let d1 = h4_gen_px(0x9E3779B9U + k.reinterpret_as_uint(), plane_n, px - 1)
      let d2 = Array::make(plane_n, 0)
      for i = 0; i < plane_n; i = i + 1 {
        d2[i] = d1[i]
      }
      let b1 = h4_gen_i16(0xDEADBEEFU + k.reinterpret_as_uint() * 7U, 16)
      let b2 = Array::make(16, 0)
      for i = 0; i < 16; i = i + 1 {
        b2[i] = b1[i]
      }
      let off = 3 * stride + 5
      hr_idct_add(d1, off, stride, b1, 0, bit_depth)
      h264_idct_add_v128(d2, off, stride, b2, 0, bit_depth~)
      for i = 0; i < plane_n; i = i + 1 {
        assert_eq(d2[i], d1[i])
      }
      for i = 0; i < 16; i = i + 1 {
        assert_eq(b2[i], b1[i])
      }
    }
  }
}

///|
test "h264 idct v128: dc adds, extremes and coefficient boundaries" {
  let stride : Int32 = 16
  let plane_n = 16 * 16
  // dc_add / idct8_dc_add equality incl. clamping both sides
  let dcs : Array[Int32] = [0, 32, 32 * 63, -32, -4096, 32767, -32768]
  for dc in dcs {
    let d1 = h4_gen_px(0xA5A5A5A5U, plane_n, 255)
    let d2 = Array::make(plane_n, 0)
    for i = 0; i < plane_n; i = i + 1 {
      d2[i] = d1[i]
    }
    let b1 = [dc, 0, 0, 0]
    let b2 = [dc, 0, 0, 0]
    hr_idct_dc_add(d1, 4 * stride + 4, stride, b1, 0, 8)
    h264_idct_dc_add_v128(d2, 4 * stride + 4, stride, b2, 0, bit_depth=8)
    for i = 0; i < plane_n; i = i + 1 {
      assert_eq(d2[i], d1[i])
    }
    assert_eq(b2[0], b1[0])
    let b3 = [dc]
    let b4 = [dc]
    hr_idct8_dc_add(d1, 4 * stride + 4, stride, b3, 0, 8)
    h264_idct8_dc_add_v128(d2, 4 * stride + 4, stride, b4, 0, bit_depth=8)
    for i = 0; i < plane_n; i = i + 1 {
      assert_eq(d2[i], d1[i])
    }
  }
  // extreme 4x4 coefficients (int16 corners) through the full transform
  let corners : Array[Int32] = [32767, -32768, 0]
  for c in corners {
    for k = 0; k < 8; k = k + 1 {
      let b1 = h4_gen_i16(0x12345678U + k.reinterpret_as_uint(), 16)
      for j = 0; j < 16; j = j + 1 {
        if (j + k) % 3 == 0 {
          b1[j] = c
        }
      }
      let b2 = Array::make(16, 0)
      for i = 0; i < 16; i = i + 1 {
        b2[i] = b1[i]
      }
      let d1 = h4_gen_px(0x5A5A5A5AU + k.reinterpret_as_uint(), plane_n, 255)
      let d2 = Array::make(plane_n, 0)
      for i = 0; i < plane_n; i = i + 1 {
        d2[i] = d1[i]
      }
      hr_idct_add(d1, 17, stride, b1, 0, 8)
      h264_idct_add_v128(d2, 17, stride, b2, 0, bit_depth=8)
      for i = 0; i < plane_n; i = i + 1 {
        assert_eq(d2[i], d1[i])
      }
    }
  }
  // zero coefficients leave the plane untouched
  let z1 = h4_gen_px(0xC0FFEE01U, plane_n, 255)
  let z2 = Array::make(plane_n, 0)
  for i = 0; i < plane_n; i = i + 1 {
    z2[i] = z1[i]
  }
  let bz1 = Array::make(16, 0)
  let bz2 = Array::make(16, 0)
  hr_idct_add(z1, 17, stride, bz1, 0, 8)
  h264_idct_add_v128(z2, 17, stride, bz2, 0, bit_depth=8)
  for i = 0; i < plane_n; i = i + 1 {
    assert_eq(z2[i], z1[i])
  }
}
