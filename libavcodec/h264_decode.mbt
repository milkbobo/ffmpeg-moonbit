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

///|
/// FFmpeg luma 4x4 block order (8x8-grouped) to 4x4 raster grid x. */
let h264_luma_block_x : Array[Int32] = [
  0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3,
]

///|
/// FFmpeg luma 4x4 block order to 4x4 raster grid y. */
let h264_luma_block_y : Array[Int32] = [
  0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3,
]

///|
/// FFmpeg luma 4x4 block order to the `y * 4 + x` raster grid index. */
let h264_luma_block_grid : Array[Int32] = [
  0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15,
]

///|
/// CBP for the six I16x16 cbp classes (`mb_type` 1..24). */
let h264_i16x16_cbp : Array[Int32] = [0, 16, 32, 15, 31, 47]

///|
/// I16x16 prediction modes in FFmpeg's `pred16x16[]` enum (2/1/0/3 cycle). */
let h264_i16x16_pred : Array[Int32] = [2, 1, 0, 3]

///|
/// Per-macroblock information retained for neighbour prediction. */
priv struct H264MbInfo {
  /// Non-zero coefficient counts in the C `h->non_zero_count` layout:
  ///| 0..15 luma raster, 16..19 Cb, 32..35 Cr (4:2:0).
  nz : Array[Int32]
  /// Intra4x4 prediction modes in raster grid order.
  modes : Array[Int32]
  mut intra4x4 : Bool
  /// Per-macroblock luma QP (`h->cur_pic.qscale_table[mb_xy]`), used by the
  ///| deblocking filter. I_PCM macroblocks store 0, matching `h264_cavlc.c`.
  mut qp : Int32
  /// FFmpeg `mb_type` bits (`MB_TYPE_INTRA4x4` / `_INTRA16x16` / `_INTRA_PCM`),
  ///| 0 when the macroblock has not been decoded yet. The CABAC neighbour
  ///| contexts read this (`sl->left_type` / `sl->top_type`).
  mut mb_type_bits : Int32
  /// `h->cbp_table[mb_xy]`: luma CBP in bits 0..3, chroma CBP in bits 4..5,
  ///| chroma DC non-zero flags in bits 6..7 and the luma DC flag in bit 8.
  ///| CABAC's `get_cabac_cbf_ctx` / `decode_cabac_mb_cbp_*` read the packed
  ///| form, so it is kept next to `nz`.
  mut cbp_all : Int32
  /// Raw `chroma_pred_mode` (0..3) as coded, for the CABAC chroma context.
  mut chroma_mode : Int32
  /// L0 motion vectors, quarter-pel, per 4x4 raster block (x = 2*i, y = 2*i+1);
  ///| `h264_mvpred.mbt` keeps the semantics of the C's `motion_val[0]`.
  mv : Array[Int32]
  /// L0 reference index per 4x4 raster block: `h264_ref_not_avail` (-2) for
  ///| an inter macroblock's unused blocks, `h264_ref_list_not_used` (-1) for
  ///| intra macroblocks.
  ref_idx : Array[Int32]
  /// Motion vector differences per 4x4 raster block (CABAC `mvd_cache`).
  mvd : Array[Int32]
}

///|
/// Reference picture planes (`H264Picture` data pointers in the C).
pub struct H264RefPic {
  y : Array[Int32]
  u : Array[Int32]
  v : Array[Int32]
  ystride : Int32
  cstride : Int32
  /// Full-plane dimensions in pixels (macroblock aligned).
  width : Int32
  height : Int32
}

