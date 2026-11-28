///|
/// Count the interleaved frames in a Xan DPCM packet, excluding predictors.
pub fn xan_dpcm_packet_frames(
  size : Int32,
  channels : Int32,
) -> Result[Int32, String] {
  guard channels == 1 || channels == 2 else {
    return Err("xan_dpcm: expected mono or stereo")
  }
  guard size > 2 * channels && size % channels == 0 else {
    return Err("xan_dpcm: incomplete packet")
  }
  Ok(size / channels - 2)
}

///|
/// Decode one Xan DPCM packet to s16. The N leading little-endian predictors
/// and the shift state are local to the packet.
/// FFmpeg 9.0.2 dpcm.c, Copyright (c) 2003 The FFmpeg project.
/// LGPL-2.1-or-later.
pub fn decode_xan_dpcm(
  data : BytesView,
  channels : Int32,
) -> Result[Array[Int32], String] {
  let frames = match xan_dpcm_packet_frames(data.length(), channels) {
    Ok(count) => count
    Err(error) => return Err(error)
  }
  let predictor = FixedArray::makei(channels, ch => {
    adpcm_sign16(data[2 * ch].to_int() | (data[2 * ch + 1].to_int() << 8))
  })
  let shifts = FixedArray::make(channels, 4)
  Ok(
    Array::makei(frames * channels, i => {
      let ch = i % channels
      let code = data[2 * channels + i].to_int()
      let adjust = code & 3
      let next_shift = if adjust == 3 {
        shifts[ch] + 1
      } else {
        shifts[ch] - 2 * adjust
      }
      shifts[ch] = adpcm_clip(next_shift, 0, 31)
      let delta = adpcm_sign16((code & 0xfc) << 8) >> shifts[ch]
      predictor[ch] = adpcm_clip_int16(predictor[ch] + delta)
      predictor[ch]
    }),
  )
}
