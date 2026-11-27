///|
/// RealAudio 2.0 (28.8 kb/s), ported from FFmpeg ra288.c and g728_template.c
/// (LGPL-2.1-or-later).
struct Ra288Decoder {
  speech_lpc : Array[Double]
  gain_lpc : Array[Double]
  speech_history : Array[Double]
  speech_recursive : Array[Double]
  gain_history : Array[Double]
  gain_recursive : Array[Double]
}

///|
pub fn Ra288Decoder::new(block_align : Int32) -> Result[Ra288Decoder, String] {
  if block_align != 38 {
    return Err("RealAudio 28.8 requires a block alignment of 38 bytes")
  }
  Ok({
    speech_lpc: Array::make(36, 0.0),
    gain_lpc: Array::make(10, 0.0),
    speech_history: Array::make(111, 0.0),
    speech_recursive: Array::make(37, 0.0),
    gain_history: Array::make(38, 0.0),
    gain_recursive: Array::make(11, 0.0),
  })
}

///|
fn ra288_backward_filter(
  history : Array[Double],
  recursive : Array[Double],
  window : FixedArray[Double],
  lpc : Array[Double],
  bandwidth : FixedArray[Double],
  input_length : Int32,
  nonrecursive_length : Int32,
  move_size : Int32,
) -> Unit {
  let order = lpc.length()
  let work = Array::makei(order + input_length + nonrecursive_length, i => {
    history[i] * window[i]
  })
  let correlation = Array::make(order + 1, 0.0)
  for lag = 0; lag <= order; lag = lag + 1 {
    let tail = order + input_length
    recursive[lag] = 0.5625 * recursive[lag] +
      amr_dot(work, order, work, order - lag, input_length)
    correlation[lag] = recursive[lag] +
      amr_dot(work, tail, work, tail - lag, nonrecursive_length)
  }
  correlation[0] *= 257.0 / 256.0
  if ra288_levinson(correlation, lpc) {
    for i = 0; i < order; i = i + 1 {
      lpc[i] *= bandwidth[i]
    }
  }
  for i = 0; i < move_size; i = i + 1 {
    history[i] = history[i + input_length]
  }
}

///|
/// Match compute_lpc_coefs with normalization and failure checks enabled.
fn ra288_levinson(correlation : Array[Double], lpc : Array[Double]) -> Bool {
  let mut error = correlation[0]
  let order = lpc.length()
  if correlation[order] == 0.0 || error <= 0.0 {
    return false
  }
  for i = 0; i < order; i = i + 1 {
    let mut reflection = -correlation[i + 1]
    for j = 0; j < i; j = j + 1 {
      reflection -= lpc[j] * correlation[i - j]
    }
    if error != 0.0 {
      reflection /= error
    }
    error *= 1.0 - reflection * reflection
    lpc[i] = reflection
    for j = 0; j < (i + 1) >> 1; j = j + 1 {
      let front = lpc[j]
      let back = lpc[i - 1 - j]
      lpc[j] = front + reflection * back
      lpc[i - 1 - j] = back + reflection * front
    }
    if error < 0.0 {
      return false
    }
  }
  true
}

///|
/// Decode a 38-byte packet into 160 mono samples.
pub fn Ra288Decoder::decode_packet(
  self : Ra288Decoder,
  packet : Bytes,
) -> Result[Array[Double], String] {
  if packet.length() != 38 {
    return Err("RealAudio 28.8 requires a 38-byte packet")
  }
  let bits = RealAudioBits::new(packet)
  let out = Array::make(160, 0.0)
  let excitation = Array::make(5, 0.0)
  for block = 0; block < 32; block = block + 1 {
    let gain = ra288_amptable[bits.read(3).reinterpret_as_int()]
    let code = bits.read(6 + (block & 1)).reinterpret_as_int()
    for i = 70; i < 106; i = i + 1 {
      self.speech_history[i] = self.speech_history[i + 5]
    }
    let mut predicted = 32.0
    for i = 0; i < 10; i = i + 1 {
      predicted -= self.gain_history[37 - i] * self.gain_lpc[i]
    }
    let scale = @math.exp(predicted.clamp(min=0.0, max=60.0) * 0.1151292546497) *
      gain /
      8388608.0
    for i = 0; i < 5; i = i + 1 {
      excitation[i] = ra288_codetable[code * 5 + i].to_double() * scale
    }
    let power = amr_dot(excitation, 0, excitation, 0, 5).max(5.0 / 16777216.0)
    for i = 28; i < 37; i = i + 1 {
      self.gain_history[i] = self.gain_history[i + 1]
    }
    self.gain_history[37] = 10.0 * @math.log10(power) +
      (10.0 * @math.log10(16777216.0 / 5.0) - 32.0)
    amr_celp_lp_synthesis_filterf(
      self.speech_history,
      106,
      excitation,
      0,
      self.speech_lpc,
      5,
      36,
    )
    for i = 0; i < 5; i = i + 1 {
      out[block * 5 + i] = self.speech_history[106 + i]
    }
    if (block & 7) == 3 {
      ra288_backward_filter(
        self.speech_history,
        self.speech_recursive,
        ra288_syn_window,
        self.speech_lpc,
        ra288_syn_bw_tab,
        40,
        35,
        70,
      )
      ra288_backward_filter(
        self.gain_history,
        self.gain_recursive,
        ra288_gain_window,
        self.gain_lpc,
        ra288_gain_bw_tab,
        8,
        20,
        28,
      )
    }
  }
  Ok(out)
}
