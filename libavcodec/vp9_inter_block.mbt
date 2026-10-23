///|
/// MoonBit port of the VP9 block mode syntax from FFmpeg 9.0.2
/// `libavcodec/vp9block.c` (`decode_mode` including the inter branches and
/// `SET_CTXS`, the per-block MV-reference bookkeeping).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Mode value conventions follow the C enums: intra modes 0..9 (+ converted
/// 10..14 in the intra path), inter modes NEARESTMV=10, NEARMV=11, ZEROMV=12,
/// NEWMV=13.

///|
/// `size_group[10]` from `decode_mode` (non-keyframe intra mode contexts).
fn vp9_size_group(bs : Int32) -> Int32 {
  match bs {
    0 | 1 | 2 | 3 => 3
    4 | 5 | 6 => 2
    _ => 1
  }
}

///|
/// `off[10]` from `decode_mode` (neighbour mode slot offsets for BS_8x8).
fn vp9_mode_off_tab(bs : Int32) -> Int32 {
  match bs {
    0 => 3
    3 => 1
    _ => 0
  }
}

///|
/// `decode_mode`: full C port covering keyframe, intra-only, intra-in-inter
/// and inter branches.
fn Vp9Decoder::decode_mode(self : Vp9Decoder) -> Unit {
  let b = self.b
  let h = self.header
  let row = self.b_row
  let col = self.b_col
  let row7 = row & 7
  let max_tx = match b.bs {
    bs if bs <= 3 => 3
    bs if bs <= 6 => 2
    bs if bs <= 9 => 1
    _ => 0
  }
  let bwh8 = vp9_bwh8_at(b.bs)
  let bw4 = bwh8[0]
  let bh4 = bwh8[1]
  let have_a = row > 0
  let have_l = col > self.tile_col_start
  let left_ctx_tbl : Array[Int32] = [
    0x0, 0x8, 0x0, 0x8, 0xc, 0x8, 0xc, 0xe, 0xc, 0xe, 0xf, 0xe, 0xf,
  ]
  let above_ctx_tbl : Array[Int32] = [
    0x0, 0x0, 0x8, 0x8, 0x8, 0xc, 0xc, 0xc, 0xe, 0xe, 0xe, 0xf, 0xf,
  ]
  // segmentation (with temporal prediction for inter frames)
  if !h.segmentation.enabled {
    b.seg_id = 0
  } else if h.keyframe || h.intra_only {
    b.seg_id = if !h.segmentation.update_map {
      0
    } else {
      vp9_rac_get_tree_flat(
        self.rac,
        vp9_segmentation_tree,
        h.segmentation.tree_probs,
        0,
      )
    }
  } else if !h.segmentation.update_map ||
    (h.segmentation.temporal &&
    vp9_rac_get_prob(
      self.rac,
      h.segmentation.pred_probs[self.above_segpred[col] + self.left_segpred[row7]],
    ) != 0) {
    if !h.error_resilient && self.ref_segmap is Some(refsegmap) {
      let mut pred = 8
      let stride = self.sb_cols * 8
      for y in 0..<bh4 {
        let idx_base = (y + row) * stride + col
        for x in 0..<bw4 {
          if refsegmap[idx_base + x] < pred {
            pred = refsegmap[idx_base + x]
          }
        }
      }
      b.seg_id = pred
    } else {
      b.seg_id = 0
    }
    for i in 0..<bw4 {
      self.above_segpred[col + i] = 1
    }
    for i in 0..<bh4 {
      self.left_segpred[row7 + i] = 1
    }
  } else {
    b.seg_id = vp9_rac_get_tree_flat(
      self.rac,
      vp9_segmentation_tree,
      h.segmentation.tree_probs,
      0,
    )
    for i in 0..<bw4 {
      self.above_segpred[col + i] = 0
    }
    for i in 0..<bh4 {
      self.left_segpred[row7 + i] = 0
    }
  }
  if h.segmentation.enabled &&
    (h.segmentation.update_map || h.keyframe || h.intra_only) {
    self.set_seg_map(row, col, bw4, bh4, b.seg_id)
  }
  b.skip = if h.segmentation.enabled &&
    h.segmentation.features[b.seg_id].skip_enabled {
    1
  } else {
    0
  }
  if b.skip == 0 {
    let cidx = self.left_skip[row7] + self.above_skip[col]
    b.skip = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_SKIP + cidx])
    self.counts[VP9_CT_SKIP + cidx * 2 + b.skip] += 1
  }
  // intra/inter flag
  if h.keyframe || h.intra_only {
    b.intra = 1
  } else if h.segmentation.enabled &&
    h.segmentation.features[b.seg_id].ref_enabled {
    b.intra = if h.segmentation.features[b.seg_id].ref_value != 0 {
      0
    } else {
      1
    }
  } else {
    let cidx = if have_a && have_l {
      let c0 = self.above_intra[col] + self.left_intra[row7]
      if c0 == 2 {
        c0 + 1
      } else {
        c0
      }
    } else if have_a {
      2 * self.above_intra[col]
    } else if have_l {
      2 * self.left_intra[row7]
    } else {
      0
    }
    let bit = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_INTRA + cidx])
    self.counts[VP9_CT_INTRA + cidx * 2 + bit] += 1
    b.intra = if bit != 0 {
      0
    } else {
      1
    }
  }
  // tx size (same as the keyframe path)
  if (b.intra != 0 || b.skip == 0) && self.tx_mode == VP9_TX_SWITCHABLE {
    let mut cidx = 0
    if have_a {
      if have_l {
        let av = if self.above_skip[col] != 0 {
          max_tx
        } else {
          self.above_txfm[col]
        }
        let lv = if self.left_skip[row7] != 0 {
          max_tx
        } else {
          self.left_txfm[row7]
        }
        cidx = if av + lv > max_tx {
          1
        } else {
          0
        }
      } else {
        cidx = if self.above_skip[col] != 0 {
          1
        } else if self.above_txfm[col] * 2 > max_tx {
          1
        } else {
          0
        }
      }
    } else if have_l {
      cidx = if self.left_skip[row7] != 0 {
        1
      } else if self.left_txfm[row7] * 2 > max_tx {
        1
      } else {
        0
      }
    } else {
      cidx = 1
    }
    match max_tx {
      3 => {
        b.tx = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX32P + cidx * 3])
        if b.tx != 0 {
          b.tx += vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX32P + cidx * 3 + 1])
          if b.tx == 2 {
            b.tx += vp9_rac_get_prob(
              self.rac,
              self.prob[VP9_PC_TX32P + cidx * 3 + 2],
            )
          }
        }
        self.counts[VP9_CT_TX32P + cidx * 4 + b.tx] += 1
      }
      2 => {
        b.tx = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX16P + cidx * 2])
        if b.tx != 0 {
          b.tx += vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX16P + cidx * 2 + 1])
        }
        self.counts[VP9_CT_TX16P + cidx * 3 + b.tx] += 1
      }
      1 => {
        b.tx = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_TX8P + cidx])
        self.counts[VP9_CT_TX8P + cidx * 2 + b.tx] += 1
      }
      _ => b.tx = 0
    }
  } else {
    b.tx = vp9_min(max_tx, self.tx_mode)
  }
  // block modes
  if h.keyframe || h.intra_only {
    self.decode_mode_kf_modes()
  } else if b.intra != 0 {
    b.comp = 0
    if b.bs > 9 {
      b.mode[0] = vp9_rac_get_tree_flat_ctx(
        self.rac,
        vp9_intramode_tree,
        self.prob,
        VP9_PC_Y_MODE,
      )
      self.counts[VP9_CT_Y_MODE + b.mode[0]] += 1
      if b.bs != 10 {
        b.mode[1] = vp9_rac_get_tree_flat_ctx(
          self.rac,
          vp9_intramode_tree,
          self.prob,
          VP9_PC_Y_MODE,
        )
        self.counts[VP9_CT_Y_MODE + b.mode[1]] += 1
      } else {
        b.mode[1] = b.mode[0]
      }
      if b.bs != 11 {
        b.mode[2] = vp9_rac_get_tree_flat_ctx(
          self.rac,
          vp9_intramode_tree,
          self.prob,
          VP9_PC_Y_MODE,
        )
        self.counts[VP9_CT_Y_MODE + b.mode[2]] += 1
        if b.bs != 10 {
          b.mode[3] = vp9_rac_get_tree_flat_ctx(
            self.rac,
            vp9_intramode_tree,
            self.prob,
            VP9_PC_Y_MODE,
          )
          self.counts[VP9_CT_Y_MODE + b.mode[3]] += 1
        } else {
          b.mode[3] = b.mode[2]
        }
      } else {
        b.mode[2] = b.mode[0]
        b.mode[3] = b.mode[1]
      }
    } else {
      let sz = vp9_size_group(b.bs)
      b.mode[0] = vp9_rac_get_tree_flat_ctx(
        self.rac,
        vp9_intramode_tree,
        self.prob,
        VP9_PC_Y_MODE + sz * 9,
      )
      b.mode[1] = b.mode[0]
      b.mode[2] = b.mode[0]
      b.mode[3] = b.mode[0]
      self.counts[VP9_CT_Y_MODE + sz * 10 + b.mode[3]] += 1
    }
    b.uvmode = vp9_rac_get_tree_flat_ctx(
      self.rac,
      vp9_intramode_tree,
      self.prob,
      VP9_PC_UV_MODE + b.mode[3] * 9,
    )
    self.counts[VP9_CT_UV_MODE + b.mode[3] * 10 + b.uvmode] += 1
  } else {
    self.decode_mode_inter(have_a, have_l)
  }
  // vref: the reference used for the above/left ref context
  let vref = if b.intra == 0 {
    if b.comp != 0 {
      b.refidx[if h.ref_sign_biases[h.var_comp_refs[0]] {
        1
      } else {
        0
      }]
    } else {
      b.refidx[0]
    }
  } else {
    0
  }
  // SET_CTXS
  let left_ctx_v = left_ctx_tbl[b.bs]
  let above_ctx_v = above_ctx_tbl[b.bs]
  let is_kf = h.keyframe || h.intra_only
  for i in 0..<bw4 {
    self.above_skip[col + i] = b.skip
    self.above_txfm[col + i] = b.tx
    self.above_partition[col + i] = above_ctx_v
    if !is_kf {
      self.above_intra[col + i] = b.intra
      self.above_comp[col + i] = b.comp
      self.above_mode[col + i] = b.mode[3]
      if b.intra == 0 {
        self.above_ref[col + i] = vref
        if h.filter_mode == 4 {
          self.above_filter[col + i] = b.filter
        }
      }
    }
  }
  for i in 0..<bh4 {
    self.left_skip[row7 + i] = b.skip
    self.left_txfm[row7 + i] = b.tx
    self.left_partition[row7 + i] = left_ctx_v
    if !is_kf {
      self.left_intra[row7 + i] = b.intra
      self.left_comp[row7 + i] = b.comp
      self.left_mode[row7 + i] = b.mode[3]
      if b.intra == 0 {
        self.left_ref[row7 + i] = vref
        if h.filter_mode == 4 {
          self.left_filter[row7 + i] = b.filter
        }
      }
    }
  }
  // MV context propagation
  if !is_kf {
    if b.bs > 9 {
      // sub-8x8: left_mv_ctx[row7*2+0]=mv[1], left[row7*2+1]=mv[3],
      // above_mv_ctx[col*2+0]=mv[2], above[col*2+1]=mv[3]
      self.left_mv_x[row7 * 4] = b.mvx[2]
      self.left_mv_y[row7 * 4] = b.mvy[2]
      self.left_mv_x[row7 * 4 + 1] = b.mvx[3]
      self.left_mv_y[row7 * 4 + 1] = b.mvy[3]
      self.left_mv_x[row7 * 4 + 2] = b.mvx[6]
      self.left_mv_y[row7 * 4 + 2] = b.mvy[6]
      self.left_mv_x[row7 * 4 + 3] = b.mvx[7]
      self.left_mv_y[row7 * 4 + 3] = b.mvy[7]
      self.above_mv_x[col * 4] = b.mvx[4]
      self.above_mv_y[col * 4] = b.mvy[4]
      self.above_mv_x[col * 4 + 1] = b.mvx[5]
      self.above_mv_y[col * 4 + 1] = b.mvy[5]
      self.above_mv_x[col * 4 + 2] = b.mvx[6]
      self.above_mv_y[col * 4 + 2] = b.mvy[6]
      self.above_mv_x[col * 4 + 3] = b.mvx[7]
      self.above_mv_y[col * 4 + 3] = b.mvy[7]
    } else {
      let mv0x = b.mvx[6]
      let mv0y = b.mvy[6]
      let mv1x = b.mvx[7]
      let mv1y = b.mvy[7]
      for n in 0..<(bw4 * 2) {
        self.above_mv_x[(col * 2 + n) * 2] = mv0x
        self.above_mv_y[(col * 2 + n) * 2] = mv0y
        self.above_mv_x[(col * 2 + n) * 2 + 1] = mv1x
        self.above_mv_y[(col * 2 + n) * 2 + 1] = mv1y
      }
      for n in 0..<(bh4 * 2) {
        self.left_mv_x[(row7 * 2 + n) * 2] = mv0x
        self.left_mv_y[(row7 * 2 + n) * 2] = mv0y
        self.left_mv_x[(row7 * 2 + n) * 2 + 1] = mv1x
        self.left_mv_y[(row7 * 2 + n) * 2 + 1] = mv1y
      }
    }
    // per-8x8 mvref map
    let stride = self.sb_cols * 8
    for y in 0..<bh4 {
      let base = (row + y) * stride + col
      if b.intra != 0 {
        for x in 0..<bw4 {
          let pair = self.mvmap[base + x]
          pair.ref0 = -1
          pair.ref1 = -1
        }
      } else if b.comp != 0 {
        for x in 0..<bw4 {
          let pair = self.mvmap[base + x]
          pair.ref0 = b.refidx[0]
          pair.ref1 = b.refidx[1]
          pair.x0 = b.mvx[6]
          pair.y0 = b.mvy[6]
          pair.x1 = b.mvx[7]
          pair.y1 = b.mvy[7]
        }
      } else {
        for x in 0..<bw4 {
          let pair = self.mvmap[base + x]
          pair.ref0 = b.refidx[0]
          pair.ref1 = -1
          pair.x0 = b.mvx[6]
          pair.y0 = b.mvy[6]
        }
      }
    }
  }
}

