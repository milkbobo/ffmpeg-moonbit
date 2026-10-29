///|
/// WMA v1/v2 decoder, ported from FFmpeg 9.0.2 `wmadec.c`, `wma.c` (shared
/// init and run-level coefficient decoding) and `wma_common.c`.
///
/// The C uses float DSP (a full IMDCT via `AV_TX_FULL_IMDCT`, per-bin float
/// multiplies); this port keeps doubles and evaluates the same half-inverse
/// MDCT with per-row cosine recurrences (no FFT), then applies the same
/// window/overlap.  Bit-reservoir and variable-block-length syntax are
/// implemented but only the non-reservoir fixed-block path is covered by
/// fixtures, because FFmpeg's own WMA encoder always writes `flags2 = 1`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

///|
let wma_block_min_bits : Int32 = 7

///|
let wma_block_max_size : Int32 = 2048

///|
let wma_block_nb_sizes : Int32 = 5

///|
let wma_noise_tab_size : Int32 = 8192

///|
let wma_lsp_pow_bits : Int32 = 7

///|
let wma_max_superframe : Int32 = 32768

///|
let wma_high_band_max_size : Int32 = 16

///|
let wma_nb_lsp_coefs : Int32 = 10

// ---------------------------------------------------------------------------
// VLC (explicit code/length tables, MSB-first)
// ---------------------------------------------------------------------------

///|
pub struct WmaVlc {
  max_len : Int32
  by_len : Array[Array[(Int32, Int32)]]
}

///|
fn wma_vlc_build(codes : Array[UInt32], bits : Array[Int32]) -> WmaVlc {
  let mut max_len = 1
  for b in bits {
    if b > max_len {
      max_len = b
    }
  }
  let by_len : Array[Array[(Int32, Int32)]] = []
  for i = 0; i <= max_len; i = i + 1 {
    by_len.push([])
  }
  for i = 0; i < codes.length(); i = i + 1 {
    by_len[bits[i]].push((codes[i].reinterpret_as_int(), i))
  }
  { max_len, by_len, }
}

///|
fn wma_vlc_build_fixed(
  codes : FixedArray[UInt32],
  bits : FixedArray[Int32],
) -> WmaVlc {
  let c : Array[UInt32] = []
  let b : Array[Int32] = []
  for i = 0; i < codes.length(); i = i + 1 {
    c.push(codes[i])
    b.push(bits[i])
  }
  wma_vlc_build(c, b)
}

///|
/// `get_vlc2` for these tables: read bits MSB-first until a code matches.
fn wma_vlc_get(gb : BitReader, vlc : WmaVlc) -> Result[Int32, String] {
  let mut code = 0
  for len = 1; len <= vlc.max_len; len = len + 1 {
    code = (code << 1) | gb.read1().reinterpret_as_int()
    for entry in vlc.by_len[len] {
      if entry.0 == code {
        return Ok(entry.1)
      }
    }
  }
  Err("wma: invalid VLC code")
}

// ---------------------------------------------------------------------------
// coefficient VLC tables (run/level)
// ---------------------------------------------------------------------------

///|
pub struct WmaCoefVlc {
  vlc : WmaVlc
  run : Array[Int32]
  level : Array[Double]
}

///|
fn wma_coef_vlc(
  codes : FixedArray[UInt32],
  bits : FixedArray[Int32],
  levels : FixedArray[Int32],
) -> WmaCoefVlc {
  let n = codes.length()
  let run : Array[Int32] = Array::make(n, 0)
  let level : Array[Double] = Array::make(n, 0.0)
  let mut i = 2
  let mut lvl = 1
  let mut k = 0
  while i < n && k < levels.length() {
    let count = levels[k]
    for j = 0; j < count && i < n; j = j + 1 {
      run[i] = j
      level[i] = lvl.to_double()
      i = i + 1
    }
    lvl = lvl + 1
    k = k + 1
  }
  { vlc: wma_vlc_build_fixed(codes, bits), run, level, }
}

