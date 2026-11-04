///|
/// AAC encoder two-loop quantizer.
///
/// Port of FFmpeg 9.0.2 `libavcodec/aaccoder_twoloop.h`
/// (`search_for_quantizers_twoloop`) plus the helpers it pulls in from
/// `aacenc_utils.h` (`find_max_val`, `find_min_book`, `coef2minsf`,
/// `find_form_factor`, `ff_init_nextband_map`, `ff_sfdelta_can_remove_band`),
/// `aacencdsp.c` (`abs_pow34_v`, `quantize_bands`) and the cost function
/// `quantize_and_encode_band_cost_template` in `aaccoder.c`.
///
/// Scope (identical to `_ref/aacenc/` so the vectors are directly
/// comparable): one long window (`num_windows = 1`, `group_len[w] = 1`,
/// 49 scalefactor bands at 44.1 kHz), ABR (`lambda = 120`, no QSCALE), and
/// intensity / M-S / TNS disabled.
///
/// PNS is opt-in through `aac_twoloop_search_pns` / `AacTwoPns`: with `on =
/// false` and `can_pns[]` all zero it reproduces §278's 245 golden bands
/// bit-for-bit, with `on = true` it reproduces the C `--pns` run's 245 bands
/// (§286). Both paths run in the same function, so the PNS-only blocks are
/// guarded by `pns.on` rather than being a separate implementation.
///
/// Numerics: FFmpeg runs the encoder in `float`.  Every arithmetic step C
/// performs on a `float` is reproduced through `aac_two_f32`, which rounds to
/// binary32 once.  `dists`, `qenergies`, `uplims` and `cost` accumulate in
/// f32 in C, and those values drive integer decisions (`sf_idx`,
/// `band_type`, `zeroes`), so the rounding points matter.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// `SCALE_DIV_512` / `SCALE_ONE_POS` / `SCALE_MAX_POS` / `SCALE_MAX_DIFF` /
/// `SCALE_DIFF_ZERO` / `POW_SF2_ZERO`, `aac.h:91-97`.
let aac_two_scale_div_512 : Int32 = 36
let aac_two_scale_one_pos : Int32 = 140
let aac_two_scale_max_pos : Int32 = 255
let aac_two_scale_max_diff : Int32 = 60
let aac_two_scale_diff_zero : Int32 = 60
let aac_two_pow_sf2_zero : Int32 = 200

///|
/// `C_QUANT`, `aacenc_utils.h:38`, which is also `ROUND_STANDARD` (`:36`).
/// The twoloop search always passes `rtz = 0`, so `ROUND_TO_ZERO` is not
/// reachable from here.
let aac_two_c_quant : Double = 0.4054

///|
/// `RESERVED_BT`, `aac.h:74`: band types from here on are not spectral.
let aac_two_reserved_bt : Int32 = 12

///|
/// Round `x` to binary32 precision, the way every C `float` assignment in
/// the reference does.
fn aac_two_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
fn aac_two_add(a : Double, b : Double) -> Double {
  aac_two_f32(a + b)
}

///|
fn aac_two_sub(a : Double, b : Double) -> Double {
  aac_two_f32(a - b)
}

///|
fn aac_two_mul(a : Double, b : Double) -> Double {
  aac_two_f32(a * b)
}

///|
fn aac_two_div(a : Double, b : Double) -> Double {
  aac_two_f32(a / b)
}

///|
/// `sqrtf`.
fn aac_two_sqrtf(x : Double) -> Double {
  aac_two_f32(x.sqrt())
}

///|
/// `log2f`.
fn aac_two_log2f(x : Double) -> Double {
  aac_two_f32(@math.log2(x))
}

///|
/// `expf`.
fn aac_two_expf(x : Double) -> Double {
  aac_two_f32(@math.exp(x))
}

///|
/// `logf`.
fn aac_two_logf(x : Double) -> Double {
  aac_two_f32(@math.ln(x))
}

///|
/// `cbrtf`.
fn aac_two_cbrtf(x : Double) -> Double {
  aac_two_f32(@math.cbrt(x))
}

///|
/// `powf`.
fn aac_two_powf(x : Double, y : Double) -> Double {
  aac_two_f32(@math.pow(x, y))
}

///|
/// `ff_fast_powf(x, y)`, `libavutil/ffmath.h:62`: `expf(logf(x) * y)`.
/// `logf(0) = -inf`, so a zero base short-circuits to 0 instead of running
/// `exp(-inf * y)`.
fn aac_two_fast_powf(x : Double, y : Double) -> Double {
  if x <= 0.0 {
    0.0
  } else {
    aac_two_expf(aac_two_mul(aac_two_logf(x), y))
  }
}