///|
/// Keyframe / intra-only mode syntax (`decode_mode` first branch).
fn Vp9Decoder::decode_mode_kf_modes(self : Vp9Decoder) -> Unit {
  let b = self.b
  b.comp = 0
  let amode = self.above_mode
  let lmode = self.left_mode
  let a0 = self.b_col * 2
  let l0 = (self.b_row & 7) * 2
  if b.bs > 9 {
    b.mode[0] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0], lmode[l0])
    amode[a0] = b.mode[0]
    if b.bs != 10 {
      b.mode[1] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0 + 1], b.mode[0])
      lmode[l0] = b.mode[1]
      amode[a0 + 1] = b.mode[1]
    } else {
      lmode[l0] = b.mode[0]
      amode[a0 + 1] = b.mode[0]
      b.mode[1] = b.mode[0]
    }
    if b.bs != 11 {
      b.mode[2] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0], lmode[l0 + 1])
      amode[a0] = b.mode[2]
      if b.bs != 10 {
        b.mode[3] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0 + 1], b.mode[2])
        lmode[l0 + 1] = b.mode[3]
        amode[a0 + 1] = b.mode[3]
      } else {
        lmode[l0 + 1] = b.mode[2]
        amode[a0 + 1] = b.mode[2]
        b.mode[3] = b.mode[2]
      }
    } else {
      b.mode[2] = b.mode[0]
      lmode[l0 + 1] = b.mode[1]
      amode[a0 + 1] = b.mode[1]
      b.mode[3] = b.mode[1]
    }
  } else {
    b.mode[0] = vp9_rac_get_tree_kf_ymode(self.rac, amode[a0], lmode[l0])
    b.mode[1] = b.mode[0]
    b.mode[2] = b.mode[0]
    b.mode[3] = b.mode[0]
    let aw = vp9_bwh4_at(b.bs)[0]
    let lh = vp9_bwh4_at(b.bs)[1]
    for i in 0..<aw {
      amode[a0 + i] = b.mode[0]
    }
    for i in 0..<lh {
      lmode[l0 + i] = b.mode[0]
    }
  }
  b.uvmode = vp9_rac_get_tree_flat(
    self.rac,
    vp9_intramode_tree,
    vp9_kf_uvmode_probs,
    b.mode[3] * 9,
  )
}

