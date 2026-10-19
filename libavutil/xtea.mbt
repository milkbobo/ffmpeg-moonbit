///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/xtea.c` / `xtea.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2012 Samuel
/// Pitoiset, loosely based on the implementation of David Wheeler and Roger
/// Needham. This port keeps the same license.
///
/// The C optimised build unrolls the 32 rounds into 32 `ESTEP`/`DSTEP` macro
/// invocations with constant-folded addends; this port uses the equivalent
/// `CONFIG_SMALL` loop, which is the canonical XTEA schedule. Both endian
/// flavours are provided: `av_xtea_crypt` (big endian) and `av_xtea_le_crypt`
/// (little endian).

///|
/// XTEA context, mirroring `AVXTEA` in libavutil/xtea.h.
/// The C header declares `uint32_t key[16]`, but the implementation only ever
/// uses the first four words, so only those are stored here.
pub struct AVXTEA {
  key : FixedArray[UInt]
}

///| `av_xtea_alloc`: create a zeroed XTEA context. */
pub fn av_xtea_alloc() -> AVXTEA {
  { key: FixedArray::make(4, 0) }
}

///| Big-endian 32-bit read (`AV_RB32`). */
fn xtea_rb32(b : Bytes, off : Int) -> UInt {
  (b[off].to_uint() << 24) |
  (b[off + 1].to_uint() << 16) |
  (b[off + 2].to_uint() << 8) |
  b[off + 3].to_uint()
}

///| Little-endian 32-bit read (`AV_RL32`). */
fn xtea_rl32(b : Bytes, off : Int) -> UInt {
  b[off].to_uint() |
  (b[off + 1].to_uint() << 8) |
  (b[off + 2].to_uint() << 16) |
  (b[off + 3].to_uint() << 24)
}

///| Big-endian 32-bit write (`AV_WB32`). */
fn xtea_wb32(dst : FixedArray[Byte], off : Int, v : UInt) -> Unit {
  dst[off] = ((v >> 24) & 0xFF).to_byte()
  dst[off + 1] = ((v >> 16) & 0xFF).to_byte()
  dst[off + 2] = ((v >> 8) & 0xFF).to_byte()
  dst[off + 3] = (v & 0xFF).to_byte()
}

///| Little-endian 32-bit write (`AV_WL32`). */
fn xtea_wl32(dst : FixedArray[Byte], off : Int, v : UInt) -> Unit {
  dst[off] = (v & 0xFF).to_byte()
  dst[off + 1] = ((v >> 8) & 0xFF).to_byte()
  dst[off + 2] = ((v >> 16) & 0xFF).to_byte()
  dst[off + 3] = ((v >> 24) & 0xFF).to_byte()
}

///| `av_xtea_init`: load the 16-byte key as big-endian 32-bit words. */
pub fn av_xtea_init(ctx : AVXTEA, key : Bytes) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    ctx.key[i] = xtea_rb32(key, i << 2)
  }
}

///| `av_xtea_le_init`: load the 16-byte key as little-endian 32-bit words. */
pub fn av_xtea_le_init(ctx : AVXTEA, key : Bytes) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    ctx.key[i] = xtea_rl32(key, i << 2)
  }
}

