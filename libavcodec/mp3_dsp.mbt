///|
/// Fixed-point MPEG Audio Layer III DSP (FFmpeg 9.0.2):
/// `libavcodec/mpegaudiodsp_template.c` (fixed path, `USE_FLOATS = 0`),
/// `libavcodec/mpegaudiodsp.c` (MDCT/synthesis window tables) and
/// `libavcodec/dct32_template.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Arithmetic notes:
///   * `INTFLOAT` is `int`, `SUINTFLOAT` is `unsigned` in the C fixed path.
///     MoonBit `Int` is a 32-bit wrapping integer, so all signed/unsigned bit
///     patterns are represented as `Int` and the C macros map to `mulh`/
///     `mull` helpers on 64-bit intermediate products.
///   * The window/table generators use the same `Double` formulas as the C
///     (`FIXHR`/`FIXR`), with a local `frexp` and round-to-nearest-even.

///|
/// `FRAC_BITS`. */
let frac_bits : Int32 = 23

///|
/// `FRAC_ONE = 1 << FRAC_BITS`. */
let frac_one : Int32 = 8388608

///|
/// `WFRAC_BITS`. */
let wfrac_bits : Int32 = 16

///|
/// `OUT_SHIFT = WFRAC_BITS + FRAC_BITS - 15`. */
let out_shift : Int32 = wfrac_bits + frac_bits - 15

///|
/// `SBLIMIT`. */
let sblimit : Int32 = 32

///|
/// `MDCT_BUF_SIZE`. */
let mdct_buf_size : Int32 = 36

///|
/// `IMDCT_SCALAR`. */
let imdct_scalar : Double = 1.759

///|
/// `FIXHR` for the fixed decoder. */
fn fixhr(x : Double) -> Int32 {
  (x * 4294967296.0 + 0.5).to_int64().to_int()
}

///|
/// `FIXR`. */
fn fixr(x : Double) -> Int32 {
  (x * 8388608.0 + 0.5).to_int64().to_int()
}

///|
/// `MUL64`. */
fn mul64(a : Int32, b : Int32) -> Int64 {
  a.to_int64() * b.to_int64()
}

///|
/// `MULH`: high 32 bits of the signed 64-bit product. */
fn mulh(a : Int32, b : Int32) -> Int32 {
  (mul64(a, b) >> 32).to_int()
}

///|
/// `MULL(a, b, s) = (MUL64(a,b) >> s)`. */
fn mull(a : Int32, b : Int32, s : Int32) -> Int32 {
  (mul64(a, b) >> s).to_int()
}

///|
/// `MULH3(x, y, s) = MULH(s*x, y)`. */
fn mulh3(x : Int32, y : Int32, s : Int32) -> Int32 {
  mulh(s * x, y)
}

///|
/// `MULLx(x, y, s) = MULL((int)x, y, s)`. */
fn mullx(x : Int32, y : Int32, s : Int32) -> Int32 {
  mull(x, y, s)
}

///|
/// `SHR(a, b)` in the fixed path (`((int)a) >> b`). */
fn shr(a : Int32, b : Int32) -> Int32 {
  a >> b
}

///|
/// `av_clip_int16`. */
fn clip_int16(v : Int32) -> Int32 {
  if v < -32768 {
    -32768
  } else if v > 32767 {
    32767
  } else {
    v
  }
}

///|
/// `round_sample` from the fixed synthesis filter: returns (sample, remainder). */
fn round_sample(sum : Int64) -> (Int32, Int64) {
  let v = (sum >> out_shift).to_int()
  (clip_int16(v), sum & ((1L << out_shift) - 1L))
}

///|
/// `exp2_lut[4]` from `mpegaudio_tablegen.h`. */
let exp2_lut : Array[Double] = [
  1.0, 1.18920711500272106672, 1.4142135623730950488, 1.68179283050742908606,
]

///|
/// `2^(e/4)` without relying on a libm `exp2`. */
fn exp2_quarter(e : Int32) -> Double {
  let mut q = e / 4
  let mut r = e % 4
  if r < 0 {
    q = q - 1
    r = r + 4
  }
  @math.pow(2.0, q.to_double()) * exp2_lut[r]
}

///|
/// Round to nearest, ties to even (C `llrint` under the default mode). */
fn llrint(x : Double) -> Int64 {
  let f = @math.floor(x)
  let frac = x - f
  let fi = f.to_int64()
  if frac > 0.5 || (frac == 0.5 && (fi & 1L) != 0L) {
    fi + 1L
  } else {
    fi
  }
}

