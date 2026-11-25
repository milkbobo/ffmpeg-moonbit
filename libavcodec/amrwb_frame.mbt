///|
/// AMR-WB decoder, second part: the algebraic codebook, the gains, the
/// excitation post-processing, the synthesis (12.8 kHz core, 5/4 upsampling
/// and the 6.4-7.0 kHz high band) and the frame entry - `amrwbdec.c`.

// ---------------------------------------------------------------------------
// algebraic (fixed) codebook: TS 26.190 5.8.2 pulse indexing
// ---------------------------------------------------------------------------

///|
/// `BIT_STR`: the `len` bits of `x` from `lsb`, zero extended.
fn amrwb_bit_str(x : Int32, lsb : Int32, len : Int32) -> Int32 {
  (x >> lsb) & ((1 << len) - 1)
}

///|
/// `BIT_POS`.
fn amrwb_bit_pos(x : Int32, p : Int32) -> Int32 {
  (x >> p) & 1
}

///|
/// `decode_1p_track`: one pulse; `out[out_off]` is its 1-based position
/// with the sign as the sign of the value.
fn amrwb_decode_1p_track(
  out : Array[Int32],
  out_off : Int32,
  code : Int32,
  m : Int32,
  off : Int32,
) -> Unit {
  let pos = amrwb_bit_str(code, 0, m) + off
  out[out_off] = if amrwb_bit_pos(code, m) != 0 { -pos } else { pos }
}

///|
/// `decode_2p_track` (code: 2m+1 bits).
fn amrwb_decode_2p_track(
  out : Array[Int32],
  out_off : Int32,
  code : Int32,
  m : Int32,
  off : Int32,
) -> Unit {
  let pos0 = amrwb_bit_str(code, m, m) + off
  let pos1 = amrwb_bit_str(code, 0, m) + off
  let sign = amrwb_bit_pos(code, 2 * m) != 0
  out[out_off] = if sign { -pos0 } else { pos0 }
  let mut second = if sign { -pos1 } else { pos1 }
  if pos0 > pos1 {
    second = -second
  }
  out[out_off + 1] = second
}

///|
/// `decode_3p_track` (code: 3m+1 bits).
fn amrwb_decode_3p_track(
  out : Array[Int32],
  out_off : Int32,
  code : Int32,
  m : Int32,
  off : Int32,
) -> Unit {
  let half_2p = amrwb_bit_pos(code, 2 * m - 1) << (m - 1)
  amrwb_decode_2p_track(
    out,
    out_off,
    amrwb_bit_str(code, 0, 2 * m - 1),
    m - 1,
    off + half_2p,
  )
  amrwb_decode_1p_track(
    out,
    out_off + 2,
    amrwb_bit_str(code, 2 * m, m + 1),
    m,
    off,
  )
}

///|
/// `decode_4p_track` (code: 4m bits).
fn amrwb_decode_4p_track(
  out : Array[Int32],
  out_off : Int32,
  code : Int32,
  m : Int32,
  off : Int32,
) -> Unit {
  let b_offset = 1 << (m - 1)
  match amrwb_bit_str(code, 4 * m - 2, 2) {
    // 0 pulses in A, 4 pulses in B or vice versa
    0 => {
      let half_4p = amrwb_bit_pos(code, 4 * m - 3) << (m - 1)
      let subhalf_2p = amrwb_bit_pos(code, 2 * m - 3) << (m - 2)
      amrwb_decode_2p_track(
        out,
        out_off,
        amrwb_bit_str(code, 0, 2 * m - 3),
        m - 2,
        off + half_4p + subhalf_2p,
      )
      amrwb_decode_2p_track(
        out,
        out_off + 2,
        amrwb_bit_str(code, 2 * m - 2, 2 * m - 1),
        m - 1,
        off + half_4p,
      )
    }
    // 1 pulse in A, 3 pulses in B
    1 => {
      amrwb_decode_1p_track(
        out,
        out_off,
        amrwb_bit_str(code, 3 * m - 2, m),
        m - 1,
        off,
      )
      amrwb_decode_3p_track(
        out,
        out_off + 1,
        amrwb_bit_str(code, 0, 3 * m - 2),
        m - 1,
        off + b_offset,
      )
    }
    // 2 pulses in each half
    2 => {
      amrwb_decode_2p_track(
        out,
        out_off,
        amrwb_bit_str(code, 2 * m - 1, 2 * m - 1),
        m - 1,
        off,
      )
      amrwb_decode_2p_track(
        out,
        out_off + 2,
        amrwb_bit_str(code, 0, 2 * m - 1),
        m - 1,
        off + b_offset,
      )
    }
    // 3 pulses in A, 1 pulse in B
    _ => {
      amrwb_decode_3p_track(
        out,
        out_off,
        amrwb_bit_str(code, m, 3 * m - 2),
        m - 1,
        off,
      )
      amrwb_decode_1p_track(
        out,
        out_off + 3,
        amrwb_bit_str(code, 0, m),
        m - 1,
        off + b_offset,
      )
    }
  }
}

