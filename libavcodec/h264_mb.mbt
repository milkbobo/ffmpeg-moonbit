///|
/// MoonBit port of the macroblock *reconstruction* half of FFmpeg 9.0.2
/// `libavcodec/h264_mb_template.c` (`hl_decode_mb_predict_luma` /
/// `hl_decode_mb_idct_luma` and the chroma paths of `hl_decode_mb_420`).
/// The parse halves live in `h264_decode.mbt` (CAVLC) and `h264_cabac_mb.mbt`
/// (CABAC); both feed this function so the pixel path is shared.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Reconstruct one intra macroblock from its dequantised coefficients.
/// `nz` is the per-macroblock `non_zero_count` array, `modes` the Intra4x4
/// modes in raster grid order and `mb` the 768-entry coefficient block
/// (0..255 luma, 256..511 Cb, 512..767 Cr). The `lv`/`ch` arguments are the
/// per-macroblock luma DC block and chroma DC presence flags.
fn h264_recon_mb(
  ctx : H264DecCtx,
  mb_x : Int32,
  mb_y : Int32,
  is_i4x4 : Bool,
  is_i16x16 : Bool,
  pred16 : Int32,
  chroma_mode : Int32,
  modes : Array[Int32],
  cbp : Int32,
  luma_dc_nz : Int32,
  chroma_dc_nz : Array[Int32],
  chroma_qp0 : Int32,
  chroma_qp1 : Int32,
  qmul_luma : Array[Int32],
  mb : Array[Int32],
  luma_dc : Array[Int32],
  nz : Array[Int32],
) -> Result[Unit, String] {
  let pps = ctx.pps
  if cbp != 0 || is_i16x16 {
    // Reconstruction, following hl_decode_mb_predict_luma /
    // hl_decode_mb_idct_luma and the chroma path of h264_mb_template.c.
    let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
    let cbase = mb_y * 8 * ctx.cstride + mb_x * 8
    let info = ctx.infos[mb_y * ctx.mb_width + mb_x]
    if is_i4x4 {
      if info.transform_8x8 {
        for i8 = 0; i8 < 4; i8 = i8 + 1 {
          let bx8 = i8 % 2
          let by8 = i8 / 2
          let off = ybase + by8 * 8 * ctx.ystride + bx8 * 8
          let mode = modes[(by8 * 2) * 4 + bx8 * 2]
          let top = by8 > 0 || mb_y > 0
          let left = bx8 > 0 || mb_x > 0
          let topright = if by8 == 0 {
            top && (bx8 == 0 || mb_x < ctx.mb_width - 1)
          } else {
            bx8 == 0
          }
          match
            h264_pred8x8l(ctx.y, off, ctx.ystride, mode, top, left, topright) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          if (cbp & (1 << i8)) != 0 {
            h264_idct8_add4(ctx.y, off, ctx.ystride, mb, 64 * i8, nz, i8)
          }
        }
      } else {
        for i = 0; i < 16; i = i + 1 {
          let bx = h264_luma_block_x[i]
          let by = h264_luma_block_y[i]
          let g = by * 4 + bx
          let off = ybase + by * 4 * ctx.ystride + bx * 4
          let top = by > 0 || mb_y > 0
          let left = bx > 0 || mb_x > 0
          let topright = if by == 0 {
            mb_y > 0 && (bx < 3 || mb_x < ctx.mb_width - 1)
          } else {
            bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)
          }
          match
            h264_pred4x4(ctx.y, off, ctx.ystride, modes[g], top, left, topright) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          if nz[g] != 0 {
            if nz[g] == 1 && mb[16 * i] != 0 {
              h264_idct_dc_add(ctx.y, off, ctx.ystride, mb, 16 * i)
            } else {
              h264_idct_add(ctx.y, off, ctx.ystride, mb, 16 * i)
            }
          }
        }
      }
    } else {
      match
        h264_pred16x16(ctx.y, ybase, ctx.ystride, pred16, mb_y > 0, mb_x > 0) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      if luma_dc_nz != 0 {
        h264_luma_dc_dequant_idct(mb, 0, luma_dc, 0, qmul_luma[0])
      }
      for i = 0; i < 16; i = i + 1 {
        let bx = h264_luma_block_x[i]
        let by = h264_luma_block_y[i]
        let off = ybase + by * 4 * ctx.ystride + bx * 4
        let g = h264_luma_block_grid[i]
        if nz[g] != 0 {
          h264_idct_add(ctx.y, off, ctx.ystride, mb, 16 * i)
        } else if mb[16 * i] != 0 {
          h264_idct_dc_add(ctx.y, off, ctx.ystride, mb, 16 * i)
        }
      }
    }
    match
      h264_pred8x8(ctx.u, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match
      h264_pred8x8(ctx.v, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let chroma_qps : Array[Int32] = [chroma_qp0, chroma_qp1]
    for c = 0; c < 2; c = c + 1 {
      if chroma_dc_nz[c] != 0 {
        let qmul_dc = h264_build_dequant4(pps, 1 + c, chroma_qps[c])[0]
        h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc)
      }
      let plane = if c == 0 { ctx.u } else { ctx.v }
      for i = 0; i < 4; i = i + 1 {
        let off = cbase + i / 2 * 4 * ctx.cstride + i % 2 * 4
        let g = 16 + 16 * c + i
        if nz[g] != 0 {
          h264_idct_add(plane, off, ctx.cstride, mb, 256 + 256 * c + 16 * i)
        } else if mb[256 + 256 * c + 16 * i] != 0 {
          h264_idct_dc_add(plane, off, ctx.cstride, mb, 256 + 256 * c + 16 * i)
        }
      }
    }
  } else {
    // No residual: predict only.
    let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
    let cbase = mb_y * 8 * ctx.cstride + mb_x * 8
    if is_i4x4 {
      for i = 0; i < 16; i = i + 1 {
        let bx = h264_luma_block_x[i]
        let by = h264_luma_block_y[i]
        let g = by * 4 + bx
        let off = ybase + by * 4 * ctx.ystride + bx * 4
        let top = by > 0 || mb_y > 0
        let left = bx > 0 || mb_x > 0
        let topright = if by == 0 {
          // Top-row blocks read the top MB's row; only bx == 3 needs the
          // top-right macroblock. Blocks are reconstructed in 8x8 z-order,
          // so a same-MB top-right block is causal for bx 0/2 and (1, even y).
          mb_y > 0 && (bx < 3 || mb_x < ctx.mb_width - 1)
        } else {
          bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)
        }
        match
          h264_pred4x4(ctx.y, off, ctx.ystride, modes[g], top, left, topright) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    } else {
      match
        h264_pred16x16(ctx.y, ybase, ctx.ystride, pred16, mb_y > 0, mb_x > 0) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    match
      h264_pred8x8(ctx.u, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match
      h264_pred8x8(ctx.v, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(())
}
