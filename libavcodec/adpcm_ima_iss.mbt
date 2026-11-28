///|
/// Decode one Funcom ISS IMA ADPCM packet to interleaved s16 PCM.
/// FFmpeg 9.0.2 adpcm.c. LGPL-2.1-or-later.
pub fn decode_ima_iss(
  data : Bytes,
  channels : Int32,
) -> Result[Array[Int32], String] {
  guard channels == 1 || channels == 2 else {
    return Err("ISS: expected mono or stereo")
  }
  let header = channels * 4
  guard data.length() > header && data.length() - header <= 0x3fffffff else {
    return Err("ISS: invalid packet length")
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  for ch in 0..<channels {
    let state = states[ch]
    state.predictor = adpcm_le16(data, ch * 4)
    state.step_index = adpcm_le16(data, ch * 4 + 2)
    guard state.step_index >= 0 && state.step_index <= 88 else {
      return Err("ISS: invalid step index")
    }
  }
  let count = data.length() - header
  let pcm = Array::make(count * 2, 0)
  for i in 0..<count {
    let code = data[header + i].to_int()
    let (first, second) = if channels == 1 {
      (code & 15, code >> 4)
    } else {
      (code >> 4, code & 15)
    }
    pcm[i * 2] = adpcm_ima_expand_multiply(states[0], first)
    pcm[i * 2 + 1] = adpcm_ima_expand_multiply(states[channels - 1], second)
  }
  Ok(pcm)
}
