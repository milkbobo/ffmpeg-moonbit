///|
/// MoonBit port of dav1d 1.5.1 `src/decode.c` + `src/recon_tmpl.c` for the
/// AV1 key-frame (intra) software decode path, single-threaded, 8-bit
/// 4:2:0. Inter frames, intrabc, film grain application and the in-loop
/// filters (CDEF/loop filter/restoration) are not part of this file; the
/// entry point rejects streams that need them.

///|
/// Block partition values (dav1d `enum BlockPartition`).
let av1_partition_none : Int = 0

///|
let av1_partition_h : Int = 1

///|
let av1_partition_v : Int = 2

///|
let av1_partition_split : Int = 3

///|
let av1_partition_t_top : Int = 4

///|
let av1_partition_t_left : Int = 6

///|
let av1_partition_t_right : Int = 7

///|
let av1_partition_h4 : Int = 8

///|
let av1_partition_v4 : Int = 9

///|
/// `BlockContext` from dav1d env.h. All arrays use Int for signed entries.
priv struct Av1BlockContext {
  mode : FixedArray[Int]
  lcoef : FixedArray[Int]
  ccoef : FixedArray[Int] // [2][32] flattened
  seg_pred : FixedArray[Int]
  skip : FixedArray[Int]
  skip_mode : FixedArray[Int]
  intra : FixedArray[Int]
  tx_intra : FixedArray[Int]
  tx : FixedArray[Int]
  tx_lpf_y : FixedArray[Int]
  tx_lpf_uv : FixedArray[Int]
  partition : FixedArray[Int] // [16]
  uvmode : FixedArray[Int]
  pal_sz : FixedArray[Int]
}

///|
fn av1_block_context_new() -> Av1BlockContext {
  {
    mode: FixedArray::make(32, 0),
    lcoef: FixedArray::make(32, 0),
    ccoef: FixedArray::make(64, 0),
    seg_pred: FixedArray::make(32, 0),
    skip: FixedArray::make(32, 0),
    skip_mode: FixedArray::make(32, 0),
    intra: FixedArray::make(32, 0),
    tx_intra: FixedArray::make(32, 0),
    tx: FixedArray::make(32, 0),
    tx_lpf_y: FixedArray::make(32, 0),
    tx_lpf_uv: FixedArray::make(32, 0),
    partition: FixedArray::make(16, 0),
    uvmode: FixedArray::make(32, 0),
    pal_sz: FixedArray::make(32, 0),
  }
}

///|
/// `reset_context` for key frames, pass 0.
fn Av1BlockContext::reset_keyframe(self : Av1BlockContext) -> Unit {
  for i in 0..<32 {
    self.intra[i] = 1
    self.uvmode[i] = av1_dc_pred
    self.mode[i] = av1_dc_pred
    self.partition[i % 16] = 0
    self.skip[i] = 0
    self.skip_mode[i] = 0
    self.tx_lpf_y[i] = 2
    self.tx_lpf_uv[i] = 1
    self.tx_intra[i] = -1
    self.tx[i] = 4 // TX_64X64
    self.lcoef[i] = 0x40
    self.ccoef[i] = 0x40
    self.ccoef[32 + i] = 0x40
    self.seg_pred[i] = 0
    self.pal_sz[i] = 0
  }
}

///|
/// Per-frame decoder state (a trimmed Dav1dFrameContext + Dav1dTileState).
priv struct Av1FrameCtx {
  seq : Av1SequenceParameters
  hdr : Av1FrameHeader
  bw : Int
  bh : Int
  sb128w : Int
  sb_shift : Int
  sb_step : Int
  /// Picture planes (8-bit), stride in pixels.
  planes : FixedArray[FixedArray[Byte]]
  y_stride : Int
  uv_stride : Int
  /// Above-context ring: sb128w * tile_rows entries.
  a : Array[Av1BlockContext]
  /// Left context for the current SB row.
  l : Av1BlockContext
  /// Above/left palette cache: [2][32][3][8] flattened bytes.
  al_pal : FixedArray[Byte]
  /// pal_sz_uv[2][32].
  pal_sz_uv : FixedArray[Int]
  /// ipred edge backup: 3 planes of sb128w*128*(sb128h+1).
  ipred_edge : FixedArray[FixedArray[Byte]]
  /// Dequant per segment: [seg*6 + plane*2 + (0 dc,1 ac)].
  dq : FixedArray[Int]
  /// Per-segment lossless flags (dav1d segmentation.lossless).
  seg_lossless : FixedArray[Bool]
  /// Per-segment qidx.
  seg_qidx : FixedArray[Int]
}

