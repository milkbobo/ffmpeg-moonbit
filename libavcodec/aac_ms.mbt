///|
/// `search_for_ms`, FFmpeg 9.0.2 `libavcodec/aaccoder.c:702`, both window
/// shapes: one long window, or the eight short windows walked in their
/// `w += group_len[w]` groups. It runs after intensity stereo has been mixed
/// in, and for every band that neither tool has already claimed it prices
/// `(L, R)` against `(M, S)` with the same rate-distortion function the
/// quantiser uses - `M = (L + R) * 0.5`, `S = M - R` - and on a win it
/// *rewrites* both channels' scalefactor and band type, because the mid/side
/// pair is quantised together at `min(sf_L, sf_R)`.
///
/// On a short frame the mid/side scalefactors and codebooks are fixed for
/// the whole window group from the companded peak of `M` and `S` over all
/// its windows, while the distortion sums price every window against its own
/// psy band record - and the bit counts are subtracted per window, inside the
/// window loop, so the group's comparison is rounded exactly like C's
/// (`aaccoder.c:745-790`). Every array is slot-indexed; the decision lands on
/// the group-start slot `w * 16 + g` (for a long frame the slot of band `g`
/// is `g` itself).
///
/// Four attempts per band, indexed by `sid_sf_boost`: each lowers the side
/// channel's scalefactor by three more steps (a coarser side, which is what
/// usually makes the pair cheap) and is rejected if the scalefactor-delta chain
/// could not carry the new value. The comparison strips the pure bit counts off
/// both sums, so what decides is distortion under the masking threshold plus the
/// separate rule that the pair must cost *fewer* bits than the pair it replaces.
///
/// Every arithmetic step models C's `float`, and the coefficient loads are
/// rounded to `float` first, because the C encoder's `sce->coeffs` are `float`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `SCALE_MAX_POS - SCALE_DIV_512` (`aacenc.h`): the highest scalefactor index
/// the quantiser may use, `255 - 36`.
let aac_ms_scale_top : Int32 = 219

///|
/// `FLT_MIN` (`float.h`), added to every masking threshold so a silent band
/// cannot divide by zero.
let aac_ms_flt_min : Double = 1.1754943508222875e-38

///|
/// `NOISE_BT` / `RESERVED_BT` (`aac.h:74-75`) as this module needs them.
let aac_ms_noise_bt : Int32 = 13

///|
let aac_ms_reserved_bt : Int32 = 12

///|
/// `0.001f`, `0.0035f` and `0.0045f` from `bval2bmax` (`aacenc_utils.h:164`) and
/// its caller, written out as the single-precision values themselves. A C
/// `float` literal is not the decimal the source shows - `0.0035f` is
/// `0.0035000001080334187` - and an f64 literal reaching an f32 multiply moves
/// the result by one ulp of the constant, which is one ulp of `bmax` here and
/// therefore one ulp of the side channel's lambda.
let aac_ms_b_offset : Double = 0.0010000000474974513

///|
let aac_ms_b_numerator : Double = 0.0035000001080334187

///|
let aac_ms_b_divisor : Double = 0.0044999998062849045

///|
/// Everything `search_for_ms` reads: the pair's spectra as they stand after
/// intensity stereo has been mixed in, both channels' masking thresholds (in
/// C's slot layout, `g` for a long frame and `w * 16 + g` for a short one),
/// the window grouping, their twoloop/PNS outcome, plus the intensity mask it
/// must leave alone. `ms_mask` is the *incoming* mask: the intensity search
/// records an out-of-phase band there (it has no other place to say "flip the
/// sign at decode time"), and `search_for_ms` only rewrites the entries that
/// intensity did not claim.
pub struct AacMsIn {
  coefs0 : Array[Double]
  coefs1 : Array[Double]
  band_sizes : Array[Int32]
  shape : AacTwoShape
  thr0 : Array[Double]
  thr1 : Array[Double]
  sf0 : Array[Int32]
  sf1 : Array[Int32]
  cb0 : Array[Int32]
  cb1 : Array[Int32]
  zeroes0 : Array[Int32]
  zeroes1 : Array[Int32]
  is_mask : Array[Int32]
  ms_mask : Array[Int32]
  num_swb : Int32
}

