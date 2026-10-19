///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/simple_idct.c` (the C "SIMPLE-C"
/// inverse DCT that `ff_idctdsp_init` selects by default) together with the
/// pixel-clamping and scan-table helpers from `libavcodec/idctdsp.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2001
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Ported here: the 8x8 in-place / put / add IDCT for the `int16` input
/// variants `ff_simple_idct{,_put,_add}_int16_8bit`, `..._int16_10bit` and
/// `..._int16_12bit`, and `ff_put_pixels_clamped_c`,
/// `ff_add_pixels_clamped_c`, `put_signed_pixels_clamped_c`,
/// `ff_init_scantable_permutation`, `ff_permute_scantable`.
///
/// Out of scope for this slice (not ported):
///   * the `int32` input variant `ff_simple_idct_*_int32_10bit` (MPEG-4 Simple
///     Studio Profile; needs a 32-bit `idctin` typedef),
///   * the partial 2x4x8 / 8x4 / 4x8 transforms `ff_simple_idct248_put`,
///     `ff_simple_idct84_add`, `ff_simple_idct48_add`, `ff_simple_idct44_add`
///     (DV and WMV2 specific),
///   * the integer `FF_IDCT_INT` (`jdct`/`jrevdct.c`), FAAN and Xvid IDCTs, and
///     all SIMD/assembly variants (kept in C, see README "边界原则").
///
/// Implementation notes:
///   * `SUINT` is the C `unsigned` holding a signed value (see
///     `doc/undefined.txt`); all accumulators here are `UInt` (32-bit wrapping)
///     so the arithmetic matches the production C build bit for bit, and the
///     final `(int)... >> shift` becomes `reinterpret_as_int` + arithmetic
///     shift.
///   * `idctin` is `int16_t` for the `IN_IDCT_DEPTH == 16` variants ported
///     here, so every value written back into the block is truncated to 16 bits
///     (`i16`) exactly like the C store into `int16_t`.

///| Bit-depth-specific constants and shifts for the SIMPLE-C IDCT. */
pub struct SimpleIdct {
  w1 : Int
  w2 : Int
  w3 : Int
  w4 : Int
  w5 : Int
  w6 : Int
  w7 : Int
  row_shift : Int
  col_shift : Int
  dc_shift : Int
  max_val : Int
}

///| `simple_idct_template.c`, `BIT_DEPTH == 8` / `IN_IDCT_DEPTH == 16`. */
pub let idct_int16_8bit : SimpleIdct = {
  w1: 22725,
  w2: 21407,
  w3: 19266,
  w4: 16383,
  w5: 12873,
  w6: 8867,
  w7: 4520,
  row_shift: 11,
  col_shift: 20,
  dc_shift: 3,
  max_val: 255,
}

///| `simple_idct_template.c`, `BIT_DEPTH == 10` / `IN_IDCT_DEPTH == 16`. */
pub let idct_int16_10bit : SimpleIdct = {
  w1: 22725,
  w2: 21407,
  w3: 19265,
  w4: 16384,
  w5: 12873,
  w6: 8867,
  w7: 4520,
  row_shift: 12,
  col_shift: 19,
  dc_shift: 2,
  max_val: 1023,
}

///| `simple_idct_template.c`, `BIT_DEPTH == 12` / `IN_IDCT_DEPTH == 16`. */
pub let idct_int16_12bit : SimpleIdct = {
  w1: 45451,
  w2: 42813,
  w3: 38531,
  w4: 32767,
  w5: 25746,
  w6: 17734,
  w7: 9041,
  row_shift: 16,
  col_shift: 17,
  dc_shift: -1,
  max_val: 4095,
}

///| Reinterpret an `Int` as a 32-bit unsigned value (the C `SUINT` cast). */
fn u(x : Int) -> UInt {
  x.reinterpret_as_uint()
}

///| Reinterpret a 32-bit unsigned accumulator back as a signed `Int`. */
fn s(x : UInt) -> Int {
  x.reinterpret_as_int()
}

///| Truncate to `int16_t` (sign-extend the low 16 bits), like a C store. */
fn i16(x : Int) -> Int {
  (x << 16) >> 16
}

///| `av_clip_uint8`: clip a signed value into [0, 255]. */
pub fn clip_uint8(a : Int) -> Int {
  if a < 0 {
    0
  } else if a > 255 {
    255
  } else {
    a
  }
}

///| `av_clip_uintp2`: clip into [0, 2^p - 1] (`av_clip_pixel` for depth > 8). */
pub fn clip_uintp2(a : Int, p : Int) -> Int {
  let hi = (1 << p) - 1
  if a < 0 {
    0
  } else if a > hi {
    hi
  } else {
    a
  }
}

