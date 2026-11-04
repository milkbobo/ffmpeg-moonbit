/// MoonBit port of the encoder side of FFmpeg 9.0.2 `libavcodec/opus/rc.c`
/// (range coder with end-bit raw bits, `ff_opus_rc_enc_*`).
///
/// The C range coder keeps two regions of one buffer: range-coded bytes grow
/// forward from `buf[0]` while the raw bits (`ff_opus_rc_put_raw`) grow
/// downward from `buf[OPUS_MAX_FRAME_SIZE + 12]`, big-endian per 32-bit word;
/// `ff_opus_rc_enc_end` merges them with an OR over the overlap. The port
/// keeps the same layout (`buf` plus a raw region written from the end).
///
/// All arithmetic is UInt32 and wraps exactly like the C; the only stateful
/// subtleties are `rem` (starts at -1, i.e. "no pending carry byte") and
/// `ext` (pending 0xFF run), which the final flush resolves.

///|
/// `OPUS_MAX_FRAME_SIZE + 12` (`opus.h` + `rc.h`), the size of `rc->buf`.
let opus_enc_rc_buf_size : Int = 1275 + 12

///|
/// Encoder-side range coder (`OpusRangeCoder`, encoder fields).
pub struct OpusRangeEncoder {
  buf : FixedArray[Byte]
  /// raw-bit words in flush order (each 4 bytes, big-endian in memory);
  /// the first flushed word occupies the highest addresses.
  raw : Array[UInt32]
  mut value : UInt32
  mut range : UInt32
  mut total_bits : Int32
  mut rem : Int32
  mut ext : Int32
  mut rng_pos : Int
  mut rb_bytes : Int32
  mut rb_cachelen : Int32
  mut rb_cacheval : UInt32
}

///|
/// `ff_opus_rc_enc_init`.
pub fn OpusRangeEncoder::init(self : OpusRangeEncoder) -> Unit {
  self.value = 0U
  self.range = 0x80000000U
  self.total_bits = 33
  self.rem = -1
  self.ext = 0
  self.rng_pos = 0
  self.rb_bytes = 0
  self.rb_cachelen = 0
  self.rb_cacheval = 0U
  self.raw.clear()
}

///|
pub fn OpusRangeEncoder::new() -> OpusRangeEncoder {
  let enc : OpusRangeEncoder = {
    buf: FixedArray::make(opus_enc_rc_buf_size, b'\x00'),
    raw: [],
    value: 0U,
    range: 0x80000000U,
    total_bits: 33,
    rem: -1,
    ext: 0,
    rng_pos: 0,
    rb_bytes: 0,
    rb_cachelen: 0,
    rb_cacheval: 0U,
  }
  enc
}

///|
/// `opus_rc_tell` (`rc.h`): `total_bits - av_log2(range) - 1`, and
/// `av_log2(x) == opus_rc_ilog(x) - 1` for `x > 0`, hence the plain
/// subtraction below.
pub fn OpusRangeEncoder::tell(self : OpusRangeEncoder) -> Int32 {
  self.total_bits - opus_rc_ilog(self.range)
}

///|
/// `opus_rc_tell_frac` (`rc.h`): 1/8th bit precision.
pub fn OpusRangeEncoder::tell_frac(self : OpusRangeEncoder) -> Int32 {
  let mut log = opus_rc_ilog(self.range)
  let mut range = self.range >> (log - 16)
  for _ in 0..<3 {
    range = (range * range) >> 15
    let bit = range >> 16
    log = (log << 1) | bit.reinterpret_as_int()
    range = range >> bit.reinterpret_as_int()
  }
  (self.total_bits << 3) - log
}

///|
/// `opus_rc_enc_carryout`.
fn OpusRangeEncoder::carryout(self : OpusRangeEncoder, cbuf : Int) -> Unit {
  let cb = cbuf >> 8
  let mb = (255 + cb) & 255
  if cbuf == 255 {
    self.ext += 1
    return
  }
  self.buf[self.rng_pos] = (self.rem + cb).to_byte()
  if self.rem >= 0 {
    self.rng_pos += 1
  }
  while self.ext > 0 {
    self.buf[self.rng_pos] = mb.to_byte()
    self.rng_pos += 1
    self.ext -= 1
  }
  self.rem = cbuf & 255
}

