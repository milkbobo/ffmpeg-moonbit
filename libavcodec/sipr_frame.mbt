///|
/// The SIPR frame below 16 kHz (`decode_frame` of FFmpeg 9.0.2
/// `libavcodec/sipr.c`) and the `lsp.c` functions it builds on. See
/// `sipr.mbt` for the module notes. Original FFmpeg code is LGPL-2.1-or-later;
/// this port keeps the same license.

// ---------------------------------------------------------------------------
// LSP helpers (lsp.c)
// ---------------------------------------------------------------------------

///|
/// `lsp2polyf`: the Pa / (1 + z^-1) or Qa / (1 - z^-1) polynomial of the
/// cosine-domain LSPs (TIA/EIA/IS-733 2.4.3.3.5-1/2).
fn sipr_lsp2polyf(
  lsp : Array[Double],
  lsp_off : Int32,
  f : Array[Double],
  lp_half_order : Int32,
) -> Unit {
  f[0] = 1.0
  f[1] = -2.0 * lsp[lsp_off]
  for i = 2; i <= lp_half_order; i = i + 1 {
    let val = -2.0 * lsp[lsp_off + 2 * i - 2]
    f[i] = val * f[i - 1] + 2.0 * f[i - 2]
    let mut j = i - 1
    while j > 1 {
      f[j] = f[j] + f[j - 1] * val + f[j - 2]
      j = j - 1
    }
    f[1] = f[1] + val
  }
}

///|
/// `ff_acelp_lspd2lpc`: cosine-domain LSPs to LP coefficients (order
/// `2 * lp_half_order`).
fn sipr_lspd2lpc(
  lsp : Array[Double],
  lpc : Array[Double],
  lpc_off : Int32,
  lp_half_order : Int32,
) -> Unit {
  let pa = Array::make(lp_half_order + 1, 0.0)
  let qa = Array::make(lp_half_order + 1, 0.0)
  sipr_lsp2polyf(lsp, 0, pa, lp_half_order)
  sipr_lsp2polyf(lsp, 1, qa, lp_half_order)
  // lpc2 points at the last coefficient
  let last = lpc_off + (lp_half_order << 1) - 1
  let mut h = lp_half_order - 1
  while h >= 0 {
    let paf = pa[h + 1] + pa[h]
    let qaf = qa[h + 1] - qa[h]
    lpc[lpc_off + h] = 0.5 * (paf + qaf)
    lpc[last - h] = 0.5 * (paf - qaf)
    h = h - 1
  }
}

///|
/// `ff_amrwb_lsp2lpc` for order 10: LP coefficients of the cosine-domain
/// LSPs of an AMR wideband (here SIPR) frame.
fn sipr_amrwb_lsp2lpc(
  lsp : Array[Double],
  lp : Array[Double],
  lp_off : Int32,
) -> Unit {
  let half = 5
  let pa = Array::make(half + 1, 0.0)
  let qa = Array::make(half, 0.0)
  sipr_lsp2polyf(lsp, 0, pa, half)
  sipr_lsp2polyf(lsp, 1, qa, half - 1)
  let last = lsp[9]
  let mut i = 1
  let mut j = 9
  while i < half {
    let paf = pa[i] * (1.0 + last)
    let previous = if i == 1 { 0.0 } else { qa[i - 2] }
    let qaf = (qa[i] - previous) * (1.0 - last)
    lp[lp_off + i - 1] = (paf + qaf) * 0.5
    lp[lp_off + j - 1] = (paf - qaf) * 0.5
    i = i + 1
    j = j - 1
  }
  lp[lp_off + half - 1] = (1.0 + last) * pa[half] * 0.5
  lp[lp_off + 9] = last
}

// ---------------------------------------------------------------------------
// small generic helpers
// ---------------------------------------------------------------------------

///|
/// `ff_sort_nearly_sorted_floats`: an insertion sort of the first `len`
/// values.
fn sipr_sort_nearly_sorted(vals : Array[Double], len : Int32) -> Unit {
  for i = 0; i < len - 1; i = i + 1 {
    let mut j = i
    while j >= 0 && vals[j] > vals[j + 1] {
      let t = vals[j]
      vals[j] = vals[j + 1]
      vals[j + 1] = t
      j = j - 1
    }
  }
}

