///|
/// G.722 quantizer thresholds from FFmpeg 9.0.2 `g722enc.c` (LGPL-2.1-or-later).
let g722_low_quant : FixedArray[Int32] = [
  35, 72, 110, 150, 190, 233, 276, 323, 370, 422, 473, 530, 587, 650, 714, 786, 858,
  940, 1023, 1121, 1219, 1339, 1458, 1612, 1765, 1980, 2195, 2557, 2919,
]

///|
fn g722_quantize_low(band : G722Band, input : Int32) -> Int32 {
  let diff = g722_clip_int16(input - band.s_predictor)
  let limit = ((diff ^ (diff >> 31)) + 1) << 10
  let mut index = 0
  while index < g722_low_quant.length() &&
        limit > g722_low_quant[index] * band.scale_factor {
    index += 1
  }
  let base = if diff >= 0 { 61 } else if index < 2 { 63 } else { 33 }
  base - index
}

///|
fn g722_quantize_high(band : G722Band, input : Int32) -> Int32 {
  let diff = g722_clip_int16(input - band.s_predictor)
  let magnitude = diff ^ (diff >> 31)
  let threshold = (141 * band.scale_factor) >> 8
  (if diff >= 0 { 2 } else { 0 }) + (if magnitude < threshold { 1 } else { 0 })
}

///|
/// Encode signed 16-bit mono PCM to 64 kbit/s G.722, using FFmpeg's default
/// quantizer. An odd final sample is repeated to complete the last codeword.
pub fn encode_g722(samples : ArrayView[Int32]) -> Bytes {
  let low = g722_band_new()
  let high = g722_band_new()
  low.scale_factor = 8
  high.scale_factor = 2
  let history = FixedArray::make(1024, 0)
  let mut pos = 22
  let size = samples.length() / 2 + samples.length() % 2
  Bytes::makei(size, i => {
    let first = g722_clip_int16(samples[i * 2])
    let second = g722_clip_int16(samples[(i * 2 + 1).min(samples.length() - 1)])
    let (x0, x1, next_pos) = g722_qmf_pair(history, pos, first, second)
    pos = next_pos
    let ilow = g722_quantize_low(low, (x0 + x1) >> 14)
    let ihigh = g722_quantize_high(high, (x0 - x1) >> 14)
    g722_update_low_predictor(low, ilow >> 2)
    let reconstructed_high = (high.scale_factor * g722_high_inv_quant[ihigh]) >>
      10
    g722_update_high_predictor(high, reconstructed_high, ihigh)
    ((ihigh << 6) | ilow).to_byte()
  })
}
