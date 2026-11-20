///|
/// SIMD (`@v128`) versions of the VP9 sub-pixel motion-compensation kernels
/// (`libavcodec/vp9dsp_template.c` via `vp9_mc.c`: `put_8tap_1d_h/v` with
/// `(Σ F·src + 64) >> 7`, the bilinear family `(a·d + 8) >> 4`, and the
/// whole-pixel copy/avg; the scalar port is `Vp9Decoder::mc_kernel` in
/// `libavcodec/vp9_inter_recon.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/vp9mc.asm`: `FILTER`/`F8_SSE2_TAPS` coefficient banks,
/// `filter_h_fn`, `filter_v_fn`, `filter_hx2_fn`, `filter_vx2_fn`,
/// `fpel_fn`). The asm broadcasts one 8-tap bank into eight `i16` registers
/// and runs `pmaddwd`-style lane products; here the taps are `i32x4`
/// multiplies accumulated over the tap dimension, which keeps the same
/// `+64 >> 7` rounding and needs no `packssdw` overflow reasoning (the
/// widest intermediate is `128·255 + 64` per tap-sum ≈ 33k, well inside
/// `Int32`, and the `pmaddwd` pair-summing the asm does is a scheduling
/// detail, not an arithmetic one).
///
/// Structure kept from the asm/C:
///   - `h` pass: lane = output pixel, taps read `src[x-3 .. x+4]`;
///   - `v` pass: lane = output column, taps gathered down `sstride`
///     (the asm's `filter_v_fn` keeps eight column vectors live for the
///     same reason — one per tap row);
///   - `hv` pass: horizontal into a clipped intermediate, then vertical,
///     matching `mc_kernel`'s two-stage `mc_tmp` (with the port's 64-column
///     `mc_tmp` stride);
///   - `avg`: `(dst + v + 1) / 2` on non-negative operands, the C's
///     `(dst[x] + v + 1) / 2` (note: division, not the asm's `pavgb`, but
///     the two agree for non-negative `dst + v + 1`, which is guaranteed
///     here).
///
/// Deviations (documented): the asm has per-size entry points (4/8/16/32/64
/// through `mc_rep`) and separate `_smooth`/`_regular`/`_sharp` const banks;
/// here one kernel takes `w`/`h` and the filter bank index, so the size
/// tiling of `mc_rep` happens at the call site instead of in the kernel.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernel. Equal
/// outputs are asserted in `vp9_mc_v128_wbtest.mbt`.

///|
/// `av_clip_pixel` lane-wise for the VP9 `pixel_max`. */
#cfg(any(target="native", target="wasm"))
fn vmc_clip(v : V128, pixel_max : Int32) -> V128 {
  @v128.i32x4_min_s(
    @v128.i32x4_max_s(v, @v128.i32x4_splat(0)),
    @v128.i32x4_splat(pixel_max.reinterpret_as_uint()),
  )
}

