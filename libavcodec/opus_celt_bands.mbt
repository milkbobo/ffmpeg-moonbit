///|
/// Recursive CELT band decoder from FFmpeg 9.0.2 opus/pvq.c.
/// Copyright (c) 2007-2008 CSIRO, 2007-2009 Xiph.Org Foundation,
/// 2008-2009 Gregory Maxwell, 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2017 Rostislav Pehlivanov. LGPL-2.1-or-later.
priv struct CeltBandContext {
  setup : OpusCeltSetup
  apply_phase_inv : Bool
  mut seed : UInt32
  mut remaining : Int32
  mut remaining2 : Int32
}

///|
fn CeltBandContext::rng(self : CeltBandContext) -> UInt32 {
  self.seed = 1664525U * self.seed + 1013904223U
  self.seed
}

///|
priv struct CeltTheta {
  angle : Int32
  cost : Int32
  delta : Int32
  mid : Float
  side : Float
  invert : Bool
  fill : Int32
}

///|
fn opus_celt_theta(
  ctx : CeltBandContext,
  rc : OpusRangeDecoder,
  band : Int32,
  n : Int32,
  bits : Int32,
  blocks : Int32,
  b0 : Int32,
  duration : Int32,
  stereo : Bool,
  fill0 : Int32,
) -> CeltTheta raise CeltSpectrumError {
  let pulse_cap = opus_celt_log_freq_range[band] + duration * 8
  let offset = (pulse_cap >> 1) - (if stereo && n == 2 { 16 } else { 4 })
  let qn = if stereo && band >= ctx.setup.allocation.intensity_stereo {
    1
  } else {
    opus_celt_qn(n, bits, offset, pulse_cap, stereo)
  }
  let tell = rc.tell_frac()
  let mut angle = 0
  let mut invert = false
  if qn != 1 {
    angle = if stereo && n > 2 {
      opus_celt_result(rc.decode_step(qn / 2))
    } else if stereo || b0 > 1 {
      opus_celt_result(rc.decode_uint((qn + 1).reinterpret_as_uint())).reinterpret_as_int()
    } else {
      opus_celt_result(rc.decode_tri(qn))
    }
    angle = angle * 16384 / qn
  } else if stereo {
    let inv = if bits > 16 && ctx.remaining2 > 16 {
      opus_celt_result(rc.decode_log(2))
    } else {
      0
    }
    invert = ctx.apply_phase_inv && inv != 0
  }
  let cost = rc.tell_frac() - tell
  let mut fill = fill0
  let (imid, iside, delta) = if angle == 0 {
    fill = fill & ((1 << blocks) - 1)
    (32767, 0, -16384)
  } else if angle == 16384 {
    fill = fill & (((1 << blocks) - 1) << blocks)
    (0, 32767, 16384)
  } else {
    let imid = opus_celt_cos(angle)
    let iside = opus_celt_cos(16384 - angle)
    (
      imid,
      iside,
      opus_celt_round_mul((n - 1) << 7, opus_celt_log2tan(iside, imid)),
    )
  }
  {
    angle,
    cost,
    delta,
    mid: Float::from_int(imid) / 32768.0,
    side: Float::from_int(iside) / 32768.0,
    invert,
    fill,
  }
}

