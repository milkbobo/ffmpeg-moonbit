///|
/// Encoder-side explicit weighted prediction (`weighted_pred_flag = 1`,
/// `weightp`): the least-squares model `dst ≈ (w / 2^denom) * src + o`
/// fitted per plane against the reference picture this slice actually
/// predicts from, rounded into the `pred_weight_table()` integer domain:
/// offsets clamp to -128..127 (the `se(v)` syntax range — an `int8` at every
/// bit depth, so the sample-domain fit is divided by `2^(bit_depth-8)`
/// first) and weights clamp to 0..127 — the syntax would allow -128, but a
/// negative slope only ever fits a sign-inverted reference, which this
/// encoder never predicts from.
///
/// The fit is the classic two-pass normal-equation solution
/// (`w = (nΣds - ΣdΣs) / (nΣs² - (Σs)²)`, `o = (Σd - wΣs) / n`), evaluated
/// in Int64 so a 1080p plane (Σs² up to ~1.4e11) cannot overflow. A flat or
/// degenerate reference (`nΣs² - (Σs)² <= 0`) yields the neutral weight.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
/// Returns `(weight, offset)`, already clamped to the syntax ranges.
fn h264_enc_plane_weight(
  dst : Array[Int32],
  dst_stride : Int32,
  src : Array[Int32],
  src_stride : Int32,
  w : Int32,
  h : Int32,
  denom : Int32,
  bit_depth~ : Int32 = 8,
) -> (Int32, Int32) {
  let scale : Int64 = (1L : Int64) << denom
  if w <= 0 || h <= 0 {
    return (scale.to_int(), 0)
  }
  let mut n : Int64 = 0L
  let mut sd : Int64 = 0L
  let mut ss : Int64 = 0L
  let mut sds : Int64 = 0L
  let mut sss : Int64 = 0L
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let d = dst[y * dst_stride + x].to_int64()
      let s = src[y * src_stride + x].to_int64()
      n = n + 1L
      sd = sd + d
      ss = ss + s
      sds = sds + d * s
      sss = sss + s * s
    }
  }
  if n == 0L {
    return (scale.to_int(), 0)
  }
  // `den` is the reference's variance numerator: zero for a flat reference,
  // where no slope exists and the neutral weight is the only sane answer.
  let den = n * sss - ss * ss
  let num = n * sds - sd * ss
  let mut wq = if den <= 0L {
    scale
  } else {
    h264_enc_div_round(scale * num, den)
  }
  // The useful slope is 0..2 (`weighted_pred` allows -128..127); keep the
  // fit inside the syntax range rather than letting an outlier distort it.
  if wq < 0L {
    wq = 0L
  }
  if wq > 127L {
    wq = 127L
  }
  let oq = h264_enc_div_round(sd * scale - wq * ss, n * scale)
  // `§412`: the fit yields a *sample-domain* offset, but the bitstream entry
  // is an `int8` in every bit depth — FFmpeg `h264_parse.c:67` rejects
  // anything outside -128..127 and applies it in sample domain directly, and
  // this decoder mirrors that by scaling it `2^(bit_depth-8)` on the way in.
  // So divide by the sample scale here and keep the syntax range.
  let sample_scale : Int64 = (1L : Int64) << (bit_depth - 8)
  let mut off = if sample_scale > 1L {
    h264_enc_div_round(oq, sample_scale).to_int()
  } else {
    oq.to_int()
  }
  if off < -128 {
    off = -128
  }
  if off > 127 {
    off = 127
  }
  // `§413` benefit gate: the least-squares fit is a *global* model, so on
  // mostly-static content with a few strong edges it is numerically
  // meaningless (a measured moving-box fit landed at w=29/o=13 and made the
  // whole-picture SAD 164% of the plain prediction; a chroma gradient's
  // half-pixel shift fit an offset of +1/+2 that had a marginal SAD gain
  // under the zero-MV fit but turned every exactly-matching static block
  // into a ±1 residual — 2.2x the P-picture bytes). Keep the fitted pair
  // only when the integer-rounded weighted prediction — exactly the
  // transform `h264_weight_rect` applies — cuts the visible-area SAD by at
  // least a quarter; only genuine global fades/gains clear that bar.
  // Otherwise return the neutral pair (the table still rides the slice
  // header, but as the identity transform).
  let wi = wq.to_int()
  if wi == scale.to_int() && off == 0 {
    return (wi, off)
  }
  let off2 = (off << (bit_depth - 8 + denom)).to_int64() +
    ((1L : Int64) << (denom - 1))
  let mut sad_plain : Int64 = 0L
  let mut sad_weighted : Int64 = 0L
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let d = dst[y * dst_stride + x]
      let s = src[y * src_stride + x]
      let dp = d - s
      sad_plain = sad_plain + (if dp < 0 { -dp } else { dp }).to_int64()
      let pred = ((s.to_int64() * wq + off2) >> denom).to_int()
      let dw = d - pred
      sad_weighted = sad_weighted + (if dw < 0 { -dw } else { dw }).to_int64()
    }
  }
  if sad_plain <= 0L || sad_weighted * 4L >= sad_plain * 3L {
    return (scale.to_int(), 0)
  }
  (wi, off)
}