///|
/// `frexp`: returns (mantissa in [0.5,1), exponent) for x > 0. */
fn frexp_pos(x : Double) -> (Double, Int32) {
  if x == 0.0 {
    return (0.0, 0)
  }
  let mut m = x
  let mut e = 0
  while m >= 1.0 {
    m = m * 0.5
    e = e + 1
  }
  while m < 0.5 {
    m = m * 2.0
    e = e - 1
  }
  (m, e)
}

///|
/// `ff_table_4_3_exp` / `ff_table_4_3_value` from
/// `mpegaudiodec_common_tablegen.h` (`TABLE_4_3_SIZE = (8191+16)*4`).
pub struct Table43 {
  exp : Array[Int32]
  value : Array[UInt32]
}

///|
/// Build the `4/3` power table exactly as the C runtime generator. */
fn make_table_4_3() -> Table43 {
  let n = (8191 + 16) * 4
  let exp = Array::make(n, 0)
  let value = Array::make(n, 0U)
  let mut pow43_val = 0.0
  for i = 1; i < n; i = i + 1 {
    let v = (i / 4).to_double()
    if (i & 3) == 0 {
      pow43_val = v / imdct_scalar * @math.cbrt(v)
    }
    let f = pow43_val * exp2_lut[i & 3]
    let (fm, e0) = frexp_pos(f)
    let m = llrint(fm * 2147483648.0)
    let e = e0 + frac_bits - 31 + 5 - 100
    value[i] = (m & 0xFFFFFFFFL).to_int().reinterpret_as_uint()
    exp[i] = -e
  }
  { exp, value, }
}

///|
/// The single global table pair (the C initializes it once). */
let table_4_3 : Table43 = make_table_4_3()

///|
/// `ff_table_4_3_exp` / `ff_table_4_3_value` accessors for the decoder. */
pub fn table_4_3_exp(i : Int32) -> Int32 {
  table_4_3.exp[i]
}

///|
/// Raw `uint32_t` value of the `4/3` table. */
pub fn table_4_3_value(i : Int32) -> UInt32 {
  table_4_3.value[i]
}

///|
/// `expval_table[512][16]` and `exp_table[512]` from `mpegaudio_tablegen.h`. */
pub struct ExpTables {
  exp : Array[Int32]
  expval : Array[Array[Int32]]
}

///|
/// Build the `value^(4/3)` / exponent tables. */
fn make_exp_tables() -> ExpTables {
  let exp = Array::make(512, 0)
  let expval : Array[Array[Int32]] = []
  let pow43_lut = Array::make(16, 0.0)
  for i = 0; i < 16; i = i + 1 {
    pow43_lut[i] = i.to_double() * @math.cbrt(i.to_double())
  }
  let mut exp2_base = 2.11758236813575084767080625169910490512847900390625e-22
  for exponent = 0; exponent < 512; exponent = exponent + 1 {
    if exponent != 0 && (exponent & 3) == 0 {
      exp2_base = exp2_base * 2.0
    }
    let exp2_val = exp2_base * exp2_lut[exponent & 3] / imdct_scalar
    let row : Array[Int32] = Array::make(16, 0)
    for value = 0; value < 16; value = value + 1 {
      let f = pow43_lut[value] * exp2_val
      row[value] = if f < 4294967295.0 {
        (llrint(f) & 0xFFFFFFFFL).to_int()
      } else {
        -1 // 0xFFFFFFFF as a 32-bit bit pattern
      }
    }
    expval.push(row)
    exp[exponent] = row[1]
  }
  { exp, expval, }
}

///|
/// Global `expval_table` / `exp_table`. */
let exp_tables : ExpTables = make_exp_tables()

///|
/// `expval_table[exp][value]`. */
pub fn expval_table(exp : Int32, value : Int32) -> Int32 {
  exp_tables.expval[exp][value]
}

///|
/// `exp_table[exp]`. */
pub fn exp_table(exp : Int32) -> Int32 {
  exp_tables.exp[exp]
}

///|
/// `l3_unscale`: value^(4/3) * 2^(exponent/4), normalized to `FRAC_BITS`.
pub fn l3_unscale(value : Int32, exponent : Int32) -> Int32 {
  let idx = 4 * value + (exponent & 3)
  let mut e = table_4_3_exp(idx)
  let mut m = table_4_3_value(idx)
  e = e - (exponent >> 2)
  if e > 31 {
    return 0
  }
  if e < 0 {
    return 0
  }
  let mut add = 1U << e
  add = add >> 1
  m = (m + add) >> e
  m.reinterpret_as_int()
}

