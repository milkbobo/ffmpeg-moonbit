///|
/// CELT pulse-vector decoding, ported from FFmpeg 9.0.2 opus/pvq.c.
/// Copyright (c) 2007-2008 CSIRO, 2007-2009 Xiph.Org Foundation,
/// 2008-2009 Gregory Maxwell, 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2017 Rostislav Pehlivanov. LGPL-2.1-or-later.
/// This is the non-recursive PVQ band kernel; bit allocation, band splitting,
/// folding, stereo coupling and PCM synthesis belong to the CELT frame layer.
pub struct OpusPulseVector {
  pulses : Array[Int32]
  norm_squared : Int64
}

///|
let opus_pvq_row : FixedArray[Int32] = [
  0, 176, 351, 525, 698, 870, 1041, 1131, 1178, 1207, 1226, 1240, 1248, 1254, 1257,
]

///|
let opus_pvq_row_end : FixedArray[Int32] = [
  176, 176, 176, 176, 176, 176, 96, 54, 37, 28, 24, 19, 18, 16, 14,
]

///|
fn opus_pvq_lookup(n : Int32, k : Int32) -> UInt32? {
  let row = n.min(k)
  let col = n.max(k)
  if row < 0 || row >= opus_pvq_row.length() || col > opus_pvq_row_end[row] {
    None
  } else { Some(opus_pvq_u[opus_pvq_row[row] + col]) }
}

///|
fn opus_pvq_get(n : Int32, k : Int32) -> UInt32 {
  opus_pvq_u[opus_pvq_row[n.min(k)] + n.max(k)]
}

///|
/// Number of signed N-dimensional integer vectors with L1 norm K.
/// Only the table domain used by FFmpeg's CELT bands is accepted; codebooks
/// exceeding a UInt32 index are rejected. N=2..176, K>=0.
pub fn opus_pvq_size(n : Int32, k : Int32) -> Result[UInt32, String] {
  if n < 2 || n > 176 || k < 0 || k > 175 {
    return Err("opus: unsupported PVQ dimensions or pulse count")
  }
  match (opus_pvq_lookup(n, k), opus_pvq_lookup(n, k + 1)) {
    (Some(a), Some(b)) => {
      let total = a.to_uint64() + b.to_uint64()
      if total > 0xffffffffUL { Err("opus: PVQ codebook exceeds 32 bits") }
      else { Ok(total.to_uint()) }
    }
    _ => Err("opus: unsupported PVQ dimensions or pulse count")
  }
}

///|
fn opus_pvq_unrank_valid(n0 : Int32, k0 : Int32, index : UInt32) -> OpusPulseVector {
  let pulses : Array[Int32] = []
  let mut n = n0
  let mut k = k0
  let mut i = index
  let mut norm = 0L
  while n > 2 {
    let mut p = 0U
    let mut sign = 0
    let previous = k
    if k >= n {
      p = opus_pvq_get(n, k + 1)
      sign = if i >= p { -1 } else { 0 }
      if sign != 0 { i -= p }
      let q = opus_pvq_get(n, n)
      if q > i {
        k = n - 1
        p = opus_pvq_get(k, n)
        while p > i { k -= 1; p = opus_pvq_get(k, n) }
      } else {
        p = opus_pvq_get(n, k)
        while p > i { k -= 1; p = opus_pvq_get(n, k) }
      }
    } else {
      p = opus_pvq_get(k, n)
      let q = opus_pvq_get(k + 1, n)
      if p <= i && i < q {
        i -= p
        pulses.push(0)
        n -= 1
        continue
      }
      sign = if i >= q { -1 } else { 0 }
      if sign != 0 { i -= q }
      k -= 1
      p = opus_pvq_get(k, n)
      while p > i { k -= 1; p = opus_pvq_get(k, n) }
    }
    i -= p
    let value = (previous - k + sign) ^ sign
    pulses.push(value)
    norm += value.to_int64() * value.to_int64()
    n -= 1
  }
  let p = (2 * k + 1).reinterpret_as_uint()
  let sign = if i >= p { -1 } else { 0 }
  if sign != 0 { i -= p }
  let previous = k
  k = ((i + 1U) / 2U).reinterpret_as_int()
  if k != 0 { i -= (2 * k - 1).reinterpret_as_uint() }
  let first = (previous - k + sign) ^ sign
  let last_sign = -i.reinterpret_as_int()
  let last = (k + last_sign) ^ last_sign
  pulses.push(first)
  pulses.push(last)
  norm += first.to_int64() * first.to_int64() + last.to_int64() * last.to_int64()
  { pulses, norm_squared: norm }
}

///|
/// Decode an explicit codebook index in CELT's signed pulse-vector ordering.
/// K=0 has one all-zero vector. Invalid indices return an error.
///
/// ```mbt check
/// test {
///   let vector = @libavcodec.opus_pvq_unrank(2, 1, 0U).unwrap()
///   assert_eq(@libavcodec.opus_pvq_size(2, 1).unwrap(), 4U)
///   assert_eq(vector.pulses, [1, 0])
///   assert_eq(vector.norm_squared, 1L)
/// }
/// ```
pub fn opus_pvq_unrank(n : Int32, k : Int32, index : UInt32) -> Result[OpusPulseVector, String] {
  let size = match opus_pvq_size(n, k) { Ok(v) => v; Err(e) => return Err(e) }
  if index >= size { return Err("opus: PVQ index outside codebook") }
  Ok(opus_pvq_unrank_valid(n, k, index))
}