///|
/// `decode_5p_track` (code: 5m bits).
fn amrwb_decode_5p_track(
  out : Array[Int32],
  out_off : Int32,
  code : Int32,
  m : Int32,
  off : Int32,
) -> Unit {
  let half_3p = amrwb_bit_pos(code, 5 * m - 1) << (m - 1)
  amrwb_decode_3p_track(
    out,
    out_off,
    amrwb_bit_str(code, 2 * m + 1, 3 * m - 2),
    m - 1,
    off + half_3p,
  )
  amrwb_decode_2p_track(out, out_off + 3, amrwb_bit_str(code, 0, 2 * m + 1), m, off)
}

///|
/// `decode_6p_track` (code: 6m-2 bits).
fn amrwb_decode_6p_track(
  out : Array[Int32],
  out_off : Int32,
  code : Int32,
  m : Int32,
  off : Int32,
) -> Unit {
  let b_offset = 1 << (m - 1)
  // which half has more pulses in cases 0 to 2
  let half_more = amrwb_bit_pos(code, 6 * m - 5) << (m - 1)
  let half_other = b_offset - half_more
  match amrwb_bit_str(code, 6 * m - 4, 2) {
    // 0 pulses in A, 6 pulses in B or vice versa
    0 => {
      amrwb_decode_1p_track(
        out,
        out_off,
        amrwb_bit_str(code, 0, m),
        m - 1,
        off + half_more,
      )
      amrwb_decode_5p_track(
        out,
        out_off + 1,
        amrwb_bit_str(code, m, 5 * m - 5),
        m - 1,
        off + half_more,
      )
    }
    // 1 pulse in A, 5 pulses in B or vice versa
    1 => {
      amrwb_decode_1p_track(
        out,
        out_off,
        amrwb_bit_str(code, 0, m),
        m - 1,
        off + half_other,
      )
      amrwb_decode_5p_track(
        out,
        out_off + 1,
        amrwb_bit_str(code, m, 5 * m - 5),
        m - 1,
        off + half_more,
      )
    }
    // 2 pulses in A, 4 pulses in B or vice versa
    2 => {
      amrwb_decode_2p_track(
        out,
        out_off,
        amrwb_bit_str(code, 0, 2 * m - 1),
        m - 1,
        off + half_other,
      )
      amrwb_decode_4p_track(
        out,
        out_off + 2,
        amrwb_bit_str(code, 2 * m - 1, 4 * m - 4),
        m - 1,
        off + half_more,
      )
    }
    // 3 pulses in A, 3 pulses in B
    _ => {
      amrwb_decode_3p_track(
        out,
        out_off,
        amrwb_bit_str(code, 3 * m - 2, 3 * m - 2),
        m - 1,
        off,
      )
      amrwb_decode_3p_track(
        out,
        out_off + 3,
        amrwb_bit_str(code, 0, 3 * m - 2),
        m - 1,
        off + b_offset,
      )
    }
  }
}

///|
/// `decode_fixed_vector`: pulse positions and signs of the four tracks,
/// then the algebraic codebook vector.
fn amrwb_decode_fixed_vector(
  fixed_vector : Array[Double],
  pulse_hi : FixedArray[Int32],
  pulse_lo : FixedArray[Int32],
  mode : Int32,
) -> Unit {
  // per track, the decoded positions (1-based) times the amplitude sign
  let sig_pos : Array[Array[Int32]] = Array::makei(4, _ => Array::make(6, 0))
  let spacing = if mode == amrwb_mode_6k60 { 2 } else { 4 }
  match mode {
    0 =>
      for i = 0; i < 2; i = i + 1 {
        amrwb_decode_1p_track(sig_pos[i], 0, pulse_lo[i], 5, 1)
      }
    1 =>
      for i = 0; i < 4; i = i + 1 {
        amrwb_decode_1p_track(sig_pos[i], 0, pulse_lo[i], 4, 1)
      }
    2 =>
      for i = 0; i < 4; i = i + 1 {
        amrwb_decode_2p_track(sig_pos[i], 0, pulse_lo[i], 4, 1)
      }
    3 => {
      for i = 0; i < 2; i = i + 1 {
        amrwb_decode_3p_track(sig_pos[i], 0, pulse_lo[i], 4, 1)
      }
      for i = 2; i < 4; i = i + 1 {
        amrwb_decode_2p_track(sig_pos[i], 0, pulse_lo[i], 4, 1)
      }
    }
    4 =>
      for i = 0; i < 4; i = i + 1 {
        amrwb_decode_3p_track(sig_pos[i], 0, pulse_lo[i], 4, 1)
      }
    5 =>
      for i = 0; i < 4; i = i + 1 {
        amrwb_decode_4p_track(sig_pos[i], 0, pulse_lo[i] + (pulse_hi[i] << 14), 4, 1)
      }
    6 => {
      for i = 0; i < 2; i = i + 1 {
        amrwb_decode_5p_track(sig_pos[i], 0, pulse_lo[i] + (pulse_hi[i] << 10), 4, 1)
      }
      for i = 2; i < 4; i = i + 1 {
        amrwb_decode_4p_track(sig_pos[i], 0, pulse_lo[i] + (pulse_hi[i] << 14), 4, 1)
      }
    }
    // 23k05 and 23k85
    _ =>
      for i = 0; i < 4; i = i + 1 {
        amrwb_decode_6p_track(sig_pos[i], 0, pulse_lo[i] + (pulse_hi[i] << 11), 4, 1)
      }
  }
  for i = 0; i < amrwb_sfr_size; i = i + 1 {
    fixed_vector[i] = 0.0
  }
  for i = 0; i < 4; i = i + 1 {
    let pulses = amrwb_pulses_nb_per_mode_tr[mode * 4 + i]
    for j = 0; j < pulses; j = j + 1 {
      let signed = sig_pos[i][j]
      let pos = ((if signed < 0 { -signed } else { signed }) - 1) * spacing + i
      fixed_vector[pos] += if signed < 0 { -1.0 } else { 1.0 }
    }
  }
}

