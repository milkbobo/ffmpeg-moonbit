///|
/// Opus entropy decoder, ported from FFmpeg 9.0.2 libavcodec/opus/rc.c
/// and rc.h. Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2017 Rostislav Pehlivanov. LGPL-2.1-or-later.
///
/// Range-coded symbols read forwards; CELT raw bits read backwards from the
/// same frame. This is the shared entropy layer for SILK and CELT, not yet
/// an Opus PCM decoder. Arithmetic uses wrapping UInt32, as in the C.
pub struct OpusRangeDecoder {
  reader : BitReader
  data : Bytes
  mut range : UInt32
  mut value : UInt32
  mut total_bits : UInt32
  mut raw_pos : Int32
  mut raw_cache : UInt32
  mut raw_count : Int32
}

///|
fn opus_rc_ilog(value : UInt32) -> Int32 {
  let mut x = value
  let mut bits = 0
  while x != 0U {
    bits += 1
    x = x >> 1
  }
  bits
}

///|
fn OpusRangeDecoder::normalize(self : OpusRangeDecoder) -> Unit {
  while self.range <= 0x00800000U {
    self.value = ((self.value << 8) | (self.reader.read(8) ^ 255U)) &
      0x7fffffffU
    self.range = self.range << 8
    self.total_bits += 8U
  }
}

///|
fn OpusRangeDecoder::update(
  self : OpusRangeDecoder,
  scale : UInt32,
  low : UInt32,
  high : UInt32,
  total : UInt32,
) -> Unit {
  self.value -= scale * (total - high)
  self.range = if low != 0U {
    scale * (high - low)
  } else {
    self.range - scale * (total - high)
  }
  self.normalize()
}

///|
/// Initialize one Opus frame's entropy decoder (without the TOC byte).
/// Reads beyond the forward arithmetic window use zero padding, matching C.
/// Empty frames are rejected; packet loss concealment belongs to the caller.
///
/// ```mbt check
/// test {
///   let rc = @libavcodec.opus_rc_init(b"\xff\xff\xff").unwrap()
///   assert_eq(rc.tell(), 1)
///   assert_eq(rc.decode_log(1).unwrap(), 1)
/// }
/// ```
pub fn opus_rc_init(data : Bytes) -> Result[OpusRangeDecoder, String] {
  if data.length() == 0 {
    return Err("opus: empty entropy frame")
  }
  if data.length() > 1275 {
    return Err("opus: entropy frame exceeds 1275 bytes")
  }
  let reader = BitReader::new(data)
  let value = 127U - reader.read(7)
  let rc : OpusRangeDecoder = {
    reader,
    data,
    range: 128U,
    value,
    total_bits: 9U,
    raw_pos: data.length(),
    raw_cache: 0U,
    raw_count: 0,
  }
  rc.normalize()
  Ok(rc)
}

///|
/// Whole bits consumed, including the initial arithmetic-coder bit.
pub fn OpusRangeDecoder::tell(self : OpusRangeDecoder) -> Int32 {
  self.total_bits.reinterpret_as_int() - opus_rc_ilog(self.range)
}

