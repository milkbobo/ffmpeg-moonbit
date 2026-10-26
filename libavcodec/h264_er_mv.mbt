///|
/// H.264 `guess_mv` pass of FFmpeg error_resilience.c. Damaged macroblocks
/// are revisited from known neighbours toward the interior of each gap.
/// LGPL-2.1-or-later.

///|
fn h264_er_put_inter(
  ctx : H264DecCtx,
  idx : Int32,
  reference_index : Int32,
  mx : Int32,
  my : Int32,
) -> Unit {
  let ref_index = if reference_index >= 0 &&
    reference_index < ctx.ref_list0.length() {
    reference_index
  } else {
    0
  }
  let pic = ctx.ref_list0[ref_index]
  let mb_x = idx % ctx.mb_width
  let mb_y = idx / ctx.mb_width
  let cw = 16 >> ctx.chroma_hshift
  let ch = 16 >> ctx.chroma_vshift
  h264_mc_luma(
    ctx.y,
    mb_y * 16 * ctx.ystride + mb_x * 16,
    ctx.ystride,
    pic.y,
    mb_x * 16 + (mx >> 2),
    mb_y * 16 + (my >> 2),
    pic.ystride,
    16,
    16,
    mx & 3,
    my & 3,
    pic.width,
    pic.height,
    sbase=pic.base_y,
    bit_depth=ctx.bit_depth,
  )
  h264_mc_chroma(
    ctx.u,
    mb_y * ch * ctx.cstride + mb_x * cw,
    ctx.cstride,
    pic.u,
    mb_x * cw,
    mb_y * ch,
    mx,
    my,
    pic.cstride,
    cw,
    ch,
    pic.cwidth,
    pic.cheight,
    sbase=pic.base_u,
    vshift=ctx.chroma_vshift,
  )
  h264_mc_chroma(
    ctx.v,
    mb_y * ch * ctx.cstride + mb_x * cw,
    ctx.cstride,
    pic.v,
    mb_x * cw,
    mb_y * ch,
    mx,
    my,
    pic.cstride,
    cw,
    ch,
    pic.cwidth,
    pic.cheight,
    sbase=pic.base_v,
    vshift=ctx.chroma_vshift,
  )
  // `h264_er_decode_mb` reconstructs through `ff_h264_hl_decode_mb`, whose
  // single-list path always runs `luma_weight_op` and, when
  // `use_weight_chroma` is set, `chroma_weight_op`. Weighted prediction is
  // therefore part of concealment too: skipping it silently drops the Cr
  // offset when only chroma weights are non-neutral.
  if ctx.pwt.use_weight != 0 {
    h264_weight_rect(
      ctx.y,
      mb_y * 16 * ctx.ystride + mb_x * 16,
      ctx.ystride,
      16,
      16,
      ctx.pwt.luma_log2_weight_denom,
      ctx.pwt.luma_weight_l0[ref_index],
      ctx.pwt.luma_offset_l0[ref_index],
      bit_depth=ctx.bit_depth,
    )
    if ctx.pwt.use_weight_chroma != 0 {
      for c = 0; c < 2; c = c + 1 {
        h264_weight_rect(
          if c == 0 {
            ctx.u
          } else {
            ctx.v
          },
          mb_y * ch * ctx.cstride + mb_x * cw,
          ctx.cstride,
          cw,
          ch,
          ctx.pwt.chroma_log2_weight_denom,
          ctx.pwt.chroma_weight_l0[ref_index][c],
          ctx.pwt.chroma_offset_l0[ref_index][c],
          bit_depth=ctx.bit_depth,
        )
      }
    }
  }
  let info = ctx.infos[idx]
  info.mb_type_bits = h264_mb_type_16x16 | h264_mb_type_p0l0
  for block = 0; block < 16; block = block + 1 {
    info.ref_idx[block] = ref_index
    info.ref_identity[block] = pic.identity
    info.mv[block * 2] = mx
    info.mv[block * 2 + 1] = my
  }
}

