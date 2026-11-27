///|
/// Whitebox tests for the SIMD (`@v128`) HEVC motion-compensation kernels
/// (`hevc_mc_v128.mbt`).
///
/// The `hr_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/hevc_mc.mbt`: `hevc_qpel_h`, `hevc_qpel_v`, `hevc_epel_h`,
/// `hevc_epel_v`, and the `_uni` epilogue of `hevc_luma_mc_uni`) — the
/// parent package's privates are not visible from a subpackage, so the
/// reference is carried here. Both must agree bit-for-bit for every
/// filter phase, block size and bit depth.

///|
/// `ff_hevc_qpel_filters[4][16]` (only the first 8 taps are used). */
let hr_qpel_filters : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0, 0, 0, 0, 0, 0],
  [-1, 4, -10, 58, 17, -5, 1, 0],
  [-1, 4, -11, 40, 40, -11, 4, -1],
  [0, 1, -5, 17, 58, -10, 4, -1],
]

///|
/// `ff_hevc_epel_filters[8][4]`. */
let hr_epel_filters : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0, 0],
  [-2, 58, 10, -2],
  [-4, 54, 16, -2],
  [-6, 46, 28, -4],
  [-4, 36, 36, -4],
  [-4, 28, 46, -6],
  [-2, 16, 54, -4],
  [-2, 10, 58, -2],
]

///|
fn hr_clip(v : Int32, bd : Int32) -> Int32 {
  let max = (1 << bd) - 1
  if v < 0 {
    0
  } else if v > max {
    max
  } else {
    v
  }
}

///|
/// Verbatim `hevc_qpel_h`. */
fn hr_qpel_h(
  row : FixedArray[Int32],
  i : Int32,
  f : FixedArray[Int32],
) -> Int32 {
  f[0] * row[i - 3] +
  f[1] * row[i - 2] +
  f[2] * row[i - 1] +
  f[3] * row[i] +
  f[4] * row[i + 1] +
  f[5] * row[i + 2] +
  f[6] * row[i + 3] +
  f[7] * row[i + 4]
}

///|
/// Verbatim `hevc_qpel_v`. */
fn hr_qpel_v(
  buf : FixedArray[Int32],
  idx : Int32,
  stride : Int32,
  f : FixedArray[Int32],
) -> Int32 {
  f[0] * buf[idx - 3 * stride] +
  f[1] * buf[idx - 2 * stride] +
  f[2] * buf[idx - stride] +
  f[3] * buf[idx] +
  f[4] * buf[idx + stride] +
  f[5] * buf[idx + 2 * stride] +
  f[6] * buf[idx + 3 * stride] +
  f[7] * buf[idx + 4 * stride]
}

///|
/// Verbatim `hevc_epel_h`. */
fn hr_epel_h(
  row : FixedArray[Int32],
  i : Int32,
  f : FixedArray[Int32],
) -> Int32 {
  f[0] * row[i - 1] + f[1] * row[i] + f[2] * row[i + 1] + f[3] * row[i + 2]
}

///|
/// Verbatim `hevc_epel_v`. */
fn hr_epel_v(
  buf : FixedArray[Int32],
  idx : Int32,
  stride : Int32,
  f : FixedArray[Int32],
) -> Int32 {
  f[0] * buf[idx - stride] +
  f[1] * buf[idx] +
  f[2] * buf[idx + stride] +
  f[3] * buf[idx + 2 * stride]
}

///|
/// Verbatim `hevc_luma_mc_uni`'s four phases. */
fn hr_luma_mc_uni(
  dst : Array[Int32],
  dst_stride : Int32,
  buf : FixedArray[Int32],
  buf_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mx : Int32,
  my : Int32,
  bw : Int32,
  bh : Int32,
  bd : Int32,
) -> Unit {
  let base = 3 + 3 * buf_stride
  let norm = bd - 8
  let shift = 14 - bd
  let offset = 1 << (shift - 1)
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        dst[(y0 + j) * dst_stride + x0 + i] = buf[base + j * buf_stride + i]
      }
    }
  } else if my == 0 {
    let f = hr_qpel_filters[mx]
    for j in 0..<bh {
      let row = base + j * buf_stride
      for i in 0..<bw {
        let v = (hr_qpel_h(buf, row + i, f) >> norm) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hr_clip(v >> shift, bd)
      }
    }
  } else if mx == 0 {
    let f = hr_qpel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (
            hr_qpel_v(buf, base + j * buf_stride + i, buf_stride, f) >> norm
          ) +
          offset
        dst[(y0 + j) * dst_stride + x0 + i] = hr_clip(v >> shift, bd)
      }
    }
  } else {
    let fh = hr_qpel_filters[mx]
    let fv = hr_qpel_filters[my]
    let max_pb : Int32 = 64
    let tmp : FixedArray[Int32] = FixedArray::make(max_pb * (max_pb + 8), 0)
    for j in 0..<(bh + 7) {
      let row = 3 + j * buf_stride
      for i in 0..<bw {
        tmp[j * max_pb + i] = hr_qpel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 3 * max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hr_qpel_v(tmp, tbase + j * max_pb + i, max_pb, fv) >> 6) +
          offset
        dst[(y0 + j) * dst_stride + x0 + i] = hr_clip(v >> shift, bd)
      }
    }
  }
}

