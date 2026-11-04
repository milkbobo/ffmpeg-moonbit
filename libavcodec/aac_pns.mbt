///|
/// Perceptual noise substitution, encoder side: `mark_pns` from FFmpeg 9.0.2
/// `libavcodec/aaccoder.c:631`, restricted to one long window.
///
/// `mark_pns` decides, band by band, whether the spectrum may be replaced by
/// noise (`can_pns`) and records the band energy the later `search_for_pns`
/// pass estimates its rate-distortion trade with (`pns_ener`). Three gates,
/// all from the 3GPP model's band records:
///
///   1. the band has to sit above `NOISE_LOW_LIMIT` (4 kHz where PNS becomes
///      inaudible) and below the encoder's bandwidth cutoff, so both the
///      frequency and the sample offset are checked;
///   2. its energy must be within `sqrt(1.5 / freq_boost)` of the masking
///      threshold — a band far below it is already inaudible, and the
///      `search_for_pns` pass rejects bands far above it because the random
///      nature of the noise would be audible (that gate lives there, not here);
///   3. the psy spread (active lines / band width) must reach
///      `spread_threshold`, i.e. the band has to look noise-like rather than
///      tonal. At lambda 120 the threshold is 0.75.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `NOISE_LOW_LIMIT`, `aaccoder_twoloop.h:54`.
let aac_pns_low_limit : Double = 4000.0

///|
/// `NOISE_SPREAD_THRESHOLD`, `aaccoder.c:55`.
let aac_pns_spread_threshold : Double = 0.9

///|
/// What `mark_pns` publishes for one frame.
pub struct AacPnsMark {
  /// 1 where the band may be coded as noise, 0 otherwise.
  can_pns : Array[Int32]
  /// Band energy seen by the model (the `search_for_pns` trade-off input).
  pns_ener : Array[Double]
  /// The bandwidth (Hz) this pass used. The C encoder writes its value back
  /// into `s->psy.cutoff`, where it sticks for the following frames, so the
  /// caller has to hand it to the psy context.
  bandwidth : Int32
}

///|
/// `mark_pns` for one long window: `bands` are the psy band records of the
/// frame, `offsets` the scalefactor band offsets (`num_swb + 1` entries).
///
/// `bit_rate` / `channels` / `sample_rate` mirror `avctx`, and `lambda` is the
/// rate-control lambda (`s->lambda`, 120 in ABR).
pub fn aac_pns_mark(
  bands : Array[AacPsyBandInfo],
  offsets : Array[Int32],
  num_swb : Int32,
  sample_rate : Int32,
  bit_rate : Int32,
  channels : Int32,
  lambda : Double,
) -> AacPnsMark {
  let can_pns : Array[Int32] = Array::make(num_swb, 0)
  let pns_ener : Array[Double] = Array::make(num_swb, 0.0)
  let wlen = 1024.0
  let freq_mult = sample_rate.to_double() * 0.5 / wlen
  let spread_threshold = aac_psy_minf(
    0.75,
    aac_pns_spread_threshold * aac_psy_maxf(0.5, lambda / 100.0),
  )
  // `mark_pns` recomputes the bandwidth from the *per channel* bitrate scaled
  // by 1.15 (the same "compensate for extensions" factor twoloop applies when
  // PNS is on), so the cutoff is slightly wider than the psy model's.
  let per_channel = bit_rate / channels
  let frame_bit_rate = (per_channel.to_double() * 1.15).to_int()
  let model_bandwidth = aac_psy_cutoff(frame_bit_rate, 1, sample_rate)
  let bandwidth = if model_bandwidth > 3000 { model_bandwidth } else { 3000 }
  // `cutoff = bandwidth * 2 * wlen / sample_rate` (`aaccoder.c:548`): the
  // sample offset at which the encoder's bandwidth ends.
  let cutoff = (bandwidth.to_double() * 2.0 * wlen / sample_rate.to_double()).to_int()
  for g in 0..<num_swb {
    let start = offsets[g]
    let freq = start.to_double() * freq_mult
    if freq < aac_pns_low_limit || start >= cutoff {
      continue
    }
    let band = bands[g]
    pns_ener[g] = band.energy
    let freq_boost = aac_psy_maxf(0.88 * freq / aac_pns_low_limit, 1.0)
    let limit = band.threshold * (1.5 / freq_boost).sqrt()
    can_pns[g] = if band.energy < limit || band.spread < spread_threshold {
      0
    } else {
      1
    }
  }
  { can_pns, pns_ener, bandwidth }
}
