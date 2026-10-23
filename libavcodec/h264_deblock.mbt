///|
/// MoonBit port of the H.264 in-loop deblocking filter from FFmpeg 9.0.2:
/// `libavcodec/h264dsp_template.c` (`h264_loop_filter_luma{,_intra}` and
/// `h264_loop_filter_chroma{,_intra}`) plus the edge-strength derivation of
/// `libavcodec/h264_loopfilter.c` (`filter_mb_dir` / `ff_h264_filter_mb`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2003-2011
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Scope: progressive and homogeneous MBAFF frame pictures, 8..14-bit
/// 4:0:0/4:2:0/4:2:2/4:4:4 I/P/B:
///   * intra macroblocks use bS 4 on macroblock edges (3 for a field MB's top
///     edge) and 3 on internal edges; inter macroblocks derive bS per 4x4
///     block (2 for non-zero coefficients, 1 for reference or motion-vector
///     differences) and compare reference indices through the `ref2frm`
///     identity (frame MBs `4*id+3`, field MBs `4*id+{1,2}`);
///   * chroma edges reuse the four luma bS values, each controlling two
///     chroma samples (`tc0_table[..][bS[i]] + 1`);
///   * MBAFF field MBs use doubled strides and field reference views;
///     mixed field/frame MB pairs use the corrected top/topleft/topright
///     neighbour indices and `ref2frm` field ids;
///   * 8x8DCT skips the internal odd luma edges (`4:2:2` still filters the
///     corresponding chroma), matching `mb_type & (edge << 24)`. The port's
///     `H264MbInfo.transform_8x8` carries that bit;
///   * `disable_deblocking_filter_idc == 2` means "filter slice boundaries
///     only", which for the single-slice pictures we accept filters nothing.
///
/// The kernels take explicit `xstep`/`ystep` so that one implementation covers
/// both directions, mirroring the C template: `xstep = 1, ystep = stride` for a
/// vertical edge (the C `h264_*_loop_filter_luma`) and `xstep = stride,
/// ystep = 1` for a horizontal one (the C `h264_v_loop_filter_luma`).

///|
/// `av_clip(v, min, max)`. */
fn h264_deblock_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// `av_clip_pixel` for 8-bit samples. */
fn h264_deblock_clip_pixel(v : Int32, bit_depth~ : Int32 = 8) -> Int32 {
  if v < 0 {
    0
  } else if v > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    v
  }
}

///|
/// `FFABS`. */
fn h264_deblock_abs(v : Int32) -> Int32 {
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
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc0 : Int32,
  bit_depth~ : Int32 = 8,
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
          h264_deblock_abs(p1 - p0) < beta &&
          h264_deblock_abs(q1 - q0) < beta {
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
                bit_depth~,
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
                bit_depth~,
              )
            }
            tc = tc + 1
          }
          let i_delta = h264_deblock_clip(
            ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3,
            -tc,
            tc,
          )
          data[p - xstep] = h264_deblock_clip_pixel(p0 + i_delta, bit_depth~)
          data[p] = h264_deblock_clip_pixel(q0 - i_delta, bit_depth~)
        }
        p = p + ystep
      }
    }
  }
}

