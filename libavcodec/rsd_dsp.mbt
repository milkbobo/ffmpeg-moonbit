///|
/// Nintendo DSP ADPCM synthesis from FFmpeg 9.0.2 adpcm.c.
/// THP ADPCM decoder by Marco Gerards. LGPL-2.1-or-later.
pub struct RsdDspDecoder {
  priv coeffs : FixedArray[Int32]
  priv states : Array[AdpcmChannel]
}

///|
/// Load the per-channel coefficient tables from a WADP or GADP header.
pub fn RsdDspDecoder::new(
  channels : Int32,
  data : Bytes,
  little_endian~ : Bool = false,
) -> Result[RsdDspDecoder, String] {
  guard (channels == 1 || channels == 2) && data.length() == 32 * channels else {
    return Err("RSD DSP: invalid channel count or coefficient table")
  }
  let coeffs = FixedArray::makei(channels * 16, i => {
    let a = data[i * 2].to_int()
    let b = data[i * 2 + 1].to_int()
    adpcm_sign16(if little_endian { a | (b << 8) } else { (a << 8) | b })
  })
  Ok({ coeffs, states: Array::makei(channels, _ => adpcm_channel_new()), })
}

///|
/// Decode complete RSD DSP blocks. Stereo WADP stores alternating
/// two-byte words from each channel.
pub fn RsdDspDecoder::decode(
  self : RsdDspDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.states.length()
  let stride = 8 * channels
  let blocks = data.length() / stride
  guard blocks > 0 &&
    data.length() % stride == 0 &&
    blocks <= 0x7fffffff / (14 * channels) else {
    return Err("RSD DSP: invalid audio block size")
  }
  let pcm = Array::make(blocks * 14 * channels, 0)
  for block in 0..<blocks {
    for ch in 0..<channels {
      let at = block * stride + ch * 2
      let header = data[at].to_int()
      let index = ch * 16 + ((header >> 4) & 7) * 2
      let shift = header & 15
      let a = self.coeffs[index].to_int64()
      let b = self.coeffs[index + 1].to_int64()
      let state = self.states[ch]
      for i in 0..<14 {
        let byte = 1 + i / 2
        let packed = data[at + byte / 2 * channels * 2 + byte % 2].to_int()
        let code = if i % 2 == 0 { packed >> 4 } else { packed & 15 }
        let delta = (if code < 8 { code } else { code - 16 }) << shift
        let predicted = (
            state.sample1.to_int64() * a + state.sample2.to_int64() * b
          ) >>
          11
        let sample = adpcm_clip_int16(predicted.to_int() + delta)
        state.sample2 = state.sample1
        state.sample1 = sample
        pcm[(block * 14 + i) * channels + ch] = sample
      }
    }
  }
  Ok(pcm)
}
