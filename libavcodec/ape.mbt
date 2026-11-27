///|
/// Monkey's Audio (APE) lossless decoder — MoonBit port of FFmpeg 9.0.2
/// `libavcodec/apedec.c` (the `ff_ape_decoder` pure-algorithm core).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Deviations from the C:
///   * `decode_frame` mirrors one call of `ape_decode_frame`: it decodes
///     `blocks_per_loop` samples (4608 by default, `-max_samples all`
///     semantics via the constructor parameter) and reports `packet_done`,
///     standing in for the C's return-code protocol that keeps re-feeding
///     the same packet until `s->samples` reaches zero.  Old streams
///     (fileversion < 3930) decode a whole packet per call, exactly like
///     the C's non-interleaved-coefficient special case.
///   * The optional CRC verification behind `AV_EF_CRCCHECK` is not ported
///     (FFmpeg's fate suite decodes with it off; only `CRC_state` consumed
///     it).  The signalled CRC value is still parsed.
///   * `bswap_buf` is expressed directly: frame data is read with every
///     aligned 4-byte word byte-reversed, and fileversion < 3950 streams
///     carry the two zero pad bytes the C overreads through
///     `AV_INPUT_BUFFER_PADDING_SIZE`.
///   * A truncated frame decodes the clean `blocks_per_loop` chunks and
///     then raises a decode error, matching the chunked C decoder's
///     observable output on the FATE `NoLegacy-cut` sample.

///|
/// `MAX_CHANNELS`.
let ape_max_channels = 2

///|
/// `APE_FRAMECODE_STEREO_SILENCE`.
let ape_framecode_stereo_silence : UInt32 = 3

///|
/// `APE_FRAMECODE_PSEUDO_STEREO`.
let ape_framecode_pseudo_stereo : UInt32 = 4

///|
/// `HISTORY_SIZE`.
let ape_history_size = 512

///|
/// `PREDICTOR_ORDER`.
let ape_predictor_order = 8

///|
/// `PREDICTOR_SIZE` (total size of all predictor histories).
let ape_predictor_size = 50

///|
/// `YDELAYA`.
let ape_ydelaya : Int32 = 18 + ape_predictor_order * 4

///|
/// `YDELAYB`.
let ape_ydelayb : Int32 = 18 + ape_predictor_order * 3

///|
/// `XDELAYA`.
let ape_xdelaya : Int32 = 18 + ape_predictor_order * 2

///|
/// `XDELAYB`.
let ape_xdelayb : Int32 = 18 + ape_predictor_order

///|
/// `YADAPTCOEFFSA`.
let ape_yadaptcoeffsa : Int32 = 18

///|
/// `XADAPTCOEFFSA`.
let ape_xadaptcoeffsa : Int32 = 14

///|
/// `YADAPTCOEFFSB`.
let ape_yadaptcoeffsb : Int32 = 10

///|
/// `XADAPTCOEFFSB`.
let ape_xadaptcoeffsb : Int32 = 5

///|
/// `COMPRESSION_LEVEL_*`.
let ape_compression_level_fast = 1000

///|
let ape_compression_level_high = 3000

///|
let ape_compression_level_extra_high = 4000

///|
let ape_compression_level_insane = 5000

///|
/// `APE_FILTER_LEVELS`.
let ape_filter_levels = 3

///|
/// `ape_filter_orders[5][APE_FILTER_LEVELS]`.
let ape_filter_orders : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0],
  [16, 0, 0],
  [64, 0, 0],
  [32, 256, 0],
  [16, 256, 1280],
]

///|
/// `ape_filter_fracbits[5][APE_FILTER_LEVELS]`.
let ape_filter_fracbits : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0],
  [11, 0, 0],
  [11, 0, 0],
  [10, 13, 0],
  [11, 13, 15],
]

///|
/// Range coder constants (`CODE_BITS` family).
let ape_extra_bits : Int32 = (32 - 2) % 8 + 1

///|
/// `BOTTOM_VALUE` = `TOP_VALUE >> 8`.
let ape_bottom_value : UInt32 = 1U << 23

///|
/// `counts_3970`: fixed symbol probabilities for Monkey Audio 3.97.
let ape_counts_3970 : FixedArray[Int32] = [
  0, 14824, 28224, 39348, 47855, 53994, 58171, 60926, 62682, 63786, 64463, 64878,
  65126, 65276, 65365, 65419, 65450, 65469, 65480, 65487, 65491, 65493,
]

///|
/// `counts_diff_3970`.
let ape_counts_diff_3970 : FixedArray[Int32] = [
  14824, 13400, 11124, 8507, 6139, 4177, 2755, 1756, 1104, 677, 415, 248, 150, 89,
  54, 31, 19, 11, 7, 4, 2,
]

///|
/// `counts_3980`: fixed symbol probabilities for Monkey Audio 3.98.
let ape_counts_3980 : FixedArray[Int32] = [
  0, 19578, 36160, 48417, 56323, 60899, 63265, 64435, 64971, 65232, 65351, 65416,
  65447, 65466, 65476, 65482, 65485, 65488, 65490, 65491, 65492, 65493,
]

///|
/// `counts_diff_3980`.
let ape_counts_diff_3980 : FixedArray[Int32] = [
  19578, 16582, 12257, 7906, 4576, 2366, 1170, 536, 261, 119, 65, 31, 19, 10, 6,
  3, 3, 2, 1, 1, 1,
]

///|
/// `initial_coeffs_fast_3320`.
let ape_initial_coeffs_fast_3320 : FixedArray[Int32] = [375]

///|
/// `initial_coeffs_a_3800`.
let ape_initial_coeffs_a_3800 : FixedArray[Int32] = [64, 115, 64]

///|
/// `initial_coeffs_b_3800`.
let ape_initial_coeffs_b_3800 : FixedArray[Int32] = [740, 0]

///|
/// `initial_coeffs_3930` (same values in the 64-bit variant).
let ape_initial_coeffs_3930 : FixedArray[Int32] = [360, 317, -109, 98]

///|
/// Unsigned-view helpers: C mixes `int32_t`/`uint32_t` heavily and the wrap
/// semantics differ per expression, so every cast is spelled out at the use
/// site; these shorthands only re-interpret the bit pattern.
fn ape_u(v : Int32) -> UInt32 {
  v.reinterpret_as_uint()
}

///|
fn ape_i(v : UInt32) -> Int32 {
  v.reinterpret_as_int()
}

///|
fn ape_u64(v : Int64) -> UInt64 {
  v.reinterpret_as_uint64()
}

///|
fn ape_i64(v : UInt64) -> Int64 {
  v.reinterpret_as_int64()
}

///|
/// `APESIGN`: -1 for positive, 1 for negative, 0 for zero.
fn ape_sign(x : Int32) -> Int32 {
  (x < 0).to_int() - (x > 0).to_int()
}