// ---------------------------------------------------------------------------
// gains and excitation post-processing
// ---------------------------------------------------------------------------

///|
/// `decode_gains`: (pitch gain, fixed gain correction factor) from the
/// vector-quantized index.
fn amrwb_decode_gains(vq_gain : Int32, mode : Int32) -> (Double, Double) {
  let gains = if mode <= amrwb_mode_8k85 { amrwb_qua_gain_6b } else { amrwb_qua_gain_7b }
  (
    gains[vq_gain * 2].to_double() / 16384.0,
    gains[vq_gain * 2 + 1].to_double() / 2048.0,
  )
}

///|
/// `pitch_sharpening`: tilt and periodicity enhancement of the fixed vector.
fn AmrWbDecoder::pitch_sharpening(self : AmrWbDecoder) -> Unit {
  let mut i = amrwb_sfr_size - 1
  while i != 0 {
    self.fixed_vector[i] -= self.fixed_vector[i - 1] * self.tilt_coef
    i = i - 1
  }
  let mut j = self.pitch_lag_int
  while j < amrwb_sfr_size {
    self.fixed_vector[j] += self.fixed_vector[j - self.pitch_lag_int] * 0.85
    j = j + 1
  }
}

///|
/// `voice_factor`: -1.0 unvoiced to 1.0 voiced.
fn amrwb_voice_factor(
  p_vector : Array[Double],
  p_gain : Double,
  f_vector : Array[Double],
  f_gain : Double,
) -> Double {
  let p_ener = amr_dot(p_vector, 0, p_vector, 0, amrwb_sfr_size) * p_gain * p_gain
  let f_ener = amr_dot(f_vector, 0, f_vector, 0, amrwb_sfr_size) * f_gain * f_gain
  (p_ener - f_ener) / (p_ener + f_ener + 0.01)
}

///|
/// `anti_sparseness`: smooth the fixed vector with one of two impulse
/// response filters ("adaptive phase dispersion"). Returns `true` when the
/// filtered copy in `buf` is the vector to use.
fn AmrWbDecoder::anti_sparseness(
  self : AmrWbDecoder,
  fixed_vector : Array[Double],
  buf : Array[Double],
) -> Bool {
  // no filtering in higher modes
  if self.fr_cur_mode > amrwb_mode_8k85 {
    return false
  }
  let mut ir_filter_nr = if self.pitch_gain[0] < 0.6 {
    0 // strong filtering
  } else if self.pitch_gain[0] < 0.9 {
    1 // medium filtering
  } else {
    2 // no filtering
  }
  // detect 'onset'
  if self.fixed_gain[0] > 3.0 * self.fixed_gain[1] {
    if ir_filter_nr < 2 {
      ir_filter_nr += 1
    }
  } else {
    let mut count = 0
    for i = 0; i < 6; i = i + 1 {
      if self.pitch_gain[i] < 0.6 {
        count += 1
      }
    }
    if count > 2 {
      ir_filter_nr = 0
    }
    if ir_filter_nr > self.prev_ir_filter_nr + 1 {
      ir_filter_nr -= 1
    }
  }
  self.prev_ir_filter_nr = ir_filter_nr
  if self.fr_cur_mode == amrwb_mode_8k85 {
    ir_filter_nr += 1
  }
  if ir_filter_nr >= 2 {
    return false
  }
  let source = if ir_filter_nr == 0 { amrwb_ir_filter_str } else { amrwb_ir_filter_mid }
  // c2(n) = sum(i,0,len-1){ c(i) * coef((n - i + len) % len) }
  let coef : Array[Double] = Array::makei(amrwb_sfr_size, i => source[i])
  for i = 0; i < amrwb_sfr_size; i = i + 1 {
    buf[i] = 0.0
  }
  for i = 0; i < amrwb_sfr_size; i = i + 1 {
    if fixed_vector[i] != 0.0 {
      amr_celp_circ_addf(buf, 0, buf, 0, coef, 0, i, fixed_vector[i], amrwb_sfr_size)
    }
  }
  true
}

