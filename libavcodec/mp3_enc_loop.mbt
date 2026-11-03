/// MoonBit port of shine 3.1.1 `l3loop.c`: quantisation, the inner/outer
/// iteration loops, Huffman table selection and the bit counters. shine has
/// no psychoacoustic model, so `calc_xmin` is a no-op (all `xmin` zero) and
/// the scalefactor bands always stay at zero scale factors.

///|
/// `subdivide`'s region split table (`region0_count`, `region1_count` by
/// number of active scalefactor bands).
let mp3enc_subdv_table : Array[(Int32, Int32)] = [
  (0, 0),
  (0, 0),
  (0, 0),
  (0, 0),
  (0, 0),
  (0, 1),
  (1, 1),
  (1, 1),
  (1, 2),
  (2, 2),
  (2, 3),
  (2, 3),
  (3, 4),
  (3, 4),
  (3, 4),
  (4, 5),
  (4, 5),
  (4, 6),
  (5, 6),
  (5, 6),
  (5, 7),
  (6, 7),
  (6, 7),
]

///|
/// Huffman table lookup helpers over the flat extracted tables. `desc[i]` is
/// `xlen, ylen, linbits, linmax, code_off, len_off`.
fn mp3enc_huff_xlen(h : Int32) -> Int32 {
  mp3enc_huff_desc[h * 6]
}

///|
fn mp3enc_huff_ylen(h : Int32) -> Int32 {
  mp3enc_huff_desc[h * 6 + 1]
}

///|
fn mp3enc_huff_linbits(h : Int32) -> Int32 {
  mp3enc_huff_desc[h * 6 + 2]
}

///|
fn mp3enc_huff_linmax(h : Int32) -> Int32 {
  mp3enc_huff_desc[h * 6 + 3]
}

///|
fn mp3enc_huff_code(h : Int32, idx : Int32) -> Int32 {
  mp3enc_huff_code_flat[mp3enc_huff_desc[h * 6 + 4] + idx]
}

///|
fn mp3enc_huff_len(h : Int32, idx : Int32) -> Int32 {
  mp3enc_huff_len_flat[mp3enc_huff_desc[h * 6 + 5] + idx]
}

///|
/// `quantize`: quantise `xr` into `ix` with the current step size and return
/// the maximum of `ix`. The early-exit branch leaves `ix` untouched, exactly
/// like the C code (callers never consume it in that case).
fn Mp3Encoder::quantize(
  self : Mp3Encoder,
  ix : Array[Int32],
  stepsize : Int32,
) -> Int32 {
  let scalei = mp3enc_steptabi[stepsize + 127]
  // a quick check to see if ixmax will be less than 8192
  if mp3enc_mulr(self.xrmax, scalei) > 165140 {
    // 8192**(4/3); no point in continuing, stepsize not big enough
    return 16384
  }
  let int2idx = mp3enc_int2idx
  let scale = mp3enc_steptab[stepsize + 127]
  let xrabs = self.xrabs
  let mut max = 0
  for i in 0..<mp3enc_granule_size {
    // This calculation is very sensitive: the multiply must round.
    let ln = mp3enc_mulr(xrabs[i], scalei)
    if ln < 10000 {
      ix[i] = int2idx[ln]
    } else {
      // outside table range so have to do it using floats
      let dbl = xrabs[i].to_double() * scale * 4.656612875e-10
      ix[i] = (dbl.sqrt() * dbl).sqrt().to_int()
    }
    let v = ix[i]
    if max < v {
      max = v
    }
  }
  max
}

///|
/// `calc_runlen`: partition `ix` into big values, count1 quadruples and
/// trailing zeros.
fn mp3enc_calc_runlen(ix : Array[Int32], gi : Mp3EncGranule) -> Unit {
  let mut i = mp3enc_granule_size
  while i > 1 {
    if ix[i - 1] == 0 && ix[i - 2] == 0 {
      i -= 2
    } else {
      break
    }
  }
  gi.count1 = 0
  while i > 3 {
    if ix[i - 1] <= 1 && ix[i - 2] <= 1 && ix[i - 3] <= 1 && ix[i - 4] <= 1 {
      gi.count1 += 1
      i -= 4
    } else {
      break
    }
  }
  gi.big_values = i >> 1
}

