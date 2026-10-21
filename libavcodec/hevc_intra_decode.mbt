///|
/// Restricted HEVC intra-frame decoder built on FFmpeg 9.0.2
/// `libavcodec/hevc/hevcdec.c` (`hls_coding_quadtree`, `hls_coding_unit`,
/// `hls_transform_tree`, `hls_transform_unit`) and
/// `libavcodec/hevc/pred_template.c`.
///
/// Supported: 8/10/12-bit 4:2:0/4:2:2/4:4:4, one slice per picture,
/// all-intra deblocking and SAO, no PCM, no scaling lists, no transform
/// skip/RDPCM/cross-component prediction, no tiles or WPP.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// C `MODE_INTER` (0) / `MODE_INTRA` (1); skip CUs use 0 with `skip_flag`. */
let hevc_mode_inter : Int32 = 0

///|
let hevc_mode_intra : Int32 = 1

///|
priv struct HevcIntraDecoder {
  sps : HevcSps
  pps : HevcPps
  mut sh : HevcSliceHeader
  pic : HevcPicture
  mut cabac : HevcCabac
  tab_ipm : Array[Int32]
  tab_ct_depth : Array[Int32]
  qp_y_tab : Array[Int32]
  vertical_bs : Array[Int32]
  horizontal_bs : Array[Int32]
  bs_width : Int32
  sao : HevcSaoParams
  mut na : HevcNeighbourAvail
  mut ctb_left : Bool
  mut ctb_up : Bool
  mut ctb_up_left : Bool
  mut ctb_up_right : Bool
  mut end_of_tiles_x : Int32
  mut end_of_tiles_y : Int32
  mut part_mode : Int32
  mut intra_split : Bool
  mut max_trafo_depth : Int32
  pu_mode : Array[Int32]
  pu_mode_c : Array[Int32]
  mut tu_mode : Int32
  mut tu_mode_c : Int32
  mut qp_y : Int32
  mut qpy_pred : Int32
  mut first_qp_group : Bool
  mut cu_qp_delta : Int32
  mut is_cu_qp_delta_coded : Bool
  mut slice_qp : Int32
  mut cur_cu_x : Int32
  mut cur_cu_y : Int32
  // --- inter slice state (I slices leave these at their defaults) ---
  /// 1 = MODE_INTRA, 0 = MODE_INTER/SKIP (`lc->cu.pred_mode`).
  mut cu_pred_mode : Int32
  /// Merge flag of the most recent PU (`lc->pu.merge_flag`).
  mut pu_merge_flag : Bool
  /// Current frame's per-min-PU motion field.
  tab_mvf : Array[HevcMvField]
  /// Per-min-CB skip flag (`l->skip_flag`).
  skip_flag : Array[Int32]
  /// Per-min-TU cbf luma (`l->cbf_luma`).
  cbf_luma_tab : Array[Int32]
  /// Reference picture lists of the current slice (empty for I slices).
  mut rpl : Array[HevcRefPicList]
  /// Inter-prediction context (set for P/B slices).
  mut inter : HevcInterCtx?
  // --- multi-slice picture state (shared across slice segments) ---
  /// CTB raster -> slice index in `slice_rpls` (`l->tab_slice_address`).
  ctb_slice_idx : Array[Int32]
  /// Per-slice reference-list snapshots, used for cross-slice bS.
  slice_rpls : Array[Array[HevcRefPicList]]
  mut slice_idx : Int32
  /// Per-CTB deblocking offsets and across-slices filter flag
  /// (`l->deblock[].tc_offset/beta_offset`, `l->filter_slice_edges`).
  deblock_tc : Array[Int32]
  deblock_beta : Array[Int32]
  filter_slice_edges : Array[Int32]
}

///|
fn hevc_intra_decoder_new(
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  cabac : HevcCabac,
  slice_qp : Int32,
  pic : HevcPicture,
  tab_mvf : Array[HevcMvField],
  rpl : Array[HevcRefPicList],
  inter : HevcInterCtx?,
) -> HevcIntraDecoder {
  {
    sps,
    pps,
    sh,
    pic,
    cabac,
    tab_ipm: Array::make(sps.min_pu_width * sps.min_pu_height, 1),
    tab_ct_depth: Array::make(sps.min_cb_width * sps.min_cb_height, 0),
    qp_y_tab: Array::make(sps.min_cb_width * sps.min_cb_height, 0),
    vertical_bs: Array::make(
      ((sps.width >> 2) + 1) * ((sps.height >> 2) + 1),
      0,
    ),
    horizontal_bs: Array::make(
      ((sps.width >> 2) + 1) * ((sps.height >> 2) + 1),
      0,
    ),
    bs_width: (sps.width >> 2) + 1,
    sao: hevc_sao_params_new(sps.ctb_size, sps.ctb_width),
    na: hevc_neighbour_avail(),
    ctb_left: false,
    ctb_up: false,
    ctb_up_left: false,
    ctb_up_right: false,
    end_of_tiles_x: sps.width,
    end_of_tiles_y: sps.height,
    part_mode: hevc_part_2nx2n,
    intra_split: false,
    max_trafo_depth: 0,
    pu_mode: Array::make(4, 1),
    pu_mode_c: Array::make(4, 1),
    tu_mode: 1,
    tu_mode_c: 1,
    qp_y: slice_qp,
    qpy_pred: slice_qp,
    first_qp_group: true,
    cu_qp_delta: 0,
    is_cu_qp_delta_coded: false,
    slice_qp,
    cur_cu_x: 0,
    cur_cu_y: 0,
    cu_pred_mode: hevc_mode_intra,
    pu_merge_flag: false,
    tab_mvf,
    skip_flag: Array::make(sps.min_cb_width * sps.min_cb_height, 0),
    cbf_luma_tab: Array::make(sps.min_tb_width * sps.min_tb_height, 0),
    rpl,
    inter,
    ctb_slice_idx: Array::make(sps.ctb_size, -1),
    slice_rpls: [],
    slice_idx: 0,
    deblock_tc: Array::make(sps.ctb_size, 0),
    deblock_beta: Array::make(sps.ctb_size, 0),
    filter_slice_edges: Array::make(sps.ctb_size, 0),
  }
}

