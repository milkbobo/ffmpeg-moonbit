///|
/// WMA Pro decoder (`wmapro`), ported from FFmpeg 9.0.2
/// `libavcodec/wmaprodec.c`, `wmaprodata.h`, the shared helpers of `wma.c`
/// / `wma_common.c`, and the float DSP kernels it calls
/// (`vector_fmul_scalar`, `vector_fmul_window`).
///
/// Scope: the WMAPRO variant only. XMA1 / XMA2 (the other users of the C
/// file) and WMA Lossless are not ported.
///
/// The C runs a float pipeline: a float FFT MDCT (`AV_TX_FLOAT_MDCT`) and
/// float multiplies for the band gains, the window and the overlap-add.
/// This port keeps doubles and evaluates the MDCT through its defining sum
/// (`ff_tx_mdct_naive_inv`) over a cosine table, so the PCM differs from
/// the C only by float32 rounding noise (at most 1 LSB as s16; see the
/// fixtures).
///
/// Error handling differs from the C in how reasons are *reported*:
///   * A broken frame is dropped and the decoder resynchronises at the
///     next packet, exactly as in the C (`packet_loss`). The C only logs
///     the reason; this port also keeps it for `last_error()`.
///   * What the C refuses with `AVERROR_PATCHWELCOME` (14-bit blocks, the
///     reserved header bit, unknown channel transforms) is an `Err` here
///     instead of a silently dropped frame.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

///|
let wmapro_max_channels : Int32 = 8

///|
let wmapro_max_subframes : Int32 = 32

///|
let wmapro_max_bands : Int32 = 29

///|
let wmapro_max_framesize : Int32 = 32768

///|
let wmapro_block_min_bits : Int32 = 6

///|
let wmapro_block_max_bits : Int32 = 13

///|
let wmapro_block_sizes : Int32 = 8

///|
let wmapro_block_max_size : Int32 = 8192

// ---------------------------------------------------------------------------
// bit reader
// ---------------------------------------------------------------------------

///|
/// `GetBitContext` with the uncached C reader's bounds: bits past the
/// buffer read as zero (the packet padding), and the index never passes
/// `size_bits + 8`.
struct WmaproBits {
  bytes : Array[Byte]
  size_bits : Int32
  mut index : Int32
}

///|
fn WmaproBits::new(bytes : Array[Byte], size_bits : Int32) -> WmaproBits {
  { bytes, size_bits, index: 0, }
}

///|
fn WmaproBits::byte_at(self : WmaproBits, i : Int32) -> UInt32 {
  if i < 0 || i >= self.bytes.length() {
    0U
  } else {
    self.bytes[i].to_int().reinterpret_as_uint()
  }
}

///|
/// `get_bits`: `n` bits MSB-first, `0 <= n <= 25`.
fn WmaproBits::read(self : WmaproBits, n : Int32) -> UInt32 {
  let v = self.show(n)
  self.index = (self.index + n).min(self.size_bits + 8)
  v
}

///|
/// `get_bits1`.
fn WmaproBits::read1(self : WmaproBits) -> UInt32 {
  self.read(1)
}

///|
/// `get_sbits`: `n` bits sign-extended to an `Int32`.
fn WmaproBits::read_signed(self : WmaproBits, n : Int32) -> Int32 {
  let v = self.read(n)
  if n > 0 && ((v >> (n - 1)) & 1U) != 0U {
    (v | (0xFFFFFFFFU << n)).reinterpret_as_int()
  } else {
    v.reinterpret_as_int()
  }
}

///|
/// `show_bits`: the next `n` bits, `0 <= n <= 25`, without consuming them.
fn WmaproBits::show(self : WmaproBits, n : Int32) -> UInt32 {
  if n == 0 {
    return 0U
  }
  let base = self.index >> 3
  let off = self.index & 7
  let b0 = self.byte_at(base)
  let b1 = self.byte_at(base + 1)
  let b2 = self.byte_at(base + 2)
  let b3 = self.byte_at(base + 3)
  let b4 = self.byte_at(base + 4)
  let mut v = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  if off != 0 {
    v = (v << off) | (b4 >> (8 - off))
  }
  v >> (32 - n)
}

///|
/// `get_bits_count`.
fn WmaproBits::count(self : WmaproBits) -> Int32 {
  self.index
}

