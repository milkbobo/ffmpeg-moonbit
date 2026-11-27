///|
/// Whitebox tests for the SIMD (`@v128`) VP9 sub-pixel motion-compensation
/// kernels (`vp9_mc_v128.mbt`).
///
/// The `vr_*` functions are verbatim transcriptions of the scalar port
/// (`libavcodec/vp9_inter_recon.mbt`: `Vp9Decoder::mc_kernel`) — the parent
/// package's methods are not visible from a subpackage, so the reference is
/// carried here. Both must agree bit-for-bit on every phase, filter type,
/// size and bit depth.

///|
/// Verbatim `ff_vp9_subpel_filters[3][16][8]`, flattened exactly like
/// `libavcodec/vp9_inter_tables.mbt` (`[type][phase][tap]`, row stride 128).
let vr_subpel_filters : Array[Int32] = [
  0, 0, 0, 128, 0, 0, 0, 0, 0, 1, -5, 126, 8, -3, 1, 0, -1, 3, -10, 122, 18, -6,
  2, 0, -1, 4, -13, 118, 27, -9, 3, -1, -1, 4, -16, 112, 37, -11, 4, -1, -1, 5, -18,
  105, 48, -14, 4, -1, -1, 5, -19, 97, 58, -16, 5, -1, -1, 6, -19, 88, 68, -18, 5,
  -1, -1, 6, -19, 78, 78, -19, 6, -1, -1, 5, -18, 68, 88, -19, 6, -1, -1, 5, -16,
  58, 97, -19, 5, -1, -1, 4, -14, 48, 105, -18, 5, -1, -1, 4, -11, 37, 112, -16,
  4, -1, -1, 3, -9, 27, 118, -13, 4, -1, 0, 2, -6, 18, 122, -10, 3, -1, 0, 1, -3,
  8, 126, -5, 1, 0, 0, 0, 0, 128, 0, 0, 0, 0, -1, 3, -7, 127, 8, -3, 1, 0, -2, 5,
  -13, 125, 17, -6, 3, -1, -3, 7, -17, 121, 27, -10, 5, -2, -4, 9, -20, 115, 37,
  -13, 6, -2, -4, 10, -23, 108, 48, -16, 8, -3, -4, 10, -24, 100, 59, -19, 9, -3,
  -4, 11, -24, 90, 70, -21, 10, -4, -4, 11, -23, 80, 80, -23, 11, -4, -4, 10, -21,
  70, 90, -24, 11, -4, -3, 9, -19, 59, 100, -24, 10, -4, -3, 8, -16, 48, 108, -23,
  10, -4, -2, 6, -13, 37, 115, -20, 9, -4, -2, 5, -10, 27, 121, -17, 7, -3, -1, 3,
  -6, 17, 125, -13, 5, -2, 0, 1, -3, 8, 127, -7, 3, -1, 0, 0, 0, 128, 0, 0, 0, 0,
  -3, -1, 32, 64, 38, 1, -3, 0, -2, -2, 29, 63, 41, 2, -3, 0, -2, -2, 26, 63, 43,
  4, -4, 0, -2, -3, 24, 62, 46, 5, -4, 0, -2, -3, 21, 60, 49, 7, -4, 0, -1, -4, 18,
  59, 51, 9, -4, 0, -1, -4, 16, 57, 53, 12, -4, -1, -1, -4, 14, 55, 55, 14, -4, -1,
  -1, -4, 12, 53, 57, 16, -4, -1, 0, -4, 9, 51, 59, 18, -4, -1, 0, -4, 7, 49, 60,
  21, -3, -2, 0, -4, 5, 46, 62, 24, -3, -2, 0, -4, 4, 43, 63, 26, -2, -2, 0, -3,
  2, 41, 63, 29, -2, -2, 0, -3, 1, 38, 64, 32, -1, -3,
]