///|
/// `count1_bitcount`: bits for the count1 quadruples, selecting the better
/// of the two count1 tables.
fn mp3enc_count1_bitcount(ix : Array[Int32], gi : Mp3EncGranule) -> Int32 {
  let mut i = gi.big_values << 1
  let mut sum0 = 0
  let mut sum1 = 0
  for _k in 0..<gi.count1 {
    let v = ix[i]
    let w = ix[i + 1]
    let x = ix[i + 2]
    let y = ix[i + 3]
    let p = v + (w << 1) + (x << 2) + (y << 3)
    let mut signbits = 0
    if v != 0 {
      signbits += 1
    }
    if w != 0 {
      signbits += 1
    }
    if x != 0 {
      signbits += 1
    }
    if y != 0 {
      signbits += 1
    }
    sum0 += signbits + mp3enc_huff_len(32, p)
    sum1 += signbits + mp3enc_huff_len(33, p)
    i += 4
  }
  if sum0 < sum1 {
    gi.count1table_select = 0
    sum0
  } else {
    gi.count1table_select = 1
    sum1
  }
}

///|
/// `subdivide`: subdivide the big values region into up to three Huffman
/// regions along scalefactor band boundaries.
fn Mp3Encoder::subdivide(self : Mp3Encoder, gi : Mp3EncGranule) -> Unit {
  if gi.big_values == 0 {
    // no big_values region
    gi.region0_count = 0
    gi.region1_count = 0
  } else {
    let sfb_row = mp3enc_scale_fact_band_index
    let base = self.samplerate_index * 23
    let bigvalues_region = 2 * gi.big_values
    // Calculate scfb_anz
    let mut scfb_anz = 0
    while sfb_row[base + scfb_anz] < bigvalues_region {
      scfb_anz += 1
    }
    let mut thiscount = mp3enc_subdv_table[scfb_anz].0
    while thiscount > 0 {
      if sfb_row[base + thiscount + 1] <= bigvalues_region {
        break
      }
      thiscount -= 1
    }
    gi.region0_count = thiscount
    gi.address1 = sfb_row[base + thiscount + 1]
    let base2 = base + gi.region0_count + 1
    thiscount = mp3enc_subdv_table[scfb_anz].1
    while thiscount > 0 {
      if sfb_row[base2 + thiscount + 1] <= bigvalues_region {
        break
      }
      thiscount -= 1
    }
    gi.region1_count = thiscount
    gi.address2 = sfb_row[base2 + thiscount + 1]
    gi.address3 = bigvalues_region
  }
}

///|
/// `ix_max`.
fn mp3enc_ix_max(ix : Array[Int32], begin : Int32, end : Int32) -> Int32 {
  let mut max = 0
  for i in begin..<end {
    if max < ix[i] {
      max = ix[i]
    }
  }
  max
}

///|
/// `count_bit`: bits needed to code `ix[start..end]` with the given table.
fn mp3enc_count_bit(
  ix : Array[Int32],
  start : Int32,
  end : Int32,
  table : Int32,
) -> Int32 {
  if table == 0 {
    return 0
  }
  let h = table
  let mut sum = 0
  let ylen = mp3enc_huff_ylen(h)
  let linbits = mp3enc_huff_linbits(h)
  if table > 15 {
    // ESC-table is used
    let mut i = start
    while i < end {
      let mut x = ix[i]
      let mut y = ix[i + 1]
      if x > 14 {
        x = 15
        sum += linbits
      }
      if y > 14 {
        y = 15
        sum += linbits
      }
      sum += mp3enc_huff_len(h, x * ylen + y)
      if x != 0 {
        sum += 1
      }
      if y != 0 {
        sum += 1
      }
      i += 2
    }
  } else {
    // No ESC-words
    let mut i = start
    while i < end {
      let x = ix[i]
      let y = ix[i + 1]
      sum += mp3enc_huff_len(h, x * ylen + y)
      if x != 0 {
        sum += 1
      }
      if y != 0 {
        sum += 1
      }
      i += 2
    }
  }
  sum
}