///|
fn h264_er_neighbor_indices(ctx : H264DecCtx, idx : Int32) -> Array[Int32] {
  let x = idx % ctx.mb_width
  let y = idx / ctx.mb_width
  let out : Array[Int32] = []
  if x > 0 {
    out.push(idx - 1)
  }
  if x + 1 < ctx.mb_width {
    out.push(idx + 1)
  }
  if y > 0 {
    out.push(idx - ctx.mb_width)
  }
  if y + 1 < ctx.mb_height {
    out.push(idx + ctx.mb_width)
  }
  out
}

///|
fn h264_er_border_score(
  ctx : H264DecCtx,
  fixed : Array[Int32],
  idx : Int32,
) -> Int32 {
  let x = idx % ctx.mb_width
  let y = idx / ctx.mb_width
  let stride = ctx.ystride
  let base = y * 16 * stride + x * 16
  let mut score = 0
  if x > 0 && fixed[idx - 1] > 1 {
    for k = 0; k < 16; k = k + 1 {
      score += h264_er_abs(
        ctx.y[base + k * stride - 1] - ctx.y[base + k * stride],
      )
    }
  }
  if x + 1 < ctx.mb_width && fixed[idx + 1] > 1 {
    for k = 0; k < 16; k = k + 1 {
      score += h264_er_abs(
        ctx.y[base + k * stride + 15] - ctx.y[base + k * stride + 16],
      )
    }
  }
  if y > 0 && fixed[idx - ctx.mb_width] > 1 {
    for k = 0; k < 16; k = k + 1 {
      score += h264_er_abs(ctx.y[base + k - stride] - ctx.y[base + k])
    }
  }
  if y + 1 < ctx.mb_height && fixed[idx + ctx.mb_width] > 1 {
    for k = 0; k < 16; k = k + 1 {
      score += h264_er_abs(
        ctx.y[base + k + 15 * stride] - ctx.y[base + k + 16 * stride],
      )
    }
  }
  score
}

///|
fn h264_er_add_neighbors(
  ctx : H264DecCtx,
  fixed : Array[Int32],
  list : Array[Int32],
  idx : Int32,
) -> Unit {
  for neighbor in h264_er_neighbor_indices(ctx, idx) {
    if fixed[neighbor] == 0 {
      fixed[neighbor] = 1
      list.push(neighbor)
    }
  }
}

