///|
/// MoonBit port of the DSP half of FFmpeg 9.0.2 AAC SBR (float instance):
/// `aacsbr.c` (sbr_dequant, sbr_hf_inverse_filter, sbr_chirp, sbr_gain_calc,
/// sbr_hf_assemble, make_bands is in aac_sbr.mbt), `sbrdsp.c` kernels and the
/// `aacsbr_template.c` QMF banks / lf_gen / hf_gen / x_gen / mapping /
/// env_estimate / ff_aac_sbr_apply.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C's `av_tx` 64-point half IMDCT is evaluated directly from the
/// `ff_tx_mdct_naive_inv` definition in `libavutil/tx_template.c` (the C
/// goes through an FFT; the naive formula is the same transform). All other
/// float arithmetic runs in Double; frame-level PCM agrees with the C within
/// one s16 LSB on the real-data vectors.

///| Temporary core-input dump hook (probe builds only).

///|
/// `ff_tx_mdct_naive_inv` with `s->len = 64` (the SBR instance length):
/// 64 input floats -> 64 output floats (the non-redundant half of the
/// 128-sample inverse), multiplied by `scale`.
fn aac_sbr_imdct64(
  src : Array[Double],
  src_off : Int32,
  dst : Array[Double],
  dst_off : Int32,
  scale : Double,
) -> Unit {
  // len = s->len >> 1 = 32, len2 = 64, phase = pi / (4*len2)
  let phase = 3.14159265358979323846 / 256.0
  for i in 0..<32 {
    let i_d = phase * (128.0 - 2.0 * i.to_double() - 1.0)
    let i_u = phase * (192.0 + 2.0 * i.to_double() + 1.0)
    let mut sum_d = 0.0
    let mut sum_u = 0.0
    for j in 0..<64 {
      let a = (2 * j + 1).to_double()
      let v = src[src_off + j]
      sum_d = sum_d + @math.cos(a * i_d) * v
      sum_u = sum_u + @math.cos(a * i_u) * v
    }
    dst[dst_off + i] = sum_d * scale
    dst[dst_off + 32 + i] = -sum_u * scale
  }
}

///|
/// `sbr_sum64x5_c`: z[k] = sum of z[k + 64n], n in 0..5, k < 64.
fn aac_sbr_sum64x5(z : Array[Double]) -> Unit {
  for k in 0..<64 {
    z[k] = z[k] + z[k + 64] + z[k + 128] + z[k + 192] + z[k + 256]
  }
}

///|
/// `sbr_qmf_pre_shuffle_c`: packs the 64 folded values at z[0..63] into the
/// 64-float (32 interleaved pair) IMDCT input at z[64..127].
fn aac_sbr_qmf_pre_shuffle(z : Array[Double]) -> Unit {
  z[64] = z[0]
  z[65] = z[1]
  let mut k = 1
  while k < 31 {
    z[64 + 2 * k] = -z[64 - k]
    z[64 + 2 * k + 1] = z[k + 1]
    z[64 + 2 * k + 2] = -z[63 - k]
    z[64 + 2 * k + 3] = z[k + 2]
    k = k + 2
  }
  z[64 + 2 * 31] = -z[64 - 31]
  z[64 + 2 * 31 + 1] = z[31 + 1]
}

///|
/// `sbr_qmf_post_shuffle_c`: w_buf[32][2] from the 64 IMDCT outputs z[0..63].
fn aac_sbr_qmf_post_shuffle(
  w : Array[Double],
  w_off : Int32,
  z : Array[Double],
) -> Unit {
  let mut k = 0
  while k < 32 {
    w[w_off + 2 * k] = -z[63 - k]
    w[w_off + 2 * k + 1] = z[k]
    w[w_off + 2 * k + 2] = -z[62 - k]
    w[w_off + 2 * k + 3] = z[k + 1]
    k = k + 2
  }
}

///|
/// `sbr_neg_odd_64_c`: negate entries 1, 3, 5, ... of a 64-array.
fn aac_sbr_neg_odd_64(x : Array[Double], off : Int32) -> Unit {
  let mut i = 1
  while i < 64 {
    x[off + i] = -x[off + i]
    x[off + i + 2] = -x[off + i + 2]
    i = i + 4
  }
}

///|
/// `sbr_qmf_deint_neg_c` (downsampled synthesis).
fn aac_sbr_qmf_deint_neg(
  v : Array[Double],
  v_off : Int32,
  src : Array[Double],
  s_off : Int32,
) -> Unit {
  for i in 0..<32 {
    v[v_off + i] = src[s_off + 63 - 2 * i]
    v[v_off + 63 - i] = -src[s_off + 63 - 2 * i - 1]
  }
}

///|
/// `sbr_qmf_deint_bfly_c` (synthesis).
fn aac_sbr_qmf_deint_bfly(
  v : Array[Double],
  v_off : Int32,
  src0 : Array[Double],
  s0 : Int32,
  src1 : Array[Double],
  s1 : Int32,
) -> Unit {
  for i in 0..<64 {
    v[v_off + i] = src0[s0 + i] - src1[s1 + 63 - i]
    v[v_off + 127 - i] = src0[s0 + i] + src1[s1 + 63 - i]
  }
}

///|
/// `sbr_sum_square_c` over an interleaved [n][2] run.
fn aac_sbr_sum_square(x : Array[Double], off : Int32, n : Int32) -> Double {
  let mut sum0 = 0.0
  let mut sum1 = 0.0
  let mut i = 0
  while i < n {
    sum0 = sum0 + x[off + 2 * i] * x[off + 2 * i]
    sum1 = sum1 + x[off + 2 * i + 1] * x[off + 2 * i + 1]
    sum0 = sum0 + x[off + 2 * (i + 1)] * x[off + 2 * (i + 1)]
    sum1 = sum1 + x[off + 2 * (i + 1) + 1] * x[off + 2 * (i + 1) + 1]
    i = i + 2
  }
  sum0 + sum1
}

