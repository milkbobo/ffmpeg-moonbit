/// Frame pipeline of the fixed-point AC-3 encoder: MDCT application,
/// coupling strategy, rematrixing, exponent processing, bit allocation
/// search, mantissa quantization and frame packing. Mirrors
/// `ac3enc_template.c` + the encoding half of `ac3enc.c`.

///|
/// `apply_mdct`: window the input (with the previous frame's tail), run the
/// int32 MDCT per block, and remember the last 256 samples per channel. */
fn Ac3FixedEncoder::apply_mdct(
  self : Ac3FixedEncoder,
  samples : Array[FixedArray[Int32]],
) -> Unit {
  for ch = 0; ch < self.channels; ch = ch + 1 {
    let prev = self.planar_samples[ch]
    let cur = samples[self.channel_map[ch]]
    let win = self.window
    let ws = self.windowed_samples
    let mut in0 : FixedArray[Int32] = prev
    let mut in0_off = 0
    let mut off1 = 0
    for blk = 0; blk < self.num_blocks; blk = blk + 1 {
      // vector_fmul: ws[0..255] = in0[in0_off..] * window (round to 2^31)
      for i = 0; i < ac3e_block_size; i = i + 1 {
        let accu = in0[in0_off + i].to_int64() * win[i].to_int64()
        ws[i] = ((accu + 0x40000000) >> 31).to_int()
      }
      // vector_fmul_reverse: ws[256..511] = in1[off..] * window reversed
      for i = 0; i < ac3e_block_size; i = i + 1 {
        let accu = cur[off1 + i].to_int64() *
          win[ac3e_block_size - 1 - i].to_int64()
        ws[ac3e_block_size + i] = ((accu + 0x40000000) >> 31).to_int()
      }
      self.mdct.run(self.blocks[blk].mdct_coef[ch + 1], ws)
      // C: input_samples0 = input_samples1 (pre-increment), then += BLOCK_SIZE
      in0 = cur
      in0_off = off1
      off1 += ac3e_block_size
    }
    // Store the last 256 samples of the current frame for the next call.
    for i = 0; i < ac3e_block_size; i = i + 1 {
      prev[i] = cur[ac3e_frame_size - ac3e_block_size + i]
    }
  }
}

///|
/// `ff_ac3_compute_coupling_strategy`. */
fn Ac3FixedEncoder::compute_coupling_strategy(self : Ac3FixedEncoder) -> Unit {
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      block.channel_in_cpl[ch] = if self.cpl_on { 1 } else { 0 }
    }
  }
  let mut got_cpl_snr = false
  let mut num_cpl_blocks = 0
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    block.num_cpl_channels = 0
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      block.num_cpl_channels += block.channel_in_cpl[ch]
    }
    block.cpl_in_use = block.num_cpl_channels > 1
    if block.cpl_in_use {
      num_cpl_blocks += 1
    }
    if !block.cpl_in_use {
      block.num_cpl_channels = 0
      for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
        block.channel_in_cpl[ch] = 0
      }
    }
    block.new_cpl_strategy = blk == 0
    if blk != 0 {
      for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
        if block.channel_in_cpl[ch] != self.blocks[blk - 1].channel_in_cpl[ch] {
          block.new_cpl_strategy = true
          break
        }
      }
    }
    block.new_cpl_leak = if block.new_cpl_strategy { 1 } else { 0 }
    if blk == 0 || (block.cpl_in_use && !got_cpl_snr) {
      block.new_snr_offsets = true
      if block.cpl_in_use {
        got_cpl_snr = true
      }
    } else {
      block.new_snr_offsets = false
    }
  }
  if num_cpl_blocks == 0 {
    self.cpl_on = false
  }
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if block.channel_in_cpl[ch] != 0 {
        block.end_freq[ch] = self.start_freq[0]
      } else {
        block.end_freq[ch] = self.bandwidth_code * 3 + 73
      }
    }
  }
}

///|
/// `calc_cpl_coord` (fixed-point). */
fn ac3e_calc_cpl_coord(energy_ch : Int64, energy_cpl : Int64) -> Int32 {
  if energy_cpl <= 16777215L {
    1048576
  } else {
    let coord = energy_ch / (energy_cpl >> 24)
    let coord32_64 = if coord > 1073741824L { 1073741824L } else { coord }
    // ff_sqrt on uint32
    let coord32 = ac3e_isqrt(coord32_64.to_int()) << 9
    if coord32 > 16777215 {
      16777215
    } else {
      coord32
    }
  }
}

///|
/// `ff_sqrt` for uint32 (floor sqrt). */
fn ac3e_isqrt(v : Int32) -> Int32 {
  if v <= 1 {
    return if v < 0 { 0 } else { v }
  }
  // Newton iterations from an initial guess via leading zeros
  let mut g = 1 << ((ac3e_log2(v) + 1) / 2)
  let target = v
  // refine
  while true {
    let ng = (g + target / g) >> 1
    if ng >= g {
      break
    }
    g = ng
  }
  // ensure floor semantics
  while g * g > target {
    g -= 1
  }
  g
}

