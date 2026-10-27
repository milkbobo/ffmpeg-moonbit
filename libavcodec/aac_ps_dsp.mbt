///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/aacps.c` (Parametric Stereo
/// synthesis: hybrid analysis/synthesis, decorrelation, stereo processing,
/// `ff_ps_apply`) and the float kernels of `aacpsdsp_template.c`, over the
/// tables of `aac_ps_tables.mbt`. Products are computed in Double from the
/// float32 table values; the staged kernel vectors tolerate the resulting
/// last-ulp differences the same way the SBR port does.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// `PS_MAX_SSB` etc. of `aacps.h`.
let ps_qmf_time_slots : Int32 = 32

///|
let ps_max_delay : Int32 = 14

///|
let ps_ap_links : Int32 = 3

///|
let ps_max_ap_delay : Int32 = 5

///|
/// `NR_BANDS[is34]`.
let ps_nr_bands : Array[Int32] = [71, 91]

///|
/// `NR_PAR_BANDS[is34]`.
let ps_nr_par_bands : Array[Int32] = [20, 34]

///|
/// `NR_IPDOPD_BANDS[is34]`.
let ps_nr_ipdopd_bands : Array[Int32] = [11, 17]

///|
/// `DECAY_CUTOFF[is34]`.
let ps_decay_cutoff : Array[Int32] = [10, 32]

///|
/// `NR_ALLPASS_BANDS[is34]`.
let ps_nr_allpass_bands : Array[Int32] = [30, 50]

///|
/// `SHORT_DELAY_BAND[is34]`.
let ps_short_delay_band : Array[Int32] = [42, 62]

///|
/// `PSContext`: all DSP state of one PS instance. Complex buffers keep the
/// C's interleaved layout, flattened: `in_buf[5][44][2]`,
/// `delay[91][46][2]`, `ap_delay[50][3][37][2]`, `Lbuf/Rbuf[91][32][2]`,
/// `H..[2][6][34]`.
pub struct AacPs {
  common : AacPsCommon
  in_buf : Array[Double]
  delay : Array[Double]
  ap_delay : Array[Double]
  peak_decay_nrg : Array[Double]
  power_smooth : Array[Double]
  peak_decay_diff_smooth : Array[Double]
  h11 : Array[Double]
  h12 : Array[Double]
  h21 : Array[Double]
  h22 : Array[Double]
  lbuf : Array[Double]
  rbuf : Array[Double]
  opd_hist : Array[Int32]
  ipd_hist : Array[Int32]
}

///|
/// Zero-initialized `PSContext` (the C's calloc + `ff_ps_ctx_init`).
fn aac_ps_new() -> AacPs {
  {
    common: aac_ps_new_common(),
    in_buf: Array::make(5 * 44 * 2, 0.0),
    delay: Array::make(91 * (32 + 14) * 2, 0.0),
    ap_delay: Array::make(50 * 3 * (32 + 5) * 2, 0.0),
    peak_decay_nrg: Array::make(34, 0.0),
    power_smooth: Array::make(34, 0.0),
    peak_decay_diff_smooth: Array::make(34, 0.0),
    h11: Array::make(2 * 6 * 34, 0.0),
    h12: Array::make(2 * 6 * 34, 0.0),
    h21: Array::make(2 * 6 * 34, 0.0),
    h22: Array::make(2 * 6 * 34, 0.0),
    lbuf: Array::make(91 * 32 * 2, 0.0),
    rbuf: Array::make(91 * 32 * 2, 0.0),
    opd_hist: Array::make(34, 0),
    ipd_hist: Array::make(34, 0),
  }
}

///|
/// `ps_hybrid_analysis_c` for one time slot: `dst` receives `n_bands`
/// outputs at `dst_base + q * dst_step` (complex interleaved). The input
/// window starts at complex element `win` of `in_buf`.
fn ps_hybrid_analysis_slot(
  dst : Array[Double],
  dst_base : Int32,
  dst_step : Int32,
  in_buf : Array[Double],
  win : Int32,
  filt : Array[Double],
  n_bands : Int32,
) -> Unit {
  let w6re = in_buf[(win + 6) * 2]
  let w6im = in_buf[(win + 6) * 2 + 1]
  let inre0 : Array[Double] = Array::make(6, 0.0)
  let inre1 : Array[Double] = Array::make(6, 0.0)
  let inim0 : Array[Double] = Array::make(6, 0.0)
  let inim1 : Array[Double] = Array::make(6, 0.0)
  for j in 0..<6 {
    inre0[j] = in_buf[(win + j) * 2] + in_buf[(win + 12 - j) * 2]
    inre1[j] = in_buf[(win + j) * 2 + 1] - in_buf[(win + 12 - j) * 2 + 1]
    inim0[j] = in_buf[(win + j) * 2 + 1] + in_buf[(win + 12 - j) * 2 + 1]
    inim1[j] = in_buf[(win + j) * 2] - in_buf[(win + 12 - j) * 2]
  }
  for q in 0..<n_bands {
    let f6 = filt[(q * 7 + 6) * 2]
    let mut sum_re = f6 * w6re
    let mut sum_im = f6 * w6im
    for j in 0..<6 {
      let fr = filt[(q * 7 + j) * 2]
      let fi = filt[(q * 7 + j) * 2 + 1]
      sum_re = sum_re + (fr * inre0[j] - fi * inre1[j])
      sum_im = sum_im + (fr * inim0[j] + fi * inim1[j])
    }
    let d = dst_base + q * dst_step
    dst[d] = sum_re
    dst[d + 1] = sum_im
  }
}