///|
/// `sbr_autocorrelate_c` (faster variant, exact transcription).
fn aac_sbr_autocorrelate(
  x_low : Array[Double],
  x_off : Int32,
  phi : Array[Double],
) -> Unit {
  // x rows: x[off + 2*i + c]; phi[3][2][2] flattened to phi[i*4 + j*2 + c]
  let x0r = x_low[x_off]
  let x0i = x_low[x_off + 1]
  let mut real_sum2 = x0r * x_low[x_off + 4] + x0i * x_low[x_off + 5]
  let mut imag_sum2 = x0r * x_low[x_off + 5] - x0i * x_low[x_off + 4]
  let mut real_sum1 = 0.0
  let mut imag_sum1 = 0.0
  let mut real_sum0 = 0.0
  for i in 1..<38 {
    let ir = x_low[x_off + 2 * i]
    let ii = x_low[x_off + 2 * i + 1]
    let r1r = x_low[x_off + 2 * (i + 1)]
    let r1i = x_low[x_off + 2 * (i + 1) + 1]
    let r2r = x_low[x_off + 2 * (i + 2)]
    let r2i = x_low[x_off + 2 * (i + 2) + 1]
    real_sum0 = real_sum0 + ir * ir + ii * ii
    real_sum1 = real_sum1 + ir * r1r + ii * r1i
    imag_sum1 = imag_sum1 + ir * r1i - ii * r1r
    real_sum2 = real_sum2 + ir * r2r + ii * r2i
    imag_sum2 = imag_sum2 + ir * r2i - ii * r2r
  }
  let x38r = x_low[x_off + 76]
  let x38i = x_low[x_off + 77]
  let x39r = x_low[x_off + 78]
  let x39i = x_low[x_off + 79]
  // Transcribe literally (phi[a][b][c] at a*4 + b*2 + c):
  // phi[2 - 2][1][0] = real_sum2
  phi[0 * 4 + 1 * 2 + 0] = real_sum2
  phi[0 * 4 + 1 * 2 + 1] = imag_sum2
  // phi[2][1][0] = real_sum0 + x0*x0
  phi[2 * 4 + 1 * 2 + 0] = real_sum0 + x0r * x0r + x0i * x0i
  // phi[1][0][0] = real_sum0 + x38*x38
  phi[1 * 4 + 0 * 2 + 0] = real_sum0 + x38r * x38r + x38i * x38i
  // phi[2 - 1][1][0] = real_sum1 + x0*x1
  phi[1 * 4 + 1 * 2 + 0] = real_sum1 +
    x0r * x_low[x_off + 2] +
    x0i * x_low[x_off + 3]
  phi[1 * 4 + 1 * 2 + 1] = imag_sum1 +
    x0r * x_low[x_off + 3] -
    x0i * x_low[x_off + 2]
  // phi[0][0][0] = real_sum1 + x38*x39
  phi[0 * 4 + 0 * 2 + 0] = real_sum1 + x38r * x39r + x38i * x39i
  phi[0 * 4 + 0 * 2 + 1] = imag_sum1 + x38r * x39i - x38i * x39r
}

///|
/// `sbr_hf_gen_c` kernel: one HF band row.
fn aac_sbr_hf_gen_c(
  x_high : Array[Double],
  xh_off : Int32,
  x_low : Array[Double],
  xl_off : Int32,
  alpha0 : Array[Double],
  a0 : Int32,
  alpha1 : Array[Double],
  a1 : Int32,
  bw : Double,
  start : Int32,
  end_ : Int32,
) -> Unit {
  let alpha : Array[Double] = Array::make(4, 0.0)
  alpha[0] = alpha1[a1] * bw * bw
  alpha[1] = alpha1[a1 + 1] * bw * bw
  alpha[2] = alpha0[a0] * bw
  alpha[3] = alpha0[a0 + 1] * bw
  for i in start..<end_ {
    let base = xh_off + 2 * i
    let l0 = xl_off + 2 * (i - 2)
    let l1 = xl_off + 2 * (i - 1)
    let l2 = xl_off + 2 * i
    x_high[base] = x_low[l0] * alpha[0] -
      x_low[l0 + 1] * alpha[1] +
      x_low[l1] * alpha[2] -
      x_low[l1 + 1] * alpha[3] +
      x_low[l2]
    x_high[base + 1] = x_low[l0 + 1] * alpha[0] +
      x_low[l0] * alpha[1] +
      x_low[l1 + 1] * alpha[2] +
      x_low[l1] * alpha[3] +
      x_low[l2 + 1]
  }
}

///|
/// `sbr_hf_g_filt_c`.
fn aac_sbr_hf_g_filt(
  y : Array[Double],
  y_off : Int32,
  x_high : Array[Double],
  row_off : Int32,
  g_filt : Array[Double],
  g_off : Int32,
  m_max : Int32,
  ixh : Int32,
) -> Unit {
  // The C passes X_high + kx, so kernel row m reads absolute row m + kx.
  for m in 0..<m_max {
    y[y_off + 2 * m] = x_high[((row_off + m) * 40 + ixh) * 2] *
      g_filt[g_off + m]
    y[y_off + 2 * m + 1] = x_high[((row_off + m) * 40 + ixh) * 2 + 1] *
      g_filt[g_off + m]
  }
}

///|
/// `sbr_hf_apply_noise` shared kernel (`phi_sign1` flips per band).
fn aac_sbr_hf_apply_noise(
  y : Array[Double],
  y_off : Int32,
  s_m : Array[Double],
  sm_off : Int32,
  q_filt : Array[Double],
  qf_off : Int32,
  noise_in : Int32,
  phi_sign0 : Double,
  phi_sign1_in : Double,
  m_max : Int32,
) -> Unit {
  // The C passes `noise` by value: the kernel's internal advance does not
  // propagate back; the caller bumps it once per time slot.
  let mut noise = noise_in
  let mut phi_sign1 = phi_sign1_in
  for m in 0..<m_max {
    let mut y0 = y[y_off + 2 * m]
    let mut y1 = y[y_off + 2 * m + 1]
    noise = (noise + 1) & 0x1ff
    let sm = s_m[sm_off + m]
    if sm != 0.0 {
      y0 = y0 + sm * phi_sign0
      y1 = y1 + sm * phi_sign1
    } else {
      let nt = aac_sbr_noise_table[noise]
      y0 = y0 + q_filt[qf_off + m] * nt.0
      y1 = y1 + q_filt[qf_off + m] * nt.1
    }
    y[y_off + 2 * m] = y0
    y[y_off + 2 * m + 1] = y1
    phi_sign1 = -phi_sign1
  }
}

