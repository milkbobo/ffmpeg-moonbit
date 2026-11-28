///|
/// Stateful GSM 06.10 full-rate RPE-LTP encoder. The fixed-point analysis
/// follows libgsm 1.0.22. See gsm.COPYRIGHT for its license.
pub struct GsmEncoder {
  priv mut previous_input : Int32
  priv mut highpass : Int64
  priv mut preemphasis : Int32
  priv previous_lar : FixedArray[Int32]
  priv lattice : FixedArray[Int32]
  priv reference : FixedArray[Int32]
}

///|
pub fn gsm_encoder_new() -> GsmEncoder {
  {
    previous_input: 0,
    highpass: 0L,
    preemphasis: 0,
    previous_lar: FixedArray::make(8, 0),
    lattice: FixedArray::make(8, 0),
    reference: FixedArray::make(280, 0),
  }
}

///|
fn GsmEncoder::preprocess(
  self : GsmEncoder,
  samples : ArrayView[Int32],
) -> FixedArray[Int32] {
  FixedArray::makei(160, i => {
    let input = clip_int16(samples[i]) >> 3 << 2
    let delta = input - self.previous_input
    self.previous_input = input
    let msb = self.highpass >> 15
    let lsb = (self.highpass & 32767L).to_int()
    self.highpass = (msb * 32735L +
    (delta.to_int64() << 15) +
    gsm_mult(lsb, 32735).to_int64()).clamp(min=-2147483648L, max=2147483647L)
    let filtered = ((self.highpass + 16384L).min(2147483647L) >> 15).to_int()
    let result = clip_int16(filtered + gsm_mult(self.preemphasis, -28180))
    self.preemphasis = filtered
    result
  })
}

///|
fn gsm_max_abs(samples : FixedArray[Int32]) -> Int32 {
  let mut maximum = 0
  for sample in samples {
    maximum = maximum.max(sample.abs().min(32767))
  }
  maximum
}

///|
fn gsm_lpc(samples : FixedArray[Int32]) -> FixedArray[Int32] {
  let maximum = gsm_max_abs(samples)
  let scale = (5 - (maximum << 16).clz()).max(0)
  if scale > 0 {
    for i in 0..<160 {
      samples[i] = gsm_mult(samples[i], 32768 >> scale)
    }
  }
  let correlation = FixedArray::makei(9, lag => {
    let mut sum = 0
    for i in lag..<160 {
      sum += samples[i] * samples[i - lag]
    }
    sum << 1
  })
  if scale > 0 {
    for i in 0..<160 {
      samples[i] = samples[i] << scale
    }
  }
  let coefficients = FixedArray::make(8, 0)
  if correlation[0] == 0 {
    return coefficients
  }
  let shift = correlation[0].clz() - 1
  let p = FixedArray::makei(9, i => correlation[i] << shift >> 16)
  let k = FixedArray::makei(9, i => p[i])
  for order in 0..<8 {
    let magnitude = p[1].abs().min(32767)
    if magnitude > p[0] || p[0] == 0 {
      break
    }
    let value = ((magnitude << 15) / p[0]).min(32767)
    let reflection = if p[1] > 0 { -value } else { value }
    coefficients[order] = reflection
    p[0] = clip_int16(p[0] + gsm_mult(p[1], reflection))
    for i in 1..<(8 - order) {
      p[i] = clip_int16(p[i + 1] + gsm_mult(k[i], reflection))
      k[i] = clip_int16(k[i] + gsm_mult(p[i + 1], reflection))
    }
  }
  coefficients
}

///|
let gsm_lar_quantizers : FixedArray[(Int32, Int32)] = [
  (20480, 0),
  (20480, 0),
  (20480, 2048),
  (20480, -2560),
  (13964, 94),
  (15360, -1792),
  (8534, -341),
  (9036, -1144),
]

///|
fn gsm_lar_encode(index : Int32, coefficient : Int32) -> Int32 {
  let magnitude = coefficient.abs()
  let lar = if magnitude < 22118 {
    magnitude >> 1
  } else if magnitude < 31130 {
    magnitude - 11059
  } else {
    (magnitude - 26112) << 2
  }
  let signed = if coefficient < 0 { -lar } else { lar }
  let (factor, offset) = gsm_lar_quantizers[index]
  let (width, _, _) = gsm_lar_parameters[index]
  let bias = 1 << (width - 1)
  let scaled = clip_int16(((signed * factor) >> 15) + offset)
  ((clip_int16(scaled + 256) >> 9) + bias).clamp(min=0, max=2 * bias - 1)
}

///|
fn GsmEncoder::short_term_analysis(
  self : GsmEncoder,
  samples : FixedArray[Int32],
  lar : FixedArray[Int32],
) -> Unit {
  for segment in 0..<4 {
    let coefficients = FixedArray::makei(8, i => {
      gsm_reflection_coefficient(
        gsm_lar_interpolate(self.previous_lar[i], lar[i], segment),
      )
    })
    for i in gsm_lar_boundaries[segment]..<gsm_lar_boundaries[segment + 1] {
      let mut current = samples[i]
      let mut saved = current
      for j in 0..<8 {
        let state = self.lattice[j]
        let reflection = coefficients[j]
        self.lattice[j] = saved
        saved = clip_int16(state + gsm_mult(reflection, current))
        current = clip_int16(current + gsm_mult(reflection, state))
      }
      samples[i] = current
    }
  }
  for i in 0..<8 {
    self.previous_lar[i] = lar[i]
  }
}

