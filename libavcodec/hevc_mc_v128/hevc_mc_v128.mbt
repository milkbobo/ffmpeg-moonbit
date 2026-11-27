///|
/// SIMD (`@v128`) versions of the HEVC motion-compensation interpolation
/// kernels (`libavcodec/hevc/dsp_template.c`: the `QPEL_FILTER` /
/// `EPEL_FILTER` 8- and 4-tap bodies behind `put_hevc_qpel_{h,v,hv}` and
/// `put_hevc_epel_{h,v,hv}`, plus their `_uni` normalisation
/// `(sum >> (bd-8)) + (1 << (shift-1))) >> shift` with
/// `shift = 14 - bd`; the scalar ports are `hevc_qpel_h/v`,
/// `hevc_epel_h/v` and `hevc_luma_mc_uni` / `hevc_chroma_mc_uni` in
/// `libavcodec/hevc_mc.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/hevc/mc.asm`: `QPEL_TABLE`/`EPEL_TABLE` coefficient
/// banks, `QPEL_FILTER`/`EPEL_FILTER`, `QPEL_H_LOAD`/`QPEL_V_LOAD`,
/// `EPEL_LOAD`, and the `PEL_8/10/12STORE*` depth-specific stores).
///
/// The asm's structure is kept:
///   - the `h` pass has one lane per output pixel and reads the eight taps
///     `x-3 .. x+4` (the `QPEL_H_LOAD` windows);
///   - the `v` pass has one lane per output **column** and gathers the
///     taps down `sstride` (`QPEL_V_LOAD`);
///   - the `hv` pass is the two-stage form: horizontal sums into an `i32`
///     scratch of `(h+7)` rows, then the vertical taps over it;
///   - `_uni` applies `>> (bd-8)` then `(v + (1<<(shift-1))) >> shift` and
///     `av_clip_uintp2` — the asm's `PEL_*STORE` packs.
///
/// `i32x4` lanes make the asm's `packusdw`/`packuswb` saturation reasoning
/// unnecessary: the widest intermediate is
/// `64 · (2^bd-1) · 2^bd`-scale only in `hv`'s second stage, which stays
/// well inside `Int32` for `bd <= 12` (2 · 4095 · 64 · 64 ≈ 3.4e7 <
/// 2^31), and the epilogue clamps with `min_s`/`max_s`.
///
/// Deviations (documented): the asm has per-width (2/4/6/8/12/16/32/64)
/// and per-bit-depth (8/10/12) entry points — 12 specialisations per
/// direction; here one kernel per direction takes `w`/`h`/`bd`, with a
/// 4-lane body plus scalar tail, so any width works and the depth is a
/// parameter instead of a separate code path.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `hevc_mc_v128_wbtest.mbt`.

///|
/// `av_clip_uintp2(v, bd)` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn hmc_clip(v : V128, bd : Int32) -> V128 {
  @simd.i32x4_min_s(
    @simd.i32x4_max_s(v, @simd.i32x4_splat(0)),
    @simd.i32x4_splat(((1 << bd) - 1).reinterpret_as_uint()),
  )
}

