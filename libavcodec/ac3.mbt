///|
/// AC-3 (ATSC A/52A) decoder, ported from FFmpeg 9.0.2 `libavcodec/ac3dec.c`
/// (float path), `ac3.c` (bit allocation) and `ac3_parser.c` (frame header).
///
/// Scope: plain AC-3 (bsid <= 10), all channel modes including dual mono and
/// LFE, coupling, stereo rematrixing, delta bit allocation, zero-mantissa
/// dithering, dynamic range compression (`drc_scale` fixed at FFmpeg's default
/// 1.0), and the 256/128-point IMDCT with KBD windowing.  E-AC-3 is rejected
/// with an error.  No downmixing is applied (FFmpeg's default decoder layout
/// keeps the coded channel count), so output channels follow the SMPTE order
/// of `ff_ac3_dec_channel_map`.
///
/// The C runs an FFT-based IMDCT; this port evaluates the same half-inverse
/// MDCT directly with precomputed cosine matrices (exact, O(N^2)).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// constants (ac3defs.h)
// ---------------------------------------------------------------------------

///|
let ac3_max_channels : Int32 = 7

///|
let ac3_max_coefs : Int32 = 256

///|
let ac3_block_size : Int32 = 256

///|
let ac3_max_blocks : Int32 = 6

///|
let ac3_critical_bands : Int32 = 50

///|
let ac3_max_cpl_bands : Int32 = 18

///|
let ac3_exp_reuse : Int32 = 0

///|
let ac3_dba_reuse : Int32 = 0

///|
let ac3_dba_new : Int32 = 1

///|
let ac3_dba_none : Int32 = 2

///|
let ac3_dba_reserved : Int32 = 3

///|
let ac3_chmode_dualmono : Int32 = 0

///|
let ac3_chmode_mono : Int32 = 1

///|
let ac3_chmode_stereo : Int32 = 2

///|
let ac3_chmode_2f2r : Int32 = 6

///|
/// `1.0 / 4194304`: the Q24 mantissa scale applied before the IMDCT. */
let ac3_coef_scale : Double = 1.0 / 4194304.0

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

///|
/// `get_sbits`: signed `n`-bit value (`1 <= n <= 32`), sign-extended.
fn ac3_get_sbits(gb : BitReader, n : Int32) -> Int32 {
  let v = gb.read(n)
  if n >= 32 {
    v.reinterpret_as_int()
  } else {
    v.reinterpret_as_int() << (32 - n) >> (32 - n)
  }
}

///|
fn ac3_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// `MULH(a, b)`: high 32 bits of the 64-bit product. */
fn ac3_mulh(a : Int32, b : Int32) -> Int32 {
  ((a.to_int64() * b.to_int64()) >> 32).to_int()
}

///|
/// `av_log2`: floor(log2(v)) for `v > 0`.
fn ac3_av_log2(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `av_clip_uintp2(a, p)`: 0 when `a` is outside `[0, 2^p)`. */
fn ac3_clip_uintp2(a : Int32, p : Int32) -> Int32 {
  if a < 0 {
    0
  } else if a >= 1 << p {
    (1 << p) - 1
  } else {
    a
  }
}

// ---------------------------------------------------------------------------
// dynamic range table (ac3_float_tables_init)
// ---------------------------------------------------------------------------

///|
fn ac3_build_dynamic_range_table() -> Array[Double] {
  let tab : Array[Double] = Array::make(256, 0.0)
  for i = 0; i < 256; i = i + 1 {
    let v = (i >> 5) - (i >> 7 << 3) - 5
    tab[i] = @math.pow(2.0, v.to_double()) * ((i & 0x1F) | 0x20).to_double()
  }
  tab
}

///|
/// `dynamic_range_tab`: `powf(2, v) * ((i & 0x1F) | 0x20)`. */
let ac3_dynamic_range_tab : Array[Double] = ac3_build_dynamic_range_table()

// ---------------------------------------------------------------------------
// lagged Fibonacci dither generator (libavutil/lfg)
// ---------------------------------------------------------------------------

///|
/// `AVLFG`: the C seeds `state[8..64]` from MD5(seed, i) and keeps the
/// previous digest bytes when hashing the next chunk.
struct Ac3Lfg {
  state : FixedArray[UInt32]
  mut index : Int32
}

///|
/// `av_lfg_init(c, seed)`. */
fn ac3_lfg_new(seed : UInt32) -> Ac3Lfg {
  let state = FixedArray::make(64, 0U)
  let tmp : Array[Byte] = Array::make(16, b'\x00')
  let mut i = 8
  while i < 64 {
    tmp[0] = (seed & 0xFFU).to_byte()
    tmp[1] = ((seed >> 8) & 0xFFU).to_byte()
    tmp[2] = ((seed >> 16) & 0xFFU).to_byte()
    tmp[3] = ((seed >> 24) & 0xFFU).to_byte()
    tmp[4] = i.to_byte()
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, Bytes::from_array(tmp), 16)
    for k = 0; k < 16; k = k + 1 {
      tmp[k] = digest[k]
    }
    for w = 0; w < 4; w = w + 1 {
      let p = w * 4
      state[i + w] = tmp[p].to_uint() |
        (tmp[p + 1].to_uint() << 8) |
        (tmp[p + 2].to_uint() << 16) |
        (tmp[p + 3].to_uint() << 24)
    }
    i = i + 4
  }
  { state, index: 0, }
}

///|
/// `av_lfg_get`. */
fn Ac3Lfg::get(self : Ac3Lfg) -> UInt32 {
  let a = self.state[(self.index - 24) & 63] +
    self.state[(self.index - 55) & 63]
  self.state[self.index & 63] = a
  self.index = self.index + 1
  a
}

// ---------------------------------------------------------------------------
// inverse MDCT (ff_tx_mdct_naive_inv)
// ---------------------------------------------------------------------------

///|
/// Two cosine matrices (`sum_d` / `sum_u`) for `ff_tx_mdct_naive_inv` with
/// length `n`: the C evaluates `cos((2j+1) * i_d)` and `cos((2j+1) * i_u)`
/// for `j < n` and `i < n/2`, which is what these tables hold.
fn ac3_build_imdct_tables(n : Int32) -> Array[FixedArray[Double]] {
  let len = n / 2
  let phase = 3.14159265358979323846 / (4.0 * n.to_double())
  let d = FixedArray::make(len * n, 0.0)
  let u = FixedArray::make(len * n, 0.0)
  for i = 0; i < len; i = i + 1 {
    let i_d = phase * (4 * len - 2 * i - 1).to_double()
    let i_u = phase * (3 * n + 2 * i + 1).to_double()
    for j = 0; j < n; j = j + 1 {
      let a = (2 * j + 1).to_double()
      d[i * n + j] = @math.cos(a * i_d)
      u[i * n + j] = @math.cos(a * i_u)
    }
  }
  [d, u]
}

///|
let ac3_imdct256_tables : Array[FixedArray[Double]] = ac3_build_imdct_tables(
  256,
)

///|
let ac3_imdct128_tables : Array[FixedArray[Double]] = ac3_build_imdct_tables(
  128,
)

///|
/// `ff_tx_mdct_naive_inv`: `n` coefficients to `n` samples, scale 1.0.
/// `dst[i] = sum_d`, `dst[i + n/2] = -sum_u`.
fn ac3_imdct(coef : Array[Double], n : Int32) -> Array[Double] {
  let tables = if n == 256 { ac3_imdct256_tables } else { ac3_imdct128_tables }
  let d = tables[0]
  let u = tables[1]
  let len = n / 2
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < len; i = i + 1 {
    let base = i * n
    let mut sum_d = 0.0
    let mut sum_u = 0.0
    for j = 0; j < n; j = j + 1 {
      let v = coef[j]
      if v != 0.0 {
        sum_d = sum_d + d[base + j] * v
        sum_u = sum_u + u[base + j] * v
      }
    }
    out[i] = sum_d
    out[i + len] = -sum_u
  }
  out
}

///|
/// `ff_kbd_window_init(s->window, 5.0, 256)`.
let ac3_window : Array[Double] = aac_kbd_window(5.0, 256)

///|
/// `vector_fmul_window(dst, src0, src1, win, len)`: the overlap-add helper
/// shared with AAC (`aac_fmul_window`), writing `2*len` samples at `dstoff`.
fn ac3_fmul_window(
  dst : Array[Double],
  dstoff : Int32,
  src0 : Array[Double],
  src1 : Array[Double],
  win : Array[Double],
  len : Int32,
) -> Unit {
  for k = 0; k < len; k = k + 1 {
    let s0 = src0[k]
    let s1 = src1[len - 1 - k]
    let wi = win[k]
    let wj = win[2 * len - 1 - k]
    dst[dstoff + k] = s0 * wj - s1 * wi
    dst[dstoff + 2 * len - 1 - k] = s0 * wi + s1 * wj
  }
}

// ---------------------------------------------------------------------------
// frame header (ac3_parser.c)
// ---------------------------------------------------------------------------

///|
/// `AC3HeaderInfo` subset the decoder and the raw demuxer need. */
pub struct Ac3Header {
  sample_rate : Int32
  bit_rate : Int32
  channels : Int32
  frame_size : Int32
  channel_mode : Int32
  lfe_on : Bool
  bitstream_id : Int32
  sr_code : Int32
  sr_shift : Int32
  bitstream_mode : Int32
  num_blocks : Int32
  frame_type : Int32
  substreamid : Int32
  channel_map_present : Bool
  channel_map : Int32
  center_mix_level : Int32
  surround_mix_level : Int32
  center_mix_level_ltrt : Int32
  surround_mix_level_ltrt : Int32
  preferred_downmix : Int32
  lfe_mix_level_exists : Bool
  lfe_mix_level : Int32
  dolby_surround_mode : Int32
  dolby_surround_ex_mode : Int32
  dolby_headphone_mode : Int32
  eac3_extension_type_a : Int32
  dialog_normalization : FixedArray[Int32]
  compression_exists : FixedArray[Bool]
  heavy_dynamic_range : FixedArray[Int32]
}