///|
/// `hybrid6_cx`: subband 0 into 6 hybrid bands via 8 output rows of
/// `f20_0_8`, with the C's temp-to-band mapping.
fn AacPs::hybrid6_cx(self : AacPs, len : Int32) -> Unit {
  let temp : Array[Double] = Array::make(8 * 2, 0.0)
  for i in 0..<len {
    ps_hybrid_analysis_slot(temp, 0, 2, self.in_buf, i, ps_f20_0_8, 8)
    for c in 0..<2 {
      self.lbuf[(0 * 32 + i) * 2 + c] = temp[6 * 2 + c]
      self.lbuf[(1 * 32 + i) * 2 + c] = temp[7 * 2 + c]
      self.lbuf[(2 * 32 + i) * 2 + c] = temp[0 * 2 + c]
      self.lbuf[(3 * 32 + i) * 2 + c] = temp[1 * 2 + c]
      self.lbuf[(4 * 32 + i) * 2 + c] = temp[2 * 2 + c] + temp[5 * 2 + c]
      self.lbuf[(5 * 32 + i) * 2 + c] = temp[3 * 2 + c] + temp[4 * 2 + c]
    }
  }
}

///|
/// `hybrid4_8_12_cx`: subband `row` into `n` hybrid bands starting at
/// `band_lo` (stride 32 slots per band).
fn AacPs::hybrid4_8_12_cx(
  self : AacPs,
  row : Int32,
  band_lo : Int32,
  filt : Array[Double],
  n : Int32,
  len : Int32,
) -> Unit {
  for i in 0..<len {
    ps_hybrid_analysis_slot(
      self.lbuf,
      (band_lo * 32 + i) * 2,
      64,
      self.in_buf,
      row * 44 + i,
      filt,
      n,
    )
  }
}

///|
/// `hybrid2_re`: subband `row` split symmetrically into two hybrid bands
/// at `band_lo` (`reverse` swaps which output gets the sum).
fn AacPs::hybrid2_re(
  self : AacPs,
  row : Int32,
  band_lo : Int32,
  reverse : Bool,
  len : Int32,
) -> Unit {
  // g1_Q2 is 7 real taps, not complex pairs.
  let g = ps_g1_q2
  for i in 0..<len {
    let win = row * 44 + i
    let re_in = g[6] * self.in_buf[(win + 6) * 2]
    let im_in = g[6] * self.in_buf[(win + 6) * 2 + 1]
    let mut re_op = 0.0
    let mut im_op = 0.0
    let mut j = 0
    while j <= 4 {
      let fj = g[j + 1]
      re_op = re_op +
        fj *
        (self.in_buf[(win + j + 1) * 2] + self.in_buf[(win + 12 - j - 1) * 2])
      im_op = im_op +
        fj *
        (
          self.in_buf[(win + j + 1) * 2 + 1] +
          self.in_buf[(win + 12 - j - 1) * 2 + 1]
        )
      j = j + 2
    }
    let b0 = if reverse { 1 } else { 0 }
    let b1 = 1 - b0
    self.lbuf[((band_lo + b0) * 32 + i) * 2] = re_in + re_op
    self.lbuf[((band_lo + b0) * 32 + i) * 2 + 1] = im_in + im_op
    self.lbuf[((band_lo + b1) * 32 + i) * 2] = re_in - re_op
    self.lbuf[((band_lo + b1) * 32 + i) * 2 + 1] = im_in - im_op
  }
}

///|
/// `ps_hybrid_analysis_ileave_c`: QMF bands `i_start..63` pass through to
/// hybrid bands `base + i` of `Lbuf`.
fn AacPs::hybrid_analysis_ileave(
  self : AacPs,
  x : Array[Double],
  base : Int32,
  i_start : Int32,
  len : Int32,
) -> Unit {
  for i in i_start..<64 {
    for j in 0..<len {
      // L[0][j][i] = x[c*38*64 + j*64 + i] with c the re/im plane.
      self.lbuf[((base + i) * 32 + j) * 2] = x[j * 64 + i]
      self.lbuf[((base + i) * 32 + j) * 2 + 1] = x[38 * 64 + j * 64 + i]
    }
  }
}

///|
/// `hybrid_analysis` (`x` is the SBR X buffer, channel 0 block of
/// `x_qmf`).
fn AacPs::hybrid_analysis(
  self : AacPs,
  x : Array[Double],
  is34 : Bool,
  len : Int32,
) -> Unit {
  for i in 0..<5 {
    for j in 0..<38 {
      self.in_buf[(i * 44 + j + 6) * 2] = x[j * 64 + i]
      self.in_buf[(i * 44 + j + 6) * 2 + 1] = x[38 * 64 + j * 64 + i]
    }
  }
  if is34 {
    self.hybrid4_8_12_cx(0, 0, ps_f34_0_12, 12, len)
    self.hybrid4_8_12_cx(1, 12, ps_f34_1_8, 8, len)
    self.hybrid4_8_12_cx(2, 20, ps_f34_2_4, 4, len)
    self.hybrid4_8_12_cx(3, 24, ps_f34_2_4, 4, len)
    self.hybrid4_8_12_cx(4, 28, ps_f34_2_4, 4, len)
    self.hybrid_analysis_ileave(x, 27, 5, len)
  } else {
    self.hybrid6_cx(len)
    self.hybrid2_re(1, 6, true, len)
    self.hybrid2_re(2, 8, false, len)
    self.hybrid_analysis_ileave(x, 7, 3, len)
  }
  // Update in_buf: keep the last 6 samples as history.
  for i in 0..<5 {
    for k in 0..<6 {
      self.in_buf[(i * 44 + k) * 2] = self.in_buf[(i * 44 + 32 + k) * 2]
      self.in_buf[(i * 44 + k) * 2 + 1] = self.in_buf[(i * 44 + 32 + k) * 2 + 1]
    }
  }
}