///|
/// Switch the decoder to a new slice segment of the same picture, keeping the
/// shared picture tables. Mirrors the per-slice resets in C `decode_slice_data`
/// (`first_qp_group = 1`, `qp_y = slice_qp`) plus a snapshot of the slice's
/// reference lists for cross-slice boundary strengths.
fn HevcIntraDecoder::start_slice(
  self : HevcIntraDecoder,
  sh : HevcSliceHeader,
  cabac : HevcCabac,
  slice_qp : Int32,
  rpl : Array[HevcRefPicList],
  inter : HevcInterCtx?,
) -> Unit {
  self.sh = sh
  self.cabac = cabac
  self.slice_qp = slice_qp
  self.rpl = rpl
  self.inter = inter
  self.slice_idx = self.slice_rpls.length()
  let snap : Array[HevcRefPicList] = []
  for list in rpl {
    let entries : Array[HevcRplEntry] = []
    for e in list.entries {
      entries.push(e)
    }
    snap.push({ entries: entries })
  }
  self.slice_rpls.push(snap)
  self.qp_y = slice_qp
  self.qpy_pred = slice_qp
  self.first_qp_group = true
  self.cu_qp_delta = 0
  self.is_cu_qp_delta_coded = false
  self.cur_cu_x = 0
  self.cur_cu_y = 0
  self.cu_pred_mode = hevc_mode_intra
  self.pu_merge_flag = false
  self.part_mode = hevc_part_2nx2n
  self.intra_split = false
  self.max_trafo_depth = 0
  self.tu_mode = 1
  self.tu_mode_c = 1
  self.na = hevc_neighbour_avail()
}

///|
/// Start a WPP CTB row: QP prediction restarts from the slice QP and the
/// neighbour state is recomputed (C `ff_hevc_cabac_init` row reset). The
/// CABAC context itself is rewound and reloaded by the caller.
fn HevcIntraDecoder::restart_wpp_row(self : HevcIntraDecoder) -> Unit {
  self.first_qp_group = true
  self.qp_y = self.slice_qp
  self.qpy_pred = self.slice_qp
  self.cu_qp_delta = 0
  self.is_cu_qp_delta_coded = false
  self.na = hevc_neighbour_avail()
}

///|
/// `ff_hevc_set_neighbour_available`. */
fn HevcIntraDecoder::set_neighbour_available(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
) -> Unit {
  let ctb_size = 1 << self.sps.log2_ctb_size
  let x0b = x0 & (ctb_size - 1)
  let y0b = y0 & (ctb_size - 1)
  self.na.cand_up = self.ctb_up || y0b != 0
  self.na.cand_left = self.ctb_left || x0b != 0
  self.na.cand_up_left = if x0b != 0 || y0b != 0 {
    self.na.cand_left && self.na.cand_up
  } else {
    self.ctb_up_left
  }
  let up_right_sap = if x0b + n_pb_w == ctb_size {
    self.ctb_up_right && y0b == 0
  } else {
    self.na.cand_up
  }
  self.na.cand_up_right_sap = up_right_sap
  self.na.cand_up_right = up_right_sap && x0 + n_pb_w < self.end_of_tiles_x
  self.na.cand_bottom_left = if y0 + n_pb_h >= self.end_of_tiles_y {
    false
  } else {
    self.na.cand_left
  }
}

///|
/// C `tab_mode_idx`: 4:2:2 chroma mode remapping. */
let hevc_tab_mode_idx : FixedArray[Int32] = [
  0, 1, 2, 2, 2, 2, 3, 5, 7, 8, 10, 12, 13, 15, 17, 18, 19, 20, 21, 22, 23, 23, 24,
  24, 25, 25, 26, 27, 27, 28, 28, 29, 29, 30, 31,
]

///|
/// `luma_intra_pred_mode`: derive MPMs and write the mode into `tab_ipm`. */
fn HevcIntraDecoder::luma_intra_pred_mode(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  pu_size : Int32,
  prev_flag : Bool,
  mpm_idx : Int32,
  rem_mode : Int32,
) -> Int32 {
  let sps = self.sps
  let x_pu = x0 >> sps.log2_min_pu_size
  let y_pu = y0 >> sps.log2_min_pu_size
  let mut size_in_pus = pu_size >> sps.log2_min_pu_size
  let x0b = x0 & ((1 << sps.log2_ctb_size) - 1)
  let y0b = y0 & ((1 << sps.log2_ctb_size) - 1)
  let mut cand_up = if self.ctb_up || y0b != 0 {
    self.tab_ipm[(y_pu - 1) * sps.min_pu_width + x_pu]
  } else {
    1
  }
  let cand_left = if self.ctb_left || x0b != 0 {
    self.tab_ipm[y_pu * sps.min_pu_width + x_pu - 1]
  } else {
    1
  }
  let y_ctb = y0 >> sps.log2_ctb_size << sps.log2_ctb_size
  if y0 - 1 < y_ctb {
    cand_up = 1
  }
  let candidate : Array[Int32] = Array::make(3, 0)
  if cand_left == cand_up {
    if cand_left < 2 {
      candidate[0] = 0
      candidate[1] = 1
      candidate[2] = 26
    } else {
      candidate[0] = cand_left
      candidate[1] = 2 + ((cand_left - 2 - 1 + 32) & 31)
      candidate[2] = 2 + ((cand_left - 2 + 1) & 31)
    }
  } else {
    candidate[0] = cand_left
    candidate[1] = cand_up
    if candidate[0] != 0 && candidate[1] != 0 {
      candidate[2] = 0
    } else if candidate[0] != 1 && candidate[1] != 1 {
      candidate[2] = 1
    } else {
      candidate[2] = 26
    }
  }
  let mode = if prev_flag {
    candidate[mpm_idx]
  } else {
    let mut c0 = candidate[0]
    let mut c1 = candidate[1]
    let mut c2 = candidate[2]
    if c0 > c1 {
      let t = c0
      c0 = c1
      c1 = t
    }
    if c0 > c2 {
      let t = c0
      c0 = c2
      c2 = t
    }
    if c1 > c2 {
      let t = c1
      c1 = c2
      c2 = t
    }
    let mut m = rem_mode
    if m >= c0 {
      m = m + 1
    }
    if m >= c1 {
      m = m + 1
    }
    if m >= c2 {
      m = m + 1
    }
    m
  }
  if size_in_pus < 1 {
    size_in_pus = 1
  }
  for i in 0..<size_in_pus {
    for j in 0..<size_in_pus {
      self.tab_ipm[(y_pu + i) * sps.min_pu_width + x_pu + j] = mode
      self.tab_mvf[(y_pu + i) * sps.min_pu_width + x_pu + j].pred_flag = hevc_pf_intra
    }
  }
  mode
}

