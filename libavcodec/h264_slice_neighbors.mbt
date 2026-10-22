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
fn h264_has_top(ctx : H264DecCtx, index : Int32) -> Bool {
  index >= ctx.mb_width && h264_same_slice(ctx, index - ctx.mb_width)
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
  index >= ctx.mb_width && h264_intra_available(ctx, index - ctx.mb_width)
}

///|
fn h264_intra_topleft(ctx : H264DecCtx, index : Int32, gx : Int32, gy : Int32) -> Bool {
  if gx > 0 { return gy > 0 || h264_intra_top(ctx, index) }
  if gy > 0 { return h264_intra_left(ctx, index) }
  index % ctx.mb_width > 0 && index >= ctx.mb_width &&
    h264_intra_available(ctx, index - ctx.mb_width - 1)
}
