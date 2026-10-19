///|
/// SIMD (`@v128`) SIMPLE-C IDCT, on a compact byte-buffer block representation.
///
/// This is the "representation change" the plain `idct.mbt` port needs before
/// it can be vectorised: `@v128` loads/stores are byte addressed, so an 8x8
/// `int16` block is held as the same 128-byte little-endian layout C uses
/// (`int16_t block[64]`), which lets `v128_load`/`v128_store` read whole rows
/// as `i16x8` lanes.
///
/// Structure (mirrors FFmpeg's `libavcodec/x86/simple_idct.asm` approach):
///   1. load the 8 rows (`i16x8` each);
///   2. transpose -> 8 column vectors whose lanes are the rows;
///   3. row pass: lane-wise butterfly across the 8 element vectors
///      (`i32x4` accumulate, `pmaddwd`-free but the same arithmetic);
///   4. transpose back -> row-major, then the column pass is lane-wise over
///      rows with lanes = columns (no third transpose needed);
///   5. narrow `i32x4 -> i16x8` and store.
///
/// The 8x8 `int16` transpose is the classic three-stage unpack (16 -> 32 -> 64
/// bit granularity) expressed with `i8x16_shuffle`; only six distinct index
/// vectors are needed.
///
/// Deviation (documented in README): the scalar port's per-row DC-only
/// shortcut in `idctRowCondDC` is *not* reproduced, exactly as the x86 asm
/// variants do; correctness is therefore asserted against the double-precision
/// reference `dctref.c` with the `libavcodec/tests/dct.c` tolerances.
///
/// Gated to `native`/`wasm`. Only the 8-bit variant is vectorised here; the
/// 10/12-bit and `int32` variants remain scalar.

///|
/// Convert a row-major `int16` block (`Array[Int]`) into the 128-byte
/// little-endian buffer used by the SIMD paths.
pub fn idct_block_to_bytes(block : Array[Int]) -> FixedArray[Byte] {
  let buf : FixedArray[Byte] = FixedArray::make(128, b'\x00')
  for i = 0; i < 64; i = i + 1 {
    buf[2 * i] = (block[i] & 0xFF).to_byte()
    buf[2 * i + 1] = ((block[i] >> 8) & 0xFF).to_byte()
  }
  buf
}

///| Convert the 128-byte little-endian buffer back into a row-major block. */
pub fn idct_bytes_to_block(buf : FixedArray[Byte]) -> Array[Int] {
  let out : Array[Int] = Array::make(64, 0)
  for i = 0; i < 64; i = i + 1 {
    let u = buf[2 * i].to_uint() | (buf[2 * i + 1].to_uint() << 8)
    out[i] = (u.reinterpret_as_int() << 16) >> 16
  }
  out
}

///| Apply one `i8x16_shuffle` from a 16-entry index vector. */
#cfg(any(target="native", target="wasm"))
fn idct_sh(a : V128, b : V128, idx : Array[Int]) -> V128 {
  @v128.i8x16_shuffle(
    a,
    b,
    idx[0],
    idx[1],
    idx[2],
    idx[3],
    idx[4],
    idx[5],
    idx[6],
    idx[7],
    idx[8],
    idx[9],
    idx[10],
    idx[11],
    idx[12],
    idx[13],
    idx[14],
    idx[15],
  )
}