///|
/// `eac3_blocks`: number of audio blocks for the two-bit E-AC-3 code. */
let ac3_eac3_blocks_tab : FixedArray[Int32] = [1, 2, 3, 6]

///|
/// `center_levels` / `surround_levels` mix-level code tables. */
let ac3_center_levels : FixedArray[Int32] = [4, 5, 6, 5]

///|
let ac3_surround_levels : FixedArray[Int32] = [4, 6, 7, 6]

///|
/// `ff_ac3_find_syncword`: offset of the 0x0B77 syncword, or `-1`. */
pub fn ac3_find_syncword(buf : Bytes) -> Int32 {
  let size = buf.length()
  let mut i = 1
  while i < size {
    let b = buf[i].to_int()
    if b == 0x77 || b == 0x0B {
      if (b ^ buf[i - 1].to_int()) == (0x77 ^ 0x0B) {
        i = i - 1
        break
      } else if i + 1 < size && (b ^ buf[i + 1].to_int()) == (0x77 ^ 0x0B) {
        break
      }
    }
    i = i + 2
  }
  if i >= size {
    -1
  } else {
    i
  }
}

///|
/// `ff_ac3_parse_header` for plain AC-3 (`bsid <= 10`).  The reader is left
/// after the bit stream information, ready for the audio blocks.
fn ac3_parse_header_bits(gb : BitReader) -> Result[Ac3Header, String] {
  let sync = gb.read(16)
  if sync != 0x0B77U {
    return Err("ac3: frame sync error")
  }
  let bitstream_id = (gb.show(29) & 0x1FU).reinterpret_as_int()
  if bitstream_id > 16 {
    return Err("ac3: invalid bitstream id")
  }
  let dialog_normalization = FixedArray::make(2, 0)
  let compression_exists = FixedArray::make(2, false)
  let heavy_dynamic_range = FixedArray::make(2, 0)
  if bitstream_id <= 10 {
    let _crc1 = gb.read(16)
    let sr_code = gb.read(2).reinterpret_as_int()
    if sr_code == 3 {
      return Err("ac3: invalid sample rate")
    }
    let frame_size_code = gb.read(6).reinterpret_as_int()
    if frame_size_code > 37 {
      return Err("ac3: invalid frame size")
    }
    let _ = gb.read(5) // bsid, already read ahead
    let bitstream_mode = gb.read(3).reinterpret_as_int()
    let channel_mode = gb.read(3).reinterpret_as_int()
    let mut center_mix_level = 5
    let mut surround_mix_level = 6
    let mut dolby_surround_mode = 0
    if channel_mode == ac3_chmode_stereo {
      dolby_surround_mode = gb.read(2).reinterpret_as_int()
    } else {
      if (channel_mode & 1) != 0 && channel_mode != ac3_chmode_mono {
        center_mix_level = ac3_center_levels[gb.read(2).reinterpret_as_int()]
      }
      if (channel_mode & 4) != 0 {
        surround_mix_level = ac3_surround_levels[gb.read(2).reinterpret_as_int()]
      }
    }
    let lfe_on = gb.read1() != 0
    let sr_shift = if bitstream_id > 8 { bitstream_id - 8 } else { 0 }
    let sample_rate = ac3_sample_rate_tab[sr_code] >> sr_shift
    let bit_rate = (ac3_bitrate_tab[frame_size_code >> 1] * 1000) >> sr_shift
    let channels = ac3_channels_tab[channel_mode] + (if lfe_on { 1 } else { 0 })
    let frame_size = ac3_frame_size_tab[frame_size_code][sr_code] * 2
    // ac3_parse_header: the dual-mono BSI block is read twice.
    let n_bsi = if channel_mode != 0 { 1 } else { 2 }
    for i = 0; i < n_bsi; i = i + 1 {
      dialog_normalization[i] = -gb.read(5).reinterpret_as_int()
      compression_exists[i] = gb.read1() != 0
      if compression_exists[i] {
        heavy_dynamic_range[i] = gb.read(8).reinterpret_as_int()
      }
      if gb.read1() != 0 {
        let _ = gb.read(8) // language code
      }
      if gb.read1() != 0 {
        let _ = gb.read(7) // audio production info
      }
    }
    let _ = gb.read(2) // copyright / original bitstream
    if bitstream_id != 6 {
      if gb.read1() != 0 {
        let _ = gb.read(14) // timecode 1
      }
      if gb.read1() != 0 {
        let _ = gb.read(14) // timecode 2
      }
    } else {
      // Alternate Bit Stream Syntax.
      if gb.read1() != 0 {
        let _ = gb.read(2) // preferred downmix
        let _ = gb.read(3) // Lt/Rt center mix level
        let _ = ac3_clip(gb.read(3).reinterpret_as_int(), 3, 7)
        center_mix_level = gb.read(3).reinterpret_as_int()
        surround_mix_level = ac3_clip(gb.read(3).reinterpret_as_int(), 3, 7)
      }
      if gb.read1() != 0 {
        let _ = gb.read(2) // Dolby Surround EX mode
        let _ = gb.read(2) // Dolby Headphone mode
        let _ = gb.read(10)
      }
    }
    if gb.read1() != 0 {
      let i = gb.read(6).reinterpret_as_int()
      for k = 0; k <= i; k = k + 1 {
        let _ = gb.read(8)
      }
    }
    return Ok({
      sample_rate,
      bit_rate,
      channels,
      frame_size,
      channel_mode,
      lfe_on,
      bitstream_id,
      sr_code,
      sr_shift,
      bitstream_mode,
      num_blocks: 6,
      frame_type: 2,
      substreamid: 0,
      channel_map_present: false,
      channel_map: 0,
      center_mix_level,
      surround_mix_level,
      center_mix_level_ltrt: 4,
      surround_mix_level_ltrt: 4,
      preferred_downmix: 0,
      lfe_mix_level_exists: false,
      lfe_mix_level: 0,
      dolby_surround_mode,
      dolby_surround_ex_mode: 0,
      dolby_headphone_mode: 0,
      eac3_extension_type_a: 0,
      dialog_normalization,
      compression_exists,
      heavy_dynamic_range,
    })
  }
  // Enhanced AC-3 (eac3_parse_header in ac3_parser.c).
  let frame_type = gb.read(2).reinterpret_as_int()
  if frame_type == 3 {
    return Err("eac3: reserved frame type")
  }
  let substreamid = gb.read(3).reinterpret_as_int()
  let frame_size = (gb.read(11).reinterpret_as_int() + 1) << 1
  if frame_size < 7 {
    return Err("eac3: invalid frame size")
  }
  let sr_code = gb.read(2).reinterpret_as_int()
  let mut sample_rate = 0
  let mut sr_shift = 0
  let mut num_blocks = 6
  if sr_code == 3 {
    let sr_code2 = gb.read(2).reinterpret_as_int()
    if sr_code2 == 3 {
      return Err("eac3: invalid sample rate")
    }
    sample_rate = ac3_sample_rate_tab[sr_code2] / 2
    sr_shift = 1
  } else {
    num_blocks = ac3_eac3_blocks_tab[gb.read(2).reinterpret_as_int()]
    sample_rate = ac3_sample_rate_tab[sr_code]
  }
  let channel_mode = gb.read(3).reinterpret_as_int()
  let lfe_on = gb.read1() != 0
  let bit_rate = 8 * frame_size * sample_rate / (num_blocks * 256)
  let channels = ac3_channels_tab[channel_mode] + (if lfe_on { 1 } else { 0 })
  let _ = gb.read(5) // bsid, already read ahead
  let mut bitstream_mode = 0
  let mut center_mix_level = 5
  let mut surround_mix_level = 6
  let mut center_mix_level_ltrt = 0
  let mut surround_mix_level_ltrt = 0
  let mut preferred_downmix = 0
  let mut lfe_mix_level_exists = false
  let mut lfe_mix_level = 0
  let mut dolby_surround_mode = 0
  let mut dolby_surround_ex_mode = 0
  let mut dolby_headphone_mode = 0
  let mut channel_map_present = false
  let mut channel_map = 0
  let mut eac3_extension_type_a = 0
  let n_bsi = if channel_mode != 0 { 1 } else { 2 }
  for i = 0; i < n_bsi; i = i + 1 {
    dialog_normalization[i] = -gb.read(5).reinterpret_as_int()
    compression_exists[i] = gb.read1() != 0
    if compression_exists[i] {
      heavy_dynamic_range[i] = gb.read(8).reinterpret_as_int()
    }
  }
  if frame_type == 1 {
    channel_map_present = gb.read1() != 0
    if channel_map_present {
      channel_map = gb.read(16).reinterpret_as_int()
    }
  }
  if gb.read1() != 0 {
    // mixing metadata
    if channel_mode > ac3_chmode_stereo {
      preferred_downmix = gb.read(2).reinterpret_as_int()
      if (channel_mode & 1) != 0 {
        center_mix_level_ltrt = gb.read(3).reinterpret_as_int()
        center_mix_level = gb.read(3).reinterpret_as_int()
      }
      if (channel_mode & 4) != 0 {
        surround_mix_level_ltrt = ac3_clip(
          gb.read(3).reinterpret_as_int(),
          3,
          7,
        )
        surround_mix_level = ac3_clip(gb.read(3).reinterpret_as_int(), 3, 7)
      }
    }
    if lfe_on {
      lfe_mix_level_exists = gb.read1() != 0
      if lfe_mix_level_exists {
        lfe_mix_level = gb.read(5).reinterpret_as_int()
      }
    }
    if frame_type == 0 {
      for _i = 0; _i < n_bsi; _i = _i + 1 {
        if gb.read1() != 0 {
          let _ = gb.read(6) // program scale factor
        }
      }
      if gb.read1() != 0 {
        let _ = gb.read(6) // external program scale factor
      }
      let mix = gb.read(2).reinterpret_as_int()
      if mix == 1 {
        let _ = gb.read(5)
      } else if mix == 2 {
        let _ = gb.read(12)
      } else if mix == 3 {
        let n = (gb.read(5).reinterpret_as_int() + 2) << 3
        gb.skip(n)
      }
      if channel_mode < ac3_chmode_stereo {
        for _i = 0; _i < n_bsi; _i = _i + 1 {
          if gb.read1() != 0 {
            let _ = gb.read(8) // pan mean direction
            let _ = gb.read(6) // pan info
          }
        }
      }
      if gb.read1() != 0 {
        for _i = 0; _i < num_blocks; _i = _i + 1 {
          if num_blocks == 1 || gb.read1() != 0 {
            let _ = gb.read(5)
          }
        }
      }
    }
  }
  if gb.read1() != 0 {
    // informational metadata
    bitstream_mode = gb.read(3).reinterpret_as_int()
    let _ = gb.read(2) // copyright / original
    if channel_mode == ac3_chmode_stereo {
      dolby_surround_mode = gb.read(2).reinterpret_as_int()
      dolby_headphone_mode = gb.read(2).reinterpret_as_int()
    }
    if channel_mode >= ac3_chmode_2f2r {
      dolby_surround_ex_mode = gb.read(2).reinterpret_as_int()
    }
    for _i = 0; _i < n_bsi; _i = _i + 1 {
      if gb.read1() != 0 {
        let _ = gb.read(8) // mix level / room type / A/D converter
      }
    }
    if sr_code != 3 {
      let _ = gb.read1() // source sample rate code
    }
  }
  if frame_type == 0 && num_blocks != 6 {
    let _ = gb.read1() // converter synchronization flag
  }
  if frame_type == 2 && (num_blocks == 6 || gb.read1() != 0) {
    let _ = gb.read(6) // original frame size code
  }
  if gb.read1() != 0 {
    let addbsil = gb.read(6).reinterpret_as_int()
    let mut i = 0
    while i < addbsil + 1 {
      if i == 0 {
        let _ = gb.read(7)
        eac3_extension_type_a = gb.read1().reinterpret_as_int()
        if eac3_extension_type_a != 0 {
          let _ = gb.read(8) // complexity index type A
          i = i + 1
        }
      } else {
        let _ = gb.read(8)
      }
      i = i + 1
    }
  }
  Ok({
    sample_rate,
    bit_rate,
    channels,
    frame_size,
    channel_mode,
    lfe_on,
    bitstream_id,
    sr_code,
    sr_shift,
    bitstream_mode,
    num_blocks,
    frame_type,
    substreamid,
    channel_map_present,
    channel_map,
    center_mix_level,
    surround_mix_level,
    center_mix_level_ltrt,
    surround_mix_level_ltrt,
    preferred_downmix,
    lfe_mix_level_exists,
    lfe_mix_level,
    dolby_surround_mode,
    dolby_surround_ex_mode,
    dolby_headphone_mode,
    eac3_extension_type_a,
    dialog_normalization,
    compression_exists,
    heavy_dynamic_range,
  })
}

