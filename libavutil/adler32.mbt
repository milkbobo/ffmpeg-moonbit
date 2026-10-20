///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/adler32.c`.
///
/// Original is a modified version of zlib's adler32.c by Mark Adler (zlib
/// licence) as shipped with FFmpeg; this port keeps the same terms.
///
/// The 64-bit interleaved fast path ("HAVE_FAST_64BIT ...") is a speed
/// optimisation; the portable `DO4` loop that FFmpeg uses otherwise produces
/// the same checksum and is what this port implements.

///|
/// Largest prime smaller than 65536, `BASE` in libavutil/adler32.c. */
let adler_base : UInt64 = 65521

///|
/// `DO1`: consume one byte, updating s1 and s2. */
fn adler_do1(s1 : UInt64, s2 : UInt64, b : Byte) -> (UInt64, UInt64) {
  let s1 = s1 + b.to_uint64()
  (s1, s2 + s1)
}

///|
/// `av_adler32_update`: Adler-32 checksum of `buf[0..len)`, continuing from
/// `adler`. Pass `1` as the initial value for a fresh checksum.
pub fn av_adler32_update(adler : UInt32, buf : Bytes, len : Int32) -> UInt32 {
  let mut s1 : UInt64 = (adler & 0xFFFF).to_uint64()
  let mut s2 : UInt64 = (adler >> 16).to_uint64()
  let mut remaining = len
  let mut p = 0
  while remaining > 0 {
    while remaining > 4 && s2 < 2147483648 {
      // DO4
      let (a1, b1) = adler_do1(s1, s2, buf[p])
      let (a2, b2) = adler_do1(a1, b1, buf[p + 1])
      let (a3, b3) = adler_do1(a2, b2, buf[p + 2])
      let (a4, b4) = adler_do1(a3, b3, buf[p + 3])
      s1 = a4
      s2 = b4
      p = p + 4
      remaining = remaining - 4
    }
    let (a, b) = adler_do1(s1, s2, buf[p])
    s1 = a
    s2 = b
    p = p + 1
    remaining = remaining - 1
    s1 = s1 % adler_base
    s2 = s2 % adler_base
  }
  ((s2 << 16) | s1).to_uint()
}
