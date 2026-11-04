/// MoonBit port of FFmpeg 9.0.2 `opus/enc_psy.c` part two: per-frame setup,
/// the lambda/boost gauge, the intensity-stereo / dual-stereo / tf searches
/// (`pvq_band_cost` / `bands_dist`) and the post-encode update.

///|
/// `celt_gauge_psy_weight`.
fn OpusEncPsy::gauge_weight(
  _self : OpusEncPsy,
  start : Int,
  steps_per_frame : Int,
  channels : Int,
  f : OpusEncCeltFrame,
) -> Unit {
  let band_score : Array[Float] = Array::make(21, 0.0)
  let mut max_score : Float = 1.0
  let mut tonal : Float = 0.0
  for i in 0..<21 {
    let mut weight : Float = 0.0
    let mut tonal_contrib : Float = 0.0
    for j in 0..<steps_per_frame {
      let st = _self.steps[start + j]
      weight += st.stereo[i]
      for ch in 0..<channels {
        weight += st.change_amp[ch * 21 + i] + st.tone[ch * 21 + i] + st.energy[ch * 21 + i]
        tonal_contrib += st.tone[ch * 21 + i]
      }
    }
    tonal += tonal_contrib
    band_score[i] = weight
  }
  tonal = tonal / 21.0
  for i in 0..<21 {
    if band_score[i] > max_score {
      max_score = band_score[i]
    }
  }
  for i in 0..<21 {
    // C: `(int)((band_score[i]/max_score)*3.0f)` — truncation, not rounding
    f.alloc_boost[i] = (band_score[i] / max_score * 3.0).to_int()
  }
  tonal = tonal / 1333136.0
  let spread = opus_enc_clip_i(opus_enc_rintf(tonal), 0, 3)
  f.spread = spread
  // framebits from the bit rate (frame_bits is always 0 upstream)
  let frame_bits : Float = 0.0
  let mut rate : Float = _self.bit_rate_f + frame_bits * 960.0 * 16.0
  rate = rate * _self.lambda
  rate = rate / (48000.0 / 960.0)
  let mut fb = opus_enc_rintf(rate)
  fb = fb.min(1276 * 8)
  // FFALIGN(x, 8)
  fb = (fb + 7) & 0xFFFFFFF8
  f.framebits = fb
}

///|
/// `pvq_band_cost`: quantify one band on a scratch rc and return
/// `lambda * dist * cost`, accumulating bits. The ORIGINAL coefficients are
/// saved before quantisation for the distance measure.
fn opus_enc_pvq_band_cost(
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
  band : Int,
  bits : Array[Float],
  lambda : Float,
  lowband_scratch : Array[Float],
  hadamard_tmp : Array[Float],
) -> Float {
  let band_size = opus_celt_freq_range[band] << f.size
  let x_off = opus_celt_freq_bands[band] << f.size
  // Work on COPIES: upstream keeps `f->block[].coeffs` untouched so the
  // following real encode still sees the pristine spectrum.
  let x : Array[Float] = Array::make(176, 0.0)
  let y : Array[Float] = Array::make(176, 0.0)
  for i in 0..<band_size {
    x[i] = f.block[0].coeffs[x_off + i]
  }
  if f.channels == 2 {
    for i in 0..<band_size {
      y[i] = f.block[1].coeffs[x_off + i]
    }
  }
  let saved = rc.snapshot()
  let cm0 : UInt32 = (1U << f.blocks) - 1U
  f.remaining2 = (f.framebits << 3) - f.anticollapse_needed - rc.tell_frac() - 1
  let mut b = 0
  if band <= f.coded_bands - 1 {
    let curr_balance = f.remaining / (f.coded_bands - band).min(3)
    b = opus_enc_clip_i((f.remaining2 + 1).min(f.pulses[band] + curr_balance), 0, (1 << 14) - 1)
  }
  let combined = cm0 | cm0
  if f.dual_stereo {
    let _ = opus_enc_quant_band(
      f,
      rc,
      band,
      x,
      0,
      None,
      0,
      band_size,
      b >> 1,
      f.blocks,
      None,
      f.size,
      None,
      0,
      1.0,
      lowband_scratch,
      cm0.reinterpret_as_int(),
      hadamard_tmp,
    )
    let _ = opus_enc_quant_band(
      f,
      rc,
      band,
      y,
      0,
      None,
      0,
      band_size,
      b >> 1,
      f.blocks,
      None,
      f.size,
      None,
      0,
      1.0,
      lowband_scratch,
      cm0.reinterpret_as_int(),
      hadamard_tmp,
    )
  } else {
    let y_opt : Array[Float]? = if f.channels == 2 { Some(y) } else { None }
    let _ = opus_enc_quant_band(
      f,
      rc,
      band,
      x,
      0,
      y_opt,
      0,
      band_size,
      b,
      f.blocks,
      None,
      f.size,
      None,
      0,
      1.0,
      lowband_scratch,
      combined.reinterpret_as_int(),
      hadamard_tmp,
    )
  }
  let mut err_x : Float = 0.0
  let mut err_y : Float = 0.0
  for i in 0..<band_size {
    let d = x[i] - f.block[0].coeffs[x_off + i]
    err_x += d * d
    if f.channels == 2 {
      let d2 = y[i] - f.block[1].coeffs[x_off + i]
      err_y += d2 * d2
    }
  }
  let dy = Float::from_double(err_y.to_double().sqrt())
  let dist = Float::from_double(err_x.to_double().sqrt()) + dy
  let cost = Float::from_int(rc.tell_frac() - saved.tell_frac) / 8.0
  bits[0] += cost
  rc.rollback(saved)
  lambda * dist * cost
}