///|
/// `ps_hybrid_synthesis_deint_c`: hybrid bands `base + i` (i from
/// `i_start`) fold back into QMF bands `i` of channel block `ch_off`.
fn ps_hybrid_synthesis_deint(
  x : Array[Double],
  ch_off : Int32,
  buf : Array[Double],
  base : Int32,
  i_start : Int32,
  len : Int32,
) -> Unit {
  for i in i_start..<64 {
    for n in 0..<len {
      x[ch_off + n * 64 + i] = buf[((base + i) * 32 + n) * 2]
      x[ch_off + 38 * 64 + n * 64 + i] = buf[((base + i) * 32 + n) * 2 + 1]
    }
  }
}

///|
/// `hybrid_synthesis` for one channel block of `x`.
fn ps_hybrid_synthesis(
  x : Array[Double],
  ch_off : Int32,
  buf : Array[Double],
  is34 : Bool,
  len : Int32,
) -> Unit {
  if is34 {
    for n in 0..<len {
      for k in 0..<5 {
        x[ch_off + n * 64 + k] = 0.0
        x[ch_off + 38 * 64 + n * 64 + k] = 0.0
      }
      for i in 0..<12 {
        x[ch_off + n * 64 + 0] = x[ch_off + n * 64 + 0] + buf[(i * 32 + n) * 2]
        x[ch_off + 38 * 64 + n * 64 + 0] = x[ch_off + 38 * 64 + n * 64 + 0] +
          buf[(i * 32 + n) * 2 + 1]
      }
      for i in 12..<20 {
        x[ch_off + n * 64 + 1] = x[ch_off + n * 64 + 1] + buf[(i * 32 + n) * 2]
        x[ch_off + 38 * 64 + n * 64 + 1] = x[ch_off + 38 * 64 + n * 64 + 1] +
          buf[(i * 32 + n) * 2 + 1]
      }
      for g in 0..<3 {
        for i in 0..<4 {
          let src = ((20 + g * 4 + i) * 32 + n) * 2
          let b = 2 + g
          x[ch_off + n * 64 + b] = x[ch_off + n * 64 + b] + buf[src]
          x[ch_off + 38 * 64 + n * 64 + b] = x[ch_off + 38 * 64 + n * 64 + b] +
            buf[src + 1]
        }
      }
    }
    ps_hybrid_synthesis_deint(x, ch_off, buf, 27, 5, len)
  } else {
    for n in 0..<len {
      x[ch_off + n * 64 + 0] = buf[(0 * 32 + n) * 2] +
        buf[(1 * 32 + n) * 2] +
        buf[(2 * 32 + n) * 2] +
        buf[(3 * 32 + n) * 2] +
        buf[(4 * 32 + n) * 2] +
        buf[(5 * 32 + n) * 2]
      x[ch_off + 38 * 64 + n * 64 + 0] = buf[(0 * 32 + n) * 2 + 1] +
        buf[(1 * 32 + n) * 2 + 1] +
        buf[(2 * 32 + n) * 2 + 1] +
        buf[(3 * 32 + n) * 2 + 1] +
        buf[(4 * 32 + n) * 2 + 1] +
        buf[(5 * 32 + n) * 2 + 1]
      x[ch_off + n * 64 + 1] = buf[(6 * 32 + n) * 2] + buf[(7 * 32 + n) * 2]
      x[ch_off + 38 * 64 + n * 64 + 1] = buf[(6 * 32 + n) * 2 + 1] +
        buf[(7 * 32 + n) * 2 + 1]
      x[ch_off + n * 64 + 2] = buf[(8 * 32 + n) * 2] + buf[(9 * 32 + n) * 2]
      x[ch_off + 38 * 64 + n * 64 + 2] = buf[(8 * 32 + n) * 2 + 1] +
        buf[(9 * 32 + n) * 2 + 1]
    }
    ps_hybrid_synthesis_deint(x, ch_off, buf, 7, 3, len)
  }
}

///|
/// `ps_add_squares_c`: accumulate `re^2 + im^2` into a power row.
fn ps_add_squares(
  dst : Array[Double],
  dst_off : Int32,
  buf : Array[Double],
  off : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst[dst_off + i] = dst[dst_off + i] +
      (
        buf[(off + i) * 2] * buf[(off + i) * 2] +
        buf[(off + i) * 2 + 1] * buf[(off + i) * 2 + 1]
      )
  }
}

///|
/// `ps_mul_pair_single_c`.
fn ps_mul_pair_single(
  dst : Array[Double],
  dst_off : Int32,
  delay : Array[Double],
  src_off : Int32,
  gain : Array[Double],
  gain_off : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst[(dst_off + i) * 2] = delay[(src_off + i) * 2] * gain[gain_off + i]
    dst[(dst_off + i) * 2 + 1] = delay[(src_off + i) * 2 + 1] *
      gain[gain_off + i]
  }
}

///|
/// `ps_decorrelate_c` for one hybrid band.
fn ps_decorrelate(
  out : Array[Double],
  out_off : Int32,
  delay : Array[Double],
  delay_row : Int32,
  ap : Array[Double],
  ap_row : Int32,
  phi_re : Double,
  phi_im : Double,
  q_fract_off : Int32,
  gain : Array[Double],
  gain_off : Int32,
  g_decay_slope : Double,
  len : Int32,
) -> Unit {
  let a0 = 0.65143905753106
  let a1 = 0.56471812200776
  let a2 = 0.48954165955695
  let ag : Array[Double] = [
    a0 * g_decay_slope,
    a1 * g_decay_slope,
    a2 * g_decay_slope,
  ]
  // delay[k] + PS_MAX_DELAY - 2: slot 12 of this band's 46-slot row.
  let d0 = (delay_row * 46 + 12) * 2
  for n in 0..<len {
    let mut in_re = delay[d0 + n * 2] * phi_re - delay[d0 + n * 2 + 1] * phi_im
    let mut in_im = delay[d0 + n * 2] * phi_im + delay[d0 + n * 2 + 1] * phi_re
    for m in 0..<3 {
      let a_re = ag[m] * in_re
      let a_im = ag[m] * in_im
      let ld_row = (ap_row * 3 + m) * 37 * 2
      let ld = ld_row + (n + 2 - m) * 2
      let ld_re = ap[ld]
      let ld_im = ap[ld + 1]
      let fr_re = ps_q_fract_allpass[q_fract_off + m * 2]
      let fr_im = ps_q_fract_allpass[q_fract_off + m * 2 + 1]
      let apd_re = in_re
      let apd_im = in_im
      in_re = ld_re * fr_re - ld_im * fr_im - a_re
      in_im = ld_re * fr_im + ld_im * fr_re - a_im
      let w = ld_row + (n + 5) * 2
      ap[w] = apd_re + ag[m] * in_re
      ap[w + 1] = apd_im + ag[m] * in_im
    }
    out[(out_off + n) * 2] = gain[gain_off + n] * in_re
    out[(out_off + n) * 2 + 1] = gain[gain_off + n] * in_im
  }
}