///|
/// Build the input (the struct's fields are private to the package).
pub fn aac_ms_in(
  coefs0 : Array[Double],
  coefs1 : Array[Double],
  band_sizes : Array[Int32],
  shape : AacTwoShape,
  thr0 : Array[Double],
  thr1 : Array[Double],
  sf0 : Array[Int32],
  sf1 : Array[Int32],
  cb0 : Array[Int32],
  cb1 : Array[Int32],
  zeroes0 : Array[Int32],
  zeroes1 : Array[Int32],
  is_mask : Array[Int32],
  ms_mask : Array[Int32],
  num_swb : Int32,
) -> AacMsIn {
  {
    coefs0,
    coefs1,
    band_sizes,
    shape,
    thr0,
    thr1,
    sf0,
    sf1,
    cb0,
    cb1,
    zeroes0,
    zeroes1,
    is_mask,
    ms_mask,
    num_swb,
  }
}

///|
/// The mask plus the *rewritten* per-slot scalefactor and band type of both
/// channels - the quantiser and the bitstream write these, not the twoloop
/// values. `boost`/`dist1`/`dist2` are the last attempt's bookkeeping, exported
/// so a vector test can pin the comparison itself and not only its outcome.
/// `mid_cost`/`bits1`/`bmax` split `dist2` one step further - it is
/// `mid_cost + side_cost - bits1`, and `bmax` is the only band-position
/// dependent factor of the side channel's lambda - because a one-ulp
/// disagreement in a distortion sum is otherwise invisible: the mask, the boost
/// and both rewrites still come out the same.
pub struct AacMsOut {
  ms_mask : Array[Int32]
  sf0 : Array[Int32]
  cb0 : Array[Int32]
  sf1 : Array[Int32]
  cb1 : Array[Int32]
  boost : Array[Int32]
  dist1 : Array[Double]
  dist2 : Array[Double]
  mid_cost : Array[Double]
  bits1 : Array[Int32]
  bmax : Array[Double]
}

///|
/// `bval2bmax` (`aacenc_utils.h:164`): the band-position-dependent share of the
/// energy the side signal is allowed to keep.
fn aac_ms_bval2bmax(b : Double) -> Double {
  let b3 = aac_two_mul(aac_two_mul(b, b), b)
  let den = aac_two_mul(aac_two_mul(15.5, 15.5), 15.5)
  aac_two_add(
    aac_ms_b_offset,
    aac_two_div(aac_two_mul(aac_ms_b_numerator, b3), den),
  )
}

///|
/// `ff_sfdelta_can_replace` (`aacenc_utils.h:222`): whether band `band`'s
/// scalefactor may become `new_sf` without breaking the differential chain,
/// given the previous coded band's value and the next one in the chain.
fn aac_ms_can_replace(
  sf : Array[Int32],
  nextband : Array[Int32],
  prev_sf : Int32,
  new_sf : Int32,
  band : Int32,
) -> Bool {
  new_sf >= prev_sf - 60 &&
  new_sf <= prev_sf + 60 &&
  sf[nextband[band]] >= new_sf - 60 &&
  sf[nextband[band]] <= new_sf + 60
}

///|
/// One `quantize_band_cost` call: its rate-distortion sum and its bit count.
/// `search_for_ms` keeps both, because after the window loop it subtracts the
/// bits off the distortion sums and compares the bit counts separately.
priv struct AacMsCost {
  cost : Double
  bits : Int32
}

///|
fn aac_ms_band_cost(
  coef : Array[Double],
  scaled : Array[Double],
  qc : Array[Int32],
  size : Int32,
  sf : Int32,
  cb : Int32,
  lambda : Double,
) -> AacMsCost {
  let out = aac_two_band_cost(coef, 0, scaled, 0, qc, size, sf, cb, lambda)
  { cost: out.cost, bits: out.bits, }
}

///|
/// Copy `src` into a fresh `len`-long array (the inputs' lengths differ by
/// window shape; the outputs must not).
fn aac_ms_fit(src : Array[Int32], len : Int32) -> Array[Int32] {
  let out : Array[Int32] = Array::make(len, 0)
  for i in 0..<len {
    out[i] = src[i]
  }
  out
}

///|
/// `FFMAX(1, x)`: `search_for_ms` never lets a codebook be zero, since a zero
/// band type would tell the decoder to skip the band's spectral data.
fn aac_ms_max1(x : Int32) -> Int32 {
  if x < 1 {
    1
  } else {
    x
  }
}

