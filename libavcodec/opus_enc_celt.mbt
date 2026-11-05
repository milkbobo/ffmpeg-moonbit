/// MoonBit port of the CELT encoding path of FFmpeg 9.0.2 `libavcodec/opus/`
/// (`enc.c`: input staging, pre-emphasis, forward MDCT, band energies;
/// coarse/fine/final energy quantisation and the tf change encoder).
///
/// All arithmetic is single precision like the C (`Float`), except the
/// forward MDCT and the deterministic libm replacements (`opus_enc_*`); the
/// forward MDCT is the direct double-precision evaluation of the naive
/// reference transform in `libavutil/tx_template.c` (upstream uses the FFT
/// based `av_tx`); the C reference harness uses the same direct transform.
///
/// The encoder produces CELT-only mono/stereo packets at 48 kHz with
/// `frame_size = OPUS_BLOCK_SIZE(3) = 960` samples per frame (the default
/// 360 ms lookahead folds to the 20 ms block size upstream).

///|
/// `CELT_OVERLAP` / `CELT_MAX_BANDS` / `CELT_MAX_FRAME_SIZE`.
let opus_enc_overlap : Int32 = 120

///|
let opus_enc_max_bands : Int32 = 21

///|
let opus_enc_max_frame_size : Int32 = 960

///|
/// `CELT_ENERGY_SILENCE`.
let opus_enc_energy_silence : Float = -28.0

///|
/// Per-channel CELT encoder block (`CeltBlock` fields used when encoding).
priv struct OpusEncCeltBlock {
  energy : Array[Float]
  lin_energy : Array[Float]
  error_energy : Array[Float]
  collapse_masks : Array[UInt32]
  /// MDCT output coefficients (`coeffs`, max frame size).
  coeffs : Array[Float]
  /// Previous packet's trailing overlap (`overlap`, 128 allocated).
  overlap : Array[Float]
  /// Current packet's samples (`samples`); 960 entries + 8 slack (the C
  /// window reads 8 past the end multiplied by the window's zero taps).
  samples : Array[Float]
  /// `emph_coeff`.
  mut emph_coeff : Float
  pf_gains_new : Array[Float]
}

///|
fn OpusEncCeltBlock::new() -> OpusEncCeltBlock {
  {
    energy: Array::make(opus_enc_max_bands, 0.0),
    lin_energy: Array::make(opus_enc_max_bands, 0.0),
    error_energy: Array::make(opus_enc_max_bands, 0.0),
    collapse_masks: Array::make(opus_enc_max_bands, 0U),
    coeffs: Array::make(opus_enc_max_frame_size, 0.0),
    overlap: Array::make(128, 0.0),
    samples: Array::make(opus_enc_max_frame_size + 8, 0.0),
    emph_coeff: 0.0,
    pf_gains_new: Array::make(3, 0.0),
  }
}

///|
/// One queued PCM frame (planar float).
struct OpusEncPcmFrame {
  nb_samples : Int32
  data : Array[Array[Float]]
}

///|
/// CELT frame under encoding (`CeltFrame`, encoder fields).
struct OpusEncCeltFrame {
  block : Array[OpusEncCeltBlock]
  mut channels : Int32
  /// block size index 0..3 (120..960).
  mut size : Int32
  mut start_band : Int32
  mut end_band : Int32
  mut coded_bands : Int32
  mut transient : Int32
  mut pfilter : Int32
  mut skip_band_floor : Int32
  mut tf_select : Int32
  mut alloc_trim : Int32
  alloc_boost : Array[Int32]
  mut blocks : Int32
  mut silence : Int32
  mut anticollapse_needed : Int32
  mut anticollapse : Int32
  mut intensity_stereo : Int32
  mut dual_stereo : Bool
  mut seed : UInt32
  mut spread : Int32
  mut pf_octave : Int32
  mut pf_period : Int32
  mut pf_tapset : Int32
  mut pf_gain : Float
  mut framebits : Int32
  mut remaining : Int32
  mut remaining2 : Int32
  caps : Array[Int32]
  fine_bits : Array[Int32]
  fine_priority : Array[Int32]
  pulses : Array[Int32]
  tf_change : Array[Int32]
  apply_phase_inv : Bool
  /// PVQ pulse scratch (`pvq->qcoeff`).
  pulse_scratch : Array[Int32]
}

