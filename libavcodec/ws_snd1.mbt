///|
/// Westwood SND1 signed delta table from FFmpeg's LGPL-2.1-or-later
/// libavcodec/ws-snd1.c by Konstantin Shishkov.
let ws_snd1_deltas : FixedArray[Int32] = [
  -9, -8, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8,
]

///|
/// Decode mono Westwood SND1 to signed 16-bit PCM. The packet begins with
/// the decoded and coded sizes as two little-endian 16-bit integers.
///
/// ```mbt check
/// test {
///   let pcm = @libavcodec.decode_ws_snd1(b"\x02\x00\x02\x00\x00\x80").unwrap()
///   assert_eq(pcm, [-32768, 0])
/// }
/// ```
pub fn decode_ws_snd1(packet : Bytes) -> Result[Array[Int32], String] {
  if packet.length() < 4 {
    return Err("ws_snd1: truncated packet header")
  }
  let output_size = packet[0].to_int() | (packet[1].to_int() << 8)
  let coded_size = packet[2].to_int() | (packet[3].to_int() << 8)
  if output_size == 0 || coded_size == 0 || coded_size != packet.length() - 4 {
    return Err("ws_snd1: invalid packet sizes")
  }
  if coded_size == output_size {
    return Ok(Array::makei(output_size, i => (packet[4 + i].to_int() - 128) << 8))
  }
  let output : Array[Int32] = []
  let mut sample = 128
  let mut pos = 4
  while output.length() < output_size {
    if pos == packet.length() {
      return Err("ws_snd1: truncated command")
    }
    let control = packet[pos].to_int()
    pos += 1
    let kind = control >> 6
    let count = (control & 63) + 1
    let large_delta = kind == 2 && (control & 32) != 0
    let (consumed, produced) = match kind {
      0 => (count, 4 * count)
      1 => (count, 2 * count)
      2 if large_delta => (0, 1)
      2 => (count, count)
      _ => (0, count)
    }
    if consumed > packet.length() - pos || produced > output_size - output.length() {
      return Err("ws_snd1: invalid command length")
    }
    match kind {
      0 | 1 => {
        let width = if kind == 0 { 2 } else { 4 }
        let mask = (1 << width) - 1
        for i in 0..<consumed {
          let packed = packet[pos + i].to_int()
          for j in 0..<(8 / width) {
            let code = (packed >> (j * width)) & mask
            let delta = if kind == 0 { code - 2 } else { ws_snd1_deltas[code] }
            sample = adpcm_clip(sample + delta, 0, 255)
            output.push((sample - 128) << 8)
          }
        }
      }
      2 if large_delta => {
        let delta = (control << 27) >> 27
        sample = adpcm_clip(sample + delta, 0, 255)
        output.push((sample - 128) << 8)
      }
      2 =>
        for i in 0..<count {
          sample = packet[pos + i].to_int()
          output.push((sample - 128) << 8)
        }
      _ =>
        for _ in 0..<count {
          output.push((sample - 128) << 8)
        }
    }
    pos += consumed
  }
  Ok(output)
}
