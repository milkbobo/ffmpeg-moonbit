/// MoonBit port of the encode path of FFmpeg 9.0.2 `opus/celt.c`:
/// `ff_celt_bitalloc` (encode branches) and `ff_celt_quant_bands`.
/// Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla Corporation.
/// LGPL-2.1-or-later.

///|
/// `ff_celt_bitalloc` (encode = true) as an `OpusEncoder` method.
fn OpusEncoder::celt_bitalloc(
  _self : OpusEncoder,
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
) -> Unit {
  let mut skip_bit = 0
  let mut intensitystereo_bit = 0
  let mut dualstereo_bit = 0
  let mut dynalloc = 6
  let mut extrabits = 0
  let boost : Array[Int32] = Array::make(21, 0)
  let trim_offset : Array[Int32] = Array::make(21, 0)
  let threshold : Array[Int32] = Array::make(21, 0)
  let bits1 : Array[Int32] = Array::make(21, 0)
  let bits2 : Array[Int32] = Array::make(21, 0)
  let mut skip_startband = f.start_band
  // Spread
  if rc.tell() + 4 <= f.framebits {
    rc.encode_cdf(f.spread, [32, 7, 9, 30, 32])
  } else {
    f.spread = 2
  }
  // Initialize static allocation caps
  for i in 0..<21 {
    let caps_base = f.size * 42 + (f.channels - 1) * 21 + i
    let normc = (opus_celt_static_caps[caps_base] + 64) *
      opus_celt_freq_range[i]
    f.caps[i] = (normc * (1 << (f.channels - 1))) << f.size >> 2
  }
  // Band boosts
  let mut tbits_8ths = f.framebits << 3
  for i in f.start_band..<f.end_band {
    let quanta0 = opus_celt_freq_range[i] << (f.channels - 1) << f.size
    let quanta = (quanta0 << 3).min((6 << 3).max(quanta0))
    let mut b_dynalloc = dynalloc
    let mut remaining_boost = f.alloc_boost[i]
    while rc.tell_frac() + (b_dynalloc << 3) < tbits_8ths &&
          boost[i] < f.caps[i] {
      let is_boost = remaining_boost
      remaining_boost -= 1
      rc.encode_log(if is_boost != 0 { 1 } else { 0 }, b_dynalloc)
      if is_boost == 0 {
        break
      }
      boost[i] += quanta
      tbits_8ths -= quanta
      b_dynalloc = 1
    }
    if boost[i] != 0 {
      dynalloc = (dynalloc - 1).max(2)
    }
  }
  // Allocation trim
  if rc.tell_frac() + (6 << 3) <= tbits_8ths {
    rc.encode_cdf(f.alloc_trim, [
      128, 2, 4, 9, 19, 41, 87, 109, 119, 124, 126, 128,
    ])
  }
  // Anti-collapse bit reservation
  tbits_8ths = (f.framebits << 3) - rc.tell_frac() - 1
  f.anticollapse_needed = 0
  if f.transient != 0 && f.size >= 2 && tbits_8ths >= (f.size + 2) << 3 {
    f.anticollapse_needed = 1 << 3
  }
  tbits_8ths -= f.anticollapse_needed
  // Band skip bit reservation
  if tbits_8ths >= 1 << 3 {
    skip_bit = 1 << 3
  }
  tbits_8ths -= skip_bit
  // Intensity/dual stereo bit reservation
  if f.channels == 2 {
    intensitystereo_bit = opus_celt_log2_frac[f.end_band - f.start_band]
    if intensitystereo_bit <= tbits_8ths {
      tbits_8ths -= intensitystereo_bit
      if tbits_8ths >= 1 << 3 {
        dualstereo_bit = 1 << 3
        tbits_8ths -= 1 << 3
      }
    } else {
      intensitystereo_bit = 0
    }
  }
  // Trim offsets
  for i in f.start_band..<f.end_band {
    let trim = f.alloc_trim - 5 - f.size
    let band = opus_celt_freq_range[i] * (f.end_band - i - 1)
    let duration = f.size + 3
    let scale = duration + f.channels - 1
    threshold[i] = ((3 * opus_celt_freq_range[i]) << duration >> 4).max(
      f.channels << 3,
    )
    trim_offset[i] = (trim * (band << scale)) >> 6
    if opus_celt_freq_range[i] << f.size == 1 {
      trim_offset[i] -= f.channels << 3
    }
  }
  // Bisection 1 over the static allocation vectors
  let mut low = 1
  let mut high = 11 - 1
  while low <= high {
    let center = (low + high) >> 1
    let mut done = 0
    let mut total = 0
    let mut i = f.end_band - 1
    while i >= f.start_band {
      let normc = opus_celt_freq_range[i] *
        opus_celt_static_alloc[center * 21 + i]
      let mut bandbits = (normc * (1 << (f.channels - 1))) << f.size >> 2
      if bandbits != 0 {
        bandbits = (bandbits + trim_offset[i]).max(0)
      }
      bandbits += boost[i]
      if bandbits >= threshold[i] || done != 0 {
        done = 1
        total += bandbits.min(f.caps[i])
      } else if bandbits >= f.channels << 3 {
        total += f.channels << 3
      }
      i -= 1
    }
    if total > tbits_8ths {
      high = center - 1
    } else {
      low = center + 1
    }
  }
  high = low
  low -= 1
  // Bisection 2: per-band bit ranges around the chosen vectors
  for i in f.start_band..<f.end_band {
    let n1 = opus_celt_freq_range[i] * opus_celt_static_alloc[low * 21 + i]
    bits1[i] = (n1 * (1 << (f.channels - 1))) << f.size >> 2
    if high >= 11 {
      bits2[i] = f.caps[i]
    } else {
      let n2 = opus_celt_freq_range[i] * opus_celt_static_alloc[high * 21 + i]
      bits2[i] = (n2 * (1 << (f.channels - 1))) << f.size >> 2
    }
    if bits1[i] != 0 {
      bits1[i] = (bits1[i] + trim_offset[i]).max(0)
    }
    if bits2[i] != 0 {
      bits2[i] = (bits2[i] + trim_offset[i]).max(0)
    }
    if low != 0 {
      bits1[i] += boost[i]
    }
    bits2[i] += boost[i]
    if boost[i] != 0 {
      skip_startband = i
    }
    bits2[i] = (bits2[i] - bits1[i]).max(0)
  }
  // Bisection 3: interpolate between the two vectors
  let mut low3 = 0
  let mut high3 = 1 << 6
  for _i in 0..<6 {
    let center = (low3 + high3) >> 1
    let mut done = 0
    let mut total = 0
    let mut j = f.end_band - 1
    while j >= f.start_band {
      let bandbits = bits1[j] + ((center * bits2[j]) >> 6)
      if bandbits >= threshold[j] || done != 0 {
        done = 1
        total += bandbits.min(f.caps[j])
      } else if bandbits >= f.channels << 3 {
        total += f.channels << 3
      }
      j -= 1
    }
    if total > tbits_8ths {
      high3 = center
    } else {
      low3 = center
    }
  }
  // Final per-band allocation
  let mut done = 0
  let mut total = 0
  let mut i = f.end_band - 1
  while i >= f.start_band {
    let mut bandbits = bits1[i] + ((low3 * bits2[i]) >> 6)
    if bandbits >= threshold[i] || done != 0 {
      done = 1
    } else {
      bandbits = if bandbits >= f.channels << 3 { f.channels << 3 } else { 0 }
    }
    bandbits = bandbits.min(f.caps[i])
    f.pulses[i] = bandbits
    total += bandbits
    i -= 1
  }
  // Band skipping
  f.coded_bands = f.end_band
  while true {
    let j = f.coded_bands - 1
    if j == skip_startband {
      // all remaining bands are not skipped
      tbits_8ths += skip_bit
      break
    }
    let mut remaining = tbits_8ths - total
    let denom_j = opus_celt_freq_bands[j + 1] -
      opus_celt_freq_bands[f.start_band]
    let bandbits = remaining / denom_j
    remaining -= bandbits *
      (opus_celt_freq_bands[j + 1] - opus_celt_freq_bands[f.start_band])
    let mut allocation = f.pulses[j] + bandbits * opus_celt_freq_range[j]
    allocation += (remaining -
    (opus_celt_freq_bands[j] - opus_celt_freq_bands[f.start_band])).max(0)
    if allocation >= threshold[j].max((f.channels + 1) << 3) {
      let do_not_skip = f.coded_bands <= f.skip_band_floor
      rc.encode_log(if do_not_skip { 1 } else { 0 }, 1)
      if do_not_skip {
        break
      }
      total += 1 << 3
      allocation -= 1 << 3
    }
    // the band is skipped, reclaim its bits
    total -= f.pulses[j]
    if intensitystereo_bit != 0 {
      total -= intensitystereo_bit
      intensitystereo_bit = opus_celt_log2_frac[j - f.start_band]
      total += intensitystereo_bit
    }
    let p = if allocation >= f.channels << 3 { f.channels << 3 } else { 0 }
    f.pulses[j] = p
    total += p
    f.coded_bands -= 1
  }
  // IS start band
  if intensitystereo_bit != 0 {
    f.intensity_stereo = f.intensity_stereo.min(f.coded_bands)
    rc.encode_uint(
      f.intensity_stereo.reinterpret_as_uint(),
      (f.coded_bands + 1 - f.start_band).reinterpret_as_uint(),
    )
  }
  // DS flag
  if f.intensity_stereo <= f.start_band {
    // no intensity stereo means no dual stereo
    tbits_8ths += dualstereo_bit
  } else if dualstereo_bit != 0 {
    rc.encode_log(if f.dual_stereo { 1 } else { 0 }, 1)
  }
  // Supply the remaining bits to lower bands
  let mut remaining = tbits_8ths - total
  let denom_c = opus_celt_freq_bands[f.coded_bands] -
    opus_celt_freq_bands[f.start_band]
  let bandbits = remaining / denom_c
  remaining -= bandbits *
    (opus_celt_freq_bands[f.coded_bands] - opus_celt_freq_bands[f.start_band])
  for i in f.start_band..<f.coded_bands {
    let bits = remaining.min(opus_celt_freq_range[i])
    f.pulses[i] += bits + bandbits * opus_celt_freq_range[i]
    remaining -= bits
  }
  // Fine energy allocation
  for i in f.start_band..<f.coded_bands {
    let n = opus_celt_freq_range[i] << f.size
    let prev_extra = extrabits
    f.pulses[i] += extrabits
    if n > 1 {
      extrabits = (f.pulses[i] - f.caps[i]).max(0)
      f.pulses[i] -= extrabits
      let extra_dof = if f.channels == 2 &&
        n > 2 &&
        !f.dual_stereo &&
        i < f.intensity_stereo {
        1
      } else {
        0
      }
      let dof = n * f.channels + extra_dof
      let temp = dof * (opus_celt_log_freq_range[i] + (f.size << 3))
      let mut offset = (temp >> 1) - dof * 21
      if n == 2 {
        offset += dof << 1
      }
      if f.pulses[i] + offset < 2 * (dof << 3) {
        offset += temp >> 2
      } else if f.pulses[i] + offset < 3 * (dof << 3) {
        offset += temp >> 3
      }
      let fine_bits = (f.pulses[i] + offset + (dof << 2)) / (dof << 3)
      let mut max_bits = (f.pulses[i] >> 3 >> (f.channels - 1)).min(8)
      max_bits = max_bits.max(0)
      f.fine_bits[i] = opus_enc_clip_i(fine_bits, 0, max_bits)
      f.fine_priority[i] = if f.fine_bits[i] * (dof << 3) >=
        f.pulses[i] + offset {
        1
      } else {
        0
      }
      f.pulses[i] -= f.fine_bits[i] << (f.channels - 1) << 3
    } else {
      // all bits go to fine energy except for the sign bit
      extrabits = (f.pulses[i] - (f.channels << 3)).max(0)
      f.pulses[i] -= extrabits
      f.fine_bits[i] = 0
      f.fine_priority[i] = 1
    }
    if extrabits > 0 {
      let fineextra = (extrabits >> (f.channels + 2)).min(8 - f.fine_bits[i])
      f.fine_bits[i] += fineextra
      let fe = fineextra << (f.channels + 2)
      f.fine_priority[i] = if fe >= extrabits - prev_extra { 1 } else { 0 }
      extrabits -= fe
    }
  }
  f.remaining = extrabits
  // skipped bands dedicate all of their bits for fine energy
  let mut i = f.coded_bands
  while i < f.end_band {
    f.fine_bits[i] = f.pulses[i] >> (f.channels - 1) >> 3
    f.pulses[i] = 0
    f.fine_priority[i] = if f.fine_bits[i] < 1 { 1 } else { 0 }
    i += 1
  }
}

