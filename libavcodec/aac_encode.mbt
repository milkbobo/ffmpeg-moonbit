///|
/// MoonBit port of a minimal AAC-LC encoder, shipped as ADTS frames.
///
/// Scope: AAC-LC object type 2, sine windows, no PNS / prediction, one SCE for
/// mono or one CPE with a common window for stereo, and codebook 11 spectral
/// Huffman with escape sequences (quantised magnitudes up to 8191).
///
/// Stereo uses mid/side coding per scalefactor band: M = (L + R) / 2 and
/// S = (L - R) / 2, chosen band by band when the companded alphabet of the
/// pair is smaller than that of L/R (the encoder-side twin of FFmpeg's
/// `search_for_ms`), with the CPE carrying one shared `ics_info` and a per-band
/// `ms_used` mask. On top of that, `aac_encode_config_with_is` lets a
/// correlated band above the intensity gate be coded as an `off_is` position of
/// the right channel with no spectral data at all (§290). Temporal noise shaping follows `aacenc_tns.c`: a 12th-order
/// (7th for short windows) LPC analysis of the upper scalefactor bands, gated
/// on the LPC gain, quantised to `ff_tns_tmp2_map_1_4` and applied as an
/// all-zero filter before quantisation. Each band gets its own scalefactor
/// from a simplified psychoacoustic
/// model (upward spreading of band energy plus a frequency-dependent SNR aim),
/// then one frame-wide offset shifts every band's scalefactor and is
/// binary-searched so each ADTS frame fills the requested average bit rate.
/// This is a CBR-style rate control: when a frame has bit head-room the
/// quantiser is refined instead of the spare bits being dropped.
///
/// Window switching follows the LAME/3GPP attack detector of FFmpeg's
/// `aacpsy.c`: the high-passed energy of each 128-sample subblock is compared
/// against a sliding average, and the four window sequences are chained
/// ONLY_LONG -> LONG_START -> EIGHT_SHORT -> LONG_STOP -> ONLY_LONG so the
/// long/short transition windows always meet a matching short block.
///
/// The quantiser/demultiplexing conventions follow FFmpeg 9.0.2
/// `libavcodec/aacenc.c` / `aacenc_quantization.h`:
///   * encoder MDCT coefficient `c` is `65536 * X` where `X` is the textbook
///     forward MDCT (the decoder's IMDCT carries `2/N` then divides by
///     65536),
///   * `q = floor((|c| * 2^(-(sf-100)/4))^(3/4) + 0.405)`,
///   * decoder dequantisation is `q^(4/3) * 2^((sf-100)/4)`.
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// Encoder configuration. Only AAC-LC (object type 2) is produced.
pub struct AacEncodeConfig {
  sample_rate : Int32
  channels : Int32
  bit_rate : Int32
  /// Quantise steady-state long frames with the 3GPP model and the twoloop
  /// search (`aac_encode_config_perceptual`) instead of the simplified
  /// perceptual model plus the frame-wide offset search.
  perceptual : Bool
  /// Enable perceptual noise substitution on those frames (FFmpeg's default
  /// `options.pns = 1`). Off by default so the §279/§280 measurements stay
  /// reproducible; use `aac_encode_config_with_pns` to turn it on.
  pns : Bool
  /// Enable intensity stereo (`aacenc_is.c`) on channel pairs. Off by default
  /// for the same reason as `pns`: bands switch to codebooks 14/15, so both
  /// the bitstream layout and the round-trip measurements change.
  /// `aac_encode_config_with_is` turns it on.
  is_stereo : Bool
}

///|
/// AAC-LC encoder state: per-channel 1024-sample overlap history, the swb band
/// plan of the configured sample rate, the precomputed MDCT kernel and the
/// per-codebook Huffman tables (codes, code lengths and the reverse map from a
/// packed vector back to its symbol).
pub struct AacEncoder {
  config : AacEncodeConfig
  sampling_index : Int32
  swb_offsets : Array[Int32]
  num_swb : Int32
  short_offsets : Array[Int32]
  num_short_swb : Int32
  history : Array[Array[Double]]
  cos_table : Array[Double]
  short_window : Array[Double]
  spectral_codes : Array[Array[UInt32]]
  spectral_bits : Array[Array[Int32]]
  spectral_rev : Array[Array[Int32]]
  prev_sequence : Array[Int32]
  attack_pending : Array[Bool]
  win_energy : Array[Double]
  psy : AacPsyContext
  /// Bit count of the previous frame's AAC payload, per channel, fed back to
  /// the psy model as `bitres.bits` (`libavcodec` `last_frame_pb_count`).
  mut last_frame_bits : Int32
  /// Rate-control lambda of the perceptual path: starts each frame at 120 and
  /// is scaled down by `min(0.9, rate/frame)` while the quantised frame
  /// overflows (`aac_encode_frame`'s strict bit-rate control).
  mut lambda : Double
  /// LCG state carried across frames by `search_for_pns` (`s->random_state`).
  mut pns_random_state : Int32
}

