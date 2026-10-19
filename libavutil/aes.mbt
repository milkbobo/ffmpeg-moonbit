///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/aes.c` / `aes.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, based on the reference AES code
/// by Paulo Barreto and Vincent Rijmen. This port keeps the same license.
///
/// DELIBERATE DEVIATION (documented, and the only such place in this project):
/// the S-box / inverse S-box generation and the `rcon` table are ported
/// line-by-line from `aes_init_static` / `aes.c`, and the key schedule follows
/// the same Rcon/SubWord structure; but the block round function is implemented
/// from the **FIPS-197 specification** (SubBytes / ShiftRows / MixColumns /
/// AddRoundKey and their inverses) rather than by reproducing FFmpeg's
/// `subshift` / `mix` / `multbl` table-driven kernel.
///
/// Rationale: that kernel is an equivalent optimisation of the same cipher whose
/// byte layout depends on little-endian `u32`/`u64` type punning and pointer
/// arithmetic (`subshift` shuffles bytes relative to `sizeof(av_aes_block)`).
/// Reproducing it is high-risk and buys no behavioural difference, whereas the
/// FIPS-197 form is verifiable against the published standard's test vectors.
///
/// Consequently the round keys are stored in FIPS-197 order rather than in the
/// decrypt pre-transformed form FFmpeg keeps internally. `av_aes_init` /
/// `av_aes_crypt` keep FFmpeg's signatures and ECB/CBC behaviour.

///| `rcon` from libavutil/aes.c. */
let aes_rcon : FixedArray[Byte] = [
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
]

///|
/// AES context, mirroring `AVAES` in libavutil/aes.h.
/// The S-boxes are held per context here; FFmpeg keeps them in file-scope
/// statics initialised once through `AVOnce`.
pub struct AVAES {
  round_keys : FixedArray[Byte]
  mut sbox : FixedArray[Byte]
  mut inv_sbox : FixedArray[Byte]
  mut rounds : Int
  mut decrypt : Bool
}

///| `av_aes_alloc`: create a context with room for the largest key schedule (AES-256). */
pub fn av_aes_alloc() -> AVAES {
  {
    round_keys: FixedArray::make(16 * 15, b'\x00'),
    sbox: FixedArray::make(256, b'\x00'),
    inv_sbox: FixedArray::make(256, b'\x00'),
    rounds: 0,
    decrypt: false,
  }
}

///|
/// Build the AES S-box and its inverse with the construction from
/// `aes_init_static` (log/antilog tables over GF(2^8), then the affine
/// transform `j ^ (j<<1) ^ (j<<2) ^ (j<<3) ^ (j<<4) ^ 0x63`).
fn aes_sbox_pair() -> (FixedArray[Byte], FixedArray[Byte]) {
  let log8 : FixedArray[Byte] = FixedArray::make(256, b'\x00')
  let alog8 : FixedArray[Byte] = FixedArray::make(512, b'\x00')
  let sbox : FixedArray[Byte] = FixedArray::make(256, b'\x00')
  let inv_sbox : FixedArray[Byte] = FixedArray::make(256, b'\x00')
  let mut j = 1
  for i = 0; i < 255; i = i + 1 {
    alog8[i] = j.to_byte()
    alog8[i + 255] = j.to_byte()
    log8[j] = i.to_byte()
    j = j ^ (j + j)
    if j > 255 {
      j = j ^ 0x11B
    }
  }
  for i = 0; i < 256; i = i + 1 {
    let mut x = if i != 0 { alog8[255 - log8[i].to_int()].to_int() } else { 0 }
    x = x ^ (x << 1) ^ (x << 2) ^ (x << 3) ^ (x << 4)
    x = (x ^ (x >> 8) ^ 99) & 255
    inv_sbox[x] = i.to_byte()
    sbox[i] = x.to_byte()
  }
  (sbox, inv_sbox)
}

///| `rot_word`: rotate a key-schedule word left by one byte. */
fn aes_rot_word(w : UInt) -> UInt {
  (w << 8) | (w >> 24)
}

///| `sub_word`: apply the S-box to each byte of a key-schedule word. */
fn aes_sub_word(w : UInt, sbox : FixedArray[Byte]) -> UInt {
  (sbox[((w >> 24) & 0xFF).reinterpret_as_int()].to_uint() << 24) |
  (sbox[((w >> 16) & 0xFF).reinterpret_as_int()].to_uint() << 16) |
  (sbox[((w >> 8) & 0xFF).reinterpret_as_int()].to_uint() << 8) |
  sbox[(w & 0xFF).reinterpret_as_int()].to_uint()
}

///| Multiplication in GF(2^8) modulo the AES polynomial x^8+x^4+x^3+x+1. */
fn gf_mul(a : UInt, b : UInt) -> UInt {
  let mut x = a
  let mut y = b
  let mut r : UInt = 0
  while y != 0 {
    if (y & 1) != 0 {
      r = r ^ x
    }
    x = x << 1
    if (x & 0x100) != 0 {
      x = x ^ 0x11B
    }
    y = y >> 1
  }
  r & 0xFF
}