///|
/// `decorrelation`.
fn AacPs::decorrelation(self : AacPs, is34 : Bool) -> Unit {
  let is34i = if is34 { 1 } else { 0 }
  let nr_bands = ps_nr_bands[is34i]
  let k_to_i = if is34 { ps_k_to_i_34 } else { ps_k_to_i_20 }
  let power : Array[Double] = Array::make(34 * 32, 0.0)
  let transient_gain : Array[Double] = Array::make(34 * 32, 0.0)
  let peak_decay_factor = 0.76592833836465
  let a_smooth = 0.25
  let transient_impact = 1.5
  if is34 != self.common.is34bands_old {
    for i in 0..<self.peak_decay_nrg.length() {
      self.peak_decay_nrg[i] = 0.0
      self.power_smooth[i] = 0.0
      self.peak_decay_diff_smooth[i] = 0.0
    }
    for i in 0..<self.delay.length() {
      self.delay[i] = 0.0
    }
    for i in 0..<self.ap_delay.length() {
      self.ap_delay[i] = 0.0
    }
  }
  for k in 0..<nr_bands {
    let i = k_to_i[k]
    ps_add_squares(power, i * 32, self.lbuf, k * 32, 32)
  }
  // Transient detection.
  for i in 0..<ps_nr_par_bands[is34i] {
    for n in 0..<32 {
      let decayed_peak = peak_decay_factor * self.peak_decay_nrg[i]
      let p = power[i * 32 + n]
      self.peak_decay_nrg[i] = if decayed_peak > p { decayed_peak } else { p }
      self.power_smooth[i] = self.power_smooth[i] +
        a_smooth * (p - self.power_smooth[i])
      self.peak_decay_diff_smooth[i] = self.peak_decay_diff_smooth[i] +
        a_smooth * (self.peak_decay_nrg[i] - p - self.peak_decay_diff_smooth[i])
      let denom = transient_impact * self.peak_decay_diff_smooth[i]
      transient_gain[i * 32 + n] = if denom > self.power_smooth[i] {
        self.power_smooth[i] / denom
      } else {
        1.0
      }
    }
  }
  // Decorrelation and transient reduction.
  let mut k = 0
  while k < ps_nr_allpass_bands[is34i] {
    let b = k_to_i[k]
    let cutoff = ps_decay_cutoff[is34i]
    let mut g_decay_slope = 1.0 - 0.05 * (k - cutoff).to_double()
    if g_decay_slope < 0.0 {
      g_decay_slope = 0.0
    }
    if g_decay_slope > 1.0 {
      g_decay_slope = 1.0
    }
    self.shift_delay(k)
    for m in 0..<ps_ap_links {
      self.shift_ap_delay(k, m)
    }
    ps_decorrelate(
      self.rbuf,
      k * 32,
      self.delay,
      k,
      self.ap_delay,
      k,
      ps_phi_fract[is34i * 50 * 2 + k * 2],
      ps_phi_fract[is34i * 50 * 2 + k * 2 + 1],
      (is34i * 50 + k) * 6,
      transient_gain,
      b * 32,
      g_decay_slope,
      32,
    )
    k = k + 1
  }
  while k < ps_short_delay_band[is34i] {
    let i = k_to_i[k]
    self.shift_delay(k)
    ps_mul_pair_single(
      self.rbuf,
      k * 32,
      self.delay,
      k * 46 + 0,
      transient_gain,
      i * 32,
      32,
    )
    k = k + 1
  }
  while k < nr_bands {
    let i = k_to_i[k]
    self.shift_delay(k)
    ps_mul_pair_single(
      self.rbuf,
      k * 32,
      self.delay,
      k * 46 + 13,
      transient_gain,
      i * 32,
      32,
    )
    k = k + 1
  }
}

///|
/// The per-band delay shift: slots 32..45 become 0..13, the current 32
/// slots of `Lbuf` band `k` land at 14..45.
fn AacPs::shift_delay(self : AacPs, k : Int32) -> Unit {
  let row = k * 46 * 2
  for s in 0..<ps_max_delay {
    self.delay[row + s * 2] = self.delay[row + (32 + s) * 2]
    self.delay[row + s * 2 + 1] = self.delay[row + (32 + s) * 2 + 1]
  }
  for s in 0..<ps_qmf_time_slots {
    self.delay[row + (ps_max_delay + s) * 2] = self.lbuf[(k * 32 + s) * 2]
    self.delay[row + (ps_max_delay + s) * 2 + 1] = self.lbuf[(k * 32 + s) * 2 +
      1]
  }
}

///|
/// The per-link all-pass shift: slots 32..36 become 0..4.
fn AacPs::shift_ap_delay(self : AacPs, k : Int32, m : Int32) -> Unit {
  let row = (k * 3 + m) * 37 * 2
  for s in 0..<ps_max_ap_delay {
    self.ap_delay[row + s * 2] = self.ap_delay[row + (32 + s) * 2]
    self.ap_delay[row + s * 2 + 1] = self.ap_delay[row + (32 + s) * 2 + 1]
  }
}