///|
/// The inter branch of `decode_mode`: comp flag, references, mode, filter
/// and motion vectors.
fn Vp9Decoder::decode_mode_inter(self : Vp9Decoder, have_a : Bool, have_l : Bool) -> Unit {
  let b = self.b
  let h = self.header
  let row7 = self.b_row & 7
  let col = self.b_col
  // reference feature forces a single reference
  if h.segmentation.enabled && h.segmentation.features[b.seg_id].ref_enabled {
    b.comp = 0
    b.refidx[0] = h.segmentation.features[b.seg_id].ref_value - 1
    b.refidx[1] = 0
  } else {
    // comp_pred flag
    if h.comp_pred_mode != 2 {
      b.comp = if h.comp_pred_mode == 1 {
        1
      } else {
        0
      }
    } else {
      let cidx = if have_a {
        if have_l {
          if self.above_comp[col] != 0 && self.left_comp[row7] != 0 {
            4
          } else if self.above_comp[col] != 0 {
            2 +
            (if self.left_intra[row7] != 0 || self.left_ref[row7] == h.fix_comp_ref {
              1
            } else {
              0
            })
          } else if self.left_comp[row7] != 0 {
            2 +
            (if self.above_intra[col] != 0 || self.above_ref[col] == h.fix_comp_ref {
              1
            } else {
              0
            })
          } else {
            (if self.above_intra[col] == 0 &&
              self.above_ref[col] == h.fix_comp_ref {
              1
            } else {
              0
            }) ^
            (if self.left_intra[row7] == 0 &&
              self.left_ref[row7] == h.fix_comp_ref {
              1
            } else {
              0
            })
          }
        } else if self.above_comp[col] != 0 {
          3
        } else if self.above_intra[col] == 0 && self.above_ref[col] == h.fix_comp_ref {
          1
        } else {
          0
        }
      } else if have_l {
        if self.left_comp[row7] != 0 {
          3
        } else if self.left_intra[row7] == 0 && self.left_ref[row7] == h.fix_comp_ref {
          1
        } else {
          0
        }
      } else {
        1
      }
      b.comp = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_COMP + cidx])
      self.counts[VP9_CT_COMP + cidx * 2 + b.comp] += 1
    }
    // references
    if b.comp != 0 {
      // two references
      let fix_idx = if h.ref_sign_biases[h.fix_comp_ref] {
        1
      } else {
        0
      }
      let var_idx = 1 - fix_idx
      b.refidx[fix_idx] = h.fix_comp_ref
      let cidx = if have_a {
        if have_l {
          if self.above_intra[col] != 0 {
            if self.left_intra[row7] != 0 {
              2
            } else {
              1 +
              2 *
              (if self.left_ref[row7] != h.var_comp_refs[1] {
                1
              } else {
                0
              })
            }
          } else if self.left_intra[row7] != 0 {
            1 +
            2 *
            (if self.above_ref[col] != h.var_comp_refs[1] {
              1
            } else {
              0
            })
          } else {
            let refl = self.left_ref[row7]
            let refa = self.above_ref[col]
            if refl == refa && refa == h.var_comp_refs[1] {
              0
            } else if self.left_comp[row7] == 0 && self.above_comp[col] == 0 {
              if (refa == h.fix_comp_ref && refl == h.var_comp_refs[0]) ||
                (refl == h.fix_comp_ref && refa == h.var_comp_refs[0]) {
                4
              } else if refa == refl {
                3
              } else {
                1
              }
            } else if self.left_comp[row7] == 0 {
              if refa == h.var_comp_refs[1] && refl != h.var_comp_refs[1] {
                1
              } else if refl == h.var_comp_refs[1] && refa != h.var_comp_refs[1] {
                2
              } else {
                4
              }
            } else if self.above_comp[col] == 0 {
              if refl == h.var_comp_refs[1] && refa != h.var_comp_refs[1] {
                1
              } else if refa == h.var_comp_refs[1] && refl != h.var_comp_refs[1] {
                2
              } else {
                4
              }
            } else if refl == refa {
              4
            } else {
              2
            }
          }
        } else if self.above_intra[col] != 0 {
          2
        } else if self.above_comp[col] != 0 {
          4 * (if self.above_ref[col] != h.var_comp_refs[1] {
            1
          } else {
            0
          })
        } else {
          3 * (if self.above_ref[col] != h.var_comp_refs[1] {
            1
          } else {
            0
          })
        }
      } else if have_l {
        if self.left_intra[row7] != 0 {
          2
        } else if self.left_comp[row7] != 0 {
          4 * (if self.left_ref[row7] != h.var_comp_refs[1] {
            1
          } else {
            0
          })
        } else {
          3 * (if self.left_ref[row7] != h.var_comp_refs[1] {
            1
          } else {
            0
          })
        }
      } else {
        2
      }
      let bit = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_COMP_REF + cidx])
      b.refidx[var_idx] = h.var_comp_refs[bit]
      self.counts[VP9_CT_COMP_REF + cidx * 2 + bit] += 1
    } else {
      // single reference
      let cidx = if have_a && self.above_intra[col] == 0 {
        if have_l && self.left_intra[row7] == 0 {
          if self.left_comp[row7] != 0 {
            if self.above_comp[col] != 0 {
              1 +
              (if h.fix_comp_ref == 0 || self.left_ref[row7] == 0 ||
                self.above_ref[col] == 0 {
                1
              } else {
                0
              })
            } else {
              3 * (if self.above_ref[col] == 0 {
                1
              } else {
                0
              }) +
              (if h.fix_comp_ref == 0 || self.left_ref[row7] == 0 {
                1
              } else {
                0
              })
            }
          } else if self.above_comp[col] != 0 {
            3 * (if self.left_ref[row7] == 0 {
              1
            } else {
              0
            }) +
            (if h.fix_comp_ref == 0 || self.above_ref[col] == 0 {
              1
            } else {
              0
            })
          } else {
            2 * (if self.left_ref[row7] == 0 {
              1
            } else {
              0
            }) +
            2 *
            (if self.above_ref[col] == 0 {
              1
            } else {
              0
            })
          }
        } else if self.above_intra[col] != 0 {
          2
        } else if self.above_comp[col] != 0 {
          1 +
          (if h.fix_comp_ref == 0 || self.above_ref[col] == 0 {
            1
          } else {
            0
          })
        } else {
          4 * (if self.above_ref[col] == 0 {
            1
          } else {
            0
          })
        }
      } else if have_l && self.left_intra[row7] == 0 {
        if self.left_comp[row7] != 0 {
          1 +
          (if h.fix_comp_ref == 0 || self.left_ref[row7] == 0 {
            1
          } else {
            0
          })
        } else {
          4 * (if self.left_ref[row7] == 0 {
            1
          } else {
            0
          })
        }
      } else {
        2
      }
      let bit = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_SINGLE_REF + cidx * 2])
      self.counts[VP9_CT_SINGLE_REF + cidx * 4 + bit] += 1
      if bit == 0 {
        b.refidx[0] = 0
      } else {
        let cidx2 = if have_a {
          if have_l {
            if self.left_intra[row7] != 0 {
              if self.above_intra[col] != 0 {
                2
              } else if self.above_comp[col] != 0 {
                1 +
                2 *
                (if h.fix_comp_ref == 1 || self.above_ref[col] == 1 {
                  1
                } else {
                  0
                })
              } else if self.above_ref[col] == 0 {
                3
              } else {
                4 * (if self.above_ref[col] == 1 {
                  1
                } else {
                  0
                })
              }
            } else if self.above_intra[col] != 0 {
              if self.left_intra[row7] != 0 {
                2
              } else if self.left_comp[row7] != 0 {
                1 +
                2 *
                (if h.fix_comp_ref == 1 || self.left_ref[row7] == 1 {
                  1
                } else {
                  0
                })
              } else if self.left_ref[row7] == 0 {
                3
              } else {
                4 * (if self.left_ref[row7] == 1 {
                  1
                } else {
                  0
                })
              }
            } else if self.above_comp[col] != 0 {
              if self.left_comp[row7] != 0 {
                if self.left_ref[row7] == self.above_ref[col] {
                  3 *
                  (if h.fix_comp_ref == 1 || self.left_ref[row7] == 1 {
                    1
                  } else {
                    0
                  })
                } else {
                  2
                }
              } else if self.left_ref[row7] == 0 {
                1 +
                2 *
                (if h.fix_comp_ref == 1 || self.above_ref[col] == 1 {
                  1
                } else {
                  0
                })
              } else {
                3 *
                (if self.left_ref[row7] == 1 {
                  1
                } else {
                  0
                }) +
                (if h.fix_comp_ref == 1 || self.above_ref[col] == 1 {
                  1
                } else {
                  0
                })
              }
            } else if self.left_comp[row7] != 0 {
              if self.above_ref[col] == 0 {
                1 +
                2 *
                (if h.fix_comp_ref == 1 || self.left_ref[row7] == 1 {
                  1
                } else {
                  0
                })
              } else {
                3 *
                (if self.above_ref[col] == 1 {
                  1
                } else {
                  0
                }) +
                (if h.fix_comp_ref == 1 || self.left_ref[row7] == 1 {
                  1
                } else {
                  0
                })
              }
            } else if self.above_ref[col] == 0 {
              if self.left_ref[row7] == 0 {
                3
              } else {
                4 * (if self.left_ref[row7] == 1 {
                  1
                } else {
                  0
                })
              }
            } else if self.left_ref[row7] == 0 {
              4 * (if self.above_ref[col] == 1 {
                1
              } else {
                0
              })
            } else {
              2 *
              (if self.left_ref[row7] == 1 {
                1
              } else {
                0
              }) +
              2 *
              (if self.above_ref[col] == 1 {
                1
              } else {
                0
              })
            }
          } else if self.above_intra[col] != 0 ||
            (self.above_comp[col] == 0 && self.above_ref[col] == 0) {
            2
          } else if self.above_comp[col] != 0 {
            3 * (if h.fix_comp_ref == 1 || self.above_ref[col] == 1 {
              1
            } else {
              0
            })
          } else {
            4 * (if self.above_ref[col] == 1 {
              1
            } else {
              0
            })
          }
        } else if have_l {
          if self.left_intra[row7] != 0 ||
            (self.left_comp[row7] == 0 && self.left_ref[row7] == 0) {
            2
          } else if self.left_comp[row7] != 0 {
            3 * (if h.fix_comp_ref == 1 || self.left_ref[row7] == 1 {
              1
            } else {
              0
            })
          } else {
            4 * (if self.left_ref[row7] == 1 {
              1
            } else {
              0
            })
          }
        } else {
          2
        }
        let bit2 = vp9_rac_get_prob(self.rac, self.prob[VP9_PC_SINGLE_REF + cidx2 * 2 + 1])
        self.counts[VP9_CT_SINGLE_REF + cidx2 * 4 + 2 + bit2] += 1
        b.refidx[0] = 1 + bit2
      }
    }
  }
  // block modes for BS_8x8 and below (skipped for sub-8x8, which read per
  // sub-block modes after this)
  if b.bs <= 9 {
    if h.segmentation.enabled && h.segmentation.features[b.seg_id].skip_enabled {
      b.mode[0] = 12
      b.mode[1] = 12
      b.mode[2] = 12
      b.mode[3] = 12
    } else {
      let cidx = vp9_inter_mode_ctx_lut[
        self.above_mode[col + vp9_mode_off_tab(b.bs)] * 14 +
        self.left_mode[row7 + vp9_mode_off_tab(b.bs)]
      ]
      b.mode[0] = vp9_rac_get_tree_flat_ctx(
        self.rac,
        vp9_inter_mode_tree,
        self.prob,
        VP9_PC_MV_MODE + cidx * 3,
      )
      b.mode[1] = b.mode[0]
      b.mode[2] = b.mode[0]
      b.mode[3] = b.mode[0]
      self.counts[VP9_CT_MV_MODE + cidx * 4 + b.mode[0] - 10] += 1
    }
  }
  // interpolation filter
  if h.filter_mode == 4 {
    let cidx = if have_a && self.above_mode[col] >= 10 {
      if have_l && self.left_mode[row7] >= 10 {
        if self.above_filter[col] == self.left_filter[row7] {
          self.left_filter[row7]
        } else {
          3
        }
      } else {
        self.above_filter[col]
      }
    } else if have_l && self.left_mode[row7] >= 10 {
      self.left_filter[row7]
    } else {
      3
    }
    let filter_id = vp9_rac_get_tree_flat_ctx(
      self.rac,
      vp9_filter_tree,
      self.prob,
      VP9_PC_FILTER + cidx * 2,
    )
    self.counts[VP9_CT_FILTER + cidx * 3 + filter_id] += 1
    b.filter = vp9_filter_lut[filter_id]
  } else {
    // The frame-level field is coded in spec order (0=smooth, 1=regular,
    // 2=sharp, 3=bilinear), which C consumes directly as its FilterMode
    // enum; this port's convention swaps the first two entries.
    b.filter = match h.filter_mode {
      0 => 1
      1 => 0
      f => f
    }
  }
  // per-sub-block modes + motion vectors
  if b.bs > 9 {
    let cidx = vp9_inter_mode_ctx_lut[self.above_mode[col] * 14 + self.left_mode[row7]]
    b.mode[0] = vp9_rac_get_tree_flat_ctx(
      self.rac,
      vp9_inter_mode_tree,
      self.prob,
      VP9_PC_MV_MODE + cidx * 3,
    )
    self.counts[VP9_CT_MV_MODE + cidx * 4 + b.mode[0] - 10] += 1
    self.fill_mv(0, b.mode[0], 0)
    if b.bs != 10 {
      b.mode[1] = vp9_rac_get_tree_flat_ctx(
        self.rac,
        vp9_inter_mode_tree,
        self.prob,
        VP9_PC_MV_MODE + cidx * 3,
      )
      self.counts[VP9_CT_MV_MODE + cidx * 4 + b.mode[1] - 10] += 1
      self.fill_mv(1, b.mode[1], 1)
    } else {
      b.mode[1] = b.mode[0]
      self.copy_mv(1, 0)
    }
    if b.bs != 11 {
      b.mode[2] = vp9_rac_get_tree_flat_ctx(
        self.rac,
        vp9_inter_mode_tree,
        self.prob,
        VP9_PC_MV_MODE + cidx * 3,
      )
      self.counts[VP9_CT_MV_MODE + cidx * 4 + b.mode[2] - 10] += 1
      self.fill_mv(2, b.mode[2], 2)
      if b.bs != 10 {
        b.mode[3] = vp9_rac_get_tree_flat_ctx(
          self.rac,
          vp9_inter_mode_tree,
          self.prob,
          VP9_PC_MV_MODE + cidx * 3,
        )
        self.counts[VP9_CT_MV_MODE + cidx * 4 + b.mode[3] - 10] += 1
        self.fill_mv(3, b.mode[3], 3)
      } else {
        b.mode[3] = b.mode[2]
        self.copy_mv(3, 2)
      }
    } else {
      b.mode[2] = b.mode[0]
      self.copy_mv(2, 0)
      b.mode[3] = b.mode[1]
      self.copy_mv(3, 1)
    }
  } else {
    self.fill_mv(0, b.mode[0], -1)
    self.copy_mv(1, 0)
    self.copy_mv(2, 0)
    self.copy_mv(3, 0)
  }
}

///|
/// Copy the MV pair of sub-block `src` into sub-block `dst`.
fn Vp9Decoder::copy_mv(self : Vp9Decoder, dst : Int32, src : Int32) -> Unit {
  let b = self.b
  b.mvx[dst * 2] = b.mvx[src * 2]
  b.mvy[dst * 2] = b.mvy[src * 2]
  b.mvx[dst * 2 + 1] = b.mvx[src * 2 + 1]
  b.mvy[dst * 2 + 1] = b.mvy[src * 2 + 1]
}