///|
fn h264_er_guess_mv_picture(
  ctx : H264DecCtx,
  status : Array[Int32],
  er_previous_infos~ : Array[H264MbInfo]? = None,
) -> Unit {
  let count = ctx.infos.length()
  let fixed = Array::make(count, 0)
  let mut available = 0
  for idx = 0; idx < count; idx = idx + 1 {
    let info = ctx.infos[idx]
    if h264_is_intra_type(info.mb_type_bits) || (status[idx] & 8) == 0 {
      fixed[idx] = 8
      available += 1
    } else {
      match er_previous_infos {
        Some(previous) if idx < previous.length() => {
          info.mv[0] = previous[idx].mv[0]
          info.mv[1] = previous[idx].mv[1]
          info.ref_idx[0] = previous[idx].ref_idx[0].max(0)
        }
        _ => ()
      }
    }
  }
  if available <= ctx.mb_width.max(ctx.mb_height) / 2 {
    for idx = 0; idx < count; idx = idx + 1 {
      if fixed[idx] != 8 {
        h264_er_put_inter(ctx, idx, 0, 0, 0)
      }
    }
    return
  }
  let mut blocklist : Array[Int32] = []
  for idx = 0; idx < count; idx = idx + 1 {
    if fixed[idx] == 8 {
      h264_er_add_neighbors(ctx, fixed, blocklist, idx)
    }
  }
  while !blocklist.is_empty() {
    let mut changed = true
    let mut none_left = true
    for pass = 0; pass < 10 && (changed || pass < 2); pass = pass + 1 {
      changed = false
      for idx in blocklist {
        let x = idx % ctx.mb_width
        let y = idx / ctx.mb_width
        if ((x ^ y ^ pass) & 1) != 0 {
          continue
        }
        let neighbors = h264_er_neighbor_indices(ctx, idx)
        let mut flags = 0
        for neighbor in neighbors {
          flags = flags | fixed[neighbor]
        }
        if (flags & 4) == 0 && pass > 1 {
          continue
        }
        none_left = false
        let candidates : Array[(Int32, Int32, Int32)] = []
        for neighbor in neighbors {
          if fixed[neighbor] > 1 {
            let info = ctx.infos[neighbor]
            candidates.push((info.mv[0], info.mv[1], info.ref_idx[0]))
          }
        }
        if candidates.is_empty() {
          continue
        }
        let original_count = candidates.length()
        if original_count > 1 {
          let mut same_reference = true
          let mut sum_x = 0
          let mut sum_y = 0
          let mut sum_ref = 0
          for j, candidate in candidates {
            sum_x += candidate.0
            sum_y += candidate.1
            sum_ref += candidate.2
            if j > 0 && candidate.2 != candidates[j - 1].2 {
              same_reference = false
            }
          }
          if same_reference {
            candidates.push(
              (
                sum_x / original_count,
                sum_y / original_count,
                sum_ref / original_count,
              ),
            )
            let mut min_x = if original_count >= 3 { 99999 } else { 0 }
            let mut min_y = min_x
            let mut min_ref = min_x
            let mut max_x = if original_count >= 3 { -99999 } else { 0 }
            let mut max_y = max_x
            let mut max_ref = max_x
            for j = 0; j < original_count; j = j + 1 {
              let candidate = candidates[j]
              min_x = min_x.min(candidate.0)
              min_y = min_y.min(candidate.1)
              min_ref = min_ref.min(candidate.2)
              max_x = max_x.max(candidate.0)
              max_y = max_y.max(candidate.1)
              max_ref = max_ref.max(candidate.2)
            }
            let divisor = if original_count == 4 { 2 } else { 1 }
            candidates.push(
              (
                (sum_x - max_x - min_x) / divisor,
                (sum_y - max_y - min_y) / divisor,
                (sum_ref - max_ref - min_ref) / divisor,
              ),
            )
          }
        }
        candidates.push((0, 0, 0))
        let previous = ctx.infos[idx]
        let previous_x = previous.mv[0]
        let previous_y = previous.mv[1]
        let previous_ref = if previous.ref_idx[0] >= 0 {
          previous.ref_idx[0]
        } else {
          0
        }
        candidates.push((previous_x, previous_y, previous_ref))
        let mut best_score = 2147483647
        let mut best = (0, 0, 0)
        for candidate in candidates {
          if candidate.2 < 0 {
            continue
          }
          h264_er_put_inter(ctx, idx, candidate.2, candidate.0, candidate.1)
          let score = h264_er_border_score(ctx, fixed, idx)
          if score <= best_score {
            best_score = score
            best = candidate
          }
        }
        h264_er_put_inter(ctx, idx, best.2, best.0, best.1)
        if best.0 != previous_x || best.1 != previous_y {
          fixed[idx] = 4
          changed = true
        } else {
          fixed[idx] = 2
        }
      }
    }
    if none_left {
      return
    }
    let next : Array[Int32] = []
    for idx in blocklist {
      if fixed[idx] >= 2 {
        fixed[idx] = 8
        h264_er_add_neighbors(ctx, fixed, next, idx)
      }
    }
    blocklist = next
  }
  // Interior MBs with no reachable valid neighbour use zero MV.
  for idx = 0; idx < count; idx = idx + 1 {
    if fixed[idx] == 0 {
      h264_er_put_inter(ctx, idx, 0, 0, 0)
    }
  }
}
