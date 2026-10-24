///|
/// MoonBit port of the VP9 frame-level decoder from FFmpeg 9.0.2
/// `libavcodec/vp9.c` (`decode_frame_header` probability handling,
/// `decode_tiles`, the qmul/filter-LUT setup) and `libavcodec/vp9dec.h`
/// (context layout).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Scope: profiles 0/2 (4:2:0, 8/10/12-bit) and profiles 1/3 (4:2:2/4:4:4),
/// single- or multi-tile, with
/// segmentation and the lossless WHT path.  Keyframes, intra-only frames
/// and inter frames are supported (NEARESTMV/NEARMV/ZEROMV/NEWMV,
/// switchable and fixed interpolation filters, single reference).
/// Keyframe reference refresh, hidden frames and show-existing display
/// are supported; probability back-adaptation covers both the
/// parallel-mode commit and the counts-driven `ff_vp9_adapt_probs` path
/// (real-world vectors so far only exercise the commit path).  Scaled
/// reference frames are rejected.  Planes are
/// allocated with 64px padding around the frame so that block overhangs and
/// the 16-wide loop filter stay in bounds (the C relies on AVFrame padding
/// plus emulated-edge MC for the same reason).

///|
/// `ProbContext` flat layout (311 entries) — offsets in C struct order. */
const VP9_PC_TX32P : Int32 = 179 // [2][3]
const VP9_PC_TX16P : Int32 = 185 // [2][2]
const VP9_PC_TX8P : Int32 = 189 // [2]
const VP9_PC_SKIP : Int32 = 191 // [3]
const VP9_PC_SIZE : Int32 = 311

///|
/// Coefficient probability layout: `prob_coef[4][2][2][6][6][11]` flat. */
fn vp9_coef_base(tx : Int32, pl : Int32, inter : Int32) -> Int32 {
  ((tx * 2 + pl) * 2 + inter) * 396
}

///|
/// `prob_ctx_coef[4][4][2][2][6][6][3]` flat (4 frame-context slots). */
fn vp9_ctx_coef_base(c : Int32, tx : Int32, pl : Int32, inter : Int32) -> Int32 {
  c * 1728 + ((tx * 2 + pl) * 2 + inter) * 108
}

pub struct Vp9Decoder {
  /// Parsed header of the frame currently being decoded. */
  mut header : Vp9FrameHeader
  mut width : Int32
  mut height : Int32
  /// Bit depth of the current frame (8/10/12) and derived limits. */
  mut bpp : Int32
  mut bpp_index : Int32
  mut pixel_max : Int32
  /// Mid-gray value `128 << (bpp-8)` used by DC intra prediction. */
  mut pixel_mid : Int32
  /// 8-px units. */
  mut cols : Int32
  mut rows : Int32
  mut sb_cols : Int32
  mut sb_rows : Int32
  mut ss_h : Int32
  mut ss_v : Int32
  /// Plane strides in pixels (padded). */
  mut ystride : Int32
  mut uvstride : Int32
  /// Offset of pixel (0,0) inside the planes (64px base padding). */
  mut ybase : Int32
  mut uvbase : Int32
  mut y : FixedArray[Int32]
  mut cb : FixedArray[Int32]
  mut cr : FixedArray[Int32]
  // above contexts (per frame, whole width)
  mut above_partition : FixedArray[Int32]
  mut above_mode : FixedArray[Int32]
  mut above_y_nnz : FixedArray[Int32]
  mut above_uv_nnz : FixedArray[FixedArray[Int32]]
  mut above_skip : FixedArray[Int32]
  mut above_txfm : FixedArray[Int32]
  mut above_segpred : FixedArray[Int32]
  // inter contexts (above)
  mut above_intra : FixedArray[Int32]
  mut above_comp : FixedArray[Int32]
  mut above_ref : FixedArray[Int32]
  mut above_filter : FixedArray[Int32]
  mut above_mv_x : FixedArray[Int32]
  mut above_mv_y : FixedArray[Int32]
  // left contexts (per tile, 8/16 entries)
  left_partition : FixedArray[Int32]
  left_mode : FixedArray[Int32]
  left_y_nnz : FixedArray[Int32]
  left_uv_nnz : FixedArray[FixedArray[Int32]]
  left_skip : FixedArray[Int32]
  left_txfm : FixedArray[Int32]
  left_segpred : FixedArray[Int32]
  // inter contexts (left)
  left_intra : FixedArray[Int32]
  left_comp : FixedArray[Int32]
  left_ref : FixedArray[Int32]
  left_filter : FixedArray[Int32]
  left_mv_x : FixedArray[Int32]
  left_mv_y : FixedArray[Int32]
  // per-superblock loop-filter state
  mut lf_level : FixedArray[Int32]
  mut lf_mask : FixedArray[Int32]
  // above-SB-row backup of the pre-loopfilter bottom row (y/cb/cr)
  mut intra_pred : FixedArray[FixedArray[Int32]]
  // probability model: working copy + four persistent frame-context slots
  prob : FixedArray[Int32]
  prob_ctx : FixedArray[Int32]
  prob_coef : FixedArray[Int32]
  prob_ctx_coef : FixedArray[Int32]
  // backward-adaptation statistics
  counts : FixedArray[Int32]
  // segmentation-derived quantizer and filter levels
  seg_qmul : FixedArray[Int32]
  seg_lflvl : FixedArray[Int32]
  mut seg_map : FixedArray[Int32]
  lim_lut : FixedArray[Int32]
  mblim_lut : FixedArray[Int32]
  mut sharpness : Int32
  // per-block scratch
  block : FixedArray[Int32]
  uvblock0 : FixedArray[Int32]
  uvblock1 : FixedArray[Int32]
  eob : FixedArray[Int32]
  uveob0 : FixedArray[Int32]
  uveob1 : FixedArray[Int32]
  cache : FixedArray[Int32]
  // motion compensation scratch (edge emulation + 2d filter temp)
  mc_tmp : FixedArray[Int32]
  b : Vp9Block
  mut rac : Vp9RangeDecoder
  mut tile_col_start : Int32
  mut b_row : Int32
  mut b_col : Int32
  mut tx_mode : Int32
  mut frame_ready : Bool
  // MV clamping window for the current block
  mut min_mv_x : Int32
  mut min_mv_y : Int32
  mut max_mv_x : Int32
  mut max_mv_y : Int32
  // per-reference scale factors ((refw << 14) / w, 0 = unscaled)
  mvscale_x : FixedArray[Int32]
  mvscale_y : FixedArray[Int32]
  mvstep_x : FixedArray[Int32]
  mvstep_y : FixedArray[Int32]
  // MV reference map of the current frame and the previous one
  mut mvmap : FixedArray[Vp9MvRefPair]
  mut prev_mvmap : FixedArray[Vp9MvRefPair]
  mut use_last_frame_mvs : Bool
  // segmentation map of the reference frame (REF_FRAME_SEGMAP)
  mut ref_segmap : FixedArray[Int32]?
  // previous-frame flags
  mut last_keyframe : Bool
  mut last_invisible : Bool
  // Packed display snapshots; the planes of refreshed references are kept
  // by reference (each frame allocates fresh planes).
  references : FixedArray[Vp9RefFrame?]
  mut display_bytes : Bytes?
}

