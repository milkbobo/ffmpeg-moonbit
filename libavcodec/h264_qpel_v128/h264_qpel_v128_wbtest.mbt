///|
/// Whitebox tests for the SIMD (`@v128`) H.264 quarter-pel luma kernels
/// (`h264_qpel_v128.mbt`).
///
/// The `qr_*` functions are verbatim transcriptions of the C reference
/// (`libavcodec/h264qpel_template.c`: `put_h264_qpel{4,8}_{h,v,hv}_lowpass`
/// with `op_put`/`op2_put`, and `put_pixels{4,8}_l2_shift5`) — the parent
/// package's `h264_mc_luma` is a nested-closure form of the same
/// arithmetic, but its privates are not visible from a subpackage, so the
/// unfolded C shape is carried here. Both kernels must agree bit-for-bit.

///|
fn qr_clip(x : Int32, bit_depth : Int32) -> Int32 {
  if x < 0 {
    0
  } else if x > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    x
  }
}

///|
/// Verbatim `put_h264_qpel{4,8}h_lowpass`. */
fn qr_h_lowpass(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  soff : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  bit_depth : Int32,
) -> Unit {
  for i = 0; i < h; i = i + 1 {
    let s = soff + i * sstride
    let d = dstoff + i * dstride
    for x = 0; x < w; x = x + 1 {
      let p = s + x
      let sum = (src[p] + src[p + 1]) * 20 -
        (src[p - 1] + src[p + 2]) * 5 +
        (src[p - 2] + src[p + 3])
      dst[d + x] = qr_clip((sum + 16) >> 5, bit_depth)
    }
  }
}

///|
/// Verbatim `put_h264_qpel{4,8}v_lowpass`. */
fn qr_v_lowpass(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  soff : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  bit_depth : Int32,
) -> Unit {
  for x = 0; x < w; x = x + 1 {
    for y = 0; y < h; y = y + 1 {
      let p = soff + x + y * sstride
      let sum = (src[p] + src[p + sstride]) * 20 -
        (src[p - sstride] + src[p + 2 * sstride]) * 5 +
        (src[p - 2 * sstride] + src[p + 3 * sstride])
      dst[dstoff + y * dstride + x] = qr_clip((sum + 16) >> 5, bit_depth)
    }
  }
}

///|
/// Verbatim `put_h264_qpel{4,8}hv_lowpass` (two-stage, unclipped
/// intermediate, `(v + 512) >> 10`). */
fn qr_hv_lowpass(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  soff : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  bit_depth : Int32,
) -> Unit {
  let tstride = w
  let tmp : Array[Int32] = Array::make(tstride * (h + 5), 0)
  for i = 0; i < h + 5; i = i + 1 {
    let s = soff + i * sstride
    for x = 0; x < w; x = x + 1 {
      let p = s + x
      tmp[i * tstride + x] = (src[p] + src[p + 1]) * 20 -
        (src[p - 1] + src[p + 2]) * 5 +
        (src[p - 2] + src[p + 3])
    }
  }
  // C positions `tmp` at row 2 of the scratch before the column loop, so
  // destination row y reads scratch rows (y+2)-2 .. (y+2)+3.
  for x = 0; x < w; x = x + 1 {
    for y = 0; y < h; y = y + 1 {
      let p = (y + 2) * tstride + x
      let sum = (tmp[p] + tmp[p + tstride]) * 20 -
        (tmp[p - tstride] + tmp[p + 2 * tstride]) * 5 +
        (tmp[p - 2 * tstride] + tmp[p + 3 * tstride])
      dst[dstoff + y * dstride + x] = qr_clip((sum + 512) >> 10, bit_depth)
    }
  }
}

///|
/// Verbatim `put_pixels{4,8}_l2_shift5`. */
fn qr_l2_shift5(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src16 : Array[Int32],
  soff16 : Int32,
  s16stride : Int32,
  src8 : Array[Int32],
  soff8 : Int32,
  s8stride : Int32,
  w : Int32,
  h : Int32,
  bit_depth : Int32,
) -> Unit {
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let a = qr_clip(src16[soff16 + y * s16stride + x] >> 5, bit_depth)
      let b = src8[soff8 + y * s8stride + x]
      dst[dstoff + y * dstride + x] = (a + b + 1) >> 1
    }
  }
}

