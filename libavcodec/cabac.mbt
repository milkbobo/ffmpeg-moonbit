///|
/// MoonBit port of the H.264 CABAC arithmetic decoding core from FFmpeg
/// 9.0.2: `libavcodec/cabac.c` (`ff_init_cabac_decoder`) and
/// `libavcodec/cabac_functions.h` (`refill`, `refill2`,
/// `renorm_cabac_decoder_once`, `get_cabac_inline`, `get_cabac_bypass`,
/// `get_cabac_bypass_sign`, `get_cabac_terminate`), plus the per-slice context
/// initialisation `ff_h264_init_cabac_states` from `h264_cabac.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2003
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Port notes:
///   * `CABAC_BITS == 16`, `CABAC_MASK == 0xFFFF`, so `low` is a 32-bit
///     wrapping accumulator exactly as in the C (`Int` is 32-bit and wraps).
///   * The byte stream is a `Bytes` plus a cursor; reads past the end yield 0,
///     matching the C's reliance on `AV_INPUT_BUFFER_PADDING_SIZE`.
///   * `ff_init_cabac_decoder` keeps the portable (non pointer-alignment
///     dependent) form of the C: two bytes plus the two guard bits of the
///     third. The C's `((uintptr_t)bytestream & 1) == 0` branch only exists to
///     keep later two-byte loads aligned and decodes the same bit sequence.
///   * `ff_ctz(low)` is computed by a loop (`h264_cabac_ctz`); the C's
///     `HAVE_FAST_CLZ` path is an optimisation only.

///|
/// `H264_NORM_SHIFT_OFFSET`. */
let h264_cabac_norm_shift_offset : Int32 = 0

///|
/// `H264_LPS_RANGE_OFFSET`. */
let h264_cabac_lps_range_offset : Int32 = 512

///|
/// `H264_MLPS_STATE_OFFSET`. */
let h264_cabac_mlps_state_offset : Int32 = 1024

///|
/// `CABAC_BITS`. */
let cabac_bits : Int32 = 16

///|
/// `CABAC_MASK`. */
let cabac_mask : Int32 = 0xFFFF

///|
/// `ff_ctz` for a value with at least one set bit (the C only calls it on
/// `low`, which always has a guard bit set when `refill2` runs). */
fn h264_cabac_ctz(v : Int32) -> Int32 {
  let mut n = 0
  while n < 32 && ((v >> n) & 1) == 0 {
    n = n + 1
  }
  n
}

///|
/// `ff_h264_norm_shift[range]`. */
fn h264_cabac_norm_shift(range : Int32) -> Int32 {
  h264_cabac_tables[h264_cabac_norm_shift_offset + range]
}

///|
/// `ff_h264_lps_range[2*(range&0xC0) + state]`. */
fn h264_cabac_lps_range(range : Int32, state : Int32) -> Int32 {
  h264_cabac_tables[h264_cabac_lps_range_offset + 2 * (range & 0xC0) + state]
}

///|
/// `(ff_h264_mlps_state+128)[s]`: the next context state after coding `s`. */
fn h264_cabac_mlps_state(s : Int32) -> Int32 {
  h264_cabac_tables[h264_cabac_mlps_state_offset + 128 + s]
}

///|
/// `CABACContext`. `start` is `bytestream_start`, `pos` the current
/// `bytestream` (in bytes, relative to the buffer).
pub struct CabacContext {
  mut low : Int32
  mut range : Int32
  bytes : Bytes
  start : Int32
  mut pos : Int32
}

///|
/// Byte at `off` bytes from the cursor, zero past the end (C padding). */
fn CabacContext::byte_at(self : CabacContext, off : Int32) -> Int32 {
  let i = self.pos + off
  if i < 0 || i >= self.bytes.length() {
    0
  } else {
    self.bytes[i].to_int()
  }
}

///|
/// `ff_init_cabac_decoder(c, buf, buf_size)`: `off` is the byte offset of the
/// CABAC payload inside `bytes` (`buf`). Returns `Err("EINVAL")` when the
/// initial window is already out of range, like the C's
/// `AVERROR_INVALIDDATA`.
pub fn ff_init_cabac_decoder(
  bytes : Bytes,
  off : Int32,
) -> Result[CabacContext, String] {
  let c : CabacContext = { low: 0, range: 0x1FE, bytes, start: off, pos: off, }
  c.low = (c.byte_at(0) << 18) + (c.byte_at(1) << 10) + (1 << 9)
  c.pos = off + 2
  if c.range << (cabac_bits + 1) < c.low {
    return Err("EINVAL")
  }
  Ok(c)
}

///|
/// `skip_bytes(c, 0)` / `cabac_reinit`: rewind the pending guard bits and
/// reinitialise the arithmetic decoder at the resulting byte position.
fn CabacContext::reinit(self : CabacContext) -> Result[Unit, String] {
  let mut ptr = self.pos
  if (self.low & 1) != 0 {
    ptr = ptr - 1
  }
  if (self.low & 0x1FF) != 0 {
    ptr = ptr - 1
  }
  match ff_init_cabac_decoder(self.bytes, ptr) {
    Ok(c) => {
      self.low = c.low
      self.range = c.range
      self.pos = c.pos
      Ok(())
    }
    Err(e) => Err(e)
  }
}