///|
/// 8x8 `int16` transpose: 8 row vectors in, 8 column vectors out.
/// Three unpack stages at 16/32/64-bit granularity.
#cfg(any(target="native", target="wasm"))
fn idct_transpose(rows : Array[V128]) -> Array[V128] {
  let s1lo = [0, 1, 16, 17, 2, 3, 18, 19, 4, 5, 20, 21, 6, 7, 22, 23]
  let s1hi = [8, 9, 24, 25, 10, 11, 26, 27, 12, 13, 28, 29, 14, 15, 30, 31]
  let s2lo = [0, 1, 2, 3, 16, 17, 18, 19, 4, 5, 6, 7, 20, 21, 22, 23]
  let s2hi = [8, 9, 10, 11, 24, 25, 26, 27, 12, 13, 14, 15, 28, 29, 30, 31]
  let s3lo = [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23]
  let s3hi = [8, 9, 10, 11, 12, 13, 14, 15, 24, 25, 26, 27, 28, 29, 30, 31]
  let t0 = idct_sh(rows[0], rows[1], s1lo)
  let t1 = idct_sh(rows[0], rows[1], s1hi)
  let t2 = idct_sh(rows[2], rows[3], s1lo)
  let t3 = idct_sh(rows[2], rows[3], s1hi)
  let t4 = idct_sh(rows[4], rows[5], s1lo)
  let t5 = idct_sh(rows[4], rows[5], s1hi)
  let t6 = idct_sh(rows[6], rows[7], s1lo)
  let t7 = idct_sh(rows[6], rows[7], s1hi)
  let u0 = idct_sh(t0, t2, s2lo)
  let u1 = idct_sh(t0, t2, s2hi)
  let u2 = idct_sh(t1, t3, s2lo)
  let u3 = idct_sh(t1, t3, s2hi)
  let u4 = idct_sh(t4, t6, s2lo)
  let u5 = idct_sh(t4, t6, s2hi)
  let u6 = idct_sh(t5, t7, s2lo)
  let u7 = idct_sh(t5, t7, s2hi)
  [
    idct_sh(u0, u4, s3lo),
    idct_sh(u0, u4, s3hi),
    idct_sh(u1, u5, s3lo),
    idct_sh(u1, u5, s3hi),
    idct_sh(u2, u6, s3lo),
    idct_sh(u2, u6, s3hi),
    idct_sh(u3, u7, s3lo),
    idct_sh(u3, u7, s3hi),
  ]
}

///|
/// Emulate a C store into `int16_t`: keep the low 16 bits and sign-extend,
/// i.e. *truncate* rather than saturate (the scalar port stores `(int)...` back
/// into the `int16_t` block, so out-of-range intermediates wrap).
#cfg(any(target="native", target="wasm"))
fn idct_i16(x : V128) -> V128 {
  @v128.i32x4_shr_s(@v128.i32x4_shl(x, 16), 16)
}

///| Multiply an `i32x4` vector by the constant `c` (32-bit wrapping). */
#cfg(any(target="native", target="wasm"))
fn idct_mul(c : Int, v : V128) -> V128 {
  @v128.i32x4_mul(@v128.i32x4_splat(c.reinterpret_as_uint()), v)
}

