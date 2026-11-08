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
/// comparable): ABR (`lambda = 120`, no QSCALE), intensity / M-S / TNS
/// disabled, and both window shapes of the C search — one long window
/// (`num_windows = 1`, 49 scalefactor bands at 44.1 kHz) and eight short
/// windows walked by group (`w += group_len[w]`, 14 bands of 128 lines each,
/// one shared scalefactor and codebook per group). `AacTwoShape` carries the
/// choice; see `aac_psy.mbt` for the analysis that fills the `w * 16 + g`
/// slots the search reads.
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

///|
/// The port's twoloop carries its scalefactors on a grid shifted +4 steps
/// from C's: its 2x coefficient domain meets the quantiser's +4-sf-per-octave
/// table exactly (the init-scalefactor comment below, §366), so every band
/// lands on `C_sf + 4` and `aac_encode_channel_data_psy` translates `- 4` at
/// the write. Every *absolute* sf constant the C search uses - the ladder's
/// clip range, the SCALE_ONE_POS / SCALE_MAX_POS-SCALE_DIV_512 markers the
/// rate-loop raise, the zeroing loops and the delta clamps key on, and the
/// `coef2minsf` floor (whose pow34 input gains only +3 from the doubled
/// spectrum, one short of the grid) - must carry the same shift. sf
/// *differences* (max_diff, diff_zero) and the quantiser's table-index
/// formulas take sf as-is and absorb the shift through the grid, so they
/// stay unshifted.
let aac_two_sf_domain_shift : Int32 = 4

///|
let aac_two_scale_one_pos : Int32 = 140

///|
let aac_two_scale_max_pos : Int32 = 255

///|
let aac_two_scale_max_diff : Int32 = 60

///|
let aac_two_scale_diff_zero : Int32 = 60

///|
let aac_two_pow_sf2_zero : Int32 = 200

///|
/// `C_QUANT`, `aacenc_utils.h:38`, which is also `ROUND_STANDARD` (`:36`).
/// The twoloop search always passes `rtz = 0`, so `ROUND_TO_ZERO` is not
/// reachable from here.
///
/// Stored as the binary32 value of `0.4054f`, not the decimal: this constant
/// enters `qmaxval = maxval * Q34 + C_QUANT` and `quant(a, Q, ROUNDING)` - both
/// of which the reference immediately truncates to an `int` - so an f64 literal
/// that differs from `0.4054f` by 1.4e-8 relative can move a value across the
/// integer boundary and change the codebook or the quantised level (§295 closed
/// the same class of bug in the mid/side search's `bmax`).
let aac_two_c_quant : Double = 0.40540000796318054

///|
/// `0.00125f` (`aaccoder_twoloop.h:277`, the floor under `uplims` before the
/// `log2f`) and `0.0125f` (`:532`, the spread interpolation), again as the
/// binary32 values the reference actually multiplies with. The port's psy
/// bands sit in its 2x coefficient domain (4x threshold domain), so the
/// `uplims` floor is pre-scaled by the same 4 (`4 * 0.00125f`, still an
/// exact f32 product) to keep `max(4f, uplim) == 4 * max(f, uplim_c)` -
/// see the init-scalefactor comment below.
let aac_two_uplim_floor : Double = 0.004999999888241291

///|
let aac_two_spread_scale : Double = 0.012500000186264515

///|
/// `1.15f` (`aaccoder_twoloop.h:191`, `aaccoder.c:516/652`): the per-channel
/// bitrate compensation for extensions that buy efficiency.
let aac_two_tool_bitrate_boost : Double = 1.149999976158142

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
  // The +domain_shift here is only +1 of grid: the pow34 input of the 2x
  // spectrum already contributes +3 (4 * log2(2^(3/4))), one short of the
  // sf grid's +4 per octave, so the constant adds the missing step.
  let v = aac_two_mul(aac_two_log2f(coef), 4.0) -
    69.0 +
    aac_two_sf_domain_shift.to_double() +
    (aac_two_scale_one_pos - aac_two_scale_div_512).to_double()
  aac_two_clip(
    v.to_int(),
    aac_two_sf_domain_shift,
    255 + aac_two_sf_domain_shift,
  )
}

