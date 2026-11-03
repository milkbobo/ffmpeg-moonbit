/// MoonBit port of FFmpeg 9.0.2 `libavcodec/mpegaudioenc.c`: the simple MPEG
/// audio Layer II encoder, fixed-point path (`mp2fixed`).
///
/// FFmpeg ships no Layer III encoder, so `mpegaudioenc.c` is the whole encoder
/// side of the MPEG audio family upstream: Layer II with the 32-band polyphase
/// analysis filter bank, a 512-tap windowed `idct32` (the inverse of the
/// decoder's `dct32`), per-subband scalefactors, the fixed psychoacoustic
/// model from toolame and a greedy bit allocation that fills the frame budget.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2000, 2001 Fabrice
/// Bellard. This port keeps the same license.
///
/// Numeric path: `FRAC_BITS = 15` (subband samples and DCT), `WFRAC_BITS = 14`
/// (window), `WSHIFT = WFRAC_BITS + 15 - FRAC_BITS = 14`. `MUL(a, b)` is
/// `(int64)a * b >> 15`, `FIX(x)` is the truncation of `x * 32768`.
///
/// Deviations: the encoder takes interleaved `Int32` samples holding the same
/// values as the C `int16_t` input, and the frame budget / padding arithmetic
/// is reproduced exactly (including the `float` frame-size computation of
/// `mpa_encode_init`). No CRC is written (FFmpeg's encoder writes none either).

///|
/// `MPA_MAX_CHANNELS`. */
let mpa_encode_max_channels : Int32 = 2

///|
/// `SAMPLES_BUF_SIZE`, the per-channel analysis buffer. */
let mpa_encode_samples_buf_size : Int32 = 4096

///|
/// `MPA_FRAME_SIZE`, PCM samples produced per frame. */
let mpa_encode_frame_samples : Int32 = 1152

///|
/// `SBLIMIT`, the number of subbands. */
let mpa_encode_sblimit : Int32 = 32

///|
/// `WSHIFT = WFRAC_BITS + 15 - FRAC_BITS`. */
let mpa_encode_wshift : Int32 = 14

///|
/// `P`: the normalisation bits of the fixed scalefactor path. */
let mpa_encode_p : Int32 = 15

///|
/// `FIX(x)`: truncate `x * 2^15` the way the C `(int)((a) * FRAC_ONE)` does. */
fn mpa_encode_fix(x : Double) -> Int32 {
  (x * 32768.0).to_int64().to_int()
}

///|
/// `MUL(a, b)`: 64-bit product shifted right by `FRAC_BITS`. */
fn mpa_encode_mul(a : Int32, b : Int32) -> Int32 {
  ((a.to_int64() * b.to_int64()) >> 15).to_int()
}

///|
/// `FIX(M_SQRT2 * 0.5)`, used by the first `idct32` butterfly. */
let mpa_encode_fix_sqrt2_half : Int32 = mpa_encode_fix(0.70710678118654752440)

///|
/// `costab32[30]` (`mpegaudiotab.h`), derived with the C `FIX` macro. */
let mpa_encode_costab32 : Array[Int32] = [
  mpa_encode_fix(0.54119610014619701222),
  mpa_encode_fix(1.3065629648763763537),
  mpa_encode_fix(0.50979557910415917998),
  mpa_encode_fix(2.5629154477415054814),
  mpa_encode_fix(0.89997622313641556513),
  mpa_encode_fix(0.60134488693504528634),
  mpa_encode_fix(0.5024192861881556782),
  mpa_encode_fix(5.1011486186891552563),
  mpa_encode_fix(0.78815462345125020249),
  mpa_encode_fix(0.64682178335999007679),
  mpa_encode_fix(0.56694403481635768927),
  mpa_encode_fix(1.0606776859903470633),
  mpa_encode_fix(1.7224470982383341955),
  mpa_encode_fix(0.52249861493968885462),
  mpa_encode_fix(10.19000812354803287),
  mpa_encode_fix(0.674808341455005678),
  mpa_encode_fix(1.1694399334328846596),
  mpa_encode_fix(0.53104259108978413284),
  mpa_encode_fix(2.0577810099534108446),
  mpa_encode_fix(0.58293496820613388554),
  mpa_encode_fix(0.83934964541552681272),
  mpa_encode_fix(0.50547095989754364798),
  mpa_encode_fix(3.4076084184687189804),
  mpa_encode_fix(0.62250412303566482475),
  mpa_encode_fix(0.97256823786196078263),
  mpa_encode_fix(0.51544730992262455249),
  mpa_encode_fix(1.4841646163141661852),
  mpa_encode_fix(0.5531038960344445421),
  mpa_encode_fix(0.74453627100229857749),
  mpa_encode_fix(0.5006029982351962726),
]