///|
/// One 8x8 position's motion-vector reference pair (`VP9mvrefPair`).
pub struct Vp9MvRefPair {
  mut ref0 : Int32
  mut ref1 : Int32
  mut x0 : Int32
  mut y0 : Int32
  mut x1 : Int32
  mut y1 : Int32
}

///|
/// A stored reference frame: padded planes plus the packed display bytes and
/// the per-position MV/segmentation maps other frames predict from.
pub struct Vp9RefFrame {
  width : Int32
  height : Int32
  y : FixedArray[Int32]
  cb : FixedArray[Int32]
  cr : FixedArray[Int32]
  ystride : Int32
  uvstride : Int32
  ybase : Int32
  uvbase : Int32
  packed : Bytes
  mvmap : FixedArray[Vp9MvRefPair]
  segmap : FixedArray[Int32]
}

///|
/// Create a VP9 decoder. Feed individual VP9 frame payloads
/// (strip IVF/container framing, or split a superframe packet first), then
/// read tightly packed Y, Cb and Cr bytes with `frame_bytes`.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.vp9_decoder_new()
///   assert_eq(decoder.frame_bytes().length(), 0)
/// }
/// ```
pub fn vp9_decoder_new() -> Vp9Decoder {
  {
    header: vp9_default_header(),
    width: 0,
    height: 0,
    bpp: 8,
    bpp_index: 0,
    pixel_max: 255,
    pixel_mid: 128,
    cols: 0,
    rows: 0,
    sb_cols: 0,
    sb_rows: 0,
    ss_h: 1,
    ss_v: 1,
    ystride: 0,
    uvstride: 0,
    ybase: 0,
    uvbase: 0,
    y: FixedArray::make(1, 0),
    cb: FixedArray::make(1, 0),
    cr: FixedArray::make(1, 0),
    above_partition: FixedArray::make(1, 0),
    above_mode: FixedArray::make(1, 0),
    above_y_nnz: FixedArray::make(1, 0),
    above_uv_nnz: [
      FixedArray::make(1, 0),
      FixedArray::make(1, 0),
    ],
    above_skip: FixedArray::make(1, 0),
    above_txfm: FixedArray::make(1, 0),
    above_segpred: FixedArray::make(1, 0),
    above_intra: FixedArray::make(1, 0),
    above_comp: FixedArray::make(1, 0),
    above_ref: FixedArray::make(1, 0),
    above_filter: FixedArray::make(1, 0),
    above_mv_x: FixedArray::make(1, 0),
    above_mv_y: FixedArray::make(1, 0),
    left_partition: FixedArray::make(8, 0),
    left_mode: FixedArray::make(16, 0),
    left_y_nnz: FixedArray::make(16, 0),
    left_uv_nnz: [
      FixedArray::make(16, 0),
      FixedArray::make(16, 0),
    ],
    left_skip: FixedArray::make(8, 0),
    left_txfm: FixedArray::make(8, 0),
    left_segpred: FixedArray::make(8, 0),
    left_intra: FixedArray::make(8, 0),
    left_comp: FixedArray::make(8, 0),
    left_ref: FixedArray::make(8, 0),
    left_filter: FixedArray::make(8, 0),
    left_mv_x: FixedArray::make(32, 0),
    left_mv_y: FixedArray::make(32, 0),
    lf_level: FixedArray::make(1, 0),
    lf_mask: FixedArray::make(1, 0),
    intra_pred: [
      FixedArray::make(1, 0),
      FixedArray::make(1, 0),
      FixedArray::make(1, 0),
    ],
    prob: FixedArray::make(VP9_PC_SIZE, 0),
    prob_ctx: FixedArray::make(4 * VP9_PC_SIZE, 0),
    prob_coef: FixedArray::make(4 * 2 * 2 * 6 * 6 * 11, 0),
    prob_ctx_coef: FixedArray::make(4 * 4 * 2 * 2 * 6 * 6 * 3, 0),
    counts: FixedArray::make(VP9_CT_SIZE, 0),
    seg_qmul: FixedArray::make(32, 0),
    seg_lflvl: FixedArray::make(64, 0),
    seg_map: FixedArray::make(1, 0),
    lim_lut: FixedArray::make(64, 0),
    mblim_lut: FixedArray::make(64, 0),
    sharpness: -1,
    block: FixedArray::make(4096, 0),
    uvblock0: FixedArray::make(4096, 0),
    uvblock1: FixedArray::make(4096, 0),
    eob: FixedArray::make(256, 0),
    uveob0: FixedArray::make(256, 0),
    uveob1: FixedArray::make(256, 0),
    cache: FixedArray::make(1024, 0),
    mc_tmp: FixedArray::make(160 * 80, 0),
    b: vp9_block_new(),
    rac: match vp9_rac_init(b"\x00\x00\x00", 0, 3) {
      Ok(c) => c
      Err(_) => abort("unreachable")
    },
    tile_col_start: 0,
    b_row: 0,
    b_col: 0,
    tx_mode: 0,
    frame_ready: false,
    min_mv_x: 0,
    min_mv_y: 0,
    max_mv_x: 0,
    max_mv_y: 0,
    mvscale_x: FixedArray::make(3, 0),
    mvscale_y: FixedArray::make(3, 0),
    mvstep_x: FixedArray::make(3, 0),
    mvstep_y: FixedArray::make(3, 0),
    mvmap: FixedArray::make(1, Vp9MvRefPair::{ ref0: -1, ref1: -1, x0: 0, y0: 0, x1: 0, y1: 0 }),
    prev_mvmap: FixedArray::make(1, Vp9MvRefPair::{ ref0: -1, ref1: -1, x0: 0, y0: 0, x1: 0, y1: 0 }),
    use_last_frame_mvs: false,
    ref_segmap: None,
    last_keyframe: false,
    last_invisible: false,
    references: FixedArray::make(8, None),
    display_bytes: None,
  }
}