// ---------------------------------------------------------------------------
// IMDCT / synthesis windows
// ---------------------------------------------------------------------------

///|
/// `sum(cos(pi*i/18))` constants from mpegaudiodsp_template.c. */
let cos_c1 : Int32 = fixhr(0.98480775301220805936 / 2.0)

///|
let cos_c2 : Int32 = fixhr(0.93969262078590838405 / 2.0)

///|
let cos_c3 : Int32 = fixhr(0.86602540378443864676 / 2.0)

///|
let cos_c4 : Int32 = fixhr(0.76604444311897803520 / 2.0)

///|
let cos_c5 : Int32 = fixhr(0.64278760968653932632 / 2.0)

///|
let cos_c7 : Int32 = fixhr(0.34202014332566873304 / 2.0)

///|
let cos_c8 : Int32 = fixhr(0.17364817766693034885 / 2.0)

///|
/// The `C3..C6` constants used by the 12-point IMDCT (they differ from the
/// 36-point IMDCT's C4/C5/C6 in mpegaudiodsp_template.c).
let imdct12_c3 : Int32 = fixhr(0.86602540378443864676 / 2.0)

///|
let imdct12_c4 : Int32 = fixhr(0.70710678118654752439 / 2.0)

///|
let imdct12_c5 : Int32 = fixhr(0.51763809020504152469 / 2.0)

///|
let imdct12_c6 : Int32 = fixhr(1.93185165257813657349 / 4.0)

///|
/// `icos36[9]` (FIXR). */
let icos36 : Array[Int32] = [
  fixr(0.50190991877167369479),
  fixr(0.51763809020504152469),
  fixr(0.55168895948124587824),
  fixr(0.61038729438072803416),
  fixr(0.70710678118654752439),
  fixr(0.87172339781054900991),
  fixr(1.18310079157624925896),
  fixr(1.93185165257813657349),
  fixr(5.73685662283492756461),
]

///|
/// `icos36h[9]` (FIXHR; the C leaves the last entry commented out). */
let icos36h : Array[Int32] = [
  fixhr(0.50190991877167369479 / 2.0),
  fixhr(0.51763809020504152469 / 2.0),
  fixhr(0.55168895948124587824 / 2.0),
  fixhr(0.61038729438072803416 / 2.0),
  fixhr(0.70710678118654752439 / 2.0),
  fixhr(0.87172339781054900991 / 2.0),
  fixhr(1.18310079157624925896 / 4.0),
  fixhr(1.93185165257813657349 / 4.0),
  0,
]

///|
/// `ff_mdct_win_fixed[8][36]`. */
let mdct_win : Array[Array[Int32]] = make_mdct_win()

///|
/// Build `ff_mdct_win_fixed`. */
fn make_mdct_win() -> Array[Array[Int32]] {
  let win : Array[Array[Int32]] = [
    Array::make(36, 0),
    Array::make(36, 0),
    Array::make(36, 0),
    Array::make(36, 0),
    Array::make(36, 0),
    Array::make(36, 0),
    Array::make(36, 0),
    Array::make(36, 0),
  ]
  for i = 0; i < 36; i = i + 1 {
    for j = 0; j < 4; j = j + 1 {
      if j == 2 && i % 3 != 1 {
        continue
      }
      let mut d = @math.sin(@math.PI * (i.to_double() + 0.5) / 36.0)
      if j == 1 {
        if i >= 30 {
          d = 0.0
        } else if i >= 24 {
          d = @math.sin(@math.PI * (i.to_double() - 18.0 + 0.5) / 12.0)
        } else if i >= 18 {
          d = 1.0
        }
      } else if j == 3 {
        if i < 6 {
          d = 0.0
        } else if i < 12 {
          d = @math.sin(@math.PI * (i.to_double() - 6.0 + 0.5) / 12.0)
        } else if i < 18 {
          d = 1.0
        }
      }
      d = d *
        0.5 *
        imdct_scalar /
        @math.cos(@math.PI * (2.0 * i.to_double() + 19.0) / 72.0)
      let v = fixhr(d / 32.0)
      if j == 2 {
        win[2][i / 3] = v
      } else {
        win[j][i] = v
      }
    }
  }
  for j = 0; j < 4; j = j + 1 {
    let mut i = 0
    while i < 36 {
      win[j + 4][i] = win[j][i]
      win[j + 4][i + 1] = -win[j][i + 1]
      i = i + 2
    }
  }
  win
}

///|
/// `ff_mpa_synth_window_fixed[768]`. */
let synth_window : Array[Int32] = make_synth_window()

