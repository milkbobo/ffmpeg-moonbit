///|
/// PlayStation ADPCM filters from FFmpeg 9.0.2 adpcm.c. LGPL-2.1-or-later.
let psx_adpcm_coeffs : FixedArray[(Int32, Int32)] = [
  (0, 0),
  (60, 0),
  (115, -52),
  (98, -55),
  (122, -60),
]

///|
pub struct PsxAdpcmDecoder {
  priv states : Array[AdpcmChannel]
}

///|
/// Initialize a PlayStation ADPCM stream, as used by RSD VAG audio.
pub fn PsxAdpcmDecoder::new(
  channels : Int32,
) -> Result[PsxAdpcmDecoder, String] {
  guard channels == 1 || channels == 2 else {
    return Err("PSX ADPCM: expected mono or stereo")
  }
  Ok({ states: Array::makei(channels, _ => adpcm_channel_new()), })
}

///|
/// Decode complete 16-byte blocks per channel. Each block emits 28 samples;
/// the predictor uses unclipped values while the output is clipped to s16.
pub fn PsxAdpcmDecoder::decode(
  self : PsxAdpcmDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.states.length()
  let stride = channels * 16
  let blocks = data.length() / stride
  guard blocks > 0 &&
    data.length() % stride == 0 &&
    blocks <= 0x7fffffff / (28 * channels) else {
    return Err("PSX ADPCM: invalid packet size")
  }
  // Check all block headers before changing the stream's predictor history.
  for i = 0; i < data.length(); i = i + 16 {
    if data[i].to_int() >> 4 >= psx_adpcm_coeffs.length() {
      return Err("PSX ADPCM: invalid prediction filter")
    }
  }
  let pcm = Array::make(blocks * 28 * channels, 0)
  for block in 0..<blocks {
    for ch in 0..<channels {
      let state = self.states[ch]
      let pos = block * stride + ch * 16
      let header = data[pos].to_int()
      let (coef1, coef2) = psx_adpcm_coeffs[header >> 4]
      let shift = header & 15
      let silent = (data[pos + 1].to_int() & 7) == 7
      for i in 0..<28 {
        let code = (data[pos + 2 + i / 2].to_int() >> ((i & 1) * 4)) & 15
        let scale = if code < 8 { code } else { code - 16 }
        let sample = if silent {
          0
        } else {
          (scale << 12 >> shift) +
          (state.sample1 * coef1 + state.sample2 * coef2) / 64
        }
        state.sample2 = state.sample1
        state.sample1 = sample
        pcm[(block * 28 + i) * channels + ch] = adpcm_clip_int16(sample)
      }
    }
  }
  Ok(pcm)
}