///|
/// `map_idx_10_to_20` (Table 8.46).
fn ps_map_idx_10_to_20(
  par_mapped : Array[Int32],
  off : Int32,
  par : Array[Int32],
  poff : Int32,
  full : Bool,
) -> Unit {
  let b0 = if full { 9 } else { 4 }
  if !full {
    par_mapped[off + 10] = 0
  }
  let mut b = b0
  while b >= 0 {
    par_mapped[off + 2 * b + 1] = par[poff + b]
    par_mapped[off + 2 * b] = par[poff + b]
    b = b - 1
  }
}

///|
/// `map_idx_34_to_20`.
fn ps_map_idx_34_to_20(
  par_mapped : Array[Int32],
  off : Int32,
  par : Array[Int32],
  poff : Int32,
  full : Bool,
) -> Unit {
  par_mapped[off + 0] = (2 * par[poff + 0] + par[poff + 1]) / 3
  par_mapped[off + 1] = (par[poff + 1] + 2 * par[poff + 2]) / 3
  par_mapped[off + 2] = (2 * par[poff + 3] + par[poff + 4]) / 3
  par_mapped[off + 3] = (par[poff + 4] + 2 * par[poff + 5]) / 3
  par_mapped[off + 4] = (par[poff + 6] + par[poff + 7]) / 2
  par_mapped[off + 5] = (par[poff + 8] + par[poff + 9]) / 2
  par_mapped[off + 6] = par[poff + 10]
  par_mapped[off + 7] = par[poff + 11]
  par_mapped[off + 8] = (par[poff + 12] + par[poff + 13]) / 2
  par_mapped[off + 9] = (par[poff + 14] + par[poff + 15]) / 2
  par_mapped[off + 10] = par[poff + 16]
  if full {
    par_mapped[off + 11] = par[poff + 17]
    par_mapped[off + 12] = par[poff + 18]
    par_mapped[off + 13] = par[poff + 19]
    par_mapped[off + 14] = (par[poff + 20] + par[poff + 21]) / 2
    par_mapped[off + 15] = (par[poff + 22] + par[poff + 23]) / 2
    par_mapped[off + 16] = (par[poff + 24] + par[poff + 25]) / 2
    par_mapped[off + 17] = (par[poff + 26] + par[poff + 27]) / 2
    par_mapped[off + 18] = (
        par[poff + 28] + par[poff + 29] + par[poff + 30] + par[poff + 31]
      ) /
      4
    par_mapped[off + 19] = (par[poff + 32] + par[poff + 33]) / 2
  }
}

///|
/// `map_idx_10_to_34`.
fn ps_map_idx_10_to_34(
  par_mapped : Array[Int32],
  off : Int32,
  par : Array[Int32],
  poff : Int32,
  full : Bool,
) -> Unit {
  if full {
    for b in [33, 32, 31, 30, 29, 28] {
      par_mapped[off + b] = par[poff + 9]
    }
    for b in [27, 26, 25, 24] {
      par_mapped[off + b] = par[poff + 8]
    }
    for b in [23, 22, 21, 20] {
      par_mapped[off + b] = par[poff + 7]
    }
    par_mapped[off + 19] = par[poff + 6]
    par_mapped[off + 18] = par[poff + 6]
    par_mapped[off + 17] = par[poff + 5]
    par_mapped[off + 16] = par[poff + 5]
  } else {
    par_mapped[off + 16] = 0
  }
  for b in [15, 14, 13, 12] {
    par_mapped[off + b] = par[poff + 4]
  }
  par_mapped[off + 11] = par[poff + 3]
  par_mapped[off + 10] = par[poff + 3]
  for b in [9, 8, 7, 6] {
    par_mapped[off + b] = par[poff + 2]
  }
  for b in [5, 4, 3] {
    par_mapped[off + b] = par[poff + 1]
  }
  for b in [2, 1, 0] {
    par_mapped[off + b] = par[poff + 0]
  }
}

///|
/// `map_idx_20_to_34`.
fn ps_map_idx_20_to_34(
  par_mapped : Array[Int32],
  off : Int32,
  par : Array[Int32],
  poff : Int32,
  full : Bool,
) -> Unit {
  if full {
    par_mapped[off + 33] = par[poff + 19]
    par_mapped[off + 32] = par[poff + 19]
    par_mapped[off + 31] = par[poff + 18]
    par_mapped[off + 30] = par[poff + 18]
    par_mapped[off + 29] = par[poff + 18]
    par_mapped[off + 28] = par[poff + 18]
    par_mapped[off + 27] = par[poff + 17]
    par_mapped[off + 26] = par[poff + 17]
    par_mapped[off + 25] = par[poff + 16]
    par_mapped[off + 24] = par[poff + 16]
    par_mapped[off + 23] = par[poff + 15]
    par_mapped[off + 22] = par[poff + 15]
    par_mapped[off + 21] = par[poff + 14]
    par_mapped[off + 20] = par[poff + 14]
    par_mapped[off + 19] = par[poff + 13]
    par_mapped[off + 18] = par[poff + 12]
    par_mapped[off + 17] = par[poff + 11]
  }
  par_mapped[off + 16] = par[poff + 10]
  par_mapped[off + 15] = par[poff + 9]
  par_mapped[off + 14] = par[poff + 9]
  par_mapped[off + 13] = par[poff + 8]
  par_mapped[off + 12] = par[poff + 8]
  par_mapped[off + 11] = par[poff + 7]
  par_mapped[off + 10] = par[poff + 6]
  par_mapped[off + 9] = par[poff + 5]
  par_mapped[off + 8] = par[poff + 5]
  par_mapped[off + 7] = par[poff + 4]
  par_mapped[off + 6] = par[poff + 4]
  par_mapped[off + 5] = par[poff + 3]
  par_mapped[off + 4] = (par[poff + 2] + par[poff + 3]) / 2
  par_mapped[off + 3] = par[poff + 2]
  par_mapped[off + 2] = par[poff + 1]
  par_mapped[off + 1] = (par[poff + 0] + par[poff + 1]) / 2
  par_mapped[off + 0] = par[poff + 0]
}

