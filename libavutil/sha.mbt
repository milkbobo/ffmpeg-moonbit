///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/sha.c` / `sha.h` (SHA-1, SHA-224,
/// SHA-256; `sha512.c` is out of scope for this slice).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2007
/// Michael Niedermayer and Copyright (C) 2009 Konstantin Shishkov.
/// This port keeps the same license.
///
/// The unrolled round macros of the C code are speed optimisations; this port
/// uses the equivalent `CONFIG_SMALL` loop. The C struct stores a `transform`
/// function pointer, replaced here by a boolean selector.

///| Round constants for SHA-256, `K256` in libavutil/sha.c. */
let sha_k256 : FixedArray[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
/// SHA-1 initial state; entries 5..7 are the zeroed tail of the C `state[8]`.
let sha1_init_state : FixedArray[UInt] = [
  0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0, 0, 0, 0,
]

///| SHA-224 initial state, `av_sha_init(ctx, 224)` in libavutil/sha.c. */
let sha224_init_state : FixedArray[UInt] = [
  0xC1059ED8, 0x367CD507, 0x3070DD17, 0xF70E5939, 0xFFC00B31, 0x68581511, 0x64F98FA7,
  0xBEFA4FA4,
]

///| SHA-256 initial state, `av_sha_init(ctx, 256)` in libavutil/sha.c. */
let sha256_init_state : FixedArray[UInt] = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB,
  0x5BE0CD19,
]

///| `rol(value, bits)`, the rotation helper from libavutil/sha.c. */
fn sha_rol(value : UInt, bits : Int) -> UInt {
  (value << bits) | (value >> (32 - bits))
}

///| Big-endian 32-bit read (`AV_RB32`) from a 64-byte block buffer. */
fn sha_rb32(buffer : FixedArray[Byte], off : Int) -> UInt {
  (buffer[off].to_uint() << 24) |
  (buffer[off + 1].to_uint() << 16) |
  (buffer[off + 2].to_uint() << 8) |
  buffer[off + 3].to_uint()
}

///| Big-endian 32-bit write (`AV_WB32`). */
fn sha_wb32(digest : FixedArray[Byte], off : Int, v : UInt) -> Unit {
  digest[off] = ((v >> 24) & 0xFF).to_byte()
  digest[off + 1] = ((v >> 16) & 0xFF).to_byte()
  digest[off + 2] = ((v >> 8) & 0xFF).to_byte()
  digest[off + 3] = (v & 0xFF).to_byte()
}

///| `Ch(x, y, z)` from libavutil/sha.c. */
fn sha_ch(x : UInt, y : UInt, z : UInt) -> UInt {
  (x & (y ^ z)) ^ z
}

///| `Maj(z, y, x)` from libavutil/sha.c, written as the usual `Maj(a, b, c)`. */
fn sha_maj(x : UInt, y : UInt, z : UInt) -> UInt {
  (x & y) | (x & z) | (y & z)
}

///| `Sigma0_256(x)`. */
fn sha_b_sig0(x : UInt) -> UInt {
  sha_rol(x, 30) ^ sha_rol(x, 19) ^ sha_rol(x, 10)
}

///| `Sigma1_256(x)`. */
fn sha_b_sig1(x : UInt) -> UInt {
  sha_rol(x, 26) ^ sha_rol(x, 21) ^ sha_rol(x, 7)
}

///| `sigma0_256(x)`. */
fn sha_s_sig0(x : UInt) -> UInt {
  sha_rol(x, 25) ^ sha_rol(x, 14) ^ (x >> 3)
}

///| `sigma1_256(x)`. */
fn sha_s_sig1(x : UInt) -> UInt {
  sha_rol(x, 15) ^ sha_rol(x, 13) ^ (x >> 10)
}

