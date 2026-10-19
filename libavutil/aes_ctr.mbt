///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/aes_ctr.c` / `aes_ctr.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2015 Eran Kornblau.
/// This port keeps the same license.
///
/// The C `av_aes_crypt` writes into a caller buffer; here the ported
/// `av_aes_crypt` returns the block, so the keystream block is refreshed by
/// reassigning `encrypted_counter`. The C `dst`/`src` pointers become an output
/// buffer plus an in-offset, and `av_aes_ctr_free` is dropped because MoonBit
/// memory is managed by the GC.
///
/// `av_aes_ctr_set_random_iv` is not ported: it depends on
/// `av_get_random_seed`, a platform facility slated for FFI (see README §1).

///|
/// AES-CTR context, mirroring `AVAESCTR` in libavutil/aes_ctr.c.
/// `counter` is the 16-byte big-endian block; `encrypted_counter` caches the
/// current keystream block; `block_offset` is how far into it we have consumed.
pub struct AVAESCTR {
  counter : FixedArray[Byte]
  mut encrypted_counter : FixedArray[Byte]
  mut block_offset : Int
  aes : AVAES
}

///| `av_aes_ctr_alloc`: create a zeroed AES-CTR context. */
pub fn av_aes_ctr_alloc() -> AVAESCTR {
  {
    counter: FixedArray::make(16, b'\x00'),
    encrypted_counter: FixedArray::make(16, b'\x00'),
    block_offset: 0,
    aes: av_aes_alloc(),
  }
}

///| `av_aes_ctr_init`: set up the AES-128 encryption context and clear the counter. */
pub fn av_aes_ctr_init(a : AVAESCTR, key : Bytes) -> Result[Unit, String] {
  match av_aes_init(a.aes, key, 128, false) {
    Err(e) => Err(e)
    Ok(_) => {
      for i = 0; i < 16; i = i + 1 {
        a.counter[i] = b'\x00'
      }
      a.block_offset = 0
      Ok(())
    }
  }
}

///|
/// `av_aes_ctr_set_iv`: set the 8-byte IV and zero the 64-bit block counter.
pub fn av_aes_ctr_set_iv(a : AVAESCTR, iv : Bytes) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    a.counter[i] = iv[i]
  }
  for i = 8; i < 16; i = i + 1 {
    a.counter[i] = b'\x00'
  }
  a.block_offset = 0
}

///| `av_aes_ctr_set_full_iv`: set the full 16-byte counter, including the counter half. */
pub fn av_aes_ctr_set_full_iv(a : AVAESCTR, iv : Bytes) -> Unit {
  for i = 0; i < 16; i = i + 1 {
    a.counter[i] = iv[i]
  }
  a.block_offset = 0
}

///| `av_aes_ctr_get_iv`: return the current 16-byte counter. */
pub fn av_aes_ctr_get_iv(a : AVAESCTR) -> Bytes {
  Bytes::from_array(a.counter[:])
}

///| `av_aes_ctr_increment_be64`: add one to the big-endian 64-bit word at `off`. */
fn aes_ctr_incr_be64(counter : FixedArray[Byte], off : Int) -> Unit {
  let mut c : UInt64 = 0
  for i = 0; i < 8; i = i + 1 {
    c = (c << 8) | counter[off + i].to_uint().to_uint64()
  }
  c = c + 1
  for i = 0; i < 8; i = i + 1 {
    counter[off + 7 - i] = (c & 0xFF).to_uint().to_byte()
    c = c >> 8
  }
}

///| `av_aes_ctr_increment_iv`: bump the top 64 bits and zero the counter half. */
pub fn av_aes_ctr_increment_iv(a : AVAESCTR) -> Unit {
  aes_ctr_incr_be64(a.counter, 0)
  for i = 8; i < 16; i = i + 1 {
    a.counter[i] = b'\x00'
  }
  a.block_offset = 0
}

///|
/// Refresh `encrypted_counter` with `AES_encrypt(counter)`, mirroring the C
/// `av_aes_crypt(&a->aes, a->encrypted_counter, a->counter, 1, NULL, 0)`.
fn aes_ctr_encrypt_counter(a : AVAESCTR) -> Unit {
  a.encrypted_counter = av_aes_crypt(
    a.aes,
    Bytes::from_array(a.counter[:]),
    1,
    None,
  ).to_fixedarray()
}

///|
/// `av_aes_ctr_crypt`: XOR `count` bytes of `src` with the AES-CTR keystream.
/// State (`counter`, `encrypted_counter`, `block_offset`) carries across calls,
/// so the same keystream is produced whether the stream is consumed in one go
/// or split into arbitrary chunks.
pub fn av_aes_ctr_crypt(a : AVAESCTR, src : Bytes, count : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count, b'\x00')
  let mut in_off = 0
  let mut remaining = count
  let mut bo = a.block_offset
  // Finish the partially consumed keystream block, if any.
  if bo != 0 && remaining > 0 {
    let left = if remaining < 16 - bo { remaining } else { 16 - bo }
    for len = 0; len < left; len = len + 1 {
      out[in_off + len] = (src[in_off + len].to_uint() ^
        a.encrypted_counter[bo].to_uint()).to_byte()
      bo = bo + 1
    }
    bo = bo & 15
    in_off = in_off + left
    remaining = remaining - left
  }
  // Full blocks.
  while remaining >= 16 {
    aes_ctr_encrypt_counter(a)
    aes_ctr_incr_be64(a.counter, 8)
    for len = 0; len < 16; len = len + 1 {
      out[in_off + len] = (src[in_off + len].to_uint() ^
        a.encrypted_counter[len].to_uint()).to_byte()
    }
    in_off = in_off + 16
    remaining = remaining - 16
  }
  // Trailing partial block.
  if remaining > 0 {
    aes_ctr_encrypt_counter(a)
    aes_ctr_incr_be64(a.counter, 8)
    for len = 0; len < remaining; len = len + 1 {
      out[in_off + len] = (src[in_off + len].to_uint() ^
        a.encrypted_counter[bo].to_uint()).to_byte()
      bo = bo + 1
    }
  }
  a.block_offset = bo
  Bytes::from_array(out[:])
}
