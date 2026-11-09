///|
/// Flush the encoder: FFmpeg's `AV_CODEC_CAP_DELAY` drain, which always
/// emits two packets once at least one frame is buffered - the pending
/// window (its type decided with `la == NULL`) and the zero-padded tail
/// `[hist | zeros]` (the type machine steps once more, also `la == NULL`).
/// Both LAME steps run `uselongblock = !(prev == EIGHT_SHORT)` and the
/// all-zero-attacks tail (`next_grouping` becomes `window_grouping[0]`,
/// `prev_attack` clears). Returns an empty array before the first frame or
/// on a repeated flush without an intervening `encode_frame` (the C gate:
/// no samples remain).
pub fn AacEncoder::flush(self : AacEncoder) -> Result[Array[Bytes], String] {
  if self.frames_encoded == 0 || self.flushed {
    return Ok([])
  }
  let out : Array[Bytes] = []
  if self.config.perceptual {
    // Packet A: the pending window.
    let sequences_a : Array[Int32] = []
    let shapes_a : Array[Int32] = []
    let lame_grp_a : Array[Int32] = []
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      // `prev_type` is the channel's own `ics->window_sequence[0]`.
      let prev = self.prev_sequence[ch]
      let uselong = prev != aac_eight_short
      let (emit, next) = aac_lame_apply_block_type(self.lame_seq[ch], uselong)
      self.lame_seq[ch] = next
      sequences_a.push(emit)
      shapes_a.push(aac_lame_window_shape(emit))
      // The short-frame grouping is the stored byte; the tail then stores
      // window_grouping[0] and clears prev_attack (attacks[] all zero).
      lame_grp_a.push(self.lame[ch].next_grouping)
      self.lame[ch].next_grouping = aac_window_grouping[0]
      self.lame[ch].prev_attack = 0
    }
    let built_a = match
      self.encode_pipeline(self.pending_bufs, sequences_a, shapes_a, lame_grp_a) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    self.last_frame_bits = (built_a.length() - av_aac_adts_header_size) * 8
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      self.prev_sequence[ch] = sequences_a[ch]
      self.use_kb[ch] = shapes_a[ch]
    }
    out.push(built_a)
    // Packet B: the zero-padded tail. Its grouping is window_grouping[0]
    // (the tail A ran already stored it), which the pipeline's empty
    // lame_grp default expands to.
    let bufs_b : Array[Array[Double]] = []
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let buf : Array[Double] = Array::make(2048, 0.0)
      let hist = self.history[ch]
      for i = 0; i < 1024; i = i + 1 {
        buf[i] = hist[i]
      }
      bufs_b.push(buf)
    }
    let sequences_b : Array[Int32] = []
    let shapes_b : Array[Int32] = []
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let prev = self.prev_sequence[ch]
      let uselong = prev != aac_eight_short
      let (emit, next) = aac_lame_apply_block_type(self.lame_seq[ch], uselong)
      self.lame_seq[ch] = next
      sequences_b.push(emit)
      shapes_b.push(aac_lame_window_shape(emit))
    }
    let built_b = match
      self.encode_pipeline(bufs_b, sequences_b, shapes_b, []) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      self.prev_sequence[ch] = sequences_b[ch]
      self.use_kb[ch] = shapes_b[ch]
    }
    out.push(built_b)
    self.flushed = true
    return Ok(out)
  }
  // The simplified path keeps its single synchronous tail.
  let bufs : Array[Array[Double]] = []
  let sequences : Array[Int32] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let buf : Array[Double] = Array::make(2048, 0.0)
    let hist = self.history[ch]
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = hist[i]
    }
    bufs.push(buf)
    sequences.push(self.prev_sequence[0])
  }
  let built = match
    self.encode_pipeline(
      bufs,
      sequences,
      Array::make(self.config.channels, 0),
      [],
    ) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    self.prev_sequence[ch] = sequences[ch]
  }
  self.flushed = true
  out.push(built)
  Ok(out)
}

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
///   * encoder MDCT coefficient `c` is `32768 * X` where `X` is the textbook
///     forward MDCT - the exact scale of the reference encoder's `av_tx`
///     float transform (§368; the port's own 2x-era scale is gone, so the
///     psy thresholds land bit-exact on C's absolute ATH anchors and the
///     twoloop carries C's own scalefactor grid),
///   * `q = floor((|c| * 2^(-(sf-104)/4))^(3/4) + 0.405)` on both paths -
///     the 104-anchored grid the reference quantiser's table indices
///     (`304 - sf`) encode,
///   * decoder dequantisation is `q^(4/3) * 2^((sf-100)/4)`, so the
///     four-step anchor gap is the 2x amplitude gain from the encoder's
///     `32768 * MDCT` domain into the decoder's `-65536 * MDCT` one.
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
  /// Enable mid/side stereo on channel pairs (`aacenc.c`'s
  /// `options.mid_side`; the stereo searches run when either tool is on).
  mid_side : Bool
  /// Let the perceptual path also quantise EIGHT_SHORT frames (§302). Off by
  /// default: eight short windows are coded as one group here, so a single
  /// scalefactor covers spectra whose energies differ by an order of magnitude,
  /// and the transient fixture loses ~6 dB of waveform SNR with no measured
  /// noise-to-mask gain yet (§303). `aac_encode_config_with_perceptual_short`
  /// turns it on; the steady long-window baselines are unaffected either way.
  perceptual_short : Bool
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
  mdct_tx : @aac_mdct_tx.AacMdctTx
  spectral_codes : Array[Array[UInt32]]
  spectral_bits : Array[Array[Int32]]
  spectral_rev : Array[Array[Int32]]
  prev_sequence : Array[Int32]
  attack_pending : Array[Bool]
  win_energy : Array[Double]
  /// LAME window/grouping analyser state per channel (`AacPsyChannel`'s LAME
  /// members, §304).  Consulted only on `perceptual_short` frames, but run
  /// every frame while that path is enabled, so the peak history and the
  /// `prev_attack`/`next_attack0_zero` chains stay on FFmpeg's cadence (the
  /// window vectors in `aac_win_vectors` pin that cadence).
  lame : Array[AacLameWindow]
  psy : AacPsyContext
  /// Bit count of the previous frame's AAC payload, per channel, fed back to
  /// the psy model as `bitres.bits` (`libavcodec` `last_frame_pb_count`).
  mut last_frame_bits : Int32
  /// Rate-control lambda of the perceptual path: starts the stream at 120
  /// and then follows `aac_encode_frame`'s ABR tracking (`sqrt` steps, a
  /// damped `sqrt(sqrt)` step clipped to [0.9, 1.1] inside the stability
  /// window); it persists across frames - there is no per-frame reset.
  mut lambda : Double
  /// LCG state carried across frames by `search_for_pns` (`s->random_state`).
  mut pns_random_state : Int32
  /// Frames encoded so far - the port's stand-in for the C flush gate
  /// `s->afq.remaining_samples`: flush emits the tail frame only after at
  /// least one frame, and only once until the next `encode_frame`.
  mut frames_encoded : Int32
  /// The one-packet-ahead tail frame has been emitted by `flush`.
  mut flushed : Bool
  /// The pending window's MDCT input buffer (per channel, 2048 samples):
  /// the perceptual path emits each window one frame late, so the buffer
  /// built by this call waits here while the next call's lookahead decides
  /// its window type.
  mut pending_bufs : Array[Array[Double]]
  /// The per-channel block-type state (`lame_apply_block_type`'s carry) for
  /// the perceptual short path - FFmpeg runs one machine per channel and
  /// drops `common_window` when the two channels' window types (or
  /// groupings) disagree (§309 ports that fork; the merged pair machine of
  /// §307 is gone). With both analysers agreeing, the per-channel machines
  /// emit exactly what the merged one did.
  lame_seq : Array[Int32]
  /// The last emitted window's shape per channel (`ics.use_kb_window[0]`,
  /// which becomes `[1]` for the next window - §371). Stays 0 on the
  /// simplified path, which only ever uses sine windows.
  use_kb : Array[Int32]
  /// C's per-`SingleChannelElement` sticky slot arrays (`sf_idx` / `band_type`
  /// / `zeroes`, 128 slots of `w * 16 + g`). The coder only ever writes
  /// group-start slots, so on a short frame the inner-window slots keep what
  /// earlier frames left there - and `search_for_pns`'s per-window pricing
  /// reads them (`aaccoder.c:597-599`), which is why they persist on the
  /// element in FFmpeg. `sf_idx`/`zeroes` are never reset; `band_type` drops
  /// its intensity entries at every attempt's element start
  /// (`aacenc.c:931-933`). Long frames rewrite every slot they read, so the
  /// stickiness is invisible on them.
  sticky_sf : Array[Array[Int32]]
  sticky_cb : Array[Array[Int32]]
  sticky_zeroes : Array[Array[Int32]]
  /// `ics.max_sfb` as the last rate-control attempt left it (`aacenc.c:517`),
  /// per channel - a `common_window = 0` pair carries two independent
  /// values. The next attempt's TNS search reads it as its band limit,
  /// clamped to `num_swb` at frame start (`aacenc.c:864`) - which is why
  /// FFmpeg's very first frame carries no TNS filter at all: the context is
  /// zero-initialized, so `mmm` is 0 and `search_for_tns` bails out on an
  /// empty range.
  last_max_sfb : Array[Int32]
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
    mid_side: false,
    perceptual_short: false,
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
    mid_side: false,
    perceptual_short: false,
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
    mid_side: config.mid_side,
    perceptual_short: config.perceptual_short,
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
    mid_side: config.mid_side,
    perceptual_short: config.perceptual_short,
  }
}

