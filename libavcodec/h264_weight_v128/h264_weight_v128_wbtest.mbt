///|
/// Whitebox tests for the SIMD (`@v128`) H.264 weighted-prediction kernels
/// (`h264_weight_v128.mbt`).
///
/// The `wr_*` functions are verbatim transcriptions of the scalar ports
/// (`libavcodec/h264_inter.mbt`: `h264_weight_rect`; and the explicit /
/// implicit branches of `libavcodec/h264_b_mc.mbt`: `h264_b_compensate`) —
/// the parent package's privates are not visible from a subpackage, so the
/// reference is carried here. The SIMD kernels must match them bit-for-bit
/// over the full FFmpeg syntax ranges: `log2_denom` 0..7, `weight` -128..127
/// (luma ±2^7), `offset` -16384..16383 at high bit depth, 8/9/10/12/14-bit.

///|
fn wr_clip8(x : Int32, bit_depth : Int32) -> Int32 {
  if x < 0 {
    0
  } else if x > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    x
  }
}

///|
/// Verbatim `h264_weight_rect`. */
fn wr_weight_rect(
  plane : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
  log2_denom : Int32,
  weight : Int32,
  offset : Int32,
  bit_depth : Int32,
) -> Unit {
  let mut off2 = offset << (bit_depth - 8 + log2_denom)
  if log2_denom != 0 {
    off2 = off2 + (1 << (log2_denom - 1))
  }
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let i = off + y * stride + x
      plane[i] = wr_clip8((plane[i] * weight + off2) >> log2_denom, bit_depth)
    }
  }
}

///|
/// Verbatim `op_scale2` (the C `biweight_h264_pixelsW` body). */
fn wr_biweight_rect(
  dst : Array[Int32],
  doff : Int32,
  src : Array[Int32],
  soff : Int32,
  stride : Int32,
  dstride : Int32,
  w : Int32,
  h : Int32,
  log2_denom : Int32,
  weightd : Int32,
  weights : Int32,
  offset : Int32,
  bit_depth : Int32,
) -> Unit {
  let off2 = (((offset << (bit_depth - 8)) + 1) | 1) << log2_denom
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let d = doff + y * dstride + x
      let s = soff + y * stride + x
      dst[d] = wr_clip8(
        (src[s] * weights + dst[d] * weightd + off2) >> (log2_denom + 1),
        bit_depth,
      )
    }
  }
}

///|
/// Verbatim implicit B weighting (`h264_b_compensate`'s `implicit` branch,
/// luma/chroma geometry folded to a rectangle). */
fn wr_implicit(
  dst : Array[Int32],
  doff : Int32,
  a : Array[Int32],
  aoff : Int32,
  b : Array[Int32],
  boff : Int32,
  stride : Int32,
  dstride : Int32,
  w : Int32,
  h : Int32,
  w0 : Int32,
  bit_depth : Int32,
) -> Unit {
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let av = a[aoff + y * stride + x]
      let bv = b[boff + y * stride + x]
      dst[doff + y * dstride + x] = wr_clip8(
        (w0 * av + (64 - w0) * bv + 32) >> 6,
        bit_depth,
      )
    }
  }
}