// ---------------------------------------------------------------------------
// MDCT (AV_TX_FULL_IMDCT equivalent)
// ---------------------------------------------------------------------------

///|
/// `sum_j coef[j] * cos((2j+1) * a)` via a rotation recurrence.
fn wma_cos_sum(coef : Array[Double], a : Double) -> Double {
  let c2 = @math.cos(2.0 * a)
  let s2 = @math.sin(2.0 * a)
  let mut c = @math.cos(a)
  let mut s = @math.sin(a)
  let mut sum = 0.0
  for j = 0; j < coef.length(); j = j + 1 {
    sum = sum + coef[j] * c
    let nc = c * c2 - s * s2
    s = s * c2 + c * s2
    c = nc
  }
  sum
}

///|
/// `AV_TX_FULL_IMDCT` of `len` coefficients to `2*len` samples, scale 1.
/// Mirrors `ff_tx_mdct_inv_full` over `ff_tx_mdct_naive_inv`.
fn wma_imdct_full(
  coef : Array[Double],
  len : Int32,
  scale : Double,
) -> Array[Double] {
  let half = len / 2
  let inner : Array[Double] = Array::make(len, 0.0)
  let phase = 3.14159265358979323846 / (4.0 * len.to_double())
  for i = 0; i < half; i = i + 1 {
    let a_d = phase * (2 * len - 2 * i - 1).to_double()
    let a_u = phase * (3 * len + 2 * i + 1).to_double()
    inner[i] = wma_cos_sum(coef, a_d)
    inner[i + half] = -wma_cos_sum(coef, a_u)
  }
  let n = 2 * len
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < half; i = i + 1 {
    out[i] = -inner[half - 1 - i] * scale
  }
  for i = 0; i < len; i = i + 1 {
    out[half + i] = inner[i] * scale
  }
  for i = 0; i < half; i = i + 1 {
    out[n - 1 - i] = out[len + i]
  }
  out
}

// ---------------------------------------------------------------------------
// decoder state
// ---------------------------------------------------------------------------

///|
pub struct WmaDecoder {
  version : Int32
  sample_rate : Int32
  channels : Int32
  bit_rate : Int32
  block_align : Int32
  use_bit_reservoir : Bool
  use_variable_block_len : Bool
  use_exp_vlc : Bool
  use_noise_coding : Bool
  byte_offset_bits : Int32
  frame_len : Int32
  frame_len_bits : Int32
  nb_block_sizes : Int32
  exponent_sizes : FixedArray[Int32]
  exponent_bands : Array[FixedArray[Int32]]
  high_band_start : FixedArray[Int32]
  coefs_start : Int32
  coefs_end : FixedArray[Int32]
  exponent_high_sizes : FixedArray[Int32]
  exponent_high_bands : Array[FixedArray[Int32]]
  exp_vlc : WmaVlc
  hgain_vlc : WmaVlc
  high_band_coded : Array[FixedArray[Int32]]
  high_band_values : Array[FixedArray[Int32]]
  coef_vlc : Array[WmaCoefVlc]
  mut reset_block_lengths : Bool
  mut block_len_bits : Int32
  mut next_block_len_bits : Int32
  mut prev_block_len_bits : Int32
  mut block_len : Int32
  mut block_num : Int32
  mut block_pos : Int32
  mut ms_stereo : Bool
  channel_coded : FixedArray[Bool]
  exponents_bsize : FixedArray[Int32]
  exponents : Array[Array[Double]]
  max_exponent : FixedArray[Double]
  coefs1 : Array[Array[Double]]
  coefs : Array[Array[Double]]
  output : Array[Double]
  windows : Array[Array[Double]]
  frame_out : Array[Array[Double]]
  last_superframe : Array[Byte]
  mut last_bitoffset : Int32
  mut last_superframe_len : Int32
  exponents_initialized : FixedArray[Bool]
  noise_table : Array[Double]
  mut noise_index : Int32
  noise_mult : Double
  lsp_cos_table : Array[Double]
  lsp_pow_e_table : Array[Double]
  lsp_pow_m_table1 : Array[Double]
  lsp_pow_m_table2 : Array[Double]
  mut eof_done : Bool
}

