///|
/// Whitebox tests for the SIMD (`@v128`) horizontal scaler
/// (`hscale_v128.mbt`).
///
/// The SIMD path must agree with the scalar port (`sws_hscale8to15`) on
/// every input: integer arithmetic wraps identically modulo 2^32, so the
/// lane-partial summation order cannot change a single output value. The
/// scalar port is itself verified by the real-data scaling suites
/// (`swscale_scale_realdata_test.mbt`).

///|
/// Deterministic byte-buffer generator (LCG). */
fn hs_gen_bytes(seed : UInt32, n : Int32) -> Bytes {
  let a : Array[Byte] = Array::make(n, b'\x00')
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFF).to_byte()
  }
  Bytes::from_array(a)
}

///|
/// Deterministic filter (LCG): coefficients in the FFmpeg 14-bit range,
/// tap windows fully inside the row. */
fn hs_gen_filter(
  seed : UInt32,
  src_w : Int32,
  dst_w : Int32,
  size : Int32,
) -> SwsFilter {
  let mut s = seed
  let coeffs : Array[Int32] = Array::make(dst_w * size, 0)
  let pos : Array[Int32] = Array::make(dst_w, 0)
  for i = 0; i < dst_w; i = i + 1 {
    for j = 0; j < size; j = j + 1 {
      s = s * 1103515245U + 12345U
      coeffs[i * size + j] = ((s >> 16) & 0x3FFFU).reinterpret_as_int() -
      8192
    }
    s = s * 1103515245U + 12345U
    pos[i] = ((s >> 16) % (src_w - size + 1).reinterpret_as_uint()).reinterpret_as_int()
  }
  { coeffs, pos, size }
}

///|
test "hscale v128: equality with the scalar port across sizes and depths" {
  let depths : Array[Int32] = [8, 9, 10, 12, 16]
  let sizes : Array[Int32] = [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17]
  for src_bits in depths {
    let step = (src_bits + 7) / 8
    for size in sizes {
      let src_w = size + 40
      let dst_w = 23
      let src = hs_gen_bytes(
        0x9E3779B9U + size.reinterpret_as_uint() * 31U +
        src_bits.reinterpret_as_uint(),
        src_w * step,
      )
      let f = hs_gen_filter(
        0xDEADBEEFU + src_bits.reinterpret_as_uint() * 7U,
        src_w,
        dst_w,
        size,
      )
      let a = sws_hscale8to15(src, 0, f, dst_w, src_bits)
      let b = sws_hscale8to15_v128(src, 0, f, dst_w, src_bits)
      for i = 0; i < dst_w; i = i + 1 {
        assert_eq(b[i], a[i])
      }
    }
  }
}

///|
test "hscale v128: long rows and nonzero row offsets" {
  let depths : Array[Int32] = [8, 16]
  let sizes : Array[Int32] = [8, 15]
  for src_bits in depths {
    let step = (src_bits + 7) / 8
    for size in sizes {
      let src_w = 640
      let dst_w = 121
      // two rows worth of source; scale the second row (row_off = src_w)
      let src = hs_gen_bytes(0xA5A5A5A5U + size.reinterpret_as_uint(), 2 *
        src_w *
        step)
      let f = hs_gen_filter(0x12345678U + src_bits.reinterpret_as_uint(), src_w, dst_w, size)
      for row = 0; row < 2; row = row + 1 {
        let off = row * src_w
        let a = sws_hscale8to15(src, off, f, dst_w, src_bits)
        let b = sws_hscale8to15_v128(src, off, f, dst_w, src_bits)
        for i = 0; i < dst_w; i = i + 1 {
          assert_eq(b[i], a[i])
        }
      }
    }
  }
}

///|
test "hscale v128: top clamp and int16 store wrap" {
  // size 8, all taps 0xff, coefficients +8192: the sum >> 7 exceeds the
  // 32767 top clamp (mirrors hScale8To15_c's FFMIN).
  let src = Bytes::from_array([
    b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff', b'\xff',
  ])
  let f_hi : SwsFilter = {
    coeffs: Array::make(8, 8192),
    pos: [0],
    size: 8,
  }
  assert_eq(sws_hscale8to15_v128(src, 0, f_hi, 1, 8)[0], 32767)
  assert_eq(sws_hscale8to15_v128(src, 0, f_hi, 1, 8)[0], sws_hscale8to15(src, 0, f_hi, 1, 8)[0])
  // Negative coefficients miss the clamp and exercise the int16 wrap on
  // store: 8 * 255 * -8192 = -16711680, >> 7 = -130560 -> 512 after the
  // wrap.
  let f_lo : SwsFilter = {
    coeffs: Array::make(8, -8192),
    pos: [0],
    size: 8,
  }
  assert_eq(sws_hscale8to15_v128(src, 0, f_lo, 1, 8)[0], 512)
  assert_eq(sws_hscale8to15_v128(src, 0, f_lo, 1, 8)[0], sws_hscale8to15(src, 0, f_lo, 1, 8)[0])
  // Zero samples stay zero through both paths.
  let z = Bytes::from_array([
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  assert_eq(sws_hscale8to15_v128(z, 0, f_hi, 1, 8)[0], 0)
}