///|
fn OpusEncCeltFrame::new(
  channels : Int32,
  apply_phase_inv : Bool,
) -> OpusEncCeltFrame {
  {
    block: [OpusEncCeltBlock::new(), OpusEncCeltBlock::new()],
    channels,
    size: 3,
    start_band: 0,
    end_band: opus_enc_band_end[3],
    coded_bands: 0,
    transient: 0,
    pfilter: 0,
    skip_band_floor: 0,
    tf_select: 0,
    alloc_trim: 5,
    alloc_boost: Array::make(opus_enc_max_bands, 0),
    blocks: 1,
    silence: 0,
    anticollapse_needed: 0,
    anticollapse: 0,
    intensity_stereo: 0,
    dual_stereo: false,
    seed: 0U,
    spread: 0,
    pf_octave: 0,
    pf_period: 0,
    pf_tapset: 0,
    pf_gain: 0.0,
    framebits: 0,
    remaining: 0,
    remaining2: 0,
    caps: Array::make(opus_enc_max_bands, 0),
    fine_bits: Array::make(opus_enc_max_bands, 0),
    fine_priority: Array::make(opus_enc_max_bands, 0),
    pulses: Array::make(opus_enc_max_bands, 0),
    tf_change: Array::make(opus_enc_max_bands, 0),
    apply_phase_inv,
    pulse_scratch: Array::make(176, 0),
  }
}

///|
/// Forward MDCT of the fully windowed `2N`-sample input, the direct
/// evaluation of the naive reference in `libavutil/tx_template.c`:
/// `dst[i*stride] = scale * sum_j src[j]*cos(pi/(4N)*(2j+1+N)*(2i+1))`.
fn opus_enc_mdct_fwd(
  dst : Array[Float],
  dst_off : Int32,
  src : Array[Float],
  n : Int32,
  scale : Float,
  stride_out : Int32,
) -> Unit {
  for i in 0..<n {
    let mi = 2 * i + 1
    let mut sum = 0.0
    for j in 0..<(2 * n) {
      let a = (2 * j + 1 + n) * mi
      // naive MDCT: cos(pi/(4N) * a) with a = (2j+1+N)*(2i+1)
      let c = opus_enc_cos_multiple(a, n)
      sum += src[j].to_double() * c
    }
    dst[dst_off + i * stride_out] = Float::from_double(sum * scale.to_double())
  }
}

///|
/// cos of `m * pi / (4*den)` with the angle folded modulo one turn.
fn opus_enc_cos_multiple(m : Int32, den : Int32) -> Double {
  let mut mm = m % (8 * den)
  if mm < 0 {
    mm += 8 * den
  }
  let mut a = mm.to_double() *
    (3.14159265358979323846 / (4.0 * den.to_double()))
  let mut neg = false
  if a > 3.14159265358979323846 {
    a = 6.28318530717958647693 - a
  }
  if a > 1.57079632679489661923 {
    a = 3.14159265358979323846 - a
    neg = true
  }
  let c = opus_enc_cos_half(a)
  if neg {
    -c
  } else {
    c
  }
}

///|
/// sin on [0, pi/2] via half-angle descent into the [0, pi/4] Taylor series.
/// `sum_k (-1)^k x^(2k+1)/(2k+1)!`, i.e. the factorials `1/(2k+1)!`.
fn opus_enc_sin_half(x : Double) -> Double {
  if x <= 0.78539816339744830962 {
    let inv_fact : Array[Double] = [
      1.0, 0.16666666666666666, 0.008333333333333333, 0.0001984126984126984, 2.7557319223985893e-06,
      2.505210838544172e-08, 1.6059043836821613e-10, 7.647163731819816e-13, 2.8114572543455206e-15,
    ]
    let t2 = x * x
    let mut tp = x
    let mut sum = 0.0
    for k in 0..<9 {
      let term = tp * inv_fact[k]
      sum += if k % 2 == 0 { term } else { -term }
      tp = tp * t2
    }
    return sum
  }
  let h = x / 2.0
  2.0 * opus_enc_sin_half(h) * opus_enc_cos_half(h)
}

