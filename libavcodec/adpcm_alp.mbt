///|
/// IMA ALP from FFmpeg 9.0.2 `adpcm.c` and `adpcmenc.c` (LGPL-2.1-or-later).
pub struct AlpDecoder {
  priv states : Array[AdpcmChannel]
}

///|
/// Start a mono or stereo stream at the initial IMA predictor state.
pub fn AlpDecoder::new(channels : Int32) -> Result[AlpDecoder, String] {
  guard channels == 1 || channels == 2 else {
    return Err("alp: expected mono or stereo")
  }
  Ok({ states: Array::makei(channels, _ => adpcm_channel_new()), })
}

///|
fn alp_expand(state : AdpcmChannel, code : Int32) -> Int32 {
  let step = adpcm_step_table[state.step_index]
  let magnitude = (step * (code & 7)) >> 2
  let delta = if code < 8 { magnitude } else { -magnitude }
  state.predictor = adpcm_clip_int16(state.predictor + delta)
  state.step_index = adpcm_clip(
    state.step_index + adpcm_index_table[code],
    0,
    88,
  )
  state.predictor
}

///|
/// Decode a packet to interleaved s16 PCM, preserving the stream predictors.
pub fn AlpDecoder::decode(
  self : AlpDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.states.length()
  guard data.length() % channels == 0 && data.length() <= 0x3fffffff else {
    return Err("alp: invalid packet length")
  }
  let pcm = Array::make(data.length() * 2, 0)
  for pos = 0; pos < data.length(); pos = pos + channels {
    for ch in 0..<channels {
      let code = data[pos + ch].to_int()
      let state = self.states[ch]
      pcm[pos * 2 + ch] = alp_expand(state, code >> 4)
      pcm[pos * 2 + ch + channels] = alp_expand(state, code & 15)
    }
  }
  Ok(pcm)
}

///|
fn alp_quantize(state : AdpcmChannel, sample : Int32) -> Int32 {
  let diff = adpcm_clip_int16(sample) - state.predictor
  let step = adpcm_step_table[state.step_index]
  let magnitude = (diff.abs() * 4 / step).min(7)
  let code = magnitude | (if diff < 0 { 8 } else { 0 })
  let _ = alp_expand(state, code)
  code
}

///|
/// Encode interleaved mono or stereo s16 PCM as a continuous ALP payload.
/// A final unpaired sample is encoded and followed by a zero-delta code.
pub fn encode_ima_alp(
  samples : ArrayView[Int32],
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("alp: expected mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("alp: expected complete PCM samples")
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  let frames = samples.length() / channels
  let pairs = frames / 2 + frames % 2
  Ok(
    Bytes::makei(pairs * channels, i => {
      let channel = i % channels
      let frame = i / channels * 2
      let state = states[channel]
      let first = alp_quantize(state, samples[frame * channels + channel])
      let second = if frame + 1 < frames {
        alp_quantize(state, samples[(frame + 1) * channels + channel])
      } else {
        0
      }
      ((first << 4) | second).to_byte()
    }),
  )
}
