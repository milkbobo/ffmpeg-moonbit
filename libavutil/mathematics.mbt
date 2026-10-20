///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/mathematics.c` plus the small
/// integer helpers it relies on (`libavutil/intmath.h`, `libavutil/mathematics.h`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2005-2012
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Out of scope for this slice (not ported): `av_rescale_delta`,
/// `av_add_stable`, `av_bessel_i0`, `av_sat_add64`/`av_clip64` helpers.

///|
/// Rounding modes, mirroring `enum AVRounding` in libavutil/mathematics.h.
pub let av_round_zero : Int32 = 0

///|
pub let av_round_inf : Int32 = 1

///|
pub let av_round_down : Int32 = 2

///|
pub let av_round_up : Int32 = 3

///|
pub let av_round_near_inf : Int32 = 5

///|
pub let av_round_pass_minmax : Int32 = 8192

///|
/// INT64_MAX / INT64_MIN, and the 32-bit bounds used as saturation limits. */
pub let int64_max : Int64 = 0x7FFFFFFFFFFFFFFF

///|
pub let int64_min : Int64 = -9223372036854775808

///|
pub let int_max_i64 : Int64 = 2147483647

///|
/// AV_NOPTS_VALUE == INT64_MIN */
pub let av_nopts_value : Int64 = -9223372036854775808

///|
/// `av_log2`: floor(log2(v)) for v >= 1, port of `ff_log2`/`av_log2`.
pub fn av_log2(v : UInt32) -> Int32 {
  31 - (v | 1).clz()
}

///|
/// `ff_ctzll`: number of trailing zero bits of a 64-bit value.
/// The result is undefined when `v` is 0, exactly as in C.
pub fn ff_ctzll(v : Int64) -> Int32 {
  v.ctz()
}