///|
/// Parse one AC-3 frame header.  Returns an error for sync errors and for
/// E-AC-3 streams (`bsid > 10`).
pub fn ac3_parse_header(data : Bytes) -> Result[Ac3Header, String] {
  ac3_parse_header_bits(BitReader::new(data))
}

// ---------------------------------------------------------------------------
// decoder state
// ---------------------------------------------------------------------------

///|
/// One decoded AC-3 frame: `channels` planar arrays of 1536 double samples in
/// SMPTE channel order (`ff_ac3_dec_channel_map[acmod][lfe]`).
pub struct Ac3Frame {
  sample_rate : Int32
  bit_rate : Int32
  channels : Int32
  channel_mode : Int32
  lfe_on : Bool
  num_blocks : Int32
  samples : Array[Array[Double]]
}

///|
/// Persistent AC-3 decoder state.  Bit allocation, exponent strategies,
/// coupling coordinates and the IMDCT overlap delays carry across frames.
pub struct Ac3Decoder {
  mut bitstream_id : Int32
  mut bitstream_mode : Int32
  mut eac3 : Bool
  mut frame_type : Int32
  mut substreamid : Int32
  mut snr_offset_strategy : Int32
  mut block_switch_syntax : Bool
  mut dither_flag_syntax : Bool
  mut bit_allocation_syntax : Bool
  mut fast_gain_syntax : Bool
  mut dba_syntax : Bool
  mut skip_syntax : Bool
  cpl_strategy_exists : FixedArray[Bool]
  cpl_band_struct : FixedArray[Bool]
  channel_uses_aht : FixedArray[Bool]
  mut sample_rate : Int32
  mut bit_rate : Int32
  mut channels : Int32
  mut fbw_channels : Int32
  mut lfe_ch : Int32
  mut frame_size : Int32
  mut channel_mode : Int32
  mut lfe_on : Bool
  mut num_blocks : Int32
  mut sr_code : Int32
  mut sr_shift : Int32
  mut slow_decay : Int32
  mut fast_decay : Int32
  mut slow_gain : Int32
  mut db_per_bit : Int32
  mut floor : Int32
  mut cpl_fast_leak : Int32
  mut cpl_slow_leak : Int32
  cpl_in_use : FixedArray[Bool]
  channel_in_cpl : FixedArray[Bool]
  mut phase_flags_in_use : Bool
  phase_flags : FixedArray[Bool]
  mut num_cpl_bands : Int32
  cpl_band_sizes : FixedArray[Int32]
  first_cpl_coords : FixedArray[Bool]
  cpl_coords : Array[FixedArray[Int32]]
  mut first_cpl_leak : Bool
  mut num_rematrixing_bands : Int32
  rematrixing_flags : FixedArray[Bool]
  exp_strategy : Array[FixedArray[Int32]]
  num_exp_groups : FixedArray[Int32]
  dexps : Array[FixedArray[Int32]]
  start_freq : FixedArray[Int32]
  end_freq : FixedArray[Int32]
  snr_offset : FixedArray[Int32]
  fast_gain : FixedArray[Int32]
  bap : Array[FixedArray[Int32]]
  psd : Array[FixedArray[Int32]]
  band_psd : Array[FixedArray[Int32]]
  mask : Array[FixedArray[Int32]]
  dba_mode : FixedArray[Int32]
  dba_nsegs : FixedArray[Int32]
  dba_offsets : Array[FixedArray[Int32]]
  dba_lengths : Array[FixedArray[Int32]]
  dba_values : Array[FixedArray[Int32]]
  dither_flag : FixedArray[Bool]
  block_switch : FixedArray[Bool]
  dynamic_range : FixedArray[Double]
  fixed_coeffs : Array[FixedArray[Int32]]
  transform_coeffs : Array[Array[Double]]
  delay : Array[Array[Double]]
  dith_state : Ac3Lfg
}

///|
fn ac3_channel_arrays_int(len : Int32) -> Array[FixedArray[Int32]] {
  let out : Array[FixedArray[Int32]] = []
  for k = 0; k < ac3_max_channels; k = k + 1 {
    out.push(FixedArray::make(len, 0))
  }
  out
}

///|
fn ac3_channel_arrays_double(len : Int32) -> Array[Array[Double]] {
  let out : Array[Array[Double]] = []
  for k = 0; k < ac3_max_channels; k = k + 1 {
    out.push(Array::make(len, 0.0))
  }
  out
}