///|
/// `intra_prediction_unit`. */
fn HevcIntraDecoder::intra_prediction_unit(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
) -> Unit {
  let split = self.part_mode == hevc_part_nxn
  let pb_size = 1 << log2_cb_size >> (if split { 1 } else { 0 })
  let side = if split { 2 } else { 1 }
  let prev_flags : Array[Bool] = Array::make(4, false)
  for i in 0..<side {
    for j in 0..<side {
      prev_flags[2 * i + j] = self.cabac.prev_intra_luma_pred_flag() != 0
    }
  }
  for i in 0..<side {
    for j in 0..<side {
      let idx = 2 * i + j
      let mpm_idx = if prev_flags[idx] { self.cabac.mpm_idx() } else { 0 }
      let rem = if prev_flags[idx] {
        0
      } else {
        self.cabac.rem_intra_luma_pred_mode()
      }
      self.pu_mode[idx] = self.luma_intra_pred_mode(
        x0 + pb_size * j,
        y0 + pb_size * i,
        pb_size,
        prev_flags[idx],
        mpm_idx,
        rem,
      )
    }
  }
  let intra_chroma_table : FixedArray[Int32] = [0, 26, 10, 1]
  if self.sps.chroma_format_idc == 3 {
    for i in 0..<side {
      for j in 0..<side {
        let idx = 2 * i + j
        let chroma_mode = self.cabac.intra_chroma_pred_mode()
        if chroma_mode != 4 {
          if self.pu_mode[idx] == intra_chroma_table[chroma_mode] {
            self.pu_mode_c[idx] = 34
          } else {
            self.pu_mode_c[idx] = intra_chroma_table[chroma_mode]
          }
        } else {
          self.pu_mode_c[idx] = self.pu_mode[idx]
        }
      }
    }
  } else {
    let chroma_mode = self.cabac.intra_chroma_pred_mode()
    let mode_idx = if chroma_mode != 4 {
      if self.pu_mode[0] == intra_chroma_table[chroma_mode] {
        34
      } else {
        intra_chroma_table[chroma_mode]
      }
    } else {
      self.pu_mode[0]
    }
    self.pu_mode_c[0] = if self.sps.chroma_format_idc == 2 {
      hevc_tab_mode_idx[mode_idx]
    } else {
      mode_idx
    }
    for i in 1..<4 {
      self.pu_mode_c[i] = self.pu_mode_c[0]
    }
  }
}

///|
/// `ff_hevc_set_qPy`: derive the luma QP from neighbours and `cu_qp_delta`.
fn HevcIntraDecoder::set_qpy(
  self : HevcIntraDecoder,
  x_base : Int32,
  y_base : Int32,
) -> Unit {
  let sps = self.sps
  let pps = self.pps
  let ctb_size_mask = (1 << sps.log2_ctb_size) - 1
  let qg_mask = (1 << (sps.log2_ctb_size - pps.diff_cu_qp_delta_depth)) - 1
  let x_qg = x_base - (x_base & qg_mask)
  let y_qg = y_base - (y_base & qg_mask)
  let x_cb = x_qg >> sps.log2_min_cb_size
  let y_cb = y_qg >> sps.log2_min_cb_size
  let available_a = (x_base & ctb_size_mask) != 0 && (x_qg & ctb_size_mask) != 0
  let available_b = (y_base & ctb_size_mask) != 0 && (y_qg & ctb_size_mask) != 0
  let qpy_pred = if self.first_qp_group || (x_qg == 0 && y_qg == 0) {
    self.first_qp_group = !self.is_cu_qp_delta_coded
    self.slice_qp
  } else {
    self.qpy_pred
  }
  let qpy_a = if !available_a {
    qpy_pred
  } else {
    self.qp_y_tab[x_cb - 1 + y_cb * sps.min_cb_width]
  }
  let qpy_b = if !available_b {
    qpy_pred
  } else {
    self.qp_y_tab[x_cb + (y_cb - 1) * sps.min_cb_width]
  }
  let base = (qpy_a + qpy_b + 1) >> 1
  if self.cu_qp_delta != 0 {
    let off = sps.qp_bd_offset
    let m = 52 + off
    self.qp_y = (base + self.cu_qp_delta + 52 + 2 * off) % m - off
  } else {
    self.qp_y = base
  }
}