///|
/// Decode task state (Dav1dTileState + Dav1dTaskContext merged).
priv struct Av1TileCtx {
  f : Av1FrameCtx
  msac : Av1Msac
  cdf : Av1CdfCtx
  col_start : Int
  col_end : Int
  row_start : Int
  row_end : Int
  tile_row : Int
  mut bx : Int
  mut by : Int
  /// Row start y for diagnostics.
  mut xrow_by : Int
  mut a_idx : Int
  /// cdef indices for the current SB (cdef_bits may be 0).
  cur_sb_cdef_idx : FixedArray[Int]
  // scratch buffers
  levels : FixedArray[Byte] // 32*34
  edge_buf : FixedArray[Byte] // 128*3, anchor at 128+128
  cf : FixedArray[Int] // coefficients
  pal_idx_y : FixedArray[Byte] // 64*64/2? use full byte per idx (bw4*bh4*16)
  pal_idx_uv : FixedArray[Byte]
  pal : FixedArray[Byte] // [3][8]
  ac : FixedArray[Int] // 32*32
}

///|
fn av1_txfm_w(tx : Int) -> Int {
  av1_txfm_info(tx, 0)
}

///|
fn av1_txfm_h(tx : Int) -> Int {
  av1_txfm_info(tx, 1)
}

///|
fn av1_txfm_lw(tx : Int) -> Int {
  av1_txfm_info(tx, 2)
}

///|
fn av1_txfm_lh(tx : Int) -> Int {
  av1_txfm_info(tx, 3)
}

///|
fn av1_txfm_min(tx : Int) -> Int {
  av1_txfm_info(tx, 4)
}

///|
fn av1_txfm_max(tx : Int) -> Int {
  av1_txfm_info(tx, 5)
}

///|
fn av1_txfm_sub(tx : Int) -> Int {
  av1_txfm_info(tx, 6)
}

///|
fn av1_txfm_ctx(tx : Int) -> Int {
  av1_txfm_info(tx, 7)
}

///|
fn av1_bdim(bs : Int, i : Int) -> Int {
  av1_block_dimensions[bs * 4 + i].to_int()
}

///|
/// `init_quant_tables` (8-bit rows of dav1d_dq_tbl).
fn Av1FrameCtx::init_quant(self : Av1FrameCtx) -> Unit {
  // 8-bit streams use dq_tbl_0; the 10/12-bit tables stay referenced for
  // the higher-bitdepth path (currently rejected at entry).
  let dq_tbl : FixedArray[UInt16] = if self.seq.bitdepth == 8 {
    av1_dq_tbl_0
  } else if self.seq.bitdepth == 10 {
    av1_dq_tbl_1
  } else {
    av1_dq_tbl_2
  }
  ignore(av1_ymode_size_context[0]) // inter-frame y_mode ctx (future)
  let segs = if self.hdr.segmentation_enabled { 8 } else { 1 }
  for i in 0..<segs {
    let yac = if self.hdr.segmentation_enabled {
      av1_iclip_u8(
        self.hdr.base_q_idx +
        (if i < self.hdr.segmentation_alt_q.length() {
            self.hdr.segmentation_alt_q[i]
          } else {
            0
          }),
      )
    } else {
      self.hdr.base_q_idx
    }
    let ydc = av1_iclip_u8(yac + self.hdr.dq_y_dc)
    let udc = av1_iclip_u8(yac + self.hdr.dq_u_dc)
    let uac = av1_iclip_u8(yac + self.hdr.dq_u_ac)
    let vdc = av1_iclip_u8(yac + self.hdr.dq_v_dc)
    let vac = av1_iclip_u8(yac + self.hdr.dq_v_ac)
    self.seg_qidx[i] = yac
    self.dq[i * 6 + 0 * 2 + 0] = dq_tbl[ydc * 2 + 0].to_int()
    self.dq[i * 6 + 0 * 2 + 1] = dq_tbl[yac * 2 + 1].to_int()
    self.dq[i * 6 + 1 * 2 + 0] = dq_tbl[udc * 2 + 0].to_int()
    self.dq[i * 6 + 1 * 2 + 1] = dq_tbl[uac * 2 + 1].to_int()
    self.dq[i * 6 + 2 * 2 + 0] = dq_tbl[vdc * 2 + 0].to_int()
    self.dq[i * 6 + 2 * 2 + 1] = dq_tbl[vac * 2 + 1].to_int()
    self.seg_lossless[i] = self.hdr.coded_lossless
  }
  if !self.hdr.segmentation_enabled {
    for i in 1..<8 {
      self.seg_qidx[i] = self.seg_qidx[0]
      self.seg_lossless[i] = self.seg_lossless[0]
      for k in 0..<6 {
        self.dq[i * 6 + k] = self.dq[k]
      }
    }
  }
}

///|
fn av1_iclip_u8(v : Int) -> Int {
  av1_imin(av1_imax(v, 0), 255)
}