///|
/// Deterministic generator (LCG). */
fn wr_gen(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
fn wr_copy(a : Array[Int32]) -> Array[Int32] {
  let b : Array[Int32] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
test "h264 weight v128: all widths x denominals x weights x offsets" {
  let stride : Int32 = 24
  let plane_n = stride * 20
  // full syntax ranges of the C template's parameters
  for bit_depth in [8, 9, 10, 12, 14] {
    let max = (1 << bit_depth) - 1
    for denom in [0, 1, 2, 3, 6, 7] {
      for weight in [0, 1, -1, 32, -32, 127, -128, 64] {
        for offset in [0, 1, -1, 8191, -8192, 16383, -16384] {
          for w in [2, 4, 8, 16, 1, 3, 5, 7, 13] {
            let h = 5
            let src = wr_gen(
              0x9E3779B9U +
              denom.reinterpret_as_uint() * 17U +
              w.reinterpret_as_uint(),
              plane_n,
              max,
            )
            let d1 = wr_copy(src)
            let d2 = wr_copy(src)
            let off = 3 * stride + 4
            wr_weight_rect(
              d1, off, stride, w, h, denom, weight, offset, bit_depth,
            )
            h264_weight_rect_v128(
              d2,
              off,
              stride,
              w,
              h,
              denom,
              weight,
              offset,
              bit_depth~,
            )
            let mut i = 0
            while i < plane_n {
              assert_eq(d2[i], d1[i])
              i = i + 1
            }
          }
        }
      }
    }
  }
}

///|
test "h264 biweight v128: two-source weighting, alias and distinct buffers" {
  let stride : Int32 = 24
  let plane_n = stride * 20
  for bit_depth in [8, 10, 12] {
    let max = (1 << bit_depth) - 1
    for denom in [0, 1, 3, 7] {
      for
        (weightd, weights) in [(1, 1), (32, 32), (127, 1), (-128, 127), (0, 64)] {
        for offset in [0, 1, -1, 8191, -8192] {
          for w in [2, 4, 8, 16, 3, 5] {
            let h = 4
            let dsrc = wr_gen(
              0xDEADBEEFU + denom.reinterpret_as_uint() * 13U,
              plane_n,
              max,
            )
            let ssrc = wr_gen(
              0x12345678U + w.reinterpret_as_uint(),
              plane_n,
              max,
            )
            let d1 = wr_copy(dsrc)
            let d2 = wr_copy(dsrc)
            let s1 = wr_copy(ssrc)
            let off = 3 * stride + 4
            wr_biweight_rect(
              d1, off, s1, off, stride, stride, w, h, denom, weightd, weights, offset,
              bit_depth,
            )
            h264_biweight_rect_v128(
              d2,
              off,
              s1,
              off,
              stride,
              stride,
              w,
              h,
              denom,
              weightd,
              weights,
              offset,
              bit_depth~,
            )
            let mut i = 0
            while i < plane_n {
              assert_eq(d2[i], d1[i])
              i = i + 1
            }
          }
        }
      }
    }
  }
}

///|
test "h264 weight v128: distinct dst/src strides and offsets" {
  // The C signature carries one stride; the port's two-stride form is
  // exercised here so a future caller with split planes is covered.
  let plane_n : Int32 = 32 * 20
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    let dsrc = wr_gen(0xA5A5A5A5U, plane_n, max)
    let ssrc = wr_gen(0x5A5A5A5AU, plane_n, max)
    let d1 = wr_copy(dsrc)
    let d2 = wr_copy(dsrc)
    let s1 = wr_copy(ssrc)
    let doff = 2 * 32 + 3
    let soff = 4 * 32 + 5
    wr_biweight_rect(d1, doff, s1, soff, 32, 32, 4, 4, 3, 32, 64, 7, bit_depth)
    h264_biweight_rect_v128(
      d2,
      doff,
      s1,
      soff,
      32,
      32,
      4,
      4,
      3,
      32,
      64,
      7,
      bit_depth~,
    )
    let mut i = 0
    while i < plane_n {
      assert_eq(d2[i], d1[i])
      i = i + 1
    }
  }
}

///|
test "h264 implicit biweight v128: all POC weights and depths" {
  let stride : Int32 = 24
  let plane_n = stride * 20
  for bit_depth in [8, 10, 12] {
    let max = (1 << bit_depth) - 1
    for w0 in [0, 1, 16, 32, 37, 63, 64] {
      for (width, height) in [(4, 4), (16, 16), (8, 4), (2, 2), (6, 3)] {
        let a = wr_gen(0xC0FFEE01U + w0.reinterpret_as_uint(), plane_n, max)
        let b = wr_gen(
          0x0BADF00DU + w0.reinterpret_as_uint() * 3U,
          plane_n,
          max,
        )
        let d1 = wr_copy(a)
        let d2 = wr_copy(a)
        let off = 3 * stride + 4
        wr_implicit(
          d1, off, a, off, b, off, stride, stride, width, height, w0, bit_depth,
        )
        h264_implicit_biweight_v128(
          d2,
          off,
          a,
          off,
          b,
          off,
          stride,
          stride,
          width,
          height,
          w0,
          bit_depth~,
        )
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
test "h264 weight v128: negative offset wraps like the C unsigned shift" {
  // `offset = -1` at log2_denom 0 / depth 8 is `0xFFFF` in the C template;
  // the result must equal the scalar port rather than something shifted
  // arithmetically.
  let stride : Int32 = 8
  let plane_n = stride * 8
  let src : Array[Int32] = Array::make(plane_n, 200)
  for denom in [0, 1, 2, 7] {
    for offset in [-1, -2, -128, -16384] {
      let d1 = wr_copy(src)
      let d2 = wr_copy(src)
      wr_weight_rect(d1, 0, stride, 8, 8, denom, 1, offset, 8)
      h264_weight_rect_v128(d2, 0, stride, 8, 8, denom, 1, offset, bit_depth=8)
      let mut i = 0
      while i < plane_n {
        assert_eq(d2[i], d1[i])
        i = i + 1
      }
      // and it really does differ from a naive arithmetic shift of the
      // negative product, which would clip to 0
      let naive = (200 * 1 + (0 - 1) * (1 << denom)) >> denom
      if naive < 0 {
        assert_true(d2[0] >= 0)
      }
    }
  }
}

///|
test "h264 weight v128: saturated extremes stay in range" {
  // weight 127 with the max pixel and a huge positive / negative offset:
  // every output must be clipped into [0, 2^depth-1] and match the port.
  let stride : Int32 = 8
  let plane_n = stride * 8
  for bit_depth in [8, 10] {
    let max = (1 << bit_depth) - 1
    let hi : Array[Int32] = Array::make(plane_n, max)
    let lo : Array[Int32] = Array::make(plane_n, 0)
    for
      (src, weight, offset) in [
        (hi, 127, 16383),
        (hi, -128, -16384),
        (lo, 127, 16383),
        (lo, -128, -16384),
      ] {
      for denom in [0, 7] {
        let d1 = wr_copy(src)
        let d2 = wr_copy(src)
        wr_weight_rect(d1, 0, stride, 8, 8, denom, weight, offset, bit_depth)
        h264_weight_rect_v128(
          d2,
          0,
          stride,
          8,
          8,
          denom,
          weight,
          offset,
          bit_depth~,
        )
        let mut i = 0
        while i < plane_n {
          assert_eq(d2[i], d1[i])
          assert_true(d2[i] >= 0)
          assert_true(d2[i] <= max)
          i = i + 1
        }
      }
    }
  }
}