///|
/// `exp2fi`: 2^x for integer x, exact.
fn aac_sbr_exp2i(x : Int32) -> Double {
  if x > 128 {
    return 1.0 / 0.0
  }
  @math.pow(2.0, x.to_double())
}

///|
/// `sbr_dequant` (14496-3 sp04 p203).
fn AacSbr::dequant(self : AacSbr, id_aac : Int32) -> Unit {
  let exp2_tab : Array[Double] = [1.0, 1.41421356237309514547]
  if id_aac == aac_id_cpe && self.bs_coupling != 0 {
    let pan_offset = if self.data[0].bs_amp_res != 0 { 12 } else { 24 }
    for e in 1..<=self.data[0].bs_num_env {
      for k in 0..<self.n[self.data[0].bs_freq_res[e]] {
        let q0 = self.data[0].env_facs_q[e * 48 + k]
        let q1 = self.data[1].env_facs_q[e * 48 + k]
        let mut temp1 : Double = 0.0
        let mut temp2 : Double = 0.0
        if self.data[0].bs_amp_res != 0 {
          temp1 = aac_sbr_exp2i(q0 + 7)
          temp2 = aac_sbr_exp2i(pan_offset - q1)
        } else {
          temp1 = aac_sbr_exp2i((q0 >> 1) + 7) * exp2_tab[q0 & 1]
          temp2 = aac_sbr_exp2i((pan_offset - q1) >> 1) *
            exp2_tab[(pan_offset - q1) & 1]
        }
        let mut t1 = temp1
        if t1 > 1.0e20 {
          t1 = 1.0
        }
        let fac = t1 / (1.0 + temp2)
        self.data[0].env_facs[e * 48 + k] = fac
        self.data[1].env_facs[e * 48 + k] = fac * temp2
      }
    }
    for e in 1..<=self.data[0].bs_num_noise {
      for k in 0..<self.n_q {
        let q0 = self.data[0].noise_facs_q[e * 5 + k]
        let q1 = self.data[1].noise_facs_q[e * 5 + k]
        let temp1 = aac_sbr_exp2i(6 - q0 + 1)
        let temp2 = aac_sbr_exp2i(12 - q1)
        let fac = temp1 / (1.0 + temp2)
        self.data[0].noise_facs[e * 5 + k] = fac
        self.data[1].noise_facs[e * 5 + k] = fac * temp2
      }
    }
  } else {
    // SCE or one non-coupled CPE
    for ch in 0..<(if id_aac == aac_id_cpe { 2 } else { 1 }) {
      for e in 1..<=self.data[ch].bs_num_env {
        for k in 0..<self.n[self.data[ch].bs_freq_res[e]] {
          let q = self.data[ch].env_facs_q[e * 48 + k]
          let v : Double = if self.data[ch].bs_amp_res != 0 {
            aac_sbr_exp2i(q + 6)
          } else {
            aac_sbr_exp2i((q >> 1) + 6) * exp2_tab[q & 1]
          }
          if v > 1.0e20 {
            self.data[ch].env_facs[e * 48 + k] = 1.0
          } else {
            self.data[ch].env_facs[e * 48 + k] = v
          }
        }
      }
      for e in 1..<=self.data[ch].bs_num_noise {
        for k in 0..<self.n_q {
          let q = self.data[ch].noise_facs_q[e * 5 + k]
          self.data[ch].noise_facs[e * 5 + k] = aac_sbr_exp2i(6 - q)
        }
      }
    }
  }
}

///|
/// `sbr_hf_inverse_filter` (aacsbr.c float).
fn AacSbr::hf_inverse_filter(self : AacSbr) -> Unit {
  let phi : Array[Double] = Array::make(12, 0.0)
  for k in 0..<self.k[0] {
    aac_sbr_autocorrelate(self.x_low, k * 40 * 2, phi)
    // phi[a][b][c] at a*4 + b*2 + c
    let dk = phi[2 * 4 + 1 * 2] * phi[1 * 4 + 0 * 2] -
      (
        phi[1 * 4 + 1 * 2] * phi[1 * 4 + 1 * 2] +
        phi[1 * 4 + 1 * 2 + 1] * phi[1 * 4 + 1 * 2 + 1]
      ) /
      1.000001
    if dk == 0.0 {
      self.alpha1[k * 2] = 0.0
      self.alpha1[k * 2 + 1] = 0.0
    } else {
      let temp_real = phi[0 * 4 + 0 * 2] * phi[1 * 4 + 1 * 2] -
        phi[0 * 4 + 0 * 2 + 1] * phi[1 * 4 + 1 * 2 + 1] -
        phi[0 * 4 + 1 * 2] * phi[1 * 4 + 0 * 2]
      let temp_im = phi[0 * 4 + 0 * 2] * phi[1 * 4 + 1 * 2 + 1] +
        phi[0 * 4 + 0 * 2 + 1] * phi[1 * 4 + 1 * 2] -
        phi[0 * 4 + 1 * 2 + 1] * phi[1 * 4 + 0 * 2]
      self.alpha1[k * 2] = temp_real / dk
      self.alpha1[k * 2 + 1] = temp_im / dk
    }
    if phi[1 * 4 + 0 * 2] == 0.0 {
      self.alpha0[k * 2] = 0.0
      self.alpha0[k * 2 + 1] = 0.0
    } else {
      let a1r = self.alpha1[k * 2]
      let a1i = self.alpha1[k * 2 + 1]
      let temp_real = phi[0 * 4 + 0 * 2] +
        a1r * phi[1 * 4 + 1 * 2] +
        a1i * phi[1 * 4 + 1 * 2 + 1]
      let temp_im = phi[0 * 4 + 0 * 2 + 1] +
        a1i * phi[1 * 4 + 1 * 2] -
        a1r * phi[1 * 4 + 1 * 2 + 1]
      self.alpha0[k * 2] = -temp_real / phi[1 * 4 + 0 * 2]
      self.alpha0[k * 2 + 1] = -temp_im / phi[1 * 4 + 0 * 2]
    }
    if self.alpha1[k * 2] * self.alpha1[k * 2] +
      self.alpha1[k * 2 + 1] * self.alpha1[k * 2 + 1] >=
      16.0 ||
      self.alpha0[k * 2] * self.alpha0[k * 2] +
      self.alpha0[k * 2 + 1] * self.alpha0[k * 2 + 1] >=
      16.0 {
      self.alpha1[k * 2] = 0.0
      self.alpha1[k * 2 + 1] = 0.0
      self.alpha0[k * 2] = 0.0
      self.alpha0[k * 2 + 1] = 0.0
    }
  }
}