///|
/// `bitinv32[32]`: the bit-reversed output permutation of `idct32`. */
let mpa_encode_bitinv32 : Array[Int32] = [
  0, 16, 8, 24, 4, 20, 12, 28, 2, 18, 10, 26, 6, 22, 14, 30, 1, 17, 9, 25, 5, 21,
  13, 29, 3, 19, 11, 27, 7, 23, 15, 31,
]

///|
/// `quant_snr[17]`: signal-to-noise ratio of each quantiser, in 0.1 dB. */
let mpa_encode_quant_snr : Array[Int32] = [
  70, 110, 160, 208, 253, 316, 378, 439, 499, 559, 620, 680, 740, 800, 861, 920,
  980,
]

///|
/// `fixed_smr[SBLIMIT]`: the toolame fixed psychoacoustic model. */
let mpa_encode_fixed_smr : Array[Double] = [
  30.0, 17.0, 16.0, 10.0, 3.0, 12.0, 8.0, 2.5, 5.0, 5.0, 6.0, 6.0, 5.0, 6.0, 10.0,
  6.0, -4.0, -10.0, -21.0, -30.0, -42.0, -55.0, -68.0, -75.0, -75.0, -75.0, -75.0,
  -75.0, -91.0, -107.0, -110.0, -108.0,
]

///|
/// `nb_scale_factors[4]`: scalefactors transmitted per `scale_code`. */
let mpa_encode_nb_scale_factors : Array[Int32] = [3, 2, 1, 2]

///|
/// `SB_NOTALLOCATED`, `SB_ALLOCATED`, `SB_NOMORE`. */
let mpa_encode_sb_notallocated : Int32 = 0

///|
let mpa_encode_sb_allocated : Int32 = 1

///|
let mpa_encode_sb_nomore : Int32 = 2

///|
/// Encoder configuration; `bit_rate` is in bits per second, as in
/// `AVCodecContext.bit_rate`.
pub struct MpaEncodeConfig {
  sample_rate : Int32
  channels : Int32
  bit_rate : Int32
}

