///|
/// MoonBit port of FFmpeg 9.0.2 progressive H.264 I/P reconstruction:
/// CAVLC/CABAC macroblocks, 4x4/8x8 transforms, intra/inter prediction,
/// multiple slices sharing one picture and the in-loop deblocking filter.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: 8..14-bit 4:0:0/4:2:0/4:2:2/4:4:4 frame-coded I/P/B pictures,
/// CAVLC/CABAC, 4x4/8x8, I_PCM, slice-local prediction, weighted prediction
/// and MBAFF frame pictures (all-field or all-frame pairs). The persistent
/// reference/POC/MMCO state lives in h264_dpb.mbt. SP/SI reconstruction, field
/// pictures (PAFF), mixed field/frame MBAFF pairs and transform bypass remain
/// unfinished.

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
  mut slice_num : Int32
  mut deblock_idc : Int32
  mut alpha_offset : Int32
  mut beta_offset : Int32
  ref_identity : Array[Int32]
  mv1 : Array[Int32]
  ref_idx1 : Array[Int32]
  mvd1 : Array[Int32]
  ref_identity1 : Array[Int32]
  direct : Array[Bool]
  /// Non-zero coefficient counts in the C `h->non_zero_count` layout:
  ///| 0..15 luma raster, 16..19 Cb, 32..35 Cr (4:2:0).
  nz : Array[Int32]
  /// Intra4x4 prediction modes in raster grid order.
  modes : Array[Int32]
  mut intra4x4 : Bool
  /// `MB_TYPE_INTERLACED`: the macroblock is field-coded inside an MBAFF pair.
  mut field_mb : Bool
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
  /// `MB_TYPE_8x8DCT`: luma uses one 8x8 transform per quadrant.
  mut transform_8x8 : Bool
}

///|
/// Reference picture planes (`H264Picture` data pointers in the C).
pub struct H264RefPic {
  /// Decoder-local identity, independent of repeated/negative POC values.
  identity : Int32
  y : Array[Int32]
  u : Array[Int32]
  v : Array[Int32]
  ystride : Int32
  cstride : Int32
  /// Full-plane dimensions in pixels (macroblock aligned).
  width : Int32
  height : Int32
  /// Chroma plane dimensions in pixels (macroblock aligned); the border
  /// replication bounds of chroma motion compensation.
  cwidth : Int32
  cheight : Int32
  /// Picture order count, used as the deblocking `ref2frm` identity.
  poc : Int32
  field_poc_top : Int32
  field_poc_bottom : Int32
  /// MBAFF field view: plane base offsets (top field 0, bottom field one
  /// frame/chroma row) and parity (1 top, 2 bottom; 0 for frame pictures).
  base_y : Int32
  base_u : Int32
  base_v : Int32
  parity : Int32
}

///|
/// A decoded H.264 frame: full MB-aligned planes plus cropping offsets. */
pub struct H264Frame {
  bit_depth : Int32
  priv epoch : Int32
  priv reorder_depth : Int32
  priv no_output_prior : Bool
  /// Picture order count; batch output retains decoding order.
  poc : Int32
  priv infos : Array[H264MbInfo]
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
  /// Chroma subsampling: `cw = width >> hshift`, `ch = height >> vshift`.
  chroma_hshift : Int32
  chroma_vshift : Int32
}

///|
/// Pack the visible area as planar YUV, matching FFmpeg's rawvideo output
/// (`yuv420p`/`yuv422p`/`yuv444p` by chroma format; the generic entry keeps
/// the historical name).
pub fn H264Frame::yuv420p(self : H264Frame) -> Bytes {
  self.yuvp()
}

