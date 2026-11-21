///|
/// Return the retained half-open range after trimming leading and trailing
/// silence. Every channel must be below the threshold for a sample to count
/// as silence. A completely silent clip returns an empty range if it meets
/// the minimum duration. Interior silence is preserved. All planes must
/// contain the same number of samples.
pub fn audio_trim_range(
  samples : Array[Array[Double]],
  threshold : Double,
  minimum : Int32,
) -> (Int32, Int32) {
  guard samples.get(0) is Some(first) else { return (0, 0) }
  let length = first.length()
  let mut start = 0
  while start < length && samples.all(plane => plane[start].abs() < threshold) {
    start += 1
  }
  if start == length {
    return if length >= minimum { (length, length) } else { (0, length) }
  }
  let mut end = length
  while end > start && samples.all(plane => plane[end - 1].abs() < threshold) {
    end -= 1
  }
  (
    if start >= minimum {
      start
    } else {
      0
    },
    if length - end >= minimum {
      end
    } else {
      length
    },
  )
}

///|
/// Mix two planar PCM inputs at the same sample rate, starting both at zero.
/// Output follows the longer input. Mono is duplicated if either input is
/// stereo. The main input has unit weight and the secondary uses `weight`.
pub fn audio_mix(
  primary : Array[Array[Double]],
  secondary : Array[Array[Double]],
  weight : Double,
) -> Result[Array[Array[Double]], String] {
  guard primary.length() >= 1 &&
    primary.length() <= 2 &&
    secondary.length() >= 1 &&
    secondary.length() <= 2 else {
    return Err("mix supports mono and stereo inputs")
  }
  let channels = primary.length().max(secondary.length())
  let a_length = primary[0].length()
  let b_length = secondary[0].length()
  guard primary.all(plane => plane.length() == a_length) &&
    secondary.all(plane => plane.length() == b_length) else {
    return Err("mix requires equal plane lengths within each input")
  }
  let length = a_length.max(b_length)
  Ok(
    Array::makei(channels, fn(channel) {
      let a = primary[channel.min(primary.length() - 1)]
      let b = secondary[channel.min(secondary.length() - 1)]
      Array::makei(length, fn(index) {
        let dry = if index < a_length { a[index] } else { 0.0 }
        let wet = if index < b_length { b[index] } else { 0.0 }
        dry + wet * weight
      })
    }),
  )
}

///|
/// Apply linear fades in place. Each duration is in sample intervals.
/// The endpoint samples reach zero and overlapping fades multiply. All
/// planes must contain the same number of samples.
pub fn audio_fade(
  samples : Array[Array[Double]],
  fade_in : Int32,
  fade_out : Int32,
) -> Unit {
  guard samples.get(0) is Some(first) && !first.is_empty() else { return }
  let end = first.length() - 1
  let head = fade_in.min(end)
  let tail = fade_out.min(end)
  if fade_in > 0 {
    for i in 0..<=head {
      let gain = if head == 0 { 0.0 } else { i.to_double() / head.to_double() }
      for plane in samples {
        plane[i] *= gain
      }
    }
  }
  if fade_out > 0 {
    for i in 0..<=tail {
      let gain = if tail == 0 { 0.0 } else { i.to_double() / tail.to_double() }
      for plane in samples {
        plane[end - i] *= gain
      }
    }
  }
}

///|
/// Return the largest absolute PCM sample across all channels.
pub fn audio_sample_peak(samples : Array[Array[Double]]) -> Double {
  let mut peak = 0.0
  for plane in samples {
    for sample in plane {
      peak = peak.max(sample.abs())
    }
  }
  peak
}

///|
/// Apply a constant gain in place, reducing the gain when the requested
/// gain would exceed the linear sample-peak ceiling. Return the actual gain.
pub fn audio_apply_gain(
  samples : Array[Array[Double]],
  gain : Double,
  ceiling : Double,
) -> Double {
  let peak = audio_sample_peak(samples)
  let applied = if peak > 0.0 { gain.min(ceiling / peak) } else { gain }
  if applied != 1.0 {
    for plane in samples {
      for i in 0..<plane.length() {
        plane[i] *= applied
      }
    }
  }
  applied
}
