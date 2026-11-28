///|
/// Encode CRI ADX type-3 blocks using the standard 500 Hz cutoff.
/// The terminal marker and stream header are written by the container.
/// FFmpeg 9.0.2 adxenc.c, Copyright (c) 2001,2003 BERO. LGPL-2.1-or-later.
pub fn encode_adx_blocks(
  samples : ArrayView[Int32],
  sample_rate : Int32,
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("adx: expected mono or stereo")
  }
  guard sample_rate > 0 && sample_rate <= 0x7fffffff / (channels * 18 * 8) else {
    return Err("adx: invalid sample rate")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("adx: expected complete PCM frames")
  }
  let (coef1, coef2) = adx_coefficients(500, sample_rate)
  let frames = samples.length() / channels
  let blocks = (frames - 1) / 32 + 1
  let out : Array[Byte] = Array(capacity=blocks * 18 * channels)
  let last = FixedArray::make(channels, 0)
  let penultimate = FixedArray::make(channels, 0)
  let pcm = FixedArray::make(32, 0)
  for block in 0..<blocks {
    for ch in 0..<channels {
      let mut s1 = last[ch]
      let mut s2 = penultimate[ch]
      let mut max_delta = 0
      let mut min_delta = 0
      for i in 0..<32 {
        let frame = block * 32 + i
        let sample = if frame < frames {
          clip_int16(samples[frame * channels + ch])
        } else {
          0
        }
        pcm[i] = sample
        let delta = sample + ((-coef1 * s1 - coef2 * s2) >> 12)
        max_delta = max_delta.max(delta)
        min_delta = min_delta.min(delta)
        s2 = s1
        s1 = sample
      }
      if max_delta == 0 && min_delta == 0 {
        last[ch] = s1
        penultimate[ch] = s2
        for _ in 0..<18 {
          out.push(0)
        }
        continue
      }
      let scale = (max_delta / 7).max(-min_delta / 8).max(1)
      out.push((scale >> 8).to_byte())
      out.push(scale.to_byte())
      s1 = last[ch]
      s2 = penultimate[ch]
      let mut packed = 0
      for i in 0..<32 {
        let prediction = coef1 * s1 + coef2 * s2
        let delta = pcm[i] + (-prediction >> 12)
        let bias = if delta >= 0 { scale >> 1 } else { -(scale >> 1) }
        let code = adpcm_clip((delta + bias) / scale, -8, 7)
        packed = (packed << 4) | (code & 15)
        if i % 2 != 0 {
          out.push(packed.to_byte())
          packed = 0
        }
        s2 = s1
        s1 = code * scale + (prediction >> 12)
      }
      last[ch] = s1
      penultimate[ch] = s2
    }
  }
  Ok(Bytes::from_array(out))
}
