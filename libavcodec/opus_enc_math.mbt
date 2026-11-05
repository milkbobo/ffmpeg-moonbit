/// Deterministic float helpers for the Opus encoder port.
///
/// The C encoder calls libm (`log2f`, `expf`, `atan2f`, `cosf`, `sinf`) and
/// `lrintf` on the encoding path; libm results differ by ulps between the
/// wasm and native environments, and the surrounding `lrintf`/range-coder
/// decisions amplify that into different bitstreams. The port therefore uses
/// the fixed formulas below, and the C reference harness patches the same
/// formulas in (`opus_ref_*` in `_ref/opus/ref_det.c`) so both sides agree
/// bit for bit. Everything is double precision internally and rounded to
/// float exactly where the C code would produce a float.

///|
/// `lrintf`: round to nearest, ties to even. Deterministic via the f64
/// magic-number addition (forces integer precision, nearest-even).
pub fn opus_enc_rintf(x : Float) -> Int32 {
  let d = x.to_double()
  let r = d + 6755399441055744.0 - 6755399441055744.0
  r.to_int()
}

///|
/// Natural log, identical formula to `mp3enc_ln` (exact power-of-two
/// normalisation into [1,2), then `2*atanh((m-1)/(m+1))` with 25 series
/// terms, plus `e*ln2`).
fn opus_enc_ln(x : Double) -> Double {
  let mut m = x
  let mut e = 0
  while m >= 2.0 {
    m = m / 2.0
    e += 1
  }
  while m < 1.0 {
    m = m * 2.0
    e -= 1
  }
  let t = (m - 1.0) / (m + 1.0)
  let t2 = t * t
  let mut sum = 0.0
  let mut tp = t
  for k in 0..<25 {
    sum += tp / (2 * k + 1).to_double()
    tp = tp * t2
  }
  2.0 * sum + e.to_double() * 0.6931471805599453094
}

///|
/// `log2f` replacement: `(float)(ln(x) / ln(2))` with the deterministic ln.
pub fn opus_enc_log2f(x : Float) -> Float {
  Float::from_double(opus_enc_ln(x.to_double()) * 1.4426950408889634)
}

///|
/// `expf` replacement: `e^x = 2^k * e^r` with `k = trunc(x*log2(e))`,
/// `r = x - k*ln2` in [-ln2/2, ln2/2], Taylor for `e^r` and exact
/// power-of-two scaling for `2^k`.
pub fn opus_enc_expf(x : Float) -> Float {
  let xd = x.to_double()
  let k = (xd * 1.4426950408889634).to_int()
  let r = xd - k.to_double() * 0.6931471805599453094
  let inv_fact : Array[Double] = [
    1.0, 1.0, 0.5, 0.16666666666666666, 0.041666666666666664, 0.008333333333333333,
    0.001388888888888889, 0.0001984126984126984, 0.0000248015873015873, 0.0000027557319223985893,
    0.0000002755731922398589, 0.00000002505210838544172, 0.00000000208767569878681,
    0.00000000016059043836821694, 0.000000000011470745597729782, 0.0000000000007647163731819855,
    0.00000000000004779477332387409, 0.000000000000002811457254345535,
  ]
  let mut rp = 1.0
  let mut sum = 0.0
  for i in 0..<18 {
    sum += rp * inv_fact[i]
    rp = rp * r
  }
  let mut acc = sum
  let mut n = if k < 0 { -k } else { k }
  while n > 0 {
    acc = if k < 0 { acc / 2.0 } else { acc * 2.0 }
    n -= 1
  }
  Float::from_double(acc)
}

///|
/// arctan via `2*atanh(u)`, `u = t/(1+sqrt(1+t^2))`, t >= 0, 25 terms.
fn opus_enc_atan_pos(t : Double) -> Double {
  let u = t / (1.0 + (1.0 + t * t).sqrt())
  let u2 = u * u
  let mut sum = 0.0
  let mut tp = u
  for k in 0..<25 {
    sum += tp / (2 * k + 1).to_double()
    tp = tp * u2
  }
  2.0 * sum
}

///|
/// `atan2f` replacement, principal value in [-pi, pi], deterministic.
pub fn opus_enc_atan2f(y : Float, x : Float) -> Float {
  let yd = y.to_double()
  let xd = x.to_double()
  let mut angle = 0.0
  if xd == 0.0 {
    angle = 1.57079632679489661923 // pi/2
  } else {
    let ax = if xd < 0.0 { -xd } else { xd }
    let ay = if yd < 0.0 { -yd } else { yd }
    let t = if ay <= ax {
      opus_enc_atan_pos(ay / (ax + (ax * ax + ay * ay).sqrt()))
    } else {
      let arg = ax / (ay + (ax * ax + ay * ay).sqrt())
      1.57079632679489661923 - opus_enc_atan_pos(arg)
    }
    angle = if xd > 0.0 { t } else { 3.14159265358979323846 - t }
  }
  if yd < 0.0 {
    angle = -angle
  }
  Float::from_double(angle)
}

///|
/// `sinf` replacement for theta in [0, pi/4] (the only range the rotation
/// code produces): Taylor with precomputed 1/(2k+1)!, alternating signs.
pub fn opus_enc_sinf(theta : Double) -> Float {
  let inv_fact : Array[Double] = [
    1.0, 0.16666666666666666, 0.008333333333333333, 0.0001984126984126984, 2.7557319223985893e-06,
    2.505210838544172e-08, 1.6059043836821613e-10, 7.647163731819816e-13, 2.8114572543455206e-15,
  ]
  let t2 = theta * theta
  let mut tp = theta
  let mut sum = 0.0
  for k in 0..<9 {
    let term = tp * inv_fact[k]
    sum += if k % 2 == 0 { term } else { -term }
    tp = tp * t2
  }
  Float::from_double(sum)
}

///|
/// `cosf` replacement for theta in [0, pi/4]: Taylor, alternating signs.
pub fn opus_enc_cosf(theta : Double) -> Float {
  let inv_fact : Array[Double] = [
    1.0, 0.5, 0.041666666666666664, 0.001388888888888889, 2.48015873015873e-05, 2.755731922398589e-07,
    2.08767569878681e-09, 1.1470745597729725e-11,
  ]
  let t2 = theta * theta
  let mut tp = 1.0
  let mut sum = 0.0
  for k in 0..<8 {
    let term = tp * inv_fact[k]
    sum += if k % 2 == 0 { term } else { -term }
    tp = tp * t2
  }
  Float::from_double(sum)
}

///|
/// Integer clip helper.
fn opus_enc_clip_i(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}
