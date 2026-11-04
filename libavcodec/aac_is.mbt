///|
/// `ff_aac_search_for_is` and its helper `aac_is_encoding_err`, FFmpeg 9.0.2
/// `libavcodec/aacenc_is.c`, restricted to one long window (the only shape this
/// project's perceptual path runs). It runs *after* the twoloop search and
/// before mid/side, exactly like `aacenc.c`: for every band above the
/// frequency gate it quantises the left band, the right band and the intensity
/// sum with the real rate-distortion cost function, and switches the band to
/// `INTENSITY_BT`/`INTENSITY_BT2` when the intensity sum is the cheaper of the
/// two candidate phases.
///
/// Every arithmetic step models C's `float` (`aac_two_f32` family), and the
/// coefficient loads are rounded to `float` first, because the C encoder's
/// `sce->coeffs` are `float`. The one place C deliberately leaves `float` is
/// `sqrt(ener0 / ener01)`: the division is `float`, the square root is the
/// `double` one, and the product is only rounded when it is stored.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `INT_STEREO_LOW_LIMIT` (`aacenc_is.c:34`): the frequency below which a band
/// is never switched to intensity, in Hz at `lambda == 170`.
let aac_is_low_limit_hz : Double = 6100.0

///|
/// `NOISE_BT` / `RESERVED_BT` / `INTENSITY_BT2` / `INTENSITY_BT`
/// (`aac.h:74-77`), as this module needs them.
let aac_is_noise_bt : Int32 = 13

let aac_is_reserved_bt : Int32 = 12

let aac_is_intensity_bt2 : Int32 = 14

let aac_is_intensity_bt : Int32 = 15

///|
/// Everything `ff_aac_search_for_is` reads from the frame: the two spectra,
/// the swb plan, both channels' psy band records and both channels' twoloop
/// outcome.
pub struct AacIsIn {
  coefs0 : Array[Double]
  coefs1 : Array[Double]
  band_sizes : Array[Int32]
  /// `band0->threshold` / `band1->threshold`, the only psy fields the search
  /// reads.
  thr0 : Array[Double]
  thr1 : Array[Double]
  sf0 : Array[Int32]
  sf1 : Array[Int32]
  cb0 : Array[Int32]
  cb1 : Array[Int32]
  zeroes0 : Array[Int32]
  zeroes1 : Array[Int32]
  num_swb : Int32
}

///|
/// Build the input (the struct's fields are private to the package).
pub fn aac_is_in(
  coefs0 : Array[Double],
  coefs1 : Array[Double],
  band_sizes : Array[Int32],
  thr0 : Array[Double],
  thr1 : Array[Double],
  sf0 : Array[Int32],
  sf1 : Array[Int32],
  cb0 : Array[Int32],
  cb1 : Array[Int32],
  zeroes0 : Array[Int32],
  zeroes1 : Array[Int32],
  num_swb : Int32,
) -> AacIsIn {
  {
    coefs0,
    coefs1,
    band_sizes,
    thr0,
    thr1,
    sf0,
    sf1,
    cb0,
    cb1,
    zeroes0,
    zeroes1,
    num_swb,
  }
}

///|
/// The decision, per band: `is_mask`, the mid/side mask after
/// `search_for_is`'s clearing, the right channel's band type (0 meaning the
/// band stayed as the twoloop left it), and the two `is_ener` values the
/// encoder then writes into the bitstream (`aacenc.c`'s
/// `apply_intensity_stereo` uses `is_ener[0]`, `set_special_band_scalefactors`
/// turns `is_ener[1]` into the position). `cpe->is_mode` is `count`.
///
/// The `pass*`/`dist*` arrays are `aac_is_encoding_err`'s per-phase
/// comparison, exported so a vector test can check the intermediate costs and
/// not only the final choice.
pub struct AacIsOut {
  is_mask : Array[Int32]
  ms_mask : Array[Int32]
  band_type1 : Array[Int32]
  is_ener0 : Array[Double]
  is_ener1 : Array[Double]
  pass1 : Array[Int32]
  pass2 : Array[Int32]
  dist11 : Array[Double]
  dist11_left : Array[Double]
  dist21 : Array[Double]
  dist21_left : Array[Double]
  dist12 : Array[Double]
  dist22 : Array[Double]
  count : Int32
}

