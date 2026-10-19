///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/md5.c` / `md5.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2006
/// Michael Niedermayer and Copyright (C) 2003-2005 Christopher R. Hertel.
/// This port keeps the same license.
///
/// The unrolled `CORE4` fast path of the C code is a speed optimisation; this
/// port uses the equivalent `CONFIG_SMALL` loop. The C API writes into a
/// caller-provided digest buffer; here the digest is a `FixedArray[Byte]` of
/// length >= 16.

///| `T[i] = floor(fabs(sin(i + 1)) * 2^32)`, the `T` table in libavutil/md5.c. */
let md5_t : FixedArray[UInt] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
  0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
  0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
  0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
  0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
  0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
  0xeb86d391,
]

///| Per-round rotation amounts, flattened from `S[4][4]` in libavutil/md5.c. */
let md5_s : FixedArray[Int] = [
  7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21,
]

///| Read a little-endian 32-bit word (`AV_RL32`). */
fn md5_rl32(src : Bytes, off : Int) -> UInt {
  src[off].to_uint() |
  (src[off + 1].to_uint() << 8) |
  (src[off + 2].to_uint() << 16) |
  (src[off + 3].to_uint() << 24)
}

///| Write a little-endian 32-bit word (`AV_WL32`). */
fn md5_wl32(dst : FixedArray[Byte], off : Int, v : UInt) -> Unit {
  dst[off] = (v & 0xFF).to_byte()
  dst[off + 1] = ((v >> 8) & 0xFF).to_byte()
  dst[off + 2] = ((v >> 16) & 0xFF).to_byte()
  dst[off + 3] = ((v >> 24) & 0xFF).to_byte()
}

///| Message word index `X[...]` used by the `CORE` macro at step `i`. */
fn md5_x_index(i : Int) -> Int {
  if i < 16 {
    i & 15
  } else if i < 32 {
    (1 + 5 * i) & 15
  } else if i < 48 {
    (5 + 3 * i) & 15
  } else {
    (7 * i) & 15
  }
}

///| MD5 context, mirroring `struct AVMD5` in libavutil/md5.c. */
pub struct AVMD5 {
  mut len : UInt64
  block : FixedArray[Byte]
  abcd : FixedArray[UInt]
}

///| `av_md5_alloc`: create a zeroed MD5 context. */
pub fn av_md5_alloc() -> AVMD5 {
  { len: 0, block: FixedArray::make(64, b'\x00'), abcd: FixedArray::make(4, 0) }
}

///| `av_md5_init`: reset a context to the MD5 initial state. */
pub fn av_md5_init(ctx : AVMD5) -> Unit {
  ctx.len = 0
  ctx.abcd[0] = 0x10325476
  ctx.abcd[1] = 0x98badcfe
  ctx.abcd[2] = 0xefcdab89
  ctx.abcd[3] = 0x67452301
}

///| `body`: hash `nblocks` 512-bit blocks, port of the static `body()` helper. */
fn md5_body(abcd : FixedArray[UInt], src : Bytes, off : Int, nblocks : Int) -> Unit {
  for nb = 0; nb < nblocks; nb = nb + 1 {
    let mut a = abcd[3]
    let mut b = abcd[2]
    let mut c = abcd[1]
    let mut d = abcd[0]
    let base = off + nb * 64
    for i = 0; i < 64; i = i + 1 {
      let t = md5_s[(i >> 4) * 4 + (i & 3)]
      a = a + md5_t[i]
      let xv = md5_rl32(src, base + 4 * md5_x_index(i))
      if i < 16 {
        a = a + (d ^ (b & (c ^ d))) + xv
      } else if i < 32 {
        a = a + ((d & b) | (d.lnot() & c)) + xv
      } else if i < 48 {
        a = a + (b ^ c ^ d) + xv
      } else {
        a = a + (c ^ (b | d.lnot())) + xv
      }
      a = b + ((a << t) | (a >> (32 - t)))
      let tmp = d
      d = c
      c = b
      b = a
      a = tmp
    }
    abcd[0] = abcd[0] + d
    abcd[1] = abcd[1] + c
    abcd[2] = abcd[2] + b
    abcd[3] = abcd[3] + a
  }
}

///| `av_md5_update`: feed `len` bytes of `src` into the context. */
pub fn av_md5_update(ctx : AVMD5, src : Bytes, len : Int) -> Unit {
  let j = (ctx.len & 63).to_int()
  ctx.len = ctx.len + len.to_uint64()
  let mut p = 0
  let mut rem = len
  if j != 0 {
    let cnt = if rem < 64 - j { rem } else { 64 - j }
    for k = 0; k < cnt; k = k + 1 {
      ctx.block[j + k] = src[k]
    }
    p = cnt
    rem = rem - cnt
    if j + cnt < 64 {
      return
    }
    md5_body(ctx.abcd, Bytes::from_array(ctx.block[:]), 0, 1)
  }
  let nblocks = rem / 64
  if nblocks > 0 {
    md5_body(ctx.abcd, src, p, nblocks)
    p = p + nblocks * 64
  }
  rem = rem & 63
  if rem > 0 {
    for k = 0; k < rem; k = k + 1 {
      ctx.block[k] = src[p + k]
    }
  }
}

///|
/// `av_md5_final`: finalise the digest into `dst` (at least 16 bytes).
/// The C padding loop feeding `""` with length 1 is reproduced with an explicit
/// zero byte, since `b""` would be an empty view in MoonBit.
pub fn av_md5_final(ctx : AVMD5, dst : FixedArray[Byte]) -> Unit {
  let cntbytes = (ctx.len << 3).to_le_bytes()
  av_md5_update(ctx, b"\x80", 1)
  while (ctx.len & 63).to_int() != 56 {
    av_md5_update(ctx, b"\x00", 1)
  }
  av_md5_update(ctx, cntbytes, 8)
  for i = 0; i < 4; i = i + 1 {
    md5_wl32(dst, 4 * i, ctx.abcd[3 - i])
  }
}

///| `av_md5_sum`: one-shot digest of `src[0..len)` into `dst`. */
pub fn av_md5_sum(dst : FixedArray[Byte], src : Bytes, len : Int) -> Unit {
  let ctx = av_md5_alloc()
  av_md5_init(ctx)
  av_md5_update(ctx, src, len)
  av_md5_final(ctx, dst)
}