///|
/// Filter-mode → table row, as `vp9_filter_to_table`. */
fn vr_filter_to_table(mode : Int32) -> Int32 {
  match mode {
    1 => 2
    2 => 1
    _ => 0
  }
}

///|
fn vr_clip_pixel(v : Int32, max : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > max {
    max
  } else {
    v
  }
}

///|
/// Verbatim `mc_kernel`. */
fn vr_mc_kernel(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  fx : Int32,
  fy : Int32,
  filter : Int32,
  avg : Bool,
  pixel_max : Int32,
) -> Unit {
  if fx == 0 && fy == 0 {
    let mut so = src_off
    let mut do_ = dst_off
    for _ in 0..<h {
      if avg {
        for x in 0..<w {
          dst[do_ + x] = (dst[do_ + x] + src[so + x] + 1) / 2
        }
      } else {
        for x in 0..<w {
          dst[do_ + x] = src[so + x]
        }
      }
      so += src_stride
      do_ += dst_stride
    }
    return
  }
  if filter == 3 {
    if fy == 0 {
      let mut so = src_off
      let mut do_ = dst_off
      for _ in 0..<h {
        for x in 0..<w {
          let v = vr_clip_pixel(
            src[so + x] + ((fx * (src[so + x + 1] - src[so + x]) + 8) >> 4),
            pixel_max,
          )
          dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) / 2 } else { v }
        }
        so += src_stride
        do_ += dst_stride
      }
    } else if fx == 0 {
      let mut so = src_off
      let mut do_ = dst_off
      for _ in 0..<h {
        for x in 0..<w {
          let v = vr_clip_pixel(
            src[so + x] +
            ((fy * (src[so + x + src_stride] - src[so + x]) + 8) >> 4),
            pixel_max,
          )
          dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) / 2 } else { v }
        }
        so += src_stride
        do_ += dst_stride
      }
    } else {
      let tmp : FixedArray[Int32] = FixedArray::make(64 * (h + 1), 0)
      let mut so = src_off
      let mut to = 0
      for _ in 0..<(h + 1) {
        for x in 0..<w {
          tmp[to + x] = vr_clip_pixel(
            src[so + x] + ((fx * (src[so + x + 1] - src[so + x]) + 8) >> 4),
            pixel_max,
          )
        }
        to += 64
        so += src_stride
      }
      let mut do_ = dst_off
      to = 0
      for _ in 0..<h {
        for x in 0..<w {
          let v = vr_clip_pixel(
            tmp[to + x] + ((fy * (tmp[to + x + 64] - tmp[to + x]) + 8) >> 4),
            pixel_max,
          )
          dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) / 2 } else { v }
        }
        to += 64
        do_ += dst_stride
      }
    }
    return
  }
  let ftab = vr_filter_to_table(filter)
  let filters = vr_subpel_filters
  if fy == 0 {
    let fb = ftab * 128 + fx * 8
    let mut so = src_off
    let mut do_ = dst_off
    for _ in 0..<h {
      for x in 0..<w {
        let v = vr_clip_pixel(
          (
            filters[fb] * src[so + x - 3] +
            filters[fb + 1] * src[so + x - 2] +
            filters[fb + 2] * src[so + x - 1] +
            filters[fb + 3] * src[so + x] +
            filters[fb + 4] * src[so + x + 1] +
            filters[fb + 5] * src[so + x + 2] +
            filters[fb + 6] * src[so + x + 3] +
            filters[fb + 7] * src[so + x + 4] +
            64
          ) >>
          7,
          pixel_max,
        )
        dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) / 2 } else { v }
      }
      so += src_stride
      do_ += dst_stride
    }
  } else if fx == 0 {
    let fb = ftab * 128 + fy * 8
    let mut so = src_off
    let mut do_ = dst_off
    for _ in 0..<h {
      for x in 0..<w {
        let v = vr_clip_pixel(
          (
            filters[fb] * src[so + x - 3 * src_stride] +
            filters[fb + 1] * src[so + x - 2 * src_stride] +
            filters[fb + 2] * src[so + x - src_stride] +
            filters[fb + 3] * src[so + x] +
            filters[fb + 4] * src[so + x + src_stride] +
            filters[fb + 5] * src[so + x + 2 * src_stride] +
            filters[fb + 6] * src[so + x + 3 * src_stride] +
            filters[fb + 7] * src[so + x + 4 * src_stride] +
            64
          ) >>
          7,
          pixel_max,
        )
        dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) / 2 } else { v }
      }
      so += src_stride
      do_ += dst_stride
    }
  } else {
    let tmp : FixedArray[Int32] = FixedArray::make(64 * (h + 7), 0)
    let fb = ftab * 128 + fx * 8
    let mut so = src_off - 3 * src_stride
    let mut to = 0
    for _ in 0..<(h + 7) {
      for x in 0..<w {
        tmp[to + x] = vr_clip_pixel(
          (
            filters[fb] * src[so + x - 3] +
            filters[fb + 1] * src[so + x - 2] +
            filters[fb + 2] * src[so + x - 1] +
            filters[fb + 3] * src[so + x] +
            filters[fb + 4] * src[so + x + 1] +
            filters[fb + 5] * src[so + x + 2] +
            filters[fb + 6] * src[so + x + 3] +
            filters[fb + 7] * src[so + x + 4] +
            64
          ) >>
          7,
          pixel_max,
        )
      }
      to += 64
      so += src_stride
    }
    let fb2 = ftab * 128 + fy * 8
    let mut do_ = dst_off
    to = 3 * 64
    for _ in 0..<h {
      for x in 0..<w {
        let v = vr_clip_pixel(
          (
            filters[fb2] * tmp[to + x - 3 * 64] +
            filters[fb2 + 1] * tmp[to + x - 2 * 64] +
            filters[fb2 + 2] * tmp[to + x - 64] +
            filters[fb2 + 3] * tmp[to + x] +
            filters[fb2 + 4] * tmp[to + x + 64] +
            filters[fb2 + 5] * tmp[to + x + 2 * 64] +
            filters[fb2 + 6] * tmp[to + x + 3 * 64] +
            filters[fb2 + 7] * tmp[to + x + 4 * 64] +
            64
          ) >>
          7,
          pixel_max,
        )
        dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) / 2 } else { v }
      }
      to += 64
      do_ += dst_stride
    }
  }
}