///|
/// `find_min_book`, `aacenc_utils.h:68`: smallest codebook able to code a
/// band whose quantised peak is `maxval` at scalefactor `sf`.
fn aac_two_find_min_book(maxval : Double, sf : Int32) -> Int32 {
  let q_idx = aac_two_pow_sf2_zero -
    sf +
    aac_two_scale_one_pos -
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
/// distortion, and so do the band types from `NOISE_BT` on (13 = PNS, 14/15 =
/// intensity): the dispatch table (`aaccoder.c:229-245`) routes them to the
/// `BT_ZERO || BT_NOISE || BT_STEREO` branch of the template, which is the same
/// energy-shaped cost and no bits. `search_for_ms` reaches that branch on the
/// noise bands of a PNS frame, because its own guard excludes only zeroed and
/// intensity bands.
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
  if cb == 0 || cb >= 13 {
    let mut acc = 0.0
    for i in 0..<size {
      acc = aac_two_add(acc, aac_two_mul(input[in_off + i], input[in_off + i]))
    }
    return { cost: aac_two_mul(acc, lambda), bits: 0, energy: 0.0, }
  }
  let q_idx = aac_two_pow_sf2_zero -
    scale_idx +
    aac_two_scale_one_pos -
    aac_two_scale_div_512
  let q = aac_twoloop_pow2sf[q_idx]
  let q34 = aac_twoloop_pow34sf[q_idx]
  let iq = aac_twoloop_pow2sf[aac_two_pow_sf2_zero +
    scale_idx -
    aac_two_scale_one_pos +
    aac_two_scale_div_512]
  let clipped_escape = aac_two_mul(165140.0, iq)
  let is_unsigned = cb >= 3 && cb != 5 && cb != 6
  let is_esc = cb == 11
  let dim = if cb <= 4 { 4 } else { 2 }
  let maxval = aac_twoloop_cb_maxval[cb]
  aac_two_quantize_bands(
    qcoefs,
    input,
    in_off,
    scaled,
    scaled_off,
    size,
    !is_unsigned,
    maxval,
    q34,
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
            // `c*cbrtf(c)` is the dumped product, not a recomputed cbrt:
            // the encoder's single-precision `cbrtf` disagrees with
            // `float(c*cbrt((double)c))` by one ulp on 2196 of the 8192
            // integer inputs, and this is the only place the quantiser
            // touches `cbrtf`.
            quantized = aac_two_mul(aac_twoloop_cbrt_prod[c], iq)
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
  { cost, bits: resbits, energy: qenergy, }
}

///|
/// `ff_init_nextband_map`, `aacenc_utils.h:175`: chain each non-zero band to
/// the next one in encoding order, so removing a band can be tested against
/// the scalefactor-delta constraint without rescanning.
fn aac_two_init_nextband_map(
  zeroes : Array[Int32],
  cb : Array[Int32],
  num_swb : Int32,
  shape : AacTwoShape,
) -> Array[Int32] {
  let num_windows = shape.num_windows
  let group_len = shape.group_len
  let nextband : Array[Int32] = Array::make(128, 0)
  for g in 0..<128 {
    nextband[g] = g
  }
  let mut prevband = 0
  let mut w = 0
  while w < num_windows {
    let base = w * 16
    for g in 0..<num_swb {
      if zeroes[base + g] == 0 && cb[base + g] < aac_two_reserved_bt {
        nextband[prevband] = base + g
        prevband = base + g
      }
    }
    w = w + group_len[w]
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
/// `ff_pns_bits`, `aaccoder_twoloop.h:57`: 9 bits for a noise band, 5 when it
/// follows another noise band (they share the preamble). `slot` is the band's
/// C slot `w * 16 + g`, and the lookbehind is the previous band of the same
/// window group - `sce->zeroes[(w<<4)+g-1]`, not a wrapped band index.
fn aac_two_pns_bits(
  zeroes : Array[Int32],
  can_pns : Array[Int32],
  slot : Int32,
) -> Int32 {
  if slot % 16 > 0 && zeroes[slot - 1] != 0 && can_pns[slot - 1] != 0 {
    5
  } else {
    9
  }
}

///|
/// Quantizer state shared by the inner rate loop and the outer distortion
/// loop: the arrays `search_for_quantizers_twoloop` keeps on its stack, all
/// sized 128 like C, plus the window shape it walks.
priv struct AacTwoLoop {
  coefs : Array[Double]
  scoefs : Array[Double]
  band_sizes : Array[Int32]
  num_swb : Int32
  num_windows : Int32
  group_len : Array[Int32]
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
/// The body C duplicates for the inner loop and for the `recomprd` re-run:
/// quantise every band at the current scalefactors, store `dists` /
/// `qenergies` and return the total bit count (`tbits`). A scalefactor is
/// shared by the whole window group, so the band cost is summed over
/// `group_len[w]` windows and the bit total counted once, and the scalefactor
/// delta chain runs across window groups without restarting (`prev` is outside
/// the `w` loop).
fn AacTwoLoop::collect(self : AacTwoLoop) -> Int32 {
  let mut tbits = 0
  let mut prev = -1
  let qcoefs : Array[Int32] = Array::make(128, 0)
  let mut w = 0
  while w < self.num_windows {
    let gl = self.group_len[w]
    let base = w * 16
    let mut start = w * 128
    for g in 0..<self.num_swb {
      if self.zeroes[base + g] != 0 || self.sf[base + g] >= 218 {
        start = start + self.band_sizes[g]
        if base + g < self.can_pns.length() && self.can_pns[base + g] != 0 {
          tbits = tbits + aac_two_pns_bits(self.zeroes, self.can_pns, base + g)
        }
        continue
      }
      let cb = aac_two_find_min_book(self.maxvals[base + g], self.sf[base + g])
      let mut cost = 0.0
      let mut bits = 0
      let mut qenergy = 0.0
      for w2 in 0..<gl {
        let off = start + w2 * 128
        let r = aac_two_band_cost(
          self.coefs,
          off,
          self.scoefs,
          off,
          qcoefs,
          self.band_sizes[g],
          self.sf[base + g],
          cb,
          1.0,
        )
        cost = aac_two_add(cost, r.cost)
        bits = bits + r.bits
        qenergy = aac_two_add(qenergy, r.energy)
      }
      self.dists[base + g] = aac_two_sub(cost, bits.to_double())
      self.qenergies[base + g] = qenergy
      if prev != -1 {
        let sfdiff = aac_two_clip(
          self.sf[base + g] - prev + aac_two_scale_diff_zero,
          0,
          2 * aac_two_scale_max_diff,
        )
        bits = bits + aac_scalefactor_bits[sfdiff]
      }
      tbits = tbits + bits
      start = start + self.band_sizes[g]
      prev = self.sf[base + g]
    }
    w = w + gl
  }
  tbits
}

///|
/// Outcome of `aac_twoloop_search`, in C's `w*16 + g` slot layout. Only the
/// slots at a window-group start carry a decision: with one long window those
/// are the first `num_swb` slots, with eight short windows they are
/// `group_len`-spaced blocks of `num_swb` slots each, and the slots a group
/// covers from its second window onward keep whatever the flat 128-entry
/// passes left in them (C touches them too, so they are part of the state).
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
  is_stereo : Bool
}

///|
/// Build the PNS inputs (the struct's fields are private to the package).
/// `is_stereo` is not a PNS switch: twoloop's bandwidth rule reads
/// `options.pns || options.intensity_stereo`, because both tools buy back
/// efficiency, so the pair of switches has to travel together here.
pub fn aac_twoloop_pns(
  can_pns : Array[Int32],
  on : Bool,
  is_stereo : Bool,
) -> AacTwoPns {
  { can_pns, on, is_stereo, }
}

///|
/// The element's sticky slot arrays C's `search_for_quantizers_twoloop`
/// mutates in place (`sce->sf_idx` / `sce->band_type` / `sce->zeroes`). The
/// search initialises and rewrites the *group-start* slots, but its rate loop
/// scales **every** slot (`for (i = 0; i < 128; i++)`, `aaccoder_twoloop.h:
/// 419-439`) and its zero-band pass writes the zeroed *inner-window* slots -
/// so what those passes do to the rest of the array depends on what earlier
/// frames left there. Handing the arrays in reproduces that; omitting them
/// starts from zeroed arrays, which is the plain-reset harness state the
/// §278/§301 vectors were generated against.
pub struct AacTwoSticky {
  sf : Array[Int32]
  cb : Array[Int32]
  zeroes : Array[Int32]
}

///|
/// Build the sticky inputs (the struct's fields are private to the package).
pub fn aac_two_sticky(
  sf : Array[Int32],
  cb : Array[Int32],
  zeroes : Array[Int32],
) -> AacTwoSticky {
  { sf, cb, zeroes, }
}

///|
/// The window shape the search runs on: `num_windows` (1 for a long frame, 8
/// for an eight-short frame) and `sce->ics.group_len` — one entry per window,
/// of which only the ones at a window-group start are read, because C walks
/// groups with `w += group_len[w]` (`aaccoder_twoloop.h:217`). A group shares
/// one scalefactor and one codebook across its windows, and its slots are at
/// `w * 16 + g` for the group's first window `w`.
pub struct AacTwoShape {
  num_windows : Int32
  group_len : Array[Int32]
}

///|
/// `ONLY_LONG`/`LONG_START`/`LONG_STOP`: one window, one group.
pub fn aac_two_shape_long() -> AacTwoShape {
  { num_windows: 1, group_len: [1, 0, 0, 0, 0, 0, 0, 0], }
}

///|
/// `EIGHT_SHORT` with the given grouping. `group_len` must be the eight
/// entries C would have built from a `window_grouping` byte
/// (`aacpsy.c:398`) - it is validated against `num_windows = 8` here because a
/// wrong walk would silently skip whole windows.
pub fn aac_two_shape_short(group_len : Array[Int32]) -> AacTwoShape {
  if group_len.length() != 8 {
    abort("aac_two_shape_short: group_len must have 8 entries")
  }
  let mut total = 0
  let mut w = 0
  while w < 8 {
    if group_len[w] <= 0 {
      abort("aac_two_shape_short: non-positive group_len[\{w}]")
    }
    total = total + group_len[w]
    w = w + group_len[w]
  }
  if total != 8 {
    abort("aac_two_shape_short: groups cover \{total} windows, want 8")
  }
  { num_windows: 8, group_len, }
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
  shape : AacTwoShape,
) -> AacTwoResult {
  aac_twoloop_search_pns(
    coefs,
    band_sizes,
    bands,
    alloc,
    bit_rate,
    sample_rate,
    channels,
    lambda,
    aac_twoloop_pns(Array::make(bands.length(), 0), false, false),
    shape,
  )
}

///|
/// `search_for_quantizers_twoloop`, `aaccoder_twoloop.h:65`, with intensity /
/// M-S / TNS off. `bands` are the `FFPsyBand` slots from
/// `AacPsyContext::analyze` (window `w`, band `g` at `w * 16 + g`); `alloc` is
/// its `bitres.alloc`.
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
  shape : AacTwoShape,
  sticky? : AacTwoSticky,
) -> AacTwoResult {
  let num_swb = band_sizes.length()
  let num_windows = shape.num_windows
  let wlen = 1024 / num_windows
  let mut destbits = (bit_rate.to_double() *
  1024.0 /
  sample_rate.to_double() /
  channels.to_double() *
  (lambda / 120.0)).to_int()
  let mut rdlambda = aac_two_clipf(2.0 * 120.0 / lambda, 0.0625, 16.0)
  let nzslope = 1.5
  let rdmin = 0.03125
  let rdmax = 1.0
  let mut sfoffs = aac_two_clipf(
    aac_two_log2f(120.0 / lambda) * 4.0,
    -5.0,
    10.0,
  )
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
  // ABR branch: `avctx->flags & AV_CODEC_FLAG_QSCALE == 0`, so
  // `frame_bit_rate = avctx->bit_rate / nb_channels` is an *integer* division,
  // and the compensation for extensions that buy efficiency
  // (`aaccoder_twoloop.h:189-191`) multiplies it by `1.15f` in single
  // precision and truncates back - at 96 kbps / 2 ch that is 55200 for C where
  // an f64 multiply truncates to 55199, one bandwidth step away.
  let fbr0 = bit_rate / channels
  let fbr = if pns.on || pns.is_stereo {
    aac_two_mul(fbr0.to_double(), aac_two_tool_bitrate_boost).to_int()
  } else {
    fbr0
  }
  let bw = aac_psy_cutoff(fbr, 1, sample_rate)
  let bandwidth = if bw < 3000 { 3000 } else { bw }
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
  // C's search runs on the element's sticky arrays; with none handed in,
  // fresh zeroed arrays stand in (the plain-reset state).
  let sf : Array[Int32] = match sticky {
    Some(s) => s.sf
    None => Array::make(128, 0)
  }
  let cb : Array[Int32] = match sticky {
    Some(s) => s.cb
    None => Array::make(128, 0)
  }
  let zeroes : Array[Int32] = match sticky {
    Some(s) => s.zeroes
    None => Array::make(128, 0)
  }
  let minsf : Array[Int32] = Array::make(128, 0)
  let maxsf : Array[Int32] = Array::make(
    128,
    aac_two_scale_max_pos + aac_two_sf_domain_shift,
  )
  // Zero bands and upper distortion limits. `start` is the band's position
  // *within a window*, so it restarts for every window group, while the psy
  // records are read at the slot of each window in the group.
  let mut allz = 0
  let mut wz = 0
  while wz < num_windows {
    let gl = shape.group_len[wz]
    let base = wz * 16
    let mut start = 0
    for g in 0..<num_swb {
      let mut nz = 0
      for w2 in 0..<gl {
        let band = bands[(wz + w2) * 16 + g]
        if start >= cutoff ||
          band.energy <= aac_two_mul(band.threshold, zeroscale) ||
          band.threshold == 0.0 {
          zeroes[(wz + w2) * 16 + g] = 1
        } else {
          nz = 1
        }
      }
      let mut uplim = 0.0
      let mut energy = 0.0
      let mut spread = 0.0
      if nz != 0 {
        nz = 0
        for w2 in 0..<gl {
          let band = bands[(wz + w2) * 16 + g]
          if not(
              band.energy <= aac_two_mul(band.threshold, zeroscale) ||
              band.threshold == 0.0,
            ) {
            uplim = aac_two_add(uplim, band.threshold)
            energy = aac_two_add(energy, band.energy)
            spread = aac_two_add(spread, band.spread)
            nz = nz + 1
          }
        }
      }
      uplims[base + g] = uplim
      energies[base + g] = energy
      nzs[base + g] = nz
      zeroes[base + g] = if nz != 0 { 0 } else { 1 }
      allz = allz | nz
      // `aaccoder_twoloop.h:248`: the spread-energy / threshold ranking that
      // the later overdistortion-driven PNS zeroing uses.
      if nz != 0 && base + g < can_pns.length() && can_pns[base + g] != 0 {
        let denom = aac_two_mul(uplim, spread)
        let r = if denom > 0.0 {
          aac_two_div(aac_two_mul(energy, nz.to_double()), denom)
        } else {
          0.0
        }
        spread_thr_r[base + g] = r
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
    wz = wz + gl
  }
  // Initial scalefactors.
  let mut minscaler = 65535
  let mut wsf = 0
  while wsf < num_windows {
    let gl_ssf = shape.group_len[wsf]
    let bsf = wsf * 16
    for g in 0..<num_swb {
      if zeroes[bsf + g] != 0 {
        sf[bsf + g] = aac_two_scale_one_pos + aac_two_sf_domain_shift
      } else {
        let denom = band_sizes[g].to_double()
        let peak = if uplims[bsf + g] > aac_two_uplim_floor {
          uplims[bsf + g]
        } else {
          aac_two_uplim_floor
        }
        // C computes this ladder from the C-domain peak; the port's psy
        // bands carry its 2x coefficient domain (4x thresholds), and its
        // quantiser tables sit on a scalefactor grid shifted by exactly
        // +4 per octave. `1.75 * log2(4x)` alone compensates only 3.5 of
        // those 4 steps, which left the whole ladder half a step off C's
        // grid (§366): divide the peak back into the C domain and add the
        // grid shift instead.
        let peak_c = aac_two_div(peak, 4.0)
        let v = aac_two_scale_one_pos.to_double() +
          4.0 +
          1.75 * aac_two_log2f(aac_two_div(peak_c, denom)) +
          sfoffs
        sf[bsf + g] = aac_two_clip(
          v.to_int(),
          60 + aac_two_sf_domain_shift,
          aac_two_scale_max_pos + aac_two_sf_domain_shift,
        )
        if sf[bsf + g] < minscaler {
          minscaler = sf[bsf + g]
        }
      }
    }
    wsf = wsf + gl_ssf
  }
  minscaler = aac_two_clip(
    minscaler,
    aac_two_scale_one_pos - aac_two_scale_div_512 + aac_two_sf_domain_shift,
    aac_two_scale_max_pos - aac_two_scale_div_512 + aac_two_sf_domain_shift,
  )
  let mut wcl = 0
  while wcl < num_windows {
    let gl_scl = shape.group_len[wcl]
    let bcl = wcl * 16
    for g in 0..<num_swb {
      if zeroes[bcl + g] == 0 {
        sf[bcl + g] = aac_two_clip(
          sf[bcl + g],
          minscaler,
          minscaler + aac_two_scale_max_diff - 1,
        )
      }
    }
    wcl = wcl + gl_scl
  }
  if allz == 0 {
    return { sf, cb, zeroes, maxvals, tbits: 0, iters: 0, }
  }
  let scoefs = aac_two_abs_pow34(coefs, 1024)
  // Per-band peak and the smallest legal scalefactor, per window group.
  let mut wpk = 0
  while wpk < num_windows {
    let gl_spk = shape.group_len[wpk]
    let bpk = wpk * 16
    let mut peak_start = wpk * 128
    for g in 0..<num_swb {
      maxvals[bpk + g] = aac_two_find_max_val(
        gl_spk,
        band_sizes[g],
        scoefs,
        peak_start,
      )
      if maxvals[bpk + g] > 0.0 {
        let minsfidx = aac_two_coef2minsf(maxvals[bpk + g])
        for w2 in 0..<gl_spk {
          minsf[(wpk + w2) * 16 + g] = minsfidx
        }
      }
      peak_start = peak_start + band_sizes[g]
    }
    wpk = wpk + gl_spk
  }
  // Rescale the upward limits by tonality: noisy bands may be quantised
  // harder, tonal bands are protected.
  for g in 0..<128 {
    euplims[g] = uplims[g]
  }
  // Two upstream quirks live here: C divides by `sce->ics.swb_sizes[w]` - the
  // *window index* used as a band-size index, not `swb_sizes[g]` - and tests
  // `nzs[g]`, the count of the first window group, for every group. Both are
  // identity-shaped with one window, so they only start to bite on short
  // frames; they are transcribed as they are.
  let mut wff = 0
  while wff < num_windows {
    let gl_sff = shape.group_len[wff]
    let bff = wff * 16
    // `aaccoder_twoloop.h:322`: short frames de-prioritise transients by the
    // share of the window group in the frame.
    let de_psy_factor = if num_windows > 1 {
      aac_two_div(8.0, gl_sff.to_double())
    } else {
      1.0
    }
    let swbw = band_sizes[wff].to_double()
    let mut ff_start = wff * 128
    for g in 0..<num_swb {
      if nzs[g] > 0 {
        let cfrac = aac_two_clipf(
          aac_two_div(
            ff_start.to_double(),
            aac_two_mul(cutoff.to_double(), 0.75),
          ),
          1.0,
          2.0,
        )
        let cleanup_factor = aac_two_mul(cfrac, cfrac)
        let thresh = aac_two_div(
          uplims[bff + g],
          aac_two_mul(nzs[g].to_double(), swbw),
        )
        let mut e2u = aac_two_find_form_factor(
          gl_sff,
          band_sizes[g],
          thresh,
          coefs,
          ff_start,
          aac_two_mul(nzslope, cleanup_factor),
        )
        e2u = aac_two_mul(e2u, de_psy_factor)
        e2u = aac_two_sqrtf(e2u)
        e2u = aac_two_clipf(e2u, 0.015625, 1.0)
        uplims[bff + g] = aac_two_mul(
          uplims[bff + g],
          aac_two_mul(
            aac_two_clipf(aac_two_mul(rdlambda, e2u), rdmin, rdmax),
            gl_sff.to_double(),
          ),
        )
        let thresh2 = aac_two_div(
          uplims[bff + g],
          aac_two_mul(nzs[g].to_double(), swbw),
        )
        let mut e2u2 = aac_two_find_form_factor(
          gl_sff,
          band_sizes[g],
          thresh2,
          coefs,
          ff_start,
          2.0,
        )
        e2u2 = aac_two_mul(e2u2, de_psy_factor)
        e2u2 = aac_two_sqrtf(e2u2)
        e2u2 = aac_two_clipf(e2u2, 0.015625, 1.0)
        euplims[bff + g] = aac_two_mul(
          euplims[bff + g],
          aac_two_clipf(
            aac_two_mul(aac_two_mul(rdlambda, e2u2), gl_sff.to_double()),
            0.5,
            1.0,
          ),
        )
      }
      ff_start = ff_start + band_sizes[g]
    }
    wff = wff + gl_sff
  }
  let st : AacTwoLoop = {
    coefs,
    scoefs,
    band_sizes,
    num_swb,
    num_windows,
    group_len: shape.group_len,
    maxvals,
    sf,
    zeroes,
    dists,
    qenergies,
    can_pns,
  }
  // Scratch for `quantize_bands` inside the RD loop: only ever written
  // before being read, so one 128-slot buffer serves every band and window.
  let qcoefs_rd : Array[Int32] = Array::make(128, 0)
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
          if sf[i] <
            aac_two_scale_max_pos -
            aac_two_scale_div_512 +
            aac_two_sf_domain_shift {
            let maxsf_i = if tbits > 5800 {
              aac_two_scale_max_pos + aac_two_sf_domain_shift
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
          if sf[i] > aac_two_scale_one_pos + aac_two_sf_domain_shift {
            let mut new_sf = minsf[i]
            if aac_two_scale_one_pos + aac_two_sf_domain_shift > new_sf {
              new_sf = aac_two_scale_one_pos + aac_two_sf_domain_shift
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
      if qstep == 0 &&
        tbits > toomanybits &&
        sf[0] < 217 + aac_two_sf_domain_shift &&
        changed {
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
        let mut wo = 0
        while wo < num_windows {
          let glo = shape.group_len[wo]
          let bo = wo * 16
          for g in 0..<num_swb {
            if zeroes[bo + g] == 0 &&
              sf[bo + g] > aac_two_scale_one_pos + aac_two_sf_domain_shift &&
              dists[bo + g] > aac_two_mul(uplims[bo + g], ovrfactor) {
              overdist = overdist + 1
            }
          }
          wo = wo + glo
        }
        if overdist != 0 {
          let mut minspread = max_spread_thr_r
          let mut maxspread = min_spread_thr_r
          let mut zeroable = 0
          let mut wz = 0
          while wz < num_windows {
            let glz = shape.group_len[wz]
            let bz = wz * 16
            for g in 0..<num_swb {
              if offsets[g] >= pns_start_pos &&
                zeroes[bz + g] == 0 &&
                bz + g < can_pns.length() &&
                can_pns[bz + g] != 0 {
                if spread_thr_r[bz + g] < minspread {
                  minspread = spread_thr_r[bz + g]
                }
                if spread_thr_r[bz + g] > maxspread {
                  maxspread = spread_thr_r[bz + g]
                }
                zeroable = zeroable + 1
              }
            }
            wz = wz + glz
          }
          // `aaccoder_twoloop.h:532-537`, every step in f32: the spread
          // interpolation, its `min_spread_thr_r * 8.f` cap, and the
          // starvation-weighted third term that caps it further.
          let spread_span = aac_two_sub(maxspread, minspread)
          let mut zspread = aac_two_add(
            aac_two_mul(spread_span, aac_two_spread_scale),
            minspread,
          )
          let starve_left = aac_two_mul(
            (toomanybits - tbits).to_double(),
            min_spread_thr_r,
          )
          let starve_right = aac_two_mul(
            (tbits - toofewbits).to_double(),
            max_spread_thr_r,
          )
          let starve_sum = aac_two_add(starve_left, starve_right)
          let third = aac_two_div(
            starve_sum,
            (toomanybits - toofewbits + 1).to_double(),
          )
          let cap1 = aac_two_mul(min_spread_thr_r, 8.0)
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
              aac_two_scale_one_pos -
              aac_two_scale_div_512 +
              aac_two_sf_domain_shift
            } else {
              aac_two_scale_one_pos + aac_two_sf_domain_shift
            }
            let mut g = num_swb - 1
            while g > 0 && zeroed < maxzeroed {
              if offsets[g] >= pns_start_pos {
                // C walks the window groups for *this* band; the
                // `zeroed < maxzeroed` cap is only tested between bands, so a
                // group of several windows can overshoot it.
                let mut wz2 = 0
                while wz2 < num_windows {
                  let glz2 = shape.group_len[wz2]
                  let slot = wz2 * 16 + g
                  let mcb = aac_two_find_min_book(maxvals[slot], sf[slot])
                  let minul = if uplims[slot] < euplims[slot] {
                    uplims[slot]
                  } else {
                    euplims[slot]
                  }
                  let overd = dists[slot] >
                    aac_two_mul(loopovrfactor, uplims[slot]) ||
                    mcb <= 0 ||
                    (mcb <= 1 && dists[slot] > minul)
                  if zeroes[slot] == 0 &&
                    slot < can_pns.length() &&
                    can_pns[slot] != 0 &&
                    spread_thr_r[slot] <= zspread &&
                    sf[slot] > loopminsf &&
                    overd {
                    zeroes[slot] = 1
                    cb[slot] = 0
                    zeroed = zeroed + 1
                  }
                  wz2 = wz2 + glz2
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
    let mut mins = aac_two_scale_max_pos + aac_two_sf_domain_shift
    let mut wm = 0
    while wm < num_windows {
      let glm = shape.group_len[wm]
      let bm = wm * 16
      for g in 0..<num_swb {
        if zeroes[bm + g] == 0 && sf[bm + g] < mins {
          mins = sf[bm + g]
        }
      }
      wm = wm + glm
    }
    mins = aac_two_clip(
      mins,
      aac_two_scale_one_pos - aac_two_scale_div_512 + aac_two_sf_domain_shift,
      aac_two_scale_max_pos - aac_two_scale_div_512 + aac_two_sf_domain_shift,
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
    let mut wr = 0
    while wr < num_windows {
      let glr = shape.group_len[wr]
      let br = wr * 16
      let mut start = wr * 128
      for g in 0..<num_swb {
        let s = br + g
        let prevsc = sf[s]
        if prev < 0 && zeroes[s] == 0 {
          prev = sf[0]
        }
        if zeroes[s] == 0 {
          let cmb = aac_two_find_min_book(maxvals[s], sf[s])
          let mut mindeltasf = prev - aac_two_scale_max_diff
          if mindeltasf < 0 {
            mindeltasf = 0
          }
          let mut maxdeltasf = prev + aac_two_scale_max_diff
          if maxdeltasf >
            aac_two_scale_max_pos -
            aac_two_scale_div_512 +
            aac_two_sf_domain_shift {
            maxdeltasf = aac_two_scale_max_pos -
              aac_two_scale_div_512 +
              aac_two_sf_domain_shift
          }
          let floor = if mindeltasf > minsf[s] { mindeltasf } else { minsf[s] }
          if (cmb == 0 || dists[s] > uplims[s]) && sf[s] > floor {
            // Push down (finer) until the band carries energy or meets the
            // distortion target.
            let mut stop = false
            let mut i = 0
            while i < edepth && sf[s] > mindeltasf {
              let mb = aac_two_find_min_book(maxvals[s], sf[s] - 1)
              let band_cb = aac_two_find_min_book(maxvals[s], sf[s])
              if band_cb == 0 {
                let lim = sf[s] - 1
                maxsf[s] = if lim < maxsf[s] { lim } else { maxsf[s] }
              } else if i >= depth && dists[s] < euplims[s] {
                stop = true
              }
              // !g is the DC band: on a short frame its error is guarded even
              // when the push continues (`aaccoder_twoloop.h:625`).
              if g == 0 && num_windows > 1 && dists[s] >= euplims[s] {
                maxsf[s] = if sf[s] < maxsf[s] { sf[s] } else { maxsf[s] }
              }
              if stop {
                break
              }
              let mut cost = 0.0
              let mut bits = 0
              let mut qenergy = 0.0
              for w2 in 0..<glr {
                let off = start + w2 * 128
                let r = aac_two_band_cost(
                  coefs,
                  off,
                  scoefs,
                  off,
                  qcoefs_rd,
                  band_sizes[g],
                  sf[s] - 1,
                  band_cb,
                  1.0,
                )
                cost = aac_two_add(cost, r.cost)
                bits = bits + r.bits
                qenergy = aac_two_add(qenergy, r.energy)
              }
              sf[s] = sf[s] - 1
              dists[s] = aac_two_sub(cost, bits.to_double())
              qenergies[s] = qenergy
              let target = aac_two_mul(uplmax, uplims[s])
              let bound = if target < euplims[s] { target } else { euplims[s] }
              let ediff = aac_two_f32((qenergies[s] - energies[s]).abs())
              if mb != 0 &&
                (sf[s] < mindeltasf || (dists[s] < bound && ediff < euplims[s])) {
                break
              }
              i = i + 1
            }
          } else {
            let maxsf_lim = if maxdeltasf < maxsf[s] {
              maxdeltasf
            } else {
              maxsf[s]
            }
            let elo = if euplims[s] < uplims[s] {
              euplims[s]
            } else {
              uplims[s]
            }
            let ediff = aac_two_f32((qenergies[s] - energies[s]).abs())
            if tbits > toofewbits &&
              sf[s] < maxsf_lim &&
              dists[s] < elo &&
              ediff < euplims[s] {
              // We are over target: spend fewer bits on this band.
              let mut i = 0
              while i < depth && sf[s] < maxdeltasf {
                let band_cb = aac_two_find_min_book(maxvals[s], sf[s] + 1)
                if band_cb > 0 {
                  let mut cost = 0.0
                  let mut bits = 0
                  let mut qenergy = 0.0
                  for w2 in 0..<glr {
                    let off = start + w2 * 128
                    let r = aac_two_band_cost(
                      coefs,
                      off,
                      scoefs,
                      off,
                      qcoefs_rd,
                      band_sizes[g],
                      sf[s] + 1,
                      band_cb,
                      1.0,
                    )
                    cost = aac_two_add(cost, r.cost)
                    bits = bits + r.bits
                    qenergy = aac_two_add(qenergy, r.energy)
                  }
                  let dist = aac_two_sub(cost, bits.to_double())
                  let lim = if euplims[s] < uplims[s] {
                    euplims[s]
                  } else {
                    uplims[s]
                  }
                  if dist < lim {
                    sf[s] = sf[s] + 1
                    dists[s] = dist
                    qenergies[s] = qenergy
                  } else {
                    break
                  }
                } else {
                  maxsf[s] = if sf[s] < maxsf[s] { sf[s] } else { maxsf[s] }
                  break
                }
                i = i + 1
              }
            }
          }
          sf[s] = aac_two_clip(sf[s], mindeltasf, maxdeltasf)
          if sf[s] != prevsc {
            fflag = true
          }
          cb[s] = aac_two_find_min_book(maxvals[s], sf[s])
          prev = sf[s]
        }
        start = start + band_sizes[g]
      }
      wr = wr + glr
    }
    // SF delta limit violation risk: re-clamp. `prev` is not restarted per
    // window group, so the delta chain runs through the whole frame.
    let mut prev2 = -1
    let mut wc = 0
    while wc < num_windows {
      let glc = shape.group_len[wc]
      let bc = wc * 16
      for g in 0..<num_swb {
        if zeroes[bc + g] == 0 {
          let prevsf = sf[bc + g]
          if prev2 < 0 {
            prev2 = prevsf
          }
          sf[bc + g] = aac_two_clip(
            sf[bc + g],
            prev2 - aac_two_scale_max_diff,
            prev2 + aac_two_scale_max_diff,
          )
          cb[bc + g] = aac_two_find_min_book(maxvals[bc + g], sf[bc + g])
          prev2 = sf[bc + g]
          if !fflag && prevsf != sf[bc + g] {
            fflag = true
          }
        }
      }
      wc = wc + glc
    }
    its = its + 1
    if !(fflag && its < maxits) {
      break
    }
  }
  // Give every non-zero band a legal codebook; a band its scalefactor no
  // longer codes is zeroed unless that would break the delta chain.
  let nextband = aac_two_init_nextband_map(zeroes, cb, num_swb, shape)
  let mut prev3 = -1
  let mut wf = 0
  while wf < num_windows {
    let glf = shape.group_len[wf]
    let bf = wf * 16
    for g in 0..<num_swb {
      let s = bf + g
      if zeroes[s] == 0 {
        cb[s] = aac_two_find_min_book(maxvals[s], sf[s])
        if cb[s] <= 0 {
          if !aac_two_can_remove_band(sf, nextband, prev3, s) {
            cb[s] = 1
          } else {
            zeroes[s] = 1
            cb[s] = 0
          }
        }
      } else {
        cb[s] = 0
      }
      if zeroes[s] == 0 {
        if prev3 == -1 && zeroes[0] != 0 {
          sf[0] = sf[s]
        }
        prev3 = sf[s]
      }
    }
    wf = wf + glf
  }
  { sf, cb, zeroes, maxvals, tbits, iters: its, }
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
  let q_idx = aac_two_pow_sf2_zero -
    sf +
    aac_two_scale_one_pos -
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
    let mut v = if capped >= cap.to_double() { cap } else { capped.to_int() }
    if is_esc && v == cap {
      v = aac_two_clip(aac_two_quant(a, q, aac_two_c_quant), 0, 8191)
    }
    out[i] = if c < 0.0 { -v } else { v }
  }
  out
}
