///|
/// Spatial/temporal direct motion, frame path from FFmpeg h264_direct.c.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
let h264_mb_type_direct : Int32 = 1 << 8

///|
fn h264_b_direct_neighbor(ctx : H264DecCtx, index : Int32, mx : Int32, my : Int32, x : Int32, y : Int32) -> Bool {
  let ax = mx * 4 + x
  let ay = my * 4 + y
  if ax < 0 || ax >= ctx.mb_width * 4 || (y >= 0 && ay >= ctx.infos.length() / ctx.mb_width * 4) {
    return false
  }
  let mb = if y < 0 {
    if x < 0 {
      h264_topleft_index(ctx, index)
    } else if x >= 4 {
      h264_topright_index(ctx, index)
    } else {
      h264_top_index(ctx, index)
    }
  } else {
    my * ctx.mb_width + ax / 4
  }
  if mb < 0 || mb >= ctx.infos.length() {
    return false
  }
  (mb == index || h264_same_slice(ctx, mb)) && ctx.infos[mb].direct[ay % 4 * 4 + ax % 4]
}

///|
fn h264_b_direct(ctx : H264DecCtx, index : Int32, quadrants : Array[Bool]) -> Result[Unit, String] {
  guard index < ctx.colocated.length() && !ctx.ref_list1.is_empty() else { return Err("missing colocated motion history") }
  let col = ctx.colocated[index]
  let mx = index % ctx.mb_width
  let my = index / ctx.mb_width
  let refs = [-1, -1]
  let motions = [(0, 0), (0, 0)]
  if ctx.direct_spatial {
    for list in 0..<2 {
      ctx.active_list = list
      let a = h264_mv_fetch(ctx, index, mx, my, -1, 0)
      let b = h264_mv_fetch(ctx, index, mx, my, 0, -1)
      let c0 = h264_mv_fetch(ctx, index, mx, my, 4, -1)
      let c = if c0.0 == -2 { h264_mv_fetch(ctx, index, mx, my, -1, -1) } else { c0 }
      for candidate in [a.0, b.0, c.0] {
        if candidate >= 0 && (refs[list] < 0 || candidate < refs[list]) { refs[list] = candidate }
      }
      if refs[list] >= 0 { motions[list] = h264_pred_motion(ctx, index, mx, my, 0, 0, 4, refs[list]) }
    }
    if refs[0] < 0 && refs[1] < 0 { refs[0] = 0; refs[1] = 0 }
  }
  for gy in 0..<4 { for gx in 0..<4 {
    let quadrant = gy / 2 * 2 + gx / 2
    if !quadrants[quadrant] { continue }
    let cx = if ctx.direct_8x8 { gx / 2 * 3 } else { gx }
    let cy = if ctx.direct_8x8 { gy / 2 * 3 } else { gy }
    let ci = cy * 4 + cx
    let intra = h264_is_intra_type(col.mb_type_bits)
    let use0 = col.ref_idx[ci] >= 0
    let cr = if use0 { col.ref_idx[ci] } else { col.ref_idx1[ci] }
    let cv = if use0 { col.mv } else { col.mv1 }
    let cvx = cv[2 * ci]
    let cvy = cv[2 * ci + 1]
    let cpoc = (if use0 { col.ref_identity } else { col.ref_identity1 })[ci]
    let zero = !intra && !ctx.long_pocs.contains(ctx.ref_list1[0].identity) && cr == 0 && cvx.abs() <= 1 && cvy.abs() <= 1
    let mut temporal_ref = 0
    let mut temporal_mv = (0, 0)
    if !ctx.direct_spatial && !intra {
      temporal_ref = ctx.ref_list0.search_by(fn(pic) { pic.identity == cpoc }).unwrap_or(0)
      let td = (ctx.ref_list1[0].poc - ctx.ref_list0[temporal_ref].poc).max(-128).min(127)
      let mut scale = 256
      if td != 0 && !ctx.long_pocs.contains(ctx.ref_list0[temporal_ref].identity) {
        let tb = (ctx.poc - ctx.ref_list0[temporal_ref].poc).max(-128).min(127)
        let tx = (16384 + (td.abs() >> 1)) / td
        scale = ((tb * tx + 32) >> 6).max(-1024).min(1023)
      }
      temporal_mv = ((scale * cvx + 128) >> 8, (scale * cvy + 128) >> 8)
    }
    for list in 0..<2 {
      ctx.active_list = list
      let refi = if ctx.direct_spatial { refs[list] } else if list == 0 { temporal_ref } else { 0 }
      let mv = if ctx.direct_spatial {
        if zero && refi == 0 { (0, 0) } else { motions[list] }
      } else if intra { (0, 0) }
      else if list == 0 { temporal_mv } else { (temporal_mv.0 - cvx, temporal_mv.1 - cvy) }
      h264_write_back_part(ctx, index, gx, gy, 1, 1, mv.0, mv.1, refi, 0, 0)
    }
    ctx.infos[index].direct[gy * 4 + gx] = true
  } }
  ctx.active_list = 0
  Ok(())
}
