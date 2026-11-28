///|
/// Magnitudes from FFmpeg 9.0.2 dpcm.c, LGPL-2.1-or-later.
let wady_magnitudes : FixedArray[Int32] = [
  0, 2, 4, 6, 8, 10, 12, 15, 18, 21, 24, 28, 32, 36, 40, 44, 49, 54, 59, 64, 70,
  76, 82, 88, 95, 102, 109, 116, 124, 132, 140, 148, 160, 170, 180, 190, 200, 210,
  220, 230, 240, 255, 270, 285, 300, 320, 340, 360, 380, 400, 425, 450, 475, 500,
  525, 550, 580, 610, 650, 700, 750, 800, 900, 1000,
]

///|
pub struct DerfWadyDecoder {
  priv wady_scale : Int32?
  priv predictor : FixedArray[Int32]
}

///|
/// Initialize a DERF decoder, or WADY when its header scale is supplied.
pub fn DerfWadyDecoder::new(
  channels : Int32,
  wady_scale~ : Int32? = None,
) -> Result[DerfWadyDecoder, String] {
  guard channels == 1 || channels == 2 else {
    return Err("DERF/WADY DPCM: expected mono or stereo")
  }
  if wady_scale is Some(scale) && (scale < 0 || scale > 255) {
    return Err("WADY DPCM: invalid scale")
  }
  Ok({ wady_scale, predictor: FixedArray::make(channels, 0), })
}

///|
/// Decode complete interleaved frames and keep predictors for the next packet.
pub fn DerfWadyDecoder::decode(
  self : DerfWadyDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.predictor.length()
  guard !data.is_empty() && data.length() % channels == 0 else {
    return Err("DERF/WADY DPCM: incomplete channel frame")
  }
  if self.wady_scale is Some(scale) {
    return Ok(
      Array::makei(data.length(), i => {
        let code = data[i].to_int()
        let channel = i % channels
        let sample = if code >= 128 {
          adpcm_sign16((code & 127) << 9)
        } else {
          let magnitude = wady_magnitudes[code & 63] * scale
          self.predictor[channel] +
          (if code < 64 { magnitude } else { -magnitude })
        }
        self.predictor[channel] = sample
        adpcm_clip_int16(sample)
      }),
    )
  }
  Ok(
    Array::makei(data.length(), i => {
      let code = data[i].to_int()
      let channel = i % channels
      let index = (code & 127).min(95)
      // The DERF table is 0..6 followed by the standard IMA step table.
      let magnitude = if index < 7 {
        index
      } else {
        adpcm_step_table[index - 7]
      }
      let delta = if code < 128 { magnitude } else { -magnitude }
      let sample = adpcm_clip_int16(self.predictor[channel] + delta)
      self.predictor[channel] = sample
      sample
    }),
  )
}
