///|
/// MoonBit port of the macroblock *reconstruction* half of FFmpeg 9.0.2
/// `libavcodec/h264_mb_template.c` (`hl_decode_mb_predict_luma` /
/// `hl_decode_mb_idct_luma` and the chroma paths of `hl_decode_mb` /
/// `hl_decode_mb_444`).
/// The parse halves live in `h264_decode.mbt` (CAVLC) and `h264_cabac_mb.mbt`
/// (CABAC); both feed this function so the pixel path is shared.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// 4:4:4 reconstructs each chroma plane through the luma machinery
/// (`hl_decode_mb_predict_luma(..., p)`), 4:2:2 uses the 8x16 chroma
/// prediction and the 2x4 DC Hadamard, 4:2:0 keeps the 8x8/2x2 path.

///|
/// `hl_decode_mb_predict_luma` + `hl_decode_mb_idct_luma` for one full-size
/// plane (`p` selects the dequant/DC scratch, all blocks 16x16 per MB).
/// `nz_base` is the plane's base in `nz` and `mb_off` in `mb`.
fn h264_recon_full_plane(
  ctx : H264DecCtx,
  dst : Array[Int32],
  base : Int32,
  stride : Int32,
  mb_idx : Int32,
  mb_x : Int32,
  is_i4x4 : Bool,
  is_i16x16 : Bool,
  pred_mode : Int32,
  modes : Array[Int32],
  cbp : Int32,
  dc : Array[Int32],
  dc_nz : Int32,
  dc_mul : Int32,
  nz : Array[Int32],
  mb : Array[Int32],
  mb_off : Int32,
  nz_base : Int32,

  bit_depth? : Int32 = 8,
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  if is_i4x4 {
    if info.transform_8x8 {
      for i8 = 0; i8 < 4; i8 = i8 + 1 {
        let bx8 = i8 % 2
        let by8 = i8 / 2
        let off = base + by8 * 8 * stride + bx8 * 8
        let mode = modes[(by8 * 2) * 4 + bx8 * 2]
        let top = by8 > 0 || h264_intra_top(ctx, mb_idx)
        let left = bx8 > 0 || h264_intra_left(ctx, mb_idx)
        let topright = if by8 == 0 {
          top && (bx8 == 0 || (mb_x < ctx.mb_width - 1 && h264_intra_available(ctx, mb_idx - ctx.mb_width + 1)))
        } else {
          bx8 == 0
        }
        match
          h264_pred8x8l(dst, off, stride, mode, top, left, topright,
            topleft=h264_intra_topleft(ctx, mb_idx, bx8, by8), bit_depth=bit_depth) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        if (cbp & (1 << i8)) != 0 {
          h264_idct8_add4(dst, off, stride, mb, mb_off + 64 * i8, nz, i8, nz_base=nz_base, bit_depth=bit_depth)
        }
      }
    } else {
      for i = 0; i < 16; i = i + 1 {
        let bx = h264_luma_block_x[i]
        let by = h264_luma_block_y[i]
        let g = by * 4 + bx
        let off = base + by * 4 * stride + bx * 4
        let top = by > 0 || h264_intra_top(ctx, mb_idx)
        let left = bx > 0 || h264_intra_left(ctx, mb_idx)
        let topright = if by == 0 {
          h264_intra_top(ctx, mb_idx) && (bx < 3 || (mb_x < ctx.mb_width - 1 && h264_intra_available(ctx, mb_idx - ctx.mb_width + 1)))
        } else {
          bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)
        }
        match
          h264_pred4x4(dst, off, stride, modes[g], top, left, topright, bit_depth=bit_depth) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        if nz[nz_base + g] != 0 {
          if nz[nz_base + g] == 1 && mb[mb_off + 16 * i] != 0 {
            h264_idct_dc_add(dst, off, stride, mb, mb_off + 16 * i, bit_depth=bit_depth)
          } else {
            h264_idct_add(dst, off, stride, mb, mb_off + 16 * i, bit_depth=bit_depth)
          }
        }
      }
    }
  } else {
    match
      h264_pred16x16(dst, base, stride, pred_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=bit_depth) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if dc_nz != 0 {
      h264_luma_dc_dequant_idct(mb, mb_off, dc, 0, dc_mul, bit_depth=bit_depth)
    }
    for i = 0; i < 16; i = i + 1 {
      let bx = h264_luma_block_x[i]
      let by = h264_luma_block_y[i]
      let off = base + by * 4 * stride + bx * 4
      let g = h264_luma_block_grid[i]
      if nz[nz_base + g] != 0 {
        h264_idct_add(dst, off, stride, mb, mb_off + 16 * i, bit_depth=bit_depth)
      } else if mb[mb_off + 16 * i] != 0 {
        h264_idct_dc_add(dst, off, stride, mb, mb_off + 16 * i, bit_depth=bit_depth)
      }
    }
  }
  ignore(is_i16x16)
  Ok(())
}