///|
fn vp9_bwh8_at(bs : Int32) -> FixedArray[Int32] {
  let base = 26 + bs * 2
  let r : FixedArray[Int32] = FixedArray::make(2, 0)
  r[0] = vp9_bwh_tab[base]
  r[1] = vp9_bwh_tab[base + 1]
  r
}

///|
fn vp9_bwh4_at(bs : Int32) -> FixedArray[Int32] {
  let base = bs * 2
  let r : FixedArray[Int32] = FixedArray::make(2, 0)
  r[0] = vp9_bwh_tab[base]
  r[1] = vp9_bwh_tab[base + 1]
  r
}

///|
fn Vp9Decoder::lossless(self : Vp9Decoder) -> Int32 {
  if self.header.lossless {
    1
  } else {
    0
  }
}

///|
fn Vp9Decoder::filter_level(self : Vp9Decoder) -> Int32 {
  self.header.filter_level
}

///|


///|
/// `update_size`: (re)allocate planes and per-frame contexts. */
fn Vp9Decoder::update_size(self : Vp9Decoder, w : Int32, h : Int32, ss_h : Int32, ss_v : Int32) -> Unit {
  self.width = w
  self.height = h
  self.bpp = self.header.bit_depth
  self.bpp_index = (self.bpp - 8) >> 1
  self.pixel_max = (1 << self.bpp) - 1
  self.pixel_mid = 128 << (self.bpp - 8)
  self.ss_h = ss_h
  self.ss_v = ss_v
  self.cols = (w + 7) >> 3
  self.rows = (h + 7) >> 3
  self.sb_cols = (w + 63) >> 6
  self.sb_rows = (h + 63) >> 6
  let ystride = self.sb_cols * 64 + 128
  let uvstride = ((self.sb_cols * 64) >> ss_h) + 128
  let yrows = self.rows * 8 + 128
  let uvrows = ((self.rows * 8) >> ss_v) + 128
  self.ystride = ystride
  self.uvstride = uvstride
  self.ybase = ystride * 64 + 64
  self.uvbase = uvstride * 64 + 64
  self.y = FixedArray::make(ystride * yrows, 0)
  self.cb = FixedArray::make(uvstride * uvrows, 0)
  self.cr = FixedArray::make(uvstride * uvrows, 0)
  self.above_partition = FixedArray::make(self.cols, 0)
  self.above_mode = FixedArray::make(self.cols * 2, 0)
  self.above_y_nnz = FixedArray::make(self.sb_cols * 16, 0)
  self.above_uv_nnz = [
    FixedArray::make((self.sb_cols * 16) >> ss_h, 0),
    FixedArray::make((self.sb_cols * 16) >> ss_h, 0),
  ]
  self.above_skip = FixedArray::make(self.cols, 0)
  self.above_txfm = FixedArray::make(self.cols, 0)
  self.above_segpred = FixedArray::make(self.cols, 0)
  self.above_intra = FixedArray::make(self.cols, 0)
  self.above_comp = FixedArray::make(self.cols, 0)
  self.above_ref = FixedArray::make(self.cols, 0)
  self.above_filter = FixedArray::make(self.cols, 0)
  self.above_mv_x = FixedArray::make(self.cols * 4, 0)
  self.above_mv_y = FixedArray::make(self.cols * 4, 0)
  let n_sb = self.sb_cols * self.sb_rows
  self.lf_level = FixedArray::make(n_sb * 64, 0)
  self.lf_mask = FixedArray::make(n_sb * 128, 0)
  self.intra_pred = [
    FixedArray::make(self.cols * 8, 0),
    FixedArray::make((self.cols * 8) >> ss_h, 0),
    FixedArray::make((self.cols * 8) >> ss_h, 0),
  ]
  self.seg_map = FixedArray::make(self.sb_cols * 8 * self.sb_rows * 8, 0)
  // the MV reference map shares the segmentation map's superblock-grid
  // layout: blocks overhanging the right/bottom frame edge still write
  // their full extent (C `VP9Frame.mv`)
  let n_pos = self.sb_cols * 8 * self.sb_rows * 8
  let mvmap : FixedArray[Vp9MvRefPair] = FixedArray::make(n_pos, Vp9MvRefPair::{ ref0: -1, ref1: -1, x0: 0, y0: 0, x1: 0, y1: 0 })
  for i in 0..<n_pos {
    mvmap[i] = Vp9MvRefPair::{ ref0: -1, ref1: -1, x0: 0, y0: 0, x1: 0, y1: 0 }
  }
  self.mvmap = mvmap
}