///|
/// cos on [0, pi/2] via half-angle descent into the [0, pi/4] Taylor series.
/// `sum_k (-1)^k x^(2k)/(2k)!`, i.e. the factorials `1/(2k)!`.
fn opus_enc_cos_half(x : Double) -> Double {
  if x <= 0.78539816339744830962 {
    let inv_fact : Array[Double] = [
      1.0, 0.5, 0.041666666666666664, 0.001388888888888889, 2.48015873015873e-05,
      2.755731922398589e-07, 2.08767569878681e-09, 1.1470745597729725e-11,
    ]
    let t2 = x * x
    let mut tp = 1.0
    let mut sum = 0.0
    for k in 0..<8 {
      let term = tp * inv_fact[k]
      sum += if k % 2 == 0 { term } else { -term }
      tp = tp * t2
    }
    return sum
  }
  let h = x / 2.0
  let sh = opus_enc_sin_half(h)
  let ch = opus_enc_cos_half(h)
  ch * ch - sh * sh
}

///|
/// `celt_apply_preemph_filter`: first-order pre-emphasis with the deemphasis
/// coefficient, applied to the overlap and all but the last subframe's tail.
fn OpusEncoder::apply_preemph(self : OpusEncoder, f : OpusEncCeltFrame) -> Unit {
  let subframesize = self.frame_size
  let subframes = 960 / subframesize
  let c = opus_enc_deemph_weights[0]
  for ch in 0..<f.channels {
    let b = f.block[ch]
    let mut m : Float = b.emph_coeff
    for i in 0..<opus_enc_overlap {
      let sample = b.overlap[i]
      b.overlap[i] = sample - m
      m = sample * c
    }
    b.emph_coeff = m
  }
  for sf in 0..<subframes {
    for ch in 0..<f.channels {
      let b = f.block[ch]
      let mut m : Float = b.emph_coeff
      for i in 0..<subframesize {
        let sample = b.samples[sf * subframesize + i]
        b.samples[sf * subframesize + i] = sample - m
        m = sample * c
      }
      if sf != subframes - 1 {
        b.emph_coeff = m
      }
    }
  }
}

