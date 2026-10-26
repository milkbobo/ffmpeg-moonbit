///|
/// CELT decoder bit allocation, ported from FFmpeg 9.0.2 opus/celt.c,
/// ff_celt_bitalloc(..., encode=0). Copyright (c) 2012 Andrew D'Addesio,
/// 2013-2014 Mozilla Corporation. LGPL-2.1-or-later.
/// All band arrays have 21 entries. `pvq_bits` and `remaining` are budgets
/// in eighth-bits, not pulse counts. `caps` covers all 21 bands; the other
/// arrays are zero outside the requested [start_band, end_band) interval.
pub struct OpusCeltAllocation {
  spread : Int32
  trim : Int32
  anticollapse_bits : Int32
  coded_bands : Int32
  intensity_stereo : Int32
  dual_stereo : Bool
  remaining : Int32
  caps : Array[Int32]
  pvq_bits : Array[Int32]
  fine_bits : Array[Int32]
  fine_priority : Array[Int32]
}

///|
fn opus_celt_norm(bits : Int32, channels : Int32, size : Int32) -> Int32 {
  bits << (channels - 1) << size >> 2
}

///|
fn opus_celt_validate(
  rc : OpusRangeDecoder,
  channels : Int32,
  size : Int32,
  start : Int32,
  end : Int32,
  framebits : Int32,
) -> String? {
  if channels != 1 && channels != 2 {
    Some("opus: CELT requires one or two coded channels")
  } else if size < 0 || size > 3 {
    Some("opus: invalid CELT block size")
  } else if start < 0 || start >= end || end > 21 {
    Some("opus: invalid CELT band interval")
  } else if framebits < 0 || framebits > rc.data.length() * 8 {
    Some("opus: invalid CELT frame bit budget")
  } else {
    None
  }
}

