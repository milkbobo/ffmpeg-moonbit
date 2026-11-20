///|
/// Whitebox tests for the SIMD (`@v128`) YUV→RGB24 converter
/// (`yuv2rgb_v128.mbt`).
///
/// Two layers: (1) the recovered closed-form colour matrix must equal
/// the probed official tables entry-by-entry (this is what makes the
/// table-free SIMD kernel byte-exact with the LUT scalar); (2) the
/// converter must equal the scalar rows byte-for-byte on generated
/// frames of every supported geometry, including RGB/BGR and the
/// `w % 4` tails.

///|
/// Deterministic byte-buffer generator (LCG). */
fn yr_gen_bytes(seed : UInt32, n : Int32) -> Bytes {
  let a : Array[Byte] = Array::make(n, b'\x00')
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFF).to_byte()
  }
  Bytes::from_array(a)
}

///|
test "yuv2rgb v128: closed forms equal the official tables" {
  // luma ramp
  for i = 0; i < 2048; i = i + 1 {
    assert_eq(sws_yramp(i), official_y_table[i])
  }
  // chroma bases and the G offset, over the full indexed domain
  for x = 512; x < 768; x = x + 1 {
    assert_eq((89828 * x - 2541216) >> 16, official_base_r[x])
    assert_eq((113536 * x - 17694720) >> 16, official_base_b[x])
    assert_eq((-22050 * x + 69092460) >> 16, official_base_gu[x])
    assert_eq((-45756 * x + 29325312) >> 16, official_off_gv[x])
  }
  // composite R over every (Y, V), B over every (Y, U), G over every
  // (Y, U) for sampled V plus every (Y, V) for sampled U
  for yv = 0; yv < 256; yv = yv + 1 {
    for c = 0; c < 256; c = c + 1 {
      let vv = c + 512
      let uv = c + 512
      let idx_r = yv + ((89828 * vv - 2541216) >> 16)
      assert_eq(sws_yramp(idx_r), official_y_table[official_base_r[vv] + yv])
      let idx_b = yv + ((113536 * uv - 17694720) >> 16)
      assert_eq(sws_yramp(idx_b), official_y_table[official_base_b[uv] + yv])
      let idx_g = yv + ((-22050 * uv + 69092460) >> 16)
      let gv = (-45756 * vv + 29325312) >> 16
      let g = (sws_yramp(idx_g) + gv) & 0xFF
      assert_eq(
        g,
        (official_y_table[official_base_gu[uv] + yv] + official_off_gv[vv]) &
        0xFF,
      )
    }
  }
}

///|
test "yuv2rgb v128: byte equality with the scalar converter" {
  let widths : Array[Int32] = [2, 4, 6, 8, 12, 16, 18, 20, 64, 66]
  for w in widths {
    let h : Int32 = 4
    // 4:2:0 (paired chroma rows)
    let cw0 = w / 2
    let y = yr_gen_bytes(0x9E3779B9U + w.reinterpret_as_uint(), w * h)
    let u = yr_gen_bytes(0xDEADBEEFU + w.reinterpret_as_uint(), cw0 * h / 2)
    let v = yr_gen_bytes(0x12345678U + w.reinterpret_as_uint(), cw0 * h / 2)
    for bgr in [false, true] {
      let a = yuv_rows_to_rgb24_scalar(y, u, v, w, h, cw0, true, bgr)
      let b = yuv_rows_to_rgb24_v128(y, u, v, w, h, cw0, true, bgr)
      assert_eq(b.length(), a.length())
      for i = 0; i < a.length(); i = i + 1 {
        assert_eq(b[i], a[i])
      }
    }
    // 4:2:2 and 4:4:4 (one-to-one chroma rows)
    let geoms : Array[(Int32, Bytes, Bytes)] = [
      (
        cw0,
        yr_gen_bytes(0xA5A5A5A5U, cw0 * h),
        yr_gen_bytes(0x5A5A5A5AU, cw0 * h),
      ),
      (w, yr_gen_bytes(0xC0FFEE01U, w * h), yr_gen_bytes(0x0BADF00DU, w * h)),
    ]
    for pair in geoms {
      let (cw, uu, vv) = pair
      for bgr in [false, true] {
        let a = yuv_rows_to_rgb24_scalar(y, uu, vv, w, h, cw, false, bgr)
        let b = yuv_rows_to_rgb24_v128(y, uu, vv, w, h, cw, false, bgr)
        assert_eq(b.length(), a.length())
        for i = 0; i < a.length(); i = i + 1 {
          assert_eq(b[i], a[i])
        }
      }
    }
  }
}

///|
test "yuv2rgb v128: extreme luma/chroma frames" {
  // all-zero, all-max and mixed-extreme planes exercise both clamps
  // and the G wrap on every pixel.
  let w : Int32 = 8
  let h : Int32 = 2
  let cw = w / 2
  let planes : Array[(Bytes, Bytes, Bytes)] = []
  planes.push(
    (
      Bytes::make(w * h, b'\x00'),
      Bytes::make(cw * h, b'\x00'),
      Bytes::make(cw * h, b'\x00'),
    ),
  )
  planes.push(
    (
      Bytes::make(w * h, b'\xff'),
      Bytes::make(cw * h, b'\xff'),
      Bytes::make(cw * h, b'\xff'),
    ),
  )
  planes.push(
    (
      yr_gen_bytes(0xFEEDFACEU, w * h),
      Bytes::make(cw * h, b'\x00'),
      Bytes::make(cw * h, b'\xff'),
    ),
  )
  planes.push(
    (
      Bytes::make(w * h, b'\x10'),
      Bytes::make(cw * h, b'\x80'),
      yr_gen_bytes(0x13579BDFU, cw * h),
    ),
  )
  for idx = 0; idx < planes.length(); idx = idx + 1 {
    let (y, u, v) = planes[idx]
    let a = yuv_rows_to_rgb24_scalar(y, u, v, w, h, cw, true, false)
    let b = yuv_rows_to_rgb24_v128(y, u, v, w, h, cw, true, false)
    for i = 0; i < a.length(); i = i + 1 {
      assert_eq(b[i], a[i])
    }
  }
}

///|
test "yuv444 to RGB gives each pixel its own chroma sample" {
  let converter = Yuv2Rgb::mpeg()
  let luma = b"\x80\x80\x80\x80\x80"
  let cb = b"\x80\x60\x70\x90\xa0"
  let cr = b"\x80\x90\x70\xb0\x60"
  let row = converter.yuv444_to_rgb24(luma, cb, cr, 5, 1)
  let mut expected = b""
  for i in 0..<5 {
    expected = expected +
      converter.yuv444_to_rgb24(
        luma[i:i + 1].to_owned(),
        cb[i:i + 1].to_owned(),
        cr[i:i + 1].to_owned(),
        1,
        1,
      )
  }
  assert_eq(row, expected)
}