///|
/// Load four consecutive samples of a scratch buffer. */
#cfg(any(target="native", target="wasm"))
fn hmc_load4(buf : FixedArray[Int32], at : Int32) -> V128 {
  let mut v = @simd.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @simd.i32x4_replace_lane(v, buf[at + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Store four lanes into a scratch buffer. */
#cfg(any(target="native", target="wasm"))
fn hmc_store4(buf : FixedArray[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    buf[at + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// Dot product of eight taps against eight coefficient splats. */
#cfg(any(target="native", target="wasm"))
fn hmc_dot(taps : Array[V128], f : FixedArray[Int32]) -> V128 {
  let mut acc = @simd.i32x4_splat(0)
  for k = 0; k < 8; k = k + 1 {
    let c = f[k]
    if c != 0 {
      acc = @simd.i32x4_add(
        acc,
        @simd.i32x4_mul(taps[k], @simd.i32x4_splat(c.reinterpret_as_uint())),
      )
    }
  }
  acc
}

///|
/// Dot product of four taps (the epel/chroma filter). */
#cfg(any(target="native", target="wasm"))
fn hmc_dot4(taps : Array[V128], f : FixedArray[Int32]) -> V128 {
  let mut acc = @simd.i32x4_splat(0)
  let mut k = 0
  while k < 4 {
    let c = f[k]
    if c != 0 {
      acc = @simd.i32x4_add(
        acc,
        @simd.i32x4_mul(taps[k], @simd.i32x4_splat(c.reinterpret_as_uint())),
      )
    }
    k = k + 1
  }
  acc
}

///|
/// The eight horizontal taps of a row at `x-3 .. x+4`. */
#cfg(any(target="native", target="wasm"))
fn hmc_htaps(buf : FixedArray[Int32], row : Int32, x : Int32) -> Array[V128] {
  [
    hmc_load4(buf, row + x - 3),
    hmc_load4(buf, row + x - 2),
    hmc_load4(buf, row + x - 1),
    hmc_load4(buf, row + x),
    hmc_load4(buf, row + x + 1),
    hmc_load4(buf, row + x + 2),
    hmc_load4(buf, row + x + 3),
    hmc_load4(buf, row + x + 4),
  ]
}

///|
/// The eight vertical taps of a column at `y-3 .. y+4`. */
#cfg(any(target="native", target="wasm"))
fn hmc_vtaps(
  buf : FixedArray[Int32],
  col : Int32,
  stride : Int32,
) -> Array[V128] {
  [
    hmc_load4(buf, col - 3 * stride),
    hmc_load4(buf, col - 2 * stride),
    hmc_load4(buf, col - stride),
    hmc_load4(buf, col),
    hmc_load4(buf, col + stride),
    hmc_load4(buf, col + 2 * stride),
    hmc_load4(buf, col + 3 * stride),
    hmc_load4(buf, col + 4 * stride),
  ]
}

///|
/// `put_hevc_qpel_h`: 8-tap horizontal, raw sum (no normalisation) — the
/// form both `_uni` and the `hv` first stage consume.
#cfg(any(target="native", target="wasm"))
pub fn hevc_qpel_h_raw_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  f : FixedArray[Int32],
) -> Unit {
  for y = 0; y < h; y = y + 1 {
    let srow = src_off + y * src_stride
    let drow = dst_off + y * dst_stride
    let mut x = 0
    while x + 4 <= w {
      hmc_store4(dst, drow + x, hmc_dot(hmc_htaps(src, srow, x), f))
      x = x + 4
    }
    while x < w {
      let p = srow + x
      let mut s = 0
      for k = 0; k < 8; k = k + 1 {
        s = s + f[k] * src[p - 3 + k]
      }
      dst[drow + x] = s
      x = x + 1
    }
  }
}

///|
/// `put_hevc_qpel_v`: 8-tap vertical, raw sum.
#cfg(any(target="native", target="wasm"))
pub fn hevc_qpel_v_raw_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  f : FixedArray[Int32],
) -> Unit {
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let col = src_off + x + y * src_stride
      hmc_store4(
        dst,
        dst_off + y * dst_stride + x,
        hmc_dot(hmc_vtaps(src, col, src_stride), f),
      )
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let col = src_off + x + y * src_stride
      let mut s = 0
      for k = 0; k < 8; k = k + 1 {
        s = s + f[k] * src[col + (k - 3) * src_stride]
      }
      dst[dst_off + y * dst_stride + x] = s
    }
    x = x + 1
  }
}

///|
/// `put_hevc_qpel_hv`: horizontal sums into a scratch of `(h+7)` rows,
/// then the vertical taps (the `hv` two-stage form; the scratch stride is
/// `w` rounded up to 4).
#cfg(any(target="native", target="wasm"))
pub fn hevc_qpel_hv_raw_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  fh : FixedArray[Int32],
  fv : FixedArray[Int32],
) -> Unit {
  let pad = if w % 4 == 0 { 0 } else { 4 - w % 4 }
  let tstride = w + pad
  let tmp : FixedArray[Int32] = FixedArray::make(tstride * (h + 7), 0)
  for y = 0; y < h + 7; y = y + 1 {
    let srow = src_off + y * src_stride
    let trow = y * tstride
    let mut x = 0
    while x + 4 <= w {
      hmc_store4(tmp, trow + x, hmc_dot(hmc_htaps(src, srow, x), fh))
      x = x + 4
    }
    while x < w {
      let p = srow + x
      let mut s = 0
      for k = 0; k < 8; k = k + 1 {
        s = s + fh[k] * src[p - 3 + k]
      }
      tmp[trow + x] = s
      x = x + 1
    }
  }
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let col = 3 * tstride + x + y * tstride
      hmc_store4(
        dst,
        dst_off + y * dst_stride + x,
        hmc_dot(hmc_vtaps(tmp, col, tstride), fv),
      )
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let col = 3 * tstride + x + y * tstride
      let mut s = 0
      for k = 0; k < 8; k = k + 1 {
        s = s + fv[k] * tmp[col + (k - 3) * tstride]
      }
      dst[dst_off + y * dst_stride + x] = s
    }
    x = x + 1
  }
}

///|
/// `put_hevc_epel_h`: 4-tap chroma horizontal, raw sum.
#cfg(any(target="native", target="wasm"))
pub fn hevc_epel_h_raw_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  f : FixedArray[Int32],
) -> Unit {
  for y = 0; y < h; y = y + 1 {
    let srow = src_off + y * src_stride
    let drow = dst_off + y * dst_stride
    let mut x = 0
    while x + 4 <= w {
      let taps : Array[V128] = [
        hmc_load4(src, srow + x - 1),
        hmc_load4(src, srow + x),
        hmc_load4(src, srow + x + 1),
        hmc_load4(src, srow + x + 2),
      ]
      hmc_store4(dst, drow + x, hmc_dot4(taps, f))
      x = x + 4
    }
    while x < w {
      let p = srow + x
      dst[drow + x] = f[0] * src[p - 1] +
        f[1] * src[p] +
        f[2] * src[p + 1] +
        f[3] * src[p + 2]
      x = x + 1
    }
  }
}