///|
/// `opus_rc_enc_normalize`.
fn OpusRangeEncoder::normalize(self : OpusRangeEncoder) -> Unit {
  while self.range <= 0x00800000U { // OPUS_RC_BOT
    self.carryout((self.value >> 23).reinterpret_as_int())
    self.value = (self.value << 8) & 0x7FFFFFFFU
    self.range = self.range << 8
    self.total_bits += 8
  }
}

///|
/// `opus_rc_enc_update`: `b`/`p` are lower/upper symbol bounds in `p_tot`.
fn OpusRangeEncoder::update(
  self : OpusRangeEncoder,
  b : UInt32,
  p : UInt32,
  p_tot : UInt32,
  ptwo : Bool,
) -> Unit {
  let cnd : UInt32 = if b != 0U { 1U } else { 0U }
  // C shifts by ff_log2(p_tot) == opus_rc_ilog(p_tot) - 1 here
  let rscaled : UInt32 = if ptwo {
    self.range >> (opus_rc_ilog(p_tot) - 1)
  } else {
    self.range / p_tot
  }
  self.value += cnd * (self.range - rscaled * (p_tot - b))
  let dec = rscaled * (p_tot - p)
  let enc = rscaled * (p - b)
  self.range = (1U - cnd) * (self.range - dec) + cnd * enc
  self.normalize()
}

///|
/// `ff_opus_rc_enc_cdf`: `cdf` is total followed by upper bounds.
pub fn OpusRangeEncoder::encode_cdf(
  self : OpusRangeEncoder,
  val : Int,
  cdf : Array[Int32],
) -> Unit {
  let b : UInt32 = if val != 0 { cdf[val].reinterpret_as_uint() } else { 0U }
  self.update(b, cdf[val + 1].reinterpret_as_uint(), cdf[0].reinterpret_as_uint(), true)
}

///|
/// `ff_opus_rc_enc_log`.
pub fn OpusRangeEncoder::encode_log(
  self : OpusRangeEncoder,
  val : Int,
  bits : Int,
) -> Unit {
  let b = (1 << bits) - 1
  let vb : UInt32 = if val != 0 { b.reinterpret_as_uint() } else { 0U }
  self.update(vb, (b + (if val != 0 { 1 } else { 0 })).reinterpret_as_uint(), (b + 1).reinterpret_as_uint(), true)
}

///|
/// `ff_opus_rc_put_raw`: 0-31 bits into the backwards raw-bit region.
pub fn OpusRangeEncoder::put_raw(
  self : OpusRangeEncoder,
  val : UInt32,
  count : Int,
) -> Unit {
  let to_write = (32 - self.rb_cachelen).min(count)
  self.total_bits += count
  let mask : UInt32 = if to_write >= 32 {
    0xFFFFFFFFU
  } else {
    (1U << to_write) - 1U
  }
  self.rb_cacheval = self.rb_cacheval | ((val & mask) << self.rb_cachelen)
  self.rb_cachelen = (self.rb_cachelen + to_write) % 32
  if self.rb_cachelen == 0 && count != 0 {
    self.raw.push(self.rb_cacheval)
    self.rb_bytes += 4
    self.rb_cachelen = count - to_write
    let rem_mask : UInt32 = if self.rb_cachelen >= 32 {
      0xFFFFFFFFU
    } else if self.rb_cachelen <= 0 {
      0U
    } else {
      (1U << self.rb_cachelen) - 1U
    }
    self.rb_cacheval = (val >> to_write) & rem_mask
  }
}

