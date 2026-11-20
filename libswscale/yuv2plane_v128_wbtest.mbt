///|
/// Whitebox tests for the SIMD (`@v128`) `yuv2planeX` rows
/// (`yuv2plane_v128.mbt`).
///
/// The SIMD paths must agree with the scalar rows
/// (`sws_yuv2planeX_row_8/16`) byte-for-byte on every input; the scalar
/// rows are exercised end-to-end by the real-data scaling suites. Inputs
/// are 15-bit horizontal intermediates in the `int16` domain, as
/// `sws_hscale8to15` produces.

///|
/// Deterministic int16-domain row generator (LCG). */
fn yp_gen_row(seed : UInt32, n : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() << 16 >> 16
  }
  a
}

///|
/// Deterministic coefficient bank (LCG) in the FFmpeg 14-bit range. */
fn yp_gen_coffs(seed : UInt32, n : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0x3FFFU).reinterpret_as_int() - 8192
  }
  a
}

///|
test "yuv2planeX v128: 8-bit equality across taps, lengths and dither" {
  let taps : Array[Int32] = [1, 2, 3, 4, 5, 8]
  let widths : Array[Int32] = [
    1, 2, 7, 8, 9, 15, 16, 17, 23, 40, 64, 65, 121,
  ]
  for size in taps {
    for dst_w in widths {
      let rows : Array[Array[Int32]] = []
      let packed : Array[FixedArray[Byte]] = []
      for j = 0; j < size; j = j + 1 {
        let r = yp_gen_row(0x9E3779B9U + size.reinterpret_as_uint() * 131U + j.reinterpret_as_uint(), dst_w)
        rows.push(r)
        packed.push(sws_pack_row_i16(r, dst_w))
      }
      let coffs = yp_gen_coffs(0xDEADBEEFU + size.reinterpret_as_uint(), size)
      for y = 0; y < 10; y = y + 1 {
        for off = 0; off < 4; off = off + 1 {
          for nbps in [false, true] {
            let d8 = sws_dither_row_8(y, off, nbps)
            let a = sws_yuv2planeX_row_8(rows, coffs, dst_w, y, off, nbps)
            let b = sws_yuv2planeX_8_v128(packed, coffs, dst_w, d8)
            for i = 0; i < dst_w; i = i + 1 {
              assert_eq(b[i], a[i])
            }
          }
        }
      }
    }
  }
}

///|
test "yuv2planeX v128: 9..16-bit equality across taps, lengths and depths" {
  let depths : Array[Int32] = [9, 10, 12, 16]
  let taps : Array[Int32] = [1, 2, 3, 5, 8]
  let widths : Array[Int32] = [1, 7, 8, 9, 16, 17, 23, 64, 65]
  for dst_bits in depths {
    for size in taps {
      for dst_w in widths {
        let rows : Array[Array[Int32]] = []
        let packed : Array[FixedArray[Byte]] = []
        for j = 0; j < size; j = j + 1 {
          let r = yp_gen_row(
            0xA5A5A5A5U + dst_bits.reinterpret_as_uint() * 61U + size.reinterpret_as_uint() * 7U + j.reinterpret_as_uint(),
            dst_w,
          )
          rows.push(r)
          packed.push(sws_pack_row_i16(r, dst_w))
        }
        let coffs = yp_gen_coffs(
          0x12345678U + dst_bits.reinterpret_as_uint() + size.reinterpret_as_uint(),
          size,
        )
        let a = sws_yuv2planeX_row_16(rows, coffs, dst_w, dst_bits)
        let b = sws_yuv2planeX_16_v128(packed, coffs, dst_w, dst_bits)
        for i = 0; i < 2 * dst_w; i = i + 1 {
          assert_eq(b[i], a[i])
        }
      }
    }
  }
}

///|
test "yuv2planeX v128: saturation pins on both sides" {
  // Four taps of +32767 x +8192 saturate high (255 / full scale), the
  // negated bank saturates low (0).
  let dst_w : Int32 = 8
  let row = Array::make(8, 32767)
  let rows = [row, row, row, row]
  let packed = [
    sws_pack_row_i16(row, 8),
    sws_pack_row_i16(row, 8),
    sws_pack_row_i16(row, 8),
    sws_pack_row_i16(row, 8),
  ]
  let hi : Array[Int32] = [8192, 8192, 8192, 8192]
  let lo : Array[Int32] = [-8192, -8192, -8192, -8192]
  let d8 = sws_dither_row_8(0, 0, false)
  for i = 0; i < dst_w; i = i + 1 {
    assert_eq(sws_yuv2planeX_8_v128(packed, hi, dst_w, d8)[i], 255)
    assert_eq(sws_yuv2planeX_8_v128(packed, lo, dst_w, d8)[i], 0)
    assert_eq(
      sws_yuv2planeX_8_v128(packed, hi, dst_w, d8)[i],
      sws_yuv2planeX_row_8(rows, hi, dst_w, 0, 0, false)[i],
    )
  }
  // 10-bit output saturates at 1023.
  for i = 0; i < 2 * dst_w; i = i + 2 {
    let v16 = sws_yuv2planeX_16_v128(packed, hi, dst_w, 10)
    let u = v16[i].to_uint() | (v16[i + 1].to_uint() << 8)
    assert_eq(u, 1023U)
  }
}