///|
/// `ff_set_min_dist_lsf`.
fn sipr_set_min_dist_lsf(
  lsf : Array[Double],
  min_spacing : Double,
  size : Int32,
) -> Unit {
  let mut prev = 0.0
  for i = 0; i < size; i = i + 1 {
    let v = lsf[i]
    prev = if v > prev + min_spacing { v } else { prev + min_spacing }
    lsf[i] = prev
  }
}

///|
/// `ff_acelp_apply_order_2_transfer_function` over `n` samples.
fn sipr_apply_order_2(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  zeros : FixedArray[Double],
  poles : FixedArray[Double],
  gain : Double,
  mem : Array[Double],
  n : Int32,
) -> Unit {
  for i = 0; i < n; i = i + 1 {
    let tmp = gain * src[src_off + i] - poles[0] * mem[0] - poles[1] * mem[1]
    out[out_off + i] = tmp + zeros[0] * mem[0] + zeros[1] * mem[1]
    mem[1] = mem[0]
    mem[0] = tmp
  }
}

// ---------------------------------------------------------------------------
// the frame
// ---------------------------------------------------------------------------

///|
/// `dequant` of the below-16k modes: five two-entry vectors.
fn sipr_dequant(idx : FixedArray[Int32], out : Array[Double]) -> Unit {
  let books : FixedArray[FixedArray[Double]] = [
    sipr_lsf_cb1, sipr_lsf_cb2, sipr_lsf_cb3, sipr_lsf_cb4, sipr_lsf_cb5,
  ]
  for i = 0; i < 5; i = i + 1 {
    out[2 * i] = books[i][2 * idx[i]]
    out[2 * i + 1] = books[i][2 * idx[i] + 1]
  }
}

///|
/// `lsf_decode_fp`: the LSFs (cosine domain, the last one scaled) of one
/// below-16k frame.
fn sipr_lsf_decode_fp(
  lsf_history : Array[Double],
  vq_indexes : FixedArray[Int32],
) -> Array[Double] {
  let lsf_tmp = Array::make(sipr_lp_filter_order, 0.0)
  let lsfnew = Array::make(sipr_lp_filter_order, 0.0)
  sipr_dequant(vq_indexes, lsf_tmp)
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    lsfnew[i] = lsf_history[i] * 0.33 + lsf_tmp[i] + sipr_mean_lsf[i]
  }
  sipr_sort_nearly_sorted(lsfnew, sipr_lp_filter_order - 1)
  // Note that a minimum distance is not enforced between the last value and
  // the previous one, contrary to what is done in ff_acelp_reorder_lsf()
  sipr_set_min_dist_lsf(lsfnew, sipr_lsfq_diff_min, sipr_lp_filter_order - 1)
  let cap = 1.3 * sipr_pi
  lsfnew[9] = if lsfnew[9] < cap { lsfnew[9] } else { cap }
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    lsf_history[i] = lsf_tmp[i]
  }
  for i = 0; i < sipr_lp_filter_order - 1; i = i + 1 {
    lsfnew[i] = @math.cos(lsfnew[i])
  }
  lsfnew[9] *= 6.153848 / sipr_pi
  lsfnew
}

///|
/// `sipr_decode_lp`: the LP coefficients of every subframe, from the LSFs
/// interpolated between the previous and the new frame.
fn sipr_decode_lp(
  lsfnew : Array[Double],
  lsfold : Array[Double],
  az : Array[Double],
  num_subfr : Int32,
) -> Unit {
  let lsfint = Array::make(sipr_lp_filter_order, 0.0)
  let t0 = 1.0 / num_subfr.to_double()
  let mut t = t0 * 0.5
  for i = 0; i < num_subfr; i = i + 1 {
    for j = 0; j < sipr_lp_filter_order; j = j + 1 {
      lsfint[j] = lsfold[j] * (1.0 - t) + t * lsfnew[j]
    }
    sipr_amrwb_lsp2lpc(lsfint, az, i * sipr_lp_filter_order)
    t += t0
  }
}

