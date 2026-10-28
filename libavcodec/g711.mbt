///|
/// G.711 A-law / µ-law decoders, ported from the `alaw2linear` /
/// `ulaw2linear` helpers in FFmpeg's `libavcodec/pcm_tablegen.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Convert a byte of A-law to signed 16-bit PCM.
pub fn pcm_alaw_decode(data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  for byte in data {
    let a = byte.to_int() ^ 0x55
    let quant = a & 0x0F
    let seg = (a & 0x70) >> 4
    let t = if seg != 0 {
      (quant + quant + 1 + 32) << (seg + 2)
    } else {
      (quant + quant + 1) << 3
    }
    out.push(if (a & 0x80) != 0 { t } else { -t })
  }
  out
}

///|
/// Convert a byte of µ-law to signed 16-bit PCM.
pub fn pcm_mulaw_decode(data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  for byte in data {
    let u = (byte.to_int() ^ 0xFF) & 0xFF
    let mut t = ((u & 0x0F) << 3) + 0x84
    t = t << ((u & 0x70) >> 4)
    out.push(if (u & 0x80) != 0 { 0x84 - t } else { t - 0x84 })
  }
  out
}
