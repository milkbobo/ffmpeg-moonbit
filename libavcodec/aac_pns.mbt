///|
/// Perceptual noise substitution, encoder side: `mark_pns` from FFmpeg 9.0.2
/// `libavcodec/aaccoder.c:631`, both window shapes - one long window or the
/// eight short windows walked in their `w += group_len[w]` groups.
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
/// `mark_pns` (`aaccoder.c:631`) for both window shapes: `bands` are the psy
/// band records in C's slot layout (`g` for a long frame, `w * 16 + g` for a
/// short one), `offsets` the scalefactor band offsets (`num_swb + 1` entries,
/// within-window), `shape` the window grouping the quantiser will search.
///
/// On a short frame a band's gates are computed for its whole window group:
/// energy and threshold are summed over the group's windows, the spread takes
/// the minimum, and a group whose quietest window falls below
/// `pns_transient_energy_r` of its loudest one is rejected outright - PNS
/// would flatten exactly the energy step the block switching was there to
/// preserve (`aaccoder.c:664-676`).
///
/// `bit_rate` / `channels` / `sample_rate` mirror `avctx`, and `lambda` is the
/// rate-control lambda (`s->lambda`, 120 in ABR).
pub fn aac_pns_mark(
  bands : Array[AacPsyBandInfo],
  offsets : Array[Int32],
  num_swb : Int32,
  shape : AacTwoShape,
  sample_rate : Int32,
  bit_rate : Int32,
  channels : Int32,
  lambda : Double,
) -> AacPnsMark {
  let num_windows = shape.num_windows
  let group_len = shape.group_len
  // Long frames keep the plain band indices (the single window's slots are
  // `0..num_swb`); short frames carry the full `w * 16 + g` space.
  let slots = if num_windows == 1 { num_swb } else { 128 }
  let can_pns : Array[Int32] = Array::make(slots, 0)
  let pns_ener : Array[Double] = Array::make(slots, 0.0)
  let wlen = 1024 / num_windows
  let freq_mult = sample_rate.to_double() * 0.5 / wlen.to_double()
  let spread_threshold = aac_psy_minf(
    0.75,
    aac_pns_spread_threshold * aac_psy_maxf(0.5, lambda / 100.0),
  )
  // `pns_transient_energy_r = FFMIN(0.7f, lambda / 140.f)`: a group survives
  // only when its quietest window keeps this fraction of the loudest one.
  let transient_ratio = aac_psy_minf(0.7, lambda / 140.0)
  // `mark_pns` recomputes the bandwidth from the *per channel* bitrate scaled
  // by 1.15 (the same "compensate for extensions" factor twoloop applies when
  // PNS is on), so the cutoff is slightly wider than the psy model's.
  let per_channel = bit_rate / channels
  let frame_bit_rate = (per_channel.to_double() * 1.15).to_int()
  let model_bandwidth = aac_psy_cutoff(frame_bit_rate, 1, sample_rate)
  let bandwidth = if model_bandwidth > 3000 { model_bandwidth } else { 3000 }
  // `cutoff = bandwidth * 2 * wlen / sample_rate` (`aaccoder.c:652`): every
  // operand is an `int`, so this is integer division of the within-window
  // sample offset at which the encoder's bandwidth ends.
  let cutoff = bandwidth * 2 * wlen / sample_rate
  let mut w = 0
  while w < num_windows {
    let gl = group_len[w]
    for g = 0; g < num_swb; g = g + 1 {
      let slot = w * 16 + g
      let start = offsets[g]
      let freq = start.to_double() * freq_mult
      if freq < aac_pns_low_limit || start >= cutoff {
        continue
      }
      let mut sfb_energy = 0.0
      let mut threshold = 0.0
      let mut spread = 2.0
      let mut min_energy = -1.0
      let mut max_energy = 0.0
      for w2 = 0; w2 < gl; w2 = w2 + 1 {
        let band = bands[(w + w2) * 16 + g]
        sfb_energy = sfb_energy + band.energy
        threshold = threshold + band.threshold
        if band.spread < spread {
          spread = band.spread
        }
        if w2 == 0 {
          min_energy = band.energy
          max_energy = band.energy
        } else if band.energy < min_energy {
          min_energy = band.energy
        } else if band.energy > max_energy {
          max_energy = band.energy
        }
      }
      pns_ener[slot] = sfb_energy
      let freq_boost = aac_psy_maxf(0.88 * freq / aac_pns_low_limit, 1.0)
      let limit = threshold * (1.5 / freq_boost).sqrt()
      can_pns[slot] = if sfb_energy < limit ||
        spread < spread_threshold ||
        min_energy < transient_ratio * max_energy {
        0
      } else {
        1
      }
    }
    w = w + gl
  }
  { can_pns, pns_ener, bandwidth, }
}