///|
/// `noise_enhancer`: non-linear fixed gain smoothing.
fn AmrWbDecoder::noise_enhancer(
  self : AmrWbDecoder,
  fixed_gain : Double,
  voice_fac : Double,
  stab_fac : Double,
) -> Double {
  let sm_fac = 0.5 * (1.0 - voice_fac) * stab_fac
  let g0 = if fixed_gain < self.prev_tr_gain {
    // +1.5 dB
    (self.prev_tr_gain).min(fixed_gain + fixed_gain * (6226.0 / 32768.0))
  } else {
    // -1.5 dB
    (self.prev_tr_gain).max(fixed_gain * (27536.0 / 32768.0))
  }
  self.prev_tr_gain = g0
  sm_fac * g0 + (1.0 - sm_fac) * fixed_gain
}

///|
/// `pitch_enhancer`: emphasize the higher frequencies of the fixed vector.
fn amrwb_pitch_enhancer(fixed_vector : Array[Double], voice_fac : Double) -> Unit {
  let cpe = 0.125 * (1.0 + voice_fac)
  let mut last = fixed_vector[0]
  fixed_vector[0] -= cpe * fixed_vector[1]
  for i = 1; i < amrwb_sfr_size - 1; i = i + 1 {
    let cur = fixed_vector[i]
    fixed_vector[i] -= cpe * (last + fixed_vector[i + 1])
    last = cur
  }
  fixed_vector[amrwb_sfr_size - 1] -= cpe * last
}

///|
/// `synthesis`: 16th order LPC synthesis from the excitation.
fn AmrWbDecoder::synthesis(
  self : AmrWbDecoder,
  sub : Int32,
  excitation : Array[Double],
  fixed_gain : Double,
  fixed_vector : Array[Double],
  samples_off : Int32,
) -> Unit {
  amr_weighted_vector_sum(
    excitation,
    0,
    self.pitch_vector,
    0,
    fixed_vector,
    0,
    self.pitch_gain[0],
    fixed_gain,
    amrwb_sfr_size,
  )
  // emphasize pitch vector contribution in low bitrate modes
  if self.pitch_gain[0] > 0.5 && self.fr_cur_mode <= amrwb_mode_8k85 {
    let energy = amr_dot(excitation, 0, excitation, 0, amrwb_sfr_size)
    // {beta} is identical to the current pitch gain
    let pitch_factor = 0.25 * self.pitch_gain[0] * self.pitch_gain[0]
    for i = 0; i < amrwb_sfr_size; i = i + 1 {
      excitation[i] += pitch_factor * self.pitch_vector[i]
    }
    amr_scale_to_sum_of_squares(
      excitation,
      0,
      excitation,
      0,
      energy,
      amrwb_sfr_size,
    )
  }
  amr_celp_lp_synthesis_filterf(
    self.samples_az,
    samples_off,
    excitation,
    0,
    self.lp_coef[sub],
    amrwb_sfr_size,
    amrwb_lp_order,
  )
}

///|
/// `de_emphasis`: H(z) = 1 / (1 - m * z^-1); the block is written at
/// `out[out_off]`, the previous output lives in `mem`.
fn amrwb_de_emphasis(
  out : Array[Double],
  out_off : Int32,
  samples : Array[Double],
  in_off : Int32,
  m : Double,
  mem : Array[Double],
) -> Unit {
  out[out_off] = samples[in_off] + m * mem[0]
  for i = 1; i < amrwb_sfr_size; i = i + 1 {
    out[out_off + i] = samples[in_off + i] + out[out_off + i - 1] * m
  }
  mem[0] = out[out_off + amrwb_sfr_size - 1]
}

///|
/// Dot product of an array slice with a fixed table slice.
fn amrwb_dot_fixed(
  a : Array[Double],
  a_off : Int32,
  b : FixedArray[Double],
  b_off : Int32,
  len : Int32,
) -> Double {
  let mut sum = 0.0
  for i = 0; i < len; i = i + 1 {
    sum = sum + a[a_off + i] * b[b_off + i]
  }
  sum
}

///|
/// `upsample_5_4`: 12.8 kHz to 16 kHz by FIR interpolation, using the
/// history in front of `samples_up[UPS_FIR_SIZE]`.
fn AmrWbDecoder::upsample_5_4(self : AmrWbDecoder, out : Array[Double], out_off : Int32) -> Unit {
  // in = &samples_up[UPS_FIR_SIZE]; in0 = in - UPS_FIR_SIZE + 1
  let in0 = 1
  let mut int_part = 0
  let mut i = 0
  for _j = 0; _j < amrwb_sfr_size_16k / 5; _j = _j + 1 {
    out[out_off + i] = self.samples_up[amrwb_ups_fir_size + int_part]
    let mut frac_part = 4
    i += 1
    for _k = 1; _k < 5; _k = _k + 1 {
      out[out_off + i] = amrwb_dot_fixed(
        self.samples_up,
        in0 + int_part,
        amrwb_upsample_fir,
        (4 - frac_part) * amrwb_ups_mem_size,
        amrwb_ups_mem_size,
      )
      int_part += 1
      frac_part -= 1
      i += 1
    }
  }
}

