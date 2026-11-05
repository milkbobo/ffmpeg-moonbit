/// MoonBit port of the encode side of FFmpeg 9.0.2 `opus/pvq.c`:
/// `ppp_pvq_search_c`, `celt_exp_rotation`, `celt_alg_quant`, and the
/// recursive `quant_band_template` with `quant = 1`. Reuses the shared
/// integer helpers from `opus_celt_math.mbt` and the PVQ tables from
/// `opus_pvq.mbt`.
/// Copyright (c) 2007-2008 CSIRO, 2007-2009 Xiph.Org Foundation,
/// 2008-2009 Gregory Maxwell, 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2017 Rostislav Pehlivanov. LGPL-2.1-or-later.

///|
/// CELT noise LCG (`celt_rng`).
fn opus_enc_celt_rng(f : OpusEncCeltFrame) -> UInt32 {
  f.seed = 1664525U * f.seed + 1013904223U
  f.seed
}

///|
/// PVQ table access: `CELT_PVQ_U(n, k)` and `CELT_PVQ_V(n, k)`.
fn opus_enc_pvq_u(n : Int32, k : Int32) -> UInt32 {
  opus_pvq_get(n, k)
}

///|
fn opus_enc_pvq_v(n : Int32, k : Int32) -> UInt32 {
  opus_enc_pvq_u(n, k) + opus_enc_pvq_u(n, k + 1)
}

///|
/// `celt_exp_rotation_impl`.
fn opus_enc_exp_rotation_impl(
  x : Array[Float],
  off : Int32,
  len : Int32,
  stride : Int32,
  c : Float,
  s : Float,
) -> Unit {
  let mut p = off
  for _i in 0..<(len - stride) {
    let x1 = x[p]
    let x2 = x[p + stride]
    x[p + stride] = c * x2 + s * x1
    x[p] = c * x1 - s * x2
    p += 1
  }
  p = off + len - 2 * stride - 1
  let mut i = len - 2 * stride - 1
  while i >= 0 {
    let x1 = x[p]
    let x2 = x[p + stride]
    x[p + stride] = c * x2 + s * x1
    x[p] = c * x1 - s * x2
    p -= 1
    i -= 1
  }
}

///|
/// `celt_icwrsi` + `celt_encode_pulses`.
fn opus_enc_encode_pulses(
  rc : OpusRangeEncoder,
  y : Array[Int32],
  n : Int32,
  k : Int32,
) -> Unit {
  let mut idx : UInt32 = 0U
  let mut sum = 0
  for i in 0..<n {
    let ii = n - 1 - i
    let i_s = opus_enc_pvq_u(n - ii, sum + y[ii].abs() + 1)
    let add : UInt32 = if y[ii] < 0 { i_s } else { 0U }
    idx += opus_enc_pvq_u(n - ii, sum) + add
    sum += y[ii].abs()
  }
  rc.encode_uint(idx, opus_enc_pvq_v(n, k))
}

///|
/// `celt_alg_quant`.
fn opus_enc_alg_quant(
  rc : OpusRangeEncoder,
  x : Array[Float],
  x_off : Int32,
  n : Int32,
  k : Int32,
  spread : Int32,
  blocks : Int32,
  gain : Float,
  y : Array[Int32],
) -> UInt32 {
  opus_enc_exp_rotation2(x, x_off, n, blocks, k, spread, true)
  let norm = opus_enc_pvq_search2(x, x_off, y, k, n)
  let g = gain / Float::from_double(norm.to_double().sqrt())
  opus_enc_encode_pulses(rc, y, n, k)
  opus_enc_normalize_residual2(y, x, x_off, n, g)
  opus_enc_exp_rotation2(x, x_off, n, blocks, k, spread, false)
  opus_enc_extract_collapse_mask2(y, n, blocks)
}

