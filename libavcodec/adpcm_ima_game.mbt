///|
/// APM and APC store their initial predictors as signed 32-bit words.
fn adpcm_predictor_le32(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
/// APM and MTF store two samples in each byte, then alternate channels.
fn AdpcmDecoder::decode_ima_channel_pairs(
  self : AdpcmDecoder,
  data : Bytes,
  expand : (AdpcmChannel, Int32) -> Int32,
) -> Result[AdpcmAudio, String] {
  let channels = self.channels
  guard !data.is_empty() &&
    data.length() % channels == 0 &&
    data.length() <= 0x3fffffff else {
    return Err("adpcm: incomplete IMA channel pairs")
  }
  let samples = Array::make(data.length() * 2, 0)
  for pos = 0; pos < data.length(); pos = pos + channels {
    for ch in 0..<channels {
      let code = data[pos + ch].to_int()
      let state = self.status[ch]
      samples[pos * 2 + ch] = expand(state, code >> 4)
      samples[pos * 2 + ch + channels] = expand(state, code & 15)
    }
  }
  Ok({ channels, samples, })
}

///|
/// MT Framework quantizer index deltas from FFmpeg 9.0.2 adpcm.c.
let adpcm_mtf_indices : FixedArray[Int32] = [
  8, 6, 4, 2, -1, -1, -1, -1, -1, -1, -1, -1, 2, 4, 6, 8,
]

///|
fn adpcm_ima_mtf_expand(state : AdpcmChannel, code : Int32) -> Int32 {
  let step = adpcm_step_table[state.step_index]
  let predictor = (state.predictor + step * (2 * code - 15)) >> 4
  state.predictor = adpcm_clip_int16(predictor)
  state.step_index = adpcm_clip(
    state.step_index + adpcm_mtf_indices[code],
    0,
    88,
  )
  state.predictor
}

///|
/// Greedy IMA QuickTime quantization used by SSI and APM in adpcmenc.c.
fn adpcm_ima_qt_quantize(state : AdpcmChannel, sample : Int32) -> Int32 {
  let delta = adpcm_clip_int16(sample) - state.predictor
  let step = adpcm_step_table[state.step_index]
  let mut remaining = delta.abs()
  let mut code = if delta < 0 { 8 } else { 0 }
  for shift in 0..<3 {
    let part = step >> shift
    if remaining >= part {
      code = code | (4 >> shift)
      remaining = remaining - part
    }
  }
  ignore(adpcm_ima_expand(state, code))
  code
}

///|
/// Encode mono or stereo PCM as continuous SSI IMA ADPCM (`apm=false`)
/// or APM IMA ADPCM. A missing low nibble in the final pair is zero-filled.
pub fn encode_ima_game(
  samples : ArrayView[Int32],
  channels : Int32,
  apm~ : Bool = false,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("adpcm: SSI/APM encoding requires mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("adpcm: expected complete PCM frames")
  }
  let state = Array::makei(channels, _ => adpcm_channel_new())
  if apm && channels == 2 {
    let frames = samples.length() / 2
    let pairs = frames / 2 + frames % 2
    return Ok(
      Bytes::makei(pairs * 2, i => {
        let pos = i / 2 * 4 + i % 2
        let channel = state[i % 2]
        let high = adpcm_ima_qt_quantize(channel, samples[pos])
        let low = if pos + 2 < samples.length() {
          adpcm_ima_qt_quantize(channel, samples[pos + 2])
        } else {
          0
        }
        ((high << 4) | low).to_byte()
      }),
    )
  }
  Ok(
    Bytes::makei(samples.length() / 2 + samples.length() % 2, i => {
      let pos = i * 2
      let high = adpcm_ima_qt_quantize(state[0], samples[pos])
      let low = if pos + 1 < samples.length() {
        adpcm_ima_qt_quantize(state[channels - 1], samples[pos + 1])
      } else {
        0
      }
      ((high << 4) | low).to_byte()
    }),
  )
}
