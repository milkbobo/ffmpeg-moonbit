///|
/// HEVC encoder sample adaptive offset (SAO): per-CTB luma band-offset
/// decision and the CABAC write side.
///
/// The decision is a genuine rate-distortion-free distortion minimiser: for
/// each CTB it builds a 32-band histogram of the residual `source - deblocked
/// reconstruction`, picks the offset that minimises that band's absolute error
/// (`o = clamp(round(mean error))`, the mean being a cheap median proxy), then
/// selects the four consecutive bands whose combined SAD gain is largest. The
/// offsets it produces are exactly what `hevc_sao_apply` will apply, so the
/// encoder's reconstruction after SAO matches the decoder's by construction.
///
/// Chroma SAO stays off (`slice_sao_chroma_flag = 0`), which is signalled
/// without any per-CTB chroma bins.

///|
/// Band-offset magnitude cap for the active bit depth: `(1 << (bd - 5)) - 1`
/// (7 for 8-bit), the same cap the CABAC syntax enforces.
fn hevc_enc_sao_offset_cap(bd : Int32) -> Int32 {
  (1 << ((if bd < 10 { bd } else { 10 }) - 5)) - 1
}

///|
/// Decide the luma SAO parameters for every CTB from the deblocked
/// reconstruction. `src_y` is the padded source plane; `pic.y` holds the
/// deblocked reconstruction. Returns parameters that are safe to both write
/// into the bitstream and apply with `hevc_sao_apply`.
fn hevc_enc_sao_decide(
  sps : HevcSps,
  src_y : FixedArray[Int32],
  pic : HevcPicture,
) -> HevcSaoParams {
  let sao = hevc_sao_params_new(sps.ctb_size, sps.ctb_width)
  let bd = sps.bit_depth
  let cap = hevc_enc_sao_offset_cap(bd)
  let band_shift = bd - 5
  let ctb_size = 1 << sps.log2_ctb_size
  let stride = pic.width
  for ctb in 0..<sps.ctb_size {
    let x_ctb = ctb % sps.ctb_width
    let y_ctb = ctb / sps.ctb_width
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
    if w <= 0 || h <= 0 {
      continue
    }
    // Per-band error statistics: sum of e, sum of |e|, count.
    let sum_e : Array[Int32] = Array::make(32, 0)
    let sum_abs : Array[Int32] = Array::make(32, 0)
    let count : Array[Int32] = Array::make(32, 0)
    for y in 0..<h {
      for x in 0..<w {
        let idx = (y0 + y) * stride + x0 + x
        let e = src_y[idx] - pic.y[idx]
        let b = (pic.y[idx] >> band_shift) & 31
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
          let idx = (y0 + y) * stride + x0 + x
          if ((pic.y[idx] >> band_shift) & 31) == b {
            let d = src_y[idx] - pic.y[idx] - o
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
    if best_start < 0 {
      // No band helps: type_idx 0 means "no SAO" for this CTB.
      sao.type_idx[ctb * 3] = 0
      continue
    }
    sao.type_idx[ctb * 3] = hevc_sao_band
    sao.band_position[ctb * 3] = best_start
    for k in 0..<4 {
      let b = (best_start + k) & 31
      let mut o = 0
      if gain[b] > 0 {
        o = best_off[b]
      }
      // The syntax carries |offset| plus a sign bit, and the decoder shifts by
      // `log2_sao_offset_scale_luma` (0 for 8-bit, the only depth we emit).
      sao.offset_val[ctb * 15 + k + 1] = o
    }
  }
  sao
}

///|
/// Write one CTB's SAO parameters, mirroring `hevc_sao_parse`. Merge flags are
/// always 0 (no CTB inherits a neighbour's parameters), luma carries the band
/// data, chroma is inactive.
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
  // Luma only: `slice_sao_chroma_flag` is 0, so chroma reads no bins.
  if !sh.slice_sao_luma_flag {
    return
  }
  let sao_type = sao.type_idx[ctb_rs * 3]
  cabac.sao_type_idx(sao_type)
  if sao_type == 0 {
    return
  }
  let bd = sps.bit_depth
  // offset_abs[0..3], then one sign bit per nonzero offset (band mode).
  let abs_val : Array[Int32] = Array::make(4, 0)
  let neg : Array[Int32] = Array::make(4, 0)
  for k in 0..<4 {
    let v = sao.offset_val[ctb_rs * 15 + k + 1]
    abs_val[k] = if v < 0 { -v } else { v }
    neg[k] = if v < 0 { 1 } else { 0 }
  }
  for k in 0..<4 {
    cabac.sao_offset_abs(bd, abs_val[k])
  }
  for k in 0..<4 {
    if abs_val[k] != 0 {
      cabac.sao_offset_sign(neg[k])
    }
  }
  cabac.sao_band_position(sao.band_position[ctb_rs * 3])
}
