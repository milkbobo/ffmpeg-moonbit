///|
/// ADPCM blocks and WAVEFORMATEX extension from FFmpeg 9.0.2's default
/// (non-trellis) encoder paths in adpcmenc.c, LGPL-2.1-or-later.
pub struct AdpcmWavEncoding {
  payload : Bytes
  format_tag : Int32
  samples_per_block : Int32
  extradata : Bytes
}

///|
fn adpcm_write_le16(out : Array[Byte], value : Int32) -> Unit {
  out.push(value.to_byte())
  out.push((value >> 8).to_byte())
}

///|
fn adpcm_wav_quantize(delta : Int32, step : Int32) -> Int32 {
  (delta.abs() * 4 / step).min(7) | (if delta < 0 { 8 } else { 0 })
}

///|
fn adpcm_ima_quantize_multiply(state : AdpcmChannel, sample : Int32) -> Int32 {
  let code = adpcm_wav_quantize(
    sample - state.predictor,
    adpcm_step_table[state.step_index],
  )
  // FFmpeg uses the multiply-and-shift predictor for encoding even though
  // its IMA WAV decoder reconstructs the delta with individual shifts.
  ignore(adpcm_ima_expand_multiply(state, code))
  code
}

///|
fn adpcm_wav_encode_ms(state : AdpcmChannel, sample : Int32) -> Int32 {
  // The default encoder selects coefficient pair 0 (predict from sample1).
  let delta = sample - state.sample1
  let bias = if delta >= 0 { state.idelta / 2 } else { -(state.idelta / 2) }
  let code = adpcm_clip((delta + bias) / state.idelta, -8, 7) & 15
  ignore(adpcm_ms_expand(state, code))
  code
}

///|
/// Encode interleaved signed 16-bit PCM as mono or stereo ADPCM WAV blocks.
/// The final block is padded with silence to the requested power-of-two
/// block size (32–8192 bytes).
pub fn encode_adpcm_wav(
  samples : ArrayView[Int32],
  codec : String,
  channels : Int32,
  block_size~ : Int32 = 1024,
) -> Result[AdpcmWavEncoding, String] {
  guard channels == 1 || channels == 2 else {
    return Err("adpcm: WAV encoding requires mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("adpcm: expected complete PCM frames")
  }
  guard block_size >= 32 &&
    block_size <= 8192 &&
    (block_size & (block_size - 1)) == 0 else {
    return Err("adpcm: block size must be a power of two from 32 to 8192")
  }
  let (format_tag, samples_per_block) = match codec {
    "adpcm_ima_wav" => (0x0011, (block_size / channels - 4) * 2 + 1)
    "adpcm_ms" => (0x0002, (block_size / channels - 7) * 2 + 2)
    "adpcm_yamaha" => (0x0020, block_size * 2 / channels)
    _ => return Err("adpcm: unsupported WAV encoder \{codec}")
  }
  let input_frames = samples.length() / channels
  let blocks = (input_frames - 1) / samples_per_block + 1
  let padded_samples = blocks.to_int64() * samples_per_block.to_int64()
  guard padded_samples * channels.to_int64() <= 0x7FFFFFFFL else {
    return Err("adpcm: too many PCM samples")
  }
  let extra : Array[Byte] = []
  if codec != "adpcm_yamaha" {
    adpcm_write_le16(extra, samples_per_block)
  }
  if codec == "adpcm_ms" {
    adpcm_write_le16(extra, adpcm_coeff1.length())
    for i in 0..<adpcm_coeff1.length() {
      adpcm_write_le16(extra, adpcm_coeff1[i] * 4)
      adpcm_write_le16(extra, adpcm_coeff2[i] * 4)
    }
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  let out : Array[Byte] = Array(capacity=blocks * block_size)
  for block in 0..<blocks {
    let base = block * samples_per_block * channels
    let sample = fn(i : Int32) -> Int32 {
      let pos = base + i
      if pos < samples.length() {
        adpcm_clip_int16(samples[pos])
      } else {
        0
      }
    }
    match codec {
      "adpcm_ima_wav" => {
        for c in 0..<channels {
          let state = states[c]
          state.predictor = sample(c)
          adpcm_write_le16(out, state.predictor)
          adpcm_write_le16(out, state.step_index)
        }
        for start = 1; start < samples_per_block; start = start + 8 {
          for c in 0..<channels {
            let state = states[c]
            for i = 0; i < 8; i = i + 2 {
              let pos = (start + i) * channels + c
              let low = adpcm_ima_quantize_multiply(state, sample(pos))
              let high = adpcm_ima_quantize_multiply(
                state,
                sample(pos + channels),
              )
              out.push((low | (high << 4)).to_byte())
            }
          }
        }
      }
      "adpcm_ms" => {
        for _ in 0..<channels {
          out.push(0)
        }
        for state in states {
          state.idelta = state.idelta.max(16)
          state.coeff1 = adpcm_coeff1[0]
          adpcm_write_le16(out, state.idelta)
        }
        for c in 0..<channels {
          states[c].sample1 = sample(channels + c)
          adpcm_write_le16(out, states[c].sample1)
        }
        for c in 0..<channels {
          states[c].sample2 = sample(c)
          adpcm_write_le16(out, states[c].sample2)
        }
        for i = 2 * channels; i < samples_per_block * channels; i = i + 2 {
          let high = adpcm_wav_encode_ms(states[0], sample(i))
          let low = adpcm_wav_encode_ms(states[channels - 1], sample(i + 1))
          out.push(((high << 4) | low).to_byte())
        }
      }
      _ =>
        for i = 0; i < samples_per_block * channels; i = i + 2 {
          let state0 = states[0]
          let state1 = states[channels - 1]
          let low = adpcm_wav_quantize(
            sample(i) - state0.predictor,
            state0.step.max(127),
          )
          ignore(adpcm_yamaha_expand(state0, low))
          let high = adpcm_wav_quantize(
            sample(i + 1) - state1.predictor,
            state1.step.max(127),
          )
          ignore(adpcm_yamaha_expand(state1, high))
          out.push((low | (high << 4)).to_byte())
        }
    }
  }
  Ok({
    payload: Bytes::from_array(out),
    format_tag,
    samples_per_block,
    extradata: Bytes::from_array(extra),
  })
}