///|
/// `get_bits_long`: more than 25 bits, read as in the C (16, then the rest).
fn WmaproBits::read_long(self : WmaproBits, n : Int32) -> UInt32 {
  if n <= 25 {
    self.read(n)
  } else {
    (self.read(16) << (n - 16)) | self.read(n - 16)
  }
}

///|
/// `skip_bits`: the index stops at `size_in_bits + 8`, as in the C.
fn WmaproBits::skip(self : WmaproBits, n : Int32) -> Unit {
  self.index = (self.index + n).min(self.size_bits + 8)
}

///|
/// `skip_bits_long` (uncached reader): clipped to `0 ..= size_bits + 8`.
fn WmaproBits::skip_long(self : WmaproBits, n : Int32) -> Unit {
  let mut idx = self.index + n
  if idx < 0 {
    idx = 0
  }
  if idx > self.size_bits + 8 {
    idx = self.size_bits + 8
  }
  self.index = idx
}

// ---------------------------------------------------------------------------
// Huffman tables built from code lengths
// ---------------------------------------------------------------------------

///|
/// One Huffman table of `wmaprodata.h`, built the way
/// `ff_vlc_init_from_lengths` does: the entry `i` with length `len > 0`
/// gets the code that follows every earlier entry (`code += 2^(32 - len)`),
/// so the order inside the table fixes the order inside each length.
/// The symbols arrive with the table's `offset` (`decode_init_static`).
/// Codes and symbols are grouped by length; inside a length they are in
/// increasing code order (but need not be consecutive: longer codes can sit
/// between them).
struct WmaproVlc {
  max_len : Int32
  /// Per code length: how many codes there are and where they start in
  /// `codes` / `syms`.
  count : FixedArray[Int32]
  start : FixedArray[Int32]
  codes : Array[Int32]
  syms : Array[Int32]
}

///|
fn wmapro_vlc_new(
  syms : FixedArray[Int32],
  lens : FixedArray[Int32],
  offset : Int32,
) -> WmaproVlc {
  let n = lens.length()
  let mut max_len = 1
  for i in 0..<n {
    if lens[i] > max_len {
      max_len = lens[i]
    }
  }
  let count = FixedArray::makei(max_len + 1, _ => 0)
  for i in 0..<n {
    if lens[i] > 0 {
      count[lens[i]] += 1
    }
  }
  let start = FixedArray::makei(max_len + 2, _ => 0)
  let mut acc = 0
  for len in 1..<=max_len {
    start[len] = acc
    acc += count[len]
  }
  let codes = Array::make(acc, 0)
  let out_syms = Array::make(acc, 0)
  let fill = FixedArray::makei(max_len + 1, _ => 0)
  let mut code : UInt64 = 0UL
  for i in 0..<n {
    let len = lens[i]
    if len > 0 {
      let c = (code >> (32 - len)).to_int()
      codes[start[len] + fill[len]] = c
      out_syms[start[len] + fill[len]] = syms[i] + offset
      fill[len] += 1
      code = code + (1UL << (32 - len))
    }
  }
  { max_len, count, start, codes, syms: out_syms, }
}

///|
/// `get_vlc2` on one of these tables: one bit at a time, and a binary
/// search among the codes of each length. The tables of `wmaprodata.h` are
/// complete prefix codes (the generator checks the Kraft sum), so every bit
/// string is a code; the escape symbols arrive as `-1`, as in the C.
fn WmaproBits::read_vlc(self : WmaproBits, vlc : WmaproVlc) -> Int32 {
  let mut code = 0
  for len in 1..<=vlc.max_len {
    code = (code << 1) | self.read1().reinterpret_as_int()
    let cnt = vlc.count[len]
    if cnt > 0 {
      let lo = vlc.start[len]
      let mut a = 0
      let mut b = cnt
      let mut found = -1
      while a < b {
        let mid = (a + b) >> 1
        let c = vlc.codes[lo + mid]
        if c == code {
          found = mid
          break
        } else if c < code {
          a = mid + 1
        } else {
          b = mid
        }
      }
      if found >= 0 {
        return vlc.syms[lo + found]
      }
    }
  }
  abort("wmapro: incomplete Huffman table")
}