///|
/// Build the 768-entry synthesis window from `ff_mpa_enwindow`. */
fn make_synth_window() -> Array[Int32] {
  let w = Array::make(768, 0)
  for i = 0; i < 257; i = i + 1 {
    let v = mpa_enwindow[i]
    w[i] = v
    let mut vv = v
    if (i & 63) != 0 {
      vv = -v
    }
    if i != 0 {
      w[512 - i] = vv
    }
  }
  for i = 0; i < 8; i = i + 1 {
    for j = 0; j < 16; j = j + 1 {
      w[512 + 16 * i + j] = w[64 * i + 32 - j]
      w[512 + 128 + 16 * i + j] = w[64 * i + 48 - j]
    }
  }
  w
}

///|
/// `is_table[2][7]` from mpegaudiodec_fixed.c. */
let is_table : Array[Array[Int32]] = [
  [0x000000, 0x1B0CB1, 0x2ED9EC, 0x400000, 0x512614, 0x64F34F, 0x800000],
  [0x800000, 0x64F34F, 0x512614, 0x400000, 0x2ED9EC, 0x1B0CB1, 0x000000],
]

///|
/// `is_table_lsf[2][2][16]`. */
let is_table_lsf : Array[Array[Array[Int32]]] = make_is_table_lsf()

///|
/// Build `is_table_lsf` exactly as decode_init_static. */
fn make_is_table_lsf() -> Array[Array[Array[Int32]]] {
  let t : Array[Array[Array[Int32]]] = [
    [Array::make(16, 0), Array::make(16, 0)],
    [Array::make(16, 0), Array::make(16, 0)],
  ]
  for i = 0; i < 16; i = i + 1 {
    for j = 0; j < 2; j = j + 1 {
      let e = -(j + 1) * ((i + 1) >> 1)
      let f = exp2_quarter(e)
      let k = i & 1
      t[j][k ^ 1][i] = fixr(f)
      t[j][k][i] = fixr(1.0)
    }
  }
  t
}

///|
/// `csa_table[8][4]` (fixed). */
let csa_table : Array[Array[Int32]] = [
  [0x36E129F8, 0xDF128056, 0x15F3AA4E, 0xA831565E],
  [0x386E75F2, 0xE1CF24A5, 0x1A3D9A97, 0xA960AEB3],
  [0x3CC6B73A, 0xEBF19FA6, 0x28B856E0, 0xAF2AE86C],
  [0x3EEEA054, 0xF45B88BC, 0x334A2910, 0xB56CE868],
  [0x3FB6905C, 0xF9F27F18, 0x39A90F74, 0xBA3BEEBC],
  [0x3FF23F20, 0xFD60D1E4, 0x3D531104, 0xBD6E92C4],
  [0x3FFE5932, 0xFF175EE4, 0x3F15B816, 0xBF1905B2],
  [0x3FFFE34A, 0xFFC3612F, 0x3FC34479, 0xBFC37DE5],
]

// ---------------------------------------------------------------------------
// IMDCT36 / IMDCT12
// ---------------------------------------------------------------------------

///|
/// `imdct12` from mpegaudiodec_template.c. */
fn imdct12(out : Array[Int32], src : Array[Int32], in_off : Int32) -> Unit {
  let mut in0 = src[in_off + 0 * 3]
  let mut in1 = src[in_off + 1 * 3] + src[in_off + 0 * 3]
  let mut in2 = src[in_off + 2 * 3] + src[in_off + 1 * 3]
  let mut in3 = src[in_off + 3 * 3] + src[in_off + 2 * 3]
  let mut in4 = src[in_off + 4 * 3] + src[in_off + 3 * 3]
  let mut in5 = src[in_off + 5 * 3] + src[in_off + 4 * 3]
  in5 = in5 + in3
  in3 = in3 + in1
  in2 = mulh3(in2, imdct12_c3, 2)
  in3 = mulh3(in3, imdct12_c3, 4)
  let t1 = in0 - in4
  let t2 = mulh3(in1 - in5, imdct12_c4, 2)
  out[7] = t1 + t2
  out[10] = t1 + t2
  out[1] = t1 - t2
  out[4] = t1 - t2
  in0 = in0 + shr(in4, 1)
  in4 = in0 + in2
  in5 = in5 + 2 * in1
  in1 = mulh3(in5 + in3, imdct12_c5, 1)
  out[8] = in4 + in1
  out[9] = in4 + in1
  out[2] = in4 - in1
  out[3] = in4 - in1
  in0 = in0 - in2
  in5 = mulh3(in5 - in3, imdct12_c6, 2)
  out[0] = in0 - in5
  out[5] = in0 - in5
  out[6] = in0 + in5
  out[11] = in0 + in5
}

