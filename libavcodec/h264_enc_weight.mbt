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
  (wq.to_int(), off)
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
) -> Unit {
  let denom = 5
  let unit = 1 << denom
  pwt.luma_log2_weight_denom = denom
  pwt.chroma_log2_weight_denom = denom
  let (lw, lo) = h264_enc_plane_weight(
    src_y, ystride, ref_y, ystride, width, height, denom, bit_depth~,
  )
  pwt.luma_weight_l0[0] = lw
  pwt.luma_offset_l0[0] = lo
  pwt.use_weight = if lw != unit || lo != 0 { 1 } else { 0 }
  let cw = width / 2
  let ch = height / 2
  let (uw, uo) = h264_enc_plane_weight(
    src_u, cstride, ref_u, cstride, cw, ch, denom, bit_depth~,
  )
  let (vw, vo) = h264_enc_plane_weight(
    src_v, cstride, ref_v, cstride, cw, ch, denom, bit_depth~,
  )
  pwt.chroma_weight_l0[0][0] = uw
  pwt.chroma_offset_l0[0][0] = uo
  pwt.chroma_weight_l0[0][1] = vw
  pwt.chroma_offset_l0[0][1] = vo
  pwt.use_weight_chroma = if uw != unit || uo != 0 || vw != unit || vo != 0 {
    1
  } else {
    0
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
fn h264_enc_put_pwt(r : H264Rbsp, pwt : H264PredWeight) -> Unit {
  let luma_denom = pwt.luma_log2_weight_denom
  let chroma_denom = pwt.chroma_log2_weight_denom
  let luma_unit = 1 << luma_denom
  let chroma_unit = 1 << chroma_denom
  r.put_ue(luma_denom)
  r.put_ue(chroma_denom)
  let lw = pwt.luma_weight_l0[0]
  let lo = pwt.luma_offset_l0[0]
  if lw != luma_unit || lo != 0 {
    r.put_bit(1)
    r.put_se(lw)
    r.put_se(lo)
  } else {
    r.put_bit(0)
  }
  let uw = pwt.chroma_weight_l0[0][0]
  let uo = pwt.chroma_offset_l0[0][0]
  let vw = pwt.chroma_weight_l0[0][1]
  let vo = pwt.chroma_offset_l0[0][1]
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
