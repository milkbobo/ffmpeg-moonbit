///|
/// RoQ audio from FFmpeg 9.0.2 `dpcm.c` and `roqaudioenc.c`.
/// Copyright (c) 2003 The FFmpeg project and (c) 2005 Eric Lasota.
/// This port is LGPL-2.1-or-later.
pub fn decode_roq_dpcm(
  packet : BytesView,
  channels : Int32,
) -> Result[Array[Int32], String] {
  guard channels == 1 || channels == 2 else {
    return Err("roq: expected mono or stereo")
  }
  guard packet.length() >= 8 &&
    packet[0].to_int() == 0x1f + channels &&
    packet[1] == b'\x10' else {
    return Err("roq: invalid audio chunk header")
  }
  let length = packet.length() - 8
  let declared = packet[2].to_uint() |
    (packet[3].to_uint() << 8) |
    (packet[4].to_uint() << 16) |
    (packet[5].to_uint() << 24)
  guard declared == length.reinterpret_as_uint() && length % channels == 0 else {
    return Err("roq: invalid audio chunk length")
  }
  let low = packet[6].to_int()
  let high = packet[7].to_int()
  let predictors : FixedArray[Int32] = if channels == 2 {
    [high << 24 >> 16, low << 24 >> 16]
  } else {
    [((high << 8) | low) << 16 >> 16]
  }
  Ok(
    Array::makei(length, i => {
      let code = packet[i + 8].to_int()
      let magnitude = code & 0x7f
      let delta = magnitude * magnitude
      let channel = i % channels
      let sample = predictors[channel] +
        (if code < 128 { delta } else { -delta })
      let sample = sample.clamp(min=-32768, max=32767)
      predictors[channel] = sample
      sample
    }),
  )
}

///|
fn roq_dpcm_quantize(previous : Int32, current : Int32) -> (Byte, Int32) {
  let diff = current - previous
  let sign = if diff < 0 { -1 } else { 1 }
  let magnitude = diff.abs().min(127 * 127)
  let root = magnitude.to_double().sqrt().to_int()
  let mut code = root + (if magnitude > root * root + root { 1 } else { 0 })
  let mut predicted = previous + sign * code * code
  while predicted < -32768 || predicted > 32767 {
    code -= 1
    predicted = previous + sign * code * code
  }
  ((code | (if sign < 0 { 128 } else { 0 })).to_byte(), predicted)
}

///|
/// Encode interleaved s16 PCM as RoQ audio chunks, each with a predictor
/// header. The initial chunk buffers up to eight 735-sample frames.
pub fn encode_roq_dpcm(
  samples : ArrayView[Int32],
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels == 1 || channels == 2 else {
    return Err("roq: expected mono or stereo")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("roq: expected complete PCM samples")
  }
  let predictors : FixedArray[Int32] = [0, 0]
  let frame_size = 735 * channels
  let padding = (frame_size - samples.length() % frame_size) % frame_size
  let total = samples.length().to_int64() + padding.to_int64()
  let out : Array[Byte] = []
  for pos = 0L; pos < total; {
    let frame_limit = if pos == 0L { frame_size * 8 } else { frame_size }
    let size = (total - pos).min(frame_limit.to_int64()).to_int()
    out.push((0x1f + channels).to_byte())
    out.push(b'\x10')
    for shift in 0..<4 {
      out.push((size >> (shift * 8)).to_byte())
    }
    if channels == 2 {
      predictors[0] = predictors[0] & -256
      predictors[1] = predictors[1] & -256
      out.push((predictors[1] >> 8).to_byte())
    } else {
      out.push(predictors[0].to_byte())
    }
    out.push((predictors[0] >> 8).to_byte())
    for i in 0..<size {
      let index = pos + i.to_int64()
      let sample = if index < samples.length().to_int64() {
        samples[index.to_int()].clamp(min=-32768, max=32767)
      } else {
        0
      }
      let channel = i % channels
      let (code, prediction) = roq_dpcm_quantize(predictors[channel], sample)
      out.push(code)
      predictors[channel] = prediction
    }
    continue pos + size.to_int64()
  }
  Ok(Bytes::from_array(out))
}
