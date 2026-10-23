///|
/// MoonBit port of the VP9 probability context persistence and backward
/// adaptation from FFmpeg 9.0.2 `libavcodec/vp9prob.c` (`adapt_prob`,
/// `ff_vp9_adapt_probs`) plus the flat `ProbContext` offsets from
/// `libavcodec/vp9dec.h` shared by the frame-header reader.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// The 311-entry `ProbContext` is stored flat in C struct order; four
/// independent slots (`prob_ctx`) persist across frames exactly like the C
/// `s->prob_ctx[4].p`, and the working copy `prob` is what the block layer
/// reads.  `counts` mirrors `VP9TileData.counts` with the same element order
/// as `ff_vp9_adapt_probs` consumes them.

///|
/// Flat `ProbContext` offsets (C struct order, 311 entries total).
const VP9_PC_Y_MODE : Int32 = 0 // [4][9]
const VP9_PC_UV_MODE : Int32 = 36 // [10][9]
const VP9_PC_FILTER : Int32 = 126 // [4][2]
const VP9_PC_MV_MODE : Int32 = 134 // [7][3]
const VP9_PC_INTRA : Int32 = 155 // [4]
const VP9_PC_COMP : Int32 = 159 // [5]
const VP9_PC_SINGLE_REF : Int32 = 164 // [5][2]
const VP9_PC_COMP_REF : Int32 = 174 // [5]
// TX32P/TX16P/TX8P/SKIP offsets reuse VP9_PC_* constants in vp9_decode.mbt.
const VP9_PC_MV_JOINT : Int32 = 194 // [3]
const VP9_PC_MV_COMP : Int32 = 197 // [2][33]
const VP9_PC_PARTITION : Int32 = 263 // [4][4][3]

///|
/// One `mv_comp` entry is 33 probabilities: sign, classes[10], class0,
/// bits[10], class0_fp[2][3], fp[3], class0_hp, hp.
const VP9_MV_COMP_SIZE : Int32 = 33

///|
/// Flat `counts` offsets (element order mirrors `ff_vp9_adapt_probs`).
const VP9_CT_Y_MODE : Int32 = 0 // [4][10]
const VP9_CT_UV_MODE : Int32 = 40 // [10][10]
const VP9_CT_FILTER : Int32 = 140 // [4][3]
const VP9_CT_MV_MODE : Int32 = 152 // [7][4]
const VP9_CT_INTRA : Int32 = 180 // [4][2]
const VP9_CT_COMP : Int32 = 188 // [5][2]
const VP9_CT_SINGLE_REF : Int32 = 198 // [5][2][2]
const VP9_CT_COMP_REF : Int32 = 218 // [5][2]
const VP9_CT_TX32P : Int32 = 228 // [2][4]
const VP9_CT_TX16P : Int32 = 236 // [2][3]
const VP9_CT_TX8P : Int32 = 242 // [2][2]
const VP9_CT_SKIP : Int32 = 246 // [3][2]
const VP9_CT_MV_JOINT : Int32 = 252 // [4]
const VP9_CT_MV_COMP : Int32 = 256 // [2][51]
const VP9_CT_PARTITION : Int32 = 358 // [4][4][4]
const VP9_CT_COEF : Int32 = 422 // [4][2][2][6][6][3]
const VP9_CT_EOB : Int32 = 2150 // [4][2][2][6][6][2]
const VP9_CT_SIZE : Int32 = 3302

///|
/// One `mv_comp` counts entry: sign[2], classes[11], class0[2], bits[10][2],
/// class0_fp[2][4], fp[4], class0_hp[2], hp[2].
const VP9_MV_COMP_CT_SIZE : Int32 = 51

