///|
/// `search_for_pns`, FFmpeg 9.0.2 `libavcodec/aaccoder.c:489`, restricted to
/// one long window. Runs *after* the twoloop search: it decides which bands
/// are cheaper to send as noise (`NOISE_BT = 13`) than as quantised spectrum.
///
/// Six gates, all from the psy band records plus the twoloop result:
///   1. above `NOISE_LOW_LIMIT` (4 kHz) and below the bandwidth cutoff;
///   2. the scalefactor chain allows the band to be removed;
///   3. near-threshold energy (both too quiet and too loud are rejected);
///   4. psy spread says the band is noise-like;
///   5. the noise scalefactor fits the ±60 delta chain from the previous
///      noise band;
///   6. the generated noise's energy ratio lands in (0.85, 1.25) and its
///      estimated RD cost beats the regular quantisation.
///
/// The LCG state is carried across frames (`s->random_state`); the noise
/// samples are `(float)lcg_random(state)`, i.e. an int-to-float conversion,
/// not a bit-pattern reinterpretation.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `NOISE_LAMBDA_REPLACE` / `NOISE_SPREAD_THRESHOLD` / `NOISE_LOW_LIMIT`,
/// `aaccoder.c:55-59` and `aaccoder_twoloop.h:54`, plus the acceptance window
/// `0.85f .. 1.25f` (`aaccoder.c:619`). Everything except `NOISE_LOW_LIMIT` is
/// stored as the binary32 value the reference multiplies with: these constants
/// sit on the far side of a comparison against a float sum
/// (`spread < spread_threshold`, `sfb_energy > threshold*thr_mult*freq_boost`,
/// `energy_ratio > 0.85f`), so the decimal in the source is not the operand.
let aac_pns_lambda_replace : Double = 1.9479999542236328
let aac_pns_spread_thr : Double = 0.8999999761581421
let aac_pns_energy_ratio_lo : Double = 0.8500000238418579
let aac_pns_energy_ratio_hi : Double = 1.25

///|
/// `0.88f` in `freq_boost = FFMAX(0.88f*freq/NOISE_LOW_LIMIT, 1.0f)`
/// (`aaccoder.c:538`).
let aac_pns_freq_boost_scale : Double = 0.8799999952316284

///|
/// `NOISE_BT` (`aac.h:75`): the band type a PNS band becomes.
let aac_pns_noise_bt : Int32 = 13

///|
/// Everything `search_for_pns` needs from the frame: the spectrum, the swb
/// plan, the psy bands, the twoloop outcome and the `mark_pns` outcome.
pub struct AacPnsSearchIn {
  coefs : Array[Double]
  band_sizes : Array[Int32]
  offsets : Array[Int32]
  bands : Array[AacPsyBandInfo]
  sf : Array[Int32]
  cb : Array[Int32]
  zeroes : Array[Int32]
  can_pns : Array[Int32]
  pns_ener : Array[Double]
  random_state : Int32
}

///|
/// Build the input (the struct's fields are private to the package).
pub fn aac_pns_search_in(
  coefs : Array[Double],
  band_sizes : Array[Int32],
  offsets : Array[Int32],
  bands : Array[AacPsyBandInfo],
  sf : Array[Int32],
  cb : Array[Int32],
  zeroes : Array[Int32],
  can_pns : Array[Int32],
  pns_ener : Array[Double],
  random_state : Int32,
) -> AacPnsSearchIn {
  {
    coefs,
    band_sizes,
    offsets,
    bands,
    sf,
    cb,
    zeroes,
    can_pns,
    pns_ener,
    random_state,
  }
}

///|
/// What the pass changes: the final band types (13 for noise), the zero flags,
/// the noise energy estimates and the carried LCG state. `sf_idx` is untouched
/// — the noise level in the bitstream comes from it, not from `pns_ener`.
pub struct AacPnsSearchOut {
  cb : Array[Int32]
  zeroes : Array[Int32]
  pns_ener : Array[Double]
  random_state : Int32
  /// `noise_sfi` for the bands turned into NOISE_BT: the scalefactor whose
  /// `pow2sf_tab` entry is the generated noise's amplitude
  /// (`noise_amp = -pow2sf_tab[sfi + POW_SF2_ZERO]`). The bitstream writes
  /// this into the independent noise scalefactor chain, so the decoder's
  /// `sfo` reproduces `noise_amp` without any offset fudging.
  noise_sfi : Array[Int32]
}

///|
/// `roundf` (half away from zero), used for `noise_sfi`.
fn aac_pns_roundf(v : Double) -> Int32 {
  if v >= 0.0 {
    (v + 0.5).to_int()
  } else {
    (v - 0.5).to_int()
  }
}