///|
/// offset variants of the helpers above (the band operates on a slice of the
/// coefficient arrays).
fn opus_enc_pvq_search2(
  x : Array[Float],
  x_off : Int32,
  y : Array[Int32],
  k0 : Int32,
  n : Int32,
) -> Float {
  let mut k = k0
  let mut res : Float = 0.0
  for i in 0..<n {
    res += x[x_off + i].abs()
  }
  let scale : Float = Float::from_int(k) / (res + 1.1920928955078125e-7)
  let mut y_norm : Int32 = 0
  let mut xy_norm : Float = 0.0
  for i in 0..<n {
    y[i] = opus_enc_rintf(scale * x[x_off + i])
    y_norm += y[i] * y[i]
    xy_norm += Float::from_int(y[i]) * x[x_off + i]
    k -= y[i].abs()
  }
  while k != 0 {
    let mut max_idx = 0
    let phase = if k > 0 { 1 } else { -1 }
    let mut max_num : Float = 0.0
    let mut max_den : Float = 1.0
    y_norm += 1
    for i in 0..<n {
      let ca = 1 ^
        ((if y[i] == 0 { 1 } else { 0 }) & (if phase < 0 { 1 } else { 0 }))
      let y_new = y_norm + 2 * phase * y[i].abs()
      let mut xy_new : Float = xy_norm +
        Float::from_int(phase) * x[x_off + i].abs()
      xy_new = xy_new * xy_new
      if ca != 0 && max_den * xy_new > Float::from_int(y_new) * max_num {
        max_den = Float::from_int(y_new)
        max_num = xy_new
        max_idx = i
      }
    }
    k -= phase
    let sign = if x[x_off + max_idx] > 0.0 {
      1
    } else if x[x_off + max_idx] < 0.0 {
      -1
    } else {
      0
    }
    let effective = phase * sign
    xy_norm += Float::from_int(effective) * x[x_off + max_idx]
    y_norm += 2 * effective * y[max_idx]
    y[max_idx] += effective
  }
  Float::from_int(y_norm)
}

///|
fn opus_enc_exp_rotation2(
  x : Array[Float],
  x_off : Int32,
  len0 : Int32,
  stride0 : Int32,
  k : Int32,
  spread : Int32,
  encode : Bool,
) -> Unit {
  if 2 * k >= len0 || spread == 0 {
    return
  }
  let denom : Float = Float::from_int(len0 + (20 - 5 * spread) * k)
  let gain : Float = Float::from_int(len0) / denom
  // upstream stores `theta` as a float before calling cosf/sinf
  let theta_f : Float = Float::from_double(
    3.14159265358979323846 * gain.to_double() * gain.to_double() / 4.0,
  )
  let theta = theta_f.to_double()
  let c = opus_enc_cosf(theta)
  let s = opus_enc_sinf(theta)
  let mut stride2 = 0
  if len0 >= stride0 << 3 {
    stride2 = 1
    while (stride2 * stride2 + stride2) * stride0 + (stride0 >> 2) < len0 {
      stride2 += 1
    }
  }
  let len = len0 / stride0
  for i in 0..<stride0 {
    let off = x_off + i * len
    if encode {
      opus_enc_exp_rotation_impl(x, off, len, 1, c, -s)
      if stride2 != 0 {
        opus_enc_exp_rotation_impl(x, off, len, stride2, s, -c)
      }
    } else {
      if stride2 != 0 {
        opus_enc_exp_rotation_impl(x, off, len, stride2, s, c)
      }
      opus_enc_exp_rotation_impl(x, off, len, 1, c, s)
    }
  }
}

///|
fn opus_enc_normalize_residual2(
  iy : Array[Int32],
  x : Array[Float],
  x_off : Int32,
  n : Int32,
  g : Float,
) -> Unit {
  for i in 0..<n {
    x[x_off + i] = g * Float::from_int(iy[i])
  }
}