///|
/// `apply_channel_coupling` (fixed-point path: cpl_coords are already the
/// fixed coords). */
fn Ac3FixedEncoder::apply_channel_coupling(self : Ac3FixedEncoder) -> Unit {
  // energy[cpl_coords layout: (blk*7 + ch)*16 + bnd]
  for i = 0; i < self.energy.length(); i = i + 1 {
    self.energy[i] = 0L
    self.cpl_coords[i] = 0L
  }
  let cpl_start0 = self.start_freq[0] - 1
  let num_cpl_coefs = (self.num_cpl_subbands * 12 + 1 + 31) / 32 * 32
  let cap = if 256 < cpl_start0 + num_cpl_coefs {
    256
  } else {
    cpl_start0 + num_cpl_coefs
  }
  let cpl_start = cap - num_cpl_coefs
  // calculate coupling channel from fbw channels
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    if !block.cpl_in_use {
      continue
    }
    let cpl_coef = block.mdct_coef[0]
    for i = 0; i < num_cpl_coefs; i = i + 1 {
      cpl_coef[cpl_start + i] = 0
    }
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if block.channel_in_cpl[ch] == 0 {
        continue
      }
      let ch_coef = block.mdct_coef[ch]
      for i = 0; i < num_cpl_coefs; i = i + 1 {
        cpl_coef[cpl_start + i] = ac3e_clip_i32(
          cpl_coef[cpl_start + i].to_int64() + ch_coef[cpl_start + i].to_int64(),
        )
      }
    }
  }
  // calculate energy in each band
  let mut bnd = 0
  let mut i = self.start_freq[0]
  while i < self.cpl_end_freq {
    let band_size = self.cpl_band_sizes[bnd]
    for ch = 0; ch <= self.fbw_channels; ch = ch + 1 {
      for blk = 0; blk < self.num_blocks; blk = blk + 1 {
        let block = self.blocks[blk]
        if !block.cpl_in_use || (ch > 0 && block.channel_in_cpl[ch] == 0) {
          continue
        }
        for j = 0; j < band_size; j = j + 1 {
          let v = block.mdct_coef[ch][i + j].to_int64()
          let eidx = (blk * 7 + ch) * 16 + bnd
          self.energy[eidx] += v * v
        }
      }
    }
    i += band_size
    bnd += 1
  }
  // calculate coupling coordinates for all blocks
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    if !block.cpl_in_use {
      continue
    }
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if block.channel_in_cpl[ch] == 0 {
        continue
      }
      for b = 0; b < self.num_cpl_bands; b = b + 1 {
        let coord = ac3e_calc_cpl_coord(
          self.energy[(blk * 7 + ch) * 16 + b],
          self.energy[(blk * 7 + 0) * 16 + b],
        )
        self.cpl_coords[(blk * 7 + ch) * 16 + b] = coord.to_int64()
      }
    }
  }
  // determine which blocks send new coordinates
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    for ch = 0; ch < 7; ch = ch + 1 {
      block.new_cpl_coords[ch] = 0
    }
    if block.cpl_in_use {
      if blk == 0 || !self.blocks[blk - 1].cpl_in_use {
        for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
          block.new_cpl_coords[ch] = 1
        }
      } else {
        for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
          if block.channel_in_cpl[ch] == 0 {
            continue
          }
          if self.blocks[blk - 1].channel_in_cpl[ch] == 0 {
            block.new_cpl_coords[ch] = 1
          } else {
            let mut coord_diff : Int64 = 0L
            for b = 0; b < self.num_cpl_bands; b = b + 1 {
              let d = self.cpl_coords[((blk - 1) * 7 + ch) * 16 + b] -
                self.cpl_coords[(blk * 7 + ch) * 16 + b]
              coord_diff += if d < 0L { -d } else { d }
            }
            coord_diff = coord_diff / self.num_cpl_bands.to_int64()
            if coord_diff > 503317L {
              block.new_cpl_coords[ch] = 1
            }
          }
        }
      }
    }
  }
  // final coupling coordinates, accounting for reuse
  for b = 0; b < self.num_cpl_bands; b = b + 1 {
    let mut blk = 0
    while blk < self.num_blocks {
      let block = self.blocks[blk]
      if !block.cpl_in_use {
        blk += 1
        continue
      }
      let mut blk1 = blk + 1
      for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
        if block.channel_in_cpl[ch] == 0 {
          continue
        }
        let mut energy_cpl = self.energy[(blk * 7 + 0) * 16 + b]
        let mut energy_ch = self.energy[(blk * 7 + ch) * 16 + b]
        blk1 = blk + 1
        while blk1 < self.num_blocks &&
              self.blocks[blk1].new_cpl_coords[ch] == 0 {
          if self.blocks[blk1].cpl_in_use {
            energy_cpl += self.energy[(blk1 * 7 + 0) * 16 + b]
            energy_ch += self.energy[(blk1 * 7 + ch) * 16 + b]
          }
          blk1 += 1
        }
        let coord = ac3e_calc_cpl_coord(energy_ch, energy_cpl)
        self.cpl_coords[(blk * 7 + ch) * 16 + b] = coord.to_int64()
      }
      blk = blk1
    }
  }
  // exponents/mantissas for the coupling coordinates
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    if !block.cpl_in_use {
      continue
    }
    // extract_exponents over fbw_channels*16 coords
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      for b = 0; b < self.num_cpl_bands; b = b + 1 {
        let v = self.cpl_coords[(blk * 7 + ch) * 16 + b].to_int()
        let a = if v < 0 { -v } else { v }
        block.cpl_coord_exp[ch][b] = if a != 0 { 23 - ac3e_log2(a) } else { 24 }
      }
    }
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if block.new_cpl_coords[ch] == 0 {
        continue
      }
      let mut min_exp = block.cpl_coord_exp[ch][0]
      let mut max_exp = block.cpl_coord_exp[ch][0]
      for b = 1; b < self.num_cpl_bands; b = b + 1 {
        let e = block.cpl_coord_exp[ch][b]
        if e < min_exp {
          min_exp = e
        }
        if e > max_exp {
          max_exp = e
        }
      }
      let mut master_exp = (max_exp - 15 + 2) / 3
      if master_exp < 0 {
        master_exp = 0
      }
      while min_exp < master_exp * 3 {
        master_exp -= 1
      }
      for b = 0; b < self.num_cpl_bands; b = b + 1 {
        let mut e = block.cpl_coord_exp[ch][b] - master_exp * 3
        if e < 0 {
          e = 0
        }
        if e > 15 {
          e = 15
        }
        block.cpl_coord_exp[ch][b] = e
      }
      block.cpl_master_exp[ch] = master_exp
      for b = 0; b < self.num_cpl_bands; b = b + 1 {
        let cpl_exp = block.cpl_coord_exp[ch][b]
        let shift = 5 + cpl_exp + master_exp * 3
        let raw = (self.cpl_coords[(blk * 7 + ch) * 16 + b] << shift).to_int()
        let mut cpl_mant = if cpl_exp == 15 { raw >> 1 } else { raw - 16 }
        if cpl_mant < 0 {
          cpl_mant = 0
        }
        block.cpl_coord_mant[ch][b] = cpl_mant
      }
    }
  }
}