///|
/// `map_val_34_to_20` on one H coefficient row.
fn ps_map_val_34_to_20(par : Array[Double], off : Int32) -> Unit {
  par[off + 0] = (2.0 * par[off + 0] + par[off + 1]) * 0.33333333
  par[off + 1] = (par[off + 1] + 2.0 * par[off + 2]) * 0.33333333
  par[off + 2] = (2.0 * par[off + 3] + par[off + 4]) * 0.33333333
  par[off + 3] = (par[off + 4] + 2.0 * par[off + 5]) * 0.33333333
  par[off + 4] = (par[off + 6] + par[off + 7]) * 0.5
  par[off + 5] = (par[off + 8] + par[off + 9]) * 0.5
  par[off + 6] = par[off + 10]
  par[off + 7] = par[off + 11]
  par[off + 8] = (par[off + 12] + par[off + 13]) * 0.5
  par[off + 9] = (par[off + 14] + par[off + 15]) * 0.5
  par[off + 10] = par[off + 16]
  par[off + 11] = par[off + 17]
  par[off + 12] = par[off + 18]
  par[off + 13] = par[off + 19]
  par[off + 14] = (par[off + 20] + par[off + 21]) * 0.5
  par[off + 15] = (par[off + 22] + par[off + 23]) * 0.5
  par[off + 16] = (par[off + 24] + par[off + 25]) * 0.5
  par[off + 17] = (par[off + 26] + par[off + 27]) * 0.5
  par[off + 18] = (
      par[off + 28] + par[off + 29] + par[off + 30] + par[off + 31]
    ) *
    0.25
  par[off + 19] = (par[off + 32] + par[off + 33]) * 0.5
}

///|
/// `map_val_20_to_34` on one H coefficient row.
fn ps_map_val_20_to_34(par : Array[Double], off : Int32) -> Unit {
  par[off + 33] = par[off + 19]
  par[off + 32] = par[off + 19]
  par[off + 31] = par[off + 18]
  par[off + 30] = par[off + 18]
  par[off + 29] = par[off + 18]
  par[off + 28] = par[off + 18]
  par[off + 27] = par[off + 17]
  par[off + 26] = par[off + 17]
  par[off + 25] = par[off + 16]
  par[off + 24] = par[off + 16]
  par[off + 23] = par[off + 15]
  par[off + 22] = par[off + 15]
  par[off + 21] = par[off + 14]
  par[off + 20] = par[off + 14]
  par[off + 19] = par[off + 13]
  par[off + 18] = par[off + 12]
  par[off + 17] = par[off + 11]
  par[off + 16] = par[off + 10]
  par[off + 15] = par[off + 9]
  par[off + 14] = par[off + 9]
  par[off + 13] = par[off + 8]
  par[off + 12] = par[off + 8]
  par[off + 11] = par[off + 7]
  par[off + 10] = par[off + 6]
  par[off + 9] = par[off + 5]
  par[off + 8] = par[off + 5]
  par[off + 7] = par[off + 4]
  par[off + 6] = par[off + 4]
  par[off + 5] = par[off + 3]
  par[off + 4] = (par[off + 2] + par[off + 3]) * 0.5
  par[off + 3] = par[off + 2]
  par[off + 2] = par[off + 1]
  par[off + 1] = (par[off + 0] + par[off + 1]) * 0.5
}

///|
/// `ipdopd_reset`.
fn AacPs::ipdopd_reset(self : AacPs) -> Unit {
  for i in 0..<34 {
    self.opd_hist[i] = 0
    self.ipd_hist[i] = 0
  }
}

///|
/// `remap34` / `remap20`: map the parsed parameter rows onto the current
/// band grid; returns the mapped rows (or `par` itself when the grid
/// already matches, like the C's pointer swap).
fn ps_remap(
  par : Array[Int32],
  num_par : Int32,
  num_env : Int32,
  is34 : Bool,
  full : Bool,
) -> Array[Int32] {
  if !((
      is34 && (num_par == 20 || num_par == 11 || num_par == 10 || num_par == 5)
    ) ||
    (!is34 && (num_par == 34 || num_par == 17 || num_par == 10 || num_par == 5))) {
    return par
  }
  let mapped : Array[Int32] = Array::make(5 * 34, 0)
  for e in 0..<num_env {
    if is34 {
      if num_par == 20 || num_par == 11 {
        ps_map_idx_20_to_34(mapped, e * 34, par, e * 34, full)
      } else {
        // num_par 10 or 5
        ps_map_idx_10_to_34(mapped, e * 34, par, e * 34, full)
      }
    } else if num_par == 34 || num_par == 17 {
      ps_map_idx_34_to_20(mapped, e * 34, par, e * 34, full)
    } else {
      // num_par 10 or 5
      ps_map_idx_10_to_20(mapped, e * 34, par, e * 34, full)
    }
  }
  mapped
}