///|
/// `imdct36` from mpegaudiodsp_template.c. */
fn imdct36(
  out : Array[Int32],
  out_off : Int32,
  buf : Array[Int32],
  buf_off : Int32,
  src : Array[Int32],
  in_off : Int32,
  win : Array[Int32],
) -> Unit {
  // The C modifies `in` in place (the accumulation is part of the transform).
  let mut i = 17
  while i >= 1 {
    src[in_off + i] = src[in_off + i] + src[in_off + i - 1]
    i = i - 1
  }
  i = 17
  while i >= 3 {
    src[in_off + i] = src[in_off + i] + src[in_off + i - 2]
    i = i - 2
  }
  let tmp = Array::make(18, 0)
  for j = 0; j < 2; j = j + 1 {
    let t2 = src[in_off + 2 * 4 + j] +
      src[in_off + 2 * 8 + j] -
      src[in_off + 2 * 2 + j]
    let t3 = src[in_off + 2 * 0 + j] + shr(src[in_off + 2 * 6 + j], 1)
    let t1 = src[in_off + 2 * 0 + j] - src[in_off + 2 * 6 + j]
    tmp[6 + j] = t1 - shr(t2, 1)
    tmp[16 + j] = t1 + t2
    let t0 = mulh3(src[in_off + 2 * 2 + j] + src[in_off + 2 * 4 + j], cos_c2, 2)
    let t1b = mulh3(
      src[in_off + 2 * 4 + j] - src[in_off + 2 * 8 + j],
      -2 * cos_c8,
      1,
    )
    let t2b = mulh3(
      src[in_off + 2 * 2 + j] + src[in_off + 2 * 8 + j],
      -cos_c4,
      2,
    )
    tmp[10 + j] = t3 - t0 - t2b
    tmp[2 + j] = t3 + t0 + t1b
    tmp[14 + j] = t3 + t2b - t1b
    tmp[4 + j] = mulh3(
      src[in_off + 2 * 5 + j] +
      src[in_off + 2 * 7 + j] -
      src[in_off + 2 * 1 + j],
      -cos_c3,
      2,
    )
    let t2c = mulh3(
      src[in_off + 2 * 1 + j] + src[in_off + 2 * 5 + j],
      cos_c1,
      2,
    )
    let t3c = mulh3(
      src[in_off + 2 * 5 + j] - src[in_off + 2 * 7 + j],
      -2 * cos_c7,
      1,
    )
    let t0c = mulh3(src[in_off + 2 * 3 + j], cos_c3, 2)
    let t1c = mulh3(
      src[in_off + 2 * 1 + j] + src[in_off + 2 * 7 + j],
      -cos_c5,
      2,
    )
    tmp[0 + j] = t2c + t3c + t0c
    tmp[12 + j] = t2c + t1c - t0c
    tmp[8 + j] = t3c - t1c - t0c
  }
  let mut idx = 0
  for j = 0; j < 4; j = j + 1 {
    let t0 = tmp[idx]
    let t1 = tmp[idx + 2]
    let s0 = t1 + t0
    let s2 = t1 - t0
    let t2 = tmp[idx + 1]
    let t3 = tmp[idx + 3]
    let s1 = mulh3(t3 + t2, icos36h[j], 2)
    let s3 = mullx(t3 - t2, icos36[8 - j], frac_bits)
    let mut t0b = s0 + s1
    let mut t1b = s0 - s1
    out[out_off + (9 + j) * sblimit] = mulh3(t1b, win[9 + j], 1) +
      buf[buf_off + 4 * (9 + j)]
    out[out_off + (8 - j) * sblimit] = mulh3(t1b, win[8 - j], 1) +
      buf[buf_off + 4 * (8 - j)]
    buf[buf_off + 4 * (9 + j)] = mulh3(t0b, win[mdct_buf_size / 2 + 9 + j], 1)
    buf[buf_off + 4 * (8 - j)] = mulh3(t0b, win[mdct_buf_size / 2 + 8 - j], 1)
    t0b = s2 + s3
    t1b = s2 - s3
    out[out_off + (9 + 8 - j) * sblimit] = mulh3(t1b, win[9 + 8 - j], 1) +
      buf[buf_off + 4 * (9 + 8 - j)]
    out[out_off + j * sblimit] = mulh3(t1b, win[j], 1) + buf[buf_off + 4 * j]
    buf[buf_off + 4 * (9 + 8 - j)] = mulh3(
      t0b,
      win[mdct_buf_size / 2 + 9 + 8 - j],
      1,
    )
    buf[buf_off + 4 * j] = mulh3(t0b, win[mdct_buf_size / 2 + j], 1)
    idx = idx + 4
  }
  let s0 = tmp[16]
  let s1 = mulh3(tmp[17], icos36h[4], 2)
  let t0 = s0 + s1
  let t1 = s0 - s1
  out[out_off + (9 + 4) * sblimit] = mulh3(t1, win[9 + 4], 1) +
    buf[buf_off + 4 * (9 + 4)]
  out[out_off + (8 - 4) * sblimit] = mulh3(t1, win[8 - 4], 1) +
    buf[buf_off + 4 * (8 - 4)]
  buf[buf_off + 4 * (9 + 4)] = mulh3(t0, win[mdct_buf_size / 2 + 9 + 4], 1)
  buf[buf_off + 4 * (8 - 4)] = mulh3(t0, win[mdct_buf_size / 2 + 8 - 4], 1)
}