///|
/// Deterministic generator (LCG). */
fn hr_gen(seed : UInt32, n : Int32, max : Int32) -> FixedArray[Int32] {
  let a : FixedArray[Int32] = FixedArray::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
fn hr_same(a : FixedArray[Int32], b : FixedArray[Int32]) -> Bool {
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
test "hevc mc v128: qpel h/v/hv raw sums over phases, sizes, depths" {
  let sstride : Int32 = 96
  let src_n = sstride * 96
  let dstride : Int32 = 80
  let dst_n = dstride * 96
  let soff = 24 * sstride + 12
  let dstoff = 24 * dstride + 8
  for pixel_max in [255, 1023, 4095] {
    for (w, h) in [(4, 4), (8, 8), (16, 16), (32, 32), (2, 2), (6, 6), (12, 4)] {
      let src = hr_gen(
        0x9E3779B9U + w.reinterpret_as_uint() * 31U + h.reinterpret_as_uint(),
        src_n,
        pixel_max,
      )
      for mx in [1, 2, 3] {
        let fh = hr_qpel_filters[mx]
        // h
        let e1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        let e2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            e1[dstoff + y * dstride + x] = hr_qpel_h(
              src,
              soff + y * sstride + x,
              fh,
            )
          }
        }
        hevc_qpel_h_raw_v128(e2, dstoff, dstride, src, soff, sstride, w, h, fh)
        assert_true(hr_same(e1, e2))
        // v
        let f1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        let f2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            f1[dstoff + y * dstride + x] = hr_qpel_v(
              src,
              soff + y * sstride + x,
              sstride,
              fh,
            )
          }
        }
        hevc_qpel_v_raw_v128(f2, dstoff, dstride, src, soff, sstride, w, h, fh)
        assert_true(hr_same(f1, f2))
        // hv
        for my in [1, 2, 3] {
          let fv = hr_qpel_filters[my]
          let g1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
          let g2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
          let max_pb : Int32 = 64
          let tmp : FixedArray[Int32] = FixedArray::make(
            max_pb * (max_pb + 8),
            0,
          )
          for j = 0; j < h + 7; j = j + 1 {
            for i = 0; i < w; i = i + 1 {
              tmp[j * max_pb + i] = hr_qpel_h(src, soff + j * sstride + i, fh)
            }
          }
          let tbase = 3 * max_pb
          for j = 0; j < h; j = j + 1 {
            for i = 0; i < w; i = i + 1 {
              g1[dstoff + j * dstride + i] = hr_qpel_v(
                tmp,
                tbase + j * max_pb + i,
                max_pb,
                fv,
              )
            }
          }
          hevc_qpel_hv_raw_v128(
            g2, dstoff, dstride, src, soff, sstride, w, h, fh, fv,
          )
          assert_true(hr_same(g1, g2))
        }
      }
    }
  }
}

///|
test "hevc mc v128: epel h/v/hv raw sums over eighth-pel phases" {
  let sstride : Int32 = 96
  let src_n = sstride * 96
  let dstride : Int32 = 80
  let dst_n = dstride * 96
  let soff = 24 * sstride + 12
  let dstoff = 24 * dstride + 8
  for pixel_max in [255, 1023, 4095] {
    for (w, h) in [(2, 2), (4, 4), (8, 8), (16, 16), (32, 32), (6, 6)] {
      let src = hr_gen(
        0xDEADBEEFU + w.reinterpret_as_uint() + h.reinterpret_as_uint(),
        src_n,
        pixel_max,
      )
      for phase in [1, 2, 3, 4, 5, 6, 7] {
        let fh = hr_epel_filters[phase]
        let e1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        let e2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            e1[dstoff + y * dstride + x] = hr_epel_h(
              src,
              soff + y * sstride + x,
              fh,
            )
          }
        }
        hevc_epel_h_raw_v128(e2, dstoff, dstride, src, soff, sstride, w, h, fh)
        assert_true(hr_same(e1, e2))
        let f1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        let f2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            f1[dstoff + y * dstride + x] = hr_epel_v(
              src,
              soff + y * sstride + x,
              sstride,
              fh,
            )
          }
        }
        hevc_epel_v_raw_v128(f2, dstoff, dstride, src, soff, sstride, w, h, fh)
        assert_true(hr_same(f1, f2))
        // hv
        let g1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        let g2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        let tstride = w
        let tmp : FixedArray[Int32] = FixedArray::make(tstride * (h + 3), 0)
        for j = 0; j < h + 3; j = j + 1 {
          for i = 0; i < w; i = i + 1 {
            let row = soff + (j - 1) * sstride
            tmp[j * tstride + i] = hr_epel_h(src, row + i, fh)
          }
        }
        for j = 0; j < h; j = j + 1 {
          for i = 0; i < w; i = i + 1 {
            g1[dstoff + j * dstride + i] = hr_epel_v(
              tmp,
              tstride + j * tstride + i,
              tstride,
              fh,
            )
          }
        }
        hevc_epel_hv_raw_v128(
          g2, dstoff, dstride, src, soff, sstride, w, h, fh, fh,
        )
        assert_true(hr_same(g1, g2))
      }
    }
  }
}

