///|
/// MoonBit port of the H.264 in-loop deblocking filter from FFmpeg 9.0.2:
/// `libavcodec/h264dsp_template.c` (`h264_loop_filter_luma{,_intra}` and
/// `h264_loop_filter_chroma{,_intra}`) plus the edge-strength derivation of
/// `libavcodec/h264_loopfilter.c` (`filter_mb_dir` / `ff_h264_filter_mb`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2003-2011
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Scope: the slice decoder only produces progressive, frame-coded, intra-only
/// 8-bit 4:2:0 pictures, which collapses `ff_h264_filter_mb` to:
///   * every macroblock is intra, so bS is 4 on macroblock edges and 3 on the
///     internal edges (`ff_h264_filter_mb` raises 3 to 4 for progressive
///     content), and all four bS values of an edge are equal — the kernels
///     therefore take a single `tc0` instead of the C `int8_t tc[4]`;
///   * no MBAFF / field coding, so `check_mv`, `mvy_limit`, `MB_FIELD` splits
///     and the `filter_mb_mbaff_*` kernels are not ported;
///   * no 8x8DCT, so `deblock_edge` is always true and the per-edge
///     `mb_type & (edge<<24)` flags are never consulted;
///   * `disable_deblocking_filter_idc == 2` means "filter slice boundaries
///     only", which for the single-slice pictures we accept filters nothing.
///
/// The kernels take explicit `xstep`/`ystep` so that one implementation covers
/// both directions, mirroring the C template: `xstep = 1, ystep = stride` for a
/// vertical edge (the C `h264_*_loop_filter_luma`) and `xstep = stride,
/// ystep = 1` for a horizontal one (the C `h264_v_loop_filter_luma`).

