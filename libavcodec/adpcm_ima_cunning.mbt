///|
/// Pro Pinball IMA tables from FFmpeg 9.0.2 adpcm.c. LGPL-2.1-or-later.
let cunning_steps : FixedArray[Int32] = [
  1, 1, 1, 1, 2, 2, 3, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48,
  56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896,
  1024, 1280, 1536, 1792, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192, 10240,
  12288, 14336, 16384, 20480, 24576, 28672, 0,
]

///|
let cunning_indices : FixedArray[Int32] = [-1, -1, -1, -1, 1, 2, 3, 4, -1]

///|
pub struct CunningImaDecoder {
  priv states : Array[AdpcmChannel]
}

///|
/// Start a Pro Pinball ADPCM stream with one predictor per channel.
pub fn CunningImaDecoder::new(
  channels : Int32,
) -> Result[CunningImaDecoder, String] {
  guard channels == 1 || channels == 2 else {
    return Err("Pro Pinball IMA: expected mono or stereo")
  }
  Ok({ states: Array::makei(channels, _ => adpcm_channel_new()), })
}

///|
fn cunning_expand(state : AdpcmChannel, nibble : Int32) -> Int32 {
  let signed = if nibble < 8 { nibble } else { nibble - 16 }
  let sample = adpcm_clip_int16(
    state.predictor + cunning_steps[state.step_index] * signed,
  )
  state.step_index = adpcm_clip(
    state.step_index + cunning_indices[signed.abs()],
    0,
    60,
  )
  state.predictor = sample
  sample
}

///|
/// Decode a planar ADPCM packet to interleaved s16 PCM, preserving state.
pub fn CunningImaDecoder::decode(
  self : CunningImaDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.states.length()
  guard !data.is_empty() &&
    data.length() % channels == 0 &&
    data.length() <= 0x3fffffff else {
    return Err("Pro Pinball IMA: invalid packet size")
  }
  let size = data.length() / channels
  let samples = Array::make(data.length() * 2, 0)
  for ch in 0..<channels {
    let state = self.states[ch]
    for i in 0..<size {
      let code = data[ch * size + i].to_int()
      let index = i * channels * 2 + ch
      samples[index] = cunning_expand(state, code & 15)
      samples[index + channels] = cunning_expand(state, code >> 4)
    }
  }
  Ok(samples)
}
