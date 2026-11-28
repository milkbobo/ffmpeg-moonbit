///|
/// Encode interleaved signed 16-bit PCM as Apple IMA4 blocks. Each block
/// holds 64 samples per channel and the last block is padded with silence.
/// FFmpeg 9.0.2 adpcmenc.c, LGPL-2.1-or-later.
pub fn encode_adpcm_ima_qt(
  samples : ArrayView[Int32],
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("IMA4: expected mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("IMA4: expected complete PCM frames")
  }
  let frames = samples.length() / channels
  let blocks = (frames - 1) / 64 + 1
  let states = Array::makei(channels, _ => adpcm_channel_new())
  let out : Array[Byte] = Array(capacity=blocks * channels * 34)
  for block in 0..<blocks {
    let first = block * 64
    for ch in 0..<channels {
      let state = states[ch]
      let header = (state.predictor & -128) | state.step_index
      out.push((header >> 8).to_byte())
      out.push(header.to_byte())
      for i = 0; i < 64; i = i + 2 {
        let frame = first + i
        let sample0 = if frame < frames {
          samples[frame * channels + ch]
        } else {
          0
        }
        let sample1 = if frame + 1 < frames {
          samples[(frame + 1) * channels + ch]
        } else {
          0
        }
        let low = adpcm_ima_qt_quantize(state, sample0)
        let high = adpcm_ima_qt_quantize(state, sample1)
        out.push(((high << 4) | low).to_byte())
      }
    }
  }
  Ok(Bytes::from_array(out))
}