///|
/// Reconstruct one intra macroblock from its dequantised coefficients.
/// `nz` is the per-macroblock `non_zero_count` array, `modes` the Intra4x4
/// modes in raster grid order and `mb` the 768-entry coefficient block
/// (0..255 luma, 256..511 Cb, 512..767 Cr). `luma_dc` holds one DC block per
/// plane (planes 1/2 used by 4:4:4), `luma_dc_nz`/`plane_dc_mul` one entry
/// per plane, `chroma_dc_nz` the 4:2:0/4:2:2 chroma DC presence flags.
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
  luma_dc_nz : Array[Int32],
  chroma_dc_nz : Array[Int32],
  chroma_qp0 : Int32,
  chroma_qp1 : Int32,
  plane_dc_mul : Array[Int32],
  mb : Array[Int32],
  luma_dc : Array[Array[Int32]],
  nz : Array[Int32],
) -> Result[Unit, String] {
  let mb_idx = mb_y * ctx.mb_width + mb_x
  let pps = ctx.pps
  if cbp != 0 || is_i16x16 || ctx.infos[mb_idx].transform_8x8 {
    let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
    match
      h264_recon_full_plane(
        ctx, ctx.y, ybase, ctx.ystride, mb_idx, mb_x, is_i4x4, is_i16x16, pred16,
        modes, cbp, luma_dc[0], luma_dc_nz[0], plane_dc_mul[0], nz, mb, 0, 0,
        bit_depth=ctx.bit_depth,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if ctx.chroma_format == 3 {
      // 4:4:4: chroma planes reuse the luma prediction/residual machinery
      // with the chroma QP and per-plane dequant tables.
      let cbase = mb_y * 16 * ctx.cstride + mb_x * 16
      let chroma_qps = [chroma_qp0, chroma_qp1]
      for p = 1; p < 3; p = p + 1 {
        let plane = if p == 1 { ctx.u } else { ctx.v }
        match
          h264_recon_full_plane(
            ctx, plane, cbase, ctx.cstride, mb_idx, mb_x, is_i4x4, is_i16x16,
            pred16, modes, cbp, luma_dc[p], luma_dc_nz[p], plane_dc_mul[p], nz, mb,
            256 * p, 16 * p,
            bit_depth=ctx.bit_depth,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        ignore(chroma_qps)
      }
    } else {
      let cw = 16 >> ctx.chroma_hshift
      let ch = 16 >> ctx.chroma_vshift
      let cbase = mb_y * ch * ctx.cstride + mb_x * cw
      let pred = if ctx.chroma_format == 2 {
        h264_pred8x16(ctx.u, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      } else {
        h264_pred8x8(ctx.u, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      }
      match pred {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      let pred_v = if ctx.chroma_format == 2 {
        h264_pred8x16(ctx.v, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      } else {
        h264_pred8x8(ctx.v, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      }
      match pred_v {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      h264_chroma_residual_intra(ctx, cbase, chroma_dc_nz, chroma_qp0, chroma_qp1, cbp, mb, nz)
    }
  } else {
    // No residual: predict only.
    let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
    if is_i4x4 {
      for i = 0; i < 16; i = i + 1 {
        let bx = h264_luma_block_x[i]
        let by = h264_luma_block_y[i]
        let g = by * 4 + bx
        let off = ybase + by * 4 * ctx.ystride + bx * 4
        let top = by > 0 || h264_intra_top(ctx, mb_idx)
        let left = bx > 0 || h264_intra_left(ctx, mb_idx)
        let topright = if by == 0 {
          // Top-row blocks read the top MB's row; only bx == 3 needs the
          // top-right macroblock. Blocks are reconstructed in 8x8 z-order,
          // so a same-MB top-right block is causal for bx 0/2 and (1, even y).
          h264_intra_top(ctx, mb_idx) && (bx < 3 || (mb_x < ctx.mb_width - 1 && h264_intra_available(ctx, mb_idx - ctx.mb_width + 1)))
        } else {
          bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)
        }
        match
          h264_pred4x4(ctx.y, off, ctx.ystride, modes[g], top, left, topright, bit_depth=ctx.bit_depth) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    } else {
      match
        h264_pred16x16(ctx.y, ybase, ctx.ystride, pred16, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    if ctx.chroma_format == 3 {
      let cbase = mb_y * 16 * ctx.cstride + mb_x * 16
      if is_i4x4 {
        for i = 0; i < 16; i = i + 1 {
          let bx = h264_luma_block_x[i]
          let by = h264_luma_block_y[i]
          let g = by * 4 + bx
          let off = cbase + by * 4 * ctx.cstride + bx * 4
          let top = by > 0 || h264_intra_top(ctx, mb_idx)
          let left = bx > 0 || h264_intra_left(ctx, mb_idx)
          let topright = if by == 0 {
            h264_intra_top(ctx, mb_idx) && (bx < 3 || (mb_x < ctx.mb_width - 1 && h264_intra_available(ctx, mb_idx - ctx.mb_width + 1)))
          } else {
            bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)
          }
          for plane in [ctx.u, ctx.v] {
            match
              h264_pred4x4(plane, off, ctx.cstride, modes[g], top, left, topright, bit_depth=ctx.bit_depth) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
          }
        }
      } else {
        for plane in [ctx.u, ctx.v] {
          match
            h264_pred16x16(plane, cbase, ctx.cstride, pred16, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
    } else {
      let cw = 16 >> ctx.chroma_hshift
      let ch = 16 >> ctx.chroma_vshift
      let cbase = mb_y * ch * ctx.cstride + mb_x * cw
      let pred = if ctx.chroma_format == 2 {
        h264_pred8x16(ctx.u, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      } else {
        h264_pred8x8(ctx.u, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      }
      match pred {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      let pred_v = if ctx.chroma_format == 2 {
        h264_pred8x16(ctx.v, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      } else {
        h264_pred8x8(ctx.v, cbase, ctx.cstride, chroma_mode, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx), bit_depth=ctx.bit_depth)
      }
      match pred_v {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  ignore(pps)
  Ok(())
}

///|
/// Intra chroma DC fold + AC add for 4:2:0/4:2:2 (`hl_decode_mb`'s
/// `(sl->cbp & 0x30)` block): intra dequant tables 1/2.
fn h264_chroma_residual_intra(
  ctx : H264DecCtx,
  cbase : Int32,
  chroma_dc_nz : Array[Int32],
  chroma_qp0 : Int32,
  chroma_qp1 : Int32,
  cbp : Int32,
  mb : Array[Int32],
  nz : Array[Int32],
) -> Unit {
  let num_c8x8 = ctx.chroma_format
  let chroma_qps = [chroma_qp0, chroma_qp1]
  for c = 0; c < 2; c = c + 1 {
    if chroma_dc_nz[c] != 0 {
      let mut cqp = chroma_qps[c]
      // The 2x4 DC Hadamard's gain halves the dequant scale, compensated
      // by indexing the table three QP steps up (`h264_mb_template.c`).
      if num_c8x8 == 2 {
        cqp = cqp + 3
      }
      let qmul_dc = h264_build_dequant4(ctx.pps, 1 + c, cqp)[0]
      if num_c8x8 == 2 {
        h264_chroma422_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc, bit_depth=ctx.bit_depth)
      } else {
        h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc, bit_depth=ctx.bit_depth)
      }
    }
    let plane = if c == 0 { ctx.u } else { ctx.v }
    for i = 0; i < 4 * num_c8x8; i = i + 1 {
      // 4:2:2 blocks are two vertically stacked 8x8s: `i` is
      // `8 * i8x8 + i4x4` with i4x4 the 2x2 raster inside each 8x8.
      let bx = i % 2
      let by = i / 2
      let off = cbase + by * 4 * ctx.cstride + bx * 4
      let g = 16 + 16 * c + i
      if nz[g] != 0 {
        h264_idct_add(plane, off, ctx.cstride, mb, 256 + 256 * c + 16 * i, bit_depth=ctx.bit_depth)
      } else if mb[256 + 256 * c + 16 * i] != 0 {
        h264_idct_dc_add(plane, off, ctx.cstride, mb, 256 + 256 * c + 16 * i, bit_depth=ctx.bit_depth)
      }
    }
  }
  ignore(cbp)
}