///|
fn gsm_long_term_predictor(
  reference : FixedArray[Int32],
  base : Int32,
  signal : FixedArray[Int32],
) -> (Int32, Int32) {
  let maximum = gsm_max_abs(signal)
  let scale = (7 - (maximum << 16).clz()).max(0)
  let scaled = FixedArray::makei(40, i => signal[i] >> scale)
  let mut lag = 40
  let mut correlation = 0
  for candidate in 40..<=120 {
    let mut sum = 0
    for i in 0..<40 {
      sum += scaled[i] * reference[base + i - candidate]
    }
    if sum > correlation {
      correlation = sum
      lag = candidate
    }
  }
  correlation = correlation << 1 >> (6 - scale)
  let mut power = 0
  for i in 0..<40 {
    let value = reference[base + i - lag] >> 3
    power += value * value
  }
  power = power << 1
  if correlation <= 0 {
    return (lag, 0)
  }
  if correlation >= power {
    return (lag, 3)
  }
  let shift = power.clz() - 1
  let fit = correlation << shift >> 16
  let normalized = power << shift >> 16
  let thresholds : FixedArray[Int32] = [6554, 16384, 26214]
  for i in 0..<3 {
    if fit <= (normalized * thresholds[i]) >> 15 {
      return (lag, i)
    }
  }
  (lag, 3)
}

///|
fn gsm_rpe(signal : FixedArray[Int32]) -> (Int32, Int32, FixedArray[Int32]) {
  let weights : FixedArray[Int32] = [
    -134, -374, 0, 2054, 5741, 8192, 5741, 2054, 0, -374, -134,
  ]
  let weighted = FixedArray::makei(40, i => {
    let mut value = 4096
    for j in 0..<weights.length() {
      let pos = i + j - 5
      if pos >= 0 && pos < 40 {
        value += signal[pos] * weights[j]
      }
    }
    clip_int16(value >> 13)
  })
  let mut grid = 0
  let mut energy = -1
  for candidate in 0..<4 {
    let mut sum = 0
    for i in 0..<13 {
      let value = weighted[candidate + 3 * i] >> 2
      sum += value * value
    }
    if sum > energy {
      energy = sum
      grid = candidate
    }
  }
  let pulses = FixedArray::makei(13, i => weighted[grid + 3 * i])
  let peak = gsm_max_abs(pulses)
  let exponent = 32 - (peak >> 9).clz()
  let maximum = (peak >> (exponent + 5)) + (exponent << 3)
  let (shift, mantissa) = gsm_apcm_scale(maximum)
  let inverse : FixedArray[Int32] = [
    29128, 26215, 23832, 21846, 20165, 18725, 17476, 16384,
  ]
  let codes = FixedArray::makei(13, i => {
    let normalized = pulses[i] << shift << 16 >> 16
    ((normalized * inverse[mantissa]) >> 27) + 4
  })
  (grid, maximum, codes)
}

///|
fn GsmEncoder::encode_block(
  self : GsmEncoder,
  pcm : ArrayView[Int32],
  write : (Int32, Int32) -> Unit,
) -> Unit {
  let samples = self.preprocess(pcm)
  let reflection = gsm_lpc(samples)
  let lar = FixedArray::makei(8, i => {
    let code = gsm_lar_encode(i, reflection[i])
    let (width, _, _) = gsm_lar_parameters[i]
    write(code, width)
    gsm_lar_decode(i, code)
  })
  self.short_term_analysis(samples, lar)
  for subframe in 0..<4 {
    let base = 120 + subframe * 40
    let signal = FixedArray::makei(40, i => samples[subframe * 40 + i])
    let (lag, gain) = gsm_long_term_predictor(self.reference, base, signal)
    for i in 0..<40 {
      let prediction = gsm_mult(
        gsm_long_term_gains[gain],
        self.reference[base + i - lag],
      )
      self.reference[base + i] = prediction
      signal[i] = clip_int16(signal[i] - prediction)
    }
    let (grid, maximum, pulses) = gsm_rpe(signal)
    write(lag, 7)
    write(gain, 2)
    write(grid, 2)
    write(maximum, 6)
    for i, code in pulses {
      write(code, 3)
      let pos = base + grid + 3 * i
      self.reference[pos] = clip_int16(
        self.reference[pos] + gsm_apcm_rows[maximum][code],
      )
    }
  }
  for i in 0..<120 {
    self.reference[i] = self.reference[i + 160]
  }
}

///|
/// Encode 160 mono s16 samples as native GSM or 320 as one WAV49 block.
/// Use the same encoder for successive packets to preserve filter history.
pub fn GsmEncoder::encode_packet(
  self : GsmEncoder,
  pcm : ArrayView[Int32],
  wav49~ : Bool = false,
) -> Result[Bytes, String] {
  if wav49 {
    guard pcm.length() == 320 else {
      return Err("gsm: WAV49 needs 320 samples")
    }
    let bytes = FixedArray::make(65, 0)
    let cursor = { val: 0, }
    let write = (value : Int32, width : Int32) => {
      for bit in 0..<width {
        let pos = cursor.val
        let index = pos >> 3
        bytes[index] = bytes[index] | (((value >> bit) & 1) << (pos & 7))
        cursor.val += 1
      }
    }
    self.encode_block(pcm[:160], write)
    self.encode_block(pcm[160:], write)
    Ok(Bytes::makei(65, i => bytes[i].to_byte()))
  } else {
    guard pcm.length() == 160 else {
      return Err("gsm: native GSM needs 160 samples")
    }
    let writer = BitWriter::new()
    writer.put(13U, 4)
    self.encode_block(pcm, (value, width) => {
      writer.put(value.reinterpret_as_uint(), width)
    })
    Ok(writer.finish())
  }
}