///|
/// Fresh decoder state, equivalent to `ac3_decode_init` with a zeroed context.
pub fn ac3_decoder_new() -> Ac3Decoder {
  let exp_strategy : Array[FixedArray[Int32]] = []
  for k = 0; k < ac3_max_blocks; k = k + 1 {
    exp_strategy.push(FixedArray::make(ac3_max_channels, 0))
  }
  {
    bitstream_id: 0,
    bitstream_mode: 0,
    eac3: false,
    frame_type: 2,
    substreamid: 0,
    snr_offset_strategy: 2,
    block_switch_syntax: true,
    dither_flag_syntax: true,
    bit_allocation_syntax: true,
    fast_gain_syntax: false,
    dba_syntax: true,
    skip_syntax: true,
    cpl_strategy_exists: FixedArray::make(ac3_max_blocks, false),
    cpl_band_struct: FixedArray::make(ac3_max_cpl_bands, false),
    channel_uses_aht: FixedArray::make(ac3_max_channels, false),
    sample_rate: 0,
    bit_rate: 0,
    channels: 0,
    fbw_channels: 0,
    lfe_ch: 0,
    frame_size: 0,
    channel_mode: 0,
    lfe_on: false,
    num_blocks: 0,
    sr_code: 0,
    sr_shift: 0,
    slow_decay: 0,
    fast_decay: 0,
    slow_gain: 0,
    db_per_bit: 0,
    floor: 0,
    cpl_fast_leak: 0,
    cpl_slow_leak: 0,
    cpl_in_use: FixedArray::make(ac3_max_blocks, false),
    channel_in_cpl: FixedArray::make(ac3_max_channels, false),
    phase_flags_in_use: false,
    phase_flags: FixedArray::make(ac3_max_cpl_bands, false),
    num_cpl_bands: 0,
    cpl_band_sizes: FixedArray::make(ac3_max_cpl_bands, 0),
    first_cpl_coords: FixedArray::make(ac3_max_channels, false),
    cpl_coords: ac3_channel_arrays_int(ac3_max_cpl_bands),
    first_cpl_leak: false,
    num_rematrixing_bands: 0,
    rematrixing_flags: FixedArray::make(4, false),
    exp_strategy,
    num_exp_groups: FixedArray::make(ac3_max_channels, 0),
    dexps: ac3_channel_arrays_int(ac3_max_coefs),
    start_freq: FixedArray::make(ac3_max_channels, 0),
    end_freq: FixedArray::make(ac3_max_channels, 0),
    snr_offset: FixedArray::make(ac3_max_channels, 0),
    fast_gain: FixedArray::make(ac3_max_channels, 0),
    bap: ac3_channel_arrays_int(ac3_max_coefs),
    psd: ac3_channel_arrays_int(ac3_max_coefs),
    band_psd: ac3_channel_arrays_int(ac3_critical_bands),
    mask: ac3_channel_arrays_int(ac3_critical_bands),
    dba_mode: FixedArray::make(ac3_max_channels, 0),
    dba_nsegs: FixedArray::make(ac3_max_channels, 0),
    dba_offsets: ac3_channel_arrays_int(8),
    dba_lengths: ac3_channel_arrays_int(8),
    dba_values: ac3_channel_arrays_int(8),
    dither_flag: FixedArray::make(ac3_max_channels, false),
    block_switch: FixedArray::make(ac3_max_channels, false),
    dynamic_range: FixedArray::make(2, 1.0),
    fixed_coeffs: ac3_channel_arrays_int(ac3_max_coefs),
    transform_coeffs: ac3_channel_arrays_double(ac3_max_coefs),
    delay: ac3_channel_arrays_double(128),
    dith_state: ac3_lfg_new(0U),
  }
}

// ---------------------------------------------------------------------------
// bit allocation (ac3.c)
// ---------------------------------------------------------------------------

///|
/// `ff_ac3_bit_alloc_calc_psd`. */
fn ac3_bit_alloc_calc_psd(
  exp : FixedArray[Int32],
  start : Int32,
  end : Int32,
  psd : FixedArray[Int32],
  band_psd : FixedArray[Int32],
) -> Unit {
  for bin = start; bin < end; bin = bin + 1 {
    psd[bin] = 3072 - (exp[bin] << 7)
  }
  let mut bin = start
  let mut band = ac3_bin_to_band_tab[start]
  while true {
    let mut v = psd[bin]
    bin = bin + 1
    let band_end = if ac3_band_start_tab[band + 1] < end {
      ac3_band_start_tab[band + 1]
    } else {
      end
    }
    while bin < band_end {
      let mx = if v > psd[bin] { v } else { psd[bin] }
      let adr = if mx - ((v + psd[bin] + 1) >> 1) < 255 {
        mx - ((v + psd[bin] + 1) >> 1)
      } else {
        255
      }
      v = mx + ac3_log_add_tab[adr]
      bin = bin + 1
    }
    band_psd[band] = v
    band = band + 1
    if end <= ac3_band_start_tab[band] {
      break
    }
  }
}

///|
fn ac3_calc_lowcomp1(a : Int32, b0 : Int32, b1 : Int32, c : Int32) -> Int32 {
  if b0 + 256 == b1 {
    c
  } else if b0 > b1 {
    if a - 64 > 0 {
      a - 64
    } else {
      0
    }
  } else {
    a
  }
}

///|
fn ac3_calc_lowcomp(a : Int32, b0 : Int32, b1 : Int32, bin : Int32) -> Int32 {
  if bin < 7 {
    ac3_calc_lowcomp1(a, b0, b1, 384)
  } else if bin < 20 {
    ac3_calc_lowcomp1(a, b0, b1, 320)
  } else if a - 128 > 0 {
    a - 128
  } else {
    0
  }
}

///|
/// `ff_ac3_bit_alloc_calc_mask`.  Returns false on invalid DBA data. */
fn ac3_bit_alloc_calc_mask(
  d : Ac3Decoder,
  band_psd : FixedArray[Int32],
  start : Int32,
  end : Int32,
  fast_gain : Int32,
  is_lfe : Bool,
  dba_mode : Int32,
  dba_nsegs : Int32,
  dba_offsets : FixedArray[Int32],
  dba_lengths : FixedArray[Int32],
  dba_values : FixedArray[Int32],
  mask : FixedArray[Int32],
) -> Bool {
  if end <= 0 {
    return false
  }
  let excite = FixedArray::make(ac3_critical_bands, 0)
  let band_start = ac3_bin_to_band_tab[start]
  let band_end = ac3_bin_to_band_tab[end - 1] + 1
  let mut begin = 0
  let mut lowcomp = 0
  let mut fastleak = 0
  let mut slowleak = 0
  if band_start == 0 {
    lowcomp = ac3_calc_lowcomp1(lowcomp, band_psd[0], band_psd[1], 384)
    excite[0] = band_psd[0] - fast_gain - lowcomp
    lowcomp = ac3_calc_lowcomp1(lowcomp, band_psd[1], band_psd[2], 384)
    excite[1] = band_psd[1] - fast_gain - lowcomp
    begin = 7
    let mut band = 2
    while band < 7 {
      if !(is_lfe && band == 6) {
        lowcomp = ac3_calc_lowcomp1(
          lowcomp,
          band_psd[band],
          band_psd[band + 1],
          384,
        )
      }
      fastleak = band_psd[band] - fast_gain
      slowleak = band_psd[band] - d.slow_gain
      excite[band] = fastleak - lowcomp
      if !(is_lfe && band == 6) {
        if band_psd[band] <= band_psd[band + 1] {
          begin = band + 1
          break
        }
      }
      band = band + 1
    }
    let end1 = if band_end < 22 { band_end } else { 22 }
    let mut band = begin
    while band < end1 {
      if !(is_lfe && band == 6) {
        lowcomp = ac3_calc_lowcomp(
          lowcomp,
          band_psd[band],
          band_psd[band + 1],
          band,
        )
      }
      let fl = fastleak - d.fast_decay
      let bl = band_psd[band] - fast_gain
      fastleak = if fl > bl { fl } else { bl }
      let sl = slowleak - d.slow_decay
      let bs = band_psd[band] - d.slow_gain
      slowleak = if sl > bs { sl } else { bs }
      let e0 = fastleak - lowcomp
      excite[band] = if e0 > slowleak { e0 } else { slowleak }
      band = band + 1
    }
    begin = 22
  } else {
    // Coupling channel.
    begin = band_start
    fastleak = (d.cpl_fast_leak << 8) + 768
    slowleak = (d.cpl_slow_leak << 8) + 768
  }
  for band = begin; band < band_end; band = band + 1 {
    let fl = fastleak - d.fast_decay
    let bl = band_psd[band] - fast_gain
    fastleak = if fl > bl { fl } else { bl }
    let sl = slowleak - d.slow_decay
    let bs = band_psd[band] - d.slow_gain
    slowleak = if sl > bs { sl } else { bs }
    excite[band] = if fastleak > slowleak { fastleak } else { slowleak }
  }
  for band = band_start; band < band_end; band = band + 1 {
    let tmp = d.db_per_bit - band_psd[band]
    if tmp > 0 {
      excite[band] = excite[band] + (tmp >> 2)
    }
    let thr = ac3_hearing_threshold_tab[band >> d.sr_shift][d.sr_code]
    mask[band] = if thr > excite[band] { thr } else { excite[band] }
  }
  if dba_mode == ac3_dba_reuse || dba_mode == ac3_dba_new {
    if dba_nsegs > 8 {
      return false
    }
    let mut band = band_start
    for seg = 0; seg < dba_nsegs; seg = seg + 1 {
      band = band + dba_offsets[seg]
      if band >= ac3_critical_bands ||
        dba_lengths[seg] > ac3_critical_bands - band {
        return false
      }
      let delta = if dba_values[seg] >= 4 {
        (dba_values[seg] - 3) * 128
      } else {
        (dba_values[seg] - 4) * 128
      }
      for k = 0; k < dba_lengths[seg]; k = k + 1 {
        mask[band] = mask[band] + delta
        band = band + 1
      }
    }
  }
  true
}

///|
/// `ac3_bit_alloc_calc_bap_c`. */
fn ac3_bit_alloc_calc_bap(
  mask : FixedArray[Int32],
  psd : FixedArray[Int32],
  start : Int32,
  end : Int32,
  snr_offset : Int32,
  floor : Int32,
  bap : FixedArray[Int32],
) -> Unit {
  if snr_offset == -960 {
    for i = 0; i < ac3_max_coefs; i = i + 1 {
      bap[i] = 0
    }
    return
  }
  let mut bin = start
  let mut band = ac3_bin_to_band_tab[start]
  while true {
    let t = mask[band] - snr_offset - floor
    let m = ((if t > 0 { t } else { 0 }) & 0x1FE0) + floor
    band = band + 1
    let band_end0 = ac3_band_start_tab[band]
    let band_end = if band_end0 < end { band_end0 } else { end }
    while bin < band_end {
      let address = ac3_clip_uintp2((psd[bin] - m) >> 5, 6)
      bap[bin] = ac3_bap_tab[address]
      bin = bin + 1
    }
    if end <= band_end {
      break
    }
  }
}

// ---------------------------------------------------------------------------
// exponents
// ---------------------------------------------------------------------------