///|
/// `struct AACISError` (`aacenc_is.c:36`).
priv struct AacIsError {
  pass : Int32
  phase : Double
  error : Double
  dist1 : Double
  /// `dist1` after the left band's cost only - the same split the reference
  /// harness exports, so a magnitude difference can be pinned to one call.
  dist1_left : Double
  dist2 : Double
  ener01 : Double
}

///|
/// `pos_pow34` (`aacenc_utils.h:40`): `sqrtf(a * sqrtf(a))`.
fn aac_is_pos_pow34(a : Double) -> Double {
  aac_two_sqrtf(aac_two_mul(a, aac_two_sqrtf(a)))
}

///|
/// `aac_is_encoding_err` (`aacenc_is.c:45`) for one window of one band.
/// `l`/`r` are the band's coefficients already rounded to `float`, `ener0` and
/// `ener1` the two channels' band energies and `ener01` the energy of the
/// phase-summed band. Returns whether coding the band as intensity would be
/// cheaper than coding both channels, and by how much.
fn aac_is_encoding_err(
  d : AacIsIn,
  g : Int32,
  l : Array[Double],
  r : Array[Double],
  ener0 : Double,
  ener1 : Double,
  ener01 : Double,
  phase : Double,
  lambda : Double,
) -> AacIsError {
  let zero = {
    pass: 0,
    phase,
    error: 0.0,
    dist1: 0.0,
    dist1_left: 0.0,
    dist2: 0.0,
    ener01,
  }
  if ener01 <= 0.0 || ener0 <= 0.0 {
    return zero
  }
  let size = d.band_sizes[g]
  // `is_sf_idx = FFMAX(1, sce0->sf_idx[w*16+g] - 4)`.
  let is_sf_idx = if d.sf0[g] - 4 > 1 { d.sf0[g] - 4 } else { 1 }
  let e01_34 = aac_two_mul(
    phase,
    aac_is_pos_pow34(aac_two_div(ener1, ener0)),
  )
  let t0 = d.thr0[g]
  let t1 = d.thr1[g]
  let minthr = if t0 < t1 { t0 } else { t1 }
  // C's `sqrt` on a `float` quotient: the division is f32, the root is the
  // double one, and the product is only rounded when it is stored.
  let scale = aac_two_div(ener0, ener01).sqrt()
  let isd : Array[Double] = Array::make(size, 0.0)
  for i in 0..<size {
    let sum = aac_two_add(l[i], aac_two_mul(r[i], phase))
    isd[i] = aac_two_f32(sum * scale)
  }
  let l34 = aac_two_abs_pow34(l, size)
  let r34 = aac_two_abs_pow34(r, size)
  let i34 = aac_two_abs_pow34(isd, size)
  let maxval = aac_two_find_max_val(1, size, i34, 0)
  let is_bt = aac_two_find_min_book(maxval, is_sf_idx)
  let qc : Array[Int32] = Array::make(size, 0)
  let dist1_left = aac_two_band_cost(
    l,
    0,
    l34,
    0,
    qc,
    size,
    d.sf0[g],
    d.cb0[g],
    aac_two_div(lambda, t0),
  ).cost
  let dist1 = aac_two_add(
    dist1_left,
    aac_two_band_cost(
      r,
      0,
      r34,
      0,
      qc,
      size,
      d.sf1[g],
      d.cb1[g],
      aac_two_div(lambda, t1),
    ).cost,
  )
  let dist_spec_err = aac_two_mul(
    aac_two_div(lambda, minthr),
    aac_is_spec_err(l34, r34, i34, size, e01_34),
  )
  let mut dist2 = aac_two_band_cost(
    isd,
    0,
    i34,
    0,
    qc,
    size,
    is_sf_idx,
    is_bt,
    aac_two_div(lambda, minthr),
  ).cost
  dist2 = aac_two_add(dist2, dist_spec_err)
  {
    pass: if dist2 <= dist1 { 1 } else { 0 },
    phase,
    error: aac_two_sub(dist2, dist1),
    dist1,
    dist1_left,
    dist2,
    ener01,
  }
}