///|
/// `sbr_chirp` (sp04 p214).
fn AacSbr::chirp(self : AacSbr, ch_data : AacSbrData) -> Unit {
  let bw_tab : Array[Double] = [0.0, 0.75, 0.9, 0.98]
  for i in 0..<self.n_q {
    let mut new_bw : Double = if ch_data.bs_invf_mode[0][i] +
      ch_data.bs_invf_mode[1][i] ==
      1 {
      0.6
    } else {
      bw_tab[ch_data.bs_invf_mode[0][i]]
    }
    if new_bw < ch_data.bw_array[i] {
      new_bw = 0.75 * new_bw + 0.25 * ch_data.bw_array[i]
    } else {
      new_bw = 0.90625 * new_bw + 0.09375 * ch_data.bw_array[i]
    }
    ch_data.bw_array[i] = if new_bw < 0.015625 { 0.0 } else { new_bw }
  }
}

///|
/// Analysis QMF Bank (sp04 p206): `sbr_qmf_analysis`. `in_` holds
/// `num_time_slots*64` core samples at offset `in_off`.
fn AacSbr::qmf_analysis(
  self : AacSbr,
  in_ : Array[Double],
  in_off : Int32,
  ch : Int32,
  num_time_slots : Int32,
) -> Unit {
  let d = self.data[ch]
  let x = d.analysis_filterbank_samples
  let z = self.qmf_filter_scratch
  let nb = num_time_slots * 64
  for i in 0..<(320 - 32) {
    x[i] = x[nb + i]
  }
  for i in 0..<nb {
    x[288 + i] = in_[in_off + i]
  }
  for i in 0..<(num_time_slots * 2) {
    let base = i * 32
    // vector_fmul_reverse: dst[i] = src0[i] * src1[len-1-i]
    for k in 0..<320 {
      z[k] = aac_sbr_qmf_window_ds[k] * x[base + 319 - k]
    }
    aac_sbr_sum64x5(z)
    aac_sbr_qmf_pre_shuffle(z)
    aac_sbr_imdct64(z, 64, z, 0, -2.0 * 32768.0)
    // w_buf[buf_idx][i]: flat ((buf*32 + i)*32 + k)*2 + c
    aac_sbr_qmf_post_shuffle(d.w_buf, (d.ypos * 32 + i) * 64, z)
  }
}

///|
/// Synthesis QMF Bank (sp04 p206): `sbr_qmf_synthesis`; writes
/// `num_time_slots*128 >> div` samples into `out` at `out_off`.
fn AacSbr::qmf_synthesis(
  self : AacSbr,
  out : Array[Double],
  out_off : Int32,
  ch : Int32,
  num_time_slots : Int32,
  div : Int32,
) -> Unit {
  let d = self.data[ch]
  let v0 = d.synthesis_filterbank_samples
  let window = if div != 0 {
    aac_sbr_qmf_window_ds
  } else {
    aac_sbr_qmf_window_us
  }
  let step = 128 >> div
  let mut outp = out_off
  let scratch = self.qmf_filter_scratch
  // X view of this channel: sbr->X[ch] is [2][38][64]
  let xch = self.x_qmf
  let xbase = ch * 2 * 38 * 64
  for i in 0..<(num_time_slots * 2) {
    if d.synthesis_filterbank_samples_offset < step {
      let saved_samples = (1280 - 128) >> div
      for k in 0..<saved_samples {
        v0[aac_sbr_synthesis_buf_size - saved_samples + k] = v0[k]
      }
      d.synthesis_filterbank_samples_offset = aac_sbr_synthesis_buf_size -
        saved_samples -
        step
    } else {
      d.synthesis_filterbank_samples_offset = d.synthesis_filterbank_samples_offset -
        step
    }
    let v_off = d.synthesis_filterbank_samples_offset
    if div != 0 {
      let x0 = xbase + (0 * 38 + i) * 64
      let x1 = xbase + (1 * 38 + i) * 64
      for n in 0..<32 {
        xch[x0 + n] = -xch[x0 + n]
        xch[x0 + 32 + n] = xch[x1 + 31 - n]
      }
      aac_sbr_imdct64(xch, x0, scratch, 0, 1.0 / (64.0 * 32768.0))
      aac_sbr_qmf_deint_neg(v0, v_off, scratch, 0)
    } else {
      let x0 = xbase + (0 * 38 + i) * 64
      let x1 = xbase + (1 * 38 + i) * 64
      aac_sbr_neg_odd_64(xch, x1)
      aac_sbr_imdct64(xch, x0, scratch, 0, 1.0 / (64.0 * 32768.0))
      aac_sbr_imdct64(xch, x1, scratch, 64, 1.0 / (64.0 * 32768.0))
      aac_sbr_qmf_deint_bfly(v0, v_off, scratch, 64, scratch, 0)
    }
    let n_out = 64 >> div
    for k in 0..<n_out {
      let mut acc = v0[v_off + k] * window[k]
      acc = acc + v0[v_off + (192 >> div) + k] * window[(64 >> div) + k]
      acc = acc + v0[v_off + (256 >> div) + k] * window[(128 >> div) + k]
      acc = acc + v0[v_off + (448 >> div) + k] * window[(192 >> div) + k]
      acc = acc + v0[v_off + (512 >> div) + k] * window[(256 >> div) + k]
      acc = acc + v0[v_off + (704 >> div) + k] * window[(320 >> div) + k]
      acc = acc + v0[v_off + (768 >> div) + k] * window[(384 >> div) + k]
      acc = acc + v0[v_off + (960 >> div) + k] * window[(448 >> div) + k]
      acc = acc + v0[v_off + (1024 >> div) + k] * window[(512 >> div) + k]
      acc = acc + v0[v_off + (1216 >> div) + k] * window[(576 >> div) + k]
      out[outp + k] = acc
    }
    outp = outp + n_out
  }
}