///|
/// `refill`. */
fn CabacContext::refill(self : CabacContext) -> Unit {
  self.low = self.low + ((self.byte_at(0) << 9) + (self.byte_at(1) << 1))
  self.low = self.low - cabac_mask
  if self.pos < self.bytes.length() {
    self.pos = self.pos + cabac_bits / 8
  }
}

///|
/// `refill2`: pull the next 16 bits into the zero run of `low`. The C uses
/// `ff_ctz(low) - CABAC_BITS` as the shift; `low`'s low 16 bits are known to be
/// zero here, so the shift is never negative.
fn CabacContext::refill2(self : CabacContext) -> Unit {
  let i = h264_cabac_ctz(self.low) - cabac_bits
  let mut x = -cabac_mask
  x = x + ((self.byte_at(0) << 9) + (self.byte_at(1) << 1))
  if i >= 0 {
    self.low = self.low + (x << i)
  } else {
    self.low = self.low + (x >> -i)
  }
  if self.pos < self.bytes.length() {
    self.pos = self.pos + cabac_bits / 8
  }
}

///|
/// `renorm_cabac_decoder_once`. */
fn CabacContext::renorm_once(self : CabacContext) -> Unit {
  // `shift = (uint32_t)(range - 0x100) >> 31`, i.e. 1 when range <= 0xFF.
  let shift = (self.range - 0x100).reinterpret_as_uint() >> 31
  let s = shift.reinterpret_as_int()
  self.range = self.range << s
  self.low = self.low << s
  if (self.low & cabac_mask) == 0 {
    self.refill()
  }
}

///|
/// `get_cabac_inline` (`get_cabac` / `get_cabac_noinline`): decode one bit with
/// the context `ctx` (`state` in the C), updating `states[ctx]`.
pub fn CabacContext::get_cabac(
  self : CabacContext,
  states : Array[Int32],
  ctx : Int32,
) -> Int32 {
  let mut s = states[ctx]
  let range_lps = h264_cabac_lps_range(self.range, s)
  self.range = self.range - range_lps
  let lps_mask = ((self.range << (cabac_bits + 1)) - self.low) >> 31
  self.low = self.low - ((self.range << (cabac_bits + 1)) & lps_mask)
  self.range = self.range + ((range_lps - self.range) & lps_mask)
  s = s ^ lps_mask
  states[ctx] = h264_cabac_mlps_state(s)
  let bit = s & 1
  let shift = h264_cabac_norm_shift(self.range)
  self.range = self.range << shift
  self.low = self.low << shift
  if (self.low & cabac_mask) == 0 {
    self.refill2()
  }
  bit
}

///|
/// `get_cabac_bypass`. */
pub fn CabacContext::get_cabac_bypass(self : CabacContext) -> Int32 {
  self.low = self.low + self.low
  if (self.low & cabac_mask) == 0 {
    self.refill()
  }
  let range = self.range << (cabac_bits + 1)
  if self.low < range {
    0
  } else {
    self.low = self.low - range
    1
  }
}

///|
/// `get_cabac_bypass_sign`: bypass bit that also flips the sign of `val`. */
pub fn CabacContext::get_cabac_bypass_sign(
  self : CabacContext,
  val : Int32,
) -> Int32 {
  self.low = self.low + self.low
  if (self.low & cabac_mask) == 0 {
    self.refill()
  }
  let range = self.range << (cabac_bits + 1)
  self.low = self.low - range
  let mask = self.low >> 31
  let masked = range & mask
  self.low = self.low + masked
  (val ^ mask) - mask
}

///|
/// `get_cabac_terminate`: returns 0 when the terminating bit is 0, otherwise
/// the number of bytes consumed (always > 0), which callers treat as "end of
/// slice".
pub fn CabacContext::get_cabac_terminate(self : CabacContext) -> Int32 {
  self.range = self.range - 2
  if self.low < self.range << (cabac_bits + 1) {
    self.renorm_once()
    0
  } else {
    self.pos - self.start
  }
}

///|
/// `ff_h264_init_cabac_states`: derive the 1024 coding states of a slice from
/// the `(m, n)` table and the slice QP. `slice_type_nos` is 2 for I slices and
/// 0 for P slices; `cabac_init_idc` only matters for the latter.
pub fn ff_h264_init_cabac_states(
  slice_qp : Int32,
  bit_depth_luma : Int32,
  slice_type_nos : Int32,
  cabac_init_idc : Int32,
) -> Array[Int32] {
  let qp = if slice_qp - 6 * (bit_depth_luma - 8) < 0 {
    0
  } else if slice_qp - 6 * (bit_depth_luma - 8) > 51 {
    51
  } else {
    slice_qp - 6 * (bit_depth_luma - 8)
  }
  let tab = if slice_type_nos == 2 {
    h264_cabac_context_init_i
  } else {
    let idc = if cabac_init_idc < 0 {
      0
    } else if cabac_init_idc > 2 {
      2
    } else {
      cabac_init_idc
    }
    h264_cabac_context_init_pb[idc]
  }
  let out : Array[Int32] = Array::make(1024, 0)
  for i = 0; i < 1024; i = i + 1 {
    let mut pre = 2 * (((tab[i][0] * qp) >> 4) + tab[i][1]) - 127
    pre = pre ^ (pre >> 31)
    if pre > 124 {
      pre = 124 + (pre & 1)
    }
    out[i] = pre
  }
  out
}
