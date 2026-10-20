///|
/// SIMD (`@v128`) multi-buffer MD5 from `libavutil/md5.c`.
///
/// MD5 is a serial construction: a single message's 64 rounds are strictly
/// dependent, so a lone stream gets no SIMD benefit (FFmpeg's own MD5 is scalar
/// C; the x86 speedups there are unrolled scalar code, not vector code). The
/// vectorisable axis is therefore *across independent messages*: the four
/// `i32x4` lanes each carry one message, and every machine word of the round
/// (`T[i]` constant, `F`/`G`/`H`/`I` mixing, the `rotl` by `S[i]`) is applied
/// lane-wise — so four digests advance at the cost of one. This mirrors the
/// "multi-buffer" (a.k.a. interleaved) hashing kernels used elsewhere, and
/// needs a new API since a single-stream `av_md5_sum` cannot be vectorised.
///
/// The four messages must have a **common length**; padding is built per lane
/// into one scratch buffer (lane `l` occupies the plane `[l*nblocks*64, ...)`),
/// which keeps the block schedule identical across lanes. The implementation is
/// asserted equal to the scalar `av_md5_sum` lane-by-lane, and to the authoritative
/// `tests/ref/fate/md5` digests, in `md5_v128_wbtest.mbt`.
///
/// Gated to `native`/`wasm`; other targets keep the scalar `av_md5_sum`.
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Little-endian 32-bit read (`AV_RL32`) from a mutable byte buffer. */
#cfg(any(target="native", target="wasm"))
fn md5v_rl32(src : FixedArray[Byte], off : Int32) -> UInt32 {
  src[off].to_uint() |
  (src[off + 1].to_uint() << 8) |
  (src[off + 2].to_uint() << 16) |
  (src[off + 3].to_uint() << 24)
}

///|
/// Little-endian 32-bit write (`AV_WL32`) into a digest buffer. */
#cfg(any(target="native", target="wasm"))
fn md5v_wl32(dst : FixedArray[Byte], off : Int32, v : UInt32) -> Unit {
  dst[off] = (v & 0xFF).to_byte()
  dst[off + 1] = ((v >> 8) & 0xFF).to_byte()
  dst[off + 2] = ((v >> 16) & 0xFF).to_byte()
  dst[off + 3] = ((v >> 24) & 0xFF).to_byte()
}

///|
/// Lane-wise `F`/`G`/`H`/`I` nonlinear functions of the MD5 round, the vector
/// forms of the `if (i < 32) { ... } else { ... }` branches of the `CORE` macro.
#cfg(any(target="native", target="wasm"))
fn md5v_f(i : Int32, b : V128, c : V128, d : V128) -> V128 {
  if i < 16 {
    @v128.v128_xor(d, @v128.v128_and_(b, @v128.v128_xor(c, d)))
  } else if i < 32 {
    @v128.v128_or_(@v128.v128_and_(d, b), @v128.v128_and_(@v128.v128_not(d), c))
  } else if i < 48 {
    @v128.v128_xor(@v128.v128_xor(b, c), d)
  } else {
    @v128.v128_xor(c, @v128.v128_or_(b, @v128.v128_not(d)))
  }
}

///|
/// `rotl32(a, t)` applied to all four lanes (`a << t | a >> (32 - t)`). */
#cfg(any(target="native", target="wasm"))
fn md5v_rotl(a : V128, t : Int32) -> V128 {
  @v128.v128_or_(@v128.i32x4_shl(a, t), @v128.i32x4_shr_u(a, 32 - t))
}

///|
/// Four-way interleaved MD5.
///
/// Hashes the four messages `srcs[0..4)` (all of length `len`) in parallel and
/// writes the four digests into `dst`, digest `l` at `dst[16*l .. 16*l + 16)`.
/// `dst` must hold at least 64 bytes. `srcs` must have exactly four entries.
#cfg(any(target="native", target="wasm"))
pub fn av_md5_sum_x4(
  dst : FixedArray[Byte],
  srcs : FixedArray[Bytes],
  len : Int32,
) -> Unit {
  // Per-lane padded message: `len` bytes, one 0x80, then the LE 64-bit bit
  // length in the final 8 bytes — the same schedule as `av_md5_final`.
  let nblocks = (len + 9 + 63) / 64
  let plane = nblocks * 64
  let scratch : FixedArray[Byte] = FixedArray::make(4 * plane, b'\x00')
  let lenbytes = (len.to_uint64() << 3).to_le_bytes()
  for l = 0; l < 4; l = l + 1 {
    let base = l * plane
    let src = srcs[l]
    for i = 0; i < len; i = i + 1 {
      scratch[base + i] = src[i]
    }
    scratch[base + len] = b'\x80'
    for k = 0; k < 8; k = k + 1 {
      scratch[base + plane - 8 + k] = lenbytes[k]
    }
  }
  // Running state, one lane per message; initialised to the MD5 IV
  // (`ABCD[3..0]` of `av_md5_init`).
  let mut sa = @v128.i32x4_splat(0x67452301)
  let mut sb = @v128.i32x4_splat(0xefcdab89)
  let mut sc = @v128.i32x4_splat(0x98badcfe)
  let mut sd = @v128.i32x4_splat(0x10325476)
  let xw : FixedArray[V128] = FixedArray::make(16, @v128.i32x4_splat(0))
  for nb = 0; nb < nblocks; nb = nb + 1 {
    // The 16 message words of this 512-bit block, one lane per message.
    for w = 0; w < 16; w = w + 1 {
      let off = nb * 64 + 4 * w
      xw[w] = @v128.i32x4_const(
        md5v_rl32(scratch, off),
        md5v_rl32(scratch, plane + off),
        md5v_rl32(scratch, 2 * plane + off),
        md5v_rl32(scratch, 3 * plane + off),
      )
    }
    let mut a = sa
    let mut b = sb
    let mut c = sc
    let mut d = sd
    for i = 0; i < 64; i = i + 1 {
      let t = md5_s[(i >> 4) * 4 + (i & 3)]
      let x = xw[md5_x_index(i)]
      a = @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(a, @v128.i32x4_splat(md5_t[i])),
          md5v_f(i, b, c, d),
        ),
        x,
      )
      a = @v128.i32x4_add(b, md5v_rotl(a, t))
      let tmp = d
      d = c
      c = b
      b = a
      a = tmp
    }
    sa = @v128.i32x4_add(sa, a)
    sb = @v128.i32x4_add(sb, b)
    sc = @v128.i32x4_add(sc, c)
    sd = @v128.i32x4_add(sd, d)
  }
  for l = 0; l < 4; l = l + 1 {
    md5v_wl32(dst, 16 * l, @v128.i32x4_extract_lane(sa, l))
    md5v_wl32(dst, 16 * l + 4, @v128.i32x4_extract_lane(sb, l))
    md5v_wl32(dst, 16 * l + 8, @v128.i32x4_extract_lane(sc, l))
    md5v_wl32(dst, 16 * l + 12, @v128.i32x4_extract_lane(sd, l))
  }
}