// ---------------------------------------------------------------------------
// high frequency band (6.4 - 7.0 kHz) generation
// ---------------------------------------------------------------------------

///|
/// `find_hb_gain`: the high-band gain from the coded index (23k85) or from
/// the low-band speech and the VAD flag.
fn AmrWbDecoder::find_hb_gain(
  self : AmrWbDecoder,
  synth : Array[Double],
  hb_idx : Int32,
  vad : Int32,
) -> Double {
  let wsp = vad > 0
  if self.fr_cur_mode == 8 {
    return amrwb_qua_hb_gain[hb_idx].to_double() / 16384.0
  }
  let tmp = amr_dot(synth, 0, synth, 1, amrwb_sfr_size - 1)
  let tilt = if tmp > 0.0 {
    tmp / amr_dot(synth, 0, synth, 0, amrwb_sfr_size)
  } else {
    0.0
  }
  // bounded by [0.1, 1.0]
  ((1.0 - tilt) * (1.25 - (if wsp { 0.25 } else { 0.0 }))).clamp(min=0.1, max=1.0)
}

///|
/// `scaled_hb_excitation`: white noise with the low band's energy, scaled.
fn AmrWbDecoder::scaled_hb_excitation(
  self : AmrWbDecoder,
  hb_exc : Array[Double],
  synth_exc : Array[Double],
  hb_gain : Double,
) -> Unit {
  let energy = amr_dot(synth_exc, 0, synth_exc, 0, amrwb_sfr_size)
  for i = 0; i < amrwb_sfr_size_16k; i = i + 1 {
    hb_exc[i] = 32768.0 - (self.prng.get() & 0xFFFFU).to_double()
  }
  amr_scale_to_sum_of_squares(
    hb_exc,
    0,
    hb_exc,
    0,
    energy * hb_gain * hb_gain,
    amrwb_sfr_size_16k,
  )
}

///|
/// `auto_correlation` of the ISF difference vector.
fn amrwb_auto_correlation(diff_isf : Array[Double], mean : Double, lag : Int32) -> Double {
  let mut sum = 0.0
  for i = 7; i < amrwb_lp_order - 2; i = i + 1 {
    let prod = (diff_isf[i] - mean) * (diff_isf[i - lag] - mean)
    sum += prod * prod
  }
  sum
}

///|
/// `extrapolate_isf`: extend a 16-coefficient ISF vector to the 20th
/// order used at 16 kHz (in place).
fn amrwb_extrapolate_isf(isf : Array[Double]) -> Unit {
  let diff_isf : Array[Double] = Array::make(amrwb_lp_order - 2, 0.0)
  let corr_lag : Array[Double] = Array::make(3, 0.0)
  isf[amrwb_lp_order_16k - 1] = isf[amrwb_lp_order - 1]
  for i = 0; i < amrwb_lp_order - 2; i = i + 1 {
    diff_isf[i] = isf[i + 1] - isf[i]
  }
  let mut diff_mean = 0.0
  for i = 2; i < amrwb_lp_order - 2; i = i + 1 {
    diff_mean += diff_isf[i] * (1.0 / (amrwb_lp_order - 4).to_double())
  }
  // which lag has the maximum autocorrelation
  let mut i_max_corr = 0
  for i = 0; i < 3; i = i + 1 {
    corr_lag[i] = amrwb_auto_correlation(diff_isf, diff_mean, i + 2)
    if corr_lag[i] > corr_lag[i_max_corr] {
      i_max_corr = i
    }
  }
  i_max_corr += 1
  for i = amrwb_lp_order - 1; i < amrwb_lp_order_16k - 1; i = i + 1 {
    isf[i] = isf[i - 1] + isf[i - 1 - i_max_corr] - isf[i - 2 - i_max_corr]
  }
  // an estimate for ISF(18), and the ISF scaled by the error
  let est = 7965.0 + (isf[2] - isf[3] - isf[4]) / 6.0
  let scale = 0.5 *
    (est.min(7600.0) - isf[amrwb_lp_order - 2]) /
    (isf[amrwb_lp_order_16k - 2] - isf[amrwb_lp_order - 2])
  let mut j = 0
  for i = amrwb_lp_order - 1; i < amrwb_lp_order_16k - 1; i = i + 1 {
    diff_isf[j] = scale * (isf[i] - isf[i - 1])
    j += 1
  }
  // stability insurance
  for i = 1; i < amrwb_lp_order_16k - amrwb_lp_order; i = i + 1 {
    if diff_isf[i] + diff_isf[i - 1] < 5.0 {
      if diff_isf[i] > diff_isf[i - 1] {
        diff_isf[i - 1] = 5.0 - diff_isf[i]
      } else {
        diff_isf[i] = 5.0 - diff_isf[i - 1]
      }
    }
  }
  j = 0
  for i = amrwb_lp_order - 1; i < amrwb_lp_order_16k - 1; i = i + 1 {
    isf[i] = isf[i - 1] + diff_isf[j] * (1.0 / 32768.0)
    j += 1
  }
  // scale the ISF vector for 16000 Hz
  for i = 0; i < amrwb_lp_order_16k - 1; i = i + 1 {
    isf[i] *= 0.8
  }
}