///|
/// `decode_exponents`: ungroup 7-bit exponent codes and expand to
/// `group_size` coefficients per delta.  Writes `dexps[dst..]`.
fn ac3_decode_exponents(
  gb : BitReader,
  exp_strategy : Int32,
  ngrps : Int32,
  absexp : Int32,
  dexps : FixedArray[Int32],
  dst : Int32,
) -> Result[Unit, String] {
  let group_size = exp_strategy + (if exp_strategy == 3 { 1 } else { 0 })
  let dexp = FixedArray::make(256, 0)
  let mut i = 0
  for grp = 0; grp < ngrps; grp = grp + 1 {
    let expacc = gb.read(7).reinterpret_as_int()
    if expacc >= 125 {
      return Err("ac3: exponent code out of range")
    }
    dexp[i] = ac3_ungroup_3_in_7_bits_tab[expacc][0]
    dexp[i + 1] = ac3_ungroup_3_in_7_bits_tab[expacc][1]
    dexp[i + 2] = ac3_ungroup_3_in_7_bits_tab[expacc][2]
    i = i + 3
  }
  let mut prevexp = absexp
  let mut j = dst
  for k = 0; k < ngrps * 3; k = k + 1 {
    prevexp = prevexp + dexp[k] - 2
    if prevexp < 0 || prevexp > 24 {
      return Err("ac3: exponent out of range")
    }
    if group_size == 4 {
      dexps[j] = prevexp
      dexps[j + 1] = prevexp
      j = j + 2
    }
    if group_size >= 2 {
      dexps[j] = prevexp
      j = j + 1
    }
    dexps[j] = prevexp
    j = j + 1
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// coupling / band structure
// ---------------------------------------------------------------------------

///|
/// `decode_band_structure` for plain AC-3 (`eac3=0`, `ecpl=0`): always reads
/// `n_subbands - 1` structure bits and derives the band sizes.
fn ac3_decode_band_structure(
  gb : BitReader,
  blk : Int32,
  eac3 : Bool,
  start_subband : Int32,
  end_subband : Int32,
  band_struct : FixedArray[Bool],
  num_bands : Ref[Int32],
  band_sizes : FixedArray[Int32],
) -> Unit {
  let n_subbands = end_subband - start_subband
  if blk == 0 {
    for i = 0; i < ac3_max_cpl_bands; i = i + 1 {
      band_struct[i] = ac3_default_cpl_band_struct[i] != 0
    }
  }
  // E-AC-3 writes a "new structure" bit; 0 keeps the previous (or default)
  // layout.
  let explicit = if eac3 { gb.read1() != 0 } else { true }
  if explicit {
    for subbnd = 0; subbnd < n_subbands - 1; subbnd = subbnd + 1 {
      band_struct[start_subband + 1 + subbnd] = gb.read1() != 0
    }
  }
  let bnd_sz = FixedArray::make(22, 0)
  let mut n_bands = n_subbands
  bnd_sz[0] = 12
  let mut bnd = 0
  for subbnd = 1; subbnd < n_subbands; subbnd = subbnd + 1 {
    if band_struct[start_subband + subbnd] {
      n_bands = n_bands - 1
      bnd_sz[bnd] = bnd_sz[bnd] + 12
    } else {
      bnd = bnd + 1
      bnd_sz[bnd] = 12
    }
  }
  num_bands.val = n_bands
  for k = 0; k < n_bands; k = k + 1 {
    band_sizes[k] = bnd_sz[k]
  }
}

///|
/// `coupling_strategy` for plain AC-3. */
fn Ac3Decoder::coupling_strategy(
  self : Ac3Decoder,
  gb : BitReader,
  blk : Int32,
  bit_alloc_stages : FixedArray[Int32],
) -> Result[Unit, String] {
  for ch = 0; ch < ac3_max_channels; ch = ch + 1 {
    bit_alloc_stages[ch] = 3
  }
  if !self.eac3 {
    self.cpl_in_use[blk] = gb.read1() != 0
  }
  let cpl_in_use = self.cpl_in_use[blk]
  if cpl_in_use {
    if self.channel_mode < ac3_chmode_stereo {
      return Err("ac3: coupling not allowed in mono or dual mono")
    }
    if self.eac3 && gb.read1() != 0 {
      return Err("eac3: enhanced coupling is not supported")
    }
    if self.eac3 && self.channel_mode == ac3_chmode_stereo {
      self.channel_in_cpl[1] = true
      self.channel_in_cpl[2] = true
    } else {
      for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
        self.channel_in_cpl[ch] = gb.read1() != 0
      }
    }
    if self.channel_mode == ac3_chmode_stereo {
      self.phase_flags_in_use = gb.read1() != 0
    }
    let cpl_start_subband = gb.read(4).reinterpret_as_int()
    let cpl_end_subband = gb.read(4).reinterpret_as_int() + 3
    if cpl_start_subband >= cpl_end_subband {
      return Err("ac3: invalid coupling range")
    }
    self.start_freq[0] = cpl_start_subband * 12 + 37
    self.end_freq[0] = cpl_end_subband * 12 + 37
    let num_bands : Ref[Int32] = { val: 0, }
    ac3_decode_band_structure(
      gb,
      blk,
      self.eac3,
      cpl_start_subband,
      cpl_end_subband,
      self.cpl_band_struct,
      num_bands,
      self.cpl_band_sizes,
    )
    self.num_cpl_bands = num_bands.val
  } else {
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      self.channel_in_cpl[ch] = false
      self.first_cpl_coords[ch] = true
    }
    self.first_cpl_leak = self.eac3
    self.phase_flags_in_use = false
  }
  Ok(())
}

///|
/// `coupling_coordinates`. */
fn Ac3Decoder::coupling_coordinates(
  self : Ac3Decoder,
  gb : BitReader,
  blk : Int32,
) -> Result[Unit, String] {
  let mut cpl_coords_exist = false
  for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
    if self.channel_in_cpl[ch] {
      if (self.eac3 && self.first_cpl_coords[ch]) || gb.read1() != 0 {
        self.first_cpl_coords[ch] = false
        cpl_coords_exist = true
        let master_cpl_coord = 3 * gb.read(2).reinterpret_as_int()
        for bnd = 0; bnd < self.num_cpl_bands; bnd = bnd + 1 {
          let cpl_coord_exp = gb.read(4).reinterpret_as_int()
          let cpl_coord_mant = gb.read(4).reinterpret_as_int()
          let v = if cpl_coord_exp == 15 {
            cpl_coord_mant << 22
          } else {
            (cpl_coord_mant + 16) << 21
          }
          self.cpl_coords[ch][bnd] = v >> (cpl_coord_exp + master_cpl_coord)
        }
      } else if blk == 0 {
        return Err("ac3: new coupling coordinates must be in block 0")
      }
    } else {
      self.first_cpl_coords[ch] = true
    }
  }
  if self.channel_mode == ac3_chmode_stereo && cpl_coords_exist {
    for bnd = 0; bnd < self.num_cpl_bands; bnd = bnd + 1 {
      self.phase_flags[bnd] = self.phase_flags_in_use && gb.read1() != 0
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// mantissas / coefficients
// ---------------------------------------------------------------------------

///|
/// Carry-over state of the grouped mantissa unpacking (`mant_groups`).
priv struct Ac3MantGroups {
  b1_mant : FixedArray[Int32]
  b2_mant : FixedArray[Int32]
  mut b1 : Int32
  mut b2 : Int32
  mut b4 : Int32
  mut b4_mant : Int32
}

///|
fn ac3_mant_groups_new() -> Ac3MantGroups {
  {
    b1_mant: FixedArray::make(2, 0),
    b2_mant: FixedArray::make(2, 0),
    b1: 0,
    b2: 0,
    b4: 0,
    b4_mant: 0,
  }
}

///|
/// `ac3_decode_transform_coeffs_ch`: decode one channel's Q24 coefficients. */
fn Ac3Decoder::decode_transform_coeffs_ch(
  self : Ac3Decoder,
  gb : BitReader,
  ch_index : Int32,
  m : Ac3MantGroups,
) -> Result[Unit, String] {
  let start_freq = self.start_freq[ch_index]
  let end_freq = self.end_freq[ch_index]
  let baps = self.bap[ch_index]
  let exps = self.dexps[ch_index]
  let coeffs = self.fixed_coeffs[ch_index]
  let dither = ch_index == 0 || self.dither_flag[ch_index]
  for freq = start_freq; freq < end_freq; freq = freq + 1 {
    let bap = baps[freq]
    let mantissa : Int32 = if bap == 0 {
      if dither {
        (((self.dith_state.get() >> 8) * 181U) >> 8).reinterpret_as_int() -
        5931008
      } else {
        0
      }
    } else if bap == 1 {
      if m.b1 > 0 {
        m.b1 = m.b1 - 1
        m.b1_mant[m.b1]
      } else {
        let bits = gb.read(5).reinterpret_as_int()
        m.b1_mant[1] = ac3_bap1_mantissas[bits][1]
        m.b1_mant[0] = ac3_bap1_mantissas[bits][2]
        m.b1 = 2
        ac3_bap1_mantissas[bits][0]
      }
    } else if bap == 2 {
      if m.b2 > 0 {
        m.b2 = m.b2 - 1
        m.b2_mant[m.b2]
      } else {
        let bits = gb.read(7).reinterpret_as_int()
        m.b2_mant[1] = ac3_bap2_mantissas[bits][1]
        m.b2_mant[0] = ac3_bap2_mantissas[bits][2]
        m.b2 = 2
        ac3_bap2_mantissas[bits][0]
      }
    } else if bap == 3 {
      ac3_bap3_mantissas[gb.read(3).reinterpret_as_int()]
    } else if bap == 4 {
      if m.b4 != 0 {
        m.b4 = 0
        m.b4_mant
      } else {
        let bits = gb.read(7).reinterpret_as_int()
        m.b4_mant = ac3_bap4_mantissas[bits][1]
        m.b4 = 1
        ac3_bap4_mantissas[bits][0]
      }
    } else if bap == 5 {
      ac3_bap5_mantissas[gb.read(4).reinterpret_as_int()]
    } else {
      if bap > 15 {
        return Err("ac3: invalid bap in plain AC-3")
      }
      let bits = ac3_quantization_tab[bap]
      let v = ac3_get_sbits(gb, bits)
      (v.reinterpret_as_uint() << (24 - bits)).reinterpret_as_int()
    }
    coeffs[freq] = mantissa >> exps[freq]
  }
  Ok(())
}

///|
/// `calc_transform_coeffs_cpl`. */
fn Ac3Decoder::calc_transform_coeffs_cpl(self : Ac3Decoder) -> Unit {
  let mut bin = self.start_freq[0]
  for band = 0; band < self.num_cpl_bands; band = band + 1 {
    let band_start = bin
    let band_end = bin + self.cpl_band_sizes[band]
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if self.channel_in_cpl[ch] {
        let cpl_coord = self.cpl_coords[ch][band] << 5
        for b = band_start; b < band_end; b = b + 1 {
          self.fixed_coeffs[ch][b] = ac3_mulh(
            self.fixed_coeffs[0][b] * (1 << 4),
            cpl_coord,
          )
        }
        if ch == 2 && self.phase_flags[band] {
          for b = band_start; b < band_end; b = b + 1 {
            self.fixed_coeffs[2][b] = -self.fixed_coeffs[2][b]
          }
        }
      }
    }
    bin = band_end
  }
}

///|
/// `decode_transform_coeffs`: decode every channel, uncouple, zero the tail. */
fn Ac3Decoder::decode_transform_coeffs(
  self : Ac3Decoder,
  gb : BitReader,
  m : Ac3MantGroups,
) -> Result[Unit, String] {
  let mut got_cplchan = false
  for ch = 1; ch <= self.channels; ch = ch + 1 {
    match self.decode_transform_coeffs_ch(gb, ch, m) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let end = if self.channel_in_cpl[ch] {
      if !got_cplchan {
        match self.decode_transform_coeffs_ch(gb, 0, m) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        self.calc_transform_coeffs_cpl()
        got_cplchan = true
      }
      self.end_freq[0]
    } else {
      self.end_freq[ch]
    }
    for k = end; k < ac3_max_coefs; k = k + 1 {
      self.fixed_coeffs[ch][k] = 0
    }
  }
  // remove_dithering
  for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
    if !self.dither_flag[ch] && self.channel_in_cpl[ch] {
      for i = self.start_freq[0]; i < self.end_freq[0]; i = i + 1 {
        if self.bap[0][i] == 0 {
          self.fixed_coeffs[ch][i] = 0
        }
      }
    }
  }
  Ok(())
}