///|
/// `sbr_lf_gen`.
fn AacSbr::lf_gen(
  self : AacSbr,
  buf_idx : Int32,
  num_time_slots : Int32,
) -> Unit {
  let t_hf_gen = 8
  let i_f = num_time_slots * 2
  for k in 0..<(32 * 40 * 2) {
    self.x_low[k] = 0.0
  }
  for k in 0..<self.kx[1] {
    for i in t_hf_gen..<(i_f + t_hf_gen) {
      self.x_low[(k * 40 + i) * 2] = self.data[0].w_buf[(
          (buf_idx * 32 + (i - t_hf_gen)) * 32 + k
        ) *
        2]
      self.x_low[(k * 40 + i) * 2 + 1] = self.data[0].w_buf[(
          (buf_idx * 32 + (i - t_hf_gen)) * 32 + k
        ) *
        2 +
        1]
    }
  }
  let other = 1 - buf_idx
  for k in 0..<self.kx[0] {
    for i in 0..<t_hf_gen {
      self.x_low[(k * 40 + i) * 2] = self.data[0].w_buf[(
          (other * 32 + (i + i_f - t_hf_gen)) * 32 + k
        ) *
        2]
      self.x_low[(k * 40 + i) * 2 + 1] = self.data[0].w_buf[(
          (other * 32 + (i + i_f - t_hf_gen)) * 32 + k
        ) *
        2 +
        1]
    }
  }
}

///|
/// `sbr_hf_gen` wrapper (sp04 p215).
fn AacSbr::hf_gen(self : AacSbr, ch_data : AacSbrData) -> Result[Unit, String] {
  let mut g = 0
  let mut k = self.kx[1]
  for j in 0..<self.num_patches {
    for x in 0..<self.patch_num_subbands[j] {
      let p = self.patch_start_subband[j] + x
      while g <= self.n_q && k >= self.f_tablenoise[g] {
        g = g + 1
      }
      g = g - 1
      if g < 0 {
        return Err("ERROR : no subband found for frequency \{k}")
      }
      // The C passes X_high[k] + ENVELOPE_ADJUSTMENT_OFFSET and
      // X_low[p] + ENVELOPE_ADJUSTMENT_OFFSET (float offset of 2 each).
      aac_sbr_hf_gen_c(
        self.x_high,
        k * 40 * 2 + 4,
        self.x_low,
        p * 40 * 2 + 4,
        self.alpha0,
        p * 2,
        self.alpha1,
        p * 2,
        ch_data.bw_array[g],
        2 * ch_data.t_env[0],
        2 * ch_data.t_env[ch_data.bs_num_env],
      )
      k = k + 1
    }
  }
  if k < self.m[1] + self.kx[1] {
    for i in k..<(self.m[1] + self.kx[1]) {
      for c in 0..<80 {
        self.x_high[i * 80 + c] = 0.0
      }
    }
  }
  Ok(())
}

///|
/// `sbr_x_gen`.
fn AacSbr::x_gen(self : AacSbr, ch : Int32, num_time_slots : Int32) -> Unit {
  let ch_data = self.data[ch]
  let i_f = num_time_slots * 2
  let i_temp = if 2 * ch_data.t_env_num_env_old - i_f > 0 {
    2 * ch_data.t_env_num_env_old - i_f
  } else {
    0
  }
  // X[ch][x][i][k] at ((ch*2 + x)*38 + i)*64 + k; memset(X, 0, 2*sizeof(*X))
  // clears exactly this channel's [2][38][64] block.
  for i in 0..<(2 * 38 * 64) {
    self.x_qmf[ch * 2 * 38 * 64 + i] = 0.0
  }
  // Y0 = y_buf[1 - ypos], Y1 = y_buf[ypos]; y_buf[pos][i][m][c] at ((pos*38 + i)*64 + m)*2 + c
  let y0base = (1 - ch_data.ypos) * 38 * 64 * 2
  let y1base = ch_data.ypos * 38 * 64 * 2
  let x0 = ch * 2 * 38 * 64
  let x1 = x0 + 38 * 64
  for k in 0..<self.kx[0] {
    for i in 0..<i_temp {
      self.x_qmf[x0 + i * 64 + k] = self.x_low[(k * 40 + i + 2) * 2]
      self.x_qmf[x1 + i * 64 + k] = self.x_low[(k * 40 + i + 2) * 2 + 1]
    }
  }
  for k in self.kx[0]..<(self.kx[0] + self.m[0]) {
    for i in 0..<i_temp {
      self.x_qmf[x0 + i * 64 + k] = ch_data.y_buf[y0base +
        ((i + i_f) * 64 + k) * 2]
      self.x_qmf[x1 + i * 64 + k] = ch_data.y_buf[y0base +
        ((i + i_f) * 64 + k) * 2 +
        1]
    }
  }
  for k in 0..<self.kx[1] {
    for i in i_temp..<38 {
      self.x_qmf[x0 + i * 64 + k] = self.x_low[(k * 40 + i + 2) * 2]
      self.x_qmf[x1 + i * 64 + k] = self.x_low[(k * 40 + i + 2) * 2 + 1]
    }
  }
  for k in self.kx[1]..<(self.kx[1] + self.m[1]) {
    for i in i_temp..<i_f {
      self.x_qmf[x0 + i * 64 + k] = ch_data.y_buf[y1base + (i * 64 + k) * 2]
      self.x_qmf[x1 + i * 64 + k] = ch_data.y_buf[y1base + (i * 64 + k) * 2 + 1]
    }
  }
}

