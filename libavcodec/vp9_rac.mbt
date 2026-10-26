///|
/// MoonBit port of the VP9 boolean/range decoder from FFmpeg 9.0.2:
/// `libavcodec/vpx_rac.h`, `libavcodec/vpx_rac.c`,
/// `libavcodec/vp89_rac.h` and the probability-update helpers in
/// `libavcodec/vp9.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C decoder relies on `AV_INPUT_BUFFER_PADDING_SIZE` zero bytes after the
/// buffer.  MoonBit `Bytes` are exact, so the two-byte refills and the initial
/// 24-bit code word synthesize zero bytes instead of reading past the declared
/// range.  This is observationally identical for valid streams (the padding is
/// required to be zero by the FFmpeg API contract).
///
/// Scope: the arithmetic decoder itself plus `update_prob`.  Tile coefficient
/// decoding and probability-context persistence are left to a future decoder
/// slice.

///|
/// `VPXRangeCoder`.
pub struct Vp9RangeDecoder {
  data : Bytes
  mut high : Int32
  mut bits : Int32
  mut pos : Int32
  end : Int32
  mut code_word : UInt32
  mut end_reached : Int32
}

///|
/// `ff_vpx_norm_shift`: the table has 8 at index 0 and otherwise
/// `7 - floor(log2(v))`.  Deriving it avoids transcribing 256 bytes.
fn vp9_norm_shift(v : Int32) -> Int32 {
  if v <= 0 {
    return 8
  }
  let mut value = v
  let mut shift = 0
  while value < 128 {
    value = value << 1
    shift = shift + 1
  }
  shift
}

///|
/// `ff_vpx_init_range_decoder`, parameterized by an offset into `data`.
pub fn vp9_rac_init(
  data : Bytes,
  offset : Int32,
  size : Int32,
) -> Result[Vp9RangeDecoder, String] {
  if size < 1 {
    return Err("vp9: empty range-coded header")
  }
  if offset < 0 || offset + size > data.length() {
    return Err("vp9: range-coded header exceeds packet")
  }
  let b0 = if offset < data.length() { data[offset].to_uint() } else { 0U }
  let b1 = if offset + 1 < data.length() {
    data[offset + 1].to_uint()
  } else {
    0U
  }
  let b2 = if offset + 2 < data.length() {
    data[offset + 2].to_uint()
  } else {
    0U
  }
  Ok({
    data,
    high: 255,
    bits: -16,
    // bytestream_get_be24 always advances three bytes, even when the declared
    // range is shorter and the remaining bytes come from zero padding.
    pos: offset + 3,
    end: offset + size,
    code_word: (b0 << 16) | (b1 << 8) | b2,
    end_reached: 0,
  })
}

///|
/// `vpx_rac_is_end`: the decoder has drained the declared range (the > 10
/// counter gives truncated streams a little slack, mirroring the C). */
pub fn vp9_rac_is_end(c : Vp9RangeDecoder) -> Bool {
  if c.end <= c.pos && c.bits >= 0 {
    c.end_reached = c.end_reached + 1
  }
  c.end_reached > 10
}

///|
/// `vpx_rac_renorm`: returns the renormalized code word. */
fn vp9_rac_renorm(c : Vp9RangeDecoder) -> UInt32 {
  let shift = vp9_norm_shift(c.high)
  let mut code_word = c.code_word
  c.high = c.high << shift
  code_word = code_word << shift
  c.bits = c.bits + shift
  if c.bits >= 0 && c.pos < c.end {
    let b0 = if c.pos < c.data.length() { c.data[c.pos].to_uint() } else { 0U }
    let b1 = if c.pos + 1 < c.data.length() {
      c.data[c.pos + 1].to_uint()
    } else {
      0U
    }
    code_word = code_word | (((b0 << 8) | b1) << c.bits)
    c.pos = c.pos + 2
    c.bits = c.bits - 16
  }
  c.code_word = code_word
  code_word
}