// ---------------------------------------------------------------------------
// per channel and per group state
// ---------------------------------------------------------------------------

///|
/// `WMAProChannelCtx`: one channel's frame state.
struct WmaproChannel {
  mut prev_block_len : Int32
  mut transmit_coefs : Bool
  mut num_subframes : Int32
  subframe_len : FixedArray[Int32]
  subframe_offset : FixedArray[Int32]
  mut cur_subframe : Int32
  mut decoded_samples : Int32
  mut grouped : Bool
  mut quant_step : Int32
  mut reuse_sf : Bool
  mut scale_factor_step : Int32
  mut max_scale_factor : Int32
  saved_scale_factors : FixedArray[FixedArray[Int32]]
  mut scale_factor_idx : Int32
  /// The scale factors in use: one of `saved_scale_factors`.
  mut scale_factors : FixedArray[Int32]
  mut table_idx : Int32
  /// `coeffs`: index in `out` where the current subframe is decoded.
  mut coeffs : Int32
  mut num_vec_coeffs : Int32
  out : Array[Double]
}

///|
fn WmaproChannel::new() -> WmaproChannel {
  {
    prev_block_len: 0,
    transmit_coefs: false,
    num_subframes: 0,
    subframe_len: FixedArray::makei(wmapro_max_subframes, _ => 0),
    subframe_offset: FixedArray::makei(wmapro_max_subframes, _ => 0),
    cur_subframe: 0,
    decoded_samples: 0,
    grouped: false,
    quant_step: 0,
    reuse_sf: false,
    scale_factor_step: 0,
    max_scale_factor: 0,
    saved_scale_factors: FixedArray::makei(2, _ => {
      FixedArray::makei(wmapro_max_bands, _ => 0)
    }),
    scale_factor_idx: 0,
    scale_factors: FixedArray::makei(wmapro_max_bands, _ => 0),
    table_idx: 0,
    coeffs: 0,
    num_vec_coeffs: 0,
    out: Array::make(wmapro_block_max_size + wmapro_block_max_size / 2, 0.0),
  }
}

///|
/// `WMAProChannelGrp`: channels decoded as one group.
struct WmaproChannelGrp {
  mut num_channels : Int32
  mut transform : Bool
  transform_band : FixedArray[Int32]
  decorrelation_matrix : Array[Double]
  /// The channels whose coefficients the group transforms (the C keeps
  /// `float *` into `channel[c].coeffs`).
  channel_data : FixedArray[Int32]
}

///|
fn WmaproChannelGrp::new() -> WmaproChannelGrp {
  {
    num_channels: 0,
    transform: false,
    transform_band: FixedArray::makei(wmapro_max_bands, _ => 0),
    decorrelation_matrix: Array::make(
      wmapro_max_channels * wmapro_max_channels,
      0.0,
    ),
    channel_data: FixedArray::makei(wmapro_max_channels, _ => 0),
  }
}

// ---------------------------------------------------------------------------
// decoder state
// ---------------------------------------------------------------------------