///|
/// Absolute value helper mirroring `FFABS` for 64-bit values. */
fn abs64(x : Int64) -> Int64 {
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
/// `av_gcd`: Stein's binary GCD algorithm, port of libavutil/mathematics.c.
pub fn av_gcd(a : Int64, b : Int64) -> Int64 {
  if a == 0 {
    return b
  }
  if b == 0 {
    return a
  }
  let za = ff_ctzll(a)
  let zb = ff_ctzll(b)
  let k = if za < zb { za } else { zb }
  let mut u = abs64(a >> za)
  let mut v = abs64(b >> zb)
  while u != v {
    if u > v {
      let t = v
      v = u
      u = t
    }
    v = v - u
    v = v >> ff_ctzll(v)
  }
  u << k
}

///|
/// `av_rescale_rnd`: rescale `a` by `b / c` with the requested rounding mode.
/// Port of libavutil/mathematics.c; the 128-bit intermediate is emulated with
/// a 64x64 -> 128 split multiply followed by a bitwise long division.
pub fn av_rescale_rnd(a : Int64, b : Int64, c : Int64, rnd : Int32) -> Int64 {
  let mode = rnd & av_round_pass_minmax.lnot()
  if c <= 0 || b < 0 || !(mode >= 0 && mode <= 5 && mode != 4) {
    return int64_min
  }
  let mut rnd = rnd
  if (rnd & av_round_pass_minmax) != 0 {
    if a == int64_min || a == int64_max {
      return a
    }
    rnd = rnd - av_round_pass_minmax
  }
  if a < 0 {
    // C: return -(uint64_t)av_rescale_rnd(-FFMAX(a, -INT64_MAX), ...).
    // Note the inner negation of the clamped value, in addition to the outer one.
    let clamped = if a > -int64_max { a } else { -int64_max }
    return -av_rescale_rnd(-clamped, b, c, rnd ^ ((rnd >> 1) & 1))
  }
  let mut r : Int64 = 0
  if rnd == av_round_near_inf {
    r = c / 2
  } else if (rnd & 1) != 0 {
    r = c - 1
  }
  if b <= int_max_i64 && c <= int_max_i64 {
    if a <= int_max_i64 {
      (a * b + r) / c
    } else {
      let ad = a / c
      let a2 = (a % c * b + r) / c
      if ad >= int_max_i64 && b != 0 && ad > (int64_max - a2) / b {
        int64_min
      } else {
        ad * b + a2
      }
    }
  } else {
    let mut a0 : UInt64 = (a & 0xFFFFFFFF).reinterpret_as_uint64()
    let a1 : UInt64 = (a >> 32).reinterpret_as_uint64()
    let b0 : UInt64 = (b & 0xFFFFFFFF).reinterpret_as_uint64()
    let b1 : UInt64 = (b >> 32).reinterpret_as_uint64()
    let mut t1 : UInt64 = a0 * b1 + a1 * b0
    let t1a : UInt64 = t1 << 32
    a0 = a0 * b0 + t1a
    let mut hi : UInt64 = a1 * b1 + (t1 >> 32)
    if a0 < t1a {
      hi = hi + 1
    }
    let ru : UInt64 = r.reinterpret_as_uint64()
    a0 = a0 + ru
    if a0 < ru {
      hi = hi + 1
    }
    let cu : UInt64 = c.reinterpret_as_uint64()
    let mut i = 63
    while i >= 0 {
      hi = hi + hi + ((a0 >> i) & 1)
      t1 = t1 + t1
      if cu <= hi {
        hi = hi - cu
        t1 = t1 + 1
      }
      i = i - 1
    }
    if t1 > int64_max.reinterpret_as_uint64() {
      int64_min
    } else {
      t1.reinterpret_as_int64()
    }
  }
}

///|
/// `av_rescale`: `av_rescale_rnd` with `AV_ROUND_NEAR_INF`. */
pub fn av_rescale(a : Int64, b : Int64, c : Int64) -> Int64 {
  av_rescale_rnd(a, b, c, av_round_near_inf)
}

///|
/// `av_rescale_q_rnd`: rescale `a` from time base `bq` to time base `cq`.
pub fn av_rescale_q_rnd(
  a : Int64,
  bq : AVRational,
  cq : AVRational,
  rnd : Int32,
) -> Int64 {
  let b = bq.num.to_int64() * cq.den.to_int64()
  let c = cq.num.to_int64() * bq.den.to_int64()
  av_rescale_rnd(a, b, c, rnd)
}

///|
/// `av_rescale_q`: `av_rescale_q_rnd` with `AV_ROUND_NEAR_INF`. */
pub fn av_rescale_q(a : Int64, bq : AVRational, cq : AVRational) -> Int64 {
  av_rescale_q_rnd(a, bq, cq, av_round_near_inf)
}

///|
/// `FFABS64U`: absolute value of a signed 64-bit value as an unsigned value. */
fn abs64u(x : Int64) -> UInt64 {
  if x < 0 {
    (-x).reinterpret_as_uint64()
  } else {
    x.reinterpret_as_uint64()
  }
}

///|
/// `av_compare_ts`: compare two timestamps expressed in different time bases.
pub fn av_compare_ts(
  ts_a : Int64,
  tb_a : AVRational,
  ts_b : Int64,
  tb_b : AVRational,
) -> Int32 {
  let a = tb_a.num.to_int64() * tb_b.den.to_int64()
  let b = tb_b.num.to_int64() * tb_a.den.to_int64()
  let mag = abs64u(ts_a) |
    a.reinterpret_as_uint64() |
    abs64u(ts_b) |
    b.reinterpret_as_uint64()
  if mag <= 2147483647 {
    let l = ts_a * a
    let r = ts_b * b
    let gt = if l > r { 1 } else { 0 }
    let lt = if l < r { 1 } else { 0 }
    gt - lt
  } else if av_rescale_rnd(ts_a, a, b, av_round_down) < ts_b {
    -1
  } else if av_rescale_rnd(ts_b, b, a, av_round_down) < ts_a {
    1
  } else {
    0
  }
}

///|
/// `av_compare_mod`: compare two values modulo `mod`, result in [-mod/2, mod/2]. */
pub fn av_compare_mod(a : UInt64, b : UInt64, mod : UInt64) -> Int64 {
  let mut c : UInt64 = (a - b) & (mod - 1)
  if c > mod >> 1 {
    c = c - mod
  }
  c.reinterpret_as_int64()
}

///|
/// `av_bessel_i0` (`libavutil/mathematics.c`): 0th-order modified Bessel
/// function of the first kind, Blair/Edwards minimax rational
/// approximations (via the Boost project). Coefficients batch-extracted
/// from the C source.
let bessel_p1 : Array[Double] = [
  -2.2335582639474375249e+15, -5.5050369673018427753e+14, -3.2940087627407749166e+13,
  -8.4925101247114157499e+11, -1.1912746104985237192e+10, -1.0313066708737980747e+08,
  -5.9545626019847898221e+05, -2.4125195876041896775e+03, -7.0935347449210549190e+00,
  -1.5453977791786851041e-02, -2.5172644670688975051e-05, -3.0517226450451067446e-08,
  -2.6843448573468483278e-11, -1.5982226675653184646e-14, -5.2487866627945699800e-18,
]

///|
let bessel_q1 : Array[Double] = [
  -2.2335582639474375245e+15, 7.8858692566751002988e+12, -1.2207067397808979846e+10,
  1.0377081058062166144e+07, -4.8527560179962773045e+03, 1.0,
]

///|
let bessel_p2 : Array[Double] = [
  -2.2210262233306573296e-04, 1.3067392038106924055e-02, -4.4700805721174453923e-01,
  5.5674518371240761397e+00, -2.3517945679239481621e+01, 3.1611322818701131207e+01,
  -9.6090021968656180000e+00,
]

///|
let bessel_q2 : Array[Double] = [
  -5.5194330231005480228e-04, 3.2547697594819615062e-02, -1.1151759188741312645e+00,
  1.3982595353892851542e+01, -6.0228002066743340583e+01, 8.5539563258012929600e+01,
  -3.1446690275135491500e+01, 1.0,
]

///|
/// `eval_poly`: Horner evaluation highest degree first. */
fn aac_bessel_eval(coeff : Array[Double], x : Double) -> Double {
  let mut sum = coeff[coeff.length() - 1]
  for i = coeff.length() - 2; i >= 0; i = i - 1 {
    sum = sum * x + coeff[i]
  }
  sum
}

///|
pub fn av_bessel_i0(x : Double) -> Double {
  if x == 0.0 {
    return 1.0
  }
  let ax = if x < 0.0 { -x } else { x }
  if ax <= 15.0 {
    let y = ax * ax
    aac_bessel_eval(bessel_p1, y) / aac_bessel_eval(bessel_q1, y)
  } else {
    let y = 1.0 / ax - 1.0 / 15.0
    let r = aac_bessel_eval(bessel_p2, y) / aac_bessel_eval(bessel_q2, y)
    let factor = @math.exp(ax) / ax.sqrt()
    factor * r
  }
}
