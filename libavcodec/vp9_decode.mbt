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
/// Scope: 8-bit 4:2:0 keyframes (`profile 0`), single- or multi-tile, with
/// segmentation and the lossless WHT path.  Inter frames / intra-only frames
/// are rejected (`vp9: inter frame not supported`); probability adaptation
/// (`ff_vp9_adapt_probs`) belongs to the inter-frame slice.  Planes are
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
  // left contexts (per tile, 8/16 entries)
  left_partition : FixedArray[Int32]
  left_mode : FixedArray[Int32]
  left_y_nnz : FixedArray[Int32]
  left_uv_nnz : FixedArray[FixedArray[Int32]]
  left_skip : FixedArray[Int32]
  left_txfm : FixedArray[Int32]
  left_segpred : FixedArray[Int32]
  // per-superblock loop-filter state
  mut lf_level : FixedArray[Int32]
  mut lf_mask : FixedArray[Int32]
  // above-SB-row backup of the pre-loopfilter bottom row (y/cb/cr)
  mut intra_pred : FixedArray[FixedArray[Int32]]
  // probability model
  prob : FixedArray[Int32]
  prob_coef : FixedArray[Int32]
  prob_ctx_coef : FixedArray[Int32]
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
  b : Vp9Block
  mut rac : Vp9RangeDecoder
  mut tile_col_start : Int32
  mut b_row : Int32
  mut b_col : Int32
  mut tx_mode : Int32
  mut frame_ready : Bool
}

///|
/// Create a profile-0 keyframe decoder. Feed individual VP9 frame payloads
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
    lf_level: FixedArray::make(1, 0),
    lf_mask: FixedArray::make(1, 0),
    intra_pred: [
      FixedArray::make(1, 0),
      FixedArray::make(1, 0),
      FixedArray::make(1, 0),
    ],
    prob: FixedArray::make(VP9_PC_SIZE, 0),
    prob_coef: FixedArray::make(4 * 2 * 2 * 6 * 6 * 11, 0),
    prob_ctx_coef: FixedArray::make(4 * 4 * 2 * 2 * 6 * 6 * 3, 0),
    seg_qmul: FixedArray::make(32, 0),
    seg_lflvl: FixedArray::make(64, 0),
    seg_map: FixedArray::make(1, 0),
    lim_lut: FixedArray::make(64, 0),
    mblim_lut: FixedArray::make(64, 0),
    sharpness: -1,
    block: FixedArray::make(4096, 0),
    uvblock0: FixedArray::make(1024, 0),
    uvblock1: FixedArray::make(1024, 0),
    eob: FixedArray::make(256, 0),
    uveob0: FixedArray::make(64, 0),
    uveob1: FixedArray::make(64, 0),
    cache: FixedArray::make(1024, 0),
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
fn vp9_seg_tree_probs(h : Vp9FrameHeader) -> Array[Int32] {
  h.segmentation.tree_probs
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
  let n_sb = self.sb_cols * self.sb_rows
  self.lf_level = FixedArray::make(n_sb * 64, 0)
  self.lf_mask = FixedArray::make(n_sb * 128, 0)
  self.intra_pred = [
    FixedArray::make(self.cols * 8, 0),
    FixedArray::make((self.cols * 8) >> ss_h, 0),
    FixedArray::make((self.cols * 8) >> ss_h, 0),
  ]
  self.seg_map = FixedArray::make(self.sb_cols * 8 * self.sb_rows * 8, 0)
}

///|
/// Reset the four frame-context slots to the defaults (keyframes /
/// error-resilient / intra-only resetctx=3). */
fn Vp9Decoder::reset_prob_ctx(self : Vp9Decoder) -> Unit {
  // all four slots receive the defaults; the active model starts from them
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
    self.seg_qmul[i * 4] = vp9_dc_qlookup[qydc]
    self.seg_qmul[i * 4 + 1] = vp9_ac_qlookup[qyac]
    self.seg_qmul[i * 4 + 2] = vp9_dc_qlookup[quvdc]
    self.seg_qmul[i * 4 + 3] = vp9_ac_qlookup[quvac]
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
/// Decode one frame (8 bpp keyframes).  Returns an error for inter /
/// intra-only / show-existing frames, which the next slices cover. */
pub fn Vp9Decoder::decode_frame(self : Vp9Decoder, data : Bytes) -> Result[Unit, String] {
  let header = match vp9_parse_frame_header(data) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  if header.show_existing_frame {
    return Err("vp9: show_existing_frame not supported")
  }
  if !header.keyframe {
    return Err("vp9: inter frame not supported")
  }
  if header.profile != 0 {
    return Err("vp9: only profile 0 (8-bit 4:2:0) is supported")
  }
  let pkt = match vp9_parse_packet(data) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let h = pkt.header
  self.header = h
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
  // probability contexts: keyframes reset all four slots
  self.reset_prob_ctx()
  match self.apply_compressed_header(data) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  h.tx_mode = self.tx_mode
  self.init_filter_lut(h.filter_sharpness)
  self.setup_segmentation()
  // main tile decode loop
  for i in 0..<self.cols {
    self.above_partition[i] = 0
    self.above_skip[i] = 0
    self.above_segpred[i] = 0
  }
  for i in 0..<(self.cols * 2) {
    self.above_mode[i] = 2
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
        for i in 0..<16 {
          self.left_mode[i] = 2
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
  self.frame_ready = h.show_frame
  Ok(())
}

///|
/// Pack the current frame as contiguous yuv420p bytes (width×height luma,
/// then chroma planes), for MD5 comparison against the reference decoder. */
pub fn Vp9Decoder::frame_bytes(self : Vp9Decoder) -> Bytes {
  let w = self.width
  let h = self.height
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  let buf : FixedArray[Byte] = FixedArray::make(w * h + 2 * cw * ch, b'\x00')
  let mut o = 0
  for y in 0..<h {
    let src = self.ybase + y * self.ystride
    for x in 0..<w {
      buf[o] = self.y[src + x].to_byte()
      o += 1
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
        buf[o] = plane[src + x].to_byte()
        o += 1
      }
    }
  }
  Bytes::from_array(buf[:])
}
