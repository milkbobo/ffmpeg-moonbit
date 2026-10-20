///|
/// Whitebox tests for the `rational` port.
/// Expected values come from libavutil/tests/rational.c (the `unit_mul_q`
/// and `unit_add_q` tables) and from the documented behaviour of
/// `av_q2intfloat`.

///|
/// Exhaustive `av_cmp_q` check against a `double` comparison, as in the C test. */
test "av_cmp_q agrees with double comparison" {
  let mut bad = 0
  for an = -2; an <= 2; an = an + 1 {
    for ad = -2; ad <= 2; ad = ad + 1 {
      for bn = -2; bn <= 2; bn = bn + 1 {
        for bd = -2; bd <= 2; bd = bd + 1 {
          let a : AVRational = { num: an, den: ad, }
          let b : AVRational = { num: bn, den: bd, }
          let c = av_cmp_q(a, b)
          let qa = av_q2d(a)
          let qb = av_q2d(b)
          let d = if qa == qb { 0.0 } else { qa - qb }
          let expected = if d > 0.0 {
            1
          } else if d < 0.0 {
            -1
          } else if d != d {
            -2147483648
          } else {
            0
          }
          if c != expected {
            bad = bad + 1
          }
          // (b + a) - b == a, in exact-arithmetic terms.
          if bd != 0 {
            let r = av_sub_q(av_add_q(b, a), b)
            let ok = r.num.to_int64() * ad.to_int64() ==
              an.to_int64() * r.den.to_int64() &&
              (r.num != 0) == (an != 0) &&
              (r.den != 0) == (ad != 0)
            if !ok {
              bad = bad + 1
            }
          }
        }
      }
    }
  }
  assert_eq(bad, 0)
}

///|
/// `unit_mul_q` from libavutil/tests/rational.c, checked for commutativity. */
test "av_mul_q saturation table" {
  let cases : Array[(AVRational, AVRational, AVRational)] = [
    (
      { num: 2147483647, den: 2, },
      { num: 2, den: 1, },
      { num: 2147483647, den: 1, },
    ),
    (
      { num: 2147483647, den: 2, },
      { num: -2, den: 1, },
      { num: -2147483647, den: 1, },
    ),
    ({ num: 2147483647, den: 2, }, { num: 0, den: 1, }, { num: 0, den: 1, }),
    (
      { num: -2147483648, den: 2, },
      { num: 2, den: 1, },
      { num: -2147483647, den: 1, },
    ),
    (
      { num: -2147483648, den: 2, },
      { num: -2, den: 1, },
      { num: 2147483647, den: 1, },
    ),
    ({ num: -2147483648, den: 2, }, { num: 0, den: 1, }, { num: 0, den: 1, }),
    (
      { num: 8388607, den: 1, },
      { num: 8388607, den: 1, },
      { num: 2147483647, den: 1, },
    ),
    ({ num: 1, den: 8388607, }, { num: 1, den: 8388607, }, { num: 0, den: 1, }),
    ({ num: 1, den: 1, }, { num: 0, den: 0, }, { num: 0, den: 0, }),
    ({ num: 0, den: 1, }, { num: 0, den: 0, }, { num: 0, den: 0, }),
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let (a, b, exp) = cases[i]
    let r1 = av_mul_q(a, b)
    let r2 = av_mul_q(b, a)
    assert_eq((r1.num, r1.den), (exp.num, exp.den))
    assert_eq((r2.num, r2.den), (exp.num, exp.den))
  }
}

///|
/// `unit_add_q` from libavutil/tests/rational.c, checked for commutativity. */
test "av_add_q saturation table" {
  let cases : Array[(AVRational, AVRational, AVRational)] = [
    (
      { num: 2147483647, den: 1, },
      { num: 2, den: 2, },
      { num: 2147483647, den: 1, },
    ),
    (
      { num: 2147483647, den: 1, },
      { num: -2, den: 2, },
      { num: 2147483646, den: 1, },
    ),
    (
      { num: 2147483647, den: 1, },
      { num: 0, den: 2, },
      { num: 2147483647, den: 1, },
    ),
    (
      { num: -2147483648, den: 1, },
      { num: 2, den: 2, },
      { num: -2147483647, den: 1, },
    ),
    (
      { num: -2147483648, den: 1, },
      { num: -2, den: 2, },
      { num: -2147483647, den: 1, },
    ),
    (
      { num: -2147483648, den: 1, },
      { num: 0, den: 2, },
      { num: -2147483647, den: 1, },
    ),
    (
      { num: 2147483637, den: 1, },
      { num: 20, den: 1, },
      { num: 2147483647, den: 1, },
    ),
    (
      { num: 2, den: 2147483647, },
      { num: 2, den: 2147483647, },
      { num: 4, den: 2147483647, },
    ),
    ({ num: 1, den: 1, }, { num: 0, den: 0, }, { num: 0, den: 0, }),
    ({ num: 0, den: 1, }, { num: 0, den: 0, }, { num: 0, den: 0, }),
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let (a, b, exp) = cases[i]
    let r1 = av_add_q(a, b)
    let r2 = av_add_q(b, a)
    assert_eq((r1.num, r1.den), (exp.num, exp.den))
    assert_eq((r2.num, r2.den), (exp.num, exp.den))
  }
}

///|
test "av_reduce" {
  assert_eq(av_reduce(1, 2, 100), (1, 2, true))
  assert_eq(av_reduce(6, 4, 100), (3, 2, true))
  assert_eq(av_reduce(-6, 4, 100), (-3, 2, true))
  assert_eq(av_reduce(1, 3, 100), (1, 3, true))
  assert_eq(av_reduce(0, 0, 100), (0, 0, true))
}

///|
test "av_d2q exact values" {
  assert_eq((av_d2q(0.0, 1000).num, av_d2q(0.0, 1000).den), (0, 1))
  assert_eq((av_d2q(0.5, 1000).num, av_d2q(0.5, 1000).den), (1, 2))
  assert_eq((av_d2q(0.25, 1000).num, av_d2q(0.25, 1000).den), (1, 4))
  assert_eq((av_d2q(2.0, 1000).num, av_d2q(2.0, 1000).den), (2, 1))
}

///|
test "av_q2intfloat binary32 bit patterns" {
  assert_eq(av_q2intfloat(av_make_q(1, 1)), 0x3F800000)
  assert_eq(av_q2intfloat(av_make_q(1, 2)), 0x3F000000)
  assert_eq(av_q2intfloat(av_make_q(1, 4)), 0x3E800000)
  assert_eq(av_q2intfloat(av_make_q(2, 1)), 0x40000000)
  assert_eq(av_q2intfloat(av_make_q(-1, 1)), 0xBF800000)
  assert_eq(av_q2intfloat(av_make_q(0, 1)), 0)
  assert_eq(av_q2intfloat(av_make_q(1, 0)), 0x7F800000)
  assert_eq(av_q2intfloat(av_make_q(0, 0)), 0xFFC00000)
}

///|
test "av_inv_q and av_gcd_q" {
  let inv = av_inv_q(av_make_q(3, 4))
  assert_eq((inv.num, inv.den), (4, 3))
  let g = av_gcd_q(
    av_make_q(1, 25),
    av_make_q(1, 1000),
    100000,
    av_make_q(1, 1000),
  )
  assert_eq((g.num, g.den), (1, 1000))
}
