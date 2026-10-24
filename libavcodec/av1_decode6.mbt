///|
/// `dav1d_backup_ipred_edge` (8-bit): copy the bottom pixel row of the
/// current SB row into the per-plane edge buffers.
fn Av1TileCtx::backup_ipred_edge(self : Av1TileCtx) -> Unit {
  let f = self.f
  let sby = self.by >> f.sb_shift
  let sby_off = f.sb128w * 128 * sby
  let x_off = self.col_start
  let y_plane = f.planes[0]
  let y = x_off * 4 + ((self.by + f.sb_step) * 4 - 1) * f.y_stride
  let edge0 = f.ipred_edge[0]
  for i in 0..<(4 * (self.col_end - x_off)) {
    edge0[sby_off + x_off * 4 + i] = y_plane[y + i]
  }
  let uv_off = ((x_off * 4) >> f.ss_h) +
    ((((self.by + f.sb_step) * 4) >> f.ss_v) - 1) * f.uv_stride
  for pl in 1..<=2 {
    let plane = f.planes[pl]
    let edge = f.ipred_edge[pl]
    for i in 0..<((4 * (self.col_end - x_off)) >> f.ss_h) {
      edge[sby_off + ((x_off * 4) >> f.ss_h) + i] = plane[uv_off + i]
    }
  }
}

///|
/// One superblock row of one tile (decode_tile_sbrow, pass 0, intra only).
fn Av1TileCtx::decode_tile_sbrow(
  self : Av1TileCtx,
  root_bl : Int32,
) -> Bool raise Av1DecError {
  let f = self.f
  let sb_step = f.sb_step
  f.l.reset_keyframe()
  for i in 0..<32 {
    self.pal_sz_uv[32 + i] = 0
  }
  for i in 0..<(32 * 3 * 8) {
    self.al_pal[32 * 3 * 8 + i] = 0
  }
  let mut bx = self.col_start
  self.a_idx = self.tile_row * f.sb128w + (self.col_start >> 5)
  while bx < self.col_end {
    // cdef idx init for this SB
    if root_bl == 0 {
      for i in 0..<4 {
        self.cur_sb_cdef_idx[i] = -1
      }
    } else {
      self.cur_sb_cdef_idx[0] = -1
    }
    self.bx = bx
    if self.decode_sb(root_bl, av1_intra_edge_tree(root_bl)) {
      return true
    }
    if (bx & 16) != 0 || f.seq.use_128x128_superblock {
      self.a_idx = self.a_idx + 1
    }
    bx = bx + sb_step
  }
  self.backup_ipred_edge()
  // error out on symbol decoder overread
  if self.msac.cnt <= -15 {
    return true
  }
  false
}

///|
/// Decoded frame output: planar planes (component values) plus geometry,
/// subsampling and bit depth.
pub struct Av1FrameOutput {
  y : FixedArray[Int32]
  u : FixedArray[Int32]
  v : FixedArray[Int32]
  width : Int32
  height : Int32
  y_stride : Int32
  uv_stride : Int32
  ss_h : Int32
  ss_v : Int32
  mono : Bool
  bitdepth : Int32
}

///|
/// Pack the frame as contiguous planar samples: luma at `width`×`height`, then
/// Cb and Cr at the sequence's chroma subsampling (none for monochrome).
/// 8-bit packs one byte per sample; 10/12-bit pack little-endian uint16 as
/// FFmpeg does for `yuv*PG(10|12)le`.
pub fn Av1FrameOutput::packed(self : Av1FrameOutput) -> Bytes {
  let cw = (self.width + self.ss_h) >> self.ss_h
  let ch = (self.height + self.ss_v) >> self.ss_v
  let buf : Array[Byte] = []
  let wide = self.bitdepth > 8
  let feed = (plane : FixedArray[Int32], stride : Int32, w : Int32, h : Int32) => {
    for y in 0..<h {
      for x in 0..<w {
        let v = plane[y * stride + x]
        if wide {
          buf.push((v & 0xFF).to_byte())
          buf.push(((v >> 8) & 0xFF).to_byte())
        } else {
          buf.push(v.to_byte())
        }
      }
    }
  }
  feed(self.y, self.y_stride, self.width, self.height)
  if !self.mono {
    feed(self.u, self.uv_stride, cw, ch)
    feed(self.v, self.uv_stride, cw, ch)
  }
  Bytes::from_array(buf)
}