///|
/// `idctRowCondDC`: one row of the row-wise IDCT, `extra_shift == 0`.
/// `block` holds the 64 coefficients, `base` is the row start.
fn idct_row(block : Array[Int], base : Int, cfg : SimpleIdct) -> Unit {
  // DC-only fast path (IN_IDCT_DEPTH == 16): row[1..7] all zero.
  let mut dc_only = true
  for k = 1; k < 8; k = k + 1 {
    if i16(block[base + k]) != 0 {
      dc_only = false
    }
  }
  if dc_only {
    let r0 = i16(block[base])
    let temp = if cfg.dc_shift >= 0 {
      i16(r0 << cfg.dc_shift)
    } else {
      i16((r0 + (1 << (0 - cfg.dc_shift - 1))) >> (0 - cfg.dc_shift))
    }
    for k = 0; k < 8; k = k + 1 {
      block[base + k] = temp
    }
    return
  }

  let r0 = i16(block[base])
  let r1 = i16(block[base + 1])
  let r2 = i16(block[base + 2])
  let r3 = i16(block[base + 3])
  let r4 = i16(block[base + 4])
  let r5 = i16(block[base + 5])
  let r6 = i16(block[base + 6])
  let r7 = i16(block[base + 7])

  let w1 = u(cfg.w1)
  let w2 = u(cfg.w2)
  let w3 = u(cfg.w3)
  let w4 = u(cfg.w4)
  let w5 = u(cfg.w5)
  let w6 = u(cfg.w6)
  let w7 = u(cfg.w7)
  let mw1 = u(0 - cfg.w1)
  let mw2 = u(0 - cfg.w2)
  let mw4 = u(0 - cfg.w4)
  let mw5 = u(0 - cfg.w5)
  let mw6 = u(0 - cfg.w6)
  let mw7 = u(0 - cfg.w7)

  let rnd = u(1 << (cfg.row_shift - 1))
  let mut a0 = w4 * u(r0) + rnd
  let mut a1 = a0
  let mut a2 = a0
  let mut a3 = a0
  a0 = a0 + w2 * u(r2)
  a1 = a1 + w6 * u(r2)
  a2 = a2 + mw6 * u(r2)
  a3 = a3 + mw2 * u(r2)

  let mut b0 = w1 * u(r1)
  let mut b1 = w3 * u(r1)
  let mut b2 = w5 * u(r1)
  let mut b3 = w7 * u(r1)
  b0 = b0 + w3 * u(r3)
  b1 = b1 + mw7 * u(r3)
  b2 = b2 + mw1 * u(r3)
  b3 = b3 + mw5 * u(r3)

  if (r4 | r5 | r6 | r7) != 0 {
    a0 = a0 + w4 * u(r4) + w6 * u(r6)
    a1 = a1 + mw4 * u(r4) - w2 * u(r6)
    a2 = a2 + mw4 * u(r4) + w2 * u(r6)
    a3 = a3 + w4 * u(r4) - w6 * u(r6)
    b0 = b0 + w5 * u(r5) + w7 * u(r7)
    b1 = b1 + mw1 * u(r5) + mw5 * u(r7)
    b2 = b2 + w7 * u(r5) + w3 * u(r7)
    b3 = b3 + w3 * u(r5) + mw1 * u(r7)
  }

  let sh = cfg.row_shift
  block[base + 0] = i16(s(a0 + b0) >> sh)
  block[base + 7] = i16(s(a0 - b0) >> sh)
  block[base + 1] = i16(s(a1 + b1) >> sh)
  block[base + 6] = i16(s(a1 - b1) >> sh)
  block[base + 2] = i16(s(a2 + b2) >> sh)
  block[base + 5] = i16(s(a2 - b2) >> sh)
  block[base + 3] = i16(s(a3 + b3) >> sh)
  block[base + 4] = i16(s(a3 - b3) >> sh)
}

