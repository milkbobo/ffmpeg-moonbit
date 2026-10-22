///|
/// FFmpeg 9.0.2 h264_cabac.c I_PCM: rewind arithmetic lookahead, read samples,
/// then restart arithmetic decoding while retaining probability contexts.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
fn h264_decode_pcm_cabac(
  cabac : CabacContext, ctx : H264DecCtx, index : Int32, mb_x : Int32, mb_y : Int32,
) -> Result[Unit, String] {
  let mut ptr = cabac.pos
  if (cabac.low & 1) != 0 { ptr -= 1 }
  if (cabac.low & 0x1ff) != 0 { ptr -= 1 }
  guard ptr >= 0 && ptr <= cabac.bytes.length() - 384 else { return Err("not enough data for I_PCM") }
  let next = match ff_init_cabac_decoder(cabac.bytes, ptr + 384) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for row in 0..<16 { for col in 0..<16 {
    ctx.y[(mb_y * 16 + row) * ctx.ystride + mb_x * 16 + col] = cabac.bytes[ptr].to_int()
    ptr += 1
  } }
  for plane in [ctx.u, ctx.v] { for row in 0..<8 { for col in 0..<8 {
    plane[(mb_y * 8 + row) * ctx.cstride + mb_x * 8 + col] = cabac.bytes[ptr].to_int()
    ptr += 1
  } } }
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