///|
test "hevc mc v128: uni epilogue matches the scalar phase output" {
  // Build a raw horizontal sum, then compare the `_uni` epilogue against
  // the scalar port's own `(raw >> (bd-8) + off) >> shift` path.
  let sstride : Int32 = 96
  let src_n = sstride * 96
  let dstride : Int32 = 80
  let dst_n = dstride * 96
  ignore(24 * sstride + 12)
  let dstoff = 24 * dstride + 8
  for (bd, pixel_max) in [(8, 255), (10, 1023), (12, 4095)] {
    for (w, h) in [(4, 4), (8, 8), (16, 16), (32, 32), (6, 6)] {
      let src = hr_gen(0xABCDEF01U + w.reinterpret_as_uint(), src_n, pixel_max)
      for mx in [1, 2, 3] {
        let f = hr_qpel_filters[mx]
        // scalar reference through hr_luma_mc_uni (needs the 3-3 padded buf)
        let buf_stride : Int32 = 96
        let buf : FixedArray[Int32] = FixedArray::make(buf_stride * 96, 0)
        // the scalar port reads with a 3/3 offset: emulate by shifting src
        for y = 0; y < 96; y = y + 1 {
          for x = 0; x < 96; x = x + 1 {
            buf[y * buf_stride + x] = src[y * sstride + x]
          }
        }
        let r1 : Array[Int32] = Array::make(dst_n, 0)
        hr_luma_mc_uni(r1, dstride, buf, buf_stride, 8, 24, mx, 0, w, h, bd)
        // SIMD: raw horizontal pass + the `_uni` epilogue.
        //
        // Layout bridge: `hevc_luma_mc_uni` writes the block at (x0,y0) and
        // its internal window base is `3 + 3*buf_stride`, i.e. the sample at
        // (x0,y0) is `buf[(y0+3)*buf_stride + x0+3]`. The raw 8-tap needs
        // its window origin 3 samples up-left of the *block*, which in `buf`
        // coordinates is exactly `buf[y0*buf_stride + x0]`.
        let raw : FixedArray[Int32] = FixedArray::make(dst_n, 0)
        hevc_qpel_h_raw_v128(
          raw,
          dstoff,
          dstride,
          buf,
          3 * buf_stride + 3,
          buf_stride,
          w,
          h,
          f,
        )
        let r2 : Array[Int32] = Array::make(dst_n, 0)
        hevc_qpel_uni_epilogue_v128(
          r2, dstoff, dstride, raw, dstoff, dstride, w, h, bd,
        )
        for i = 0; i < dst_n; i = i + 1 {
          assert_eq(r2[i], r1[i])
        }
      }
    }
  }
}

///|
test "hevc mc v128: extreme samples and impulse rows" {
  let sstride : Int32 = 96
  let src_n = sstride * 96
  let dstride : Int32 = 80
  let dst_n = dstride * 96
  let soff = 24 * sstride + 12
  let dstoff = 24 * dstride + 8
  for pixel_max in [255, 1023] {
    for fill in [0, pixel_max] {
      let flat : FixedArray[Int32] = FixedArray::make(src_n, fill)
      let imp : FixedArray[Int32] = FixedArray::make(src_n, 0)
      imp[40 * sstride + 40] = pixel_max
      for src in [flat, imp] {
        for (w, h) in [(8, 8), (16, 16)] {
          for mx in [1, 2, 3] {
            let f = hr_qpel_filters[mx]
            let e1 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
            let e2 : FixedArray[Int32] = FixedArray::make(dst_n, 0)
            for y = 0; y < h; y = y + 1 {
              for x = 0; x < w; x = x + 1 {
                e1[dstoff + y * dstride + x] = hr_qpel_h(
                  src,
                  soff + y * sstride + x,
                  f,
                )
              }
            }
            hevc_qpel_h_raw_v128(
              e2, dstoff, dstride, src, soff, sstride, w, h, f,
            )
            assert_true(hr_same(e1, e2))
          }
        }
      }
    }
  }
}