///|
/// Pack the visible area as planar YUV of the frame's chroma format. */
pub fn H264Frame::yuvp(self : H264Frame) -> Bytes {
  let out : Array[Byte] = []
  for row = 0; row < self.height; row = row + 1 {
    let o = self.crop_left + (self.crop_top + row) * self.ystride
    for col = 0; col < self.width; col = col + 1 {
      let sample = self.y[o + col]
      out.push(sample.to_byte())
      if self.bit_depth > 8 { out.push((sample >> 8).to_byte()) }
    }
  }
  let cw = self.width >> self.chroma_hshift
  let ch = self.height >> self.chroma_vshift
  let ccrop_l = self.crop_left >> self.chroma_hshift
  let ccrop_t = self.crop_top >> self.chroma_vshift
  for plane = 0; plane < 2; plane = plane + 1 {
    let src = if plane == 0 { self.u } else { self.v }
    for row = 0; row < ch; row = row + 1 {
      let o = ccrop_l + (ccrop_t + row) * self.cstride
      for col = 0; col < cw; col = col + 1 {
        let sample = src[o + col]
        out.push(sample.to_byte())
        if self.bit_depth > 8 { out.push((sample >> 8).to_byte()) }
      }
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Shared planes and slice-local syntax state for one progressive I/P picture.
priv struct H264DecCtx {
  bit_depth : Int32
  /// `sps.chroma_format_idc`: 1 (4:2:0), 2 (4:2:2) or 3 (4:4:4).
  chroma_format : Int32
  /// Chroma plane shifts derived from `chroma_format` (`chroma_x_shift`,
  /// `chroma_y_shift` in `h264_slice.c`).
  chroma_hshift : Int32
  chroma_vshift : Int32
  mut si_slice : Bool
  mut active_list : Int32
  mut ref_list1 : Array[H264RefPic]
  mut ref_count1 : Int32
  mut direct_spatial : Bool
  direct_8x8 : Bool
  mut colocated : Array[H264MbInfo]
  mut poc : Int32
  mut poc_top : Int32
  mut poc_bottom : Int32
  mut long_pocs : Array[Int32]
  mut slice_num : Int32
  pps : H264Pps
  mb_width : Int32
  mb_height : Int32
  /// `FRAME_MBAFF(h)`: MBAFF frame picture (adaptive field/frame MB pairs).
  mb_aff : Bool
  /// `MB_FIELD(sl)`: the macroblock currently being decoded is field-coded.
  mut mb_field : Bool
  /// CABAC MBAFF skip lookahead (`sl->prev_mb_skipped/next_mb_skipped`).
  mut prev_mb_skipped : Bool
  mut next_mb_skipped : Bool
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
  mut slice_type_nos : Int32
  /// Whether the macroblock being decoded is intra; selects the inter
  ///| defaults for unavailable CABAC cbp/nz neighbours (`fill_decode_caches`).
  mut cur_mb_is_intra : Bool
  /// `sl->ref_count[0]`: active L0 references for the current slice.
  mut ref_count0 : Int32
  /// The L0 reference picture list (`h->ref_list[0]`), planes only.
  mut ref_list0 : Array[H264RefPic]
  /// CAVLC `sl->mb_skip_run`; -1 means the next macroblock reads a new run.
  mut mb_skip_run : Int32
  /// `sl->pwt`: explicit weighted prediction for P slices.
  mut pwt : H264PredWeight
}

///|
/// `h264_fill_mbaff_ref_list`: frame refs stay at 0..15, top/bottom field
/// views go to 16+2*i and 17+2*i with doubled strides and half heights.
fn h264_fill_mbaff_refs(frames : Array[H264RefPic], mb_aff : Bool) -> Array[H264RefPic] {
  if !mb_aff || frames.length() == 0 {
    return frames
  }
  let n = frames.length()
  let list : Array[H264RefPic] = []
  for i = 0; i < 16; i = i + 1 {
    list.push(if i < n { frames[i] } else { frames[0] })
  }
  for i = 0; i < n; i = i + 1 {
    let f = frames[i]
    list.push({
      ..f,
      ystride: f.ystride * 2,
      cstride: f.cstride * 2,
      height: f.height / 2,
      cheight: f.cheight / 2,
      base_y: 0,
      base_u: 0,
      base_v: 0,
      parity: 1,
      poc: f.field_poc_top,
    })
    list.push({
      ..f,
      ystride: f.ystride * 2,
      cstride: f.cstride * 2,
      height: f.height / 2,
      cheight: f.cheight / 2,
      base_y: f.ystride,
      base_u: f.cstride,
      base_v: f.cstride,
      parity: 2,
      poc: f.field_poc_bottom,
    })
  }
  list
}

///|
/// Deblocking reference id after `ref2frm`: frame MBs use `4*id+3`, field MBs
/// `4*id + (r even ? 1 : 2)` (top/bottom field of every other ref list entry).
fn h264_deblock_ref_id(ctx : H264DecCtx, ref_index : Int32, field_mb : Bool,
  list? : Int32 = 0) -> Int32 {
  if ref_index < 0 {
    return -1
  }
  let refs = if list == 0 { ctx.ref_list0 } else { ctx.ref_list1 }
  if ctx.mb_aff {
    if field_mb {
      let frame = ref_index >> 1
      if frame < refs.length() && frame < 16 {
        refs[frame].identity * 4 + (if (ref_index & 1) == 0 { 1 } else { 2 })
      } else {
        -1
      }
    } else if ref_index < refs.length() {
      refs[ref_index].identity * 4 + 3
    } else {
      -1
    }
  } else if ref_index < refs.length() {
    refs[ref_index].identity
  } else {
    -1
  }
}

///|
/// `sl->ref_count[list] << MB_MBAFF(sl)`: MBAFF field MBs index both fields
/// of every reference.
fn h264_ref_count(ctx : H264DecCtx) -> Int32 {
  if ctx.mb_aff && ctx.mb_field { ctx.ref_count0 * 2 } else { ctx.ref_count0 }
}

///|
/// Map a coded ref index to its entry in the MBAFF reference list: field MBs
/// use `16 + (ref ^ parity)` (`ff_h264_decode_mb_*` + `hl_decode_mb`).
fn h264_ref_entry(ctx : H264DecCtx, ref_index : Int32, field_mb : Bool, parity : Int32) -> Int32 {
  if ctx.mb_aff && field_mb && ref_index >= 0 { 16 + (ref_index ^ parity) } else { ref_index }
}

///|
/// Predicted Intra4x4 mode (`pred_intra_mode`). */
fn h264_pred_intra_mode(
  ctx : H264DecCtx,
  mb_idx : Int32,
  _mb_x : Int32,
  _mb_y : Int32,
  gx : Int32,
  gy : Int32,
  modes : Array[Int32],
) -> Int32 {
  let left = if gx > 0 {
    modes[gy * 4 + gx - 1]
  } else if h264_intra_left(ctx, mb_idx) {
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
  } else if h264_intra_top(ctx, mb_idx) {
    let ti = ctx.infos[h264_top_index(ctx, mb_idx)]
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
/// Luma 4x4 block nC prediction from the retained neighbour counts. `base`
/// selects the plane's section of `nz` (4:4:4 chroma planes use 16 * p). */
fn h264_nc_luma(
  ctx : H264DecCtx,
  mb_idx : Int32,
  _mb_x : Int32,
  _mb_y : Int32,
  gx : Int32,
  gy : Int32,
  nz : Array[Int32],
  base? : Int32 = 0,
) -> Int32 {
  let left = if gx > 0 {
    nz[base + gy * 4 + gx - 1]
  } else if h264_has_left(ctx, mb_idx) {
    ctx.infos[mb_idx - 1].nz[base + gy * 4 + 3]
  } else {
    64
  }
  let top = if gy > 0 {
    nz[base + (gy - 1) * 4 + gx]
  } else if h264_has_top(ctx, mb_idx) {
    ctx.infos[h264_top_index(ctx, mb_idx)].nz[base + 3 * 4 + gx]
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
  _mb_x : Int32,
  _mb_y : Int32,
  component : Int32,
  i : Int32,
  nz : Array[Int32],
) -> Int32 {
  let base = 16 + 16 * component
  let gx = i % 2
  let gy = i / 2
  let left = if gx > 0 {
    nz[base + i - 1]
  } else if h264_has_left(ctx, mb_idx) {
    ctx.infos[mb_idx - 1].nz[base + 1 + 2 * gy]
  } else {
    64
  }
  let top = if gy > 0 {
    nz[base + i - 2]
  } else if h264_has_top(ctx, mb_idx) {
    ctx.infos[h264_top_index(ctx, mb_idx)].nz[base + 2 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
/// 4:2:2 chroma AC nC prediction. FFmpeg's `non_zero_count_cache` lays the
/// two vertically stacked 8x8s side by side (`scan8[16..23]`), so the
/// neighbour relations follow that cache, not the image geometry: the left
/// neighbour of the bottom 8x8's left column is the top 8x8's right column,
/// and the top-MB border row reads the top macroblock's (always zero for
/// 4:2:2) blocks 28..31 (`fill_decode_caches`'s `!chroma_y_shift` fill).
fn h264_nc_chroma_422(
  ctx : H264DecCtx,
  mb_idx : Int32,
  component : Int32,
  i : Int32,
  nz : Array[Int32],
) -> Int32 {
  let base = 16 + 16 * component
  // `scan8` stacks the two 8x8s vertically: block i sits at cache row
  // 6 + i/2, column 4 + i%2. Column-4 blocks read the left macroblock's
  // right column (b1/b3/b5/b7 of this component), row-6 blocks read the
  // top macroblock's bottom row (b6/b7) - `fill_decode_caches`'s
  // `!chroma_y_shift` fills mirror exactly that.
  let left = if (i & 1) == 1 {
    nz[base + i - 1]
  } else if h264_has_left(ctx, mb_idx) {
    ctx.infos[mb_idx - 1].nz[base + i + 1]
  } else {
    64
  }
  let top = if i >= 2 {
    nz[base + i - 2]
  } else if h264_has_top(ctx, mb_idx) {
    ctx.infos[h264_top_index(ctx, mb_idx)].nz[base + 6 + i]
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
  if ctx.slice_type_nos == 1 { return h264_decode_b_mb(Cavlc(gb), ctx, mb_idx) }
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
      // `ff_h264_decode_mb_cavlc`: a skip run ending on the top MB of an
      // MBAFF pair carries the pair's field-decoding flag.
      if ctx.mb_aff && (mb_y & 1) == 0 && ctx.mb_skip_run == 0 {
        ctx.mb_field = gb.read1() != 0U
      }
      ctx.infos[mb_idx].field_mb = ctx.mb_field
      return h264_decode_mb_skip_common(ctx, mb_idx, mb_x, mb_y)
    }
    ctx.mb_skip_run = ctx.mb_skip_run - 1
  }
  if ctx.mb_aff && (mb_y & 1) == 0 {
    ctx.mb_field = gb.read1() != 0U
  }
  ctx.infos[mb_idx].field_mb = ctx.mb_field
  ctx.cur_mb_is_intra = true
  let mut mb_type_raw = gb.read_ue31()
  if mb_type_raw < 0 {
    return Err("invalid mb_type")
  }
  if ctx.si_slice && mb_type_raw > 0 { mb_type_raw -= 1 }
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
  h264_decode_mb_cavlc_intra(gb, ctx, mb_idx, mb_x, mb_y, mb_type_raw)
}

///|
fn h264_decode_mb_cavlc_intra(
  gb : BitReader, ctx : H264DecCtx, mb_idx : Int32, mb_x : Int32, mb_y : Int32, mb_type_raw : Int32,
) -> Result[Unit, String] {
  let pps = ctx.pps
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
  let luma_dc : Array[Array[Int32]] = [
    Array::make(16, 0),
    Array::make(16, 0),
    Array::make(16, 0),
  ]
  let luma_dc_nz : Array[Int32] = Array::make(3, 0)
  let chroma_dc_nz : Array[Int32] = Array::make(2, 0)
  let modes : Array[Int32] = Array::make(16, 0)
  let modes_ck : Array[Int32] = Array::make(16, 0)
  let mut chroma_mode = 0
  if is_pcm {
    gb.align()
    // Chroma samples per plane: 8x8 (4:2:0), 8x16 (4:2:2) or 16x16 (4:4:4);
    // monochrome PCM carries luma only (`ff_h264_mb_sizes[0] == 256`).
    let cw = 16 >> ctx.chroma_hshift
    let chh = 16 >> ctx.chroma_vshift
    let samples = if ctx.chroma_format == 0 { 256 } else { 256 + 2 * cw * chh }
    if gb.bits_left() < samples * ctx.bit_depth {
      return Err("not enough data for I_PCM")
    }
    let ystride = h264_mb_ystride(ctx)
    let ybase = h264_mb_ybase(ctx, mb_x, mb_y)
    for row = 0; row < 16; row = row + 1 {
      for col = 0; col < 16; col = col + 1 {
        ctx.y[ybase + row * ystride + col] = gb.read(ctx.bit_depth).reinterpret_as_int()
      }
    }
    if ctx.chroma_format != 0 {
      let cstride = h264_mb_cstride(ctx)
      let cbase = h264_mb_cbase(ctx, mb_x, mb_y)
      for p = 0; p < 2; p = p + 1 {
        let plane = if p == 0 { ctx.u } else { ctx.v }
        for row = 0; row < chh; row = row + 1 {
          for col = 0; col < cw; col = col + 1 {
            plane[cbase + row * cstride + col] = gb
              .read(ctx.bit_depth)
              .reinterpret_as_int()
          }
        }
      }
    }
    for i = 0; i < 48; i = i + 1 {
      nz[i] = 16
    }
    info.intra4x4 = false
    info.mb_type_bits = h264_mb_type_intra_pcm
    info.cbp_all = 0xf7ef
    info.chroma_mode = 0
    // "In deblocking, the quantizer is 0" (h264_cavlc.c).
    info.qp = 0
    return Ok(())
  }
  if is_i4x4 {
    info.transform_8x8 = pps.transform_8x8_mode != 0 && gb.read1() != 0U
    let step = if info.transform_8x8 { 4 } else { 1 }
    for i = 0; i < 16; i = i + step {
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
      if info.transform_8x8 {
        for dy in 0..<2 { for dx in 0..<2 { modes[(gy + dy) * 4 + gx + dx] = mode } }
      }
    }
  }
  // Chroma prediction mode follows the luma intra modes / mb_type; 4:4:4 and
  // monochrome code none (`decode_chroma == 0` in the C: 4:4:4 reuses the
  // luma modes, 4:0:0 uses the DC_128 placeholder).
  let mut raw_cm = 0
  if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
    let cm = gb.read_ue31()
    raw_cm = cm
    if cm < 0 || cm > 3 {
      return Err("chroma prediction mode out of range")
    }
    chroma_mode = match h264_check_intra_pred_mode(cm, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx)) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  if is_i16x16 {
    pred16 = match h264_check_intra_pred_mode(pred16, h264_intra_top(ctx, mb_idx), h264_intra_left(ctx, mb_idx)) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  if is_i4x4 {
    for gy = 0; gy < 4; gy = gy + 1 {
      for gx = 0; gx < 4; gx = gx + 1 {
        let g = gy * 4 + gx
        let top = gy > 0 || h264_intra_top(ctx, mb_idx)
        let left = gx > 0 || h264_intra_left(ctx, mb_idx)
        modes_ck[g] = match h264_check_intra4x4_mode(modes[g], top, left) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
    }
  }
  if !is_i16x16 {
    let cbp_code = gb.read_ue31()
    if ctx.chroma_format == 0 || ctx.chroma_format == 3 {
      if cbp_code < 0 || cbp_code > 15 {
        return Err("cbp out of range")
      }
      cbp = h264_golomb_to_intra4x4_cbp_gray[cbp_code]
    } else {
      if cbp_code < 0 || cbp_code > 47 {
        return Err("cbp out of range")
      }
      cbp = h264_golomb_to_intra4x4_cbp[cbp_code]
    }
  } else if (ctx.chroma_format == 0 || ctx.chroma_format == 3) && cbp > 15 {
    return Err("gray chroma")
  }
  let mut chroma_qp0 = h264_get_chroma_qp(pps, 0, ctx.qscale, bit_depth=ctx.bit_depth)
  let mut chroma_qp1 = h264_get_chroma_qp(pps, 1, ctx.qscale, bit_depth=ctx.bit_depth)
  if cbp != 0 || is_i16x16 {
    let dquant = gb.read_se()
    if dquant == -2147483648 {
      return Err("invalid mb_qp_delta")
    }
    let mut q = ctx.qscale + dquant
    if q < 0 || q > h264_max_qp(ctx) {
      q = if q < 0 { q + h264_max_qp(ctx) + 1 } else { q - h264_max_qp(ctx) - 1 }
      if q < 0 || q > h264_max_qp(ctx) {
        return Err("dquant out of range")
      }
    }
    ctx.qscale = q
    chroma_qp0 = h264_get_chroma_qp(pps, 0, q, bit_depth=ctx.bit_depth)
    chroma_qp1 = h264_get_chroma_qp(pps, 1, q, bit_depth=ctx.bit_depth)
    let plane_count = if ctx.chroma_format == 3 { 3 } else { 1 }
    let chroma_qps = [0, chroma_qp0, chroma_qp1]
    for p = 0; p < plane_count; p = p + 1 {
      let plane_qp = if p == 0 { ctx.qscale } else { chroma_qps[p] }
      match
        h264_cavlc_luma_residual(
          gb, ctx, mb_idx, mb_x, mb_y, cbp, p, plane_qp, is_i16x16, mb, luma_dc, luma_dc_nz, nz,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }

    if ctx.chroma_format == 1 || ctx.chroma_format == 2 {
      let num_c8x8 = ctx.chroma_format
      if (cbp & 0x30) != 0 {
        for c = 0; c < 2; c = c + 1 {
          chroma_dc_nz[c] = match
            h264_decode_residual(
              gb,
              mb,
              256 + 256 * c,
              if num_c8x8 == 2 { h264_chroma422_dc_scan } else { h264_chroma_dc_scan },
              0,
              None,
              4 * num_c8x8,
              0,
             bit_depth=ctx.bit_depth,) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
        }
      }
      if (cbp & 0x20) != 0 {
        for c = 0; c < 2; c = c + 1 {
          let cqp = if c == 0 { chroma_qp0 } else { chroma_qp1 }
          let qmul_c = h264_build_dequant4(pps, 1 + c, cqp)
          for i = 0; i < 4 * num_c8x8; i = i + 1 {
            let nc = if num_c8x8 == 2 {
              h264_nc_chroma_422(ctx, mb_idx, c, i, nz)
            } else {
              h264_nc_chroma(ctx, mb_idx, mb_x, mb_y, c, i, nz)
            }
              let total = match
              h264_decode_residual(
                gb,
                mb,
                256 + 256 * c + 16 * i,
                h264_scan4(ctx),
                1,
                Some(qmul_c),
                15,
                nc,
               bit_depth=ctx.bit_depth,) {
              Ok(v) => v
              Err(e) => return Err(e)
            }
            nz[16 + 16 * c + i] = total
          }
        }
      }
    }
  }
  let plane_dc_mul : Array[Int32] = [
    h264_build_dequant4(pps, 0, ctx.qscale)[0],
    h264_build_dequant4(pps, 1, chroma_qp0)[0],
    h264_build_dequant4(pps, 2, chroma_qp1)[0],
  ]
  match
    h264_recon_mb(
      ctx, mb_x, mb_y, is_i4x4, is_i16x16, pred16, chroma_mode, modes_ck, cbp, luma_dc_nz,
      chroma_dc_nz, chroma_qp0, chroma_qp1, plane_dc_mul, mb, luma_dc, nz,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
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
/// `decode_luma_residual` (CAVLC) for one full-size plane `p`: the I16x16 DC
/// block plus the CBP-gated AC blocks, 4x4 or 8x8 transform, writing raster
/// nz at `16 * p` and coefficients at `256 * p` of `mb`.
fn h264_cavlc_luma_residual(
  gb : BitReader,
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  cbp : Int32,
  p : Int32,
  plane_qp : Int32,
  is_i16x16 : Bool,
  mb : Array[Int32],
  luma_dc : Array[Array[Int32]],
  luma_dc_nz : Array[Int32],
  nz : Array[Int32],
) -> Result[Unit, String] {
  let info = ctx.infos[mb_idx]
  let base = 16 * p
  let mb_off = 256 * p
  let qmul = h264_build_dequant4(ctx.pps, p, plane_qp)
  if is_i16x16 {
    luma_dc_nz[p] = match
      h264_decode_residual(
        gb,
        luma_dc[p],
        0,
        h264_scan4(ctx),
        0,
        None,
        16,
        h264_block0_nc(ctx, mb_idx, mb_x, mb_y, base=base),
       bit_depth=ctx.bit_depth,) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if (cbp & 15) != 0 {
      for i = 0; i < 16; i = i + 1 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz, base=base)
        let total = match
          h264_decode_residual(
            gb,
            mb,
            mb_off + 16 * i,
            h264_scan4(ctx),
            1,
            Some(qmul),
            15,
            nc,
           bit_depth=ctx.bit_depth,) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        nz[base + gy * 4 + gx] = total
      }
    }
    return Ok(())
  }
  if info.transform_8x8 {
    match h264_cavlc_luma8(gb, ctx, mb_idx, mb_x, mb_y, cbp, p, plane_qp, base, mb_off, mb) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    return Ok(())
  }
  for i8x8 = 0; i8x8 < 4; i8x8 = i8x8 + 1 {
    if (cbp & (1 << i8x8)) != 0 {
      for i4x4 = 0; i4x4 < 4; i4x4 = i4x4 + 1 {
        let i = i8x8 * 4 + i4x4
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let nc = h264_nc_luma(ctx, mb_idx, mb_x, mb_y, gx, gy, nz, base=base)
        let total = match
          h264_decode_residual(
            gb,
            mb,
            mb_off + 16 * i,
            h264_scan4(ctx),
            0,
            Some(qmul),
            16,
            nc,
           bit_depth=ctx.bit_depth,) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        nz[base + gy * 4 + gx] = total
      }
    }
  }
  Ok(())
}

///|
/// nC for the I16x16 luma DC block: `pred_non_zero_count` of luma block 0's
/// left/top neighbours.
fn h264_block0_nc(
  ctx : H264DecCtx,
  mb_idx : Int32,
  _mb_x : Int32,
  _mb_y : Int32,
  base? : Int32 = 0,
) -> Int32 {
  let left = if h264_has_left(ctx, mb_idx) { ctx.infos[mb_idx - 1].nz[base + 3] } else { 64 }
  let top = if h264_has_top(ctx, mb_idx) { ctx.infos[h264_top_index(ctx, mb_idx)].nz[base + 12] } else { 64 }
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
  h264_decode_picture_ex([nal], ps, fn(_) { Ok({ list0: ref_list0, list1: [], colocated: [], long_pocs: [], poc: 0, poc_top: 0, poc_bottom: 0 }) }, skip_lf)
}

///|
fn h264_decode_picture_ex(
  nals : Array[H2645Nal], ps : H264ParamSets,
  resolve_refs : (H264SliceHeader) -> Result[H264SliceRefs, String], skip_lf : Bool,
) -> Result[H264Frame, String] {
  guard nals.length() > 0 else { return Err("empty H.264 picture") }
  let slices = nals.copy()
  slices.sort_by(fn(a, b) {
    let ga = BitReader::with_size(a.data, a.size_bits); ga.skip(8)
    let gb = BitReader::with_size(b.data, b.size_bits); gb.skip(8)
    ga.read_ue().compare(gb.read_ue())
  })
  let nal = slices[0]
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
  let references = match resolve_refs(sh) { Ok(value) => value; Err(error) => return Err(error) }
  let ref_list0 = references.list0
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
  if sps.chroma_format_idc < 0 || sps.chroma_format_idc > 3 {
    return Err("invalid H.264 chroma format")
  }
  if ![8, 9, 10, 12, 14].contains(sps.bit_depth_luma) || sps.bit_depth_chroma != sps.bit_depth_luma {
    return Err("unsupported H.264 bit depths")
  }
  // Frame pictures with `frame_mbs_only_flag == 0` are either MBAFF (adaptive
  // field/frame MB pairs) or plain frames; the per-MB field flag decides.
  let mb_aff = sps.frame_mbs_only_flag == 0 && sps.mb_aff != 0
  if sh.qscale < 0 || sh.qscale > 51 + 6 * (sps.bit_depth_luma - 8) {
    return Err("slice QP out of range")
  }
  let chroma_format = sps.chroma_format_idc
  // FFmpeg decodes 4:0:0 into yuv420p, filling chroma with the mid value
  // (`h264_slice.c: h->chroma_y_shift = sps->chroma_format_idc <= 1`), so
  // monochrome keeps the 4:2:0 plane geometry.
  let chroma_hshift = if chroma_format <= 2 { 1 } else { 0 }
  let chroma_vshift = if chroma_format == 0 || chroma_format == 1 { 1 } else { 0 }
  let mb_width = sps.mb_width
  let mb_height = sps.mb_height
  let mb_count = mb_width * mb_height
  let ystride = mb_width * 16
  let yheight = mb_height * 16
  let cstride = ystride >> chroma_hshift
  let cheight = yheight >> chroma_vshift
  let y : Array[Int32] = Array::make(ystride * yheight, 0)
  // Monochrome frames keep neutral chroma, matching FFmpeg's yuv420p output
  // (DC_128 chroma prediction and byte-exact chroma motion compensation).
  let chroma_fill = if chroma_format == 0 { 1 << (sps.bit_depth_luma - 1) } else { 0 }
  let u : Array[Int32] = Array::make(cstride * cheight, chroma_fill)
  let v : Array[Int32] = Array::make(cstride * cheight, chroma_fill)
  let infos : Array[H264MbInfo] = []
  for _i = 0; _i < mb_count; _i = _i + 1 {
    infos.push({
      nz: Array::make(48, 0),
      modes: Array::make(16, 0),
      intra4x4: false,
      field_mb: false,
      qp: 0,
      mb_type_bits: 0,
      cbp_all: 0,
      chroma_mode: 0,
      mv: Array::make(32, 0),
      mv1: Array::make(32, 0), ref_idx1: Array::make(16, -1), mvd1: Array::make(32, 0),
      ref_identity1: Array::make(16, -1), direct: Array::make(16, false),
      ref_idx: Array::make(16, h264_ref_not_avail),
      mvd: Array::make(32, 0),
      transform_8x8: false,
      slice_num: 0, deblock_idc: 0, alpha_offset: 52, beta_offset: 52,
      ref_identity: Array::make(16, -1),
    })
  }
  // `ff_h264_build_ref_list`'s missing-reference pass substitutes
  // `default_ref = ref_list[0]` for every inactive entry up to `ref_count`.
  let ref_list0 = if ref_list0.length() == 0 {
    ref_list0
  } else {
    let padded = ref_list0.copy()
    while padded.length() < sh.num_ref_idx_l0_active {
      padded.push(ref_list0[0])
    }
    padded
  }
  let ctx : H264DecCtx = {
    bit_depth: sps.bit_depth_luma,
    chroma_format,
    chroma_hshift,
    chroma_vshift,
    si_slice: false,
    slice_num: 0,
    pps,
    mb_width,
    mb_height,
    mb_aff,
    mb_field: false,
    prev_mb_skipped: false,
    next_mb_skipped: false,
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
    active_list: 0, ref_list1: references.list1, ref_count1: sh.num_ref_idx_l1_active,
    direct_spatial: sh.direct_spatial_mv_pred, direct_8x8: sps.direct_8x8_inference_flag != 0,
    colocated: references.colocated, poc: references.poc,
    poc_top: references.poc_top, poc_bottom: references.poc_bottom,
    long_pocs: references.long_pocs,
    mb_skip_run: -1,
    pwt: sh.pwt,
  }
  for number, slice in slices {
    let reader = BitReader::with_size(slice.data, slice.size_bits); reader.skip(8)
    let header = match ff_h264_decode_slice_header(reader, slice.nal_type, slice.ref_idc, ps) {
      Ok(value) => value; Err(error) => return Err(error)
    }
    if header.pps_id != sh.pps_id || header.frame_num != sh.frame_num ||
      header.pic_order_cnt_lsb != sh.pic_order_cnt_lsb || header.idr_pic_id != sh.idr_pic_id ||
      header.delta_pic_order_cnt_bottom != sh.delta_pic_order_cnt_bottom ||
      header.delta_pic_order_cnt != sh.delta_pic_order_cnt || header.mmco != sh.mmco ||
      header.long_term_reference != sh.long_term_reference || header.adaptive_ref_marking != sh.adaptive_ref_marking ||
      header.no_output_of_prior_pics != sh.no_output_of_prior_pics ||
      header.field_pic_flag != 0 || slice.ref_idc != nal.ref_idc || slice.nal_type != nal.nal_type {
      return Err("inconsistent H.264 picture slices")
    }
    let refs = match resolve_refs(header) { Ok(value) => value; Err(error) => return Err(error) }
    match h264_decode_picture_slice(ctx, slice, reader, header, refs, number) {
      Ok(_) => (); Err(error) => return Err(error)
    }
  }
  for info in infos { if info.mb_type_bits == 0 { return Err("incomplete H.264 picture") } }
  // Mixed field/frame MB pairs need FFmpeg's sample-availability borders and
  // MBAFF deblock pair kernels, which this port does not model yet.
  if mb_aff {
    let any_field = infos.any(fn(info) { info.field_mb })
    let any_frame = infos.any(fn(info) { !info.field_mb })
    if any_field && any_frame {
      return Err("mixed field/frame macroblocks are not supported")
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
  if !skip_lf {
    if ctx.mb_aff {
      // `loop_filter`: per MB pair row, walk x and filter the top then the
      // bottom MB of each pair.
      for pair_y = 0; pair_y < mb_height; pair_y = pair_y + 2 {
        for x = 0; x < mb_width; x = x + 1 {
          for parity = 0; parity < 2; parity = parity + 1 {
            let idx = (pair_y + parity) * mb_width + x
            let info = infos[idx]
            if info.deblock_idc != 1 {
              h264_filter_mb(ctx, idx, x, pair_y + parity, info.alpha_offset, info.beta_offset)
            }
          }
        }
      }
    } else {
      for i = 0; i < mb_count; i = i + 1 {
        let info = infos[i]
        if info.deblock_idc != 1 { h264_filter_mb(ctx, i, i % mb_width, i / mb_width, info.alpha_offset, info.beta_offset) }
      }
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
    bit_depth: sps.bit_depth_luma,
    epoch: 0,
    reorder_depth: sps.num_reorder_frames.max(0).min(16),
    no_output_prior: sh.no_output_of_prior_pics,
    poc: references.poc,
    infos,
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
    chroma_hshift,
    chroma_vshift,
  })
}

///|
/// Historical I-frame entry, now backed by the persistent I/P picture decoder.
/// Parses in-band SPS/PPS, groups slices and includes deblocking by default.
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
  h264_decode_annexb_frames(data, skip_loop_filter)
}

///|
/// Decode H.264 pictures from MP4-style access units: `extradata` is the
/// `avcC` record (or an Annex B parameter-set blob) and every entry of
/// `samples` is one length-prefixed access unit. `nal_length_size` comes from
/// the `avcC` header (`ff_h264_decode_extradata`), which is what the C gets
/// from `AVCodecParameters.nal_length_size`.
///
/// Samples may carry parameter sets, SEI (skipped) and multiple slice NALs per
/// picture. Supports progressive 8-bit 4:2:0 I/P pictures.
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
