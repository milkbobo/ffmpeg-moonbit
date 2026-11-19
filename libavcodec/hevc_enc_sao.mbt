///|
/// HEVC encoder sample adaptive offset (SAO): per-CTB luma and (opt-in,
/// §460) chroma band-offset decision, plus the opt-in edge-offset mode
/// (§461), and the CABAC write side.
///
/// The band decision is a rate-distortion-free distortion minimiser: for
/// each CTB and plane it builds a 32-band histogram of the residual
/// `source - deblocked reconstruction`, picks the offset that minimises that
/// band's absolute error (`o = clamp(round(mean error))`), then selects the
/// four consecutive bands whose combined SAD gain is largest. The edge
/// decision classifies the same residual by edge category (`edge_idx`,
/// comparing the reconstruction against its two neighbours along one of the
/// four EO directions) and minimises each category's error under the syntax
/// sign constraint — categories 1/2 offset up, 3/4 offset down, 0 never
/// offsets. Whichever of the two modes (and, for EO, whichever of the four
/// `eo_class` directions) yields the larger exact SAD gain wins the CTB.
/// The offsets the decision produces are exactly what `hevc_sao_apply` will
/// apply, so the encoder's reconstruction after SAO matches the decoder's
/// by construction.
///
/// Chroma SAO mirrors `hevc_sao_parse`'s component coupling: Cb carries its
/// own type and EO-class bins, Cr inherits both (no bins) while its offsets
/// and band position are still coded — so the Cr decision runs under
/// whatever type and EO class Cb picked, and both are off when Cb is.
/// Chroma is opt-in (`slice_sao_chroma_flag = 1`) so the default streams
/// keep their pinned bytes; EO is opt-in the same way (`sao_eo = true`).

///|
/// Band-offset magnitude cap for the active bit depth: `(1 << (bd - 5)) - 1`
/// (7 for 8-bit), the same cap the CABAC syntax enforces.
fn hevc_enc_sao_offset_cap(bd : Int32) -> Int32 {
  (1 << ((if bd < 10 { bd } else { 10 }) - 5)) - 1
}

///|
/// One SAO candidate for a CTB plane: the exact SAD gain, the mode
/// (0 = off, `hevc_sao_band`, `hevc_sao_edge`), the band position or EO
/// class it carries, and the four offsets for the syntax slots 1..4.
priv struct HevcSaoCand {
  gain : Int32
  kind : Int32
  aux : Int32
  offsets : FixedArray[Int32]
}

///|
fn hevc_enc_sao_cand_off() -> FixedArray[Int32] {
  FixedArray::make(4, 0)
}

