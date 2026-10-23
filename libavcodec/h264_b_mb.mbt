///|
/// B macroblocks from FFmpeg 9.0.2 h264_cabac.c/h264_cavlc.c and h264data.c.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
priv enum H264BEntropy {
  Cavlc(BitReader)
  Cabac(CabacContext, Array[Int32])
}

///|
priv struct H264BPart {
  x : Int32
  y : Int32
  w : Int32
  h : Int32
  mask : Int32
  group : Int32
}

///|
fn h264_b_cabac_type(
  c : CabacContext,
  states : Array[Int32],
  ctx : H264DecCtx,
  index : Int32,
) -> Int32 {
  let mut context = 0
  for
    n in [
      if h264_has_left(ctx, index) {
        index - 1
      } else {
        -1
      },
      if h264_has_top(ctx, index) {
        h264_top_index(ctx, index)
      } else {
        -1
      },
    ] {
    if n >= 0 && (ctx.infos[n].mb_type_bits & h264_mb_type_direct) == 0 {
      context += 1
    }
  }
  if c.get_cabac(states, 27 + context) == 0 {
    return 0
  }
  if c.get_cabac(states, 30) == 0 {
    return 1 + c.get_cabac(states, 32)
  }
  let bits = (c.get_cabac(states, 31) << 3) +
    (c.get_cabac(states, 32) << 2) +
    (c.get_cabac(states, 32) << 1) +
    c.get_cabac(states, 32)
  if bits < 8 {
    bits + 3
  } else if bits == 13 {
    23 +
    h264_cabac_intra_mb_type(
      c,
      states,
      ctx,
      index,
      index % ctx.mb_width,
      index / ctx.mb_width,
      32,
      0,
    )
  } else if bits == 14 {
    11
  } else if bits == 15 {
    22
  } else {
    (bits << 1) + c.get_cabac(states, 32) - 4
  }
}

///|
fn h264_b_sub_type(entropy : H264BEntropy) -> Int32 {
  match entropy {
    Cavlc(gb) => gb.read_ue()
    Cabac(c, states) => {
      if c.get_cabac(states, 36) == 0 {
        return 0
      }
      if c.get_cabac(states, 37) == 0 {
        return 1 + c.get_cabac(states, 39)
      }
      let mut kind = 3
      if c.get_cabac(states, 38) != 0 {
        if c.get_cabac(states, 39) != 0 {
          return 11 + c.get_cabac(states, 39)
        }
        kind += 4
      }
      kind + 2 * c.get_cabac(states, 39) + c.get_cabac(states, 39)
    }
  }
}

///|
fn h264_b_partitions(
  kind : Int32,
  sub : Array[Int32],
) -> (Array[H264BPart], Array[H264BPart], Array[Bool], Int32) {
  let groups : Array[H264BPart] = []
  let parts : Array[H264BPart] = []
  let direct = Array::make(4, false)
  let mb_bits = if kind == 0 {
    h264_mb_type_direct | h264_mb_type_16x16
  } else if kind < 4 {
    h264_mb_type_16x16
  } else if kind == 22 {
    h264_mb_type_8x8
  } else if (kind & 1) == 0 {
    h264_mb_type_16x8
  } else {
    h264_mb_type_8x16
  }
  if kind == 0 {
    for i in 0..<4 {
      direct[i] = true
    }
  } else if kind < 4 {
    let part : H264BPart = { x: 0, y: 0, w: 4, h: 4, mask: kind, group: 0, }
    groups.push(part)
    parts.push(part)
  } else if kind < 22 {
    let masks = [
        (1, 1),
        (2, 2),
        (1, 2),
        (2, 1),
        (1, 3),
        (2, 3),
        (3, 1),
        (3, 2),
        (3, 3),
      ][(kind - 4) / 2]
    for i in 0..<2 {
      let horizontal = (kind & 1) == 0
      let part : H264BPart = {
        x: if horizontal {
          0
        } else {
          2 * i
        },
        y: if horizontal {
          2 * i
        } else {
          0
        },
        w: if horizontal {
          4
        } else {
          2
        },
        h: if horizontal {
          2
        } else {
          4
        },
        mask: if i == 0 {
          masks.0
        } else {
          masks.1
        },
        group: i,
      }
      groups.push(part)
      parts.push(part)
    }
  } else {
    for i, s in sub {
      if s == 0 {
        direct[i] = true
        continue
      }
      let mask = if s < 4 {
        s
      } else if s < 6 {
        1
      } else if s < 8 {
        2
      } else if s < 10 {
        3
      } else {
        s - 9
      }
      let shape = if s < 4 {
        0
      } else if s < 10 {
        if (s & 1) == 0 {
          1
        } else {
          2
        }
      } else {
        3
      }
      let x = i % 2 * 2
      let y = i / 2 * 2
      groups.push({ x, y, w: 2, h: 2, mask, group: i, })
      let w = if shape == 2 || shape == 3 { 1 } else { 2 }
      let h = if shape == 1 || shape == 3 { 1 } else { 2 }
      for by = 0; by < 2; by = by + h {
        for bx = 0; bx < 2; bx = bx + w {
          parts.push({ x: x + bx, y: y + by, w, h, mask, group: i, })
        }
      }
    }
  }
  (
    groups,
    parts,
    direct,
    mb_bits | h264_mb_type_p0l0 | h264_mb_type_p1l0 | (1 << 14) | (1 << 15),
  )
}