///|
/// `vpx_rac_get_prob` (and `vpx_rac_get_prob_branchy`; the branch placement
/// only affects performance in the C).
pub fn vp9_rac_get_prob(c : Vp9RangeDecoder, prob : Int32) -> Int32 {
  let code_word = vp9_rac_renorm(c)
  let low = 1 + (((c.high - 1) * prob) >> 8)
  let low_shift = (low << 16).reinterpret_as_uint()
  let bit = code_word >= low_shift
  if bit {
    c.high = c.high - low
    c.code_word = code_word - low_shift
  } else {
    c.high = low
    c.code_word = code_word
  }
  if bit {
    1
  } else {
    0
  }
}

///|
/// `vpx_rac_get`: the equiprobable variant with `low = (high + 1) >> 1`.
/// Note that this is not the same rounding as `vpx_rac_get_prob(c, 128)`;
/// both are used by VP9 (`vp89_rac_get` uses the latter).
pub fn vp9_rac_get(c : Vp9RangeDecoder) -> Int32 {
  let code_word = vp9_rac_renorm(c)
  let low = (c.high + 1) >> 1
  let low_shift = (low << 16).reinterpret_as_uint()
  let bit = code_word >= low_shift
  if bit {
    c.high = c.high - low
    c.code_word = code_word - low_shift
  } else {
    c.high = low
    c.code_word = code_word
  }
  if bit {
    1
  } else {
    0
  }
}

///|
/// `vp89_rac_get`: equiprobable decision through the probability-128 path.
pub fn vp9_rac_get_bool(c : Vp9RangeDecoder) -> Int32 {
  vp9_rac_get_prob(c, 128)
}

///|
/// `vp89_rac_get_uint`.
pub fn vp9_rac_get_uint(c : Vp9RangeDecoder, bits : Int32) -> Int32 {
  let mut value = 0
  for _ in 0..<bits {
    value = (value << 1) | vp9_rac_get_bool(c)
  }
  value
}

///|
fn vp9_inv_recenter_nonneg(v : Int32, m : Int32) -> Int32 {
  if v > 2 * m {
    return v
  }
  if (v & 1) != 0 {
    m - ((v + 1) >> 1)
  } else {
    m + (v >> 1)
  }
}

///|
/// `inv_map_table` from `vp9.c:update_prob`.
let vp9_inv_map_table : Array[Int32] = [
  7, 20, 33, 46, 59, 72, 85, 98, 111, 124, 137, 150, 163, 176, 189, 202, 215, 228,
  241, 254, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22,
  23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43,
  44, 45, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 61, 62, 63, 64, 65,
  66, 67, 68, 69, 70, 71, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 86, 87,
  88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 99, 100, 101, 102, 103, 104, 105, 106,
  107, 108, 109, 110, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123,
  125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 138, 139, 140, 141,
  142, 143, 144, 145, 146, 147, 148, 149, 151, 152, 153, 154, 155, 156, 157, 158,
  159, 160, 161, 162, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
  177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 190, 191, 192, 193,
  194, 195, 196, 197, 198, 199, 200, 201, 203, 204, 205, 206, 207, 208, 209, 210,
  211, 212, 213, 214, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227,
  229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 242, 243, 244, 245,
  246, 247, 248, 249, 250, 251, 252, 253, 253,
]

///|
/// `update_prob`: differential forward probability update.  `p` only affects
/// the returned probability; every bit consumed by this function depends on
/// fixed probabilities (128), which lets callers that do not model the full
/// probability context still consume the syntax exactly.
pub fn vp9_rac_update_prob(c : Vp9RangeDecoder, p : Int32) -> Int32 {
  let d = if vp9_rac_get_prob(c, 128) == 0 {
    vp9_rac_get_uint(c, 4)
  } else if vp9_rac_get_prob(c, 128) == 0 {
    vp9_rac_get_uint(c, 4) + 16
  } else if vp9_rac_get_prob(c, 128) == 0 {
    vp9_rac_get_uint(c, 5) + 32
  } else {
    let mut value = vp9_rac_get_uint(c, 7)
    if value >= 65 {
      value = (value << 1) - 65 + vp9_rac_get_bool(c)
    }
    value + 64
  }
  if p <= 128 {
    1 + vp9_inv_recenter_nonneg(vp9_inv_map_table[d], p - 1)
  } else {
    255 - vp9_inv_recenter_nonneg(vp9_inv_map_table[d], 255 - p)
  }
}