///|
/// Band candidate for one CTB plane: 32-band histogram of the residual,
/// per-band mean offset, best four consecutive bands.
fn hevc_enc_sao_band_eval(
  bd : Int32,
  src : FixedArray[Int32],
  rec : Array[Int32],
  rec_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
) -> HevcSaoCand {
  let cap = hevc_enc_sao_offset_cap(bd)
  let band_shift = bd - 5
  // Per-band error statistics: sum of e, sum of |e|, count.
  let sum_e : Array[Int32] = Array::make(32, 0)
  let sum_abs : Array[Int32] = Array::make(32, 0)
  let count : Array[Int32] = Array::make(32, 0)
  for y in 0..<h {
    for x in 0..<w {
      let idx = (y0 + y) * rec_stride + x0 + x
      let e = src[idx] - rec[idx]
      let b = (rec[idx] >> band_shift) & 31
      sum_e[b] = sum_e[b] + e
      sum_abs[b] = sum_abs[b] + (if e < 0 { -e } else { e })
      count[b] = count[b] + 1
    }
  }
  // Best offset and its SAD gain for each band.
  let best_off : Array[Int32] = Array::make(32, 0)
  let gain : Array[Int32] = Array::make(32, 0)
  for b in 0..<32 {
    if count[b] == 0 {
      continue
    }
    let mut o = (sum_e[b] + count[b] / 2) / count[b]
    if o > cap {
      o = cap
    }
    if o < -cap {
      o = -cap
    }
    best_off[b] = o
    // Exact gain: sum|e| - sum|e - o|. Recompute the shifted sum.
    let mut shifted = 0
    for y in 0..<h {
      for x in 0..<w {
        let idx = (y0 + y) * rec_stride + x0 + x
        if ((rec[idx] >> band_shift) & 31) == b {
          let d = src[idx] - rec[idx] - o
          shifted = shifted + (if d < 0 { -d } else { d })
        }
      }
    }
    gain[b] = sum_abs[b] - shifted
  }
  // Pick the four consecutive bands with the largest combined gain.
  let mut best_start = -1
  let mut best_gain = 0
  for p in 0..<32 {
    let mut g = 0
    for k in 0..<4 {
      let b = (p + k) & 31
      if gain[b] > 0 {
        g = g + gain[b]
      }
    }
    if g > best_gain {
      best_gain = g
      best_start = p
    }
  }
  let cand : HevcSaoCand = {
    gain: best_gain,
    kind: if best_start < 0 {
      0
    } else {
      hevc_sao_band
    },
    aux: if best_start < 0 {
      0
    } else {
      best_start
    },
    offsets: hevc_enc_sao_cand_off(),
  }
  if best_start >= 0 {
    for k in 0..<4 {
      let b = (best_start + k) & 31
      if gain[b] > 0 {
        cand.offsets[k] = best_off[b]
      }
    }
  }
  cand
}

