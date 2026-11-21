///|
priv struct LoudnessFilter {
  b0 : Double
  b1 : Double
  b2 : Double
  a1 : Double
  a2 : Double
  mut z1 : Double
  mut z2 : Double
}

///|
fn LoudnessFilter::step(self : LoudnessFilter, sample : Double) -> Double {
  let output = self.b0 * sample + self.z1
  self.z1 = self.b1 * sample - self.a1 * output + self.z2
  self.z2 = self.b2 * sample - self.a2 * output
  output
}

///|
// BS.1770 K-weighting as used by FFmpeg's libavfilter/ebur128.c.
fn loudness_filter(rate : Int32, shelf : Bool) -> LoudnessFilter {
  let frequency = if shelf { 1681.974450955533 } else { 38.13547087602444 }
  let q = if shelf { 0.7071752369554196 } else { 0.5003270373238773 }
  let k = @math.tan(3.141592653589793 * frequency / rate.to_double())
  let kk = k * k
  let a0 = 1.0 + k / q + kk
  let (b0, b1, b2) = if shelf {
    let vh = @math.pow(10.0, 3.999843853973347 / 20.0)
    let vb = @math.pow(vh, 0.4996667741545416)
    (
      (vh + vb * k / q + kk) / a0,
      2.0 * (kk - vh) / a0,
      (vh - vb * k / q + kk) / a0,
    )
  } else {
    (1.0, -2.0, 1.0)
  }
  {
    b0,
    b1,
    b2,
    a1: 2.0 * (kk - 1.0) / a0,
    a2: (1.0 - k / q + kk) / a0,
    z1: 0.0,
    z2: 0.0,
  }
}

///|
fn energy_lufs(energy : Double) -> Double {
  -0.691 + 10.0 * @math.log10(energy)
}

///|
/// Measure BS.1770 integrated loudness for mono or stereo planar PCM.
/// Returns None for clips without a complete 400 ms block above the gate.
pub fn integrated_loudness(
  samples : Array[Array[Double]],
  rate : Int32,
) -> Double? {
  guard samples.get(0) is Some(first) else { return None }
  let length = first.length()
  // PCM here has a channel count but no per-channel layout for BS.1770 weights.
  guard samples.length() <= 2 &&
    rate >= 8000 &&
    samples.all(plane => plane.length() == length) else {
    return None
  }
  let step = rate / 10 + (rate % 10 + 5) / 10
  guard length / step >= 4 else { return None }
  let filters = samples.map(_ => {
    (loudness_filter(rate, true), loudness_filter(rate, false))
  })
  let recent = Array::make(4, 0.0)
  let energies : Array[Double] = []
  let mut total = 0.0
  let absolute_gate = @math.pow(10.0, (-70.0 + 0.691) / 10.0)
  for block in 0..<(length / step) {
    let mut energy = 0.0
    for c in 0..<samples.length() {
      let (shelf, highpass) = filters[c]
      for i in (block * step)..<((block + 1) * step) {
        let filtered = highpass.step(shelf.step(samples[c][i]))
        energy += filtered * filtered
      }
    }
    recent[block % 4] = energy
    if block >= 3 {
      let mean = (recent[0] + recent[1] + recent[2] + recent[3]) /
        (4.0 * step.to_double())
      if mean >= absolute_gate {
        energies.push(mean)
        total += mean
      }
    }
  }
  guard !energies.is_empty() else { return None }
  let gate = total / energies.length().to_double() * 0.1
  let mut gated_total = 0.0
  let mut count = 0
  for energy in energies {
    if energy >= gate {
      gated_total += energy
      count += 1
    }
  }
  Some(energy_lufs(gated_total / count.to_double()))
}
