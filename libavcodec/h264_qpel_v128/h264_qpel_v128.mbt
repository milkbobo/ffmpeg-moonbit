///|
/// SIMD (`@v128`) versions of the H.264 quarter-pel luma interpolation
/// kernels (`libavcodec/h264qpel_template.c`: `put_h264_qpel{4,8}_{h,v,hv}_
/// lowpass` with `op_put`/`op2_put`, plus the `put_pixels*_l2_shift5`
/// merge; the scalar port is `h264_mc_luma` in `libavcodec/h264_mc.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/h264_qpel_8bit.asm`: `QPEL4_H_LOWPASS_OP`,
/// `QPEL8_H_LOWPASS_OP_XMM`, `QPEL4_V_LOWPASS_OP`,
/// `QPEL8OR16_V_LOWPASS_OP`, `put_h264_qpel*_hv_lowpass_*`, `FILT_HV`,
/// `PIXELS{4,8}_L2_SHIFT5`).
///
/// The 6-tap is the H.264 half-pel filter
///
///   filt(s, -2..3) = (s0+s1)*20 - (sA+s2)*5 + (sB+s3)     [A=-1, B=-2]
///
/// and the asm keeps it in `i16` lanes: `punpcklbw` widens the source
/// bytes, `psllw 2` + `psubw` forms `(a+b)*20 - (c+d)*5` without ever
/// multiplying 20 (a `pmullw` by `pw_5` does the negative half), then
/// `psraw 5` + `packuswb` finishes `op_put`. Here the same body runs in
/// `i32x4` lanes accumulated over the tap dimension, so:
///
///   - the horizontal pass over `w` outputs is one lane per pixel for
///     `w`=4 and two `i32x4` groups for `w`=8/16;
///   - the vertical pass vectorises across the 4/8/16 output columns (each
///     lane is one column, taps gathered down `srcStride`), which is
///     exactly the asm's `FILT_V` rotation but with the lane axis fixed;
///   - the `hv` pass reproduces the C/asm two-stage shape: an unshifted,
///     unclipped horizontal `i32` scratch of `(h+5)` rows, then the
///     vertical 6-tap over that scratch and the `(v + 512) >> 10` finish
///     (`op2_put`). Keeping the intermediate unclipped is what makes
///     `hv` differ from `h`-then-`v`, so the port preserves it.
///
/// `i32` lanes make the `i16` overflow the asm has to reason about
/// impossible: the widest intermediate is `(255+255)*20 + 255+255 = 10710`
/// horiontally and `(10710+10710)*20 * 2 = ~857k` in the `hv` second stage,
/// both far inside `Int32`. `packuswb` becomes an `i32x4` clamp to
/// `[0, 2^depth-1]` (`av_clip_pixel`).
///
/// Deviations (documented): the asm has fixed 4/8/16 entry points with
/// hand-rotated register lanes; here one kernel per orientation takes
/// `w`/`h` so the 16-wide cases are just a bigger loop over the same
/// `i32x4` groups. Only the `put` variants are ported — the port's scalar
/// path never uses `avg` (B-weighted averaging goes through
/// `h264_weight_v128`), and `l2_shift5` is provided because the qpel
/// quarter-position merges go through it.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernel. Equal
/// outputs are asserted in `h264_qpel_v128_wbtest.mbt`.

///|
/// `av_clip_pixel` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn qp_clip_lanes(v : V128, bit_depth : Int32) -> V128 {
  @simd.i32x4_min_s(
    @simd.i32x4_max_s(v, @simd.i32x4_splat(0)),
    @simd.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint()),
  )
}