///|
/// `bands_dist` on a detached range coder.
fn opus_enc_bands_dist(
  f : OpusEncCeltFrame,
  lambda : Float,
  run_bitalloc : (OpusEncCeltFrame, OpusRangeEncoder) -> Unit,
) -> Float {
  let dump = OpusRangeEncoder::new()
  dump.init()
  // `bands_dist` does not touch `framebits`: the gauge already set it.
  run_bitalloc(f, dump)
  // C: `int tdist = 0.0f; tdist += dist;` — each band's cost is truncated
  // toward zero before accumulation, and the total is returned as float.
  let mut tdist : Int = 0
  let lowband_scratch : Array[Float] = Array::make(8 * 22, 0.0)
  let hadamard_tmp : Array[Float] = Array::make(176, 0.0)
  for i in 0..<21 {
    let bits : Array[Float] = [0.0]
    tdist += opus_enc_pvq_band_cost(f, dump, i, bits, lambda, lowband_scratch, hadamard_tmp).to_int()
  }
  Float::from_int(tdist)
}

///|
/// `ff_opus_psy_celt_frame_init`.
fn OpusEncoder::psy_celt_frame_init(self : OpusEncoder, f : OpusEncCeltFrame, index : Int) -> Unit {
  let steps_per_frame = 960 / self.frame_size
  let step_offset = steps_per_frame * index
  let mut silence = 1
  f.start_band = 0
  // OPUS_BANDWIDTH_FULLBAND = 4
  f.end_band = opus_enc_band_end[4]
  f.channels = self.channels
  f.size = self.packet_framesize
  for i in 0..<steps_per_frame {
    if self.psy.steps[index * steps_per_frame + i].silence == 0 {
      silence = 0
    }
  }
  if self.psy.eof == 1 && step_offset >= self.psy.buffered_steps {
    silence = 1
  }
  f.silence = silence
  if f.silence != 0 {
    f.framebits = 0
    f.intensity_stereo = f.end_band
    return
  }
  let mut neighbouring_points = 0
  let mut start_offset = 0
  for i in 0..<self.psy.inflection_points_count {
    if self.psy.inflection_points[i] >= step_offset {
      start_offset = i
      break
    }
  }
  let upper = steps_per_frame.min(self.psy.inflection_points_count - start_offset)
  for i in start_offset..<upper {
    if self.psy.inflection_points[i] < step_offset + steps_per_frame {
      neighbouring_points += 1
    }
  }
  // Transient flagging
  f.transient = if neighbouring_points > 0 { 1 } else { 0 }
  f.blocks = if f.transient != 0 { 960 / opus_enc_overlap } else { 1 }
  // Some sane defaults
  f.pfilter = 0
  f.pf_gain = 0.5
  f.pf_octave = 2
  f.pf_period = 1
  f.pf_tapset = 2
  f.tf_select = 0
  f.anticollapse = 1
  f.alloc_trim = 5
  f.skip_band_floor = f.end_band
  f.intensity_stereo = f.end_band
  f.dual_stereo = false
  f.spread = 2
  for i in 0..<21 {
    f.tf_change[i] = 0
    f.alloc_boost[i] = 0
  }
}

///|
/// `celt_enc_quant_pfilter` (enc.c).
fn OpusEncoder::quant_pfilter(_self : OpusEncoder, rc : OpusRangeEncoder, f : OpusEncCeltFrame) -> Unit {
  let gain0 = f.pf_gain
  let octave0 = f.pf_octave
  let period0 = f.pf_period
  let tapset0 = f.pf_tapset
  rc.encode_log(f.pfilter, 1)
  if f.pfilter == 0 {
    return
  }
  // Octave
  let txval_oct = octave0.min(6)
  rc.encode_uint(txval_oct.reinterpret_as_uint(), 6U)
  let octave = txval_oct
  // Period
  rc.put_raw(period0.reinterpret_as_uint(), 4 + octave)
  let txval_period = opus_enc_clip_i(period0 - (16 << octave) + 1, 0, (1 << (4 + octave)) - 1)
  let period = txval_period + (16 << octave) - 1
  // Gain
  let txval_gain = (opus_enc_rintf(gain0 / 0.09375) - 1).min(7)
  rc.put_raw(txval_gain.reinterpret_as_uint(), 3)
  let q : Float = 0.09375
  let gain = q * Float::from_int(txval_gain + 1)
  // Tapset
  let mut tapset = tapset0
  if rc.tell() + 2 <= f.framebits {
    rc.encode_cdf(tapset, [4, 2, 3, 4])
  } else {
    tapset = 0
  }
  for i in 0..<2 {
    let block = f.block[i]
    let _pf_new = period.max(15)
    block.pf_gains_new[0] = gain * opus_enc_postfilter_taps[tapset * 3]
    block.pf_gains_new[1] = gain * opus_enc_postfilter_taps[tapset * 3 + 1]
    block.pf_gains_new[2] = gain * opus_enc_postfilter_taps[tapset * 3 + 2]
  }
}