///|
/// `sbr_mapping` (sp04 p217).
fn AacSbr::mapping(self : AacSbr, ch_data : AacSbrData) -> Result[Unit, String] {
  // memset(ch_data->s_indexmapped[1], 0, 7 rows)
  for i in 0..<(7 * 48) {
    ch_data.s_indexmapped[48 + i] = 0
  }
  for e in 0..<ch_data.bs_num_env {
    let ilim = self.n[ch_data.bs_freq_res[e + 1]]
    let table : Array[Int32] = if ch_data.bs_freq_res[e + 1] != 0 {
      self.f_tablehigh
    } else {
      self.f_tablelow
    }
    if self.kx[1] != table[0] {
      return Err(
        "kx != f_table{high,low}[0]. Derived frequency tables were not regenerated.",
      )
    }
    for i in 0..<ilim {
      for m in table[i]..<table[i + 1] {
        self.e_origmapped[e * 48 + m - self.kx[1]] = ch_data.env_facs[(e + 1) *
          48 +
          i]
      }
    }
    let k = if ch_data.bs_num_noise > 1 && ch_data.t_env[e] >= ch_data.t_q[1] {
      1
    } else {
      0
    }
    for i in 0..<self.n_q {
      for m in self.f_tablenoise[i]..<self.f_tablenoise[i + 1] {
        self.q_mapped[e * 48 + m - self.kx[1]] = ch_data.noise_facs[(k + 1) * 5 +
          i]
      }
    }
    for i in 0..<self.n[1] {
      if ch_data.bs_add_harmonic_flag != 0 {
        let m_midpoint = (self.f_tablehigh[i] + self.f_tablehigh[i + 1]) >> 1
        ch_data.s_indexmapped[(e + 1) * 48 + m_midpoint - self.kx[1]] = ch_data.bs_add_harmonic[i] *
          (if e >= ch_data.e_a[1] ||
            ch_data.s_indexmapped[0 * 48 + m_midpoint - self.kx[1]] == 1 {
            1
          } else {
            0
          })
      }
    }
    for i in 0..<ilim {
      let mut additional_sinusoid_present = 0
      for m in table[i]..<table[i + 1] {
        if ch_data.s_indexmapped[(e + 1) * 48 + m - self.kx[1]] != 0 {
          additional_sinusoid_present = 1
          break
        }
      }
      for m in table[i]..<table[i + 1] {
        self.s_mapped[e * 48 + m - self.kx[1]] = additional_sinusoid_present
      }
    }
  }
  for i in 0..<48 {
    ch_data.s_indexmapped[i] = ch_data.s_indexmapped[ch_data.bs_num_env * 48 + i]
  }
  Ok(())
}

///|
/// `sbr_env_estimate` (sp04 p218).
fn AacSbr::env_estimate(self : AacSbr, ch_data : AacSbrData) -> Unit {
  let kx1 = self.kx[1]
  if self.bs_interpol_freq != 0 {
    for e in 0..<ch_data.bs_num_env {
      let recip_env_size = 0.5 /
        (ch_data.t_env[e + 1] - ch_data.t_env[e]).to_double()
      let ilb = ch_data.t_env[e] * 2 + 2
      let iub = ch_data.t_env[e + 1] * 2 + 2
      if ilb >= 40 {
        return
      }
      for m in 0..<self.m[1] {
        // X_high[m+kx1] + ilb: ilb/iub are complex-element indexes and the
        // count is in complex pairs; our sum_square consumes 2 floats per
        // unit of n, matching the C's float[2]-typed loop.
        let sum = aac_sbr_sum_square(
          self.x_high,
          (m + kx1) * 80 + ilb * 2,
          iub - ilb,
        )
        self.e_curr[e * 48 + m] = sum * recip_env_size
      }
    }
  } else {
    for e in 0..<ch_data.bs_num_env {
      let env_size = 2 * (ch_data.t_env[e + 1] - ch_data.t_env[e])
      let ilb = ch_data.t_env[e] * 2 + 2
      let iub = ch_data.t_env[e + 1] * 2 + 2
      let table : Array[Int32] = if ch_data.bs_freq_res[e + 1] != 0 {
        self.f_tablehigh
      } else {
        self.f_tablelow
      }
      if ilb >= 40 {
        return
      }
      for p in 0..<self.n[ch_data.bs_freq_res[e + 1]] {
        let den = env_size * (table[p + 1] - table[p])
        let mut sum = 0.0
        for k in table[p]..<table[p + 1] {
          sum = sum +
            aac_sbr_sum_square(self.x_high, k * 80 + ilb * 2, iub - ilb)
        }
        sum = sum / den.to_double()
        for k in table[p]..<table[p + 1] {
          self.e_curr[e * 48 + k - kx1] = sum
        }
      }
    }
  }
}