///|
/// `pitch_sharpening` (AMR section 6.1.2).
fn sipr_pitch_sharpening(
  pitch_lag_int : Int32,
  beta : Double,
  fixed_vector : Array[Double],
  off : Int32,
) -> Unit {
  for i = pitch_lag_int; i < sipr_subfr_size; i = i + 1 {
    fixed_vector[off + i] += beta * fixed_vector[off + i - pitch_lag_int]
  }
}

///|
/// `eval_ir`: the impulse response of the subframe, written to
/// `ir_buf[LP_FILTER_ORDER ..]` (the ten entries before it are zero history).
fn sipr_eval_ir(
  az : Array[Double],
  az_off : Int32,
  pitch_lag : Int32,
  ir_buf : Array[Double],
  pitch_sharp_factor : Double,
) -> Unit {
  let tmp1 = Array::make(sipr_subfr_size + 1, 0.0)
  let tmp2 = Array::make(sipr_lp_filter_order, 0.0)
  tmp1[0] = 1.0
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    tmp1[i + 1] = az[az_off + i] * sipr_pow_0_55[i]
    tmp2[i] = az[az_off + i] * sipr_pow_0_7[i]
  }
  // tmp1[11 ..] is zero, as the C's memset leaves it
  amr_celp_lp_synthesis_filterf(
    ir_buf, sipr_lp_filter_order, tmp1, 0, tmp2, sipr_subfr_size, sipr_lp_filter_order,
  )
  sipr_pitch_sharpening(
    pitch_lag, pitch_sharp_factor, ir_buf, sipr_lp_filter_order,
  )
}

///|
/// `convolute_with_sparse`: the sparse fixed codebook convolved with the
/// impulse response `shape`.
fn sipr_convolute_with_sparse(
  pulses : SiprFixed,
  shape : Array[Double],
  shape_off : Int32,
  length : Int32,
) -> Array[Double] {
  let out = Array::make(length, 0.0)
  for i = 0; i < pulses.n; i = i + 1 {
    for j = pulses.x[i]; j < length; j = j + 1 {
      out[j] += pulses.y[i] * shape[shape_off + j - pulses.x[i]]
    }
  }
  out
}

///|
/// `postfilter_5k0`: the formant postfilter of the 5k0 mode, in place.
fn SiprDecoder::postfilter_5k0(
  self : SiprDecoder,
  az : Array[Double],
  az_off : Int32,
  samples : Array[Double],
) -> Unit {
  let lpc_n = Array::make(sipr_lp_filter_order, 0.0)
  let lpc_d = Array::make(sipr_lp_filter_order, 0.0)
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    lpc_d[i] = az[az_off + i] * sipr_pow_0_75[i]
    lpc_n[i] = az[az_off + i] * sipr_pow_0_5[i]
  }
  let buf = Array::make(sipr_subfr_size + sipr_lp_filter_order, 0.0)
  let pole_out = sipr_lp_filter_order
  let tail = pole_out + sipr_subfr_size - sipr_lp_filter_order
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    buf[i] = self.postfilter_mem[i]
  }
  amr_celp_lp_synthesis_filterf(
    buf, pole_out, samples, 0, lpc_d, sipr_subfr_size, sipr_lp_filter_order,
  )
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    self.postfilter_mem[i] = buf[tail + i]
  }
  amr_tilt_compensation(buf, pole_out, self.tilt_mem, 0.4, sipr_subfr_size)
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    buf[i] = self.postfilter_mem5k0[i]
  }
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    self.postfilter_mem5k0[i] = buf[tail + i]
  }
  amr_celp_lp_zero_synthesis_filterf(
    samples, 0, buf, pole_out, lpc_n, sipr_subfr_size, sipr_lp_filter_order,
  )
}