///|
/// Deterministic generator (LCG). */
fn qr_gen(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
fn qr_copy(a : Array[Int32]) -> Array[Int32] {
  let b : Array[Int32] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
test "h264 qpel v128: h/v/hv lowpass over all block sizes and depths" {
  // The 6-tap reads x-2..x+3 and y-2..y+3, so the source needs a 2-sample
  // margin on every side of the block.
  let sstride : Int32 = 32
  let src_n = sstride * 32
  let dstride : Int32 = 24
  let dst_n = dstride * 24
  for bit_depth in [8, 10, 12] {
    let max = (1 << bit_depth) - 1
    for (w, h) in [(4, 4), (8, 8), (16, 16), (2, 2), (6, 6), (12, 4)] {
      let src = qr_gen(
        0x9E3779B9U + w.reinterpret_as_uint() * 37U + h.reinterpret_as_uint(),
        src_n,
        max,
      )
      let soff = 8 * sstride + 8
      let dstoff = 6 * dstride + 4
      // horizontal
      let e1 = qr_gen(0x11111111U, dst_n, max)
      let e2 = qr_copy(e1)
      qr_h_lowpass(e1, dstoff, dstride, src, soff, sstride, w, h, bit_depth)
      h264_qpel_h_lowpass_v128(
        e2,
        dstoff,
        dstride,
        src,
        soff,
        sstride,
        w,
        h,
        bit_depth~,
      )
      let mut i = 0
      while i < dst_n {
        assert_eq(e2[i], e1[i])
        i = i + 1
      }
      // vertical
      let f1 = qr_gen(0x22222222U, dst_n, max)
      let f2 = qr_copy(f1)
      qr_v_lowpass(f1, dstoff, dstride, src, soff, sstride, w, h, bit_depth)
      h264_qpel_v_lowpass_v128(
        f2,
        dstoff,
        dstride,
        src,
        soff,
        sstride,
        w,
        h,
        bit_depth~,
      )
      let mut j = 0
      while j < dst_n {
        assert_eq(f2[j], f1[j])
        j = j + 1
      }
      // hv
      let g1 = qr_gen(0x33333333U, dst_n, max)
      let g2 = qr_copy(g1)
      qr_hv_lowpass(g1, dstoff, dstride, src, soff, sstride, w, h, bit_depth)
      h264_qpel_hv_lowpass_v128(
        g2,
        dstoff,
        dstride,
        src,
        soff,
        sstride,
        w,
        h,
        bit_depth~,
      )
      let mut k = 0
      while k < dst_n {
        assert_eq(g2[k], g1[k])
        k = k + 1
      }
    }
  }
}

///|
test "h264 qpel v128: extreme samples exercise the clip both ways" {
  // All-zero and all-max sources push the 6-tap into both clamp rails for
  // the h/v passes, and into the wider hv range (which is why hv needs its
  // own reference rather than h-then-v).
  let sstride : Int32 = 32
  let src_n = sstride * 32
  let dstride : Int32 = 24
  let dst_n = dstride * 24
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    for fill in [0, max] {
      let src : Array[Int32] = Array::make(src_n, fill)
      let soff = 8 * sstride + 8
      let dstoff = 6 * dstride + 4
      for (w, h) in [(4, 4), (8, 8), (16, 16)] {
        let e1 = Array::make(dst_n, 0)
        let e2 = Array::make(dst_n, 0)
        qr_h_lowpass(e1, dstoff, dstride, src, soff, sstride, w, h, bit_depth)
        h264_qpel_h_lowpass_v128(
          e2,
          dstoff,
          dstride,
          src,
          soff,
          sstride,
          w,
          h,
          bit_depth~,
        )
        let mut i = 0
        while i < dst_n {
          assert_eq(e2[i], e1[i])
          i = i + 1
        }
        let f1 = Array::make(dst_n, 0)
        let f2 = Array::make(dst_n, 0)
        qr_hv_lowpass(f1, dstoff, dstride, src, soff, sstride, w, h, bit_depth)
        h264_qpel_hv_lowpass_v128(
          f2,
          dstoff,
          dstride,
          src,
          soff,
          sstride,
          w,
          h,
          bit_depth~,
        )
        let mut j = 0
        while j < dst_n {
          assert_eq(f2[j], f1[j])
          j = j + 1
        }
      }
    }
  }
}

///|
test "h264 qpel v128: alternating extremes and impulse rows" {
  // A single bright impulse makes the 6-tap's negative taps visible in one
  // direction and not the other; alternation stresses neighbouring lanes.
  let sstride : Int32 = 32
  let src_n = sstride * 32
  let dstride : Int32 = 24
  let dst_n = dstride * 24
  let soff = 8 * sstride + 8
  let dstoff = 6 * dstride + 4
  let k = 16 * sstride + 16
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    // impulse source
    let imp : Array[Int32] = Array::make(src_n, 0)
    imp[k] = max
    // alternating source
    let alt : Array[Int32] = Array::make(src_n, 0)
    for r = 0; r < 32; r = r + 1 {
      for c = 0; c < 32; c = c + 1 {
        alt[r * sstride + c] = if (r + c) % 2 == 0 { 0 } else { max }
      }
    }
    for src in [imp, alt] {
      for (w, h) in [(4, 4), (8, 8), (16, 16)] {
        let e1 = Array::make(dst_n, 0)
        let e2 = Array::make(dst_n, 0)
        qr_hv_lowpass(e1, dstoff, dstride, src, soff, sstride, w, h, bit_depth)
        h264_qpel_hv_lowpass_v128(
          e2,
          dstoff,
          dstride,
          src,
          soff,
          sstride,
          w,
          h,
          bit_depth~,
        )
        let mut i = 0
        while i < dst_n {
          assert_eq(e2[i], e1[i])
          i = i + 1
        }
      }
    }
  }
}