///|
/// `ff_opus_psy_celt_frame_process`.
fn OpusEncoder::psy_celt_frame_process(self : OpusEncoder, f : OpusEncCeltFrame, index : Int) -> Bool {
  let start_transient_flag = f.transient
  let steps_per_frame = 960 / self.frame_size
  let start = index * steps_per_frame
  if f.silence != 0 {
    return false
  }
  self.psy.gauge_weight(start, steps_per_frame, f.channels, f)
  if f.channels == 2 {
    // intensity stereo search
    let mut best_band = 20
    let mut best_dist : Float = 3.4028234663852886e38
    let end_band = 0
    let mut i = f.end_band
    while i >= end_band {
      f.intensity_stereo = i
      let dist = self.psy_search_dist(f)
      if best_dist > dist {
        best_dist = dist
        best_band = i
      }
      i -= 1
    }
    f.intensity_stereo = best_band
    self.psy.avg_is_band = (self.psy.avg_is_band + Float::from_int(f.intensity_stereo)) / 2.0
    // dual stereo search
    f.dual_stereo = false
    let td1 = self.psy_search_dist(f)
    f.dual_stereo = true
    let td2 = self.psy_search_dist(f)
    f.dual_stereo = td2 < td1
  }
  // tf search
  let config : Array[Array[Int]] = [Array::make(21, 0), Array::make(21, 0)]
  let score : Array[Float] = [0.0, 0.0]
  for cway in 0..<2 {
    let base = if f.transient != 0 { 120 } else { 960 }
    let mag : Array[Int] = [0, 0]
    for i in 0..<2 {
      let c = opus_celt_tf_select[f.size * 8 + f.transient * 4 + cway * 2 + i]
      mag[i] = if c < 0 { base >> c.abs() } else { base << c.abs() }
    }
    for i in 0..<21 {
      let mut iscore0 : Float = 0.0
      let mut iscore1 : Float = 0.0
      for j in 0..<steps_per_frame {
        for k in 0..<f.channels {
          let st = self.psy.steps[start + j]
          let t = st.tone[k * 21 + i] * st.change_amp[k * 21 + i]
          iscore0 += t / Float::from_int(mag[0])
          iscore1 += t / Float::from_int(mag[1])
        }
      }
      config[cway][i] = if (iscore0 - 1.0).abs() < (iscore1 - 1.0).abs() { 1 } else { 0 }
      score[cway] += if config[cway][i] != 0 { iscore1 } else { iscore0 }
    }
  }
  f.tf_select = if score[0] < score[1] { 1 } else { 0 }
  for i in 0..<21 {
    f.tf_change[i] = config[f.tf_select][i]
  }
  if f.transient != start_transient_flag {
    f.blocks = if f.transient != 0 { 960 / opus_enc_overlap } else { 1 }
    return true
  }
  false
}

///|
/// `bands_dist` through the encoder.
fn OpusEncoder::psy_search_dist(_self : OpusEncoder, f : OpusEncCeltFrame) -> Float {
  let saved_framebits = f.framebits
  let lambda = _self.psy.lambda
  let dist = opus_enc_bands_dist(f, lambda, (ff, rcc) => {
    _self.celt_bitalloc(ff, rcc)
  })
  f.framebits = saved_framebits
  dist
}

///|
/// `ff_opus_psy_postencode_update`.
fn OpusEncoder::psy_postencode_update(self : OpusEncoder) -> Unit {
  let frame_size = 2 * 15 * (1 << (self.packet_framesize + 2))
  let steps_out = self.packet_frames * (frame_size / self.frame_size)
  for i in 0..<steps_out {
    self.psy.steps[i] = OpusEncPsyStep::new()
  }
  let tmp : Array[OpusEncPsyStep] = []
  for i in 0..<self.psy.steps.length() {
    tmp.push(self.psy.steps[i])
  }
  for i in 0..<self.psy.steps.length() {
    let i_new = i - steps_out
    self.psy.steps[if i_new < 0 { self.psy.steps.length() + i_new } else { i_new }] = tmp[i]
  }
  let ideal_fbits = Float::from_int(self.bit_rate / (48000 / 960))
  for i in 0..<self.packet_frames {
    self.psy.avg_is_band += Float::from_int(self.frames[i].intensity_stereo)
    if self.frames[i].framebits > 0 {
      let scaled = self.psy.lambda * ideal_fbits
      self.psy.lambda = scaled / Float::from_int(self.frames[i].framebits)
    }
  }
  self.psy.avg_is_band = self.psy.avg_is_band / Float::from_int(self.packet_frames + 1)
  self.psy.buffered_steps -= steps_out
  self.psy.inflection_points_count = 0
}