///|
/// `h264_loop_filter_luma_intra`: the bS == 4 (strong) intra edge filter. */
fn h264_lf_luma_intra(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  // Strong filtering uses convex averages; the result stays in the input range.
  ignore(bit_depth)
  let mut p = start
  for _d = 0; _d < 4 * along; _d = _d + 1 {
    let p1 = data[p - 2 * xstep]
    let p0 = data[p - xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if h264_deblock_abs(p0 - q0) < alpha &&
      h264_deblock_abs(p1 - p0) < beta &&
      h264_deblock_abs(q1 - q0) < beta {
      let p2 = data[p - 3 * xstep]
      let q2 = data[p + 2 * xstep]
      if h264_deblock_abs(p0 - q0) < (alpha >> 2) + 2 {
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
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc : Int32,
  bit_depth~ : Int32 = 8,
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
          h264_deblock_abs(p1 - p0) < beta &&
          h264_deblock_abs(q1 - q0) < beta {
          let delta = h264_deblock_clip(
            ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3,
            -tc,
            tc,
          )
          data[p - xstep] = h264_deblock_clip_pixel(p0 + delta, bit_depth~)
          data[p] = h264_deblock_clip_pixel(q0 - delta, bit_depth~)
        }
        p = p + ystep
      }
    }
  }
}

///|
/// `h264_loop_filter_chroma_intra`: the bS == 4 chroma edge filter. */
fn h264_lf_chroma_intra(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  // Strong filtering uses convex averages; the result stays in the input range.
  ignore(bit_depth)
  let mut p = start
  for _d = 0; _d < 4 * along; _d = _d + 1 {
    let p0 = data[p - xstep]
    let p1 = data[p - 2 * xstep]
    let q0 = data[p]
    let q1 = data[p + xstep]
    if h264_deblock_abs(p0 - q0) < alpha &&
      h264_deblock_abs(p1 - p0) < beta &&
      h264_deblock_abs(q1 - q0) < beta {
      data[p - xstep] = (2 * p1 + p0 + q1 + 2) >> 2
      data[p] = (2 * q1 + q0 + p1 + 2) >> 2
    }
    p = p + ystep
  }
}

///|
/// `filter_mb_edgec{v,h}`: the chroma edge uses the same four luma bS values,
/// each controlling two chroma samples (`tc0_table[..][bS[i]] + 1`).
fn h264_filter_chroma_edge(
  data : Array[Int32],
  start : Int32,
  stride : Int32,
  qp : Int32,
  a : Int32,
  b : Int32,
  bs : Array[Int32],
  intra : Bool,
  vertical : Bool,
  group~ : Int32 = 2,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let shift = bit_depth - 8
  let index_a = qp + a - 6 * shift
  let index_b = qp + b - 6 * shift
  if index_a < 0 ||
    index_a >= h264_alpha_table.length() ||
    index_b < 0 ||
    index_b >= h264_beta_table.length() {
    return
  }
  let alpha = h264_alpha_table[index_a] << shift
  let beta = h264_beta_table[index_b] << shift
  if alpha == 0 || beta == 0 {
    return
  }
  let xstep = if vertical { 1 } else { stride }
  let ystep = if vertical { stride } else { 1 }
  if intra && bs[0] >= 4 {
    // `h264_h_loop_filter_chroma422_intra` extends the kernel to 16 rows
    // via `inner_iters` = 4; `group` carries that width.
    h264_lf_chroma_intra(
      data,
      start,
      xstep,
      ystep,
      group,
      alpha,
      beta,
      bit_depth~,
    )
    return
  }
  let mut p = start
  for i = 0; i < 4; i = i + 1 {
    let tc = if bs[i] > 0 {
      (h264_tc0_table[4 * index_a + bs[i]] << shift) + 1
    } else {
      0
    }
    if tc <= 0 {
      p = p + group * ystep
    } else {
      for _d = 0; _d < group; _d = _d + 1 {
        let p0 = data[p - xstep]
        let p1 = data[p - 2 * xstep]
        let q0 = data[p]
        let q1 = data[p + xstep]
        if h264_deblock_abs(p0 - q0) < alpha &&
          h264_deblock_abs(p1 - p0) < beta &&
          h264_deblock_abs(q1 - q0) < beta {
          let delta = h264_deblock_clip(
            ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3,
            -tc,
            tc,
          )
          data[p - xstep] = h264_deblock_clip_pixel(p0 + delta, bit_depth~)
          data[p] = h264_deblock_clip_pixel(q0 - delta, bit_depth~)
        }
        p = p + ystep
      }
    }
  }
}

///|
/// One filtered edge: the C `filter_mb_edge{v,h}` / `filter_mb_edgec{v,h}`
/// with `intra` telling whether the strong (bS == 4) kernel may be used.
fn h264_filter_edge(
  data : Array[Int32],
  start : Int32,
  stride : Int32,
  along : Int32,
  qp : Int32,
  a : Int32,
  b : Int32,
  bs : Int32,
  intra : Bool,
  chroma : Bool,
  vertical : Bool,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let shift = bit_depth - 8
  let index_a = qp + a - 6 * shift
  let index_b = qp + b - 6 * shift
  if index_a < 0 ||
    index_a >= h264_alpha_table.length() ||
    index_b < 0 ||
    index_b >= h264_beta_table.length() {
    return
  }
  let alpha = h264_alpha_table[index_a] << shift
  let beta = h264_beta_table[index_b] << shift
  if alpha == 0 || beta == 0 {
    return
  }
  let xstep = if vertical { 1 } else { stride }
  let ystep = if vertical { stride } else { 1 }
  if intra && bs >= 4 {
    if chroma {
      h264_lf_chroma_intra(
        data,
        start,
        xstep,
        ystep,
        along,
        alpha,
        beta,
        bit_depth~,
      )
    } else {
      h264_lf_luma_intra(
        data,
        start,
        xstep,
        ystep,
        along,
        alpha,
        beta,
        bit_depth~,
      )
    }
  } else {
    let raw = h264_tc0_table[4 * index_a + bs]
    let tc = if chroma { (raw << shift) + 1 } else { raw << shift }
    if chroma {
      h264_lf_chroma(
        data,
        start,
        xstep,
        ystep,
        along,
        alpha,
        beta,
        tc,
        bit_depth~,
      )
    } else {
      h264_lf_luma(
        data,
        start,
        xstep,
        ystep,
        along,
        alpha,
        beta,
        tc,
        bit_depth~,
      )
    }
  }
}

///|
/// `ff_h264_filter_mb` restricted to intra-only progressive pictures: filter
/// the left macroblock edge and the internal vertical edges (`dir == 0`), then
/// the top edge and the internal horizontal edges (`dir == 1`), in exactly the
/// order the C code calls `filter_mb_dir`.

///| Deblock-side neighbour block info: intra flag, luma nz, ref and mv of

///| the 4x4 block at macroblock-relative coordinates (may cross into the

///|
/// left/top macroblocks). Intra blocks keep the constructor ref/mv (-2, 0).
fn h264_deblock_block(
  ctx : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
) -> (Bool, Int32, Int32, Int32, Int32) {
  let ax = mb_x * 4 + bx
  let ay = mb_y * 4 + by
  // Field-coded MBs reach the same-parity MB two frame rows up (`top_xy =
  // mb_xy - (mb_stride << MB_FIELD)`), not the MB of the adjacent line.
  let nmb = if ctx.mb_field && by < 0 {
    (mb_y - 2) * ctx.mb_width + ax / 4
  } else if ctx.mb_field {
    mb_y * ctx.mb_width + ax / 4
  } else {
    ay / 4 * ctx.mb_width + ax / 4
  }
  let info = ctx.infos[nmb]
  let idx = ay % 4 * 4 + ax % 4
  // CAVLC stores four entropy counts, with their sum in the 8x8 leader.
  // The deblock cache expands the actual 8x8 coefficient presence to all
  // four 4x4 locations; entropy counts themselves must remain unchanged.
  let nz_idx = if info.transform_8x8 { (idx & 8) + (idx & 2) } else { idx }
  (
    h264_is_intra_type(info.mb_type_bits),
    info.nz[nz_idx],
    info.ref_identity[idx],
    info.mv[2 * idx],
    info.mv[2 * idx + 1],
  )
}

///|
/// bS for one 4x4 block pair across an edge (spec 8.7.2.3, frame pictures):
/// 4/3 when either side is intra (macroblock edge / inner edge), 3 when any
/// coefficient is present, 1 for different references, 2/1 by the motion
/// vector difference (quarter-pel thresholds 4 and 1), 0 otherwise.
fn h264_bs_pair(
  ctx : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  pxy : (Int32, Int32),
  qxy : (Int32, Int32),
  mb_edge : Bool,
  vertical : Bool,
) -> Int32 {
  let (pintra, pnz, _, _, _) = h264_deblock_block(ctx, mb_x, mb_y, pxy.0, pxy.1)
  let (qintra, qnz, _, _, _) = h264_deblock_block(ctx, mb_x, mb_y, qxy.0, qxy.1)
  if pintra || qintra {
    // `filter_mb_dir`: the MB edge is bS 4 for progressive pictures and for
    // the vertical edge of field MBs; a field MB's top edge stays at 3.
    if !mb_edge {
      3
    } else if vertical || !ctx.mb_field {
      4
    } else {
      3
    }
  } else if pnz > 0 || qnz > 0 {
    2
  } else {
    // `fill_filter_caches` maps each ref index through `ref2frm`, so two
    // indices that name the same picture (reordered/duplicated lists) compare
    // equal.
    let p = h264_deblock_lists(ctx, mb_x, mb_y, pxy.0, pxy.1)
    let q = h264_deblock_lists(ctx, mb_x, mb_y, qxy.0, qxy.1)
    let limit = if ctx.mb_field { 2 } else { 4 }
    let same = h264_deblock_match(p[0], q[0], limit~) &&
      h264_deblock_match(p[1], q[1], limit~)
    let swapped = h264_deblock_match(p[0], q[1], limit~) &&
      h264_deblock_match(p[1], q[0], limit~)
    if same || swapped {
      0
    } else {
      1
    }
  }
}

///|
fn h264_deblock_lists(
  ctx : H264DecCtx,
  mx : Int32,
  my : Int32,
  bx : Int32,
  by : Int32,
) -> Array[(Int32, Int32, Int32)] {
  let ax = mx * 4 + bx
  let ay = my * 4 + by
  let nmb = if ctx.mb_field && by < 0 {
    (my - 2) * ctx.mb_width + ax / 4
  } else if ctx.mb_field {
    my * ctx.mb_width + ax / 4
  } else {
    ay / 4 * ctx.mb_width + ax / 4
  }
  let info = ctx.infos[nmb]
  let index = ay % 4 * 4 + ax % 4
  [
    (
      if info.ref_idx[index] >= 0 {
        info.ref_identity[index]
      } else {
        -1
      },
      info.mv[2 * index],
      info.mv[2 * index + 1],
    ),
    (
      if info.ref_idx1[index] >= 0 {
        info.ref_identity1[index]
      } else {
        -1
      },
      info.mv1[2 * index],
      info.mv1[2 * index + 1],
    ),
  ]
}

///|
fn h264_deblock_match(
  a : (Int32, Int32, Int32),
  b : (Int32, Int32, Int32),
  limit~ : Int32 = 4,
) -> Bool {
  // `check_mv`: horizontal threshold is always 4 quarter-pels, vertical uses
  // `mvy_limit` (2 for field MBs, 4 otherwise).
  a.0 == b.0 && (a.1 - b.1).abs() < 4 && (a.2 - b.2).abs() < limit
}

///|
/// The four bS values of one luma edge: `vertical` selects the vertical
/// edges (blocks left/right of the edge), `edge` is 0 (macroblock edge) to 3.
fn h264_bs_edge(
  ctx : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  vertical : Bool,
  edge : Int32,
) -> Array[Int32] {
  let bs : Array[Int32] = [0, 0, 0, 0]
  for s = 0; s < 4; s = s + 1 {
    bs[s] = if vertical {
      h264_bs_pair(ctx, mb_x, mb_y, (edge - 1, s), (edge, s), edge == 0, true)
    } else {
      h264_bs_pair(ctx, mb_x, mb_y, (s, edge - 1), (s, edge), edge == 0, false)
    }
  }
  bs
}

///|
/// Filter one luma/chroma edge segment-by-segment when the picture has
/// inter macroblocks: each 4-sample segment takes its own bS. Intra edges
/// keep the whole-edge strong/bs=3 paths of `h264_filter_edge`.
fn h264_filter_mb(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  a : Int32,
  b : Int32,
) -> Unit {
  let pps = ctx.pps
  let qp = ctx.infos[mb_idx].qp
  ctx.mb_field = ctx.infos[mb_idx].field_mb
  let cqp0 = h264_get_chroma_qp(pps, 0, qp, bit_depth=ctx.bit_depth)
  let cqp1 = h264_get_chroma_qp(pps, 1, qp, bit_depth=ctx.bit_depth)
  let ystride = h264_mb_ystride(ctx)
  let cstride = h264_mb_cstride(ctx)
  let ybase = h264_mb_ybase(ctx, mb_x, mb_y)
  let cbase = h264_mb_cbase(ctx, mb_x, mb_y)
  let cur_intra = h264_is_intra_type(ctx.infos[mb_idx].mb_type_bits)
  // Vertical edges (dir == 0), then horizontal (dir == 1).
  for dir = 0; dir < 2; dir = dir + 1 {
    let vertical = dir == 0
    let ystep = if vertical { ystride } else { 1 }
    for edge = 0; edge < 4; edge = edge + 1 {
      // `deblock_edge = !IS_8x8DCT(mb_type & (edge << 24))`: odd internal
      // edges lie inside an 8x8 transform and are not filtered. 4:2:2 still
      // filters the chroma of horizontal odd edges (`!chroma422 || dir == 0`).
      let deblock_luma = !ctx.infos[mb_idx].transform_8x8 || (edge & 1) == 0
      if !deblock_luma && !(ctx.chroma_format == 2 && !vertical) {
        continue
      }
      let neigh_intra = if edge == 0 {
        if vertical {
          mb_x > 0 && h264_is_intra_type(ctx.infos[mb_idx - 1].mb_type_bits)
        } else if ctx.mb_field {
          h264_has_top(ctx, mb_idx) &&
          h264_is_intra_type(
            ctx.infos[h264_top_index(ctx, mb_idx)].mb_type_bits,
          )
        } else {
          mb_y > 0 &&
          h264_is_intra_type(ctx.infos[mb_idx - ctx.mb_width].mb_type_bits)
        }
      } else {
        false
      }
      let at_border = if vertical {
        edge == 0 && mb_x == 0
      } else {
        edge == 0 && (mb_y == 0 || (ctx.mb_field && mb_y == 1))
      }
      if at_border {
        continue
      }
      if edge == 0 && ctx.infos[mb_idx].deblock_idc == 2 {
        let neighbor = if vertical {
          mb_idx - 1
        } else {
          h264_top_index(ctx, mb_idx)
        }
        if ctx.infos[neighbor].slice_num != ctx.infos[mb_idx].slice_num {
          continue
        }
      }
      // Neighbour QP for the macroblock edge, own QP for inner edges.
      let neigh_qp = if edge == 0 {
        if vertical {
          ctx.infos[mb_idx - 1].qp
        } else {
          ctx.infos[h264_top_index(ctx, mb_idx)].qp
        }
      } else {
        qp
      }
      let yqp = (qp + neigh_qp + 1) >> 1
      let cq0 = (
          cqp0 +
          h264_get_chroma_qp(pps, 0, neigh_qp, bit_depth=ctx.bit_depth) +
          1
        ) >>
        1
      let cq1 = (
          cqp1 +
          h264_get_chroma_qp(pps, 1, neigh_qp, bit_depth=ctx.bit_depth) +
          1
        ) >>
        1
      let yoff = ybase + (if vertical { 4 * edge } else { 4 * edge * ystride })
      let bs = h264_bs_edge(ctx, mb_x, mb_y, vertical, edge)
      let strong = cur_intra || neigh_intra
      let mut any_bs = false
      for s = 0; s < 4; s = s + 1 {
        if bs[s] > 0 {
          any_bs = true
        }
      }
      // One whole-edge or per-segment luma filter (skipped for the odd
      // edges of a 4:2:2 8x8 macroblock, whose chroma is still filtered).
      if deblock_luma {
        if strong {
          if edge == 0 {
            h264_filter_edge(
              ctx.y,
              yoff,
              ystride,
              4,
              yqp,
              a,
              b,
              if vertical || !ctx.mb_field {
                4
              } else {
                3
              },
              true,
              false,
              vertical,
              bit_depth=ctx.bit_depth,
            )
          } else {
            h264_filter_edge(
              ctx.y,
              yoff,
              ystride,
              4,
              qp,
              a,
              b,
              3,
              false,
              false,
              vertical,
              bit_depth=ctx.bit_depth,
            )
          }
        } else if any_bs {
          for s = 0; s < 4; s = s + 1 {
            if bs[s] > 0 {
              h264_filter_edge(
                ctx.y,
                yoff + 4 * s * ystep,
                ystride,
                1,
                if edge == 0 {
                  yqp
                } else {
                  qp
                },
                a,
                b,
                bs[s],
                false,
                false,
                vertical,
                bit_depth=ctx.bit_depth,
              )
            }
          }
        }
      }
      // Chroma edges. 4:4:4 uses the luma kernels with the chroma QPs on
      // every luma-grid edge; 4:2:0/4:2:2 use the chroma kernels (tc+1)
      // on the 4x4 chroma grid — for 4:2:2 every horizontal edge and 8
      // samples of the vertical ones (`filter_mb_dir`).
      if !strong && !any_bs {
        continue
      }
      // `CHROMA(h)` is false for 4:0:0: monochrome edges only filter luma.
      if ctx.chroma_format == 0 {
        continue
      }
      if ctx.chroma_format == 3 {
        let coff = cbase +
          (if vertical { 4 * edge } else { 4 * edge * cstride })
        let cstep = if vertical { cstride } else { 1 }
        let planes = [(ctx.u, cq0, cqp0), (ctx.v, cq1, cqp1)]
        for plane_q in planes {
          let (plane, cq_avg, cq_own) = plane_q
          if strong {
            h264_filter_edge(
              plane,
              coff,
              cstride,
              4,
              if edge == 0 {
                cq_avg
              } else {
                cq_own
              },
              a,
              b,
              if edge == 0 && (vertical || !ctx.mb_field) {
                4
              } else {
                3
              },
              edge == 0,
              false,
              vertical,
              bit_depth=ctx.bit_depth,
            )
          } else {
            for s = 0; s < 4; s = s + 1 {
              if bs[s] > 0 {
                h264_filter_edge(
                  plane,
                  coff + 4 * s * cstep,
                  cstride,
                  1,
                  if edge == 0 {
                    cq_avg
                  } else {
                    cq_own
                  },
                  a,
                  b,
                  bs[s],
                  false,
                  false,
                  vertical,
                  bit_depth=ctx.bit_depth,
                )
              }
            }
          }
        }
      } else {
        // 4:2:0: edges 0/2 in both directions; 4:2:2: the same vertical
        // edges but every horizontal edge (chroma is 16 tall).
        let chroma_edge = if vertical {
          (edge & 1) == 0
        } else {
          ctx.chroma_format == 2 || (edge & 1) == 0
        }
        if chroma_edge {
          let coff = if vertical {
            cbase + 2 * edge
          } else if ctx.chroma_format == 2 {
            cbase + 4 * edge * cstride
          } else {
            cbase + 2 * edge * cstride
          }
          let group = if vertical && ctx.chroma_format == 2 { 4 } else { 2 }
          h264_filter_chroma_edge(
            ctx.u,
            coff,
            cstride,
            cq0,
            a,
            b,
            bs,
            strong,
            vertical,
            group~,
            bit_depth=ctx.bit_depth,
          )
          h264_filter_chroma_edge(
            ctx.v,
            coff,
            cstride,
            cq1,
            a,
            b,
            bs,
            strong,
            vertical,
            group~,
            bit_depth=ctx.bit_depth,
          )
        }
      }
    }
  }
}

///|
/// `alpha_table[52*3]` (`h264_loopfilter.c`). Index is `qp + a`.
let h264_alpha_table : Array[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15,
  17, 20, 22, 25, 28, 32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101, 113, 127, 144,
  162, 182, 203, 226, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
]

///|
/// `beta_table[52*3]`. Index is `qp + b`.
let h264_beta_table : Array[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7,
  7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
]

///|
/// `tc0_table[52*3][4]`, flattened row-major (index `4 * (qp + a) + bS`).
let h264_tc0_table : Array[Int32] = [
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1,
  0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0,
  0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0,
  0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1,
  0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0,
  0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0,
  0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0,
  -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1,
  0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0,
  0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0,
  0, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 1, 1, -1, 0, 1, 1,
  -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 2, -1, 1, 1, 2, -1,
  1, 1, 2, -1, 1, 1, 2, -1, 1, 2, 3, -1, 1, 2, 3, -1, 2, 2, 3, -1, 2, 2, 4, -1, 2,
  3, 4, -1, 2, 3, 4, -1, 3, 3, 5, -1, 3, 4, 6, -1, 3, 4, 6, -1, 4, 5, 7, -1, 4, 5,
  8, -1, 4, 6, 9, -1, 5, 7, 10, -1, 6, 8, 11, -1, 6, 8, 13, -1, 7, 10, 14, -1, 8,
  11, 16, -1, 9, 12, 18, -1, 10, 13, 20, -1, 11, 15, 23, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13, 17, 25, -1, 13,
  17, 25, -1, 13, 17, 25,
]
