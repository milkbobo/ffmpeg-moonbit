///|
/// Slice-local neighbour availability (FFmpeg h264_mvpred.h fill_decode_caches).
/// LGPL-2.1-or-later. Reconstruction shares planes, syntax never crosses slices.
fn h264_same_slice(ctx : H264DecCtx, index : Int32) -> Bool {
  index >= 0 && index < ctx.infos.length() &&
  ctx.infos[index].slice_num == ctx.slice_num && ctx.infos[index].mb_type_bits != 0
}

///|
fn h264_has_left(ctx : H264DecCtx, index : Int32) -> Bool {
  index % ctx.mb_width > 0 && h264_same_slice(ctx, index - 1)
}

///|
/// Corrected top neighbour (`fill_decode_neighbors`): for a field-coded MB in
/// an even pair row, a frame-coded neighbour MB one pair up is addressed at
/// the pair's bottom MB (`top_xy += mb_stride`).
fn h264_top_corrected(ctx : H264DecCtx, index : Int32, dx : Int32) -> Int32 {
  let base = index - h264_mb_top_offset(ctx) + dx
  if ctx.mb_aff && ctx.mb_field && ((index / ctx.mb_width) & 1) == 0 &&
    base >= 0 && base < ctx.infos.length() && !ctx.infos[base].field_mb {
    base + ctx.mb_width
  } else {
    base
  }
}

///|
/// Top macroblock distance: two MB rows for a field-coded MB, one otherwise
/// (`mb_stride << MB_FIELD` in `fill_decode_neighbors`).
fn h264_mb_top_offset(ctx : H264DecCtx) -> Int32 {
  if ctx.mb_field { ctx.mb_width * 2 } else { ctx.mb_width }
}

///|
fn h264_top_index(ctx : H264DecCtx, index : Int32) -> Int32 {
  h264_top_corrected(ctx, index, 0)
}

///|
fn h264_topleft_index(ctx : H264DecCtx, index : Int32) -> Int32 {
  h264_top_corrected(ctx, index, -1)
}

///|
fn h264_topright_index(ctx : H264DecCtx, index : Int32) -> Int32 {
  h264_top_corrected(ctx, index, 1)
}

///|
fn h264_has_top(ctx : H264DecCtx, index : Int32) -> Bool {
  let top = h264_top_index(ctx, index)
  top >= 0 && top < ctx.infos.length() && h264_same_slice(ctx, top)
}

///|
/// Plane stride of the current MB: field-coded MBs are stored every other
/// frame row (`mb_linesize = linesize * 2`).
fn h264_mb_ystride(ctx : H264DecCtx) -> Int32 {
  if ctx.mb_field { ctx.ystride * 2 } else { ctx.ystride }
}

///|
fn h264_mb_cstride(ctx : H264DecCtx) -> Int32 {
  if ctx.mb_field { ctx.cstride * 2 } else { ctx.cstride }
}

///|
/// Luma plane offset of the current MB; the bottom MB of a field pair starts
/// on the odd line of the 32-line pair (`dest_y -= linesize * 15`).
fn h264_mb_ybase(ctx : H264DecCtx, mb_x : Int32, mb_y : Int32) -> Int32 {
  let row = mb_y * 16 - (if ctx.mb_field && (mb_y & 1) == 1 { 15 } else { 0 })
  row * ctx.ystride + mb_x * 16
}

///|
fn h264_mb_cbase(ctx : H264DecCtx, mb_x : Int32, mb_y : Int32) -> Int32 {
  let cw = 16 >> ctx.chroma_hshift
  let ch = 16 >> ctx.chroma_vshift
  let row = mb_y * ch - (if ctx.mb_field && (mb_y & 1) == 1 { ch - 1 } else { 0 })
  row * ctx.cstride + mb_x * cw
}

///|
fn h264_intra_available(ctx : H264DecCtx, index : Int32) -> Bool {
  h264_same_slice(ctx, index) &&
  (ctx.pps.constrained_intra_pred == 0 || h264_is_intra_type(ctx.infos[index].mb_type_bits))
}

///|
fn h264_intra_left(ctx : H264DecCtx, index : Int32) -> Bool {
  index % ctx.mb_width > 0 && h264_intra_available(ctx, index - 1)
}

///|
fn h264_intra_top(ctx : H264DecCtx, index : Int32) -> Bool {
  let top = h264_top_index(ctx, index)
  top >= 0 && top < ctx.infos.length() && h264_intra_available(ctx, top)
}

///|
fn h264_intra_topleft(ctx : H264DecCtx, index : Int32, gx : Int32, gy : Int32) -> Bool {
  if gx > 0 { return gy > 0 || h264_intra_top(ctx, index) }
  if gy > 0 { return h264_intra_left(ctx, index) }
  let top_left = h264_topleft_index(ctx, index)
  index % ctx.mb_width > 0 && top_left >= 0 && top_left < ctx.infos.length() &&
    h264_intra_available(ctx, top_left)
}