///|
/// `celt_frame_mdct`: window (transient: per 120-sample block; else one
/// windowed frame), forward MDCT, then per-band normalisation and energies.
fn opus_enc_frame_mdct(f : OpusEncCeltFrame) -> Unit {
  let win : Array[Float] = Array::make(1920, 0.0)
  let temp : Array[Float] = Array::make(240, 0.0)
  if f.transient != 0 {
    for ch in 0..<f.channels {
      let b = f.block[ch]
      // src1 starts at b->overlap; from the second block on it is
      // &b->samples[120*(t-1)] (the previous block's samples)
      for t in 0..<f.blocks {
        let src2_off = opus_enc_overlap * t
        let src1_arr = if t == 0 { b.overlap } else { b.samples }
        let src1_off = if t == 0 { 0 } else { opus_enc_overlap * (t - 1) }
        // vector_fmul(win, src1, ff_celt_window, 128); ff_celt_window is
        // ff_celt_window_padded + 8 and the overlap buffer has 8 slack zeros
        for i in 0..<128 {
          win[i] = src1_arr[src1_off + i] * opus_enc_celt_window_padded[8 + i]
        }
        // vector_fmul_reverse(&win[120], src2, ff_celt_window_padded, 128)
        // dst[i] = src0[i] * src1[len-1-i]: the WINDOW is the reversed operand
        for i in 0..<128 {
          win[opus_enc_overlap + i] = b.samples[src2_off + i] *
            opus_enc_celt_window_padded[127 - i]
        }
        opus_enc_mdct_fwd(
          b.coeffs,
          t,
          win,
          120,
          Float::from_int(68 << 3),
          f.blocks,
        )
      }
    }
  } else {
    let blk_len = 960
    let wlen = 1920
    let rwin = blk_len - opus_enc_overlap
    let lap_dst = (wlen - blk_len - opus_enc_overlap) >> 1
    for i in 0..<wlen {
      win[i] = 0.0
    }
    for ch in 0..<f.channels {
      let b = f.block[ch]
      // Overlap
      for i in 0..<128 {
        temp[i] = b.overlap[i] * opus_enc_celt_window_padded[8 + i]
      }
      for i in 0..<opus_enc_overlap {
        win[lap_dst + i] = temp[i]
      }
      // Samples, flat top window
      for i in 0..<rwin {
        win[lap_dst + opus_enc_overlap + i] = b.samples[i]
      }
      // Samples, windowed: vector_fmul_reverse reverses the second operand
      for i in 0..<128 {
        temp[i] = b.samples[rwin + i] * opus_enc_celt_window_padded[127 - i]
      }
      for i in 0..<opus_enc_overlap {
        win[lap_dst + blk_len + i] = temp[i]
      }
      opus_enc_mdct_fwd(
        b.coeffs,
        0,
        win,
        blk_len,
        Float::from_int(68 << (3 - f.size)),
        1,
      )
    }
  }
  for ch in 0..<f.channels {
    let block = f.block[ch]
    for i in 0..<opus_enc_max_bands {
      let mut ener : Float = 0.0
      let band_offset = opus_celt_freq_bands[i] << f.size
      let band_size = opus_celt_freq_range[i] << f.size
      for j in 0..<band_size {
        let c = block.coeffs[band_offset + j]
        ener += c * c
      }
      let lin = Float::from_double(ener.to_double().sqrt()) +
        1.1920928955078125e-7
      block.lin_energy[i] = lin
      let scale : Float = 1.0 / lin
      for j in 0..<band_size {
        block.coeffs[band_offset + j] = block.coeffs[band_offset + j] * scale
      }
      let mut e = opus_enc_log2f(lin) - opus_enc_mean_energy[i]
      if e < opus_enc_energy_silence {
        e = opus_enc_energy_silence
      }
      block.energy[i] = e
    }
  }
}

///|
/// `celt_enc_tf`.
fn opus_enc_celt_tf(f : OpusEncCeltFrame, rc : OpusRangeEncoder) -> Unit {
  let mut tf_select = 0
  let mut diff = 0
  let mut tf_changed = 0
  let mut bits = if f.transient != 0 { 2 } else { 4 }
  let tf_select_needed = f.size != 0 && rc.tell() + bits + 1 <= f.framebits
  for i in f.start_band..<f.end_band {
    if rc.tell() + bits + (if tf_select_needed { 1 } else { 0 }) <= f.framebits {
      let tbit = if (diff ^ 1) == f.tf_change[i] { 1 } else { 0 }
      rc.encode_log(tbit, bits)
      diff = diff ^ tbit
      tf_changed = tf_changed | diff
    }
    bits = if f.transient != 0 { 4 } else { 5 }
  }
  // `ff_celt_tf_select[size][transient][select][change]`: the two scalar
  // entries compared here differ in `select`, not in `change`.
  let tf_base = f.size * 8 + f.transient * 4
  let sel0 = opus_celt_tf_select[tf_base + tf_changed]
  let sel1 = opus_celt_tf_select[tf_base + 2 + tf_changed]
  if tf_select_needed && sel0 != sel1 {
    rc.encode_log(f.tf_select, 1)
    tf_select = f.tf_select
  }
  for i in f.start_band..<f.end_band {
    let idx = f.size * 8 + f.transient * 4 + tf_select * 2 + f.tf_change[i]
    f.tf_change[i] = opus_celt_tf_select[idx]
  }
}