///|
/// `hls_transform_unit`. `cbf_cb`/`cbf_cr` hold one flag per chroma transform
/// block (two vertically stacked blocks for 4:2:2, one otherwise).
fn HevcIntraDecoder::transform_unit(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  x_base : Int32,
  y_base : Int32,
  _log2_cb_size : Int32,
  log2_trafo_size : Int32,
  blk_idx : Int32,
  cbf_luma_in : Int32,
  cbf_cb : FixedArray[Int32],
  cbf_cr : FixedArray[Int32],
) -> Result[Unit, String] {
  let sps = self.sps
  let pps = self.pps
  let trafo_size = 1 << log2_trafo_size
  self.set_neighbour_available(x0, y0, trafo_size, trafo_size)
  if self.cu_pred_mode == hevc_mode_intra {
    hevc_intra_predict(
      self.pic,
      sps,
      pps,
      self.na,
      x0,
      y0,
      log2_trafo_size,
      0,
      self.tu_mode,
    )
  }
  let cbf_luma = cbf_luma_in
  let log2_trafo_size_c = log2_trafo_size - sps.hshift[1]
  let n_chroma_blocks = if sps.chroma_format_idc == 2 { 2 } else { 1 }
  let cbf_chroma = cbf_cb[0] != 0 ||
    cbf_cr[0] != 0 ||
    (sps.chroma_format_idc == 2 && (cbf_cb[1] != 0 || cbf_cr[1] != 0))
  if cbf_luma != 0 || cbf_chroma {
    if pps.cu_qp_delta_enabled_flag != 0 && !self.is_cu_qp_delta_coded {
      let abs = match self.cabac.cu_qp_delta_abs() {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      self.cu_qp_delta = abs
      if abs != 0 && self.cabac.cu_qp_delta_sign_flag() == 1 {
        self.cu_qp_delta = -abs
      }
      self.is_cu_qp_delta_coded = true
      self.set_qpy(self.cur_cu_x, self.cur_cu_y)
    }
    let mut scan_luma = hevc_scan_diag
    let mut scan_chroma = hevc_scan_diag
    if self.cu_pred_mode == hevc_mode_intra && log2_trafo_size < 4 {
      if self.tu_mode >= 6 && self.tu_mode <= 14 {
        scan_luma = hevc_scan_vert
      } else if self.tu_mode >= 22 && self.tu_mode <= 30 {
        scan_luma = hevc_scan_horiz
      }
      if self.tu_mode_c >= 6 && self.tu_mode_c <= 14 {
        scan_chroma = hevc_scan_vert
      } else if self.tu_mode_c >= 22 && self.tu_mode_c <= 30 {
        scan_chroma = hevc_scan_horiz
      }
    }
    if cbf_luma_in != 0 {
      match
        hevc_hls_residual_coding(
          self.cabac,
          sps,
          pps,
          self.sh,
          self.pic,
          x0,
          y0,
          log2_trafo_size,
          scan_luma,
          0,
          self.qp_y,
          self.cu_pred_mode == hevc_mode_intra,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    if sps.chroma_format_idc != 0 &&
      (log2_trafo_size > 2 || sps.chroma_format_idc == 3) {
      let trafo_size_h = 1 << (log2_trafo_size_c + sps.hshift[1])
      let trafo_size_v = 1 << (log2_trafo_size_c + sps.vshift[1])
      for i in 0..<n_chroma_blocks {
        let y_c = y0 + (i << log2_trafo_size_c)
        self.set_neighbour_available(x0, y_c, trafo_size_h, trafo_size_v)
        if self.cu_pred_mode == hevc_mode_intra {
          hevc_intra_predict(
            self.pic,
            sps,
            pps,
            self.na,
            x0,
            y_c,
            log2_trafo_size_c,
            1,
            self.tu_mode_c,
          )
        }
        if cbf_cb[i] != 0 {
          match
            hevc_hls_residual_coding(
              self.cabac,
              sps,
              pps,
              self.sh,
              self.pic,
              x0,
              y_c,
              log2_trafo_size_c,
              scan_chroma,
              1,
              self.qp_y,
              self.cu_pred_mode == hevc_mode_intra,
            ) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
      for i in 0..<n_chroma_blocks {
        let y_c = y0 + (i << log2_trafo_size_c)
        self.set_neighbour_available(x0, y_c, trafo_size_h, trafo_size_v)
        if self.cu_pred_mode == hevc_mode_intra {
          hevc_intra_predict(
            self.pic,
            sps,
            pps,
            self.na,
            x0,
            y_c,
            log2_trafo_size_c,
            2,
            self.tu_mode_c,
          )
        }
        if cbf_cr[i] != 0 {
          match
            hevc_hls_residual_coding(
              self.cabac,
              sps,
              pps,
              self.sh,
              self.pic,
              x0,
              y_c,
              log2_trafo_size_c,
              scan_chroma,
              2,
              self.qp_y,
              self.cu_pred_mode == hevc_mode_intra,
            ) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
    } else if sps.chroma_format_idc != 0 && blk_idx == 3 {
      let trafo_size_h = 1 << (log2_trafo_size + 1)
      let trafo_size_v = 1 << (log2_trafo_size + sps.vshift[1])
      for i in 0..<n_chroma_blocks {
        let y_c = y_base + (i << log2_trafo_size)
        self.set_neighbour_available(x_base, y_c, trafo_size_h, trafo_size_v)
        if self.cu_pred_mode == hevc_mode_intra {
          hevc_intra_predict(
            self.pic,
            sps,
            pps,
            self.na,
            x_base,
            y_c,
            log2_trafo_size,
            1,
            self.tu_mode_c,
          )
        }
        if cbf_cb[i] != 0 {
          match
            hevc_hls_residual_coding(
              self.cabac,
              sps,
              pps,
              self.sh,
              self.pic,
              x_base,
              y_c,
              log2_trafo_size,
              scan_chroma,
              1,
              self.qp_y,
              self.cu_pred_mode == hevc_mode_intra,
            ) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
      for i in 0..<n_chroma_blocks {
        let y_c = y_base + (i << log2_trafo_size)
        self.set_neighbour_available(x_base, y_c, trafo_size_h, trafo_size_v)
        if self.cu_pred_mode == hevc_mode_intra {
          hevc_intra_predict(
            self.pic,
            sps,
            pps,
            self.na,
            x_base,
            y_c,
            log2_trafo_size,
            2,
            self.tu_mode_c,
          )
        }
        if cbf_cr[i] != 0 {
          match
            hevc_hls_residual_coding(
              self.cabac,
              sps,
              pps,
              self.sh,
              self.pic,
              x_base,
              y_c,
              log2_trafo_size,
              scan_chroma,
              2,
              self.qp_y,
              self.cu_pred_mode == hevc_mode_intra,
            ) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
    }
  } else if sps.chroma_format_idc != 0 && self.cu_pred_mode == hevc_mode_intra {
    if log2_trafo_size > 2 || sps.chroma_format_idc == 3 {
      let trafo_size_h = 1 << (log2_trafo_size_c + sps.hshift[1])
      let trafo_size_v = 1 << (log2_trafo_size_c + sps.vshift[1])
      for i in 0..<n_chroma_blocks {
        let y_c = y0 + (i << log2_trafo_size_c)
        self.set_neighbour_available(x0, y_c, trafo_size_h, trafo_size_v)
        hevc_intra_predict(
          self.pic,
          sps,
          pps,
          self.na,
          x0,
          y_c,
          log2_trafo_size_c,
          1,
          self.tu_mode_c,
        )
        hevc_intra_predict(
          self.pic,
          sps,
          pps,
          self.na,
          x0,
          y_c,
          log2_trafo_size_c,
          2,
          self.tu_mode_c,
        )
      }
    } else if blk_idx == 3 {
      let trafo_size_h = 1 << (log2_trafo_size + 1)
      let trafo_size_v = 1 << (log2_trafo_size + sps.vshift[1])
      for i in 0..<n_chroma_blocks {
        let y_c = y_base + (i << log2_trafo_size)
        self.set_neighbour_available(x_base, y_c, trafo_size_h, trafo_size_v)
        hevc_intra_predict(
          self.pic,
          sps,
          pps,
          self.na,
          x_base,
          y_c,
          log2_trafo_size,
          1,
          self.tu_mode_c,
        )
        hevc_intra_predict(
          self.pic,
          sps,
          pps,
          self.na,
          x_base,
          y_c,
          log2_trafo_size,
          2,
          self.tu_mode_c,
        )
      }
    }
  }
  Ok(())
}

///|
/// `hls_transform_tree`. */
fn HevcIntraDecoder::transform_tree(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  x_base : Int32,
  y_base : Int32,
  log2_cb_size : Int32,
  log2_trafo_size : Int32,
  trafo_depth : Int32,
  blk_idx : Int32,
  cbf_cb_in : FixedArray[Int32],
  cbf_cr_in : FixedArray[Int32],
) -> Result[Unit, String] {
  let sps = self.sps
  let cbf_cb : FixedArray[Int32] = [cbf_cb_in[0], cbf_cb_in[1]]
  let cbf_cr : FixedArray[Int32] = [cbf_cr_in[0], cbf_cr_in[1]]
  if self.intra_split {
    if trafo_depth == 1 {
      self.tu_mode = self.pu_mode[blk_idx]
      self.tu_mode_c = if sps.chroma_format_idc == 3 {
        self.pu_mode_c[blk_idx]
      } else {
        self.pu_mode_c[0]
      }
    }
  } else {
    self.tu_mode = self.pu_mode[0]
    self.tu_mode_c = self.pu_mode_c[0]
  }
  let split = if log2_trafo_size <= sps.log2_max_trafo_size &&
    log2_trafo_size > sps.log2_min_tb_size &&
    trafo_depth < self.max_trafo_depth &&
    !(self.intra_split && trafo_depth == 0) {
    self.cabac.split_transform_flag(log2_trafo_size) != 0
  } else {
    let inter_split = sps.max_transform_hierarchy_depth_inter == 0 &&
      self.cu_pred_mode == hevc_mode_inter &&
      self.part_mode != hevc_part_2nx2n &&
      trafo_depth == 0
    log2_trafo_size > sps.log2_max_trafo_size ||
    (self.intra_split && trafo_depth == 0) ||
    inter_split
  }
  if sps.chroma_format_idc != 0 &&
    (log2_trafo_size > 2 || sps.chroma_format_idc == 3) {
    if trafo_depth == 0 || cbf_cb[0] != 0 {
      cbf_cb[0] = self.cabac.cbf_cb_cr(trafo_depth)
      if sps.chroma_format_idc == 2 && (!split || log2_trafo_size == 3) {
        cbf_cb[1] = self.cabac.cbf_cb_cr(trafo_depth)
      }
    }
    if trafo_depth == 0 || cbf_cr[0] != 0 {
      cbf_cr[0] = self.cabac.cbf_cb_cr(trafo_depth)
      if sps.chroma_format_idc == 2 && (!split || log2_trafo_size == 3) {
        cbf_cr[1] = self.cabac.cbf_cb_cr(trafo_depth)
      }
    }
  }
  if split {
    let half = 1 << (log2_trafo_size - 1)
    let x1 = x0 + half
    let y1 = y0 + half
    match
      self.transform_tree(
        x0,
        y0,
        x0,
        y0,
        log2_cb_size,
        log2_trafo_size - 1,
        trafo_depth + 1,
        0,
        cbf_cb,
        cbf_cr,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match
      self.transform_tree(
        x1,
        y0,
        x0,
        y0,
        log2_cb_size,
        log2_trafo_size - 1,
        trafo_depth + 1,
        1,
        cbf_cb,
        cbf_cr,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match
      self.transform_tree(
        x0,
        y1,
        x0,
        y0,
        log2_cb_size,
        log2_trafo_size - 1,
        trafo_depth + 1,
        2,
        cbf_cb,
        cbf_cr,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match
      self.transform_tree(
        x1,
        y1,
        x0,
        y0,
        log2_cb_size,
        log2_trafo_size - 1,
        trafo_depth + 1,
        3,
        cbf_cb,
        cbf_cr,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    let mut cbf_luma = 1
    if self.cu_pred_mode == hevc_mode_intra ||
      trafo_depth != 0 ||
      cbf_cb[0] != 0 ||
      cbf_cr[0] != 0 ||
      (sps.chroma_format_idc == 2 && (cbf_cb[1] != 0 || cbf_cr[1] != 0)) {
      cbf_luma = self.cabac.cbf_luma(trafo_depth)
    }
    match
      self.transform_unit(
        x0, y0, x_base, y_base, log2_cb_size, log2_trafo_size, blk_idx, cbf_luma,
        cbf_cb, cbf_cr,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if cbf_luma != 0 {
      let min_tu = 1 << sps.log2_min_tb_size
      let size = 1 << log2_trafo_size
      let mut j = 0
      while j < size {
        let mut i = 0
        while i < size {
          self.cbf_luma_tab[((y0 + j) >> sps.log2_min_tb_size) * sps.min_tb_width +
          ((x0 + i) >> sps.log2_min_tb_size)] = 1
          i = i + min_tu
        }
        j = j + min_tu
      }
    }
    if !self.sh.disable_deblocking_filter_flag {
      self.deblocking_boundary_strengths(x0, y0, log2_trafo_size)
    }
  }
  Ok(())
}

///|
/// `hls_coding_unit` for an I or P/B slice. */
fn HevcIntraDecoder::coding_unit(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
  cb_depth : Int32,
) -> Result[Unit, String] {
  let sps = self.sps
  let pps = self.pps
  self.cur_cu_x = x0
  self.cur_cu_y = y0
  self.part_mode = hevc_part_2nx2n
  self.intra_split = false
  self.cu_pred_mode = hevc_mode_intra
  self.pu_merge_flag = false
  let cb_size = 1 << log2_cb_size
  let length = cb_size >> sps.log2_min_cb_size
  let x_cb = x0 >> sps.log2_min_cb_size
  let y_cb = y0 >> sps.log2_min_cb_size
  for y in 0..<length {
    for x in 0..<length {
      self.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = 0
    }
  }
  let ctb_size = 1 << sps.log2_ctb_size
  let mut skip = false
  if self.sh.slice_type != hevc_slice_i {
    skip = self.cabac.skip_flag(
      self.skip_flag,
      x0 & (ctb_size - 1),
      y0 & (ctb_size - 1),
      x_cb,
      y_cb,
      sps.min_cb_width,
      self.ctb_left,
      self.ctb_up,
    ) !=
    0
    let v = if skip { 1 } else { 0 }
    for y in 0..<length {
      for x in 0..<length {
        self.skip_flag[(y_cb + y) * sps.min_cb_width + x_cb + x] = v
      }
    }
    self.cu_pred_mode = hevc_mode_inter
  }
  if skip {
    self.prediction_unit(x0, y0, cb_size, cb_size, log2_cb_size, 0, true)
    self.intra_prediction_unit_default_value(x0, y0, log2_cb_size)
    if !self.sh.disable_deblocking_filter_flag {
      self.deblocking_boundary_strengths(x0, y0, log2_cb_size)
    }
  } else {
    if self.sh.slice_type != hevc_slice_i {
      self.cu_pred_mode = self.cabac.pred_mode_flag()
    }
    if self.cu_pred_mode != hevc_mode_intra ||
      log2_cb_size == sps.log2_min_cb_size {
      self.part_mode = self.cabac.part_mode_decode(
        log2_cb_size,
        sps.log2_min_cb_size,
        sps.amp_enabled != 0,
        self.cu_pred_mode == hevc_mode_intra,
      )
      self.intra_split = self.part_mode == hevc_part_nxn &&
        self.cu_pred_mode == hevc_mode_intra
    }
    if self.cu_pred_mode == hevc_mode_intra {
      self.intra_prediction_unit(x0, y0, log2_cb_size)
    } else {
      self.intra_prediction_unit_default_value(x0, y0, log2_cb_size)
      let half = cb_size >> 1
      let quarter = cb_size >> 2
      match self.part_mode {
        p if p == hevc_part_2nx2n =>
          self.prediction_unit(x0, y0, cb_size, cb_size, log2_cb_size, 0, false)
        p if p == hevc_part_2nxn => {
          self.prediction_unit(x0, y0, cb_size, half, log2_cb_size, 0, false)
          self.prediction_unit(x0, y0 + half, cb_size, half, log2_cb_size, 1, false)
        }
        p if p == hevc_part_nx2n => {
          self.prediction_unit(x0, y0, half, cb_size, log2_cb_size, 0, false)
          self.prediction_unit(x0 + half, y0, half, cb_size, log2_cb_size, 1, false)
        }
        p if p == hevc_part_2nxnu => {
          self.prediction_unit(x0, y0, cb_size, quarter, log2_cb_size, 0, false)
          self.prediction_unit(x0, y0 + quarter, cb_size, cb_size - quarter, log2_cb_size, 1, false)
        }
        p if p == hevc_part_2nxnd => {
          self.prediction_unit(x0, y0, cb_size, cb_size - quarter, log2_cb_size, 0, false)
          self.prediction_unit(x0, y0 + cb_size - quarter, cb_size, quarter, log2_cb_size, 1, false)
        }
        p if p == hevc_part_nlx2n => {
          self.prediction_unit(x0, y0, quarter, cb_size, log2_cb_size, 0, false)
          self.prediction_unit(x0 + quarter, y0, cb_size - quarter, cb_size, log2_cb_size, 1, false)
        }
        p if p == hevc_part_nrx2n => {
          self.prediction_unit(x0, y0, cb_size - quarter, cb_size, log2_cb_size, 0, false)
          self.prediction_unit(x0 + cb_size - quarter, y0, quarter, cb_size, log2_cb_size, 1, false)
        }
        _ => {
          // PART_NxN
          self.prediction_unit(x0, y0, half, half, log2_cb_size, 0, false)
          self.prediction_unit(x0 + half, y0, half, half, log2_cb_size, 1, false)
          self.prediction_unit(x0, y0 + half, half, half, log2_cb_size, 2, false)
          self.prediction_unit(x0 + half, y0 + half, half, half, log2_cb_size, 3, false)
        }
      }
    }
    let mut rqt_root_cbf = 1
    if self.cu_pred_mode != hevc_mode_intra &&
      !(self.part_mode == hevc_part_2nx2n && self.pu_merge_flag) {
      rqt_root_cbf = self.cabac.no_residual_flag()
    }
    if rqt_root_cbf != 0 {
      self.max_trafo_depth = if self.cu_pred_mode == hevc_mode_intra {
        sps.max_transform_hierarchy_depth_intra +
        (if self.intra_split { 1 } else { 0 })
      } else {
        sps.max_transform_hierarchy_depth_inter
      }
      match
        self.transform_tree(
          x0,
          y0,
          x0,
          y0,
          log2_cb_size,
          log2_cb_size,
          0,
          0,
          [0, 0],
          [0, 0],
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if !self.sh.disable_deblocking_filter_flag {
      self.deblocking_boundary_strengths(x0, y0, log2_cb_size)
    }
  }
  if pps.cu_qp_delta_enabled_flag != 0 && !self.is_cu_qp_delta_coded {
    self.set_qpy(x0, y0)
  }
  let x_cb2 = x0 >> sps.log2_min_cb_size
  let y_cb2 = y0 >> sps.log2_min_cb_size
  for y in 0..<(cb_size >> sps.log2_min_cb_size) {
    for x in 0..<(cb_size >> sps.log2_min_cb_size) {
      self.qp_y_tab[(y_cb2 + y) * sps.min_cb_width + x_cb2 + x] = self.qp_y
    }
  }
  let qg_mask = (1 << (sps.log2_ctb_size - pps.diff_cu_qp_delta_depth)) - 1
  if ((x0 + (1 << log2_cb_size)) & qg_mask) == 0 &&
    ((y0 + (1 << log2_cb_size)) & qg_mask) == 0 {
    self.qpy_pred = self.qp_y
  }
  for y in 0..<(cb_size >> sps.log2_min_cb_size) {
    for x in 0..<(cb_size >> sps.log2_min_cb_size) {
      self.tab_ct_depth[(y_cb2 + y) * sps.min_cb_width + x_cb2 + x] = cb_depth
    }
  }
  Ok(())
}

///|
/// `hls_coding_quadtree`: returns the C `more_data` flag. */
fn HevcIntraDecoder::coding_quadtree(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  log2_cb_size : Int32,
  cb_depth : Int32,
) -> Result[Bool, String] {
  let sps = self.sps
  let pps = self.pps
  match self.inter {
    Some(ctx) => ctx.ct_depth = cb_depth
    None => ()
  }
  let cb_size = 1 << log2_cb_size
  let split = if x0 + cb_size <= sps.width &&
    y0 + cb_size <= sps.height &&
    log2_cb_size > sps.log2_min_cb_size {
    self.cabac.split_coding_unit_flag(
      self.ctb_left,
      self.ctb_up,
      self.tab_ct_depth,
      sps,
      cb_depth,
      x0,
      y0,
    ) !=
    0
  } else {
    log2_cb_size > sps.log2_min_cb_size
  }
  if pps.cu_qp_delta_enabled_flag != 0 &&
    log2_cb_size >= sps.log2_ctb_size - pps.diff_cu_qp_delta_depth {
    self.is_cu_qp_delta_coded = false
    self.cu_qp_delta = 0
  }
  if split {
    let half = cb_size >> 1
    let x1 = x0 + half
    let y1 = y0 + half
    let mut more = match
      self.coding_quadtree(x0, y0, log2_cb_size - 1, cb_depth + 1) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if more && x1 < sps.width {
      more = match
        self.coding_quadtree(x1, y0, log2_cb_size - 1, cb_depth + 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    if more && y1 < sps.height {
      more = match
        self.coding_quadtree(x0, y1, log2_cb_size - 1, cb_depth + 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    if more && x1 < sps.width && y1 < sps.height {
      more = match
        self.coding_quadtree(x1, y1, log2_cb_size - 1, cb_depth + 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    let qg_mask = (1 << (sps.log2_ctb_size - pps.diff_cu_qp_delta_depth)) - 1
    if ((x0 + cb_size) & qg_mask) == 0 && ((y0 + cb_size) & qg_mask) == 0 {
      self.qpy_pred = self.qp_y
    }
    if more {
      Ok(x1 + half < sps.width || y1 + half < sps.height)
    } else {
      Ok(false)
    }
  } else {
    match self.coding_unit(x0, y0, log2_cb_size, cb_depth) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let ctb_size = 1 << sps.log2_ctb_size
    if ((x0 + cb_size) % ctb_size == 0 || x0 + cb_size >= sps.width) &&
      ((y0 + cb_size) % ctb_size == 0 || y0 + cb_size >= sps.height) {
      Ok(!self.cabac.terminate())
    } else {
      Ok(true)
    }
  }
}

///|
/// Decode the single intra slice of `data` (Annex B or length-prefixed) into
/// pre-loop-filter 8/10/12-bit 4:2:0 planes.
fn hevc_decode_intra_frame_impl(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
  apply_filters : Bool,
) -> Result[HevcPicture, String] {
  let ps = new_hevc_param_sets()
  let pkt = match ff_h2645_packet_split(data, nal_length_size, Hevc, is_nalff) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  match hevc_decode_extradata_nals(pkt, ps, true) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let mut slice_nal : H2645Nal? = None
  let mut vcl_count = 0
  for nal in pkt.nals {
    if nal.nal_type <= 31 {
      vcl_count = vcl_count + 1
      match slice_nal {
        None => slice_nal = Some(nal)
        Some(_) => ()
      }
    }
  }
  if vcl_count != 1 {
    return Err("PATCHWELCOME: only one HEVC slice per picture is supported")
  }
  let nal = match slice_nal {
    Some(n) => n
    None => return Err("hevc: no slice NAL")
  }
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(16)
  let sh = match ff_hevc_decode_slice_header(gb, nal.nal_type, ps, 0) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  if !sh.first_slice_segment_in_pic_flag {
    return Err("PATCHWELCOME: HEVC slice segment address != 0")
  }
  if sh.slice_type != hevc_slice_i {
    return Err("PATCHWELCOME: only HEVC I slices are supported")
  }
  let pps = match ps.pps_list[sh.pps_id] {
    Some(p) => p
    None => return Err("hevc: missing PPS")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("hevc: missing SPS")
  }
  if (sps.bit_depth != 8 && sps.bit_depth != 10 && sps.bit_depth != 12) ||
    sps.chroma_format_idc == 0 ||
    sps.separate_colour_plane != 0 {
    return Err("PATCHWELCOME: only 8/10/12-bit 4:2:0/4:2:2/4:4:4 HEVC is supported")
  }
  if sps.pcm_enabled != 0 {
    return Err("PATCHWELCOME: HEVC PCM is not supported")
  }
  if pps.transform_skip_enabled_flag != 0 {
    return Err("PATCHWELCOME: HEVC transform skip is not supported")
  }
  if pps.transquant_bypass_enable_flag != 0 {
    return Err("PATCHWELCOME: HEVC transquant bypass is not supported")
  }
  if pps.cross_component_prediction_enabled_flag != 0 {
    return Err("PATCHWELCOME: HEVC cross-component prediction is not supported")
  }
  if sps.scaling_list_enabled != 0 {
    return Err("PATCHWELCOME: HEVC scaling lists are not supported")
  }
  if pps.tiles_enabled_flag != 0 || pps.entropy_coding_sync_enabled_flag != 0 {
    return Err("PATCHWELCOME: HEVC tiles/WPP are not supported")
  }
  let slice_qp = 26 + pps.pic_init_qp_minus26 + sh.slice_qp_delta
  let states = ff_hevc_init_cabac_states(
    slice_qp,
    sh.slice_type,
    sh.cabac_init_flag,
  )
  let data_offset = (sh.header_bits + 7) >> 3
  let cabac = match hevc_cabac_new(nal.data, data_offset, states) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  let tab_mvf : Array[HevcMvField] = []
  for _ in 0..<(sps.min_pu_width * sps.min_pu_height) {
    tab_mvf.push(hevc_mv_field_new())
  }
  let dec = hevc_intra_decoder_new(
    sps,
    pps,
    sh,
    cabac,
    slice_qp,
    hevc_picture_new(
      sps.width,
      sps.height,
      sps.width >> sps.hshift[1],
      sps.height >> sps.vshift[1],
    ),
    tab_mvf,
    [],
    None,
  )
  let ctb_size = 1 << sps.log2_ctb_size
  for i in 0..<sps.ctb_size {
    dec.ctb_slice_idx[i] = 0
    dec.deblock_tc[i] = sh.tc_offset
    dec.deblock_beta[i] = sh.beta_offset
    dec.filter_slice_edges[i] = if sh.slice_loop_filter_across_slices_enabled_flag {
      1
    } else {
      0
    }
  }
  let mut rs = 0
  let mut more = true
  while more && rs < sps.ctb_size {
    let x_ctb = (rs % sps.ctb_width) << sps.log2_ctb_size
    let y_ctb = (rs / sps.ctb_width) << sps.log2_ctb_size
    dec.ctb_left = x_ctb > 0
    dec.ctb_up = y_ctb > 0
    dec.ctb_up_left = x_ctb > 0 && y_ctb > 0
    dec.ctb_up_right = y_ctb > 0
    dec.end_of_tiles_x = sps.width
    dec.end_of_tiles_y = if y_ctb + ctb_size < sps.height {
      y_ctb + ctb_size
    } else {
      sps.height
    }
    if sps.sao_enabled != 0 {
      hevc_sao_parse(
        dec.cabac,
        sps,
        pps,
        sh,
        dec.sao,
        rs,
        x_ctb,
        y_ctb,
        dec.ctb_left,
        dec.ctb_up,
      )
    }
    more = match dec.coding_quadtree(x_ctb, y_ctb, sps.log2_ctb_size, 0) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    rs = rs + 1
  }
  if apply_filters {
    hevc_deblock_picture(
      dec.pic,
      sps,
      pps,
      dec.deblock_tc,
      dec.deblock_beta,
      dec.qp_y_tab,
      dec.vertical_bs,
      dec.horizontal_bs,
      dec.bs_width,
    )
    hevc_sao_apply(
      dec.pic,
      sps,
      pps,
      dec.sao,
      dec.filter_slice_edges,
      dec.ctb_slice_idx,
    )
  }
  Ok(dec.pic)
}

///|
/// Decode one intra slice and apply the in-loop filters (deblocking, and SAO
/// once supported).
pub fn ff_hevc_decode_intra_frame(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
) -> Result[HevcPicture, String] {
  hevc_decode_intra_frame_impl(data, is_nalff, nal_length_size, true)
}

///|
/// Decode one intra slice without in-loop filters (pre-deblock reconstruction),
/// for bit-exact comparison against `ffmpeg -skip_loop_filter all`.
pub fn ff_hevc_decode_intra_frame_unfiltered(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
) -> Result[HevcPicture, String] {
  hevc_decode_intra_frame_impl(data, is_nalff, nal_length_size, false)
}