///|
/// Clip to the int32 coefficient range. */
fn ac3e_clip_i32(v : Int64) -> Int32 {
  if v < -16777215L {
    -16777215
  } else if v > 16777215L {
    16777215
  } else {
    v.to_int()
  }
}

///|
/// `compute_rematrixing_strategy`. */
fn Ac3FixedEncoder::compute_rematrixing_strategy(
  self : Ac3FixedEncoder,
) -> Unit {
  if self.channel_mode != ac3e_chmode_stereo {
    return
  }
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    block.new_rematrixing_strategy = blk == 0
    block.num_rematrixing_bands = 4
    if block.cpl_in_use {
      if self.start_freq[0] <= 61 {
        block.num_rematrixing_bands -= 1
      }
      if self.start_freq[0] == 37 {
        block.num_rematrixing_bands -= 1
      }
      if blk != 0 &&
        block.num_rematrixing_bands !=
        self.blocks[blk - 1].num_rematrixing_bands {
        block.new_rematrixing_strategy = true
      }
    }
    let nb_coefs = if block.end_freq[1] < block.end_freq[2] {
      block.end_freq[1]
    } else {
      block.end_freq[2]
    }
    if !self.rematrixing_enabled {
      continue
    }
    for bnd = 0; bnd < block.num_rematrixing_bands; bnd = bnd + 1 {
      let start = ac3_enc_rematrix_band_tab[bnd]
      let end = if nb_coefs < ac3_enc_rematrix_band_tab[bnd + 1] {
        nb_coefs
      } else {
        ac3_enc_rematrix_band_tab[bnd + 1]
      }
      let mut sum0 = 0L
      let mut sum1 = 0L
      let mut sum2 = 0L
      let mut sum3 = 0L
      for i = start; i < end; i = i + 1 {
        let lt = self.blocks[blk].mdct_coef[1][i].to_int64()
        let rt = self.blocks[blk].mdct_coef[2][i].to_int64()
        let md = lt + rt
        let sd = lt - rt
        sum0 += lt * lt
        sum1 += rt * rt
        sum2 += md * md
        sum3 += sd * sd
      }
      let min23 = if sum2 < sum3 { sum2 } else { sum3 }
      let min01 = if sum0 < sum1 { sum0 } else { sum1 }
      if min23 < min01 {
        block.rematrixing_flags[bnd] = 1
      } else {
        block.rematrixing_flags[bnd] = 0
      }
      if blk != 0 &&
        block.rematrixing_flags[bnd] !=
        self.blocks[blk - 1].rematrixing_flags[bnd] {
        block.new_rematrixing_strategy = true
      }
    }
  }
}

