///|
/// HLS AES-128 segment decryption, following FFmpeg 9.0.2
/// `libavformat/hls.c` (`hls_encryption`/`do_encrypt`) and
/// `libavformat/hlsenc.c`'s key/IV handling.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The key is supplied by the caller (fetching `EXT-X-KEY:URI` is a platform
/// boundary). AES-128-CBC with a 16-byte IV is decrypted through the existing
/// `libavutil` AES implementation; PKCS#7 padding is removed when present.

///|
/// Build the implicit IV from `EXT-X-MEDIA-SEQUENCE` (big-endian 128-bit). */
pub fn hls_iv_from_sequence(sequence : Int64) -> Bytes {
  let iv : Array[Byte] = []
  for _ in 0..<8 {
    iv.push(b'\x00')
  }
  for i in 0..<8 {
    iv.push(((sequence >> (56 - 8 * i)) & 0xFFL).to_int().to_byte())
  }
  Bytes::from_array(iv[:])
}

///|
/// Parse an `IV=0x...` attribute value (16 bytes, hex). Returns None for a
/// malformed or missing value.
pub fn hls_parse_iv(text : String) -> Bytes? {
  let mut s = text.trim(chars=" \t\r\n")
  if s.has_prefix("0x") || s.has_prefix("0X") {
    s = s[2:]
  }
  if s.length() != 32 {
    return None
  }
  let out : Array[Byte] = []
  for i in 0..<16 {
    let hi = hls_hex_digit(s[i * 2])
    let lo = hls_hex_digit(s[i * 2 + 1])
    match (hi, lo) {
      (Some(h), Some(l)) => out.push(((h << 4) | l).to_byte())
      _ => return None
    }
  }
  Some(Bytes::from_array(out[:]))
}

///|
fn hls_hex_digit(c : UInt16) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// Decrypt one AES-128-CBC HLS segment. `key` must be 16 bytes, `iv` 16 bytes.
/// PKCS#7 padding is stripped only when the final block is consistently padded.
pub fn hls_decrypt_aes128(
  key : Bytes,
  iv : Bytes,
  data : Bytes,
) -> Result[Bytes, String] {
  if key.length() != 16 {
    return Err("hls: AES-128 key must be 16 bytes")
  }
  if iv.length() != 16 {
    return Err("hls: IV must be 16 bytes")
  }
  if data.length() % 16 != 0 {
    return Err("hls: encrypted segment is not block-aligned")
  }
  let aes = @libavutil.av_aes_alloc()
  match @libavutil.av_aes_init(aes, key, 128, true) {
    Ok(_) => ()
    Err(e) => return Err("hls: AES init failed: \{e}")
  }
  let chain : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    chain[i] = iv[i]
  }
  let plain = @libavutil.av_aes_crypt(
    aes,
    data,
    data.length() / 16,
    Some(chain),
  )
  // PKCS#7: 1..16 bytes each equal to the pad length.
  if plain.length() > 0 {
    let pad = plain[plain.length() - 1].to_int()
    if pad >= 1 && pad <= 16 && pad <= plain.length() {
      let mut valid = true
      for i in 0..<pad {
        if plain[plain.length() - 1 - i].to_int() != pad {
          valid = false
        }
      }
      if valid {
        let out : Array[Byte] = []
        for i in 0..<(plain.length() - pad) {
          out.push(plain[i])
        }
        return Ok(Bytes::from_array(out[:]))
      }
    }
  }
  Ok(plain)
}
