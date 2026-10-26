///|
/// `mode_conv[mode][have_left][have_top]` from `check_intra_mode`. */
fn vp9_mode_conv(mode : Int32, have_left : Bool, have_top : Int32) -> Int32 {
  let t = have_top != 0
  match mode {
    0 => if t { 0 } else { 13 } // VERT_PRED -> DC_127 without top
    1 => if have_left { 1 } else { 14 } // HOR_PRED -> DC_129 without left
    2 =>
      // DC_PRED
      if have_left {
        if t {
          2
        } else {
          10
        }
      } else if t {
        11
      } else {
        12
      }
    3 => if t { 3 } else { 13 } // DIAG_DOWN_LEFT -> DC_127 without top
    4 => 4
    5 => 5
    6 => 6
    7 => if t { 7 } else { 13 } // VERT_LEFT -> DC_127 without top
    8 => if have_left { 8 } else { 14 } // HOR_UP -> DC_129 without left
    _ =>
      // TM_VP8_PRED
      if have_left {
        if t {
          9
        } else {
          1
        }
      } else if t {
        0
      } else {
        14
      }
  }
}

///|
/// `edges[]` needs flags: { left, top, topleft, topright, invert_left }. */
fn vp9_edges_needs(mode : Int32) -> (Bool, Bool, Bool, Bool, Bool) {
  // needs_left, needs_top, needs_topleft, needs_topright, invert_left
  match mode {
    0 => (false, true, false, false, false)
    1 => (true, false, false, false, false)
    2 => (true, true, false, false, false)
    3 => (false, true, false, true, false)
    4 => (true, true, true, false, false)
    5 => (true, true, true, false, false)
    6 => (true, true, true, false, false)
    7 => (false, true, false, true, false)
    8 => (true, false, false, false, true)
    9 => (true, true, true, false, false) // TM_VP8_PRED
    10 => (true, false, false, false, false) // LEFT_DC_PRED
    11 => (false, true, false, false, false) // TOP_DC_PRED
    _ => (false, false, false, false, false) // DC_128/127/129
  }
}

///|
/// `check_intra_mode`: prepare the `top` (65 entries, index 0 = above-left)
/// and `left` (64 entries, bottom-most first) edge buffers and return the
/// converted prediction mode. */
fn Vp9Decoder::check_intra_mode(
  self : Vp9Decoder,
  mode0 : Int32,
  top : FixedArray[Int32],
  left : FixedArray[Int32],
  plane : FixedArray[Int32],
  tu_off : Int32,
  stride : Int32,
  col : Int32,
  row : Int32,
  x : Int32,
  y : Int32,
  w4 : Int32,
  tx : Int32,
  p : Int32,
  ss_h : Int32,
  ss_v : Int32,
) -> Int32 {
  let have_top = row > 0 || y > 0
  let have_left = col > self.tile_col_start || x > 0
  let have_right = x < w4 - 1
  let mode = vp9_mode_conv(mode0, have_left, if have_top { 1 } else { 0 })
  let (needs_left, needs_top, needs_topleft, needs_topright, invert_left) = vp9_edges_needs(
    mode,
  )
  if needs_top {
    let n_px_need = 4 << tx
    let n_px_have = (((self.cols - col) << (1 - ss_h)) - x) * 4
    let n_px_need_tr = if tx == 0 && needs_topright && have_right {
      4
    } else {
      0
    }
    // top source: the above-SB-row backup for the first TU row of a SB row,
    // otherwise the plane row above the current TU
    let use_backup = have_top && (row & 7) == 0 && y == 0
    let backup_idx = col * (8 >> ss_h) + x * 4 - 1
    let src_off = tu_off - stride
    let top_src_off = if use_backup { 0 } else { src_off }
    if have_top &&
      (!needs_topleft || have_left) &&
      (tx != 0 || !needs_topright || have_right) &&
      n_px_need + n_px_need_tr <= n_px_have {
      // fast path: enough contiguous pixels — copy them verbatim
      let base = if use_backup { backup_idx + 1 } else { top_src_off }
      for i in 0..<(n_px_need + n_px_need_tr) {
        top[1 + i] = if use_backup {
          self.intra_pred[p][base + i]
        } else {
          plane[base + i]
        }
      }
      if needs_topleft {
        top[0] = if use_backup {
          self.intra_pred[p][backup_idx]
        } else {
          plane[src_off - 1]
        }
      }
    } else {
      if have_top {
        if n_px_need <= n_px_have {
          for i in 0..<n_px_need {
            top[1 + i] = if use_backup {
              self.intra_pred[p][backup_idx + 1 + i]
            } else {
              plane[top_src_off + i]
            }
          }
        } else {
          for i in 0..<n_px_have {
            top[1 + i] = if use_backup {
              self.intra_pred[p][backup_idx + 1 + i]
            } else {
              plane[top_src_off + i]
            }
          }
          let last = top[n_px_have]
          for i in n_px_have..<n_px_need {
            top[1 + i] = last
          }
        }
      } else {
        for i in 0..<n_px_need {
          top[1 + i] = self.pixel_mid - 1
        }
      }
      if needs_topleft {
        if have_left && have_top {
          top[0] = if use_backup {
            self.intra_pred[p][backup_idx]
          } else {
            plane[src_off - 1]
          }
        } else if have_top {
          top[0] = self.pixel_mid + 1
        } else {
          top[0] = self.pixel_mid - 1
        }
      }
      if tx == 0 && needs_topright {
        if have_top && have_right && n_px_need + n_px_need_tr <= n_px_have {
          for i in 0..<4 {
            top[1 + 4 + i] = if use_backup {
              self.intra_pred[p][backup_idx + 1 + 4 + i]
            } else {
              plane[top_src_off + 4 + i]
            }
          }
        } else {
          let v = top[4]
          for i in 4..<8 {
            top[1 + i] = v
          }
        }
      }
    }
  }
  if needs_left {
    if have_left {
      let n_px_need = 4 << tx
      let n_px_have = (((self.rows - row) << (1 - ss_v)) - y) * 4
      // the left column always comes from the plane: the current SB row has
      // not been loop-filtered yet (the backup only substitutes the top row)
      if invert_left {
        if n_px_need <= n_px_have {
          for i in 0..<n_px_need {
            left[i] = plane[tu_off + i * stride - 1]
          }
        } else {
          for i in 0..<n_px_have {
            left[i] = plane[tu_off + i * stride - 1]
          }
          let last = left[n_px_have - 1]
          for i in n_px_have..<n_px_need {
            left[i] = last
          }
        }
      } else if n_px_need <= n_px_have {
        for i in 0..<n_px_need {
          left[n_px_need - 1 - i] = plane[tu_off + i * stride - 1]
        }
      } else {
        for i in 0..<n_px_have {
          left[n_px_need - 1 - i] = plane[tu_off + i * stride - 1]
        }
        let last = left[n_px_need - n_px_have]
        for i in 0..<(n_px_need - n_px_have) {
          left[i] = last
        }
      }
    } else {
      for i in 0..<(4 << tx) {
        left[i] = self.pixel_mid + 1
      }
    }
  }
  mode
}