///|
/// `adapt_prob` (vp9prob.c): `FASTDIV(update_factor * FFMIN(ct, max), max)`
/// is a division by a constant; compute it directly.
fn vp9_adapt_prob(
  probs : FixedArray[Int32],
  idx : Int32,
  ct0 : Int32,
  ct1 : Int32,
  max_count : Int32,
  update_factor : Int32,
) -> Unit {
  let ct = ct0 + ct1
  if ct == 0 {
    return
  }
  let uf = update_factor * (if ct < max_count {
    ct
  } else {
    max_count
  }) / max_count
  let p1 = probs[idx]
  let mut p2 = (ct0 * 256 + ct / 2) / ct
  p2 = if p2 < 1 {
    1
  } else if p2 > 255 {
    255
  } else {
    p2
  }
  // (p1 * (256 - update_factor) + p2 * update_factor + 128) >> 8, with
  // the C arithmetic shift: negative adjustments must floor (not truncate
  // toward zero) or adapted probabilities drift by +1
  probs[idx] = p1 + (((p2 - p1) * uf + 128) >> 8)
}

///|
/// `ff_vp9_adapt_probs` for the 8-bit path (coefficient probabilities are
/// adapted in the same function in the C; `framectxid` selects the slot).
fn Vp9Decoder::adapt_probs(self : Vp9Decoder) -> Unit {
  let h = self.header
  let slot = h.frame_context_idx * VP9_PC_SIZE
  let p = self.prob_ctx
  let c = self.counts
  let uf = if h.keyframe || h.intra_only || !self.last_keyframe {
    112
  } else {
    128
  }
  // coefficients (4 tx * 2 pl * 2 inter)
  for tx in 0..<4 {
    for pl in 0..<2 {
      for inter in 0..<2 {
        let cbase = ((tx * 2 + pl) * 2 + inter) * 108
        for band in 0..<6 {
          for ctxn in 0..<6 {
            if band == 0 && ctxn >= 3 {
              break
            }
            let ci = VP9_CT_COEF + cbase + (band * 6 + ctxn) * 3
            let ei = VP9_CT_EOB + cbase * 2 / 3 + (band * 6 + ctxn) * 2
            let pp = h.frame_context_idx * 1728 + cbase + (band * 6 + ctxn) * 3
            vp9_adapt_prob(self.prob_ctx_coef, pp, c[ei], c[ei + 1], 24, uf)
            vp9_adapt_prob(
              self.prob_ctx_coef,
              pp + 1,
              c[ci],
              c[ci + 1] + c[ci + 2],
              24,
              uf,
            )
            vp9_adapt_prob(self.prob_ctx_coef, pp + 2, c[ci + 1], c[ci + 2], 24, uf)
          }
        }
      }
    }
  }
  if h.keyframe || h.intra_only {
    for i in 0..<3 {
      p[slot + VP9_PC_SKIP + i] = self.prob[VP9_PC_SKIP + i]
    }
    for i in 0..<6 {
      p[slot + VP9_PC_TX32P + i] = self.prob[VP9_PC_TX32P + i]
    }
    for i in 0..<4 {
      p[slot + VP9_PC_TX16P + i] = self.prob[VP9_PC_TX16P + i]
    }
    for i in 0..<2 {
      p[slot + VP9_PC_TX8P + i] = self.prob[VP9_PC_TX8P + i]
    }
    return
  }
  // skip flag
  for i in 0..<3 {
    vp9_adapt_prob(
      p,
      slot + VP9_PC_SKIP + i,
      c[VP9_CT_SKIP + i * 2],
      c[VP9_CT_SKIP + i * 2 + 1],
      20,
      128,
    )
  }
  // intra/inter flag
  for i in 0..<4 {
    vp9_adapt_prob(
      p,
      slot + VP9_PC_INTRA + i,
      c[VP9_CT_INTRA + i * 2],
      c[VP9_CT_INTRA + i * 2 + 1],
      20,
      128,
    )
  }
  // comppred flag
  if h.comp_pred_mode == 2 {
    for i in 0..<5 {
      vp9_adapt_prob(
        p,
        slot + VP9_PC_COMP + i,
        c[VP9_CT_COMP + i * 2],
        c[VP9_CT_COMP + i * 2 + 1],
        20,
        128,
      )
    }
  }
  // reference frames
  if h.comp_pred_mode != 0 {
    for i in 0..<5 {
      vp9_adapt_prob(
        p,
        slot + VP9_PC_COMP_REF + i,
        c[VP9_CT_COMP_REF + i * 2],
        c[VP9_CT_COMP_REF + i * 2 + 1],
        20,
        128,
      )
    }
  }
  if h.comp_pred_mode != 1 {
    for i in 0..<5 {
      let ci = VP9_CT_SINGLE_REF + i * 4
      vp9_adapt_prob(p, slot + VP9_PC_SINGLE_REF + i * 2, c[ci], c[ci + 1], 20, 128)
      vp9_adapt_prob(
        p,
        slot + VP9_PC_SINGLE_REF + i * 2 + 1,
        c[ci + 2],
        c[ci + 3],
        20,
        128,
      )
    }
  }
  // block partitioning
  for i in 0..<4 {
    for j in 0..<4 {
      let ci = VP9_CT_PARTITION + (i * 4 + j) * 4
      let pi = slot + VP9_PC_PARTITION + (i * 4 + j) * 3
      vp9_adapt_prob(p, pi, c[ci], c[ci + 1] + c[ci + 2] + c[ci + 3], 20, 128)
      vp9_adapt_prob(p, pi + 1, c[ci + 1], c[ci + 2] + c[ci + 3], 20, 128)
      vp9_adapt_prob(p, pi + 2, c[ci + 2], c[ci + 3], 20, 128)
    }
  }
  // tx size
  if self.tx_mode == VP9_TX_SWITCHABLE {
    for i in 0..<2 {
      let c16 = VP9_CT_TX16P + i * 3
      let c32 = VP9_CT_TX32P + i * 4
      vp9_adapt_prob(
        p,
        slot + VP9_PC_TX8P + i,
        c[VP9_CT_TX8P + i * 2],
        c[VP9_CT_TX8P + i * 2 + 1],
        20,
        128,
      )
      vp9_adapt_prob(
        p,
        slot + VP9_PC_TX16P + i * 2,
        c[c16],
        c[c16 + 1] + c[c16 + 2],
        20,
        128,
      )
      vp9_adapt_prob(p, slot + VP9_PC_TX16P + i * 2 + 1, c[c16 + 1], c[c16 + 2], 20, 128)
      vp9_adapt_prob(
        p,
        slot + VP9_PC_TX32P + i * 3,
        c[c32],
        c[c32 + 1] + c[c32 + 2] + c[c32 + 3],
        20,
        128,
      )
      vp9_adapt_prob(
        p,
        slot + VP9_PC_TX32P + i * 3 + 1,
        c[c32 + 1],
        c[c32 + 2] + c[c32 + 3],
        20,
        128,
      )
      vp9_adapt_prob(p, slot + VP9_PC_TX32P + i * 3 + 2, c[c32 + 2], c[c32 + 3], 20, 128)
    }
  }
  // interpolation filter
  if h.filter_mode == 4 {
    for i in 0..<4 {
      let ci = VP9_CT_FILTER + i * 3
      let pi = slot + VP9_PC_FILTER + i * 2
      vp9_adapt_prob(p, pi, c[ci], c[ci + 1] + c[ci + 2], 20, 128)
      vp9_adapt_prob(p, pi + 1, c[ci + 1], c[ci + 2], 20, 128)
    }
  }
  // inter modes
  for i in 0..<7 {
    let ci = VP9_CT_MV_MODE + i * 4
    let pi = slot + VP9_PC_MV_MODE + i * 3
    vp9_adapt_prob(p, pi, c[ci + 2], c[ci + 1] + c[ci] + c[ci + 3], 20, 128)
    vp9_adapt_prob(p, pi + 1, c[ci], c[ci + 1] + c[ci + 3], 20, 128)
    vp9_adapt_prob(p, pi + 2, c[ci + 1], c[ci + 3], 20, 128)
  }
  // mv joints
  {
    let ci = VP9_CT_MV_JOINT
    let pi = slot + VP9_PC_MV_JOINT
    vp9_adapt_prob(p, pi, c[ci], c[ci + 1] + c[ci + 2] + c[ci + 3], 20, 128)
    vp9_adapt_prob(p, pi + 1, c[ci + 1], c[ci + 2] + c[ci + 3], 20, 128)
    vp9_adapt_prob(p, pi + 2, c[ci + 2], c[ci + 3], 20, 128)
  }
  // mv components
  for i in 0..<2 {
    let cb = VP9_CT_MV_COMP + i * VP9_MV_COMP_CT_SIZE
    let pi = slot + VP9_PC_MV_COMP + i * VP9_MV_COMP_SIZE
    vp9_adapt_prob(p, pi, c[cb], c[cb + 1], 20, 128)
    // classes
    let mut sum = 0
    for j in 1..<11 {
      sum += c[cb + 2 + j]
    }
    vp9_adapt_prob(p, pi + 1, c[cb + 2], sum, 20, 128)
    sum -= c[cb + 2 + 1]
    vp9_adapt_prob(p, pi + 2, c[cb + 2 + 1], sum, 20, 128)
    sum -= c[cb + 2 + 2] + c[cb + 2 + 3]
    vp9_adapt_prob(p, pi + 3, c[cb + 2 + 2] + c[cb + 2 + 3], sum, 20, 128)
    vp9_adapt_prob(p, pi + 4, c[cb + 2 + 2], c[cb + 2 + 3], 20, 128)
    sum -= c[cb + 2 + 4] + c[cb + 2 + 5]
    vp9_adapt_prob(p, pi + 5, c[cb + 2 + 4] + c[cb + 2 + 5], sum, 20, 128)
    vp9_adapt_prob(p, pi + 6, c[cb + 2 + 4], c[cb + 2 + 5], 20, 128)
    sum -= c[cb + 2 + 6]
    vp9_adapt_prob(p, pi + 7, c[cb + 2 + 6], sum, 20, 128)
    vp9_adapt_prob(p, pi + 8, c[cb + 2 + 7] + c[cb + 2 + 8], c[cb + 2 + 9] + c[cb + 2 + 10], 20, 128)
    vp9_adapt_prob(p, pi + 9, c[cb + 2 + 7], c[cb + 2 + 8], 20, 128)
    vp9_adapt_prob(p, pi + 10, c[cb + 2 + 9], c[cb + 2 + 10], 20, 128)
    // class0
    vp9_adapt_prob(p, pi + 11, c[cb + 13], c[cb + 14], 20, 128)
    // bits
    for j in 0..<10 {
      vp9_adapt_prob(p, pi + 12 + j, c[cb + 15 + j * 2], c[cb + 16 + j * 2], 20, 128)
    }
    // class0_fp
    for j in 0..<2 {
      let cj = cb + 35 + j * 4
      let pj = pi + 22 + j * 3
      vp9_adapt_prob(p, pj, c[cj], c[cj + 1] + c[cj + 2] + c[cj + 3], 20, 128)
      vp9_adapt_prob(p, pj + 1, c[cj + 1], c[cj + 2] + c[cj + 3], 20, 128)
      vp9_adapt_prob(p, pj + 2, c[cj + 2], c[cj + 3], 20, 128)
    }
    // fp
    let cf = cb + 43
    let pf = pi + 28
    vp9_adapt_prob(p, pf, c[cf], c[cf + 1] + c[cf + 2] + c[cf + 3], 20, 128)
    vp9_adapt_prob(p, pf + 1, c[cf + 1], c[cf + 2] + c[cf + 3], 20, 128)
    vp9_adapt_prob(p, pf + 2, c[cf + 2], c[cf + 3], 20, 128)
    if h.high_precision_mvs {
      vp9_adapt_prob(p, pi + 31, c[cb + 47], c[cb + 48], 20, 128)
      vp9_adapt_prob(p, pi + 32, c[cb + 49], c[cb + 50], 20, 128)
    }
  }
  // y intra modes
  for i in 0..<4 {
    let ci = VP9_CT_Y_MODE + i * 10
    let pi = slot + VP9_PC_Y_MODE + i * 9
    let mut sum = 0
    // sum of all but c[2] (the tree's second leaf slot)
    for j in 0..<10 {
      sum += c[ci + j]
    }
    sum -= c[ci + 2]
    vp9_adapt_prob(p, pi, c[ci + 2], sum, 20, 128)
    sum -= c[ci + 9]
    vp9_adapt_prob(p, pi + 1, c[ci + 9], sum, 20, 128)
    sum -= c[ci]
    vp9_adapt_prob(p, pi + 2, c[ci], sum, 20, 128)
    let mut s2 = c[ci + 1] + c[ci + 4] + c[ci + 5]
    sum -= s2
    vp9_adapt_prob(p, pi + 3, s2, sum, 20, 128)
    s2 -= c[ci + 1]
    vp9_adapt_prob(p, pi + 4, c[ci + 1], s2, 20, 128)
    vp9_adapt_prob(p, pi + 5, c[ci + 4], c[ci + 5], 20, 128)
    sum -= c[ci + 3]
    vp9_adapt_prob(p, pi + 6, c[ci + 3], sum, 20, 128)
    sum -= c[ci + 7]
    vp9_adapt_prob(p, pi + 7, c[ci + 7], sum, 20, 128)
    vp9_adapt_prob(p, pi + 8, c[ci + 6], c[ci + 8], 20, 128)
  }
  // uv intra modes
  for i in 0..<10 {
    let ci = VP9_CT_UV_MODE + i * 10
    let pi = slot + VP9_PC_UV_MODE + i * 9
    let mut sum = 0
    for j in 0..<10 {
      sum += c[ci + j]
    }
    sum -= c[ci + 2]
    vp9_adapt_prob(p, pi, c[ci + 2], sum, 20, 128)
    sum -= c[ci + 9]
    vp9_adapt_prob(p, pi + 1, c[ci + 9], sum, 20, 128)
    sum -= c[ci]
    vp9_adapt_prob(p, pi + 2, c[ci], sum, 20, 128)
    let mut s2 = c[ci + 1] + c[ci + 4] + c[ci + 5]
    sum -= s2
    vp9_adapt_prob(p, pi + 3, s2, sum, 20, 128)
    s2 -= c[ci + 1]
    vp9_adapt_prob(p, pi + 4, c[ci + 1], s2, 20, 128)
    vp9_adapt_prob(p, pi + 5, c[ci + 4], c[ci + 5], 20, 128)
    sum -= c[ci + 3]
    vp9_adapt_prob(p, pi + 6, c[ci + 3], sum, 20, 128)
    sum -= c[ci + 7]
    vp9_adapt_prob(p, pi + 7, c[ci + 7], sum, 20, 128)
    vp9_adapt_prob(p, pi + 8, c[ci + 6], c[ci + 8], 20, 128)
  }
}