///|
/// Reset the four frame-context slots to the defaults (keyframes /
/// error-resilient / intra-only resetctx=3). */
fn Vp9Decoder::reset_prob_ctx(self : Vp9Decoder) -> Unit {
  // all four slots receive the defaults; the active model starts from them
  for c in 0..<4 {
    let base = c * VP9_PC_SIZE
    for i in 0..<VP9_PC_SIZE {
      self.prob_ctx[base + i] = vp9_default_probs[i]
    }
  }
  for i in 0..<VP9_PC_SIZE {
    self.prob[i] = vp9_default_probs[i]
  }
  for c in 0..<4 {
    let base = c * 1728
    for i in 0..<1728 {
      self.prob_ctx_coef[base + i] = vp9_default_coef_probs[i]
    }
  }
}

///|
/// Reset a single frame-context slot to the defaults (intra-only resetctx=2).
fn Vp9Decoder::reset_one_prob_ctx(self : Vp9Decoder, c : Int32) -> Unit {
  let base = c * VP9_PC_SIZE
  for i in 0..<VP9_PC_SIZE {
    self.prob_ctx[base + i] = vp9_default_probs[i]
  }
  let cbase = c * 1728
  for i in 0..<1728 {
    self.prob_ctx_coef[cbase + i] = vp9_default_coef_probs[i]
  }
}

///|
/// `filter_lut` init when the sharpness changed. */
fn Vp9Decoder::init_filter_lut(self : Vp9Decoder, sharp : Int32) -> Unit {
  if self.sharpness != sharp {
    for i in 1..<64 {
      let mut limit = i
      if sharp > 0 {
        limit = limit >> ((sharp + 3) >> 2)
        limit = vp9_min(limit, 9 - sharp)
      }
      if limit < 1 {
        limit = 1
      }
      self.lim_lut[i] = limit
      self.mblim_lut[i] = 2 * (i + 2) + limit
    }
    self.sharpness = sharp
  }
}

