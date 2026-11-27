///|
/// SIMD (`@v128`) versions of the H.264 weighted-prediction pixel kernels
/// (`libavcodec/h264dsp_template.c`: `H264_WEIGHT(16/8/4/2)` producing
/// `weight_h264_pixels*` / `biweight_h264_pixels*`; the scalar ports are
/// `h264_weight_rect` in `libavcodec/h264_inter.mbt` and the explicit /
/// implicit B weighting in `libavcodec/h264_b_mc.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/h264_weight.asm`: `ff_h264_weight_16_sse2`,
/// `ff_h264_weight_8/4_sse2`, `ff_h264_biweight_16_sse2` &
/// `ff_h264_biweight_8/4_sse2`). The asm setup ( `WEIGHT_SETUP` /
/// `BIWEIGHT_SETUP` ) folds the C template's rounding into a single
/// constant added before the shift:
///
///   weight:   offset' = (unsigned)offset << (log2_denom + depth-8)
///                       + (log2_denom ? 1<<(log2_denom-1) : 0)
///             out = clip_pixel((px*weight + offset') >> log2_denom)
///   biweight: offset' = (unsigned)((offset<<(depth-8)) + 1 | 1) << log2_denom
///             out = clip_pixel((src*weights + dst*weightd + offset')
///                              >> (log2_denom+1))
///
/// Both are carried here as `i32x4` lane-wise multiply-adds over four
/// pixels at a time (the asm's `punpcklbw` widening + `pmullw`/`paddsw`:
/// 8-bit samples in `i16` lanes there, `i32` lanes here, so the 15-bit
/// weight times a 14-bit pixel product cannot overflow and no saturation
/// argument is needed). The asm's `packuswb` becomes `i32x4_min_s` /
/// `i32x4_max_s`. The unsigned shift of negative offsets is reproduced by
/// masking the offset to 16 bits before shifting, exactly like the C
/// `(unsigned)offset << ...`, then reinterpreting as `Int32`.
///
/// Deviations (documented): the asm has dedicated entry points per width
/// (2/4/8/16); here one kernel takes `w` and processes 4-pixel groups with
/// a scalar tail, so any width works. `w=2` still rounds through `i32x4`
/// with two dead lanes (the asm's `WEIGHT_FUNC_HALF_MM` row pairing is a
/// scheduling trick, not an arithmetic difference).
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `h264_weight_v128_wbtest.mbt`.