// ---------------------------------------------------------------------------
// 32-point DCT and synthesis filter
// ---------------------------------------------------------------------------

///|
/// BF helper (`BF(a,b,c,s)`). */
fn bf(v : Array[Int32], a : Int32, b : Int32, c : Int32, s : Int32) -> Unit {
  let t0 = v[a] + v[b]
  let t1 = v[a] - v[b]
  v[a] = t0
  v[b] = mulh3(t1, c, 1 << s)
}

///|
/// BF0 helper (`BF0(a,b,c,s)`). */
fn bf0(
  v : Array[Int32],
  tab : Array[Int32],
  a : Int32,
  b : Int32,
  c : Int32,
  s : Int32,
) -> Unit {
  let t0 = tab[a] + tab[b]
  let t1 = tab[a] - tab[b]
  v[a] = t0
  v[b] = mulh3(t1, c, 1 << s)
}

///|
/// BF1 helper. */
fn bf1(v : Array[Int32], a : Int32, b : Int32, c : Int32, d : Int32) -> Unit {
  bf(v, a, b, 0x5A82799A, 1) // COS4_0 = FIXHR(sqrt(1/2)/2)
  bf(v, c, d, -0x5A82799A, 1)
  v[c] = v[c] + v[d]
}

///|
/// BF2 helper. */
fn bf2(v : Array[Int32], a : Int32, b : Int32, c : Int32, d : Int32) -> Unit {
  bf(v, a, b, 0x5A82799A, 1)
  bf(v, c, d, -0x5A82799A, 1)
  v[c] = v[c] + v[d]
  v[a] = v[a] + v[c]
  v[c] = v[c] + v[b]
  v[b] = v[b] + v[d]
}