///|
/// qmul[] and lflvl[][] per segmentation feature (C decode_frame_header). */
fn Vp9Decoder::setup_segmentation(self : Vp9Decoder) -> Unit {
  let h = self.header
  let n = if h.segmentation.enabled {
    8
  } else {
    1
  }
  for i in 0..<n {
    let feat = h.segmentation.features[i]
    let mut qyac = h.base_q_idx
    if h.segmentation.enabled && feat.q_enabled {
      if h.segmentation.absolute_vals {
        qyac = vp9_clip_u8(feat.q_value)
      } else {
        qyac = vp9_clip_u8(h.base_q_idx + feat.q_value)
      }
    }
    let qydc = vp9_clip_u8(qyac + h.ydc_qdelta)
    let quvdc = vp9_clip_u8(qyac + h.uvdc_qdelta)
    let quvac = vp9_clip_u8(qyac + h.uvac_qdelta)
    qyac = vp9_clip_u8(qyac)
    // qlookup rows are bpp-index major (0=8, 1=10, 2=12 bit)
    let qrow = self.bpp_index * 256
    self.seg_qmul[i * 4] = vp9_dc_qlookup[qrow + qydc]
    self.seg_qmul[i * 4 + 1] = vp9_ac_qlookup[qrow + qyac]
    self.seg_qmul[i * 4 + 2] = vp9_dc_qlookup[qrow + quvdc]
    self.seg_qmul[i * 4 + 3] = vp9_ac_qlookup[qrow + quvac]
    let sh = if h.filter_level >= 32 {
      1
    } else {
      0
    }
    let mut lflvl = h.filter_level
    if h.segmentation.enabled && feat.lf_enabled {
      if h.segmentation.absolute_vals {
        lflvl = vp9_clip_u6(feat.lf_value)
      } else {
        lflvl = vp9_clip_u6(h.filter_level + feat.lf_value)
      }
    }
    if h.lf_delta_enabled {
      self.seg_lflvl[i * 8 + 0] = vp9_clip_u6(lflvl + (h.lf_ref_deltas[0] * (1 << sh)))
      self.seg_lflvl[i * 8 + 1] = vp9_clip_u6(lflvl + (h.lf_ref_deltas[0] * (1 << sh)))
      for j in 1..<4 {
        self.seg_lflvl[i * 8 + j * 2] = vp9_clip_u6(
          lflvl + ((h.lf_ref_deltas[j] + h.lf_mode_deltas[0]) * (1 << sh)),
        )
        self.seg_lflvl[i * 8 + j * 2 + 1] = vp9_clip_u6(
          lflvl + ((h.lf_ref_deltas[j] + h.lf_mode_deltas[1]) * (1 << sh)),
        )
      }
    } else {
      for j in 0..<4 {
        self.seg_lflvl[i * 8 + j * 2] = lflvl
        self.seg_lflvl[i * 8 + j * 2 + 1] = lflvl
      }
    }
  }
}