///|
fn opus_enc_extract_collapse_mask2(
  iy : Array[Int32],
  n : Int32,
  b : Int32,
) -> UInt32 {
  if b <= 1 {
    return 1U
  }
  let n0 = n / b
  let mut mask = 0U
  for i in 0..<b {
    for j in 0..<n0 {
      if iy[i * n0 + j] != 0 {
        mask = mask | (1U << i)
      }
    }
  }
  mask
}

///|
/// `celt_calc_theta`.
fn opus_enc_calc_theta(
  x : Array[Float],
  x_off : Int32,
  y : Array[Float],
  y_off : Int32,
  coupling : Bool,
  n : Int32,
) -> Int32 {
  let mut e0 : Float = 0.0
  let mut e1 : Float = 0.0
  if coupling {
    for i in 0..<n {
      let a = x[x_off + i]
      let b = y[y_off + i]
      e0 += (a + b) * (a + b)
      e1 += (a - b) * (a - b)
    }
  } else {
    for i in 0..<n {
      e0 += x[x_off + i] * x[x_off + i]
      e1 += y[y_off + i] * y[y_off + i]
    }
  }
  let angle = opus_enc_atan2f(
    Float::from_double(e1.to_double().sqrt()),
    Float::from_double(e0.to_double().sqrt()),
  )
  opus_enc_rintf(32768.0 * angle / 3.14159265358979323846)
}

///|
/// `celt_stereo_is_decouple` with offsets.
fn opus_enc_stereo_is_decouple(
  x : Array[Float],
  x_off : Int32,
  y : Array[Float],
  y_off : Int32,
  e_l : Float,
  e_r : Float,
  n : Int32,
) -> Unit {
  // `energy_n = 1/(sqrt(e_l^2 + e_r^2) + FLT_EPSILON)`: the epsilon is inside
  // the denominator (upstream), not added to the reciprocal.
  let root = Float::from_double((e_l * e_l + e_r * e_r).to_double().sqrt())
  let energy_n : Float = 1.0 / (root + 1.1920928955078125e-7)
  let el = e_l * energy_n
  let er = e_r * energy_n
  for i in 0..<n {
    x[x_off + i] = el * x[x_off + i] + er * y[y_off + i]
  }
}

///|
/// `celt_stereo_ms_decouple` with offsets.
fn opus_enc_stereo_ms_decouple(
  x : Array[Float],
  x_off : Int32,
  y : Array[Float],
  y_off : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    let xret = x[x_off + i]
    x[x_off + i] = Float::from_double(
      (x[x_off + i] + y[y_off + i]).to_double() * 0.70710678118654752440,
    )
    y[y_off + i] = Float::from_double(
      (y[y_off + i] - xret).to_double() * 0.70710678118654752440,
    )
  }
}

///|
/// `celt_stereo_merge` with offsets.
fn opus_enc_stereo_merge2(
  x : Array[Float],
  x_off : Int32,
  y : Array[Float],
  y_off : Int32,
  mid : Float,
  n : Int32,
) -> Unit {
  let mut xp : Float = 0.0
  let mut side : Float = 0.0
  for i in 0..<n {
    xp += x[x_off + i] * y[y_off + i]
    side += y[y_off + i] * y[y_off + i]
  }
  xp *= mid
  let e0 : Float = mid * mid + side - 2.0 * xp
  let e1 : Float = mid * mid + side + 2.0 * xp
  if e0 < 0.0006 || e1 < 0.0006 {
    for i in 0..<n {
      y[y_off + i] = x[x_off + i]
    }
    return
  }
  let g0 : Float = 1.0 / e0.sqrt()
  let g1 : Float = 1.0 / e1.sqrt()
  for i in 0..<n {
    let a = mid * x[x_off + i]
    let b = y[y_off + i]
    x[x_off + i] = g0 * (a - b)
    y[y_off + i] = g1 * (a + b)
  }
}