///|
/// `ff_opus_rc_enc_uint`: uniform integer, 8-bit chunks.
pub fn OpusRangeEncoder::encode_uint(
  self : OpusRangeEncoder,
  val : UInt32,
  size : UInt32,
) -> Unit {
  // C: opus_ilog(size-1) == opus_rc_ilog
  let ps = (opus_rc_ilog(size - 1U) - 8).max(0)
  self.update(
    val >> ps,
    (val >> ps) + 1U,
    ((size - 1U) >> ps) + 1U,
    false,
  )
  self.put_raw(val, ps)
}

///|
/// `ff_opus_rc_enc_uint_step`.
pub fn OpusRangeEncoder::encode_uint_step(
  self : OpusRangeEncoder,
  val : UInt32,
  k0 : Int,
) -> Unit {
  let a : UInt32 = if val <= k0.reinterpret_as_uint() { 1U } else { 0U }
  let b = 2U * a + 1U
  let k = ((k0 + 1) << 1).reinterpret_as_uint()
  let v = b * (val + k) - 3U * a * k
  self.update(v, v + b, (k << 1) - 1U, false)
}

///|
/// `ff_opus_rc_enc_uint_tri`.
pub fn OpusRangeEncoder::encode_uint_tri(
  self : OpusRangeEncoder,
  k : UInt32,
  qn : Int,
) -> Unit {
  let total = (((qn >> 1) + 1) * ((qn >> 1) + 1)).reinterpret_as_uint()
  let low : UInt32 = if k <= (qn >> 1).reinterpret_as_uint() {
    (k * (k + 1U)) >> 1
  } else {
    total - ((((qn + 1).reinterpret_as_uint() - k) * ((qn + 2).reinterpret_as_uint() - k)) >> 1)
  }
  let symbol : UInt32 = if k <= (qn >> 1).reinterpret_as_uint() {
    k + 1U
  } else {
    (qn + 1).reinterpret_as_uint() - k
  }
  self.update(low, low + symbol, total, false)
}

///|
/// `ff_opus_rc_enc_laplace`.
pub fn OpusRangeEncoder::encode_laplace(
  self : OpusRangeEncoder,
  value : Int,
  symbol : UInt32,
  decay : Int,
) -> (UInt32, Int) {
  let mut symbol = symbol
  let mut low = symbol
  let mut i = 1
  let val = value.abs()
  let pos = if value > 0 { 1 } else { 0 }
  if val == 0 {
    self.update(0U, symbol, 1U << 15, true)
    return (symbol, value)
  }
  symbol = (((32768U - 32U - symbol) * (16384U - decay.reinterpret_as_uint())) >> 15)
  while i < val && symbol != 0U {
    low += (symbol << 1) + 2U
    symbol = (symbol * decay.reinterpret_as_uint()) >> 14
    i += 1
  }
  let mut out_value = value
  if symbol != 0U {
    symbol += 1U
    low += symbol * pos.reinterpret_as_uint()
  } else {
    let distance = (val - i).min(
      ((((32768 - low.reinterpret_as_int()) - (if pos != 0 { 0 } else { 1 })) >> 1) - 1),
    )
    low += (pos + (distance << 1)).reinterpret_as_uint()
    symbol = (1).min(32768 - low.reinterpret_as_int()).reinterpret_as_uint()
    out_value = (if value < 0 { -1 } else { 1 }) * (distance + i)
  }
  self.update(low, low + symbol, 1U << 15, true)
  (symbol, out_value)
}

