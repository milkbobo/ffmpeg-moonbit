///|
// `lsf_decode_fp_16k`（含 `dequant`：四个 3 维码书 + 一个 4 维码书）
fn sipr_lsf_decode_fp_16k(
  lsf_history : Array[Double],
  vq_indexes : FixedArray[Int32],
  ma_pred : Int32,
) -> Array[Double] {
  let isp_q = Array::make(16, 0.0)
  let isp_new = Array::make(16, 0.0)
  for i = 0; i < 4; i = i + 1 {
    let cb = match i {
      0 => sipr_lsf_cb1_16k
      1 => sipr_lsf_cb2_16k
      2 => sipr_lsf_cb3_16k
      _ => sipr_lsf_cb4_16k
    }
    for k = 0; k < 3; k = k + 1 {
      isp_q[3 * i + k] = cb[3 * vq_indexes[i] + k]
    }
  }
  for k = 0; k < 4; k = k + 1 {
    isp_q[12 + k] = sipr_lsf_cb5_16k[4 * vq_indexes[4] + k]
  }
  for i = 0; i < 16; i = i + 1 {
    isp_new[i] = (1.0 - sipr_qu[ma_pred]) * isp_q[i] +
      sipr_qu[ma_pred] * lsf_history[i] +
      sipr_mean_lsf_16k[i]
  }
  for i = 0; i < 16; i = i + 1 {
    lsf_history[i] = isp_q[i]
  }
  isp_new
}

///|
// `acelp_lp_decodef`：lp_1st 写在 [0,16)，lp_2nd 写在 [16,32)
fn sipr_acelp_lp_decodef(
  lp : Array[Double],
  lsp_2nd : Array[Double],
  lsp_prev : Array[Double],
) -> Unit {
  let lsp_1st = Array::make(16, 0.0)
  for i = 0; i < 16; i = i + 1 {
    lsp_1st[i] = (lsp_2nd[i] + lsp_prev[i]) * 0.5
  }
  sipr_lspd2lpc(lsp_1st, lp, 0, 8)
  sipr_lspd2lpc(lsp_2nd, lp, 16, 8)
}

///|
// `dec_delay3_1st`
fn sipr_dec_delay3_1st(index : Int32) -> Int32 {
  if index < 390 {
    index + 88
  } else {
    3 * index - 690
  }
}

///|
// `dec_delay3_2nd`
fn sipr_dec_delay3_2nd(
  index : Int32,
  pit_min : Int32,
  pit_max : Int32,
  pitch_lag_prev : Int32,
) -> Int32 {
  if index < 62 {
    let pitch_delay_min = amr_clip_int(pitch_lag_prev - 10, pit_min, pit_max - 19)
    3 * pitch_delay_min + index - 2
  } else {
    3 * pitch_lag_prev
  }
}

///|
// `DIVIDE_BY_3`
fn sipr_divide_by_3(x : Int32) -> Int32 {
  (x * 10923) >> 15
}

///|
// `ff_decode_10_pulses_35bits`
fn sipr_decode_10_pulses_35bits(
  fixed_index : FixedArray[Int32],
  f : SiprFixed,
  gray_decode : FixedArray[Int32],
  half_pulse_count : Int32,
  bits : Int32,
) -> Unit {
  let mask = (1 << bits) - 1
  f.no_repeat_mask = 0
  f.n = 2 * half_pulse_count
  for i = 0; i < half_pulse_count; i = i + 1 {
    let pos1 = gray_decode[fixed_index[2 * i + 1] & mask] + i
    let pos2 = gray_decode[fixed_index[2 * i] & mask] + i
    let sign = if (fixed_index[2 * i + 1] & (1 << bits)) != 0 { -1.0 } else { 1.0 }
    f.x[2 * i + 1] = pos1
    f.x[2 * i] = pos2
    f.y[2 * i + 1] = sign
    f.y[2 * i] = if pos2 < pos1 { -sign } else { sign }
  }
}

///|
// `ff_set_fixed_vector`（C 的 do-while：第一轮无条件执行）
fn sipr_set_fixed_vector(
  out : Array[Double],
  f : SiprFixed,
  scale : Double,
  size : Int32,
) -> Unit {
  for i = 0; i < f.n; i = i + 1 {
    let repeats = ((f.no_repeat_mask >> i) & 1) == 0
    let mut x = f.x[i]
    let mut y = f.y[i] * scale
    if f.pitch_lag > 0 {
      let mut first = true
      while (first || repeats) && x < size {
        out[x] += y
        y *= f.pitch_fac
        x += f.pitch_lag
        first = false
      }
    }
  }
}

///|
// `acelp_decode_gain_codef`
fn sipr_acelp_decode_gain_codef(
  gain_scale : Double,
  fc_v : Array[Double],
  mr_energy_in : Double,
  quant_energy : Array[Double],
  ma_prediction_coeff : FixedArray[Double],
  subframe_size : Int32,
  ma_pred_order : Int32,
) -> Double {
  let mut mr_energy = mr_energy_in
  for i = 0; i < ma_pred_order; i = i + 1 {
    mr_energy += quant_energy[i] * ma_prediction_coeff[i]
  }
  gain_scale * @math.exp(sipr_ln10 / 20.0 * mr_energy) /
  (0.01 + amr_dot(fc_v, 0, fc_v, 0, subframe_size)).sqrt()
}

