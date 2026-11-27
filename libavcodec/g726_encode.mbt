///|
/// Adaptive quantizer from FFmpeg 9.0.2 `libavcodec/g726.c` (LGPL-2.1-or-later).
fn G726Decoder::quantize_sample(self : G726Decoder, sample : Int32) -> Int32 {
  let difference = sample.clamp(min=-32768, max=32767) / 4 - self.se
  let magnitude = difference.abs()
  let exp = g726_log2_16bit(magnitude)
  let log_difference = (exp << 7) +
    ((magnitude << 7 >> exp) & 0x7f) -
    (self.y >> 2)
  let mut index = 0
  while self.quant[index] < log_difference {
    index += 1
  }
  let index = if difference < 0 { -index - 1 } else { index }
  let index = if self.code_size != 2 && index == 0 { -1 } else { index }
  index & ((1 << self.code_size) - 1)
}

///|
/// Encode mono signed 16-bit PCM as a continuous G.726 stream.
/// The default is MSB-first. Select LSB-first for G.726LE.
/// Up to seven zero bits pad the final byte, as in FFmpeg.
pub fn encode_g726(
  samples : ArrayView[Int32],
  code_size : Int32,
  little_endian~ : Bool = false,
) -> Result[Bytes, String] {
  let state = match g726_decoder_new(code_size, little_endian~) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  let output : Array[Byte] = []
  let mut pending = 0
  let mut pending_bits = 0
  for sample in samples {
    let code = state.quantize_sample(sample)
    let _ = state.step(code)
    if little_endian {
      pending = pending | (code << pending_bits)
      pending_bits += code_size
      if pending_bits >= 8 {
        output.push(pending.to_byte())
        pending = pending >> 8
        pending_bits -= 8
      }
    } else {
      pending = (pending << code_size) | code
      pending_bits += code_size
      if pending_bits >= 8 {
        pending_bits -= 8
        output.push((pending >> pending_bits).to_byte())
        pending = pending & ((1 << pending_bits) - 1)
      }
    }
  }
  if pending_bits != 0 {
    output.push(
      (if little_endian { pending } else { pending << (8 - pending_bits) }).to_byte(),
    )
  }
  Ok(Bytes::from_array(output))
}