///|
fn opus_celt_band(
  ctx : CeltBandContext,
  rc : OpusRangeDecoder,
  band : Int32,
  x : CeltVector,
  y0 : CeltVector?,
  n0 : Int32,
  bits0 : Int32,
  blocks0 : Int32,
  lowband0 : CeltVector?,
  duration0 : Int32,
  lowband_out : CeltVector?,
  level : Int32,
  gain : Float,
  fill0 : Int32,
) -> UInt32 raise CeltSpectrumError {
  let stereo = y0 is Some(_)
  let mut y = y0
  let mut n = n0
  let mut bits = bits0
  let mut blocks = blocks0
  let mut duration = duration0
  let mut fill = fill0
  let mut lowband = lowband0
  let mut nb = n / blocks
  let mut nb0 = nb
  let mut b0 = blocks
  let longblocks = b0 == 1
  let mut recombine = 0
  let mut time_divide = 0
  let mut split = stereo
  let mut cm = 0U
  if n == 1 {
    let vectors = match y {
      Some(y) => [x, y]
      None => [x]
    }
    for vector in vectors {
      let sign = if ctx.remaining2 >= 8 {
        ctx.remaining2 -= 8
        opus_celt_result(rc.get_raw(1)).reinterpret_as_int()
      } else {
        0
      }
      vector[0] = Float::from_int(1 - 2 * sign)
    }
    if lowband_out is Some(output) {
      output[0] = x[0]
    }
    return 1U
  }
  if !stereo && level == 0 {
    let mut tf = ctx.setup.tf_change[band]
    if tf > 0 {
      recombine = tf
    }
    if lowband is Some(source) &&
      (recombine != 0 || ((nb & 1) == 0 && tf < 0) || b0 > 1) {
      lowband = Some({ data: [ for i in 0..<n => source[i] ], offset: 0, })
    }
    for k in 0..<recombine {
      if lowband is Some(source) {
        opus_celt_haar(source, n >> k, 1 << k)
      }
      fill = opus_celt_bit_interleave[fill & 15] |
        (opus_celt_bit_interleave[fill >> 4] << 2)
    }
    blocks = blocks >> recombine
    nb = nb << recombine
    while (nb & 1) == 0 && tf < 0 {
      if lowband is Some(source) {
        opus_celt_haar(source, nb, blocks)
      }
      fill = fill | (fill << blocks)
      blocks = blocks << 1
      nb = nb >> 1
      time_divide += 1
      tf += 1
    }
    b0 = blocks
    nb0 = nb
    if b0 > 1 && lowband is Some(source) {
      opus_celt_hadamard(
        source,
        nb >> recombine,
        b0 << recombine,
        longblocks,
        false,
      )
    }
  }
  let cache_index = (duration + 1) * 21 + band
  if cache_index < 0 || cache_index >= opus_celt_cache_index.length() {
    raise SpectrumError("opus: invalid recursive CELT duration")
  }
  let cache = opus_celt_cache_index[cache_index]
  if cache < 0 {
    raise SpectrumError("opus: invalid recursive CELT cache")
  }
  if !stereo &&
    duration >= 0 &&
    bits > opus_celt_cache_bits[cache + opus_celt_cache_bits[cache]] + 12 &&
    n > 2 {
    n = n >> 1
    y = Some(x.slice(n))
    split = true
    duration -= 1
    if blocks == 1 {
      fill = (fill & 1) | (fill << 1)
    }
    blocks = (blocks + 1) >> 1
  }
  let mut mid : Float = 0.0
  let mut invert = false
  if split {
    let side_vector = match y {
      Some(value) => value
      None => raise SpectrumError("opus: missing CELT split vector")
    }
    let original_fill = fill
    let theta = opus_celt_theta(
      ctx, rc, band, n, bits, blocks, b0, duration, stereo, fill,
    )
    mid = theta.mid
    invert = theta.invert
    fill = theta.fill
    bits -= theta.cost
    if n == 2 && stereo {
      let side_bits = if theta.angle != 0 && theta.angle != 16384 {
        8
      } else {
        0
      }
      let mid_bits = bits - side_bits
      ctx.remaining2 -= theta.cost + side_bits
      let (x2, y2) = if theta.angle > 8192 {
        (side_vector, x)
      } else {
        (x, side_vector)
      }
      let sign = if side_bits != 0 {
        opus_celt_result(rc.get_raw(1)).reinterpret_as_int()
      } else {
        0
      }
      let sign = 1 - 2 * sign
      cm = opus_celt_band(
        ctx,
        rc,
        band,
        x2,
        None,
        n,
        mid_bits,
        blocks,
        lowband,
        duration,
        lowband_out,
        level,
        gain,
        original_fill,
      )
      y2[0] = -Float::from_int(sign) * x2[1]
      y2[1] = Float::from_int(sign) * x2[0]
      for i in 0..<2 {
        x[i] = x[i] * mid
        side_vector[i] = side_vector[i] * theta.side
      }
      for i in 0..<2 {
        let value = x[i]
        x[i] = value - side_vector[i]
        side_vector[i] = value + side_vector[i]
      }
    } else {
      let mut delta = theta.delta
      if b0 > 1 && !stereo && (theta.angle & 0x3fff) != 0 {
        if theta.angle > 8192 {
          delta -= delta >> (4 - duration)
        } else {
          delta = (delta + (n << 3 >> (5 - duration))).min(0)
        }
      }
      let mut mid_bits = ((bits - delta) / 2).max(0).min(bits)
      let mut side_bits = bits - mid_bits
      ctx.remaining2 -= theta.cost
      let next_lowband = if !stereo {
        lowband.map(source => source.slice(n))
      } else {
        None
      }
      let output = if stereo { lowband_out } else { None }
      let next_level = if stereo { 0 } else { level + 1 }
      let mut rebalance = ctx.remaining2
      let mid_gain : Float = if stereo { 1.0 } else { gain * mid }
      let shift = if stereo { 0 } else { b0 >> 1 }
      if mid_bits >= side_bits {
        cm = opus_celt_band(
          ctx,
          rc,
          band,
          x,
          None,
          n,
          mid_bits,
          blocks,
          lowband,
          duration,
          output,
          next_level,
          mid_gain,
          fill,
        )
        rebalance = mid_bits - (rebalance - ctx.remaining2)
        if rebalance > 24 && theta.angle != 0 {
          side_bits += rebalance - 24
        }
        let side_mask = opus_celt_band(
          ctx,
          rc,
          band,
          side_vector,
          None,
          n,
          side_bits,
          blocks,
          next_lowband,
          duration,
          None,
          next_level,
          gain * theta.side,
          fill >> blocks,
        )
        cm = cm | (side_mask << shift)
      } else {
        cm = opus_celt_band(
          ctx,
          rc,
          band,
          side_vector,
          None,
          n,
          side_bits,
          blocks,
          next_lowband,
          duration,
          None,
          next_level,
          gain * theta.side,
          fill >> blocks,
        )
        cm = cm << shift
        rebalance = side_bits - (rebalance - ctx.remaining2)
        if rebalance > 24 && theta.angle != 16384 {
          mid_bits += rebalance - 24
        }
        cm = cm |
          opus_celt_band(
            ctx,
            rc,
            band,
            x,
            None,
            n,
            mid_bits,
            blocks,
            lowband,
            duration,
            output,
            next_level,
            mid_gain,
            fill,
          )
      }
    }
  } else {
    let mut q = opus_celt_bits2pulses(cache, bits)
    let mut current_bits = opus_celt_pulses2bits(cache, q)
    ctx.remaining2 -= current_bits
    while ctx.remaining2 < 0 && q > 0 {
      ctx.remaining2 += current_bits
      q -= 1
      current_bits = opus_celt_pulses2bits(cache, q)
      ctx.remaining2 -= current_bits
    }
    if q != 0 {
      let k = if q < 8 { q } else { (8 + (q & 7)) << ((q >> 3) - 1) }
      let band_data = opus_celt_result(
        rc.decode_celt_band(n, k, ctx.setup.allocation.spread, blocks, gain),
      )
      for i in 0..<n {
        x[i] = band_data.coefficients[i]
      }
      cm = band_data.collapse_mask
    } else {
      let mask = (1 << blocks) - 1
      fill = fill & mask
      if fill != 0 {
        if lowband is Some(source) {
          for i in 0..<n {
            let noise : Float = if (ctx.rng() & 0x8000U) != 0U {
              1.0 / 256.0
            } else {
              -1.0 / 256.0
            }
            x[i] = source[i] + noise
          }
          cm = fill.reinterpret_as_uint()
        } else {
          for i in 0..<n {
            x[i] = Float::from_int(ctx.rng().reinterpret_as_int() >> 20)
          }
          cm = mask.reinterpret_as_uint()
        }
        opus_celt_renormalize(x, n, gain)
      } else {
        for i in 0..<n {
          x[i] = 0.0
        }
      }
    }
  }
  if stereo {
    if y is Some(side_vector) {
      if n > 2 {
        opus_celt_stereo_merge(x, side_vector, mid, n)
      }
      if invert {
        for i in 0..<n {
          side_vector[i] = -side_vector[i]
        }
      }
    }
  } else if level == 0 {
    if b0 > 1 {
      opus_celt_hadamard(x, nb >> recombine, b0 << recombine, longblocks, true)
    }
    nb = nb0
    blocks = b0
    for _ in 0..<time_divide {
      blocks = blocks >> 1
      nb = nb << 1
      cm = cm | (cm >> blocks)
      opus_celt_haar(x, nb, blocks)
    }
    for k in 0..<recombine {
      cm = opus_celt_bit_deinterleave[cm.reinterpret_as_int()].reinterpret_as_uint()
      opus_celt_haar(x, n0 >> k, 1 << k)
    }
    blocks = blocks << recombine
    if lowband_out is Some(output) {
      let scale = Float::from_int(n0).sqrt()
      for i in 0..<n0 {
        output[i] = scale * x[i]
      }
    }
    cm = cm & ((1U << blocks) - 1U)
  }
  cm
}
