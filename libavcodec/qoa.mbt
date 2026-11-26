///|
/// Frame parameters and LMS synthesis for QOA, following FFmpeg qoadec.c.
/// LGPL-2.1-or-later.
pub struct QoaHeader {
  channels : Int32
  sample_rate : Int32
  samples : Int32
  frame_bytes : Int32
}

///|
fn qoa_u16(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 8) | data[pos + 1].to_int()
}

///|
/// Read a QOA frame header and check that its declared size fits the LMS
/// state and all slices. The caller checks that the payload is present.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.parse_qoa_header(b""[:]) is Err(_))
/// }
/// ```
pub fn parse_qoa_header(data : BytesView) -> Result[QoaHeader, String] {
  if data.length() < 8 {
    return Err("qoa: truncated frame header")
  }
  let channels = data[0].to_int()
  let sample_rate = (data[1].to_int() << 16) | qoa_u16(data, 2)
  let samples = qoa_u16(data, 4)
  let frame_bytes = qoa_u16(data, 6)
  if channels == 0 || sample_rate == 0 || samples == 0 {
    return Err("qoa: invalid frame parameters")
  }
  let required = 8 + channels * (16 + 8 * ((samples + 19) / 20))
  if frame_bytes < required {
    return Err("qoa: frame size too small for slices")
  }
  Ok({ channels, sample_rate, samples, frame_bytes, })
}

///|
/// Magnitudes from FFmpeg qoa_dequant_tab. The low code bit selects sign.
let qoa_dequant : FixedArray[Int32] = [
  1, 3, 5, 7, 5, 18, 32, 49, 16, 53, 95, 147, 34, 113, 203, 315, 63, 210, 378, 588,
  104, 345, 621, 966, 158, 528, 950, 1477, 228, 760, 1368, 2128, 316, 1053, 1895,
  2947, 422, 1405, 2529, 3934, 548, 1828, 3290, 5117, 696, 2320, 4176, 6496, 868,
  2893, 5207, 8099, 1064, 3548, 6386, 9933, 1286, 4288, 7718, 12005, 1536, 5120,
  9216, 14336,
]

///|
/// Decode a self-contained QOA frame to interleaved signed 16-bit PCM.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.decode_qoa_frame(b"") is Err(_))
/// }
/// ```
pub fn decode_qoa_frame(
  data : Bytes,
) -> Result[(QoaHeader, Array[Int32]), String] {
  let src = data[:]
  let h = match parse_qoa_header(src) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if data.length() != h.frame_bytes {
    return Err("qoa: incorrect packet size")
  }
  let history = FixedArray::makei(h.channels * 4, i => {
    qoa_u16(src, 8 + i / 4 * 16 + i % 4 * 2) << 16 >> 16
  })
  let weights = FixedArray::makei(h.channels * 4, i => {
    qoa_u16(src, 16 + i / 4 * 16 + i % 4 * 2) << 16 >> 16
  })
  let pcm = Array::make(h.samples * h.channels, 0)
  let slices = (h.samples + 19) / 20
  let mut pos = 8 + h.channels * 16
  for slice_index in 0..<slices {
    let start = slice_index * 20
    let end = (start + 20).min(h.samples)
    for ch in 0..<h.channels {
      let mut slice = 0UL
      for byte in data[pos:pos + 8] {
        slice = (slice << 8) | byte.to_uint().to_uint64()
      }
      pos += 8
      let scale = (slice >> 60).to_int() * 4
      let base = ch * 4
      for i in start..<end {
        let mut prediction = 0
        for tap in base..<(base + 4) {
          // The reference accumulates as wrapped 32-bit arithmetic.
          prediction += history[tap] * weights[tap]
        }
        let code = ((slice >> 57) & 7UL).to_int()
        let magnitude = qoa_dequant[scale + (code >> 1)]
        let residual = if (code & 1) == 0 { magnitude } else { -magnitude }
        let sample = clip_int16((prediction >> 13) + residual)
        pcm[i * h.channels + ch] = sample
        slice = slice << 3
        let delta = residual >> 4
        for tap in base..<(base + 4) {
          weights[tap] += if history[tap] < 0 { -delta } else { delta }
        }
        for tap in base..<(base + 3) {
          history[tap] = history[tap + 1]
        }
        history[base + 3] = sample
      }
    }
  }
  Ok((h, pcm))
}
