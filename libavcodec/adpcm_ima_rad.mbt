///|
/// Decode a Radical Games IMA ADPCM block to interleaved s16 PCM.
/// Each channel starts with a little-endian step index and predictor.
/// FFmpeg 9.0.2 adpcm.c, LGPL-2.1-or-later.
pub fn decode_ima_rad(
  data : Bytes,
  channels : Int32,
) -> Result[Array[Int32], String] {
  guard channels == 1 || channels == 2 else {
    return Err("RADP: expected mono or stereo")
  }
  let head = channels * 4
  guard data.length() > head &&
    data.length() % channels == 0 &&
    data.length() - head <= 0x3fffffff else {
    return Err("RADP: invalid block size")
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  for ch in 0..<channels {
    let index = adpcm_le16(data, ch * 4)
    guard index >= 0 && index <= 88 else {
      return Err("RADP: invalid step index")
    }
    states[ch].step_index = index
    states[ch].predictor = adpcm_le16(data, ch * 4 + 2)
  }
  let pcm = Array::make((data.length() - head) * 2, 0)
  for pos = head; pos < data.length(); pos = pos + channels {
    let base = (pos - head) * 2
    for ch in 0..<channels {
      let code = data[pos + ch].to_int()
      pcm[base + ch] = adpcm_ima_expand_multiply(states[ch], code & 15)
      pcm[base + ch + channels] = adpcm_ima_expand_multiply(
        states[ch],
        code >> 4,
      )
    }
  }
  Ok(pcm)
}
