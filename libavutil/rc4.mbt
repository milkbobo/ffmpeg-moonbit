///|
/// MoonBit port of FFmpeg 9.0.2 libavutil/rc4.c and rc4.h.
///
/// The original FFmpeg code is LGPL-2.1-or-later, copyright 2007
/// Reimar Doeffinger. This port keeps the same license.
///
/// The C iv and decrypt parameters of av_rc4_crypt are unused, because RC4 is a
/// symmetric stream cipher, so they are dropped here; likewise the unused
/// decrypt argument of av_rc4_init.

///| RC4 state, mirroring AVRC4 in libavutil/rc4.h. */
pub struct AVRC4 {
  state : FixedArray[Byte]
  mut x : UInt
  mut y : UInt
}

///| `av_rc4_alloc`: create a zeroed RC4 context. */
pub fn av_rc4_alloc() -> AVRC4 {
  { state: FixedArray::make(256, b'\x00'), x: 0, y: 0 }
}

///|
/// `av_rc4_init`: key-schedule `key` into the context.
/// Returns `Err` when `key_bits` is not a multiple of 8, mirroring
/// `AVERROR(EINVAL)`.
pub fn av_rc4_init(r : AVRC4, key : Bytes, key_bits : Int) -> Result[Unit, String] {
  if (key_bits & 7) != 0 {
    return Err("EINVAL")
  }
  let keylen = key_bits >> 3
  for i = 0; i < 256; i = i + 1 {
    r.state[i] = i.to_byte()
  }
  let mut y : Int = 0
  let mut j = 0
  for i = 0; i < 256; i = i + 1 {
    if j == keylen {
      j = 0
    }
    y = (y + r.state[i].to_int() + key[j].to_int()) & 0xFF
    let tmp = r.state[i]
    r.state[i] = r.state[y]
    r.state[y] = tmp
    j = j + 1
  }
  r.x = 1
  r.y = r.state[1].to_uint()
  Ok(())
}

///|
/// `av_rc4_crypt`: encrypt or decrypt `count` bytes.
/// Pass `None` as `src` to read the raw keystream, exactly like the C
/// `src == NULL` case.
pub fn av_rc4_crypt(r : AVRC4, src : Bytes?, count : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count, b'\x00')
  let mut x = r.x.reinterpret_as_int()
  let mut y = r.y.reinterpret_as_int()
  for i = 0; i < count; i = i + 1 {
    let sum = (r.state[x].to_int() + r.state[y].to_int()) & 0xFF
    let tmp = r.state[x]
    r.state[x] = r.state[y]
    r.state[y] = tmp
    let ks = r.state[sum].to_uint()
    out[i] = match src {
      None => ks.to_byte()
      Some(s) => (s[i].to_uint() ^ ks).to_byte()
    }
    x = (x + 1) & 0xFF
    y = (y + r.state[x].to_int()) & 0xFF
  }
  r.x = x.reinterpret_as_uint()
  r.y = y.reinterpret_as_uint()
  Bytes::from_array(out[:])
}