///|
/// `ac3_apply_rematrixing`. */
fn Ac3FixedEncoder::apply_rematrixing(self : Ac3FixedEncoder) -> Unit {
  if !self.rematrixing_enabled {
    return
  }
  let mut flags : FixedArray[Int32] = self.blocks[0].rematrixing_flags
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    if block.new_rematrixing_strategy {
      flags = block.rematrixing_flags
    }
    let nb_coefs = if block.end_freq[1] < block.end_freq[2] {
      block.end_freq[1]
    } else {
      block.end_freq[2]
    }
    for bnd = 0; bnd < block.num_rematrixing_bands; bnd = bnd + 1 {
      if flags[bnd] != 0 {
        let start = ac3_enc_rematrix_band_tab[bnd]
        let end = if nb_coefs < ac3_enc_rematrix_band_tab[bnd + 1] {
          nb_coefs
        } else {
          ac3_enc_rematrix_band_tab[bnd + 1]
        }
        for i = start; i < end; i = i + 1 {
          let lt = block.mdct_coef[1][i]
          let rt = block.mdct_coef[2][i]
          block.mdct_coef[1][i] = (lt + rt) >> 1
          block.mdct_coef[2][i] = (lt - rt) >> 1
        }
      }
    }
  }
}

///|
/// `extract_exponents` (over all blocks of the affected channels). */
fn Ac3FixedEncoder::extract_exponents(self : Ac3FixedEncoder) -> Unit {
  // C: int ch = !s->cpl_on — with coupling ON extraction starts at the CPL
  // slot (0) and covers channels 0..channels; without coupling it starts at
  // slot 1, skipping the empty CPL slot.
  let ch_start = if self.cpl_on { 0 } else { 1 }
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    for ch = ch_start; ch <= self.channels; ch = ch + 1 {
      let exp = block.exp[ch]
      let coef = block.mdct_coef[ch]
      for i = 0; i < ac3e_max_coefs; i = i + 1 {
        let v = coef[i]
        let a = if v < 0 { -v } else { v }
        exp[i] = if a != 0 { 23 - ac3e_log2(a) } else { 24 }
      }
    }
  }
}

///|
/// `compute_exp_strategy`. */
fn Ac3FixedEncoder::compute_exp_strategy(self : Ac3FixedEncoder) -> Unit {
  let ch_start = if self.cpl_on { 0 } else { 1 }
  for ch = ch_start; ch <= self.fbw_channels; ch = ch + 1 {
    self.exp_strategy[ch][0] = ac3e_exp_new
    for blk = 1; blk < self.num_blocks; blk = blk + 1 {
      if ch == 0 {
        if !self.blocks[blk - 1].cpl_in_use {
          self.exp_strategy[ch][blk] = ac3e_exp_new
          continue
        } else if !self.blocks[blk].cpl_in_use {
          self.exp_strategy[ch][blk] = ac3e_exp_reuse
          continue
        }
      } else if self.blocks[blk].channel_in_cpl[ch] !=
        self.blocks[blk - 1].channel_in_cpl[ch] {
        self.exp_strategy[ch][blk] = ac3e_exp_new
        continue
      }
      // SAD over 256 exponents vs the previous block
      let mut diff = 0
      let cur = self.blocks[blk].exp[ch]
      let pre = self.blocks[blk - 1].exp[ch]
      for i = 0; i < ac3e_max_coefs; i = i + 1 {
        let d = cur[i] - pre[i]
        diff += if d < 0 { -d } else { d }
      }
      self.exp_strategy[ch][blk] = ac3e_exp_reuse
      if ch == 0 {
        let span = self.blocks[blk].end_freq[ch] - self.start_freq[ch]
        if diff > ac3e_exp_diff_threshold * span / ac3e_max_coefs {
          self.exp_strategy[ch][blk] = ac3e_exp_new
        }
      } else if diff > ac3e_exp_diff_threshold {
        self.exp_strategy[ch][blk] = ac3e_exp_new
      }
    }
    let mut blk = 0
    while blk < self.num_blocks {
      let mut blk1 = blk + 1
      while blk1 < self.num_blocks &&
            self.exp_strategy[ch][blk1] == ac3e_exp_reuse {
        blk1 += 1
      }
      self.exp_strategy[ch][blk] = ac3e_exp_strategy_reuse_tab[self.num_blks_code *
        6 +
        blk1 -
        blk -
        1]
      blk = blk1
    }
  }
  if self.lfe_on {
    let ch = self.lfe_channel
    self.exp_strategy[ch][0] = ac3e_exp_d15
    for blk = 1; blk < self.num_blocks; blk = blk + 1 {
      self.exp_strategy[ch][blk] = ac3e_exp_reuse
    }
  }
}