///|
/// Commit the working probability model (`prob`) into the frame-context slot
/// (`parallelmode` path of `vp9_decode_frame`).
fn Vp9Decoder::commit_prob_ctx(self : Vp9Decoder) -> Unit {
  let h = self.header
  let slot = h.frame_context_idx * VP9_PC_SIZE
  for i in 0..<VP9_PC_SIZE {
    self.prob_ctx[slot + i] = self.prob[i]
  }
  // coefficient probabilities up to the frame's tx mode (C commit loop)
  for tx in 0..<4 {
    for pl in 0..<2 {
      for inter in 0..<2 {
        for band in 0..<6 {
          for ctxn in 0..<6 {
            if band == 0 && ctxn >= 3 {
              break
            }
            let pb = vp9_ctx_coef_base(h.frame_context_idx, tx, pl, inter)
            // the working table stores 11 values per slot (3 probs + pareto
            // tail) while the context copy stores 3
            let q = vp9_coef_base(tx, pl, inter) + (band * 6 + ctxn) * 11
            for n in 0..<3 {
              self.prob_ctx_coef[pb + (band * 6 + ctxn) * 3 + n] = self.prob_coef[q + n]
            }
          }
        }
      }
    }
    if self.tx_mode == tx {
      break
    }
  }
}

///|
/// Load the working probability model from the selected frame-context slot
/// (C `s->prob.p = s->prob_ctx[c].p`).
fn Vp9Decoder::load_prob_ctx(self : Vp9Decoder) -> Unit {
  let slot = self.header.frame_context_idx * VP9_PC_SIZE
  for i in 0..<VP9_PC_SIZE {
    self.prob[i] = self.prob_ctx[slot + i]
  }
}