///|
/// Fit this picture's single-reference P weight table (`weightp`): one luma
/// entry (L0 index 0) and one chroma entry per plane, all at
/// `log2_weight_denom = 5` (the denominator x264's 8-bit `--weightp` uses).
/// `use_weight` / `use_weight_chroma` are set exactly when a fitted value
/// leaves the neutral table, which is the same gate the decoder applies.
fn h264_enc_fit_p_weight(
  pwt : H264PredWeight,
  src_y : Array[Int32],
  ref_y : Array[Int32],
  src_u : Array[Int32],
  ref_u : Array[Int32],
  src_v : Array[Int32],
  ref_v : Array[Int32],
  ystride : Int32,
  cstride : Int32,
  width : Int32,
  height : Int32,
  bit_depth~ : Int32 = 8,
  /// `§420`: chroma plane rows (h/2 at 4:2:0, h at 4:2:2).
  chroma_h~ : Int32 = height / 2,
) -> Unit {
  pwt.use_weight = 0
  pwt.use_weight_chroma = 0
  h264_enc_fit_list_weight(
    pwt,
    src_y,
    ref_y,
    src_u,
    ref_u,
    src_v,
    ref_v,
    ystride,
    cstride,
    width,
    height,
    bit_depth~,
    chroma_h~,
  )
}

///|
/// `§434`: fit both B lists against the same source frame — L0 from the
/// past reference, L1 from the future one. The benefit gate in
/// `h264_enc_plane_weight` keeps either list neutral when a fade model does
/// not help, so a static sequence still codes a neutral (but present) table.
fn h264_enc_fit_b_weight(
  pwt : H264PredWeight,
  src_y : Array[Int32],
  l0_y : Array[Int32],
  l1_y : Array[Int32],
  src_u : Array[Int32],
  l0_u : Array[Int32],
  l1_u : Array[Int32],
  src_v : Array[Int32],
  l0_v : Array[Int32],
  l1_v : Array[Int32],
  ystride : Int32,
  cstride : Int32,
  width : Int32,
  height : Int32,
  bit_depth~ : Int32 = 8,
  chroma_h~ : Int32 = height / 2,
) -> Unit {
  pwt.use_weight = 0
  pwt.use_weight_chroma = 0
  h264_enc_fit_list_weight(
    pwt,
    src_y,
    l0_y,
    src_u,
    l0_u,
    src_v,
    l0_v,
    ystride,
    cstride,
    width,
    height,
    bit_depth~,
    chroma_h~,
    list=0,
  )
  h264_enc_fit_list_weight(
    pwt,
    src_y,
    l1_y,
    src_u,
    l1_u,
    src_v,
    l1_v,
    ystride,
    cstride,
    width,
    height,
    bit_depth~,
    chroma_h~,
    list=1,
  )
}

