///|
/// `h_block_filter` and `v_block_filter` of FFmpeg error_resilience.c for
/// H.264 picture planes. The ordinary in-loop filter has already completed.
/// LGPL-2.1-or-later.

///|
fn h264_er_abs(value : Int32) -> Int32 {
  if value < 0 {
    -value
  } else {
    value
  }
}

///|
fn h264_er_edge_mbs(
  ctx : H264DecCtx,
  status : Array[Int32],
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
  mb_w : Int32,
  mb_h : Int32,
) -> (Bool, Bool, Bool) {
  let a = y0 / mb_h * ctx.mb_width + x0 / mb_w
  let b = y1 / mb_h * ctx.mb_width + x1 / mb_w
  let damaged_a = (status[a] & 14) != 0
  let damaged_b = (status[b] & 14) != 0
  if !damaged_a && !damaged_b {
    return (false, false, false)
  }
  let info_a = ctx.infos[a]
  let info_b = ctx.infos[b]
  let block_a = y0 / 8 * 8 % mb_h * 4 / mb_h * 4 + x0 / 8 * 8 % mb_w * 4 / mb_w
  let block_b = y1 / 8 * 8 % mb_h * 4 / mb_h * 4 + x1 / 8 * 8 % mb_w * 4 / mb_w
  if !h264_is_intra_type(info_a.mb_type_bits) &&
    !h264_is_intra_type(info_b.mb_type_bits) &&
    h264_er_abs(info_a.mv[block_a * 2] - info_b.mv[block_b * 2]) +
    h264_er_abs(info_a.mv[block_a * 2 + 1] + info_b.mv[block_b * 2 + 1]) <
    2 {
    return (false, false, false)
  }
  (true, damaged_a, damaged_b)
}

///|
fn h264_er_filter_plane(
  ctx : H264DecCtx,
  status : Array[Int32],
  plane : Array[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  mb_w : Int32,
  mb_h : Int32,
) -> Unit {
  let blocks_w = width / 8
  let blocks_h = height / 8
  // h_block_filter: boundaries between horizontally adjacent 8x8 blocks.
  for by = 0; by < blocks_h; by = by + 1 {
    for bx = 0; bx < blocks_w - 1; bx = bx + 1 {
      let x = bx * 8 + 8
      let y = by * 8
      let (active, left, right) = h264_er_edge_mbs(
        ctx,
        status,
        x - 1,
        y,
        x,
        y,
        mb_w,
        mb_h,
      )
      if !active {
        continue
      }
      for row = 0; row < 8; row = row + 1 {
        let offset = (y + row) * stride + x
        let a = plane[offset - 1] - plane[offset - 2]
        let b = plane[offset] - plane[offset - 1]
        let c = plane[offset + 1] - plane[offset]
        let mut d = (h264_er_abs(b) -
        ((h264_er_abs(a) + h264_er_abs(c) + 1) >> 1)).max(0)
        if b < 0 {
          d = -d
        }
        if d == 0 {
          continue
        }
        if !(left && right) {
          d = d * 16 / 9
        }
        if left {
          for k = 0; k < 4; k = k + 1 {
            let weight = 7 - 2 * k
            plane[offset - 1 - k] = h264_clip8(
              plane[offset - 1 - k] + ((d * weight) >> 4),
              bit_depth=ctx.bit_depth,
            )
          }
        }
        if right {
          for k = 0; k < 4; k = k + 1 {
            let weight = 7 - 2 * k
            plane[offset + k] = h264_clip8(
              plane[offset + k] - ((d * weight) >> 4),
              bit_depth=ctx.bit_depth,
            )
          }
        }
      }
    }
  }
  // v_block_filter: boundaries between vertically adjacent 8x8 blocks.
  for by = 0; by < blocks_h - 1; by = by + 1 {
    for bx = 0; bx < blocks_w; bx = bx + 1 {
      let x = bx * 8
      let y = by * 8 + 8
      let (active, top, bottom) = h264_er_edge_mbs(
        ctx,
        status,
        x,
        y - 1,
        x,
        y,
        mb_w,
        mb_h,
      )
      if !active {
        continue
      }
      for col = 0; col < 8; col = col + 1 {
        let offset = y * stride + x + col
        let a = plane[offset - stride] - plane[offset - 2 * stride]
        let b = plane[offset] - plane[offset - stride]
        let c = plane[offset + stride] - plane[offset]
        let mut d = (h264_er_abs(b) -
        ((h264_er_abs(a) + h264_er_abs(c) + 1) >> 1)).max(0)
        if b < 0 {
          d = -d
        }
        if d == 0 {
          continue
        }
        if !(top && bottom) {
          d = d * 16 / 9
        }
        if top {
          for k = 0; k < 4; k = k + 1 {
            let weight = 7 - 2 * k
            let index = offset - (k + 1) * stride
            plane[index] = h264_clip8(
              plane[index] + ((d * weight) >> 4),
              bit_depth=ctx.bit_depth,
            )
          }
        }
        if bottom {
          for k = 0; k < 4; k = k + 1 {
            let weight = 7 - 2 * k
            let index = offset + k * stride
            plane[index] = h264_clip8(
              plane[index] - ((d * weight) >> 4),
              bit_depth=ctx.bit_depth,
            )
          }
        }
      }
    }
  }
}

///|
fn h264_er_deblock(ctx : H264DecCtx, status : Array[Int32]) -> Unit {
  h264_er_filter_plane(
    ctx,
    status,
    ctx.y,
    ctx.ystride,
    ctx.ystride,
    ctx.mb_height * 16,
    16,
    16,
  )
  let cw = 16 >> ctx.chroma_hshift
  let ch = 16 >> ctx.chroma_vshift
  h264_er_filter_plane(
    ctx,
    status,
    ctx.u,
    ctx.cstride,
    ctx.cstride,
    ctx.mb_height * ch,
    cw,
    ch,
  )
  h264_er_filter_plane(
    ctx,
    status,
    ctx.v,
    ctx.cstride,
    ctx.cstride,
    ctx.mb_height * ch,
    cw,
    ch,
  )
}