///|
/// `quant_band_template` with quant = 1. `lowband`/`lowband_out` are
/// (array, offset) pairs; `None` for NULL. `x`/`y` are the coefficient
/// arrays with their band offsets.
fn opus_enc_quant_band(
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
  band : Int32,
  x : Array[Float],
  x_off : Int32,
  y : Array[Float]?,
  y_off0 : Int32,
  n0 : Int32,
  bits0 : Int32,
  blocks0 : Int32,
  lowband0 : (Array[Float], Int32)?,
  duration0 : Int32,
  lowband_out0 : (Array[Float], Int32)?,
  level : Int32,
  gain : Float,
  lowband_scratch : Array[Float],
  fill0 : Int32,
  hadamard_tmp : Array[Float],
) -> UInt32 {
  let stereo = y is Some(_)
  let mut y_arr = y
  let mut y_off = y_off0
  let mut n = n0
  let mut bits = bits0
  let mut blocks = blocks0
  let mut lowband = lowband0
  let mut duration = duration0
  let lowband_out = lowband_out0
  let mut fill = fill0
  let mut n_b = n0 / blocks
  let mut b0 = blocks
  let mut time_divide = 0
  let mut recombine = 0
  let mut inv = false
  let mut mid : Float = 0.0
  let mut side : Float = 0.0
  let longblocks = b0 == 1
  let mut cm : UInt32 = 0U
  let n_orig = n0
  if n == 1 {
    // sign for each channel (C: `for (i = 0; i <= stereo; i++) { ... x = Y; }`)
    let mut arr = x
    let mut off = x_off
    let iters = if stereo { 2 } else { 1 }
    for _i in 0..<iters {
      let mut sign = 0
      if f.remaining2 >= 1 << 3 {
        sign = if arr[off] < 0.0 { 1 } else { 0 }
        rc.put_raw(sign.reinterpret_as_uint(), 1)
        f.remaining2 -= 1 << 3
      }
      arr[off] = 1.0 - 2.0 * Float::from_int(sign)
      match y_arr {
        Some(ya) => {
          arr = ya
          off = y_off
        }
        None => ()
      }
    }
    match lowband_out {
      Some((out, out_off)) => out[out_off] = x[x_off]
      None => ()
    }
    return 1U
  }
  if !stereo && level == 0 {
    let mut tf_change = f.tf_change[band]
    if tf_change > 0 {
      recombine = tf_change
    }
    let mut lowband_is_scratch = false
    match lowband {
      Some((lb, lb_off)) =>
        if recombine != 0 || ((n_b & 1) == 0 && tf_change < 0) || b0 > 1 {
          for i in 0..<n {
            lowband_scratch[i] = lb[lb_off + i]
          }
          lowband = Some((lowband_scratch, 0))
          lowband_is_scratch = true
        }
      None => ()
    }
    let _ = lowband_is_scratch
    for k in 0..<recombine {
      opus_celt_haar({ data: x, offset: x_off, }, n >> k, 1 << k)
      fill = opus_celt_bit_interleave[fill & 0xF] |
        (opus_celt_bit_interleave[(fill >> 4) & 0xF] << 2)
    }
    blocks = blocks >> recombine
    n_b = n_b << recombine
    while (n_b & 1) == 0 && tf_change < 0 {
      opus_celt_haar({ data: x, offset: x_off, }, n_b, blocks)
      fill = fill | (fill << blocks)
      blocks = blocks << 1
      n_b = n_b >> 1
      time_divide += 1
      tf_change += 1
    }
    b0 = blocks
    if b0 > 1 {
      if lowband_is_scratch {
        opus_celt_hadamard(
          { data: lowband_scratch, offset: 0, },
          n_b >> recombine,
          b0 << recombine,
          longblocks,
          false,
        )
      }
      opus_celt_hadamard(
        { data: x, offset: x_off, },
        n_b >> recombine,
        b0 << recombine,
        longblocks,
        false,
      )
    }
  }
  // Split decision
  let cache_idx = opus_celt_cache_index[(duration + 1) * opus_enc_max_bands +
    band]
  let cache0 = opus_celt_cache_bits[cache_idx]
  let mut split = stereo
  if !stereo &&
    duration >= 0 &&
    bits > opus_celt_cache_bits[cache_idx + cache0] + 12 &&
    n > 2 {
    n = n >> 1
    y_arr = Some(x)
    y_off = x_off + n
    split = true
    duration -= 1
    if blocks == 1 {
      fill = (fill & 1) | (fill << 1)
    }
    blocks = (blocks + 1) >> 1
  }
  if split {
    let ya = match y_arr {
      Some(a) => a
      None => abort("unreachable")
    }
    // `celt_calc_theta` runs for BOTH cases: with coupling it is the
    // stereo angle, without it is the time-split angle of the two halves.
    let mut itheta = opus_enc_calc_theta(x, x_off, ya, y_off, stereo, n)
    let pulse_cap = opus_celt_log_freq_range[band] + duration * 8
    let offset = (pulse_cap >> 1) - (if stereo && n == 2 { 16 } else { 4 })
    let mut qn = 1
    if !(stereo && band >= f.intensity_stereo) {
      qn = opus_celt_qn(n, bits, offset, pulse_cap, stereo)
    }
    let tell = rc.tell_frac()
    if qn != 1 {
      // upstream scales the angle unconditionally (`if (quant)`), not only
      // for the stereo case
      itheta = (itheta * qn + 8192) >> 14
      if stereo && n > 2 {
        rc.encode_uint_step(itheta.reinterpret_as_uint(), qn / 2)
      } else if stereo || b0 > 1 {
        rc.encode_uint(
          itheta.reinterpret_as_uint(),
          (qn + 1).reinterpret_as_uint(),
        )
      } else {
        rc.encode_uint_tri(itheta.reinterpret_as_uint(), qn)
      }
      itheta = itheta * 16384 / qn
      if stereo {
        if itheta == 0 {
          opus_enc_stereo_is_decouple(
            x,
            x_off,
            ya,
            y_off,
            f.block[0].lin_energy[band],
            f.block[1].lin_energy[band],
            n,
          )
        } else {
          opus_enc_stereo_ms_decouple(x, x_off, ya, y_off, n)
        }
      }
    } else if stereo {
      // upstream assigns unconditionally: `inv = apply_phase_inv ? itheta > 8192 : 0`
      inv = f.apply_phase_inv && itheta > 8192
      if inv {
        for i in 0..<n {
          ya[y_off + i] = -ya[y_off + i]
        }
      }
      opus_enc_stereo_is_decouple(
        x,
        x_off,
        ya,
        y_off,
        f.block[0].lin_energy[band],
        f.block[1].lin_energy[band],
        n,
      )
      if bits > 2 << 3 && f.remaining2 > 2 << 3 {
        rc.encode_log(if inv { 1 } else { 0 }, 2)
      } else {
        inv = false
      }
      itheta = 0
    }
    let qalloc = rc.tell_frac() - tell
    bits -= qalloc
    let orig_fill = fill
    let mut imid = 0
    let mut iside = 0
    let mut delta = 0
    if itheta == 0 {
      imid = 32767
      iside = 0
      fill = fill & ((1 << blocks) - 1)
      delta = -16384
    } else if itheta == 16384 {
      imid = 0
      iside = 32767
      fill = fill & (((1 << blocks) - 1) << blocks)
      delta = 16384
    } else {
      imid = opus_celt_cos(itheta)
      iside = opus_celt_cos(16384 - itheta)
      delta = opus_celt_round_mul((n - 1) << 7, opus_celt_log2tan(iside, imid))
    }
    mid = Float::from_int(imid) / 32768.0
    side = Float::from_int(iside) / 32768.0
    if n == 2 && stereo {
      // special N=2 stereo case: one bit for the side
      let mut mbits = bits
      let sbits = if itheta != 0 && itheta != 16384 { 1 << 3 } else { 0 }
      mbits -= sbits
      let c = itheta > 8192
      f.remaining2 -= qalloc + sbits
      let (x2, x2_off, y2, y2_off) = if c {
        (ya, y_off, x, x_off)
      } else {
        (x, x_off, ya, y_off)
      }
      let mut sign = 0
      if sbits != 0 {
        sign = if x2[x2_off] * y2[y2_off + 1] - x2[x2_off + 1] * y2[y2_off] <
          0.0 {
          1
        } else {
          0
        }
        rc.put_raw(sign.reinterpret_as_uint(), 1)
      }
      let s = 1 - 2 * sign
      cm = opus_enc_quant_band(
        f,
        rc,
        band,
        x2,
        x2_off,
        None,
        0,
        n,
        mbits,
        blocks,
        lowband,
        duration,
        lowband_out,
        level,
        gain,
        lowband_scratch,
        orig_fill,
        hadamard_tmp,
      )
      y2[y2_off] = Float::from_int(-s) * x2[x2_off + 1]
      y2[y2_off + 1] = Float::from_int(s) * x2[x2_off]
      x[x_off] = x[x_off] * mid
      x[x_off + 1] = x[x_off + 1] * mid
      ya[y_off] = ya[y_off] * side
      ya[y_off + 1] = ya[y_off + 1] * side
      let t0 = x[x_off]
      x[x_off] = t0 - ya[y_off]
      ya[y_off] = t0 + ya[y_off]
      let t1 = x[x_off + 1]
      x[x_off + 1] = t1 - ya[y_off + 1]
      ya[y_off + 1] = t1 + ya[y_off + 1]
    } else {
      // "Normal" split code
      let mut next_lowband2 : (Array[Float], Int32)? = None
      let mut next_lowband_out1 : (Array[Float], Int32)? = None
      let mut next_level = 0
      if b0 > 1 && !stereo && (itheta & 0x3fff) != 0 {
        if itheta > 8192 {
          delta -= delta >> (4 - duration)
        } else {
          let d2 = delta + (n << 3 >> (5 - duration))
          delta = if d2 < 0 { d2 } else { 0 }
        }
      }
      let mut mbits = opus_enc_clip_i((bits - delta) / 2, 0, bits)
      let mut sbits = bits - mbits
      f.remaining2 -= qalloc
      if lowband is Some(_) && !stereo {
        match lowband {
          Some((lb, lb_off)) => next_lowband2 = Some((lb, lb_off + n))
          None => ()
        }
      }
      if stereo {
        next_lowband_out1 = lowband_out
      } else {
        next_level = level + 1
      }
      let rebalance0 = f.remaining2
      let gain_mid : Float = if stereo { 1.0 } else { gain * mid }
      if mbits >= sbits {
        cm = opus_enc_quant_band(
          f,
          rc,
          band,
          x,
          x_off,
          None,
          0,
          n,
          mbits,
          blocks,
          lowband,
          duration,
          next_lowband_out1,
          next_level,
          gain_mid,
          lowband_scratch,
          fill,
          hadamard_tmp,
        )
        let rebalance = mbits - (rebalance0 - f.remaining2)
        if rebalance > 3 << 3 && itheta != 0 {
          sbits += rebalance - (3 << 3)
        }
        let cmt = opus_enc_quant_band(
          f,
          rc,
          band,
          ya,
          y_off,
          None,
          0,
          n,
          sbits,
          blocks,
          next_lowband2,
          duration,
          None,
          next_level,
          gain * side,
          lowband_scratch,
          fill >> blocks,
          hadamard_tmp,
        )
        cm = cm | (cmt << (if stereo { 0 } else { b0 >> 1 }))
      } else {
        cm = opus_enc_quant_band(
          f,
          rc,
          band,
          ya,
          y_off,
          None,
          0,
          n,
          sbits,
          blocks,
          next_lowband2,
          duration,
          None,
          next_level,
          gain * side,
          lowband_scratch,
          fill >> blocks,
          hadamard_tmp,
        )
        cm = cm << (if stereo { 0 } else { b0 >> 1 })
        let rebalance = sbits - (rebalance0 - f.remaining2)
        if rebalance > 3 << 3 && itheta != 16384 {
          mbits += rebalance - (3 << 3)
        }
        cm = cm |
          opus_enc_quant_band(
            f,
            rc,
            band,
            x,
            x_off,
            None,
            0,
            n,
            mbits,
            blocks,
            lowband,
            duration,
            next_lowband_out1,
            next_level,
            gain_mid,
            lowband_scratch,
            fill,
            hadamard_tmp,
          )
      }
    }
  } else {
    // no-split case
    let q_init = opus_celt_bits2pulses(cache_idx, bits)
    let mut q = q_init
    let mut curr_bits = opus_celt_pulses2bits(cache_idx, q)
    f.remaining2 -= curr_bits
    while f.remaining2 < 0 && q > 0 {
      f.remaining2 += curr_bits
      q -= 1
      curr_bits = opus_celt_pulses2bits(cache_idx, q)
      f.remaining2 -= curr_bits
    }
    if q != 0 {
      let kk = if q < 8 { q } else { (8 + (q & 7)) << ((q >> 3) - 1) }
      cm = opus_enc_alg_quant(
        rc,
        x,
        x_off,
        n,
        kk,
        f.spread,
        blocks,
        gain,
        f.pulse_scratch,
      )
    } else {
      let cm_mask = (1U << blocks) - 1U
      fill = fill & cm_mask.reinterpret_as_int()
      if fill != 0 {
        match lowband {
          None => {
            // Noise
            for i in 0..<n {
              let r = opus_enc_celt_rng(f)
              let v = r.reinterpret_as_int() >> 20
              x[x_off + i] = Float::from_int(v)
            }
            cm = cm_mask
          }
          Some((lb, lb_off)) => {
            // Folded spectrum
            for i in 0..<n {
              let r = opus_enc_celt_rng(f)
              let d : Float = if (r & 0x8000U) != 0U {
                1.0 / 256.0
              } else {
                -1.0 / 256.0
              }
              x[x_off + i] = lb[lb_off + i] + d
            }
            cm = fill.reinterpret_as_uint()
          }
        }
        opus_celt_renormalize({ data: x, offset: x_off, }, n, gain)
      } else {
        for i in 0..<n {
          x[x_off + i] = 0.0
        }
      }
    }
  }
  if stereo {
    if n > 2 {
      opus_enc_stereo_merge2(x, x_off, ya_of(y_arr), y_off, mid, n)
    }
    if inv {
      match y_arr {
        Some(ya) =>
          for i in 0..<n {
            ya[y_off + i] = -ya[y_off + i]
          }
        None => ()
      }
    }
  } else if level == 0 {
    if b0 > 1 {
      opus_celt_hadamard(
        { data: x, offset: x_off, },
        n_b >> recombine,
        b0 << recombine,
        longblocks,
        true,
      )
    }
    let mut nb = n_b
    let mut bl = b0
    for _k in 0..<time_divide {
      bl = bl >> 1
      nb = nb << 1
      cm = cm | (cm >> bl)
      opus_celt_haar({ data: x, offset: x_off, }, nb, bl)
    }
    for k in 0..<recombine {
      cm = opus_celt_bit_deinterleave[cm.reinterpret_as_int() & 0xFF].reinterpret_as_uint()
      opus_celt_haar({ data: x, offset: x_off, }, n_orig >> k, 1 << k)
    }
    bl = bl << recombine
    match lowband_out {
      Some((out, out_off)) => {
        let scale = Float::from_double(n_orig.to_double().sqrt())
        for i in 0..<n_orig {
          out[out_off + i] = scale * x[x_off + i]
        }
      }
      None => ()
    }
    if bl < 32 {
      cm = cm & ((1U << bl) - 1U)
    }
  }
  cm
}

///|
fn ya_of(y : Array[Float]?) -> Array[Float] {
  match y {
    Some(a) => a
    None => abort("unreachable")
  }
}