///|
/// `decode_fixed_sparse`: the pulses of the fixed codebook of one subframe.
fn sipr_decode_fixed_sparse(
  pulses : FixedArray[Int32],
  mode : Int32,
  low_gain : Bool,
) -> SiprFixed {
  let f = SiprFixed::new()
  if mode == 2 { // MODE_6k5
    for i = 0; i < 3; i = i + 1 {
      f.x[i] = 3 * (pulses[i] & 0xF) + i
      f.y[i] = if (pulses[i] & 0x10) != 0 { -1.0 } else { 1.0 }
    }
    f.n = 3
  } else if mode == 1 { // MODE_8k5
    for i = 0; i < 3; i = i + 1 {
      f.x[2 * i] = 3 * ((pulses[i] >> 4) & 0xF) + i
      f.x[2 * i + 1] = 3 * (pulses[i] & 0xF) + i
      f.y[2 * i] = if (pulses[i] & 0x100) != 0 { -1.0 } else { 1.0 }
      f.y[2 * i + 1] = if f.x[2 * i + 1] < f.x[2 * i] {
        -f.y[2 * i]
      } else {
        f.y[2 * i]
      }
    }
    f.n = 6
  } else if low_gain { // MODE_5k0
    let offset = if (pulses[0] & 0x200) != 0 { 2 } else { 0 }
    let mut val = pulses[0]
    for i = 0; i < 3; i = i + 1 {
      let index = (val & 0x7) * 6 + 4 - i * 2
      f.y[i] = if ((offset + index) & 0x3) != 0 { -1.0 } else { 1.0 }
      f.x[i] = index
      val = val >> 3
    }
    f.n = 3
  } else { // MODE_5k0
    let pulse_subset = (pulses[0] >> 8) & 1
    f.x[0] = ((pulses[0] >> 4) & 15) * 3 + pulse_subset
    f.x[1] = (pulses[0] & 15) * 3 + pulse_subset + 1
    f.y[0] = if (pulses[0] & 0x200) != 0 { -1.0 } else { 1.0 }
    f.y[1] = -f.y[0]
    f.n = 2
  }
  f
}

///|
/// The zeros, poles and gain of the high-pass filter that closes a frame.
let sipr_hp_zeros : FixedArray[Double] = [-1.99997, 1.0]

///|
let sipr_hp_poles : FixedArray[Double] = [-1.93307352, 0.935891986]

///|
let sipr_hp_gain : Double = 0.939805806