///|
/// `lpc_weighting`: y[i] = x[i] * gamma^i.
fn amrwb_lpc_weighting(out : Array[Double], lpc : Array[Double], gamma : Double, size : Int32) -> Unit {
  let mut fac = gamma
  for i = 0; i < size; i = i + 1 {
    out[i] = lpc[i] * fac
    fac *= gamma
  }
}

///|
/// `hb_synthesis`: 20th order LPC synthesis of the high band at 16 kHz;
/// `samples_off` is where the subframe goes in `samples_hb`.
fn AmrWbDecoder::hb_synthesis(
  self : AmrWbDecoder,
  sub : Int32,
  samples_off : Int32,
  exc : Array[Double],
  isf : Array[Double],
  isf_past : Array[Double],
) -> Unit {
  let hb_lpc : Array[Double] = Array::make(amrwb_lp_order_16k, 0.0)
  let order = if self.fr_cur_mode == amrwb_mode_6k60 {
    let e_isf : Array[Double] = Array::make(amrwb_lp_order_16k, 0.0)
    let e_isp : Array[Double] = Array::make(amrwb_lp_order_16k, 0.0)
    let c = amrwb_isfp_inter[sub]
    amr_weighted_vector_sum(
      e_isf,
      0,
      isf_past,
      0,
      isf,
      0,
      c,
      1.0 - c,
      amrwb_lp_order,
    )
    amrwb_extrapolate_isf(e_isf)
    e_isf[amrwb_lp_order_16k - 1] *= 2.0
    amrwb_lsf2lspd(e_isp, e_isf, amrwb_lp_order_16k)
    amrwb_lsp2lpc(e_isp, hb_lpc, amrwb_lp_order_16k)
    amrwb_lpc_weighting(hb_lpc, hb_lpc, 0.9, amrwb_lp_order_16k)
    amrwb_lp_order_16k
  } else {
    amrwb_lpc_weighting(hb_lpc, self.lp_coef[sub], 0.6, amrwb_lp_order)
    amrwb_lp_order
  }
  amr_celp_lp_synthesis_filterf(
    self.samples_hb,
    samples_off,
    exc,
    0,
    hb_lpc,
    amrwb_sfr_size_16k,
    order,
  )
}

///|
/// `hb_fir_filter`: a 30th order FIR filter with `mem` carrying the last 30
/// inputs; `in` may alias `out`.
fn amrwb_hb_fir_filter(
  out : Array[Double],
  out_off : Int32,
  fir_coef : FixedArray[Double],
  mem : Array[Double],
  input : Array[Double],
  in_off : Int32,
) -> Unit {
  let data : Array[Double] = Array::make(amrwb_sfr_size_16k + amrwb_hb_fir_size, 0.0)
  for i = 0; i < amrwb_hb_fir_size; i = i + 1 {
    data[i] = mem[i]
  }
  for i = 0; i < amrwb_sfr_size_16k; i = i + 1 {
    data[amrwb_hb_fir_size + i] = input[in_off + i]
  }
  for i = 0; i < amrwb_sfr_size_16k; i = i + 1 {
    let mut v = 0.0
    for j = 0; j <= amrwb_hb_fir_size; j = j + 1 {
      v += data[i + j] * fir_coef[j]
    }
    out[out_off + i] = v
  }
  for i = 0; i < amrwb_hb_fir_size; i = i + 1 {
    mem[i] = data[amrwb_sfr_size_16k + i]
  }
}

///|
/// `update_sub_state`: shift the histories before the next subframe.
fn AmrWbDecoder::update_sub_state(self : AmrWbDecoder) -> Unit {
  let keep = amrwb_p_delay_max + amrwb_lp_order + 1
  for i = 0; i < keep; i = i + 1 {
    self.excitation_buf[i] = self.excitation_buf[amrwb_sfr_size + i]
  }
  // memmove(&pitch_gain[1], &pitch_gain[0], 5): copy backwards so the
  // overlapping shift does not propagate pitch_gain[0] into every slot
  let mut i = 4
  while i >= 0 {
    self.pitch_gain[i + 1] = self.pitch_gain[i]
    i = i - 1
  }
  self.fixed_gain[1] = self.fixed_gain[0]
  for i = 0; i < amrwb_lp_order; i = i + 1 {
    self.samples_az[i] = self.samples_az[amrwb_sfr_size + i]
  }
  for i = 0; i < amrwb_ups_mem_size; i = i + 1 {
    self.samples_up[i] = self.samples_up[amrwb_sfr_size + i]
  }
  for i = 0; i < amrwb_lp_order_16k; i = i + 1 {
    self.samples_hb[i] = self.samples_hb[amrwb_sfr_size_16k + i]
  }
}