///|
/// Build an AAC-LC encoder configuration.
pub fn aac_encode_config(
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> AacEncodeConfig {
  {
    sample_rate,
    channels,
    bit_rate,
    perceptual: false,
    pns: false,
    is_stereo: false,
  }
}

///|
/// Build a configuration whose steady-state long frames are quantised by the
/// ported FFmpeg rate control: the 3GPP model (`aac_psy.mbt`, §277) publishes
/// per-band thresholds and the frame's bit allocation, the twoloop search
/// (`aac_twoloop.mbt`, §278) turns them into per-band scalefactors, and lambda
/// is retried until the real frame fits the nominal size.
///
/// This path is **opt-in**. On this project's tonal fixtures it lands several
/// dB below the simplified model in SNR at the same bit rate, and the
/// quantisation noise still exceeds the model's own thresholds on steady
/// frames, so the default stays the path with the measured 30 dB round trip.
/// `PORTING_HISTORY.md` §279 records the measurements and what is still open.
pub fn aac_encode_config_perceptual(
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> AacEncodeConfig {
  {
    sample_rate,
    channels,
    bit_rate,
    perceptual: true,
    pns: false,
    is_stereo: false,
  }
}

///|
/// Enable PNS on a configuration. PNS needs the psy bands and the twoloop
/// search, so it also switches the perceptual rate control on: leaving
/// `perceptual = false` would make `pns = true` a silent no-op.
///
/// This is opt-in: noise bands change both the bitstream layout and the
/// SNR/NMR measurements, so the existing round-trip baselines stay on the
/// PNS-off path.
pub fn aac_encode_config_with_pns(config : AacEncodeConfig) -> AacEncodeConfig {
  {
    sample_rate: config.sample_rate,
    channels: config.channels,
    bit_rate: config.bit_rate,
    perceptual: true,
    pns: true,
    // Since §294 this also keeps intensity stereo on when the caller had
    // enabled it: `aacenc.c` runs `ff_aac_search_for_is` *after*
    // `search_for_pns` and skips the bands that ended up as `NOISE_BT`, which
    // is exactly what `aac_is_search` does with the post-PNS `cb`/`zeroes` it
    // is handed.
    is_stereo: config.is_stereo,
  }
}

///|
/// Enable intensity stereo on a configuration: the high bands of a channel
/// pair are coded as codebook 14/15 bands, whose only payload is an intensity
/// position in the `off_is` differential chain
/// (`encode_scale_factors`), and the decoder rebuilds the right channel by
/// scaling the left one (`apply_intensity_stereo`).
///
/// Which search picks those bands depends on the rate-control path: the
/// perceptual one runs FFmpeg's cost comparison
/// (`aac_is_encoding_err`, §292), the simplified one the correlation gate of
/// §290. On the perceptual path this composes with `pns` (§294), because the
/// cost search already excludes noise and empty bands; on the simplified path
/// PNS never runs at all (it needs the psy bands), so the two cannot collide
/// there either.
///
/// Like PNS, this is opt-in: it rewrites bands of the right channel, so both
/// the bitstream layout and the round-trip measurements differ from the
/// IS-off baselines.
pub fn aac_encode_config_with_is(config : AacEncodeConfig) -> AacEncodeConfig {
  {
    sample_rate: config.sample_rate,
    channels: config.channels,
    bit_rate: config.bit_rate,
    perceptual: config.perceptual,
    pns: config.pns,
    is_stereo: true,
  }
}

///|
/// MPEG-4 sampling_frequency_index for a sample rate (mpeg4audio.c table).
fn aac_encode_sampling_index(rate : Int32) -> Int32 {
  for i = 0; i < mpeg4audio_sample_rates.length(); i = i + 1 {
    if mpeg4audio_sample_rates[i] == rate {
      return i
    }
  }
  -1
}

///|
/// Forward MDCT kernel table: `K[j][t] = cos(pi/1024 * (t + 512.5) * (j + 0.5))`
/// for the 1024 coefficients of a 2048-sample window (`aac_mdct_forward`'s
/// kernel, precomputed because the direct O(N^2) loop is the encoder's hot
/// path).
fn aac_encode_cos_table() -> Array[Double] {
  let out : Array[Double] = Array::make(1024 * 2048, 0.0)
  let base = 3.14159265358979323846 / 1024.0
  for j = 0; j < 1024; j = j + 1 {
    let jf = j.to_double() + 0.5
    for t = 0; t < 2048; t = t + 1 {
      out[j * 2048 + t] = @math.cos(base * (t.to_double() + 512.5) * jf)
    }
  }
  out
}

///|
/// Full sine analysis window of a 128-hop short block (256 samples):
/// `sin(pi/256 * (i + 0.5))` — the rising half is `aac_sine_short`, the falling
/// half its mirror.
fn aac_encode_short_window() -> Array[Double] {
  let out : Array[Double] = Array::make(256, 0.0)
  for i = 0; i < 256; i = i + 1 {
    out[i] = @math.sin(3.14159265358979323846 / 256.0 * (i.to_double() + 0.5))
  }
  out
}

///|
/// Huffman code / code-length tables of codebooks 1..11, indexed by
/// `codebook - 1`.
fn aac_encode_code_tables() -> (Array[Array[UInt32]], Array[Array[Int32]]) {
  let codes : Array[Array[UInt32]] = [
    aac_codes1, aac_codes2, aac_codes3, aac_codes4, aac_codes5, aac_codes6, aac_codes7,
    aac_codes8, aac_codes9, aac_codes10, aac_codes11,
  ]
  let bits : Array[Array[Int32]] = [
    aac_bits1, aac_bits2, aac_bits3, aac_bits4, aac_bits5, aac_bits6, aac_bits7,
    aac_bits8, aac_bits9, aac_bits10, aac_bits11,
  ]
  (codes, bits)
}

///|
/// Reverse map for the packed indices of a codebook whose low 8 bits hold the
/// 2-bit / 4-bit digit tuple (`codebook_vector02_idx`, `codebook_vector4_idx`):
/// the digit tuple alone identifies a row, so the redundant non-zero-count and
/// sign-mask bits above bit 8 are dropped from the key.
fn aac_encode_rev_digits(idx_table : Array[UInt32]) -> Array[Int32] {
  let rev : Array[Int32] = Array::make(256, -1)
  for row = 0; row < idx_table.length(); row = row + 1 {
    rev[idx_table[row].reinterpret_as_int() & 255] = row
  }
  rev
}

///|
/// Reverse map for the unsigned pair codebooks (`codebook_vector6_idx` /
/// `codebook_vector8_idx`): the low 8 bits are the two magnitudes and bits
/// 12..15 hold the one-bit sign-slot shift (set when only the first value is
/// non-zero).
fn aac_encode_rev_pairs(idx_table : Array[UInt32]) -> Array[Int32] {
  let rev : Array[Int32] = Array::make(1024, -1)
  for row = 0; row < idx_table.length(); row = row + 1 {
    let idx = idx_table[row].reinterpret_as_int()
    rev[(idx & 255) | (((idx >> 12) & 1) << 8)] = row
  }
  rev
}

///|
/// Reverse map for codebook 11: the low 8 bits are the two 4-bit magnitudes
/// (0 for an escaped value) and bits 8..9 the escape mask.
fn aac_encode_rev_escape(idx_table : Array[UInt32]) -> Array[Int32] {
  let rev : Array[Int32] = Array::make(1024, -1)
  for row = 0; row < idx_table.length(); row = row + 1 {
    let idx = idx_table[row].reinterpret_as_int()
    rev[(idx & 255) | (((idx >> 8) & 3) << 8)] = row
  }
  rev
}

///|
/// Per-codebook reverse maps, indexed by `codebook - 1`. Codebooks 1..4 share
/// `codebook_vector02_idx` and 5..10 come in pairs sharing one table, so only
/// five distinct maps are built.
fn aac_encode_reverse_tables() -> Array[Array[Int32]] {
  let rev02 = aac_encode_rev_digits(aac_idx_quads02)
  let rev4 = aac_encode_rev_digits(aac_idx_quads4)
  let rev6 = aac_encode_rev_pairs(aac_idx_pairs6)
  let rev8 = aac_encode_rev_pairs(aac_idx_pairs8)
  let rev11 = aac_encode_rev_escape(aac_idx_pairs10)
  [rev02, rev02, rev02, rev02, rev4, rev4, rev6, rev6, rev8, rev8, rev11]
}

///|
/// Create an AAC-LC encoder for `config`. Supports 1 or 2 channels, a standard
/// MPEG-4 sample rate and a positive target bit rate.
pub fn aac_encoder_new(config : AacEncodeConfig) -> Result[AacEncoder, String] {
  if config.channels != 1 && config.channels != 2 {
    return Err("AAC encoder supports 1 or 2 channels")
  }
  if config.bit_rate <= 0 {
    return Err("AAC encoder requires a positive bit rate")
  }
  let sampling_index = aac_encode_sampling_index(config.sample_rate)
  if sampling_index < 0 {
    return Err("unsupported AAC sample rate")
  }
  let num_swb = aac_num_swb_1024[sampling_index]
  let table = aac_swb_offset_1024[sampling_index]
  if table.length() != num_swb + 1 {
    return Err("AAC swb table length mismatch")
  }
  let swb_offsets : Array[Int32] = []
  for i = 0; i < table.length(); i = i + 1 {
    swb_offsets.push(table[i].reinterpret_as_int())
  }
  let num_short_swb = aac_num_swb_128[sampling_index]
  let short_table = aac_swb_offset_128[sampling_index]
  if short_table.length() != num_short_swb + 1 {
    return Err("AAC short swb table length mismatch")
  }
  let short_offsets : Array[Int32] = []
  for i = 0; i < short_table.length(); i = i + 1 {
    short_offsets.push(short_table[i].reinterpret_as_int())
  }
  let history : Array[Array[Double]] = []
  let prev_sequence : Array[Int32] = []
  let attack_pending : Array[Bool] = []
  let win_energy : Array[Double] = []
  for _ch = 0; _ch < config.channels; _ch = _ch + 1 {
    history.push(Array::make(1024, 0.0))
    prev_sequence.push(aac_only_long)
    attack_pending.push(false)
    win_energy.push(0.0)
  }
  // One model per element, like `FFPsyContext`: the bit reservoir and the PE
  // range are shared by the channels, only the band records are per channel.
  let psy = aac_psy_new(
    sampling_index,
    config.sample_rate,
    config.bit_rate,
    config.channels,
  )
  let (spectral_codes, spectral_bits) = aac_encode_code_tables()
  Ok({
    config,
    sampling_index,
    swb_offsets,
    num_swb,
    short_offsets,
    num_short_swb,
    history,
    cos_table: aac_encode_cos_table(),
    short_window: aac_encode_short_window(),
    spectral_codes,
    spectral_bits,
    spectral_rev: aac_encode_reverse_tables(),
    prev_sequence,
    attack_pending,
    win_energy,
    psy,
    last_frame_bits: 0,
    lambda: 120.0,
    pns_random_state: 0,
  })
}

///|
/// Apply the analysis window of `seq` to the 2048-sample overlap buffer.
///
/// Natural time order: ONLY_LONG is a full 2048-point sine window; LONG_START
/// is the long rising half, 448 samples at unit gain, the falling short half
/// and 448 zeros; LONG_STOP is its mirror (the short rising half and the long
/// falling half). The flat 448-sample stretches are what the neighbouring long
/// frame and the eight short blocks overlap, so the transition is TDAC-safe.
fn aac_encode_window(seq : Int32, buf : Array[Double]) -> Array[Double] {
  let win = aac_sine_long
  let swin = aac_sine_short
  let d : Array[Double] = Array::make(2048, 0.0)
  if seq == aac_long_start {
    for i = 0; i < 1024; i = i + 1 {
      d[i] = buf[i] * win[i]
    }
    for i = 0; i < 448; i = i + 1 {
      d[1024 + i] = buf[1024 + i]
    }
    for i = 0; i < 128; i = i + 1 {
      d[1472 + i] = buf[1472 + i] * swin[127 - i]
    }
  } else if seq == aac_long_stop {
    for i = 0; i < 128; i = i + 1 {
      d[448 + i] = buf[448 + i] * swin[i]
    }
    for i = 0; i < 448; i = i + 1 {
      d[576 + i] = buf[576 + i]
    }
    for i = 0; i < 1024; i = i + 1 {
      d[1024 + i] = buf[1024 + i] * win[1023 - i]
    }
  } else {
    for i = 0; i < 1024; i = i + 1 {
      d[i] = buf[i] * win[i]
      d[1024 + i] = buf[1024 + i] * win[1023 - i]
    }
  }
  d
}

///|
/// Analysis coefficients of a frame in the requested window sequence, scaled
/// into the encoder's coefficient domain (`65536 * textbook MDCT`).
///
/// The eight short blocks are 256-sample sine-windowed chunks on a 128-sample
/// hop, anchored 448 samples before the current frame (the `flat` of the
/// decoder's overlap-add), so the last blocks reach 576 samples into the
/// look-ahead part of the overlap buffer.
fn AacEncoder::frame_coefficients(
  self : AacEncoder,
  buf : Array[Double],
  seq : Int32,
) -> Array[Double] {
  let out : Array[Double] = Array::make(1024, 0.0)
  if seq == aac_eight_short {
    let swin = self.short_window
    for w = 0; w < 8; w = w + 1 {
      let slot : Array[Double] = Array::make(256, 0.0)
      for i = 0; i < 256; i = i + 1 {
        slot[i] = buf[448 + w * 128 + i] * swin[i]
      }
      let part = aac_mdct_forward(slot, 256)
      for j = 0; j < 128; j = j + 1 {
        out[w * 128 + j] = part[j] * 65536.0
      }
    }
    return out
  }
  let d = aac_encode_window(seq, buf)
  for j = 0; j < 1024; j = j + 1 {
    let row = j * 2048
    let mut acc = 0.0
    for t = 0; t < 2048; t = t + 1 {
      acc = acc + d[t] * self.cos_table[row + t]
    }
    out[j] = acc * 65536.0
  }
  out
}

///|
/// The spectrum of one 2048-sample overlap buffer exactly as the encoder forms
/// it for a steady long frame (sine window plus the 65536-scaled MDCT kernel).
///
/// Exposed so tests can measure a decoded frame's error in the same domain the
/// psy model and the quantiser use — a noise-to-mask comparison is only
/// meaningful against the thresholds of the original spectrum.
pub fn AacEncoder::spectrum(
  self : AacEncoder,
  buf : Array[Double],
) -> Array[Double] {
  self.frame_coefficients(buf, aac_only_long)
}

///|
/// Attack detector of FFmpeg's `aacpsy.c` `psy_lame_window`: the high-passed
/// energy of each 128-sample subblock is compared with the channel's sliding
/// energy average (`sum2 / 64`, i.e. one eighth of the frame mean, so the
/// ratio 10 corresponds to 1.25x the mean subblock energy). The average is
/// updated after the comparison, so an onset from silence always attacks.
///
/// Returns `(early, late)`: `early` covers the first four subblocks, whose
/// samples a short block of this frame can code, while `late` covers the
/// second half, which only the next frame's short blocks reach (the eight
/// short windows span `buf[448]..buf[1600)`, i.e. the previous frame's second
/// half and the current frame's first 576 samples).
fn AacEncoder::detect_attack(
  self : AacEncoder,
  ch : Int32,
  pcm : Array[Double],
) -> (Bool, Bool) {
  let s : Array[Double] = Array::make(8, 0.0)
  let mut prev = 0.0
  for i = 0; i < 1024; i = i + 1 {
    let v = pcm[i] - prev
    prev = pcm[i]
    s[i / 128] = s[i / 128] + v * v
  }
  let mut sum2 = 0.0
  let mut early = false
  let mut late = false
  for i = 0; i < 8; i = i + 1 {
    sum2 = sum2 + s[i]
    if s[i] > self.win_energy[ch] * 10.0 {
      if i < 4 {
        early = true
      } else {
        late = true
      }
    }
  }
  self.win_energy[ch] = self.win_energy[ch] * 7.0 / 8.0 + sum2 / 64.0
  (early, late)
}

///|
/// Largest quantised magnitude codebook 11 can carry: escape sequences allow
/// up to 8 leading one bits, i.e. a mantissa length of 12, i.e. 8191.
let aac_encode_max_q : Int32 = 8191

///|
/// Absolute threshold of hearing, expressed as the energy of one MDCT
/// coefficient: a full-scale sine peaks near 1.2e7 in the encoder's
/// `65536 * MDCT` scale, a 0 dBFS programme sits around 90 dB SPL, and the
/// threshold in quiet is about 0 dB SPL, so `(1.2e7 * 10^(-90/20))^2`, i.e.
/// -90 dB re full scale.
let aac_encode_ath_energy : Double = 143900.0

///|
/// `tns_min_sfb_long/short` (`aacenctab.h`): the first scalefactor band the
/// TNS analysis may use, per sampling index.
let aac_encode_tns_min_sfb_long : Array[Int32] = [
  12, 13, 15, 16, 17, 20, 25, 26, 24, 28, 30, 31, 31, 31, 31, 31,
]

///|
let aac_encode_tns_min_sfb_short : Array[Int32] = [
  2, 2, 2, 3, 3, 4, 6, 6, 8, 10, 10, 12, 12, 12, 12, 12,
]

///|
/// `ff_tns_max_bands_1024/128` (`aactab.c`): the highest band TNS may reach.
let aac_encode_tns_max_bands_long : Array[Int32] = [
  31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39, 39,
]

///|
let aac_encode_tns_max_bands_short : Array[Int32] = [
  9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
]

///|
/// `ff_tns_tmp2_map_1_4` (`aactab.c`): the 4-bit quantisation alphabet of TNS
/// reflection coefficients. `aacenc_tns.c` quantises every coefficient to the
/// nearest member; the decoder dequantises through the same table.
let aac_encode_tns_quant : Array[Double] = [
  0.00000000, -0.20791170, -0.40673664, -0.58778524, -0.74314481, -0.86602539, -0.95105654,
  -0.99452192, 0.99573416, 0.96182561, 0.89516330, 0.79801720, 0.67369562, 0.52643216,
  0.36124167, 0.18374951,
]

///|
/// `ff_lpc_calc_ref_coefs_f` (`lpc.c`): Welch-window a run of `len`
/// coefficients, take its autocorrelation, and return
/// `(reflection coefficients, LPC gain = signal / average prediction error)`.
/// `aacenc_tns.c` only keeps the filter when this gain sits inside
/// `[1.4, 1.16 * 1.4]`, i.e. when the predictor explains a real amount of the
/// signal but not so much that the residual is already tiny.
fn aac_encode_tns_gain(
  coef : Array[Double],
  start : Int32,
  len : Int32,
  order : Int32,
) -> (Array[Double], Double) {
  let refc : Array[Double] = Array::make(order, 0.0)
  if len < 2 {
    return (refc, 0.0)
  }
  // Weight = 0.5 - 0.5 cos(2 pi i / (len - 1)): a Welch window, mirrored about
  // the centre exactly as the C loop writes the two halves.
  let w : Array[Double] = Array::make(len, 0.0)
  for i = 0; i <= len / 2; i = i + 1 {
    let weight = 0.5 -
      0.5 *
      @math.cos(
        2.0 * 3.14159265358979323846 * i.to_double() / (len - 1).to_double(),
      )
    w[i] = weight * coef[start + i]
    w[len - 1 - i] = weight * coef[start + len - 1 - i]
  }
  let autoc : Array[Double] = Array::make(order + 1, 0.0)
  for k = 0; k <= order; k = k + 1 {
    // The C autocorrelator seeds every lag with 1.0.
    let mut sum = 1.0
    for i = k; i < len; i = i + 1 {
      sum = sum + w[i] * w[i - k]
    }
    autoc[k] = sum
  }
  let (reflection, error) = aac_encode_ref_coefs(autoc, order)
  let mut avg_err = 0.0
  for i = 0; i < order; i = i + 1 {
    avg_err = (avg_err + error[i]) / 2.0
  }
  let gain = if avg_err != 0.0 { autoc[0] / avg_err } else { 0.0 }
  (reflection, gain)
}

///|
/// `compute_ref_coefs` (`lpc.c`): Schur recursion producing reflection
/// coefficients and the residual error of every order from autocorrelation
/// data.
fn aac_encode_ref_coefs(
  autoc : Array[Double],
  order : Int32,
) -> (Array[Double], Array[Double]) {
  let gen0 : Array[Double] = Array::make(order, 0.0)
  let gen1 : Array[Double] = Array::make(order, 0.0)
  for i = 0; i < order; i = i + 1 {
    gen0[i] = autoc[i + 1]
    gen1[i] = autoc[i + 1]
  }
  let refc : Array[Double] = Array::make(order, 0.0)
  let errs : Array[Double] = Array::make(order, 0.0)
  let mut err = autoc[0]
  refc[0] = -gen1[0] / (if err != 0.0 { err } else { 1.0 })
  err = err + gen1[0] * refc[0]
  errs[0] = err
  for i = 1; i < order; i = i + 1 {
    for j = 0; j < order - i; j = j + 1 {
      let next = gen1[j + 1]
      gen1[j] = next + refc[i - 1] * gen0[j]
      gen0[j] = next * refc[i - 1] + gen0[j]
    }
    refc[i] = -gen1[0] / (if err != 0.0 { err } else { 1.0 })
    err = err + gen1[0] * refc[i]
    errs[i] = err
  }
  (refc, errs)
}

///|
/// Levinson-Durbin recursion from quantised reflection coefficients to the
/// predictor coefficients the all-zero filter uses; identical arithmetic to
/// the decoder's `aac_tns_lpc`.
fn aac_encode_tns_lpc(coef : Array[Double], order : Int32) -> Array[Double] {
  let lpc : Array[Double] = Array::make(order, 0.0)
  for i = 0; i < order; i = i + 1 {
    let r = -coef[i]
    lpc[i] = r
    for j = 0; j < (i + 1) / 2; j = j + 1 {
      let f = lpc[j]
      let b = lpc[i - 1 - j]
      lpc[j] = f + r * b
      lpc[i - 1 - j] = b + r * f
    }
  }
  lpc
}

///|
/// One TNS filter of one window (spec 4.6.2.5).
priv struct AacEncTnsFilter {
  length : Int32
  order : Int32
  direction : Int32
  coef_idx : Array[Int32]
  coef : Array[Double]
}

///|
/// Per-channel TNS data. `mmm` is `min(tns_max_bands, max_sfb)` — the band
/// limit both the encoder filter and the decoder's `aac_apply_tns` derive from
/// the bitstream, so it is kept here to make the encoder's filter cover
/// exactly the decoder's band range.
priv struct AacEncTns {
  present : Bool
  mmm : Int32
  n_filt : Array[Int32]
  filters : Array[Array[AacEncTnsFilter]]
}

///|
/// `search_for_pns`-style empty TNS data (no filters on any window).
fn aac_encode_tns_none(num_windows : Int32) -> AacEncTns {
  let n_filt : Array[Int32] = Array::make(num_windows, 0)
  let empty : Array[AacEncTnsFilter] = []
  let filters : Array[Array[AacEncTnsFilter]] = []
  for _w = 0; _w < num_windows; _w = _w + 1 {
    filters.push(empty)
  }
  { present: false, mmm: 0, n_filt, filters, }
}

///|
/// `ff_aac_search_for_tns`: per window, LPC-analyse the upper bands
/// `[sfb_start, sfb_end)` and keep the filter only when the prediction gain
/// falls inside the FFmpeg margins. A long frame uses two filters of order 6
/// (12th order overall), a short frame one filter of order 7; the filters
/// split the band range and run from the top band downwards, which is how
/// `aacenc_tns.c` and the decoder both derive their range from `length`.
fn AacEncoder::search_tns(
  self : AacEncoder,
  coef : Array[Double],
  planned_max_sfb : Int32,
  seq : Int32,
) -> AacEncTns {
  let is8 = seq == aac_eight_short
  let num_swb = if is8 { self.num_short_swb } else { self.num_swb }
  let offsets = if is8 { self.short_offsets } else { self.swb_offsets }
  let num_windows = if is8 { 8 } else { 1 }
  let si = self.sampling_index
  let max_bands = if is8 {
    aac_encode_tns_max_bands_short[si]
  } else {
    aac_encode_tns_max_bands_long[si]
  }
  let mut mmm = planned_max_sfb
  if mmm > max_bands {
    mmm = max_bands
  }
  let mut sfb_start = if is8 {
    aac_encode_tns_min_sfb_short[si]
  } else {
    aac_encode_tns_min_sfb_long[si]
  }
  if sfb_start > mmm {
    sfb_start = mmm
  }
  let mut sfb_end = num_swb
  if sfb_end > mmm {
    sfb_end = mmm
  }
  let sfb_len = sfb_end - sfb_start
  let coef_len = offsets[sfb_end] - offsets[sfb_start]
  if coef_len <= 0 || sfb_len <= 0 {
    return aac_encode_tns_none(num_windows)
  }
  // Long: 12th order split over two filters; short: one 7th-order filter.
  let n_filt = if is8 { 1 } else { 2 }
  let order = if is8 { 7 } else { 12 }
  let filt_order = order / n_filt
  // LONG_START slants the filter forwards, LONG_STOP backwards; the steady
  // sequences pick the direction from the energy of the band halves.
  let slant = if seq == aac_long_stop {
    1
  } else if seq == aac_long_start {
    0
  } else {
    2
  }
  let nfilts : Array[Int32] = Array::make(num_windows, 0)
  let filters : Array[Array[AacEncTnsFilter]] = []
  let mut count = 0
  for w = 0; w < num_windows; w = w + 1 {
    // Energy of the start / middle / end slices of the band range.
    let en : Array[Double] = Array::make(4, 0.0)
    for g = sfb_start; g < sfb_end; g = g + 1 {
      let mut e = 0.0
      for i = w * 128 + offsets[g]; i < w * 128 + offsets[g + 1]; i = i + 1 {
        e = e + coef[i] * coef[i]
      }
      if n_filt == 2 {
        if g > sfb_start + sfb_len / 2 {
          en[1] = en[1] + e
        } else {
          en[0] = en[0] + e
        }
      } else if g > sfb_start + sfb_len / 2 + sfb_len / 4 {
        en[2] = en[2] + e
      } else if g > sfb_start + sfb_len / 2 - sfb_len / 4 {
        en[1] = en[1] + e
      } else {
        en[0] = en[0] + e
      }
    }
    if n_filt == 2 {
      en[2] = en[0]
    } else {
      en[3] = en[0]
    }
    let (refc, gain) = aac_encode_tns_gain(
      coef,
      w * 128 + offsets[sfb_start],
      coef_len,
      order,
    )
    if gain < 1.4 || gain > 1.4 * 1.16 {
      filters.push(aac_encode_tns_none(1).filters[0])
      continue
    }
    let list : Array[AacEncTnsFilter] = []
    let mut oc = 0
    for g = 0; g < n_filt; g = g + 1 {
      let direction = if slant != 2 {
        slant
      } else if en[g] < en[g + 1] {
        1
      } else {
        0
      }
      let idx : Array[Int32] = Array::make(filt_order, 0)
      let qcoef : Array[Double] = Array::make(filt_order, 0.0)
      for k = 0; k < filt_order; k = k + 1 {
        let mut best = 0
        let mut best_err = 1.0e30
        for q = 0; q < 16; q = q + 1 {
          let d = refc[oc + k] - aac_encode_tns_quant[q]
          if d * d < best_err {
            best_err = d * d
            best = q
          }
        }
        idx[k] = best
        qcoef[k] = aac_encode_tns_quant[best]
      }
      oc = oc + filt_order
      list.push({
        length: sfb_len / n_filt,
        order: filt_order,
        direction,
        coef_idx: idx,
        coef: qcoef,
      })
    }
    nfilts[w] = n_filt
    filters.push(list)
    count = count + 1
  }
  { present: count > 0, mmm, n_filt: nfilts, filters, }
}

///|
/// `ff_aac_apply_tns`: the encoder-side all-zero filter, `c[m] += lpc[i] *
/// c_orig[m - i]` applied causally toward `direction` over the range derived
/// from the filter lengths and `mmm`. The original coefficients are read from
/// a copy, so the input to the filter is the unfiltered spectrum — exactly the
/// inverse of the decoder's AR synthesis (`c[m] -= lpc[i] * c[m - i]`).
fn aac_encode_apply_tns(
  coef : Array[Double],
  tns : AacEncTns,
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
) -> Unit {
  if !tns.present {
    return
  }
  let orig = coef.copy()
  for w = 0; w < num_windows; w = w + 1 {
    let mut bottom = num_swb
    for filt = 0; filt < tns.n_filt[w]; filt = filt + 1 {
      let top = bottom
      bottom = top - tns.filters[w][filt].length
      if bottom < 0 {
        bottom = 0
      }
      let order = tns.filters[w][filt].order
      if order == 0 {
        continue
      }
      let lpc = aac_encode_tns_lpc(tns.filters[w][filt].coef, order)
      let b = if bottom < tns.mmm { bottom } else { tns.mmm }
      let t = if top < tns.mmm { top } else { tns.mmm }
      let size = offsets[t] - offsets[b]
      if size <= 0 {
        continue
      }
      let inc = if tns.filters[w][filt].direction != 0 { -1 } else { 1 }
      let mut st = if inc < 0 {
        w * 128 + offsets[t] - 1
      } else {
        w * 128 + offsets[b]
      }
      for m = 0; m < size; m = m + 1 {
        let lim = if m < order { m } else { order }
        for i = 1; i <= lim; i = i + 1 {
          coef[st] = coef[st] + lpc[i - 1] * orig[st - i * inc]
        }
        st = st + inc
      }
    }
  }
}

///|
/// `compress_coeffs` (`aacenc_tns.c`): the quantised indices can be written in
/// one bit less when none of them falls in `[4, 11]`; the two ends of the
/// alphabet then pack into 6 instead of 7 bits.
fn aac_encode_tns_compress(idx : Array[Int32], order : Int32) -> Int32 {
  for i = 0; i < order; i = i + 1 {
    if idx[i] >= 4 && idx[i] <= 11 {
      return 0
    }
  }
  1
}

///|
/// `ff_aac_encode_tns_info`: n_filt per window, then per filter its band
/// `length`, `order`, `direction`, coefficient compression flag and the
/// quantised coefficients.
fn aac_encode_write_tns(
  bw : BitWriter,
  tns : AacEncTns,
  is8 : Bool,
  num_windows : Int32,
) -> Unit {
  let short = if is8 { 1 } else { 0 }
  for w = 0; w < num_windows; w = w + 1 {
    bw.put(tns.n_filt[w].reinterpret_as_uint(), 2 - short)
    if tns.n_filt[w] == 0 {
      continue
    }
    bw.put(1, 1) // coef_res: 4-bit coefficients
    for filt = 0; filt < tns.n_filt[w]; filt = filt + 1 {
      let f = tns.filters[w][filt]
      bw.put(f.length.reinterpret_as_uint(), 6 - 2 * short)
      bw.put(f.order.reinterpret_as_uint(), 5 - 2 * short)
      if f.order == 0 {
        continue
      }
      bw.put(f.direction.reinterpret_as_uint(), 1)
      let compress = aac_encode_tns_compress(f.coef_idx, f.order)
      bw.put(compress.reinterpret_as_uint(), 1)
      // `c_bits` is the 1-bit "4-bit resolution" flag, so the coefficient
      // width is `c_bits + 3 - compress`: four or three bits.
      let coef_len = 1 + 3 - compress
      for k = 0; k < f.order; k = k + 1 {
        let mut v = f.coef_idx[k]
        if compress == 1 && v > 11 {
          v = v - 8
        }
        bw.put(v.reinterpret_as_uint(), coef_len)
      }
    }
  }
}

///|
/// `sum sqrt(|c|)` of band `b` across the windows, the companded-code cost
/// measure of `aac_encode_band_stats`.
fn aac_encode_band_root(
  coef : Array[Double],
  offsets : Array[Int32],
  b : Int32,
  num_windows : Int32,
) -> Double {
  let mut root = 0.0
  for w = 0; w < num_windows; w = w + 1 {
    for i = w * 128 + offsets[b]; i < w * 128 + offsets[b + 1]; i = i + 1 {
      root = root + coef[i].abs().sqrt()
    }
  }
  root
}

///|
/// `INTENSITY_BT2` / `INTENSITY_BT` (`aac.h:74`): the band types whose
/// scalefactors carry intensity stereo positions (14 out of phase, 15 in
/// phase) and which transmit no spectral data at all.
let aac_intensity_bt2 : Int32 = 14

let aac_intensity_bt : Int32 = 15

///|
/// `INT_STEREO_LOW_LIMIT` (`aacenc_is.c:34`): the frequency in Hz below which
/// a band is never coded as intensity, at `lambda == 170`.
let aac_is_low_limit : Double = 6100.0

///|
/// Correlation floor of the simplified intensity decision (see
/// `aac_encode_is_search`).
let aac_is_corr_min : Double = 0.95

///|
/// Round half away from zero, which is what C's `roundf` does.
fn aac_encode_roundf(v : Double) -> Int32 {
  if v >= 0.0 {
    @math.floor(v + 0.5).to_int()
  } else {
    -@math.floor(-v + 0.5).to_int()
  }
}

///|
/// `set_special_band_scalefactors`' intensity branch: the position written to
/// the `off_is` chain is `round(log2(is_ener) * 2)`, clipped to the decoder's
/// `[-155, 100]` and to +/-60 of the previous position so the delta stays in
/// the scalefactor VLC's domain.
fn aac_encode_is_position(ener_ratio : Double, prev : Int32) -> Int32 {
  let raw = aac_encode_roundf(2.0 * @math.log2(ener_ratio))
  let mut v = raw
  if v < -155 {
    v = -155
  } else if v > 100 {
    v = 100
  }
  if v < prev - 60 {
    v = prev - 60
  } else if v > prev + 60 {
    v = prev + 60
  }
  v
}

///|
/// Simplified `ff_aac_search_for_is`, folded together with the intensity part
/// of `set_special_band_scalefactors`. For every band above the frequency gate
/// `start * freq_mult > INT_STEREO_LOW_LIMIT * (lambda / 170)` whose left and
/// right spectra are strongly correlated, it picks the phase whose sum carries
/// more energy, prices the intensity position
/// `round(2 * log2(ener0 / ener1))` - clipped to `[-155, 100]` and to +/-60 of
/// the previous position, exactly the chain the `off_is` bitstream replays -
/// and reports `sqrt(ener0 / ener01)`, the scale that makes the intensity sum
/// energy-matched to the left channel.
///
/// FFmpeg instead runs `aac_is_encoding_err`, which quantises `L`, `R` and the
/// IS'd sum through the twoloop cost function under each band's masking
/// threshold and keeps the cheaper phase. Since §291 the perceptual path has
/// that order - analyse and price the left/right spectra, then mix - so the
/// cost test is within reach; this version still uses the correlation floor,
/// and the simplified path analyses the already-mixed pair (deviation 1 of
/// §289, kept because its per-band scalefactor is derived from the spectrum
/// that actually gets coded).
///
/// The correlation floor stands in for that cost test: the right band is
/// rebuilt as `(p*L + R) * m` with `m = sqrt(ener1 / ener01)`, so its error
/// energy is `2*ener1 - 2*m*(|cross| + ener1)`, which for two equally strong
/// channels is `ener1 * (2 - sqrt(2 * (1 + |rho|)))` - 2.5% of the right
/// channel's energy at `|rho| = 0.95` and zero at `|rho| = 1` - and the
/// frequency gate keeps intensity out of the bands where stereo imaging is
/// audible.
fn aac_encode_is_search(
  left : Array[Double],
  right : Array[Double],
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
  sample_rate : Int32,
  lambda : Double,
) -> (Array[Int32], Array[Int32], Array[Double]) {
  let bt : Array[Int32] = Array::make(num_swb, 0)
  let pos : Array[Int32] = Array::make(num_swb, 0)
  let scale : Array[Double] = Array::make(num_swb, 0.0)
  // One bin of a 1024/num_windows-point spectrum, in Hz.
  let freq_mult =
    sample_rate.to_double() / (1024.0 / num_windows.to_double()) / 2.0
  let limit = aac_is_low_limit * (lambda / 170.0)
  let mut prev = 0
  for b = 0; b < num_swb; b = b + 1 {
    let start = offsets[b]
    let end = offsets[b + 1]
    if end <= start || start.to_double() * freq_mult <= limit {
      continue
    }
    let mut ener0 = 0.0
    let mut ener1 = 0.0
    let mut cross = 0.0
    for w = 0; w < num_windows; w = w + 1 {
      for i = w * 128 + start; i < w * 128 + end; i = i + 1 {
        ener0 = ener0 + left[i] * left[i]
        ener1 = ener1 + right[i] * right[i]
        cross = cross + left[i] * right[i]
      }
    }
    if ener0 <= 0.0 || ener1 <= 0.0 {
      continue
    }
    if cross.abs() < aac_is_corr_min * (ener0 * ener1).sqrt() {
      continue
    }
    // `ener01` of the phase that was picked: `L + R` when the channels agree,
    // `L - R` when they are inverted.
    let sum = ener0 + ener1 + 2.0 * cross.abs()
    let v = aac_encode_is_position(ener0 / ener1, prev)
    bt[b] = if cross >= 0.0 { aac_intensity_bt } else { aac_intensity_bt2 }
    pos[b] = v
    scale[b] = (ener0 / sum).sqrt()
    prev = v
  }
  (bt, pos, scale)
}

///|
/// Mark the right channel's intensity bands after quantisation: their codebook
/// becomes 14/15 and their scalefactor becomes the intensity position, which
/// takes them out of the regular differential chain, out of `section_data`'s
/// spectral coding, and into the `off_is` chain.
fn aac_encode_mark_is(
  ch : AacEncChannel,
  bt : Array[Int32],
  pos : Array[Int32],
) -> Unit {
  for b = 0; b < ch.max_sfb && b < bt.length(); b = b + 1 {
    if bt[b] != 0 {
      ch.cb[b] = bt[b]
      ch.sf[b] = pos[b]
    }
  }
}

///|
/// The simplified path's mid/side mask, standing in for `search_for_ms`: a band
/// switches when the companded alphabet of `M = (L + R) / 2` and
/// `S = (L - R) / 2` is smaller than that of `L` and `R` (the quantiser then
/// spends fewer bits for the same error). It cannot be the real search on this
/// path: `aac_ms_search` prices a band with twoloop's `sf_idx`/`band_type` and
/// the psy thresholds, and the simplified model derives its scalefactor from the
/// spectrum after the mix, so at decision time it has neither.
fn aac_encode_ms_mask(
  left : Array[Double],
  right : Array[Double],
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
) -> Array[Bool] {
  let mask : Array[Bool] = Array::make(num_swb, false)
  for b = 0; b < num_swb; b = b + 1 {
    let rl = aac_encode_band_root(left, offsets, b, num_windows)
    let rr = aac_encode_band_root(right, offsets, b, num_windows)
    if rl + rr <= 0.0 {
      continue
    }
    let mut rm = 0.0
    let mut rs = 0.0
    for w = 0; w < num_windows; w = w + 1 {
      for i = w * 128 + offsets[b]; i < w * 128 + offsets[b + 1]; i = i + 1 {
        rm = rm + ((left[i] + right[i]) * 0.5).abs().sqrt()
        rs = rs + ((left[i] - right[i]) * 0.5).abs().sqrt()
      }
    }
    // Require a clear win, not a tie: switching bands with almost equal cost
    // only spreads quantisation noise of the pair across both channels.
    mask[b] = rm + rs < 0.9 * (rl + rr)
  }
  mask
}

///|
/// `apply_mid_side_stereo`: on the masked bands replace `(L, R)` by
/// `M = (L + R) * 0.5`, `S = M - R`; the decoder's inverse is `L = M + S`,
/// `R = M - S`, so the factor 0.5 is what makes the pair an isometry. The side
/// is written as `M - R` rather than `(L - R) * 0.5` because that is the
/// expression upstream evaluates - the two differ in the last bit, and the
/// mid/side search priced the band with `M - R`.
fn aac_encode_apply_ms(
  left : Array[Double],
  right : Array[Double],
  offsets : Array[Int32],
  num_swb : Int32,
  mask : Array[Bool],
  num_windows : Int32,
) -> Unit {
  for b = 0; b < num_swb; b = b + 1 {
    if !mask[b] {
      continue
    }
    for w = 0; w < num_windows; w = w + 1 {
      for i = w * 128 + offsets[b]; i < w * 128 + offsets[b + 1]; i = i + 1 {
        let m = (left[i] + right[i]) * 0.5
        right[i] = m - right[i]
        left[i] = m
      }
    }
  }
}

///|
/// The stereo tools of one frame: the `ms_present`/`ms_mask` pair that
/// `assemble_frame` writes and the intensity bands that
/// `aac_encode_mark_is` stamps onto the right channel. Both are re-decided on
/// every rate-control iteration, because which bands end up as noise depends
/// on lambda and a noise band must not be mid/side mixed.
priv struct AacEncStereo {
  mut ms_present : Int32
  ms_mask : Array[Bool]
  is_bt : Array[Int32]
  is_pos : Array[Int32]
}

///|
/// A mono (or tool-free) frame: nothing mixed, no intensity bands.
fn aac_encode_stereo_none(num_swb : Int32) -> AacEncStereo {
  {
    ms_present: 0,
    ms_mask: Array::make(num_swb, false),
    is_bt: Array::make(num_swb, 0),
    is_pos: Array::make(num_swb, 0),
  }
}

///|
/// The simplified path's stereo tools, in `aacenc.c`'s order: intensity first
/// (`apply_intensity_stereo`), then mid/side (`apply_mid_side_stereo`); the
/// perceptual path uses `aac_encode_stereo_psy`, whose mid/side decision is the
/// ported `search_for_ms`. Two exclusions are copied from upstream: a band
/// coded as intensity leaves the
/// mid/side mask (`search_for_ms` does that with `if (!is_mask) ms_mask = 0`),
/// and so does a band either channel codes as `NOISE_BT` - which is what
/// `apply_mid_side_stereo`'s own `band_type >= NOISE_BT` guard is for, because
/// the decoder's `aac_apply_stereo` skips both kinds when it undoes the mix.
/// `left` and `right` are rewritten in place, so the caller hands the spectra
/// the *quantiser* is to code, not the ones the analysis is reading.
fn aac_encode_stereo(
  left : Array[Double],
  right : Array[Double],
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
  sample_rate : Int32,
  lambda : Double,
  use_is : Bool,
  noise : Array[Int32],
) -> AacEncStereo {
  let (bt, pos, scale) = if use_is {
    aac_encode_is_search(
      left,
      right,
      offsets,
      num_swb,
      num_windows,
      sample_rate,
      lambda,
    )
  } else {
    (
      Array::make(num_swb, 0),
      Array::make(num_swb, 0),
      Array::make(num_swb, 0.0),
    )
  }
  let mask = aac_encode_ms_mask(left, right, offsets, num_swb, num_windows)
  let ms_mask : Array[Bool] = Array::make(num_swb, false)
  for b = 0; b < num_swb; b = b + 1 {
    ms_mask[b] = mask[b] && bt[b] == 0 && noise[b] == 0
  }
  if use_is {
    aac_is_apply(
      left,
      right,
      offsets,
      num_swb,
      num_windows,
      bt,
      Array::make(num_swb, false),
      scale,
    )
  }
  aac_encode_apply_ms(left, right, offsets, num_swb, ms_mask, num_windows)
  { ms_present: 0, ms_mask, is_bt: bt, is_pos: pos }
}

///|
/// The perceptual path's stereo stage, in `aacenc.c:983-995`'s order:
/// `search_for_is` (only when intensity stereo is on) and its mix, then
/// `search_for_ms` on the mixed pair, then `apply_mid_side_stereo`. The
/// mid/side search *rewrites* both channels' scalefactor and band type on the
/// bands it picks, so the caller must quantise and write what it returns, not
/// what twoloop left behind - which is also why it runs on every rate-control
/// iteration.
/// A flip band - the case `search_for_is` answers by setting `ms_mask` and
/// picking the other band type - keeps its mid/side bit in the bitstream so the
/// decoder can negate that band's reconstructed right channel, but is still not
/// mixed: `apply_mid_side_stereo` skips every band with `is_mask` set, flips
/// included, and every band either channel codes as `NOISE_BT`.
fn aac_encode_stereo_psy(
  work : Array[Array[Double]],
  band_sizes : Array[Int32],
  thr : Array[Array[Double]],
  twos : Array[AacTwoResult],
  cbs : Array[Array[Int32]],
  zeros : Array[Array[Int32]],
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
  sample_rate : Int32,
  lambda : Double,
  use_is : Bool,
) -> (AacEncStereo, AacMsOut) {
  let no_mask : Array[Int32] = Array::make(num_swb, 0)
  let (is_mask, bt, pos, scale, flip_in) = if use_is {
    let isr = aac_is_search(
      aac_is_in(
        work[0],
        work[1],
        band_sizes,
        thr[0],
        thr[1],
        twos[0].sf,
        twos[1].sf,
        cbs[0],
        cbs[1],
        zeros[0],
        zeros[1],
        num_swb,
      ),
      sample_rate,
      lambda,
    )
    let pos : Array[Int32] = Array::make(num_swb, 0)
    let mut prev = 0
    for b = 0; b < num_swb; b = b + 1 {
      if isr.is_mask[b] == 1 {
        pos[b] = aac_encode_is_position(isr.is_ener1[b], prev)
        prev = pos[b]
      }
    }
    (isr.is_mask, isr.band_type1, pos, isr.is_ener0, isr.ms_mask)
  } else {
    (
      no_mask.copy(),
      no_mask.copy(),
      no_mask.copy(),
      Array::make(num_swb, 0.0),
      no_mask.copy(),
    )
  }
  let flip : Array[Bool] = Array::make(num_swb, false)
  for b = 0; b < num_swb; b = b + 1 {
    flip[b] = flip_in[b] == 1
  }
  aac_is_apply(work[0], work[1], offsets, num_swb, num_windows, bt, flip, scale)
  // The right channel's band type already reads 14/15 on the intensity bands,
  // and `search_for_ms` must see that: `ff_init_nextband_map` skips those
  // entries, which is what keeps the scalefactor-delta chain it tests
  // consistent with the one the bitstream will carry.
  let cb1 : Array[Int32] = Array::make(num_swb, 0)
  for b = 0; b < num_swb; b = b + 1 {
    cb1[b] = if is_mask[b] == 1 { bt[b] } else { cbs[1][b] }
  }
  let ms = aac_ms_search(
    aac_ms_in(
      work[0],
      work[1],
      band_sizes,
      thr[0],
      thr[1],
      twos[0].sf,
      twos[1].sf,
      cbs[0],
      cb1,
      zeros[0],
      zeros[1],
      is_mask,
      flip_in,
      num_swb,
    ),
    lambda,
  )
  let ms_mask : Array[Bool] = Array::make(num_swb, false)
  let apply_mask : Array[Bool] = Array::make(num_swb, false)
  for b = 0; b < num_swb; b = b + 1 {
    ms_mask[b] = ms.ms_mask[b] == 1
    apply_mask[b] =
      ms_mask[b] &&
        is_mask[b] == 0 &&
        ms.cb0[b] < 13 &&
        ms.cb1[b] < 13
  }
  aac_encode_apply_ms(
    work[0],
    work[1],
    offsets,
    num_swb,
    apply_mask,
    num_windows,
  )
  (
    { ms_present: 0, ms_mask, is_bt: bt, is_pos: pos },
    ms,
  )
}

///|
/// Per-band power and `sum sqrt(|c|)` of a channel's spectrum.
///
/// With the companded AAC quantiser a coefficient of magnitude `c` quantised
/// at `step = 2^((sf-100)/4)` has an amplitude error of about
/// `(4/3) u c^(1/4) step^(3/4)` with `u` uniform in `[0,1)`, i.e. an expected
/// error energy of `(16/27) step^(3/2) sqrt(c)`. The band's total error is
/// therefore proportional to `sum sqrt(|c|)`, which is what the model below
/// turns into a scalefactor.
fn aac_encode_band_stats(
  coef : Array[Double],
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
) -> (Array[Double], Array[Double]) {
  let energy : Array[Double] = Array::make(num_swb, 0.0)
  let root : Array[Double] = Array::make(num_swb, 0.0)
  for b = 0; b < num_swb; b = b + 1 {
    for w = 0; w < num_windows; w = w + 1 {
      for i = w * 128 + offsets[b]; i < w * 128 + offsets[b + 1]; i = i + 1 {
        let c = coef[i].abs()
        energy[b] = energy[b] + c * c
        root[b] = root[b] + c.sqrt()
      }
    }
  }
  (energy, root)
}

///|
/// Simplified psychoacoustic model: one target scalefactor per band, or `-1`
/// for a silent or all-zero spectrum.
///
/// The masking threshold of band `b` is its own power plus the upspread
/// contribution of the two bands below it; the 0.3 / 0.09 factors approximate
/// the 15 dB/Bark threshold spreading of 3GPP TS 26.403 for one-third-octave
/// bands (and deliberately ignore the weaker downward spread). The quantiser
/// noise is aimed a frequency-dependent SNR below that threshold: 18 dB up to
/// 3 kHz, falling 10 dB per decade towards a 6 dB floor, which buys coarse
/// high bands where the ear is less sensitive.
///
/// Two more floors model the threshold in quiet:
///   * an absolute one at -90 dB re a full-scale sine (`aac_encode_ath_energy`
///     per coefficient), and
///   * a programme-relative one 20 dB below the loudest band, so bands that
///     contribute nothing to the programme are quantised away instead of
///     eating the frame budget.
///
/// Scalefactors are absolute (not yet shifted by the frame-wide rate-control
/// offset), so a frame can compute them once and then only offset them.
fn AacEncoder::band_targets(
  self : AacEncoder,
  coef : Array[Double],
  seq : Int32,
) -> Array[Int32] {
  let is8 = seq == aac_eight_short
  let num_swb = if is8 { self.num_short_swb } else { self.num_swb }
  let offsets = if is8 { self.short_offsets } else { self.swb_offsets }
  let num_windows = if is8 { 8 } else { 1 }
  let (energy, root) = aac_encode_band_stats(
    coef, offsets, num_swb, num_windows,
  )
  let sf : Array[Int32] = Array::make(num_swb, -1)
  let mut peak = 0.0
  for b = 0; b < num_swb; b = b + 1 {
    if energy[b] > peak {
      peak = energy[b]
    }
  }
  if peak <= 0.0 {
    return sf
  }
  let relative_floor = peak * 1.0e-2 // -20 dB
  // Spectral width of one window of the current sequence: the short swb
  // offsets span 128 bins, the long ones 1024.
  let block = if is8 { 128.0 } else { 1024.0 }
  for b = 0; b < num_swb; b = b + 1 {
    let mut mask = energy[b]
    if b > 0 {
      mask = mask + 0.3 * energy[b - 1]
    }
    if b > 1 {
      mask = mask + 0.09 * energy[b - 2]
    }
    let centre = (offsets[b] + offsets[b + 1]).to_double() / 2.0
    let freq = centre / block * self.config.sample_rate.to_double()
    let mut snr = 18.0
    if freq > 3000.0 {
      snr = 18.0 - 10.0 * @math.log10(freq / 3000.0)
    }
    if snr < 6.0 {
      snr = 6.0
    }
    let mut allowed = mask * @math.pow(10.0, -snr / 10.0)
    let quiet = aac_encode_ath_energy *
      (offsets[b + 1] - offsets[b]).to_double() *
      num_windows.to_double()
    if allowed < quiet {
      allowed = quiet
    }
    if allowed < relative_floor {
      allowed = relative_floor
    }
    if root[b] > 0.0 && allowed > 0.0 {
      let step = @math.pow(allowed * 27.0 / (16.0 * root[b]), 2.0 / 3.0)
      let mut v = @math.floor(100.0 + 4.0 * @math.log2(step) + 0.5).to_int()
      if v < 0 {
        v = 0
      } else if v > 255 {
        v = 255
      }
      sf[b] = v
    }
  }
  sf
}

///|
/// Quantise one scalefactor band (of `num_windows` 128-bin segments):
/// `q = sign(c) * floor((|c| * 2^(-(s-100)/4))^(3/4) + 0.405)`, clamped to
/// `aac_encode_max_q` (the escape limit of codebook 11). `s < 0` zeroes the
/// band.
fn aac_encode_quantize_band(
  q : Array[Int32],
  coef : Array[Double],
  start : Int32,
  end : Int32,
  num_windows : Int32,
  s : Int32,
) -> Unit {
  let step = if s < 0 {
    0.0
  } else {
    @math.pow(2.0, -(s - 100).to_double() / 4.0)
  }
  for w = 0; w < num_windows; w = w + 1 {
    for i = w * 128 + start; i < w * 128 + end; i = i + 1 {
      let mut n = 0
      if s >= 0 {
        let a = coef[i].abs() * step
        // Clamp in the real domain before converting: coarse scalefactors can
        // push `a^(3/4)` far past Int's range (the rate-control search visits
        // them).
        if a > 0.0 {
          let p = @math.pow(a, 0.75) + 0.405
          n = if p >= aac_encode_max_q.to_double() {
            aac_encode_max_q
          } else {
            p.to_int()
          }
        }
      }
      q[i] = if coef[i] < 0.0 && n > 0 { -n } else { n }
    }
  }
}

///|
/// One channel's quantised spectrum, its per-band scalefactors and the
/// codebook chosen for each band (0 for a zero band).
priv struct AacEncChannel {
  sf : Array[Int32]
  cb : Array[Int32]
  q : Array[Int32]
  max_sfb : Int32
  window_sequence : Int32
  num_windows : Int32
}

///|
fn aac_encode_abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// Packed vector key of the tuple starting at `i`, in the same bit layout as
/// `ff_aac_codebook_vector_idx` (see `aac_encode_reverse_tables`).
fn aac_encode_tuple_key(cb : Int32, q : Array[Int32], i : Int32) -> Int32 {
  if cb <= 4 {
    // 4-tuple, 2 bits per value: books 1/2 store the signed value as `v + 1`
    // (the sign lives inside the Huffman symbol), books 3/4 the magnitude.
    let mut key = 0
    for j = 0; j < 4; j = j + 1 {
      let v = q[i + j]
      let d = if cb <= 2 { v + 1 } else { aac_encode_abs(v) }
      key = key | ((d & 3) << (j * 2))
    }
    key
  } else if cb <= 6 {
    // Signed pair: digit = value + 4.
    (q[i] + 4) | ((q[i + 1] + 4) << 4)
  } else if cb <= 10 {
    // Unsigned pair: magnitudes plus the one-bit sign-slot shift used when
    // only the first value is non-zero.
    let a0 = aac_encode_abs(q[i])
    let a1 = aac_encode_abs(q[i + 1])
    a0 | (a1 << 4) | ((if a0 != 0 && a1 == 0 { 1 } else { 0 }) << 8)
  } else {
    // Codebook 11: escaped magnitudes are stored as 0 and marked in bits 8..9.
    let a0 = aac_encode_abs(q[i])
    let a1 = aac_encode_abs(q[i + 1])
    let nzt = (if a0 >= 16 { 1 } else { 0 }) | (if a1 >= 16 { 2 } else { 0 })
    (if a0 >= 16 { 0 } else { a0 }) |
    ((if a1 >= 16 { 0 } else { a1 }) << 4) |
    (nzt << 8)
  }
}

///|
/// Number of separate sign bits of the tuple (zero for codebooks 1/2 and 5/6,
/// which carry the sign inside the Huffman symbol).
fn aac_encode_tuple_signs(cb : Int32, q : Array[Int32], i : Int32) -> Int32 {
  if cb <= 2 || (cb >= 5 && cb <= 6) {
    0
  } else {
    let dim = if cb <= 4 { 4 } else { 2 }
    let mut n = 0
    for j = 0; j < dim; j = j + 1 {
      if q[i + j] != 0 {
        n = n + 1
      }
    }
    n
  }
}

///|
/// Bits spent by a codebook 11 escape sequence for magnitude `v >= 16`:
/// `(len - 4)` one bits, a terminating zero and `len` mantissa bits.
fn aac_encode_escape_bits(v : Int32) -> Int32 {
  let mut len = 0
  let mut t = v
  while t > 1 {
    t = t >> 1
    len = len + 1
  }
  len - 4 + 1 + len
}

///|
/// Bits needed to code `[start, end)` of each of the `num_windows` windows
/// with codebook `cb`, or `-1` when the codebook cannot represent the band
/// (tuple size or magnitude limit). For EIGHT_SHORT the band's segment is
/// coded once per window of the (single) scale-factor group, at a 128-sample
/// window stride.
fn aac_encode_band_cost(
  cb : Int32,
  q : Array[Int32],
  start : Int32,
  end : Int32,
  rev : Array[Int32],
  bits : Array[Int32],
  num_windows : Int32,
) -> Int32 {
  let dim = if cb <= 4 { 4 } else { 2 }
  if (end - start) % dim != 0 {
    return -1
  }
  let mut cost = 0
  for w = 0; w < num_windows; w = w + 1 {
    let base = w * 128
    let mut i = base + start
    let stop = base + end
    while i < stop {
      let row = rev[aac_encode_tuple_key(cb, q, i)]
      if row < 0 {
        return -1
      }
      cost = cost + bits[row] + aac_encode_tuple_signs(cb, q, i)
      if cb == 11 {
        let a0 = aac_encode_abs(q[i])
        let a1 = aac_encode_abs(q[i + 1])
        if a0 >= 16 {
          cost = cost + aac_encode_escape_bits(a0)
        }
        if a1 >= 16 {
          cost = cost + aac_encode_escape_bits(a1)
        }
      }
      i = i + dim
    }
  }
  cost
}

///|
/// Cheapest codebook able to code the band `[start, end)` whose largest
/// magnitude is `magnitude`. The magnitude limits mirror AAC's codebook
/// ranges: 1/2 -> 1, 3/4 -> 2, 5/6 -> 4, 7/8 -> 7, 9/10 -> 12, 11 -> escape.
fn AacEncoder::select_band_cb(
  self : AacEncoder,
  q : Array[Int32],
  start : Int32,
  end : Int32,
  magnitude : Int32,
  num_windows : Int32,
) -> Int32 {
  let limits : Array[Int32] = [1, 1, 2, 2, 4, 4, 7, 7, 12, 12, aac_encode_max_q]
  let mut best = 11
  let mut best_cost = 1 << 30
  for cb = 1; cb <= 11; cb = cb + 1 {
    if magnitude <= limits[cb - 1] {
      let cost = aac_encode_band_cost(
        cb,
        q,
        start,
        end,
        self.spectral_rev[cb - 1],
        self.spectral_bits[cb - 1],
        num_windows,
      )
      if cost >= 0 && cost < best_cost {
        best_cost = cost
        best = cb
      }
    }
  }
  best
}

///|
/// Build one channel's quantised spectrum from the model's per-band
/// scalefactors shifted by the frame-wide rate-control offset `delta`.
///
/// A band is quantised at `target[b] + delta`, clamped to 0..255 and to
/// ±60 around the previous *coded* band's scalefactor: the differential
/// scalefactor syntax cannot express a larger step, and the clamp has to
/// happen before quantisation so the decoder's dequantiser reproduces the
/// encoder's spectrum. Bands whose quantisation yields all zeros are coded
/// with codebook 0 (no scalefactor, no data), so they do not advance the
/// differential chain. The remaining bands use the cheapest codebook that
/// can represent them. A short frame's 8 windows form one scale-factor group:
/// each band's scalefactor and codebook are chosen over all eight windows.
fn AacEncoder::channel_data(
  self : AacEncoder,
  coef : Array[Double],
  target : Array[Int32],
  delta : Int32,
  seq : Int32,
  min_max_sfb : Int32,
) -> AacEncChannel {
  let is8 = seq == aac_eight_short
  let num_swb = if is8 { self.num_short_swb } else { self.num_swb }
  let offsets = if is8 { self.short_offsets } else { self.swb_offsets }
  let num_windows = if is8 { 8 } else { 1 }
  let sf : Array[Int32] = Array::make(num_swb, -1)
  let cb : Array[Int32] = Array::make(num_swb, 0)
  let q : Array[Int32] = Array::make(1024, 0)
  let mut max_sfb = 0
  // Scalefactor of the last coded band; the first coded band's value becomes
  // `global_gain` and the ±60 window only applies from the second one on.
  let mut prev = -1000
  for b = 0; b < num_swb; b = b + 1 {
    if target[b] < 0 {
      continue
    }
    let mut v = target[b] + delta
    if v < 0 {
      v = 0
    } else if v > 255 {
      v = 255
    }
    if prev > -1000 {
      if v < prev - 60 {
        v = prev - 60
      } else if v > prev + 60 {
        v = prev + 60
      }
    }
    let start = offsets[b]
    let end = offsets[b + 1]
    aac_encode_quantize_band(q, coef, start, end, num_windows, v)
    let mut magnitude = 0
    for w = 0; w < num_windows; w = w + 1 {
      for i = w * 128 + start; i < w * 128 + end; i = i + 1 {
        let a = aac_encode_abs(q[i])
        if a > magnitude {
          magnitude = a
        }
      }
    }
    if magnitude > 0 {
      sf[b] = v
      prev = v
      max_sfb = b + 1
      cb[b] = self.select_band_cb(q, start, end, magnitude, num_windows)
    }
  }
  // A common-window CPE shares `max_sfb` between both channels and TNS derives
  // its band range from it; pad with zero bands up to the planned value so the
  // decoder's `aac_apply_tns` sees exactly the encoder's region.
  if max_sfb < min_max_sfb {
    max_sfb = min_max_sfb
  }
  { sf, cb, q, max_sfb, window_sequence: seq, num_windows, }
}

///|
/// One channel of a steady-state long frame, quantised by the twoloop search.
///
/// The search reports `sf` in FFmpeg's internal scale, where the quantiser
/// step is `Q = 2^((104-sf)/4)` (`aaccoder.c:83`), while this module writes
/// the bitstream scale `q = floor((|c| * 2^(-(s-100)/4))^(3/4) + 0.405)` that
/// `aac_encode_quantize_band` and the decoder share. The two agree for
/// `s = sf - 4`.
///
/// The spectrum is re-quantised band by band with the exact f32 path the cost
/// function used (`aac_twoloop_quantize_band`), so the coefficients written
/// are the ones the search priced. `max_sfb` is the frame's planned value: a
/// common-window CPE shares it and TNS derives its band range from it, so both
/// the transmitted value and the decoder's `aac_apply_tns` must see the same
/// number.
fn AacEncoder::channel_data_psy(
  self : AacEncoder,
  coef : Array[Double],
  final_sf : Array[Int32],
  seq : Int32,
  max_sfb : Int32,
  final_cb : Array[Int32],
  final_zeroes : Array[Int32],
  noise_sfi : Array[Int32],
) -> AacEncChannel {
  let num_swb = final_sf.length()
  let sf : Array[Int32] = Array::make(num_swb, -1)
  let cb : Array[Int32] = Array::make(num_swb, 0)
  let q : Array[Int32] = Array::make(1024, 0)
  for b = 0; b < num_swb && b < max_sfb; b = b + 1 {
    // A band reaches here only if it is coded at all: codebooks 1..11 carry
    // spectral data and `NOISE_BT` carries a scalefactor for the noise the
    // decoder synthesises. The intensity band types (14/15), which
    // `search_for_ms` leaves in the right channel's band type where intensity
    // claimed the band, carry neither.
    let coded = aac_encode_band_has_data(final_cb[b]) || final_cb[b] == 13
    if final_zeroes[b] != 0 || final_sf[b] < 0 || !coded {
      continue
    }
    let start = self.swb_offsets[b]
    let size = self.swb_offsets[b + 1] - start
    let noise = final_cb[b] == 13
    if !noise {
      let band = aac_twoloop_quantize_band(
        coef, start, size, final_sf[b], final_cb[b],
      )
      for i = 0; i < size; i = i + 1 {
        q[start + i] = band[i]
      }
    }
    // A NOISE_BT band carries no spectral data: the decoder synthesises it
    // and scales it with `pow2sf_tab[sfo + POW_SF2_ZERO]`. `search_for_pns`
    // already computed the scalefactor whose entry equals the generated
    // noise amplitude (`noise_amp = -pow2sf_tab[sfi + POW_SF2_ZERO]`), so
    // write that `sfi` into the independent noise chain. The regular chain
    // instead uses `final_sf - 4`, whose decoded `sfo` is 100 lower.
    sf[b] = if noise { noise_sfi[b] } else { final_sf[b] - 4 }
    cb[b] = final_cb[b]
  }
  { sf, cb, q, max_sfb, window_sequence: seq, num_windows: 1 }
}

///|
/// Band types that transmit neither a scalefactor delta nor spectral data:
/// ZERO_BT (0) bands are not coded at all, NOISE_BT (13) bands are synthesised
/// by the decoder, and the intensity bands (14/15) are rebuilt from the other
/// channel. Only 1..11 reach the Huffman writer.
fn aac_encode_band_has_data(cb : Int32) -> Bool {
  cb >= 1 && cb <= 11
}

///|
/// Global gain: the first band with real spectral content's scalefactor (or
/// 100 when silent). Intensity bands are skipped: their `sf` is an `off_is`
/// position, not a scalefactor.
fn aac_encode_global_gain(ch : AacEncChannel) -> Int32 {
  for b = 0; b < ch.max_sfb; b = b + 1 {
    if aac_encode_band_has_data(ch.cb[b]) {
      return ch.sf[b]
    }
  }
  100
}

///|
/// section_data: group runs of equal band type (0 = zero band). Short frames
/// use 3-bit section lengths with a 7-value escape instead of the long frames'
/// 5-bit lengths (35.3 in ISO/IEC 14496-3).
fn aac_encode_write_sections(bw : BitWriter, ch : AacEncChannel) -> Unit {
  let bits = if ch.window_sequence == aac_eight_short { 3 } else { 5 }
  let escape = (1 << bits) - 1
  let mut b = 0
  while b < ch.max_sfb {
    let cb = ch.cb[b]
    let mut e = b + 1
    while e < ch.max_sfb && ch.cb[e] == cb {
      e = e + 1
    }
    bw.put(cb.reinterpret_as_uint(), 4)
    let mut len = e - b
    while len >= escape {
      bw.put(escape.reinterpret_as_uint(), bits)
      len = len - escape
    }
    bw.put(len.reinterpret_as_uint(), bits)
    b = e
  }
}

///|
/// scale_factor_data: differential Huffman coding (60 = zero delta).
fn aac_encode_write_scalefactors(
  bw : BitWriter,
  ch : AacEncChannel,
  global_gain : Int32,
) -> Unit {
  // `encode_scale_factors` (`aacenc.c`): regular, noise and intensity bands
  // run on three independent differential chains. The noise chain starts 90
  // below the global gain and its first band carries a raw 9-bit preamble
  // instead of a Huffman delta (`NOISE_PRE = 256`). The intensity chain starts
  // at 0, advances only on bands coded as 14/15, and its value is an
  // `off_is` position rather than a scalefactor, so it must be told apart by
  // codebook: a position is negative as often as not.
  let mut off_sf = global_gain
  let mut off_pns = global_gain - aac_noise_offset
  let mut off_is = 0
  let mut noise_flag = true
  for b = 0; b < ch.max_sfb; b = b + 1 {
    let cb = ch.cb[b]
    if cb == aac_intensity_bt2 || cb == aac_intensity_bt {
      let d = ch.sf[b] - off_is + 60
      off_is = ch.sf[b]
      bw.put(aac_scalefactor_code[d], aac_scalefactor_bits[d])
      continue
    }
    if ch.sf[b] < 0 {
      continue
    }
    let noise = cb == 13
    let diff = ch.sf[b] - (if noise { off_pns } else { off_sf })
    if noise {
      off_pns = ch.sf[b]
      if noise_flag {
        noise_flag = false
        bw.put((diff + aac_noise_pre).reinterpret_as_uint(), aac_noise_pre_bits)
        continue
      }
    } else {
      off_sf = ch.sf[b]
    }
    let mut d = diff + 60
    if d < 0 {
      d = 0
    }
    if d > 120 {
      d = 120
    }
    bw.put(aac_scalefactor_code[d], aac_scalefactor_bits[d])
  }
}

///|
/// Write one codebook 11 escape sequence for a magnitude `v >= 16`:
/// `(len - 4)` one bits, a terminating zero, then `len` bits holding
/// `v - 2^len`, where `len` is the position of `v`'s highest set bit. This is
/// the mirror of the decoder's ``n = (1 << b) + read(b)`` with
/// ``b = 4 + ones`` (spec 4.6.3.3).
fn aac_encode_write_escape(bw : BitWriter, v : Int32) -> Unit {
  let mut len = 0
  let mut t = v
  while t > 1 {
    t = t >> 1
    len = len + 1
  }
  let mut ones = len - 4
  while ones > 0 {
    bw.put_bit(1)
    ones = ones - 1
  }
  bw.put_bit(0)
  bw.put((v - (1 << len)).reinterpret_as_uint(), len)
}

///|
/// spectral_data: the per-band Huffman codebook, its sign bits and (for
/// codebook 11) the escape sequences. A short frame's eight windows form one
/// group, so a band's segment is emitted once per window, in window order.
fn aac_encode_write_spectral(
  bw : BitWriter,
  ch : AacEncChannel,
  offsets : Array[Int32],
  codes : Array[Array[UInt32]],
  bits : Array[Array[Int32]],
  revs : Array[Array[Int32]],
) -> Unit {
  for b = 0; b < ch.max_sfb; b = b + 1 {
    let cb = ch.cb[b]
    // NOISE_BT carries no spectral data: the decoder synthesises it from the
    // scalefactor and its own LCG state. INTENSITY_BT/INTENSITY_BT2 carry none
    // either: `quantize_and_encode_band_cost_STEREO` writes nothing, and the
    // decoder rebuilds the band by scaling the left channel's.
    if !aac_encode_band_has_data(cb) {
      continue
    }
    let dim = if cb <= 4 { 4 } else { 2 }
    let table = cb - 1
    for w = 0; w < ch.num_windows; w = w + 1 {
      let mut i = w * 128 + offsets[b]
      let end = w * 128 + offsets[b + 1]
      while i < end {
        let row = revs[table][aac_encode_tuple_key(cb, ch.q, i)]
        bw.put(codes[table][row], bits[table][row])
        // Codebooks 3/4 and 7..11 carry one sign bit per non-zero magnitude;
        // codebooks 1/2 and 5/6 embed the sign in the Huffman symbol.
        let mut j = 0
        while j < dim {
          let v = ch.q[i + j]
          if v != 0 && (cb == 3 || cb == 4 || cb >= 7) {
            bw.put_bit(if v < 0 { 1 } else { 0 })
          }
          j = j + 1
        }
        if cb == 11 {
          let a0 = aac_encode_abs(ch.q[i])
          let a1 = aac_encode_abs(ch.q[i + 1])
          if a0 >= 16 {
            aac_encode_write_escape(bw, a0)
          }
          if a1 >= 16 {
            aac_encode_write_escape(bw, a1)
          }
        }
        i = i + dim
      }
    }
  }
}

///|
/// ics_info (spec 4.6.2.2) for one channel, written once for a common-window
/// CPE and therefore separated from the rest of the channel stream.
fn aac_encode_write_ics_info(bw : BitWriter, ch : AacEncChannel) -> Unit {
  let is8 = ch.window_sequence == aac_eight_short
  // reserved bit, window_sequence, sine window.
  bw.put(0, 1)
  bw.put(ch.window_sequence.reinterpret_as_uint(), 2)
  bw.put(0, 1)
  if is8 {
    bw.put(ch.max_sfb.reinterpret_as_uint(), 4)
    // scale_factor_grouping: all seven bits set -> one group of eight windows.
    bw.put(0x7f, 7)
  } else {
    bw.put(ch.max_sfb.reinterpret_as_uint(), 6)
    bw.put(0, 1) // predictor_data_present
  }
}

///|
/// The `individual_channel_stream` body after global_gain and ics_info:
/// section data, scalefactors, pulse, TNS, gain control and spectral data.
fn aac_encode_write_channel_body(
  bw : BitWriter,
  ch : AacEncChannel,
  tns : AacEncTns,
  long_offsets : Array[Int32],
  short_offsets : Array[Int32],
  codes : Array[Array[UInt32]],
  bits : Array[Array[Int32]],
  revs : Array[Array[Int32]],
) -> Unit {
  let is8 = ch.window_sequence == aac_eight_short
  let offsets = if is8 { short_offsets } else { long_offsets }
  let global_gain = aac_encode_global_gain(ch)
  aac_encode_write_sections(bw, ch)
  aac_encode_write_scalefactors(bw, ch, global_gain)
  bw.put(0, 1) // pulse_data_present
  bw.put(if tns.present { 1 } else { 0 }, 1)
  if tns.present {
    aac_encode_write_tns(bw, tns, is8, ch.num_windows)
  }
  bw.put(0, 1) // gain_control_data_present
  aac_encode_write_spectral(bw, ch, offsets, codes, bits, revs)
}

///|
/// One frame's inputs that a rate-control attempt does not change: the spectra
/// the analysis reads (already TNS-filtered; mid/side and intensity are mixed
/// in only per attempt, and on the simplified path they were mixed here
/// already), the per-band model targets, the shared window sequence and the
/// shared `max_sfb`.
priv struct AacEncFrame {
  coefs : Array[Array[Double]]
  targets : Array[Array[Int32]]
  sequences : Array[Int32]
  max_sfb : Int32
  tns : Array[AacEncTns]
}

///|
/// Assemble one ADTS frame for a prepared frame and frame-wide scalefactor
/// offset `delta` (the transition/short-frame path, which keeps the simplified
/// perceptual model).
fn AacEncoder::build_frame(
  self : AacEncoder,
  frame : AacEncFrame,
  stereo : AacEncStereo,
  delta : Int32,
) -> Result[Bytes, String] {
  let chans : Array[AacEncChannel] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let one = self.channel_data(
      frame.coefs[ch],
      frame.targets[ch],
      delta,
      frame.sequences[ch],
      frame.max_sfb,
    )
    if ch == 1 {
      aac_encode_mark_is(one, stereo.is_bt, stereo.is_pos)
    }
    chans.push(one)
  }
  self.assemble_frame(frame, stereo, chans)
}

///|
/// `aac_encode_frame`'s `rate_bits`: the nominal bits of one frame, capped at
/// what an ADTS header can describe (`6144 * channels - 3`).
fn AacEncoder::aac_encode_rate_bits(self : AacEncoder) -> Int32 {
  let mut rate_bits = self.config.bit_rate * 1024 / self.config.sample_rate
  let limit = 6144 * self.config.channels - 3
  if rate_bits > limit {
    rate_bits = limit
  }
  rate_bits
}

///|
/// Write the element(s), ics_info, section data, scalefactors, TNS and spectral
/// data of an already-quantised channel pair, then prefix the ADTS header.
fn AacEncoder::assemble_frame(
  self : AacEncoder,
  frame : AacEncFrame,
  stereo : AacEncStereo,
  chans : Array[AacEncChannel],
) -> Result[Bytes, String] {
  let bw = BitWriter::new()
  if self.config.channels == 1 {
    bw.put(0, 3) // ID_SCE
    bw.put(0, 4) // element_instance_tag
    // individual_channel_stream: global_gain, then ics_info.
    bw.put(aac_encode_global_gain(chans[0]).reinterpret_as_uint(), 8)
    aac_encode_write_ics_info(bw, chans[0])
    aac_encode_write_channel_body(
      bw,
      chans[0],
      frame.tns[0],
      self.swb_offsets,
      self.short_offsets,
      self.spectral_codes,
      self.spectral_bits,
      self.spectral_rev,
    )
  } else {
    bw.put(1, 3) // ID_CPE
    bw.put(0, 4) // element_instance_tag
    bw.put(1, 1) // common_window = 1: one shared ics_info for both channels
    aac_encode_write_ics_info(bw, chans[0])
    bw.put(stereo.ms_present.reinterpret_as_uint(), 2)
    if stereo.ms_present == 1 {
      for b = 0; b < frame.max_sfb; b = b + 1 {
        bw.put(if stereo.ms_mask[b] { 1 } else { 0 }, 1)
      }
    }
    for ch = 0; ch < 2; ch = ch + 1 {
      bw.put(aac_encode_global_gain(chans[ch]).reinterpret_as_uint(), 8)
      aac_encode_write_channel_body(
        bw,
        chans[ch],
        frame.tns[ch],
        self.swb_offsets,
        self.short_offsets,
        self.spectral_codes,
        self.spectral_bits,
        self.spectral_rev,
      )
    }
  }
  bw.put(7, 3) // ID_END
  let payload = bw.finish()
  let frame_length = av_aac_adts_header_size + payload.length()
  let header = match
    aac_adts_header_write(
      self.config.sample_rate,
      self.config.channels,
      2,
      frame_length,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let out : Array[Byte] = []
  for i = 0; i < header.length(); i = i + 1 {
    out.push(header[i])
  }
  for i = 0; i < payload.length(); i = i + 1 {
    out.push(payload[i])
  }
  Ok(Bytes::from_array(out[:]))
}

///|
/// Encode one 1024-sample frame per channel into a single ADTS frame. The
/// input is planar float PCM in `[-1, 1]`; the first frame's 1024-sample
/// history is silence, so a decoder emits one priming frame before the input
/// samples (AAC's is 1024 samples of delay).
pub fn AacEncoder::encode_frame(
  self : AacEncoder,
  pcm : Array[Array[Double]],
) -> Result[Bytes, String] {
  if pcm.length() != self.config.channels {
    return Err("AAC encoder input channel count mismatch")
  }
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    if pcm[ch].length() != 1024 {
      return Err("AAC encoder expects 1024 samples per channel")
    }
  }
  // A common-window CPE shares one window sequence, so the attack decision is
  // taken over both channels: either channel attacking starts a short run for
  // the pair.
  let mut attack = false
  let late : Array[Bool] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let (attack_early, attack_late) = self.detect_attack(ch, pcm[ch])
    // A late attack falls in the current frame's second half, which the eight
    // short windows do not reach; the next frame's short blocks cover it, so
    // the flag carries over one frame. A pending attack keeps a short run
    // alive even when the new frame itself is quiet, which is what gives the
    // attack's samples their short blocks.
    late.push(attack_late)
    if attack_early || attack_late || self.attack_pending[ch] {
      attack = true
    }
  }
  let prev = self.prev_sequence[0]
  // LONG_START must be followed by short blocks, and short blocks return to
  // the long transform through LONG_STOP; anything else is a steady-state
  // long frame (or a fresh start when the current frame attacks).
  let seq = if prev == aac_eight_short {
    if attack {
      aac_eight_short
    } else {
      aac_long_stop
    }
  } else if prev == aac_long_start {
    aac_eight_short
  } else if attack {
    aac_long_start
  } else {
    aac_only_long
  }
  let sequences : Array[Int32] = []
  let coefs : Array[Array[Double]] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    sequences.push(seq)
    let buf : Array[Double] = Array::make(2048, 0.0)
    let hist = self.history[ch]
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = hist[i]
      buf[1024 + i] = pcm[ch][i]
      hist[i] = pcm[ch][i]
    }
    coefs.push(self.frame_coefficients(buf, seq))
  }
  let is8 = seq == aac_eight_short
  let num_swb = if is8 { self.num_short_swb } else { self.num_swb }
  let offsets = if is8 { self.short_offsets } else { self.swb_offsets }
  let num_windows = if is8 { 8 } else { 1 }
  // Two orders, because the two models need different spectra.
  //
  // The perceptual path follows `aacenc.c`: analyse, quantise and decide noise
  // on the *left/right* spectra, then mix - intensity and mid/side are re-run
  // on every rate-control iteration, because which bands end up as noise
  // depends on lambda and a noise band must not be mid/side mixed.
  //
  // The simplified path has no such dependency: its per-band scalefactor is
  // derived from the spectrum that actually gets coded, so it still mixes
  // first and models afterwards. That is safe because M/S and TNS commute
  // (mid/side mixes each coefficient index across the two channels, TNS
  // filters along the index axis within one channel), and the decoder undoes
  // stereo before TNS either way.
  // The intensity search on the perceptual path reads the post-PNS `cb` and
  // `zeroes`, so it skips noise bands exactly like `ff_aac_search_for_is` does
  // upstream and the two tools compose (§294). On the simplified path PNS never
  // runs at all - it needs the psy bands - so its correlation-gated search
  // cannot meet a noise band either.
  let use_psy = self.config.perceptual && seq != aac_eight_short
  let use_is = self.config.is_stereo
  let mut stereo = aac_encode_stereo_none(num_swb)
  if self.config.channels == 2 && !use_psy {
    stereo = aac_encode_stereo(
      coefs[0],
      coefs[1],
      offsets,
      num_swb,
      num_windows,
      self.config.sample_rate,
      self.lambda,
      use_is,
      Array::make(num_swb, 0),
    )
  }
  // Perceptual analysis, one pass per channel: the 3GPP model publishes the
  // per-band thresholds and the frame's bit allocation, and the twoloop
  // quantiser turns them into per-band scalefactors. Both are only defined for
  // one long window (the psy port is long-only, the search is single-window),
  // so EIGHT_SHORT frames always keep the simplified model with the frame-wide
  // offset search below. A rate-control retry re-runs this analysis - see the
  // loop below (§289 deviation 2, closed in §297).
  let psy_results : Array[AacPsyResult] = []
  let targets : Array[Array[Int32]] = []
  let mut planned_max_sfb = 0
  if use_psy {
    let prev_bits = if self.config.channels > 0 {
      self.last_frame_bits / self.config.channels
    } else {
      0
    }
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      psy_results.push(
        self.psy.analyze(ch, coefs[ch], prev_bits, seq, self.prev_sequence[ch]),
      )
    }
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let bands = psy_results[ch].bands
      for b = 0; b < bands.length() && b < num_swb; b = b + 1 {
        if bands[b].bits > 0 && b + 1 > planned_max_sfb {
          planned_max_sfb = b + 1
        }
      }
    }
    // TNS derives its band range from `max_sfb` on both sides, so a frame
    // that transmits no band at all still needs a non-zero value.
    if planned_max_sfb < 1 {
      planned_max_sfb = 1
    }
  } else {
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let t = self.band_targets(coefs[ch], seq)
      for b = 0; b < num_swb; b = b + 1 {
        if t[b] >= 0 && b + 1 > planned_max_sfb {
          planned_max_sfb = b + 1
        }
      }
      targets.push(t)
    }
  }
  // TNS: analyse and filter each channel's upper bands, exactly the range the
  // decoder reconstructs from the shared max_sfb.
  let tns : Array[AacEncTns] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let data = self.search_tns(coefs[ch], planned_max_sfb, seq)
    aac_encode_apply_tns(coefs[ch], data, offsets, num_swb, num_windows)
    tns.push(data)
  }
  if self.config.channels == 2 && !use_psy {
    for b = 0; b < planned_max_sfb; b = b + 1 {
      if stereo.ms_mask[b] {
        stereo.ms_present = 1
      }
    }
  }
  let frame : AacEncFrame = {
    coefs,
    targets,
    sequences,
    max_sfb: planned_max_sfb,
    tns,
  }
  // Average bits per frame from the requested bit rate, minus the ADTS header
  // (which is not part of the payload budget).
  let mut target_bytes = self.config.bit_rate * 1024 / self.config.sample_rate
  target_bytes = target_bytes / 8
  if target_bytes < av_aac_adts_header_size + 1 {
    target_bytes = av_aac_adts_header_size + 1
  }
  let result = if use_psy {
    // `aacenc.c:916-945`: the whole element loop - `analyze` included - runs
    // inside the rate-control retry, with `bitres.alloc = -1` and
    // `bitres.bits = last_frame_pb_count / channels` re-set before each call.
    // So a frame that needs a second attempt is analysed *twice*, and the
    // second pass sees the model state the first pass wrote (`fill_level`,
    // `prev_sfb_microphone`, the stored `linpow`). Attempt 0 reuses the
    // frame-start analysis above - that one is the pass C also runs first -
    // and every later attempt re-analyses in place.
    let prev_bits = if self.config.channels > 0 {
      self.last_frame_bits / self.config.channels
    } else {
      0
    }
    let psy_iter : Array[AacPsyResult] = psy_results
    let rate_bits = self.aac_encode_rate_bits()
    let mut its = 0
    let mut built : Bytes = b""
    while true {
      if its > 0 {
        for ch = 0; ch < self.config.channels; ch = ch + 1 {
          psy_iter[ch] = self.psy.analyze(
            ch,
            coefs[ch],
            prev_bits,
            seq,
            self.prev_sequence[ch],
          )
        }
      }
      // FFmpeg hands the element budget to the search from the last channel's
      // analyse (`bitres` is per element, and `aacenc.c` divides by the channel
      // count before `search_for_quantizers`).
      let last = psy_iter.length() - 1
      let psy_alloc = if last >= 0 { psy_iter[last].alloc } else { 0 }
      let alloc = psy_alloc / self.config.channels
      // `aac_encode_frame`'s strict bit-rate control (`bit_rate_tolerance == 0`):
      // quantise, measure the *real* frame, and while it overflows the nominal
      // frame size scale lambda down by `min(0.9, rate/frame)` and quantise
      // again. A frame that fits resets lambda to 120. This keeps the psy bit
      // reservoir from draining: frames never exceed the nominal size, so
      // `fill_level` stays positive and the model keeps asking for detail.
      // The masking thresholds the intensity cost test compares against, one row
      // per channel (`aac_is_encoding_err` reads `band0->threshold` and
      // `band1->threshold`).
      let thr : Array[Array[Double]] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let row : Array[Double] = Array::make(num_swb, 0.0)
        for b = 0; b < num_swb; b = b + 1 {
          row[b] = psy_iter[ch].bands[b].threshold
        }
        thr.push(row)
      }
      let sizes = self.psy.band_sizes()
      // One channel pair, one rate-control attempt: analyse, price and decide
      // noise on the left/right spectra first (`aacenc.c`'s order), then mix.
      let twos : Array[AacTwoResult] = []
      let cbs : Array[Array[Int32]] = []
      let zeros : Array[Array[Int32]] = []
      let sfi : Array[Array[Int32]] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let r = psy_iter[ch]
        // PNS runs around the search: mark noise-like bands, let the twoloop
        // rate loop price them, then decide which ones actually become noise.
        let mark = aac_pns_mark(
          r.bands, self.swb_offsets, self.num_swb,
          self.config.sample_rate, self.config.bit_rate,
          self.config.channels, self.lambda,
        )
        let can_pns = if self.config.pns {
          mark.can_pns
        } else {
          Array::make(self.num_swb, 0)
        }
        let two = aac_twoloop_search_pns(
          coefs[ch],
          sizes,
          r.bands,
          alloc,
          self.config.bit_rate,
          self.config.sample_rate,
          self.config.channels,
          self.lambda,
          aac_twoloop_pns(can_pns, self.config.pns, use_is),
        )
        twos.push(two)
        if self.config.pns {
          let out = aac_pns_search(
            aac_pns_search_in(
              coefs[ch], sizes, self.swb_offsets, r.bands, two.sf,
              two.cb, two.zeroes, can_pns, mark.pns_ener,
              self.pns_random_state,
            ),
            self.config.sample_rate,
            self.config.bit_rate,
            self.config.channels,
            self.lambda,
          )
          self.pns_random_state = out.random_state
          cbs.push(out.cb)
          zeros.push(out.zeroes)
          sfi.push(out.noise_sfi)
        } else {
          cbs.push(two.cb)
          zeros.push(two.zeroes)
          sfi.push(Array::make(self.num_swb, 0))
        }
      }
      // The mix works on a copy: the analysis above has to keep reading the
      // un-mixed pair, and the next lambda iteration starts from it again.
      let work : Array[Array[Double]] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        work.push(
          if self.config.channels == 2 { coefs[ch].copy() } else { coefs[ch] },
        )
      }
      let mut st = stereo
      // What the quantiser and the bitstream use per band: twoloop's
      // scalefactors and band types, except where the mid/side search replaced
      // them with the ones its chosen `(M, S)` pair was priced with.
      let sf_ch : Array[Array[Int32]] = []
      let cb_ch : Array[Array[Int32]] = []
      for ch in 0..<self.config.channels {
        sf_ch.push(twos[ch].sf)
        cb_ch.push(cbs[ch])
      }
      if self.config.channels == 2 {
        let (psy_st, ms) = aac_encode_stereo_psy(
          work,
          sizes,
          thr,
          twos,
          cbs,
          zeros,
          offsets,
          num_swb,
          num_windows,
          self.config.sample_rate,
          self.lambda,
          use_is,
        )
        st = psy_st
        sf_ch[0] = ms.sf0
        cb_ch[0] = ms.cb0
        sf_ch[1] = ms.sf1
        cb_ch[1] = ms.cb1
        for b = 0; b < planned_max_sfb; b = b + 1 {
          if st.ms_mask[b] {
            st.ms_present = 1
          }
        }
      }
      let chans : Array[AacEncChannel] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let one = self.channel_data_psy(
          work[ch],
          sf_ch[ch],
          seq,
          planned_max_sfb,
          cb_ch[ch],
          zeros[ch],
          sfi[ch],
        )
        if ch == 1 {
          aac_encode_mark_is(one, st.is_bt, st.is_pos)
        }
        chans.push(one)
      }
      let frame_bytes = match self.assemble_frame(frame, st, chans) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      built = frame_bytes
      let frame_bits = (frame_bytes.length() - av_aac_adts_header_size) * 8
      if frame_bits <= rate_bits {
        self.lambda = 120.0
        break
      }
      let ratio = rate_bits.to_double() / frame_bits.to_double()
      let step = if ratio < 0.9 { ratio } else { 0.9 }
      self.lambda = self.lambda * step
      its = its + 1
      // Upstream keeps shrinking lambda until the frame fits; the cap only
      // guards against a pathological input that cannot be made to fit.
      if its >= 10 {
        break
      }
    }
    Ok(built)
  } else {
    // Finer quantisation costs more bits, so the smallest offset whose frame
    // still fits the budget is the highest quality this frame can afford. The
    // offset may be negative: escape coding lets the scalefactor go below the
    // reference value that a 15-step codebook would require.
    let mut lo = -255
    let mut hi = 255
    let mut best : Bytes = b""
    let mut found = false
    while lo <= hi {
      let mid = (lo + hi) / 2
      let built = match self.build_frame(frame, stereo, mid) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if built.length() <= target_bytes {
        best = built
        found = true
        hi = mid - 1
      } else {
        lo = mid + 1
      }
    }
    if !found {
      return Err("AAC frame exceeds the requested bit rate")
    }
    Ok(best)
  }
  let built = match result {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Feed the psy model the payload bits actually produced: FFmpeg's
  // `last_frame_pb_count` is the AAC frame without the ADTS header.
  self.last_frame_bits = (built.length() - av_aac_adts_header_size) * 8
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    self.prev_sequence[ch] = sequences[ch]
    self.attack_pending[ch] = late[ch]
  }
  Ok(built)
}