///|
/// `search_for_pns` for one long window.
pub fn aac_pns_search(
  input : AacPnsSearchIn,
  sample_rate : Int32,
  bit_rate : Int32,
  channels : Int32,
  lambda : Double,
) -> AacPnsSearchOut {
  let coefs = input.coefs
  let band_sizes = input.band_sizes
  let offsets = input.offsets
  let bands = input.bands
  let sf = input.sf
  // Work on copies: the caller's twoloop result is still used to quantise
  // the surviving spectral bands, so a band turned into NOISE_BT here must
  // not overwrite its original codebook there.
  let cb : Array[Int32] = Array::make(input.cb.length(), 0)
  for i = 0; i < input.cb.length(); i = i + 1 {
    cb[i] = input.cb[i]
  }
  let zeroes : Array[Int32] = Array::make(input.zeroes.length(), 0)
  for i = 0; i < input.zeroes.length(); i = i + 1 {
    zeroes[i] = input.zeroes[i]
  }
  let pns_ener : Array[Double] = Array::make(input.pns_ener.length(), 0.0)
  for i = 0; i < input.pns_ener.length(); i = i + 1 {
    pns_ener[i] = input.pns_ener[i]
  }
  let num_swb = band_sizes.length()
  let wlen = 1024
  // The frame-wide factors of `search_for_pns` (`aaccoder.c:499-522`), each in
  // the precision the reference evaluates it in.
  let freq_mult = aac_two_div(aac_two_mul(sample_rate.to_double(), 0.5),
    wlen.to_double())
  let thr_mult = aac_two_mul(
    aac_pns_lambda_replace,
    aac_two_div(100.0, lambda),
  )
  let spread_boost = aac_psy_maxf(0.5, aac_two_div(lambda, 100.0))
  let spread_threshold = aac_psy_minf(
    0.75,
    aac_two_mul(aac_pns_spread_thr, spread_boost),
  )
  let dist_bias = aac_two_clipf(aac_two_div(480.0, lambda), 0.25, 4.0)
  let pns_transient_energy_r = aac_psy_minf(0.7, aac_two_div(lambda, 140.0))
  // `frame_bit_rate *= 1.15f` on an `int`: integer division first, then a
  // single-precision multiply truncated back (`aaccoder.c:512-516`).
  let fbr_boost = aac_two_mul(
    (bit_rate / channels).to_double(),
    aac_two_tool_bitrate_boost,
  )
  let fbr = fbr_boost.to_int()
  let bw = aac_psy_cutoff(fbr, 1, sample_rate)
  let bandwidth = if bw > 3000 { bw } else { 3000 }
  // `cutoff = bandwidth * 2 * wlen / avctx->sample_rate` with every operand an
  // `int` (`aaccoder.c:523`), so this is integer division, not a float one.
  let cutoff = bandwidth * 2 * wlen / sample_rate
  // `band_alt` is a snapshot of the twoloop band types.
  let band_alt : Array[Int32] = Array::make(cb.length(), 0)
  for g = 0; g < cb.length(); g = g + 1 {
    band_alt[g] = cb[g]
  }
  let nextband = aac_two_init_nextband_map(zeroes, cb, num_swb, aac_two_shape_long())
  let mut random_state = input.random_state
  let mut prev = -1000
  let mut prev_sf = -1
  let noise_sfi_out : Array[Int32] = Array::make(num_swb, 0)
  let pns : Array[Double] = Array::make(128, 0.0)
  for g = 0; g < num_swb; g = g + 1 {
    let start = offsets[g]
    // `freq = (start-wstart)*freq_mult` is a float multiply (`aaccoder.c:535`).
    let freq = aac_two_mul(start.to_double(), freq_mult)
    if freq < aac_pns_low_limit || start >= cutoff {
      if zeroes[g] == 0 {
        prev_sf = sf[g]
      }
      continue
    }
    let band = bands[g]
    let sfb_energy = band.energy
    let threshold = band.threshold
    let spread = band.spread
    let min_energy = sfb_energy
    let max_energy = sfb_energy
    let freq_boost = aac_psy_maxf(
      aac_two_div(aac_two_mul(aac_pns_freq_boost_scale, freq), aac_pns_low_limit),
      1.0,
    )
    let dist_thresh = aac_two_mul(
      aac_two_clipf(
        aac_two_div(2.5 * aac_pns_low_limit, freq), 0.5, 2.5,
      ),
      dist_bias,
    )
    let removable = zeroes[g] == 0 &&
      !aac_two_can_remove_band(sf, nextband, prev_sf, g)
    let quiet = (zeroes[g] != 0 || band_alt[g] == 0) &&
      sfb_energy < aac_two_mul(
        threshold,
        aac_two_sqrtf(aac_two_div(1.0, freq_boost)),
      )
    let loud_boost = aac_two_mul(threshold, thr_mult)
    let loud = zeroes[g] == 0 && band_alt[g] != 0 &&
      sfb_energy > aac_two_mul(loud_boost, freq_boost)
    let transient =
      min_energy < aac_two_mul(pns_transient_energy_r, max_energy)
    if removable || quiet || spread < spread_threshold || loud || transient {
      pns_ener[g] = sfb_energy
      if zeroes[g] == 0 {
        prev_sf = sf[g]
      }
      continue
    }
    let spread_sq = aac_two_mul(spread, spread)
    let pns_tgt_energy = aac_two_mul(sfb_energy,
      if spread_sq < 1.0 { spread_sq } else { 1.0 })
    let sfi = aac_two_clip(
      aac_pns_roundf(aac_two_log2f(pns_tgt_energy) * 2.0), -100, 155,
    )
    let noise_amp = -aac_twoloop_pow2sf[sfi + aac_two_pow_sf2_zero]
    if prev != -1000 {
      let noise_sfdiff = sfi - prev + aac_two_scale_diff_zero
      if noise_sfdiff < 0 || noise_sfdiff > 2 * aac_two_scale_max_diff {
        if zeroes[g] == 0 {
          prev_sf = sf[g]
        }
        continue
      }
    }
    // Generate the noise at the target amplitude and estimate both costs.
    let size = band_sizes[g]
    for i = 0; i < size; i = i + 1 {
      random_state = aac_lcg_random(random_state)
      pns[i] = aac_two_f32(random_state.to_double())
    }
    let mut band_energy = 0.0
    for i = 0; i < size; i = i + 1 {
      band_energy = aac_two_add(band_energy, aac_two_mul(pns[i], pns[i]))
    }
    let scale = aac_two_div(noise_amp, aac_two_sqrtf(band_energy))
    for i = 0; i < size; i = i + 1 {
      pns[i] = aac_two_mul(pns[i], scale)
    }
    let mut pns_energy = 0.0
    for i = 0; i < size; i = i + 1 {
      pns_energy = aac_two_add(pns_energy, aac_two_mul(pns[i], pns[i]))
    }
    let scaled : Array[Double] = Array::make(size, 0.0)
    for i = 0; i < size; i = i + 1 {
      let a = aac_two_f32(coefs[start + i].abs())
      scaled[i] = aac_two_sqrtf(aac_two_mul(a, aac_two_sqrtf(a)))
    }
    let qcoefs : Array[Int32] = Array::make(size, 0)
    let d1 = aac_two_band_cost(
      coefs,
      start,
      scaled,
      0,
      qcoefs,
      size,
      sf[g],
      band_alt[g],
      aac_two_div(lambda, threshold),
    )
    let dist1 = d1.cost
    // `dist2 += band->energy/(band->spread*band->spread)*lambda*dist_thresh/
    // band->threshold` (`aaccoder.c:608`) is one single-precision expression,
    // and the 5 or 9 bits of scalefactor/codebook overhead are added *after*
    // it, as a separate float add.
    let dist2_spread_sq = aac_two_mul(spread, spread)
    let dist2_e = aac_two_div(band.energy, dist2_spread_sq)
    let dist2_l = aac_two_mul(dist2_e, lambda)
    let dist2_t = aac_two_mul(dist2_l, dist_thresh)
    let dist2_b = aac_two_div(dist2_t, threshold)
    let overhead = if g > 0 && cb[g - 1] == aac_pns_noise_bt {
      5.0
    } else {
      9.0
    }
    let dist2 = aac_two_add(dist2_b, overhead)
    let energy_ratio = if pns_energy > 0.0 {
      aac_two_div(pns_tgt_energy, pns_energy)
    } else {
      0.0
    }
    pns_ener[g] = aac_two_mul(energy_ratio, pns_tgt_energy)
    if zeroes[g] != 0 || band_alt[g] == 0 ||
      (energy_ratio > aac_pns_energy_ratio_lo &&
        energy_ratio < aac_pns_energy_ratio_hi && dist2 < dist1) {
      cb[g] = aac_pns_noise_bt
      zeroes[g] = 0
      noise_sfi_out[g] = sfi
      prev = sfi
    } else if zeroes[g] == 0 {
      prev_sf = sf[g]
    }
  }
  { cb, zeroes, pns_ener, random_state, noise_sfi: noise_sfi_out }
}