///|
pub struct WmaProDecoder {
  /// The bit reservoir (`frame_data`). It is never cleared: a frame that
  /// overreads sees the bytes of an earlier frame, as in the C.
  frame_data : Array[Byte]
  /// `put_bits_count` of the reservoir's writer.
  mut pb_pos : Int32
  /// IMDCT scale per block size (`av_tx_init`'s `scale`).
  tx_scale : FixedArray[Double]
  tmp : Array[Double]
  /// The frame being decoded (`frame->extended_data`).
  frame_buf : Array[Array[Double]]
  windows : Array[Array[Double]]
  /// `cos(k * pi / (4 * samples_per_frame))`, one period.
  imdct_cos : Array[Double]
  imdct_mask : Int32
  sample_rate : Int32
  block_align : Int32
  decode_flags : Int32
  len_prefix : Bool
  dynamic_range_compression : Bool
  bits_per_sample : Int32
  samples_per_frame : Int32
  mut trim_start : Int32
  mut trim_end : Int32
  log2_frame_size : Int32
  lfe_channel : Int32
  max_num_subframes : Int32
  subframe_len_bits : Int32
  max_subframe_len_bit : Bool
  min_samples_per_subframe : Int32
  num_sfb : FixedArray[Int32]
  sfb_offsets : Array[FixedArray[Int32]]
  sf_offsets : Array[Array[FixedArray[Int32]]]
  subwoofer_cutoffs : FixedArray[Int32]
  // packet decode state
  mut pgb : WmaproBits
  mut next_packet_start : Int32
  mut packet_offset : Int32
  mut packet_sequence_number : Int32
  mut num_saved_bits : Int32
  mut frame_offset : Int32
  mut packet_loss : Bool
  mut packet_done : Bool
  mut eof_done : Bool
  // frame decode state
  mut gb : WmaproBits
  mut buf_bit_size : Int32
  mut skip_frame : Bool
  mut parsed_all_subframes : Bool
  // subframe decode state
  mut subframe_len : Int32
  nb_channels : Int32
  mut channels_for_cur_subframe : Int32
  channel_indexes_for_cur_subframe : FixedArray[Int32]
  mut num_bands : Int32
  mut transmit_num_vec_coeffs : Bool
  mut table_idx : Int32
  mut esc_len : Int32
  mut num_chgroups : Int32
  chgroup : Array[WmaproChannelGrp]
  channel : Array[WmaproChannel]
  sf_vlc : WmaproVlc
  sf_rl_vlc : WmaproVlc
  coef_vlc : Array[WmaproVlc]
  vec4_vlc : WmaproVlc
  vec2_vlc : WmaproVlc
  vec1_vlc : WmaproVlc
  sin64 : Array[Double]
  mut last_error : String
}

// ---------------------------------------------------------------------------
// DSP kernels
// ---------------------------------------------------------------------------

///|
/// `ff_sine_windows[6 + k]`: `sin((i + 0.5) * pi / (2 * n))`, `n = 64 << k`.
fn wmapro_sine_windows() -> Array[Array[Double]] {
  let pi = 3.14159265358979323846
  let out : Array[Array[Double]] = []
  for k in 0..<wmapro_block_sizes {
    let n = wmapro_block_min_size() << k
    let w = Array::make(n, 0.0)
    for i in 0..<n {
      w[i] = @math.sin((i.to_double() + 0.5) * (pi / (2.0 * n.to_double())))
    }
    out.push(w)
  }
  out
}

///|
fn wmapro_block_min_size() -> Int32 {
  1 << wmapro_block_min_bits
}

///|
/// The inverse `AV_TX_FLOAT_MDCT` through its defining sum
/// (`ff_tx_mdct_naive_inv`): the `n` inputs `src[0 ..< n]` become the `n`
/// samples at `dst[dst_off ..]`, times `scale`. (The tx length is the frame
/// size: the inverse takes `n` coefficients and gives the `n` non-redundant
/// samples.)
/// `cos` holds `cos(k * pi / (4 * samples_per_frame))` for one period and
/// `ratio` is `samples_per_frame / n`.
fn wmapro_imdct(
  cos : Array[Double],
  cos_mask : Int32,
  ratio : Int32,
  src : Array[Double],
  dst : Array[Double],
  dst_off : Int32,
  n : Int32,
  scale : Double,
) -> Unit {
  let half = n / 2
  for i in 0..<half {
    let a_d = 2 * n - 2 * i - 1
    let a_u = 3 * n + 2 * i + 1
    let mut sum_d = 0.0
    let mut sum_u = 0.0
    for j in 0..<n {
      let v = src[j]
      if v != 0.0 {
        let m = (2 * j + 1) * ratio
        sum_d += cos[(m * a_d) & cos_mask] * v
        sum_u += cos[(m * a_u) & cos_mask] * v
      }
    }
    dst[dst_off + i] = sum_d * scale
    dst[dst_off + half + i] = -(sum_u * scale)
  }
}

///|
/// `vector_fmul_window(start, start, start + len, window, len)` of
/// `float_dsp.c`, in place on `buf[start ..]`.
fn wmapro_fmul_window(
  buf : Array[Double],
  start : Int32,
  win : Array[Double],
  len : Int32,
) -> Unit {
  for k in 0..<len {
    let j = len - 1 - k
    let s0 = buf[start + k]
    let s1 = buf[start + len + j]
    let wi = win[k]
    let wj = win[len + j]
    buf[start + k] = s0 * wj - s1 * wi
    buf[start + len + j] = s0 * wi + s1 * wj
  }
}