///|
/// `IDCT_COLS`: compute the eight output values of one column-wise pass.
/// `ci` is the column index (0..7); the column is read with stride 8.
fn idct_col_values(block : Array[Int], ci : Int, cfg : SimpleIdct) -> Array[Int] {
  let c0 = i16(block[ci])
  let c1 = i16(block[ci + 8])
  let c2 = i16(block[ci + 16])
  let c3 = i16(block[ci + 24])
  let c4 = i16(block[ci + 32])
  let c5 = i16(block[ci + 40])
  let c6 = i16(block[ci + 48])
  let c7 = i16(block[ci + 56])

  let w1 = u(cfg.w1)
  let w2 = u(cfg.w2)
  let w3 = u(cfg.w3)
  let w4 = u(cfg.w4)
  let w5 = u(cfg.w5)
  let w6 = u(cfg.w6)
  let w7 = u(cfg.w7)
  let mw1 = u(0 - cfg.w1)
  let mw2 = u(0 - cfg.w2)
  let mw4 = u(0 - cfg.w4)
  let mw5 = u(0 - cfg.w5)
  let mw6 = u(0 - cfg.w6)
  let mw7 = u(0 - cfg.w7)

  // (1 << (COL_SHIFT - 1)) / W4, evaluated at compile time in C.
  let mut a0 = w4 * u(c0 + ((1 << (cfg.col_shift - 1)) / cfg.w4))
  let mut a1 = a0
  let mut a2 = a0
  let mut a3 = a0
  a0 = a0 + w2 * u(c2)
  a1 = a1 + w6 * u(c2)
  a2 = a2 + mw6 * u(c2)
  a3 = a3 + mw2 * u(c2)

  let mut b0 = w1 * u(c1)
  let mut b1 = w3 * u(c1)
  let mut b2 = w5 * u(c1)
  let mut b3 = w7 * u(c1)
  b0 = b0 + w3 * u(c3)
  b1 = b1 + mw7 * u(c3)
  b2 = b2 + mw1 * u(c3)
  b3 = b3 + mw5 * u(c3)

  if c4 != 0 {
    a0 = a0 + w4 * u(c4)
    a1 = a1 + mw4 * u(c4)
    a2 = a2 + mw4 * u(c4)
    a3 = a3 + w4 * u(c4)
  }
  if c5 != 0 {
    b0 = b0 + w5 * u(c5)
    b1 = b1 + mw1 * u(c5)
    b2 = b2 + w7 * u(c5)
    b3 = b3 + w3 * u(c5)
  }
  if c6 != 0 {
    a0 = a0 + w6 * u(c6)
    a1 = a1 + mw2 * u(c6)
    a2 = a2 + w2 * u(c6)
    a3 = a3 + mw6 * u(c6)
  }
  if c7 != 0 {
    b0 = b0 + w7 * u(c7)
    b1 = b1 + mw5 * u(c7)
    b2 = b2 + w3 * u(c7)
    b3 = b3 + mw1 * u(c7)
  }

  let sh = cfg.col_shift
  [
    s(a0 + b0) >> sh,
    s(a1 + b1) >> sh,
    s(a2 + b2) >> sh,
    s(a3 + b3) >> sh,
    s(a3 - b3) >> sh,
    s(a2 - b2) >> sh,
    s(a1 - b1) >> sh,
    s(a0 - b0) >> sh,
  ]
}

///| Row pass over all 8 rows, shared by every variant. */
fn idct_rows(block : Array[Int], cfg : SimpleIdct) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    idct_row(block, i * 8, cfg)
  }
}

///|
/// `ff_simple_idct_*_put`: transform `block` in place, then write the clipped
/// 8x8 result into `dest` (row stride `stride`, no `dest += line_size` cast).
pub fn simple_idct_put(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
  cfg : SimpleIdct,
) -> Unit {
  idct_rows(block, cfg)
  for i = 0; i < 8; i = i + 1 {
    let v = idct_col_values(block, i, cfg)
    for r = 0; r < 8; r = r + 1 {
      let hi = cfg.max_val
      let p = v[r]
      dest[r * stride + i] = if p < 0 { 0 } else if p > hi { hi } else { p }
    }
  }
}

///| `ff_simple_idct_*_add`: same as put but adds onto the existing pixels. */
pub fn simple_idct_add(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
  cfg : SimpleIdct,
) -> Unit {
  idct_rows(block, cfg)
  for i = 0; i < 8; i = i + 1 {
    let v = idct_col_values(block, i, cfg)
    for r = 0; r < 8; r = r + 1 {
      let hi = cfg.max_val
      let p = dest[r * stride + i] + v[r]
      dest[r * stride + i] = if p < 0 { 0 } else if p > hi { hi } else { p }
    }
  }
}

///| `ff_simple_idct*`: in-place 8x8 transform, results stored back as int16. */
pub fn simple_idct(block : Array[Int], cfg : SimpleIdct) -> Unit {
  idct_rows(block, cfg)
  for i = 0; i < 8; i = i + 1 {
    let v = idct_col_values(block, i, cfg)
    for k = 0; k < 8; k = k + 1 {
      block[i + k * 8] = i16(v[k])
    }
  }
}

///| `ff_simple_idct_int16_8bit`. */
pub fn ff_simple_idct_int16_8bit(block : Array[Int]) -> Unit {
  simple_idct(block, idct_int16_8bit)
}