///|
/// Decode one AV1 key frame from a single-tile payload (lossless 8-bit
/// software path).  Multi-tile frames must use `av1_decode_keyframe_tiles`.
pub fn av1_decode_keyframe(
  seq : Av1SequenceParameters,
  hdr : Av1FrameHeader,
  tile : Bytes,
) -> Result[Av1FrameOutput, String] {
  if hdr.tile_cols != 1 || hdr.tile_rows != 1 {
    return Err("av1: multi-tile frames require av1_decode_keyframe_tiles")
  }
  let tiles : Array[Bytes] = [tile]
  av1_decode_keyframe_payloads(seq, hdr, tiles)
}

///|
/// Decode one AV1 key frame from all of its extracted tiles.
pub fn av1_decode_keyframe_tiles(
  seq : Av1SequenceParameters,
  hdr : Av1FrameHeader,
  tiles : Array[Av1Tile],
) -> Result[Av1FrameOutput, String] {
  let payloads : Array[Bytes] = []
  for tile in tiles {
    payloads.push(tile.data)
  }
  av1_decode_keyframe_payloads(seq, hdr, payloads)
}

///|
/// Shared key-frame driver: one independent range decoder and CDF context per
/// tile, with above contexts banked per tile row.
fn av1_decode_keyframe_payloads(
  seq : Av1SequenceParameters,
  hdr : Av1FrameHeader,
  payloads : Array[Bytes],
) -> Result[Av1FrameOutput, String] {
  if hdr.frame_type != av1_frame_key {
    return Err("av1: not a key frame")
  }
  if hdr.segmentation_enabled {
    return Err("av1: segmentation unsupported in pixel path")
  }
  if hdr.delta_q_present {
    return Err("av1: delta q unsupported in pixel path")
  }
  if hdr.using_qmatrix {
    return Err("av1: qmatrix unsupported")
  }
  if hdr.use_superres {
    return Err("av1: superres unsupported")
  }
  if !hdr.coded_lossless {
    // Lossy frames need the in-loop filters (LF/CDEF/LR) plus the remaining
    // lossy symbol paths; the decode layer is mostly in place (tx size/txtp/
    // eob tables) but one symbol divergence is still being tracked down.
    return Err("av1: lossy frames unsupported (need CDEF/LF/LR)")
  }
  if seq.bitdepth != 8 && seq.bitdepth != 10 && seq.bitdepth != 12 {
    return Err("av1: unsupported bit depth")
  }
  let num_tiles = hdr.tile_cols * hdr.tile_rows
  if payloads.length() != num_tiles {
    return Err("av1: tile count does not match the frame header")
  }
  let ss_h = if seq.chroma_subsampling_x { 1 } else { 0 }
  let ss_v = if seq.chroma_subsampling_y { 1 } else { 0 }
  let w = hdr.width
  let h = hdr.height
  let bw = (w + 7) >> 3 << 1
  let bh = (h + 7) >> 3 << 1
  let sb128 = if seq.use_128x128_superblock { 1 } else { 0 }
  let sb128w = (bw + 31) >> 5
  let sb128h = (bh + 31) >> 5
  let sb_shift = 4 + sb128
  let sb_step = 16 << sb128
  let sb_cols = (bw + sb_step - 1) / sb_step
  let sb_rows = (bh + sb_step - 1) / sb_step
  let tile_width_sb = (sb_cols + (1 << hdr.tile_cols_log2) - 1) >>
    hdr.tile_cols_log2
  let tile_height_sb = (sb_rows + (1 << hdr.tile_rows_log2) - 1) >>
    hdr.tile_rows_log2
  let aligned_w = (w + 127) & -128
  let y_stride = aligned_w
  let uv_stride = aligned_w >> ss_h
  let bpc = seq.bitdepth
  let pixel_max = (1 << bpc) - 1
  let mid = (1 << bpc) >> 1
  let y_plane : FixedArray[Int32] = FixedArray::make(
    y_stride * (h + 2 * sb_step * 4 + 64),
    mid,
  )
  let uv_h = (h + ss_v) >> ss_v
  let u_plane : FixedArray[Int32] = FixedArray::make(
    uv_stride * (uv_h + sb_step * 2 + 64),
    mid,
  )
  let v_plane : FixedArray[Int32] = FixedArray::make(
    uv_stride * (uv_h + sb_step * 2 + 64),
    mid,
  )
  let planes : FixedArray[FixedArray[Int32]] = [y_plane, u_plane, v_plane]
  let a = []
  for _ in 0..<(sb128w * hdr.tile_rows) {
    let a_ctx = av1_block_context_new()
    a_ctx.reset_keyframe()
    a.push(a_ctx)
  }
  let ipred_edge : FixedArray[FixedArray[Int32]] = [
    FixedArray::make(sb128w * 128 * (sb128h + 1), mid),
    FixedArray::make(sb128w * 128 * (sb128h + 1), mid),
    FixedArray::make(sb128w * 128 * (sb128h + 1), mid),
  ]
  let f : Av1FrameCtx = {
    seq,
    hdr,
    bw,
    bh,
    sb128w,
    sb_shift,
    sb_step,
    bpc,
    pixel_max,
    mid,
    planes,
    y_stride,
    uv_stride,
    ss_h,
    ss_v,
    a,
    l: av1_block_context_new(),
    ipred_edge,
    dq: FixedArray::make(8 * 6, 4),
    seg_lossless: FixedArray::make(8, false),
    seg_qidx: FixedArray::make(8, 0),
  }
  f.init_quant()
  let root_bl = if seq.use_128x128_superblock { 0 } else { 1 }
  let result : Result[Av1FrameOutput, String] = try {
    for tile_idx in 0..<num_tiles {
      let tile_row = tile_idx / hdr.tile_cols
      let tile_col = tile_idx % hdr.tile_cols
      let col_start_sb = tile_col * tile_width_sb
      let row_start_sb = tile_row * tile_height_sb
      let col_end_sb = av1_imin(col_start_sb + tile_width_sb, sb_cols)
      let row_end_sb = av1_imin(row_start_sb + tile_height_sb, sb_rows)
      let col_start = col_start_sb * sb_step
      let row_start = row_start_sb * sb_step
      let col_end = col_end_sb * sb_step
      let row_end = row_end_sb * sb_step
      let ts : Av1TileCtx = {
        f,
        msac: Av1Msac::init(payloads[tile_idx], hdr.disable_cdf_update),
        cdf: av1_cdf_copy_defaults(hdr.base_q_idx),
        col_start,
        col_end,
        row_start,
        row_end,
        tile_row,
        bx: col_start,
        by: row_start,
        a_idx: tile_row * sb128w + (col_start >> 5),
        cur_sb_cdef_idx: FixedArray::make(4, -1),
        al_pal: FixedArray::make(2 * 32 * 3 * 8, 0),
        pal_sz_uv: FixedArray::make(64, 0),
        levels: FixedArray::make(32 * 34, b'\x00'),
        edge_buf: FixedArray::make(128 * 3, 0),
        cf: FixedArray::make(64 * 64, 0),
        pal_idx_y: FixedArray::make(64 * 64, b'\x00'),
        pal_idx_uv: FixedArray::make(64 * 64, b'\x00'),
        pal: FixedArray::make(3 * 8, 0),
        ac: FixedArray::make(32 * 32, 0),
      }
      let mut by = row_start
      while by < row_end {
        ts.by = by
        if ts.decode_tile_sbrow(root_bl) {
          raise Av1DecError::Unsupported("symbol decoder overread")
        }
        by = by + sb_step
      }
    }
    // clear trailing bits check is skipped (strict mode off)
    Ok({
      y: f.planes[0],
      u: f.planes[1],
      v: f.planes[2],
      width: w,
      height: h,
      y_stride,
      uv_stride,
      ss_h,
      ss_v,
      mono: seq.monochrome,
      bitdepth: bpc,
    })
  } catch {
    Av1DecError::Unsupported(msg) => Err(msg)
  }
  result
}