///|
/// `ff_celt_quant_bands` (encode path).
fn OpusEncoder::celt_quant_bands(
  _self : OpusEncoder,
  f : OpusEncCeltFrame,
  rc : OpusRangeEncoder,
) -> Unit {
  let lowband_scratch : Array[Float] = Array::make(8 * 22, 0.0)
  let norm1 : Array[Float] = Array::make(2 * 8 * 100, 0.0)
  let norm2_off = 8 * 100
  let hadamard_tmp : Array[Float] = Array::make(176, 0.0)
  let totalbits = (f.framebits << 3) - f.anticollapse_needed
  let mut update_lowband = true
  let mut lowband_offset = 0
  for i in f.start_band..<f.end_band {
    let mut cm0 : UInt32 = (1U << f.blocks) - 1U
    let mut cm1 : UInt32 = (1U << f.blocks) - 1U
    let band_offset = opus_celt_freq_bands[i] << f.size
    let band_size = opus_celt_freq_range[i] << f.size
    let consumed = rc.tell_frac()
    let mut effective_lowband = -1
    let mut b = 0
    if i != f.start_band {
      f.remaining -= consumed
    }
    f.remaining2 = totalbits - consumed - 1
    if i <= f.coded_bands - 1 {
      let curr_balance = f.remaining / (f.coded_bands - i).min(3)
      b = opus_enc_clip_i(
        (f.remaining2 + 1).min(f.pulses[i] + curr_balance),
        0,
        (1 << 14) - 1,
      )
    }
    let lower = opus_celt_freq_bands[i] - opus_celt_freq_range[i]
    if lower >= opus_celt_freq_bands[f.start_band] || i == f.start_band + 1 {
      if update_lowband || lowband_offset == 0 {
        lowband_offset = i
      }
    }
    if i == f.start_band + 1 {
      // Special Hybrid Folding (RFC 8251 section 9)
      let count = (opus_celt_freq_range[i] - opus_celt_freq_range[i - 1]) <<
        f.size
      for k in 0..<count {
        norm1[band_offset + k] = norm1[band_offset - count + k]
        norm1[norm2_off + band_offset + k] = norm1[norm2_off +
          band_offset -
          count +
          k]
      }
    }
    if lowband_offset != 0 &&
      (f.spread != 3 || f.blocks > 1 || f.tf_change[i] < 0) {
      let effective = opus_celt_freq_bands[f.start_band].max(
        opus_celt_freq_bands[lowband_offset] - opus_celt_freq_range[i],
      )
      effective_lowband = effective
      // C uses a do-while: `while (ff_celt_freq_bands[--foldstart] > effective_lowband);`
      // and keeps the index where it stopped (no extra +1).
      let mut foldstart = lowband_offset - 1
      while opus_celt_freq_bands[foldstart] > effective {
        foldstart -= 1
      }
      let mut foldend = lowband_offset - 1
      foldend += 1
      while foldend < i &&
            opus_celt_freq_bands[foldend] < effective + opus_celt_freq_range[i] {
        foldend += 1
      }
      cm0 = 0U
      cm1 = 0U
      for j in foldstart..<foldend {
        cm0 = cm0 | f.block[0].collapse_masks[j]
        cm1 = cm1 | f.block[f.channels - 1].collapse_masks[j]
      }
    }
    if f.dual_stereo && i == f.intensity_stereo {
      // Switch off dual stereo to do intensity
      f.dual_stereo = false
      for j in (opus_celt_freq_bands[f.start_band] << f.size)..<band_offset {
        norm1[j] = (norm1[j] + norm1[norm2_off + j]) / 2
      }
    }
    let norm_loc1 : (Array[Float], Int32)? = if effective_lowband != -1 {
      Some((norm1, effective_lowband << f.size))
    } else {
      None
    }
    let norm_loc2 : (Array[Float], Int32)? = if effective_lowband != -1 {
      Some((norm1, norm2_off + (effective_lowband << f.size)))
    } else {
      None
    }
    if f.dual_stereo {
      cm0 = opus_enc_quant_band(
        f,
        rc,
        i,
        f.block[0].coeffs,
        band_offset,
        None,
        0,
        band_size,
        b >> 1,
        f.blocks,
        norm_loc1,
        f.size,
        Some((norm1, band_offset)),
        0,
        1.0,
        lowband_scratch,
        cm0.reinterpret_as_int(),
        hadamard_tmp,
      )
      cm1 = opus_enc_quant_band(
        f,
        rc,
        i,
        f.block[1].coeffs,
        band_offset,
        None,
        0,
        band_size,
        b >> 1,
        f.blocks,
        norm_loc2,
        f.size,
        Some((norm1, norm2_off + band_offset)),
        0,
        1.0,
        lowband_scratch,
        cm1.reinterpret_as_int(),
        hadamard_tmp,
      )
    } else {
      let has_y = f.channels == 2
      let combined = cm0 | cm1
      cm0 = opus_enc_quant_band(
        f,
        rc,
        i,
        f.block[0].coeffs,
        band_offset,
        if has_y {
          Some(f.block[1].coeffs)
        } else {
          None
        },
        band_offset,
        band_size,
        b,
        f.blocks,
        norm_loc1,
        f.size,
        Some((norm1, band_offset)),
        0,
        1.0,
        lowband_scratch,
        combined.reinterpret_as_int(),
        hadamard_tmp,
      )
      cm1 = cm0
    }
    // `collapse_masks` is `uint8_t[]` upstream: the OR-accumulated masks are
    // truncated on store, and later folding ORs read the truncated values.
    f.block[0].collapse_masks[i] = cm0 & 0xFFU
    f.block[f.channels - 1].collapse_masks[i] = cm1 & 0xFFU
    f.remaining += f.pulses[i] + consumed
    // Update the folding position only as long as we have 1 bit/sample depth
    update_lowband = b > band_size << 3
  }
}
