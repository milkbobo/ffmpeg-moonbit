///|
/// MoonBit port of the H.264 Baseline I-picture reconstruction path from
/// FFmpeg 9.0.2: the CAVLC macroblock parser (`ff_h264_decode_mb_cavlc`),
/// the `hl_decode_mb` intra reconstruction sequence (`h264_mb_template.c`),
/// and a minimal Annex B entry point.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope of this slice:
///   * Baseline / Constrained Baseline, 8-bit 4:2:0, frame-coded pictures,
///     CAVLC only, I slices, one slice per picture.
///   * I_4x4, I_16x16 and I_PCM macroblocks.
///   * 4x4 inverse transform, luma/chroma DC Hadamard transforms and the
///     intra predictors.
/// Out of scope (rejected explicitly): CABAC, P/B/SP/SI slices, interlaced or
/// MBAFF pictures, 8x8 transform, high bit depth, 4:2:2/4:4:4, multiple
/// slices per picture, and the in-loop deblocking filter. Output is therefore
/// meant to be compared against FFmpeg with `-skip_loop_filter all`.

///| FFmpeg luma 4x4 block order (8x8-grouped) to 4x4 raster grid x. */
let h264_luma_block_x : Array[Int] = [
  0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3,
]

///| FFmpeg luma 4x4 block order to 4x4 raster grid y. */
let h264_luma_block_y : Array[Int] = [
  0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3,
]

///| FFmpeg luma 4x4 block order to the `y * 4 + x` raster grid index. */
let h264_luma_block_grid : Array[Int] = [
  0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15,
]

///| CBP for the six I16x16 cbp classes (`mb_type` 1..24). */
let h264_i16x16_cbp : Array[Int] = [0, 16, 32, 15, 31, 47]

///| I16x16 prediction modes in FFmpeg's `pred16x16[]` enum (2/1/0/3 cycle). */
let h264_i16x16_pred : Array[Int] = [2, 1, 0, 3]

///| Per-macroblock information retained for neighbour prediction. */
priv struct H264MbInfo {
  ///| Non-zero coefficient counts in the C `h->non_zero_count` layout:
  ///| 0..15 luma raster, 16..19 Cb, 32..35 Cr (4:2:0).
  nz : Array[Int]
  ///| Intra4x4 prediction modes in raster grid order.
  modes : Array[Int]
  mut intra4x4 : Bool
  ///| Per-macroblock luma QP (`h->cur_pic.qscale_table[mb_xy]`), used by the
  ///| deblocking filter. I_PCM macroblocks store 0, matching `h264_cavlc.c`.
  mut qp : Int
}

///| A decoded H.264 frame: full MB-aligned planes plus cropping offsets. */
pub struct H264Frame {
  ///| Visible (cropped) width.
  width : Int
  ///| Visible (cropped) height.
  height : Int
  y : Array[Int]
  u : Array[Int]
  v : Array[Int]
  ystride : Int
  cstride : Int
  crop_left : Int
  crop_top : Int
}

///|
/// Pack the visible area as YUV420P, matching FFmpeg's rawvideo output for a
/// progressive 4:2:0 frame.
pub fn H264Frame::yuv420p(self : H264Frame) -> Bytes {
  let out : Array[Byte] = []
  for row = 0; row < self.height; row = row + 1 {
    let o = self.crop_left + (self.crop_top + row) * self.ystride
    for col = 0; col < self.width; col = col + 1 {
      out.push(self.y[o + col].to_byte())
    }
  }
  let cw = self.width / 2
  let ch = self.height / 2
  for plane = 0; plane < 2; plane = plane + 1 {
    let src = if plane == 0 { self.u } else { self.v }
    for row = 0; row < ch; row = row + 1 {
      let o = self.crop_left / 2 + (self.crop_top / 2 + row) * self.cstride
      for col = 0; col < cw; col = col + 1 {
        out.push(src[o + col].to_byte())
      }
    }
  }
  Bytes::from_array(out[:])
}

