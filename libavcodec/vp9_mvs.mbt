///|
/// MoonBit port of the VP9 motion-vector prediction from FFmpeg 9.0.2
/// `libavcodec/vp9mvs.c` (`find_ref_mvs`, `read_mv_component`,
/// `ff_vp9_fill_mv`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// MVs are 1/8-pel pairs kept as Int32 (the C stores int16_t).  The C packs
/// both components with `AV_RN32A` for identity comparisons; here the (x, y)
/// pair is compared directly, which is equivalent.  The `mem_sub8x8` quirk
/// and the "unclamped MV replaced by zero" bug from the C are preserved
/// verbatim (`BUG` comment in the upstream).

///|
/// Sentinel marker used in place of the C `INVALID_MV` (0x80008000).
fn vp9_mv_is_invalid(x : Int32, y : Int32) -> Bool {
  x == -32768 && y == -32768
}

///|
/// `clamp_mv`.
fn Vp9Decoder::clamp_mv(self : Vp9Decoder, x : Int32, y : Int32) -> (Int32, Int32) {
  (
    if x < self.min_mv_x {
      self.min_mv_x
    } else if x > self.max_mv_x {
      self.max_mv_x
    } else {
      x
    },
    if y < self.min_mv_y {
      self.min_mv_y
    } else if y > self.max_mv_y {
      self.max_mv_y
    } else {
      y
    },
  )
}