///|
/// `av_log2` for `UInt32` (floor; 0 maps to 0 like FFmpeg's table lookup).
fn ape_av_log2(v : UInt32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `av_clip_int16`.
fn ape_clip_int16(v : Int32) -> Int32 {
  if v > 32767 {
    32767
  } else if v < -32768 {
    -32768
  } else {
    v
  }
}

///|
/// `APERice`.
struct ApeRice {
  mut k : UInt32
  mut ksum : UInt32
}

///|
/// `APERangecoder`.
struct ApeRc {
  mut low : UInt32
  mut range : UInt32
  mut help : UInt32
  mut buffer : UInt32
}

///|
/// `APEPredictor` (32-bit path, fileversion < 3950).  `buf` is the index of
/// the C's sliding `p->buf` pointer into `historybuffer`.
struct ApePredictor32 {
  historybuffer : FixedArray[Int32]
  mut buf : Int32
  lastA : FixedArray[Int32]
  filterA : FixedArray[Int32]
  filterB : FixedArray[Int32]
  coeffsA : FixedArray[UInt32]
  coeffsB : FixedArray[UInt32]
  mut sample_pos : UInt32
}

///|
/// `APEPredictor64` (fileversion >= 3950).
struct ApePredictor64 {
  historybuffer : FixedArray[Int64]
  mut buf : Int32
  lastA : FixedArray[Int64]
  filterA : FixedArray[Int64]
  filterB : FixedArray[Int64]
  coeffsA : FixedArray[UInt64]
  coeffsB : FixedArray[UInt64]
}

///|
/// One `APEFilter`: the C's single `int16_t` allocation holds the
/// coefficients (`buf[0..order)`), the sliding adapt region starting at
/// `order` and the delay region starting at `3*order`; `delay`/`adapt` are
/// absolute indices into `buf`.
struct ApeFilter {
  buf : FixedArray[Int16]
  order : Int32
  mut delay : Int32
  mut adapt : Int32
  mut avg : UInt32
}

///|
/// Per-call decode scratch (the C's `decoded`/`interim` buffer halves).
priv struct ApeChannels {
  d0 : Array[Int32]
  d1 : Array[Int32]
  i0 : Array[Int32]
  i1 : Array[Int32]
}

///|
/// One decoded APE chunk. `samples` is interleaved and already shifted the
/// way FFmpeg outputs it: 8-bit as unsigned 0..255, 16-bit as s16, 24-bit
/// left-justified in s32 (value << 8).
pub struct ApeFrame {
  bps : Int32
  channels : Int32
  nb_samples : Int32
  samples : Array[Int32]
}

///|
/// `decode_frame` result: the chunk plus whether the packet is fully
/// consumed (the C's `return !s->samples ? avpkt->size : 0`).
pub struct ApeChunk {
  frame : ApeFrame
  packet_done : Bool
}

///|
/// `APEContext`.
pub struct ApeDecoder {
  channels : Int32
  bps : Int32
  fileversion : Int32
  compression_level : Int32
  fset : Int32
  flags : Int32
  blocks_per_loop : Int32
  mut samples : Int32
  mut crc : UInt32
  mut frameflags : UInt32
  predictor : ApePredictor32
  predictor64 : ApePredictor64
  filters : FixedArray[ApeFilter]
  rc : ApeRc
  rice_x : ApeRice
  rice_y : ApeRice
  mut gb : BitReader
  mut data : Bytes
  mut ptr : Int32
  mut data_end : Int32
  mut has_data : Bool
  mut error : Bool
  mut interim_mode : Int32
}

///|
/// `ape_decode_init`: `extradata` is the six-byte (fileversion,
/// compression level, flags) tuple containers attach to the stream.
pub fn ape_decoder_new(
  extradata : Bytes,
  channels : Int32,
  bits_per_coded_sample : Int32,
  max_samples~ : Int32 = 4608,
) -> Result[ApeDecoder, String] {
  if extradata.length() != 6 {
    return Err("ape: incorrect extradata")
  }
  if channels > ape_max_channels {
    return Err("ape: only mono and stereo is supported")
  }
  let bps = bits_per_coded_sample
  let interim_mode = if bps == 24 { -1 } else { 0 }
  if bps != 8 && bps != 16 && bps != 24 {
    return Err("ape: unsupported bits per coded sample \{bps}")
  }
  let fileversion = ape_le16(extradata, 0)
  let compression_level = ape_le16(extradata, 2)
  let flags = ape_le16(extradata, 4)
  if compression_level % 1000 != 0 ||
    compression_level > ape_compression_level_insane ||
    compression_level == 0 ||
    (fileversion < 3930 && compression_level == ape_compression_level_insane) {
    return Err("ape: incorrect compression level \{compression_level}")
  }
  let fset = compression_level / 1000 - 1
  let filters : FixedArray[ApeFilter] = FixedArray::make(
    ape_filter_levels * 2,
    { buf: FixedArray::make(1, 0), order: 0, delay: 0, adapt: 0, avg: 0, },
  )
  for i = 0; i < ape_filter_levels; i = i + 1 {
    let order = ape_filter_orders[fset][i]
    if order == 0 {
      break
    }
    for ch = 0; ch < 2; ch = ch + 1 {
      filters[i * 2 + ch] = {
        buf: FixedArray::make(order * 3 + ape_history_size, 0),
        order,
        delay: 0,
        adapt: 0,
        avg: 0,
      }
    }
  }
  Ok({
    channels,
    bps,
    fileversion,
    compression_level,
    fset,
    flags,
    blocks_per_loop: max_samples,
    samples: 0,
    crc: 0,
    frameflags: 0,
    predictor: {
      historybuffer: FixedArray::make(ape_history_size + ape_predictor_size, 0),
      buf: 0,
      lastA: FixedArray::make(2, 0),
      filterA: FixedArray::make(2, 0),
      filterB: FixedArray::make(2, 0),
      coeffsA: FixedArray::make(8, 0),
      coeffsB: FixedArray::make(10, 0),
      sample_pos: 0,
    },
    predictor64: {
      historybuffer: FixedArray::make(ape_history_size + ape_predictor_size, 0L),
      buf: 0,
      lastA: FixedArray::make(2, 0L),
      filterA: FixedArray::make(2, 0L),
      filterB: FixedArray::make(2, 0L),
      coeffsA: FixedArray::make(8, 0UL),
      coeffsB: FixedArray::make(10, 0UL),
    },
    filters,
    rc: { low: 0, range: 0, help: 0, buffer: 0, },
    rice_x: { k: 0, ksum: 0, },
    rice_y: { k: 0, ksum: 0, },
    gb: BitReader::new(b""),
    data: b"",
    ptr: 0,
    data_end: 0,
    has_data: false,
    error: false,
    interim_mode,
  })
}

///|
/// `ape_flush`.
pub fn ApeDecoder::flush(self : ApeDecoder) -> Unit {
  self.samples = 0
}

///|
/// Little-endian `u16` read over the extradata.
fn ape_le16(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int() | (data[off + 1].to_int() << 8)
}

///|
/// Big-endian `u32` read advancing `ptr` (`bytestream_get_be32`).
fn ApeDecoder::be32(self : ApeDecoder) -> UInt32 {
  let v = (self.data[self.ptr].to_uint() << 24) |
    (self.data[self.ptr + 1].to_uint() << 16) |
    (self.data[self.ptr + 2].to_uint() << 8) |
    self.data[self.ptr + 3].to_uint()
  self.ptr = self.ptr + 4
  v
}

// ---------------------------------------------------------------------------
// Range decoder (`range_*` functions)
// ---------------------------------------------------------------------------

///|
/// `range_start_decoding`.
fn ApeDecoder::range_start_decoding(self : ApeDecoder) -> Unit {
  self.rc.buffer = if self.ptr < self.data.length() {
    self.data[self.ptr].to_uint()
  } else {
    0
  }
  self.ptr = self.ptr + 1
  self.rc.low = self.rc.buffer >> (8 - ape_extra_bits)
  self.rc.range = 1U << ape_extra_bits
}

///|
/// `range_dec_normalize`.
fn ApeDecoder::range_dec_normalize(self : ApeDecoder) -> Unit {
  while self.rc.range <= ape_bottom_value {
    self.rc.buffer = self.rc.buffer << 8
    if self.ptr < self.data_end {
      self.rc.buffer = self.rc.buffer + self.data[self.ptr].to_uint()
      self.ptr = self.ptr + 1
    } else {
      self.error = true
    }
    self.rc.low = (self.rc.low << 8) | ((self.rc.buffer >> 1) & 0xFF)
    self.rc.range = self.rc.range << 8
  }
}

///|
/// `range_decode_culfreq`.
fn ApeDecoder::range_decode_culfreq(self : ApeDecoder, tot_f : Int32) -> Int32 {
  self.range_dec_normalize()
  self.rc.help = self.rc.range / ape_u(tot_f)
  ape_i(self.rc.low / self.rc.help)
}

///|
/// `range_decode_culshift`.
fn ApeDecoder::range_decode_culshift(self : ApeDecoder, shift : Int32) -> Int32 {
  self.range_dec_normalize()
  self.rc.help = self.rc.range >> shift
  ape_i(self.rc.low / self.rc.help)
}

///|
/// `range_decode_update`.
fn ApeDecoder::range_decode_update(
  self : ApeDecoder,
  sy_f : Int32,
  lt_f : Int32,
) -> Unit {
  self.rc.low = self.rc.low - self.rc.help * ape_u(lt_f)
  self.rc.range = self.rc.help * ape_u(sy_f)
}

///|
/// `range_decode_bits` (n <= 16 in practice, C says <= 16).
fn ApeDecoder::range_decode_bits(self : ApeDecoder, n : Int32) -> Int32 {
  let sym = self.range_decode_culshift(n)
  self.range_decode_update(1, sym)
  sym
}

///|
/// `range_get_symbol`.
fn ApeDecoder::range_get_symbol(
  self : ApeDecoder,
  counts : FixedArray[Int32],
  counts_diff : FixedArray[Int32],
) -> Int32 {
  let cf = self.range_decode_culshift(16)
  if cf > 65492 {
    let symbol = cf - 65535 + 63
    self.range_decode_update(1, cf)
    if cf > 65535 {
      self.error = true
    }
    return symbol
  }
  // figure out the symbol inefficiently; a binary search would be much better
  let mut symbol = 0
  while counts[symbol + 1] <= cf {
    symbol = symbol + 1
  }
  self.range_decode_update(counts_diff[symbol], counts[symbol])
  symbol
}

// ---------------------------------------------------------------------------
// Rice decoding (`update_rice`, `ape_decode_value_*`)
// ---------------------------------------------------------------------------

///|
/// `update_rice`.
fn ape_update_rice(rice : ApeRice, x : UInt32) -> Unit {
  let lim = if rice.k != 0 { 1U << ape_i(rice.k + 4U) } else { 0 }
  rice.ksum = rice.ksum + (x + 1U) / 2U - ((rice.ksum + 16U) >> 5)
  if rice.ksum < lim {
    rice.k = rice.k - 1
  } else if rice.ksum >= 1U << ape_i(rice.k + 5U) && rice.k < 24U {
    rice.k = rice.k + 1
  }
}

///|
/// `get_k`.
fn ape_get_k(ksum : UInt32) -> UInt32 {
  ape_av_log2(ksum).reinterpret_as_uint() + (ksum != 0).to_uint()
}

///|
/// `get_unary(gb, stop, len)`.
fn ape_get_unary(gb : BitReader, stop : Int32, len : Int32) -> UInt32 {
  let mut i = 0
  while i < len && gb.read1().reinterpret_as_int() != stop {
    i = i + 1
  }
  i.reinterpret_as_uint()
}

///|
/// `get_rice_ook`.
fn ape_get_rice_ook(gb : BitReader, k : Int32) -> UInt32 {
  let mut x = ape_get_unary(gb, 1, gb.bits_left())
  if k != 0 {
    x = (x << k) | gb.read(k)
  }
  x
}

///|
/// `ape_decode_value_3860` (rice family with unary overflow).
fn ApeDecoder::decode_value_3860(
  self : ApeDecoder,
  gb : BitReader,
  rice : ApeRice,
) -> Int32 {
  let mut overflow = ape_get_unary(gb, 1, gb.bits_left())
  if self.fileversion > 3880 {
    while overflow >= 16 {
      overflow = overflow - 16
      rice.k = rice.k + 4U
    }
  }
  let x : UInt32 = if rice.k == 0 {
    overflow
  } else if rice.k <= 25U {
    (overflow << ape_i(rice.k)) + gb.read(ape_i(rice.k))
  } else {
    self.error = true
    return 0
  }
  rice.ksum = rice.ksum + x - ((rice.ksum + 8U) >> 4)
  if rice.ksum < (if rice.k != 0 { 1U << ape_i(rice.k + 4U) } else { 0 }) {
    rice.k = rice.k - 1
  } else if rice.ksum >= 1U << ape_i(rice.k + 5U) && rice.k < 24U {
    rice.k = rice.k + 1
  }
  // Convert to signed
  ape_i(((x >> 1) ^ ((x & 1) - 1)) + 1)
}

///|
/// `ape_decode_value_3900` (range-coded rice family, 3.97 tables).
fn ApeDecoder::decode_value_3900(self : ApeDecoder, rice : ApeRice) -> Int32 {
  let mut overflow = self
    .range_get_symbol(ape_counts_3970, ape_counts_diff_3970)
    .reinterpret_as_uint()
  let is_escape = overflow == 63
  let tmpk : Int32 = if is_escape {
    self.range_decode_bits(5)
  } else if rice.k < 1 {
    0
  } else {
    ape_i(rice.k) - 1
  }
  if is_escape {
    overflow = 0
  }
  let mut x : UInt32 = 0
  if tmpk <= 16 || self.fileversion < 3910 {
    if tmpk > 23 {
      self.error = true
      return 0
    }
    x = ape_u(self.range_decode_bits(tmpk))
  } else if tmpk <= 31 {
    x = ape_u(self.range_decode_bits(16))
    x = x | (ape_u(self.range_decode_bits(tmpk - 16)) << 16)
  } else {
    self.error = true
    return 0
  }
  x = x + (overflow << tmpk)
  ape_update_rice(rice, x)
  // Convert to signed
  ape_i(((x >> 1) ^ ((x & 1) - 1)) + 1)
}

///|
/// `ape_decode_value_3990` (range-coded rice family, 3.98 tables + pivot).
fn ApeDecoder::decode_value_3990(self : ApeDecoder, rice : ApeRice) -> Int32 {
  let pivot = if rice.ksum >> 5 > 1 { rice.ksum >> 5 } else { 1 }
  let mut overflow = self
    .range_get_symbol(ape_counts_3980, ape_counts_diff_3980)
    .reinterpret_as_uint()
  if overflow == 63 {
    overflow = ape_u(self.range_decode_bits(16)) << 16
    overflow = overflow | ape_u(self.range_decode_bits(16))
  }
  let base : UInt32 = if pivot < 0x10000 {
    let b = self.range_decode_culfreq(ape_i(pivot))
    self.range_decode_update(1, b)
    ape_u(b)
  } else {
    let mut base_hi = ape_i(pivot)
    let mut bbits = 0
    while (base_hi & -65536) != 0 {
      base_hi = base_hi >> 1
      bbits = bbits + 1
    }
    let hi = self.range_decode_culfreq(base_hi + 1)
    self.range_decode_update(1, hi)
    let lo = self.range_decode_culfreq(1 << bbits)
    self.range_decode_update(1, lo)
    (ape_u(hi) << bbits) + ape_u(lo)
  }
  let x = base + overflow * pivot
  ape_update_rice(rice, x)
  // Convert to signed
  ape_i(((x >> 1) ^ ((x & 1) - 1)) + 1)
}

// ---------------------------------------------------------------------------
// Entropy decoding (`decode_array_0000`, `entropy_decode_*`)
// ---------------------------------------------------------------------------

///|
/// `FFMIN`.
fn ape_min32(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// `decode_array_0000`.
fn ApeDecoder::decode_array_0000(
  self : ApeDecoder,
  out : Array[Int32],
  rice : ApeRice,
  blockstodecode : Int32,
) -> Unit {
  rice.ksum = 0
  let mut i = 0
  let lim5 = ape_min32(blockstodecode, 5)
  while i < lim5 {
    out[i] = ape_i(ape_get_rice_ook(self.gb, 10))
    rice.ksum = rice.ksum + ape_u(out[i])
    i = i + 1
  }
  if blockstodecode > 5 {
    rice.k = ape_get_k(rice.ksum / 10)
    if rice.k < 24 {
      let lim64 = ape_min32(blockstodecode, 64)
      while i < lim64 {
        out[i] = ape_i(ape_get_rice_ook(self.gb, ape_i(rice.k)))
        rice.ksum = rice.ksum + ape_u(out[i])
        rice.k = ape_get_k(rice.ksum / ape_u((i + 1) * 2))
        if rice.k >= 24 {
          return
        }
        i = i + 1
      }
      if blockstodecode > 64 {
        rice.k = ape_get_k(rice.ksum >> 7)
        let mut ksummax = 1U << ape_i(rice.k + 7U)
        let mut ksummin = if rice.k != 0 { 1U << ape_i(rice.k + 6U) } else { 0 }
        while i < blockstodecode {
          if self.gb.bits_left() < 1 {
            self.error = true
            return
          }
          out[i] = ape_i(ape_get_rice_ook(self.gb, ape_i(rice.k)))
          rice.ksum = rice.ksum + ape_u(out[i]) - ape_u(out[i - 64])
          while rice.ksum < ksummin {
            rice.k = rice.k - 1
            ksummin = if rice.k != 0 { ksummin >> 1 } else { 0 }
            ksummax = ksummax >> 1
          }
          while rice.ksum >= ksummax {
            rice.k = rice.k + 1
            if rice.k > 24 {
              return
            }
            ksummax = ksummax << 1
            ksummin = if ksummin != 0 { ksummin << 1 } else { 128 }
          }
          i = i + 1
        }
      }
    }
  }
  // end: convert to signed (int32_t semantics: arithmetic shift)
  for j = 0; j < blockstodecode; j = j + 1 {
    out[j] = ((out[j] >> 1) ^ ((out[j] & 1) - 1)) + 1
  }
}

///|
/// `entropy_decode_mono_0000` / `entropy_decode_stereo_0000`.
fn ApeDecoder::entropy_decode_0000(
  self : ApeDecoder,
  ch : ApeChannels,
  blockstodecode : Int32,
  stereo : Bool,
) -> Unit {
  self.decode_array_0000(ch.d0, self.rice_y, blockstodecode)
  if stereo {
    self.decode_array_0000(ch.d1, self.rice_x, blockstodecode)
  }
}

///|
/// `entropy_decode_mono_3860` / `entropy_decode_stereo_3860`.
fn ApeDecoder::entropy_decode_3860(
  self : ApeDecoder,
  ch : ApeChannels,
  blockstodecode : Int32,
  stereo : Bool,
) -> Unit {
  for i = 0; i < blockstodecode; i = i + 1 {
    ch.d0[i] = self.decode_value_3860(self.gb, self.rice_y)
  }
  if stereo {
    for i = 0; i < blockstodecode; i = i + 1 {
      ch.d1[i] = self.decode_value_3860(self.gb, self.rice_x)
    }
  }
}

///|
/// `entropy_decode_mono_3900` / `entropy_decode_stereo_3900` (sequential,
/// with the C's backpedal-and-restart between channels) and
/// `entropy_decode_stereo_3930` (interleaved: one Y/X symbol pair per
/// sample, so the range coder consumes both channels' symbols alternately).
fn ApeDecoder::entropy_decode_3900(
  self : ApeDecoder,
  ch : ApeChannels,
  blockstodecode : Int32,
  stereo : Bool,
) -> Unit {
  if stereo && self.fileversion >= 3930 {
    for i = 0; i < blockstodecode; i = i + 1 {
      ch.d0[i] = self.decode_value_3900(self.rice_y)
      ch.d1[i] = self.decode_value_3900(self.rice_x)
    }
    return
  }
  for i = 0; i < blockstodecode; i = i + 1 {
    ch.d0[i] = self.decode_value_3900(self.rice_y)
  }
  if stereo {
    self.range_dec_normalize()
    // because of some implementation peculiarities we need to backpedal here
    self.ptr = self.ptr - 1
    self.range_start_decoding()
    for i = 0; i < blockstodecode; i = i + 1 {
      ch.d1[i] = self.decode_value_3900(self.rice_x)
    }
  }
}

///|
/// `entropy_decode_mono_3990` / `entropy_decode_stereo_3990` (interleaved).
fn ApeDecoder::entropy_decode_3990(
  self : ApeDecoder,
  ch : ApeChannels,
  blockstodecode : Int32,
  stereo : Bool,
) -> Unit {
  for i = 0; i < blockstodecode; i = i + 1 {
    ch.d0[i] = self.decode_value_3990(self.rice_y)
    if stereo {
      ch.d1[i] = self.decode_value_3990(self.rice_x)
    }
  }
}

///|
/// `init_entropy_decoder`.
fn ApeDecoder::init_entropy_decoder(self : ApeDecoder) -> Result[Unit, String] {
  // Read the CRC
  if self.fileversion >= 3900 {
    if self.data_end - self.ptr < 6 {
      return Err("ape: packet is too small")
    }
    self.crc = self.be32()
  } else {
    self.crc = self.gb.read(32)
  }
  // Read the frame flags if they exist
  self.frameflags = 0
  if self.fileversion > 3820 && (self.crc & 0x80000000) != 0 {
    self.crc = self.crc & 0x7FFFFFFF
    if self.data_end - self.ptr < 6 {
      return Err("ape: packet is too small")
    }
    self.frameflags = self.be32()
  }
  // Initialize the rice structs
  self.rice_x.k = 10
  self.rice_x.ksum = (1U << ape_i(self.rice_x.k)) * 16U
  self.rice_y.k = 10
  self.rice_y.ksum = (1U << ape_i(self.rice_y.k)) * 16U
  if self.fileversion >= 3900 {
    // The first 8 bits of input are ignored.
    self.ptr = self.ptr + 1
    self.range_start_decoding()
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Predictor initialisation and the 32-bit predictors (fileversion < 3950)
// ---------------------------------------------------------------------------

///|
/// `init_predictor_decoder`.
fn ApeDecoder::init_predictor_decoder(self : ApeDecoder) -> Unit {
  let p = self.predictor
  let p64 = self.predictor64
  // Zero the history buffers
  for i = 0; i < ape_predictor_size; i = i + 1 {
    p.historybuffer[i] = 0
    p64.historybuffer[i] = 0
  }
  p.buf = 0
  p64.buf = 0
  // Initialize and zero the coefficients
  if self.fileversion < 3930 {
    let src = if self.compression_level == ape_compression_level_fast {
      ape_initial_coeffs_fast_3320
    } else {
      ape_initial_coeffs_a_3800
    }
    for ch = 0; ch < 2; ch = ch + 1 {
      for i = 0; i < src.length(); i = i + 1 {
        p.coeffsA[ch * 4 + i] = ape_u(src[i])
      }
    }
  } else {
    for ch = 0; ch < 2; ch = ch + 1 {
      for i = 0; i < 4; i = i + 1 {
        p.coeffsA[ch * 4 + i] = ape_u(ape_initial_coeffs_3930[i])
        p64.coeffsA[ch * 4 + i] = ape_initial_coeffs_3930[i]
          .to_int64()
          .reinterpret_as_uint64()
      }
    }
  }
  for i = 0; i < 10; i = i + 1 {
    p.coeffsB[i] = 0
    p64.coeffsB[i] = 0
  }
  if self.fileversion < 3930 {
    for ch = 0; ch < 2; ch = ch + 1 {
      for i = 0; i < ape_initial_coeffs_b_3800.length(); i = i + 1 {
        p.coeffsB[ch * 5 + i] = ape_u(ape_initial_coeffs_b_3800[i])
      }
    }
  }
  for ch = 0; ch < 2; ch = ch + 1 {
    p.filterA[ch] = 0
    p.filterB[ch] = 0
    p.lastA[ch] = 0
    p64.filterA[ch] = 0L
    p64.filterB[ch] = 0L
    p64.lastA[ch] = 0L
  }
  p.sample_pos = 0
}

///|
/// `filter_fast_3320`.
fn ape_filter_fast_3320(
  p : ApePredictor32,
  decoded : Int32,
  filter : Int32,
  delay_a : Int32,
) -> Int32 {
  p.historybuffer[p.buf + delay_a] = p.lastA[filter]
  if p.sample_pos < 3 {
    p.lastA[filter] = decoded
    p.filterA[filter] = decoded
    return decoded
  }
  let predictionA = ape_i(
    ape_u(p.historybuffer[p.buf + delay_a]) * 2 -
    ape_u(p.historybuffer[p.buf + delay_a - 1]),
  )
  let prod = ape_i(ape_u(predictionA) * p.coeffsA[filter * 4])
  p.lastA[filter] = ape_i(ape_u(decoded) + ape_u(prod >> 9))
  if (decoded ^ predictionA) > 0 {
    p.coeffsA[filter * 4] = p.coeffsA[filter * 4] + 1
  } else {
    p.coeffsA[filter * 4] = p.coeffsA[filter * 4] - 1
  }
  p.filterA[filter] = ape_i(ape_u(p.filterA[filter]) + ape_u(p.lastA[filter]))
  p.filterA[filter]
}

///|
/// `filter_3800`.
fn ape_filter_3800(
  p : ApePredictor32,
  decoded : Int32,
  filter : Int32,
  delay_a : Int32,
  delay_b : Int32,
  start : Int32,
  shift : Int32,
) -> Int32 {
  p.historybuffer[p.buf + delay_a] = p.lastA[filter]
  p.historybuffer[p.buf + delay_b] = p.filterB[filter]
  if p.sample_pos < ape_u(start) {
    let predictionA = decoded + p.filterA[filter]
    p.lastA[filter] = decoded
    p.filterB[filter] = decoded
    p.filterA[filter] = predictionA
    return predictionA
  }
  let d2 = p.historybuffer[p.buf + delay_a]
  let d1 = ape_i(
    (
      ape_u(p.historybuffer[p.buf + delay_a]) -
      ape_u(p.historybuffer[p.buf + delay_a - 1])
    ) *
    2,
  )
  let d0 = ape_i(
    ape_u(p.historybuffer[p.buf + delay_a]) +
    (
      ape_u(p.historybuffer[p.buf + delay_a - 2]) -
      ape_u(p.historybuffer[p.buf + delay_a - 1])
    ) *
    8,
  )
  let d3 = ape_i(
    ape_u(p.historybuffer[p.buf + delay_b]) * 2 -
    ape_u(p.historybuffer[p.buf + delay_b - 1]),
  )
  let d4 = p.historybuffer[p.buf + delay_b]
  let predictionA = ape_i(
    ape_u(d0) * p.coeffsA[filter * 4] +
    ape_u(d1) * p.coeffsA[filter * 4 + 1] +
    ape_u(d2) * p.coeffsA[filter * 4 + 2],
  )
  let sign = ape_sign(decoded)
  p.coeffsA[filter * 4] = ape_u(
    ape_i(p.coeffsA[filter * 4]) + (((d0 >> 30) & 2) - 1) * sign,
  )
  p.coeffsA[filter * 4 + 1] = ape_u(
    ape_i(p.coeffsA[filter * 4 + 1]) + (((d1 >> 28) & 8) - 4) * sign,
  )
  p.coeffsA[filter * 4 + 2] = ape_u(
    ape_i(p.coeffsA[filter * 4 + 2]) + (((d2 >> 28) & 8) - 4) * sign,
  )
  let predictionB = ape_i(
    ape_u(d3) * p.coeffsB[filter * 5] - ape_u(d4) * p.coeffsB[filter * 5 + 1],
  )
  p.lastA[filter] = decoded + (predictionA >> 11)
  let sign_b = ape_sign(p.lastA[filter])
  p.coeffsB[filter * 5] = ape_u(
    ape_i(p.coeffsB[filter * 5]) + (((d3 >> 29) & 4) - 2) * sign_b,
  )
  p.coeffsB[filter * 5 + 1] = ape_u(
    ape_i(p.coeffsB[filter * 5 + 1]) - (((d4 >> 30) & 2) - 1) * sign_b,
  )
  p.filterB[filter] = ape_i(
    ape_u(p.lastA[filter]) + ape_u(predictionB >> shift),
  )
  p.filterA[filter] = ape_i(
    ape_u(p.filterB[filter]) + ape_u(ape_i(ape_u(p.filterA[filter]) * 31) >> 5),
  )
  p.filterA[filter]
}

///|
/// `long_filter_high_3800`.
fn ape_long_filter_high_3800(
  buffer : Array[Int32],
  order : Int32,
  shift : Int32,
  length : Int32,
) -> Unit {
  if order >= length {
    return
  }
  let coeffs : FixedArray[Int32] = FixedArray::make(order, 0)
  let delay : FixedArray[Int32] = FixedArray::make(256 + 256, 0)
  let mut delayp = 0
  for i = 0; i < order; i = i + 1 {
    delay[i] = buffer[i]
  }
  for i = order; i < length; i = i + 1 {
    let mut dotprod = 0
    let sign = ape_sign(buffer[i])
    if sign == 1 {
      for j = 0; j < order; j = j + 1 {
        dotprod = ape_i(
          ape_u(dotprod) + ape_u(delay[delayp + j]) * ape_u(coeffs[j]),
        )
        coeffs[j] = coeffs[j] + ((delay[delayp + j] >> 31) | 1)
      }
    } else if sign == -1 {
      for j = 0; j < order; j = j + 1 {
        dotprod = ape_i(
          ape_u(dotprod) + ape_u(delay[delayp + j]) * ape_u(coeffs[j]),
        )
        coeffs[j] = coeffs[j] - ((delay[delayp + j] >> 31) | 1)
      }
    } else {
      for j = 0; j < order; j = j + 1 {
        dotprod = ape_i(
          ape_u(dotprod) + ape_u(delay[delayp + j]) * ape_u(coeffs[j]),
        )
      }
    }
    buffer[i] = ape_i(ape_u(buffer[i]) - ape_u(dotprod >> shift))
    delayp = delayp + 1
    delay[delayp + order - 1] = buffer[i]
    if delayp == 256 {
      for j = 0; j < 256; j = j + 1 {
        delay[j] = delay[delayp + j]
      }
      delayp = 0
    }
  }
}

///|
/// `long_filter_ehigh_3830`, operating on `buffer[from..from+length)`.
fn ape_long_filter_ehigh_3830(
  buffer : Array[Int32],
  from : Int32,
  length : Int32,
) -> Unit {
  let delay : FixedArray[Int32] = FixedArray::make(8, 0)
  let coeffs : FixedArray[UInt32] = FixedArray::make(8, 0)
  for i = 0; i < length; i = i + 1 {
    let mut dotprod = 0
    let sign = ape_sign(buffer[from + i])
    let mut j = 7
    while j >= 0 {
      dotprod = ape_i(ape_u(dotprod) + ape_u(delay[j]) * coeffs[j])
      coeffs[j] = ape_u(ape_i(coeffs[j]) + ((delay[j] >> 31) | 1) * sign)
      j = j - 1
    }
    j = 7
    while j > 0 {
      delay[j] = delay[j - 1]
      j = j - 1
    }
    delay[0] = buffer[from + i]
    buffer[from + i] = ape_i(ape_u(buffer[from + i]) - ape_u(dotprod >> 9))
  }
}

///|
/// Shared body of `predictor_decode_mono_3800` / `predictor_decode_stereo_3800`:
/// long-filter preprocessing per compression level.
fn ApeDecoder::predictor_3800_prefilters(
  self : ApeDecoder,
  ch0 : Array[Int32],
  ch1 : Array[Int32]?,
  count : Int32,
) -> (Int32, Int32) {
  let mut start = 4
  let mut shift = 10
  if self.compression_level == ape_compression_level_high {
    start = 16
    ape_long_filter_high_3800(ch0, 16, 9, count)
    if ch1 is Some(c1) {
      ape_long_filter_high_3800(c1, 16, 9, count)
    }
  } else if self.compression_level == ape_compression_level_extra_high {
    let mut order = 128
    let mut shift2 = 11
    if self.fileversion >= 3830 {
      order = order * 2
      shift = shift + 1
      shift2 = shift2 + 1
      ape_long_filter_ehigh_3830(ch0, order, count - order)
      if ch1 is Some(c1) {
        ape_long_filter_ehigh_3830(c1, order, count - order)
      }
    }
    start = order
    ape_long_filter_high_3800(ch0, order, shift2, count)
    if ch1 is Some(c1) {
      ape_long_filter_high_3800(c1, order, shift2, count)
    }
  }
  (start, shift)
}

///|
/// `predictor_decode_stereo_3800`.
fn ApeDecoder::predictor_decode_stereo_3800(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  let p = self.predictor
  let (start, shift) = self.predictor_3800_prefilters(ch.d0, Some(ch.d1), count)
  for i = 0; i < count; i = i + 1 {
    let x = ch.d0[i]
    let y = ch.d1[i]
    if self.compression_level == ape_compression_level_fast {
      ch.d0[i] = ape_filter_fast_3320(p, y, 0, ape_ydelaya)
      ch.d1[i] = ape_filter_fast_3320(p, x, 1, ape_xdelaya)
    } else {
      ch.d0[i] = ape_filter_3800(
        p, y, 0, ape_ydelaya, ape_ydelayb, start, shift,
      )
      ch.d1[i] = ape_filter_3800(
        p, x, 1, ape_xdelaya, ape_xdelayb, start, shift,
      )
    }
    // Combined
    p.buf = p.buf + 1
    p.sample_pos = p.sample_pos + 1
    // Have we filled the history buffer?
    if p.buf == ape_history_size {
      for j = 0; j < ape_predictor_size; j = j + 1 {
        p.historybuffer[j] = p.historybuffer[ape_history_size + j]
      }
      p.buf = 0
    }
  }
}

///|
/// `predictor_decode_mono_3800`.
fn ApeDecoder::predictor_decode_mono_3800(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  let p = self.predictor
  let (start, shift) = self.predictor_3800_prefilters(ch.d0, None, count)
  for i = 0; i < count; i = i + 1 {
    if self.compression_level == ape_compression_level_fast {
      ch.d0[i] = ape_filter_fast_3320(p, ch.d0[i], 0, ape_ydelaya)
    } else {
      ch.d0[i] = ape_filter_3800(
        p,
        ch.d0[i],
        0,
        ape_ydelaya,
        ape_ydelayb,
        start,
        shift,
      )
    }
    // Combined
    p.buf = p.buf + 1
    p.sample_pos = p.sample_pos + 1
    // Have we filled the history buffer?
    if p.buf == ape_history_size {
      for j = 0; j < ape_predictor_size; j = j + 1 {
        p.historybuffer[j] = p.historybuffer[ape_history_size + j]
      }
      p.buf = 0
    }
  }
}

///|
/// `predictor_update_3930`.
fn ape_predictor_update_3930(
  p : ApePredictor32,
  decoded : Int32,
  filter : Int32,
  delay_a : Int32,
) -> Int32 {
  p.historybuffer[p.buf + delay_a] = p.lastA[filter]
  let d0 = ape_u(p.historybuffer[p.buf + delay_a])
  let d1 = ape_u(p.historybuffer[p.buf + delay_a]) -
    ape_u(p.historybuffer[p.buf + delay_a - 1])
  let d2 = ape_u(p.historybuffer[p.buf + delay_a - 1]) -
    ape_u(p.historybuffer[p.buf + delay_a - 2])
  let d3 = ape_u(p.historybuffer[p.buf + delay_a - 2]) -
    ape_u(p.historybuffer[p.buf + delay_a - 3])
  let predictionA = ape_i(
    d0 * p.coeffsA[filter * 4] +
    d1 * p.coeffsA[filter * 4 + 1] +
    d2 * p.coeffsA[filter * 4 + 2] +
    d3 * p.coeffsA[filter * 4 + 3],
  )
  p.lastA[filter] = decoded + (predictionA >> 9)
  p.filterA[filter] = p.lastA[filter] +
    (ape_i(ape_u(p.filterA[filter]) * 31) >> 5)
  let sign = ape_sign(decoded)
  p.coeffsA[filter * 4] = ape_u(
    ape_i(p.coeffsA[filter * 4]) + ((ape_i(d0) < 0).to_int() * 2 - 1) * sign,
  )
  p.coeffsA[filter * 4 + 1] = ape_u(
    ape_i(p.coeffsA[filter * 4 + 1]) + ((ape_i(d1) < 0).to_int() * 2 - 1) * sign,
  )
  p.coeffsA[filter * 4 + 2] = ape_u(
    ape_i(p.coeffsA[filter * 4 + 2]) + ((ape_i(d2) < 0).to_int() * 2 - 1) * sign,
  )
  p.coeffsA[filter * 4 + 3] = ape_u(
    ape_i(p.coeffsA[filter * 4 + 3]) + ((ape_i(d3) < 0).to_int() * 2 - 1) * sign,
  )
  p.filterA[filter]
}

///|
/// `predictor_decode_stereo_3930`.
fn ApeDecoder::predictor_decode_stereo_3930(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  let p = self.predictor
  self.apply_filters(ch.d0, Some(ch.d1), count)
  for i = 0; i < count; i = i + 1 {
    // Predictor Y
    let y = ch.d1[i]
    let x = ch.d0[i]
    ch.d0[i] = ape_predictor_update_3930(p, y, 0, ape_ydelaya)
    ch.d1[i] = ape_predictor_update_3930(p, x, 1, ape_xdelaya)
    // Combined
    p.buf = p.buf + 1
    // Have we filled the history buffer?
    if p.buf == ape_history_size {
      for j = 0; j < ape_predictor_size; j = j + 1 {
        p.historybuffer[j] = p.historybuffer[ape_history_size + j]
      }
      p.buf = 0
    }
  }
}

///|
/// `predictor_decode_mono_3930`.
fn ApeDecoder::predictor_decode_mono_3930(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  let p = self.predictor
  self.apply_filters(ch.d0, None, count)
  for i = 0; i < count; i = i + 1 {
    ch.d0[i] = ape_predictor_update_3930(p, ch.d0[i], 0, ape_ydelaya)
    p.buf = p.buf + 1
    if p.buf == ape_history_size {
      for j = 0; j < ape_predictor_size; j = j + 1 {
        p.historybuffer[j] = p.historybuffer[ape_history_size + j]
      }
      p.buf = 0
    }
  }
}

// ---------------------------------------------------------------------------
// 64-bit predictor (fileversion >= 3950)
// ---------------------------------------------------------------------------

///|
/// `APESIGN` in 64-bit.
fn ape_sign64(x : Int64) -> Int64 {
  (x < 0L).to_int64() - (x > 0L).to_int64()
}

///|
/// `predictor_update_filter`.
fn ape_predictor_update_filter(
  p : ApePredictor64,
  decoded : Int32,
  filter : Int32,
  delay_a : Int32,
  delay_b : Int32,
  adapt_a : Int32,
  adapt_b : Int32,
  interim_mode : Int32,
) -> Int32 {
  p.historybuffer[p.buf + delay_a] = p.lastA[filter]
  p.historybuffer[p.buf + adapt_a] = ape_sign64(
    p.historybuffer[p.buf + delay_a],
  )
  p.historybuffer[p.buf + delay_a - 1] = ape_i64(
    ape_u64(p.historybuffer[p.buf + delay_a]) -
    ape_u64(p.historybuffer[p.buf + delay_a - 1]),
  )
  p.historybuffer[p.buf + adapt_a - 1] = ape_sign64(
    p.historybuffer[p.buf + delay_a - 1],
  )
  let mut predictionA = ape_i64(
    ape_u64(p.historybuffer[p.buf + delay_a]) * p.coeffsA[filter * 4] +
    ape_u64(p.historybuffer[p.buf + delay_a - 1]) * p.coeffsA[filter * 4 + 1] +
    ape_u64(p.historybuffer[p.buf + delay_a - 2]) * p.coeffsA[filter * 4 + 2] +
    ape_u64(p.historybuffer[p.buf + delay_a - 3]) * p.coeffsA[filter * 4 + 3],
  )
  // Apply a scaled first-order filter compression
  p.historybuffer[p.buf + delay_b] = p.filterA[filter ^ 1] -
    (ape_i64(ape_u64(p.filterB[filter]) * 31UL) >> 5)
  p.historybuffer[p.buf + adapt_b] = ape_sign64(
    p.historybuffer[p.buf + delay_b],
  )
  p.historybuffer[p.buf + delay_b - 1] = ape_i64(
    ape_u64(p.historybuffer[p.buf + delay_b]) -
    ape_u64(p.historybuffer[p.buf + delay_b - 1]),
  )
  p.historybuffer[p.buf + adapt_b - 1] = ape_sign64(
    p.historybuffer[p.buf + delay_b - 1],
  )
  p.filterB[filter] = p.filterA[filter ^ 1]
  let mut predictionB = ape_i64(
    ape_u64(p.historybuffer[p.buf + delay_b]) * p.coeffsB[filter * 5] +
    ape_u64(p.historybuffer[p.buf + delay_b - 1]) * p.coeffsB[filter * 5 + 1] +
    ape_u64(p.historybuffer[p.buf + delay_b - 2]) * p.coeffsB[filter * 5 + 2] +
    ape_u64(p.historybuffer[p.buf + delay_b - 3]) * p.coeffsB[filter * 5 + 3] +
    ape_u64(p.historybuffer[p.buf + delay_b - 4]) * p.coeffsB[filter * 5 + 4],
  )
  if interim_mode < 1 {
    predictionA = predictionA.to_int().to_int64()
    predictionB = predictionB.to_int().to_int64()
    let sum = (predictionA + (predictionB >> 1)).to_int()
    p.lastA[filter] = ape_i(ape_u(decoded) + ape_u(sum >> 10)).to_int64()
  } else {
    p.lastA[filter] = decoded.to_int64() +
      (ape_i64(ape_u64(predictionA) + ape_u64(predictionB >> 1)) >> 10)
  }
  p.filterA[filter] = p.lastA[filter] +
    (ape_i64(ape_u64(p.filterA[filter]) * 31UL) >> 5)
  let sign = ape_sign(decoded)
  p.coeffsA[filter * 4] = p.coeffsA[filter * 4] +
    ape_u64(p.historybuffer[p.buf + adapt_a]) * ape_u64(sign.to_int64())
  p.coeffsA[filter * 4 + 1] = p.coeffsA[filter * 4 + 1] +
    ape_u64(p.historybuffer[p.buf + adapt_a - 1]) * ape_u64(sign.to_int64())
  p.coeffsA[filter * 4 + 2] = p.coeffsA[filter * 4 + 2] +
    ape_u64(p.historybuffer[p.buf + adapt_a - 2]) * ape_u64(sign.to_int64())
  p.coeffsA[filter * 4 + 3] = p.coeffsA[filter * 4 + 3] +
    ape_u64(p.historybuffer[p.buf + adapt_a - 3]) * ape_u64(sign.to_int64())
  p.coeffsB[filter * 5] = p.coeffsB[filter * 5] +
    ape_u64(p.historybuffer[p.buf + adapt_b]) * ape_u64(sign.to_int64())
  p.coeffsB[filter * 5 + 1] = p.coeffsB[filter * 5 + 1] +
    ape_u64(p.historybuffer[p.buf + adapt_b - 1]) * ape_u64(sign.to_int64())
  p.coeffsB[filter * 5 + 2] = p.coeffsB[filter * 5 + 2] +
    ape_u64(p.historybuffer[p.buf + adapt_b - 2]) * ape_u64(sign.to_int64())
  p.coeffsB[filter * 5 + 3] = p.coeffsB[filter * 5 + 3] +
    ape_u64(p.historybuffer[p.buf + adapt_b - 3]) * ape_u64(sign.to_int64())
  p.coeffsB[filter * 5 + 4] = p.coeffsB[filter * 5 + 4] +
    ape_u64(p.historybuffer[p.buf + adapt_b - 4]) * ape_u64(sign.to_int64())
  p.filterA[filter].to_int()
}

///|
/// Deep copy for the C's struct assignment `p_interim = *p_default`.
fn ape_predictor64_clone(p : ApePredictor64) -> ApePredictor64 {
  let q : ApePredictor64 = {
    historybuffer: FixedArray::make(p.historybuffer.length(), 0L),
    buf: p.buf,
    lastA: FixedArray::make(2, 0L),
    filterA: FixedArray::make(2, 0L),
    filterB: FixedArray::make(2, 0L),
    coeffsA: FixedArray::make(8, 0UL),
    coeffsB: FixedArray::make(10, 0UL),
  }
  for i = 0; i < p.historybuffer.length(); i = i + 1 {
    q.historybuffer[i] = p.historybuffer[i]
  }
  for i = 0; i < 2; i = i + 1 {
    q.lastA[i] = p.lastA[i]
    q.filterA[i] = p.filterA[i]
    q.filterB[i] = p.filterB[i]
  }
  for i = 0; i < 8; i = i + 1 {
    q.coeffsA[i] = p.coeffsA[i]
  }
  for i = 0; i < 10; i = i + 1 {
    q.coeffsB[i] = p.coeffsB[i]
  }
  q
}

///|
/// `predictor_decode_stereo_3950`.
fn ApeDecoder::predictor_decode_stereo_3950(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  let p_default = self.predictor64
  let p_interim : ApePredictor64 = ape_predictor64_clone(p_default)
  let mut num_passes = 1
  self.apply_filters(ch.d0, Some(ch.d1), count)
  if self.interim_mode == -1 {
    num_passes = num_passes + 1
    for i = 0; i < count; i = i + 1 {
      ch.i0[i] = ch.d0[i]
      ch.i1[i] = ch.d1[i]
    }
  }
  for pass = 0; pass < num_passes; pass = pass + 1 {
    let interim_mode = if self.interim_mode > 0 || pass != 0 { 1 } else { 0 }
    let p = if pass != 0 { p_interim } else { p_default }
    let d0 = if pass != 0 { ch.i0 } else { ch.d0 }
    let d1 = if pass != 0 { ch.i1 } else { ch.d1 }
    p.buf = 0
    for i = 0; i < count; i = i + 1 {
      // Predictor Y
      let a0 = ape_predictor_update_filter(
        p,
        d0[i],
        0,
        ape_ydelaya,
        ape_ydelayb,
        ape_yadaptcoeffsa,
        ape_yadaptcoeffsb,
        interim_mode,
      )
      let a1 = ape_predictor_update_filter(
        p,
        d1[i],
        1,
        ape_xdelaya,
        ape_xdelayb,
        ape_xadaptcoeffsa,
        ape_xadaptcoeffsb,
        interim_mode,
      )
      d0[i] = a0
      d1[i] = a1
      if num_passes > 1 {
        let left = ape_i(ape_u(a1) - ape_u(a0 / 2))
        let right = ape_i(ape_u(left) + ape_u(a0))
        let nleft = if left < 0 { -left } else { left }
        let nright = if right < 0 { -right } else { right }
        let mn = if nleft < nright { -nleft } else { -nright }
        if mn < -(1 << 23) {
          self.interim_mode = if interim_mode == 0 { 1 } else { 0 }
          break
        }
      }
      // Combined
      p.buf = p.buf + 1
      // Have we filled the history buffer?
      if p.buf == ape_history_size {
        for j = 0; j < ape_predictor_size; j = j + 1 {
          p.historybuffer[j] = p.historybuffer[ape_history_size + j]
        }
        p.buf = 0
      }
    }
  }
  if num_passes > 1 && self.interim_mode > 0 {
    for i = 0; i < count; i = i + 1 {
      ch.d0[i] = ch.i0[i]
      ch.d1[i] = ch.i1[i]
    }
    // *p_default = p_interim
    for i = 0; i < p_default.historybuffer.length(); i = i + 1 {
      p_default.historybuffer[i] = p_interim.historybuffer[i]
    }
    for i = 0; i < 2; i = i + 1 {
      p_default.lastA[i] = p_interim.lastA[i]
      p_default.filterA[i] = p_interim.filterA[i]
      p_default.filterB[i] = p_interim.filterB[i]
    }
    for i = 0; i < 8; i = i + 1 {
      p_default.coeffsA[i] = p_interim.coeffsA[i]
    }
    for i = 0; i < 10; i = i + 1 {
      p_default.coeffsB[i] = p_interim.coeffsB[i]
    }
    p_default.buf = 0
  }
}

///|
/// `predictor_decode_mono_3950`.
fn ApeDecoder::predictor_decode_mono_3950(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  let p = self.predictor64
  self.apply_filters(ch.d0, None, count)
  let mut currentA = p.lastA[0]
  for i = 0; i < count; i = i + 1 {
    let a = ch.d0[i]
    p.historybuffer[p.buf + ape_ydelaya] = currentA
    p.historybuffer[p.buf + ape_ydelaya - 1] = ape_i64(
      ape_u64(p.historybuffer[p.buf + ape_ydelaya]) -
      ape_u64(p.historybuffer[p.buf + ape_ydelaya - 1]),
    )
    let predictionA = ape_i64(
      ape_u64(p.historybuffer[p.buf + ape_ydelaya]) * p.coeffsA[0] +
      ape_u64(p.historybuffer[p.buf + ape_ydelaya - 1]) * p.coeffsA[1] +
      ape_u64(p.historybuffer[p.buf + ape_ydelaya - 2]) * p.coeffsA[2] +
      ape_u64(p.historybuffer[p.buf + ape_ydelaya - 3]) * p.coeffsA[3],
    )
    currentA = a.to_int64() + ape_u64(predictionA >> 10).reinterpret_as_int64()
    p.historybuffer[p.buf + ape_yadaptcoeffsa] = ape_sign64(
      p.historybuffer[p.buf + ape_ydelaya],
    )
    p.historybuffer[p.buf + ape_yadaptcoeffsa - 1] = ape_sign64(
      p.historybuffer[p.buf + ape_ydelaya - 1],
    )
    let sign = ape_sign(a)
    p.coeffsA[0] = p.coeffsA[0] +
      ape_u64(p.historybuffer[p.buf + ape_yadaptcoeffsa]) *
      ape_u64(sign.to_int64())
    p.coeffsA[1] = p.coeffsA[1] +
      ape_u64(p.historybuffer[p.buf + ape_yadaptcoeffsa - 1]) *
      ape_u64(sign.to_int64())
    p.coeffsA[2] = p.coeffsA[2] +
      ape_u64(p.historybuffer[p.buf + ape_yadaptcoeffsa - 2]) *
      ape_u64(sign.to_int64())
    p.coeffsA[3] = p.coeffsA[3] +
      ape_u64(p.historybuffer[p.buf + ape_yadaptcoeffsa - 3]) *
      ape_u64(sign.to_int64())
    p.buf = p.buf + 1
    // Have we filled the history buffer?
    if p.buf == ape_history_size {
      for j = 0; j < ape_predictor_size; j = j + 1 {
        p.historybuffer[j] = p.historybuffer[ape_history_size + j]
      }
      p.buf = 0
    }
    p.filterA[0] = currentA + (ape_i64(ape_u64(p.filterA[0]) * 31UL) >> 5)
    ch.d0[i] = p.filterA[0].to_int()
  }
  p.lastA[0] = currentA
}

// ---------------------------------------------------------------------------
// Filters (`do_init_filter` / `init_filter` / `do_apply_filter`)
// ---------------------------------------------------------------------------

///|
/// `do_init_filter`.
fn ape_do_init_filter(f : ApeFilter) -> Unit {
  f.delay = f.order * 3
  f.adapt = f.order * 2
  for i = 0; i < f.order * 2; i = i + 1 {
    f.buf[f.order + i] = 0
  }
  for i = 0; i < f.order; i = i + 1 {
    f.buf[i] = 0
  }
  f.avg = 0
}

///|
/// `scalarproduct_and_madd_int16` (the C reference version).
fn ape_scalarproduct_and_madd_int16(f : ApeFilter, mul : Int32) -> Int32 {
  let mut res : UInt32 = 0
  for i = 0; i < f.order; i = i + 1 {
    let v1 = f.buf[i].to_int()
    let v2 = f.buf[f.delay - f.order + i].to_int()
    let v3 = f.buf[f.adapt - f.order + i].to_int()
    res = res + ape_u(v1) * ape_u(v2)
    f.buf[i] = Int16::from_int(v1 + v3 * mul)
  }
  ape_i(res)
}

///|
/// `do_apply_filter`.
fn ApeDecoder::do_apply_filter(
  self : ApeDecoder,
  f : ApeFilter,
  data : Array[Int32],
  count : Int32,
  fracbits : Int32,
) -> Unit {
  let order = f.order
  for i = 0; i < count; i = i + 1 {
    // round fixedpoint scalar product
    let mut res = ((
      ape_scalarproduct_and_madd_int16(f, ape_sign(data[i])).to_int64() +
      (1L << (fracbits - 1))
    ) >>
    fracbits).to_int()
    res = ape_i(ape_u(res) + ape_u(data[i]))
    data[i] = res
    // Update the output history
    f.buf[f.delay] = Int16::from_int(ape_clip_int16(res))
    f.delay = f.delay + 1
    if self.fileversion < 3980 {
      // Version ??? to < 3.98 files (untested)
      f.buf[f.adapt] = if res == 0 {
        0
      } else {
        Int16::from_int(((res >> 28) & 8) - 4)
      }
      f.buf[f.adapt - 4] = Int16::from_int(f.buf[f.adapt - 4].to_int() >> 1)
      f.buf[f.adapt - 8] = Int16::from_int(f.buf[f.adapt - 8].to_int() >> 1)
    } else {
      // Version 3.98 and later files
      let absres = if res < 0 { 0U - ape_u(res) } else { ape_u(res) }
      if absres != 0 {
        let m = ape_u(
          ape_sign(res) *
          ape_i(
            8 <<
            (
              (absres > f.avg * 3U).to_int() +
              (absres > f.avg + f.avg / 3U).to_int()
            ),
          ),
        )
        f.buf[f.adapt] = Int16::from_int(ape_i(m))
      } else {
        f.buf[f.adapt] = 0
      }
      f.avg = f.avg + ape_u(ape_i(absres - f.avg) / 16)
      f.buf[f.adapt - 1] = Int16::from_int(f.buf[f.adapt - 1].to_int() >> 1)
      f.buf[f.adapt - 2] = Int16::from_int(f.buf[f.adapt - 2].to_int() >> 1)
      f.buf[f.adapt - 8] = Int16::from_int(f.buf[f.adapt - 8].to_int() >> 1)
    }
    f.adapt = f.adapt + 1
    // Have we filled the history buffer?
    if f.delay == f.order * 3 + ape_history_size {
      for j = 0; j < order * 2; j = j + 1 {
        f.buf[f.order + j] = f.buf[f.order + ape_history_size + j]
      }
      f.delay = f.order * 3
      f.adapt = f.order * 2
    }
  }
}

///|
/// `ape_apply_filters`.
fn ApeDecoder::apply_filters(
  self : ApeDecoder,
  d0 : Array[Int32],
  d1 : Array[Int32]?,
  count : Int32,
) -> Unit {
  for i = 0; i < ape_filter_levels; i = i + 1 {
    let order = ape_filter_orders[self.fset][i]
    if order == 0 {
      break
    }
    let fracbits = ape_filter_fracbits[self.fset][i]
    self.do_apply_filter(self.filters[i * 2], d0, count, fracbits)
    if d1 is Some(c1) {
      self.do_apply_filter(self.filters[i * 2 + 1], c1, count, fracbits)
    }
  }
}

///|
/// `init_frame_decoder`.
fn ApeDecoder::init_frame_decoder(self : ApeDecoder) -> Result[Unit, String] {
  match self.init_entropy_decoder() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.init_predictor_decoder()
  for i = 0; i < ape_filter_levels; i = i + 1 {
    let order = ape_filter_orders[self.fset][i]
    if order == 0 {
      break
    }
    ape_do_init_filter(self.filters[i * 2])
    ape_do_init_filter(self.filters[i * 2 + 1])
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Unpack + frame entry point
// ---------------------------------------------------------------------------

///|
/// `ape_unpack_mono`.
fn ApeDecoder::unpack_mono(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  if (self.frameflags & ape_framecode_stereo_silence) != 0 {
    // We are pure silence, so we're done.
    return
  }
  self.entropy_decode(ch, count, false)
  if self.error {
    return
  }
  // Now apply the predictor decoding
  self.predictor_decode_mono(ch, count)
  // Pseudo-stereo - just copy left channel to right channel
  if self.channels == 2 {
    for i = 0; i < count; i = i + 1 {
      ch.d1[i] = ch.d0[i]
    }
  }
}

///|
/// `ape_unpack_stereo`.
fn ApeDecoder::unpack_stereo(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  if (self.frameflags & ape_framecode_stereo_silence) ==
    ape_framecode_stereo_silence {
    // We are pure silence, so we're done.
    return
  }
  self.entropy_decode(ch, count, true)
  if self.error {
    return
  }
  // Now apply the predictor decoding
  self.predictor_decode_stereo(ch, count)
  // Decorrelate and scale to output depth
  for i = 0; i < count; i = i + 1 {
    let left = ape_i(ape_u(ch.d1[i]) - ape_u(ch.d0[i] / 2))
    let right = ape_i(ape_u(left) + ape_u(ch.d0[i]))
    ch.d0[i] = left
    ch.d1[i] = right
  }
}

///|
/// The entropy/predictor dispatch from `ape_decode_init`.
fn ApeDecoder::entropy_decode(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
  stereo : Bool,
) -> Unit {
  if self.fileversion < 3860 {
    self.entropy_decode_0000(ch, count, stereo)
  } else if self.fileversion < 3900 {
    self.entropy_decode_3860(ch, count, stereo)
  } else if self.fileversion < 3990 {
    self.entropy_decode_3900(ch, count, stereo)
  } else {
    self.entropy_decode_3990(ch, count, stereo)
  }
}

///|
/// Predictor dispatch (mono).
fn ApeDecoder::predictor_decode_mono(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  if self.fileversion < 3930 {
    self.predictor_decode_mono_3800(ch, count)
  } else if self.fileversion < 3950 {
    self.predictor_decode_mono_3930(ch, count)
  } else {
    self.predictor_decode_mono_3950(ch, count)
  }
}

///|
/// Predictor dispatch (stereo).
fn ApeDecoder::predictor_decode_stereo(
  self : ApeDecoder,
  ch : ApeChannels,
  count : Int32,
) -> Unit {
  if self.fileversion < 3930 {
    self.predictor_decode_stereo_3800(ch, count)
  } else if self.fileversion < 3950 {
    self.predictor_decode_stereo_3930(ch, count)
  } else {
    self.predictor_decode_stereo_3950(ch, count)
  }
}

///|
/// `ape_decode_frame`: one `blocks_per_loop` chunk per call.  Feed the same
/// packet repeatedly until `packet_done` turns true (the C's decode-API
/// loop).  On a mid-packet decode error the packet is dropped (`samples`
/// resets), exactly like the C's error path.
pub fn ApeDecoder::decode_frame(
  self : ApeDecoder,
  packet : Bytes,
) -> Result[ApeChunk, String] {
  if self.samples == 0 {
    if packet.length() == 0 {
      return Err("ape: empty packet")
    }
    if packet.length() < 8 {
      return Err("ape: packet is too small")
    }
    // bswap_buf over the aligned words; < 3950 streams overread two zero
    // bytes through the padding.
    let aligned = packet.length() & -4
    let extra = if self.fileversion < 3950 { 2 } else { 0 }
    let swapped : Array[Byte] = Array::make(aligned + extra, b'\x00')
    let mut w = 0
    while w < aligned {
      swapped[w] = packet[w + 3]
      swapped[w + 1] = packet[w + 2]
      swapped[w + 2] = packet[w + 1]
      swapped[w + 3] = packet[w]
      w = w + 4
    }
    self.data = Bytes::from_array(swapped)
    self.ptr = 0
    self.data_end = aligned + extra
    let nblocks = ape_i(self.be32())
    let offset = ape_i(self.be32())
    if self.fileversion >= 3900 {
      if offset > 3 {
        return Err("ape: incorrect offset passed")
      }
      if self.data_end - self.ptr < offset {
        return Err("ape: packet is too small")
      }
      self.ptr = self.ptr + offset
    } else {
      self.gb = BitReader::new(
        self.data.clamped_view(start=self.ptr, end=self.data_end).to_owned(),
      )
      if self.fileversion > 3800 {
        self.gb.skip(offset * 8)
      } else {
        self.gb.skip(offset)
      }
    }
    if nblocks <= 0 || nblocks > 268435455 - 8 {
      return Err("ape: invalid sample count \{nblocks}")
    }
    // Initialize the frame decoder
    match self.init_frame_decoder() {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    self.samples = nblocks
    self.has_data = true
  }
  if !self.has_data {
    return Err("ape: no frame data")
  }
  let mut blockstodecode = if self.blocks_per_loop < self.samples {
    self.blocks_per_loop
  } else {
    self.samples
  }
  // for old files coefficients were not interleaved,
  // so we need to decode all of them at once
  if self.fileversion < 3930 {
    blockstodecode = self.samples
  }
  let align = (blockstodecode + 7) & -8
  let ch : ApeChannels = {
    d0: Array::make(align, 0),
    d1: Array::make(align, 0),
    i0: Array::make(align, 0),
    i1: Array::make(align, 0),
  }
  self.error = false
  if self.channels == 1 || (self.frameflags & ape_framecode_pseudo_stereo) != 0 {
    self.unpack_mono(ch, blockstodecode)
  } else {
    self.unpack_stereo(ch, blockstodecode)
  }
  if self.error {
    self.samples = 0
    return Err("ape: error decoding frame")
  }
  let samples : Array[Int32] = Array::make(blockstodecode * self.channels, 0)
  for i = 0; i < blockstodecode; i = i + 1 {
    for c = 0; c < self.channels; c = c + 1 {
      let v = if c == 0 { ch.d0[i] } else { ch.d1[i] }
      samples[i * self.channels + c] = match self.bps {
        8 => ape_i(ape_u(v + 0x80) & 0xFF)
        24 => ape_i(ape_u(v) * 256)
        _ => v
      }
    }
  }
  self.samples = self.samples - blockstodecode
  Ok({
    frame: {
      bps: self.bps,
      channels: self.channels,
      nb_samples: blockstodecode,
      samples,
    },
    packet_done: self.samples == 0,
  })
}
