///|
/// FFmpeg 9.0.2 h264_cabac.c I_PCM: rewind arithmetic lookahead, read samples,
/// then restart arithmetic decoding while retaining probability contexts.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
fn h264_decode_pcm_cabac(
  cabac : CabacContext, ctx : H264DecCtx, index : Int32, mb_x : Int32, mb_y : Int32,
) -> Result[Unit, String] {
  // Chroma samples per plane: 8x8 (4:2:0), 8x16 (4:2:2) or 16x16 (4:4:4);
  // monochrome PCM carries luma only (`ff_h264_mb_sizes[0] == 256`).
  let cw = 16 >> ctx.chroma_hshift
  let chh = 16 >> ctx.chroma_vshift
  let pcm_samples = if ctx.chroma_format == 0 { 256 } else { 256 + 2 * cw * chh }
  let pcm_bytes = pcm_samples * ctx.bit_depth / 8
  let mut ptr = cabac.pos
  if (cabac.low & 1) != 0 { ptr -= 1 }
  if (cabac.low & 0x1ff) != 0 { ptr -= 1 }
  guard ptr >= 0 && ptr <= cabac.bytes.length() - pcm_bytes else { return Err("not enough data for I_PCM") }
  let next = match ff_init_cabac_decoder(cabac.bytes, ptr + pcm_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let reader = BitReader::with_size(cabac.bytes, cabac.bytes.length() * 8)
  reader.skip(ptr * 8)
  let ystride = h264_mb_ystride(ctx)
  let ybase = h264_mb_ybase(ctx, mb_x, mb_y)
  for row in 0..<16 { for col in 0..<16 {
    ctx.y[ybase + row * ystride + col] = reader.read(ctx.bit_depth).reinterpret_as_int()
  } }
  let cstride = h264_mb_cstride(ctx)
  let cbase = h264_mb_cbase(ctx, mb_x, mb_y)
  if ctx.chroma_format != 0 {
    for plane in [ctx.u, ctx.v] { for row in 0..<chh { for col in 0..<cw {
      plane[cbase + row * cstride + col] = reader.read(ctx.bit_depth).reinterpret_as_int()
    } } }
  }
  cabac.low = next.low
  cabac.range = next.range
  cabac.pos = next.pos
  let info = ctx.infos[index]
  for i in 0..<48 { info.nz[i] = 16 }
  info.intra4x4 = false
  info.transform_8x8 = false
  info.mb_type_bits = h264_mb_type_intra_pcm
  info.cbp_all = 0xf7ef
  info.chroma_mode = 0
  info.qp = 0
  ctx.last_qscale_diff = 0
  Ok(())
}