///|
/// Load four consecutive plane samples into `i32x4` lanes. */
#cfg(any(target="native", target="wasm"))
fn qp_load4(src : Array[Int32], at : Int32) -> V128 {
  let mut v = @simd.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @simd.i32x4_replace_lane(v, src[at + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Store four `i32x4` lanes to the plane. */
#cfg(any(target="native", target="wasm"))
fn qp_store4(dst : Array[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    dst[at + i] = @simd.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// The 6-tap lowpass over four lane-vectors `sB sA s0 s1 s2 s3` (taps at
/// offsets -2..3):
///
///   (s0+s1)*20 - (sA+s2)*5 + (sB+s3)
///
/// This is the asm's `paddw`/`psllw 2`/`psubw`/`pmullw pw_5` sequence —
/// `(a+b)*20 = ((a+b)<<2)*5` — expressed without the shift trick, since
/// `i32x4_mul` is a real multiply in Wasm SIMD.
#cfg(any(target="native", target="wasm"))
fn qp_filt6(
  sB : V128,
  sA : V128,
  s0 : V128,
  s1 : V128,
  s2 : V128,
  s3 : V128,
) -> V128 {
  let twenty = @simd.i32x4_splat(20)
  let five = @simd.i32x4_splat(5)
  @simd.i32x4_add(
    @simd.i32x4_sub(
      @simd.i32x4_mul(@simd.i32x4_add(s0, s1), twenty),
      @simd.i32x4_mul(@simd.i32x4_add(sA, s2), five),
    ),
    @simd.i32x4_add(sB, s3),
  )
}

///|
/// `put_h264_qpel{4,8}h_lowpass`: horizontal 6-tap, `(v + 16) >> 5`, clip.
///
/// Source row `y` of the destination needs `src[y][x-2 .. x+3]`; the
/// caller passes a plane + offsets so the border-replication accessor of
/// the scalar port is what feeds it.
#cfg(any(target="native", target="wasm"))
pub fn h264_qpel_h_lowpass_v128(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  soff : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let sixteen = @simd.i32x4_splat(16)
  for y = 0; y < h; y = y + 1 {
    let srow = soff + y * sstride
    let drow = dstoff + y * dstride
    let mut x = 0
    while x + 4 <= w {
      // taps are the four consecutive windows -2..3 relative to x..x+3
      let sB = qp_load4(src, srow + x - 2)
      let sA = qp_load4(src, srow + x - 1)
      let s0 = qp_load4(src, srow + x)
      let s1 = qp_load4(src, srow + x + 1)
      let s2 = qp_load4(src, srow + x + 2)
      let s3 = qp_load4(src, srow + x + 3)
      let sum = qp_filt6(sB, sA, s0, s1, s2, s3)
      qp_store4(
        dst,
        drow + x,
        qp_clip_lanes(
          @simd.i32x4_shr_s(@simd.i32x4_add(sum, sixteen), 5),
          bit_depth,
        ),
      )
      x = x + 4
    }
    while x < w {
      let p = srow + x
      let sum = (src[p] + src[p + 1]) * 20 -
        (src[p - 1] + src[p + 2]) * 5 +
        (src[p - 2] + src[p + 3])
      let v = (sum + 16) >> 5
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
/// `put_h264_qpel{4,8,16}v_lowpass`: vertical 6-tap, `(v + 16) >> 5`, clip.
///
/// Lane `i` is output column `i` + 4*group; the taps are four columns
/// gathered down `sstride` (the asm's `FILT_V` register rotation).
#cfg(any(target="native", target="wasm"))
pub fn h264_qpel_v_lowpass_v128(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  soff : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let sixteen = @simd.i32x4_splat(16)
  let mut x = 0
  while x + 4 <= w {
    let col = soff + x
    for y = 0; y < h; y = y + 1 {
      let r = col + y * sstride
      let sB = qp_load4(src, r - 2 * sstride)
      let sA = qp_load4(src, r - sstride)
      let s0 = qp_load4(src, r)
      let s1 = qp_load4(src, r + sstride)
      let s2 = qp_load4(src, r + 2 * sstride)
      let s3 = qp_load4(src, r + 3 * sstride)
      let sum = qp_filt6(sB, sA, s0, s1, s2, s3)
      qp_store4(
        dst,
        dstoff + y * dstride + x,
        qp_clip_lanes(
          @simd.i32x4_shr_s(@simd.i32x4_add(sum, sixteen), 5),
          bit_depth,
        ),
      )
    }
    x = x + 4
  }
  while x < w {
    let col = soff + x
    for y = 0; y < h; y = y + 1 {
      let r = col + y * sstride
      let sum = (src[r] + src[r + sstride]) * 20 -
        (src[r - sstride] + src[r + 2 * sstride]) * 5 +
        (src[r - 2 * sstride] + src[r + 3 * sstride])
      let v = (sum + 16) >> 5
      dst[dstoff + y * dstride + x] = if v < 0 {
        0
      } else if v > (1 << bit_depth) - 1 {
        (1 << bit_depth) - 1
      } else {
        v
      }
    }
    x = x + 1
  }
}

///|
/// `put_h264_qpel{4,8}hv_lowpass`: the two-stage 6-tap.
///
/// Stage 1 writes `(h+5)` rows of the *unshifted, unclipped* horizontal
/// sum into an `i32` scratch (`FILT_HV`'s `mova [r1+%1], m6`), stage 2
/// runs the vertical 6-tap over the scratch and finishes with
/// `(v + 512) >> 10` (`op2_put`). The scratch stride is `w` rounded up to
/// a multiple of 4 so the vector stores stay in bounds; the extra columns
/// are written but never read.
#cfg(any(target="native", target="wasm"))
pub fn h264_qpel_hv_lowpass_v128(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  soff : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let pad = if w % 4 == 0 { 0 } else { 4 - w % 4 }
  let tstride = w + pad
  let tn = tstride * (h + 5)
  let tmp : Array[Int32] = Array::make(tn, 0)
  // stage 1: nw columns x (h+5) rows of unclipped horizontal sums
  for y = 0; y < h + 5; y = y + 1 {
    let srow = soff + y * sstride
    let trow = y * tstride
    let mut x = 0
    while x + 4 <= w {
      let sB = qp_load4(src, srow + x - 2)
      let sA = qp_load4(src, srow + x - 1)
      let s0 = qp_load4(src, srow + x)
      let s1 = qp_load4(src, srow + x + 1)
      let s2 = qp_load4(src, srow + x + 2)
      let s3 = qp_load4(src, srow + x + 3)
      qp_store4(tmp, trow + x, qp_filt6(sB, sA, s0, s1, s2, s3))
      x = x + 4
    }
    while x < w {
      let p = srow + x
      tmp[trow + x] = (src[p] + src[p + 1]) * 20 -
        (src[p - 1] + src[p + 2]) * 5 +
        (src[p - 2] + src[p + 3])
      x = x + 1
    }
    // the padded columns are never read; zero them so the scratch is
    // deterministic
    let mut q = w
    while q < tstride {
      tmp[trow + q] = 0
      q = q + 1
    }
  }
  // stage 2: vertical 6-tap over the scratch, (v + 512) >> 10, clip.
  // The C positions `tmp` at row 2 of the scratch (`tmp -= tmpStride*(h+5-2)`)
  // before the column loop, so destination row y reads scratch rows
  // (y+2)-2 .. (y+2)+3 — i.e. the base index carries a +2 row shift.
  let r512 = @simd.i32x4_splat(512)
  let mut x = 0
  while x + 4 <= w {
    for y = 0; y < h; y = y + 1 {
      let r = (y + 2) * tstride + x
      let tB = qp_load4(tmp, r - 2 * tstride)
      let tA = qp_load4(tmp, r - tstride)
      let t0 = qp_load4(tmp, r)
      let t1 = qp_load4(tmp, r + tstride)
      let t2 = qp_load4(tmp, r + 2 * tstride)
      let t3 = qp_load4(tmp, r + 3 * tstride)
      let sum = qp_filt6(tB, tA, t0, t1, t2, t3)
      qp_store4(
        dst,
        dstoff + y * dstride + x,
        qp_clip_lanes(
          @simd.i32x4_shr_s(@simd.i32x4_add(sum, r512), 10),
          bit_depth,
        ),
      )
    }
    x = x + 4
  }
  while x < w {
    for y = 0; y < h; y = y + 1 {
      let r = (y + 2) * tstride + x
      let sum = (tmp[r] + tmp[r + tstride]) * 20 -
        (tmp[r - tstride] + tmp[r + 2 * tstride]) * 5 +
        (tmp[r - 2 * tstride] + tmp[r + 3 * tstride])
      let v = (sum + 512) >> 10
      dst[dstoff + y * dstride + x] = if v < 0 {
        0
      } else if v > (1 << bit_depth) - 1 {
        (1 << bit_depth) - 1
      } else {
        v
      }
    }
    x = x + 1
  }
}

///|
/// `put_pixels{4,8}_l2_shift5`: merge a shifted `i16`-domain scratch with
/// an 8-bit block, `(a + b + 1) >> 1` per sample (the asm's `psraw 5` +
/// `packuswb` + `pavgb`).
///
/// `src16` holds the vertical-pass output with its `<<5` scaling still on
/// it (`put_h264_qpel*_hv_lowpass`'s scratch); `src8` is the full-pel
/// reference block the quarter position averages with. Output goes to
/// `dst`.
#cfg(any(target="native", target="wasm"))
pub fn h264_qpel_l2_shift5_v128(
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
  bit_depth~ : Int32 = 8,
) -> Unit {
  let one = @simd.i32x4_splat(1)
  for y = 0; y < h; y = y + 1 {
    let r16 = soff16 + y * s16stride
    let r8 = soff8 + y * s8stride
    let drow = dstoff + y * dstride
    let mut x = 0
    while x + 4 <= w {
      let a = qp_clip_lanes(
        @simd.i32x4_shr_s(qp_load4(src16, r16 + x), 5),
        bit_depth,
      )
      let b = qp_load4(src8, r8 + x)
      // (a + b + 1) >> 1 on non-negative values == the asm's pavgb
      qp_store4(
        dst,
        drow + x,
        @simd.i32x4_shr_s(@simd.i32x4_add(@simd.i32x4_add(a, b), one), 1),
      )
      x = x + 4
    }
    while x < w {
      let av = src16[r16 + x] >> 5
      let a = if av < 0 {
        0
      } else if av > (1 << bit_depth) - 1 {
        (1 << bit_depth) - 1
      } else {
        av
      }
      dst[drow + x] = (a + src8[r8 + x] + 1) >> 1
      x = x + 1
    }
  }
}
