///|
/// CELT recursive-band helpers from FFmpeg 9.0.2 opus/pvq.c.
/// Copyright (c) 2007-2008 CSIRO, 2007-2009 Xiph.Org Foundation,
/// 2008-2009 Gregory Maxwell, 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2017 Rostislav Pehlivanov. LGPL-2.1-or-later.
/// A bounded array plus offset replaces C's aliasing float pointers.
priv struct CeltVector {
  data : Array[Float]
  offset : Int32
}

///|
#alias("_[_]")
fn CeltVector::get(self : CeltVector, i : Int32) -> Float { self.data[self.offset + i] }

///|
#alias("_[_]=_")
fn CeltVector::set(self : CeltVector, i : Int32, value : Float) -> Unit { self.data[self.offset + i] = value }

///|
fn CeltVector::slice(self : CeltVector, offset : Int32) -> CeltVector { { data: self.data, offset: self.offset + offset } }

///|
priv suberror CeltSpectrumError { SpectrumError(String) }

///|
fn[T] opus_celt_result(result : Result[T, String]) -> T raise CeltSpectrumError {
  match result { Ok(value) => value; Err(error) => raise SpectrumError(error) }
}

///|
fn opus_celt_round_mul(a : Int32, b : Int32) -> Int32 { (a * b + 16384) >> 15 }

///|
fn opus_celt_cos(angle : Int32) -> Int32 {
  let x = (angle * angle + 4096) >> 13
  let value = 32767 - x + opus_celt_round_mul(x,
    -7651 + opus_celt_round_mul(x, 8277 + opus_celt_round_mul(-626, x)))
  // Both the intermediate assignment and return type are int16_t in C.
  ((value + 1) << 16) >> 16
}

///|
fn opus_celt_log2tan(sine : Int32, cosine : Int32) -> Int32 {
  let ls = opus_rc_ilog(sine.reinterpret_as_uint())
  let lc = opus_rc_ilog(cosine.reinterpret_as_uint())
  let s = sine << (15 - ls)
  let c = cosine << (15 - lc)
  (ls << 11) - (lc << 11) + opus_celt_round_mul(s, opus_celt_round_mul(s, -2597) + 7932) -
    opus_celt_round_mul(c, opus_celt_round_mul(c, -2597) + 7932)
}

///|
fn opus_celt_qn(n : Int32, bits : Int32, offset : Int32, pulse_cap : Int32, stereo : Bool) -> Int32 {
  let n2 = 2 * n - 1 - (if stereo && n == 2 { 1 } else { 0 })
  let qb = (bits - pulse_cap - 32).min((bits + n2 * offset) / n2).min(64)
  if qb < 4 { 1 } else { ((opus_celt_qn_exp2[qb & 7] >> (14 - (qb >> 3))) + 1) >> 1 << 1 }
}

///|
fn opus_celt_bits2pulses(cache : Int32, bits0 : Int32) -> Int32 {
  let bits = bits0 - 1
  let mut low = 0
  let mut high = opus_celt_cache_bits[cache]
  for _ in 0..<6 {
    let center = (low + high + 1) >> 1
    if opus_celt_cache_bits[cache + center] >= bits { high = center } else { low = center }
  }
  let previous = if low == 0 { -1 } else { opus_celt_cache_bits[cache + low] }
  if bits - previous <= opus_celt_cache_bits[cache + high] - bits { low } else { high }
}

///|
fn opus_celt_pulses2bits(cache : Int32, pulses : Int32) -> Int32 {
  if pulses == 0 { 0 } else { opus_celt_cache_bits[cache + pulses] + 1 }
}

///|
fn opus_celt_renormalize(x : CeltVector, n : Int32, gain : Float) -> Unit {
  let mut energy : Float = 1.0e-15
  for i in 0..<n { energy += x[i] * x[i] }
  let scale = gain / energy.sqrt()
  for i in 0..<n { x[i] = x[i] * scale }
}

///|
fn opus_celt_haar(x : CeltVector, n0 : Int32, stride : Int32) -> Unit {
  for i in 0..<stride {
    for j in 0..<(n0 >> 1) {
      let a = x[stride * (2 * j) + i]
      let b = x[stride * (2 * j + 1) + i]
      // M_SQRT1_2 promotes the product to double in the original C.
      x[stride * (2 * j) + i] = Float::from_double((a + b).to_double() * 0.70710678118654752440)
      x[stride * (2 * j + 1) + i] = Float::from_double((a - b).to_double() * 0.70710678118654752440)
    }
  }
}

///|
fn opus_celt_hadamard(x : CeltVector, n0 : Int32, stride : Int32, longblocks : Bool, inverse : Bool) -> Unit {
  let temp : Array[Float] = Array::make(n0 * stride, 0.0)
  let order = if longblocks { stride - 2 } else { 30 }
  for i in 0..<stride {
    for j in 0..<n0 {
      let time = j * stride + i
      let frequency = opus_celt_hadamard_order[order + i] * n0 + j
      if inverse { temp[time] = x[frequency] } else { temp[frequency] = x[time] }
    }
  }
  for i in 0..<temp.length() { x[i] = temp[i] }
}

///|
fn opus_celt_stereo_merge(x : CeltVector, y : CeltVector, mid : Float, n : Int32) -> Unit {
  let mut xp : Float = 0.0
  let mut side : Float = 0.0
  for i in 0..<n { xp += x[i] * y[i]; side += y[i] * y[i] }
  xp *= mid
  let e0 : Float = mid * mid + side - 2.0 * xp
  let e1 : Float = mid * mid + side + 2.0 * xp
  if e0 < 0.0006 || e1 < 0.0006 { for i in 0..<n { y[i] = x[i] }; return }
  let g0 : Float = 1.0 / e0.sqrt()
  let g1 : Float = 1.0 / e1.sqrt()
  for i in 0..<n {
    let a = mid * x[i]
    let b = y[i]
    x[i] = g0 * (a - b)
    y[i] = g1 * (a + b)
  }
}
