///|
/// WMA v1/v2 block/frame/packet decoding, split out of `wma.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// exponent / LSP decoding
// ---------------------------------------------------------------------------

///|
/// `pow_m1_4`: x^-0.25 through the float exponent/mantissa tables.
fn WmaDecoder::pow_m1_4(self : WmaDecoder, x : Double) -> Double {
  let uf = Float::from_double(x)
  let uv = uf.reinterpret_as_uint()
  let e = (uv >> 23).reinterpret_as_int()
  let m = ((uv >> (23 - wma_lsp_pow_bits)) & ((1U << wma_lsp_pow_bits) - 1U)).reinterpret_as_int()
  let tv = ((uv << wma_lsp_pow_bits) & ((1U << 23) - 1U)) | (127U << 23)
  let tf = Float::reinterpret_from_uint(tv)
  let af = Float::from_double(self.lsp_pow_m_table1[m])
  let bf = Float::from_double(self.lsp_pow_m_table2[m])
  let ef = Float::from_double(self.lsp_pow_e_table[e])
  ef.to_double() * (af + bf * tf).to_double()
}

///|
/// `wma_lsp_to_curve`, writing `block_len` values and returning the maximum.
fn WmaDecoder::lsp_to_curve(
  self : WmaDecoder,
  ch : Int32,
  lsp : Array[Double],
) -> Double {
  let out = self.exponents[ch]
  let n = self.block_len
  let mut val_max = 0.0
  for i = 0; i < n; i = i + 1 {
    let mut p = 0.5
    let mut q = 0.5
    let w = self.lsp_cos_table[i]
    let mut j = 1
    while j < wma_nb_lsp_coefs {
      q = q * (w - lsp[j - 1])
      p = p * (w - lsp[j])
      j = j + 2
    }
    p = p * p * (2.0 - w)
    q = q * q * (2.0 + w)
    let v = self.pow_m1_4(p + q)
    if v > val_max {
      val_max = v
    }
    out[i] = v
  }
  val_max
}

///|
fn WmaDecoder::decode_exp_lsp(
  self : WmaDecoder,
  gb : BitReader,
  ch : Int32,
) -> Result[Unit, String] {
  let lsp : Array[Double] = Array::make(wma_nb_lsp_coefs, 0.0)
  for i = 0; i < wma_nb_lsp_coefs; i = i + 1 {
    let val = if i == 0 || i >= 8 {
      gb.read(3).reinterpret_as_int()
    } else {
      gb.read(4).reinterpret_as_int()
    }
    lsp[i] = wma_lsp_codebook[i][val]
  }
  self.max_exponent[ch] = self.lsp_to_curve(ch, lsp)
  Ok(())
}

///|
/// `pow(10, i / 16.0)` over the C exponent table range -60..95.
fn wma_pow10(i : Int32) -> Double {
  @math.pow(10.0, i.to_double() / 16.0)
}

///|
/// `ff_exp10(i * 0.05)`, used for total gain and high-band gains.
fn wma_exp10_20(i : Int32) -> Double {
  @math.pow(10.0, i.to_double() * 0.05)
}

///|
fn WmaDecoder::decode_exp_vlc(
  self : WmaDecoder,
  gb : BitReader,
  ch : Int32,
) -> Result[Unit, String] {
  let bands = self.exponent_bands[self.frame_len_bits - self.block_len_bits]
  let exponents = self.exponents[ch]
  let mut q = 0
  let mut max_scale = 0.0
  let mut last_exp = 36
  let mut band = 0
  if self.version == 1 {
    last_exp = gb.read(5).reinterpret_as_int() + 10
    let v = wma_pow10(last_exp)
    max_scale = v
    let n = bands[0]
    band = 1
    for i = 0; i < n; i = i + 1 {
      exponents[q] = v
      q = q + 1
    }
  }
  while q < self.block_len {
    let code = match wma_vlc_get(gb, self.exp_vlc) {
      Ok(c) => c
      Err(e) => return Err(e)
    }
    last_exp = last_exp + code - 60
    if last_exp < -60 || last_exp > 95 {
      return Err("wma: exponent out of range")
    }
    let v = wma_pow10(last_exp)
    if v > max_scale {
      max_scale = v
    }
    let n = bands[band]
    band = band + 1
    for i = 0; i < n; i = i + 1 {
      if q >= self.block_len {
        break
      }
      exponents[q] = v
      q = q + 1
    }
  }
  self.max_exponent[ch] = max_scale
  Ok(())
}