///|
/// `new_choose_table`: pick the Huffman table that encodes `ix[begin..end]`
/// with the fewest bits. Note: this code contains knowledge about the sizes
/// and characteristics of the Huffman tables, like the C original.
fn mp3enc_new_choose_table(
  ix : Array[Int32],
  begin : Int32,
  end : Int32,
) -> Int32 {
  let max = mp3enc_ix_max(ix, begin, end)
  if max == 0 {
    return 0
  }
  let mut choice0 = 0
  let mut choice1 = 0
  if max < 15 {
    // try tables with no linbits (`for (i = 14; i--;)` in C)
    let mut i = 14
    while i > 0 {
      i -= 1
      if mp3enc_huff_xlen(i) > max {
        choice0 = i
        break
      }
    }
    let mut sum0 = mp3enc_count_bit(ix, begin, end, choice0)
    match choice0 {
      2 => {
        let sum1 = mp3enc_count_bit(ix, begin, end, 3)
        if sum1 <= sum0 {
          choice0 = 3
        }
      }
      5 => {
        let sum1 = mp3enc_count_bit(ix, begin, end, 6)
        if sum1 <= sum0 {
          choice0 = 6
        }
      }
      7 => {
        let sum1 = mp3enc_count_bit(ix, begin, end, 8)
        if sum1 <= sum0 {
          choice0 = 8
          sum0 = sum1
        }
        let sum1 = mp3enc_count_bit(ix, begin, end, 9)
        if sum1 <= sum0 {
          choice0 = 9
        }
      }
      10 => {
        let sum1 = mp3enc_count_bit(ix, begin, end, 11)
        if sum1 <= sum0 {
          choice0 = 11
          sum0 = sum1
        }
        let sum1 = mp3enc_count_bit(ix, begin, end, 12)
        if sum1 <= sum0 {
          choice0 = 12
        }
      }
      13 => {
        let sum1 = mp3enc_count_bit(ix, begin, end, 15)
        if sum1 <= sum0 {
          choice0 = 15
        }
      }
      _ => ()
    }
  } else {
    // try tables with linbits
    let max = max - 15
    let mut i = 15
    while i < 24 {
      if mp3enc_huff_linmax(i) >= max {
        choice0 = i
        break
      }
      i += 1
    }
    let mut i = 24
    while i < 32 {
      if mp3enc_huff_linmax(i) >= max {
        choice1 = i
        break
      }
      i += 1
    }
    let sum0 = mp3enc_count_bit(ix, begin, end, choice0)
    let sum1 = mp3enc_count_bit(ix, begin, end, choice1)
    if sum1 < sum0 {
      choice0 = choice1
    }
  }
  choice0
}

///|
/// `bigv_tab_select`.
fn mp3enc_bigv_tab_select(ix : Array[Int32], gi : Mp3EncGranule) -> Unit {
  gi.table_select[0] = 0
  gi.table_select[1] = 0
  gi.table_select[2] = 0
  if gi.address1 > 0 {
    gi.table_select[0] = mp3enc_new_choose_table(ix, 0, gi.address1)
  }
  if gi.address2 > gi.address1 {
    gi.table_select[1] = mp3enc_new_choose_table(ix, gi.address1, gi.address2)
  }
  if gi.big_values << 1 > gi.address2 {
    gi.table_select[2] = mp3enc_new_choose_table(
      ix,
      gi.address2,
      gi.big_values << 1,
    )
  }
}

///|
/// `bigv_bitcount`.
fn mp3enc_bigv_bitcount(ix : Array[Int32], gi : Mp3EncGranule) -> Int32 {
  let mut bits = 0
  let table0 = gi.table_select[0]
  if table0 != 0 {
    bits += mp3enc_count_bit(ix, 0, gi.address1, table0)
  }
  let table1 = gi.table_select[1]
  if table1 != 0 {
    bits += mp3enc_count_bit(ix, gi.address1, gi.address2, table1)
  }
  let table2 = gi.table_select[2]
  if table2 != 0 {
    bits += mp3enc_count_bit(ix, gi.address2, gi.address3, table2)
  }
  bits
}

///|
/// `bin_search_StepSize`: successive approximation for the initial
/// quantiser step size.
fn Mp3Encoder::bin_search_step_size(
  self : Mp3Encoder,
  desired_rate : Int32,
  ix : Array[Int32],
  gi : Mp3EncGranule,
) -> Int32 {
  let mut next = -120
  let mut count = 120
  while true {
    let half = count / 2
    let bit = if self.quantize(ix, next + half) > 8192 {
      100000 // fail
    } else {
      mp3enc_calc_runlen(ix, gi) // rzero,count1,big_values
      let mut bit = mp3enc_count1_bitcount(ix, gi) // count1_table selection
      self.subdivide(gi) // bigvalues sfb division
      mp3enc_bigv_tab_select(ix, gi) // codebook selection
      bit += mp3enc_bigv_bitcount(ix, gi) // bit count
      bit
    }
    if bit < desired_rate {
      count = half
    } else {
      next += half
      count -= half
    }
    if count <= 1 {
      break
    }
  }
  next
}