///|
/// Intra-block record (the intra half of dav1d's Av1Block).
priv struct Av1IntraBlock {
  seg_id : Int
  skip : Bool
  y_mode : Int
  y_angle : Int
  uv_mode : Int
  uv_angle : Int
  cfl_alpha : (Int, Int)
  pal_sz : (Int, Int)
  tx : Int
  uvtx : Int
}

///|
/// `get_skip_ctx` from recon_tmpl.c (loop form of the bit tricks).
fn av1_get_skip_ctx(
  tx : Int,
  bs : Int,
  a : FixedArray[Int],
  a_off : Int,
  l : FixedArray[Int],
  l_off : Int,
  chroma : Bool,
) -> Int {
  let lw = av1_txfm_lw(tx)
  let lh = av1_txfm_lh(tx)
  if chroma {
    let not_one_blk = av1_bdim(bs, 2) -
        (
          if av1_bdim(bs, 2) != 0 && true { 1 } else { 0 }
        ) >
        lw ||
      av1_bdim(bs, 3) -
        (
          if av1_bdim(bs, 3) != 0 && true { 1 } else { 0 }
        ) >
        lh
    let ca = {
      let mut any = false
      for i in 0..<(1 << lw) {
        if a[a_off + i] != 0x40 {
          any = true
        }
      }
      any
    }
    let cl = {
      let mut any = false
      for i in 0..<(1 << lh) {
        if l[l_off + i] != 0x40 {
          any = true
        }
      }
      any
    }
    7 + (if not_one_blk { 3 } else { 0 }) + (if ca { 1 } else { 0 }) +
      (if cl { 1 } else { 0 })
  } else if av1_bdim(bs, 2) == lw && av1_bdim(bs, 3) == lh {
    0
  } else {
    let la = {
      let mut acc = 0
      for i in 0..<(1 << av1_imin(lw, 4)) {
        acc = acc | a[a_off + i]
      }
      acc
    }
    let ll = {
      let mut acc = 0
      for i in 0..<(1 << av1_imin(lh, 4)) {
        acc = acc | l[l_off + i]
      }
      acc
    }
    let mi = av1_imin(av1_imin(la & 0x3F, 4), 4)
    let mj = av1_imin(av1_imin(ll & 0x3F, 4), 4)
    av1_skip_ctx[mi * 5 + mj].to_int()
  }
}

///|
/// `get_dc_sign_ctx` (loop form).
fn av1_get_dc_sign_ctx(
  tx : Int,
  a : FixedArray[Int],
  a_off : Int,
  l : FixedArray[Int],
  l_off : Int,
) -> Int {
  let nw = av1_imin(1 << av1_txfm_lw(tx), 16)
  let nh = av1_imin(1 << av1_txfm_lh(tx), 16)
  let mut s = 0
  for i in 0..<nw {
    s = s + (a[a_off + i] >> 6)
  }
  for i in 0..<nh {
    s = s + (l[l_off + i] >> 6)
  }
  s = s - nw - nh
  (if s != 0 { 1 } else { 0 }) + (if s > 0 { 1 } else { 0 })
}

///|
/// `read_golomb` from recon_tmpl.c.
fn Av1Msac::read_golomb(self : Av1Msac) -> Int {
  let mut len = 0
  let mut val = 1
  while self.decode_bool_equi() == 0 && len < 32 {
    len = len + 1
  }
  while len > 0 {
    len = len - 1
    val = (val << 1) + self.decode_bool_equi().reinterpret_as_int()
  }
  val - 1
}

///|
/// `get_lo_ctx` from recon_tmpl.c; returns (ctx, hi_mag).
fn av1_get_lo_ctx(
  levels : FixedArray[Byte],
  tx_class : Int,
  ctx_tbl : Int,
  x : Int,
  y : Int,
  stride : Int,
) -> (Int, Int) {
  let lv = (i : Int, j : Int) => levels[i * stride + j].to_int()
  let mag0 = lv(0, 1) + lv(1, 0)
  if tx_class == 0 {
    let hi_mag = mag0 + lv(1, 1)
    let mag = hi_mag + lv(0, 2) + lv(2, 0)
    let offset = av1_lo_ctx_offsets[ctx_tbl * 25 + av1_imin(y, 4) * 5 +
        av1_imin(x, 4)].to_int()
    (offset + (if mag > 512 { 4 } else { (mag + 64) >> 7 }), hi_mag)
  } else {
    let hi_mag = mag0 + lv(0, 2)
    let mag = hi_mag + lv(0, 3) + lv(0, 4)
    let offset = 26 + (if y > 1 { 10 } else { y * 5 })
    (offset + (if mag > 512 { 4 } else { (mag + 64) >> 7 }), hi_mag)
  }
}

///|
/// Checked error for the AV1 pixel decode path.
pub(all) suberror Av1DecError {
  Unsupported(String)
}
