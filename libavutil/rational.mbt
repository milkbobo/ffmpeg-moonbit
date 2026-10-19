///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/rational.c` / `rational.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2003
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// The C API writes through `int *dst_num / *dst_den`; here those output
/// parameters become part of the return value (`av_reduce` returns a
/// `(num, den, exact)` tuple).

///|
/// Rational number (pair of numerator and denominator), mirroring `AVRational`.
pub struct AVRational {
  num : Int
  den : Int
}

///|
/// `av_make_q`: build an `AVRational` (not reduced).
pub fn av_make_q(num : Int, den : Int) -> AVRational {
  { num, den }
}

///|
/// `av_cmp_q`: compare two rationals.
/// Returns 0 if equal, 1 if a > b, -1 if a < b, INT_MIN for 0/0 forms.
pub fn av_cmp_q(a : AVRational, b : AVRational) -> Int {
  let tmp = a.num.to_int64() * b.den.to_int64() - b.num.to_int64() * a.den.to_int64()
  if tmp != 0 {
    // ((tmp ^ a.den ^ b.den) >> 63) | 1
    let t = tmp ^ a.den.to_int64() ^ b.den.to_int64()
    ((t >> 63) | 1).to_int()
  } else if b.den != 0 && a.den != 0 {
    0
  } else if a.num != 0 && b.num != 0 {
    (a.num >> 31) - (b.num >> 31)
  } else {
    -2147483648
  }
}

///| `av_q2d`: convert an `AVRational` to a `Double`. */
pub fn av_q2d(a : AVRational) -> Double {
  a.num.to_double() / a.den.to_double()
}

///| `av_inv_q`: invert a rational, i.e. `1 / q`. */
pub fn av_inv_q(q : AVRational) -> AVRational {
  { num: q.den, den: q.num }
}

///|
/// `av_reduce`: reduce a fraction, bounded by `max`.
/// Returns `(dst_num, dst_den, exact)`; `exact` is true when no rounding was needed.
pub fn av_reduce(num : Int64, den : Int64, max : Int64) -> (Int, Int, Bool) {
  let mut a0 : AVRational = { num: 0, den: 1 }
  let mut a1 : AVRational = { num: 1, den: 0 }
  let sign = (num < 0) != (den < 0)
  let g = av_gcd(abs64(num), abs64(den))
  let mut n = num
  let mut d = den
  if g != 0 {
    n = abs64(num) / g
    d = abs64(den) / g
  }
  if n <= max && d <= max {
    a1 = { num: n.to_int(), den: d.to_int() }
    d = 0
  }
  while d != 0 {
    let x = n / d
    let next_den = n - d * x
    let a2n = x * a1.num.to_int64() + a0.num.to_int64()
    let a2d = x * a1.den.to_int64() + a0.den.to_int64()
    if a2n > max || a2d > max {
      let mut xx = x
      if a1.num != 0 {
        xx = (max - a0.num.to_int64()) / a1.num.to_int64()
      }
      if a1.den != 0 {
        let lim = (max - a0.den.to_int64()) / a1.den.to_int64()
        if lim < xx {
          xx = lim
        }
      }
      if d * (2 * xx * a1.den.to_int64() + a0.den.to_int64()) > n * a1.den.to_int64() {
        a1 = {
          num: (xx * a1.num.to_int64() + a0.num.to_int64()).to_int(),
          den: (xx * a1.den.to_int64() + a0.den.to_int64()).to_int(),
        }
      }
      break
    }
    a0 = a1
    a1 = { num: a2n.to_int(), den: a2d.to_int() }
    n = d
    d = next_den
  }
  (if sign { -a1.num } else { a1.num }, a1.den, d == 0)
}

///| `av_mul_q`: `b * c`, reduced with `INT_MAX` bound. */
pub fn av_mul_q(b : AVRational, c : AVRational) -> AVRational {
  let (n, d, _) = av_reduce(
    b.num.to_int64() * c.num.to_int64(),
    b.den.to_int64() * c.den.to_int64(),
    int_max_i64,
  )
  { num: n, den: d }
}

///| `av_div_q`: `b / c`. */
pub fn av_div_q(b : AVRational, c : AVRational) -> AVRational {
  av_mul_q(b, { num: c.den, den: c.num })
}