///|
/// `encode_exponents_blk_ch`. */
fn ac3e_encode_exponents_blk_ch(
  exp : FixedArray[Int32],
  base : Int32,
  nb_exps : Int32,
  exp_strategy : Int32,
  cpl : Int32,
) -> Unit {
  let nb_groups = ac3e_group_count(cpl, exp_strategy, nb_exps) * 3
  let e = fn(i : Int32) -> Int32 { exp[base + i] }
  let set = fn(i : Int32, v : Int32) -> Unit { exp[base + i] = v }
  if exp_strategy == ac3e_exp_d25 {
    let mut k = 1 - cpl
    for i = 1; i <= nb_groups; i = i + 1 {
      let mut exp_min = e(k)
      if e(k + 1) < exp_min {
        exp_min = e(k + 1)
      }
      set(i - cpl, exp_min)
      k += 2
    }
  } else if exp_strategy == ac3e_exp_d45 {
    let mut k = 1 - cpl
    for i = 1; i <= nb_groups; i = i + 1 {
      let mut exp_min = e(k)
      if e(k + 1) < exp_min {
        exp_min = e(k + 1)
      }
      if e(k + 2) < exp_min {
        exp_min = e(k + 2)
      }
      if e(k + 3) < exp_min {
        exp_min = e(k + 3)
      }
      set(i - cpl, exp_min)
      k += 4
    }
  }
  // constraint for DC exponent
  if cpl == 0 && e(0) > 15 {
    set(0, 15)
  }
  // decrease deltas to within 2
  for i = 1; i <= nb_groups; i = i + 1 {
    let v = if e(i) < e(i - 1) + 2 { e(i) } else { e(i - 1) + 2 }
    set(i, v)
  }
  let mut i = nb_groups - 1
  while i >= 0 {
    let v = if e(i) < e(i + 1) + 2 { e(i) } else { e(i + 1) + 2 }
    set(i, v)
    i -= 1
  }
  if cpl != 0 {
    set(-1, e(0) & -2)
  }
  // expand back
  if exp_strategy == ac3e_exp_d25 {
    // C writes exp[k--] first (use then decrement): the final group writes
    // exp[nb_groups*2-2] and exp[nb_groups*2-1], never exp[-1].
    let mut k = nb_groups * 2 - cpl
    let mut i2 = nb_groups
    while i2 > 0 {
      let exp1 = e(i2 - cpl)
      set(k, exp1)
      set(k - 1, exp1)
      k -= 2
      i2 -= 1
    }
  } else if exp_strategy == ac3e_exp_d45 {
    // Same use-then-decrement as C: the last group writes exp[k-3..k] with
    // k = nb_groups*4 - cpl, never touching exp[-1].
    let mut k = nb_groups * 4 - cpl
    let mut i2 = nb_groups
    while i2 > 0 {
      let exp1 = e(i2 - cpl)
      set(k, exp1)
      set(k - 1, exp1)
      set(k - 2, exp1)
      set(k - 3, exp1)
      k -= 4
      i2 -= 1
    }
  }
}

///|
/// `encode_exponents`. */
fn Ac3FixedEncoder::encode_exponents(self : Ac3FixedEncoder) -> Unit {
  let ch_start = if self.cpl_on { 0 } else { 1 }
  for ch = ch_start; ch <= self.channels; ch = ch + 1 {
    let cpl = if ch == 0 { 1 } else { 0 }
    let mut blk = 0
    while blk < self.num_blocks {
      let block = self.blocks[blk]
      if cpl != 0 && !block.cpl_in_use {
        blk += 1
        continue
      }
      let nb_coefs = block.end_freq[ch] - self.start_freq[ch]
      let mut blk1 = blk + 1
      self.exp_ref_block[ch][blk] = blk
      while blk1 < self.num_blocks &&
            self.exp_strategy[ch][blk1] == ac3e_exp_reuse {
        self.exp_ref_block[ch][blk1] = blk
        blk1 += 1
      }
      let num_reuse_blocks = blk1 - blk - 1
      // ac3_exponent_min: take the min over the reuse blocks
      let base = self.start_freq[ch]
      for i = 0; i < ac3e_max_coefs; i = i + 1 {
        let mut v = self.blocks[blk].exp[ch][i]
        for b2 = 1; b2 <= num_reuse_blocks; b2 = b2 + 1 {
          let v2 = self.blocks[blk + b2].exp[ch][i]
          if v2 < v {
            v = v2
          }
        }
        self.blocks[blk].exp[ch][i] = v
      }
      if self.exp_strategy[ch][blk] != ac3e_exp_reuse {
        ac3e_encode_exponents_blk_ch(
          self.blocks[blk].exp[ch],
          base,
          nb_coefs,
          self.exp_strategy[ch][blk],
          cpl,
        )
      }
      blk = blk1
    }
  }
}

