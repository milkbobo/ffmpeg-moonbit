///|
/// Encode continuous Westwood IMA from interleaved s16 PCM. Each channel
/// takes one byte per sample pair, with the earlier sample in the low
/// nibble. Fill a missing final high nibble with code zero.
/// FFmpeg 9.0.2 adpcmenc.c, LGPL-2.1-or-later.
pub fn encode_adpcm_ima_ws(
  samples : ArrayView[Int32],
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("Westwood IMA: expected mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("Westwood IMA: expected complete PCM frames")
  }
  let states = Array::makei(channels, _ => adpcm_channel_new())
  let frames = samples.length() / channels
  let pairs = frames / 2 + frames % 2
  Ok(
    Bytes::makei(pairs * channels, i => {
      let channel = i % channels
      let pos = i / channels * 2 * channels + channel
      let state = states[channel]
      let low = adpcm_ima_quantize_multiply(
        state,
        adpcm_clip_int16(samples[pos]),
      )
      let high = if pos + channels < samples.length() {
        adpcm_ima_quantize_multiply(
          state,
          adpcm_clip_int16(samples[pos + channels]),
        )
      } else {
        0
      }
      ((high << 4) | low).to_byte()
    }),
  )
}
