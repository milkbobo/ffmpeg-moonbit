///|
/// Nintendo AFC from FFmpeg 9.0.2 adpcm.c (LGPL-2.1-or-later).
let adpcm_afc_coefficients : FixedArray[(Int32, Int32)] = [
  (0, 0),
  (2048, 0),
  (0, 2048),
  (1024, 1024),
  (4096, -2048),
  (3584, -1536),
  (3072, -1024),
  (4608, -2560),
  (4200, -2248),
  (4800, -2300),
  (5120, -3072),
  (2048, -2048),
  (1024, -1024),
  (-1024, 1024),
  (-1024, 0),
  (-2048, 0),
]

///|
pub struct AfcDecoder {
  priv states : Array[AdpcmChannel]
}

///|
pub fn AfcDecoder::new(channels : Int32) -> Result[AfcDecoder, String] {
  guard channels >= 1 && channels <= 6 else {
    return Err("afc: invalid channel count")
  }
  Ok({ states: Array::makei(channels, _ => adpcm_channel_new()), })
}

///|
/// Decode a packet with all nine-byte frames for each channel stored together.
/// Each frame produces 16 samples. The predictor history survives packet boundaries.
pub fn AfcDecoder::decode(
  self : AfcDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.states.length()
  let stride = 9 * channels
  let blocks = data.length() / stride
  guard blocks > 0 &&
    data.length() % stride == 0 &&
    blocks <= 0x7fffffff / (16 * channels) else {
    return Err("afc: invalid planar packet size")
  }
  let pcm = Array::make(blocks * 16 * channels, 0)
  for ch in 0..<channels {
    let state = self.states[ch]
    for block in 0..<blocks {
      let pos = (ch * blocks + block) * 9
      let header = data[pos].to_int()
      let (a, b) = adpcm_afc_coefficients[header & 15]
      let shift = header >> 4
      for i in 0..<16 {
        let packed = data[pos + 1 + i / 2].to_int()
        let nibble = if i % 2 == 0 { packed >> 4 } else { packed & 15 }
        let delta = nibble << 28 >> 28 << shift
        let predicted = (state.sample1 * a + state.sample2 * b) >> 11
        let sample = adpcm_clip_int16(predicted + delta)
        state.sample2 = state.sample1
        state.sample1 = sample
        pcm[(block * 16 + i) * channels + ch] = sample
      }
    }
  }
  Ok(pcm)
}