///|
/// Load four consecutive samples of a `FixedArray[Int32]` plane. */
#cfg(any(target="native", target="wasm"))
fn vmc_load4(p : FixedArray[Int32], at : Int32) -> V128 {
  let mut v = @v128.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @v128.i32x4_replace_lane(v, p[at + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Store four `i32x4` lanes into a `FixedArray[Int32]` plane. */
#cfg(any(target="native", target="wasm"))
fn vmc_store4(p : FixedArray[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    p[at + i] = @v128.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// Merge a filtered value into `dst` per the `avg` flag. */
#cfg(any(target="native", target="wasm"))
fn vmc_merge(cur : V128, v : V128, avg : Bool) -> V128 {
  if avg {
    @v128.i32x4_shr_s(
      @v128.i32x4_add(@v128.i32x4_add(cur, v), @v128.i32x4_splat(1)),
      1,
    )
  } else {
    v
  }
}

///|
/// One 8-tap dot product over four lane-vectors, `+64 >> 7`, clipped.
/// `taps` holds the eight coefficient vectors in tap order. */
#cfg(any(target="native", target="wasm"))
fn vmc_dot8(taps : Array[V128], coeffs : Array[Int32]) -> V128 {
  let mut acc = @v128.i32x4_splat(0)
  for i = 0; i < 8; i = i + 1 {
    acc = @v128.i32x4_add(
      acc,
      @v128.i32x4_mul(taps[i], @v128.i32x4_splat(coeffs[i].reinterpret_as_uint())),
    )
  }
  @v128.i32x4_shr_s(
    @v128.i32x4_add(acc, @v128.i32x4_splat(64)),
    7,
  )
}

///|
/// `put_8tap_1d_h`: horizontal 8-tap (`(Σ F·src + 64) >> 7`), optional avg.
///
/// `coeffs` is the eight-tap bank for the phase (`vp9_subpel_filters`
/// row); the caller resolves the table row.
#cfg(any(target="native", target="wasm"))
pub fn vp9_8tap_1d_h_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  coeffs : Array[Int32],
  pixel_max : Int32,
  avg~ : Bool = false,
) -> Unit {
  for y = 0; y < h; y = y + 1 {
    let srow = src_off + y * src_stride
    let drow = dst_off + y * dst_stride
    let mut x = 0
    while x + 4 <= w {
      let taps : Array[V128] = [
        vmc_load4(src, srow + x - 3),
        vmc_load4(src, srow + x - 2),
        vmc_load4(src, srow + x - 1),
        vmc_load4(src, srow + x),
        vmc_load4(src, srow + x + 1),
        vmc_load4(src, srow + x + 2),
        vmc_load4(src, srow + x + 3),
        vmc_load4(src, srow + x + 4),
      ]
      let v = vmc_clip(vmc_dot8(taps, coeffs), pixel_max)
      let merged = if avg {
        vmc_merge(vmc_load4(dst, drow + x), v, true)
      } else {
        v
      }
      vmc_store4(dst, drow + x, merged)
      x = x + 4
    }
    while x < w {
      let p = srow + x
      let mut sum = 0
      for t = 0; t < 8; t = t + 1 {
        sum = sum + coeffs[t] * src[p - 3 + t]
      }
      let fv = (sum + 64) >> 7
      let v = if fv < 0 {
        0
      } else if fv > pixel_max {
        pixel_max
      } else {
        fv
      }
      let d = drow + x
      dst[d] = if avg { (dst[d] + v + 1) / 2 } else { v }
      x = x + 1
    }
  }
}

///|
/// `put_8tap_1d_v`: vertical 8-tap, optional avg.
#cfg(any(target="native", target="wasm"))
pub fn vp9_8tap_1d_v_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  coeffs : Array[Int32],
  pixel_max : Int32,
  avg~ : Bool = false,
) -> Unit {
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let r = src_off + x + y * src_stride
      let taps : Array[V128] = [
        vmc_load4(src, r - 3 * src_stride),
        vmc_load4(src, r - 2 * src_stride),
        vmc_load4(src, r - src_stride),
        vmc_load4(src, r),
        vmc_load4(src, r + src_stride),
        vmc_load4(src, r + 2 * src_stride),
        vmc_load4(src, r + 3 * src_stride),
        vmc_load4(src, r + 4 * src_stride),
      ]
      let v = vmc_clip(vmc_dot8(taps, coeffs), pixel_max)
      let d = dst_off + y * dst_stride + x
      let merged = if avg {
        vmc_merge(vmc_load4(dst, d), v, true)
      } else {
        v
      }
      vmc_store4(dst, d, merged)
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let r = src_off + x + y * src_stride
      let mut sum = 0
      for t = 0; t < 8; t = t + 1 {
        sum = sum + coeffs[t] * src[r + (t - 3) * src_stride]
      }
      let fv = (sum + 64) >> 7
      let v = if fv < 0 {
        0
      } else if fv > pixel_max {
        pixel_max
      } else {
        fv
      }
      let d = dst_off + y * dst_stride + x
      dst[d] = if avg { (dst[d] + v + 1) / 2 } else { v }
    }
    x = x + 1
  }
}

///|
/// `put_8tap_1d_hv`: horizontal pass into a clipped intermediate, then the
/// vertical pass — the same two stages as `mc_kernel`'s `hv` branch.
///
/// The intermediate uses a caller-provided stride (`64` in the port's
/// `mc_tmp`); `tmp` must hold at least `tstride * (h + 7)` entries and the
/// output block starts at scratch row 3 (`mc_kernel`'s `to = 3 * 64`).
#cfg(any(target="native", target="wasm"))
pub fn vp9_8tap_1d_hv_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  tmp : FixedArray[Int32],
  tstride : Int32,
  w : Int32,
  h : Int32,
  fx_coeffs : Array[Int32],
  fy_coeffs : Array[Int32],
  pixel_max : Int32,
  avg~ : Bool = false,
) -> Unit {
  // stage 1: h + 7 rows of horizontal taps, starting 3 rows above the block
  for y = 0; y < h + 7; y = y + 1 {
    let srow = src_off + (y - 3) * src_stride
    let trow = y * tstride
    let mut x = 0
    while x + 4 <= w {
      let taps : Array[V128] = [
        vmc_load4(src, srow + x - 3),
        vmc_load4(src, srow + x - 2),
        vmc_load4(src, srow + x - 1),
        vmc_load4(src, srow + x),
        vmc_load4(src, srow + x + 1),
        vmc_load4(src, srow + x + 2),
        vmc_load4(src, srow + x + 3),
        vmc_load4(src, srow + x + 4),
      ]
      vmc_store4(tmp, trow + x, vmc_clip(vmc_dot8(taps, fx_coeffs), pixel_max))
      x = x + 4
    }
    while x < w {
      let p = srow + x
      let mut sum = 0
      for t = 0; t < 8; t = t + 1 {
        sum = sum + fx_coeffs[t] * src[p - 3 + t]
      }
      let fv = (sum + 64) >> 7
      tmp[trow + x] = if fv < 0 {
        0
      } else if fv > pixel_max {
        pixel_max
      } else {
        fv
      }
      x = x + 1
    }
  }
  // stage 2: vertical taps over the scratch, block origin at scratch row 3
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let r = (3 + y) * tstride + x
      let taps : Array[V128] = [
        vmc_load4(tmp, r - 3 * tstride),
        vmc_load4(tmp, r - 2 * tstride),
        vmc_load4(tmp, r - tstride),
        vmc_load4(tmp, r),
        vmc_load4(tmp, r + tstride),
        vmc_load4(tmp, r + 2 * tstride),
        vmc_load4(tmp, r + 3 * tstride),
        vmc_load4(tmp, r + 4 * tstride),
      ]
      let v = vmc_clip(vmc_dot8(taps, fy_coeffs), pixel_max)
      let d = dst_off + y * dst_stride + x
      let merged = if avg {
        vmc_merge(vmc_load4(dst, d), v, true)
      } else {
        v
      }
      vmc_store4(dst, d, merged)
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let r = (3 + y) * tstride + x
      let mut sum = 0
      for t = 0; t < 8; t = t + 1 {
        sum = sum + fy_coeffs[t] * tmp[r + (t - 3) * tstride]
      }
      let fv = (sum + 64) >> 7
      let v = if fv < 0 {
        0
      } else if fv > pixel_max {
        pixel_max
      } else {
        fv
      }
      let d = dst_off + y * dst_stride + x
      dst[d] = if avg { (dst[d] + v + 1) / 2 } else { v }
    }
    x = x + 1
  }
}