///| Horizontal lane-wise 1-D butterfly over 8 `i16x8` element vectors. */
#cfg(any(target="native", target="wasm"))
fn idct_1d(v : Array[V128], cfg : SimpleIdct, is_col : Bool) -> Array[V128] {
  let shift = if is_col { cfg.col_shift } else { cfg.row_shift }
  // low/high halves: four lanes per group (rows 0..3 / 4..7)
  let g0 : Array[V128] = []
  let g1 : Array[V128] = []
  for k = 0; k < 8; k = k + 1 {
    g0.push(@v128.i32x4_extend_low_i16x8_s(v[k]))
    g1.push(@v128.i32x4_extend_high_i16x8_s(v[k]))
  }
  let res : Array[V128] = []
  for grp = 0; grp < 2; grp = grp + 1 {
    let x = if grp == 0 { g0 } else { g1 }
    // a0 initial: row pass adds the rounding constant after *W4, the column
    // pass adds (1<<(COL_SHIFT-1))/W4 to the input before *W4 (see simple_idct.c).
    let mut a0 = if is_col {
      idct_mul(cfg.w4, @v128.i32x4_add(x[0], @v128.i32x4_splat(((1 << (shift - 1)) / cfg.w4).reinterpret_as_uint())))
    } else {
      @v128.i32x4_add(idct_mul(cfg.w4, x[0]), @v128.i32x4_splat((1 << (shift - 1)).reinterpret_as_uint()))
    }
    let mut a1 = a0
    let mut a2 = a0
    let mut a3 = a0
    a0 = @v128.i32x4_add(a0, idct_mul(cfg.w2, x[2]))
    a1 = @v128.i32x4_add(a1, idct_mul(cfg.w6, x[2]))
    a2 = @v128.i32x4_add(a2, idct_mul(0 - cfg.w6, x[2]))
    a3 = @v128.i32x4_add(a3, idct_mul(0 - cfg.w2, x[2]))
    let mut b0 = @v128.i32x4_add(idct_mul(cfg.w1, x[1]), idct_mul(cfg.w3, x[3]))
    let mut b1 = @v128.i32x4_add(idct_mul(cfg.w3, x[1]), idct_mul(0 - cfg.w7, x[3]))
    let mut b2 = @v128.i32x4_add(idct_mul(cfg.w5, x[1]), idct_mul(0 - cfg.w1, x[3]))
    let mut b3 = @v128.i32x4_add(idct_mul(cfg.w7, x[1]), idct_mul(0 - cfg.w5, x[3]))
    a0 = @v128.i32x4_add(
      a0,
      @v128.i32x4_add(idct_mul(cfg.w4, x[4]), idct_mul(cfg.w6, x[6])),
    )
    a1 = @v128.i32x4_add(
      a1,
      @v128.i32x4_sub(idct_mul(0 - cfg.w4, x[4]), idct_mul(cfg.w2, x[6])),
    )
    a2 = @v128.i32x4_add(
      a2,
      @v128.i32x4_add(idct_mul(0 - cfg.w4, x[4]), idct_mul(cfg.w2, x[6])),
    )
    a3 = @v128.i32x4_add(
      a3,
      @v128.i32x4_sub(idct_mul(cfg.w4, x[4]), idct_mul(cfg.w6, x[6])),
    )
    b0 = @v128.i32x4_add(
      b0,
      @v128.i32x4_add(idct_mul(cfg.w5, x[5]), idct_mul(cfg.w7, x[7])),
    )
    b1 = @v128.i32x4_add(
      b1,
      @v128.i32x4_sub(idct_mul(0 - cfg.w1, x[5]), idct_mul(cfg.w5, x[7])),
    )
    b2 = @v128.i32x4_add(
      b2,
      @v128.i32x4_add(idct_mul(cfg.w7, x[5]), idct_mul(cfg.w3, x[7])),
    )
    b3 = @v128.i32x4_add(
      b3,
      @v128.i32x4_add(idct_mul(cfg.w3, x[5]), idct_mul(0 - cfg.w1, x[7])),
    )
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_add(a0, b0), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_add(a1, b1), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_add(a2, b2), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_add(a3, b3), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_sub(a3, b3), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_sub(a2, b2), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_sub(a1, b1), shift)))
    res.push(idct_i16(@v128.i32x4_shr_s(@v128.i32x4_sub(a0, b0), shift)))
  }
  // combine the two 4-lane groups into one 8-lane vector per output element
  let out : Array[V128] = []
  for k = 0; k < 8; k = k + 1 {
    out.push(@v128.i16x8_narrow_i32x4_s(res[k], res[8 + k]))
  }
  out
}

///| Run the full 8x8 SIMD transform and return the 8 result rows (`i16x8`). */
#cfg(any(target="native", target="wasm"))
fn idct_rows_v128(buf : FixedArray[Byte], cfg : SimpleIdct) -> Array[V128] {
  let rows : Array[V128] = []
  for r = 0; r < 8; r = r + 1 {
    rows.push(@v128.v128_load(buf, r * 16))
  }
  // row pass: transpose so lanes are rows, butterfly, transpose back
  let after_row = idct_transpose(idct_1d(idct_transpose(rows), cfg, false))
  // column pass: lanes are columns already
  idct_1d(after_row, cfg, true)
}

///| `simple_idct` (in place) on the compact byte buffer. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_v128(buf : FixedArray[Byte]) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_8bit)
  for r = 0; r < 8; r = r + 1 {
    @v128.v128_store(buf, r * 16, out[r])
  }
}

///| Store the low 8 bytes of `v` (a saturated row) at `dest[off..off+8)`. */
#cfg(any(target="native", target="wasm"))
fn idct_store8(dest : FixedArray[Byte], off : Int, v : V128) -> Unit {
  let scratch : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  @v128.v128_store(scratch, 0, v)
  for j = 0; j < 8; j = j + 1 {
    dest[off + j] = scratch[j]
  }
}

///| `ff_simple_idct_put_int16_8bit` on a byte pixel plane of the given stride. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_put_v128(
  dest : FixedArray[Byte],
  stride : Int,
  buf : FixedArray[Byte],
) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_8bit)
  for r = 0; r < 8; r = r + 1 {
    idct_store8(
      dest,
      r * stride,
      @v128.i8x16_narrow_i16x8_u(out[r], out[r]),
    )
  }
}