///|
/// `intra_recon` (8 bpp): predict + inverse-transform every TU of the block. */
fn Vp9Decoder::intra_recon(
  self : Vp9Decoder,
  y_off : Int32,
  uv_off : Int32,
) -> Unit {
  let b = self.b
  let row = self.b_row
  let col = self.b_col
  let w4 = vp9_bwh8_at(b.bs)[0] << 1
  let h4 = vp9_bwh8_at(b.bs)[1] << 1
  let step1d = 1 << b.tx
  let mut step = 1 << (b.tx * 2)
  let end_x = vp9_min(2 * (self.cols - col), w4)
  let end_y = vp9_min(2 * (self.rows - row), h4)
  let tx_kind = 4 * self.lossless() + b.tx
  let uvtx_kind = 4 * self.lossless() + b.uvtx
  let uvstep1d = 1 << b.uvtx
  let top : FixedArray[Int32] = FixedArray::make(73, 0)
  let left : FixedArray[Int32] = FixedArray::make(64, 0)
  // luma
  let mut n = 0
  let mut y = 0
  while y < end_y {
    let mut x = 0
    while x < end_x {
      let mode_idx = if b.bs > VP9_BS_8x8 && b.tx == 0 { y * 2 + x } else { 0 }
      let tu_off = y_off + x * 4 + y * 4 * self.ystride
      let eob = if b.skip != 0 { 0 } else { self.eob[n] }
      let mode = self.check_intra_mode(
        b.mode[mode_idx],
        top,
        left,
        self.y,
        tu_off,
        self.ystride,
        col,
        row,
        x,
        y,
        w4,
        b.tx,
        0,
        0,
        0,
      )
      vp9_intra_pred(
        b.tx,
        mode,
        self.y,
        tu_off,
        self.ystride,
        left,
        top,
        self.pixel_mid,
        self.pixel_max,
      )
      if eob != 0 {
        vp9_itxfm_add(
          tx_kind,
          vp9_intra_txfm_type[b.mode[mode_idx]],
          self.y,
          tu_off,
          self.ystride,
          self.block,
          16 * n,
          eob,
          self.bpp,
          self.pixel_max,
        )
      }
      n += step
      x += step1d
    }
    y += step1d
  }
  // chroma
  let w4c = w4 >> self.ss_h
  let end_xc = end_x >> self.ss_h
  let end_yc = end_y >> self.ss_v
  step = 1 << (b.uvtx * 2)
  for pl in 0..<2 {
    let plane = if pl == 0 { self.cb } else { self.cr }
    let mut n = 0
    let mut y = 0
    while y < end_yc {
      let mut x = 0
      while x < end_xc {
        let tu_off = uv_off + x * 4 + y * 4 * self.uvstride
        let eob = if b.skip != 0 {
          0
        } else if pl == 0 {
          self.uveob0[n]
        } else {
          self.uveob1[n]
        }
        let mode = self.check_intra_mode(
          b.uvmode,
          top,
          left,
          plane,
          tu_off,
          self.uvstride,
          col,
          row,
          x,
          y,
          w4c,
          b.uvtx,
          pl + 1,
          self.ss_h,
          self.ss_v,
        )
        vp9_intra_pred(
          b.uvtx,
          mode,
          plane,
          tu_off,
          self.uvstride,
          left,
          top,
          self.pixel_mid,
          self.pixel_max,
        )
        if eob != 0 {
          let ublock = if pl == 0 { self.uvblock0 } else { self.uvblock1 }
          vp9_itxfm_add(
            uvtx_kind,
            0,
            plane,
            tu_off,
            self.uvstride,
            ublock,
            16 * n,
            eob,
            self.bpp,
            self.pixel_max,
          )
        }
        n += step
        x += uvstep1d
      }
      y += uvstep1d
    }
  }
}
