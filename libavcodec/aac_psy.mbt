///|
/// 3GPP psychoacoustic model for the AAC encoder.
///
/// Port of FFmpeg 9.0.2 `libavcodec/aacpsy.c` (`psy_3gpp_init`,
/// `calc_thr_3gpp`, `psy_3gpp_analyze_channel`, `calc_bit_demand`,
/// `calc_pe_3gpp`, `calc_reduction_3gpp`, `calc_reduced_thr_3gpp`) plus the
/// band/context plumbing of `psymodel.c`.  It replaces the simplified
/// "band energy + upward spreading + SNR aim" model in `aac_encode.mbt`.
///
/// Scope of this first slice (matches `_ref/aacenc/vectors.txt`): one long
/// window (`num_windows = 1`, `ONLY_LONG_SEQUENCE`), ABR (no QSCALE), PNS /
/// TNS / IS / M-S off, no block switching.  Short-window coefficient tables
/// are still built by `init` because `psy_3gpp_init` computes both sets, but
/// `analyze` only exercises the long set.  `bitres.bits` (bits consumed by
/// the previous frame) is an explicit parameter so a real bitstream writer can
/// feed it later.
///
/// Numerics: FFmpeg runs this model in `float` (f32).  All state below is
/// `Float`, with f32 libm twins for `log2f` / `exp2f` / `exp10f`.  The
/// reference harness is MinGW-W64 libm, so a few ulps of divergence are
/// expected in threshold/PE; the regression tests use relative tolerances.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// `PSY_3GPP_*` constants, `aacpsy.c:45-93`.
let psy_thr_spread_hi : Double = 1.5
let psy_thr_spread_low : Double = 3.0
let psy_en_spread_hi_l1 : Double = 2.0
let psy_en_spread_hi_s : Double = 1.5
let psy_en_spread_low_l : Double = 3.0
let psy_en_spread_low_s : Double = 2.0
let psy_rpemin : Double = 0.01
let psy_rpelev : Double = 2.0
let psy_c1 : Double = 3.0
let psy_c2 : Double = 1.3219281
let psy_c3 : Double = 0.55935729
let psy_snr_1db : Double = 7.9432821e-1
let psy_snr_25db : Double = 3.1622776e-3
let psy_save_slope_l : Double = -0.46666667
let psy_save_add_l : Double = -0.84285712
let psy_spend_slope_l : Double = 0.66666669
let psy_spend_add_l : Double = -0.35
let psy_clip_lo_l : Double = 0.2
let psy_clip_hi_l : Double = 0.95
let psy_save_slope_s : Double = -0.36363637
let psy_save_add_s : Double = -0.75
let psy_spend_slope_s : Double = 0.81818181
let psy_spend_add_s : Double = -0.26111111
let psy_clip_lo_s : Double = 0.2
let psy_clip_hi_s : Double = 0.75
let psy_ah_thr_long : Double = 0.5
let psy_pe_forget_slope : Double = 511.0
let psy_ath_add : Double = 4.0
let psy_rpe_thr_coeff : Double = 0.001258925
let psy_bits_to_pe : Double = 1.18
let psy_ah_none : Int32 = 0
let psy_ah_inactive : Int32 = 1
let psy_ah_active : Int32 = 2

///|
/// f32 libm twins. `@math` has no `log2f`/`exp2f`/`exp10f`; compute in f64
/// and round once to f32 (C stores every one of these results in a `float`),
/// which is within an ulp of the MinGW f32 libm entries on the test inputs.
fn aac_psy_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
fn aac_psy_log2f(x : Double) -> Double {
  aac_psy_f32(@math.log2(x))
}

///|
fn aac_psy_exp2f(x : Double) -> Double {
  aac_psy_f32(@math.pow(2.0, x))
}

///|
fn aac_psy_exp10f(x : Double) -> Double {
  aac_psy_f32(@math.pow(10.0, x))
}