///|
/// `decode_frame`: one frame of a below-16k mode (`subframe_count` subframes
/// of 48 samples) written to `out[out_off ..]`.
fn SiprDecoder::decode_frame(
  self : SiprDecoder,
  params : SiprParameters,
  out : Array[Double],
  out_off : Int32,
) -> Unit {
  let p = sipr_modes[self.mode]
  let subframe_count = p.subframe_count
  let frame_size = subframe_count * sipr_subfr_size
  let az = Array::make(5 * sipr_lp_filter_order, 0.0)
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    self.ir_buf[i] = 0.0
  }
  let lsf_new = sipr_lsf_decode_fp(self.lsf_history, params.vq_indexes)
  sipr_decode_lp(lsf_new, self.lsp_history, az, subframe_count)
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    self.lsp_history[i] = lsf_new[i]
  }
  let synth = 16
  let mut t0_first = 0
  for i = 0; i < subframe_count; i = i + 1 {
    let az_off = i * sipr_lp_filter_order
    let ex = sipr_excitation_history + i * sipr_subfr_size
    let lag_int : Ref[Int32] = Ref(0)
    let lag_frac : Ref[Int32] = Ref(0)
    amr_decode_pitch_lag(
      lag_int,
      lag_frac,
      params.pitch_delay[i],
      t0_first,
      i,
      self.mode == 3,
      6,
    )
    let t0 = lag_int.val
    let t0_frac = lag_frac.val
    if i == 0 || (i == 2 && self.mode == 3) {
      t0_first = t0
    }
    amr_acelp_interpolatef(
      self.excitation,
      ex,
      self.excitation,
      ex - t0 + (if t0_frac <= 0 { 1 } else { 0 }),
      amr_b60_sinc,
      6,
      2 * ((2 + t0_frac) % 3 + 1),
      sipr_lp_filter_order,
      sipr_subfr_size,
    )
    let fixed_cb = sipr_decode_fixed_sparse(
      params.fc_indexes[i],
      self.mode,
      self.past_pitch_gain < 0.8,
    )
    sipr_eval_ir(az, az_off, t0, self.ir_buf, p.pitch_sharp_factor)
    let fixed_vector = sipr_convolute_with_sparse(
      fixed_cb,
      self.ir_buf,
      sipr_lp_filter_order,
      sipr_subfr_size,
    )
    let avg_energy = (
        0.01 + amr_dot(fixed_vector, 0, fixed_vector, 0, sipr_subfr_size)
      ) /
      sipr_subfr_size.to_double()
    self.past_pitch_gain = sipr_gain_cb[params.gc_index[i] * 2]
    let pitch_gain = self.past_pitch_gain
    let mut gain_code = amr_set_fixed_gain(
      sipr_gain_cb[params.gc_index[i] * 2 + 1],
      avg_energy,
      self.energy_history,
      sipr_energy_mean(34.0),
      sipr_pred,
    )
    amr_weighted_vector_sum(
      self.excitation,
      ex,
      self.excitation,
      ex,
      fixed_vector,
      0,
      pitch_gain,
      gain_code,
      sipr_subfr_size,
    )
    let mut sharpened = pitch_gain * 0.5 * pitch_gain
    if sharpened > 0.4 {
      sharpened = 0.4
    }
    self.gain_mem = 0.7 * self.gain_mem + 0.3 * sharpened
    if self.gain_mem > sharpened {
      self.gain_mem = sharpened
    }
    gain_code *= self.gain_mem
    for j = 0; j < sipr_subfr_size; j = j + 1 {
      fixed_vector[j] = self.excitation[ex + j] - gain_code * fixed_vector[j]
    }
    if self.mode == 3 {
      self.postfilter_5k0(az, az_off, fixed_vector)
      sipr_lp_synthesis_filterf(
        self.postfilter_syn5k0,
        sipr_lp_filter_order + i * sipr_subfr_size,
        self.excitation,
        ex,
        az,
        az_off,
        sipr_subfr_size,
        sipr_lp_filter_order,
      )
    }
    sipr_lp_synthesis_filterf(
      self.synth_buf,
      synth + i * sipr_subfr_size,
      fixed_vector,
      0,
      az,
      az_off,
      sipr_subfr_size,
      sipr_lp_filter_order,
    )
  }

  // the last samples become the history of the next frame
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    self.synth_buf[synth - sipr_lp_filter_order + i] = self.synth_buf[synth +
      frame_size -
      sipr_lp_filter_order +
      i]
  }
  if self.mode == 3 {
    for i = 0; i < subframe_count; i = i + 1 {
      let pf = sipr_lp_filter_order + i * sipr_subfr_size
      let energy = amr_dot(
        self.postfilter_syn5k0,
        pf,
        self.postfilter_syn5k0,
        pf,
        sipr_subfr_size,
      )
      amr_adaptive_gain_control(
        self.synth_buf,
        synth + i * sipr_subfr_size,
        self.synth_buf,
        synth + i * sipr_subfr_size,
        energy,
        sipr_subfr_size,
        0.9,
        self.postfilter_agc,
      )
    }
    for i = 0; i < sipr_lp_filter_order; i = i + 1 {
      self.postfilter_syn5k0[i] = self.postfilter_syn5k0[frame_size + i]
    }
  }
  // memmove(ctx->excitation, excitation - PITCH_DELAY_MAX - L_INTERPOL, ...)
  for i = 0; i < sipr_excitation_history; i = i + 1 {
    self.excitation[i] = self.excitation[frame_size + i]
  }
  sipr_apply_order_2(
    out,
    out_off,
    self.synth_buf,
    synth,
    sipr_hp_zeros,
    sipr_hp_poles,
    sipr_hp_gain,
    self.highpass_filt_mem,
    frame_size,
  )
}

///|
/// Synthesize using the LPC coefficients for the selected subframe.
fn sipr_lp_synthesis_filterf(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  coeffs : Array[Double],
  coeffs_off : Int32,
  buffer_length : Int32,
  filter_length : Int32,
) -> Unit {
  for n = 0; n < buffer_length; n = n + 1 {
    let mut v = src[src_off + n]
    for i = 1; i <= filter_length; i = i + 1 {
      v -= coeffs[coeffs_off + i - 1] * out[out_off + n - i]
    }
    out[out_off + n] = v
  }
}