///|
/// The `dist_spec_err` accumulation of `aac_is_encoding_err`: how far the
/// dequantised magnitude shape of the intensity sum is from the two channels'
/// own shapes, in `pow34` units. Split out only to keep the cost call chain
/// readable.
fn aac_is_spec_err(
  l34 : Array[Double],
  r34 : Array[Double],
  i34 : Array[Double],
  size : Int32,
  e01_34 : Double,
) -> Double {
  let mut acc = 0.0
  for i in 0..<size {
    let dl = aac_two_sub(l34[i], i34[i])
    acc = aac_two_add(acc, aac_two_mul(dl, dl))
    let rr = aac_two_sub(r34[i], aac_two_mul(i34[i], e01_34))
    acc = aac_two_add(acc, aac_two_mul(rr, rr))
  }
  acc
}

///|
/// `apply_intensity_stereo`: the band's left channel keeps the phase-summed,
/// energy-matched intensity signal and its right channel is emptied, because
/// the decoder rebuilds that half by scaling the left one by
/// `2^(-position / 4)` (`aac_apply_stereo`).
pub fn aac_is_apply(
  left : Array[Double],
  right : Array[Double],
  offsets : Array[Int32],
  num_swb : Int32,
  num_windows : Int32,
  bt : Array[Int32],
  flip : Array[Bool],
  scale : Array[Double],
) -> Unit {
  for b = 0; b < num_swb; b = b + 1 {
    if bt[b] == 0 {
      continue
    }
    let base = if bt[b] == aac_intensity_bt { 1.0 } else { -1.0 }
    let p = if flip[b] { -base } else { base }
    let s = scale[b]
    for w = 0; w < num_windows; w = w + 1 {
      for i = w * 128 + offsets[b]; i < w * 128 + offsets[b + 1]; i = i + 1 {
        let sum = (left[i] + p * right[i]) * s
        left[i] = sum
        right[i] = 0.0
      }
    }
  }
}

