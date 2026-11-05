///|
/// 3GPP psychoacoustic model for the AAC encoder.
///
/// Port of FFmpeg 9.0.2 `libavcodec/aacpsy.c` (`psy_3gpp_init`,
/// `calc_thr_3gpp`, `psy_3gpp_analyze_channel`, `calc_bit_demand`,
/// `calc_pe_3gpp`, `calc_reduction_3gpp`, `calc_reduced_thr_3gpp`) plus the
/// band/context plumbing of `psymodel.c`.  It replaces the simplified
/// "band energy + upward spreading + SNR aim" model in `aac_encode.mbt`.
///
/// Scope: ABR (no QSCALE), PNS / TNS / IS / M-S off. Both window shapes of
/// `psy_3gpp_analyze_channel` are transcribed — one long window
/// (`ONLY_LONG`/`LONG_START`/`LONG_STOP`, 49 bands at 44.1 kHz) and eight short
/// windows (`EIGHT_SHORT`, 14 bands of 128 lines each, the `w += 16` per-window
/// chains) — with `psy_3gpp_init`'s two coefficient sets and two band plans.
/// `bitres.bits` (bits consumed by the previous frame) is an explicit parameter
/// so a real bitstream writer can feed it later. The encoder still routes only
/// long frames through this model; the multi-window quantiser search is what
/// consumes a short frame's bands.
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
let psy_ah_thr_short : Double = 0.6299999952316284
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
/// Result of one frame of analysis. `bands` is C's `psy_bands` slot array: the
/// record of window `w`, band `g` sits at `w * 16 + g`, so `num_windows` says
/// how far the stride goes and `num_bands` how many bands each window has.
pub struct AacPsyResult {
  bands : Array[AacPsyBandInfo]
  num_windows : Int32
  num_bands : Int32
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
  /// Per-channel state, one entry per channel (`AacPsyChannel` in
  /// `aacpsy.c`): the band records of the frame being analysed and the copy of
  /// the previous frame's that pre-echo control reads.
  bands : Array[Array[AacPsyBandState]]
  prev_band : Array[Array[AacPsyBandState]]
  /// Per-channel perceptual entropy of the last analysed frame.
  entropy : Array[Double]
  /// Bandwidth the quantiser settled on (Hz), 0 = derive from the bit rate.
  /// Written back by the caller once the quantiser has run, exactly like
  /// `s->psy.cutoff = bandwidth` in the C encoder.
  mut cutoff : Int32
  /// Element-level allocation (`bitres.alloc`), shared by the channels of one
  /// element exactly like `FFPsyContext.bitres` is.
  mut alloc : Int32
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
/// `calc_thr_3gpp`, `aacpsy.c:597`. `cutoff` is a coefficient index, not a
/// frequency. Band records live in a flat 128-slot array with the stride the
/// whole encoder uses (`band[w * 16 + g]`), while `start` walks the spectrum
/// contiguously: eight short windows read the same 1024 coefficients, each
/// window's band cursor restarting at zero so `wstart < cutoff` gates every
/// window on its own 128-sample span.
fn aac_psy_calc_thr(
  bands : Array[AacPsyBandState],
  coefs : Array[Double],
  cutoff : Int32,
  sizes : Array[Int32],
  num_windows : Int32,
) -> Unit {
  let num_bands = sizes.length()
  let mut start = 0
  let mut w = 0
  while w < num_windows * 16 {
    let mut wstart = 0
    for g in 0..<num_bands {
      let band = bands[w + g]
      let mut energy = 0.0
      let mut form_factor = 0.0
      if wstart < cutoff {
        for i in 0..<sizes[g] {
          let c = coefs[start + i]
          energy += c * c
          form_factor += c.abs().sqrt()
        }
      }
      let temp = if energy > 0.0 {
        (sizes[g].to_double() / energy).sqrt()
      } else {
        0.0
      }
      band.energy = energy
      band.thr = energy * psy_rpe_thr_coeff
      band.nz_lines = form_factor * temp.sqrt()
      start += sizes[g]
      wstart += sizes[g]
    }
    w = w + 16
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
  for _ in 0..<128 {
    coeffs_long.push(aac_psy_new_coeffs())
    coeffs_short.push(aac_psy_new_coeffs())
  }
  let prev_band : Array[Array[AacPsyBandState]] = []
  let bands : Array[Array[AacPsyBandState]] = []
  let entropy : Array[Double] = []
  for _ch in 0..<channels {
    let sc : Array[AacPsyBandState] = []
    let pc : Array[AacPsyBandState] = []
    for _ in 0..<128 {
      sc.push(aac_psy_new_band())
      pc.push(aac_psy_new_band())
    }
    bands.push(sc)
    prev_band.push(pc)
    entropy.push(0.0)
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
    entropy,
    alloc: -1,
    cutoff: 0,
  }
  aac_psy_init_coeffs(ctx, sampling_index, bandwidth)
  ctx
}

///|
/// Bandwidth the model analyses with (Hz). 0 means "derive from the bit rate".
pub fn AacPsyContext::cutoff(self : AacPsyContext) -> Int32 {
  self.cutoff
}

///|
/// Set the sticky bandwidth the next analyses use (0 restores the derivation).
/// The C encoder does this from the quantiser (`s->psy.cutoff = bandwidth`),
/// which is why the value carries over to later frames.
pub fn AacPsyContext::set_cutoff(self : AacPsyContext, bandwidth : Int32) -> Unit {
  self.cutoff = bandwidth
}

///|
/// Bandwidth the model analyses with when it has to derive it from the bitrate.
pub fn aac_psy_model_bandwidth(
  bit_rate : Int32,
  channels : Int32,
  sample_rate : Int32,
) -> Int32 {
  aac_psy_cutoff(bit_rate, channels, sample_rate)
}
///|
/// Scalefactor band sizes of the long window, exactly as `psy_3gpp_init`
/// derived them from the swb offset table. The twoloop quantizer needs the
/// same plan, so it takes it from the model instead of re-deriving it.
pub fn AacPsyContext::band_sizes(self : AacPsyContext) -> Array[Int32] {
  self.band_sizes
}

///|
/// The eight-window plan (`ctx->bands[1]`, 14 bands of 128 lines at 44.1 kHz),
/// the same table `psy_3gpp_analyze_channel` switches to when the frame is
/// `EIGHT_SHORT`. A multi-window quantiser search needs the identical plan the
/// analysis used, so it comes from the model rather than being re-derived.
pub fn AacPsyContext::band_sizes_short(self : AacPsyContext) -> Array[Int32] {
  self.band_sizes_short
}

///|
/// Run one frame of 3GPP analysis for `channel` on `coefs` (1024 f32 MDCT
/// coefficients in the encoder's coefficient domain). `prev_bits` is
/// `bitres.bits` (bits consumed by the previous frame); the reference harness
/// uses 0.
///
/// This is `psy_3gpp_analyze_channel`, `aacpsy.c:646`. `window_type` /
/// `prev_window_type` are the frame's `window_sequence` and the previous
/// frame's (`wi->window_type[0]` and `[1]`), and they select the window shape:
/// `aac_eight_short` means eight 128-sample windows, every other sequence is
/// one long window. Upstream reads that from `wi->num_windows`, which both of
/// FFmpeg's block-switchers set from exactly this test
/// (`psy_3gpp_window`, `aacpsy.c:475-486`), so it is derived here instead of
/// passed in — an eight-short frame with one window is then unrepresentable.
/// The short shape changes four things: the band plan (`ctx->bands[1]`, 14
/// bands of 8x128 at 44.1 kHz instead of 49), the coefficient tables
/// (`psy_coef[1]`, whose spreading factors come from the short slope
/// constants), `PSY_3GPP_AH_THR_SHORT` for hole avoidance, and the
/// `calc_bit_demand` short-window slope set; the analysed span also halves, so
/// `cutoff` divides by the window count.
///
/// The returned bands are the `FFPsyBand` array that the twoloop quantizer
/// consumes, in the slot layout every consumer indexes with
/// (`psy_bands[w * 16 + g]`, `aaccoder.c:366`): for one long window that is the
/// contiguous `num_bands` records, for eight short windows a 128-slot array
/// whose `w * 16 + g` entries carry window `w`. The band records and the
/// perceptual entropy are per channel, while `bitres` (`fill_level`) and the PE
/// range (`pe.min` / `pe.max` / `pe.previous`) are shared by every channel of
/// the element — analysing channel 0 already moves the element's reservoir
/// position, exactly like upstream.
pub fn AacPsyContext::analyze(
  self : AacPsyContext,
  channel : Int32,
  coefs : Array[Double],
  prev_bits : Int32,
  window_type : Int32,
  prev_window_type : Int32,
) -> AacPsyResult {
  let is_short = window_type == aac_eight_short
  let num_windows = if is_short { 8 } else { 1 }
  let sizes = if is_short {
    self.band_sizes_short
  } else {
    self.band_sizes
  }
  let num_bands = sizes.length()
  let coeffs = if is_short { self.coeffs_short } else { self.coeffs_long }
  let slots = if is_short { num_windows * 16 } else { num_bands }
  let bands = self.bands[channel]
  let prev_band = self.prev_band[channel]
  // `aacpsy.c:685`: the pre-echo reduction is skipped for the whole frame when
  // this is a LONG_STOP window, and for `w == 0` only when the frame before it
  // started with a LONG_START (the `!w` in the C condition).
  let skip_preecho_all = window_type == aac_long_stop
  // `FFPsyContext.cutoff` is sticky: the quantiser writes the bandwidth it
  // settled on back into the model, so from the second frame on the analysis
  // uses that value instead of recomputing it (with PNS enabled the quantiser
  // scales the bitrate by 1.15 first, which widens the band).
  let bandwidth = if self.cutoff > 0 {
    self.cutoff
  } else {
    aac_psy_cutoff(self.bit_rate, self.channels, self.sample_rate)
  }
  let cutoff = bandwidth * 2048 / num_windows / self.sample_rate
  let avoid_hole_thr = if is_short {
    psy_ah_thr_short
  } else {
    psy_ah_thr_long
  }
  // 5.4.2 threshold calculation
  aac_psy_calc_thr(bands, coefs, cutoff, sizes, num_windows)
  // 5.4.2.3 spreading + 5.4.3 spread energy, one pass per window.
  let spread_en : Array[Double] = Array::make(128, 0.0)
  let mut pe = if self.chan_bitrate > 32000 {
    0.0
  } else {
    aac_psy_maxf(50.0, 100.0 - self.chan_bitrate.to_double() * 100.0 / 32000.0)
  }
  let mut a = 0.0
  let mut active_lines = 0.0
  let mut w = 0
  while w < num_windows * 16 {
    // `aacpsy.c:670` writes this window's first band energy to `spread_en[0]`
    // - not to `spread_en[w]` - so for every window after the first the
    // spreading chain starts from the zero the array was initialised with, and
    // band `w + 0` never gets its own energy into the hole-avoidance test.
    // Upstream quirk, transcribed verbatim; with one window it is the
    // assignment it was meant to be.
    spread_en[0] = bands[w].energy
    for g in 1..<num_bands {
      let b = bands[w + g]
      let bm = bands[w + g - 1]
      let t = aac_psy_maxf(b.thr, bm.thr * coeffs[g].spread_hi_thr)
      b.thr = t
      spread_en[w + g] = aac_psy_maxf(
        b.energy,
        spread_en[w + g - 1] * coeffs[g].spread_hi_en,
      )
    }
    for g = num_bands - 2; g >= 0; g = g - 1 {
      let b = bands[w + g]
      let bp = bands[w + g + 1]
      b.thr = aac_psy_maxf(b.thr, bp.thr * coeffs[g].spread_low_thr)
      spread_en[w + g] = aac_psy_maxf(
        spread_en[w + g],
        spread_en[w + g + 1] * coeffs[g].spread_low_en,
      )
    }
    let skip_preecho = skip_preecho_all ||
      (w == 0 && prev_window_type == aac_long_start)
    // 5.4.2.4 "Threshold in quiet" + 5.4.2.5 pre-echo + 5.6.1.3 PE/hole choice
    for g in 0..<num_bands {
      let b = bands[w + g]
      b.thr = aac_psy_maxf(b.thr, coeffs[g].ath)
      b.thr_quiet = b.thr
      // `psy_3gpp_analyze_channel` skips the reduction for a LONG_STOP window
      // and for a window that follows LONG_START: those transition windows
      // already carry the attack in their own spectrum, so damping the
      // threshold against the previous frame would be wrong. For a short frame
      // only the first window sees the previous frame.
      if !skip_preecho {
        let prevq = prev_band[w + g].thr_quiet
        b.thr = aac_psy_maxf(
          psy_rpemin * b.thr,
          aac_psy_minf(b.thr, psy_rpelev * prevq),
        )
      }
      pe += aac_psy_calc_pe(b)
      a += b.pe_const
      active_lines += b.active_lines
      // 5.6.1.3.3 selection of bands for avoidance of holes
      b.avoid_holes = if spread_en[w + g] * avoid_hole_thr > b.energy ||
        coeffs[g].min_snr > 1.0 {
        psy_ah_none
      } else {
        psy_ah_inactive
      }
    }
    w = w + 16
  }
  self.entropy[channel] = pe
  let desired_bits = self.bit_demand(pe, prev_bits, is_short)
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
    // 5.6.1.3.4 first estimation of the reduction value. Like C, the running
    // totals are reset *inside* the per-window loop, so when this stage is
    // done `pe` / `a` / `active_lines` describe only the last window - and the
    // second estimation below reads those frame-wide-looking variables.
    let mut reduction = 0.0
    let mut w_first = 0
    while w_first < num_windows * 16 {
      reduction = aac_psy_calc_reduction(a, desired_pe, pe, active_lines)
      pe = 0.0
      a = 0.0
      active_lines = 0.0
      for g in 0..<num_bands {
        let b = bands[w_first + g]
        b.thr = aac_psy_calc_reduced_thr(b, coeffs[g].min_snr, reduction)
        pe += aac_psy_calc_pe(b)
        a += b.pe_const
        active_lines += b.active_lines
      }
      w_first = w_first + 16
    }
    // 5.6.1.3.5 second estimation (two passes)
    let mut delta_pe = 0.0
    let mut norm_fac_total = 0.0
    for _ in 0..<2 {
      let mut pe_no_ah = 0.0
      let mut a2 = 0.0
      let mut al2 = 0.0
      let mut w_sum = 0
      while w_sum < num_windows * 16 {
        for g in 0..<num_bands {
          let b = bands[w_sum + g]
          if b.avoid_holes != psy_ah_active {
            pe_no_ah += b.pe
            a2 += b.pe_const
            al2 += b.active_lines
          }
        }
        w_sum = w_sum + 16
      }
      let desired_pe_no_ah = aac_psy_maxf(desired_pe - (pe - pe_no_ah), 0.0)
      if al2 > 0.0 {
        reduction = aac_psy_calc_reduction(a2, desired_pe_no_ah, pe_no_ah, al2)
      }
      pe = 0.0
      let mut w_thr = 0
      while w_thr < num_windows * 16 {
        for g in 0..<num_bands {
          let b = bands[w_thr + g]
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
        w_thr = w_thr + 16
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
      let mut w_lin = 0
      while w_lin < num_windows * 16 {
        for g in 0..<num_bands {
          let b = bands[w_lin + g]
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
        w_lin = w_lin + 16
      }
    } else {
      // 5.6.1.3.7 further PE reduction: raise min_snr from the top band down,
      // all windows of one band together (`aacpsy.c:812-822`).
      let mut g = num_bands - 1
      while g >= 0 && pe > desired_pe {
        let mut w_pe = 0
        while w_pe < num_windows * 16 {
          let b = bands[w_pe + g]
          if b.avoid_holes != psy_ah_none &&
            coeffs[g].min_snr < psy_snr_1db {
            coeffs[g].min_snr = psy_snr_1db
            b.thr = b.energy * psy_snr_1db
            pe += b.active_lines * 1.5 - b.pe
          }
          w_pe = w_pe + 16
        }
        g = g - 1
      }
    }
  }
  // publish FFPsyBand + commit prev_band (aacpsy.c:827-839). The published
  // array keeps C's slot layout, so a short frame's window `w` starts at
  // `w * 16` and the padding slots between bands stay empty.
  let out : Array[AacPsyBandInfo] = []
  for _ in 0..<slots {
    out.push({ energy: 0.0, threshold: 0.0, spread: 0.0, bits: 0 })
  }
  let mut w_pub = 0
  while w_pub < num_windows * 16 {
    for g in 0..<num_bands {
      let b = bands[w_pub + g]
      out[w_pub + g] = {
        energy: b.energy,
        threshold: b.thr,
        spread: b.active_lines * 2.0 / sizes[g].to_double(),
        bits: (b.pe / psy_bits_to_pe).to_int(),
      }
    }
    w_pub = w_pub + 16
  }
  // `memcpy(pch->prev_band, pch->band, sizeof(pch->band))`: the whole 128-slot
  // array, including the slots this frame did not touch, so a frame that
  // switches between the long and the short slot layout still finds the values
  // the last frame of that layout wrote.
  for s in 0..<128 {
    let b = bands[s]
    let pb = prev_band[s]
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
    num_windows,
    num_bands,
    alloc: self.alloc,
    entropy: self.entropy[channel],
    fill_level: self.fill_level,
  }
}