///|
/// The VP9 bilinear family (`FILTER_BILINEAR`): `d + ((f * (d2 - d) + 8) >> 4)`,
/// clipped. One direction at a time; both non-zero goes through a scratch,
/// exactly like `mc_kernel`'s 2D bilinear branch.
///
/// Pass `tmp = dst` and `two_stage = false` for the 1D cases.
#cfg(any(target="native", target="wasm"))
pub fn vp9_bilinear_v128(
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
  pixel_max : Int32,
  avg~ : Bool = false,
) -> Unit {
  let eight = @v128.i32x4_splat(8)

  if fy == 0 {
    // horizontal only: d + ((fx * (d[x+1] - d[x]) + 8) >> 4)
    let fv = @v128.i32x4_splat(fx.reinterpret_as_uint())
    for y = 0; y < h; y = y + 1 {
      let srow = src_off + y * src_stride
      let drow = dst_off + y * dst_stride
      let mut x = 0
      while x + 4 <= w {
        let a = vmc_load4(src, srow + x)
        let b = vmc_load4(src, srow + x + 1)
        let d = @v128.i32x4_add(
          a,
          @v128.i32x4_shr_s(
            @v128.i32x4_add(
              @v128.i32x4_mul(fv, @v128.i32x4_sub(b, a)),
              eight,
            ),
            4,
          ),
        )
        let v = vmc_clip(d, pixel_max)
        let merged = if avg { vmc_merge(vmc_load4(dst, drow + x), v, true) } else { v }
        vmc_store4(dst, drow + x, merged)
        x = x + 4
      }
      while x < w {
        let p = srow + x
        let fv2 = src[p] + ((fx * (src[p + 1] - src[p]) + 8) >> 4)
        let v = if fv2 < 0 {
          0
        } else if fv2 > pixel_max {
          pixel_max
        } else {
          fv2
        }
        let d = drow + x
        dst[d] = if avg { (dst[d] + v + 1) / 2 } else { v }
        x = x + 1
      }
    }
  } else if fx == 0 {
    // vertical only
    let fv = @v128.i32x4_splat(fy.reinterpret_as_uint())
    let mut x = 0
    while x + 4 <= w {
      for y = 0; y < h; y = y + 1 {
        let r = src_off + x + y * src_stride
        let a = vmc_load4(src, r)
        let b = vmc_load4(src, r + src_stride)
        let d = @v128.i32x4_add(
          a,
          @v128.i32x4_shr_s(
            @v128.i32x4_add(
              @v128.i32x4_mul(fv, @v128.i32x4_sub(b, a)),
              eight,
            ),
            4,
          ),
        )
        let v = vmc_clip(d, pixel_max)
        let dpos = dst_off + y * dst_stride + x
        let merged = if avg { vmc_merge(vmc_load4(dst, dpos), v, true) } else { v }
        vmc_store4(dst, dpos, merged)
      }
      x = x + 4
    }
    while x < w {
      for y = 0; y < h; y = y + 1 {
        let r = src_off + x + y * src_stride
        let fv2 = src[r] + ((fy * (src[r + src_stride] - src[r]) + 8) >> 4)
        let v = if fv2 < 0 {
          0
        } else if fv2 > pixel_max {
          pixel_max
        } else {
          fv2
        }
        let d = dst_off + y * dst_stride + x
        dst[d] = if avg { (dst[d] + v + 1) / 2 } else { v }
      }
      x = x + 1
    }
  } else {
    // 2D: horizontal into a scratch of (h+1) rows, then vertical from it
    let tstride = 64
    let tmp : FixedArray[Int32] = FixedArray::make(tstride * (h + 1), 0)
    let fxv = @v128.i32x4_splat(fx.reinterpret_as_uint())
    for y = 0; y < h + 1; y = y + 1 {
      let srow = src_off + y * src_stride
      let trow = y * tstride
      let mut x = 0
      while x + 4 <= w {
        let a = vmc_load4(src, srow + x)
        let b = vmc_load4(src, srow + x + 1)
        let d = @v128.i32x4_add(
          a,
          @v128.i32x4_shr_s(
            @v128.i32x4_add(
              @v128.i32x4_mul(fxv, @v128.i32x4_sub(b, a)),
              eight,
            ),
            4,
          ),
        )
        vmc_store4(tmp, trow + x, vmc_clip(d, pixel_max))
        x = x + 4
      }
      while x < w {
        let p = srow + x
        let fv2 = src[p] + ((fx * (src[p + 1] - src[p]) + 8) >> 4)
        tmp[trow + x] = if fv2 < 0 {
          0
        } else if fv2 > pixel_max {
          pixel_max
        } else {
          fv2
        }
        x = x + 1
      }
    }
    let fyv = @v128.i32x4_splat(fy.reinterpret_as_uint())
    let mut x = 0
    while x + 4 <= w {
      for y = 0; y < h; y = y + 1 {
        let r = y * tstride + x
        let a = vmc_load4(tmp, r)
        let b = vmc_load4(tmp, r + tstride)
        let d = @v128.i32x4_add(
          a,
          @v128.i32x4_shr_s(
            @v128.i32x4_add(
              @v128.i32x4_mul(fyv, @v128.i32x4_sub(b, a)),
              eight,
            ),
            4,
          ),
        )
        let dstpos = dst_off + y * dst_stride + x
        let merged = if avg {
          vmc_merge(vmc_load4(dst, dstpos), vmc_clip(d, pixel_max), true)
        } else {
          vmc_clip(d, pixel_max)
        }
        vmc_store4(dst, dstpos, merged)
      }
      x = x + 4
    }
    while x < w {
      for y = 0; y < h; y = y + 1 {
        let r = y * tstride + x
        let fv2 = tmp[r] + ((fy * (tmp[r + tstride] - tmp[r]) + 8) >> 4)
        let v = if fv2 < 0 {
          0
        } else if fv2 > pixel_max {
          pixel_max
        } else {
          fv2
        }
        let d = dst_off + y * dst_stride + x
        dst[d] = if avg { (dst[d] + v + 1) / 2 } else { v }
      }
      x = x + 1
    }
  }
}

///|
/// Whole-pixel copy / average (`fpel_fn`): `dst = src` or
/// `dst = (dst + src + 1) / 2`.
#cfg(any(target="native", target="wasm"))
pub fn vp9_fpel_copy_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  avg~ : Bool = false,
) -> Unit {
  for y = 0; y < h; y = y + 1 {
    let srow = src_off + y * src_stride
    let drow = dst_off + y * dst_stride
    let mut x = 0
    if avg {
      let one = @v128.i32x4_splat(1)
      while x + 4 <= w {
        vmc_store4(
          dst,
          drow + x,
          @v128.i32x4_shr_s(
            @v128.i32x4_add(
              @v128.i32x4_add(vmc_load4(dst, drow + x), vmc_load4(src, srow + x)),
              one,
            ),
            1,
          ),
        )
        x = x + 4
      }
      while x < w {
        dst[drow + x] = (dst[drow + x] + src[srow + x] + 1) / 2
        x = x + 1
      }
    } else {
      while x + 4 <= w {
        vmc_store4(dst, drow + x, vmc_load4(src, srow + x))
        x = x + 4
      }
      while x < w {
        dst[drow + x] = src[srow + x]
        x = x + 1
      }
    }
  }
}