///|
/// EO candidate for one CTB plane. With `force_class >= 0` only that EO
/// direction is evaluated (the Cr decision under Cb's inherited class);
/// otherwise all four compete. Neighbour samples outside the PLANE (not the
/// CTB) fall back to the sample itself, exactly like `hevc_sao_apply`.
fn hevc_enc_sao_eo_eval(
  bd : Int32,
  src : FixedArray[Int32],
  rec : Array[Int32],
  rec_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
  pw : Int32,
  ph : Int32,
  force_class : Int32,
) -> HevcSaoCand {
  let cap = hevc_enc_sao_offset_cap(bd)
  // Neighbour pairs per EO direction, and the d0+d1 -> category map, both
  // shared with `hevc_sao_apply`.
  let pos : FixedArray[Int32] = [
    -1, 0, 1, 0, 0, -1, 0, 1, -1, -1, 1, 1, 1, -1, -1, 1,
  ]
  let edge_idx : FixedArray[Int32] = [1, 2, 0, 3, 4]
  let classes : Array[Int32] = if force_class >= 0 {
    [force_class]
  } else {
    [0, 1, 2, 3]
  }
  let mut best : HevcSaoCand = {
    gain: 0,
    kind: 0,
    aux: 0,
    offsets: hevc_enc_sao_cand_off(),
  }
  for eo in classes {
    let o0 = eo * 4
    let dx0 = pos[o0]
    let dy0 = pos[o0 + 1]
    let dx1 = pos[o0 + 2]
    let dy1 = pos[o0 + 3]
    // Residual statistics per edge category (slots 1..4; 0 never offsets).
    let diff : Array[Int32] = Array::make(5, 0)
    let cnt : Array[Int32] = Array::make(5, 0)
    let sum_abs : Array[Int32] = Array::make(5, 0)
    for y in 0..<h {
      for x in 0..<w {
        let px = x0 + x
        let pyi = y0 + y
        let idx = pyi * rec_stride + px
        let v = rec[idx]
        let nx0 = px + dx0
        let ny0 = pyi + dy0
        let n0 = if nx0 < 0 || nx0 >= pw || ny0 < 0 || ny0 >= ph {
          v
        } else {
          rec[ny0 * rec_stride + nx0]
        }
        let nx1 = px + dx1
        let ny1 = pyi + dy1
        let n1 = if nx1 < 0 || nx1 >= pw || ny1 < 0 || ny1 >= ph {
          v
        } else {
          rec[ny1 * rec_stride + nx1]
        }
        let d0 = if v > n0 { 1 } else if v < n0 { -1 } else { 0 }
        let d1 = if v > n1 { 1 } else if v < n1 { -1 } else { 0 }
        let oi = edge_idx[2 + d0 + d1]
        let e = src[idx] - rec[idx]
        diff[oi] = diff[oi] + e
        cnt[oi] = cnt[oi] + 1
        sum_abs[oi] = sum_abs[oi] + (if e < 0 { -e } else { e })
      }
    }
    // Offsets under the sign constraint: categories 1/2 up, 3/4 down.
    // Symmetric round-half-away (the naive `(d + c/2)/c` truncates negative
    // means toward zero, biasing every down-offset by +0.5 — the ringing
    // construction in the whitebox test pins this).
    let offs : Array[Int32] = Array::make(5, 0)
    for oi in 1..<5 {
      if cnt[oi] == 0 {
        continue
      }
      let neg_mean = diff[oi] < 0
      let mag = if neg_mean { -diff[oi] } else { diff[oi] }
      let mut o = (mag + cnt[oi] / 2) / cnt[oi]
      if neg_mean {
        o = -o
      }
      if o > cap {
        o = cap
      }
      if o < -cap {
        o = -cap
      }
      if oi <= 2 {
        if o < 0 {
          o = 0
        }
      } else if o > 0 {
        o = 0
      }
      offs[oi] = o
    }
    // Exact gain: sum|e| - sum|e - o_oi| over the whole block.
    let mut shifted = 0
    for y in 0..<h {
      for x in 0..<w {
        let px = x0 + x
        let pyi = y0 + y
        let idx = pyi * rec_stride + px
        let v = rec[idx]
        let nx0 = px + dx0
        let ny0 = pyi + dy0
        let n0 = if nx0 < 0 || nx0 >= pw || ny0 < 0 || ny0 >= ph {
          v
        } else {
          rec[ny0 * rec_stride + nx0]
        }
        let nx1 = px + dx1
        let ny1 = pyi + dy1
        let n1 = if nx1 < 0 || nx1 >= pw || ny1 < 0 || ny1 >= ph {
          v
        } else {
          rec[ny1 * rec_stride + nx1]
        }
        let d0 = if v > n0 { 1 } else if v < n0 { -1 } else { 0 }
        let d1 = if v > n1 { 1 } else if v < n1 { -1 } else { 0 }
        let oi = edge_idx[2 + d0 + d1]
        let d = src[idx] - rec[idx] - offs[oi]
        shifted = shifted + (if d < 0 { -d } else { d })
      }
    }
    let total_abs = sum_abs[1] + sum_abs[2] + sum_abs[3] + sum_abs[4]
    let g = total_abs - shifted
    if g > best.gain {
      best = {
        gain: g,
        kind: hevc_sao_edge,
        aux: eo,
        offsets: hevc_enc_sao_cand_off(),
      }
      best.offsets[0] = offs[1]
      best.offsets[1] = offs[2]
      best.offsets[2] = offs[3]
      best.offsets[3] = offs[4]
    }
  }
  best
}

///|
/// Adopt a candidate into the parameter slots for component `c` of CTB `ctb`.
fn hevc_enc_sao_adopt(
  sao : HevcSaoParams,
  cand : HevcSaoCand,
  ctb : Int32,
  c : Int32,
) -> Unit {
  sao.type_idx[ctb * 3 + c] = cand.kind
  if cand.kind == hevc_sao_band {
    sao.band_position[ctb * 3 + c] = cand.aux
  } else if cand.kind == hevc_sao_edge {
    sao.eo_class[ctb * 3 + c] = cand.aux
  }
  for k in 0..<4 {
    sao.offset_val[ctb * 15 + c * 5 + k + 1] = cand.offsets[k]
  }
}