///|
/// `ff_dct32_fixed`: DCT of 32 subband samples. */
pub fn dct32(
  out : Array[Int32],
  out_off : Int32,
  tab : Array[Int32],
  tab_off : Int32,
) -> Unit {
  let v = Array::make(32, 0)
  let t = Array::make(32, 0)
  for i = 0; i < 32; i = i + 1 {
    t[i] = tab[tab_off + i]
  }
  // Constants from dct32_template.c (COSx_y = FIXHR(cos(...)/2^k)).
  let c = dct32_consts
  bf0(v, t, 0, 31, c[0], 1)
  bf0(v, t, 15, 16, c[15], 5)
  bf(v, 0, 15, c[16], 1)
  bf(v, 16, 31, -c[16], 1)
  bf0(v, t, 7, 24, c[7], 1)
  bf0(v, t, 8, 23, c[8], 1)
  bf(v, 7, 8, c[23], 4)
  bf(v, 23, 24, -c[23], 4)
  bf(v, 0, 7, c[24], 1)
  bf(v, 8, 15, -c[24], 1)
  bf(v, 16, 23, c[24], 1)
  bf(v, 24, 31, -c[24], 1)
  bf0(v, t, 3, 28, c[3], 1)
  bf0(v, t, 12, 19, c[12], 2)
  bf(v, 3, 12, c[19], 1)
  bf(v, 19, 28, -c[19], 1)
  bf0(v, t, 4, 27, c[4], 1)
  bf0(v, t, 11, 20, c[11], 2)
  bf(v, 4, 11, c[20], 1)
  bf(v, 20, 27, -c[20], 1)
  bf(v, 3, 4, c[27], 3)
  bf(v, 11, 12, -c[27], 3)
  bf(v, 19, 20, c[27], 3)
  bf(v, 27, 28, -c[27], 3)
  bf(v, 0, 3, c[28], 1)
  bf(v, 4, 7, -c[28], 1)
  bf(v, 8, 11, c[28], 1)
  bf(v, 12, 15, -c[28], 1)
  bf(v, 16, 19, c[28], 1)
  bf(v, 20, 23, -c[28], 1)
  bf(v, 24, 27, c[28], 1)
  bf(v, 28, 31, -c[28], 1)
  bf0(v, t, 1, 30, c[1], 1)
  bf0(v, t, 14, 17, c[14], 3)
  bf(v, 1, 14, c[17], 1)
  bf(v, 17, 30, -c[17], 1)
  bf0(v, t, 6, 25, c[6], 1)
  bf0(v, t, 9, 22, c[9], 1)
  bf(v, 6, 9, c[22], 2)
  bf(v, 22, 25, -c[22], 2)
  bf(v, 1, 6, c[25], 1)
  bf(v, 9, 14, -c[25], 1)
  bf(v, 17, 22, c[25], 1)
  bf(v, 25, 30, -c[25], 1)
  bf0(v, t, 2, 29, c[2], 1)
  bf0(v, t, 13, 18, c[13], 3)
  bf(v, 2, 13, c[18], 1)
  bf(v, 18, 29, -c[18], 1)
  bf0(v, t, 5, 26, c[5], 1)
  bf0(v, t, 10, 21, c[10], 1)
  bf(v, 5, 10, c[21], 2)
  bf(v, 21, 26, -c[21], 2)
  bf(v, 2, 5, c[26], 1)
  bf(v, 10, 13, -c[26], 1)
  bf(v, 18, 21, c[26], 1)
  bf(v, 26, 29, -c[26], 1)
  bf(v, 1, 2, c[29], 2)
  bf(v, 5, 6, -c[29], 2)
  bf(v, 9, 10, c[29], 2)
  bf(v, 13, 14, -c[29], 2)
  bf(v, 17, 18, c[29], 2)
  bf(v, 21, 22, -c[29], 2)
  bf(v, 25, 26, c[29], 2)
  bf(v, 29, 30, -c[29], 2)
  bf1(v, 0, 1, 2, 3)
  bf2(v, 4, 5, 6, 7)
  bf1(v, 8, 9, 10, 11)
  bf2(v, 12, 13, 14, 15)
  bf1(v, 16, 17, 18, 19)
  bf2(v, 20, 21, 22, 23)
  bf1(v, 24, 25, 26, 27)
  bf2(v, 28, 29, 30, 31)
  v[8] = v[8] + v[12]
  v[12] = v[12] + v[10]
  v[10] = v[10] + v[14]
  v[14] = v[14] + v[9]
  v[9] = v[9] + v[13]
  v[13] = v[13] + v[11]
  v[11] = v[11] + v[15]
  out[out_off + 0] = v[0]
  out[out_off + 16] = v[1]
  out[out_off + 8] = v[2]
  out[out_off + 24] = v[3]
  out[out_off + 4] = v[4]
  out[out_off + 20] = v[5]
  out[out_off + 12] = v[6]
  out[out_off + 28] = v[7]
  out[out_off + 2] = v[8]
  out[out_off + 18] = v[9]
  out[out_off + 10] = v[10]
  out[out_off + 26] = v[11]
  out[out_off + 6] = v[12]
  out[out_off + 22] = v[13]
  out[out_off + 14] = v[14]
  out[out_off + 30] = v[15]
  v[24] = v[24] + v[28]
  v[28] = v[28] + v[26]
  v[26] = v[26] + v[30]
  v[30] = v[30] + v[25]
  v[25] = v[25] + v[29]
  v[29] = v[29] + v[27]
  v[27] = v[27] + v[31]
  out[out_off + 1] = v[16] + v[24]
  out[out_off + 17] = v[17] + v[25]
  out[out_off + 9] = v[18] + v[26]
  out[out_off + 25] = v[19] + v[27]
  out[out_off + 5] = v[20] + v[28]
  out[out_off + 21] = v[21] + v[29]
  out[out_off + 13] = v[22] + v[30]
  out[out_off + 29] = v[23] + v[31]
  out[out_off + 3] = v[24] + v[20]
  out[out_off + 19] = v[25] + v[21]
  out[out_off + 11] = v[26] + v[22]
  out[out_off + 27] = v[27] + v[23]
  out[out_off + 7] = v[28] + v[18]
  out[out_off + 23] = v[29] + v[19]
  out[out_off + 15] = v[30] + v[17]
  out[out_off + 31] = v[31]
}