///|
/// Bits consumed in eighth-bit units (`opus_rc_tell_frac`).
pub fn OpusRangeDecoder::tell_frac(self : OpusRangeDecoder) -> Int32 {
  let mut log = opus_rc_ilog(self.range)
  let mut range = self.range >> (log - 16)
  for _ in 0..<3 {
    range = (range * range) >> 15
    let bit = range >> 16
    log = (log << 1) | bit.reinterpret_as_int()
    range = range >> bit.reinterpret_as_int()
  }
  ((self.total_bits << 3) - log.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// Decode a symbol using C's cumulative table format: total, followed by
/// nondecreasing upper bounds ending at total (1..65535). Zero-frequency
/// symbols are allowed and are skipped by the search, as in the C.
pub fn OpusRangeDecoder::decode_cdf(
  self : OpusRangeDecoder,
  cdf : ArrayView[Int32],
) -> Result[Int32, String] {
  if cdf.length() < 2 || cdf[0] < 1 || cdf[0] > 65535 {
    return Err("opus: invalid cumulative distribution")
  }
  let total = cdf[0].reinterpret_as_uint()
  let mut previous = 0
  for i in 1..<cdf.length() {
    if cdf[i] < previous || cdf[i] > cdf[0] {
      return Err("opus: invalid cumulative distribution")
    }
    previous = cdf[i]
  }
  if previous != cdf[0] {
    return Err("opus: invalid cumulative distribution")
  }
  let scale = self.range / total
  let symbol = total - (self.value / scale + 1U).min(total)
  let mut k = 1
  while cdf[k].reinterpret_as_uint() <= symbol {
    k += 1
  }
  let low = if k == 1 { 0U } else { cdf[k - 1].reinterpret_as_uint() }
  self.update(scale, low, cdf[k].reinterpret_as_uint(), total)
  Ok(k - 1)
}

///|
/// Decode a bit whose probability of one is 1/(2^bits), bits=1..31.
pub fn OpusRangeDecoder::decode_log(
  self : OpusRangeDecoder,
  bits : Int32,
) -> Result[Int32, String] {
  if bits < 1 || bits > 31 || self.range >> bits == 0U {
    return Err("opus: invalid logarithmic probability")
  }
  let scale = self.range >> bits
  let bit = if self.value >= scale {
    self.value -= scale
    self.range -= scale
    0
  } else {
    self.range = scale
    1
  }
  self.normalize()
  Ok(bit)
}

///|
/// Re-point the backwards raw-bit reader at `data[0..end]`, as
/// `ff_opus_rc_dec_raw_init(&rc, data + size, size)` does after SILK consumed
/// the front of a hybrid frame. Clears the cached raw bits.
fn OpusRangeDecoder::reinit_raw(self : OpusRangeDecoder, end : Int32) -> Unit {
  self.raw_pos = end
  self.raw_cache = 0U
  self.raw_count = 0
}

///|
/// Read 0..25 CELT raw bits, backwards byte-wise and low bit first.
/// An exhausted raw buffer returns an error without changing the decoder.
pub fn OpusRangeDecoder::get_raw(
  self : OpusRangeDecoder,
  count : Int32,
) -> Result[UInt32, String] {
  if count < 0 || count > 25 {
    return Err("opus: invalid raw bit count")
  }
  if self.raw_count + self.raw_pos * 8 < count {
    return Err("opus: truncated raw bits")
  }
  while self.raw_count < count {
    self.raw_pos -= 1
    self.raw_cache = self.raw_cache |
      (self.data[self.raw_pos].to_uint() << self.raw_count)
    self.raw_count += 8
  }
  let value = self.raw_cache & ((1U << count) - 1U)
  self.raw_cache = self.raw_cache >> count
  self.raw_count -= count
  self.total_bits += count.reinterpret_as_uint()
  Ok(value)
}

///|
/// Decode a uniformly distributed integer in 0..<size (size >= 2).
pub fn OpusRangeDecoder::decode_uint(
  self : OpusRangeDecoder,
  size : UInt32,
) -> Result[UInt32, String] {
  if size < 2U {
    return Err("opus: uniform size must be at least two")
  }
  let bits = opus_rc_ilog(size - 1U)
  let total = if bits > 8 { ((size - 1U) >> (bits - 8)) + 1U } else { size }
  if bits > 8 && self.raw_count + self.raw_pos * 8 < bits - 8 {
    return Err("opus: truncated raw bits")
  }
  let scale = self.range / total
  let k = total - (self.value / scale + 1U).min(total)
  self.update(scale, k, k + 1U, total)
  if bits > 8 {
    match self.get_raw(bits - 8) {
      Ok(raw) => Ok(((k << (bits - 8)) | raw).min(size - 1U))
      Err(e) => Err(e)
    }
  } else {
    Ok(k)
  }
}

///|
/// CELT theta distribution: probability weight 3 through k0, then 1.
/// The symbol range is 0..=2*k0, k0=0..8191.
pub fn OpusRangeDecoder::decode_step(
  self : OpusRangeDecoder,
  k0 : Int32,
) -> Result[Int32, String] {
  if k0 < 0 || k0 > 8191 {
    return Err("opus: invalid step distribution")
  }
  let total = ((k0 + 1) * 3 + k0).reinterpret_as_uint()
  let scale = self.range / total
  let symbol = (total - (self.value / scale + 1U).min(total)).reinterpret_as_int()
  let k = if symbol < (k0 + 1) * 3 { symbol / 3 } else { symbol - (k0 + 1) * 2 }
  let low = if k <= k0 { 3 * k } else { k - 1 - k0 + 3 * (k0 + 1) }
  let high = if k <= k0 { 3 * (k + 1) } else { k - k0 + 3 * (k0 + 1) }
  self.update(
    scale,
    low.reinterpret_as_uint(),
    high.reinterpret_as_uint(),
    total,
  )
  Ok(k)
}

///|
fn opus_rc_isqrt(value : UInt32) -> UInt32 {
  // Floor square root by a bounded binary search; no floating-point rounding.
  for low = 0U, high = 65536U; low + 1U < high; {
    let mid = (low + high) >> 1
    if mid <= value / mid {
      continue mid, high
    } else {
      continue low, mid
    }
  } nobreak {
    low
  }
}

///|
/// CELT triangular theta distribution, qn even in 0..=256.
pub fn OpusRangeDecoder::decode_tri(
  self : OpusRangeDecoder,
  qn : Int32,
) -> Result[Int32, String] {
  if qn < 0 || qn > 256 || (qn & 1) != 0 {
    return Err("opus: invalid triangular distribution")
  }
  let total = (((qn >> 1) + 1) * ((qn >> 1) + 1)).reinterpret_as_uint()
  let scale = self.range / total
  let center = total - (self.value / scale + 1U).min(total)
  let (k, low, symbol) = if center < total >> 1 {
    let k = ((opus_rc_isqrt(8U * center + 1U) - 1U) >> 1).reinterpret_as_int()
    (k, (k * (k + 1)) >> 1, k + 1)
  } else {
    let k = (
        2 * (qn + 1) -
        opus_rc_isqrt(8U * (total - center - 1U) + 1U).reinterpret_as_int()
      ) >>
      1
    (
      k,
      total.reinterpret_as_int() - (((qn + 1 - k) * (qn + 2 - k)) >> 1),
      qn + 1 - k,
    )
  }
  self.update(
    scale,
    low.reinterpret_as_uint(),
    (low + symbol).reinterpret_as_uint(),
    total,
  )
  Ok(k)
}

///|
/// Decode a signed Laplace symbol (zero frequency 1..32736, decay 0..16384).
pub fn OpusRangeDecoder::decode_laplace(
  self : OpusRangeDecoder,
  zero_frequency : Int32,
  decay : Int32,
) -> Result[Int32, String] {
  if zero_frequency < 1 || zero_frequency > 32736 || decay < 0 || decay > 16384 {
    return Err("opus: invalid Laplace distribution")
  }
  let scale = self.range >> 15
  let center = 32768U - (self.value / scale + 1U).min(32768U)
  let mut value = 0
  let mut low = 0U
  let mut symbol = zero_frequency.reinterpret_as_uint()
  if center >= symbol {
    value += 1
    low = symbol
    symbol = 1U +
      (((32768U - 32U - symbol) * (16384 - decay).reinterpret_as_uint()) >> 15)
    while symbol > 1U && center >= low + 2U * symbol {
      value += 1
      symbol *= 2U
      low += symbol
      symbol = (((symbol - 2U) * decay.reinterpret_as_uint()) >> 15) + 1U
    }
    if symbol <= 1U {
      let distance = (center - low) >> 1
      value += distance.reinterpret_as_int()
      low += 2U * distance
    }
    if center < low + symbol {
      value = -value
    } else {
      low += symbol
    }
  }
  self.update(scale, low, (low + symbol).min(32768U), 32768U)
  Ok(value)
}