///|
/// Decode the uniformly coded index from an Opus frame's shared entropy
/// decoder. Parameter errors leave the entropy state unchanged.
pub fn OpusRangeDecoder::decode_pulses(
  self : OpusRangeDecoder, n : Int32, k : Int32,
) -> Result[OpusPulseVector, String] {
  let size = match opus_pvq_size(n, k) { Ok(v) => v; Err(e) => return Err(e) }
  let index = if size == 1U { 0U } else {
    match self.decode_uint(size) { Ok(v) => v; Err(e) => return Err(e) }
  }
  Ok(opus_pvq_unrank_valid(n, k, index))
}

///|
/// A normalized CELT band and its nonzero time-block mask.
pub struct OpusCeltBand {
  coefficients : Array[Float]
  collapse_mask : UInt32
}

///|
fn opus_celt_rotate_pass(
  x : Array[Float], base : Int32, length : Int32, stride : Int32,
  c : Float, s : Float,
) -> Unit {
  for i in 0..<(length - stride) {
    let a = x[base + i]
    let b = x[base + i + stride]
    x[base + i + stride] = c * b + s * a
    x[base + i] = c * a - s * b
  }
  let mut i = length - 2 * stride - 1
  while i >= 0 {
    let a = x[base + i]
    let b = x[base + i + stride]
    x[base + i + stride] = c * b + s * a
    x[base + i] = c * a - s * b
    i -= 1
  }
}

///|
fn opus_celt_spread(
  x : Array[Float], k : Int32, blocks : Int32, spread : Int32,
) -> Unit {
  let n = x.length()
  if 2 * k >= n || spread == 0 { return }
  let gain = Float::from_int(n) / Float::from_int(n + (20 - 5 * spread) * k)
  // C evaluates M_PI * gain * gain / 4 in double then casts to float.
  let theta = Float::from_double(@math.PI * gain.to_double() * gain.to_double() / 4.0)
  let c = Float::from_double(@math.cos(theta.to_double()))
  let s = Float::from_double(@math.sin(theta.to_double()))
  let mut stride2 = 0
  if n >= blocks << 3 {
    stride2 = 1
    while (stride2 * stride2 + stride2) * blocks + (blocks >> 2) < n { stride2 += 1 }
  }
  let length = n / blocks
  for block in 0..<blocks {
    if stride2 != 0 { opus_celt_rotate_pass(x, block * length, length, stride2, s, c) }
    opus_celt_rotate_pass(x, block * length, length, 1, c, s)
  }
}

///|
/// Decode a non-recursive CELT PVQ band (`celt_alg_unquant`).
/// `spread` is 0:none, 1:light, 2:normal or 3:aggressive; `blocks` is
/// 1/2/4/8/16 and must divide N. Sixteen blocks occur after CELT TF subdivision.
/// K must be positive and gain finite/nonnegative.
/// Invalid parameters leave the entropy state unchanged. This kernel does
/// not perform bit allocation, folding or stereo band splitting.
///
/// ```mbt check
/// test {
///   let rc = @libavcodec.opus_rc_init(b"\x00\x00\x00\x00").unwrap()
///   let band = rc.decode_celt_band(2, 1, 0, 1, 1.0).unwrap()
///   assert_eq(band.collapse_mask, 1U)
///   assert_eq(band.coefficients.length(), 2)
/// }
/// ```
pub fn OpusRangeDecoder::decode_celt_band(
  self : OpusRangeDecoder, n : Int32, k : Int32,
  spread : Int32, blocks : Int32, gain : Float,
) -> Result[OpusCeltBand, String] {
  if k <= 0 { return Err("opus: CELT band requires positive pulse count") }
  if spread < 0 || spread > 3 { return Err("opus: invalid CELT spread") }
  if !(blocks == 1 || blocks == 2 || blocks == 4 || blocks == 8 || blocks == 16) || n % blocks != 0 {
    return Err("opus: invalid CELT block count")
  }
  if !(gain >= 0.0 && gain <= 3.4028234663852886e38) {
    return Err("opus: invalid CELT band gain")
  }
  let vector = match self.decode_pulses(n, k) { Ok(v) => v; Err(e) => return Err(e) }
  let scale = gain / Float::from_int64(vector.norm_squared).sqrt()
  let coefficients = [for value in vector.pulses => scale * Float::from_int(value)]
  let mut collapse_mask = if blocks == 1 { 1U } else { 0U }
  if blocks > 1 {
    for block in 0..<blocks {
      for j in 0..<(n / blocks) {
        if vector.pulses[block * (n / blocks) + j] != 0 {
          collapse_mask = collapse_mask | (1U << block)
        }
      }
    }
  }
  opus_celt_spread(coefficients, k, blocks, spread)
  Ok({ coefficients, collapse_mask })
}
