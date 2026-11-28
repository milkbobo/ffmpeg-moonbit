///|
/// Decode a Loki SMJPEG APCM packet, with a fresh predictor per channel.
/// FFmpeg 9.0.2 adpcm.c. LGPL-2.1-or-later.
pub fn decode_ima_smjpeg(
  data : BytesView,
  channels : Int32,
) -> Result[Array[Int32], String] {
  guard channels == 1 || channels == 2 else {
    return Err("SMJPEG APCM: expected mono or stereo")
  }
  let header = channels * 4
  let count = data.length() - header
  guard count > 0 && count <= 0x3fffffff else {
    return Err("SMJPEG APCM: invalid packet length")
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  for ch in 0..<channels {
    let pos = ch * 4
    let step = data[pos + 2].to_int()
    guard step <= 88 else { return Err("SMJPEG APCM: invalid step index") }
    states[ch].step_index = step
    states[ch].predictor = adpcm_sign16(
      (data[pos].to_int() << 8) | data[pos + 1].to_int(),
    )
  }
  let pcm = Array::make(count * 2, 0)
  for i in 0..<count {
    let code = data[header + i].to_int()
    pcm[i * 2] = adpcm_ima_expand(states[0], code >> 4)
    pcm[i * 2 + 1] = adpcm_ima_expand(states[channels - 1], code & 15)
  }
  Ok(pcm)
}