///|
/// `xtea_crypt_ecb` / `xtea_le_crypt_ecb`: transform one 8-byte block with the
/// canonical 32-round XTEA schedule (`CONFIG_SMALL` form). `little` selects the
/// endian flavour used to load/store the two words.
fn xtea_ecb_block(
  ctx : AVXTEA,
  src : Bytes,
  off : Int,
  decrypt : Bool,
  little : Bool
) -> Bytes {
  let mut v0 = if little {
    xtea_rl32(src, off)
  } else {
    xtea_rb32(src, off)
  }
  let mut v1 = if little {
    xtea_rl32(src, off + 4)
  } else {
    xtea_rb32(src, off + 4)
  }
  let delta : UInt = 0x9E3779B9
  if decrypt {
    let mut sum : UInt = delta * 32
    for i = 0; i < 32; i = i + 1 {
      v1 = v1 -
        ((((v0 << 4) ^ (v0 >> 5)) + v0) ^
          (sum + ctx.key[((sum >> 11) & 3).reinterpret_as_int()]))
      sum = sum - delta
      v0 = v0 -
        ((((v1 << 4) ^ (v1 >> 5)) + v1) ^
          (sum + ctx.key[(sum & 3).reinterpret_as_int()]))
    }
  } else {
    let mut sum : UInt = 0
    for i = 0; i < 32; i = i + 1 {
      v0 = v0 +
        ((((v1 << 4) ^ (v1 >> 5)) + v1) ^
          (sum + ctx.key[(sum & 3).reinterpret_as_int()]))
      sum = sum + delta
      v1 = v1 +
        ((((v0 << 4) ^ (v0 >> 5)) + v0) ^
          (sum + ctx.key[((sum >> 11) & 3).reinterpret_as_int()]))
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  if little {
    xtea_wl32(out, 0, v0)
    xtea_wl32(out, 4, v1)
  } else {
    xtea_wb32(out, 0, v0)
    xtea_wb32(out, 4, v1)
  }
  Bytes::from_array(out[:])
}

///|
/// `xtea_crypt`: shared driver over `count` 8-byte blocks.
/// `iv == None` selects ECB; a non-`None` 8-byte buffer selects CBC and is
/// updated in place with the final chaining value, exactly like the C `iv`.
fn xtea_crypt(
  ctx : AVXTEA,
  src : Bytes,
  count : Int,
  iv : FixedArray[Byte]?,
  decrypt : Bool,
  little : Bool
) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count * 8, b'\x00')
  let mut chain : Bytes? = match iv {
    None => None
    Some(v) => Some(Bytes::from_array(v[:]))
  }
  for b = 0; b < count; b = b + 1 {
    let off = b * 8
    if decrypt {
      let blk = xtea_ecb_block(ctx, src, off, true, little)
      match chain {
        None =>
          for i = 0; i < 8; i = i + 1 {
            out[off + i] = blk[i]
          }
        Some(c) => {
          // XOR the decrypted block with the chaining value, then the chaining
          // value becomes the ciphertext block just consumed (memcpy(iv, src)).
          for i = 0; i < 8; i = i + 1 {
            out[off + i] = (blk[i].to_uint() ^ c[i].to_uint()).to_byte()
          }
          let nb : FixedArray[Byte] = FixedArray::make(8, b'\x00')
          for i = 0; i < 8; i = i + 1 {
            nb[i] = src[off + i]
          }
          chain = Some(Bytes::from_array(nb[:]))
        }
      }
    } else {
      match chain {
        None => {
          let blk = xtea_ecb_block(ctx, src, off, false, little)
          for i = 0; i < 8; i = i + 1 {
            out[off + i] = blk[i]
          }
        }
        Some(c) => {
          // dst = src ^ iv, encrypt in place, then iv <- dst.
          let tmp : FixedArray[Byte] = FixedArray::make(8, b'\x00')
          for i = 0; i < 8; i = i + 1 {
            tmp[i] = (src[off + i].to_uint() ^ c[i].to_uint()).to_byte()
          }
          let enc = xtea_ecb_block(ctx, Bytes::from_array(tmp[:]), 0, false, little)
          for i = 0; i < 8; i = i + 1 {
            out[off + i] = enc[i]
          }
          chain = Some(enc)
        }
      }
    }
  }
  match (iv, chain) {
    (Some(v), Some(c)) =>
      for i = 0; i < 8; i = i + 1 {
        v[i] = c[i]
      }
    _ => ()
  }
  Bytes::from_array(out[:])
}

///|
/// `av_xtea_crypt`: big-endian ECB (pass `None` as `iv`) or CBC (pass the
/// caller's 8-byte `iv` buffer).
pub fn av_xtea_crypt(
  ctx : AVXTEA,
  src : Bytes,
  count : Int,
  iv : FixedArray[Byte]?,
  decrypt : Bool
) -> Bytes {
  xtea_crypt(ctx, src, count, iv, decrypt, false)
}

///|
/// `av_xtea_le_crypt`: little-endian ECB (pass `None` as `iv`) or CBC (pass the
/// caller's 8-byte `iv` buffer).
pub fn av_xtea_le_crypt(
  ctx : AVXTEA,
  src : Bytes,
  count : Int,
  iv : FixedArray[Byte]?,
  decrypt : Bool
) -> Bytes {
  xtea_crypt(ctx, src, count, iv, decrypt, true)
}