///|
/// Decode spread, dynamic allocation boosts, trim, skipped bands, stereo
/// reservations, fine-energy bits and PVQ eighth-bit budgets. `size` is
/// log2(frame_samples/120), 0..3; `framebits` is the whole frame budget.
/// Invoke after coarse energy and TF syntax, before fine energy and PVQ.
/// Invalid parameters leave the range decoder unchanged.
///
/// ```mbt check
/// test {
///   let rc = @libavcodec.opus_rc_init(b"\x00\x23\x88\x61").unwrap()
///   let alloc = rc.decode_celt_allocation(1, 0, 0, 13, 32, false).unwrap()
///   assert_eq(alloc.pvq_bits.length(), 21)
///   assert_eq(alloc.fine_bits.length(), 21)
/// }
/// ```
pub fn OpusRangeDecoder::decode_celt_allocation(
  self : OpusRangeDecoder,
  channels : Int32,
  size : Int32,
  start : Int32,
  end : Int32,
  framebits : Int32,
  transient : Bool,
) -> Result[OpusCeltAllocation, String] {
  if opus_celt_validate(self, channels, size, start, end, framebits)
    is Some(error) {
    return Err(error)
  }
  let spread = if self.tell() + 4 <= framebits {
    match self.decode_cdf(opus_celt_model_spread[:]) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  } else {
    2
  }
  let caps = [
    for i in 0..<21 => {
      opus_celt_norm(
        (opus_celt_static_caps[(size * 2 + channels - 1) * 21 + i] + 64) *
        opus_celt_freq_range[i],
        channels,
        size,
      )
    }
  ]
  let boost = Array::make(21, 0)
  let mut dynalloc = 6
  let mut budget = framebits << 3
  for i in start..<end {
    let width = opus_celt_freq_range[i] << (channels - 1) << size
    let quanta = (width << 3).min(width.max(48))
    let mut probability = dynalloc
    // opus_rc_tell_frac returns uint32_t in C, including in these budget
    // comparisons. A corrupt frame may have overspent the signed budget.
    while (self.tell_frac() + (probability << 3)).reinterpret_as_uint() <
          budget.reinterpret_as_uint() &&
          boost[i] < caps[i] {
      let is_boost = match self.decode_log(probability) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if is_boost == 0 {
        break
      }
      boost[i] += quanta
      budget -= quanta
      probability = 1
    }
    if boost[i] != 0 {
      dynalloc = (dynalloc - 1).max(2)
    }
  }
  let trim = if (self.tell_frac() + 48).reinterpret_as_uint() <=
    budget.reinterpret_as_uint() {
    match self.decode_cdf(opus_celt_model_alloc_trim[:]) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  } else {
    5
  }
  budget = (framebits << 3) - self.tell_frac() - 1
  // C's nonnegative CeltBlockSize enum promotes the RHS to unsigned. Preserve
  // that comparison even for malformed tiny frames with a negative budget.
  let anticollapse_bits = if transient &&
    size >= 2 &&
    budget.reinterpret_as_uint() >= ((size + 2) << 3).reinterpret_as_uint() {
    8
  } else {
    0
  }
  budget -= anticollapse_bits
  let skip_bit = if budget >= 8 { 8 } else { 0 }
  budget -= skip_bit
  let mut intensity_bit = 0
  let mut dual_bit = 0
  if channels == 2 {
    intensity_bit = opus_celt_log2_frac[end - start]
    if intensity_bit <= budget {
      budget -= intensity_bit
      if budget >= 8 {
        dual_bit = 8
        budget -= 8
      }
    } else {
      intensity_bit = 0
    }
  }
  let threshold = Array::make(21, 0)
  let trim_offset = Array::make(21, 0)
  for i in start..<end {
    threshold[i] = ((3 * opus_celt_freq_range[i]) << (size + 3) >> 4).max(
      channels << 3,
    )
    trim_offset[i] = (
        (trim - 5 - size) *
        ((opus_celt_freq_range[i] * (end - i - 1)) << (size + 3 + channels - 1))
      ) >>
      6
    if opus_celt_freq_range[i] << size == 1 {
      trim_offset[i] -= channels << 3
    }
  }
  let mut low = 1
  let mut high = 10
  while low <= high {
    let center = (low + high) >> 1
    let mut done = false
    let mut total = 0
    for i = end - 1; i >= start; i = i - 1 {
      let mut bits = opus_celt_norm(
        opus_celt_freq_range[i] * opus_celt_static_alloc[center * 21 + i],
        channels,
        size,
      )
      if bits != 0 {
        bits = (bits + trim_offset[i]).max(0)
      }
      bits += boost[i]
      if bits >= threshold[i] || done {
        done = true
        total += bits.min(caps[i])
      } else if bits >= channels << 3 {
        total += channels << 3
      }
    }
    if total > budget {
      high = center - 1
    } else {
      low = center + 1
    }
  }
  high = low
  low -= 1
  let bits1 = Array::make(21, 0)
  let bits2 = Array::make(21, 0)
  let mut skip_start = start
  for i in start..<end {
    bits1[i] = opus_celt_norm(
      opus_celt_freq_range[i] * opus_celt_static_alloc[low * 21 + i],
      channels,
      size,
    )
    bits2[i] = if high >= 11 {
      caps[i]
    } else {
      opus_celt_norm(
        opus_celt_freq_range[i] * opus_celt_static_alloc[high * 21 + i],
        channels,
        size,
      )
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
      skip_start = i
    }
    bits2[i] = (bits2[i] - bits1[i]).max(0)
  }
  low = 0
  high = 64
  for _ in 0..<6 {
    let center = (low + high) >> 1
    let mut done = false
    let mut total = 0
    for i = end - 1; i >= start; i = i - 1 {
      let bits = bits1[i] + ((center * bits2[i]) >> 6)
      if bits >= threshold[i] || done {
        done = true
        total += bits.min(caps[i])
      } else if bits >= channels << 3 {
        total += channels << 3
      }
    }
    if total > budget {
      high = center
    } else {
      low = center
    }
  }
  let pulses = Array::make(21, 0)
  let mut done = false
  let mut total = 0
  for i = end - 1; i >= start; i = i - 1 {
    let mut bits = bits1[i] + ((low * bits2[i]) >> 6)
    if bits >= threshold[i] || done {
      done = true
    } else {
      bits = if bits >= channels << 3 { channels << 3 } else { 0 }
    }
    pulses[i] = bits.min(caps[i])
    total += pulses[i]
  }
  let mut coded = end
  for ;; {
    let j = coded - 1
    if j == skip_start {
      budget += skip_bit
      break
    }
    let width = opus_celt_freq_bands[j + 1] - opus_celt_freq_bands[start]
    let mut remaining = budget - total
    let bits = remaining / width
    remaining -= bits * width
    let mut allocation = pulses[j] +
      bits * opus_celt_freq_range[j] +
      (remaining - (opus_celt_freq_bands[j] - opus_celt_freq_bands[start])).max(
        0,
      )
    if allocation >= threshold[j].max((channels + 1) << 3) {
      let keep = match self.decode_log(1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if keep != 0 {
        break
      }
      total += 8
      allocation -= 8
    }
    total -= pulses[j]
    if intensity_bit != 0 {
      total -= intensity_bit
      intensity_bit = opus_celt_log2_frac[j - start]
      total += intensity_bit
    }
    pulses[j] = if allocation >= channels << 3 { channels << 3 } else { 0 }
    total += pulses[j]
    coded -= 1
  }
  let intensity = if intensity_bit != 0 {
    match self.decode_uint((coded + 1 - start).reinterpret_as_uint()) {
      Ok(v) => start + v.reinterpret_as_int()
      Err(e) => return Err(e)
    }
  } else {
    0
  }
  let dual = if intensity <= start {
    budget += dual_bit
    false
  } else if dual_bit != 0 {
    match self.decode_log(1) {
      Ok(v) => v != 0
      Err(e) => return Err(e)
    }
  } else {
    false
  }
  let mut remaining = budget - total
  let width = opus_celt_freq_bands[coded] - opus_celt_freq_bands[start]
  let bits = remaining / width
  remaining -= bits * width
  for i in start..<coded {
    let extra = remaining.min(opus_celt_freq_range[i])
    pulses[i] += extra + bits * opus_celt_freq_range[i]
    remaining -= extra
  }
  let fine_bits = Array::make(21, 0)
  let fine_priority = Array::make(21, 0)
  let mut extrabits = 0
  for i in start..<coded {
    let n = opus_celt_freq_range[i] << size
    let previous_extra = extrabits
    pulses[i] += extrabits
    if n > 1 {
      extrabits = (pulses[i] - caps[i]).max(0)
      pulses[i] -= extrabits
      let dof = n * channels +
        (if channels == 2 && n > 2 && !dual && i < intensity { 1 } else { 0 })
      let temp = dof * (opus_celt_log_freq_range[i] + (size << 3))
      let mut offset = (temp >> 1) - dof * 21
      if n == 2 {
        offset += dof << 1
      }
      if pulses[i] + offset < 2 * (dof << 3) {
        offset += temp >> 2
      } else if pulses[i] + offset < 3 * (dof << 3) {
        offset += temp >> 3
      }
      let fine = (pulses[i] + offset + (dof << 2)) / (dof << 3)
      let maximum = (pulses[i] >> 3 >> (channels - 1)).min(8).max(0)
      fine_bits[i] = fine.max(0).min(maximum)
      fine_priority[i] = if fine_bits[i] * (dof << 3) >= pulses[i] + offset {
        1
      } else {
        0
      }
      pulses[i] -= fine_bits[i] << (channels - 1) << 3
    } else {
      extrabits = (pulses[i] - (channels << 3)).max(0)
      pulses[i] -= extrabits
      fine_priority[i] = 1
    }
    if extrabits > 0 {
      let fineextra = (extrabits >> (channels + 2)).min(8 - fine_bits[i])
      fine_bits[i] += fineextra
      let used = fineextra << (channels + 2)
      fine_priority[i] = if used >= extrabits - previous_extra { 1 } else { 0 }
      extrabits -= used
    }
  }
  for i in coded..<end {
    fine_bits[i] = pulses[i] >> (channels - 1) >> 3
    pulses[i] = 0
    fine_priority[i] = if fine_bits[i] < 1 { 1 } else { 0 }
  }
  Ok({
    spread,
    trim,
    anticollapse_bits,
    coded_bands: coded,
    intensity_stereo: intensity,
    dual_stereo: dual,
    remaining: extrabits,
    caps,
    pvq_bits: pulses,
    fine_bits,
    fine_priority,
  })
}