///|
/// `ff_aac_search_for_is` (`aacenc_is.c:109`), one long window.
pub fn aac_is_search(
  d : AacIsIn,
  sample_rate : Int32,
  lambda : Double,
) -> AacIsOut {
  let n = d.num_swb
  let is_mask : Array[Int32] = Array::make(n, 0)
  let ms_mask : Array[Int32] = Array::make(n, 0)
  let bt1 : Array[Int32] = Array::make(n, 0)
  let ener0_out : Array[Double] = Array::make(n, 0.0)
  let ener1_out : Array[Double] = Array::make(n, 0.0)
  let pass1 : Array[Int32] = Array::make(n, 0)
  let pass2 : Array[Int32] = Array::make(n, 0)
  let d11 : Array[Double] = Array::make(n, 0.0)
  let d11l : Array[Double] = Array::make(n, 0.0)
  let d12 : Array[Double] = Array::make(n, 0.0)
  let d21 : Array[Double] = Array::make(n, 0.0)
  let d21l : Array[Double] = Array::make(n, 0.0)
  let d22 : Array[Double] = Array::make(n, 0.0)
  // `freq_mult = sample_rate/(1024.0f/num_windows)/2.0f` and the gate is
  // `start*freq_mult > INT_STEREO_LOW_LIMIT*(lambda/170)`.
  let freq_mult = aac_two_div(aac_two_div(sample_rate.to_double(), 1024.0), 2.0)
  let limit = aac_two_mul(aac_is_low_limit_hz, aac_two_div(lambda, 170.0))
  let nextband1 = aac_two_init_nextband_map(d.zeroes1, d.cb1, n)
  let mut prev_sf1 = -1
  let mut prev_bt = -1
  let mut prev_is = 0
  let mut count = 0
  let mut start = 0
  for g in 0..<n {
    let size = d.band_sizes[g]
    if aac_two_mul(start.to_double(), freq_mult) > limit &&
        d.cb0[g] != aac_is_noise_bt && d.zeroes0[g] == 0 &&
        d.cb1[g] != aac_is_noise_bt && d.zeroes1[g] == 0 &&
        aac_two_can_remove_band(d.sf1, nextband1, prev_sf1, g) {
      // `ener01` is the sum for phase +1, `ener01p` for phase -1.
      let mut ener0 = 0.0
      let mut ener1 = 0.0
      let mut ener01 = 0.0
      let mut ener01p = 0.0
      let l : Array[Double] = Array::make(size, 0.0)
      let r : Array[Double] = Array::make(size, 0.0)
      for i in 0..<size {
        let c0 = aac_two_f32(d.coefs0[start + i])
        let c1 = aac_two_f32(d.coefs1[start + i])
        l[i] = c0
        r[i] = c1
        ener0 = aac_two_add(ener0, aac_two_mul(c0, c0))
        ener1 = aac_two_add(ener1, aac_two_mul(c1, c1))
        let s = aac_two_add(c0, c1)
        ener01 = aac_two_add(ener01, aac_two_mul(s, s))
        let t = aac_two_sub(c0, c1)
        ener01p = aac_two_add(ener01p, aac_two_mul(t, t))
      }
      let err1 = aac_is_encoding_err(
        d, g, l, r, ener0, ener1, ener01p, -1.0, lambda,
      )
      let err2 = aac_is_encoding_err(
        d, g, l, r, ener0, ener1, ener01, 1.0, lambda,
      )
      pass1[g] = err1.pass
      pass2[g] = err2.pass
      d11[g] = err1.dist1
      d11l[g] = err1.dist1_left
      d12[g] = err1.dist2
      d21[g] = err2.dist1
      d21l[g] = err2.dist1_left
      d22[g] = err2.dist2
      let best = if err1.pass == 1 && err1.error < err2.error {
        err1
      } else {
        err2
      }
      if best.pass == 1 {
        is_mask[g] = 1
        ms_mask[g] = 0
        ener0_out[g] = aac_two_f32(aac_two_div(ener0, best.ener01).sqrt())
        ener1_out[g] = aac_two_div(ener0, ener1)
        bt1[g] = if best.phase > 0.0 {
          aac_is_intensity_bt
        } else {
          aac_is_intensity_bt2
        }
        // Two neighbouring intensity bands of opposite phase encode more
        // efficiently as mid/side plus the other band type.
        if prev_is != 0 && prev_bt != bt1[g] {
          ms_mask[g] = 1
          bt1[g] = if best.phase > 0.0 {
            aac_is_intensity_bt2
          } else {
            aac_is_intensity_bt
          }
        }
        prev_bt = bt1[g]
        count = count + 1
      }
    }
    if d.zeroes1[g] == 0 && d.cb1[g] < aac_is_reserved_bt {
      prev_sf1 = d.sf1[g]
    }
    prev_is = is_mask[g]
    start = start + size
  }
  {
    is_mask,
    ms_mask,
    band_type1: bt1,
    is_ener0: ener0_out,
    is_ener1: ener1_out,
    pass1,
    pass2,
    dist11: d11,
    dist11_left: d11l,
    dist12: d12,
    dist21: d21,
    dist21_left: d21l,
    dist22: d22,
    count,
  }
}