///|
/// `find_ref_mvs`: search the spatial/temporal neighbourhood for a predictor
/// for reference `ref` of the sub-block `z` at the current position.
/// `idx != 0` selects the second candidate (NEARMV); `sb >= 0` selects the
/// sub-8x8 direct-MV path with `sb` the quadrant encoding (1 = upper right
/// pair source, 2, 3), -1 for whole-block NEWMV.
fn Vp9Decoder::find_ref_mvs(
  self : Vp9Decoder,
  slot : Int32,
  refi : Int32,
  z : Int32,
  idx : Int32,
  sb : Int32,
) -> Unit {
  let b = self.b
  let row = self.b_row
  let col = self.b_col
  let row7 = row & 7
  let pbase = b.bs * 16
  let mut mem_x = -32768
  let mut mem_y = -32768
  let mut mem_sub_x = -32768
  let mut mem_sub_y = -32768
  // pmv slot: self.b.mvx[slot]/self.b.mvy[slot]
  let mut returned = false
  let set_result = (x : Int32, y : Int32) => {
    self.b.mvx[slot] = x
    self.b.mvy[slot] = y
    returned = true
  }
  // RETURN_DIRECT_MV
  let direct_mv = (x : Int32, y : Int32) => {
    if returned {
      return
    }
    if idx == 0 {
      set_result(x, y)
    } else if vp9_mv_is_invalid(mem_x, mem_y) {
      mem_x = x
      mem_y = y
    } else if x != mem_x || y != mem_y {
      set_result(x, y)
    }
  }
  // RETURN_MV
  let return_mv = (x : Int32, y : Int32) => {
    if returned {
      return
    }
    if sb > 0 {
      if vp9_mv_is_invalid(mem_sub_x, mem_sub_y) {
        let (cx, cy) = self.clamp_mv(x, y)
        if cx != mem_x || cy != mem_y {
          set_result(cx, cy)
          return
        }
        mem_sub_x = x
        mem_sub_y = y
      } else if mem_sub_x != x || mem_sub_y != y {
        let (cx, cy) = self.clamp_mv(x, y)
        if cx != mem_x || cy != mem_y {
          set_result(cx, cy)
        } else {
          // BUG in upstream: "I'm pretty sure this isn't the intention"
          set_result(0, 0)
        }
        return
      }
    } else if idx == 0 {
      let (cx, cy) = self.clamp_mv(x, y)
      set_result(cx, cy)
    } else if vp9_mv_is_invalid(mem_x, mem_y) {
      mem_x = x
      mem_y = y
    } else if x != mem_x || y != mem_y {
      let (cx, cy) = self.clamp_mv(x, y)
      set_result(cx, cy)
    }
  }
  // RETURN_SCALE_MV
  let return_scale_mv = (x : Int32, y : Int32, scale : Bool) => {
    if scale {
      return_mv(-x, -y)
    } else {
      return_mv(x, y)
    }
  }
  let check_pair = (
    (rx0 : Int32, ry0 : Int32, rx1 : Int32, ry1 : Int32, r0 : Int32, r1 : Int32) => {
      if returned {
        return
      }
      if r0 == refi {
        return_mv(rx0, ry0)
      } else if r1 == refi {
        return_mv(rx1, ry1)
      }
    }
  )
  let mut i = 0
  if sb >= 0 {
    if sb == 2 || sb == 1 {
      direct_mv(self.b.mvx[z * 2], self.b.mvy[z * 2])
    } else if sb == 3 {
      direct_mv(self.b.mvx[2 * 2], self.b.mvy[2 * 2])
      direct_mv(self.b.mvx[1 * 2], self.b.mvy[1 * 2])
      direct_mv(self.b.mvx[0 * 2], self.b.mvy[0 * 2])
    }
    if !returned && row > 0 {
      let pair = self.mvmap[(row - 1) * self.sb_cols * 8 + col]
      // above_mv_ctx[2 * col + (sb & 1)]
      let ac = (col * 2 + (sb & 1)) * 2
      check_pair(
        self.above_mv_x[ac],
        self.above_mv_y[ac],
        self.above_mv_x[ac + 1],
        self.above_mv_y[ac + 1],
        pair.ref0,
        pair.ref1,
      )
    }
    if !returned && col > self.tile_col_start {
      let pair = self.mvmap[row * self.sb_cols * 8 + col - 1]
      // left_mv_ctx[2 * row7 + (sb >> 1)]
      let lc = (row7 * 2 + (sb >> 1)) * 2
      check_pair(
        self.left_mv_x[lc],
        self.left_mv_y[lc],
        self.left_mv_x[lc + 1],
        self.left_mv_y[lc + 1],
        pair.ref0,
        pair.ref1,
      )
    }
    i = 2
  }
  // previously coded MVs in this neighbourhood, same reference frame
  while i < 8 && !returned {
    let cx = vp9_mv_ref_blk_off[pbase + i * 2] + col
    let ry = vp9_mv_ref_blk_off[pbase + i * 2 + 1] + row
    if cx >= self.tile_col_start && cx < self.cols && ry >= 0 && ry < self.rows {
      let pair = self.mvmap[ry * self.sb_cols * 8 + cx]
      if pair.ref0 == refi {
        return_mv(pair.x0, pair.y0)
      } else if pair.ref1 == refi {
        return_mv(pair.x1, pair.y1)
      }
    }
    i += 1
  }
  // MV at this position in the previous frame, same reference frame
  if !returned && self.use_last_frame_mvs {
    let pair = self.prev_mvmap[row * self.sb_cols * 8 + col]
    if pair.ref0 == refi {
      return_mv(pair.x0, pair.y0)
    } else if pair.ref1 == refi {
      return_mv(pair.x1, pair.y1)
    }
  }
  // previously coded MVs with a different reference frame
  for k in 0..<8 {
    if returned {
      break
    }
    let cx = vp9_mv_ref_blk_off[pbase + k * 2] + col
    let ry = vp9_mv_ref_blk_off[pbase + k * 2 + 1] + row
    if cx >= self.tile_col_start && cx < self.cols && ry >= 0 && ry < self.rows {
      let pair = self.mvmap[ry * self.sb_cols * 8 + cx]
      if pair.ref0 != refi && pair.ref0 >= 0 {
        return_scale_mv(
          pair.x0,
          pair.y0,
          self.header.ref_sign_biases[pair.ref0] != self.header.ref_sign_biases[refi],
        )
      }
      if !returned && pair.ref1 != refi && pair.ref1 >= 0 &&
        // BUG in upstream: this condition applies regardless of whether the
        // first ref MV was already used for pre-scaling
        (pair.x0 != pair.x1 || pair.y0 != pair.y1) {
        return_scale_mv(
          pair.x1,
          pair.y1,
          self.header.ref_sign_biases[pair.ref1] != self.header.ref_sign_biases[refi],
        )
      }
    }
  }
  // previous frame with a different reference frame
  if !returned && self.use_last_frame_mvs {
    let pair = self.prev_mvmap[row * self.sb_cols * 8 + col]
    if pair.ref0 != refi && pair.ref0 >= 0 {
      return_scale_mv(
        pair.x0,
        pair.y0,
        self.header.ref_sign_biases[pair.ref0] != self.header.ref_sign_biases[refi],
      )
    }
    if !returned && pair.ref1 != refi && pair.ref1 >= 0 &&
      (pair.x0 != pair.x1 || pair.y0 != pair.y1) {
      return_scale_mv(
        pair.x1,
        pair.y1,
        self.header.ref_sign_biases[pair.ref1] != self.header.ref_sign_biases[refi],
      )
    }
  }
  if !returned {
    let (cx, cy) = self.clamp_mv(0, 0)
    self.b.mvx[slot] = cx
    self.b.mvy[slot] = cy
  }
}