///|
/// The eight coefficient taps of `(type, phase)`. */
fn vr_coeffs(mode : Int32, phase : Int32) -> Array[Int32] {
  let fb = vr_filter_to_table(mode) * 128 + phase * 8
  [
    vr_subpel_filters[fb],
    vr_subpel_filters[fb + 1],
    vr_subpel_filters[fb + 2],
    vr_subpel_filters[fb + 3],
    vr_subpel_filters[fb + 4],
    vr_subpel_filters[fb + 5],
    vr_subpel_filters[fb + 6],
    vr_subpel_filters[fb + 7],
  ]
}

///|
/// Deterministic plane generator (LCG). */
fn vr_gen(seed : UInt32, n : Int32, max : Int32) -> FixedArray[Int32] {
  let a : FixedArray[Int32] = FixedArray::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
fn vr_copy(a : FixedArray[Int32]) -> FixedArray[Int32] {
  let b : FixedArray[Int32] = FixedArray::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn vr_same(a : FixedArray[Int32], b : FixedArray[Int32]) -> Bool {
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
test "vp9 mc v128: 8-tap h/v/hv over all phases, filters, sizes, depths" {
  let sstride : Int32 = 96
  let src_n = sstride * 96
  let dstride : Int32 = 80
  let dst_n = dstride * 96
  // source plane is padded by 4 samples on each side for the 8-tap reach
  let soff = 24 * sstride + 12
  let dstoff = 24 * dstride + 8
  for pixel_max in [255, 1023, 4095] {
    for filter in [0, 1, 2] {
      for
        (fx, fy) in [
          (0, 0),
          (1, 0),
          (4, 0),
          (15, 0),
          (0, 1),
          (0, 4),
          (0, 15),
          (4, 4),
          (7, 9),
          (15, 15),
          (1, 15),
          (15, 1),
        ] {
        for
          (w, h) in [
            (4, 4),
            (8, 8),
            (16, 16),
            (32, 32),
            (2, 2),
            (6, 6),
            (64, 4),
          ] {
          if w > 64 {
            continue
          }
          let src = vr_gen(
            0x9E3779B9U +
            w.reinterpret_as_uint() * 31U +
            h.reinterpret_as_uint() +
            (fx * 16 + fy).reinterpret_as_uint(),
            src_n,
            pixel_max,
          )
          // base destination (for avg paths) must match on both sides
          let base = vr_gen(
            0x5A5A5A5AU + w.reinterpret_as_uint(),
            dst_n,
            pixel_max,
          )
          for avg in [false, true] {
            // ---- 1D horizontal ----
            if fy == 0 && fx != 0 {
              let e1 = vr_copy(base)
              let e2 = vr_copy(base)
              vr_mc_kernel(
                e1, dstoff, dstride, src, soff, sstride, w, h, fx, fy, filter, avg,
                pixel_max,
              )
              vp9_8tap_1d_h_v128(
                e2,
                dstoff,
                dstride,
                src,
                soff,
                sstride,
                w,
                h,
                vr_coeffs(filter, fx),
                pixel_max,
                avg~,
              )
              assert_true(vr_same(e1, e2))
            }
            // ---- 1D vertical ----
            if fx == 0 && fy != 0 && filter != 3 {
              let e1 = vr_copy(base)
              let e2 = vr_copy(base)
              vr_mc_kernel(
                e1, dstoff, dstride, src, soff, sstride, w, h, fx, fy, filter, avg,
                pixel_max,
              )
              vp9_8tap_1d_v_v128(
                e2,
                dstoff,
                dstride,
                src,
                soff,
                sstride,
                w,
                h,
                vr_coeffs(filter, fy),
                pixel_max,
                avg~,
              )
              assert_true(vr_same(e1, e2))
            }
            // ---- 2D ----
            if fx != 0 && fy != 0 && filter != 3 {
              let e1 = vr_copy(base)
              let e2 = vr_copy(base)
              vr_mc_kernel(
                e1, dstoff, dstride, src, soff, sstride, w, h, fx, fy, filter, avg,
                pixel_max,
              )
              let tmp : FixedArray[Int32] = FixedArray::make(64 * (h + 7), 0)
              vp9_8tap_1d_hv_v128(
                e2,
                dstoff,
                dstride,
                src,
                soff,
                sstride,
                tmp,
                64,
                w,
                h,
                vr_coeffs(filter, fx),
                vr_coeffs(filter, fy),
                pixel_max,
                avg~,
              )
              assert_true(vr_same(e1, e2))
            }
          }
        }
      }
    }
  }
}

///|
test "vp9 mc v128: bilinear family all phases and sizes" {
  let sstride : Int32 = 96
  let src_n = sstride * 80
  let dstride : Int32 = 80
  let dst_n = dstride * 80
  let soff = 16 * sstride + 12
  let dstoff = 16 * dstride + 8
  for pixel_max in [255, 1023, 4095] {
    for
      (fx, fy) in [
        (1, 0),
        (7, 0),
        (15, 0),
        (0, 1),
        (0, 7),
        (0, 15),
        (1, 1),
        (7, 9),
        (15, 15),
      ] {
      for (w, h) in [(4, 4), (8, 8), (16, 16), (32, 32), (6, 6), (2, 2)] {
        let src = vr_gen(
          0xDEADBEEFU +
          w.reinterpret_as_uint() +
          (fx * 16 + fy).reinterpret_as_uint(),
          src_n,
          pixel_max,
        )
        let base = vr_gen(
          0xC0FFEE01U + w.reinterpret_as_uint(),
          dst_n,
          pixel_max,
        )
        for avg in [false, true] {
          let e1 = vr_copy(base)
          let e2 = vr_copy(base)
          vr_mc_kernel(
            e1, dstoff, dstride, src, soff, sstride, w, h, fx, fy, 3, avg, pixel_max,
          )
          vp9_bilinear_v128(
            e2,
            dstoff,
            dstride,
            src,
            soff,
            sstride,
            w,
            h,
            fx,
            fy,
            pixel_max,
            avg~,
          )
          assert_true(vr_same(e1, e2))
        }
      }
    }
  }
}

///|
test "vp9 mc v128: whole-pixel copy and avg" {
  let sstride : Int32 = 96
  let src_n = sstride * 80
  let dstride : Int32 = 80
  let dst_n = dstride * 80
  let soff = 16 * sstride + 12
  let dstoff = 16 * dstride + 8
  for pixel_max in [255, 1023] {
    for (w, h) in [(4, 4), (8, 8), (16, 16), (32, 32), (64, 8), (6, 6)] {
      let src = vr_gen(0xABCDEF01U + w.reinterpret_as_uint(), src_n, pixel_max)
      let base = vr_gen(0x13572468U + w.reinterpret_as_uint(), dst_n, pixel_max)
      for avg in [false, true] {
        let e1 = vr_copy(base)
        let e2 = vr_copy(base)
        vr_mc_kernel(
          e1, dstoff, dstride, src, soff, sstride, w, h, 0, 0, 0, avg, pixel_max,
        )
        vp9_fpel_copy_v128(e2, dstoff, dstride, src, soff, sstride, w, h, avg~)
        assert_true(vr_same(e1, e2))
      }
    }
  }
}

///|
test "vp9 mc v128: extreme pixel values stay clipped" {
  // All-zero and all-max sources drive the negative filter taps into both
  // clamp rails; the outputs must match the scalar reference exactly.
  let sstride : Int32 = 96
  let src_n = sstride * 80
  let dstride : Int32 = 80
  let dst_n = dstride * 80
  let soff = 16 * sstride + 12
  let dstoff = 16 * dstride + 8
  for pixel_max in [255, 1023] {
    for fill in [0, pixel_max] {
      let src : FixedArray[Int32] = FixedArray::make(src_n, fill)
      let base : FixedArray[Int32] = FixedArray::make(dst_n, fill / 2)
      for filter in [0, 1, 2] {
        for (fx, fy) in [(4, 0), (0, 4), (4, 4), (15, 15)] {
          let e1 = vr_copy(base)
          let e2 = vr_copy(base)
          vr_mc_kernel(
            e1, dstoff, dstride, src, soff, sstride, 8, 8, fx, fy, filter, false,
            pixel_max,
          )
          if fy == 0 {
            vp9_8tap_1d_h_v128(
              e2,
              dstoff,
              dstride,
              src,
              soff,
              sstride,
              8,
              8,
              vr_coeffs(filter, fx),
              pixel_max,
            )
          } else if fx == 0 {
            vp9_8tap_1d_v_v128(
              e2,
              dstoff,
              dstride,
              src,
              soff,
              sstride,
              8,
              8,
              vr_coeffs(filter, fy),
              pixel_max,
            )
          } else {
            let tmp : FixedArray[Int32] = FixedArray::make(64 * 15, 0)
            vp9_8tap_1d_hv_v128(
              e2,
              dstoff,
              dstride,
              src,
              soff,
              sstride,
              tmp,
              64,
              8,
              8,
              vr_coeffs(filter, fx),
              vr_coeffs(filter, fy),
              pixel_max,
            )
          }
          assert_true(vr_same(e1, e2))
        }
      }
    }
  }
}