///|
/// Fit one list's single-reference weight entry (`§434`): the same
/// least-squares model as `§410`, but writing into a caller-chosen list so
/// B pictures can fit L0 and L1 independently. Denominators are shared by
/// both lists in the syntax, so they are (re)written to `5` here.
fn h264_enc_fit_list_weight(
  pwt : H264PredWeight,
  src_y : Array[Int32],
  ref_y : Array[Int32],
  src_u : Array[Int32],
  ref_u : Array[Int32],
  src_v : Array[Int32],
  ref_v : Array[Int32],
  ystride : Int32,
  cstride : Int32,
  width : Int32,
  height : Int32,
  bit_depth~ : Int32 = 8,
  chroma_h~ : Int32 = height / 2,
  list~ : Int32 = 0,
) -> Unit {
  let denom = 5
  let unit = 1 << denom
  pwt.luma_log2_weight_denom = denom
  pwt.chroma_log2_weight_denom = denom
  let (lw, lo) = h264_enc_plane_weight(
    src_y,
    ystride,
    ref_y,
    ystride,
    width,
    height,
    denom,
    bit_depth~,
  )
  let luma_w = if list == 0 { pwt.luma_weight_l0 } else { pwt.luma_weight_l1 }
  let luma_o = if list == 0 { pwt.luma_offset_l0 } else { pwt.luma_offset_l1 }
  luma_w[0] = lw
  luma_o[0] = lo
  if lw != unit || lo != 0 {
    pwt.use_weight = 1
  }
  let cw = width / 2
  let ch = chroma_h
  let (uw, uo) = h264_enc_plane_weight(
    src_u,
    cstride,
    ref_u,
    cstride,
    cw,
    ch,
    denom,
    bit_depth~,
  )
  let (vw, vo) = h264_enc_plane_weight(
    src_v,
    cstride,
    ref_v,
    cstride,
    cw,
    ch,
    denom,
    bit_depth~,
  )
  let chroma_w = if list == 0 {
    pwt.chroma_weight_l0
  } else {
    pwt.chroma_weight_l1
  }
  let chroma_o = if list == 0 {
    pwt.chroma_offset_l0
  } else {
    pwt.chroma_offset_l1
  }
  chroma_w[0][0] = uw
  chroma_o[0][0] = uo
  chroma_w[0][1] = vw
  chroma_o[0][1] = vo
  if uw != unit || uo != 0 || vw != unit || vo != 0 {
    pwt.use_weight_chroma = 1
  }
}

///|
/// `§434`: the `(weight, offset, log2_denom)` triple a B prediction sample
/// uses, mirroring `h264_b_compensate` exactly. The offset is scaled from
/// the syntax `int8` into sample domain by `2^(bit_depth-8)`. Plane 0 is
/// luma, 1/2 are Cb/Cr.
fn h264_enc_b_weight_params(
  pwt : H264PredWeight,
  list : Int32,
  refi : Int32,
  plane : Int32,
  bit_depth~ : Int32 = 8,
) -> (Int32, Int32, Int32) {
  let denom = if plane == 0 {
    pwt.luma_log2_weight_denom
  } else {
    pwt.chroma_log2_weight_denom
  }
  let w = if list == 0 {
    if plane == 0 {
      pwt.luma_weight_l0[refi]
    } else {
      pwt.chroma_weight_l0[refi][plane - 1]
    }
  } else if plane == 0 {
    pwt.luma_weight_l1[refi]
  } else {
    pwt.chroma_weight_l1[refi][plane - 1]
  }
  let o = if list == 0 {
    if plane == 0 {
      pwt.luma_offset_l0[refi]
    } else {
      pwt.chroma_offset_l0[refi][plane - 1]
    }
  } else if plane == 0 {
    pwt.luma_offset_l1[refi]
  } else {
    pwt.chroma_offset_l1[refi][plane - 1]
  }
  (w, o << (bit_depth - 8), denom)
}