///|
/// Apply the arithmetic-coded header to the real probability model
/// (C `decode_frame_header` from the marker bit through the skip-prob
/// updates; the inter-mode updates are consumed for keyframes only in so
/// far as they exist — keyframes have none). */
fn Vp9Decoder::apply_compressed_header(self : Vp9Decoder, data : Bytes) -> Result[Unit, String] {
  let h = self.header
  let c = match vp9_rac_init(data, h.uncompressed_header_size, h.compressed_header_size) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  if vp9_rac_get_prob(c, 128) != 0 {
    return Err("vp9: marker bit was set")
  }
  if h.lossless {
    self.tx_mode = 0
  } else {
    self.tx_mode = vp9_rac_get_uint(c, 2)
    if self.tx_mode == 3 {
      self.tx_mode += vp9_rac_get_bool(c)
    }
    if self.tx_mode == 4 {
      for i in 0..<2 {
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[VP9_PC_TX8P + i] = vp9_rac_update_prob(c, self.prob[VP9_PC_TX8P + i])
        }
      }
      for i in 0..<2 {
        for j in 0..<2 {
          let idx = VP9_PC_TX16P + i * 2 + j
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
          }
        }
      }
      for i in 0..<2 {
        for j in 0..<3 {
          let idx = VP9_PC_TX32P + i * 3 + j
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
          }
        }
      }
    }
  }
  // coef updates
  let ctx = h.frame_context_idx
  for tx in 0..<4 {
    if vp9_rac_get_bool(c) != 0 {
      for pl in 0..<2 {
        for inter in 0..<2 {
          for band in 0..<6 {
            for ctxn in 0..<6 {
              if ctxn >= 3 && band == 0 {
                break
              }
              let pb = vp9_ctx_coef_base(ctx, tx, pl, inter) +
                (band * 6 + ctxn) * 3
              let pbase = vp9_coef_base(tx, pl, inter) +
                (band * 6 + ctxn) * 11
              for n in 0..<3 {
                if vp9_rac_get_prob(c, 252) != 0 {
                  self.prob_coef[pbase + n] = vp9_rac_update_prob(
                    c,
                    self.prob_ctx_coef[pb + n],
                  )
                } else {
                  self.prob_coef[pbase + n] = self.prob_ctx_coef[pb + n]
                }
              }
              let p2 = self.prob_coef[pbase + 2] * 8
              for n in 0..<8 {
                self.prob_coef[pbase + 3 + n] = vp9_model_pareto8[p2 + n]
              }
            }
          }
        }
      }
    } else {
      for pl in 0..<2 {
        for inter in 0..<2 {
          for band in 0..<6 {
            for ctxn in 0..<6 {
              if ctxn > 3 && band == 0 {
                break
              }
              let pb = vp9_ctx_coef_base(ctx, tx, pl, inter) +
                (band * 6 + ctxn) * 3
              let pbase = vp9_coef_base(tx, pl, inter) +
                (band * 6 + ctxn) * 11
              for n in 0..<3 {
                self.prob_coef[pbase + n] = self.prob_ctx_coef[pb + n]
              }
              let p2 = self.prob_coef[pbase + 2] * 8
              for n in 0..<8 {
                self.prob_coef[pbase + 3 + n] = vp9_model_pareto8[p2 + n]
              }
            }
          }
        }
      }
    }
    if self.tx_mode == tx {
      break
    }
  }
  // skip probs
  for i in 0..<3 {
    if vp9_rac_get_prob(c, 252) != 0 {
      self.prob[VP9_PC_SKIP + i] = vp9_rac_update_prob(c, self.prob[VP9_PC_SKIP + i])
    }
  }
  if !h.keyframe && !h.intra_only {
    // inter mode updates; the MV-related fields use the plain 7-bit
    // subexp reading instead of the update_prob model (C quirk)
    for i in 0..<7 {
      for j in 0..<3 {
        let idx = VP9_PC_MV_MODE + i * 3 + j
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
        }
      }
    }
    if h.filter_mode == 4 {
      for i in 0..<4 {
        for j in 0..<2 {
          let idx = VP9_PC_FILTER + i * 2 + j
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
          }
        }
      }
    }
    for i in 0..<4 {
      let idx = VP9_PC_INTRA + i
      if vp9_rac_get_prob(c, 252) != 0 {
        self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
      }
    }
    if h.allow_comp_inter {
      h.comp_pred_mode = vp9_rac_get_bool(c)
      if h.comp_pred_mode != 0 {
        h.comp_pred_mode = h.comp_pred_mode + vp9_rac_get_bool(c)
      }
      if h.comp_pred_mode == 2 {
        for i in 0..<5 {
          let idx = VP9_PC_COMP + i
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
          }
        }
      }
    } else {
      h.comp_pred_mode = 0
    }
    if h.comp_pred_mode != 1 {
      for i in 0..<5 {
        for j in 0..<2 {
          let idx = VP9_PC_SINGLE_REF + i * 2 + j
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
          }
        }
      }
    }
    if h.comp_pred_mode != 0 {
      for i in 0..<5 {
        let idx = VP9_PC_COMP_REF + i
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
        }
      }
    }
    for i in 0..<4 {
      for j in 0..<9 {
        let idx = VP9_PC_Y_MODE + i * 9 + j
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
        }
      }
    }
    for i in 0..<4 {
      for j in 0..<4 {
        for k in 0..<3 {
          let idx = VP9_PC_PARTITION + ((3 - i) * 4 + j) * 3 + k
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = vp9_rac_update_prob(c, self.prob[idx])
          }
        }
      }
    }
    for i in 0..<3 {
      let idx = VP9_PC_MV_JOINT + i
      if vp9_rac_get_prob(c, 252) != 0 {
        self.prob[idx] = (vp9_rac_get_uint(c, 7) << 1) | 1
      }
    }
    for i in 0..<2 {
      let base = VP9_PC_MV_COMP + i * VP9_MV_COMP_SIZE
      if vp9_rac_get_prob(c, 252) != 0 {
        self.prob[base] = (vp9_rac_get_uint(c, 7) << 1) | 1
      }
      for j in 0..<10 {
        let idx = base + 1 + j
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[idx] = (vp9_rac_get_uint(c, 7) << 1) | 1
        }
      }
      if vp9_rac_get_prob(c, 252) != 0 {
        self.prob[base + 11] = (vp9_rac_get_uint(c, 7) << 1) | 1
      }
      for j in 0..<10 {
        let idx = base + 12 + j
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[idx] = (vp9_rac_get_uint(c, 7) << 1) | 1
        }
      }
    }
    for i in 0..<2 {
      let base = VP9_PC_MV_COMP + i * VP9_MV_COMP_SIZE
      for j in 0..<2 {
        for k in 0..<3 {
          let idx = base + 22 + j * 3 + k
          if vp9_rac_get_prob(c, 252) != 0 {
            self.prob[idx] = (vp9_rac_get_uint(c, 7) << 1) | 1
          }
        }
      }
      for j in 0..<3 {
        let idx = base + 28 + j
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[idx] = (vp9_rac_get_uint(c, 7) << 1) | 1
        }
      }
    }
    if h.high_precision_mvs {
      for i in 0..<2 {
        let base = VP9_PC_MV_COMP + i * VP9_MV_COMP_SIZE
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[base + 31] = (vp9_rac_get_uint(c, 7) << 1) | 1
        }
        if vp9_rac_get_prob(c, 252) != 0 {
          self.prob[base + 32] = (vp9_rac_get_uint(c, 7) << 1) | 1
        }
      }
    }
  }
  Ok(())
}

///|
/// `set_tile_offset`. */
fn vp9_set_tile_offset(idx : Int32, log2_n : Int32, n : Int32) -> (Int32, Int32) {
  let sb_start = (idx * n) >> log2_n
  let sb_end = ((idx + 1) * n) >> log2_n
  (vp9_min(sb_start, n) << 3, vp9_min(sb_end, n) << 3)
}