///|
/// `sbr_gain_calc` (sp04 p219).
fn AacSbr::gain_calc(self : AacSbr, ch_data : AacSbrData) -> Unit {
  let limgain : Array[Double] = [0.70795, 1.0, 1.41254, 10000000000.0]
  let flt_min = 1.1754943508222875e-38
  let flt_epsilon = 1.1920928955078125e-7
  for e in 0..<ch_data.bs_num_env {
    let delta : Int32 = if e == ch_data.e_a[1] || e == ch_data.e_a[0] {
      0
    } else {
      1
    }
    for k in 0..<self.n_lim {
      let mut sum0 = 0.0
      let mut sum1 = 0.0
      for
        m in (self.f_tablelim[k] - self.kx[1])..<(self.f_tablelim[k + 1] -
        self.kx[1]) {
        let temp = self.e_origmapped[e * 48 + m] /
          (1.0 + self.q_mapped[e * 48 + m])
        self.q_m[e * 48 + m] = (temp * self.q_mapped[e * 48 + m]).sqrt()
        self.s_m[e * 48 + m] = (temp *
        ch_data.s_indexmapped[(e + 1) * 48 + m].to_double()).sqrt()
        if self.s_mapped[e * 48 + m] == 0 {
          self.gain[e * 48 + m] = (self.e_origmapped[e * 48 + m] /
          (
            (1.0 + self.e_curr[e * 48 + m]) *
            (1.0 + self.q_mapped[e * 48 + m] * delta.to_double())
          )).sqrt()
        } else {
          self.gain[e * 48 + m] = (self.e_origmapped[e * 48 + m] *
          self.q_mapped[e * 48 + m] /
          ((1.0 + self.e_curr[e * 48 + m]) * (1.0 + self.q_mapped[e * 48 + m]))).sqrt()
        }
        self.gain[e * 48 + m] = self.gain[e * 48 + m] + flt_min
      }
      for
        m in (self.f_tablelim[k] - self.kx[1])..<(self.f_tablelim[k + 1] -
        self.kx[1]) {
        sum0 = sum0 + self.e_origmapped[e * 48 + m]
        sum1 = sum1 + self.e_curr[e * 48 + m]
      }
      let mut gain_max = limgain[self.bs_limiter_gains] *
        ((flt_epsilon + sum0) / (flt_epsilon + sum1)).sqrt()
      if gain_max > 100000.0 {
        gain_max = 100000.0
      }
      for
        m in (self.f_tablelim[k] - self.kx[1])..<(self.f_tablelim[k + 1] -
        self.kx[1]) {
        let q_m_max = self.q_m[e * 48 + m] * gain_max / self.gain[e * 48 + m]
        if self.q_m[e * 48 + m] > q_m_max {
          self.q_m[e * 48 + m] = q_m_max
        }
        if self.gain[e * 48 + m] > gain_max {
          self.gain[e * 48 + m] = gain_max
        }
      }
      sum0 = 0.0
      sum1 = 0.0
      for
        m in (self.f_tablelim[k] - self.kx[1])..<(self.f_tablelim[k + 1] -
        self.kx[1]) {
        sum0 = sum0 + self.e_origmapped[e * 48 + m]
        sum1 = sum1 +
          self.e_curr[e * 48 + m] *
          self.gain[e * 48 + m] *
          self.gain[e * 48 + m] +
          self.s_m[e * 48 + m] * self.s_m[e * 48 + m] +
          (if delta != 0 && self.s_m[e * 48 + m] == 0.0 {
            self.q_m[e * 48 + m] * self.q_m[e * 48 + m]
          } else {
            0.0
          })
      }
      let mut gain_boost = ((flt_epsilon + sum0) / (flt_epsilon + sum1)).sqrt()
      if gain_boost > 1.584893192 {
        gain_boost = 1.584893192
      }
      for
        m in (self.f_tablelim[k] - self.kx[1])..<(self.f_tablelim[k + 1] -
        self.kx[1]) {
        self.gain[e * 48 + m] = self.gain[e * 48 + m] * gain_boost
        self.q_m[e * 48 + m] = self.q_m[e * 48 + m] * gain_boost
        self.s_m[e * 48 + m] = self.s_m[e * 48 + m] * gain_boost
      }
    }
  }
}