///| `ff_simple_idct_add_int16_8bit` on a byte pixel plane of the given stride. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_add_v128(
  dest : FixedArray[Byte],
  stride : Int,
  buf : FixedArray[Byte],
) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_8bit)
  for r = 0; r < 8; r = r + 1 {
    // load the current 8 destination bytes through a scratch (no OOB read)
    let scratch : FixedArray[Byte] = FixedArray::make(16, b'\x00')
    for j = 0; j < 8; j = j + 1 {
      scratch[j] = dest[r * stride + j]
    }
    let d = @v128.i16x8_extend_low_i8x16_u(@v128.v128_load(scratch, 0))
    let sum = @v128.i8x16_narrow_i16x8_u(
      @v128.i16x8_add(d, out[r]),
      @v128.i16x8_add(d, out[r]),
    )
    idct_store8(dest, r * stride, sum)
  }
}

// ---------------------------------------------------------------------------
// 10-bit / 12-bit (`pixel = uint16_t`) variants
// ---------------------------------------------------------------------------

///|
/// Clamp an `i16x8` row to `[0, max_val]` (`av_clip_uintp2`) and store it as
/// 16 little-endian bytes (8 `uint16` pixels).
#cfg(any(target="native", target="wasm"))
fn idct_store16_clamped(
  dest : FixedArray[Byte],
  off : Int,
  v : V128,
  max_val : Int,
) -> Unit {
  let hi = @v128.i16x8_splat(max_val.to_uint16())
  let zero = @v128.i16x8_splat(0)
  @v128.v128_store(
    dest,
    off,
    @v128.i16x8_max_s(@v128.i16x8_min_s(v, hi), zero),
  )
}

///| `ff_simple_idct_int16_10bit` (in place) on the compact byte buffer. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_v128_10bit(buf : FixedArray[Byte]) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_10bit)
  for r = 0; r < 8; r = r + 1 {
    @v128.v128_store(buf, r * 16, out[r])
  }
}

///| `ff_simple_idct_int16_12bit` (in place) on the compact byte buffer. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_v128_12bit(buf : FixedArray[Byte]) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_12bit)
  for r = 0; r < 8; r = r + 1 {
    @v128.v128_store(buf, r * 16, out[r])
  }
}

///|
/// `ff_simple_idct_put_int16_10bit` writing 16-bit pixels; `stride_bytes` is
/// the row stride in bytes (8 pixels = 16 bytes per row).
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_put_v128_10bit(
  dest : FixedArray[Byte],
  stride_bytes : Int,
  buf : FixedArray[Byte],
) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_10bit)
  for r = 0; r < 8; r = r + 1 {
    idct_store16_clamped(dest, r * stride_bytes, out[r], 1023)
  }
}

///| `ff_simple_idct_put_int16_12bit` writing 16-bit pixels. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_put_v128_12bit(
  dest : FixedArray[Byte],
  stride_bytes : Int,
  buf : FixedArray[Byte],
) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_12bit)
  for r = 0; r < 8; r = r + 1 {
    idct_store16_clamped(dest, r * stride_bytes, out[r], 4095)
  }
}

///| `ff_simple_idct_add_int16_10bit` writing 16-bit pixels. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_add_v128_10bit(
  dest : FixedArray[Byte],
  stride_bytes : Int,
  buf : FixedArray[Byte],
) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_10bit)
  for r = 0; r < 8; r = r + 1 {
    let off = r * stride_bytes
    let cur = @v128.v128_load(dest, off)
    idct_store16_clamped(dest, off, @v128.i16x8_add(cur, out[r]), 1023)
  }
}

///| `ff_simple_idct_add_int16_12bit` writing 16-bit pixels. */
#cfg(any(target="native", target="wasm"))
pub fn ff_simple_idct_add_v128_12bit(
  dest : FixedArray[Byte],
  stride_bytes : Int,
  buf : FixedArray[Byte],
) -> Unit {
  let out = idct_rows_v128(buf, idct_int16_12bit)
  for r = 0; r < 8; r = r + 1 {
    let off = r * stride_bytes
    let cur = @v128.v128_load(dest, off)
    idct_store16_clamped(dest, off, @v128.i16x8_add(cur, out[r]), 4095)
  }
}