// ---------------------------------------------------------------------------
// frame entry
// ---------------------------------------------------------------------------

///|
/// The bit-reordering table of one mode (`amr_bit_orderings_by_mode`).
fn amrwb_order_table(mode : Int32) -> FixedArray[Int32] {
  match mode {
    0 => amrwb_order_mode_6k60
    1 => amrwb_order_mode_8k85
    2 => amrwb_order_mode_12k65
    3 => amrwb_order_mode_14k25
    4 => amrwb_order_mode_15k85
    5 => amrwb_order_mode_18k25
    6 => amrwb_order_mode_19k85
    7 => amrwb_order_mode_23k05
    _ => amrwb_order_mode_23k85
  }
}

///|
/// `decode_mime_header`: the frame type and the quality bit of the TOC byte.
fn AmrWbDecoder::decode_mime_header(self : AmrWbDecoder, data : Bytes) -> Unit {
  self.fr_cur_mode = (data[0].to_int() >> 3) & 0x0F
  self.fr_quality = (data[0].to_int() & 0x4) == 0x4
}

///|
/// Total byte size of one AMR-WB frame (table-of-contents byte plus speech
/// payload) by its frame type: the nine speech/noise modes and NO_DATA.
/// The reserved frame types return 0.
pub fn amrwb_frame_size(frame : Bytes) -> Int32 {
  if frame.length() < 1 {
    return 0
  }
  let mode = (frame[0].to_int() >> 3) & 0x0F
  if mode > amrwb_mode_sid && mode != amrwb_no_data {
    return 0
  }
  amrwb_packed_size[mode]
}

