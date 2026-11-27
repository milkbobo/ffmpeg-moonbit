///|
/// SIMD (`@v128`) versions of the H.264 intra prediction kernels for the
/// 16x16 luma and 8x8 chroma block sizes
/// (`libavcodec/h264pred_template.c`: `pred16x16_*` / `pred8x8_*`; the
/// scalar ports are `h264_pred16x16` and `h264_pred8x8` in
/// `libavcodec/h264_pred.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/h264_intrapred.asm`: `pred16x16_vertical_8`,
/// `pred16x16_horizontal_8`, `pred16x16_dc_8`, `pred16x16_plane_*_8`,
/// `pred8x8_vertical_8`, `pred8x8_horizontal_8`, `pred8x8_top_dc_8`,
/// `pred8x8_dc_8`, `pred8x8_left_dc_8`, `pred8x8_plane_8`).
///
/// The asm's structure is faithfully kept, with the row-replication loads
/// (`movq`/`mova` of the top row broadcast into 16 registers) becoming
/// `i32x4` broadcasts and the plane-mode ramp
///
///   out[j][i] = clip_pixel((b + i*h) >> 5),  b += v after each row
///
/// becoming a four-lane `i32x4` add-of-constant-steps plus a
/// `min_s`/`max_s` clip. DC modes sum the edges with the scalar port's own
/// accumulation order and splat the result (the asm's `psadbw` horizontal
/// sums are an implementation detail of getting the same integer).
///
/// Deviations (documented):
///   - the asm has fixed 16x16 / 8x8 entry points; here one kernel each
///     takes the block size through separate `_v128` functions per size,
///     matching the two scalar ports;
///   - the plane-mode predictor coefficients (`h`, `v`, `a`) are computed
///     with the scalar port's integer arithmetic, not the asm's fixed-point
///     `pmulhw` path, so the recomputed ramp cannot drift by a rounding
///     step (the asm itself notes the two differ in the spec corner cases).
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `h264_pred_v128_wbtest.mbt`.

///|
/// Mode codes, mirroring `libavcodec/h264_pred.mbt`'s `h264_pred8_*`. */
#cfg(any(target="native", target="wasm"))
let h264pv_dc : Int32 = 0

///|
#cfg(any(target="native", target="wasm"))
let h264pv_hor : Int32 = 1

///|
#cfg(any(target="native", target="wasm"))
let h264pv_vert : Int32 = 2

///|
#cfg(any(target="native", target="wasm"))
let h264pv_plane : Int32 = 3

///|
#cfg(any(target="native", target="wasm"))
let h264pv_left_dc : Int32 = 4

///|
#cfg(any(target="native", target="wasm"))
let h264pv_top_dc : Int32 = 5

///|
#cfg(any(target="native", target="wasm"))
let h264pv_128_dc : Int32 = 6

///|
/// `av_clip_pixel` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn h264pv_clip_lanes(v : V128, bit_depth : Int32) -> V128 {
  @simd.i32x4_min_s(
    @simd.i32x4_max_s(v, @simd.i32x4_splat(0)),
    @simd.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint()),
  )
}