///|
/// `sbr_hf_assemble` (sp04 p220).
fn AacSbr::hf_assemble(self : AacSbr, ch_data : AacSbrData) -> Unit {
  let h_sl = if self.bs_smoothing_mode != 0 { 0 } else { 4 }
  let kx = self.kx[1]
  let m_max = self.m[1]
  let h_smooth : Array[Double] = [
    0.33333333333333, 0.30150283239582, 0.21816949906249, 0.11516383427084, 0.03183050093751,
  ]
  let g_temp = ch_data.g_temp
  let q_temp = ch_data.q_temp
  let mut indexnoise = ch_data.f_indexnoise
  let mut indexsine = ch_data.f_indexsine
  if self.reset {
    for i in 0..<h_sl {
      for m in 0..<m_max {
        g_temp[(i + 2 * ch_data.t_env[0]) * 48 + m] = self.gain[m]
        q_temp[(i + 2 * ch_data.t_env[0]) * 48 + m] = self.q_m[m]
      }
    }
  } else if h_sl != 0 {
    for i in 0..<4 {
      for m in 0..<48 {
        g_temp[(i + 2 * ch_data.t_env[0]) * 48 + m] = g_temp[(
            i + 2 * ch_data.t_env_num_env_old
          ) *
          48 +
          m]
        q_temp[(i + 2 * ch_data.t_env[0]) * 48 + m] = q_temp[(
            i + 2 * ch_data.t_env_num_env_old
          ) *
          48 +
          m]
      }
    }
  }
  for e in 0..<ch_data.bs_num_env {
    for i in (2 * ch_data.t_env[e])..<(2 * ch_data.t_env[e + 1]) {
      for m in 0..<m_max {
        g_temp[(h_sl + i) * 48 + m] = self.gain[e * 48 + m]
        q_temp[(h_sl + i) * 48 + m] = self.q_m[e * 48 + m]
      }
    }
  }
  let y1base = ch_data.ypos * 38 * 64 * 2
  let g_filt_tab : Array[Double] = Array::make(48, 0.0)
  let q_filt_tab : Array[Double] = Array::make(48, 0.0)
  for e in 0..<ch_data.bs_num_env {
    for i in (2 * ch_data.t_env[e])..<(2 * ch_data.t_env[e + 1]) {
      let g_filt = g_filt_tab
      let q_filt = q_filt_tab
      if h_sl != 0 && e != ch_data.e_a[0] && e != ch_data.e_a[1] {
        for m in 0..<m_max {
          let idx1 = i + h_sl
          let mut gv = 0.0
          let mut qv = 0.0
          for j in 0..<=h_sl {
            gv = gv + g_temp[(idx1 - j) * 48 + m] * h_smooth[j]
            qv = qv + q_temp[(idx1 - j) * 48 + m] * h_smooth[j]
          }
          g_filt[m] = gv
          q_filt[m] = qv
        }
      } else {
        for m in 0..<48 {
          g_filt[m] = g_temp[(i + h_sl) * 48 + m]
          q_filt[m] = q_temp[i * 48 + m]
        }
      }
      aac_sbr_hf_g_filt(
        ch_data.y_buf,
        y1base + (i * 64 + kx) * 2,
        self.x_high,
        kx,
        g_filt,
        0,
        m_max,
        i + 2,
      )
      if e != ch_data.e_a[0] && e != ch_data.e_a[1] {
        // hf_apply_noise[indexsine]
        let y_off = y1base + (i * 64 + kx) * 2
        let mut phi_sign0 : Double = 0.0
        let mut phi_sign1 : Double = 0.0
        let sign = 1 - 2 * (kx & 1)
        match indexsine {
          0 => {
            phi_sign0 = 1.0
            phi_sign1 = 0.0
          }
          1 => {
            phi_sign0 = 0.0
            phi_sign1 = sign.to_double()
          }
          2 => {
            phi_sign0 = -1.0
            phi_sign1 = 0.0
          }
          _ => {
            phi_sign0 = 0.0
            phi_sign1 = -sign.to_double()
          }
        }
        aac_sbr_hf_apply_noise(
          ch_data.y_buf,
          y_off,
          self.s_m,
          e * 48,
          q_filt,
          0,
          indexnoise,
          phi_sign0,
          phi_sign1,
          m_max,
        )
      } else {
        let idx = indexsine & 1
        let a = 1 - ((indexsine + (kx & 1)) & 2)
        let b = (a ^ -idx) + idx
        let out_base = y1base + (i * 64 + kx) * 2 + idx
        let mut m = 0
        while m + 1 < m_max {
          ch_data.y_buf[out_base + 2 * m] = ch_data.y_buf[out_base + 2 * m] +
            self.s_m[e * 48 + m] * a.to_double()
          ch_data.y_buf[out_base + 2 * m + 2] = ch_data.y_buf[out_base +
            2 * m +
            2] +
            self.s_m[e * 48 + m + 1] * b.to_double()
          m = m + 2
        }
        if (m_max & 1) != 0 {
          ch_data.y_buf[out_base + 2 * m] = ch_data.y_buf[out_base + 2 * m] +
            self.s_m[e * 48 + m] * a.to_double()
        }
      }
      // Both counters advance once per time slot, regardless of branch.
      indexnoise = (indexnoise + m_max) & 0x1ff
      indexsine = (indexsine + 1) & 3
    }
  }
  ch_data.f_indexnoise = indexnoise
  ch_data.f_indexsine = indexsine
}

///|
/// `ff_aac_sbr_apply`: expands one channel element's core samples to the
/// SBR output rate. `channels` holds the element's per-channel sample arrays
/// (input, and resized output). Returns the number of output channels.
pub fn AacSbr::apply(
  self : AacSbr,
  channels : Array[Array[Double]],
  fl960 : Bool,
  ext_sample_rate : Int32,
  ps_enabled : Bool,
) -> Result[Int32, String] {
  let num_time_slots = if fl960 { 15 } else { 16 }
  let downsampled = ext_sample_rate < self.sample_rate
  let div = if downsampled { 1 } else { 0 }
  let id_aac = self.id_aac
  let mut nch = if id_aac == aac_id_cpe { 2 } else { 1 }
  if self.start && !self.ready_for_dequant {
    // "No quantized data read for sbr_dequant."
    self.turnoff()
  }
  if !self.kx_and_m_pushed {
    self.kx[0] = self.kx[1]
    self.m[0] = self.m[1]
  } else {
    self.kx_and_m_pushed = false
  }
  if self.start {
    self.dequant(id_aac)
    self.ready_for_dequant = false
  }
  if aac_sbr_ps_seen.val {
    return Err("Parametric Stereo payload is not implemented")
  }
  let out_len = (num_time_slots * 128) >> div
  for ch in 0..<nch {
    let d = self.data[ch]
    self.qmf_analysis(channels[ch], 0, ch, num_time_slots)
    self.lf_gen(d.ypos, num_time_slots)
    d.ypos = 1 - d.ypos
    if self.start {
      self.hf_inverse_filter()
      self.chirp(d)
      if d.bs_num_env <= 0 {
        return Err("SBR frame with zero envelopes")
      }
      match self.hf_gen(d) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      // hf_adj: mapping failure switches SBR off and falls through to
      // synthesis, exactly like the C's `if (!err) { ... }`.
      match self.mapping(d) {
        Ok(_) => {
          self.env_estimate(d)
          self.gain_calc(d)
          self.hf_assemble(d)
        }
        Err(_) => ()
      }
    }
    self.x_gen(ch, num_time_slots)
  }
  if ps_enabled {
    // PS payloads are rejected earlier; this is the mono implicit-PS
    // duplication path (no PS data was read: duplicate the QMF signal).
    for i in 0..<(2 * 38 * 64) {
      self.x_qmf[1 * 2 * 38 * 64 + i] = self.x_qmf[0 * 2 * 38 * 64 + i]
    }
    nch = 2
  }
  for ch in 0..<nch {
    if channels.length() <= ch {
      channels.push(Array::make(out_len, 0.0))
    } else {
      channels[ch].resize(out_len, 0.0)
    }
    self.qmf_synthesis(channels[ch], 0, ch, num_time_slots, div)
  }
  Ok(nch)
}
