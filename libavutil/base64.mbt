///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/base64.c` / `base64.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2006
/// Ryan Martell. This port keeps the same license.
///
/// API note: the C functions take raw `char *` buffers and report failure with
/// `NULL` / a negative return code. Here encoding returns a `String` and
/// decoding returns `Result[Bytes, String]`, reporting invalid input as `Err`.

///|
/// Base64 alphabet, the `b64` table in libavutil/base64.c. */
let b64_alphabet : Bytes = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Decode table equivalent to `map2` in libavutil/base64.c: `0..63` for
/// alphabet characters, `0xFE` for `'='`, `0xFF` for everything else.
fn b64_map() -> FixedArray[Int32] {
  let map : FixedArray[Int32] = FixedArray::make(256, 0xFF)
  for k = 0; k < 64; k = k + 1 {
    map[b64_alphabet[k].to_uint().reinterpret_as_int()] = k
  }
  map[b'='.to_uint().reinterpret_as_int()] = 0xFE
  map
}

///|
/// Encoded size for `n` input bytes (the `AV_BASE64_SIZE` macro). */
pub fn av_base64_size(n : Int32) -> Int32 {
  (n + 2) / 3 * 4
}

///|
/// Build a `String` from an ASCII byte buffer.
/// MoonBit strings are UTF-16, so the bytes are mapped one code point at a
/// time; `Bytes::to_string()` cannot be used because it renders the `b"..."`
/// literal form rather than decoding the bytes.
fn ascii_to_string(buf : FixedArray[Byte], len : Int32) -> String {
  let chars : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    chars.push(buf[i].to_char())
  }
  String::from_array(chars[:])
}

///|
/// `av_base64_encode`: encode binary data as a base64 string. */
pub fn av_base64_encode(input : Bytes) -> String {
  let n = input.length()
  let out : FixedArray[Byte] = FixedArray::make(av_base64_size(n), b'=')
  let mut i = 0
  let mut o = 0
  while i + 3 <= n {
    let bits = (input[i].to_uint() << 16) |
      (input[i + 1].to_uint() << 8) |
      input[i + 2].to_uint()
    out[o] = b64_alphabet[((bits >> 18) & 0x3F).reinterpret_as_int()]
    out[o + 1] = b64_alphabet[((bits >> 12) & 0x3F).reinterpret_as_int()]
    out[o + 2] = b64_alphabet[((bits >> 6) & 0x3F).reinterpret_as_int()]
    out[o + 3] = b64_alphabet[(bits & 0x3F).reinterpret_as_int()]
    i = i + 3
    o = o + 4
  }
  let rem = n - i
  if rem == 1 {
    let bits = input[i].to_uint() << 16
    out[o] = b64_alphabet[((bits >> 18) & 0x3F).reinterpret_as_int()]
    out[o + 1] = b64_alphabet[((bits >> 12) & 0x3F).reinterpret_as_int()]
  } else if rem == 2 {
    let bits = (input[i].to_uint() << 16) | (input[i + 1].to_uint() << 8)
    out[o] = b64_alphabet[((bits >> 18) & 0x3F).reinterpret_as_int()]
    out[o + 1] = b64_alphabet[((bits >> 12) & 0x3F).reinterpret_as_int()]
    out[o + 2] = b64_alphabet[((bits >> 6) & 0x3F).reinterpret_as_int()]
  }
  ascii_to_string(out, out.length())
}

///|
/// `av_base64_decode`: decode a base64 string into at most `out_size` bytes,
/// mirroring the C `out_size` truncation. Invalid input yields `Err`.
pub fn av_base64_decode(
  in_str : Bytes,
  out_size : Int32,
) -> Result[Bytes, String] {
  let map = b64_map()
  let n = in_str.length()
  let decoded : Array[Byte] = []
  let mut i = 0
  let mut done = false
  while i + 4 <= n && !done {
    let c0 = map[in_str[i].to_uint().reinterpret_as_int()]
    let c1 = map[in_str[i + 1].to_uint().reinterpret_as_int()]
    let c2 = map[in_str[i + 2].to_uint().reinterpret_as_int()]
    let c3 = map[in_str[i + 3].to_uint().reinterpret_as_int()]
    if (c0 & 0x80) != 0 || (c1 & 0x80) != 0 {
      return Err("invalid base64")
    }
    if (c2 & 0x80) != 0 {
      // Two data characters followed by "=="; must terminate the input.
      if c2 != 0xFE || c3 != 0xFE || i + 4 != n {
        return Err("invalid base64")
      }
      let bits = (c0 << 18) | (c1 << 12)
      decoded.push((bits >> 16).to_byte())
      done = true
    } else if (c3 & 0x80) != 0 {
      // Three data characters followed by a single "="; must terminate.
      if c3 != 0xFE || i + 4 != n {
        return Err("invalid base64")
      }
      let bits = (c0 << 18) | (c1 << 12) | (c2 << 6)
      decoded.push((bits >> 16).to_byte())
      decoded.push(((bits >> 8) & 0xFF).to_byte())
      done = true
    } else {
      let bits = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3
      decoded.push((bits >> 16).to_byte())
      decoded.push(((bits >> 8) & 0xFF).to_byte())
      decoded.push((bits & 0xFF).to_byte())
    }
    i = i + 4
  }
  if !done && i != n {
    return Err("invalid base64")
  }
  let total = decoded.length()
  let keep = if out_size < 0 {
    0
  } else if out_size < total {
    out_size
  } else {
    total
  }
  let out : FixedArray[Byte] = FixedArray::make(keep, b'\x00')
  for k = 0; k < keep; k = k + 1 {
    out[k] = decoded[k]
  }
  Ok(Bytes::from_array(out[:]))
}

///|
/// Validity check for a base64 string, corresponding to decoding to `NULL`. */
pub fn av_base64_decode_syntax(in_str : Bytes) -> Bool {
  match av_base64_decode(in_str, 0) {
    Ok(_) => true
    Err(_) => false
  }
}