///|
fn aac_psy_clipf(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
fn aac_psy_maxf(a : Double, b : Double) -> Double {
  if a > b { a } else { b }
}

///|
fn aac_psy_minf(a : Double, b : Double) -> Double {
  if a < b { a } else { b }
}

///|
/// `calc_bark`, `aacpsy.c:280`.
fn aac_psy_calc_bark(f : Double) -> Double {
  aac_psy_f32(
    13.3 * @math.atan(0.00076 * f) +
    3.5 * @math.atan((f / 7500.0) * (f / 7500.0)),
  )
}

///|
/// `ath`, `aacpsy.c:290`. The C body is entirely double (the literals carry
/// no `f` suffix); only the result is stored into a float field.
fn aac_psy_ath(f : Double, add : Double) -> Double {
  let x = f / 1000.0
  let d = 3.64 * @math.pow(x, -0.8) -
    6.8 * @math.exp(-0.6 * (x - 3.4) * (x - 3.4)) +
    6.0 * @math.exp(-0.15 * (x - 8.7) * (x - 8.7)) +
    (0.6 + 0.04 * add) * 0.001 * x * x * x * x
  aac_psy_f32(d)
}

///|
/// Per-band static coefficients (`AacPsyCoeffs`, `aacpsy.c:112-130`).
struct AacPsyCoeffs {
  mut barks : Double
  mut spread_hi_thr : Double
  mut spread_low_thr : Double
  mut spread_hi_en : Double
  mut spread_low_en : Double
  mut min_snr : Double
  mut ath : Double
}

///|
fn aac_psy_new_coeffs() -> AacPsyCoeffs {
  {
    barks: 0.0,
    spread_hi_thr: 0.0,
    spread_low_thr: 0.0,
    spread_hi_en: 0.0,
    spread_low_en: 0.0,
    min_snr: 0.0,
    ath: 0.0,
  }
}

///|
/// Per-band running state (`AacPsyBand`, `aacpsy.c:112-130`). `prev_band`
/// keeps the previous frame's copy for pre-echo control.
struct AacPsyBandState {
  mut thr : Double
  mut thr_quiet : Double
  mut energy : Double
  mut nz_lines : Double
  mut pe : Double
  mut pe_const : Double
  mut active_lines : Double
  mut norm_fac : Double
  mut avoid_holes : Int32
}

///|
fn aac_psy_new_band() -> AacPsyBandState {
  {
    thr: 0.0,
    thr_quiet: 0.0,
    energy: 0.0,
    nz_lines: 0.0,
    pe: 0.0,
    pe_const: 0.0,
    active_lines: 0.0,
    norm_fac: 0.0,
    avoid_holes: psy_ah_none,
  }
}

///|
/// One published band result (`FFPsyBand`, `psymodel.h:50`).
pub struct AacPsyBandInfo {
  energy : Double
  threshold : Double
  spread : Double
  bits : Int32
}

///|
/// Result of one frame of analysis.
pub struct AacPsyResult {
  bands : Array[AacPsyBandInfo]
  alloc : Int32
  entropy : Double
  fill_level : Int32
}

///|
/// 3GPP psy context. Construct with `aac_psy_new`, then call
/// `analyze` once per frame; the instance owns all cross-frame state
/// (`prev_band`, `fill_level`, `pe.min/max`, `pe.previous`).
pub struct AacPsyContext {
  sample_rate : Int32
  bit_rate : Int32
  channels : Int32
  chan_bitrate : Int32
  frame_bits : Int32
  bitres_size : Int32
  mut fill_level : Int32
  mut pe_min : Double
  mut pe_max : Double
  mut pe_previous : Double
  coeffs_long : Array[AacPsyCoeffs]
  coeffs_short : Array[AacPsyCoeffs]
  band_sizes : Array[Int32]
  band_sizes_short : Array[Int32]
  prev_band : Array[AacPsyBandState]
  bands : Array[AacPsyBandState]
  mut alloc : Int32
  mut entropy : Double
}

///|
/// `AAC_CUTOFF_FROM_BITRATE` / `AAC_CUTOFF`, `psymodel.h:35-45`. Only the
/// ABR branch is needed here (the reference harness uses `flags = 0`).
fn aac_psy_cutoff(bit_rate : Int32, channels : Int32, sample_rate : Int32) -> Int32 {
  let per_chan = bit_rate / channels
  let a = if per_chan / 5 > per_chan * 15 / 32 - 5500 {
    per_chan / 5
  } else {
    per_chan * 15 / 32 - 5500
  }
  let b = 3000 + per_chan / 4
  let c = 12000 + per_chan / 16
  let mut m = a
  if b < m { m = b }
  if c < m { m = c }
  if 22000 < m { m = 22000 }
  if sample_rate / 2 < m { m = sample_rate / 2 }
  m
}

///|
/// Build the scalefactor band size table from the existing offset tables
/// (`aac_tables.mbt`), for one sampling-frequency index.
fn aac_psy_band_sizes(offsets : Array[UInt32], num : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for g in 0..<num {
    out.push(
      offsets[g + 1].reinterpret_as_int() - offsets[g].reinterpret_as_int(),
    )
  }
  out
}

///|
/// `psy_3gpp_init`, `aacpsy.c:299`. Builds both the long and short window
/// coefficient sets. `sampling_index` indexes the MPEG-4 sample rate table,
/// e.g. 4 == 44100 Hz.
fn aac_psy_init_coeffs(
  ctx : AacPsyContext,
  sampling_index : Int32,
  bandwidth : Int32,
) -> Unit {
  let sr = ctx.sample_rate.to_double()
  let num_bark = aac_psy_calc_bark(bandwidth.to_double())
  let minath = aac_psy_ath(3410.0 - 0.733 * psy_ath_add, psy_ath_add)
  for j in 0..<2 {
    let sizes = if j == 0 { ctx.band_sizes } else { ctx.band_sizes_short }
    let coeffs = if j == 0 { ctx.coeffs_long } else { ctx.coeffs_short }
    let line_to_frequency = sr / (if j == 1 { 256.0 } else { 2048.0 })
    let avg_chan_bits = ctx.chan_bitrate.to_double() *
      (if j == 1 { 128.0 } else { 1024.0 }) / sr
    let bark_pe = 0.024 * (avg_chan_bits * psy_bits_to_pe) / num_bark
    let en_spread_low = if j == 1 {
      psy_en_spread_low_s
    } else {
      psy_en_spread_low_l
    }
    // Upstream compares a bitrate in bits/s with 22 (kbps); reproduced
    // verbatim: for any real ABR bitrate the long path selects HI_L1.
    let en_spread_hi = if j == 1 || ctx.chan_bitrate.to_double() <= 22.0 {
      psy_en_spread_hi_s
    } else {
      psy_en_spread_hi_l1
    }
    let mut i = 0.0
    let mut prev = 0.0
    for g in 0..<sizes.length() {
      i += sizes[g].to_double()
      let bark = aac_psy_calc_bark((i - 1.0) * line_to_frequency)
      coeffs[g].barks = (bark + prev) / 2.0
      prev = bark
    }
    for g in 0..<(sizes.length() - 1) {
      // aacpsy.c:352 is `coeffs[g+1].barks - coeffs->barks`, NOT
      // `coeff->barks`: `coeffs` is the array pointer, so this is the
      // cumulative width from band 0, not the width of band g.  Using the
      // adjacent difference silently zeroes every min_snr to the -25 dB
      // floor and wrecks the whole reduction stage.
      let bark_width = coeffs[g + 1].barks - coeffs[0].barks
      coeffs[g].spread_low_thr = aac_psy_exp10f(
        -bark_width * psy_thr_spread_low,
      )
      coeffs[g].spread_hi_thr = aac_psy_exp10f(
        -bark_width * psy_thr_spread_hi,
      )
      coeffs[g].spread_low_en = aac_psy_exp10f(-bark_width * en_spread_low)
      coeffs[g].spread_hi_en = aac_psy_exp10f(-bark_width * en_spread_hi)
      let pe_min = bark_pe * bark_width
      let minsnr = aac_psy_exp2f(pe_min / sizes[g].to_double()) - 1.5
      coeffs[g].min_snr = aac_psy_clipf(
        1.0 / minsnr,
        psy_snr_25db,
        psy_snr_1db,
      )
    }
    let mut start = 0
    for g in 0..<sizes.length() {
      let mut minscale = aac_psy_ath(
        start.to_double() * line_to_frequency,
        psy_ath_add,
      )
      for k in 1..<sizes[g] {
        let v = aac_psy_ath(
          (start + k).to_double() * line_to_frequency,
          psy_ath_add,
        )
        if v < minscale { minscale = v }
      }
      coeffs[g].ath = minscale - minath
      start += sizes[g]
    }
  }
  let _ = sampling_index
}

///|
/// `calc_bit_demand`, `aacpsy.c:492`. Updates `fill_level` and the
/// self-adjusting `pe.min`/`pe.max` window and returns `desired_bits`.
fn AacPsyContext::bit_demand(
  self : AacPsyContext,
  pe : Double,
  bits : Int32,
  short_window : Bool,
) -> Int32 {
  let save_slope = if short_window {
    psy_save_slope_s
  } else {
    psy_save_slope_l
  }
  let save_add = if short_window { psy_save_add_s } else { psy_save_add_l }
  let spend_slope = if short_window {
    psy_spend_slope_s
  } else {
    psy_spend_slope_l
  }
  let spend_add = if short_window {
    psy_spend_add_s
  } else {
    psy_spend_add_l
  }
  let clip_lo = if short_window { psy_clip_lo_s } else { psy_clip_lo_l }
  let clip_hi = if short_window { psy_clip_hi_s } else { psy_clip_hi_l }
  self.fill_level += self.frame_bits - bits
  let mut fl = self.fill_level
  if fl < 0 { fl = 0 }
  if fl > self.bitres_size { fl = self.bitres_size }
  self.fill_level = fl
  let fill_level = aac_psy_clipf(
    fl.to_double() / self.bitres_size.to_double(),
    clip_lo,
    clip_hi,
  )
  let clipped_pe = aac_psy_clipf(pe, self.pe_min, self.pe_max)
  let bit_save = (fill_level + save_add) * save_slope
  let bit_spend = (fill_level + spend_add) * spend_slope
  let bit_factor = 1.0 - bit_save +
    ((bit_spend - bit_save) / (self.pe_max - self.pe_min)) *
      (clipped_pe - self.pe_min)
  if pe > self.pe_max { self.pe_max = pe }
  let forgetful_min_pe = (self.pe_min * psy_pe_forget_slope +
    aac_psy_maxf(self.pe_min, pe * (pe / self.pe_max))) /
    (psy_pe_forget_slope + 1.0)
  self.pe_min = aac_psy_minf(pe, forgetful_min_pe)
  let want = self.frame_bits.to_double() * bit_factor
  let cap = if self.frame_bits + self.bitres_size - bits > self.frame_bits / 8 {
    (self.frame_bits + self.bitres_size - bits).to_double()
  } else {
    (self.frame_bits / 8).to_double()
  }
  let target = if want < cap { want } else { cap }
  target.to_int()
}

///|
/// `calc_pe_3gpp`, `aacpsy.c:535`. Returns the band's PE and refreshes its
/// `pe_const` / `active_lines` fields.
fn aac_psy_calc_pe(band : AacPsyBandState) -> Double {
  band.pe = 0.0
  band.pe_const = 0.0
  band.active_lines = 0.0
  if band.energy > band.thr {
    let mut a = aac_psy_log2f(band.energy)
    let mut pe = a - aac_psy_log2f(band.thr)
    band.active_lines = band.nz_lines
    if pe < psy_c1 {
      pe = pe * psy_c3 + psy_c2
      a = a * psy_c3 + psy_c2
      band.active_lines *= psy_c3
    }
    band.pe = pe * band.nz_lines
    band.pe_const = a * band.nz_lines
  }
  band.pe
}

///|
/// `calc_reduction_3gpp`, `aacpsy.c:558`.
fn aac_psy_calc_reduction(
  a : Double,
  desired_pe : Double,
  pe : Double,
  active_lines : Double,
) -> Double {
  if active_lines == 0.0 {
    return 0.0
  }
  let thr_avg = aac_psy_exp2f((a - pe) / (4.0 * active_lines))
  let reduction = aac_psy_exp2f(
      (a - desired_pe) / (4.0 * active_lines),
    ) - thr_avg
  aac_psy_maxf(reduction, 0.0)
}

///|
/// `calc_reduced_thr_3gpp`, `aacpsy.c:572`.
fn aac_psy_calc_reduced_thr(
  band : AacPsyBandState,
  min_snr : Double,
  reduction : Double,
) -> Double {
  let mut thr = band.thr
  if band.energy > thr {
    // C: thr = sqrtf(thr); thr = sqrtf(thr) + reduction; thr *= thr; thr *= thr;
    // i.e. (sqrt(sqrt(thr)) + reduction)^4, not a product of mixed roots.
    let first = thr.sqrt()
    let raised = first.sqrt() + reduction
    thr = raised * raised
    thr = thr * thr
    if thr > band.energy * min_snr && band.avoid_holes != psy_ah_none {
      thr = aac_psy_maxf(band.thr, band.energy * min_snr)
      band.avoid_holes = psy_ah_active
    }
  }
  thr
}

///|
/// `calc_thr_3gpp`, `aacpsy.c:597`. Only the `num_windows = 1` case is
/// needed here; `cutoff` is a coefficient index, not a frequency.
fn AacPsyContext::calc_thr(
  self : AacPsyContext,
  coefs : Array[Double],
  cutoff : Int32,
) -> Unit {
  let mut start = 0
  let mut wstart = 0
  for g in 0..<self.band_sizes.length() {
    let band = self.bands[g]
    let mut energy = 0.0
    let mut form_factor = 0.0
    if wstart < cutoff {
      for i in 0..<self.band_sizes[g] {
        let c = coefs[start + i]
        energy += c * c
        form_factor += c.abs().sqrt()
      }
    }
    let temp = if energy > 0.0 {
      (self.band_sizes[g].to_double() / energy).sqrt()
    } else {
      0.0
    }
    band.energy = energy
    band.thr = energy * psy_rpe_thr_coeff
    band.nz_lines = form_factor * temp.sqrt()
    start += self.band_sizes[g]
    wstart += self.band_sizes[g]
  }
}

///|
/// Create a 3GPP psy context. `sampling_index` is the MPEG-4 sample rate
/// index (4 == 44100 Hz). `bit_rate` is the total stream bitrate; the
/// per-channel bitrate is derived exactly as `psy_3gpp_init` does.
pub fn aac_psy_new(
  sampling_index : Int32,
  sample_rate : Int32,
  bit_rate : Int32,
  channels : Int32,
) -> AacPsyContext {
  let nlong = aac_num_swb_1024[sampling_index]
  let nshort = aac_num_swb_128[sampling_index]
  let sizes = aac_psy_band_sizes(aac_swb_offset_1024[sampling_index], nlong)
  let sizes_short = aac_psy_band_sizes(
    aac_swb_offset_128[sampling_index],
    nshort,
  )
  let coeffs_long : Array[AacPsyCoeffs] = []
  let coeffs_short : Array[AacPsyCoeffs] = []
  let prev_band : Array[AacPsyBandState] = []
  let bands : Array[AacPsyBandState] = []
  for _ in 0..<128 {
    coeffs_long.push(aac_psy_new_coeffs())
    coeffs_short.push(aac_psy_new_coeffs())
    prev_band.push(aac_psy_new_band())
    bands.push(aac_psy_new_band())
  }
  let chan_bitrate = bit_rate / channels
  let frame_bits = if chan_bitrate * 1024 / sample_rate < 2560 {
    chan_bitrate * 1024 / sample_rate
  } else {
    2560
  }
  let bandwidth = aac_psy_cutoff(bit_rate, channels, sample_rate)
  let size0 = 6144 - frame_bits
  let bitres_size = size0 - size0 % 8
  let ctx : AacPsyContext = {
    sample_rate,
    bit_rate,
    channels,
    chan_bitrate,
    frame_bits,
    bitres_size,
    fill_level: bitres_size,
    pe_min: 8.0 * 1024.0 * bandwidth.to_double() /
      (sample_rate.to_double() * 2.0),
    pe_max: 12.0 * 1024.0 * bandwidth.to_double() /
      (sample_rate.to_double() * 2.0),
    pe_previous: 0.0,
    coeffs_long,
    coeffs_short,
    band_sizes: sizes,
    band_sizes_short: sizes_short,
    prev_band,
    bands,
    alloc: -1,
    entropy: 0.0,
  }
  aac_psy_init_coeffs(ctx, sampling_index, bandwidth)
  ctx
}

///|
/// Run one frame of 3GPP analysis on `coefs` (1024 f32 MDCT coefficients in
/// the encoder's coefficient domain). `prev_bits` is `bitres.bits` (bits
/// consumed by the previous frame); the reference harness uses 0.
///
/// This is `psy_3gpp_analyze_channel`, `aacpsy.c:646`, restricted to one
/// long window. The returned bands are the `FFPsyBand` array that the
/// twoloop quantizer consumes.
pub fn AacPsyContext::analyze(
  self : AacPsyContext,
  coefs : Array[Double],
  prev_bits : Int32,
) -> AacPsyResult {
  let num_bands = self.band_sizes.length()
  let coeffs = self.coeffs_long
  let bandwidth = aac_psy_cutoff(
    self.bit_rate,
    self.channels,
    self.sample_rate,
  )
  let cutoff = bandwidth * 2048 / self.sample_rate
  let avoid_hole_thr = psy_ah_thr_long
  // 5.4.2 threshold calculation
  self.calc_thr(coefs, cutoff)
  // 5.4.2.3 spreading + 5.4.3 spread energy (one window, w = 0)
  let spread_en : Array[Double] = Array::make(128, 0.0)
  spread_en[0] = self.bands[0].energy
  for g in 1..<num_bands {
    let b = self.bands[g]
    let bm = self.bands[g - 1]
    let t = aac_psy_maxf(b.thr, bm.thr * coeffs[g].spread_hi_thr)
    b.thr = t
    spread_en[g] = aac_psy_maxf(
      b.energy,
      spread_en[g - 1] * coeffs[g].spread_hi_en,
    )
  }
  for g = num_bands - 2; g >= 0; g = g - 1 {
    let b = self.bands[g]
    let bp = self.bands[g + 1]
    b.thr = aac_psy_maxf(b.thr, bp.thr * coeffs[g].spread_low_thr)
    spread_en[g] = aac_psy_maxf(
      spread_en[g],
      spread_en[g + 1] * coeffs[g].spread_low_en,
    )
  }
  let mut pe = if self.chan_bitrate > 32000 {
    0.0
  } else {
    aac_psy_maxf(50.0, 100.0 - self.chan_bitrate.to_double() * 100.0 / 32000.0)
  }
  let mut a = 0.0
  let mut active_lines = 0.0
  for g in 0..<num_bands {
    let b = self.bands[g]
    b.thr = aac_psy_maxf(b.thr, coeffs[g].ath)
    b.thr_quiet = b.thr
    // 5.4.2.5 pre-echo control. With ONLY_LONG / w=0 the guard is false,
    // so the reduction is applied using the previous frame's quiet threshold.
    let prevq = self.prev_band[g].thr_quiet
    b.thr = aac_psy_maxf(
      psy_rpemin * b.thr,
      aac_psy_minf(b.thr, psy_rpelev * prevq),
    )
    pe += aac_psy_calc_pe(b)
    a += b.pe_const
    active_lines += b.active_lines
    // 5.6.1.3.3 selection of bands for avoidance of holes
    b.avoid_holes = if spread_en[g] * avoid_hole_thr > b.energy ||
      coeffs[g].min_snr > 1.0 {
      psy_ah_none
    } else {
      psy_ah_inactive
    }
  }
  self.entropy = pe
  let desired_bits = self.bit_demand(pe, prev_bits, false)
  let mut desired_pe = desired_bits.to_double() * psy_bits_to_pe
  if prev_bits > 0 {
    let ratio = aac_psy_clipf(
      self.pe_previous / (prev_bits.to_double() * psy_bits_to_pe),
      0.85,
      1.15,
    )
    desired_pe = desired_pe * ratio
  }
  self.pe_previous = desired_bits.to_double() * psy_bits_to_pe
  self.alloc = desired_bits
  if desired_pe < pe {
    // 5.6.1.3.4 first estimation of the reduction value
    let mut reduction = aac_psy_calc_reduction(a, desired_pe, pe, active_lines)
    pe = 0.0
    a = 0.0
    active_lines = 0.0
    for g in 0..<num_bands {
      let b = self.bands[g]
      b.thr = aac_psy_calc_reduced_thr(b, coeffs[g].min_snr, reduction)
      pe += aac_psy_calc_pe(b)
      a += b.pe_const
      active_lines += b.active_lines
    }
    // 5.6.1.3.5 second estimation (two passes)
    let mut delta_pe = 0.0
    let mut norm_fac_total = 0.0
    for _ in 0..<2 {
      let mut pe_no_ah = 0.0
      let mut a2 = 0.0
      let mut al2 = 0.0
      for g in 0..<num_bands {
        let b = self.bands[g]
        if b.avoid_holes != psy_ah_active {
          pe_no_ah += b.pe
          a2 += b.pe_const
          al2 += b.active_lines
        }
      }
      let desired_pe_no_ah = aac_psy_maxf(desired_pe - (pe - pe_no_ah), 0.0)
      if al2 > 0.0 {
        reduction = aac_psy_calc_reduction(a2, desired_pe_no_ah, pe_no_ah, al2)
      }
      pe = 0.0
      for g in 0..<num_bands {
        let b = self.bands[g]
        if al2 > 0.0 {
          b.thr = aac_psy_calc_reduced_thr(b, coeffs[g].min_snr, reduction)
        }
        pe += aac_psy_calc_pe(b)
        b.norm_fac = if b.thr > 0.0 {
          b.active_lines / b.thr
        } else {
          0.0
        }
        norm_fac_total += b.norm_fac
      }
      delta_pe = desired_pe - pe
      if (delta_pe.abs() > 0.05 * desired_pe) {
        break
      }
    }
    if pe < 1.15 * desired_pe {
      // 5.6.1.3.6 final threshold modification by linearization
      let inv = if norm_fac_total > 0.0 {
        1.0 / norm_fac_total
      } else {
        0.0
      }
      for g in 0..<num_bands {
        let b = self.bands[g]
        if b.active_lines > 0.5 {
          let delta_sfb_pe = b.norm_fac * inv * delta_pe
          let mut thr = b.thr *
            aac_psy_exp2f(delta_sfb_pe / b.active_lines)
          if thr > coeffs[g].min_snr * b.energy &&
            b.avoid_holes == psy_ah_inactive {
            thr = aac_psy_maxf(b.thr, coeffs[g].min_snr * b.energy)
          }
          b.thr = thr
        }
      }
    } else {
      // 5.6.1.3.7 further PE reduction: raise min_snr from the top band down
      for g = num_bands - 1; g >= 0 && pe > desired_pe; g = g - 1 {
        let b = self.bands[g]
        if b.avoid_holes != psy_ah_none && coeffs[g].min_snr < psy_snr_1db {
          coeffs[g].min_snr = psy_snr_1db
          b.thr = b.energy * psy_snr_1db
          pe += b.active_lines * 1.5 - b.pe
        }
      }
    }
  }
  // publish FFPsyBand + commit prev_band (aacpsy.c:827-839)
  let out : Array[AacPsyBandInfo] = []
  for g in 0..<num_bands {
    let b = self.bands[g]
    let pb = self.prev_band[g]
    out.push({
      energy: b.energy,
      threshold: b.thr,
      spread: b.active_lines * 2.0 / self.band_sizes[g].to_double(),
      bits: (b.pe / psy_bits_to_pe).to_int(),
    })
    pb.thr = b.thr
    pb.thr_quiet = b.thr_quiet
    pb.energy = b.energy
    pb.nz_lines = b.nz_lines
    pb.pe = b.pe
    pb.pe_const = b.pe_const
    pb.active_lines = b.active_lines
    pb.norm_fac = b.norm_fac
    pb.avoid_holes = b.avoid_holes
  }
  {
    bands: out,
    alloc: self.alloc,
    entropy: self.entropy,
    fill_level: self.fill_level,
  }
}