///|

///|
/// Enable mid/side stereo on a channel pair: bands whose mid/side
/// reconstruction is cheaper than left/right are coded from the mid channel
/// with a per-band mask (`encode_ms_info`), exactly `aacenc.c`'s
/// `options.mid_side = -1` (auto) behaviour. Opt-in like `is`/`pns`.
pub fn aac_encode_config_with_ms(config : AacEncodeConfig) -> AacEncodeConfig {
  {
    sample_rate: config.sample_rate,
    channels: config.channels,
    bit_rate: config.bit_rate,
    perceptual: config.perceptual,
    pns: config.pns,
    is_stereo: config.is_stereo,
    mid_side: true,
    perceptual_short: config.perceptual_short,
  }
}

///|
/// Extend the perceptual rate control to EIGHT_SHORT frames (§302). The 3GPP
/// model already publishes 8 x 128 band records (§300) and the twoloop search
/// already walks window groups (§301); this switch is what finally lets the
/// encoder hand short frames to that chain instead of the simplified model.
///
/// Like PNS and intensity stereo this is opt-in: since §304 the short frames
/// carry the LAME analyser's real `scale_factor_grouping`, which cut the
/// short-frame noise-to-mask deficit on the §303 fixture (14.21 -> 13.40 dB
/// at 128 kbps) but did not flip it below the simplified arm (9.75 dB), so
/// the default stays the measured path. The multi-window forms of PNS / IS /
/// M-S remain future work and stay off on short frames.
/// `PORTING_HISTORY.md` §303/§304 record the measurements.
///
/// It also turns `perceptual` on, like `aac_encode_config_with_pns` does:
/// otherwise the flag would be a silent no-op.
pub fn aac_encode_config_with_perceptual_short(
  config : AacEncodeConfig,
) -> AacEncodeConfig {
  {
    sample_rate: config.sample_rate,
    channels: config.channels,
    bit_rate: config.bit_rate,
    perceptual: true,
    pns: config.pns,
    is_stereo: config.is_stereo,
    mid_side: config.mid_side,
    perceptual_short: true,
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
  // `lame_window_init`: the attack threshold comes from the per-channel
  // bitrate (`bit_rate / nb_channels / 1000`, integer division), the peak
  // history starts at 10.0f.
  let lame_kbps = config.bit_rate / config.channels / 1000
  let lame : Array[AacLameWindow] = []
  // Sticky slot arrays, zeroed like FFmpeg's calloc'd `SingleChannelElement`.
  let sticky_sf : Array[Array[Int32]] = []
  let sticky_cb : Array[Array[Int32]] = []
  let sticky_zeroes : Array[Array[Int32]] = []
  for _ch = 0; _ch < config.channels; _ch = _ch + 1 {
    history.push(Array::make(1024, 0.0))
    prev_sequence.push(aac_only_long)
    attack_pending.push(false)
    win_energy.push(0.0)
    lame.push(AacLameWindow::new(lame_kbps))
    sticky_sf.push(Array::make(128, 0))
    sticky_cb.push(Array::make(128, 0))
    sticky_zeroes.push(Array::make(128, 0))
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
    mdct_tx: @aac_mdct_tx.AacMdctTx::new(),
    spectral_codes,
    spectral_bits,
    spectral_rev: aac_encode_reverse_tables(),
    prev_sequence,
    attack_pending,
    win_energy,
    lame,
    psy,
    last_frame_bits: 0,
    lambda: 120.0,
    pns_random_state: 0,
    frames_encoded: 0,
    flushed: false,
    pending_bufs: [],
    last_max_sfb: Array::make(2, 0),
    lame_seq: Array::make(2, 0),
    use_kb: Array::make(2, 0),
    sticky_sf,
    sticky_cb,
    sticky_zeroes,
  })
}

///|
/// Apply the analysis window of `seq` to the 2048-sample overlap buffer.
///
/// Natural time order: ONLY_LONG is a full 2048-point window; LONG_START
/// is the long rising half, 448 samples at unit gain, the falling short half
/// and 448 zeros; LONG_STOP is its mirror (the short rising half and the long
/// falling half). The flat 448-sample stretches are what the neighbouring long
/// frame and the eight short blocks overlap, so the transition is TDAC-safe.
///
/// Mirrors `apply_*_window` (`aacenc.c:383-436`): the windows are the f32
/// tables, the falling halves index them in reverse (`vector_fmul_reverse`),
/// and every product is rounded to f32. `lwin0`/`swin0` are the tables of
/// this frame's shape (`use_kb_window[0]`), `lwin1`/`swin1` the previous
/// frame's (`[1]`), and each window picks them exactly as the C does -
/// including ONLY_LONG's current-shape *rising* half, the reverse of the
/// decoder's convention (§371).
fn aac_encode_window(
  seq : Int32,
  buf : Array[Double],
  lwin0 : Array[Double],
  swin0 : Array[Double],
  lwin1 : Array[Double],
  swin1 : Array[Double],
) -> Array[Double] {
  let d : Array[Double] = Array::make(2048, 0.0)
  if seq == aac_long_start {
    for i = 0; i < 1024; i = i + 1 {
      d[i] = aac_two_mul(buf[i], lwin1[i])
    }
    for i = 0; i < 448; i = i + 1 {
      d[1024 + i] = buf[1024 + i]
    }
    for i = 0; i < 128; i = i + 1 {
      d[1472 + i] = aac_two_mul(buf[1472 + i], swin0[127 - i])
    }
  } else if seq == aac_long_stop {
    for i = 0; i < 128; i = i + 1 {
      d[448 + i] = aac_two_mul(buf[448 + i], swin1[i])
    }
    for i = 0; i < 448; i = i + 1 {
      d[576 + i] = buf[576 + i]
    }
    for i = 0; i < 1024; i = i + 1 {
      d[1024 + i] = aac_two_mul(buf[1024 + i], lwin0[1023 - i])
    }
  } else {
    for i = 0; i < 1024; i = i + 1 {
      d[i] = aac_two_mul(buf[i], lwin0[i])
      d[1024 + i] = aac_two_mul(buf[1024 + i], lwin1[1023 - i])
    }
  }
  d
}

///|
/// Analysis coefficients of a frame in the requested window sequence - the
/// exact `av_tx` FLOAT MDCT of the windowed samples (scale 32768 folded into
/// the twiddles, `aac_mdct_tx.mbt`, §370).
///
/// `shape` is this frame's window shape and `prev_shape` the previous
/// frame's (`use_kb_window[0]`/`[1]`, §371); the simplified path passes 0
/// for both and stays all-sine.
///
/// The eight short blocks are 256-sample windowed chunks on a 128-sample
/// hop, anchored 448 samples before the current frame (the `flat` of the
/// decoder's overlap-add), so the last blocks reach 576 samples into the
/// look-ahead part of the overlap buffer. `apply_eight_short_window` builds
/// each chunk with the rising window on the first half and the reversed
/// window on the second (`vector_fmul_reverse`); the first block rises on
/// the current shape, blocks 1..7 on the previous one, and every block
/// falls on the current shape.
fn AacEncoder::frame_coefficients(
  self : AacEncoder,
  buf : Array[Double],
  seq : Int32,
  shape : Int32,
  prev_shape : Int32,
) -> Array[Double] {
  let out : Array[Double] = Array::make(1024, 0.0)
  if seq == aac_eight_short {
    let swin = self.mdct_tx.short_window(shape)
    let pwin = self.mdct_tx.short_window(prev_shape)
    for w = 0; w < 8; w = w + 1 {
      let rise = if w == 0 { swin } else { pwin }
      let slot : Array[Double] = Array::make(256, 0.0)
      for j = 0; j < 128; j = j + 1 {
        slot[j] = aac_two_mul(buf[448 + w * 128 + j], rise[j])
        slot[128 + j] = aac_two_mul(buf[448 + w * 128 + 128 + j], swin[127 - j])
      }
      let part = @aac_mdct_tx.aac_mdct_tx_128(self.mdct_tx, slot)
      for j = 0; j < 128; j = j + 1 {
        out[w * 128 + j] = part[j]
      }
    }
    return out
  }
  let d = aac_encode_window(
    seq,
    buf,
    self.mdct_tx.long_window(shape),
    self.mdct_tx.short_window(shape),
    self.mdct_tx.long_window(prev_shape),
    self.mdct_tx.short_window(prev_shape),
  )
  @aac_mdct_tx.aac_mdct_tx_1024(self.mdct_tx, d)
}