///|
/// `count_exponent_bits`. */
fn Ac3FixedEncoder::count_exponent_bits(self : Ac3FixedEncoder) -> Int32 {
  let mut bit_count = 0
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    let ch_start = if block.cpl_in_use { 0 } else { 1 }
    for ch = ch_start; ch <= self.channels; ch = ch + 1 {
      let exp_strategy = self.exp_strategy[ch][blk]
      if exp_strategy == ac3e_exp_reuse {
        continue
      }
      let cpl = if ch == 0 { 1 } else { 0 }
      let nb_coefs = block.end_freq[ch] - self.start_freq[ch]
      let nb_groups = ac3e_group_count(cpl, exp_strategy, nb_coefs)
      bit_count += 4 + nb_groups * 7
    }
  }
  bit_count
}

///|
/// `ac3_group_exponents`. */
fn Ac3FixedEncoder::group_exponents(self : Ac3FixedEncoder) -> Unit {
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    let ch_start = if block.cpl_in_use { 0 } else { 1 }
    for ch = ch_start; ch <= self.channels; ch = ch + 1 {
      let exp_strategy = self.exp_strategy[ch][blk]
      if exp_strategy == ac3e_exp_reuse {
        continue
      }
      let cpl = if ch == 0 { 1 } else { 0 }
      let group_size = exp_strategy +
        (if exp_strategy == ac3e_exp_d45 { 1 } else { 0 })
      let nb_groups = ac3e_group_count(
        cpl,
        exp_strategy,
        block.end_freq[ch] - self.start_freq[ch],
      )
      let p = self.start_freq[ch] - cpl
      let exp = block.exp[ch]
      let mut i1 = exp[p]
      block.grouped_exp[ch][0] = i1
      let mut idx = p + 1
      for gi = 1; gi <= nb_groups; gi = gi + 1 {
        let mut exp0 = i1
        i1 = exp[idx]
        idx += group_size
        let delta0 = i1 - exp0 + 2
        exp0 = i1
        i1 = exp[idx]
        idx += group_size
        let delta1 = i1 - exp0 + 2
        exp0 = i1
        i1 = exp[idx]
        idx += group_size
        let delta2 = i1 - exp0 + 2
        block.grouped_exp[ch][gi] = (delta0 * 5 + delta1) * 5 + delta2
      }
    }
  }
}

///|
/// DBA_NONE specialization of ff_ac3_bit_alloc_calc_mask with the
/// encoder's own parameters (exact translation of the C DBA_NONE path). */
fn ac3e_calc_mask(
  band_psd : FixedArray[Int32],
  start : Int32,
  end : Int32,
  fast_gain : Int32,
  is_lfe : Bool,
  slow_gain : Int32,
  fast_decay : Int32,
  slow_decay : Int32,
  db_per_bit : Int32,
  sr_shift : Int32,
  sr_code : Int32,
  cpl_fast_leak : Int32,
  cpl_slow_leak : Int32,
  mask : FixedArray[Int32],
) -> Unit {
  if end <= 0 {
    return
  }
  let excite = FixedArray::make(ac3_critical_bands, 0)
  let band_start = ac3_bin_to_band_tab[start]
  let band_end = ac3_bin_to_band_tab[end - 1] + 1
  let mut begin = 0
  let mut lowcomp = 0
  let mut fastleak = 0
  let mut slowleak = 0
  if band_start == 0 {
    lowcomp = ac3_calc_lowcomp1(0, band_psd[0], band_psd[1], 384)
    excite[0] = band_psd[0] - fast_gain - lowcomp
    lowcomp = ac3_calc_lowcomp1(lowcomp, band_psd[1], band_psd[2], 384)
    excite[1] = band_psd[1] - fast_gain - lowcomp
    begin = 7
    for band = 2; band < 7; band = band + 1 {
      if !(is_lfe && band == 6) {
        lowcomp = ac3_calc_lowcomp1(
          lowcomp,
          band_psd[band],
          band_psd[band + 1],
          384,
        )
      }
      fastleak = band_psd[band] - fast_gain
      slowleak = band_psd[band] - slow_gain
      excite[band] = fastleak - lowcomp
      if !(is_lfe && band == 6) {
        if band_psd[band] <= band_psd[band + 1] {
          begin = band + 1
          break
        }
      }
    }
    let end1 = if band_end < 22 { band_end } else { 22 }
    for band = begin; band < end1; band = band + 1 {
      if !(is_lfe && band == 6) {
        lowcomp = ac3_calc_lowcomp(
          lowcomp,
          band_psd[band],
          band_psd[band + 1],
          band,
        )
      }
      let fl = fastleak - fast_decay
      fastleak = if band_psd[band] - fast_gain > fl {
        band_psd[band] - fast_gain
      } else {
        fl
      }
      let sl = slowleak - slow_decay
      slowleak = if band_psd[band] - slow_gain > sl {
        band_psd[band] - slow_gain
      } else {
        sl
      }
      let e1 = fastleak - lowcomp
      excite[band] = if slowleak > e1 { slowleak } else { e1 }
    }
    begin = 22
  } else {
    // coupling channel
    begin = band_start
    fastleak = (cpl_fast_leak << 8) + 768
    slowleak = (cpl_slow_leak << 8) + 768
  }
  for band = begin; band < band_end; band = band + 1 {
    let fl = fastleak - fast_decay
    fastleak = if band_psd[band] - fast_gain > fl {
      band_psd[band] - fast_gain
    } else {
      fl
    }
    let sl = slowleak - slow_decay
    slowleak = if band_psd[band] - slow_gain > sl {
      band_psd[band] - slow_gain
    } else {
      sl
    }
    excite[band] = if fastleak > slowleak { fastleak } else { slowleak }
  }
  // compute masking curve
  for band = band_start; band < band_end; band = band + 1 {
    let tmp = db_per_bit - band_psd[band]
    if tmp > 0 {
      excite[band] += tmp >> 2
    }
    let h = ac3_hearing_threshold_tab[band >> sr_shift][sr_code]
    let e = excite[band]
    mask[band] = if h > e { h } else { e }
  }
}