///|
fn wma_log2(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `ff_wma_get_frame_len_bits` for versions 1/2.
fn wma_get_frame_len_bits(sample_rate : Int32, version : Int32) -> Int32 {
  if sample_rate <= 16000 {
    9
  } else if sample_rate <= 22050 || (sample_rate <= 32000 && version == 1) {
    10
  } else {
    11
  }
}

///|
/// `ff_wma_total_gain_to_bits`.
fn wma_total_gain_to_bits(total_gain : Int32) -> Int32 {
  if total_gain < 15 {
    13
  } else if total_gain < 32 {
    12
  } else if total_gain < 40 {
    11
  } else if total_gain < 45 {
    10
  } else {
    9
  }
}

///|
fn wma_exponent_band_table(
  sample_rate : Int32,
  frame_len_bits : Int32,
  k : Int32,
) -> FixedArray[Int32]? {
  let a = frame_len_bits - wma_block_min_bits - k
  if a >= 3 {
    return None
  }
  if sample_rate >= 44100 {
    Some(wma_exponent_band_44100[a])
  } else if sample_rate >= 32000 {
    Some(wma_exponent_band_32000[a])
  } else if sample_rate >= 22050 {
    Some(wma_exponent_band_22050[a])
  } else {
    None
  }
}

///|
/// `wma_lsp_to_curve_init` and the `pow_m1_4` tables.
fn wma_init_lsp_tables(
  frame_len : Int32,
) -> (Array[Double], Array[Double], Array[Double], Array[Double]) {
  let cos_table : Array[Double] = Array::make(frame_len, 0.0)
  let wdel = 3.14159265358979323846 / frame_len.to_double()
  for i = 0; i < frame_len; i = i + 1 {
    cos_table[i] = 2.0 * @math.cos(wdel * i.to_double())
  }
  let e_table : Array[Double] = Array::make(256, 0.0)
  for i = 0; i < 256; i = i + 1 {
    let e = i - 126
    e_table[i] = Float::from_double(@math.pow(2.0, e.to_double() * -0.25)).to_double()
  }
  let m1 : Array[Double] = Array::make(1 << wma_lsp_pow_bits, 0.0)
  let m2 : Array[Double] = Array::make(1 << wma_lsp_pow_bits, 0.0)
  let mut b = 1.0
  let mut i = (1 << wma_lsp_pow_bits) - 1
  while i >= 0 {
    let m = (1 << wma_lsp_pow_bits) + i
    let a = 1.0 /
      (m.to_double() * (0.5 / (1 << wma_lsp_pow_bits).to_double()))
      .sqrt()
      .sqrt()
    let af = Float::from_double(a).to_double()
    m1[i] = Float::from_double(2.0 * af - b).to_double()
    m2[i] = Float::from_double(b - af).to_double()
    b = af
    i = i - 1
  }
  (cos_table, e_table, m1, m2)
}

///|
fn wma_new_vlc_empty() -> WmaVlc {
  { max_len: 1, by_len: [[], []], }
}

///|
/// Fresh WMA v1/v2 decoder state, equivalent to `wma_decode_init` +
/// `ff_wma_init`.  `flags2` comes from the WAVEFORMATEX codec private data
/// (bit 0 exp VLC, bit 1 bit reservoir, bit 2 variable block length).
pub fn wma_decoder_new(
  version : Int32,
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
  block_align : Int32,
  flags2 : Int32,
) -> Result[WmaDecoder, String] {
  if version != 1 && version != 2 {
    return Err("EINVAL: only WMA v1/v2 are supported")
  }
  if sample_rate > 50000 ||
    channels < 1 ||
    channels > 2 ||
    bit_rate <= 0 ||
    block_align <= 0 {
    return Err("EINVAL: invalid WMA stream parameters")
  }
  let use_exp_vlc = (flags2 & 0x0001) != 0
  let use_bit_reservoir = (flags2 & 0x0002) != 0
  let use_variable_block_len = (flags2 & 0x0004) != 0
  let frame_len_bits = wma_get_frame_len_bits(sample_rate, version)
  let frame_len = 1 << frame_len_bits
  let mut nb_block_sizes = 1
  if use_variable_block_len {
    let mut nb = ((flags2 >> 3) & 3) + 1
    if bit_rate / channels >= 32000 {
      nb = nb + 2
    }
    let nb_max = frame_len_bits - wma_block_min_bits
    if nb > nb_max {
      nb = nb_max
    }
    nb_block_sizes = nb + 1
  }
  let mut use_noise_coding = true
  let mut high_freq = sample_rate.to_double() * 0.5
  let mut sample_rate1 = sample_rate
  if version == 2 {
    if sample_rate1 >= 44100 {
      sample_rate1 = 44100
    } else if sample_rate1 >= 22050 {
      sample_rate1 = 22050
    } else if sample_rate1 >= 16000 {
      sample_rate1 = 16000
    } else if sample_rate1 >= 11025 {
      sample_rate1 = 11025
    } else if sample_rate1 >= 8000 {
      sample_rate1 = 8000
    }
  }
  let bps = bit_rate.to_double() / (channels * sample_rate).to_double()
  let byte_offset_bits = wma_log2(
      (bps * frame_len.to_double() / 8.0 + 0.5).to_int(),
    ) +
    2
  if byte_offset_bits + 3 > 25 {
    return Err("EINVAL: WMA byte offset bits too large")
  }
  let mut bps1 = bps
  if channels == 2 {
    bps1 = bps * 1.6
  }
  if sample_rate1 == 44100 {
    if bps1 >= 0.61 {
      use_noise_coding = false
    } else {
      high_freq = high_freq * 0.4
    }
  } else if sample_rate1 == 22050 {
    if bps1 >= 1.16 {
      use_noise_coding = false
    } else if bps1 >= 0.72 {
      high_freq = high_freq * 0.7
    } else {
      high_freq = high_freq * 0.6
    }
  } else if sample_rate1 == 16000 {
    if bps > 0.5 {
      high_freq = high_freq * 0.5
    } else {
      high_freq = high_freq * 0.3
    }
  } else if sample_rate1 == 11025 {
    high_freq = high_freq * 0.7
  } else if sample_rate1 == 8000 {
    if bps <= 0.625 {
      high_freq = high_freq * 0.5
    } else if bps > 0.75 {
      use_noise_coding = false
    } else {
      high_freq = high_freq * 0.65
    }
  } else if bps >= 0.8 {
    high_freq = high_freq * 0.75
  } else if bps >= 0.6 {
    high_freq = high_freq * 0.6
  } else {
    high_freq = high_freq * 0.5
  }
  let exponent_sizes = FixedArray::make(wma_block_nb_sizes, 0)
  let exponent_bands : Array[FixedArray[Int32]] = []
  let high_band_start = FixedArray::make(wma_block_nb_sizes, 0)
  let coefs_end = FixedArray::make(wma_block_nb_sizes, 0)
  let exponent_high_sizes = FixedArray::make(wma_block_nb_sizes, 0)
  let exponent_high_bands : Array[FixedArray[Int32]] = []
  for i = 0; i < wma_block_nb_sizes; i = i + 1 {
    // 25 entries is the maximum band count for one block size.
    exponent_bands.push(FixedArray::make(25, 0))
    exponent_high_bands.push(FixedArray::make(wma_high_band_max_size, 0))
  }
  let coefs_start = if version == 1 { 3 } else { 0 }
  for k = 0; k < nb_block_sizes; k = k + 1 {
    let block_len = frame_len >> k
    if version == 1 {
      let mut lpos = 0
      let mut i = 0
      while i < 25 {
        let a = wma_critical_freqs[i]
        let mut pos = (block_len * 2 * a + (sample_rate >> 1)) / sample_rate
        if pos > block_len {
          pos = block_len
        }
        exponent_bands[0][i] = pos - lpos
        if pos >= block_len {
          i = i + 1
          break
        }
        lpos = pos
        i = i + 1
      }
      exponent_sizes[0] = i
    } else {
      let table = wma_exponent_band_table(sample_rate, frame_len_bits, k)
      match table {
        Some(row) => {
          let n = row[0]
          for i = 0; i < n; i = i + 1 {
            exponent_bands[k][i] = row[i + 1]
          }
          exponent_sizes[k] = n
        }
        None => {
          let mut j = 0
          let mut lpos = 0
          for i = 0; i < 25; i = i + 1 {
            let a = wma_critical_freqs[i]
            let mut pos = (block_len * 2 * a + (sample_rate << 1)) /
              (4 * sample_rate)
            pos = pos << 2
            if pos > block_len {
              pos = block_len
            }
            if pos > lpos {
              exponent_bands[k][j] = pos - lpos
              j = j + 1
            }
            if pos >= block_len {
              break
            }
            lpos = pos
          }
          exponent_sizes[k] = j
        }
      }
    }
    coefs_end[k] = (frame_len - frame_len * 9 / 100) >> k
    high_band_start[k] = (block_len.to_double() *
    2.0 *
    high_freq /
    sample_rate.to_double() +
    0.5).to_int()
    let n = exponent_sizes[k]
    let mut j = 0
    let mut pos = 0
    for i = 0; i < n; i = i + 1 {
      let mut start = pos
      pos = pos + exponent_bands[k][i]
      let mut end = pos
      if start < high_band_start[k] {
        start = high_band_start[k]
      }
      if end > coefs_end[k] {
        end = coefs_end[k]
      }
      if end > start {
        exponent_high_bands[k][j] = end - start
        j = j + 1
      }
    }
    exponent_high_sizes[k] = j
  }
  let windows : Array[Array[Double]] = []
  for k = 0; k < nb_block_sizes; k = k + 1 {
    windows.push(wma_sine_window(frame_len >> k))
  }
  let mut noise_mult = 0.0
  let noise_table : Array[Double] = Array::make(wma_noise_tab_size, 0.0)
  if use_noise_coding {
    noise_mult = if use_exp_vlc { 0.02 } else { 0.04 }
    let norm = 1.0 / 2147483648.0 * 1.7320508075688772 * noise_mult
    let mut seed : UInt32 = 1U
    for i = 0; i < wma_noise_tab_size; i = i + 1 {
      seed = seed * 314159U + 1U
      let sv = seed.reinterpret_as_int().to_double()
      noise_table[i] = Float::from_double(sv * norm).to_double()
    }
  }
  let mut coef_vlc_table = 2
  if sample_rate >= 32000 {
    if bps1 < 0.72 {
      coef_vlc_table = 0
    } else if bps1 < 1.16 {
      coef_vlc_table = 1
    }
  }
  let coef_vlc = [
    wma_coef_table(coef_vlc_table * 2),
    wma_coef_table(coef_vlc_table * 2 + 1),
  ]
  let exp_vlc = if use_exp_vlc {
    wma_vlc_build(aac_scalefactor_code, aac_scalefactor_bits)
  } else {
    wma_new_vlc_empty()
  }
  let hgain_vlc = if use_noise_coding {
    let codes : Array[UInt32] = []
    let bits : Array[Int32] = []
    for i = 0; i < wma_hgain_hufftab.length(); i = i + 1 {
      codes.push(wma_hgain_hufftab[i][0].reinterpret_as_uint())
      bits.push(wma_hgain_hufftab[i][1])
    }
    wma_vlc_build(codes, bits)
  } else {
    wma_new_vlc_empty()
  }
  let lsp_tables = wma_init_lsp_tables(frame_len)
  let high_band_coded : Array[FixedArray[Int32]] = []
  let high_band_values : Array[FixedArray[Int32]] = []
  let exponents : Array[Array[Double]] = []
  let coefs1 : Array[Array[Double]] = []
  let coefs : Array[Array[Double]] = []
  let frame_out : Array[Array[Double]] = []
  for i = 0; i < 2; i = i + 1 {
    high_band_coded.push(FixedArray::make(wma_high_band_max_size, 0))
    high_band_values.push(FixedArray::make(wma_high_band_max_size, 0))
    exponents.push(Array::make(wma_block_max_size, 0.0))
    coefs1.push(Array::make(wma_block_max_size, 0.0))
    coefs.push(Array::make(wma_block_max_size, 0.0))
    frame_out.push(Array::make(wma_block_max_size * 2, 0.0))
  }
  Ok({
    version,
    sample_rate,
    channels,
    bit_rate,
    block_align,
    use_bit_reservoir,
    use_variable_block_len,
    use_exp_vlc,
    use_noise_coding,
    byte_offset_bits,
    frame_len,
    frame_len_bits,
    nb_block_sizes,
    exponent_sizes,
    exponent_bands,
    high_band_start,
    coefs_start,
    coefs_end,
    exponent_high_sizes,
    exponent_high_bands,
    exp_vlc,
    hgain_vlc,
    high_band_coded,
    high_band_values,
    coef_vlc,
    reset_block_lengths: true,
    block_len_bits: frame_len_bits,
    next_block_len_bits: frame_len_bits,
    prev_block_len_bits: frame_len_bits,
    block_len: frame_len,
    block_num: 0,
    block_pos: 0,
    ms_stereo: false,
    channel_coded: FixedArray::make(2, false),
    exponents_bsize: FixedArray::make(2, 0),
    exponents,
    max_exponent: FixedArray::make(2, 1.0),
    coefs1,
    coefs,
    output: Array::make(wma_block_max_size * 2, 0.0),
    windows,
    frame_out,
    last_superframe: Array::make(wma_max_superframe + 64, b'\x00'),
    last_bitoffset: 0,
    last_superframe_len: 0,
    exponents_initialized: FixedArray::make(2, false),
    noise_table,
    noise_index: 0,
    noise_mult,
    lsp_cos_table: lsp_tables.0,
    lsp_pow_e_table: lsp_tables.1,
    lsp_pow_m_table1: lsp_tables.2,
    lsp_pow_m_table2: lsp_tables.3,
    eof_done: false,
  })
}

///|
/// `ff_sine_window_init`: `w[i] = sin((i + 0.5) * pi / (2n))`.
fn wma_sine_window(n : Int32) -> Array[Double] {
  let w : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    w[i] = @math.sin(
      (i.to_double() + 0.5) * (3.14159265358979323846 / (2.0 * n.to_double())),
    )
  }
  w
}

///|
/// One of the six coefficient VLC tables (`coef_vlcs[i]`).
fn wma_coef_table(idx : Int32) -> WmaCoefVlc {
  match idx {
    0 => wma_coef_vlc(wma_coef0_codes, wma_coef0_bits, wma_coef0_levels)
    1 => wma_coef_vlc(wma_coef1_codes, wma_coef1_bits, wma_coef1_levels)
    2 => wma_coef_vlc(wma_coef2_codes, wma_coef2_bits, wma_coef2_levels)
    3 => wma_coef_vlc(wma_coef3_codes, wma_coef3_bits, wma_coef3_levels)
    4 => wma_coef_vlc(wma_coef4_codes, wma_coef4_bits, wma_coef4_levels)
    _ => wma_coef_vlc(wma_coef5_codes, wma_coef5_bits, wma_coef5_levels)
  }
}
