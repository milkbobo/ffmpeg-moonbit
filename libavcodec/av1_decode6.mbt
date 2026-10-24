///|
/// `dav1d_backup_ipred_edge` (8-bit, 4:2:0): copy the bottom pixel row of
/// the current SB row into the per-plane edge buffers.
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
  let uv_off = ((x_off * 4) >> 1) +
    ((((self.by + f.sb_step) * 4) >> 1) - 1) * f.uv_stride
  for pl in 1..=2 {
    let plane = f.planes[pl]
    let edge = f.ipred_edge[pl]
    for i in 0..<((4 * (self.col_end - x_off)) >> 1) {
      edge[sby_off + ((x_off * 4) >> 1) + i] = plane[uv_off + i]
    }
  }
}

///|
/// One superblock row of one tile (decode_tile_sbrow, pass 0, intra only).
fn Av1TileCtx::decode_tile_sbrow(
  self : Av1TileCtx,
  root_bl : Int,
) -> Bool raise Av1DecError {
  let f = self.f
  let sb_step = f.sb_step
  self.xrow_by = self.by
  f.l.reset_keyframe()
  let mut bx = self.col_start
  self.a_idx = self.tile_row * f.sb128w
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
    println("OVERREAD rowby=" + self.xrow_by.to_string() + " cnt=" + self.msac.cnt.to_string())
    return true
  }
  false
}

///|
/// Decoded frame output: planar yuv420p planes plus geometry.
pub struct Av1FrameOutput {
  y : FixedArray[Byte]
  u : FixedArray[Byte]
  v : FixedArray[Byte]
  width : Int
  height : Int
  y_stride : Int
  uv_stride : Int
}

///|
/// Decode one AV1 key frame (lossless 8-bit 4:2:0 software path).
/// `frame_obus` is the OBU byte stream of one frame (sequence header OBU
/// included or already parsed); `seq`/`hdr` are the parsed headers and
/// `tile` the entropy payload for tile 0 (single-tile frames only).
pub fn av1_decode_keyframe(
  seq : Av1SequenceParameters,
  hdr : Av1FrameHeader,
  tile : Bytes,
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
  if hdr.tile_cols != 1 || hdr.tile_rows != 1 {
    return Err("av1: multi-tile frames unsupported")
  }
  if !hdr.coded_lossless {
    // Lossy frames require the in-loop filters (not yet ported).
    return Err("av1: lossy frames unsupported (need CDEF/LF/LR)")
  }
  let w = hdr.width
  let h = hdr.height
  let bw = ((w + 7) >> 3) << 1
  let bh = ((h + 7) >> 3) << 1
  let sb128 = if seq.use_128x128_superblock { 1 } else { 0 }
  let sb128w = (bw + 31) >> 5
  let sb128h = (bh + 31) >> 5
  let sb_shift = 4 + sb128
  let sb_step = 16 << sb128
  let aligned_w = (w + 127) & -128
  let y_stride = aligned_w
  let uv_stride = aligned_w >> 1
  let y_plane : FixedArray[Byte] = FixedArray::make(
    y_stride * (h + 2 * sb_step * 4 + 64), b'\x80',
  )
  let uv_h = (h + 1) >> 1
  let u_plane : FixedArray[Byte] = FixedArray::make(
    uv_stride * (uv_h + sb_step * 2 + 64), b'\x80',
  )
  let v_plane : FixedArray[Byte] = FixedArray::make(
    uv_stride * (uv_h + sb_step * 2 + 64), b'\x80',
  )
  let planes : FixedArray[FixedArray[Byte]] = [y_plane, u_plane, v_plane]
  let a = []
  for _ in 0..<(sb128w * 1) {
    let a_ctx = av1_block_context_new()
    a_ctx.reset_keyframe()
    a.push(a_ctx)
  }
  let ipred_edge : FixedArray[FixedArray[Byte]] = [
    FixedArray::make(sb128w * 128 * (sb128h + 1), b'\x80'),
    FixedArray::make(sb128w * 128 * (sb128h + 1), b'\x80'),
    FixedArray::make(sb128w * 128 * (sb128h + 1), b'\x80'),
  ]
  let f : Av1FrameCtx = {
    seq,
    hdr,
    bw,
    bh,
    sb128w,
    sb_shift,
    sb_step,
    planes,
    y_stride,
    uv_stride,
    a,
    l: av1_block_context_new(),
    al_pal: FixedArray::make(2 * 32 * 3 * 8, b'\x00'),
    pal_sz_uv: FixedArray::make(64, 0),
    ipred_edge,
    dq: FixedArray::make(8 * 6, 4),
    seg_lossless: FixedArray::make(8, false),
    seg_qidx: FixedArray::make(8, 0),
  }
  f.init_quant()
  println("PROBE frame w=" + w.to_string() + " h=" + h.to_string() + " bw=" + bw.to_string() + " bh=" + bh.to_string() + " tiles=" + tile.length().to_string())
  let ts : Av1TileCtx = {
    f,
    msac: Av1Msac::init(tile, hdr.disable_cdf_update),
    cdf: av1_cdf_copy_defaults(hdr.base_q_idx),
    col_start: 0,
    col_end: av1_imin(bw, bw),
    row_start: 0,
    row_end: av1_imin(bh, bh),
    tile_row: 0,
    bx: 0,
    by: 0,
    xrow_by: 0,
    a_idx: 0,
    cur_sb_cdef_idx: FixedArray::make(4, -1),
    levels: FixedArray::make(32 * 34, b'\x00'),
    edge_buf: FixedArray::make(128 * 3, b'\x00'),
    cf: FixedArray::make(64 * 64, 0),
    pal_idx_y: FixedArray::make(64 * 64, b'\x00'),
    pal_idx_uv: FixedArray::make(64 * 64, b'\x00'),
    pal: FixedArray::make(3 * 8, b'\x00'),
    ac: FixedArray::make(32 * 32, 0),
  }
  let root_bl = if seq.use_128x128_superblock { 0 } else { 1 }
  let result : Result[Av1FrameOutput, String] = try {
    let mut by = 0
    while by < ts.row_end {
      ts.by = by
      println("PROBE sbrow by=" + by.to_string())
      if ts.decode_tile_sbrow(root_bl) {
        raise Av1DecError::Unsupported("symbol decoder overread")
      }
      println("ROWDONE by=" + by.to_string())
      by = by + sb_step
    }
    // clear trailing bits check is skipped (strict mode off)
    Ok({
      y: ts.f.planes[0], u: ts.f.planes[1], v: ts.f.planes[2], width: w,
      height: h, y_stride, uv_stride,
    })
  } catch {
    Av1DecError::Unsupported(msg) => Err(msg)
  }
  result
}