///|
/// The spectrum of one 2048-sample overlap buffer exactly as the encoder forms
/// it for a steady long frame on the simplified path (sine window plus the
/// 32768-scaled MDCT kernel). The perceptual path's steady frames are KBD
/// (§371); this sine-window spectrum stays the fixed measuring ruler.
///
/// Exposed so tests can measure a decoded frame's error in the same domain the
/// psy model and the quantiser use — a noise-to-mask comparison is only
/// meaningful against the thresholds of the original spectrum.
pub fn AacEncoder::spectrum(
  self : AacEncoder,
  buf : Array[Double],
) -> Array[Double] {
  self.frame_coefficients(buf, aac_only_long, 0, 0)
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
/// coefficient: a full-scale sine peaks near 6e6 in the encoder's
/// `32768 * MDCT` scale (§368), a 0 dBFS programme sits around 90 dB SPL, and
/// the threshold in quiet is about 0 dB SPL, so `(6e6 * 10^(-90/20))^2`, i.e.
/// -90 dB re full scale.
let aac_encode_ath_energy : Double = 35975.0

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
  // `compute_lpc_coefs(coef, 0, order, lpc, 0, 0, 0, NULL)` with the
  // encoder's float `LPC_TYPE` (`lpc_functions.h`): every product and sum of
  // the step-up mirror rounds to f32 (§371).
  let lpc : Array[Double] = Array::make(order, 0.0)
  for i = 0; i < order; i = i + 1 {
    let r = aac_two_f32(-coef[i])
    lpc[i] = r
    for j = 0; j < (i + 1) / 2; j = j + 1 {
      let f = lpc[j]
      let b = lpc[i - 1 - j]
      lpc[j] = aac_two_add(f, aac_two_mul(r, b))
      lpc[i - 1 - j] = aac_two_add(b, aac_two_mul(r, f))
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
  psy_bands? : Array[AacPsyBandInfo],
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
    match psy_bands {
      Some(pb) =>
        // The perceptual path reads the psy model's per-window band energies
        // (`psy_bands[w*16+g].energy`, f32 sums) over the upstream loop
        // bounds `g < num_swb && g <= sfb_end` (§371).
        for g = sfb_start; g < num_swb && g <= sfb_end; g = g + 1 {
          let e = pb[w * 16 + g].energy
          if n_filt == 2 {
            if g > sfb_start + sfb_len / 2 {
              en[1] = aac_two_add(en[1], e)
            } else {
              en[0] = aac_two_add(en[0], e)
            }
          } else if g > sfb_start + sfb_len / 2 + sfb_len / 4 {
            en[2] = aac_two_add(en[2], e)
          } else if g > sfb_start + sfb_len / 2 - sfb_len / 4 {
            en[1] = aac_two_add(en[1], e)
          } else {
            en[0] = aac_two_add(en[0], e)
          }
        }
      None =>
        // The simplified path has no psy bands: coefficient energies.
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
          // `sce->coeffs[start] += lpc[i-1] * sce->pcoeffs[start - i*inc]`:
          // a float product and a float sum (§371).
          coef[st] = aac_two_add(
            coef[st],
            aac_two_mul(lpc[i - 1], orig[st - i * inc]),
          )
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

///|
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
  let freq_mult = sample_rate.to_double() /
    (1024.0 / num_windows.to_double()) /
    2.0
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
  // The window-group walk of `encode_ms_info`'s siblings: on a short frame the
  // decisions live on the group-start slots `w * 16 + b`; on a long frame the
  // single group makes the slot of band `b` be `b` itself.
  let mut w = 0
  while w < ch.num_windows {
    for b = 0; b < ch.max_sfb && b < bt.length(); b = b + 1 {
      let slot = w * 16 + b
      if bt[slot] != 0 && slot < ch.cb.length() && slot < ch.sf.length() {
        ch.cb[slot] = bt[slot]
        ch.sf[slot] = pos[slot]
      }
    }
    w = w + ch.group_len[w]
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
  group_len : Array[Int32],
) -> Unit {
  let mut w = 0
  while w < num_windows {
    for b = 0; b < num_swb; b = b + 1 {
      if !mask[w * 16 + b] {
        continue
      }
      for w2 = 0; w2 < group_len[w]; w2 = w2 + 1 {
        let base = (w + w2) * 128
        for i = base + offsets[b]; i < base + offsets[b + 1]; i = i + 1 {
          let m = (left[i] + right[i]) * 0.5
          right[i] = m - right[i]
          left[i] = m
        }
      }
    }
    w = w + group_len[w]
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
  ignore(num_swb)
  {
    ms_present: 0,
    // 128 slots: the ms-present counting loop indexes the `w * 16 + b`
    // layout even when no search ran (short frames reach 7*16+13).
    ms_mask: Array::make(128, false),
    is_bt: Array::make(128, 0),
    is_pos: Array::make(128, 0),
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
      left, right, offsets, num_swb, num_windows, sample_rate, lambda,
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
  // The simplified path codes a short frame as one group of eight windows
  // (§302's shape), so its band-indexed arrays slot trivially.
  let simple_group : Array[Int32] = if num_windows == 8 {
    [8, 0, 0, 0, 0, 0, 0, 0]
  } else {
    [1, 0, 0, 0, 0, 0, 0, 0]
  }
  if use_is {
    aac_is_apply(
      left,
      right,
      offsets,
      num_swb,
      num_windows,
      simple_group,
      bt,
      Array::make(num_swb, false),
      scale,
    )
  }
  aac_encode_apply_ms(
    left, right, offsets, num_swb, ms_mask, num_windows, simple_group,
  )
  { ms_present: 0, ms_mask, is_bt: bt, is_pos: pos, }
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
  group_len : Array[Int32],
  sample_rate : Int32,
  lambda : Double,
  use_is : Bool,
) -> (AacEncStereo, AacMsOut) {
  let shape = if num_windows == 8 {
    aac_two_shape_short(group_len)
  } else {
    aac_two_shape_long()
  }
  // Slot-space size: the full `w * 16 + g` range on a short frame, plain band
  // indices on a long one (where the slot of band `g` is `g`).
  let slots = if num_windows == 8 { 128 } else { num_swb }
  let no_mask : Array[Int32] = Array::make(slots, 0)
  let (is_mask, bt, pos, scale, flip_in) = if use_is {
    let isr = aac_is_search(
      aac_is_in(
        work[0],
        work[1],
        band_sizes,
        shape,
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
    // `set_special_band_scalefactors`' position chain: the ±60 window runs in
    // emission order - group by group, bands within each group.
    let pos : Array[Int32] = Array::make(slots, 0)
    let mut prev = 0
    let mut wg = 0
    while wg < num_windows {
      for g = 0; g < num_swb; g = g + 1 {
        let slot = wg * 16 + g
        if isr.is_mask[slot] == 1 {
          pos[slot] = aac_encode_is_position(isr.is_ener1[slot], prev)
          prev = pos[slot]
        }
      }
      wg = wg + group_len[wg]
    }
    (isr.is_mask, isr.band_type1, pos, isr.is_ener0, isr.ms_mask)
  } else {
    (
      no_mask.copy(),
      no_mask.copy(),
      no_mask.copy(),
      Array::make(slots, 0.0),
      no_mask.copy(),
    )
  }
  let flip : Array[Bool] = Array::make(slots, false)
  for b = 0; b < slots; b = b + 1 {
    flip[b] = flip_in[b] == 1
  }
  aac_is_apply(
    work[0],
    work[1],
    offsets,
    num_swb,
    num_windows,
    group_len,
    bt,
    flip,
    scale,
  )
  // The right channel's band type already reads 14/15 on the intensity bands,
  // and `search_for_ms` must see that: `ff_init_nextband_map` skips those
  // entries, which is what keeps the scalefactor-delta chain it tests
  // consistent with the one the bitstream will carry.
  let cb1 : Array[Int32] = Array::make(slots, 0)
  for w = 0; w < num_windows; w = w + 1 {
    for b = 0; b < num_swb; b = b + 1 {
      let slot = w * 16 + b
      cb1[slot] = if is_mask[slot] == 1 { bt[slot] } else { cbs[1][slot] }
    }
  }
  let ms = aac_ms_search(
    aac_ms_in(
      work[0],
      work[1],
      band_sizes,
      shape,
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
  let ms_mask : Array[Bool] = Array::make(slots, false)
  let apply_mask : Array[Bool] = Array::make(slots, false)
  for w = 0; w < num_windows; w = w + 1 {
    for b = 0; b < num_swb; b = b + 1 {
      let slot = w * 16 + b
      ms_mask[slot] = ms.ms_mask[slot] == 1
      apply_mask[slot] = ms_mask[slot] &&
        is_mask[slot] == 0 &&
        ms.cb0[slot] < 13 &&
        ms.cb1[slot] < 13
    }
  }
  aac_encode_apply_ms(
    work[0],
    work[1],
    offsets,
    num_swb,
    apply_mask,
    num_windows,
    group_len,
  )
  ({ ms_present: 0, ms_mask, is_bt: bt, is_pos: pos, }, ms)
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
      // Anchor 104, the twoloop grid's: with the §368 domain the simplified
      // path and the reference quantiser share one sf convention, and the
      // four-step gap to the bitstream's anchor-100 scalefactors is the 2x
      // gain into the decoder's `-65536 * MDCT` convention (see
      // `aac_encode_channel_data_psy`).
      let mut v = @math.floor(104.0 + 4.0 * @math.log2(step) + 0.5).to_int()
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
/// Smallest scalefactor at which no coefficient of the band quantises past
/// `aac_encode_max_q` - the guard FFmpeg's coders get from `coef2minsf`.
/// 0 for an all-zero band.
fn aac_encode_min_sf(
  coef : Array[Double],
  start : Int32,
  end : Int32,
  num_windows : Int32,
) -> Int32 {
  let mut peak = 0.0
  for w = 0; w < num_windows; w = w + 1 {
    for i = w * 128 + start; i < w * 128 + end; i = i + 1 {
      let a = coef[i].abs()
      if a > peak {
        peak = a
      }
    }
  }
  if peak <= 0.0 {
    return 0
  }
  // `floor((peak * 2^(-(s-104)/4))^(3/4) + 0.405)` must stay <= max_q - the
  // grid is anchored at 104 like the twoloop's (§368).
  let limit = @math.pow(aac_encode_max_q.to_double() + 0.595, 4.0 / 3.0)
  let mut s = @math.ceil(104.0 + 4.0 * @math.log2(peak / limit)).to_int()
  if s < 0 {
    s = 0
  }
  // Settle the float edge with the quantiser's own arithmetic.
  while s < 255 &&
        @math.pow(peak * @math.pow(2.0, -(s - 104).to_double() / 4.0), 0.75) +
        0.405 >=
        aac_encode_max_q.to_double() + 1.0 {
    s = s + 1
  }
  s
}

///|
/// Quantise one scalefactor band (of `num_windows` 128-bin segments):
/// `q = sign(c) * floor((|c| * 2^(-(s-104)/4))^(3/4) + 0.405)`, clamped to
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
  // Anchor 104, the shared quantiser grid (§368): the four-step gap to the
  // bitstream's anchor-100 scalefactors is the 2x amplitude gain from this
  // encoder's `32768 * MDCT` domain into the decoder's `-65536 * MDCT`
  // convention, so a directly-written `s` reconstructs at decoder scale.
  let step = if s < 0 {
    0.0
  } else {
    @math.pow(2.0, -(s - 104).to_double() / 4.0)
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
///
/// Short frames carry their per-group scalefactors/codebooks in the
/// `w * 16 + b` slot layout every encoder-side consumer uses
/// (`sce->sf_idx[w*16+g]`); a long frame has a single window, so its slots
/// are plain band indices.  `group_len` is `ics.group_len` - only group-start
/// entries are meaningful, and `scale_factor_grouping` is its `!group_len[w]`
/// bit image.
priv struct AacEncChannel {
  sf : Array[Int32]
  cb : Array[Int32]
  q : Array[Int32]
  max_sfb : Int32
  window_sequence : Int32
  /// `use_kb_window[0]` (§371): 1 for a KBD window, written in ics_info.
  window_shape : Int32
  num_windows : Int32
  group_len : Array[Int32]
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
    let start = offsets[b]
    let end = offsets[b + 1]
    // FFmpeg's coders never let a band saturate the escape alphabet
    // (`coef2minsf`): without this floor a tonal peak is clipped to 8191 and
    // decodes at a fraction of its level - a pure tone kept ~1 dB of SNR on
    // long frames.
    let floor_sf = aac_encode_min_sf(coef, start, end, num_windows)
    if v < floor_sf {
      v = floor_sf
    }
    if prev > -1000 {
      if v < prev - 60 {
        v = prev - 60
      } else if v > prev + 60 {
        v = prev + 60
      }
    }
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
  // The simplified path always codes a short frame as one group of eight
  // windows (§302's shape); a long frame is a single window.
  let group_len : Array[Int32] = if is8 {
    [8, 0, 0, 0, 0, 0, 0, 0]
  } else {
    [1, 0, 0, 0, 0, 0, 0, 0]
  }
  // The simplified path windows with sine only (shape 0).
  {
    sf,
    cb,
    q,
    max_sfb,
    window_sequence: seq,
    window_shape: 0,
    num_windows,
    group_len,
  }
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
///
/// On a short frame every window group carries its own scalefactor and
/// codebook per band, read from the group-start slot (`w * 16 + b`) of the
/// quantiser's 128-slot arrays; the same `(sf, cb)` then applies to the band's
/// line range in every window of the group - each window is still quantised
/// from its *own* coefficients (`aacenc.c:684-709` walks the same
/// group -> band -> group-window order).
fn aac_encode_channel_data_psy(
  coef : Array[Double],
  final_sf : Array[Int32],
  seq : Int32,
  shape : Int32,
  max_sfb : Int32,
  final_cb : Array[Int32],
  final_zeroes : Array[Int32],
  noise_sfi : Array[Int32],
  offsets : Array[Int32],
  num_windows : Int32,
  group_len : Array[Int32],
) -> AacEncChannel {
  let is8 = seq == aac_eight_short
  let num_swb = offsets.length() - 1
  // Short frames keep the full `w * 16 + b` slot space (group starts live at
  // w*16, b=0..13); a long frame only has band slots.
  let slots = if is8 { 128 } else { num_swb }
  let sf : Array[Int32] = Array::make(slots, -1)
  let cb : Array[Int32] = Array::make(slots, 0)
  let q : Array[Int32] = Array::make(1024, 0)
  let mut w = 0
  while w < num_windows {
    let gl = group_len[w]
    for b = 0; b < num_swb && b < max_sfb; b = b + 1 {
      let slot = w * 16 + b
      // A band reaches here only if it is coded at all: codebooks 1..11 carry
      // spectral data and `NOISE_BT` carries a scalefactor for the noise the
      // decoder synthesises. The intensity band types (14/15), which
      // `search_for_ms` leaves in the right channel's band type where intensity
      // claimed the band, carry neither.
      let coded = aac_encode_band_has_data(final_cb[slot]) ||
        final_cb[slot] == 13
      if final_zeroes[slot] != 0 || final_sf[slot] < 0 || !coded {
        continue
      }
      let start = offsets[b]
      let size = offsets[b + 1] - start
      let noise = final_cb[slot] == 13
      if !noise {
        for w2 = 0; w2 < gl; w2 = w2 + 1 {
          let base = (w + w2) * 128 + start
          let band = aac_twoloop_quantize_band(
            coef,
            base,
            size,
            final_sf[slot],
            final_cb[slot],
          )
          for i = 0; i < size; i = i + 1 {
            q[base + i] = band[i]
          }
        }
      }
      // A NOISE_BT band carries no spectral data: the decoder synthesises it
      // and scales it with `pow2sf_tab[sfo + POW_SF2_ZERO]`. `search_for_pns`
      // already computed the scalefactor whose entry equals the generated
      // noise amplitude (`noise_amp = -pow2sf_tab[sfi + POW_SF2_ZERO]`), so
      // write that `sfi` into the independent noise chain. The regular chain
      // writes `final_sf` unchanged, exactly like the reference encoder: its
      // quantiser grid is anchored at 104 (`Q = 2^((104-sf)/4)`, `q_idx =
      // 304 - sf`) while the bitstream's scalefactors - and this port's
      // decoder dequant `q^(4/3) * 2^((sf-100)/4)` - are anchored at 100, and
      // that four-step gap is the 2x amplitude gain between the encoder's
      // `32768 * MDCT` coefficients and the decoder's `-65536 * MDCT`
      // convention. (The port's 2x-era MDCT carried the gain instead and the
      // write compensated with `- 4` - §368 unified the two.)
      // `noise_sfi` is slot-indexed like everything else this reads.
      sf[slot] = if noise { noise_sfi[slot] } else { final_sf[slot] }
      cb[slot] = final_cb[slot]
    }
    w = w + gl
  }
  {
    sf,
    cb,
    q,
    max_sfb,
    window_sequence: seq,
    window_shape: shape,
    num_windows,
    group_len,
  }
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
/// 100 when silent), scanned in emission order - group by group, bands within
/// each group. Intensity bands are skipped: their `sf` is an `off_is`
/// position, not a scalefactor.
fn aac_encode_global_gain(ch : AacEncChannel) -> Int32 {
  let is8 = ch.window_sequence == aac_eight_short
  let mut w = 0
  while w < ch.num_windows {
    for b = 0; b < ch.max_sfb; b = b + 1 {
      let slot = if is8 { w * 16 + b } else { b }
      if aac_encode_band_has_data(ch.cb[slot]) {
        return ch.sf[slot]
      }
    }
    w = w + ch.group_len[w]
  }
  100
}

///|
/// section_data: group runs of equal band type (0 = zero band), one run-length
/// pass per window group over that group's slots (`aacenc.c:615-627` emits
/// one `codebook_trellis_rate` section chain per group). Short frames use
/// 3-bit section lengths with a 7-value escape instead of the long frames'
/// 5-bit lengths (35.3 in ISO/IEC 14496-3).
fn aac_encode_write_sections(bw : BitWriter, ch : AacEncChannel) -> Unit {
  let is8 = ch.window_sequence == aac_eight_short
  let bits = if is8 { 3 } else { 5 }
  let escape = (1 << bits) - 1
  let mut w = 0
  while w < ch.num_windows {
    let slotbase = if is8 { w * 16 } else { 0 }
    let mut b = 0
    while b < ch.max_sfb {
      let cb = ch.cb[slotbase + b]
      let mut e = b + 1
      while e < ch.max_sfb && ch.cb[slotbase + e] == cb {
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
    w = w + ch.group_len[w]
  }
}

///|
/// scale_factor_data: differential Huffman coding (60 = zero delta), walked
/// group by group with the three differential chains continuing across group
/// boundaries (`aacenc.c:629-661` steps `w += group_len[w]` and never resets
/// `off_sf`/`off_pns`/`off_is` between groups).
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
  let is8 = ch.window_sequence == aac_eight_short
  let mut off_sf = global_gain
  let mut off_pns = global_gain - aac_noise_offset
  let mut off_is = 0
  let mut noise_flag = true
  let mut w = 0
  while w < ch.num_windows {
    let slotbase = if is8 { w * 16 } else { 0 }
    for b = 0; b < ch.max_sfb; b = b + 1 {
      let slot = slotbase + b
      let cb = ch.cb[slot]
      if cb == aac_intensity_bt2 || cb == aac_intensity_bt {
        let d = ch.sf[slot] - off_is + 60
        off_is = ch.sf[slot]
        bw.put(aac_scalefactor_code[d], aac_scalefactor_bits[d])
        continue
      }
      if ch.sf[slot] < 0 {
        continue
      }
      let noise = cb == 13
      let diff = ch.sf[slot] - (if noise { off_pns } else { off_sf })
      if noise {
        off_pns = ch.sf[slot]
        if noise_flag {
          noise_flag = false
          bw.put(
            (diff + aac_noise_pre).reinterpret_as_uint(),
            aac_noise_pre_bits,
          )
          continue
        }
      } else {
        off_sf = ch.sf[slot]
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
    w = w + ch.group_len[w]
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
/// codebook 11) the escape sequences, in the decoder's read order - window
/// group, then band, then every window of the group (`aacenc.c:684-709`). With
/// one group of eight windows that is the band-major order this writer always
/// used, so single-group streams are unchanged bit for bit.
fn aac_encode_write_spectral(
  bw : BitWriter,
  ch : AacEncChannel,
  offsets : Array[Int32],
  codes : Array[Array[UInt32]],
  bits : Array[Array[Int32]],
  revs : Array[Array[Int32]],
) -> Unit {
  let is8 = ch.window_sequence == aac_eight_short
  let mut w = 0
  while w < ch.num_windows {
    let gl = ch.group_len[w]
    let slotbase = if is8 { w * 16 } else { 0 }
    for b = 0; b < ch.max_sfb; b = b + 1 {
      let cb = ch.cb[slotbase + b]
      // NOISE_BT carries no spectral data: the decoder synthesises it from the
      // scalefactor and its own LCG state. INTENSITY_BT/INTENSITY_BT2 carry none
      // either: `quantize_and_encode_band_cost_STEREO` writes nothing, and the
      // decoder rebuilds the band by scaling the left channel's.
      if !aac_encode_band_has_data(cb) {
        continue
      }
      let dim = if cb <= 4 { 4 } else { 2 }
      let table = cb - 1
      for w2 = 0; w2 < gl; w2 = w2 + 1 {
        let win = w + w2
        let mut i = win * 128 + offsets[b]
        let end = win * 128 + offsets[b + 1]
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
    w = w + gl
  }
}

///|
/// ics_info (spec 4.6.2.2) for one channel, written once for a common-window
/// CPE and therefore separated from the rest of the channel stream.
fn aac_encode_write_ics_info(bw : BitWriter, ch : AacEncChannel) -> Unit {
  let is8 = ch.window_sequence == aac_eight_short
  // reserved bit, window_sequence, window_shape (`use_kb_window[0]`).
  bw.put(0, 1)
  bw.put(ch.window_sequence.reinterpret_as_uint(), 2)
  bw.put(ch.window_shape.reinterpret_as_uint(), 1)
  if is8 {
    bw.put(ch.max_sfb.reinterpret_as_uint(), 4)
    // scale_factor_grouping (`put_ics_info`): bit w-1 set means window w
    // continues its group (`!group_len[w]`). One group of eight windows is
    // all ones, the `0x7f` this writer always emitted before §304.
    for w = 1; w < 8; w = w + 1 {
      bw.put(
        (if ch.group_len[w] == 0 { 1 } else { 0 }).reinterpret_as_uint(),
        1,
      )
    }
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
/// One channel's window plan for a frame: the sequence its own machine (or
/// the pair's shared one) emitted and everything the coder derives from it.
/// A `common_window` pair has two identical plans; when they differ the pair
/// is written as two independent ICS (`common_window = 0`, §309).
priv struct AacEncPlan {
  seq : Int32
  shape : Int32
  is8 : Bool
  num_swb : Int32
  offsets : Array[Int32]
  num_windows : Int32
  group_len : Array[Int32]
  use_psy : Bool
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
}

///|
/// Assemble one ADTS frame for a prepared frame and frame-wide scalefactor
/// offset `delta` (the transition/short-frame path, which keeps the simplified
/// perceptual model).
fn AacEncoder::build_frame(
  self : AacEncoder,
  frame : AacEncFrame,
  stereo : AacEncStereo,
  tns : Array[AacEncTns],
  max_sfb : Int32,
  delta : Int32,
) -> Result[Bytes, String] {
  let chans : Array[AacEncChannel] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let one = self.channel_data(
      frame.coefs[ch],
      frame.targets[ch],
      delta,
      frame.sequences[ch],
      max_sfb,
    )
    if ch == 1 {
      aac_encode_mark_is(one, stereo.is_bt, stereo.is_pos)
    }
    chans.push(one)
  }
  match self.assemble_frame(stereo, tns, [max_sfb, max_sfb], true, chans) {
    Ok((b, _)) => Ok(b)
    Err(e) => Err(e)
  }
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
/// Returns the frame bytes plus the exact pre-`ID_END` bit count: C's rate
/// control measures `put_bits_count` before writing `TYPE_END` and flushing,
/// so the byte-rounded payload size (which includes the 3 END bits and up to
/// 7 padding bits) must not feed the lambda ratio (§369).
/// `max_sfb` is per channel (a `common_window = 0` pair carries two
/// independent values); `plans` is the frame's per-channel window plans when
/// the caller has them (`None` on the simplified path, whose channels always
/// share one plan).
fn AacEncoder::assemble_frame(
  self : AacEncoder,
  stereo : AacEncStereo,
  tns : Array[AacEncTns],
  max_sfb : Array[Int32],
  common_window : Bool,
  chans : Array[AacEncChannel],
) -> Result[(Bytes, Int32), String] {
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
      tns[0],
      self.swb_offsets,
      self.short_offsets,
      self.spectral_codes,
      self.spectral_bits,
      self.spectral_rev,
    )
  } else {
    bw.put(1, 3) // ID_CPE
    bw.put(0, 4) // element_instance_tag
    bw.put(if common_window { 1 } else { 0 }, 1)
    if common_window {
      // One shared ics_info (ch0's) plus the mid/side mask; each channel
      // then writes global_gain and its body (`aacenc.c:999-1006`).
      aac_encode_write_ics_info(bw, chans[0])
      bw.put(stereo.ms_present.reinterpret_as_uint(), 2)
      // `encode_ms_info` (`aacenc.c:489-498`): mode 2 means every band is
      // mid/side, so the mask itself is not transmitted. Mode 1 writes one
      // bit per group-start slot, group by group.
      if stereo.ms_present == 1 {
        let mut w = 0
        while w < chans[0].num_windows {
          for b = 0; b < max_sfb[0]; b = b + 1 {
            bw.put(if stereo.ms_mask[w * 16 + b] { 1 } else { 0 }, 1)
          }
          w = w + chans[0].group_len[w]
        }
      }
    }
    for ch = 0; ch < 2; ch = ch + 1 {
      bw.put(aac_encode_global_gain(chans[ch]).reinterpret_as_uint(), 8)
      // `encode_individual_channel` (`aacenc.c:732`): a forked pair writes
      // each channel's own ics_info after its global gain.
      if not(common_window) {
        aac_encode_write_ics_info(bw, chans[ch])
      }
      aac_encode_write_channel_body(
        bw,
        chans[ch],
        tns[ch],
        self.swb_offsets,
        self.short_offsets,
        self.spectral_codes,
        self.spectral_bits,
        self.spectral_rev,
      )
    }
  }
  let pre_end_bits = bw.buf.length() * 8 + bw.nbits
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
  Ok((Bytes::from_array(out[:]), pre_end_bits))
}

///|
/// Encode one 1024-sample frame per channel into a single ADTS frame. The
/// input is planar float PCM in `[-1, 1]`; the first frame's 1024-sample
/// history is silence, so a decoder emits one priming frame before the input
/// samples (AAC's is 1024 samples of delay).
pub fn AacEncoder::encode_frame(
  self : AacEncoder,
  pcm : Array[Array[Double]],
) -> Result[Bytes?, String] {
  if pcm.length() != self.config.channels {
    return Err("AAC encoder input channel count mismatch")
  }
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    if pcm[ch].length() != 1024 {
      return Err("AAC encoder expects 1024 samples per channel")
    }
  }
  self.frames_encoded += 1
  self.flushed = false
  let bufs : Array[Array[Double]] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let buf : Array[Double] = Array::make(2048, 0.0)
    let hist = self.history[ch]
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = hist[i]
      buf[1024 + i] = pcm[ch][i]
      hist[i] = pcm[ch][i]
    }
    bufs.push(buf)
  }
  if self.config.perceptual {
    // The stock framing (verified against the oracle's packet pacing): the
    // window [f(k-2)|f(k-1)] is emitted one frame after its samples arrive,
    // because its window type is decided by `psy_lame_window`'s lookahead -
    // la = f(k-1)tail + f(k)head, which only the NEXT frame's buffer
    // provides. N frames therefore stream N-1 packets and the flush emits
    // the pending window plus the zero-padded tail (two packets).
    if self.frames_encoded == 1 {
      // The C's first call runs nothing (`if (!avctx->frame_num) return 0`):
      // no analyser cadence, no packet - just stash the window buffer.
      self.pending_bufs = bufs
      return Ok(None)
    }
    // Decide the pending window's type from this frame's lookahead region.
    let lame_grp : Array[Int32] = []
    let lame_uselong : Array[Bool] = []
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let d = self.lame[ch].analyze(bufs[ch], 523)
      // The emitted window's grouping is the byte the PREVIOUS analysis
      // stored (`pch->next_grouping`, read by the EIGHT_SHORT/LONG_START
      // cases of the current window's decision) - `wi_grp_pre` is exactly
      // that stored-before-this-call value. This call's own attack byte
      // goes into `next_grouping` for the next emission.
      lame_grp.push(d.wi_grp_pre)
      lame_uselong.push(d.uselong)
    }
    let sequences : Array[Int32] = []
    let shapes : Array[Int32] = []
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let (emit, next) = aac_lame_apply_block_type(
        self.lame_seq[ch],
        lame_uselong[ch],
      )
      self.lame_seq[ch] = next
      sequences.push(emit)
      shapes.push(aac_lame_window_shape(emit))
    }
    let built = match
      self.encode_pipeline(self.pending_bufs, sequences, shapes, lame_grp) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    // Feed the psy model the payload bits actually produced: FFmpeg's
    // `last_frame_pb_count` is the AAC frame without the ADTS header.
    self.last_frame_bits = (built.length() - av_aac_adts_header_size) * 8
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      self.prev_sequence[ch] = sequences[ch]
      self.use_kb[ch] = shapes[ch]
    }
    self.pending_bufs = bufs
    return Ok(Some(built))
  }
  // The simplified path is this port's own construction and stays
  // synchronous: the early/late attack machine decides the window from the
  // current frame alone, so every call emits its own packet.
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
  let sequences : Array[Int32] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
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
    sequences.push(seq)
  }
  let built = match
    self.encode_pipeline(
      bufs,
      sequences,
      Array::make(self.config.channels, 0),
      [],
    ) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  self.last_frame_bits = (built.length() - av_aac_adts_header_size) * 8
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    self.prev_sequence[ch] = sequences[ch]
    self.attack_pending[ch] = late[ch]
  }
  Ok(Some(built))
}

///|
/// The shared per-frame encode pipeline: window the overlap buffers and run
/// the psy model / quantisation / bitstream write for the already-decided
/// window sequences. `encode_frame` and `flush` both end here; `lame_grp`
/// carries the grouping byte per channel on the perceptual paths (it stays
/// empty on the simplified path, where the pipeline then uses the
/// all-in-one-group default). `shapes` is each channel's window shape for
/// this frame (all 0 on the simplified path); the previous frame's shape is
/// read from `use_kb`, which the caller advances afterwards.
fn AacEncoder::encode_pipeline(
  self : AacEncoder,
  bufs : Array[Array[Double]],
  sequences : Array[Int32],
  shapes : Array[Int32],
  lame_grp : Array[Int32],
) -> Result[Bytes, String] {
  let use_lame = self.config.perceptual
  let coefs : Array[Array[Double]] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    coefs.push(
      self.frame_coefficients(
        bufs[ch],
        sequences[ch],
        shapes[ch],
        self.use_kb[ch],
      ),
    )
  }
  // The frame's window plans, one per channel (§309): sequence, shape, band
  // plan and window grouping. FFmpeg drops `common_window` unless the two
  // channels' window types, shapes and groupings all match
  // (`aacenc.c:960-970`). Every non-LAME path shares one decision across
  // the pair, so they always come out common-window.
  let plans : Array[AacEncPlan] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let seq = sequences[ch]
    let is8 = seq == aac_eight_short
    // Short frames quantise through the psy/twoloop on every perceptual
    // configuration (the stock coder has no short-window opt-out).
    let use_psy = self.config.perceptual
    let group_len : Array[Int32] = if is8 {
      if use_lame && ch < lame_grp.length() {
        // The channel's own first-attack byte - FFmpeg stores it per
        // channel and the common-window check compares the expansions.
        aac_window_grouping_expand(lame_grp[ch])
      } else {
        [8, 0, 0, 0, 0, 0, 0, 0]
      }
    } else {
      [1, 0, 0, 0, 0, 0, 0, 0]
    }
    plans.push({
      seq,
      shape: shapes[ch],
      is8,
      num_swb: if is8 {
        self.num_short_swb
      } else {
        self.num_swb
      },
      offsets: if is8 {
        self.short_offsets
      } else {
        self.swb_offsets
      },
      num_windows: if is8 {
        8
      } else {
        1
      },
      group_len,
      use_psy,
    })
  }
  let common_window = if self.config.channels == 1 {
    true
  } else {
    plans[0].seq == plans[1].seq &&
    plans[0].shape == plans[1].shape &&
    (
      plans[0].seq != aac_eight_short ||
      (
        plans[0].group_len[1] == plans[1].group_len[1] &&
        plans[0].group_len[2] == plans[1].group_len[2] &&
        plans[0].group_len[3] == plans[1].group_len[3] &&
        plans[0].group_len[4] == plans[1].group_len[4] &&
        plans[0].group_len[5] == plans[1].group_len[5] &&
        plans[0].group_len[6] == plans[1].group_len[6] &&
        plans[0].group_len[7] == plans[1].group_len[7]
      )
    )
  }
  // The shared-plan aliases every non-LAME path keeps using.
  let is8 = plans[0].is8
  let num_swb = plans[0].num_swb
  let offsets = plans[0].offsets
  let num_windows = plans[0].num_windows
  let use_psy = plans[0].use_psy
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
  //
  // Since §302 the perceptual path can take both window shapes: `aac_psy.mbt`
  // analyses eight short windows (§300) and the quantiser search walks window
  // groups (§301); since §304 the short frames carry the LAME analyser's real
  // `scale_factor_grouping`; since §305 PNS runs on them, and since §306 so do
  // the stereo pair of tools - all of them walk `w += group_len[w]` upstream.
  //
  // The short-window half is opt-in (`perceptual_short`): with it off, a short
  // frame keeps the simplified model and every long-window baseline stream is
  // byte-for-byte what §301 produced.
  let use_is = self.config.is_stereo
  // The stereo pair of tools only exists on a common-window pair: both
  // searches early-return on `!cpe->common_window` upstream, and a forked
  // pair has no shared `ms_mask` to talk about (§309).
  // `aacenc.c` gates the two stereo searches independently
  // (`options.mid_side` / `options.intensity_stereo`); the port's combined
  // search runs when either tool is opted into. A plain perceptual
  // configuration runs neither (matching the harness's is=0/ms=0).
  let use_stereo_psy = self.config.channels == 2 &&
    common_window &&
    use_psy &&
    (self.config.is_stereo || self.config.mid_side)
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
  // quantiser turns them into per-band scalefactors. Both window shapes run
  // here (§300's analysis, §301's grouped search); a rate-control retry re-runs
  // the analysis - see the loop below (§289 deviation 2, closed in §297).
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
        self.psy.analyze(
          ch,
          coefs[ch],
          prev_bits,
          plans[ch].seq,
          self.prev_sequence[ch],
        ),
      )
    }
    // The plan only seeds TNS and the fallback bit-search: since §299 the
    // transmitted `max_sfb` comes from the quantiser's own `zeroes`. A short
    // frame's records live at `w * 16 + g`, so a band counts as planned if any
    // of its eight windows asked for bits.
    let slot_stride = if is8 { 16 } else { 1 }
    let slot_windows = if is8 { 8 } else { 1 }
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let bands = psy_results[ch].bands
      for b = 0; b < num_swb; b = b + 1 {
        let mut wanted = false
        for wi in 0..<slot_windows {
          let slot = wi * slot_stride + b
          if slot < bands.length() && bands[slot].bits > 0 {
            wanted = true
          }
        }
        if wanted && b + 1 > planned_max_sfb {
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
      let t = self.band_targets(coefs[ch], plans[ch].seq)
      for b = 0; b < num_swb; b = b + 1 {
        if t[b] >= 0 && b + 1 > planned_max_sfb {
          planned_max_sfb = b + 1
        }
      }
      targets.push(t)
    }
  }
  // TNS: analyse and filter each channel's upper bands, exactly the range the
  // decoder reconstructs from the shared max_sfb. Only the simplified path does
  // this once per frame: `aacenc.c:971-985` runs `search_for_tns` +
  // `apply_tns_filt` inside the rate-control loop, after the quantiser has
  // priced the band and before `search_for_pns`, on coefficients that the ABR
  // branch restores from `pcoeffs` first (`aacenc.c:1075`). The perceptual path
  // therefore does it per attempt below (§298), which also keeps `coefs`
  // pristine - so the analysis of every attempt, the first included, reads the
  // unfiltered spectrum, exactly like the reference.
  let tns : Array[AacEncTns] = []
  if !use_psy {
    for ch = 0; ch < self.config.channels; ch = ch + 1 {
      let data = self.search_tns(coefs[ch], planned_max_sfb, plans[ch].seq)
      aac_encode_apply_tns(coefs[ch], data, offsets, num_swb, num_windows)
      tns.push(data)
    }
  }
  if self.config.channels == 2 && !use_psy {
    for b = 0; b < planned_max_sfb; b = b + 1 {
      if stereo.ms_mask[b] {
        stereo.ms_present = 1
      }
    }
  }
  let frame : AacEncFrame = { coefs, targets, sequences, }
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
            plans[ch].seq,
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
      // The masking thresholds the intensity cost test compares against, one
      // row per channel (`aac_is_encoding_err` reads `band0->threshold` and
      // `band1->threshold`), in slot layout (`w * 16 + g` on a short frame).
      let thr : Array[Array[Double]] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let plan = plans[ch]
        let row : Array[Double] = if plan.is8 {
          Array::make(128, 0.0)
        } else {
          Array::make(plan.num_swb, 0.0)
        }
        for w = 0; w < plan.num_windows; w = w + 1 {
          for b = 0; b < plan.num_swb; b = b + 1 {
            row[w * 16 + b] = psy_iter[ch].bands[w * 16 + b].threshold
          }
        }
        thr.push(row)
      }
      let sizes : Array[Array[Int32]] = []
      let two_shapes : Array[AacTwoShape] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let plan = plans[ch]
        sizes.push(
          if plan.is8 {
            self.psy.band_sizes_short()
          } else {
            self.psy.band_sizes()
          },
        )
        two_shapes.push(
          if plan.is8 {
            aac_two_shape_short(plan.group_len)
          } else {
            aac_two_shape_long()
          },
        )
      }
      // One channel pair, one rate-control attempt: analyse, price and decide
      // noise on the left/right spectra first (`aacenc.c`'s order), then mix.
      let twos : Array[AacTwoResult] = []
      let cbs : Array[Array[Int32]] = []
      let zeros : Array[Array[Int32]] = []
      let sfi : Array[Array[Int32]] = []
      // The spectrum the bitstream codes, built per attempt: PNS, the stereo
      // tools and `channel_data_psy` all read the TNS-filtered copy, while
      // `coefs` stays the pristine MDCT output that the next attempt's analysis
      // and the next band's pricing look at (§298).
      let work : Array[Array[Double]] = []
      let tns_iter : Array[AacEncTns] = []
      // `aacenc.c:864` clamps `ics.max_sfb` to `num_swb` at frame start, and
      // that carried-over value - not this attempt's plan - is what bounds the
      // TNS search (`mmm` in `aacenc_tns.c`). Zero at the very start of a
      // stream, which is why FFmpeg's first frame never carries a filter.
      let tns_mmm : Array[Int32] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let cap = self.last_max_sfb[ch]
        tns_mmm.push(
          if cap < plans[ch].num_swb {
            cap
          } else {
            plans[ch].num_swb
          },
        )
      }
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let r = psy_iter[ch]
        let plan = plans[ch]
        let use_pns_ch = self.config.pns && (!plan.is8 || plan.use_psy)
        // `aacenc.c:931-933`: the element start drops the intensity band
        // types; `sf_idx`/`zeroes` (and the regular band types) stay sticky
        // across frames *and* rate-control attempts - the inner-window slots
        // of a short frame's groups keep what earlier frames left there, and
        // `search_for_pns` prices its per-window `dist1` against them.
        let st_sf = self.sticky_sf[ch]
        let st_cb = self.sticky_cb[ch]
        let st_z = self.sticky_zeroes[ch]
        for slot = 0; slot < 128; slot = slot + 1 {
          if st_cb[slot] > 12 {
            st_cb[slot] = 0
          }
        }
        // PNS runs around the search: mark noise-like bands, let the twoloop
        // rate loop price them, then decide which ones actually become noise.
        let mark = aac_pns_mark(
          r.bands,
          plan.offsets,
          plan.num_swb,
          two_shapes[ch],
          self.config.sample_rate,
          self.config.bit_rate,
          self.config.channels,
          self.lambda,
        )
        let can_pns = if use_pns_ch {
          mark.can_pns
        } else {
          Array::make(128, 0)
        }
        let two = aac_twoloop_search_pns(
          coefs[ch],
          sizes[ch],
          r.bands,
          alloc,
          self.config.bit_rate,
          self.config.sample_rate,
          self.config.channels,
          self.lambda,
          // `on` stays the *configuration* flag: C's bandwidth compensation
          // reads `options.pns || options.intensity_stereo`, which does not
          // depend on the window shape, even though this frame cannot use the
          // tool itself (§304 gives `search_for_pns` its group loop).
          aac_twoloop_pns(can_pns, self.config.pns, use_is),
          two_shapes[ch],
          // The search runs on the element's sticky slot arrays in C - its
          // rate loop scales every slot, so the inner-window slots it leaves
          // feed the next frame's `search_for_pns` pricing.
          sticky=aac_two_sticky(st_sf, st_cb, st_z),
        )
        // `aaccoder_twoloop.h:197`: the search writes its bandwidth into
        // `s->psy.cutoff`, which every later analysis (the next attempt's
        // and the next frame's) bands with (§371).
        self.psy.set_cutoff(two.bandwidth)
        twos.push(two)
        // `aacenc.c:971-985`: `search_for_tns` + `apply_tns_filt` run *after*
        // the quantiser has priced the band and before `search_for_pns`, on
        // coefficients the ABR branch has restored from `pcoeffs`
        // (`aacenc.c:1075-1077`) - so the filter never compounds across
        // attempts and the analysis above always saw the unfiltered spectrum.
        let tns_data = self.search_tns(
          coefs[ch],
          tns_mmm[ch],
          plan.seq,
          psy_bands=r.bands,
        )
        tns_iter.push(tns_data)
        let w = coefs[ch].copy()
        aac_encode_apply_tns(
          w,
          tns_data,
          plan.offsets,
          plan.num_swb,
          plan.num_windows,
        )
        work.push(w)
        let mut noise_sfi : Array[Int32] = Array::make(128, 0)
        if use_pns_ch {
          let out = aac_pns_search(
            aac_pns_search_in(
              w,
              sizes[ch],
              plan.offsets,
              r.bands,
              two_shapes[ch],
              st_sf,
              st_cb,
              st_z,
              can_pns,
              mark.pns_ener,
              self.pns_random_state,
            ),
            self.config.sample_rate,
            self.config.bit_rate,
            self.config.channels,
            self.lambda,
          )
          self.pns_random_state = out.random_state
          // The decisions land back on the element's arrays (C mutates
          // `sce->band_type`/`sce->zeroes` in place).
          for slot = 0; slot < 128; slot = slot + 1 {
            st_cb[slot] = out.cb[slot]
            st_z[slot] = out.zeroes[slot]
          }
          noise_sfi = out.noise_sfi
        }
        cbs.push(st_cb)
        zeros.push(st_z)
        sfi.push(noise_sfi)
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
      if use_stereo_psy {
        let (psy_st, ms) = aac_encode_stereo_psy(
          work,
          sizes[0],
          thr,
          twos,
          cbs,
          zeros,
          plans[0].offsets,
          plans[0].num_swb,
          plans[0].num_windows,
          plans[0].group_len,
          self.config.sample_rate,
          self.lambda,
          use_is,
        )
        st = psy_st
        sf_ch[0] = ms.sf0
        cb_ch[0] = ms.cb0
        sf_ch[1] = ms.sf1
        cb_ch[1] = ms.cb1
        // The element carries the stereo rewrites into the next frame: the
        // search writes group-start slots only, but the next frame's grouping
        // can turn one of them into an inner window, whose twoloop rate loop
        // then scales from the rewritten value.  Zeroes are untouched by both
        // tools, so only sf/band_type flow back into the sticky arrays.
        // The arrays are slot-length on a short frame and band-length on a
        // long one, so each write is bounded by its own array.
        for slot = 0; slot < ms.sf0.length(); slot = slot + 1 {
          self.sticky_sf[0][slot] = ms.sf0[slot]
          self.sticky_cb[0][slot] = ms.cb0[slot]
        }
        for slot = 0; slot < ms.sf1.length(); slot = slot + 1 {
          self.sticky_sf[1][slot] = ms.sf1[slot]
          self.sticky_cb[1][slot] = ms.cb1[slot]
        }
      }
      // `adjust_frame_information` (`aacenc.c:503-547`), once per attempt:
      // per channel, each group's trailing-zero trim over its start slots
      // (max over groups), then the in-group zeroes merge - a band stays
      // coded for the group when any of its windows is non-zero. On fresh
      // twoloop arrays the merge is the identity (an inner 1 only ever comes
      // from this frame's twoloop cutoff path, so the merged group-start
      // slot equals twoloop's own decision; FFmpeg's sticky-array variant is
      // a documented §304 deviation) - it still runs, so `zeros` carries the
      // group-image `channel_data_psy` reads. A common-window pair then
      // shares the larger `max_sfb`; a forked one keeps two independent
      // values (§309).
      let iter_max_sfb : Array[Int32] = Array::make(self.config.channels, 0)
      for ch in 0..<self.config.channels {
        let plan = plans[ch]
        let mut cmaxsfb = 0
        let mut w = 0
        while w < plan.num_windows {
          let mut group_max = plan.num_swb
          while group_max > 0 && zeros[ch][w * 16 + group_max - 1] != 0 {
            group_max = group_max - 1
          }
          if group_max > cmaxsfb {
            cmaxsfb = group_max
          }
          w = w + plan.group_len[w]
        }
        let mut wg = 0
        while wg < plan.num_windows {
          for b = 0; b < cmaxsfb; b = b + 1 {
            let mut allzero = 1
            let w2_stop = wg + plan.group_len[wg]
            let mut w2 = wg
            while w2 < w2_stop {
              if zeros[ch][w2 * 16 + b] == 0 {
                allzero = 0
                break
              }
              w2 = w2 + 1
            }
            zeros[ch][wg * 16 + b] = allzero
          }
          wg = wg + plan.group_len[wg]
        }
        iter_max_sfb[ch] = cmaxsfb
      }
      if common_window && self.config.channels == 2 {
        // A common-window pair shares `ics.max_sfb` (`aacenc.c:537-539`);
        // a forked one keeps two independent values.
        if iter_max_sfb[1] > iter_max_sfb[0] {
          iter_max_sfb[0] = iter_max_sfb[1]
        }
        if iter_max_sfb[0] > iter_max_sfb[1] {
          iter_max_sfb[1] = iter_max_sfb[0]
        }
      }
      // `ms_mode` (`aacenc.c:544-547`): 0 with no marked band, 2 when every
      // band of every window is marked - and then the mask itself is not
      // transmitted at all. The count walks every window's slots (not the
      // groups), because that is the total the comparison divides by; only a
      // common-window pair has a mask to count.
      let mut msc = 0
      if common_window && self.config.channels == 2 {
        for w = 0; w < plans[0].num_windows; w = w + 1 {
          for b = 0; b < iter_max_sfb[0]; b = b + 1 {
            if st.ms_mask[w * 16 + b] {
              msc = msc + 1
            }
          }
        }
      }
      st.ms_present = if msc == 0 || iter_max_sfb[0] == 0 {
        0
      } else if msc < iter_max_sfb[0] * plans[0].num_windows {
        1
      } else {
        2
      }
      // The next attempt's TNS search reads this value (`aacenc.c:864`), and
      // so does the next frame's - per channel now.
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        self.last_max_sfb[ch] = iter_max_sfb[ch]
      }
      let chans : Array[AacEncChannel] = []
      for ch = 0; ch < self.config.channels; ch = ch + 1 {
        let plan = plans[ch]
        // `encode_band_info` (`aacenc.c:615-627`): the trellis rewrites each
        // group's codebooks (and zero bands) on the element's sticky arrays
        // right before anything is quantised for the bitstream. With no
        // mid/side rewrite `cb_ch[ch]`/`zeros[ch]` already are those sticky
        // arrays; after one, the mid/side copies must flow back like the
        // write-back above did (`aacenc.c`'s trellis mutates `sce->band_type`
        // in place).
        aac_encode_codebook_trellis(
          work[ch],
          sf_ch[ch],
          cb_ch[ch],
          zeros[ch],
          sizes[ch],
          plan.num_windows,
          plan.group_len,
          iter_max_sfb[ch],
          plan.is8,
        )
        if use_stereo_psy {
          for slot = 0; slot < cb_ch[ch].length(); slot = slot + 1 {
            self.sticky_cb[ch][slot] = cb_ch[ch][slot]
          }
        }
        let one = aac_encode_channel_data_psy(
          work[ch],
          sf_ch[ch],
          plan.seq,
          plan.shape,
          iter_max_sfb[ch],
          cb_ch[ch],
          zeros[ch],
          sfi[ch],
          plan.offsets,
          plan.num_windows,
          plan.group_len,
        )
        if ch == 1 && common_window {
          aac_encode_mark_is(one, st.is_bt, st.is_pos)
        }
        chans.push(one)
      }
      let (frame_bytes, frame_bits) = match
        self.assemble_frame(st, tns_iter, iter_max_sfb, common_window, chans) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      built = frame_bytes
      // `aacenc.c`'s ABR rate control (`bit_rate_tolerance != 0`, the
      // library default and what the reference encoder runs): the psy
      // allocation raises the target above the nominal bitrate, a stability
      // window of roughly +-12.5% around it decides between full and damped
      // sqrt steps, and a stable update terminates the retry. The strict
      // `tolerance == 0` branch (shrink until the frame fits, reset lambda)
      // has no iteration cap upstream and hangs on frames that cannot fit,
      // so it is not the alignment target. All ratio steps are f32.
      let cap = 6144 * self.config.channels - 3
      // `aacenc.c:943-951`: bitres.alloc is reset to -1 before each
      // element's analyze, every channel's calc_bit_demand overwrites the
      // shared value, and the accumulator adds ONCE per element with the
      // LAST channel's allocation - not per channel.
      let last_alloc = psy_iter[psy_iter.length() - 1].alloc
      let mut target_bits = 0
      if last_alloc > 0 {
        target_bits = aac_two_mul(
          last_alloc.to_double(),
          aac_two_div(self.lambda, 120.0),
        ).to_int()
      }
      let rate_capped = if rate_bits < cap { rate_bits } else { cap }
      let many0 = if target_bits > rate_capped {
        target_bits
      } else {
        rate_capped
      }
      let many0 = if many0 < cap { many0 } else { cap }
      let few0 = rate_bits - rate_bits / 4
      let few1 = if few0 > target_bits { few0 } else { target_bits }
      let too_few0 = if few1 < many0 { few1 } else { many0 }
      let too_few = too_few0 - too_few0 / 8
      let too_many = many0 + many0 / 2
      let in_stable = frame_bits >= too_few && frame_bits <= too_many
      if its == 0 ||
        (its < 5 && (frame_bits < too_few || frame_bits > too_many)) ||
        frame_bits >= cap {
        let mut ratio = aac_two_div(
          rate_capped.to_double(),
          frame_bits.to_double(),
        )
        if in_stable {
          ratio = aac_two_sqrtf(aac_two_sqrtf(ratio))
          ratio = aac_two_clipf(ratio, 0.9, 1.1)
        } else {
          ratio = aac_two_sqrtf(ratio)
        }
        self.lambda = aac_two_clipf(
          aac_two_mul(self.lambda, ratio),
          1.1920928955078125e-07,
          65536.0,
        )
        // A stable update ends the retry; the pcoeffs restore upstream is
        // implicit here - every attempt rebuilds `work` from the pristine
        // `coefs`.
        if ratio > 0.9 && ratio < 1.1 {
          break
        }
        its = its + 1
      } else {
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
      let built = match
        self.build_frame(frame, stereo, tns, planned_max_sfb, mid) {
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
  Ok(built)
}

///|
/// Flush the encoder: the final frame FFmpeg's `AV_CODEC_CAP_DELAY` path