///|
/// Decide the SAO parameters for every CTB from the deblocked
/// reconstruction. `sy`/`su`/`sv` are the padded source planes; `pic.y` /
/// `pic.cb` / `pic.cr` hold the deblocked reconstruction. `chroma` selects
/// the opt-in chroma decision (Cb decides its own type and EO class; Cr
/// inherits both). `eo` lets the edge-offset mode compete with (and possibly
/// replace) the band mode. Returns parameters that are safe to both write
/// into the bitstream and apply with `hevc_sao_apply`.
fn hevc_enc_sao_decide(
  sps : HevcSps,
  sy : FixedArray[Int32],
  su : FixedArray[Int32],
  sv : FixedArray[Int32],
  pic : HevcPicture,
  chroma~ : Bool = false,
  eo~ : Bool = false,
) -> HevcSaoParams {
  let sao = hevc_sao_params_new(sps.ctb_size, sps.ctb_width)
  let bd = sps.bit_depth
  let ctb_size = 1 << sps.log2_ctb_size
  for ctb in 0..<sps.ctb_size {
    let x_ctb = ctb % sps.ctb_width
    let y_ctb = ctb / sps.ctb_width
    // Luma: full CTB block.
    let x0 = x_ctb * ctb_size
    let y0 = y_ctb * ctb_size
    let mut w = ctb_size
    let mut h = ctb_size
    if x0 + w > sps.width {
      w = sps.width - x0
    }
    if y0 + h > sps.height {
      h = sps.height - y0
    }
    if w > 0 && h > 0 {
      let band = hevc_enc_sao_band_eval(bd, sy, pic.y, pic.width, x0, y0, w, h)
      let cand = if eo {
        let edge = hevc_enc_sao_eo_eval(
          bd,
          sy,
          pic.y,
          pic.width,
          x0,
          y0,
          w,
          h,
          pic.width,
          pic.height,
          -1,
        )
        // Tie-break towards EO: equal gain, fewer bins (no band position,
        // no sign bits).
        if edge.gain >= band.gain {
          edge
        } else {
          band
        }
      } else {
        band
      }
      hevc_enc_sao_adopt(sao, cand, ctb, 0)
    }
    if !chroma {
      continue
    }
    // Chroma: the CTB's plane-aligned block (4:2:0 halves both axes, 4:2:2
    // only the columns, 4:4:4 the full CTB).
    let cs_h = ctb_size >> sps.hshift[1]
    let cs_v = ctb_size >> sps.vshift[1]
    let cx0 = x_ctb * cs_h
    let cy0 = y_ctb * cs_v
    let cw = pic.width >> sps.hshift[1]
    let ch = pic.height >> sps.vshift[1]
    let mut cw_ctb = cs_h
    let mut ch_ctb = cs_v
    if cx0 + cw_ctb > cw {
      cw_ctb = cw - cx0
    }
    if cy0 + ch_ctb > ch {
      ch_ctb = ch - cy0
    }
    if cw_ctb <= 0 || ch_ctb <= 0 {
      continue
    }
    let band_cb = hevc_enc_sao_band_eval(
      bd,
      su,
      pic.cb,
      cw,
      cx0,
      cy0,
      cw_ctb,
      ch_ctb,
    )
    let cb = if eo {
      let edge = hevc_enc_sao_eo_eval(
        bd,
        su,
        pic.cb,
        cw,
        cx0,
        cy0,
        cw_ctb,
        ch_ctb,
        cw,
        ch,
        -1,
      )
      if edge.gain >= band_cb.gain {
        edge
      } else {
        band_cb
      }
    } else {
      band_cb
    }
    hevc_enc_sao_adopt(sao, cb, ctb, 1)
    // Cr inherits Cb's type and EO class (no bins of its own); when Cb is
    // off, Cr is off too.
    sao.type_idx[ctb * 3 + 2] = sao.type_idx[ctb * 3 + 1]
    if sao.type_idx[ctb * 3 + 1] != 0 {
      let cand_cr = if sao.type_idx[ctb * 3 + 1] == hevc_sao_edge {
        // Same EO direction as Cb; only the offsets are Cr's own.
        hevc_enc_sao_eo_eval(
          bd,
          sv,
          pic.cr,
          cw,
          cx0,
          cy0,
          cw_ctb,
          ch_ctb,
          cw,
          ch,
          sao.eo_class[ctb * 3 + 1],
        )
      } else {
        hevc_enc_sao_band_eval(bd, sv, pic.cr, cw, cx0, cy0, cw_ctb, ch_ctb)
      }
      hevc_enc_sao_adopt(sao, cand_cr, ctb, 2)
    }
  }
  sao
}