///|
/// `sha1_transform`: hash one 512-bit block into `state[0..5]`.
fn sha1_transform(state : FixedArray[UInt], buffer : FixedArray[Byte]) -> Unit {
  let block : FixedArray[UInt] = FixedArray::make(80, 0)
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  for i = 0; i < 80; i = i + 1 {
    let w = if i < 16 {
      sha_rb32(buffer, 4 * i)
    } else {
      sha_rol(block[i - 3] ^ block[i - 8] ^ block[i - 14] ^ block[i - 16], 1)
    }
    block[i] = w
    let mut t = w + e + sha_rol(a, 5)
    if i < 40 {
      if i < 20 {
        t = t + ((b & (c ^ d)) ^ d) + 0x5A827999
      } else {
        t = t + (b ^ c ^ d) + 0x6ED9EBA1
      }
    } else {
      if i < 60 {
        t = t + (((b | c) & d) | (b & c)) + 0x8F1BBCDC
      } else {
        t = t + (b ^ c ^ d) + 0xCA62C1D6
      }
    }
    e = d
    d = c
    c = sha_rol(b, 30)
    b = a
    a = t
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
  state[4] = state[4] + e
}

///|
/// `sha256_transform`: hash one 512-bit block into `state[0..8]`.
fn sha256_transform(state : FixedArray[UInt], buffer : FixedArray[Byte]) -> Unit {
  let block : FixedArray[UInt] = FixedArray::make(64, 0)
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  let mut f = state[5]
  let mut g = state[6]
  let mut h = state[7]
  for i = 0; i < 64; i = i + 1 {
    let w = if i < 16 {
      sha_rb32(buffer, 4 * i)
    } else {
      block[i - 16] +
      sha_s_sig0(block[i - 15]) +
      sha_s_sig1(block[i - 2]) +
      block[i - 7]
    }
    block[i] = w
    let t1 = w + h + sha_b_sig1(e) + sha_ch(e, f, g) + sha_k256[i]
    let t2 = sha_b_sig0(a) + sha_maj(a, b, c)
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
  state[4] = state[4] + e
  state[5] = state[5] + f
  state[6] = state[6] + g
  state[7] = state[7] + h
}

///| SHA context, mirroring `struct AVSHA` in libavutil/sha.c. */
pub struct AVSHA {
  mut digest_len : Int
  mut count : UInt64
  buffer : FixedArray[Byte]
  mut state : FixedArray[UInt]
  mut is_sha1 : Bool
}

///| `av_sha_alloc`: create a zeroed SHA context. */
pub fn av_sha_alloc() -> AVSHA {
  {
    digest_len: 0,
    count: 0,
    buffer: FixedArray::make(64, b'\x00'),
    state: FixedArray::make(8, 0),
    is_sha1: false,
  }
}

///|
/// `av_sha_init`: initialise a context for `bits` in {160, 224, 256}.
/// Returns `Err` for other digest sizes, mirroring `AVERROR(EINVAL)`.
pub fn av_sha_init(ctx : AVSHA, bits : Int) -> Result[Unit, String] {
  ctx.digest_len = bits >> 5
  ctx.count = 0
  if bits == 160 {
    ctx.state = sha1_init_state.copy()
    ctx.is_sha1 = true
    Ok(())
  } else if bits == 224 {
    ctx.state = sha224_init_state.copy()
    ctx.is_sha1 = false
    Ok(())
  } else if bits == 256 {
    ctx.state = sha256_init_state.copy()
    ctx.is_sha1 = false
    Ok(())
  } else {
    Err("EINVAL")
  }
}

///| Dispatch to the transform selected by `av_sha_init`. */
fn sha_transform(ctx : AVSHA) -> Unit {
  if ctx.is_sha1 {
    sha1_transform(ctx.state, ctx.buffer)
  } else {
    sha256_transform(ctx.state, ctx.buffer)
  }
}

///| `av_sha_update`: feed `len` bytes of `data` into the context. */
pub fn av_sha_update(ctx : AVSHA, data : Bytes, len : Int) -> Unit {
  let mut j = (ctx.count & 63).to_int()
  ctx.count = ctx.count + len.to_uint64()
  for i = 0; i < len; i = i + 1 {
    ctx.buffer[j] = data[i]
    j = j + 1
    if j == 64 {
      sha_transform(ctx)
      j = 0
    }
  }
}

///|
/// `av_sha_final`: finalise the digest into `digest`.
/// The C padding loop feeding `""` with length 1 is reproduced with an explicit
/// zero byte, since `b""` would be an empty view in MoonBit.
pub fn av_sha_final(ctx : AVSHA, digest : FixedArray[Byte]) -> Unit {
  let cntbytes = (ctx.count << 3).to_be_bytes()
  av_sha_update(ctx, b"\x80", 1)
  let mut c = (ctx.count & 63).to_int()
  while c != 56 {
    av_sha_update(ctx, b"\x00", 1)
    c = (ctx.count & 63).to_int()
  }
  av_sha_update(ctx, cntbytes, 8)
  for i = 0; i < ctx.digest_len; i = i + 1 {
    sha_wb32(digest, 4 * i, ctx.state[i])
  }
}

///| One-shot digest of `src[0..len)` into `digest` for the given `bits`. */
pub fn av_sha_sum(
  digest : FixedArray[Byte],
  src : Bytes,
  len : Int,
  bits : Int
) -> Result[Unit, String] {
  let ctx = av_sha_alloc()
  match av_sha_init(ctx, bits) {
    Err(e) => Err(e)
    Ok(_) => {
      av_sha_update(ctx, src, len)
      av_sha_final(ctx, digest)
      Ok(())
    }
  }
}