///|
/// Decode one VP9 frame (keyframe, intra-only or inter) or display an
/// existing reference slot.
pub fn Vp9Decoder::decode_frame(self : Vp9Decoder, data : Bytes) -> Result[Unit, String] {
  // reference dimensions for inter size inheritance
  let refw : Array[Int32] = []
  let refh : Array[Int32] = []
  for i in 0..<8 {
    match self.references[i] {
      Some(r) => {
        refw.push(r.width)
        refh.push(r.height)
      }
      None => {
        refw.push(0)
        refh.push(0)
      }
    }
  }
  let header = match vp9_parse_frame_header_with_refs(data, refw, refh) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  if header.show_existing_frame {
    guard self.references[header.frame_to_show] is Some(ref_frame) else {
      return Err("vp9: show_existing_frame references an empty slot")
    }
    self.width = ref_frame.width
    self.height = ref_frame.height
    self.display_bytes = Some(ref_frame.packed)
    self.frame_ready = true
    header.width = ref_frame.width
    header.height = ref_frame.height
    self.header = header
    return Ok(())
  }
  if !header.keyframe && !header.intra_only {
    for i in 0..<3 {
      if self.references[header.ref_indices[i]] is None {
        return Err("vp9: not all references are available")
      }
    }
  }
  // snapshot the previous frame's maps before reallocation
  let old_mvmap = self.mvmap
  let old_segmap = self.seg_map
  let old_valid = self.width > 0 && self.height > 0
  let old_w = self.width
  let old_h = self.height
  let pkt = match vp9_parse_packet_with_refs(data, refw, refh) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let h = pkt.header
  if !h.keyframe && !h.intra_only {
    // inter frames do not re-parse the colourspace details; C keeps them in
    // the persistent frame header, so profile/bit-depth/subsampling carry
    // over from the previous frame
    let prev = self.header
    h.profile = prev.profile
    h.bit_depth = prev.bit_depth
    h.chroma_subsampling_x = prev.chroma_subsampling_x
    h.chroma_subsampling_y = prev.chroma_subsampling_y
  }
  if h.profile == 0 || h.profile == 2 {
    if h.chroma_subsampling_x != true || h.chroma_subsampling_y != true {
      return Err("vp9: profiles 0/2 must be 4:2:0")
    }
  } else if h.chroma_subsampling_x && h.chroma_subsampling_y {
    return Err("vp9: profiles 1/3 must be 4:2:2 or 4:4:4")
  }
  self.display_bytes = None
  self.header = h
  let ctx = h.frame_context_idx
  // probability context selection / reset (C decode_frame_header)
  if h.keyframe || h.error_resilient || (h.intra_only && h.resetctx == 3) {
    self.reset_prob_ctx()
  } else if h.intra_only && h.resetctx == 2 {
    self.reset_one_prob_ctx(ctx)
  }
  self.load_prob_ctx()
  match self.apply_compressed_header(data) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  h.tx_mode = self.tx_mode
  // backward-adaptation statistics start from zero every frame
  for i in 0..<VP9_CT_SIZE {
    self.counts[i] = 0
  }
  // REF_FRAME_SEGMAP / REF_FRAME_MVPAIR bookkeeping (vp9_decode_frame)
  if !h.keyframe && !h.intra_only {
    // scaled references are a later slice
    for i in 0..<3 {
      match self.references[h.ref_indices[i]] {
        Some(r) => {
          if r.width == h.width && r.height == h.height {
            self.mvscale_x[i] = 0
            self.mvscale_y[i] = 0
          } else {
            return Err("vp9: scaled reference frames not supported")
          }
        }
        None => return Err("vp9: not all references are available")
      }
    }
    let retain_segmap = self.ref_segmap is Some(_) &&
      (!h.segmentation.enabled || !h.segmentation.update_map)
    if !retain_segmap || h.keyframe || h.intra_only {
      self.ref_segmap = if !h.error_resilient && old_valid {
        Some(old_segmap)
      } else {
        None
      }
    }
    // C drops the segmap reference when the MV-pair frame dimensions do not
    // match the current frame
    if !old_valid || old_w != h.width || old_h != h.height {
      self.ref_segmap = None
    }
    self.use_last_frame_mvs = !h.error_resilient && !self.last_invisible &&
      old_valid &&
      old_w == h.width &&
      old_h == h.height
    self.prev_mvmap = old_mvmap
  }
  self.update_size(h.width, h.height, if h.chroma_subsampling_x {
    1
  } else {
    0
  }, if h.chroma_subsampling_y {
    1
  } else {
    0
  })
  self.frame_ready = false
  self.init_filter_lut(h.filter_sharpness)
  self.setup_segmentation()
  // main tile decode loop
  for i in 0..<self.cols {
    self.above_partition[i] = 0
    self.above_skip[i] = 0
    self.above_segpred[i] = 0
  }
  if h.keyframe || h.intra_only {
    for i in 0..<(self.cols * 2) {
      self.above_mode[i] = 2
    }
  } else {
    for i in 0..<self.cols {
      self.above_mode[i] = 10
    }
  }
  for i in 0..<(self.sb_cols * 16) {
    self.above_y_nnz[i] = 0
  }
  for pl in 0..<2 {
    for i in 0..<((self.sb_cols * 16) >> self.ss_h) {
      self.above_uv_nnz[pl][i] = 0
    }
  }
  // per-tile range decoders (marker bit consumed here)
  let tiles = pkt.tiles
  let racs : Array[Vp9RangeDecoder] = []
  for t in tiles {
    let c = match vp9_rac_init(data, t.offset, t.size) {
      Ok(c) => c
      Err(e) => return Err(e)
    }
    if vp9_rac_get_prob(c, 128) != 0 {
      return Err("vp9: tile marker bit was set")
    }
    racs.push(c)
  }
  let mut tile_idx = 0
  for trow in 0..<h.tile_rows {
    let (row_start, row_end) = vp9_set_tile_offset(trow, h.log2_tile_rows, self.sb_rows)
    let mut row = row_start
    while row < row_end {
      let yoff = self.ybase + row * 8 * self.ystride
      let uvoff = self.uvbase + ((row * 8 * self.uvstride) >> self.ss_v)
      for tcol in 0..<h.tile_cols {
        let (col_start, col_end) = vp9_set_tile_offset(tcol, h.log2_tile_cols, self.sb_cols)
        let rac = racs[tile_idx + tcol]
        self.rac = rac
        self.tile_col_start = col_start
        for i in 0..<8 {
          self.left_partition[i] = 0
          self.left_skip[i] = 0
          self.left_segpred[i] = 0
        }
        if h.keyframe || h.intra_only {
          for i in 0..<16 {
            self.left_mode[i] = 2
          }
        } else {
          for i in 0..<8 {
            self.left_mode[i] = 10
          }
        }
        for i in 0..<16 {
          self.left_y_nnz[i] = 0
          self.left_uv_nnz[0][i] = 0
          self.left_uv_nnz[1][i] = 0
        }
        let mut col = col_start
        while col < col_end {
          let lflvl_idx = (row >> 3) * self.sb_cols + (col >> 3)
          let maskbase = lflvl_idx * 128
          for i in 0..<128 {
            self.lf_mask[maskbase + i] = 0
          }
          if vp9_rac_is_end(self.rac) {
            return Err("vp9: tile ended prematurely")
          }
          self.decode_sb(row, col, lflvl_idx, yoff + col * 8, uvoff + ((col * 8) >> self.ss_h), 0)
          col += 8
        }
      }
      // backup the pre-loopfilter bottom row of this SB row
      if row + 8 < self.rows {
        let src = self.ybase + (row * 8 + 63) * self.ystride
        for i in 0..<(self.cols * 8) {
          self.intra_pred[0][i] = self.y[src + i]
        }
        let usrc = self.uvbase + ((row * 8 * self.uvstride) >> self.ss_v) +
          ((64 >> self.ss_v) - 1) * self.uvstride
        for i in 0..<((self.cols * 8) >> self.ss_h) {
          self.intra_pred[1][i] = self.cb[usrc + i]
          self.intra_pred[2][i] = self.cr[usrc + i]
        }
      }
      // loopfilter one SB row
      if h.filter_level > 0 {
        let mut col = 0
        while col < self.cols {
          let lflvl_idx = (row >> 3) * self.sb_cols + (col >> 3)
          self.loopfilter_sb(lflvl_idx, yoff + col * 8, uvoff + ((col * 8) >> self.ss_h))
          col += 8
        }
      }
      row += 8
    }
    tile_idx += h.tile_cols
  }
  // probability back-adaptation / commit
  if h.refreshctx == 1 && h.parallelmode == 0 {
    self.adapt_probs()
  } else if h.refreshctx == 1 && h.parallelmode == 1 {
    self.commit_prob_ctx()
  }
  self.last_keyframe = h.keyframe
  self.last_invisible = !h.show_frame
  self.frame_ready = h.show_frame
  let snapshot = self.frame_bytes()
  let snap_ref : Vp9RefFrame = {
    width: self.width,
    height: self.height,
    y: self.y,
    cb: self.cb,
    cr: self.cr,
    ystride: self.ystride,
    uvstride: self.uvstride,
    ybase: self.ybase,
    uvbase: self.uvbase,
    packed: snapshot,
    mvmap: self.mvmap,
    segmap: self.seg_map,
  }
  for i in 0..<8 {
    if (h.refresh_frame_flags & (1 << i)) != 0 {
      self.references[i] = Some(snap_ref)
    }
  }
  Ok(())
}