///|
/// Write `pred_weight_table()` for a B slice — the two denominators,
/// then L0's and L1's per-reference luma flag/pair and single chroma
/// flag/pairs. FFmpeg's parser (`h264_slice.c:252-330`) reads both lists
/// back-to-back for `weighted_bipred_idc == 1`; this must sit after the two
/// `ref_pic_list_modification` flags and before the dec-ref-pic-marking.
/// Each list has exactly one active reference in the encoder, so only
/// entry 0 may carry a non-neutral pair.
fn h264_enc_put_bwt(
  r : H264Rbsp,
  pwt : H264PredWeight,
  nrefs0~ : Int32 = 1,
) -> Unit {
  let luma_denom = pwt.luma_log2_weight_denom
  let chroma_denom = pwt.chroma_log2_weight_denom
  let luma_unit = 1 << luma_denom
  let chroma_unit = 1 << chroma_denom
  r.put_ue(luma_denom)
  r.put_ue(chroma_denom)
  for list = 0; list < 2; list = list + 1 {
    let nrefs = if list == 0 { nrefs0 } else { 1 }
    let lw = if list == 0 { pwt.luma_weight_l0 } else { pwt.luma_weight_l1 }
    let lo = if list == 0 { pwt.luma_offset_l0 } else { pwt.luma_offset_l1 }
    let cw = if list == 0 { pwt.chroma_weight_l0 } else { pwt.chroma_weight_l1 }
    let co = if list == 0 { pwt.chroma_offset_l0 } else { pwt.chroma_offset_l1 }
    for i = 0; i < nrefs; i = i + 1 {
      if lw[i] != luma_unit || lo[i] != 0 {
        r.put_bit(1)
        r.put_se(lw[i])
        r.put_se(lo[i])
      } else {
        r.put_bit(0)
      }
      if cw[i][0] != chroma_unit ||
        co[i][0] != 0 ||
        cw[i][1] != chroma_unit ||
        co[i][1] != 0 {
        r.put_bit(1)
        r.put_se(cw[i][0])
        r.put_se(co[i][0])
        r.put_se(cw[i][1])
        r.put_se(co[i][1])
      } else {
        r.put_bit(0)
      }
    }
  }
}

///|
/// Write `pred_weight_table()` for a P slice with one L0 reference
/// (`ff_h264_pred_weight_table`'s syntax, h264_slice.c): both
/// `log2_weight_denom` values, then the per-reference luma flag/pair and
/// the single chroma flag covering the two chroma components. The caller
/// emits this between `ref_pic_list_modification()` and
/// `dec_ref_pic_marking()`, the order FFmpeg's own parser expects
/// (h264_slice.c:1841 reads the table before h264_slice.c:1853).
fn h264_enc_put_pwt(
  r : H264Rbsp,
  pwt : H264PredWeight,
  nrefs~ : Int32 = 1,
) -> Unit {
  let luma_denom = pwt.luma_log2_weight_denom
  let chroma_denom = pwt.chroma_log2_weight_denom
  let luma_unit = 1 << luma_denom
  let chroma_unit = 1 << chroma_denom
  r.put_ue(luma_denom)
  r.put_ue(chroma_denom)
  // `§415`: one entry per active L0 reference, **interleaved** exactly as
  // the decoder's `pred_weight_table` loop reads it (per reference: the
  // luma flag/pair, then the single chroma flag and its pairs). The fit
  // fills entry 0; entries 1.. carry the neutral pair, so their flags
  // stay 0 and the decoder derives `2^denom / 0` itself.
  for i = 0; i < nrefs; i = i + 1 {
    let lw = pwt.luma_weight_l0[i]
    let lo = pwt.luma_offset_l0[i]
    if lw != luma_unit || lo != 0 {
      r.put_bit(1)
      r.put_se(lw)
      r.put_se(lo)
    } else {
      r.put_bit(0)
    }
    let uw = pwt.chroma_weight_l0[i][0]
    let uo = pwt.chroma_offset_l0[i][0]
    let vw = pwt.chroma_weight_l0[i][1]
    let vo = pwt.chroma_offset_l0[i][1]
    if uw != chroma_unit || uo != 0 || vw != chroma_unit || vo != 0 {
      r.put_bit(1)
      r.put_se(uw)
      r.put_se(uo)
      r.put_se(vw)
      r.put_se(vo)
    } else {
      r.put_bit(0)
    }
  }
}

///|
/// Round-half-away-from-zero integer division (`Int64`), the rounding the
/// PWT weights use when a rational fit lands between two code words.
fn h264_enc_div_round(num : Int64, den : Int64) -> Int64 {
  if den == 0L {
    return 0L
  }
  if den < 0L {
    return h264_enc_div_round(-num, -den)
  }
  if num >= 0L {
    (num + den / 2L) / den
  } else {
    -((-num + den / 2L) / den)
  }
}