///|
/// Write one CTB's SAO parameters, mirroring `hevc_sao_parse`. Merge flags are
/// always 0 (no CTB inherits a neighbour's parameters); luma and (with
/// `slice_sao_chroma_flag`) Cb carry their type, offsets, signs (band mode
/// only) and band position / EO class, Cr codes its offsets, signs and band
/// position under Cb's inherited type and EO class.
fn hevc_enc_write_sao_ctb(
  cabac : HevcEncCabac,
  sps : HevcSps,
  sh : HevcSliceHeader,
  sao : HevcSaoParams,
  ctb_rs : Int32,
  x_ctb : Int32,
  y_ctb : Int32,
  ctb_left : Bool,
  ctb_up : Bool,
) -> Unit {
  if !(sh.slice_sao_luma_flag || sh.slice_sao_chroma_flag) {
    return
  }
  if x_ctb > 0 && ctb_left {
    cabac.sao_merge_flag(false)
  }
  if y_ctb > 0 && ctb_up {
    cabac.sao_merge_flag(false)
  }
  let bd = sps.bit_depth
  // The component loop mirrors `hevc_sao_parse`'s cIdx 0..2: luma then, when
  // the chroma flag is on, Cb with its own type bin and Cr under Cb's type.
  let comps : Array[Int32] = if sh.slice_sao_chroma_flag {
    [0, 1, 2]
  } else if sh.slice_sao_luma_flag {
    [0]
  } else {
    []
  }
  for c_idx in comps {
    let active = if c_idx == 0 {
      sh.slice_sao_luma_flag
    } else {
      sh.slice_sao_chroma_flag
    }
    if !active {
      continue
    }
    // Cr (c_idx == 2) inherits Cb's type: no sao_type_idx bin of its own.
    if c_idx != 2 {
      let sao_type = sao.type_idx[ctb_rs * 3 + c_idx]
      cabac.sao_type_idx(sao_type)
      if sao_type == 0 {
        continue
      }
    } else if sao.type_idx[ctb_rs * 3 + 1] == 0 {
      continue
    }
    let sao_type = sao.type_idx[ctb_rs * 3 + c_idx]
    // offset_abs[0..3]; band mode adds one sign bit per nonzero offset, EO
    // mode's signs are implied by the category (1/2 up, 3/4 down).
    let abs_val : Array[Int32] = Array::make(4, 0)
    let neg : Array[Int32] = Array::make(4, 0)
    for k in 0..<4 {
      let v = sao.offset_val[ctb_rs * 15 + c_idx * 5 + k + 1]
      abs_val[k] = if v < 0 { -v } else { v }
      neg[k] = if v < 0 { 1 } else { 0 }
    }
    for k in 0..<4 {
      cabac.sao_offset_abs(bd, abs_val[k])
    }
    if sao_type == hevc_sao_band {
      for k in 0..<4 {
        if abs_val[k] != 0 {
          cabac.sao_offset_sign(neg[k])
        }
      }
      cabac.sao_band_position(sao.band_position[ctb_rs * 3 + c_idx])
      // The EO class is luma's and Cb's own bin; Cr inherits Cb's.
    } else if c_idx != 2 {
      cabac.sao_eo_class(sao.eo_class[ctb_rs * 3 + c_idx])
    }
  }
}