///|
/// `ps_stereo_interpolate_c` (baseline: real mixing only).
fn ps_stereo_interpolate(
  l : Array[Double],
  l_off : Int32,
  r : Array[Double],
  r_off : Int32,
  h : Array[Double],
  h_step : Array[Double],
  len : Int32,
) -> Unit {
  let mut h0 = h[0]
  let mut h1 = h[1]
  let mut h2 = h[2]
  let mut h3 = h[3]
  let hs0 = h_step[0]
  let hs1 = h_step[1]
  let hs2 = h_step[2]
  let hs3 = h_step[3]
  for n in 0..<len {
    let l_re = l[(l_off + n) * 2]
    let l_im = l[(l_off + n) * 2 + 1]
    let r_re = r[(r_off + n) * 2]
    let r_im = r[(r_off + n) * 2 + 1]
    h0 = h0 + hs0
    h1 = h1 + hs1
    h2 = h2 + hs2
    h3 = h3 + hs3
    l[(l_off + n) * 2] = h0 * l_re + h2 * r_re
    l[(l_off + n) * 2 + 1] = h0 * l_im + h2 * r_im
    r[(r_off + n) * 2] = h1 * l_re + h3 * r_re
    r[(r_off + n) * 2 + 1] = h1 * l_im + h3 * r_im
  }
}

///|
/// `ps_stereo_interpolate_ipdopd_c`.
fn ps_stereo_interpolate_ipdopd(
  l : Array[Double],
  l_off : Int32,
  r : Array[Double],
  r_off : Int32,
  h : Array[Double],
  h_step : Array[Double],
  len : Int32,
) -> Unit {
  let mut h00 = h[0]
  let mut h10 = h[4]
  let mut h01 = h[1]
  let mut h11 = h[5]
  let mut h02 = h[2]
  let mut h12 = h[6]
  let mut h03 = h[3]
  let mut h13 = h[7]
  let hs00 = h_step[0]
  let hs10 = h_step[4]
  let hs01 = h_step[1]
  let hs11 = h_step[5]
  let hs02 = h_step[2]
  let hs12 = h_step[6]
  let hs03 = h_step[3]
  let hs13 = h_step[7]
  for n in 0..<len {
    let l_re = l[(l_off + n) * 2]
    let l_im = l[(l_off + n) * 2 + 1]
    let r_re = r[(r_off + n) * 2]
    let r_im = r[(r_off + n) * 2 + 1]
    h00 = h00 + hs00
    h01 = h01 + hs01
    h02 = h02 + hs02
    h03 = h03 + hs03
    h10 = h10 + hs10
    h11 = h11 + hs11
    h12 = h12 + hs12
    h13 = h13 + hs13
    l[(l_off + n) * 2] = h00 * l_re + h02 * r_re - h10 * l_im - h12 * r_im
    l[(l_off + n) * 2 + 1] = h00 * l_im + h02 * r_im + h10 * l_re + h12 * r_re
    r[(r_off + n) * 2] = h01 * l_re + h03 * r_re - h11 * l_im - h13 * r_im
    r[(r_off + n) * 2 + 1] = h01 * l_im + h03 * r_im + h11 * l_re + h13 * r_re
  }
}

