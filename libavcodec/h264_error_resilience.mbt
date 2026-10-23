///|
/// Conceal absent macroblocks after the ordinary H.264 slice reconstruction
/// and loop filter. FFmpeg's `ff_er_frame_end` likewise runs after the slice
/// loop filter and uses the first L0 picture for temporal concealment.
/// LGPL-2.1-or-later.

let zz_er_deblock : Ref[Bool] = { val: true }

///|
fn h264_er_dc_plane(
  ctx : H264DecCtx,
  status : Array[Int32],
  plane : Array[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  mb_w : Int32,
  mb_h : Int32,
  filter_luma : Bool,
) -> Array[Int32] {
  let blocks_w = width / 8
  let blocks_h = height / 8
  let dc = Array::make(blocks_w * blocks_h, 0)
  for by = 0; by < blocks_h; by = by + 1 {
    for bx = 0; bx < blocks_w; bx = bx + 1 {
      let mut sum = 0
      for y = 0; y < 8; y = y + 1 {
        for x = 0; x < 8; x = x + 1 {
          sum += plane[(by * 8 + y) * stride + bx * 8 + x]
        }
      }
      dc[by * blocks_w + bx] = (sum + 4) >> 3
    }
  }
  // FFmpeg guess_dc: nearest valid 8x8 DC in each cardinal direction,
  // weighted by inverse distance. Invalid directions supply neutral 128.
  let guessed = dc.copy()
  for by = 0; by < blocks_h; by = by + 1 {
    for bx = 0; bx < blocks_w; bx = bx + 1 {
      let mb = (by * 8 / mb_h) * ctx.mb_width + bx * 8 / mb_w
      if (status[mb] & 4) == 0 { continue }
      let mut weighted = 0L
      let mut weights = 0L
      for direction = 0; direction < 4; direction = direction + 1 {
        let dx = if direction == 0 { -1 } else if direction == 1 { 1 } else { 0 }
        let dy = if direction == 2 { -1 } else if direction == 3 { 1 } else { 0 }
        let mut x = bx + dx
        let mut y = by + dy
        let mut distance = 1
        let mut color = 1 << (ctx.bit_depth + 2)
        while x >= 0 && x < blocks_w && y >= 0 && y < blocks_h {
          let neighbor = (y * 8 / mb_h) * ctx.mb_width + x * 8 / mb_w
          if (status[neighbor] & 4) == 0 ||
            (ctx.infos[neighbor].mb_type_bits != 0 &&
            !h264_is_intra_type(ctx.infos[neighbor].mb_type_bits)) {
            color = dc[y * blocks_w + x]
            break
          }
          x += dx
          y += dy
          distance += 1
        }
        if x < 0 || x >= blocks_w || y < 0 || y >= blocks_h {
          distance = 9999
        }
        let weight = 268435456L / distance.to_int64()
        weighted += color.to_int64() * weight
        weights += weight
      }
      guessed[by * blocks_w + bx] =
        ((weighted + weights / 2L) / weights).to_int()
    }
  }
  if filter_luma {
    // filter181 in error_resilience.c; it sharpens the DC grid before put_dc.
    //
    // `value * 10923` stays inside Int32 at every supported depth. The grid
    // holds 8x8 block averages, so at most `1 << bit_depth`; `value` peaks at
    // `8 * (1 << bit_depth)` = 131064 for 14-bit, and the product is 1.4e9,
    // below `INT32_MAX`. FFmpeg evaluates the same expression in `int`, so
    // keeping Int32 reproduces it bit for bit instead of silently widening.
    for by = 1; by < blocks_h - 1; by = by + 1 {
      let mut previous = guessed[by * blocks_w]
      for bx = 1; bx < blocks_w - 1; bx = bx + 1 {
        let idx = by * blocks_w + bx
        let current = guessed[idx]
        let value = -previous + 8 * current - guessed[idx + 1]
        guessed[idx] = (value * 10923 + 32768) >> 16
        previous = current
      }
    }
    for bx = 1; bx < blocks_w - 1; bx = bx + 1 {
      let mut previous = guessed[bx]
      for by = 1; by < blocks_h - 1; by = by + 1 {
        let idx = by * blocks_w + bx
        let current = guessed[idx]
        let value = -previous + 8 * current - guessed[idx + blocks_w]
        guessed[idx] = (value * 10923 + 32768) >> 16
        previous = current
      }
    }
  }
  guessed
}

///|
/// `put_dc` writes `dc / 8` after clamping the estimated DC to 0..2040. The
/// clamp is not scaled by bit depth upstream: a 10-bit stream therefore conceals
/// with values capped at 255, and the port reproduces that.
fn h264_er_put_dc_value(dc : Int32) -> Int32 {
  dc.max(0).min(2040) / 8
}

///|
fn h264_conceal_missing_mbs(
  ctx : H264DecCtx,
  slice_type : Int32,
  status : Array[Int32],
  qscale : Int32,
  alpha_offset : Int32,
  beta_offset : Int32,
  er_previous_infos~ : Array[H264MbInfo]? = None,
) -> Unit {
  let reference : H264RefPic? = if slice_type == 2 {
    None
  } else if !ctx.ref_list0.is_empty() {
    Some(ctx.ref_list0[0])
  } else if !ctx.ref_list1.is_empty() {
    Some(ctx.ref_list1[0])
  } else {
    None
  }
  let reference = match reference {
    Some(pic) if pic.width == ctx.ystride &&
      pic.height == ctx.mb_height * 16 && pic.parity == 0 => Some(pic)
    _ => None
  }
  let picture_mv_done = slice_type == 0 && reference is Some(_)
  if picture_mv_done {
    h264_er_guess_mv_picture(ctx, status, er_previous_infos~)
  }
  let cw = 16 >> ctx.chroma_hshift
  let ch = 16 >> ctx.chroma_vshift
  let y_dc = h264_er_dc_plane(
    ctx, status, ctx.y, ctx.ystride, ctx.ystride, ctx.mb_height * 16,
    16, 16, true,
  )
  let u_dc = h264_er_dc_plane(
    ctx, status, ctx.u, ctx.cstride, ctx.cstride, ctx.mb_height * ch,
    cw, ch, false,
  )
  let v_dc = h264_er_dc_plane(
    ctx, status, ctx.v, ctx.cstride, ctx.cstride, ctx.mb_height * ch,
    cw, ch, false,
  )
  for idx = 0; idx < ctx.infos.length(); idx = idx + 1 {
    let info = ctx.infos[idx]
    if (status[idx] & 14) == 0 {
      continue
    }
    let mb_x = idx % ctx.mb_width
    let mb_y = idx / ctx.mb_width
    match reference {
      Some(pic) if !h264_is_intra_type(info.mb_type_bits) => {
        if !picture_mv_done {
          // Reached only for B pictures: `portrait` of FFmpeg's
          // `h264_er_decode_mb`, which ignores `mv_dir` and reconstructs
          // through its L0 cache with the zero vector. P pictures always take
          // the multi-pass `h264_er_guess_mv_picture` path above.
          let (mx, my) = (0, 0)
        h264_mc_luma(
          ctx.y, mb_y * 16 * ctx.ystride + mb_x * 16, ctx.ystride,
          pic.y, mb_x * 16 + (mx >> 2), mb_y * 16 + (my >> 2),
          pic.ystride, 16, 16, mx & 3, my & 3,
          pic.width, pic.height, sbase=pic.base_y, bit_depth=ctx.bit_depth,
        )
        h264_mc_chroma(
          ctx.u, mb_y * ch * ctx.cstride + mb_x * cw, ctx.cstride,
          pic.u, mb_x * cw, mb_y * ch, mx, my, pic.cstride,
          cw, ch, pic.cwidth, pic.cheight,
          sbase=pic.base_u, vshift=ctx.chroma_vshift,
        )
        h264_mc_chroma(
          ctx.v, mb_y * ch * ctx.cstride + mb_x * cw, ctx.cstride,
          pic.v, mb_x * cw, mb_y * ch, mx, my, pic.cstride,
          cw, ch, pic.cwidth, pic.cheight,
          sbase=pic.base_v, vshift=ctx.chroma_vshift,
        )
        info.mb_type_bits = h264_mb_type_16x16 | h264_mb_type_p0l0
        for block = 0; block < 16; block = block + 1 {
          info.ref_idx[block] = 0
          info.ref_identity[block] = pic.identity
          info.mv[block * 2] = mx
          info.mv[block * 2 + 1] = my
        }
        }
      }
      _ => {
        for row = 0; row < 16; row = row + 1 {
          for col = 0; col < 16; col = col + 1 {
            let block = (mb_y * 16 + row) / 8 * (ctx.ystride / 8) +
              (mb_x * 16 + col) / 8
            ctx.y[(mb_y * 16 + row) * ctx.ystride + mb_x * 16 + col] =
              h264_er_put_dc_value(y_dc[block])
          }
        }
        for row = 0; row < ch; row = row + 1 {
          for col = 0; col < cw; col = col + 1 {
            let block = (mb_y * ch + row) / 8 * (ctx.cstride / 8) +
              (mb_x * cw + col) / 8
            let dst = (mb_y * ch + row) * ctx.cstride + mb_x * cw + col
            ctx.u[dst] = h264_er_put_dc_value(u_dc[block])
            ctx.v[dst] = h264_er_put_dc_value(v_dc[block])
          }
        }
        info.mb_type_bits = h264_mb_type_intra4x4
      }
    }
    info.qp = qscale
    info.cbp_all = 0
    // The concealed macroblock keeps the slice's deblocking state so that its
    // neighbours still filter against it. Marking it as disabled would suppress
    // the whole boundary, which upstream never does.
    info.deblock_idc = 0
    // A concealed macroblock still takes part in the ordinary loop filter as a
    // neighbour, so it must carry the slice's deblocking offsets instead of the
    // neutral default. `h264_er_decode_mb` inherits them from `slice_ctx[0]`.
    info.alpha_offset = alpha_offset
    info.beta_offset = beta_offset
    info.field_mb = false
  }
  if zz_er_deblock.val {
    h264_er_deblock(ctx, status)
  }
}