///| `av_clip(v, min, max)`. */
fn h264_deblock_clip(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///| `av_clip_pixel` for 8-bit samples. */
fn h264_deblock_clip_pixel(v : Int) -> Int {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///| `FFABS`. */
fn h264_deblock_abs(v : Int) -> Int {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// `h264_loop_filter_luma`: `tc0 < 0` skips the whole group (bS == 0).
/// `along` is the C `inner_iters` (4 for the 16-sample luma edge, 2 for the
/// 8-sample chroma edge).
fn h264_lf_luma(
  data : Array[Int],
  start : Int,
  xstep : Int,
  ystep : Int,
  along : Int,
  alpha : Int,
  beta : Int,
  tc0 : Int,
) -> Unit {
  let mut p = start
  for _i = 0; _i < 4; _i = _i + 1 {
    if tc0 < 0 {
      p = p + along * ystep
    } else {
      for _d = 0; _d < along; _d = _d + 1 {
        let p0 = data[p - xstep]
        let p1 = data[p - 2 * xstep]
        let p2 = data[p - 3 * xstep]
        let q0 = data[p]
        let q1 = data[p + xstep]
        let q2 = data[p + 2 * xstep]
        if h264_deblock_abs(p0 - q0) < alpha &&
          h264_deblock_abs(p1 - p0) < beta && h264_deblock_abs(q1 - q0) < beta {
          let mut tc = tc0
          if h264_deblock_abs(p2 - p0) < beta {
            if tc0 != 0 {
              data[p - 2 * xstep] = h264_deblock_clip_pixel(
                p1 +
                h264_deblock_clip(
                  ((p2 + ((p0 + q0 + 1) >> 1)) >> 1) - p1,
                  -tc0,
                  tc0,
                ),
              )
            }
            tc = tc + 1
          }
          if h264_deblock_abs(q2 - q0) < beta {
            if tc0 != 0 {
              data[p + xstep] = h264_deblock_clip_pixel(
                q1 +
                h264_deblock_clip(
                  ((q2 + ((p0 + q0 + 1) >> 1)) >> 1) - q1,
                  -tc0,
                  tc0,
                ),
              )
            }
            tc = tc + 1
          }
          let i_delta = h264_deblock_clip(
            (((q0 - p0) * 4) + (p1 - q1) + 4) >> 3,
            -tc,
            tc,
          )
          data[p - xstep] = h264_deblock_clip_pixel(p0 + i_delta)
          data[p] = h264_deblock_clip_pixel(q0 - i_delta)
        }
        p = p + ystep
      }
    }
  }
}

///| `h264_loop_filter_luma_intra`: the bS == 4 (strong) intra edge filter. */
fn h264_lf_luma_intra(
  data : Array[Int],
  start : Int,
  xstep : Int,
  ystep : Int,
  along : Int,
  alpha : Int,
  beta : Int,
) -> Unit {
  let mut p = start
  for _d = 0; _d < 4 * along; _d = _d + 1 {
    let p1 = data[p - 2 * xstep]
    let p0 = data[p - xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if h264_deblock_abs(p0 - q0) < alpha &&
      h264_deblock_abs(p1 - p0) < beta && h264_deblock_abs(q1 - q0) < beta {
      let p2 = data[p - 3 * xstep]
      let q2 = data[p + 2 * xstep]
      if h264_deblock_abs(p0 - q0) < ((alpha >> 2) + 2) {
        if h264_deblock_abs(p2 - p0) < beta {
          let p3 = data[p - 4 * xstep]
          data[p - xstep] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
          data[p - 2 * xstep] = (p2 + p1 + p0 + q0 + 2) >> 2
          data[p - 3 * xstep] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3
        } else {
          data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
        }
        if h264_deblock_abs(q2 - q0) < beta {
          let q3 = data[p + 3 * xstep]
          data[p] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3
          data[p + xstep] = (p0 + q0 + q1 + q2 + 2) >> 2
          data[p + 2 * xstep] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3
        } else {
          data[p] = (2 * q1 + q0 + p1 + 2) >> 2
        }
      } else {
        data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
        data[p] = (2 * q1 + q0 + p1 + 2) >> 2
      }
    }
    p = p + ystep
  }
}

///|
/// `h264_loop_filter_chroma`: `tc` is already `tc0_table[index][bS] + 1`, and a
/// non-positive value skips the group (`tc0_table` uses -1 for bS == 0).
fn h264_lf_chroma(
  data : Array[Int],
  start : Int,
  xstep : Int,
  ystep : Int,
  along : Int,
  alpha : Int,
  beta : Int,
  tc : Int,
) -> Unit {
  let mut p = start
  for _i = 0; _i < 4; _i = _i + 1 {
    if tc <= 0 {
      p = p + along * ystep
    } else {
      for _d = 0; _d < along; _d = _d + 1 {
        let p0 = data[p - xstep]
        let p1 = data[p - 2 * xstep]
        let q0 = data[p]
        let q1 = data[p + xstep]
        if h264_deblock_abs(p0 - q0) < alpha &&
          h264_deblock_abs(p1 - p0) < beta && h264_deblock_abs(q1 - q0) < beta {
          let delta = h264_deblock_clip(
            ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3,
            -tc,
            tc,
          )
          data[p - xstep] = h264_deblock_clip_pixel(p0 + delta)
          data[p] = h264_deblock_clip_pixel(q0 - delta)
        }
        p = p + ystep
      }
    }
  }
}

///| `h264_loop_filter_chroma_intra`: the bS == 4 chroma edge filter. */
fn h264_lf_chroma_intra(
  data : Array[Int],
  start : Int,
  xstep : Int,
  ystep : Int,
  along : Int,
  alpha : Int,
  beta : Int,
) -> Unit {
  let mut p = start
  for _d = 0; _d < 4 * along; _d = _d + 1 {
    let p0 = data[p - xstep]
    let p1 = data[p - 2 * xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if h264_deblock_abs(p0 - q0) < alpha &&
      h264_deblock_abs(p1 - p0) < beta && h264_deblock_abs(q1 - q0) < beta {
      data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
      data[p] = (2 * q1 + q0 + p1 + 2) >> 2
    }
    p = p + ystep
  }
}

///|
/// One filtered edge: the C `filter_mb_edge{v,h}` / `filter_mb_edgec{v,h}`
/// with `intra` telling whether the strong (bS == 4) kernel may be used.
fn h264_filter_edge(
  data : Array[Int],
  start : Int,
  stride : Int,
  along : Int,
  qp : Int,
  a : Int,
  b : Int,
  bs : Int,
  intra : Bool,
  chroma : Bool,
  vertical : Bool,
) -> Unit {
  let index_a = qp + a
  let index_b = qp + b
  if index_a < 0 || index_a >= h264_alpha_table.length() || index_b < 0 ||
    index_b >= h264_beta_table.length() {
    return
  }
  let alpha = h264_alpha_table[index_a]
  let beta = h264_beta_table[index_b]
  if alpha == 0 || beta == 0 {
    return
  }
  let xstep = if vertical { 1 } else { stride }
  let ystep = if vertical { stride } else { 1 }
  if intra && bs >= 4 {
    if chroma {
      h264_lf_chroma_intra(data, start, xstep, ystep, along, alpha, beta)
    } else {
      h264_lf_luma_intra(data, start, xstep, ystep, along, alpha, beta)
    }
  } else {
    let raw = h264_tc0_table[4 * index_a + bs]
    let tc = if chroma { raw + 1 } else { raw }
    if chroma {
      h264_lf_chroma(data, start, xstep, ystep, along, alpha, beta, tc)
    } else {
      h264_lf_luma(data, start, xstep, ystep, along, alpha, beta, tc)
    }
  }
}

///|
/// `ff_h264_filter_mb` restricted to intra-only progressive pictures: filter
/// the left macroblock edge and the internal vertical edges (`dir == 0`), then
/// the top edge and the internal horizontal edges (`dir == 1`), in exactly the
/// order the C code calls `filter_mb_dir`.
fn h264_filter_mb(
  ctx : H264DecCtx,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  a : Int,
  b : Int,
) -> Unit {
  let pps = ctx.pps
  let qp = ctx.infos[mb_idx].qp
  let cqp0 = h264_get_chroma_qp(pps, 0, qp)
  let cqp1 = h264_get_chroma_qp(pps, 1, qp)
  let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
  let cbase = mb_y * 8 * ctx.cstride + mb_x * 8
  // --- dir == 0: vertical edges (left macroblock edge, then 4/8/12)
  if mb_x > 0 {
    let nqp = ctx.infos[mb_idx - 1].qp
    let qp_avg = (qp + nqp + 1) >> 1
    let c0_avg = (cqp0 + h264_get_chroma_qp(pps, 0, nqp) + 1) >> 1
    let c1_avg = (cqp1 + h264_get_chroma_qp(pps, 1, nqp) + 1) >> 1
    h264_filter_edge(ctx.y, ybase, ctx.ystride, 4, qp_avg, a, b, 4, true, false, true)
    h264_filter_edge(ctx.u, cbase, ctx.cstride, 2, c0_avg, a, b, 4, true, true, true)
    h264_filter_edge(ctx.v, cbase, ctx.cstride, 2, c1_avg, a, b, 4, true, true, true)
  }
  for edge = 1; edge < 4; edge = edge + 1 {
    h264_filter_edge(
      ctx.y, ybase + 4 * edge, ctx.ystride, 4, qp, a, b, 3, false, false, true,
    )
    if edge % 2 == 0 {
      h264_filter_edge(
        ctx.u, cbase + 2 * edge, ctx.cstride, 2, cqp0, a, b, 3, false, true, true,
      )
      h264_filter_edge(
        ctx.v, cbase + 2 * edge, ctx.cstride, 2, cqp1, a, b, 3, false, true, true,
      )
    }
  }
  // --- dir == 1: horizontal edges (top macroblock edge, then 4/8/12 rows)
  if mb_y > 0 {
    let nqp = ctx.infos[mb_idx - ctx.mb_width].qp
    let qp_avg = (qp + nqp + 1) >> 1
    let c0_avg = (cqp0 + h264_get_chroma_qp(pps, 0, nqp) + 1) >> 1
    let c1_avg = (cqp1 + h264_get_chroma_qp(pps, 1, nqp) + 1) >> 1
    h264_filter_edge(ctx.y, ybase, ctx.ystride, 4, qp_avg, a, b, 4, true, false, false)
    h264_filter_edge(ctx.u, cbase, ctx.cstride, 2, c0_avg, a, b, 4, true, true, false)
    h264_filter_edge(ctx.v, cbase, ctx.cstride, 2, c1_avg, a, b, 4, true, true, false)
  }
  for edge = 1; edge < 4; edge = edge + 1 {
    h264_filter_edge(
      ctx.y,
      ybase + 4 * edge * ctx.ystride,
      ctx.ystride,
      4,
      qp,
      a,
      b,
      3,
      false,
      false,
      false,
    )
    if edge % 2 == 0 {
      h264_filter_edge(
        ctx.u,
        cbase + 2 * edge * ctx.cstride,
        ctx.cstride,
        2,
        cqp0,
        a,
        b,
        3,
        false,
        true,
        false,
      )
      h264_filter_edge(
        ctx.v,
        cbase + 2 * edge * ctx.cstride,
        ctx.cstride,
        2,
        cqp1,
        a,
        b,
        3,
        false,
        true,
        false,
      )
    }
  }
}

///| `alpha_table[52*3]` (`h264_loopfilter.c`). Index is `qp + a`.
let h264_alpha_table : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 4, 4, 5, 6, 7, 8, 9, 10, 12, 13,
  15, 17, 20, 22, 25, 28, 32, 36, 40, 45, 50, 56, 63,
  71, 80, 90, 101, 113, 127, 144, 162, 182, 203, 226, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
]

///| `beta_table[52*3]`. Index is `qp + b`.
let h264_beta_table : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
  6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12,
  12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
]

///| `tc0_table[52*3][4]`, flattened row-major (index `4 * (qp + a) + bS`).
let h264_tc0_table : Array[Int] = [
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1,
  -1, 0, 0, 1, -1, 0, 1, 1, -1, 0, 1, 1, -1, 1, 1, 1,
  -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 2,
  -1, 1, 1, 2, -1, 1, 1, 2, -1, 1, 1, 2, -1, 1, 2, 3,
  -1, 1, 2, 3, -1, 2, 2, 3, -1, 2, 2, 4, -1, 2, 3, 4,
  -1, 2, 3, 4, -1, 3, 3, 5, -1, 3, 4, 6, -1, 3, 4, 6,
  -1, 4, 5, 7, -1, 4, 5, 8, -1, 4, 6, 9, -1, 5, 7, 10,
  -1, 6, 8, 11, -1, 6, 8, 13, -1, 7, 10, 14, -1, 8, 11, 16,
  -1, 9, 12, 18, -1, 10, 13, 20, -1, 11, 15, 23, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
  -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25,
]