///|
/// `read_mv_component` (vp9mvs.c): decode one MV component in 1/8-pel units.
fn Vp9Decoder::read_mv_component(self : Vp9Decoder, idx : Int32, hp : Bool) -> Int32 {
  let c = self.rac
  let p = self.prob
  let base = VP9_PC_MV_COMP + idx * VP9_MV_COMP_SIZE
  let cb = VP9_CT_MV_COMP + idx * VP9_MV_COMP_CT_SIZE
  let sign = vp9_rac_get_prob(c, p[base])
  let class_idx = vp9_rac_get_tree_flat_ctx(c, vp9_mv_class_tree, p, base + 1)
  self.counts[cb + sign] += 1
  self.counts[cb + 2 + class_idx] += 1
  let mut n = 0
  if class_idx != 0 {
    for m in 0..<class_idx {
      let bit = vp9_rac_get_prob(c, p[base + 12 + m])
      n = n | (bit << m)
      self.counts[cb + 15 + m * 2 + bit] += 1
    }
    n = n << 3
    let bit = vp9_rac_get_tree_flat_ctx(c, vp9_mv_fp_tree, p, base + 28)
    n = n | (bit << 1)
    self.counts[cb + 43 + bit] += 1
    if hp {
      let bit2 = vp9_rac_get_prob(c, p[base + 32])
      self.counts[cb + 49 + bit2] += 1
      n = n | bit2
    } else {
      n = n | 1
      // bug in libvpx - counted even if the bit was not coded
      self.counts[cb + 50] += 1
    }
    n += 8 << class_idx
  } else {
    let bit0 = vp9_rac_get_prob(c, p[base + 11])
    self.counts[cb + 13 + bit0] += 1
    let bit = vp9_rac_get_tree_flat_ctx(c, vp9_mv_fp_tree, p, base + 22 + bit0 * 3)
    self.counts[cb + 35 + bit0 * 4 + bit] += 1
    n = (bit0 << 3) | (bit << 1)
    if hp {
      let bit2 = vp9_rac_get_prob(c, p[base + 31])
      self.counts[cb + 47 + bit2] += 1
      n = n | bit2
    } else {
      n = n | 1
      // bug in libvpx - counted even if the bit was not coded
      self.counts[cb + 48] += 1
    }
  }
  if sign != 0 {
    -(n + 1)
  } else {
    n + 1
  }
}

///|
/// `ff_vp9_fill_mv`: resolve the MV pair for sub-block index `sb_slot`
/// (into `b.mv`) given the inter mode.  `sb` follows the C: -1 for NEWMV at
/// whole-block level, else the quadrant encoding (0..3), and for BS<=8x8 the
/// caller passes -1.
fn Vp9Decoder::fill_mv(self : Vp9Decoder, out : Int32, mode : Int32, sb : Int32) -> Unit {
  if mode == 12 {
    // ZEROMV
    self.b.mvx[out * 2] = 0
    self.b.mvy[out * 2] = 0
    self.b.mvx[out * 2 + 1] = 0
    self.b.mvy[out * 2 + 1] = 0
    return
  }
  let b = self.b
  // first reference
  self.find_ref_mvs(out * 2, b.refidx[0], 0, if mode == 11 {
    1
  } else {
    0
  }, if mode == 13 {
    -1
  } else {
    sb
  })
  let mut hp = self.rac_hp_candidate(self.b.mvx[out * 2], self.b.mvy[out * 2])
  if mode == 13 || sb == -1 {
    if !hp {
      let mut y = self.b.mvy[out * 2]
      if (y & 1) != 0 {
        y += if y < 0 { 1 } else { -1 }
      }
      self.b.mvy[out * 2] = y
      let mut x = self.b.mvx[out * 2]
      if (x & 1) != 0 {
        x += if x < 0 { 1 } else { -1 }
      }
      self.b.mvx[out * 2] = x
    }
  }
  if mode == 13 {
    // NEWMV: read the residual joint/components
    let j = vp9_rac_get_tree_flat_ctx(self.rac, vp9_mv_joint_tree, self.prob, VP9_PC_MV_JOINT)
    self.counts[VP9_CT_MV_JOINT + j] += 1
    if j >= 2 {
      self.b.mvy[out * 2] += self.read_mv_component(0, hp)
    }
    if (j & 1) != 0 {
      self.b.mvx[out * 2] += self.read_mv_component(1, hp)
    }
  }
  if b.comp != 0 {
    self.find_ref_mvs(out * 2 + 1, b.refidx[1], 1, if mode == 11 {
      1
    } else {
      0
    }, if mode == 13 {
      -1
    } else {
      sb
    })
    hp = self.rac_hp_candidate(self.b.mvx[out * 2 + 1], self.b.mvy[out * 2 + 1])
    if mode == 13 || sb == -1 {
      if !hp {
        let mut y = self.b.mvy[out * 2 + 1]
        if (y & 1) != 0 {
          y += if y < 0 { 1 } else { -1 }
        }
        self.b.mvy[out * 2 + 1] = y
        let mut x = self.b.mvx[out * 2 + 1]
        if (x & 1) != 0 {
          x += if x < 0 { 1 } else { -1 }
        }
        self.b.mvx[out * 2 + 1] = x
      }
    }
    if mode == 13 {
      let j = vp9_rac_get_tree_flat_ctx(
        self.rac,
        vp9_mv_joint_tree,
        self.prob,
        VP9_PC_MV_JOINT,
      )
      self.counts[VP9_CT_MV_JOINT + j] += 1
      if j >= 2 {
        self.b.mvy[out * 2 + 1] += self.read_mv_component(0, hp)
      }
      if (j & 1) != 0 {
        self.b.mvx[out * 2 + 1] += self.read_mv_component(1, hp)
      }
    }
  }
}

///|
/// C: `s->s.h.highprecisionmvs && abs(mv.x) < 64 && abs(mv.y) < 64` — the hp
/// flag used when decoding NEWMV residuals / rounding predictors.
fn Vp9Decoder::rac_hp_candidate(self : Vp9Decoder, x : Int32, y : Int32) -> Bool {
  self.header.high_precision_mvs && x.abs() < 64 && y.abs() < 64
}