///|
/// Build an MP2 encoder configuration.
pub fn mpa_encode_config(
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> MpaEncodeConfig {
  { sample_rate, channels, bit_rate, }
}

///|
/// `MpegAudioContext`. All per-channel state is kept inline, like the C struct.
pub struct MpaEncoder {
  config : MpaEncodeConfig
  nb_channels : Int32
  lsf : Int32
  bitrate_index : Int32
  freq_index : Int32
  frame_size : Int32
  mut frame_frac : Int32
  frame_frac_incr : Int32
  mut do_padding : Int32
  samples_buf : Array[Array[Int32]]
  samples_offset : Array[Int32]
  sb_samples : Array[Array[Array[Array[Int32]]]]
  scale_factors : Array[Array[Array[Int32]]]
  scale_code : Array[Array[Int32]]
  sblimit : Int32
  alloc_table : Array[Int32]
  filter_bank : Array[Int32]
  scale_factor_table : Array[Int32]
  scale_factor_shift : Array[Int32]
  scale_factor_mult : Array[Int32]
  scale_diff_table : Array[Int32]
  total_quant_bits : Array[Int32]
}

///|
/// `(float)x`: round a double to the nearest IEEE-754 single-precision value
/// (the C `float a` of `mpa_encode_init`). `Float` is MoonBit's binary32 type.
fn mpa_encode_float(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
/// `mpa_encode_init`: validate the sample rate / bit rate, pick the allocation
/// table and precompute the window, scalefactor and quantiser tables.
pub fn mpa_encoder_new(config : MpaEncodeConfig) -> Result[MpaEncoder, String] {
  let freq = config.sample_rate
  let channels = config.channels
  if channels <= 0 || channels > mpa_encode_max_channels {
    return Err("MP2 supports 1 or 2 channels")
  }
  let mut bitrate = config.bit_rate / 1000
  // Encoding frequency: MPEG-1 rates first, then the MPEG-2 LSF halves.
  let mut lsf = 0
  let mut freq_index = -1
  for i = 0; i < 3; i = i + 1 {
    if ff_mpa_freq_tab[i] == freq {
      freq_index = i
      break
    }
    if ff_mpa_freq_tab[i] / 2 == freq {
      lsf = 1
      freq_index = i
      break
    }
  }
  if freq_index < 0 {
    return Err("MP2 does not support this sample rate")
  }
  // Encoding bit rate: index 1..14 selects a Layer II bit rate.
  let mut bitrate_index = 1
  while bitrate_index < 15 &&
        ff_mpa_bitrate_tab[lsf][1][bitrate_index] != bitrate {
    bitrate_index = bitrate_index + 1
  }
  if bitrate_index == 15 {
    if config.bit_rate == 0 {
      bitrate_index = 14
      bitrate = ff_mpa_bitrate_tab[lsf][1][bitrate_index]
    } else {
      return Err("bitrate is not allowed in mp2")
    }
  }
  // Total header size and pad bit. The C computes `a` in binary32.
  let a = mpa_encode_float(
    (bitrate * 1000 * mpa_encode_frame_samples).to_double() /
    (freq.to_double() * 8.0),
  )
  let frame_size = a.to_int64().to_int() * 8
  let frame_frac_incr = ((a - @math.floor(a)) * 65536.0).to_int64().to_int()
  let table = mpa_l2_select_table(bitrate, channels, freq, lsf)
  let sblimit = mpa_sblimit_table[table]
  let alloc_table = mpa_alloc_tables[table]
  // Analysis window: `ff_mpa_enwindow` narrowed from WFRAC_BITS=16 to 14.
  let filter_bank : Array[Int32] = Array::make(512, 0)
  for i = 0; i <= 256; i = i + 1 {
    let mut v = mpa_enwindow[i]
    v = (v + 2) >> 2
    filter_bank[i] = v
    if (i & 63) != 0 {
      v = -v
    }
    if i != 0 {
      filter_bank[512 - i] = v
    }
  }
  // Scalefactor tables of the fixed path.
  let scale_factor_table : Array[Int32] = Array::make(64, 0)
  let scale_factor_shift : Array[Int32] = Array::make(64, 0)
  let scale_factor_mult : Array[Int32] = Array::make(64, 0)
  for i = 0; i < 64; i = i + 1 {
    let mut v = (@math.pow(2.0, (3 - i).to_double() / 3.0) * 1048576.0)
      .to_int64()
      .to_int()
    if v <= 0 {
      v = 1
    }
    scale_factor_table[i] = v
    scale_factor_shift[i] = 21 - mpa_encode_p - i / 3
    scale_factor_mult[i] = (32768.0 * @math.pow(2.0, (i % 3).to_double() / 3.0))
      .to_int64()
      .to_int()
  }
  // `scale_diff_table`: coarsens the scalefactor distance to 0..4.
  let scale_diff_table : Array[Int32] = Array::make(128, 0)
  for i = 0; i < 128; i = i + 1 {
    let v = i - 64
    scale_diff_table[i] = if v <= -3 {
      0
    } else if v < 0 {
      1
    } else if v == 0 {
      2
    } else if v < 3 {
      3
    } else {
      4
    }
  }
  // Total bits per allocation group, including the grouped 3-sample codes.
  let total_quant_bits : Array[Int32] = Array::make(17, 0)
  for i = 0; i < 17; i = i + 1 {
    let mut v = mpa_quant_bits[i]
    v = if v < 0 { -v } else { v * 3 }
    total_quant_bits[i] = 12 * v
  }
  // Per-channel scratch state.
  let samples_buf : Array[Array[Int32]] = []
  let samples_offset : Array[Int32] = []
  let sb_samples : Array[Array[Array[Array[Int32]]]] = []
  let scale_factors : Array[Array[Array[Int32]]] = []
  let scale_code : Array[Array[Int32]] = []
  for ch = 0; ch < channels; ch = ch + 1 {
    samples_buf.push(Array::make(mpa_encode_samples_buf_size, 0))
    samples_offset.push(0)
    let blocks : Array[Array[Array[Int32]]] = []
    for _k = 0; _k < 3; _k = _k + 1 {
      let rows : Array[Array[Int32]] = []
      for _l = 0; _l < 12; _l = _l + 1 {
        rows.push(Array::make(mpa_encode_sblimit, 0))
      }
      blocks.push(rows)
    }
    sb_samples.push(blocks)
    let sfs : Array[Array[Int32]] = []
    for _i = 0; _i < mpa_encode_sblimit; _i = _i + 1 {
      sfs.push(Array::make(3, 0))
    }
    scale_factors.push(sfs)
    scale_code.push(Array::make(mpa_encode_sblimit, 0))
  }
  Ok({
    config,
    nb_channels: channels,
    lsf,
    bitrate_index,
    freq_index,
    frame_size,
    frame_frac: 0,
    frame_frac_incr,
    do_padding: 0,
    samples_buf,
    samples_offset,
    sb_samples,
    scale_factors,
    scale_code,
    sblimit,
    alloc_table,
    filter_bank,
    scale_factor_table,
    scale_factor_shift,
    scale_factor_mult,
    scale_diff_table,
    total_quant_bits,
  })
}

///|
/// `av_log2(v)` for `v > 0`: the position of the most significant bit. */
fn mpa_encode_log2(v : Int32) -> Int32 {
  let mut x = v
  let mut n = 0
  while x >= 2 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `idct32`: the 32-point inverse DCT of the analysis filter bank (no
/// `1/sqrt(2)` scaling). `tab` is the 32-entry windowed input, `out` receives
/// the 32 subband samples in `bitinv32` order.
fn mpa_encode_idct32(
  out : Array[Int32],
  out_off : Int32,
  tab : Array[Int32],
) -> Unit {
  let xp = mpa_encode_costab32
  for j = 31; j >= 3; j = j - 2 {
    tab[j] = tab[j] + tab[j - 2]
  }
  let mut t = 30
  while t != 2 {
    tab[t] = tab[t] + tab[t - 4]
    tab[t + 1] = tab[t + 1] + tab[t + 1 - 4]
    t = t - 4
  }
  t = 28
  while t != 4 {
    tab[t] = tab[t] + tab[t - 8]
    tab[t + 1] = tab[t + 1] + tab[t + 1 - 8]
    tab[t + 2] = tab[t + 2] + tab[t + 2 - 8]
    tab[t + 3] = tab[t + 3] + tab[t + 3 - 8]
    t = t - 8
  }
  t = 0
  while t != 32 {
    tab[t + 3] = -tab[t + 3]
    tab[t + 6] = -tab[t + 6]
    tab[t + 11] = -tab[t + 11]
    tab[t + 12] = -tab[t + 12]
    tab[t + 13] = -tab[t + 13]
    tab[t + 15] = -tab[t + 15]
    t = t + 16
  }
  for b = 0; b < 8; b = b + 1 {
    let x3 = mpa_encode_mul(tab[b + 16], mpa_encode_fix_sqrt2_half)
    let x4 = tab[b] - x3
    let x3b = tab[b] + x3
    let x2 = mpa_encode_mul(
      -(tab[b + 24] + tab[b + 8]),
      mpa_encode_fix_sqrt2_half,
    )
    let x1 = mpa_encode_mul(tab[b + 8] - x2, xp[0])
    let x2b = mpa_encode_mul(tab[b + 8] + x2, xp[1])
    tab[b] = x3b + x1
    tab[b + 8] = x4 - x2b
    tab[b + 16] = x4 + x2b
    tab[b + 24] = x3b - x1
  }
  for b = 0; b < 4; b = b + 1 {
    let mut xr = mpa_encode_mul(tab[b + 28], xp[2])
    tab[b + 28] = tab[b] - xr
    tab[b] = tab[b] + xr
    xr = mpa_encode_mul(tab[b + 4], xp[3])
    tab[b + 4] = tab[b + 24] - xr
    tab[b + 24] = tab[b + 24] + xr
    xr = mpa_encode_mul(tab[b + 20], xp[4])
    tab[b + 20] = tab[b + 8] - xr
    tab[b + 8] = tab[b + 8] + xr
    xr = mpa_encode_mul(tab[b + 12], xp[5])
    tab[b + 12] = tab[b + 16] - xr
    tab[b + 16] = tab[b + 16] + xr
  }
  for i = 0; i < 4; i = i + 1 {
    let ca = xp[6 + i * 2]
    let cb = xp[7 + i * 2]
    let mut xr = mpa_encode_mul(tab[30 - i * 4], ca)
    tab[30 - i * 4] = tab[i * 4] - xr
    tab[i * 4] = tab[i * 4] + xr
    xr = mpa_encode_mul(tab[2 + i * 4], cb)
    tab[2 + i * 4] = tab[28 - i * 4] - xr
    tab[28 - i * 4] = tab[28 - i * 4] + xr
    xr = mpa_encode_mul(tab[31 - i * 4], ca)
    tab[31 - i * 4] = tab[1 + i * 4] - xr
    tab[1 + i * 4] = tab[1 + i * 4] + xr
    xr = mpa_encode_mul(tab[3 + i * 4], cb)
    tab[3 + i * 4] = tab[29 - i * 4] - xr
    tab[29 - i * 4] = tab[29 - i * 4] + xr
  }
  let mut th = 30
  let mut tl = 1
  let mut xi = 14
  while th >= 0 {
    let xr = mpa_encode_mul(tab[tl], xp[xi])
    tab[tl] = tab[th] - xr
    tab[th] = tab[th] + xr
    th = th - 2
    tl = tl + 2
    xi = xi + 1
  }
  for i = 0; i < 32; i = i + 1 {
    out[out_off + i] = tab[mpa_encode_bitinv32[i]]
  }
}

///|
/// `filter`: run the 32-band polyphase analysis filter over 36 blocks of 32
/// samples (one Layer II frame), writing `sb_samples`.
fn MpaEncoder::filter(
  self : MpaEncoder,
  ch : Int32,
  samples : Array[Int32],
  incr : Int32,
) -> Unit {
  let buf = self.samples_buf[ch]
  let mut offset = self.samples_offset[ch]
  let out = self.sb_samples[ch]
  let tmp : Array[Int32] = Array::make(64, 0)
  let tmp1 : Array[Int32] = Array::make(32, 0)
  let mut pos = ch
  for j = 0; j < 36; j = j + 1 {
    for i = 0; i < 32; i = i + 1 {
      buf[offset + (31 - i)] = samples[pos]
      pos = pos + incr
    }
    for i = 0; i < 64; i = i + 1 {
      let mut sum : Int32 = 0
      for k = 0; k < 8; k = k + 1 {
        sum = sum + buf[offset + k * 64 + i] * self.filter_bank[k * 64 + i]
      }
      tmp[i] = sum
    }
    tmp1[0] = tmp[16] >> mpa_encode_wshift
    for i = 1; i <= 16; i = i + 1 {
      tmp1[i] = (tmp[i + 16] + tmp[16 - i]) >> mpa_encode_wshift
    }
    for i = 17; i <= 31; i = i + 1 {
      tmp1[i] = (tmp[i + 16] - tmp[80 - i]) >> mpa_encode_wshift
    }
    mpa_encode_idct32(out[j / 12][j % 12], 0, tmp1)
    offset = offset - 32
    if offset < 0 {
      for i = 0; i < 480; i = i + 1 {
        buf[mpa_encode_samples_buf_size - 480 + i] = buf[i]
      }
      offset = mpa_encode_samples_buf_size - 512
    }
  }
  self.samples_offset[ch] = offset
}

///|
/// `compute_scale_factors`: choose the three scalefactors of every subband and
/// the 2-bit `scale_code` that says which of them are transmitted.
fn MpaEncoder::compute_scale_factors(self : MpaEncoder, ch : Int32) -> Unit {
  let sb = self.sb_samples[ch]
  let codes = self.scale_code[ch]
  let sfs = self.scale_factors[ch]
  for j = 0; j < self.sblimit; j = j + 1 {
    for i = 0; i < 3; i = i + 1 {
      let v0 = sb[i][0][j]
      let mut vmax = if v0 < 0 { -v0 } else { v0 }
      for k = 1; k < 12; k = k + 1 {
        let v = sb[i][k][j]
        let av = if v < 0 { -v } else { v }
        if av > vmax {
          vmax = av
        }
      }
      let mut index : Int32 = 0
      if vmax > 1 {
        let n = mpa_encode_log2(vmax)
        index = (21 - n) * 3 - 3
        if index >= 0 {
          while vmax <= self.scale_factor_table[index + 1] {
            index = index + 1
          }
        } else {
          index = 0
        }
      } else {
        index = 62
      }
      sfs[j][i] = index
    }
    let mut sf0 = sfs[j][0]
    let mut sf1 = sfs[j][1]
    let mut sf2 = sfs[j][2]
    let d1 = self.scale_diff_table[sf0 - sf1 + 64]
    let d2 = self.scale_diff_table[sf1 - sf2 + 64]
    let mut code = 0
    match d1 * 5 + d2 {
      0 | 4 | 19 | 20 | 24 => code = 0
      1 | 2 | 21 | 22 => {
        code = 3
        sf2 = sf1
      }
      3 | 23 => {
        code = 3
        sf1 = sf2
      }
      5 | 9 | 14 => {
        code = 1
        sf1 = sf0
      }
      6 | 7 | 10 | 11 | 12 => {
        code = 2
        sf2 = sf0
        sf1 = sf0
      }
      13 | 18 => {
        code = 2
        sf1 = sf2
        sf0 = sf2
      }
      15 | 16 | 17 => {
        code = 2
        sf2 = sf1
        sf0 = sf1
      }
      8 => {
        code = 2
        if sf0 > sf2 {
          sf0 = sf2
        }
        sf1 = sf0
        sf2 = sf0
      }
      _ => code = 0
    }
    sfs[j][0] = sf0
    sfs[j][1] = sf1
    sfs[j][2] = sf2
    codes[j] = code
  }
}

///|
/// `psycho_acoustic_model`: the fixed toolame SNR table, in 0.1 dB. */
fn MpaEncoder::psycho_acoustic_model(
  self : MpaEncoder,
  smr : Array[Int32],
) -> Unit {
  for i = 0; i < self.sblimit; i = i + 1 {
    smr[i] = (mpa_encode_fixed_smr[i] * 10.0).to_int64().to_int()
  }
}

///|
/// `compute_bit_allocation`: greedily hand out the frame budget to the subband
/// with the largest remaining signal-to-mask ratio. Returns the allocation,
/// the padded frame size in bytes and the leftover bits.
fn MpaEncoder::compute_bit_allocation(
  self : MpaEncoder,
  smr1 : Array[Array[Int32]],
) -> (Array[Array[Int32]], Int32, Int32) {
  let nch = self.nb_channels
  let smr : Array[Array[Int32]] = []
  let bit_alloc : Array[Array[Int32]] = []
  let status : Array[Array[Int32]] = []
  for ch = 0; ch < nch; ch = ch + 1 {
    smr.push(Array::copy(smr1[ch]))
    bit_alloc.push(Array::make(mpa_encode_sblimit, 0))
    status.push(Array::make(mpa_encode_sblimit, mpa_encode_sb_notallocated))
  }
  // Frame size and padding.
  let mut max_frame_size = self.frame_size
  self.frame_frac = self.frame_frac + self.frame_frac_incr
  if self.frame_frac >= 65536 {
    self.frame_frac = self.frame_frac - 65536
    self.do_padding = 1
    max_frame_size = max_frame_size + 8
  } else {
    self.do_padding = 0
  }
  // Header + bit allocation.
  let mut current_frame_size = 32
  let mut j = 0
  for _i = 0; _i < self.sblimit; _i = _i + 1 {
    let incr = self.alloc_table[j]
    current_frame_size = current_frame_size + incr * nch
    j = j + (1 << incr)
  }
  while true {
    // Subband with the largest remaining SMR.
    let mut max_sb = -1
    let mut max_ch = -1
    let mut max_smr : Int32 = -2147483647 - 1
    for ch = 0; ch < nch; ch = ch + 1 {
      for i = 0; i < self.sblimit; i = i + 1 {
        if smr[ch][i] > max_smr && status[ch][i] != mpa_encode_sb_nomore {
          max_smr = smr[ch][i]
          max_sb = i
          max_ch = ch
        }
      }
    }
    if max_sb < 0 {
      break
    }
    // Allocation-table entry of this subband.
    let mut alloc_j = 0
    for _i = 0; _i < max_sb; _i = _i + 1 {
      alloc_j = alloc_j + (1 << self.alloc_table[alloc_j])
    }
    let mut incr : Int32 = 0
    if status[max_ch][max_sb] == mpa_encode_sb_notallocated {
      // Nothing coded yet: scalefactors plus the first quantiser.
      incr = 2 +
        mpa_encode_nb_scale_factors[self.scale_code[max_ch][max_sb]] * 6
      incr = incr + self.total_quant_bits[self.alloc_table[alloc_j + 1]]
    } else {
      let b = bit_alloc[max_ch][max_sb]
      incr = self.total_quant_bits[self.alloc_table[alloc_j + b + 1]] -
        self.total_quant_bits[self.alloc_table[alloc_j + b]]
    }
    if current_frame_size + incr <= max_frame_size {
      let b = bit_alloc[max_ch][max_sb] + 1
      bit_alloc[max_ch][max_sb] = b
      current_frame_size = current_frame_size + incr
      smr[max_ch][max_sb] = smr1[max_ch][max_sb] -
        mpa_encode_quant_snr[self.alloc_table[alloc_j + b]]
      if b == (1 << self.alloc_table[alloc_j]) - 1 {
        status[max_ch][max_sb] = mpa_encode_sb_nomore
      } else {
        status[max_ch][max_sb] = mpa_encode_sb_allocated
      }
    } else {
      status[max_ch][max_sb] = mpa_encode_sb_nomore
    }
  }
  (bit_alloc, max_frame_size / 8, max_frame_size - current_frame_size)
}

///|
/// `encode_subbands`: quantise and write the 3 × 12 blocks of every allocated
/// subband of both channels. Grouped quantisers (negative `quant_bits`) pack
/// three samples into one code word.
fn MpaEncoder::encode_subbands(
  self : MpaEncoder,
  bw : BitWriter,
  bit_alloc : Array[Array[Int32]],
) -> Unit {
  let alloc = self.alloc_table
  for k = 0; k < 3; k = k + 1 {
    for l = 0; l < 12; l = l + 3 {
      let mut j = 0
      for i = 0; i < self.sblimit; i = i + 1 {
        let bit_alloc_bits = alloc[j]
        for ch = 0; ch < self.nb_channels; ch = ch + 1 {
          let b = bit_alloc[ch][i]
          if b != 0 {
            let qindex = alloc[j + b]
            let steps = mpa_quant_steps[qindex]
            let q : Array[Int32] = Array::make(3, 0)
            for m = 0; m < 3; m = m + 1 {
              let sample = self.sb_samples[ch][k][l + m][i]
              let e = self.scale_factors[ch][i][k]
              let shift = self.scale_factor_shift[e]
              let mult = self.scale_factor_mult[e]
              let mut q1 = if shift < 0 {
                sample * ((1 : Int32) << -shift)
              } else {
                sample >> shift
              }
              q1 = ((q1.to_int64() * mult.to_int64()) >> mpa_encode_p).to_int()
              q1 = q1 + (1 << mpa_encode_p)
              if q1 < 0 {
                q1 = 0
              }
              let mut qm = ((q1.to_int64() * steps.to_int64()) >>
              (mpa_encode_p + 1)).to_int()
              if qm >= steps {
                qm = steps - 1
              }
              q[m] = qm
            }
            let bits = mpa_quant_bits[qindex]
            if bits < 0 {
              bw.put(
                (q[0] + steps * (q[1] + steps * q[2])).reinterpret_as_uint(),
                -bits,
              )
            } else {
              bw.put(q[0].reinterpret_as_uint(), bits)
              bw.put(q[1].reinterpret_as_uint(), bits)
              bw.put(q[2].reinterpret_as_uint(), bits)
            }
          }
        }
        j = j + (1 << bit_alloc_bits)
      }
    }
  }
}

///|
/// `encode_frame`: write the Layer II header, bit allocation, scalecodes,
/// scalefactors and subband samples, then zero-fill the frame to its padded
/// size.
fn MpaEncoder::write_frame(
  self : MpaEncoder,
  frame_size_bytes : Int32,
  bit_alloc : Array[Array[Int32]],
) -> Result[Bytes, String] {
  let bw = BitWriter::new()
  // Header.
  bw.put(0xFFF, 12)
  bw.put((1 - self.lsf).reinterpret_as_uint(), 1)
  bw.put(2, 2)
  bw.put(1, 1)
  bw.put(self.bitrate_index.reinterpret_as_uint(), 4)
  bw.put(self.freq_index.reinterpret_as_uint(), 2)
  bw.put(self.do_padding.reinterpret_as_uint(), 1)
  bw.put(0, 1)
  bw.put(if self.nb_channels == 2 { 0 } else { 3 }, 2)
  bw.put(0, 2)
  bw.put(0, 1)
  bw.put(1, 1)
  bw.put(0, 2)
  // Bit allocation.
  let mut j = 0
  for i = 0; i < self.sblimit; i = i + 1 {
    let bit_alloc_bits = self.alloc_table[j]
    for ch = 0; ch < self.nb_channels; ch = ch + 1 {
      bw.put(bit_alloc[ch][i].reinterpret_as_uint(), bit_alloc_bits)
    }
    j = j + (1 << bit_alloc_bits)
  }
  // Scalecodes, then scalefactors: the C writes the 2-bit selection codes of
  // every allocated subband first, then the factors in a second pass.
  for i = 0; i < self.sblimit; i = i + 1 {
    for ch = 0; ch < self.nb_channels; ch = ch + 1 {
      if bit_alloc[ch][i] != 0 {
        bw.put(self.scale_code[ch][i].reinterpret_as_uint(), 2)
      }
    }
  }
  for i = 0; i < self.sblimit; i = i + 1 {
    for ch = 0; ch < self.nb_channels; ch = ch + 1 {
      if bit_alloc[ch][i] != 0 {
        let code = self.scale_code[ch][i]
        let sf0 = self.scale_factors[ch][i][0]
        let sf1 = self.scale_factors[ch][i][1]
        let sf2 = self.scale_factors[ch][i][2]
        match code {
          0 =>
            bw.put(((sf0 << 12) | (sf1 << 6) | sf2).reinterpret_as_uint(), 18)
          3 | 1 => bw.put(((sf0 << 6) | sf2).reinterpret_as_uint(), 12)
          2 => bw.put(sf0.reinterpret_as_uint(), 6)
          _ => ()
        }
      }
    }
  }
  self.encode_subbands(bw, bit_alloc)
  let bytes = bw.finish()
  if bytes.length() > frame_size_bytes {
    return Err("MP2 frame overflow")
  }
  let out : Array[Byte] = Array::make(frame_size_bytes, (0).to_byte())
  for i = 0; i < bytes.length(); i = i + 1 {
    out[i] = bytes[i]
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode one Layer II frame (1152 PCM samples per channel) from interleaved
/// `Int32` samples holding `int16` values. The returned packet is exactly
/// `frame_size` bytes (417..1728 depending on rate and bit rate).
pub fn MpaEncoder::encode_frame(
  self : MpaEncoder,
  samples : Array[Int32],
) -> Result[Bytes, String] {
  let need = mpa_encode_frame_samples * self.nb_channels
  if samples.length() < need {
    return Err("MP2 encoder needs 1152 samples per channel")
  }
  for ch = 0; ch < self.nb_channels; ch = ch + 1 {
    self.filter(ch, samples, self.nb_channels)
  }
  for ch = 0; ch < self.nb_channels; ch = ch + 1 {
    self.compute_scale_factors(ch)
  }
  let smr : Array[Array[Int32]] = []
  for _ch = 0; _ch < self.nb_channels; _ch = _ch + 1 {
    let row : Array[Int32] = Array::make(mpa_encode_sblimit, 0)
    self.psycho_acoustic_model(row)
    smr.push(row)
  }
  let (bit_alloc, frame_size_bytes, _padding) = self.compute_bit_allocation(smr)
  self.write_frame(frame_size_bytes, bit_alloc)
}