///|
/// Pack the current frame as contiguous bytes (width×height luma, then the
/// two chroma planes at the frame's subsampling), for MD5 comparison against
/// the reference decoder.  Above 8 bpp each sample becomes a little-endian
/// 16-bit word, matching the yuv420p10le/yuv444p12le output layout. */
pub fn Vp9Decoder::frame_bytes(self : Vp9Decoder) -> Bytes {
  if self.display_bytes is Some(bytes) { return bytes }
  let w = self.width
  let h = self.height
  let cw = (w + self.ss_h) >> self.ss_h
  let ch = (h + self.ss_v) >> self.ss_v
  let sbytes = if self.bpp > 8 { 2 } else { 1 }
  let buf : FixedArray[Byte] = FixedArray::make(
    (w * h + 2 * cw * ch) * sbytes,
    b'\x00',
  )
  let mut o = 0
  let store = (v : Int32) => {
    if sbytes == 2 {
      buf[o] = (v & 0xFF).to_byte()
      buf[o + 1] = ((v >> 8) & 0xFF).to_byte()
      o += 2
    } else {
      buf[o] = v.to_byte()
      o += 1
    }
  }
  for y in 0..<h {
    let src = self.ybase + y * self.ystride
    for x in 0..<w {
      store(self.y[src + x])
    }
  }
  for pl in 0..<2 {
    let plane = if pl == 0 {
      self.cb
    } else {
      self.cr
    }
    for y in 0..<ch {
      let src = self.uvbase + y * self.uvstride
      for x in 0..<cw {
        store(plane[src + x])
      }
    }
  }
  Bytes::from_array(buf[:])
}
