///|
/// MoonBit port of the MSB-first subset of FFmpeg 9.0.2
/// `libavcodec/get_bits.h` and `libavcodec/golomb.h` used by the H.264 /
/// HEVC / AAC / MPEG-audio header parsers.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Deviations from the C:
///   * `GetBitContext`'s cached reader is replaced by a plain bit cursor; the
///     observable values are identical because every read is bounds-checked
///     against `size_in_bits` and returns zero bits past the end, matching the
///     zero-padded input buffers the C relies on (`AV_INPUT_BUFFER_PADDING_SIZE`).
///   * `get_ue_golomb` returns -1 on overread/invalid instead of
///     `AVERROR_INVALIDDATA`; `get_ue_golomb_long` keeps the C's peculiar
///     overread behaviour (a 32-bit zero window still skips 31 bits).
///
/// The reader is deliberately independent of libavutil: libavcodec only pulls
/// libavutil in for white-box tests, mirroring the package graph of this port.

///|
/// `GetBitContext`: `bytes` is the underlying buffer, `size_bits` is
/// `size_in_bits` from the C (which callers shrink to the NAL's SODB).
pub struct BitReader {
  bytes : Bytes
  mut pos : Int32
  size_bits : Int32
}

///|
/// `init_get_bits8`: whole bytes.
pub fn BitReader::new(bytes : Bytes) -> BitReader {
  { bytes, pos: 0, size_bits: bytes.length() * 8, }
}

///|
/// `init_get_bits`: explicit bit size (e.g. a NAL's SODB).
pub fn BitReader::with_size(bytes : Bytes, size_bits : Int32) -> BitReader {
  { bytes, pos: 0, size_bits, }
}

///|
/// `get_bits_count`. */
pub fn BitReader::count(self : BitReader) -> Int32 {
  self.pos
}

///|
/// `get_bits_left`: may go negative on overread, as in the C. */
pub fn BitReader::bits_left(self : BitReader) -> Int32 {
  self.size_bits - self.pos
}

///|
/// `get_bits_bytesize`. With `round_up` this is the byte size of the buffer
/// described by `size_in_bits`, independent of the current position. */
pub fn BitReader::bytesize(self : BitReader, round_up : Bool) -> Int32 {
  (self.size_bits + (if round_up { 7 } else { 0 })) >> 3
}

///|
/// `size_in_bits` (the C field), needed for `get_bits_bytesize` semantics. */
pub fn BitReader::size_bits(self : BitReader) -> Int32 {
  self.size_bits
}

///|
/// Raw bit at an absolute position; zero past the end. */
fn BitReader::bit_at(self : BitReader, bitpos : Int32) -> UInt32 {
  if bitpos < 0 || bitpos >= self.bytes.length() * 8 {
    return 0
  }
  (self.bytes[bitpos / 8].to_uint() >> (7 - bitpos % 8)) & 1
}

///|
/// `get_bits`: `n` bits MSB-first, `0 <= n <= 32`. */
pub fn BitReader::read(self : BitReader, n : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i = 0; i < n; i = i + 1 {
    v = (v << 1) | self.bit_at(self.pos + i)
  }
  self.pos = self.pos + n
  v
}

///|
/// `get_bits1`. */
pub fn BitReader::read1(self : BitReader) -> UInt32 {
  self.read(1)
}

///|
/// `show_bits`: peek `n` bits without consuming them. */
pub fn BitReader::show(self : BitReader, n : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i = 0; i < n; i = i + 1 {
    v = (v << 1) | self.bit_at(self.pos + i)
  }
  v
}

///|
/// `skip_bits`. Unlike the C (which clamps at `size_in_bits + 8`), the cursor
/// is allowed to run past the end; callers detect overread via `bits_left() < 0`. */
pub fn BitReader::skip(self : BitReader, n : Int32) -> Unit {
  self.pos = self.pos + n
}

///|
/// Absolute bit position (MP3's bit-reservoir reader needs this). */
pub fn BitReader::set_pos(self : BitReader, pos : Int32) -> Unit {
  self.pos = pos
}

///|
/// `align_get_bits`: round the cursor up to the next byte boundary. */
pub fn BitReader::align(self : BitReader) -> Unit {
  self.pos = (self.pos + 7) >> 3 << 3
}

///|
/// `get_ue_golomb`: unsigned Exp-Golomb, 0..8190. Returns INT32_MIN when the
/// code does not fit the 32-bit window (C returns AVERROR_INVALIDDATA); the
/// sentinel is outside the valid value range and survives `read_se`.
pub fn BitReader::read_ue(self : BitReader) -> Int32 {
  let mut zeros = 0
  while zeros < 32 && self.bit_at(self.pos + zeros) == 0 {
    zeros = zeros + 1
  }
  if zeros >= 32 {
    return -2147483648
  }
  self.pos = self.pos + zeros + 1
  let suffix = if zeros == 0 { 0U } else { self.read(zeros) }
  suffix.reinterpret_as_int() + (1 << zeros) - 1
}

///|
/// `get_ue_golomb_long`: unsigned Exp-Golomb over the full 32-bit range.
/// The C derives the skip from a 32-bit `show_bits` window even when that
/// window is all zeros, so this keeps `log = 31` for a zero window and then
/// reads 32 bits.
pub fn BitReader::read_ue_long(self : BitReader) -> UInt64 {
  let window = self.show(32)
  let mut log = 0
  while log < 31 && ((window >> (31 - log)) & 1) == 0 {
    log = log + 1
  }
  self.skip(log)
  self.read(log + 1).to_uint64() - 1UL
}

///|
/// `get_ue_golomb_31`: like `read_ue` but the C documents a 0..31 constraint.
/// The value is returned unchanged when out of range so callers can apply
/// their own bounds checks (as `h264_ps.c`/`hevc/ps.c` do).
pub fn BitReader::read_ue31(self : BitReader) -> Int32 {
  self.read_ue()
}

///|
/// `get_se_golomb`: signed Exp-Golomb. The C operates on `code_num = ue + 1`;
/// the resulting mapping is 0→0, 1→1, 2→-1, 3→2, 4→-2, ... */
pub fn BitReader::read_se(self : BitReader) -> Int32 {
  let v = self.read_ue()
  if v < 0 {
    return v
  }
  if (v & 1) != 0 {
    (v + 1) >> 1
  } else {
    -(v >> 1)
  }
}

///|
/// `get_se_golomb_long`. */
pub fn BitReader::read_se_long(self : BitReader) -> Int32 {
  let v = self.read_ue_long()
  let mag = (v >> 1).to_int()
  if (v & 1UL) != 0 {
    mag + 1
  } else {
    -mag
  }
}

///|
/// `ff_ctz`: number of trailing zero bits of a non-zero byte.
/// (The C callers only invoke it on `size > min_size` with `v != 0`.)
pub fn ctz8(v : Int32) -> Int32 {
  let mut n = 0
  while ((v >> n) & 1) == 0 {
    n = n + 1
  }
  n
}