// ---------------------------------------------------------------------------
// run-level coefficients
// ---------------------------------------------------------------------------

///|
/// `ff_wma_run_level_decode` for WMA v1/v2 (`version = 0`).
fn wma_run_level_decode(
  gb : BitReader,
  table : WmaCoefVlc,
  ptr : Array[Double],
  num_coefs : Int32,
  block_len : Int32,
  frame_len_bits : Int32,
  coef_nb_bits : Int32,
) -> Result[Unit, String] {
  let mut offset = 0
  let mask = block_len - 1
  while offset < num_coefs {
    let code = match wma_vlc_get(gb, table.vlc) {
      Ok(c) => c
      Err(e) => return Err(e)
    }
    if code > 1 {
      offset = offset + table.run[code]
      let sign = gb.read1() != 0
      let level = table.level[code]
      ptr[offset & mask] = if sign { level } else { -level }
    } else if code == 1 {
      break
    } else {
      let level = gb.read(coef_nb_bits).reinterpret_as_int()
      offset = offset + gb.read(frame_len_bits).reinterpret_as_int()
      let sign = gb.read1() != 0
      ptr[offset & mask] = if sign {
        level.to_double()
      } else {
        -level.to_double()
      }
    }
    offset = offset + 1
  }
  if offset > num_coefs {
    return Err("wma: spectral RLE overflow")
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// windowing
// ---------------------------------------------------------------------------

///|
/// `wma_window`: apply the sine window and overlap-add into `frame_out`.
fn WmaDecoder::window(self : WmaDecoder, ch : Int32, out_off : Int32) -> Unit {
  let frame_out = self.frame_out[ch]
  let src = self.output
  let mut out = out_off
  let mut src_off = 0
  let blen = self.block_len
  if self.block_len_bits <= self.prev_block_len_bits {
    let bsize = self.frame_len_bits - self.block_len_bits
    let win = self.windows[bsize]
    for i = 0; i < blen; i = i + 1 {
      frame_out[out + i] = frame_out[out + i] + src[i] * win[i]
    }
  } else {
    let block_len = 1 << self.prev_block_len_bits
    let n = (blen - block_len) / 2
    let bsize = self.frame_len_bits - self.prev_block_len_bits
    let win = self.windows[bsize]
    for i = 0; i < block_len; i = i + 1 {
      frame_out[out + n + i] = frame_out[out + n + i] + src[n + i] * win[i]
    }
    for i = 0; i < n; i = i + 1 {
      frame_out[out + n + block_len + i] = src[n + block_len + i]
    }
  }
  out = out + blen
  src_off = src_off + blen
  if self.block_len_bits <= self.next_block_len_bits {
    let bsize = self.frame_len_bits - self.block_len_bits
    let win = self.windows[bsize]
    for i = 0; i < blen; i = i + 1 {
      frame_out[out + i] = src[src_off + i] * win[blen - 1 - i]
    }
  } else {
    let block_len = 1 << self.next_block_len_bits
    let n = (blen - block_len) / 2
    let bsize = self.frame_len_bits - self.next_block_len_bits
    let win = self.windows[bsize]
    for i = 0; i < n; i = i + 1 {
      frame_out[out + i] = src[src_off + i]
    }
    for i = 0; i < block_len; i = i + 1 {
      frame_out[out + n + i] = src[src_off + n + i] * win[block_len - 1 - i]
    }
    for i = 0; i < n; i = i + 1 {
      frame_out[out + n + block_len + i] = 0.0
    }
  }
}

// ---------------------------------------------------------------------------
// block / frame / packet decode
// ---------------------------------------------------------------------------

///|
/// `wma_decode_block`: returns 1 when the frame is complete.
fn WmaDecoder::decode_block(
  self : WmaDecoder,
  gb : BitReader,
) -> Result[Int32, String] {
  let channels = self.channels
  if self.use_variable_block_len {
    let n = wma_log2(self.nb_block_sizes - 1) + 1
    if self.reset_block_lengths {
      self.reset_block_lengths = false
      let v = gb.read(n).reinterpret_as_int()
      if v >= self.nb_block_sizes {
        return Err("wma: prev block length out of range")
      }
      self.prev_block_len_bits = self.frame_len_bits - v
      let v2 = gb.read(n).reinterpret_as_int()
      if v2 >= self.nb_block_sizes {
        return Err("wma: block length out of range")
      }
      self.block_len_bits = self.frame_len_bits - v2
    } else {
      self.prev_block_len_bits = self.block_len_bits
      self.block_len_bits = self.next_block_len_bits
    }
    let v = gb.read(n).reinterpret_as_int()
    if v >= self.nb_block_sizes {
      return Err("wma: next block length out of range")
    }
    self.next_block_len_bits = self.frame_len_bits - v
  } else {
    self.next_block_len_bits = self.frame_len_bits
    self.prev_block_len_bits = self.frame_len_bits
    self.block_len_bits = self.frame_len_bits
  }
  if self.frame_len_bits - self.block_len_bits >= self.nb_block_sizes {
    return Err("wma: block_len_bits not initialized")
  }
  self.block_len = 1 << self.block_len_bits
  if self.block_pos + self.block_len > self.frame_len {
    return Err("wma: frame_len overflow")
  }
  if channels == 2 {
    self.ms_stereo = gb.read1() != 0
  }
  let mut any_coded = false
  for ch = 0; ch < channels; ch = ch + 1 {
    let a = gb.read1() != 0
    self.channel_coded[ch] = a
    if a {
      any_coded = true
    }
  }
  let bsize = self.frame_len_bits - self.block_len_bits
  if any_coded {
    let mut total_gain = 1
    while true {
      if gb.bits_left() < 7 {
        return Err("wma: total_gain overread")
      }
      let a = gb.read(7).reinterpret_as_int()
      total_gain = total_gain + a
      if a != 127 {
        break
      }
    }
    let coef_nb_bits = wma_total_gain_to_bits(total_gain)
    let n = self.coefs_end[bsize] - self.coefs_start
    let nb_coefs = FixedArray::make(2, n)
    // Noise coding: high-band flags and the shared first gain code.
    if self.use_noise_coding {
      for ch = 0; ch < channels; ch = ch + 1 {
        if self.channel_coded[ch] {
          let count = self.exponent_high_sizes[bsize]
          for i = 0; i < count; i = i + 1 {
            let a = gb.read1().reinterpret_as_int()
            self.high_band_coded[ch][i] = a
            if a != 0 {
              nb_coefs[ch] = nb_coefs[ch] - self.exponent_high_bands[bsize][i]
            }
          }
        }
      }
      for ch = 0; ch < channels; ch = ch + 1 {
        if self.channel_coded[ch] {
          let count = self.exponent_high_sizes[bsize]
          let mut val = -2147483648
          for i = 0; i < count; i = i + 1 {
            if self.high_band_coded[ch][i] != 0 {
              if val == -2147483648 {
                val = gb.read(7).reinterpret_as_int() - 19
              } else {
                let code = match wma_vlc_get(gb, self.hgain_vlc) {
                  Ok(c) => c
                  Err(e) => return Err(e)
                }
                val = val + code - 18
              }
              self.high_band_values[ch][i] = val
            }
          }
        }
      }
    }
    // Exponents can be reused in short blocks.
    if self.block_len_bits == self.frame_len_bits || gb.read1() != 0 {
      for ch = 0; ch < channels; ch = ch + 1 {
        if self.channel_coded[ch] {
          let r = if self.use_exp_vlc {
            self.decode_exp_vlc(gb, ch)
          } else {
            self.decode_exp_lsp(gb, ch)
          }
          match r {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          self.exponents_bsize[ch] = bsize
          self.exponents_initialized[ch] = true
        }
      }
    }
    for ch = 0; ch < channels; ch = ch + 1 {
      if self.channel_coded[ch] && !self.exponents_initialized[ch] {
        return Err("wma: exponents not initialized")
      }
    }
    // Spectral coefficients (run-level).
    for ch = 0; ch < channels; ch = ch + 1 {
      if self.channel_coded[ch] {
        let tindex = if ch == 1 && self.ms_stereo { 1 } else { 0 }
        for i = 0; i < self.block_len; i = i + 1 {
          self.coefs1[ch][i] = 0.0
        }
        match
          wma_run_level_decode(
            gb,
            self.coef_vlc[tindex],
            self.coefs1[ch],
            nb_coefs[ch],
            self.block_len,
            self.frame_len_bits,
            coef_nb_bits,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      if self.version == 1 && channels >= 2 {
        gb.align()
      }
    }
    // Normalize.
    let n4 = self.block_len / 2
    let mut mdct_norm = 1.0 / n4.to_double()
    if self.version == 1 {
      mdct_norm = mdct_norm * n4.to_double().sqrt()
    }
    // Compute the MDCT coefficients for each coded channel.
    for ch = 0; ch < channels; ch = ch + 1 {
      if self.channel_coded[ch] {
        let coefs = self.coefs[ch]
        let coefs1 = self.coefs1[ch]
        let exponents = self.exponents[ch]
        let esize = self.exponents_bsize[ch]
        let mut mult = wma_exp10_20(total_gain) / self.max_exponent[ch]
        mult = mult * mdct_norm
        if self.use_noise_coding {
          let mut mult1 = mult
          let mut ci = 0
          for i = 0; i < self.coefs_start; i = i + 1 {
            coefs[ci] = self.noise_table[self.noise_index] *
              exponents[i << bsize >> esize] *
              mult1
            ci = ci + 1
            self.noise_index = (self.noise_index + 1) & (wma_noise_tab_size - 1)
          }
          let n1 = self.exponent_high_sizes[bsize]
          let exp_power : Array[Double] = Array::make(
            wma_high_band_max_size, 0.0,
          )
          let mut exp_off = self.high_band_start[bsize] << bsize >> esize
          let mut last_high_band = 0
          for j = 0; j < n1; j = j + 1 {
            let n = self.exponent_high_bands[self.frame_len_bits -
              self.block_len_bits][j]
            if self.high_band_coded[ch][j] != 0 {
              let mut e2 = 0.0
              for i = 0; i < n; i = i + 1 {
                let v = exponents[exp_off + (i << bsize >> esize)]
                e2 = e2 + v * v
              }
              exp_power[j] = e2 / n.to_double()
              last_high_band = j
            }
            exp_off = exp_off + (n << bsize >> esize)
          }
          let mut exp_off2 = self.coefs_start << bsize >> esize
          let mut c1 = 0
          for j = -1; j < n1; j = j + 1 {
            let n = if j < 0 {
              self.high_band_start[bsize] - self.coefs_start
            } else {
              self.exponent_high_bands[self.frame_len_bits - self.block_len_bits][j]
            }
            if j >= 0 && self.high_band_coded[ch][j] != 0 {
              mult1 = (exp_power[j] / exp_power[last_high_band]).sqrt()
              mult1 = mult1 * wma_exp10_20(self.high_band_values[ch][j])
              mult1 = mult1 / (self.max_exponent[ch] * self.noise_mult)
              mult1 = mult1 * mdct_norm
              for i = 0; i < n; i = i + 1 {
                let noise = self.noise_table[self.noise_index]
                self.noise_index = (self.noise_index + 1) &
                  (wma_noise_tab_size - 1)
                coefs[ci] = noise *
                  exponents[exp_off2 + (i << bsize >> esize)] *
                  mult1
                ci = ci + 1
              }
              exp_off2 = exp_off2 + (n << bsize >> esize)
            } else {
              for i = 0; i < n; i = i + 1 {
                let noise = self.noise_table[self.noise_index]
                self.noise_index = (self.noise_index + 1) &
                  (wma_noise_tab_size - 1)
                coefs[ci] = (coefs1[c1] + noise) *
                  exponents[exp_off2 + (i << bsize >> esize)] *
                  mult
                ci = ci + 1
                c1 = c1 + 1
              }
              exp_off2 = exp_off2 + (n << bsize >> esize)
            }
          }
          let n = self.block_len - self.coefs_end[bsize]
          let mult2 = mult * exponents[-(1 << bsize) >> esize]
          for _i = 0; _i < n; _i = _i + 1 {
            coefs[ci] = self.noise_table[self.noise_index] * mult2
            ci = ci + 1
            self.noise_index = (self.noise_index + 1) & (wma_noise_tab_size - 1)
          }
        } else {
          let mut ci = 0
          for i = 0; i < self.coefs_start; i = i + 1 {
            coefs[ci] = 0.0
            ci = ci + 1
          }
          let n = nb_coefs[ch]
          for i = 0; i < n; i = i + 1 {
            coefs[ci] = coefs1[i] * exponents[i << bsize >> esize] * mult
            ci = ci + 1
          }
          let n2 = self.block_len - self.coefs_end[bsize]
          for _i = 0; _i < n2; _i = _i + 1 {
            coefs[ci] = 0.0
            ci = ci + 1
          }
        }
      }
    }
    if self.ms_stereo && self.channel_coded[1] {
      if !self.channel_coded[0] {
        for i = 0; i < self.block_len; i = i + 1 {
          self.coefs[0][i] = 0.0
        }
        self.channel_coded[0] = true
      }
      for i = 0; i < self.block_len; i = i + 1 {
        let a = self.coefs[0][i]
        let b = self.coefs[1][i]
        self.coefs[0][i] = a + b
        self.coefs[1][i] = a - b
      }
    }
  }
  // MDCT and windowing.
  for ch = 0; ch < channels; ch = ch + 1 {
    let n4 = self.block_len / 2
    if self.channel_coded[ch] {
      let y = wma_imdct_full(self.coefs[ch], self.block_len, 1.0 / 32768.0)
      for i = 0; i < y.length(); i = i + 1 {
        self.output[i] = y[i]
      }
    } else if !(self.ms_stereo && ch == 1) {
      for i = 0; i < self.output.length(); i = i + 1 {
        self.output[i] = 0.0
      }
    }
    let index = self.frame_len / 2 + self.block_pos - n4
    self.window(ch, index)
  }
  self.block_num = self.block_num + 1
  self.block_pos = self.block_pos + self.block_len
  Ok(if self.block_pos >= self.frame_len { 1 } else { 0 })
}

///|
fn WmaDecoder::decode_frame(
  self : WmaDecoder,
  gb : BitReader,
  samples : Array[Array[Double]],
  samples_offset : Int32,
) -> Result[Unit, String] {
  self.block_num = 0
  self.block_pos = 0
  while true {
    let r = match self.decode_block(gb) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if r != 0 {
      break
    }
  }
  for ch = 0; ch < self.channels; ch = ch + 1 {
    for i = 0; i < self.frame_len; i = i + 1 {
      samples[ch][samples_offset + i] = self.frame_out[ch][i]
    }
    for i = 0; i < self.frame_len; i = i + 1 {
      self.frame_out[ch][i] = self.frame_out[ch][self.frame_len + i]
    }
  }
  Ok(())
}

///|
/// Decode one ASF/WMA packet (`block_align` bytes, one or more coded frames
/// depending on the bit-reservoir flag) into planar float samples.
pub fn WmaDecoder::decode_packet(
  self : WmaDecoder,
  packet : Bytes,
) -> Result[Array[Array[Double]], String] {
  if packet.length() < self.block_align {
    return Err("wma: input packet too small")
  }
  let gb = BitReader::new(packet[0:self.block_align].to_owned())
  let mut nb_frames = 1
  if self.use_bit_reservoir {
    gb.skip(4)
    nb_frames = gb.read(4).reinterpret_as_int() -
      (if self.last_superframe_len <= 0 { 1 } else { 0 })
    if nb_frames <= 0 {
      let is_error = nb_frames < 0 || gb.bits_left() <= 8
      if is_error {
        self.last_superframe_len = 0
        return Err("wma: bad superframe header")
      }
      if self.last_superframe_len + self.block_align - 1 > wma_max_superframe {
        self.last_superframe_len = 0
        return Err("wma: superframe too large")
      }
      let mut q = self.last_superframe_len
      let mut len = self.block_align - 1
      while len > 0 {
        self.last_superframe[q] = gb.read(8).reinterpret_as_int().to_byte()
        q = q + 1
        len = len - 1
      }
      self.last_superframe_len = self.last_superframe_len +
        8 * self.block_align -
        8
      let empty : Array[Array[Double]] = []
      for _ch = 0; _ch < self.channels; _ch = _ch + 1 {
        empty.push([])
      }
      return Ok(empty)
    }
  }
  let total = nb_frames * self.frame_len
  let samples : Array[Array[Double]] = []
  for _ch = 0; _ch < self.channels; _ch = _ch + 1 {
    samples.push(Array::make(total, 0.0))
  }
  let mut samples_offset = 0
  if self.use_bit_reservoir {
    let bit_offset = gb.read(self.byte_offset_bits + 3).reinterpret_as_int()
    if bit_offset > gb.bits_left() {
      self.last_superframe_len = 0
      return Err("wma: invalid last frame bit offset")
    }
    if self.last_superframe_len > 0 {
      if self.last_superframe_len + ((bit_offset + 7) >> 3) > wma_max_superframe {
        self.last_superframe_len = 0
        return Err("wma: superframe too large")
      }
      let mut q = self.last_superframe_len
      let mut len = bit_offset
      while len > 7 {
        self.last_superframe[q] = gb.read(8).reinterpret_as_int().to_byte()
        q = q + 1
        len = len - 8
      }
      if len > 0 {
        let v = gb.read(len).reinterpret_as_int() << (8 - len)
        self.last_superframe[q] = v.to_byte()
        q = q + 1
      }
      let prev : Array[Byte] = []
      for i = 0; i < q; i = i + 1 {
        prev.push(self.last_superframe[i])
      }
      let lgb = BitReader::with_size(
        Bytes::from_array(prev),
        q * 8 + bit_offset,
      )
      if self.last_bitoffset > 0 {
        lgb.skip(self.last_bitoffset)
      }
      match self.decode_frame(lgb, samples, samples_offset) {
        Ok(_) => ()
        Err(e) => {
          self.last_superframe_len = 0
          return Err(e)
        }
      }
      samples_offset = samples_offset + self.frame_len
      nb_frames = nb_frames - 1
    }
    let pos0 = bit_offset + 4 + 4 + self.byte_offset_bits + 3
    if pos0 >= wma_max_superframe * 8 || pos0 > self.block_align * 8 {
      self.last_superframe_len = 0
      return Err("wma: invalid superframe bit position")
    }
    let fgb = BitReader::new(packet[pos0 >> 3:self.block_align].to_owned())
    let rem = pos0 & 7
    if rem > 0 {
      fgb.skip(rem)
    }
    self.reset_block_lengths = true
    for _i = 0; _i < nb_frames; _i = _i + 1 {
      match self.decode_frame(fgb, samples, samples_offset) {
        Ok(_) => ()
        Err(e) => {
          self.last_superframe_len = 0
          return Err(e)
        }
      }
      samples_offset = samples_offset + self.frame_len
    }
    let mut pos = fgb.count() +
      ((bit_offset + 4 + 4 + self.byte_offset_bits + 3) >> 3 << 3)
    self.last_bitoffset = pos & 7
    pos = pos >> 3
    let len = self.block_align - pos
    if len > wma_max_superframe || len < 0 {
      self.last_superframe_len = 0
      return Err("wma: invalid superframe length")
    }
    self.last_superframe_len = len
    for i = 0; i < len; i = i + 1 {
      self.last_superframe[i] = packet[pos + i]
    }
  } else {
    match self.decode_frame(gb, samples, samples_offset) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(samples)
}

///|
/// Flush the overlap tail after the last packet (the C's EOF frame).
pub fn WmaDecoder::decode_flush(
  self : WmaDecoder,
) -> Result[Array[Array[Double]], String] {
  if self.eof_done {
    return Err("wma: flush after EOF")
  }
  let samples : Array[Array[Double]] = []
  for ch = 0; ch < self.channels; ch = ch + 1 {
    let out : Array[Double] = Array::make(self.frame_len, 0.0)
    for i = 0; i < self.frame_len; i = i + 1 {
      out[i] = self.frame_out[ch][i]
    }
    samples.push(out)
  }
  self.last_superframe_len = 0
  self.eof_done = true
  Ok(samples)
}
