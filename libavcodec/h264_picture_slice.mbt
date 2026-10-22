///|
/// One slice within a shared progressive picture (FFmpeg h264_slice.c).
/// LGPL-2.1-or-later. Each slice owns its entropy/QP/MV prediction state.
fn h264_decode_picture_slice(
  ctx : H264DecCtx, nal : H2645Nal, gb : BitReader, sh : H264SliceHeader,
  refs : Array[H264RefPic], slice_num : Int32,
) -> Result[Unit, String] {
  guard sh.slice_type_nos == 0 || sh.slice_type_nos == 2 else { return Err("only I and P slices are supported") }
  ctx.slice_num = slice_num
  ctx.slice_type_nos = sh.slice_type_nos
  ctx.qscale = sh.qscale
  ctx.last_qscale_diff = 0
  ctx.mb_skip_run = -1
  ctx.ref_count0 = sh.num_ref_idx_l0_active
  ctx.ref_list0 = refs.copy()
  ctx.pwt = sh.pwt
  if sh.slice_type_nos == 0 && refs.is_empty() { return Err("no reference picture for a P slice") }
  while ctx.ref_list0.length() < ctx.ref_count0 && !refs.is_empty() { ctx.ref_list0.push(refs[0]) }
  let cabac : CabacContext? = if ctx.pps.cabac != 0 {
    gb.align()
    match ff_init_cabac_decoder(nal.data, gb.count() / 8) { Ok(value) => Some(value); Err(error) => return Err(error) }
  } else { None }
  let states = ff_h264_init_cabac_states(sh.qscale, 8, sh.slice_type_nos, sh.cabac_init_flag)
  let mut index = sh.first_mb_in_slice
  let mut terminated = false
  while index < ctx.infos.length() {
    if cabac is None && gb.bits_left() <= 0 && ctx.mb_skip_run <= 0 { break }
    let info = ctx.infos[index]
    if info.mb_type_bits != 0 { return Err("overlapping H.264 slices") }
    info.slice_num = slice_num
    info.deblock_idc = sh.disable_deblocking_filter_idc
    info.alpha_offset = 52 + sh.slice_alpha_c0_offset
    info.beta_offset = 52 + sh.slice_beta_offset
    let result = match cabac {
      Some(coder) => h264_decode_mb_cabac(coder, states, ctx, index, index % ctx.mb_width, index / ctx.mb_width)
      None => h264_decode_mb(gb, ctx, index, index % ctx.mb_width, index / ctx.mb_width)
    }
    match result { Ok(_) => (); Err(error) => return Err(error) }
    for block in 0..<16 {
      let ref_index = info.ref_idx[block]
      info.ref_identity[block] = if ref_index >= 0 && ref_index < ctx.ref_list0.length() { ctx.ref_list0[ref_index].poc } else { -1 }
    }
    index += 1
    if cabac is Some(coder) && coder.get_cabac_terminate() != 0 { terminated = true; break }
  }
  if index == sh.first_mb_in_slice { return Err("empty H.264 slice") }
  if cabac is Some(_) && !terminated { return Err("missing H.264 end_of_slice_flag: frame=\{sh.frame_num} slice=\{slice_num} first=\{sh.first_mb_in_slice}") }
  if cabac is None && (gb.bits_left() < 0 || ctx.mb_skip_run > 0) { return Err("H.264 slice exceeds picture") }
  Ok(())
}