///|
/// DCT32 constants indexed by the `COSx_y` names above. */
let dct32_consts : Array[Int32] = [
  fixhr(0.50060299823519630134 / 2.0),
  fixhr(0.50547095989754365998 / 2.0),
  fixhr(0.51544730992262454697 / 2.0),
  fixhr(0.53104259108978417447 / 2.0),
  fixhr(0.55310389603444452782 / 2.0),
  fixhr(0.58293496820613387367 / 2.0),
  fixhr(0.62250412303566481615 / 2.0),
  fixhr(0.67480834145500574602 / 2.0),
  fixhr(0.74453627100229844977 / 2.0),
  fixhr(0.83934964541552703873 / 2.0),
  fixhr(0.97256823786196069369 / 2.0),
  fixhr(1.16943993343288495515 / 4.0),
  fixhr(1.48416461631416627724 / 4.0),
  fixhr(2.05778100995341155085 / 8.0),
  fixhr(3.40760841846871878570 / 8.0),
  fixhr(10.19000812354805681150 / 32.0),
  fixhr(0.50241928618815570551 / 2.0),
  fixhr(0.52249861493968888062 / 2.0),
  fixhr(0.56694403481635770368 / 2.0),
  fixhr(0.64682178335999012954 / 2.0),
  fixhr(0.78815462345125022473 / 2.0),
  fixhr(1.06067768599034747134 / 4.0),
  fixhr(1.72244709823833392782 / 4.0),
  fixhr(5.10114861868916385802 / 16.0),
  fixhr(0.50979557910415916894 / 2.0),
  fixhr(0.60134488693504528054 / 2.0),
  fixhr(0.89997622313641570463 / 2.0),
  fixhr(2.56291544774150617881 / 8.0),
  fixhr(0.54119610014619698439 / 2.0),
  fixhr(1.30656296487637652785 / 4.0),
  fixhr(0.70710678118654752439 / 2.0),
]

///|
/// `ff_mpadsp_apply_window_fixed` (32 output samples at `incr` stride). */
pub fn apply_window(
  synth_buf : Array[Int32],
  offset : Int32,
  window : Array[Int32],
  dither : Int32,
  samples : Array[Int32],
  sample_base : Int32,
  incr : Int32,
) -> Int32 {
  // memcpy(synth_buf + 512, synth_buf, 32 * sizeof)
  for i = 0; i < 32; i = i + 1 {
    synth_buf[offset + 512 + i] = synth_buf[offset + i]
  }
  let mut sum : Int64 = dither.to_int64()
  let mut sum2 : Int64 = 0
  let mut samples2 = sample_base + 31 * incr
  let mut w = 0
  let mut w2 = 31
  let mut p = offset + 16
  // SUM8(MACS, sum, w, p)
  for k = 0; k < 8; k = k + 1 {
    sum = sum + mul64(window[w + k * 64], synth_buf[p + k * 64])
  }
  p = offset + 48
  for k = 0; k < 8; k = k + 1 {
    sum = sum - mul64(window[w + 32 + k * 64], synth_buf[p + k * 64])
  }
  let (s0, r0) = round_sample(sum)
  samples[sample_base] = s0
  sum = r0
  let mut sample_pos = sample_base + incr
  w = w + 1
  for j = 1; j < 16; j = j + 1 {
    sum2 = 0
    p = offset + 16 + j
    for k = 0; k < 8; k = k + 1 {
      let tmp = synth_buf[p + k * 64]
      sum = sum + mul64(window[w + k * 64], tmp)
      sum2 = sum2 - mul64(window[w2 + k * 64], tmp)
    }
    p = offset + 48 - j
    for k = 0; k < 8; k = k + 1 {
      let tmp = synth_buf[p + k * 64]
      sum = sum - mul64(window[w + 32 + k * 64], tmp)
      sum2 = sum2 - mul64(window[w2 + 32 + k * 64], tmp)
    }
    let (a, ra) = round_sample(sum)
    samples[sample_pos] = a
    sample_pos = sample_pos + incr
    sum = ra + sum2
    let (b, rb) = round_sample(sum)
    samples[samples2] = b
    sum = rb
    samples2 = samples2 - incr
    w = w + 1
    w2 = w2 - 1
  }
  p = offset + 32
  for k = 0; k < 8; k = k + 1 {
    sum = sum - mul64(window[w + 32 + k * 64], synth_buf[p + k * 64])
  }
  let (last, remainder) = round_sample(sum)
  samples[sample_pos] = last
  remainder.to_int()
}