///|
/// `put_hevc_epel_v`: 4-tap chroma vertical, raw sum.
#cfg(any(target="native", target="wasm"))
pub fn hevc_epel_v_raw_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  f : FixedArray[Int32],
) -> Unit {
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let col = src_off + x + y * src_stride
      let taps : Array[V128] = [
        hmc_load4(src, col - src_stride),
        hmc_load4(src, col),
        hmc_load4(src, col + src_stride),
        hmc_load4(src, col + 2 * src_stride),
      ]
      hmc_store4(dst, dst_off + y * dst_stride + x, hmc_dot4(taps, f))
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let col = src_off + x + y * src_stride
      dst[dst_off + y * dst_stride + x] = f[0] * src[col - src_stride] +
        f[1] * src[col] +
        f[2] * src[col + src_stride] +
        f[3] * src[col + 2 * src_stride]
    }
    x = x + 1
  }
}

///|
/// `put_hevc_epel_hv`: horizontal sums into `(h+3)` scratch rows, then the
/// vertical 4-tap.
#cfg(any(target="native", target="wasm"))
pub fn hevc_epel_hv_raw_v128(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  fh : FixedArray[Int32],
  fv : FixedArray[Int32],
) -> Unit {
  let pad = if w % 4 == 0 { 0 } else { 4 - w % 4 }
  let tstride = w + pad
  let tmp : FixedArray[Int32] = FixedArray::make(tstride * (h + 3), 0)
  for y = 0; y < h + 3; y = y + 1 {
    let srow = src_off + (y - 1) * src_stride
    let trow = y * tstride
    let mut x = 0
    while x + 4 <= w {
      let taps : Array[V128] = [
        hmc_load4(src, srow + x - 1),
        hmc_load4(src, srow + x),
        hmc_load4(src, srow + x + 1),
        hmc_load4(src, srow + x + 2),
      ]
      hmc_store4(tmp, trow + x, hmc_dot4(taps, fh))
      x = x + 4
    }
    while x < w {
      let p = srow + x
      tmp[trow + x] = fh[0] * src[p - 1] +
        fh[1] * src[p] +
        fh[2] * src[p + 1] +
        fh[3] * src[p + 2]
      x = x + 1
    }
  }
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let col = tstride + x + y * tstride
      let t0 = hmc_load4(tmp, col - tstride)
      let t1 = hmc_load4(tmp, col)
      let t2 = hmc_load4(tmp, col + tstride)
      let t3 = hmc_load4(tmp, col + 2 * tstride)
      hmc_store4(
        dst,
        dst_off + y * dst_stride + x,
        hmc_dot4([t0, t1, t2, t3], fv),
      )
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let col = tstride + x + y * tstride
      dst[dst_off + y * dst_stride + x] = fv[0] * tmp[col - tstride] +
        fv[1] * tmp[col] +
        fv[2] * tmp[col + tstride] +
        fv[3] * tmp[col + 2 * tstride]
    }
    x = x + 1
  }
}

///|
/// `_uni` epilogue: `(raw >> (bd-8) + (1 << (shift-1))) >> shift` then
/// `av_clip_uintp2`, where `shift = 14 - bd`. Lanes store into the pixel
/// plane.
#cfg(any(target="native", target="wasm"))
pub fn hevc_qpel_uni_epilogue_v128(
  dst : Array[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  raw : FixedArray[Int32],
  raw_off : Int32,
  raw_stride : Int32,
  w : Int32,
  h : Int32,
  bd : Int32,
) -> Unit {
  let norm = bd - 8
  let shift = 14 - bd
  let offset = 1 << (shift - 1)
  let ov = @simd.i32x4_splat(offset.reinterpret_as_uint())
  for y = 0; y < h; y = y + 1 {
    let rrow = raw_off + y * raw_stride
    let drow = dst_off + y * dst_stride
    let mut x = 0
    while x + 4 <= w {
      let v = @simd.i32x4_add(
        @simd.i32x4_shr_s(hmc_load4(raw, rrow + x), norm),
        ov,
      )
      hmc_store4_px(dst, drow + x, hmc_clip(@simd.i32x4_shr_s(v, shift), bd))
      x = x + 4
    }
    while x < w {
      let v = ((raw[rrow + x] >> norm) + offset) >> shift
      dst[drow + x] = if v < 0 {
        0
      } else if v > (1 << bd) - 1 {
        (1 << bd) - 1
      } else {
        v
      }
      x = x + 1
    }
  }
}

///|
/// Store four lanes into the destination `Array[Int32]` plane. */
#cfg(any(target="native", target="wasm"))
fn hmc_store4_px(dst : Array[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    dst[at + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}