///|
/// `search_for_ms` (`aaccoder.c:702`), both window shapes. Every array is
/// slot-indexed; on a long frame the slot of band `g` is `g`.
pub fn aac_ms_search(d : AacMsIn, lambda : Double) -> AacMsOut {
  let n = d.num_swb
  let num_windows = d.shape.num_windows
  let group_len = d.shape.group_len
  // Output arrays live in slot space: the full `w * 16 + g` range on a short
  // frame, plain band indices on a long one.
  let out_len = if num_windows == 1 { n } else { 128 }
  let ms_mask = aac_ms_fit(d.ms_mask, out_len)
  // All four rewrites are normalised to the slot-space length: the scalefactor
  // arrays arrive twoloop-length (always 128) while the right channel's band
  // type arrives view-length (band-long or slot-short), and the caller writes
  // the result back onto the element's sticky arrays of exactly `out_len`.
  let sf0 = aac_ms_fit(d.sf0, out_len)
  let sf1 = aac_ms_fit(d.sf1, out_len)
  let cb0 = aac_ms_fit(d.cb0, out_len)
  let cb1 = aac_ms_fit(d.cb1, out_len)
  let boost : Array[Int32] = Array::make(out_len, -1)
  let dist1_out : Array[Double] = Array::make(out_len, 0.0)
  let dist2_out : Array[Double] = Array::make(out_len, 0.0)
  let mid_cost_out : Array[Double] = Array::make(out_len, 0.0)
  let bits1_out : Array[Int32] = Array::make(out_len, 0)
  let bmax_out : Array[Double] = Array::make(out_len, 0.0)
  let nextband0 = aac_two_init_nextband_map(d.zeroes0, d.cb0, n, d.shape)
  let nextband1 = aac_two_init_nextband_map(d.zeroes1, d.cb1, n, d.shape)
  // `mslambda` is the side channel's own discount, capped at 1.
  let boost_lambda = aac_two_div(lambda, 120.0)
  let msl = if boost_lambda < 1.0 { boost_lambda } else { 1.0 }
  let mut prev_mid = sf0[0]
  let mut prev_side = sf1[0]
  let m : Array[Double] = Array::make(128, 0.0)
  let s : Array[Double] = Array::make(128, 0.0)
  let l : Array[Double] = Array::make(128, 0.0)
  let r : Array[Double] = Array::make(128, 0.0)
  let qc : Array[Int32] = Array::make(128, 0)
  let mut w = 0
  while w < num_windows {
    let gl = group_len[w]
    let mut start = 0
    for g in 0..<n {
      let size = d.band_sizes[g]
      let slot = w * 16 + g
      let gdouble = aac_two_div(aac_two_mul(g.to_double(), 17.0), n.to_double())
      let bmax = aac_two_div(aac_ms_bval2bmax(gdouble), aac_ms_b_divisor)
      // `search_for_ms` claims the whole mask for its own use everywhere except
      // where intensity stereo already put something: an out-of-phase band's
      // flip marker lives in `ms_mask` and survives this search untouched.
      if d.is_mask[slot] == 0 {
        ms_mask[slot] = 0
      }
      if d.zeroes0[slot] == 0 && d.zeroes1[slot] == 0 && d.is_mask[slot] == 0 {
        // Mid/side's scalefactor and codebook are fixed for the whole window
        // group from the companded peak of `M` and `S` over its windows, so
        // compute them first (`aaccoder.c:726-740`).
        let mut mmax = 0.0
        let mut smax = 0.0
        for w2 in 0..<gl {
          let base = (w + w2) * 128 + start
          for i in 0..<size {
            let c0 = aac_two_f32(d.coefs0[base + i])
            let c1 = aac_two_f32(d.coefs1[base + i])
            m[i] = aac_two_mul(aac_two_add(c0, c1), 0.5)
            s[i] = aac_two_sub(m[i], c1)
          }
          let m34 = aac_two_abs_pow34(m, size)
          let s34 = aac_two_abs_pow34(s, size)
          for i in 0..<size {
            if m34[i] > mmax {
              mmax = m34[i]
            }
            if s34[i] > smax {
              smax = s34[i]
            }
          }
        }
        let minidx = if sf0[slot] < sf1[slot] { sf0[slot] } else { sf1[slot] }
        for b in 0..<4 {
          let mididx = aac_two_clip(minidx, 0, aac_ms_scale_top)
          let sididx = aac_two_clip(minidx - b * 3, 0, aac_ms_scale_top)
          if cb0[slot] != aac_ms_noise_bt &&
            cb1[slot] != aac_ms_noise_bt &&
            !(aac_ms_can_replace(sf0, nextband0, prev_mid, mididx, slot) &&
            aac_ms_can_replace(sf1, nextband1, prev_side, sididx, slot)) {
            // Upstream: "scalefactor range violation, bad stuff, will decrease
            // quality unacceptably".
            continue
          }
          let midcb = aac_ms_max1(aac_two_find_min_book(mmax, mididx))
          let sidcb = aac_ms_max1(aac_two_find_min_book(smax, sididx))
          // `dist1`/`dist2` are built up over the window group with each
          // window's bit count subtracted as it joins, so the comparison is a
          // pure distortion one while `B0`/`B1` still carry the bits.
          let mut dist1 = 0.0
          let mut dist2 = 0.0
          let mut b0 = 0
          let mut b1_bits = 0
          let mut mid_cost_total = 0.0
          for w2 in 0..<gl {
            let base = (w + w2) * 128 + start
            for i in 0..<size {
              let c0 = aac_two_f32(d.coefs0[base + i])
              let c1 = aac_two_f32(d.coefs1[base + i])
              l[i] = c0
              r[i] = c1
              m[i] = aac_two_mul(aac_two_add(c0, c1), 0.5)
              s[i] = aac_two_sub(m[i], c1)
            }
            let t0 = aac_two_add(d.thr0[(w + w2) * 16 + g], aac_ms_flt_min)
            let t1 = aac_two_add(d.thr1[(w + w2) * 16 + g], aac_ms_flt_min)
            let minthr = if t0 < t1 { t0 } else { t1 }
            let l34 = aac_two_abs_pow34(l, size)
            let r34 = aac_two_abs_pow34(r, size)
            let m34 = aac_two_abs_pow34(m, size)
            let s34 = aac_two_abs_pow34(s, size)
            let cl = aac_ms_band_cost(
              l,
              l34,
              qc,
              size,
              sf0[slot],
              cb0[slot],
              aac_two_div(lambda, t0),
            )
            let cr = aac_ms_band_cost(
              r,
              r34,
              qc,
              size,
              sf1[slot],
              cb1[slot],
              aac_two_div(lambda, t1),
            )
            let cm = aac_ms_band_cost(
              m,
              m34,
              qc,
              size,
              mididx,
              midcb,
              aac_two_div(lambda, minthr),
            )
            // C computes `minthr` for the mid cost *before* the `+ FLT_MIN`
            // the lambdas add it to, and the side's divisor is
            // `minthr * bmax + FLT_MIN` with the same pre-epsilon `minthr`.
            let side_lambda = aac_two_div(
              msl,
              aac_two_add(
                aac_two_mul(aac_two_sub(minthr, aac_ms_flt_min), bmax),
                aac_ms_flt_min,
              ),
            )
            let cs = aac_ms_band_cost(
              s, s34, qc, size, sididx, sidcb, side_lambda,
            )
            dist1 = aac_two_add(dist1, cl.cost)
            dist2 = aac_two_add(dist2, cm.cost)
            dist1 = aac_two_add(dist1, cr.cost)
            dist2 = aac_two_add(dist2, cs.cost)
            b0 = b0 + cl.bits + cr.bits
            b1_bits = b1_bits + cm.bits + cs.bits
            dist1 = aac_two_sub(dist1, (cl.bits + cr.bits).to_double())
            dist2 = aac_two_sub(dist2, (cm.bits + cs.bits).to_double())
            mid_cost_total = aac_two_add(mid_cost_total, cm.cost)
          }
          boost[slot] = b
          dist1_out[slot] = dist1
          dist2_out[slot] = dist2
          mid_cost_out[slot] = mid_cost_total
          bits1_out[slot] = b1_bits
          bmax_out[slot] = bmax
          ms_mask[slot] = if dist2 <= dist1 && b1_bits < b0 { 1 } else { 0 }
          if ms_mask[slot] == 1 {
            if cb0[slot] != aac_ms_noise_bt && cb1[slot] != aac_ms_noise_bt {
              sf0[slot] = mididx
              sf1[slot] = sididx
              cb0[slot] = midcb
              cb1[slot] = sidcb
            } else if (cb0[slot] != aac_ms_noise_bt) !=
              (cb1[slot] != aac_ms_noise_bt) {
              // `ms_mask` would be ignored by the mix anyway, and upstream
              // notes that it confuses some decoders.
              ms_mask[slot] = 0
            }
            break
          } else if b1_bits > b0 {
            // More boost cannot fix this.
            break
          }
        }
      }
      if d.zeroes0[slot] == 0 && cb0[slot] < aac_ms_reserved_bt {
        prev_mid = sf0[slot]
      }
      if d.zeroes1[slot] == 0 &&
        d.is_mask[slot] == 0 &&
        cb1[slot] < aac_ms_reserved_bt {
        prev_side = sf1[slot]
      }
      start = start + size
    }
    w = w + gl
  }
  {
    ms_mask,
    sf0,
    cb0,
    sf1,
    cb1,
    boost,
    dist1: dist1_out,
    dist2: dist2_out,
    mid_cost: mid_cost_out,
    bits1: bits1_out,
    bmax: bmax_out,
  }
}