///|
/// bit_alloc_masking. */
fn Ac3FixedEncoder::bit_alloc_masking(self : Ac3FixedEncoder) -> Unit {
  // C never assigns s->bit_alloc.sr_shift in the encoder, so it stays 0 and
  // the hearing-threshold lookup is tab[band >> 0][sr_code]. Do NOT port the
  // decoder's sr_shift convention here.
  let sr_shift = 0
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    let ch_start = if block.cpl_in_use { 0 } else { 1 }
    for ch = ch_start; ch <= self.channels; ch = ch + 1 {
      if self.exp_strategy[ch][blk] != ac3e_exp_reuse {
        ac3_bit_alloc_calc_psd(
          block.exp[ch],
          self.start_freq[ch],
          block.end_freq[ch],
          block.psd[ch],
          block.band_psd[ch],
        )
        ac3e_calc_mask(
          block.band_psd[ch],
          self.start_freq[ch],
          block.end_freq[ch],
          ac3_fast_gain_tab[self.fast_gain_code[ch]],
          ch == self.lfe_channel,
          self.ba_slow_gain,
          self.ba_fast_decay,
          self.ba_slow_decay,
          self.ba_db_per_bit,
          sr_shift,
          self.sr_code,
          0,
          0,
          block.mask[ch],
        )
      }
    }
  }
}

///|
/// count_frame_bits (AC-3 branch, dynamic part). */
fn Ac3FixedEncoder::count_frame_bits(self : Ac3FixedEncoder) -> Unit {
  let mut frame_bits = 0
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    if block.new_cpl_strategy {
      frame_bits += 1
      if block.cpl_in_use {
        frame_bits += self.fbw_channels
        if self.channel_mode == ac3e_chmode_stereo {
          frame_bits += 1
        }
        frame_bits += 4 + 4
        frame_bits += self.num_cpl_subbands - 1
      }
    }
    if block.cpl_in_use {
      for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
        if block.channel_in_cpl[ch] != 0 {
          frame_bits += 1
          if block.new_cpl_coords[ch] != 0 {
            frame_bits += 2
            frame_bits += 8 * self.num_cpl_bands
          }
        }
      }
    }
    if self.channel_mode == ac3e_chmode_stereo {
      frame_bits += 1
      if block.new_rematrixing_strategy {
        frame_bits += block.num_rematrixing_bands
      }
    }
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if self.exp_strategy[ch][blk] != ac3e_exp_reuse {
        if block.channel_in_cpl[ch] == 0 {
          frame_bits += 6
        }
        frame_bits += 2
      }
    }
    if block.cpl_in_use {
      frame_bits += 2
    }
    if block.new_snr_offsets {
      frame_bits += 6 +
        (self.channels + (if block.cpl_in_use { 1 } else { 0 })) * 7
    }
    if block.cpl_in_use {
      frame_bits += 1
      if block.new_cpl_leak != 0 {
        frame_bits += 3 + 3
      }
    }
  }
  self.frame_bits = self.frame_bits_fixed + frame_bits
}

///|
/// Bind each block to the BAP array of its exponent reference in this bank.
/// Blocks that reuse exponents then share the reference block's BAP array.
fn Ac3FixedEncoder::reset_block_bap(
  self : Ac3FixedEncoder,
  bank : Array[Array[FixedArray[Int32]]],
) -> Unit {
  for ch = 0; ch <= self.channels; ch = ch + 1 {
    for blk = 0; blk < self.num_blocks; blk = blk + 1 {
      self.ref_bap[ch][blk] = bank[ch][self.exp_ref_block[ch][blk]]
    }
  }
}