///|
test "h264 qpel v128: l2_shift5 merge matches the scalar reference" {
  let s16stride : Int32 = 24
  let s8stride : Int32 = 24
  let dstride : Int32 = 24
  let n = 24 * 24
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    for (w, h) in [(4, 4), (8, 8), (16, 16), (2, 2), (6, 4)] {
      let src16 = qr_gen(0xABCDEF01U, n, max << 5)
      let src8 = qr_gen(0xFEDCBA98U, n, max)
      let off16 = 6 * s16stride + 4
      let off8 = 6 * s8stride + 4
      let dstoff = 6 * dstride + 4
      let e1 = qr_gen(0x1234567U, n, max)
      let e2 = qr_copy(e1)
      qr_l2_shift5(
        e1,
        dstoff,
        dstride,
        src16,
        off16,
        s16stride,
        src8,
        off8,
        s8stride,
        w,
        h,
        bit_depth,
      )
      h264_qpel_l2_shift5_v128(
        e2,
        dstoff,
        dstride,
        src16,
        off16,
        s16stride,
        src8,
        off8,
        s8stride,
        w,
        h,
        bit_depth~,
      )
      let mut i = 0
      while i < n {
        assert_eq(e2[i], e1[i])
        i = i + 1
      }
    }
  }
}

///|
test "h264 qpel v128: writes stay inside the destination block" {
  // Every kernel must touch only the w x h block it was asked for.
  let sstride : Int32 = 32
  let src_n = sstride * 32
  let dstride : Int32 = 24
  let dst_n = dstride * 24
  let src = qr_gen(0x0BADF00DU, src_n, 255)
  let soff = 8 * sstride + 8
  let dstoff = 6 * dstride + 4
  for (w, h) in [(4, 4), (8, 8), (16, 16)] {
    let base = qr_gen(0xC0FFEE01U, dst_n, 255)
    for which in [0, 1, 2] {
      let d = qr_copy(base)
      if which == 0 {
        h264_qpel_h_lowpass_v128(d, dstoff, dstride, src, soff, sstride, w, h, bit_depth=8)
      } else if which == 1 {
        h264_qpel_v_lowpass_v128(d, dstoff, dstride, src, soff, sstride, w, h, bit_depth=8)
      } else {
        h264_qpel_hv_lowpass_v128(d, dstoff, dstride, src, soff, sstride, w, h, bit_depth=8)
      }
      for r = 0; r < 24; r = r + 1 {
        for c = 0; c < 24; c = c + 1 {
          let idx = r * dstride + c
          let inside = r >= 6 && r < 6 + h && c >= 4 && c < 4 + w
          if !inside {
            assert_eq(d[idx], base[idx])
          }
        }
      }
    }
  }
}