///|
/// FIPS-197 key expansion: derive `rounds + 1` 16-byte round keys from a
/// `nk`-word key. The Rcon/SubWord structure matches FFmpeg's `av_aes_init`
/// loop (including the `KC == 8 && j == KC >> 1` SubWord-only case for AES-256).
fn aes_expand_key(
  round_keys : FixedArray[Byte],
  key : Bytes,
  nk : Int,
  rounds : Int,
  sbox : FixedArray[Byte]
) -> Unit {
  let words = 4 * (rounds + 1)
  let w : FixedArray[UInt] = FixedArray::make(words, 0)
  for i = 0; i < nk; i = i + 1 {
    w[i] = (key[4 * i].to_uint() << 24) |
      (key[4 * i + 1].to_uint() << 16) |
      (key[4 * i + 2].to_uint() << 8) |
      key[4 * i + 3].to_uint()
  }
  for i = nk; i < words; i = i + 1 {
    let mut temp = w[i - 1]
    if i % nk == 0 {
      temp = aes_sub_word(aes_rot_word(temp), sbox) ^
        (aes_rcon[i / nk - 1].to_uint() << 24)
    } else if nk > 6 && i % nk == 4 {
      temp = aes_sub_word(temp, sbox)
    }
    w[i] = w[i - nk] ^ temp
  }
  for r = 0; r <= rounds; r = r + 1 {
    for j = 0; j < 4; j = j + 1 {
      round_keys[16 * r + 4 * j] = ((w[4 * r + j] >> 24) & 0xFF).to_byte()
      round_keys[16 * r + 4 * j + 1] = ((w[4 * r + j] >> 16) & 0xFF).to_byte()
      round_keys[16 * r + 4 * j + 2] = ((w[4 * r + j] >> 8) & 0xFF).to_byte()
      round_keys[16 * r + 4 * j + 3] = (w[4 * r + j] & 0xFF).to_byte()
    }
  }
}

///|
/// `av_aes_init`: expand `key` into the context.
/// `decrypt` selects the direction used by `av_aes_crypt`.
/// Returns `Err` for key sizes other than 128/192/256, mirroring
/// `AVERROR(EINVAL)`.
pub fn av_aes_init(
  a : AVAES,
  key : Bytes,
  key_bits : Int,
  decrypt : Bool
) -> Result[Unit, String] {
  if key_bits != 128 && key_bits != 192 && key_bits != 256 {
    return Err("EINVAL")
  }
  let (sbox, inv_sbox) = aes_sbox_pair()
  a.sbox = sbox
  a.inv_sbox = inv_sbox
  let nk = key_bits >> 5
  let rounds = nk + 6
  a.rounds = rounds
  a.decrypt = decrypt
  aes_expand_key(a.round_keys, key, nk, rounds, a.sbox)
  Ok(())
}

///| One FIPS-197 encryption of a 16-byte block held in `st` (index `4*column + row`). */
fn aes_state_add_round_key(st : FixedArray[UInt], rk : FixedArray[Byte], round : Int) -> Unit {
  for i = 0; i < 16; i = i + 1 {
    st[i] = st[i] ^ rk[16 * round + i].to_uint()
  }
}

///| SubBytes over the whole state. */
fn aes_state_sub_bytes(st : FixedArray[UInt], sbox : FixedArray[Byte]) -> Unit {
  for i = 0; i < 16; i = i + 1 {
    st[i] = sbox[st[i].reinterpret_as_int()].to_uint()
  }
}

///| ShiftRows (or its inverse), operating on `st` in place. */
fn aes_state_shift_rows(st : FixedArray[UInt], inverse : Bool) -> Unit {
  let tmp = st.copy()
  for r = 0; r < 4; r = r + 1 {
    for c = 0; c < 4; c = c + 1 {
      let src_c = if inverse {
        (c - r + 4) % 4
      } else {
        (c + r) % 4
      }
      st[4 * c + r] = tmp[4 * src_c + r]
    }
  }
}

///| MixColumns (or its inverse), operating on `st` in place. */
fn aes_state_mix_columns(st : FixedArray[UInt], inverse : Bool) -> Unit {
  for c = 0; c < 4; c = c + 1 {
    let a0 = st[4 * c]
    let a1 = st[4 * c + 1]
    let a2 = st[4 * c + 2]
    let a3 = st[4 * c + 3]
    if inverse {
      st[4 * c] = gf_mul(a0, 14) ^ gf_mul(a1, 11) ^ gf_mul(a2, 13) ^ gf_mul(a3, 9)
      st[4 * c + 1] = gf_mul(a0, 9) ^ gf_mul(a1, 14) ^ gf_mul(a2, 11) ^ gf_mul(a3, 13)
      st[4 * c + 2] = gf_mul(a0, 13) ^ gf_mul(a1, 9) ^ gf_mul(a2, 14) ^ gf_mul(a3, 11)
      st[4 * c + 3] = gf_mul(a0, 11) ^ gf_mul(a1, 13) ^ gf_mul(a2, 9) ^ gf_mul(a3, 14)
    } else {
      st[4 * c] = gf_mul(a0, 2) ^ gf_mul(a1, 3) ^ a2 ^ a3
      st[4 * c + 1] = a0 ^ gf_mul(a1, 2) ^ gf_mul(a2, 3) ^ a3
      st[4 * c + 2] = a0 ^ a1 ^ gf_mul(a2, 2) ^ gf_mul(a3, 3)
      st[4 * c + 3] = gf_mul(a0, 3) ^ a1 ^ a2 ^ gf_mul(a3, 2)
    }
  }
}