///|
/// Broadcast the four samples `src[at..at+4)` into an `i32x4`. */
#cfg(any(target="native", target="wasm"))
fn h264pv_load4(src : Array[Int32], at : Int32) -> V128 {
  let mut v = @simd.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @simd.i32x4_replace_lane(v, src[at + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Store four lanes of `v` to `dst[at..at+4)`. */
#cfg(any(target="native", target="wasm"))
fn h264pv_store4(dst : Array[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    dst[at + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// Write `n` rows of a constant row vector (`n` = 8 or 16). */
/// `pred16x16_*`: 16x16 luma prediction with the rows filled by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn h264_pred16x16_v128(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
  bit_depth~ : Int32 = 8,
) -> Result[Unit, String] {
  if mode == h264pv_vert {
    if !top {
      return Err("16x16 vertical prediction without top samples")
    }
    // stage the 16 top samples so the row copies never read a row that the
    // first writes already overwrote (rows 1..15 read row 0's original)
    let trow : Array[Int32] = Array::make(16, 0)
    for i = 0; i < 16; i = i + 1 {
      trow[i] = dst[off - stride + i]
    }
    for j = 0; j < 16; j = j + 1 {
      let p = off + j * stride
      for g = 0; g < 4; g = g + 1 {
        h264pv_store4(dst, p + 4 * g, h264pv_load4(trow, 4 * g))
      }
    }
  } else if mode == h264pv_hor {
    if !left {
      return Err("16x16 horizontal prediction without left samples")
    }
    for j = 0; j < 16; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      let rowv = @simd.i32x4_splat(v.reinterpret_as_uint())
      let p = off + j * stride
      let mut i = 0
      while i + 4 <= 16 {
        h264pv_store4(dst, p + i, rowv)
        i = i + 4
      }
    }
  } else if mode == h264pv_dc ||
    mode == h264pv_left_dc ||
    mode == h264pv_top_dc ||
    mode == h264pv_128_dc {
    let mut dc = 1 << (bit_depth - 1)
    if mode == h264pv_dc {
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
    } else if mode == h264pv_left_dc {
      if !left {
        return Err("16x16 left DC without left samples")
      }
      let mut sum = 0
      for i = 0; i < 16; i = i + 1 {
        sum = sum + dst[off - 1 + i * stride]
      }
      dc = (sum + 8) >> 4
    } else if mode == h264pv_top_dc {
      if !top {
        return Err("16x16 top DC without top samples")
      }
      let mut sum = 0
      for i = 0; i < 16; i = i + 1 {
        sum = sum + dst[off - stride + i]
      }
      dc = (sum + 8) >> 4
    }
    let rowv = @simd.i32x4_splat(dc.reinterpret_as_uint())
    for j = 0; j < 16; j = j + 1 {
      let p = off + j * stride
      let mut i = 0
      while i + 4 <= 16 {
        h264pv_store4(dst, p + i, rowv)
        i = i + 4
      }
    }
  } else if mode == h264pv_plane {
    if !top || !left {
      return Err("16x16 plane prediction without both edges")
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
    // per row: lanes hold b, b+h, b+2h, b+3h then advance b by 4h (the
    // scalar port's `i4` unrolling advances the running b, so the lane
    // offsets are always 0..3 — advancing b *and* shifting the offsets
    // would count the 4h step twice)
    let hv = @simd.i32x4_splat(h.reinterpret_as_uint())
    let steps = @simd.i32x4_const(0, 1, 2, 3)
    let four_h = 4 * h
    for j = 0; j < 16; j = j + 1 {
      let p = off + j * stride
      let mut b = a
      a = a + v
      for quad = 0; quad < 4; quad = quad + 1 {
        let bq = @simd.i32x4_splat(b.reinterpret_as_uint())
        let vals = @simd.i32x4_add(bq, @simd.i32x4_mul(hv, steps))
        h264pv_store4(
          dst,
          p + 4 * quad,
          h264pv_clip_lanes(@simd.i32x4_shr_s(vals, 5), bit_depth),
        )
        b = b + four_h
      }
    }
  } else {
    return Err("unsupported 16x16 prediction mode")
  }
  Ok(())
}

///|
/// `pred8x8_*`: 8x8 prediction (chroma for 4:2:0).
#cfg(any(target="native", target="wasm"))
pub fn h264_pred8x8_v128(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
  bit_depth~ : Int32 = 8,
) -> Result[Unit, String] {
  if mode == h264pv_vert {
    if !top {
      return Err("8x8 vertical prediction without top samples")
    }
    let trow : Array[Int32] = Array::make(8, 0)
    for i = 0; i < 8; i = i + 1 {
      trow[i] = dst[off - stride + i]
    }
    for j = 0; j < 8; j = j + 1 {
      let p = off + j * stride
      h264pv_store4(dst, p, h264pv_load4(trow, 0))
      h264pv_store4(dst, p + 4, h264pv_load4(trow, 4))
    }
  } else if mode == h264pv_hor {
    if !left {
      return Err("8x8 horizontal prediction without left samples")
    }
    for j = 0; j < 8; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      let rowv = @simd.i32x4_splat(v.reinterpret_as_uint())
      let p = off + j * stride
      h264pv_store4(dst, p, rowv)
      h264pv_store4(dst, p + 4, rowv)
    }
  } else if mode == h264pv_dc {
    if !top || !left {
      return Err("8x8 DC prediction without both edges")
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
      let p = off + j * stride
      h264pv_store4(dst, p, @simd.i32x4_splat(lv.reinterpret_as_uint()))
      h264pv_store4(dst, p + 4, @simd.i32x4_splat(rv.reinterpret_as_uint()))
    }
  } else if mode == h264pv_left_dc {
    if !left {
      return Err("8x8 left DC without left samples")
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
      let rowv = @simd.i32x4_splat(v.reinterpret_as_uint())
      let p = off + j * stride
      h264pv_store4(dst, p, rowv)
      h264pv_store4(dst, p + 4, rowv)
    }
  } else if mode == h264pv_top_dc {
    if !top {
      return Err("8x8 top DC without top samples")
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
      let p = off + j * stride
      h264pv_store4(dst, p, @simd.i32x4_splat(v0.reinterpret_as_uint()))
      h264pv_store4(dst, p + 4, @simd.i32x4_splat(v1.reinterpret_as_uint()))
    }
  } else if mode == h264pv_128_dc {
    let rowv = @simd.i32x4_splat((1 << (bit_depth - 1)).reinterpret_as_uint())
    for j = 0; j < 8; j = j + 1 {
      let p = off + j * stride
      h264pv_store4(dst, p, rowv)
      h264pv_store4(dst, p + 4, rowv)
    }
  } else if mode == h264pv_plane {
    if !top || !left {
      return Err("8x8 plane prediction without both edges")
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
    let hv = @simd.i32x4_splat(h.reinterpret_as_uint())
    let steps = @simd.i32x4_const(0, 1, 2, 3)
    for j = 0; j < 8; j = j + 1 {
      let p = off + j * stride
      let b = a
      a = a + v
      let bq = @simd.i32x4_splat(b.reinterpret_as_uint())
      let lo = h264pv_clip_lanes(
        @simd.i32x4_shr_s(@simd.i32x4_add(bq, @simd.i32x4_mul(hv, steps)), 5),
        bit_depth,
      )
      let hi = h264pv_clip_lanes(
        @simd.i32x4_shr_s(
          @simd.i32x4_add(
            bq,
            @simd.i32x4_mul(hv, @simd.i32x4_add(steps, @simd.i32x4_splat(4))),
          ),
          5,
        ),
        bit_depth,
      )
      h264pv_store4(dst, p, lo)
      h264pv_store4(dst, p + 4, hi)
    }
  } else {
    return Err("unsupported 8x8 prediction mode")
  }
  Ok(())
}
