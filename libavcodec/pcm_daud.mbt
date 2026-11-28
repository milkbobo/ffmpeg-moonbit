///|
/// D-Cinema PCM packing from FFmpeg 9.0.2 pcm.c (LGPL-2.1-or-later).
/// Each signed 16-bit sample occupies a 24-bit word with room for sync bits.
pub fn encode_pcm_daud(samples : ArrayView[Int32]) -> Bytes {
  let out : Array[Byte] = Array(capacity=samples.length() * 3)
  for sample in samples {
    let low = reverse_byte_bits[sample & 0xff]
    let high = reverse_byte_bits[(sample >> 8) & 0xff]
    out.push((low >> 4).to_byte())
    out.push(((low << 4) | (high >> 4)).to_byte())
    out.push((high << 4).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Decode 24-bit D-Cinema words to signed 16-bit PCM, ignoring sync bits.
pub fn decode_pcm_daud(data : BytesView) -> Result[Array[Int32], String] {
  guard data.length() % 3 == 0 else { return Err("daud: incomplete PCM word") }
  Ok(
    Array::makei(data.length() / 3, i => {
      let pos = i * 3
      let middle = data[pos + 1].to_int()
      let low = reverse_byte_bits[((data[pos].to_int() & 15) << 4) |
        (middle >> 4)]
      let high = reverse_byte_bits[((middle & 15) << 4) |
        (data[pos + 2].to_int() >> 4)]
      ((high << 8) | low) << 16 >> 16
    }),
  )
}