///|
/// Accumulate four pixels of `src` starting at `off` into `i32x4`. */
#cfg(any(target="native", target="wasm"))
fn wgt_load4(plane : Array[Int32], off : Int32) -> V128 {
  let mut v = @simd.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @simd.i32x4_replace_lane(v, plane[off + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Write four `i32x4` lanes back to `plane` at `off`. */
#cfg(any(target="native", target="wasm"))
fn wgt_store4(plane : Array[Int32], off : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    plane[off + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// `av_clip_pixel` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn wgt_clip(v : V128, bit_depth : Int32) -> V128 {
  @simd.i32x4_min_s(
    @simd.i32x4_max_s(v, @simd.i32x4_splat(0)),
    @simd.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint()),
  )
}

///|
/// `weight_h264_pixels*`: in-place weighted prediction.
///
/// The C template computes `offset = (unsigned)offset << (log2_denom +
/// depth-8)` — a left shift of an unsigned value whose result is stored
/// back into an `int`. On two's complement that is exactly the wrapping
/// `Int32` shift, so the port's plain `<<` is bit-identical for negative
/// offsets too (no masking dance needed).
#cfg(any(target="native", target="wasm"))
pub fn h264_weight_rect_v128(
  plane : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
  log2_denom : Int32,
  weight : Int32,
  offset : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let mut off2 = offset << (bit_depth - 8 + log2_denom)
  if log2_denom != 0 {
    off2 = off2 + (1 << (log2_denom - 1))
  }
  let wv = @simd.i32x4_splat(weight.reinterpret_as_uint())
  let ov = @simd.i32x4_splat(off2.reinterpret_as_uint())
  for y = 0; y < h; y = y + 1 {
    let row = off + y * stride
    let mut x = 0
    while x + 4 <= w {
      let px = wgt_load4(plane, row + x)
      let scaled = @simd.i32x4_shr_s(
        @simd.i32x4_add(@simd.i32x4_mul(px, wv), ov),
        log2_denom,
      )
      wgt_store4(plane, row + x, wgt_clip(scaled, bit_depth))
      x = x + 4
    }
    while x < w {
      let i = row + x
      let v = (plane[i] * weight + off2) >> log2_denom
      plane[i] = if v < 0 {
        0
      } else if v > (1 << bit_depth) - 1 {
        (1 << bit_depth) - 1
      } else {
        v
      }
      x = x + 1
    }
  }
}

///|
/// `biweight_h264_pixels*`: two-reference weighted average into `dst`.
///
/// `dst` and `src` may be the same array (the C contract lets `pix` and
/// `src` alias for `op_scale2`'s read-then-write), which is why each group
/// is read fully before any lane is stored.
#cfg(any(target="native", target="wasm"))
pub fn h264_biweight_rect_v128(
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
  bit_depth~ : Int32 = 8,
) -> Unit {
  // offset' = ((offset << (depth-8)) + 1 | 1) << log2_denom — the C
  // template's `(unsigned)((offset + 1) | 1) << log2_denom`, which on two's
  // complement is the wrapping Int32 shift.
  let off2 = (((offset << (bit_depth - 8)) + 1) | 1) << log2_denom
  let wdv = @simd.i32x4_splat(weightd.reinterpret_as_uint())
  let wsv = @simd.i32x4_splat(weights.reinterpret_as_uint())
  let ov = @simd.i32x4_splat(off2.reinterpret_as_uint())
  for y = 0; y < h; y = y + 1 {
    let drow = doff + y * dstride
    let srow = soff + y * stride
    let mut x = 0
    while x + 4 <= w {
      let d = wgt_load4(dst, drow + x)
      let s = wgt_load4(src, srow + x)
      let acc = @simd.i32x4_add(
        @simd.i32x4_add(@simd.i32x4_mul(s, wsv), @simd.i32x4_mul(d, wdv)),
        ov,
      )
      wgt_store4(
        dst,
        drow + x,
        wgt_clip(@simd.i32x4_shr_s(acc, log2_denom + 1), bit_depth),
      )
      x = x + 4
    }
    while x < w {
      let acc = src[srow + x] * weights + dst[drow + x] * weightd + off2
      let v = acc >> (log2_denom + 1)
      dst[drow + x] = if v < 0 {
        0
      } else if v > (1 << bit_depth) - 1 {
        (1 << bit_depth) - 1
      } else {
        v
      }
      x = x + 1
    }
  }
}

///|
/// Implicit B weighting (`implicit_weight_table` + `mc_part_weighted`'s
/// `implicit` branch in `h264_mb.c`):
///
///   out = clip_pixel((a*w + b*(64-w) + 32) >> 6)
///
/// `w` is the 0..64 luma weight derived from the POC distances; the scalar
/// port spells it `(implicit0*av + (64-implicit0)*bv + 32) >> 6`.
#cfg(any(target="native", target="wasm"))
pub fn h264_implicit_biweight_v128(
  dst : Array[Int32],
  doff : Int32,
  a : Array[Int32],
  aoff : Int32,
  b : Array[Int32],
  boff : Int32,
  stride : Int32,
  dstride : Int32,
  width : Int32,
  height : Int32,
  w0 : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let w0v = @simd.i32x4_splat(w0.reinterpret_as_uint())
  let w1v = @simd.i32x4_splat((64 - w0).reinterpret_as_uint())
  let rnd = @simd.i32x4_splat(32)
  for y = 0; y < height; y = y + 1 {
    let drow = doff + y * dstride
    let arow = aoff + y * stride
    let brow = boff + y * stride
    let mut x = 0
    while x + 4 <= width {
      let av = wgt_load4(a, arow + x)
      let bv = wgt_load4(b, brow + x)
      let acc = @simd.i32x4_add(
        @simd.i32x4_add(@simd.i32x4_mul(av, w0v), @simd.i32x4_mul(bv, w1v)),
        rnd,
      )
      wgt_store4(dst, drow + x, wgt_clip(@simd.i32x4_shr_s(acc, 6), bit_depth))
      x = x + 4
    }
    while x < width {
      let v = (a[arow + x] * w0 + b[brow + x] * (64 - w0) + 32) >> 6
      dst[drow + x] = if v < 0 {
        0
      } else if v > (1 << bit_depth) - 1 {
        (1 << bit_depth) - 1
      } else {
        v
      }
      x = x + 1
    }
  }
}