///|
/// Decode one AMR-WB frame (TOC byte plus speech payload) to 320 samples at
/// 16 kHz in `[-1, 1)`. A NO_DATA frame or a frame whose quality bit is
/// clear decodes to silence, as in the C.
pub fn AmrWbDecoder::decode_frame(
  self : AmrWbDecoder,
  data : Bytes,
) -> Result[Array[Double], String] {
  if data.length() < 1 {
    return Err("amrwb: empty frame")
  }
  self.decode_mime_header(data)
  let expected_fr_size = ((amrwb_cf_sizes_wb[self.fr_cur_mode] + 7) >> 3) + 1
  if self.fr_cur_mode == amrwb_no_data || !self.fr_quality {
    // The specification suggests "a random signal" and "a muting
    // technique" to "gradually decrease the output level".
    return Ok(Array::make(4 * amrwb_sfr_size_16k, 0.0))
  }
  if self.fr_cur_mode > amrwb_mode_sid {
    return Err("amrwb: invalid mode \{self.fr_cur_mode}")
  }
  if data.length() < expected_fr_size {
    return Err(
      "amrwb: frame too small (\{data.length()} bytes). Truncated file?",
    )
  }
  if self.fr_cur_mode == amrwb_mode_sid {
    return Err("amrwb: SID (comfort noise) mode is not supported")
  }
  let words = amr_unpack_words(amrwb_order_table(self.fr_cur_mode), data[1:].to_owned())
  // AMRWBFrame words: vad, isp_id[7], then 12 words per subframe
  // (adap, ltp, vq_gain, hb_gain, pul_ih[4], pul_il[4]).
  let isp_id = FixedArray::makei(7, i => words[1 + i])
  let vad = words[0]
  if self.fr_cur_mode == amrwb_mode_6k60 {
    amrwb_decode_isf_indices_36b(isp_id, self.isf_cur)
  } else {
    amrwb_decode_isf_indices_46b(isp_id, self.isf_cur)
  }
  amrwb_isf_add_mean_and_past(self.isf_cur, self.isf_q_past)
  amrwb_set_min_dist_lsf(self.isf_cur, amrwb_min_isf_spacing, amrwb_lp_order - 1)
  let stab_fac = amrwb_stability_factor(self.isf_cur, self.isf_past_final)
  self.isf_cur[amrwb_lp_order - 1] *= 2.0
  amrwb_lsf2lspd(self.isp[3], self.isf_cur, amrwb_lp_order)
  // an ISP vector for each subframe
  if self.first_frame {
    self.first_frame = false
    for i = 0; i < amrwb_lp_order; i = i + 1 {
      self.isp_sub4_past[i] = self.isp[3][i]
    }
  }
  amrwb_interpolate_isp(self.isp, self.isp_sub4_past)
  for sub = 0; sub < 4; sub = sub + 1 {
    amrwb_lsp2lpc(self.isp[sub], self.lp_coef[sub], amrwb_lp_order)
  }
  let out = Array::make(4 * amrwb_sfr_size_16k, 0.0)
  let synth_exc : Array[Double] = Array::make(amrwb_sfr_size, 0.0)
  let spare_vector : Array[Double] = Array::make(amrwb_sfr_size, 0.0)
  let hb_exc : Array[Double] = Array::make(amrwb_sfr_size_16k, 0.0)
  let hb_samples : Array[Double] = Array::make(amrwb_sfr_size_16k, 0.0)
  for sub = 0; sub < 4; sub = sub + 1 {
    let base = 8 + 12 * sub
    let adap = words[base]
    let ltp = words[base + 1]
    let vq_gain = words[base + 2]
    let hb_gain = words[base + 3]
    let pul_ih = FixedArray::makei(4, k => words[base + 4 + k])
    let pul_il = FixedArray::makei(4, k => words[base + 8 + k])
    // adaptive codebook (pitch vector)
    self.decode_pitch_vector(adap, ltp, sub)
    // innovative codebook (fixed vector)
    amrwb_decode_fixed_vector(self.fixed_vector, pul_ih, pul_il, self.fr_cur_mode)
    self.pitch_sharpening()
    let (pitch_gain, fixed_gain_factor) = amrwb_decode_gains(vq_gain, self.fr_cur_mode)
    self.pitch_gain[0] = pitch_gain
    // the fixed gain's float result, from the float-rounded energy
    self.fixed_gain[0] = amr_set_fixed_gain(
      fixed_gain_factor,
      amr_f32(amr_dot(self.fixed_vector, 0, self.fixed_vector, 0, amrwb_sfr_size) /
        amrwb_sfr_size.to_double()),
      self.prediction_error,
      amrwb_energy_mean,
      amrwb_energy_pred_fac,
    )
    // voice factor; the tilt is stored for the next subframe
    let voice_fac = amrwb_voice_factor(
      self.pitch_vector,
      self.pitch_gain[0],
      self.fixed_vector,
      self.fixed_gain[0],
    )
    self.tilt_coef = voice_fac * 0.25 + 0.25
    // current excitation
    let ex = amrwb_excitation_off
    for i = 0; i < amrwb_sfr_size; i = i + 1 {
      // the C's float arithmetic step by step, then truncf
      let a = amr_f32(self.excitation_buf[ex + i] * self.pitch_gain[0])
      let b = amr_f32(self.fixed_gain[0] * self.fixed_vector[i])
      self.excitation_buf[ex + i] = amr_trunc(amr_f32(a + b))
    }
    // post-processing of the excitation elements
    let synth_fixed_gain = self.noise_enhancer(self.fixed_gain[0], voice_fac, stab_fac)
    let use_spare = self.anti_sparseness(self.fixed_vector, spare_vector)
    let synth_fixed_vector = if use_spare { spare_vector } else { self.fixed_vector }
    amrwb_pitch_enhancer(synth_fixed_vector, voice_fac)
    self.synthesis(sub, synth_exc, synth_fixed_gain, synth_fixed_vector, amrwb_lp_order)
    // synthesis speech post-processing
    amrwb_de_emphasis(
      self.samples_up,
      amrwb_ups_mem_size,
      self.samples_az,
      amrwb_lp_order,
      amrwb_preemph_fac,
      self.demph_mem,
    )
    amrwb_apply_order_2(
      self.samples_up,
      amrwb_ups_mem_size,
      self.samples_up,
      amrwb_ups_mem_size,
      amrwb_hpf_zeros,
      amrwb_hpf_31_poles,
      amrwb_hpf_31_gain,
      self.hpf_31_mem,
      amrwb_sfr_size,
    )
    let sub_off = sub * amrwb_sfr_size_16k
    self.upsample_5_4(out, sub_off)
    // high frequency band (6.4 - 7.0 kHz) generation part
    amrwb_apply_order_2(
      hb_samples,
      0,
      self.samples_up,
      amrwb_ups_mem_size,
      amrwb_hpf_zeros,
      amrwb_hpf_400_poles,
      amrwb_hpf_400_gain,
      self.hpf_400_mem,
      amrwb_sfr_size,
    )
    let hb_gain_v = self.find_hb_gain(hb_samples, hb_gain, vad)
    self.scaled_hb_excitation(hb_exc, synth_exc, hb_gain_v)
    self.hb_synthesis(
      sub,
      amrwb_lp_order_16k,
      hb_exc,
      self.isf_cur,
      self.isf_past_final,
    )
    // high-band post-processing filters
    amrwb_hb_fir_filter(
      hb_samples,
      0,
      amrwb_bpf_6_7_coef,
      self.bpf_6_7_mem,
      self.samples_hb,
      amrwb_lp_order_16k,
    )
    if self.fr_cur_mode == 8 {
      amrwb_hb_fir_filter(
        hb_samples,
        0,
        amrwb_lpf_7_coef,
        self.lpf_7_mem,
        hb_samples,
        0,
      )
    }
    // add the low and high frequency bands
    for i = 0; i < amrwb_sfr_size_16k; i = i + 1 {
      out[sub_off + i] = (out[sub_off + i] + hb_samples[i]) * (1.0 / 32768.0)
    }
    self.update_sub_state()
  }
  // state for the next frame
  for i = 0; i < amrwb_lp_order; i = i + 1 {
    self.isp_sub4_past[i] = self.isp[3][i]
    self.isf_past_final[i] = self.isf_cur[i]
  }
  Ok(out)
}