///|
/// `exp_quant_coarse`.
fn opus_enc_exp_quant_coarse(
  rc : OpusRangeEncoder,
  f : OpusEncCeltFrame,
  last_energy : Array[Array[Float]],
  intra : Int32,
) -> Unit {
  let prev : Array[Float] = [0.0, 0.0]
  let mut eff_intra = intra
  if rc.tell() + 3 <= f.framebits {
    rc.encode_log(intra, 3)
  } else {
    eff_intra = 0
  }
  let alpha : Float = if eff_intra != 0 { 0.0 } else { opus_celt_alpha[f.size] }
  let beta : Float = if eff_intra != 0 {
    1.0 - Float::from_double(4915.0) / Float::from_double(32768.0)
  } else {
    opus_celt_beta[f.size]
  }
  let pmod = (f.size * 2 + intra) * 42
  for i in f.start_band..<f.end_band {
    for ch in 0..<f.channels {
      let block = f.block[ch]
      let left = f.framebits - rc.tell()
      let mut last = last_energy[ch][i]
      if last < -9.0 {
        last = -9.0
      }
      let diff = block.energy[i] - prev[ch] - last * alpha
      let mut q_en = opus_enc_rintf(diff)
      if left >= 15 {
        let symbol = (opus_celt_coarse_energy_dist[pmod + (i << 1)] * 128).reinterpret_as_uint()
        let decay = opus_celt_coarse_energy_dist[pmod + (i << 1) + 1] << 6
        let (_, out) = rc.encode_laplace(q_en, symbol, decay)
        q_en = out
      } else if left >= 2 {
        q_en = opus_enc_clip_i(q_en, -1, 1)
        let idx = 2 * q_en + (if q_en < 0 { 3 } else { 0 })
        rc.encode_cdf(idx, [4, 2, 3, 4])
      } else if left >= 1 {
        q_en = opus_enc_clip_i(q_en, -1, 0)
        rc.encode_log(q_en & 1, 1)
      } else {
        q_en = -1
      }
      block.error_energy[i] = Float::from_int(q_en) - diff
      prev[ch] = prev[ch] + beta * Float::from_int(q_en)
    }
  }
}

///|
/// `celt_quant_coarse`: try intra, roll back, try inter, keep the cheaper.
fn opus_enc_celt_quant_coarse(
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
  last_energy : Array[Array[Float]],
) -> Unit {
  let saved = rc.snapshot()
  opus_enc_exp_quant_coarse(rc, f, last_energy, 1)
  let intra_bits = rc.tell_frac() - saved.tell_frac
  rc.rollback(saved)
  opus_enc_exp_quant_coarse(rc, f, last_energy, 0)
  let inter_bits = rc.tell_frac() - saved.tell_frac
  if inter_bits > intra_bits {
    rc.rollback(saved)
    opus_enc_exp_quant_coarse(rc, f, last_energy, 1)
  }
}

///|
/// `celt_quant_fine`.
fn opus_enc_celt_quant_fine(
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
) -> Unit {
  for i in f.start_band..<f.end_band {
    if f.fine_bits[i] == 0 {
      continue
    }
    for ch in 0..<f.channels {
      let block = f.block[ch]
      let lim = 1 << f.fine_bits[i]
      let half : Float = 0.5
      let diff = half - block.error_energy[i]
      let floor_v = (diff * Float::from_int(lim)).to_double().floor()
      let quant = opus_enc_clip_i(floor_v.to_int(), 0, lim - 1)
      rc.put_raw(quant.reinterpret_as_uint(), f.fine_bits[i])
      let w = Float::from_int(1 << (14 - f.fine_bits[i]))
      let offset = half - (Float::from_int(quant) + 0.5) * w / 16384.0
      block.error_energy[i] = block.error_energy[i] - offset
    }
  }
}

///|
/// `celt_quant_final`.
fn opus_enc_celt_quant_final(
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
) -> Unit {
  for priority in 0..<2 {
    for i in f.start_band..<f.end_band {
      if f.framebits - rc.tell() < f.channels {
        break
      }
      if f.fine_priority[i] != priority || f.fine_bits[i] >= 8 {
        continue
      }
      for ch in 0..<f.channels {
        let block = f.block[ch]
        let err = block.error_energy[i]
        let half : Float = 0.5
        let offset = half *
          Float::from_int(1 << (14 - f.fine_bits[i] - 1)) /
          16384.0
        let sign = if (err + offset).abs() < (err - offset).abs() {
          1
        } else {
          0
        }
        rc.put_raw(sign.reinterpret_as_uint(), 1)
        block.error_energy[i] = block.error_energy[i] -
          offset * Float::from_int(1 - 2 * sign)
      }
    }
  }
}