///|
/// `shine_inner_loop`: find the best quantiserStepSize for a particular set
/// of scalefacs.
fn Mp3Encoder::inner_loop(
  self : Mp3Encoder,
  ix : Array[Int32],
  max_bits : Int32,
  gi : Mp3EncGranule,
) -> Int32 {
  if max_bits < 0 {
    gi.quantizer_step_size -= 1
  }
  let mut bits = 0
  let mut fit = false
  while !fit {
    // while(quantize(ix, ++quantizerStepSize) > 8192);
    while true {
      gi.quantizer_step_size += 1
      if self.quantize(ix, gi.quantizer_step_size) <= 8192 {
        break
      }
    }
    mp3enc_calc_runlen(ix, gi) // rzero,count1,big_values
    bits = mp3enc_count1_bitcount(ix, gi) // count1_table selection
    self.subdivide(gi) // bigvalues sfb division
    mp3enc_bigv_tab_select(ix, gi) // codebook selection
    bits += mp3enc_bigv_bitcount(ix, gi) // bit count
    if bits <= max_bits {
      fit = true
    }
  }
  bits
}

///|
/// `shine_outer_loop`: compute the global gain (and, upstream, the
/// scalefacs) so the granule fits into its bit budget.
fn Mp3Encoder::outer_loop(
  self : Mp3Encoder,
  max_bits : Int32,
  ix : Array[Int32],
  gr : Int32,
  ch : Int32,
) -> Int32 {
  let gi = self.gr[gr][ch]
  gi.quantizer_step_size = self.bin_search_step_size(max_bits, ix, gi)
  gi.part2_length = self.part2_length(gr, ch)
  let huff_bits = max_bits - gi.part2_length
  let bits = self.inner_loop(ix, huff_bits, gi)
  gi.part2_3_length = gi.part2_length + bits
  gi.part2_3_length
}

///|
/// `shine_iteration_loop`: quantise every granule of every channel and
/// update the bit reservoir.
fn Mp3Encoder::iteration_loop(self : Mp3Encoder) -> Unit {
  let mut ch = self.channels - 1
  while ch >= 0 {
    for gr in 0..<self.granules_per_frame {
      let ix = self.l3_enc[ch][gr]
      // Precalculate the square, abs and maximum, for use later on
      let xr = self.mdct_freq[ch][gr]
      let xrsq = self.xrsq
      let xrabs = self.xrabs
      let mut xrmax = 0
      for i in 0..<mp3enc_granule_size {
        let v = xr[i]
        xrsq[i] = mp3enc_mulsr(v, v)
        let a = if v < 0 { -v } else { v }
        xrabs[i] = a
        if a > xrmax {
          xrmax = a
        }
      }
      self.xrmax = xrmax
      let gi = self.gr[gr][ch]
      // calc_xmin: shine's ratio/xmin are all zero, so nothing to do here
      if self.version == mp3enc_mpeg_i {
        self.calc_scfsi(ch, gr)
      }
      // calculation of number of available bits (per granule)
      let max_bits = self.max_reservoir_bits()
      // reset of iteration variables
      let scalefac = self.scalefac_l[gr][ch]
      for i in 0..<scalefac.length() {
        scalefac[i] = 0
      }
      gi.part2_3_length = 0
      gi.big_values = 0
      gi.count1 = 0
      gi.scalefac_compress = 0
      gi.table_select[0] = 0
      gi.table_select[1] = 0
      gi.table_select[2] = 0
      gi.region0_count = 0
      gi.region1_count = 0
      gi.part2_length = 0
      gi.preflag = 0
      gi.scalefac_scale = 0
      gi.count1table_select = 0
      // all spectral values zero?
      if self.xrmax != 0 {
        gi.part2_3_length = self.outer_loop(max_bits, ix, gr, ch)
      }
      self.resv_adjust(gi)
      gi.global_gain = gi.quantizer_step_size + 210
    }
    ch -= 1
  }
  self.resv_frame_end()
}