///|
/// A decoded H.264 frame: full MB-aligned planes plus cropping offsets. */
pub struct H264Frame {
  /// Visible (cropped) width.
  width : Int32
  /// Visible (cropped) height.
  height : Int32
  /// Full macroblock-aligned plane height (`mb_height * 16`); the planes are
  /// `ystride` x `pheight`. Motion compensation clamps against it.
  pheight : Int32
  y : Array[Int32]
  u : Array[Int32]
  v : Array[Int32]
  ystride : Int32
  cstride : Int32
  crop_left : Int32
  crop_top : Int32
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

///|
/// Decoder state for one I picture. */
priv struct H264DecCtx {
  pps : H264Pps
  mb_width : Int32
  y : Array[Int32]
  u : Array[Int32]
  v : Array[Int32]
  ystride : Int32
  cstride : Int32
  infos : Array[H264MbInfo]
  mut qscale : Int32
  /// `sl->last_qscale_diff`: selects the `mb_qp_delta` CABAC context.
  mut last_qscale_diff : Int32
  /// `sl->slice_type_nos` (0 P, 2 I) of the slice being decoded.
  slice_type_nos : Int32
  /// Whether the macroblock being decoded is intra; selects the inter
  ///| defaults for unavailable CABAC cbp/nz neighbours (`fill_decode_caches`).
  mut cur_mb_is_intra : Bool
  /// `sl->ref_count[0]`: active L0 references for the current slice.
  ref_count0 : Int32
  /// The L0 reference picture list (`h->ref_list[0]`), planes only.
  ref_list0 : Array[H264RefPic]
  /// CAVLC `sl->mb_skip_run`; -1 means the next macroblock reads a new run.
  mut mb_skip_run : Int32
}

///|
/// Predicted Intra4x4 mode (`pred_intra_mode`). */
fn h264_pred_intra_mode(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  gx : Int32,
  gy : Int32,
  modes : Array[Int32],
) -> Int32 {
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

///|
/// Luma 4x4 block nC prediction from the retained neighbour counts. */
fn h264_nc_luma(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  gx : Int32,
  gy : Int32,
  nz : Array[Int32],
) -> Int32 {
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

///|
/// Chroma AC block nC prediction (2x2 blocks per component). */
fn h264_nc_chroma(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  component : Int32,
  i : Int32,
  nz : Array[Int32],
) -> Int32 {
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

///| Decode one macroblock: the CAVLC path of `ff_h264_decode_mb_cavlc`,

///|
/// extended with the P-slice prelude (`mb_skip_run`) and the inter branch.
fn h264_decode_mb(
  gb : BitReader,
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Result[Unit, String] {
  let pps = ctx.pps
  if ctx.slice_type_nos != 2 {
    // `mb_skip_run`: -1 means "read a new run" (the value after a coded
    // macroblock, matching `sl->mb_skip_run--` in the C).
    if ctx.mb_skip_run == -1 {
      let run = gb.read_ue()
      if run < 0 || run > ctx.mb_width * (ctx.infos.length() / ctx.mb_width) {
        return Err("mb_skip_run is invalid")
      }
      ctx.mb_skip_run = run
    }
    if ctx.mb_skip_run > 0 {
      ctx.mb_skip_run = ctx.mb_skip_run - 1
      return h264_decode_mb_skip_common(ctx, mb_idx, mb_x, mb_y)
    }
    ctx.mb_skip_run = ctx.mb_skip_run - 1
  }
  ctx.cur_mb_is_intra = true
  let mut mb_type_raw = gb.read_ue31()
  if mb_type_raw < 0 {
    return Err("invalid mb_type")
  }
  if ctx.slice_type_nos != 2 {
    if mb_type_raw <= 4 {
      return h264_decode_mb_cavlc_p(gb, ctx, mb_idx, mb_x, mb_y, mb_type_raw)
    }
    if mb_type_raw > 30 {
      return Err("mb_type out of range for a P slice")
    }
    // Intra macroblock in a P slice: `mb_type` 5..30 codes the intra types
    // shifted by 5 (`ff_h264_decode_mb_cavlc`).
    mb_type_raw = mb_type_raw - 5
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
  let mb : Array[Int32] = Array::make(768, 0)
  let luma_dc : Array[Int32] = Array::make(16, 0)
  let mut luma_dc_nz = 0
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let modes : Array[Int32] = Array::make(16, 0)
  let mut chroma_mode = 0
  if is_pcm {
    gb.align()
    let samples = 256 + 128
    if gb.bits_left() < samples * 8 {
      return Err("not enough data for I_PCM")
    }
    let ybase = mb_y * 16 * ctx.ystride + mb_x * 16
    for row = 0; row < 16; row = row + 1 {
      for col = 0; col < 16; col = col + 1 {
        ctx.y[ybase + row * ctx.ystride + col] = gb.read(8).reinterpret_as_int()
      }
    }
    for p = 0; p < 2; p = p + 1 {
      let plane = if p == 0 { ctx.u } else { ctx.v }
      let cbase = mb_y * 8 * ctx.cstride + mb_x * 8
      for row = 0; row < 8; row = row + 1 {
        for col = 0; col < 8; col = col + 1 {
          plane[cbase + row * ctx.cstride + col] = gb
            .read(8)
            .reinterpret_as_int()
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
      let predicted = h264_pred_intra_mode(
        ctx, mb_idx, mb_x, mb_y, gx, gy, modes,
      )
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
  let mut raw_cm = 0
  {
    let cm = gb.read_ue31()
    raw_cm = cm
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
  let mut qmul_luma : Array[Int32] = []
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
      luma_dc_nz = match
        h264_decode_residual(
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
          let total = match
            h264_decode_residual(
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
            let total = match
              h264_decode_residual(
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
        chroma_dc_nz[c] = match
          h264_decode_residual(
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
          let total = match
            h264_decode_residual(
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
    match
      h264_recon_mb(
        ctx, mb_x, mb_y, is_i4x4, is_i16x16, pred16, chroma_mode, modes, cbp, luma_dc_nz,
        chroma_dc_nz, chroma_qp0, chroma_qp1, qmul_luma, mb, luma_dc, nz,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  for g = 0; g < 16; g = g + 1 {
    info.modes[g] = modes[g]
  }
  info.intra4x4 = is_i4x4
  info.mb_type_bits = if is_i16x16 {
    h264_mb_type_intra16x16
  } else {
    h264_mb_type_intra4x4
  }
  info.cbp_all = cbp
  info.chroma_mode = raw_cm
  info.qp = ctx.qscale
  Ok(())
}

///|
/// nC for the I16x16 luma DC block: `pred_non_zero_count` of luma block 0's
/// left/top neighbours.
fn h264_block0_nc(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let left = if mb_x > 0 { ctx.infos[mb_idx - 1].nz[3] } else { 64 }
  let top = if mb_y > 0 { ctx.infos[mb_idx - ctx.mb_width].nz[12] } else { 64 }
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
  h264_decode_slice_ex(nal, ps, [], skip_loop_filter)
}

///|
/// Generalized single-slice picture decoder: as `h264_decode_i_slice_ex`,
/// but P slices are decoded against `ref_list0` (most recent reference
/// first, matching `h->ref_list[0]` for a plain sliding-window DPB).
fn h264_decode_slice_ex(
  nal : H2645Nal,
  ps : H264ParamSets,
  ref_list0 : Array[H264RefPic],
  skip_lf : Bool,
) -> Result[H264Frame, String] {
  if nal.nal_type != h264_nal_idr_slice && nal.nal_type != 1 {
    return Err("not a coded slice NAL")
  }
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(8)
  let sh = match
    ff_h264_decode_slice_header(gb, nal.nal_type, nal.ref_idc, ps) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if sh.slice_type_nos != 2 && sh.slice_type_nos != 0 {
    return Err("only I and P slices are supported")
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
  let y : Array[Int32] = Array::make(ystride * yheight, 0)
  let u : Array[Int32] = Array::make(cstride * cheight, 0)
  let v : Array[Int32] = Array::make(cstride * cheight, 0)
  let infos : Array[H264MbInfo] = []
  for _i = 0; _i < mb_count; _i = _i + 1 {
    infos.push({
      nz: Array::make(48, 0),
      modes: Array::make(16, 0),
      intra4x4: false,
      qp: 0,
      mb_type_bits: 0,
      cbp_all: 0,
      chroma_mode: 0,
      mv: Array::make(32, 0),
      ref_idx: Array::make(16, h264_ref_not_avail),
      mvd: Array::make(32, 0),
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
    last_qscale_diff: 0,
    slice_type_nos: sh.slice_type_nos,
    cur_mb_is_intra: true,
    ref_count0: sh.num_ref_idx_l0_active,
    ref_list0,
    mb_skip_run: -1,
  }
  // Deblocking parameters (`h264_loopfilter.c`, 8-bit so `qp_bd_offset` is 0).
  // `disable_deblocking_filter_idc == 1` disables the filter and `== 2` asks for
  // slice boundaries only, which for a single-slice picture filters nothing.
  let deblock = !skip_lf && sh.disable_deblocking_filter_idc == 0
  let alpha_off = 52 + sh.slice_alpha_c0_offset
  let beta_off = 52 + sh.slice_beta_offset
  if pps.cabac != 0 {
    // `decode_slice()` with CABAC: realign the bit reader, hand the rest of
    // the NAL to the arithmetic decoder, then read `end_of_slice_flag`
    // (`get_cabac_terminate`) after every macroblock.
    gb.align()
    let cabac = match ff_init_cabac_decoder(nal.data, gb.count() / 8) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let states = ff_h264_init_cabac_states(
      sh.qscale,
      8,
      sh.slice_type_nos,
      sh.cabac_init_flag,
    )
    for i = 0; i < mb_count; i = i + 1 {
      match
        h264_decode_mb_cabac(cabac, states, ctx, i, i % mb_width, i / mb_width) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      // `end_of_slice_flag`
      if cabac.get_cabac_terminate() != 0 {
        break
      }
    }
  } else {
    for i = 0; i < mb_count; i = i + 1 {
      match h264_decode_mb(gb, ctx, i, i % mb_width, i / mb_width) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
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
    pheight: yheight,
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
pub fn h264_decode_annexb_i_frames(
  data : Bytes,
) -> Result[Array[H264Frame], String] {
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
      frames.push(
        match h264_decode_i_slice_ex(nal, ps, skip_loop_filter) {
          Ok(v) => v
          Err(e) => return Err(e)
        },
      )
    }
  }
  Ok(frames)
}

///|
/// Decode H.264 pictures from MP4-style access units: `extradata` is the
/// `avcC` record (or an Annex B parameter-set blob) and every entry of
/// `samples` is one length-prefixed access unit. `nal_length_size` comes from
/// the `avcC` header (`ff_h264_decode_extradata`), which is what the C gets
/// from `AVCodecParameters.nal_length_size`.
///
/// Samples may carry parameter sets, SEI (skipped) and one coded-slice NAL per
/// picture; the scope limits of `h264_decode_i_slice_ex` still apply (single
/// slice, I or P pictures, 8-bit 4:2:0 progressive).
pub fn h264_decode_avc_frames(
  extradata : Bytes,
  samples : Array[Bytes],
  skip_loop_filter : Bool,
) -> Result[Array[H264Frame], String] {
  // The extradata SPS/PPS feed the persistent decoder state so that P
  // pictures can reference the I picture across samples (`H264Decoder`).
  let dec = new_h264_decoder()
  let info = match ff_h264_decode_extradata(extradata, dec.ps) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let frames : Array[H264Frame] = []
  for s = 0; s < samples.length(); s = s + 1 {
    match
      dec.decode_avc_sample(samples[s], info.nal_length_size, skip_loop_filter) {
      Ok(None) => ()
      Ok(Some(f)) => frames.push(f)
      Err(e) => return Err(e)
    }
  }
  Ok(frames)
}
