///|
/// Argonaut Games ADPCM from FFmpeg 9.0.2 adpcm.c and adpcmenc.c.
/// LGPL-2.1-or-later.
pub struct ArgoAdpcmDecoder {
  priv states : Array[AdpcmChannel]
}

///|
/// Start a mono or stereo stream with zero predictor history.
pub fn ArgoAdpcmDecoder::new(
  channels : Int32,
) -> Result[ArgoAdpcmDecoder, String] {
  guard channels == 1 || channels == 2 else {
    return Err("argo ADPCM: expected mono or stereo")
  }
  Ok({ states: Array::makei(channels, _ => adpcm_channel_new()), })
}

///|
fn argo_predict(state : AdpcmChannel, second_order : Bool) -> Int32 {
  if second_order {
    2 * state.sample1 - state.sample2
  } else {
    state.sample1
  }
}

///|
fn argo_expand(
  state : AdpcmChannel,
  code : Int32,
  shift : Int32,
  second_order : Bool,
) -> Int32 {
  let signed = if code < 8 { code } else { code - 16 }
  let sample = adpcm_clip_int16(
    argo_predict(state, second_order) + (signed << (shift - 2)),
  )
  state.sample2 = state.sample1
  state.sample1 = sample
  sample
}

///|
/// Decode complete ADPCM blocks to interleaved signed 16-bit PCM.
pub fn ArgoAdpcmDecoder::decode(
  self : ArgoAdpcmDecoder,
  packet : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.states.length()
  let block_size = 17 * channels
  let blocks = packet.length() / block_size
  guard blocks > 0 &&
    packet.length() % block_size == 0 &&
    blocks <= 0x7fffffff / (32 * channels) else {
    return Err("argo ADPCM: invalid packet length")
  }
  let pcm = Array::make(blocks * 32 * channels, 0)
  for block in 0..<blocks {
    for ch in 0..<channels {
      let offset = block * block_size + ch * 17
      let control = packet[offset].to_int()
      let shift = (control >> 4) + 2
      let second_order = (control & 4) != 0
      let state = self.states[ch]
      for i in 0..<16 {
        let codes = packet[offset + 1 + i].to_int()
        let pos = (block * 32 + i * 2) * channels + ch
        pcm[pos] = argo_expand(state, codes >> 4, shift, second_order)
        pcm[pos + channels] = argo_expand(
          state,
          codes & 15,
          shift,
          second_order,
        )
      }
    }
  }
  Ok(pcm)
}

///|
fn argo_quantize(
  state : AdpcmChannel,
  sample : Int32,
  shift : Int32,
  second_order : Bool,
) -> Int32 {
  let delta = sample - argo_predict(state, second_order)
  let code = (delta >> (shift - 2)) & 15
  ignore(argo_expand(state, code, shift, second_order))
  code
}

///|
fn argo_encode_channel(
  state : AdpcmChannel,
  pcm : FixedArray[Int32],
  out : Array[Byte],
) -> Unit {
  let prev1 = state.sample1
  let prev2 = state.sample2
  let mut best_error = 0x7fffffff
  let mut best_shift = 2
  let mut best_second_order = false
  for shift = 2; shift <= 17 && best_error != 0; shift = shift + 1 {
    for order in 0..<2 {
      let second_order = order == 1
      state.sample1 = prev1
      state.sample2 = prev2
      let mut error = 0
      for sample in pcm {
        ignore(argo_quantize(state, sample, shift, second_order))
        error = error + (sample - state.sample1).abs()
      }
      if error < best_error {
        best_error = error
        best_shift = shift
        best_second_order = second_order
      }
      if best_error == 0 {
        break
      }
    }
  }
  state.sample1 = prev1
  state.sample2 = prev2
  out.push(
    (((best_shift - 2) << 4) | (if best_second_order { 4 } else { 0 })).to_byte(),
  )
  for i = 0; i < 32; i = i + 2 {
    let high = argo_quantize(state, pcm[i], best_shift, best_second_order)
    let low = argo_quantize(state, pcm[i + 1], best_shift, best_second_order)
    out.push(((high << 4) | low).to_byte())
  }
}

///|
/// Encode interleaved s16 mono or stereo PCM. Pad the last block with
/// silence to 32 samples per channel.
pub fn encode_adpcm_argo(
  samples : ArrayView[Int32],
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("argo ADPCM: expected mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("argo ADPCM: expected complete PCM frames")
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  let frames = samples.length() / channels
  let blocks = (frames - 1) / 32 + 1
  let out : Array[Byte] = Array(capacity=blocks * 17 * channels)
  let pcm = FixedArray::make(32, 0)
  for block in 0..<blocks {
    let start = block * 32
    for ch in 0..<channels {
      for i in 0..<32 {
        let frame = start + i
        pcm[i] = if frame < frames {
          adpcm_clip_int16(samples[frame * channels + ch])
        } else {
          0
        }
      }
      argo_encode_channel(states[ch], pcm, out)
    }
  }
  Ok(Bytes::from_array(out))
}