///|
/// `do_rematrixing`. */
fn Ac3Decoder::do_rematrixing(self : Ac3Decoder) -> Unit {
  let end = if self.end_freq[1] < self.end_freq[2] {
    self.end_freq[1]
  } else {
    self.end_freq[2]
  }
  for bnd = 0; bnd < self.num_rematrixing_bands; bnd = bnd + 1 {
    if self.rematrixing_flags[bnd] {
      let bndend = if end < ac3_rematrix_band_tab[bnd + 1] {
        end
      } else {
        ac3_rematrix_band_tab[bnd + 1]
      }
      for i = ac3_rematrix_band_tab[bnd]; i < bndend; i = i + 1 {
        let tmp0 = self.fixed_coeffs[1][i]
        self.fixed_coeffs[1][i] = tmp0 + self.fixed_coeffs[2][i]
        self.fixed_coeffs[2][i] = tmp0 - self.fixed_coeffs[2][i]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// IMDCT / windowing
// ---------------------------------------------------------------------------

///|
/// `do_imdct`: one block of 256 output samples per channel, writing into
/// `out[slot][blk * 256 ..]` and updating the persistent overlap delay.
fn Ac3Decoder::do_imdct(
  self : Ac3Decoder,
  channels : Int32,
  out : Array[Array[Double]],
  channel_map : FixedArray[Int32],
  blk : Int32,
) -> Unit {
  let off = blk * ac3_block_size
  for ch = 1; ch <= channels; ch = ch + 1 {
    let delay = self.delay[ch - 1]
    let dst = out[channel_map[ch - 1]]
    if self.block_switch[ch] {
      let x : Array[Double] = Array::make(128, 0.0)
      for i = 0; i < 128; i = i + 1 {
        x[i] = self.transform_coeffs[ch][2 * i]
      }
      let tmp = ac3_imdct(x, 128)
      ac3_fmul_window(dst, off, delay, tmp, ac3_window, 128)
      for i = 0; i < 128; i = i + 1 {
        x[i] = self.transform_coeffs[ch][2 * i + 1]
      }
      let odd = ac3_imdct(x, 128)
      for i = 0; i < 128; i = i + 1 {
        delay[i] = odd[i]
      }
    } else {
      let tmp = ac3_imdct(self.transform_coeffs[ch], 256)
      ac3_fmul_window(dst, off, delay, tmp, ac3_window, 128)
      for i = 0; i < 128; i = i + 1 {
        delay[i] = tmp[128 + i]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// block / frame decode
// ---------------------------------------------------------------------------

///|
/// `decode_audio_block`. */
fn Ac3Decoder::decode_audio_block(
  self : Ac3Decoder,
  gb : BitReader,
  blk : Int32,
  out : Array[Array[Double]],
  channel_map : FixedArray[Int32],
) -> Result[Unit, String] {
  let fbw_channels = self.fbw_channels
  let channel_mode = self.channel_mode
  let bit_alloc_stages = FixedArray::make(ac3_max_channels, 0)
  // Block switch and dither flags (E-AC-3 signals their presence in the
  // frame header instead of in every block).
  if self.block_switch_syntax {
    for ch = 1; ch <= fbw_channels; ch = ch + 1 {
      self.block_switch[ch] = gb.read1() != 0
    }
  }
  if self.dither_flag_syntax {
    for ch = 1; ch <= fbw_channels; ch = ch + 1 {
      self.dither_flag[ch] = gb.read1() != 0
    }
  }
  // Dynamic range (`drc_scale` is fixed at 1.0, so AC3_DYNAMIC_RANGE is the
  // table value).
  let mut i = if channel_mode == 0 { 1 } else { 0 }
  while true {
    if gb.read1() != 0 {
      let range_bits = gb.read(8).reinterpret_as_int()
      self.dynamic_range[i] = ac3_dynamic_range_tab[range_bits]
    } else if blk == 0 {
      self.dynamic_range[i] = 1.0
    }
    if i == 0 {
      break
    }
    i = i - 1
  }
  // Spectral extension strategy (E-AC-3).  SPX is not implemented, so a
  // stream that enables it is rejected instead of decoded incorrectly.
  if self.eac3 {
    let parse_spx = if blk == 0 { true } else { gb.read1() != 0 }
    if parse_spx && gb.read1() != 0 {
      return Err("eac3: spectral extension is not supported")
    }
  }
  // Coupling strategy.
  let cpl_strategy = if self.eac3 {
    self.cpl_strategy_exists[blk]
  } else {
    gb.read1() != 0
  }
  if cpl_strategy {
    match self.coupling_strategy(gb, blk, bit_alloc_stages) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else if blk == 0 && !self.eac3 {
    return Err("ac3: new coupling strategy must be present in block 0")
  } else if blk > 0 {
    self.cpl_in_use[blk] = self.cpl_in_use[blk - 1]
  }
  let cpl_in_use = self.cpl_in_use[blk]
  if cpl_in_use {
    match self.coupling_coordinates(gb, blk) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  // Stereo rematrixing strategy and band structure.
  if channel_mode == ac3_chmode_stereo {
    let new_rematrix = if self.eac3 && blk == 0 {
      true
    } else {
      gb.read1() != 0
    }
    if new_rematrix {
      self.num_rematrixing_bands = 4
      if cpl_in_use && self.start_freq[0] <= 61 {
        self.num_rematrixing_bands = self.num_rematrixing_bands -
          (1 + (if self.start_freq[0] == 37 { 1 } else { 0 }))
      }
      for bnd = 0; bnd < self.num_rematrixing_bands; bnd = bnd + 1 {
        self.rematrixing_flags[bnd] = gb.read1() != 0
      }
    } else if blk == 0 {
      self.num_rematrixing_bands = 0
    }
  }
  // Exponent strategies.
  for ch = (if cpl_in_use { 0 } else { 1 }); ch <= self.channels; ch = ch + 1 {
    if !self.eac3 {
      let bits = if ch == self.lfe_ch { 1 } else { 2 }
      self.exp_strategy[blk][ch] = gb.read(bits).reinterpret_as_int()
    }
    if self.exp_strategy[blk][ch] != ac3_exp_reuse {
      bit_alloc_stages[ch] = 3
    }
  }
  // Channel bandwidth.
  for ch = 1; ch <= fbw_channels; ch = ch + 1 {
    self.start_freq[ch] = 0
    if self.exp_strategy[blk][ch] != ac3_exp_reuse {
      let prev = self.end_freq[ch]
      if self.channel_in_cpl[ch] {
        self.end_freq[ch] = self.start_freq[0]
      } else {
        let bandwidth_code = gb.read(6).reinterpret_as_int()
        if bandwidth_code > 60 {
          return Err("ac3: bandwidth code out of range")
        }
        self.end_freq[ch] = bandwidth_code * 3 + 73
      }
      let group_size = 3 << (self.exp_strategy[blk][ch] - 1)
      self.num_exp_groups[ch] = (self.end_freq[ch] + group_size - 4) /
        group_size
      if blk > 0 && self.end_freq[ch] != prev {
        for k = 0; k < ac3_max_channels; k = k + 1 {
          bit_alloc_stages[k] = 3
        }
      }
    }
  }
  if cpl_in_use && self.exp_strategy[blk][0] != ac3_exp_reuse {
    self.num_exp_groups[0] = (self.end_freq[0] - self.start_freq[0]) /
      (3 << (self.exp_strategy[blk][0] - 1))
  }
  // Decode exponents.
  for ch = (if cpl_in_use { 0 } else { 1 }); ch <= self.channels; ch = ch + 1 {
    if self.exp_strategy[blk][ch] != ac3_exp_reuse {
      self.dexps[ch][0] = gb.read(4).reinterpret_as_int() <<
        (if ch == 0 { 1 } else { 0 })
      let dst = self.start_freq[ch] + (if ch != 0 { 1 } else { 0 })
      match
        ac3_decode_exponents(
          gb,
          self.exp_strategy[blk][ch],
          self.num_exp_groups[ch],
          self.dexps[ch][0],
          self.dexps[ch],
          dst,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      if ch != 0 && ch != self.lfe_ch {
        let _ = gb.read(2) // gainrng
      }
    }
  }
  // Bit allocation information.
  if self.bit_allocation_syntax {
    if gb.read1() != 0 {
      self.slow_decay = ac3_slow_decay_tab[gb.read(2).reinterpret_as_int()] >>
        self.sr_shift
      self.fast_decay = ac3_fast_decay_tab[gb.read(2).reinterpret_as_int()] >>
        self.sr_shift
      self.slow_gain = ac3_slow_gain_tab[gb.read(2).reinterpret_as_int()]
      self.db_per_bit = ac3_db_per_bit_tab[gb.read(2).reinterpret_as_int()]
      self.floor = ac3_floor_tab[gb.read(3).reinterpret_as_int()]
      for ch = (if cpl_in_use { 0 } else { 1 })
          ch <= self.channels
          ch = ch + 1 {
        if bit_alloc_stages[ch] < 2 {
          bit_alloc_stages[ch] = 2
        }
      }
    } else if blk == 0 {
      return Err("ac3: new bit allocation info must be present in block 0")
    }
  }
  // Signal-to-noise ratio offsets and fast gains.  E-AC-3 carries these only
  // in block 0 (and its fast gains in a separate syntax element).
  if !self.eac3 || blk == 0 {
    if self.snr_offset_strategy != 0 && gb.read1() != 0 {
      let csnr = (gb.read(6).reinterpret_as_int() - 15) << 4
      let mut snr = 0
      let first = if cpl_in_use { 0 } else { 1 }
      for ch = first; ch <= self.channels; ch = ch + 1 {
        if ch == first || self.snr_offset_strategy == 2 {
          snr = (csnr + gb.read(4).reinterpret_as_int()) << 2
        }
        if blk > 0 && self.snr_offset[ch] != snr {
          if bit_alloc_stages[ch] < 1 {
            bit_alloc_stages[ch] = 1
          }
        }
        self.snr_offset[ch] = snr
        if !self.eac3 {
          let prev = self.fast_gain[ch]
          self.fast_gain[ch] = ac3_fast_gain_tab[gb.read(3).reinterpret_as_int()]
          if blk > 0 && prev != self.fast_gain[ch] {
            if bit_alloc_stages[ch] < 2 {
              bit_alloc_stages[ch] = 2
            }
          }
        }
      }
    } else if !self.eac3 && blk == 0 {
      return Err("ac3: new snr offsets must be present in block 0")
    }
  }
  // E-AC-3 fast gain codes.
  if self.fast_gain_syntax {
    if gb.read1() != 0 {
      for ch = (if cpl_in_use { 0 } else { 1 })
          ch <= self.channels
          ch = ch + 1 {
        let prev = self.fast_gain[ch]
        self.fast_gain[ch] = ac3_fast_gain_tab[gb.read(3).reinterpret_as_int()]
        if blk > 0 && prev != self.fast_gain[ch] {
          if bit_alloc_stages[ch] < 2 {
            bit_alloc_stages[ch] = 2
          }
        }
      }
    }
  } else if self.eac3 && blk == 0 {
    for ch = (if cpl_in_use { 0 } else { 1 }); ch <= self.channels; ch = ch + 1 {
      self.fast_gain[ch] = ac3_fast_gain_tab[4]
    }
  }
  // E-AC-3 to AC-3 converter SNR offset.
  if self.frame_type == 0 && gb.read1() != 0 {
    gb.skip(10)
  }
  // Coupling leak information.
  if cpl_in_use {
    if self.first_cpl_leak || gb.read1() != 0 {
      let fl = gb.read(3).reinterpret_as_int()
      let sl = gb.read(3).reinterpret_as_int()
      if blk > 0 && (fl != self.cpl_fast_leak || sl != self.cpl_slow_leak) {
        if bit_alloc_stages[0] < 2 {
          bit_alloc_stages[0] = 2
        }
      }
      self.cpl_fast_leak = fl
      self.cpl_slow_leak = sl
    } else if blk == 0 {
      return Err("ac3: new coupling leak info must be present in block 0")
    }
    self.first_cpl_leak = false
  }
  // Delta bit allocation information.
  if self.dba_syntax && gb.read1() != 0 {
    for ch = (if cpl_in_use { 0 } else { 1 }); ch <= fbw_channels; ch = ch + 1 {
      self.dba_mode[ch] = gb.read(2).reinterpret_as_int()
      if self.dba_mode[ch] == ac3_dba_reserved {
        return Err("ac3: delta bit allocation strategy reserved")
      }
      if bit_alloc_stages[ch] < 2 {
        bit_alloc_stages[ch] = 2
      }
    }
    for ch = (if cpl_in_use { 0 } else { 1 }); ch <= fbw_channels; ch = ch + 1 {
      if self.dba_mode[ch] == ac3_dba_new {
        self.dba_nsegs[ch] = gb.read(3).reinterpret_as_int() + 1
        for seg = 0; seg < self.dba_nsegs[ch]; seg = seg + 1 {
          self.dba_offsets[ch][seg] = gb.read(5).reinterpret_as_int()
          self.dba_lengths[ch][seg] = gb.read(4).reinterpret_as_int()
          self.dba_values[ch][seg] = gb.read(3).reinterpret_as_int()
        }
        if bit_alloc_stages[ch] < 2 {
          bit_alloc_stages[ch] = 2
        }
      }
    }
  } else if blk == 0 {
    for ch = 0; ch <= self.channels; ch = ch + 1 {
      self.dba_mode[ch] = ac3_dba_none
    }
  }
  // Bit allocation.
  for ch = (if cpl_in_use { 0 } else { 1 }); ch <= self.channels; ch = ch + 1 {
    if bit_alloc_stages[ch] > 2 {
      ac3_bit_alloc_calc_psd(
        self.dexps[ch],
        self.start_freq[ch],
        self.end_freq[ch],
        self.psd[ch],
        self.band_psd[ch],
      )
    }
    if bit_alloc_stages[ch] > 1 {
      match
        ac3_bit_alloc_calc_mask(
          self,
          self.band_psd[ch],
          self.start_freq[ch],
          self.end_freq[ch],
          self.fast_gain[ch],
          ch == self.lfe_ch,
          self.dba_mode[ch],
          self.dba_nsegs[ch],
          self.dba_offsets[ch],
          self.dba_lengths[ch],
          self.dba_values[ch],
          self.mask[ch],
        ) {
        true => ()
        false => return Err("ac3: error in bit allocation")
      }
    }
    if bit_alloc_stages[ch] > 0 {
      ac3_bit_alloc_calc_bap(
        self.mask[ch],
        self.psd[ch],
        self.start_freq[ch],
        self.end_freq[ch],
        self.snr_offset[ch],
        self.floor,
        self.bap[ch],
      )
    }
  }
  // Unused dummy data.
  if self.skip_syntax && gb.read1() != 0 {
    let skipl = gb.read(9).reinterpret_as_int()
    gb.skip(8 * skipl)
  }
  // Unpack transform coefficients (uncouples as well).
  let m = ac3_mant_groups_new()
  match self.decode_transform_coeffs(gb, m) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if channel_mode == ac3_chmode_stereo {
    self.do_rematrixing()
  }
  // Scale coefficients (headroom, dynrng) and run the IMDCT.
  for ch = 1; ch <= self.channels; ch = ch + 1 {
    let audio_channel = if channel_mode == ac3_chmode_dualmono && ch <= 2 {
      2 - ch
    } else {
      0
    }
    let gain = self.dynamic_range[audio_channel] * ac3_coef_scale
    for i = 0; i < ac3_max_coefs; i = i + 1 {
      self.transform_coeffs[ch][i] = self.fixed_coeffs[ch][i].to_double() * gain
    }
  }
  self.do_imdct(self.channels, out, channel_map, blk)
  Ok(())
}

///|
/// `parse_frame_header` from ac3dec.c for plain AC-3. */
fn Ac3Decoder::parse_frame_header(
  self : Ac3Decoder,
  gb : BitReader,
  hdr : Ac3Header,
) -> Result[Unit, String] {
  self.sr_code = hdr.sr_code
  self.bitstream_id = hdr.bitstream_id
  self.bitstream_mode = hdr.bitstream_mode
  self.channel_mode = hdr.channel_mode
  self.lfe_on = hdr.lfe_on
  self.sr_shift = hdr.sr_shift
  self.sample_rate = hdr.sample_rate
  self.bit_rate = hdr.bit_rate
  self.channels = hdr.channels
  self.fbw_channels = self.channels - (if self.lfe_on { 1 } else { 0 })
  self.lfe_ch = self.fbw_channels + 1
  self.frame_size = hdr.frame_size
  self.num_blocks = hdr.num_blocks
  self.frame_type = hdr.frame_type
  self.substreamid = hdr.substreamid
  self.eac3 = hdr.bitstream_id > 10
  if self.lfe_on {
    self.start_freq[self.lfe_ch] = 0
    self.end_freq[self.lfe_ch] = 7
    self.num_exp_groups[self.lfe_ch] = 2
    self.channel_in_cpl[self.lfe_ch] = false
  }
  self.dynamic_range[0] = 1.0
  self.dynamic_range[1] = 1.0
  if !self.eac3 {
    self.snr_offset_strategy = 2
    self.block_switch_syntax = true
    self.dither_flag_syntax = true
    self.bit_allocation_syntax = true
    self.fast_gain_syntax = false
    self.dba_syntax = true
    self.skip_syntax = true
    for ch = 0; ch < ac3_max_channels; ch = ch + 1 {
      self.channel_uses_aht[ch] = false
    }
    self.first_cpl_leak = false
    return Ok(())
  }
  self.parse_eac3_frame_header(gb, hdr)
}

///|
/// `ff_eac3_parse_header`: the audio frame syntax flags, exponent strategy
/// data and per-frame values that follow the E-AC-3 bit stream information.
fn Ac3Decoder::parse_eac3_frame_header(
  self : Ac3Decoder,
  gb : BitReader,
  hdr : Ac3Header,
) -> Result[Unit, String] {
  if self.frame_type == 3 {
    return Err("eac3: reserved frame type")
  }
  if self.substreamid != 0 {
    return Err("eac3: additional substreams are not supported")
  }
  if hdr.sr_code == 3 {
    return Err("eac3: reduced sampling rate is not supported")
  }
  if hdr.channel_map_present {
    return Err("eac3: dependent channel maps are not supported")
  }
  let ac3_exponent_strategy = if self.num_blocks == 6 {
    gb.read1() != 0
  } else {
    true
  }
  let parse_aht_info = if self.num_blocks == 6 {
    gb.read1() != 0
  } else {
    false
  }
  self.snr_offset_strategy = gb.read(2).reinterpret_as_int()
  let parse_transient = gb.read1() != 0
  self.block_switch_syntax = gb.read1() != 0
  if !self.block_switch_syntax {
    for ch = 0; ch < ac3_max_channels; ch = ch + 1 {
      self.block_switch[ch] = false
    }
  }
  self.dither_flag_syntax = gb.read1() != 0
  if !self.dither_flag_syntax {
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      self.dither_flag[ch] = true
    }
  }
  self.dither_flag[0] = false
  self.dither_flag[self.lfe_ch] = false
  self.bit_allocation_syntax = gb.read1() != 0
  if !self.bit_allocation_syntax {
    self.slow_decay = ac3_slow_decay_tab[2]
    self.fast_decay = ac3_fast_decay_tab[1]
    self.slow_gain = ac3_slow_gain_tab[1]
    self.db_per_bit = ac3_db_per_bit_tab[2]
    self.floor = ac3_floor_tab[7]
  }
  self.fast_gain_syntax = gb.read1() != 0
  self.dba_syntax = gb.read1() != 0
  self.skip_syntax = gb.read1() != 0
  let parse_spx_atten = gb.read1() != 0
  // Coupling strategy occurrence and coupling use per block.
  let mut num_cpl_blocks = 0
  if self.channel_mode > 1 {
    for blk = 0; blk < self.num_blocks; blk = blk + 1 {
      self.cpl_strategy_exists[blk] = if blk == 0 {
        true
      } else {
        gb.read1() != 0
      }
      if self.cpl_strategy_exists[blk] {
        self.cpl_in_use[blk] = gb.read1() != 0
      } else {
        self.cpl_in_use[blk] = self.cpl_in_use[blk - 1]
      }
      if self.cpl_in_use[blk] {
        num_cpl_blocks = num_cpl_blocks + 1
      }
    }
  } else {
    for blk = 0; blk < ac3_max_blocks; blk = blk + 1 {
      self.cpl_in_use[blk] = false
    }
  }
  // Exponent strategy data.
  if ac3_exponent_strategy {
    for blk = 0; blk < self.num_blocks; blk = blk + 1 {
      for ch = (if self.cpl_in_use[blk] { 0 } else { 1 })
          ch <= self.fbw_channels
          ch = ch + 1 {
        self.exp_strategy[blk][ch] = gb.read(2).reinterpret_as_int()
      }
    }
  } else {
    let start_ch = if self.channel_mode > 1 && num_cpl_blocks > 0 {
      0
    } else {
      1
    }
    for ch = start_ch; ch <= self.fbw_channels; ch = ch + 1 {
      let frmchexpstr = gb.read(5).reinterpret_as_int()
      for blk = 0; blk < 6; blk = blk + 1 {
        self.exp_strategy[blk][ch] = eac3_frm_expstr[frmchexpstr][blk]
      }
    }
  }
  if self.lfe_on {
    for blk = 0; blk < self.num_blocks; blk = blk + 1 {
      self.exp_strategy[blk][self.lfe_ch] = gb.read1().reinterpret_as_int()
    }
  }
  if self.frame_type == 0 && (self.num_blocks == 6 || gb.read1() != 0) {
    gb.skip(5 * self.fbw_channels) // converter channel exponent strategy
  }
  // Determine which channels use AHT; the port does not decode AHT.
  let mut any_aht = false
  if parse_aht_info {
    self.channel_uses_aht[0] = false
    let start_ch = if num_cpl_blocks != self.num_blocks { 0 } else { 1 }
    for ch = start_ch; ch <= self.channels; ch = ch + 1 {
      let mut use_aht = true
      for blk = 1; blk < 6; blk = blk + 1 {
        if self.exp_strategy[blk][ch] != ac3_exp_reuse ||
          (ch == 0 && self.cpl_strategy_exists[blk]) {
          use_aht = false
        }
      }
      self.channel_uses_aht[ch] = use_aht && gb.read1() != 0
      if self.channel_uses_aht[ch] {
        any_aht = true
      }
    }
  } else {
    for ch = 0; ch < ac3_max_channels; ch = ch + 1 {
      self.channel_uses_aht[ch] = false
    }
  }
  if any_aht {
    return Err("eac3: adaptive hybrid transform is not supported")
  }
  // Per-frame SNR offset.
  if self.snr_offset_strategy == 0 {
    let csnroffst = (gb.read(6).reinterpret_as_int() - 15) << 4
    let snroffst = (csnroffst + gb.read(4).reinterpret_as_int()) << 2
    for ch = 0; ch <= self.channels; ch = ch + 1 {
      self.snr_offset[ch] = snroffst
    }
  }
  if parse_transient {
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if gb.read1() != 0 {
        gb.skip(10) // transient processing location
        gb.skip(8) // transient processing length
      }
    }
  }
  for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
    if parse_spx_atten && gb.read1() != 0 {
      let _ = gb.read(5) // spx attenuation code
    }
  }
  if self.num_blocks > 1 && gb.read1() != 0 {
    let block_start_bits = (self.num_blocks - 1) *
      (4 + ac3_av_log2(self.frame_size - 2))
    gb.skip(block_start_bits)
  }
  for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
    self.first_cpl_coords[ch] = true
  }
  self.first_cpl_leak = true
  Ok(())
}

///|
/// Decode one AC-3 frame.  `data` may contain leading garbage up to 10 bytes
/// (the C sync search) and trailing padding.
pub fn Ac3Decoder::decode_frame(
  self : Ac3Decoder,
  data : Bytes,
) -> Result[Ac3Frame, String] {
  let mut off = 0
  if data.length() >= 2 && data[0] == b'\x0B' && data[1] == b'\x77' {
    off = 0
  } else {
    off = ac3_find_syncword(data)
    if off < 0 || off > 10 {
      return Err("ac3: frame sync error")
    }
  }
  let buf = data[off:].to_owned()
  let gb = BitReader::new(buf)
  let hdr = match ac3_parse_header_bits(gb) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  if hdr.frame_size > buf.length() {
    return Err("ac3: incomplete frame")
  }
  match self.parse_frame_header(gb, hdr) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if self.frame_type == 1 {
    return Err("ac3: dependent frames are not supported")
  }
  if self.channels > 6 {
    return Err("ac3: too many channels")
  }
  let out : Array[Array[Double]] = []
  for ch = 0; ch < self.channels; ch = ch + 1 {
    out.push(Array::make(self.num_blocks * ac3_block_size, 0.0))
  }
  let map_base = (self.channel_mode * 2 + (if self.lfe_on { 1 } else { 0 })) * 6
  // The C directs each decoded channel through `outptr[channel_map[ch]]` into
  // `output_buffer`; the frame layout is then the buffer order, so invert the
  // map to get the output slot of each decoded channel.
  let channel_map = FixedArray::make(6, 0)
  for b = 0; b < self.channels; b = b + 1 {
    channel_map[ac3_dec_channel_map[map_base + b]] = b
  }
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    match self.decode_audio_block(gb, blk, out, channel_map) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok({
    sample_rate: self.sample_rate,
    bit_rate: self.bit_rate,
    channels: self.channels,
    channel_mode: self.channel_mode,
    lfe_on: self.lfe_on,
    num_blocks: self.num_blocks,
    samples: out,
  })
}