///| Decoder state for one I picture. */
priv struct H264DecCtx {
  pps : H264Pps
  mb_width : Int
  y : Array[Int]
  u : Array[Int]
  v : Array[Int]
  ystride : Int
  cstride : Int
  infos : Array[H264MbInfo]
  mut qscale : Int
}

///| Predicted Intra4x4 mode (`pred_intra_mode`). */
fn h264_pred_intra_mode(
  ctx : H264DecCtx,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  gx : Int,
  gy : Int,
  modes : Array[Int],
) -> Int {
  let left = if gx > 0 {
    modes[gy * 4 + gx - 1]
  } else if mb_x > 0 {
    let li = ctx.infos[mb_idx - 1]
    if li.intra4x4 {
      li.modes[gy * 4 + 3]
    } else {
      2
    }
  } else {
    -1
  }
  let top = if gy > 0 {
    modes[(gy - 1) * 4 + gx]
  } else if mb_y > 0 {
    let ti = ctx.infos[mb_idx - ctx.mb_width]
    if ti.intra4x4 {
      ti.modes[3 * 4 + gx]
    } else {
      2
    }
  } else {
    -1
  }
  if left < 0 || top < 0 {
    2
  } else if left < top {
    left
  } else {
    top
  }
}

///| Luma 4x4 block nC prediction from the retained neighbour counts. */
fn h264_nc_luma(
  ctx : H264DecCtx,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  gx : Int,
  gy : Int,
  nz : Array[Int],
) -> Int {
  let left = if gx > 0 {
    nz[gy * 4 + gx - 1]
  } else if mb_x > 0 {
    ctx.infos[mb_idx - 1].nz[gy * 4 + 3]
  } else {
    64
  }
  let top = if gy > 0 {
    nz[(gy - 1) * 4 + gx]
  } else if mb_y > 0 {
    ctx.infos[mb_idx - ctx.mb_width].nz[3 * 4 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///| Chroma AC block nC prediction (2x2 blocks per component). */
fn h264_nc_chroma(
  ctx : H264DecCtx,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  component : Int,
  i : Int,
  nz : Array[Int],
) -> Int {
  let base = 16 + 16 * component
  let gx = i % 2
  let gy = i / 2
  let left = if gx > 0 {
    nz[base + i - 1]
  } else if mb_x > 0 {
    ctx.infos[mb_idx - 1].nz[base + 1 + 2 * gy]
  } else {
    64
  }
  let top = if gy > 0 {
    nz[base + i - 2]
  } else if mb_y > 0 {
    ctx.infos[mb_idx - ctx.mb_width].nz[base + 2 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///| Decode one intra macroblock and reconstruct it into the frame planes. */
fn h264_decode_mb(
  gb : BitReader,
  ctx : H264DecCtx,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
) -> Result[Unit, String] {
  let pps = ctx.pps
  let mb_type_raw = gb.read_ue31()
  if mb_type_raw < 0 {
    return Err("invalid mb_type")
  }
  let mut is_i4x4 = false
  let mut is_i16x16 = false
  let mut is_pcm = false
  let mut cbp = 0
  let mut pred16 = 0
  if mb_type_raw == 0 {
    is_i4x4 = true
  } else if mb_type_raw >= 1 && mb_type_raw <= 24 {
    is_i16x16 = true
    let group = (mb_type_raw - 1) / 4
    cbp = h264_i16x16_cbp[group]
    pred16 = h264_i16x16_pred[(mb_type_raw - 1) % 4]
  } else if mb_type_raw == 25 {
    is_pcm = true
  } else {
    return Err("mb_type out of range for an I slice")
  }
  let info = ctx.infos[mb_idx]
  let nz = info.nz
  let mb : Array[Int] = Array::make(768, 0)
  let luma_dc : Array[Int] = Array::make(16, 0)
  let mut luma_dc_nz = 0
  let chroma_dc_nz : Array[Int] = Array::make(2, 0)
  let modes : Array[Int] = Array::make(16, 0)
  let mut chroma_mode = 0
  if is_pcm {
    gb.align()
    let samples = 256 + 128
    if gb.bits_left() < samples * 8 {
      return Err("not enough data for I_PCM")
    }
    let ybase = (mb_y * 16) * ctx.ystride + mb_x * 16
    for row = 0; row < 16; row = row + 1 {
      for col = 0; col < 16; col = col + 1 {
        ctx.y[ybase + row * ctx.ystride + col] = gb.read(8).reinterpret_as_int()
      }
    }
    for p = 0; p < 2; p = p + 1 {
      let plane = if p == 0 { ctx.u } else { ctx.v }
      let cbase = (mb_y * 8) * ctx.cstride + mb_x * 8
      for row = 0; row < 8; row = row + 1 {
        for col = 0; col < 8; col = col + 1 {
          plane[cbase + row * ctx.cstride + col] = gb.read(8).reinterpret_as_int()
        }
      }
    }
    for i = 0; i < 48; i = i + 1 {
      nz[i] = 16
    }
    info.intra4x4 = false
    // "In deblocking, the quantizer is 0" (h264_cavlc.c).
    info.qp = 0
    return Ok(())
  }
  if is_i4x4 {
    if pps.transform_8x8_mode != 0 && gb.read1() != 0U {
      return Err("8x8 transform is not supported")
    }
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let predicted = h264_pred_intra_mode(ctx, mb_idx, mb_x, mb_y, gx, gy, modes)
      let mode = if gb.read1() == 0U {
        let rem = gb.read(3).reinterpret_as_int()
        rem + (if rem >= predicted { 1 } else { 0 })
      } else {
        predicted
      }
      if mode > 8 {
        return Err("intra4x4 prediction mode out of range")
      }
      modes[gy * 4 + gx] = mode
    }
  }
  // Chroma prediction mode follows the luma intra modes / mb_type.
  {
    let cm = gb.read_ue31()
    if cm < 0 || cm > 3 {
      return Err("chroma prediction mode out of range")
    }
    chroma_mode = match h264_check_intra_pred_mode(cm, mb_y > 0, mb_x > 0) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  if is_i16x16 {
    pred16 = match h264_check_intra_pred_mode(pred16, mb_y > 0, mb_x > 0) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  if is_i4x4 {
    for gy = 0; gy < 4; gy = gy + 1 {
      for gx = 0; gx < 4; gx = gx + 1 {
        let g = gy * 4 + gx
        let top = gy > 0 || mb_y > 0
        let left = gx > 0 || mb_x > 0
        modes[g] = match h264_check_intra4x4_mode(modes[g], top, left) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
  }
  if !is_i16x16 {
    let cbp_code = gb.read_ue31()
    if cbp_code < 0 || cbp_code > 47 {
      return Err("cbp out of range")
    }
    cbp = h264_golomb_to_intra4x4_cbp[cbp_code]
  }
  let mut qmul_luma : Array[Int] = []
  if cbp != 0 || is_i16x16 {
    let dquant = gb.read_se()
    if dquant == -2147483648 {
      return Err("invalid mb_qp_delta")
    }
    let mut q = ctx.qscale + dquant
    if q < 0 || q > 51 {
      q = if q < 0 { q + 52 } else { q - 52 }
      if q < 0 || q > 51 {
        return Err("dquant out of range")
      }
    }
    ctx.qscale = q
    qmul_luma = h264_build_dequant4(pps, 0, q)
    let chroma_qp0 = h264_get_chroma_qp(pps, 0, q)
    let chroma_qp1 = h264_get_chroma_qp(pps, 1, q)
    if is_i16x16 {
      luma_dc_nz = match h264_decode_residual(
        gb,
        luma_dc,
        0,
        h264_zigzag_scan_t,
        0,
        None,
        16,
        h264_block0_nc(ctx, mb_idx, mb_x, mb_y),
      ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if (cbp & 15) != 0 {
        for i = 0; i < 16; i = i + 1 {
          let gx = h264_luma_block_x[i]
          let gy = h264_luma_block_y[i]
          let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz)
          let total = match h264_decode_residual(
            gb,
            mb,
            16 * i,
            h264_zigzag_scan_t,
            1,
            Some(qmul_luma),
            15,
            nc,
          ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          nz[gy * 4 + gx] = total
        }
      }
    } else {
      for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
        if (cbp & (1 << i8x8)) != 0 {
          for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
            let i = i8x8 * 4 + i4x4
            let gx = h264_luma_block_x[i]
            let gy = h264_luma_block_y[i]
            let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz)
            let total = match h264_decode_residual(
              gb,
              mb,
              16 * i,
              h264_zigzag_scan_t,
              0,
              Some(qmul_luma),
              16,
              nc,
            ) {
              Ok(v) => v
              Err(e) => return Err(e)
            }
            nz[gy * 4 + gx] = total
          }
        }
      }
    }
    if (cbp & 0x30) != 0 {
      for c = 0; c < 2; c = c + 1 {
        chroma_dc_nz[c] = match h264_decode_residual(
          gb,
          mb,
          256 + 256 * c,
          h264_chroma_dc_scan,
          0,
          None,
          4,
          0,
        ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
    if (cbp & 0x20) != 0 {
      for c = 0; c < 2; c = c + 1 {
        let cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
        let qmul_c = h264_build_dequant4(pps, 1 + c, cqp)
        for i = 0; i < 4; i = i + 1 {
          let nc = h264_nc_chroma(ctx, mb_idx, mb_x, mb_y, c, i, nz)
          let total = match h264_decode_residual(
            gb,
            mb,
            256 + 256 * c + 16 * i,
            h264_zigzag_scan_t,
            1,
            Some(qmul_c),
            15,
            nc,
          ) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          nz[16 + 16 * c + i] = total
        }
      }
    }
    // Reconstruction, following hl_decode_mb_predict_luma /
    // hl_decode_mb_idct_luma and the chroma path of h264_mb_template.c.
    let ybase = (mb_y * 16) * ctx.ystride + mb_x * 16
    let cbase = (mb_y * 8) * ctx.cstride + mb_x * 8
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
        match h264_pred4x4(ctx.y, off, ctx.ystride, modes[g], top, left, topright) {
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
    } else {
      match h264_pred16x16(ctx.y, ybase, ctx.ystride, pred16, mb_y > 0, mb_x > 0) {
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
    match h264_pred8x8(ctx.u, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match h264_pred8x8(ctx.v, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let chroma_qps : Array[Int] = [chroma_qp0, chroma_qp1]
    for c = 0; c < 2; c = c + 1 {
      if chroma_dc_nz[c] != 0 {
        let qmul_dc = h264_build_dequant4(pps, 1 + c, chroma_qps[c])[0]
        h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_dc)
      }
      let plane = if c == 0 { ctx.u } else { ctx.v }
      for i = 0; i < 4; i = i + 1 {
        let off = cbase + (i / 2) * 4 * ctx.cstride + (i % 2) * 4
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
    let ybase = (mb_y * 16) * ctx.ystride + mb_x * 16
    let cbase = (mb_y * 8) * ctx.cstride + mb_x * 8
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
        match h264_pred4x4(ctx.y, off, ctx.ystride, modes[g], top, left, topright) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    } else {
      match h264_pred16x16(ctx.y, ybase, ctx.ystride, pred16, mb_y > 0, mb_x > 0) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    match h264_pred8x8(ctx.u, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match h264_pred8x8(ctx.v, cbase, ctx.cstride, chroma_mode, mb_y > 0, mb_x > 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = modes[g]
  }
  info.intra4x4 = is_i4x4
  info.qp = ctx.qscale
  Ok(())
}

///|
/// nC for the I16x16 luma DC block: `pred_non_zero_count` of luma block 0's
/// left/top neighbours.
fn h264_block0_nc(
  ctx : H264DecCtx,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
) -> Int {
  let left = if mb_x > 0 { ctx.infos[mb_idx - 1].nz[3] } else { 64 }
  let top = if mb_y > 0 {
    ctx.infos[mb_idx - ctx.mb_width].nz[12]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
/// Decode one CAVLC I-slice NAL into a frame, including the in-loop deblocking
/// filter, i.e. what FFmpeg emits by default. The NAL is expected to be a
/// complete, single-slice picture starting at macroblock 0.
pub fn h264_decode_i_slice(
  nal : H2645Nal,
  ps : H264ParamSets,
) -> Result[H264Frame, String] {
  h264_decode_i_slice_ex(nal, ps, false)
}

///|
/// As `h264_decode_i_slice`, but `skip_loop_filter = true` leaves the
/// deblocking filter out, reproducing FFmpeg's `-skip_loop_filter all` output.
pub fn h264_decode_i_slice_ex(
  nal : H2645Nal,
  ps : H264ParamSets,
  skip_loop_filter : Bool,
) -> Result[H264Frame, String] {
  if nal.nal_type != h264_nal_idr_slice && nal.nal_type != 1 {
    return Err("not a coded slice NAL")
  }
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(8)
  let sh = match ff_h264_decode_slice_header(
    gb,
    nal.nal_type,
    nal.ref_idc,
    ps,
  ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if sh.slice_type_nos != 2 {
    return Err("only I slices are supported")
  }
  if sh.first_mb_in_slice != 0 {
    return Err("multi-slice pictures are not supported")
  }
  if sh.field_pic_flag != 0 {
    return Err("field pictures are not supported")
  }
  let pps = match ps.pps_list[sh.pps_id] {
    Some(p) => p
    None => return Err("missing PPS")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("missing SPS")
  }
  if pps.cabac != 0 {
    return Err("CABAC is not supported")
  }
  if pps.transform_8x8_mode != 0 {
    return Err("8x8 transform is not supported")
  }
  if sps.chroma_format_idc != 1 {
    return Err("only 4:2:0 is supported")
  }
  if sps.bit_depth_luma != 8 || sps.bit_depth_chroma != 8 {
    return Err("only 8-bit decoding is supported")
  }
  if sps.frame_mbs_only_flag == 0 || sps.mb_aff != 0 {
    return Err("interlaced pictures are not supported")
  }
  if sh.qscale < 0 || sh.qscale > 51 {
    return Err("slice QP out of range")
  }
  let mb_width = sps.mb_width
  let mb_height = sps.mb_height
  let mb_count = mb_width * mb_height
  let ystride = mb_width * 16
  let yheight = mb_height * 16
  let cstride = ystride / 2
  let cheight = yheight / 2
  let y : Array[Int] = Array::make(ystride * yheight, 0)
  let u : Array[Int] = Array::make(cstride * cheight, 0)
  let v : Array[Int] = Array::make(cstride * cheight, 0)
  let infos : Array[H264MbInfo] = []
  for _i = 0; _i < mb_count; _i = _i + 1 {
    infos.push({
      nz: Array::make(48, 0),
      modes: Array::make(16, 0),
      intra4x4: false,
      qp: 0,
    })
  }
  let ctx : H264DecCtx = {
    pps,
    mb_width,
    y,
    u,
    v,
    ystride,
    cstride,
    infos,
    qscale: sh.qscale,
  }
  // Deblocking parameters (`h264_loopfilter.c`, 8-bit so `qp_bd_offset` is 0).
  // `disable_deblocking_filter_idc == 1` disables the filter and `== 2` asks for
  // slice boundaries only, which for a single-slice picture filters nothing.
  let deblock = !skip_loop_filter && sh.disable_deblocking_filter_idc == 0
  let alpha_off = 52 + sh.slice_alpha_c0_offset
  let beta_off = 52 + sh.slice_beta_offset
  for i = 0; i < mb_count; i = i + 1 {
    match h264_decode_mb(gb, ctx, i, i % mb_width, i / mb_width) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  // Deblocking runs *after* the whole picture is reconstructed, in macroblock
  // raster order, exactly reproducing FFmpeg's observable behaviour:
  //
  //   * `decode_slice()` (`h264_slice.c`) reconstructs one macroblock row and
  //     then calls `loop_filter()` for that row, so the filter of row N sees
  //     row N-1 already filtered. Filtering never reads rows below the edge,
  //     so filtering a fully reconstructed picture row by row is equivalent.
  //   * Intra prediction never sees filtered samples: FFmpeg copies the row
  //     above into `sl->top_borders` *before* filtering and predicts from that
  //     copy. Predicting from the unfiltered reconstruction is equivalent.
  //
  // Filtering each macroblock immediately after decoding it (a tempting
  // simplification) breaks the second point and changes the reconstruction of
  // every macroblock that has a left or top neighbour.
  if deblock {
    for i = 0; i < mb_count; i = i + 1 {
      h264_filter_mb(ctx, i, i % mb_width, i / mb_width, alpha_off, beta_off)
    }
  }
  // `sps.crop_*` is already scaled to luma pixels by step_x/step_y in
  // `h264_ps.mbt` (`h264_ps.c:510-513`), so no further factor of two here:
  // `init_dimensions()` in `h264_slice.c` does `width = h->width - (cr + cl)`.
  let crop_x = sps.crop_left + sps.crop_right
  let crop_y = sps.crop_top + sps.crop_bottom
  let width = ystride - crop_x
  let height = yheight - crop_y
  if width <= 0 || height <= 0 {
    return Err("invalid cropping rectangle")
  }
  Ok({
    width,
    height,
    y,
    u,
    v,
    ystride,
    cstride,
    crop_left: sps.crop_left,
    crop_top: sps.crop_top,
  })
}

///|
/// Minimal Annex B I-frame decoder: parses SPS/PPS in-band and decodes every
/// coded-slice NAL as a standalone I picture, deblocking included (FFmpeg's
/// default output). Multi-slice pictures, P/B slices and non-Baseline features
/// return an error.
pub fn h264_decode_annexb_i_frames(data : Bytes) -> Result[Array[H264Frame], String] {
  h264_decode_annexb_i_frames_ex(data, false)
}

///|
/// As `h264_decode_annexb_i_frames`, with `skip_loop_filter = true` leaving the
/// in-loop deblocking filter out (FFmpeg's `-skip_loop_filter all`).
pub fn h264_decode_annexb_i_frames_ex(
  data : Bytes,
  skip_loop_filter : Bool,
) -> Result[Array[H264Frame], String] {
  let pkt = match ff_h2645_packet_split(data, 4, H264, false) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let ps = new_h264_param_sets()
  // A picture split into several slices would be decoded here as one standalone
  // picture per coded-slice NAL, i.e. silently truncated pixels. Only the first
  // field of a slice header is needed to detect that, so screen all slice NALs
  // before decoding anything (`ff_h264_decode_slice_header` checks
  // `first_mb_in_slice` the same way, but by then the previous slice has already
  // been reconstructed).
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    if nal.nal_type == h264_nal_idr_slice || nal.nal_type == 1 {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      if gb.read_ue() != 0 {
        return Err("multi-slice pictures are not supported")
      }
    }
  }
  let frames : Array[H264Frame] = []
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    if nal.nal_type == h264_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_seq_parameter_set(gb, ps, false) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_pps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_picture_parameter_set(gb, ps, gb.size_bits()) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_idr_slice || nal.nal_type == 1 {
      frames.push(match h264_decode_i_slice_ex(nal, ps, skip_loop_filter) {
        Ok(v) => v
        Err(e) => return Err(e)
      })
    }
  }
  Ok(frames)
}