///|
fn h264_decode_b_mb(
  entropy : H264BEntropy,
  ctx : H264DecCtx,
  index : Int32,
) -> Result[Unit, String] {
  let mx = index % ctx.mb_width
  let my = index / ctx.mb_width
  let info = ctx.infos[index]
  let skip = match entropy {
    Cabac(c, states) => {
      let skip = if ctx.mb_aff && (my & 1) == 1 && ctx.prev_mb_skipped {
        ctx.next_mb_skipped
      } else {
        h264_cabac_mb_skip(c, states, ctx, index, mx, my) != 0
      }
      if skip {
        if ctx.mb_aff && (my & 1) == 0 {
          info.mb_type_bits = h264_mb_type_skip
          ctx.next_mb_skipped = h264_cabac_mb_skip(
              c,
              states,
              ctx,
              index + ctx.mb_width,
              mx,
              my + 1,
            ) !=
            0
          if !ctx.next_mb_skipped {
            ctx.mb_field = h264_cabac_field_decoding_flag(
              c, states, ctx, index, mx,
            )
          }
        }
        ctx.prev_mb_skipped = true
      } else {
        if ctx.mb_aff && (my & 1) == 0 {
          ctx.mb_field = h264_cabac_field_decoding_flag(
            c, states, ctx, index, mx,
          )
        }
        ctx.prev_mb_skipped = false
      }
      skip
    }
    Cavlc(gb) => {
      if ctx.mb_skip_run < 0 {
        ctx.mb_skip_run = gb.read_ue()
        if ctx.mb_skip_run < 0 || ctx.mb_skip_run > ctx.infos.length() - index {
          return Err("mb_skip_run is invalid")
        }
      }
      let value = ctx.mb_skip_run > 0
      ctx.mb_skip_run -= 1
      if ctx.mb_aff && (my & 1) == 0 {
        if value {
          if ctx.mb_skip_run == 0 {
            ctx.mb_field = gb.read1() != 0U
          }
        } else {
          ctx.mb_field = gb.read1() != 0U
        }
      }
      value
    }
  }
  info.field_mb = ctx.mb_field
  let kind = if skip {
    0
  } else {
    match entropy {
      Cavlc(gb) => gb.read_ue()
      Cabac(c, states) => h264_b_cabac_type(c, states, ctx, index)
    }
  }
  if kind < 0 || kind > 48 {
    return Err("invalid B macroblock type")
  }
  if kind >= 23 {
    ctx.cur_mb_is_intra = true
    return match entropy {
      Cavlc(gb) => h264_decode_mb_cavlc_intra(gb, ctx, index, mx, my, kind - 23)
      Cabac(c, states) =>
        if kind == 48 {
          h264_decode_pcm_cabac(c, ctx, index, mx, my)
        } else {
          h264_decode_mb_cabac_intra(
            c,
            states,
            ctx,
            index,
            mx,
            my,
            kind - 23,
            Array::make(16, 0),
          )
        }
    }
  }
  ctx.cur_mb_is_intra = false
  for i in 0..<16 {
    info.ref_idx[i] = -1
    info.ref_idx1[i] = -1
  }
  let sub = Array::make(4, 0)
  if kind == 22 {
    for i in 0..<4 {
      sub[i] = h264_b_sub_type(entropy)
      if sub[i] < 0 || sub[i] > 12 {
        return Err("invalid B submacroblock type")
      }
    }
  }
  let (groups, parts, direct, mb_bits) = h264_b_partitions(kind, sub)
  info.mb_type_bits = mb_bits | (if skip { h264_mb_type_skip } else { 0 })
  if direct.any(fn(value) { value }) {
    match h264_b_direct(ctx, index, direct) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  if kind == 22 {
    // fill_decode_caches / pred_direct_motion leave the right-hand groups'
    // top-left reference unavailable until that group's motion pass. Preserve
    // direct MVs: only the reference cache slot is temporarily hidden.
    for block in [2, 10] {
      info.ref_idx[block] = -2
      info.ref_idx1[block] = -2
    }
  }
  let refs = [Array::make(4, -1), Array::make(4, -1)]
  for list in 0..<2 {
    ctx.active_list = list
    let count = if list == 0 {
      h264_ref_count(ctx)
    } else if ctx.mb_aff && ctx.mb_field {
      ctx.ref_count1 * 2
    } else {
      ctx.ref_count1
    }
    for part in groups {
      if (part.mask & (1 << list)) == 0 {
        continue
      }
      let refi = if count <= 1 {
        0
      } else {
        match entropy {
          Cabac(c, states) =>
            match
              h264_cabac_mb_ref(
                c,
                states,
                ctx,
                index,
                mx,
                my,
                part.x,
                part.y,
                count,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
          Cavlc(gb) =>
            if count == 2 {
              (gb.read1() ^ 1U).reinterpret_as_int()
            } else {
              gb.read_ue()
            }
        }
      }
      if refi < 0 || refi >= count {
        return Err("invalid B reference index")
      }
      refs[list][part.group] = refi
      if kind == 22 {
        if entropy is Cabac(_, _) {
          h264_write_back_ref(ctx, index, part.x + 1, part.y, 1, 1, refi)
          h264_write_back_ref(ctx, index, part.x, part.y + 1, 2, 1, refi)
        }
      } else {
        h264_write_back_ref(ctx, index, part.x, part.y, part.w, part.h, refi)
      }
    }
  }
  for list in 0..<2 {
    ctx.active_list = list
    for group in 0..<(if kind == 22 { 4 } else { 1 }) {
      if kind == 22 {
        let x = (group & 1) * 2
        let y = (group >> 1) * 2
        let cache = if list == 0 { info.ref_idx } else { info.ref_idx1 }
        if direct[group] {
          cache[y * 4 + x] = cache[y * 4 + x + 1]
        } else {
          h264_write_back_ref(ctx, index, x, y, 2, 2, refs[list][group])
        }
      }
      for part in parts {
        if kind == 22 && part.group != group {
          continue
        }
        if (part.mask & (1 << list)) == 0 {
          continue
        }
        let refi = refs[list][part.group]
        let prediction = if kind >= 4 && kind < 22 {
          if (kind & 1) == 0 {
            h264_pred_16x8_motion(ctx, index, mx, my, part.group, refi)
          } else {
            h264_pred_8x16_motion(ctx, index, mx, my, part.group, refi)
          }
        } else {
          h264_pred_motion(ctx, index, mx, my, part.x, part.y, part.w, refi)
        }
        let (vx, vy, dx, dy) = match entropy {
          Cabac(c, states) =>
            match
              h264_cabac_read_mvd(
                c,
                states,
                ctx,
                index,
                mx,
                my,
                part.x,
                part.y,
                prediction.0,
                prediction.1,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
          Cavlc(gb) => {
            let x = gb.read_se()
            let y = gb.read_se()
            if x == -2147483648 || y == -2147483648 {
              return Err("invalid B motion difference")
            }
            (
              prediction.0 + x,
              prediction.1 + y,
              x.abs().min(70),
              y.abs().min(70),
            )
          }
        }
        h264_write_back_part(
          ctx,
          index,
          part.x,
          part.y,
          part.w,
          part.h,
          vx,
          vy,
          refi,
          dx,
          dy,
        )
      }
    }
  }
  ctx.active_list = 0
  match h264_b_compensate(ctx, index) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if skip {
    info.qp = ctx.qscale
    info.cbp_all = 0
    ctx.last_qscale_diff = 0
    return Ok(())
  }
  let allowed = ctx.pps.transform_8x8_mode != 0 &&
    parts.all(fn(part) { part.w >= 2 && part.h >= 2 }) &&
    (ctx.direct_8x8 || !direct.any(fn(value) { value }))
  match entropy {
    Cabac(c, states) =>
      h264_inter_residual_cabac(c, states, ctx, index, mx, my, [], allowed)
    Cavlc(gb) => h264_inter_residual_cavlc(gb, ctx, index, mx, my, [], allowed)
  }
}