///| Encrypt one 16-byte block into `out` at `out_off`. */
fn aes_encrypt_block(a : AVAES, input : Bytes, in_off : Int, out : FixedArray[Byte], out_off : Int) -> Unit {
  let st : FixedArray[UInt] = FixedArray::make(16, 0)
  for i = 0; i < 16; i = i + 1 {
    st[i] = input[in_off + i].to_uint()
  }
  aes_state_add_round_key(st, a.round_keys, 0)
  for r = 1; r < a.rounds; r = r + 1 {
    aes_state_sub_bytes(st, a.sbox)
    aes_state_shift_rows(st, false)
    aes_state_mix_columns(st, false)
    aes_state_add_round_key(st, a.round_keys, r)
  }
  aes_state_sub_bytes(st, a.sbox)
  aes_state_shift_rows(st, false)
  aes_state_add_round_key(st, a.round_keys, a.rounds)
  for i = 0; i < 16; i = i + 1 {
    out[out_off + i] = (st[i] & 0xFF).to_byte()
  }
}

///| Decrypt one 16-byte block into `out` at `out_off`. */
fn aes_decrypt_block(a : AVAES, input : Bytes, in_off : Int, out : FixedArray[Byte], out_off : Int) -> Unit {
  let st : FixedArray[UInt] = FixedArray::make(16, 0)
  for i = 0; i < 16; i = i + 1 {
    st[i] = input[in_off + i].to_uint()
  }
  aes_state_add_round_key(st, a.round_keys, a.rounds)
  let mut r = a.rounds - 1
  while r >= 1 {
    aes_state_shift_rows(st, true)
    aes_state_sub_bytes(st, a.inv_sbox)
    aes_state_add_round_key(st, a.round_keys, r)
    aes_state_mix_columns(st, true)
    r = r - 1
  }
  aes_state_shift_rows(st, true)
  aes_state_sub_bytes(st, a.inv_sbox)
  aes_state_add_round_key(st, a.round_keys, 0)
  for i = 0; i < 16; i = i + 1 {
    out[out_off + i] = (st[i] & 0xFF).to_byte()
  }
}

///|
/// `av_aes_crypt`: process `count` 16-byte blocks from `src`.
/// A non-`None` `iv` selects CBC mode and is updated in place with the final
/// chaining value, exactly like the C 16-byte `iv` buffer; `None` selects ECB.
/// The C `decrypt` parameter is unused: the context's direction decides.
pub fn av_aes_crypt(a : AVAES, src : Bytes, count : Int, iv : FixedArray[Byte]?) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count * 16, b'\x00')
  let chain = match iv {
    None => None
    Some(v) => Some(v.copy())
  }
  for b = 0; b < count; b = b + 1 {
    let in_off = b * 16
    match chain {
      None => {
        if a.decrypt {
          aes_decrypt_block(a, src, in_off, out, in_off)
        } else {
          aes_encrypt_block(a, src, in_off, out, in_off)
        }
      }
      Some(c) => {
        if a.decrypt {
          // Decrypt, then XOR with the previous ciphertext block.
          let tmp : FixedArray[Byte] = FixedArray::make(16, b'\x00')
          aes_decrypt_block(a, src, in_off, tmp, 0)
          for i = 0; i < 16; i = i + 1 {
            out[in_off + i] = (tmp[i].to_uint() ^ c[i].to_uint()).to_byte()
            // The chaining value becomes the ciphertext block just consumed.
            c[i] = src[in_off + i]
          }
        } else {
          // XOR the plaintext block with the chaining value, then encrypt.
          let tmp : FixedArray[Byte] = FixedArray::make(16, b'\x00')
          for i = 0; i < 16; i = i + 1 {
            tmp[i] = (src[in_off + i].to_uint() ^ c[i].to_uint()).to_byte()
          }
          aes_encrypt_block(a, Bytes::from_array(tmp[:]), 0, out, in_off)
          for i = 0; i < 16; i = i + 1 {
            c[i] = out[in_off + i]
          }
        }
      }
    }
  }
  match (iv, chain) {
    (Some(v), Some(c)) => {
      for i = 0; i < 16; i = i + 1 {
        v[i] = c[i]
      }
    }
    _ => ()
  }
  Bytes::from_array(out[:])
}