///|
/// `av_clipf`.
fn aac_two_clipf(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// `av_clip`.
fn aac_two_clip(x : Int32, lo : Int32, hi : Int32) -> Int32 {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// `av_log2`: index of the highest set bit. Only called with `v >= 1`.
fn aac_two_av_log2(v : Int32) -> Int32 {
  let mut n = 0
  let mut t = v >> 1
  while t > 0 {
    t = t >> 1
    n = n + 1
  }
  n
}

///|
/// `abs_pow34_v`, `aacencdsp.c:26`: `out[i] = sqrtf(a * sqrtf(a))` with
/// `a = fabsf(in[i])`, every step in f32.
fn aac_two_abs_pow34(input : Array[Double], size : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(size, 0.0)
  for i in 0..<size {
    let a = aac_two_f32(input[i].abs())
    let inner = aac_two_sqrtf(a)
    out[i] = aac_two_sqrtf(aac_two_mul(a, inner))
  }
  out
}

///|
/// `find_max_val`, `aacenc_utils.h:56`.
fn aac_two_find_max_val(
  group_len : Int32,
  swb_size : Int32,
  scaled : Array[Double],
  offset : Int32,
) -> Double {
  let mut maxval = 0.0
  for w2 in 0..<group_len {
    for i in 0..<swb_size {
      let v = scaled[offset + w2 * 128 + i]
      if v > maxval {
        maxval = v
      }
    }
  }
  maxval
}

///|
/// `coef2minsf`, `aacenc_utils.h:133`:
/// `av_clip_uint8(log2f(coef)*4 - 69 + SCALE_ONE_POS - SCALE_DIV_512)`.
/// The float sum is truncated to `int` by the C call, then clipped.
fn aac_two_coef2minsf(coef : Double) -> Int32 {
  let v = aac_two_mul(aac_two_log2f(coef), 4.0) - 69.0 +
    (aac_two_scale_one_pos - aac_two_scale_div_512).to_double()
  aac_two_clip(v.to_int(), 0, 255)
}

///|
/// `find_min_book`, `aacenc_utils.h:68`: smallest codebook able to code a
/// band whose quantised peak is `maxval` at scalefactor `sf`.
fn aac_two_find_min_book(maxval : Double, sf : Int32) -> Int32 {
  let q_idx = aac_two_pow_sf2_zero - sf + aac_two_scale_one_pos -
    aac_two_scale_div_512
  let q34 = aac_twoloop_pow34sf[q_idx]
  let qmaxval = aac_two_add(aac_two_mul(maxval, q34), aac_two_c_quant).to_int()
  if qmaxval >= aac_twoloop_maxval_cb.length() {
    11
  } else {
    aac_twoloop_maxval_cb[qmaxval]
  }
}

///|
/// `find_form_factor`, `aacenc_utils.h:80`: the share of the band energy the
/// dominant line explains, i.e. a crude tonality measure. `nzslope == 2`
/// uses the cheap square instead of `ff_fast_powf`.
fn aac_two_find_form_factor(
  group_len : Int32,
  swb_size : Int32,
  thresh : Double,
  scaled : Array[Double],
  offset : Int32,
  nzslope : Double,
) -> Double {
  let iswb_size = aac_two_div(1.0, swb_size.to_double())
  let iswb_sizem1 = aac_two_div(1.0, (swb_size - 1).to_double())
  let mut form = 0.0
  let mut weight = 0.0
  for w2 in 0..<group_len {
    let base = offset + w2 * 128
    let mut e = 0.0
    let mut e2 = 0.0
    let mut variance = 0.0
    let mut maxval = 0.0
    let mut nzl = 0.0
    for i in 0..<swb_size {
      let s0 = aac_two_f32(scaled[base + i].abs())
      if s0 > maxval {
        maxval = s0
      }
      e = aac_two_add(e, s0)
      let s = aac_two_mul(s0, s0)
      e2 = aac_two_add(e2, s)
      if s >= thresh {
        nzl = aac_two_add(nzl, 1.0)
      } else {
        let ratio = aac_two_div(s, thresh)
        if nzslope == 2.0 {
          nzl = aac_two_add(nzl, aac_two_mul(ratio, ratio))
        } else {
          nzl = aac_two_add(nzl, aac_two_fast_powf(ratio, nzslope))
        }
      }
    }
    if e2 > thresh {
      e = aac_two_mul(e, iswb_size)
      for i in 0..<swb_size {
        let d = aac_two_sub(aac_two_f32(scaled[base + i].abs()), e)
        variance = aac_two_add(variance, aac_two_mul(d, d))
      }
      variance = aac_two_sqrtf(aac_two_mul(variance, iswb_sizem1))
      e2 = aac_two_mul(e2, iswb_size)
      let spread = aac_two_add(e, aac_two_mul(4.0, variance))
      let denom = aac_two_f32(if spread < maxval { spread } else { maxval })
      let frm = aac_two_div(e, denom)
      let nz = if nzl < 0.5 { 0.5 } else { nzl }
      form = aac_two_add(
        form,
        aac_two_div(aac_two_mul(e2, aac_two_sqrtf(frm)), nz),
      )
      weight = aac_two_add(weight, e2)
    }
  }
  if weight > 0.0 {
    aac_two_div(form, weight)
  } else {
    1.0
  }
}

///|
/// `quant`, `aacenc_utils.h:50`, truncated to `int` exactly where C's
/// `sqrtf(a * sqrtf(a)) + rounding` is converted.
fn aac_two_quant(coef : Double, q : Double, rounding : Double) -> Int32 {
  let a = aac_two_mul(coef, q)
  let inner = aac_two_sqrtf(a)
  aac_two_add(aac_two_sqrtf(aac_two_mul(a, inner)), rounding).to_int()
}

///|
/// Result of the cost function: distortion (`rd`), bits and quantised band
/// energy.
priv struct AacTwoCost {
  cost : Double
  bits : Int32
  energy : Double
}

///|
/// `quantize_bands`, `aacencdsp.c:30`:
/// `(int)min(scaled*Q34 + rounding, maxval)`, negated for negative samples
/// when the codebook is signed.
fn aac_two_quantize_bands(
  out : Array[Int32],
  input : Array[Double],
  in_off : Int32,
  scaled : Array[Double],
  scaled_off : Int32,
  size : Int32,
  is_signed : Bool,
  maxval : Int32,
  q34 : Double,
) -> Unit {
  for i in 0..<size {
    let qc = aac_two_mul(scaled[scaled_off + i], q34)
    let capped = aac_two_add(qc, aac_two_c_quant)
    let mut tmp = if capped >= maxval.to_double() {
      maxval
    } else {
      capped.to_int()
    }
    if is_signed && input[in_off + i] < 0.0 {
      tmp = -tmp
    }
    out[i] = tmp
  }
}

///|
/// One band's rate-distortion cost, `quantize_and_encode_band_cost_template`
/// (`aaccoder.c:94`). The twoloop search passes `lambda` from its argument
/// (1.0) and `uplim = INFINITY`, so the `cost >= uplim` early exit and the
/// bit writer are dropped.
///
/// Codebook flags (`aaccoder.c:217-228`): 1/2 signed quads, 3/4 unsigned
/// quads, 5/6 signed pairs, 7..10 unsigned pairs, 11 unsigned pairs with
/// escape. Codebook 0 codes nothing and returns the band energy as
/// distortion.
fn aac_two_band_cost(
  input : Array[Double],
  in_off : Int32,
  scaled : Array[Double],
  scaled_off : Int32,
  qcoefs : Array[Int32],
  size : Int32,
  scale_idx : Int32,
  cb : Int32,
  lambda : Double,
) -> AacTwoCost {
  if cb == 0 {
    let mut acc = 0.0
    for i in 0..<size {
      acc = aac_two_add(acc, aac_two_mul(input[in_off + i], input[in_off + i]))
    }
    return { cost: aac_two_mul(acc, lambda), bits: 0, energy: 0.0 }
  }
  let q_idx = aac_two_pow_sf2_zero - scale_idx + aac_two_scale_one_pos -
    aac_two_scale_div_512
  let q = aac_twoloop_pow2sf[q_idx]
  let q34 = aac_twoloop_pow34sf[q_idx]
  let iq = aac_twoloop_pow2sf[aac_two_pow_sf2_zero + scale_idx -
    aac_two_scale_one_pos + aac_two_scale_div_512]
  let clipped_escape = aac_two_mul(165140.0, iq)
  let is_unsigned = cb >= 3 && cb != 5 && cb != 6
  let is_esc = cb == 11
  let dim = if cb <= 4 { 4 } else { 2 }
  let maxval = aac_twoloop_cb_maxval[cb]
  aac_two_quantize_bands(
    qcoefs, input, in_off, scaled, scaled_off, size, !is_unsigned, maxval, q34,
  )
  let off = if is_unsigned { 0 } else { maxval }
  let range = aac_twoloop_cb_range[cb]
  let bit_tab = aac_twoloop_spectral_bits[cb - 1]
  let vec_tab = aac_twoloop_vectors[cb - 1]
  let mut cost = 0.0
  let mut resbits = 0
  let mut qenergy = 0.0
  let mut i = 0
  while i < size {
    let mut curidx = 0
    for j in 0..<dim {
      curidx = curidx * range + qcoefs[i + j] + off
    }
    let mut curbits = bit_tab[curidx]
    let vbase = curidx * dim
    let mut rd = 0.0
    if is_unsigned {
      for j in 0..<dim {
        let t = aac_two_f32(input[in_off + i + j].abs())
        let vecj = vec_tab[vbase + j]
        let mut quantized = 0.0
        if is_esc && vecj == 64.0 {
          if t >= clipped_escape {
            quantized = clipped_escape
            curbits = curbits + 21
          } else {
            let c = aac_two_clip(aac_two_quant(t, q, aac_two_c_quant), 0, 8191)
            quantized = aac_two_mul(
              aac_two_mul(c.to_double(), aac_two_cbrtf(c.to_double())),
              iq,
            )
            curbits = curbits + aac_two_av_log2(c) * 2 - 4 + 1
          }
        } else {
          quantized = aac_two_mul(vecj, iq)
        }
        let di = aac_two_sub(t, quantized)
        if vecj != 0.0 {
          curbits = curbits + 1
        }
        qenergy = aac_two_add(qenergy, aac_two_mul(quantized, quantized))
        rd = aac_two_add(rd, aac_two_mul(di, di))
      }
    } else {
      for j in 0..<dim {
        let quantized = aac_two_mul(vec_tab[vbase + j], iq)
        qenergy = aac_two_add(qenergy, aac_two_mul(quantized, quantized))
        let di = aac_two_sub(input[in_off + i + j], quantized)
        rd = aac_two_add(rd, aac_two_mul(di, di))
      }
    }
    cost = aac_two_add(
      cost,
      aac_two_add(aac_two_mul(rd, lambda), curbits.to_double()),
    )
    resbits = resbits + curbits
    i = i + dim
  }
  { cost, bits: resbits, energy: qenergy }
}

///|
/// `ff_init_nextband_map`, `aacenc_utils.h:175`: chain each non-zero band to
/// the next one in encoding order, so removing a band can be tested against
/// the scalefactor-delta constraint without rescanning.
fn aac_two_init_nextband_map(
  zeroes : Array[Int32],
  cb : Array[Int32],
  num_swb : Int32,
) -> Array[Int32] {
  let nextband : Array[Int32] = Array::make(128, 0)
  for g in 0..<128 {
    nextband[g] = g
  }
  let mut prevband = 0
  for g in 0..<num_swb {
    if zeroes[g] == 0 && cb[g] < aac_two_reserved_bt {
      nextband[prevband] = g
      prevband = g
    }
  }
  nextband[prevband] = prevband
  nextband
}

///|
/// `ff_sfdelta_can_remove_band`, `aacenc_utils.h:208`.
fn aac_two_can_remove_band(
  sf : Array[Int32],
  nextband : Array[Int32],
  prev_sf : Int32,
  band : Int32,
) -> Bool {
  prev_sf >= 0 &&
  sf[nextband[band]] >= prev_sf - aac_two_scale_max_diff &&
  sf[nextband[band]] <= prev_sf + aac_two_scale_max_diff
}

///|
/// Quantizer state shared by the inner rate loop and the outer distortion
/// loop: the arrays `search_for_quantizers_twoloop` keeps on its stack, all
/// sized 128 like C.
priv struct AacTwoLoop {
  coefs : Array[Double]
  scoefs : Array[Double]
  band_sizes : Array[Int32]
  num_swb : Int32
  maxvals : Array[Double]
  sf : Array[Int32]
  zeroes : Array[Int32]
  dists : Array[Double]
  qenergies : Array[Double]
  /// `can_pns` from `aac_pns_mark`: a zeroed band that may become noise
  /// still costs a few bits (`ff_pns_bits`).
  can_pns : Array[Int32]
}

///|
/// `ff_pns_bits`, `aaccoder_twoloop.h:57`: 9 bits for a noise band, 5 when it
/// follows another noise band (they share the preamble).
fn aac_two_pns_bits(
  zeroes : Array[Int32],
  can_pns : Array[Int32],
  g : Int32,
) -> Int32 {
  if g > 0 && zeroes[g - 1] != 0 && can_pns[g - 1] != 0 {
    5
  } else {
    9
  }
}

///|
/// The body C duplicates for the inner loop and for the `recomprd` re-run:
/// quantise every band at the current scalefactors, store `dists` /
/// `qenergies` and return the total bit count (`tbits`).
fn AacTwoLoop::collect(self : AacTwoLoop) -> Int32 {
  let mut tbits = 0
  let mut prev = -1
  let mut start = 0
  let qcoefs : Array[Int32] = Array::make(1024, 0)
  for g in 0..<self.num_swb {
    if self.zeroes[g] != 0 || self.sf[g] >= 218 {
      start = start + self.band_sizes[g]
      if g < self.can_pns.length() && self.can_pns[g] != 0 {
        tbits = tbits + aac_two_pns_bits(self.zeroes, self.can_pns, g)
      }
      continue
    }
    let cb = aac_two_find_min_book(self.maxvals[g], self.sf[g])
    let r = aac_two_band_cost(
      self.coefs, start, self.scoefs, start, qcoefs, self.band_sizes[g],
      self.sf[g], cb, 1.0,
    )
    let mut bits = r.bits
    self.dists[g] = aac_two_sub(r.cost, r.bits.to_double())
    self.qenergies[g] = r.energy
    if prev != -1 {
      let sfdiff = aac_two_clip(
        self.sf[g] - prev + aac_two_scale_diff_zero, 0,
        2 * aac_two_scale_max_diff,
      )
      bits = bits + aac_scalefactor_bits[sfdiff]
    }
    tbits = tbits + bits
    start = start + self.band_sizes[g]
    prev = self.sf[g]
  }
  tbits
}

///|
/// Outcome of `aac_twoloop_search`, in C's `w*16 + g` slot layout. With one
/// long window only the first `num_swb` slots carry real bands.
pub struct AacTwoResult {
  sf : Array[Int32]
  cb : Array[Int32]
  zeroes : Array[Int32]
  maxvals : Array[Double]
  tbits : Int32
  iters : Int32
}

///|
/// `search_for_quantizers_twoloop`, `aaccoder_twoloop.h:65`, restricted to
/// one long window with PNS / intensity / M-S / TNS off (see the module
/// docs). `bands` are the `FFPsyBand` values published by
/// `AacPsyContext::analyze`; `alloc` is its `bitres.alloc`; the reference
/// configuration uses `bit_rate = 128000`, `sample_rate = 44100`,
/// `channels = 2`, `lambda = 120`.
///|
/// PNS inputs for the twoloop search. `can_pns` comes from `aac_pns_mark`;
/// `on` is the encoder's `options.pns` flag, which also scales the nominal
/// per-channel bitrate by 1.15 before the bandwidth lookup.
pub struct AacTwoPns {
  can_pns : Array[Int32]
  on : Bool
}

///|
/// Build the PNS inputs (the struct's fields are private to the package).
pub fn aac_twoloop_pns(can_pns : Array[Int32], on : Bool) -> AacTwoPns {
  { can_pns, on }
}

///|
/// The configuration §278's 245 golden vectors were produced in: no PNS, so
/// `can_pns` is all zero and the bandwidth factor stays 1.0.
pub fn aac_twoloop_search(
  coefs : Array[Double],
  band_sizes : Array[Int32],
  bands : Array[AacPsyBandInfo],
  alloc : Int32,
  bit_rate : Int32,
  sample_rate : Int32,
  channels : Int32,
  lambda : Double,
) -> AacTwoResult {
  aac_twoloop_search_pns(
    coefs, band_sizes, bands, alloc, bit_rate, sample_rate, channels, lambda,
    aac_twoloop_pns(Array::make(band_sizes.length(), 0), false),
  )
}

///|
/// `search_for_quantizers_twoloop`, `aaccoder_twoloop.h:65`, restricted to
/// one long window with intensity / M-S / TNS off. `bands` are the `FFPsyBand`
/// values from `AacPsyContext::analyze`; `alloc` is its `bitres.alloc`.
pub fn aac_twoloop_search_pns(
  coefs : Array[Double],
  band_sizes : Array[Int32],
  bands : Array[AacPsyBandInfo],
  alloc : Int32,
  bit_rate : Int32,
  sample_rate : Int32,
  channels : Int32,
  lambda : Double,
  pns : AacTwoPns,
) -> AacTwoResult {
  let num_swb = band_sizes.length()
  // One long window: w = 0, group_len[w] = 1.
  let group_len = 1
  let wlen = 1024
  let mut destbits = (bit_rate.to_double() * 1024.0 / sample_rate.to_double() /
    channels.to_double() * (lambda / 120.0)).to_int()
  let mut rdlambda = aac_two_clipf(2.0 * 120.0 / lambda, 0.0625, 16.0)
  let nzslope = 1.5
  let rdmin = 0.03125
  let rdmax = 1.0
  let mut sfoffs = aac_two_clipf(aac_two_log2f(120.0 / lambda) * 4.0, -5.0, 10.0)
  let zeroscale = if lambda > 120.0 {
    aac_two_clipf(aac_two_powf(120.0 / lambda, 0.25), 0.0625, 1.0)
  } else {
    1.0
  }
  if alloc >= 0 {
    // The psy model granted extra bits from the reservoir.
    destbits = (alloc.to_double() * (lambda / 120.0)).to_int()
  }
  // ABR branch: `avctx->flags & AV_CODEC_FLAG_QSCALE == 0`.
  let mut toomanybits = destbits + destbits / 8
  let mut toofewbits = destbits - destbits / 8
  sfoffs = 0.0
  rdlambda = aac_two_sqrtf(rdlambda)
  let bandwidth = if pns.on {
    // `aaccoder_twoloop.h:190`: PNS or intensity stereo scales the nominal
    // per-channel bitrate by 1.15 before the bandwidth lookup.
    let fbr = (bit_rate.to_double() / channels.to_double() * 1.15).to_int()
    let bw = aac_psy_cutoff(fbr, 1, sample_rate)
    if bw < 3000 { 3000 } else { bw }
  } else {
    let bw = aac_psy_cutoff(bit_rate, channels, sample_rate)
    if bw < 3000 { 3000 } else { bw }
  }
  let cutoff = bandwidth * 2 * wlen / sample_rate
  // `pns_start_pos` (`aaccoder_twoloop.h:201`), in spectra-bin units.
  let pns_start_pos = 4000 * 2 * wlen / sample_rate
  let offsets : Array[Int32] = Array::make(num_swb + 1, 0)
  let mut off_acc = 0
  for g in 0..<num_swb {
    offsets[g] = off_acc
    off_acc = off_acc + band_sizes[g]
  }
  offsets[num_swb] = off_acc
  let can_pns = pns.can_pns
  let spread_thr_r : Array[Double] = Array::make(128, 0.0)
  let mut min_spread_thr_r = -1.0
  let mut max_spread_thr_r = -1.0
  destbits = if destbits > 5800 { 5800 } else { destbits }
  toomanybits = if toomanybits > 5800 { 5800 } else { toomanybits }
  toofewbits = if toofewbits > 5800 { 5800 } else { toofewbits }
  let uplims : Array[Double] = Array::make(128, 0.0)
  let euplims : Array[Double] = Array::make(128, 0.0)
  let energies : Array[Double] = Array::make(128, 0.0)
  let maxvals : Array[Double] = Array::make(128, 0.0)
  let dists : Array[Double] = Array::make(128, 0.0)
  let qenergies : Array[Double] = Array::make(128, 0.0)
  let nzs : Array[Int32] = Array::make(128, 0)
  let sf : Array[Int32] = Array::make(128, 0)
  let cb : Array[Int32] = Array::make(128, 0)
  let zeroes : Array[Int32] = Array::make(128, 0)
  let minsf : Array[Int32] = Array::make(128, 0)
  let maxsf : Array[Int32] = Array::make(128, aac_two_scale_max_pos)
  // Zero bands and upper distortion limits.
  let mut allz = 0
  let mut start = 0
  for g in 0..<num_swb {
    let band = bands[g]
    let mut nz = 0
    if start >= cutoff ||
      band.energy <= aac_two_mul(band.threshold, zeroscale) ||
      band.threshold == 0.0 {
      zeroes[g] = 1
    } else {
      nz = 1
    }
    let mut uplim = 0.0
    let mut energy = 0.0
    let mut spread = 0.0
    if nz != 0 {
      nz = 0
      if not(
        band.energy <= aac_two_mul(band.threshold, zeroscale) ||
        band.threshold == 0.0
      ) {
        uplim = aac_two_add(uplim, band.threshold)
        energy = aac_two_add(energy, band.energy)
        spread = aac_two_add(spread, band.spread)
        nz = nz + 1
      }
    }
    uplims[g] = uplim
    energies[g] = energy
    nzs[g] = nz
    zeroes[g] = if nz != 0 { 0 } else { 1 }
    allz = allz | nz
    // `aaccoder_twoloop.h:248`: the spread-energy / threshold ranking that
    // the later overdistortion-driven PNS zeroing uses.
    if nz != 0 && g < can_pns.length() && can_pns[g] != 0 {
      let denom = aac_two_mul(uplim, spread)
      let r = if denom > 0.0 {
        aac_two_div(aac_two_mul(energy, nz.to_double()), denom)
      } else {
        0.0
      }
      spread_thr_r[g] = r
      if min_spread_thr_r < 0.0 {
        min_spread_thr_r = r
        max_spread_thr_r = r
      } else {
        if r < min_spread_thr_r {
          min_spread_thr_r = r
        }
        if r > max_spread_thr_r {
          max_spread_thr_r = r
        }
      }
    }
    start = start + band_sizes[g]
  }
  // Initial scalefactors.
  let mut minscaler = 65535
  for g in 0..<num_swb {
    if zeroes[g] != 0 {
      sf[g] = aac_two_scale_one_pos
    } else {
      let denom = band_sizes[g].to_double()
      let peak = if uplims[g] > 0.00125 { uplims[g] } else { 0.00125 }
      let v = aac_two_scale_one_pos.to_double() +
        1.75 * aac_two_log2f(aac_two_div(peak, denom)) + sfoffs
      sf[g] = aac_two_clip(v.to_int(), 60, aac_two_scale_max_pos)
      if sf[g] < minscaler {
        minscaler = sf[g]
      }
    }
  }
  minscaler = aac_two_clip(
    minscaler, aac_two_scale_one_pos - aac_two_scale_div_512,
    aac_two_scale_max_pos - aac_two_scale_div_512,
  )
  for g in 0..<num_swb {
    if zeroes[g] == 0 {
      sf[g] = aac_two_clip(
        sf[g], minscaler, minscaler + aac_two_scale_max_diff - 1,
      )
    }
  }
  if allz == 0 {
    return { sf, cb, zeroes, maxvals, tbits: 0, iters: 0 }
  }
  let scoefs = aac_two_abs_pow34(coefs, 1024)
  // Per-band peak and the smallest legal scalefactor.
  let mut peak_start = 0
  for g in 0..<num_swb {
    maxvals[g] = aac_two_find_max_val(group_len, band_sizes[g], scoefs, peak_start)
    if maxvals[g] > 0.0 {
      minsf[g] = aac_two_coef2minsf(maxvals[g])
    }
    peak_start = peak_start + band_sizes[g]
  }
  // Rescale the upward limits by tonality: noisy bands may be quantised
  // harder, tonal bands are protected.
  for g in 0..<128 {
    euplims[g] = uplims[g]
  }
  // C divides by `sce->ics.swb_sizes[w]` here (w = 0), not `swb_sizes[g]`.
  let swb0 = band_sizes[0].to_double()
  let mut ff_start = 0
  for g in 0..<num_swb {
    if nzs[g] > 0 {
      let cfrac = aac_two_clipf(
        aac_two_div(ff_start.to_double(), aac_two_mul(cutoff.to_double(), 0.75)),
        1.0, 2.0,
      )
      let cleanup_factor = aac_two_mul(cfrac, cfrac)
      let thresh = aac_two_div(uplims[g], aac_two_mul(nzs[g].to_double(), swb0))
      let mut e2u = aac_two_find_form_factor(
        group_len, band_sizes[g], thresh, coefs, ff_start,
        aac_two_mul(nzslope, cleanup_factor),
      )
      e2u = aac_two_sqrtf(e2u)
      e2u = aac_two_clipf(e2u, 0.015625, 1.0)
      uplims[g] = aac_two_mul(
        uplims[g],
        aac_two_clipf(aac_two_mul(rdlambda, e2u), rdmin, rdmax),
      )
      let thresh2 = aac_two_div(
        uplims[g], aac_two_mul(nzs[g].to_double(), swb0),
      )
      let mut e2u2 = aac_two_find_form_factor(
        group_len, band_sizes[g], thresh2, coefs, ff_start, 2.0,
      )
      e2u2 = aac_two_sqrtf(e2u2)
      e2u2 = aac_two_clipf(e2u2, 0.015625, 1.0)
      euplims[g] = aac_two_mul(
        euplims[g], aac_two_clipf(aac_two_mul(rdlambda, e2u2), 0.5, 1.0),
      )
    }
    ff_start = ff_start + band_sizes[g]
  }
  let st : AacTwoLoop = {
    coefs,
    scoefs,
    band_sizes,
    num_swb,
    maxvals,
    sf,
    zeroes,
    dists,
    qenergies,
    can_pns,
  }
  let maxits = 30
  let mut its = 0
  let mut fflag = false
  let mut tbits = 0
  while true {
    // Inner loop: fit the spectrum into the bit budget.
    let mut qstep = if its != 0 { 1 } else { 32 }
    let mut recomprd = false
    while qstep > 0 {
      let mut changed = false
      recomprd = false
      tbits = st.collect()
      if tbits > toomanybits {
        recomprd = true
        for i in 0..<128 {
          if sf[i] < aac_two_scale_max_pos - aac_two_scale_div_512 {
            let maxsf_i = if tbits > 5800 {
              aac_two_scale_max_pos
            } else {
              maxsf[i]
            }
            let new_sf = if maxsf_i < sf[i] + qstep {
              maxsf_i
            } else {
              sf[i] + qstep
            }
            if new_sf != sf[i] {
              sf[i] = new_sf
              changed = true
            }
          }
        }
      } else if tbits < toofewbits {
        recomprd = true
        for i in 0..<128 {
          if sf[i] > aac_two_scale_one_pos {
            let mut new_sf = minsf[i]
            if aac_two_scale_one_pos > new_sf {
              new_sf = aac_two_scale_one_pos
            }
            if sf[i] - qstep > new_sf {
              new_sf = sf[i] - qstep
            }
            if new_sf != sf[i] {
              sf[i] = new_sf
              changed = true
            }
          }
        }
      }
      qstep = qstep >> 1
      if qstep == 0 && tbits > toomanybits && sf[0] < 217 && changed {
        qstep = 1
      }
    }
    fflag = tbits < toofewbits
    // `aaccoder_twoloop.h:448-570`: C runs at most two distortion passes,
    // and the first one may trade overdistorted bands for noise (PNS). With
    // PNS off this reduces to the old "collect twice when recomputed" loop.
    let mut overdist = 1
    let mut twopass = 0
    while twopass < 2 && (overdist != 0 || recomprd) {
      if recomprd {
        tbits = st.collect()
      }
      if twopass == 0 && pns.on && its > maxits / 2 && tbits > toofewbits {
        let ovrfactor = 1.0 +
          (maxits - its).to_double() * 16.0 / maxits.to_double()
        overdist = 0
        recomprd = false
        for g in 0..<num_swb {
          if zeroes[g] == 0 && sf[g] > aac_two_scale_one_pos &&
            dists[g] > aac_two_mul(uplims[g], ovrfactor) {
            overdist = overdist + 1
          }
        }
        if overdist != 0 {
          let mut minspread = max_spread_thr_r
          let mut maxspread = min_spread_thr_r
          let mut zeroable = 0
          for g in 0..<num_swb {
            if offsets[g] >= pns_start_pos && zeroes[g] == 0 &&
              g < can_pns.length() && can_pns[g] != 0 {
              if spread_thr_r[g] < minspread {
                minspread = spread_thr_r[g]
              }
              if spread_thr_r[g] > maxspread {
                maxspread = spread_thr_r[g]
              }
              zeroable = zeroable + 1
            }
          }
          let mut zspread = (maxspread - minspread) * 0.0125 + minspread
          let third = aac_two_div(
            ((toomanybits - tbits).to_double() * min_spread_thr_r) +
            ((tbits - toofewbits).to_double() * max_spread_thr_r),
            (toomanybits - toofewbits + 1).to_double(),
          )
          let cap1 = min_spread_thr_r * 8.0
          if zspread > cap1 {
            zspread = cap1
          }
          if zspread > third {
            zspread = third
          }
          let maxzeroed = if zeroable <
            (zeroable * its + maxits - 1) / (2 * maxits) {
            zeroable
          } else {
            (zeroable * its + maxits - 1) / (2 * maxits)
          }
          let mut zeroed = 0
          for zloop in 0..<2 {
            let loopovrfactor = if zloop != 0 { 1.0 } else { ovrfactor }
            let loopminsf = if zloop != 0 {
              aac_two_scale_one_pos - aac_two_scale_div_512
            } else {
              aac_two_scale_one_pos
            }
            let mut g = num_swb - 1
            while g > 0 && zeroed < maxzeroed {
              if offsets[g] >= pns_start_pos {
                let mcb = aac_two_find_min_book(maxvals[g], sf[g])
                let minul = if uplims[g] < euplims[g] {
                  uplims[g]
                } else {
                  euplims[g]
                }
                let overd = dists[g] > aac_two_mul(loopovrfactor, uplims[g]) ||
                  mcb <= 0 || (mcb <= 1 && dists[g] > minul)
                if zeroes[g] == 0 && g < can_pns.length() &&
                  can_pns[g] != 0 && spread_thr_r[g] <= zspread &&
                  sf[g] > loopminsf && overd {
                  zeroes[g] = 1
                  cb[g] = 0
                  zeroed = zeroed + 1
                }
              }
              g = g - 1
            }
          }
          if zeroed != 0 {
            recomprd = true
            fflag = true
          }
        }
      }
      twopass = twopass + 1
    }
    // Smallest scalefactor in use.
    let mut mins = aac_two_scale_max_pos
    for g in 0..<num_swb {
      if zeroes[g] == 0 && sf[g] < mins {
        mins = sf[g]
      }
    }
    mins = aac_two_clip(
      mins, aac_two_scale_one_pos - aac_two_scale_div_512,
      aac_two_scale_max_pos - aac_two_scale_div_512,
    )
    let depth = if its > maxits / 2 {
      if its > maxits * 2 / 3 {
        1
      } else {
        3
      }
    } else {
      10
    }
    let edepth = depth + 2
    let mut uplmax = aac_two_f32(
      its.to_double() / (maxits.to_double() * 0.25) + 1.0,
    )
    uplmax = aac_two_mul(
      uplmax,
      if tbits > destbits {
        let d = if destbits < 1 { 1 } else { destbits }
        let ratio = aac_two_div(tbits.to_double(), d.to_double())
        if ratio < 2.0 {
          ratio
        } else {
          2.0
        }
      } else {
        1.0
      },
    )
    let mut prev = -1
    let mut start = 0
    for g in 0..<num_swb {
      let prevsc = sf[g]
      if prev < 0 && zeroes[g] == 0 {
        prev = sf[0]
      }
      if zeroes[g] == 0 {
        let cmb = aac_two_find_min_book(maxvals[g], sf[g])
        let mut mindeltasf = prev - aac_two_scale_max_diff
        if mindeltasf < 0 {
          mindeltasf = 0
        }
        let mut maxdeltasf = prev + aac_two_scale_max_diff
        if maxdeltasf > aac_two_scale_max_pos - aac_two_scale_div_512 {
          maxdeltasf = aac_two_scale_max_pos - aac_two_scale_div_512
        }
        let floor = if mindeltasf > minsf[g] { mindeltasf } else { minsf[g] }
        if (cmb == 0 || dists[g] > uplims[g]) && sf[g] > floor {
          // Push down (finer) until the band carries energy or meets the
          // distortion target.
          let mut stop = false
          let mut i = 0
          while i < edepth && sf[g] > mindeltasf {
            let mb = aac_two_find_min_book(maxvals[g], sf[g] - 1)
            let band_cb = aac_two_find_min_book(maxvals[g], sf[g])
            if band_cb == 0 {
              let lim = sf[g] - 1
              maxsf[g] = if lim < maxsf[g] { lim } else { maxsf[g] }
            } else if i >= depth && dists[g] < euplims[g] {
              stop = true
            }
            if stop {
              break
            }
            let r = aac_two_band_cost(
              coefs, start, scoefs, start, Array::make(band_sizes[g], 0),
              band_sizes[g], sf[g] - 1, band_cb, 1.0,
            )
            sf[g] = sf[g] - 1
            dists[g] = aac_two_sub(r.cost, r.bits.to_double())
            qenergies[g] = r.energy
            let target = aac_two_mul(uplmax, uplims[g])
            let bound = if target < euplims[g] { target } else { euplims[g] }
            let ediff = aac_two_f32((qenergies[g] - energies[g]).abs())
            if mb != 0 &&
              (sf[g] < mindeltasf || (dists[g] < bound && ediff < euplims[g])) {
              break
            }
            i = i + 1
          }
        } else {
          let maxsf_lim = if maxdeltasf < maxsf[g] {
            maxdeltasf
          } else {
            maxsf[g]
          }
          let elo = if euplims[g] < uplims[g] { euplims[g] } else { uplims[g] }
          let ediff = aac_two_f32((qenergies[g] - energies[g]).abs())
          if tbits > toofewbits && sf[g] < maxsf_lim && dists[g] < elo &&
            ediff < euplims[g] {
            // We are over target: spend fewer bits on this band.
            let mut i = 0
            while i < depth && sf[g] < maxdeltasf {
              let band_cb = aac_two_find_min_book(maxvals[g], sf[g] + 1)
              if band_cb > 0 {
                let r = aac_two_band_cost(
                  coefs, start, scoefs, start, Array::make(band_sizes[g], 0),
                  band_sizes[g], sf[g] + 1, band_cb, 1.0,
                )
                let dist = aac_two_sub(r.cost, r.bits.to_double())
                let lim = if euplims[g] < uplims[g] {
                  euplims[g]
                } else {
                  uplims[g]
                }
                if dist < lim {
                  sf[g] = sf[g] + 1
                  dists[g] = dist
                  qenergies[g] = r.energy
                } else {
                  break
                }
              } else {
                maxsf[g] = if sf[g] < maxsf[g] { sf[g] } else { maxsf[g] }
                break
              }
              i = i + 1
            }
          }
        }
        sf[g] = aac_two_clip(sf[g], mindeltasf, maxdeltasf)
        if sf[g] != prevsc {
          fflag = true
        }
        cb[g] = aac_two_find_min_book(maxvals[g], sf[g])
        prev = sf[g]
      }
      start = start + band_sizes[g]
    }
    // SF delta limit violation risk: re-clamp.
    let mut prev2 = -1
    for g in 0..<num_swb {
      if zeroes[g] == 0 {
        let prevsf = sf[g]
        if prev2 < 0 {
          prev2 = prevsf
        }
        sf[g] = aac_two_clip(
          sf[g], prev2 - aac_two_scale_max_diff, prev2 + aac_two_scale_max_diff,
        )
        cb[g] = aac_two_find_min_book(maxvals[g], sf[g])
        prev2 = sf[g]
        if !fflag && prevsf != sf[g] {
          fflag = true
        }
      }
    }
    its = its + 1
    if !(fflag && its < maxits) {
      break
    }
  }
  // Give every non-zero band a legal codebook; a band its scalefactor no
  // longer codes is zeroed unless that would break the delta chain.
  let nextband = aac_two_init_nextband_map(zeroes, cb, num_swb)
  let mut prev3 = -1
  for g in 0..<num_swb {
    if zeroes[g] == 0 {
      cb[g] = aac_two_find_min_book(maxvals[g], sf[g])
      if cb[g] <= 0 {
        if !aac_two_can_remove_band(sf, nextband, prev3, g) {
          cb[g] = 1
        } else {
          zeroes[g] = 1
          cb[g] = 0
        }
      }
    } else {
      cb[g] = 0
    }
    if zeroes[g] == 0 {
      if prev3 == -1 && zeroes[0] != 0 {
        sf[0] = sf[g]
      }
      prev3 = sf[g]
    }
  }
  { sf, cb, zeroes, maxvals, tbits, iters: its }
}

///|
/// Quantise one band with the scalefactor and codebook the search settled on.
/// This repeats `quantize_bands` with the same f32 pipeline the cost function
/// used (`aacencdsp.c:30`), so the coefficients a caller writes to the
/// bitstream are exactly the ones that were costed.
///
/// Magnitudes are capped at `aac_cb_maxval[cb]`; codebook 11 keeps its escape
/// path, where a sample whose capped value hit 16 is re-quantised with the
/// wider `quant()` (`aacenc_utils.h:50`) and clipped to 8191. The sign is
/// carried in the returned values: `aac_encode_write_spectral` emits the
/// separate sign bits of the unsigned books from them.
pub fn aac_twoloop_quantize_band(
  coefs : Array[Double],
  start : Int32,
  size : Int32,
  sf : Int32,
  cb : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(size, 0)
  if cb <= 0 {
    return out
  }
  let q_idx = aac_two_pow_sf2_zero - sf + aac_two_scale_one_pos -
    aac_two_scale_div_512
  let q34 = aac_twoloop_pow34sf[q_idx]
  let q = aac_twoloop_pow2sf[q_idx]
  let cap = aac_twoloop_cb_maxval[cb]
  let is_esc = cb == 11
  for i in 0..<size {
    let c = coefs[start + i]
    let a = aac_two_f32(c.abs())
    let scaled = aac_two_sqrtf(aac_two_mul(a, aac_two_sqrtf(a)))
    let capped = aac_two_add(aac_two_mul(scaled, q34), aac_two_c_quant)
    let mut v = if capped >= cap.to_double() {
      cap
    } else {
      capped.to_int()
    }
    if is_esc && v == cap {
      v = aac_two_clip(aac_two_quant(a, q, aac_two_c_quant), 0, 8191)
    }
    out[i] = if c < 0.0 { -v } else { v }
  }
  out
}