///|
/// `stereo_processing`.
fn AacPs::stereo_processing(self : AacPs, is34 : Bool) -> Unit {
  let ps2 = self.common
  let is34i = if is34 { 1 } else { 0 }
  let k_to_i = if is34 { ps_k_to_i_34 } else { ps_k_to_i_20 }
  let h_lut = if ps2.icc_mode < 3 { ps_ha } else { ps_hb }
  if ps2.num_env_old > 0 {
    for b in 0..<34 {
      for c in 0..<2 {
        self.h11[c * 6 * 34 + b] = self.h11[(c * 6 + ps2.num_env_old) * 34 + b]
        self.h12[c * 6 * 34 + b] = self.h12[(c * 6 + ps2.num_env_old) * 34 + b]
        self.h21[c * 6 * 34 + b] = self.h21[(c * 6 + ps2.num_env_old) * 34 + b]
        self.h22[c * 6 * 34 + b] = self.h22[(c * 6 + ps2.num_env_old) * 34 + b]
      }
    }
  }
  let iid_mapped = ps_remap(
    ps2.iid_par,
    ps2.nr_iid_par,
    ps2.num_env,
    is34,
    true,
  )
  let icc_mapped = ps_remap(
    ps2.icc_par,
    ps2.nr_icc_par,
    ps2.num_env,
    is34,
    true,
  )
  let (ipd_mapped, opd_mapped) = if ps2.enable_ipdopd {
    (
      ps_remap(ps2.ipd_par, ps2.nr_ipdopd_par, ps2.num_env, is34, false),
      ps_remap(ps2.opd_par, ps2.nr_ipdopd_par, ps2.num_env, is34, false),
    )
  } else {
    (ps2.ipd_par, ps2.opd_par)
  }
  if is34 {
    if !ps2.is34bands_old {
      ps_map_val_20_to_34(self.h11, 0)
      ps_map_val_20_to_34(self.h11, 6 * 34)
      ps_map_val_20_to_34(self.h12, 0)
      ps_map_val_20_to_34(self.h12, 6 * 34)
      ps_map_val_20_to_34(self.h21, 0)
      ps_map_val_20_to_34(self.h21, 6 * 34)
      ps_map_val_20_to_34(self.h22, 0)
      ps_map_val_20_to_34(self.h22, 6 * 34)
      self.ipdopd_reset()
    }
  } else if ps2.is34bands_old {
    ps_map_val_34_to_20(self.h11, 0)
    ps_map_val_34_to_20(self.h11, 6 * 34)
    ps_map_val_34_to_20(self.h12, 0)
    ps_map_val_34_to_20(self.h12, 6 * 34)
    ps_map_val_34_to_20(self.h21, 0)
    ps_map_val_34_to_20(self.h21, 6 * 34)
    ps_map_val_34_to_20(self.h22, 0)
    ps_map_val_34_to_20(self.h22, 6 * 34)
    self.ipdopd_reset()
  }
  for e in 0..<ps2.num_env {
    for b in 0..<ps_nr_par_bands[is34i] {
      let idx = iid_mapped[e * 34 + b] + 7 + 23 * ps2.iid_quant
      let icc = icc_mapped[e * 34 + b]
      let mut h11 = h_lut[(idx * 8 + icc) * 4 + 0]
      let mut h12 = h_lut[(idx * 8 + icc) * 4 + 1]
      let mut h21 = h_lut[(idx * 8 + icc) * 4 + 2]
      let mut h22 = h_lut[(idx * 8 + icc) * 4 + 3]
      if ps2.enable_ipdopd && b < ps_nr_ipdopd_bands[is34i] {
        // The smoother runs whenever ipdopd is enabled.
        let opd_idx = self.opd_hist[b] * 8 + opd_mapped[e * 34 + b]
        let ipd_idx = self.ipd_hist[b] * 8 + ipd_mapped[e * 34 + b]
        let opd_re = ps_pd_re_smooth[opd_idx]
        let opd_im = ps_pd_im_smooth[opd_idx]
        let ipd_re = ps_pd_re_smooth[ipd_idx]
        let ipd_im = ps_pd_im_smooth[ipd_idx]
        self.opd_hist[b] = opd_idx & 0x3f
        self.ipd_hist[b] = ipd_idx & 0x3f
        let ipd_adj_re = opd_re * ipd_re + opd_im * ipd_im
        let ipd_adj_im = opd_im * ipd_re - opd_re * ipd_im
        let h11i = h11 * opd_im
        h11 = h11 * opd_re
        let h12i = h12 * ipd_adj_im
        h12 = h12 * ipd_adj_re
        let h21i = h21 * opd_im
        h21 = h21 * opd_re
        let h22i = h22 * ipd_adj_im
        h22 = h22 * ipd_adj_re
        self.h11[(6 + (e + 1)) * 34 + b] = h11i
        self.h12[(6 + (e + 1)) * 34 + b] = h12i
        self.h21[(6 + (e + 1)) * 34 + b] = h21i
        self.h22[(6 + (e + 1)) * 34 + b] = h22i
      }
      self.h11[(e + 1) * 34 + b] = h11
      self.h12[(e + 1) * 34 + b] = h12
      self.h21[(e + 1) * 34 + b] = h21
      self.h22[(e + 1) * 34 + b] = h22
    }
    for k in 0..<ps_nr_bands[is34i] {
      let h : Array[Double] = Array::make(8, 0.0)
      let h_step : Array[Double] = Array::make(8, 0.0)
      let start = ps2.border_position[e]
      let stop = ps2.border_position[e + 1]
      let width = 1.0 /
        (if stop - start != 0 { stop - start } else { 1 }).to_double()
      let b = k_to_i[k]
      h[0] = self.h11[e * 34 + b]
      h[1] = self.h12[e * 34 + b]
      h[2] = self.h21[e * 34 + b]
      h[3] = self.h22[e * 34 + b]
      if ps2.enable_ipdopd {
        let neg = if is34 { k <= 13 && k >= 9 } else { k <= 1 }
        let sign = if neg { -1.0 } else { 1.0 }
        h[4] = sign * self.h11[(6 + e) * 34 + b]
        h[5] = sign * self.h12[(6 + e) * 34 + b]
        h[6] = sign * self.h21[(6 + e) * 34 + b]
        h[7] = sign * self.h22[(6 + e) * 34 + b]
      }
      h_step[0] = (self.h11[(e + 1) * 34 + b] - h[0]) * width
      h_step[1] = (self.h12[(e + 1) * 34 + b] - h[1]) * width
      h_step[2] = (self.h21[(e + 1) * 34 + b] - h[2]) * width
      h_step[3] = (self.h22[(e + 1) * 34 + b] - h[3]) * width
      if ps2.enable_ipdopd {
        h_step[4] = (self.h11[(6 + e + 1) * 34 + b] - h[4]) * width
        h_step[5] = (self.h12[(6 + e + 1) * 34 + b] - h[5]) * width
        h_step[6] = (self.h21[(6 + e + 1) * 34 + b] - h[6]) * width
        h_step[7] = (self.h22[(6 + e + 1) * 34 + b] - h[7]) * width
      }
      if stop != start {
        let off = 1 + start
        if ps2.enable_ipdopd {
          ps_stereo_interpolate_ipdopd(
            self.lbuf,
            k * 32 + off,
            self.rbuf,
            k * 32 + off,
            h,
            h_step,
            stop - start,
          )
        } else {
          ps_stereo_interpolate(
            self.lbuf,
            k * 32 + off,
            self.rbuf,
            k * 32 + off,
            h,
            h_step,
            stop - start,
          )
        }
      }
    }
  }
}

///|
/// `ff_ps_apply` on the SBR X buffer (`x_qmf`): channel 0 is `L`, channel
/// 1 `R`, each `[2][38][64]` with re/im planes (the `X[ch][x][i][k]`
/// layout of `sbr_x_gen`).
fn AacPs::apply(self : AacPs, x : Array[Double], top_qmf : Int32) -> Unit {
  let is34 = self.common.is34bands
  let is34i = if is34 { 1 } else { 0 }
  let nr_bands = ps_nr_bands[is34i]
  let mut top = top_qmf + nr_bands - 64
  if top < 0 {
    top = 0
  }
  if top < nr_bands {
    let lo = top * 46 * 2
    let hi = nr_bands * 46 * 2
    for i in lo..<hi {
      self.delay[i] = 0.0
    }
    if top < ps_nr_allpass_bands[is34i] {
      let alo = top * 3 * 37 * 2
      let ahi = ps_nr_allpass_bands[is34i] * 3 * 37 * 2
      for i in alo..<ahi {
        self.ap_delay[i] = 0.0
      }
    }
  }
  self.hybrid_analysis(x, is34, 32)
  self.decorrelation(is34)
  self.stereo_processing(is34)
  ps_hybrid_synthesis(x, 0, self.lbuf, is34, 32)
  ps_hybrid_synthesis(x, 2 * 38 * 64, self.rbuf, is34, 32)
}