///|
/// count_mantissa_bits given the current bap arrays (group padding via the
/// preset counts 2/2/1 like the C mant_cnt init). */
fn Ac3FixedEncoder::count_mantissa_bits(self : Ac3FixedEncoder) -> Int32 {
  let bap_bits : FixedArray[Int32] = FixedArray::from_array([
    0, 0, 0, 3, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16,
  ])
  let mut bits = 0
  let max_end_freq = self.bandwidth_code * 3 + 73
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let mut c1 = 2
    let mut c2 = 2
    let mut c4 = 1
    let mut bits_blk = 0
    let ch_start = if self.cpl_enabled { 0 } else { 1 }
    for ch = ch_start; ch <= self.channels; ch = ch + 1 {
      if ch == 0 && !self.blocks[blk].cpl_in_use {
        continue
      }
      let ef = self.blocks[blk].end_freq[ch]
      let end = if max_end_freq < ef { max_end_freq } else { ef }
      let bap = self.ref_bap[ch][blk]
      for i = self.start_freq[ch]; i < end; i = i + 1 {
        let b = bap[i]
        if b == 1 {
          c1 += 1
        } else if b == 2 {
          c2 += 1
        } else if b == 4 {
          c4 += 1
        } else {
          bits_blk += bap_bits[b]
        }
      }
    }
    bits += bits_blk
    bits += c1 / 3 * 5
    bits += (c2 / 3 + (c4 >> 1)) * 7
  }
  bits
}

///|
/// The active bap bank (C `s->bap_buffer`; swapped with `bap1_buffer`
/// around successful search candidates so a failing probe never clobbers
/// the last-good allocation). */
fn Ac3FixedEncoder::bap_bank(
  self : Ac3FixedEncoder,
) -> Array[Array[FixedArray[Int32]]] {
  if self.bap_cur {
    self.bap_bank0
  } else {
    self.bap_bank1
  }
}

///|
/// bit_alloc with a given snr_offset: returns the mantissa bit count. */
fn Ac3FixedEncoder::bit_alloc(
  self : Ac3FixedEncoder,
  snr_offset_in : Int32,
) -> Int32 {
  let snr_offset = (snr_offset_in - 240) * 4
  self.reset_block_bap(self.bap_bank())
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    let ch_start = if block.cpl_in_use { 0 } else { 1 }
    for ch = ch_start; ch <= self.channels; ch = ch + 1 {
      if self.exp_strategy[ch][blk] != ac3e_exp_reuse {
        ac3_bit_alloc_calc_bap(
          block.mask[ch],
          block.psd[ch],
          self.start_freq[ch],
          block.end_freq[ch],
          snr_offset,
          self.ba_floor,
          self.ref_bap[ch][blk],
        )
      }
    }
  }
  self.count_mantissa_bits()
}

///|
/// cbr_bit_allocation search. */
fn Ac3FixedEncoder::cbr_bit_allocation(
  self : Ac3FixedEncoder,
) -> Result[Unit, String] {
  let bits_left = 8 * self.frame_size - (self.frame_bits + self.exponent_bits)
  if bits_left < 0 {
    return Err("ac3: bit allocation failed (increase bitrate)")
  }
  let mut snr_offset = self.coarse_snr_offset << 4
  if (snr_offset | self.fine_snr_offset[1]) == 1023 {
    if self.bit_alloc(1023) <= bits_left {
      return Ok(())
    }
  }
  while snr_offset >= 0 && self.bit_alloc(snr_offset) > bits_left {
    snr_offset -= 64
  }
  if snr_offset < 0 {
    return Err("ac3: bit allocation failed (increase bitrate)")
  }
  let mut snr_incr = 64
  // C: FFSWAP(bap_buffer, bap1_buffer) after the descent, after each
  // successful ascent candidate, and once more at the end — the active bank
  // therefore holds the bap of the LAST SUCCESSFUL snr, not the last probe
  // (a failing candidate still wrote its bap into the inactive bank).
  self.bap_cur = !self.bap_cur
  while snr_incr > 0 {
    while snr_offset + snr_incr <= 1023 &&
          self.bit_alloc(snr_offset + snr_incr) <= bits_left {
      snr_offset += snr_incr
      self.bap_cur = !self.bap_cur
    }
    snr_incr = snr_incr >> 2
  }
  self.bap_cur = !self.bap_cur
  self.reset_block_bap(self.bap_bank())
  self.coarse_snr_offset = snr_offset >> 4
  let ch_start = if self.cpl_on { 0 } else { 1 }
  for ch = ch_start; ch <= self.channels; ch = ch + 1 {
    self.fine_snr_offset[ch] = snr_offset & 0xF
  }
  Ok(())
}

///|
/// ac3_compute_bit_allocation. */
fn Ac3FixedEncoder::compute_bit_allocation(
  self : Ac3FixedEncoder,
) -> Result[Unit, String] {
  self.count_frame_bits()
  self.exponent_bits = self.count_exponent_bits()
  self.bit_alloc_masking()
  self.cbr_bit_allocation()
}
