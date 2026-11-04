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
/// `aaccoder.c:55-59` and `aaccoder_twoloop.h:54`.
let aac_pns_lambda_replace : Double = 1.948
let aac_pns_spread_thr : Double = 0.9
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
  let cb = input.cb
  let zeroes = input.zeroes
  let pns_ener = input.pns_ener
  let num_swb = band_sizes.length()
  let wlen = 1024
  let freq_mult = sample_rate.to_double() * 0.5 / wlen.to_double()
  let thr_mult = aac_pns_lambda_replace * (100.0 / lambda)
  let spread_threshold = aac_psy_minf(
    0.75,
    aac_pns_spread_thr * aac_psy_maxf(0.5, lambda / 100.0),
  )
  let dist_bias = aac_two_clipf(4.0 * 120.0 / lambda, 0.25, 4.0)
  let pns_transient_energy_r = aac_psy_minf(0.7, lambda / 140.0)
  let fbr = (bit_rate.to_double() / channels.to_double() * 1.15).to_int()
  let bw = aac_psy_cutoff(fbr, 1, sample_rate)
  let bandwidth = if bw > 3000 { bw } else { 3000 }
  let cutoff = (bandwidth.to_double() * 2.0 * wlen.to_double() /
    sample_rate.to_double()).to_int()
  // `band_alt` is a snapshot of the twoloop band types.
  let band_alt : Array[Int32] = Array::make(cb.length(), 0)
  for g = 0; g < cb.length(); g = g + 1 {
    band_alt[g] = cb[g]
  }
  let nextband = aac_two_init_nextband_map(zeroes, cb, num_swb)
  let mut random_state = input.random_state
  let mut prev = -1000
  let mut prev_sf = -1
  let pns : Array[Double] = Array::make(128, 0.0)
  for g = 0; g < num_swb; g = g + 1 {
    let start = offsets[g]
    let freq = start.to_double() * freq_mult
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
    let freq_boost = aac_psy_maxf(0.88 * freq / aac_pns_low_limit, 1.0)
    let dist_thresh = aac_two_mul(
      aac_two_clipf(
        aac_two_div(2.5 * aac_pns_low_limit, freq), 0.5, 2.5,
      ),
      dist_bias,
    )
    let removable = zeroes[g] == 0 &&
      !aac_two_can_remove_band(sf, nextband, prev_sf, g)
    let quiet = (zeroes[g] != 0 || band_alt[g] == 0) &&
      sfb_energy < aac_two_mul(threshold, aac_two_sqrtf(1.0 / freq_boost))
    let loud = zeroes[g] == 0 && band_alt[g] != 0 &&
      sfb_energy > threshold * thr_mult * freq_boost
    let transient = min_energy < pns_transient_energy_r * max_energy
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
    let noise_sfi = aac_two_clip(
      aac_pns_roundf(aac_two_log2f(pns_tgt_energy) * 2.0), -100, 155,
    )
    let noise_amp = -aac_twoloop_pow2sf[noise_sfi + aac_two_pow_sf2_zero]
    if prev != -1000 {
      let noise_sfdiff = noise_sfi - prev + aac_two_scale_diff_zero
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
      coefs, start, scaled, 0, qcoefs, size, sf[g], band_alt[g],
      lambda / threshold,
    )
    let dist1 = d1.cost
    let dist2 = band.energy / aac_two_mul(spread, spread) * lambda *
      dist_thresh / threshold + (if g > 0 && cb[g - 1] == aac_pns_noise_bt {
      5.0
    } else {
      9.0
    })
    let energy_ratio = if pns_energy > 0.0 {
      aac_two_div(pns_tgt_energy, pns_energy)
    } else {
      0.0
    }
    pns_ener[g] = aac_two_mul(energy_ratio, pns_tgt_energy)
    if zeroes[g] != 0 || band_alt[g] == 0 ||
      (energy_ratio > 0.85 && energy_ratio < 1.25 && dist2 < dist1) {
      cb[g] = aac_pns_noise_bt
      zeroes[g] = 0
      prev = noise_sfi
    } else if zeroes[g] == 0 {
      prev_sf = sf[g]
    }
  }
  { cb, zeroes, pns_ener, random_state }
}
