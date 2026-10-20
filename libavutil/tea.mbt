///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/tea.c` / `tea.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2015 Vesselin
/// Bontchev. This port keeps the same license.
///
/// Like the XTEA port, `av_tea_crypt` builds an 8-byte block per call; CBC
/// chaining state (`iv`) lives in the caller's 8-byte buffer. The C
/// `av_tea_size` constant and `av_tea_alloc`'s raw allocation are not needed
/// under MoonBit's GC.

///|
/// TEA context, mirroring `AVTEA` in libavutil/tea.c.
/// The C struct declares `uint32_t key[16]` but only the first four words are
/// used; `rounds` is the round count (64 for standard TEA).
pub struct AVTEA {
  key : FixedArray[UInt32]
  mut rounds : Int32
}

///|
/// `av_tea_alloc`: create a zeroed TEA context. */
pub fn av_tea_alloc() -> AVTEA {
  { key: FixedArray::make(4, 0), rounds: 0, }
}

///|
/// Big-endian 32-bit read (`AV_RB32`). */
fn tea_rb32(b : Bytes, off : Int32) -> UInt32 {
  (b[off].to_uint() << 24) |
  (b[off + 1].to_uint() << 16) |
  (b[off + 2].to_uint() << 8) |
  b[off + 3].to_uint()
}

///|
/// Big-endian 32-bit write (`AV_WB32`). */
fn tea_wb32(dst : FixedArray[Byte], off : Int32, v : UInt32) -> Unit {
  dst[off] = ((v >> 24) & 0xFF).to_byte()
  dst[off + 1] = ((v >> 16) & 0xFF).to_byte()
  dst[off + 2] = ((v >> 8) & 0xFF).to_byte()
  dst[off + 3] = (v & 0xFF).to_byte()
}

///|
/// `av_tea_init`: load the 16-byte key as big-endian 32-bit words and set `rounds`. */
pub fn av_tea_init(ctx : AVTEA, key : Bytes, rounds : Int32) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    ctx.key[i] = tea_rb32(key, i << 2)
  }
  ctx.rounds = rounds
}

///|
/// `tea_crypt_ecb`: transform one 8-byte block using the TEA Feistel network
/// (`rounds / 2` double-rounds, standard delta 0x9E3779B9).
fn tea_ecb_block(
  ctx : AVTEA,
  src : Bytes,
  off : Int32,
  decrypt : Bool,
) -> Bytes {
  let mut v0 = tea_rb32(src, off)
  let mut v1 = tea_rb32(src, off + 4)
  let k0 = ctx.key[0]
  let k1 = ctx.key[1]
  let k2 = ctx.key[2]
  let k3 = ctx.key[3]
  let delta : UInt32 = 0x9E3779B9
  let n = ctx.rounds / 2
  if decrypt {
    let mut sum : UInt32 = delta * n.reinterpret_as_uint()
    for i = 0; i < n; i = i + 1 {
      v1 = v1 - (((v0 << 4) + k2) ^ (v0 + sum) ^ ((v0 >> 5) + k3))
      v0 = v0 - (((v1 << 4) + k0) ^ (v1 + sum) ^ ((v1 >> 5) + k1))
      sum = sum - delta
    }
  } else {
    let mut sum : UInt32 = 0
    for i = 0; i < n; i = i + 1 {
      sum = sum + delta
      v0 = v0 + (((v1 << 4) + k0) ^ (v1 + sum) ^ ((v1 >> 5) + k1))
      v1 = v1 + (((v0 << 4) + k2) ^ (v0 + sum) ^ ((v0 >> 5) + k3))
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  tea_wb32(out, 0, v0)
  tea_wb32(out, 4, v1)
  Bytes::from_array(out[:])
}

///|
/// `av_tea_crypt`: process `count` 8-byte blocks.
/// `iv == None` selects ECB; a non-`None` 8-byte buffer selects CBC and is
/// updated in place with the final chaining value, exactly like the C `iv`.
pub fn av_tea_crypt(
  ctx : AVTEA,
  src : Bytes,
  count : Int32,
  iv : FixedArray[Byte]?,
  decrypt : Bool,
) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count * 8, b'\x00')
  let mut chain : Bytes? = match iv {
    None => None
    Some(v) => Some(Bytes::from_array(v[:]))
  }
  for b = 0; b < count; b = b + 1 {
    let off = b * 8
    if decrypt {
      let blk = tea_ecb_block(ctx, src, off, true)
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
          let blk = tea_ecb_block(ctx, src, off, false)
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
          let enc = tea_ecb_block(ctx, Bytes::from_array(tmp[:]), 0, false)
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
