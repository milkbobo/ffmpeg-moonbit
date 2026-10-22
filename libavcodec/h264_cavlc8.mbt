///|
/// FFmpeg 9.0.2 h264_cavlc.c decode_luma_residual, 8x8 transform path.
/// LGPL-2.1-or-later. Each 8x8 is four interleaved CAVLC 16-coefficient lists.
fn h264_cavlc_luma8(
  gb : BitReader, ctx : H264DecCtx, mb_idx : Int32, mb_x : Int32, mb_y : Int32,
  cbp : Int32, matrix : Int32, mb : Array[Int32],
) -> Result[Unit, String] {
  let nz = ctx.infos[mb_idx].nz
  let qmul = h264_build_dequant8(ctx.pps, matrix, ctx.qscale)
  for quadrant in 0..<4 {
    if (cbp & (1 << quadrant)) != 0 {
      for sub in 0..<4 {
        let index = 4 * quadrant + sub
        let gx = h264_luma_block_x[index]
        let gy = h264_luma_block_y[index]
        let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz)
        let scan = [for j in 0..<16 => h264_zigzag_scan8x8[4 * j + sub]]
        nz[gy * 4 + gx] = match h264_decode_residual(gb, mb, 64 * quadrant, scan, 0, Some(qmul), 16, nc) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      }
      let leader = h264_luma_block_grid[4 * quadrant]
      nz[leader] += nz[leader + 1] + nz[leader + 4] + nz[leader + 5]
    }
  }
  Ok(())
}