///|
/// `ff_opus_rc_enc_end`: flush the range coder, merge the raw-bit region and
/// write `min(size, produced)` bytes worth of frame into `dst[dst_off..]`.
/// Returns the number of bytes written (always `size` when called per frame).
pub fn OpusRangeEncoder::end(
  self : OpusRangeEncoder,
  dst : FixedArray[Byte],
  dst_off : Int,
  size : Int,
) -> Unit {
  // C: opus_ilog(range) == opus_rc_ilog(range)
  let mut bits = 32 - opus_rc_ilog(self.range)
  let mut mask = 0x7FFFFFFFU >> bits
  let not_mask = mask ^ 0xFFFFFFFFU
  let mut end = (self.value + mask) & not_mask
  if (end | mask) >= self.value + self.range {
    bits += 1
    mask = mask >> 1
    end = (self.value + mask) & (mask ^ 0xFFFFFFFFU)
  }
  while bits > 0 {
    self.carryout((end >> 23).reinterpret_as_int())
    end = (end << 8) & 0x7FFFFFFFU
    bits -= 8
  }
  if self.rem >= 0 || self.ext > 0 {
    self.carryout(0)
  }
  let rng_bytes = self.rng_pos
  for i in 0..<rng_bytes.min(size) {
    dst[dst_off + i] = self.buf[i]
  }
  // merge raw bits (written top-down) into the tail of the frame
  if self.rb_bytes > 0 || self.rb_cachelen > 0 {
    self.put_raw(0U, 32 - self.rb_cachelen)
    let n = self.rb_bytes
    // memory order (ascending addresses) = flushed words in reverse
    let words = self.raw.length()
    let src : Array[Byte] = []
    for w = words - 1; w >= 0; w = w - 1 {
      let v = self.raw[w]
      src.push((v >> 24).to_byte())
      src.push(((v >> 16) & 0xFFU).to_byte())
      src.push(((v >> 8) & 0xFFU).to_byte())
      src.push((v & 0xFFU).to_byte())
    }
    let dst_start = dst_off + (size - n).max(0)
    let lap = (dst_off + rng_bytes) - dst_start
    for i in 0..<lap {
      if dst_start + i < dst.length() {
        dst[dst_start + i] = (dst[dst_start + i].to_int() | src[i].to_int()).to_byte()
      }
    }
    for i in lap.max(0)..<n {
      if dst_start + i < dst.length() {
        dst[dst_start + i] = src[i]
      }
    }
  }
}

///|
/// Number of range-coded bytes currently in the buffer (for tests).
pub fn OpusRangeEncoder::rng_bytes(self : OpusRangeEncoder) -> Int {
  self.rng_pos
}

///|
/// `OPUS_RC_CHECKPOINT_SPAWN` / `ROLLBACK`: full encoder state snapshot.
pub struct OpusEncRcSnapshot {
  tell_frac : Int
  value : UInt32
  range : UInt32
  total_bits : Int32
  rem : Int32
  ext : Int32
  rng_pos : Int
  raw_len : Int
  rb_bytes : Int32
  rb_cachelen : Int32
  rb_cacheval : UInt32
}

///|
pub fn OpusRangeEncoder::snapshot(self : OpusRangeEncoder) -> OpusEncRcSnapshot {
  {
    tell_frac: self.tell_frac(),
    value: self.value,
    range: self.range,
    total_bits: self.total_bits,
    rem: self.rem,
    ext: self.ext,
    rng_pos: self.rng_pos,
    raw_len: self.raw.length(),
    rb_bytes: self.rb_bytes,
    rb_cachelen: self.rb_cachelen,
    rb_cacheval: self.rb_cacheval,
  }
}

///|
pub fn OpusRangeEncoder::rollback(
  self : OpusRangeEncoder,
  s : OpusEncRcSnapshot,
) -> Unit {
  self.value = s.value
  self.range = s.range
  self.total_bits = s.total_bits
  self.rem = s.rem
  self.ext = s.ext
  self.rng_pos = s.rng_pos
  self.raw.truncate(s.raw_len)
  self.rb_bytes = s.rb_bytes
  self.rb_cachelen = s.rb_cachelen
  self.rb_cacheval = s.rb_cacheval
}

///|
/// `ff_opus_rc_enc_end` variant writing into `out[off..off+size]` for frame
/// slot `slot` of a multi-frame packet.
pub fn OpusRangeEncoder::end_frame(
  self : OpusRangeEncoder,
  _slot : Int,
  out : Array[Byte],
  off : Int,
  size : Int,
) -> Unit {
  let dst : FixedArray[Byte] = FixedArray::make(size, b'\x00')
  self.end(dst, 0, size)
  for i in 0..<size {
    out[off + i] = dst[i]
  }
}