///|
// `ff_sipr_decode_frame_16k`：160 个样本写到 out[out_off ..]
fn SiprDecoder::decode_frame_16k(
  self : SiprDecoder,
  params : SiprParameters,
  out : Array[Double],
  out_off : Int32,
) -> Unit {
  let frame_size = 2 * sipr_l_subfr_16k
  let synth = 16
  let az = Array::make(32, 0.0)
  let lsf_new = sipr_lsf_decode_fp_16k(
    self.lsf_history,
    params.vq_indexes,
    params.ma_pred_switch,
  )
  sipr_set_min_dist_lsf(lsf_new, sipr_lsfq_diff_min / 2.0, 16)
  let lsp_new = Array::make(16, 0.0)
  for i = 0; i < 16; i = i + 1 {
    lsp_new[i] = @math.cos(lsf_new[i]) // lsf2lsp
  }
  sipr_acelp_lp_decodef(az, lsp_new, self.lsp_history_16k)
  for i = 0; i < 16; i = i + 1 {
    self.lsp_history_16k[i] = lsp_new[i]
  }
  for i = 0; i < 16; i = i + 1 {
    self.synth_buf[synth - 16 + i] = self.synth[i]
  }
  for i = 0; i < 2; i = i + 1 {
    let i_subfr = i * sipr_l_subfr_16k
    let ex = sipr_excitation_16k + i_subfr
    let pitch_delay_3x = if i == 0 {
      sipr_dec_delay3_1st(params.pitch_delay[0])
    } else {
      sipr_dec_delay3_2nd(
        params.pitch_delay[i],
        sipr_pitch_min,
        sipr_pitch_max,
        self.pitch_lag_prev,
      )
    }
    let f = SiprFixed::new()
    let pitch_fac = sipr_gain_pitch_cb_16k[params.gp_index[i]]
    f.pitch_fac = if pitch_fac < 1.0 { pitch_fac } else { 1.0 }
    f.pitch_lag = sipr_divide_by_3(pitch_delay_3x + 1)
    self.pitch_lag_prev = f.pitch_lag
    let pitch_delay_int = sipr_divide_by_3(pitch_delay_3x + 2)
    let pitch_delay_frac = pitch_delay_3x + 2 - 3 * pitch_delay_int
    amr_acelp_interpolatef(
      self.excitation, ex, self.excitation, ex - pitch_delay_int + 1,
      sipr_sinc_win, 3, pitch_delay_frac + 1, sipr_lp_filter_order,
      sipr_l_subfr_16k,
    )
    let fixed_vector = Array::make(sipr_l_subfr_16k, 0.0)
    sipr_decode_10_pulses_35bits(
      params.fc_indexes[i], f, sipr_fc_4pulses_8bits_tracks_13, 5, 4,
    )
    sipr_set_fixed_vector(fixed_vector, f, 1.0, sipr_l_subfr_16k)
    let gain_corr_factor = sipr_gain_cb_16k[params.gc_index[i]]
    let gain_code = gain_corr_factor *
      sipr_acelp_decode_gain_codef(
        sipr_l_subfr_16k.to_double().sqrt(), fixed_vector, sipr_energy_mean(19.0),
        self.energy_history, sipr_pred_16k, sipr_l_subfr_16k, 2,
      )
    self.energy_history[1] = self.energy_history[0]
    self.energy_history[0] = 20.0 * @math.log10(gain_corr_factor)
    amr_weighted_vector_sum(
      self.excitation, ex, self.excitation, ex, fixed_vector, 0,
      pitch_fac, gain_code, sipr_l_subfr_16k,
    )
    sipr_lp_synthesis_filterf(
      self.synth_buf, synth + i_subfr, self.excitation, ex, az, i * 16,
      sipr_l_subfr_16k, 16,
    )
  }
  for i = 0; i < 16; i = i + 1 {
    self.synth[i] = self.synth_buf[synth + frame_size - 16 + i]
  }
  for i = 0; i < sipr_excitation_16k; i = i + 1 {
    self.excitation[i] = self.excitation[frame_size + i]
  }
  self.postfilter_16k(out, out_off, synth)
  for i = 0; i < 16; i = i + 1 {
    self.iir_mem[i] = az[16 + i]
  }
}

///|
// `postfilter`（16k）
fn SiprDecoder::postfilter_16k(
  self : SiprDecoder,
  out : Array[Double],
  out_off : Int32,
  synth : Int32,
) -> Unit {
  let buf = Array::make(30 + 16, 0.0)
  let tmpbuf = 16
  // Alternate the previous and current filter buffers each frame.
  let filt0 = self.filt_buf[self.filt_sel]
  let filt1 = self.filt_buf[1 - self.filt_sel]
  for i = 0; i < 16; i = i + 1 {
    filt0[i] = self.iir_mem[i] * sipr_pow_0_5[i]
  }
  for i = 0; i < 16; i = i + 1 {
    buf[i] = self.mem_preemph[i]
  }
  amr_celp_lp_synthesis_filterf(buf, tmpbuf, self.synth_buf, synth, filt1, 30, 16)
  for i = 0; i < 16; i = i + 1 {
    self.synth_buf[synth - 16 + i] = self.mem_preemph[i]
  }
  amr_celp_lp_synthesis_filterf(self.synth_buf, synth, self.synth_buf, synth, filt0, 30, 16)
  for i = 0; i < 16; i = i + 1 {
    out[out_off + 14 + i] = self.synth_buf[synth + 14 + i]
  }
  amr_celp_lp_synthesis_filterf(
    out, out_off + 30, self.synth_buf, synth + 30, filt0, 130, 16,
  )
  for i = 0; i < 16; i = i + 1 {
    self.mem_preemph[i] = out[out_off + 144 + i]
  }
  self.filt_sel = 1 - self.filt_sel
  let mut s = 0.0
  for i = 0; i < 30; i = i + 1 {
    out[out_off + i] = buf[tmpbuf + i] +
      s * (self.synth_buf[synth + i] - buf[tmpbuf + i])
    s += 1.0 / 30.0
  }
}