///| `ff_simple_idct_int16_10bit`. */
pub fn ff_simple_idct_int16_10bit(block : Array[Int]) -> Unit {
  simple_idct(block, idct_int16_10bit)
}

///| `ff_simple_idct_int16_12bit`. */
pub fn ff_simple_idct_int16_12bit(block : Array[Int]) -> Unit {
  simple_idct(block, idct_int16_12bit)
}

///| `ff_simple_idct_put_int16_8bit`. */
pub fn ff_simple_idct_put_int16_8bit(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
) -> Unit {
  simple_idct_put(dest, stride, block, idct_int16_8bit)
}

///| `ff_simple_idct_add_int16_8bit`. */
pub fn ff_simple_idct_add_int16_8bit(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
) -> Unit {
  simple_idct_add(dest, stride, block, idct_int16_8bit)
}

///| `ff_simple_idct_put_int16_10bit`. */
pub fn ff_simple_idct_put_int16_10bit(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
) -> Unit {
  simple_idct_put(dest, stride, block, idct_int16_10bit)
}

///| `ff_simple_idct_add_int16_10bit`. */
pub fn ff_simple_idct_add_int16_10bit(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
) -> Unit {
  simple_idct_add(dest, stride, block, idct_int16_10bit)
}

///| `ff_simple_idct_put_int16_12bit`. */
pub fn ff_simple_idct_put_int16_12bit(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
) -> Unit {
  simple_idct_put(dest, stride, block, idct_int16_12bit)
}

///| `ff_simple_idct_add_int16_12bit`. */
pub fn ff_simple_idct_add_int16_12bit(
  dest : Array[Int],
  stride : Int,
  block : Array[Int],
) -> Unit {
  simple_idct_add(dest, stride, block, idct_int16_12bit)
}

// ---------------------------------------------------------------------------
// idctdsp.c pixel helpers
// ---------------------------------------------------------------------------

///| `ff_put_pixels_clamped_c`: clip and store an 8x8 block (no add). */
pub fn ff_put_pixels_clamped_c(
  block : Array[Int],
  pixels : Array[Int],
  line_size : Int,
) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      pixels[i * line_size + j] = clip_uint8(block[i * 8 + j])
    }
  }
}

///| `ff_add_pixels_clamped_c`: clip and add an 8x8 block onto the pixels. */
pub fn ff_add_pixels_clamped_c(
  block : Array[Int],
  pixels : Array[Int],
  line_size : Int,
) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      pixels[i * line_size + j] = clip_uint8(pixels[i * line_size + j] + block[i * 8 + j])
    }
  }
}

///| `put_signed_pixels_clamped_c`: store a signed block with +128 bias. */
pub fn put_signed_pixels_clamped_c(
  block : Array[Int],
  pixels : Array[Int],
  line_size : Int,
) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      let b = block[i * 8 + j]
      pixels[i * line_size + j] = if b < -128 {
        0
      } else if b > 127 {
        255
      } else {
        b + 128
      }
    }
  }
}

///|
/// `ff_init_scantable_permutation`: fill the 64-entry IDCT permutation.
/// `perm_type` uses the `enum idct_permutation_type` values
/// (NONE = 0, LIBMPEG2 = 1, TRANSPOSE = 2, PARTTRANS = 3).
/// The x86 special case is omitted (see README "边界原则").
pub fn ff_init_scantable_permutation(perm_type : Int) -> Array[Int] {
  let p : Array[Int] = Array::make(64, 0)
  match perm_type {
    0 => {
      for i = 0; i < 64; i = i + 1 {
        p[i] = i
      }
    }
    1 => {
      for i = 0; i < 64; i = i + 1 {
        p[i] = (i & 0x38) | ((i & 6) >> 1) | ((i & 1) << 2)
      }
    }
    2 => {
      for i = 0; i < 64; i = i + 1 {
        p[i] = ((i & 7) << 3) | (i >> 3)
      }
    }
    3 => {
      for i = 0; i < 64; i = i + 1 {
        p[i] = (i & 0x24) | ((i & 3) << 3) | ((i >> 3) & 3)
      }
    }
    _ => {
      for i = 0; i < 64; i = i + 1 {
        p[i] = i
      }
    }
  }
  p
}

///| `ff_permute_scantable`: `dst[i] = permutation[src[i]]`. */
pub fn ff_permute_scantable(
  dst : Array[Int],
  src : Array[Int],
  permutation : Array[Int],
) -> Unit {
  for i = 0; i < 64; i = i + 1 {
    dst[i] = permutation[src[i]]
  }
}