///| `av_add_q`: `b + c`. */
pub fn av_add_q(b : AVRational, c : AVRational) -> AVRational {
  let (n, d, _) = av_reduce(
    b.num.to_int64() * c.den.to_int64() + c.num.to_int64() * b.den.to_int64(),
    b.den.to_int64() * c.den.to_int64(),
    int_max_i64,
  )
  { num: n, den: d }
}

///| `av_sub_q`: `b - c`. */
pub fn av_sub_q(b : AVRational, c : AVRational) -> AVRational {
  let (n, d, _) = av_reduce(
    b.num.to_int64() * c.den.to_int64() - c.num.to_int64() * b.den.to_int64(),
    b.den.to_int64() * c.den.to_int64(),
    int_max_i64,
  )
  { num: n, den: d }
}

///|
/// `frexp` reimplementation: split `x` into `(m, e)` with `x == m * 2^e`
/// and `0.5 <= |m| < 1`. Subnormals collapse to exponent -1022, which is
/// sufficient for `av_d2q` because the caller clamps the exponent to >= 0.
fn ff_frexp(x : Double) -> (Double, Int) {
  if x == 0.0 || x.is_nan() || x.is_inf() {
    return (x, 0)
  }
  let bits = x.reinterpret_as_uint64()
  let exp_raw = ((bits >> 52) & 0x7FF).to_int()
  let frac = bits & 0xFFFFFFFFFFFFF
  let e = exp_raw - 1022
  let m_bits : UInt64 = 0x3FE0000000000000 | frac
  (m_bits.reinterpret_as_double(), e)
}

///|
/// `av_d2q`: convert a `Double` to the nearest rational with `num, den <= max`.
pub fn av_d2q(d : Double, max : Int) -> AVRational {
  if d.is_nan() {
    return { num: 0, den: 0 }
  }
  if d.abs() > 2147483650.0 {
    return { num: (if d < 0.0 { -1 } else { 1 }), den: 0 }
  }
  let (_, exponent) = ff_frexp(d)
  let exponent = if exponent - 1 > 0 { exponent - 1 } else { 0 }
  let den : Int64 = 1L << (62 - exponent)
  let (n, dd, _) = av_reduce((d * den.to_double() + 0.5).floor().to_int64(), den, max.to_int64())
  { num: n, den: dd }
}

///|
/// `av_gcd_q`: best rational that divides both `a` and `b`, else `def`.
pub fn av_gcd_q(a : AVRational, b : AVRational, max_den : Int, def : AVRational) -> AVRational {
  let gcd = av_gcd(a.den.to_int64(), b.den.to_int64())
  let lcm = (a.den.to_int64() / gcd) * b.den.to_int64()
  if lcm < max_den.to_int64() {
    av_make_q(av_gcd(a.num.to_int64(), b.num.to_int64()).to_int(), lcm.to_int())
  } else {
    def
  }
}

///|
/// `av_q2intfloat`: convert a rational to the IEEE-754 binary32 bit pattern
/// of its value, expressed as an unsigned 32-bit integer.
pub fn av_q2intfloat(q : AVRational) -> UInt {
  let mut num = q.num
  let mut den = q.den
  let mut sign = 0
  if den < 0 {
    den = -den
    num = -num
  }
  if num < 0 {
    num = -num
    sign = 1
  }
  if num == 0 && den == 0 {
    return 0xFFC00000
  }
  if num == 0 {
    return 0
  }
  if den == 0 {
    return 0x7F800000 | (num.reinterpret_as_uint() & 0x80000000)
  }
  let mut shift = 23 + av_log2(den.reinterpret_as_uint()) - av_log2(num.reinterpret_as_uint())
  let mut n : Int64 = 0
  if shift >= 0 {
    n = av_rescale(num.to_int64(), 1L << shift, den.to_int64())
  } else {
    n = av_rescale(num.to_int64(), 1L, den.to_int64() << (-shift))
  }
  shift = shift - (if n >= 16777216L { 1 } else { 0 })
  shift = shift + (if n < 8388608L { 1 } else { 0 })
  if shift >= 0 {
    n = av_rescale(num.to_int64(), 1L << shift, den.to_int64())
  } else {
    n = av_rescale(num.to_int64(), 1L, den.to_int64() << (-shift))
  }
  (sign.reinterpret_as_uint() << 31) |
  ((150 - shift).reinterpret_as_uint() << 23) |
  (n.reinterpret_as_uint64().to_uint() - 0x800000)
}
