///|
/// sym_quant: symmetric quantization on 'levels' levels. */
fn ac3e_sym_quant(c : Int32, e : Int32, levels : Int32) -> Int32 {
  let v = (((levels * c) >> (24 - e)) + levels) >> 1
  v
}

///|
/// asym_quant: asymmetric quantization on 2^qbits levels. */
fn ac3e_asym_quant(c : Int32, e : Int32, qbits : Int32) -> Int32 {
  let c2 = (((c * (1 << e)) >> (24 - qbits)) + 1) >> 1
  let m = 1 << (qbits - 1)
  if c2 >= m {
    m - 1
  } else {
    c2
  }
}

///|
/// quantize_mantissas_blk_ch. The bap=1/2/4 grouping writes into the qmant
/// array at running positions, mirroring the C pointer trick. */
fn Ac3FixedEncoder::quantize_mantissas_blk_ch(
  self : Ac3FixedEncoder,
  m : Ac3EncMant,
  blk : Int32,
  ch : Int32,
  exp_ref : FixedArray[Int32],
) -> Unit {
  let block = self.blocks[blk]
  let fixed_coef = block.mdct_coef[ch]
  let exp = exp_ref
  let bap = self.ref_bap[ch][blk]
  let qmant = block.qmant[ch]
  let start_freq = self.start_freq[ch]
  let end_freq = block.end_freq[ch]
  for i = start_freq; i < end_freq; i = i + 1 {
    let c = fixed_coef[i]
    let e = exp[i]
    let mut v = bap[i]
    if v == 0 {
      qmant[i] = 0
      continue
    } else if v == 1 {
      v = ac3e_sym_quant(c, e, 3)
      match m.mant1_cnt {
        0 => {
          m.qmant1_arr = qmant
          m.qmant1_idx = i
          v = 9 * v
          m.mant1_cnt = 1
        }
        1 => {
          let old = m.qmant1_arr[m.qmant1_idx]
          m.qmant1_arr[m.qmant1_idx] = old + 3 * v
          m.mant1_cnt = 2
          v = 128
        }
        _ => {
          let old = m.qmant1_arr[m.qmant1_idx]
          m.qmant1_arr[m.qmant1_idx] = old + v
          m.mant1_cnt = 0
          v = 128
        }
      }
    } else if v == 2 {
      v = ac3e_sym_quant(c, e, 5)
      match m.mant2_cnt {
        0 => {
          m.qmant2_arr = qmant
          m.qmant2_idx = i
          v = 25 * v
          m.mant2_cnt = 1
        }
        1 => {
          let old = m.qmant2_arr[m.qmant2_idx]
          m.qmant2_arr[m.qmant2_idx] = old + 5 * v
          m.mant2_cnt = 2
          v = 128
        }
        _ => {
          let old = m.qmant2_arr[m.qmant2_idx]
          m.qmant2_arr[m.qmant2_idx] = old + v
          m.mant2_cnt = 0
          v = 128
        }
      }
    } else if v == 3 {
      v = ac3e_sym_quant(c, e, 7)
    } else if v == 4 {
      v = ac3e_sym_quant(c, e, 11)
      match m.mant4_cnt {
        0 => {
          m.qmant4_arr = qmant
          m.qmant4_idx = i
          v = 11 * v
          m.mant4_cnt = 1
        }
        _ => {
          let old = m.qmant4_arr[m.qmant4_idx]
          m.qmant4_arr[m.qmant4_idx] = old + v
          m.mant4_cnt = 0
          v = 128
        }
      }
    } else if v == 5 {
      v = ac3e_sym_quant(c, e, 15)
    } else if v == 14 {
      v = ac3e_asym_quant(c, e, 14)
    } else if v == 15 {
      v = ac3e_asym_quant(c, e, 16)
    } else {
      v = ac3e_asym_quant(c, e, v - 1)
    }
    qmant[i] = v
  }
}

///|
/// ac3_quantize_mantissas. */
fn Ac3FixedEncoder::quantize_mantissas(self : Ac3FixedEncoder) -> Unit {
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    let block = self.blocks[blk]
    let m : Ac3EncMant = {
      mant1_cnt: 0,
      mant2_cnt: 0,
      mant4_cnt: 0,
      qmant1_arr: block.qmant[1],
      qmant1_idx: 0,
      qmant2_arr: block.qmant[1],
      qmant2_idx: 0,
      qmant4_arr: block.qmant[1],
      qmant4_idx: 0,
    }
    let mut got_cpl = !block.cpl_in_use
    let mut ch = 1
    let mut ch0 = 0
    while ch <= self.channels {
      if !got_cpl && ch > 1 && block.channel_in_cpl[ch - 1] != 0 {
        ch0 = ch - 1
        ch = 0
        got_cpl = true
      }
      let exp_ref = self.blocks[self.exp_ref_block[ch][blk]].exp[ch]
      self.quantize_mantissas_blk_ch(m, blk, ch, exp_ref)
      if ch == 0 {
        ch = ch0
      }
      ch += 1
    }
  }
}

///|
/// Minimal bit writer (put_bits). */
priv struct Ac3Pb {
  buf : FixedArray[Byte]
  mut bit_pos : Int32
}

///|
fn Ac3Pb::new(size : Int32) -> Ac3Pb {
  { buf: FixedArray::make(size, b'\x00'), bit_pos: 0, }
}

///|
fn Ac3Pb::put(self : Ac3Pb, n : Int32, v : Int32) -> Unit {
  if self.bit_pos + n > self.buf.length() * 8 {
    abort("overflow")
  }
  let mut sh = n - 1
  while sh >= 0 {
    let bit = (v >> sh) & 1
    let p = self.bit_pos
    if bit != 0 {
      let byte = self.buf[p >> 3]
      self.buf[p >> 3] = (byte.to_int() | (1 << (7 - p % 8))).to_byte()
    }
    self.bit_pos += 1
    sh -= 1
  }
}

///|
/// put_sbits: signed value written in n bits (two's complement). */
fn Ac3Pb::put_s(self : Ac3Pb, n : Int32, v : Int32) -> Unit {
  self.put(n, v & ((1 << n) - 1))
}

///|
/// ac3_output_frame_header. */
fn Ac3FixedEncoder::output_frame_header(
  self : Ac3FixedEncoder,
  pb : Ac3Pb,
) -> Unit {
  pb.put(16, 0x0b77)
  pb.put(16, 0) // crc1 placeholder
  pb.put(2, self.sr_code)
  pb.put(6, self.frame_size_code + (self.frame_size - self.frame_size_min) / 2)
  pb.put(5, self.bitstream_id)
  pb.put(3, self.bitstream_mode)
  pb.put(3, self.channel_mode)
  if (self.channel_mode & 0x01) != 0 && self.channel_mode != ac3e_chmode_mono {
    pb.put(2, self.center_mix_level)
  }
  if (self.channel_mode & 0x04) != 0 {
    pb.put(2, self.surround_mix_level)
  }
  if self.channel_mode == ac3e_chmode_stereo {
    pb.put(2, 0) // dolby_surround_mode: not indicated (reference value)
  }
  pb.put(1, if self.lfe_on { 1 } else { 0 })
  pb.put(5, 31) // -dialnorm (-(-31))
  pb.put(1, 0) // no compression control word
  pb.put(1, 0) // no lang code
  pb.put(1, 0) // audio_production_info
  pb.put(1, 0) // copyright (reference value)
  pb.put(1, 1) // original default NONE(-1) -> bit 1
  pb.put(1, 0) // no time code 1
  pb.put(1, 0) // no time code 2
  pb.put(1, 0) // no additional bit stream info
}

///|
/// output_audio_block. */
fn Ac3FixedEncoder::output_audio_block(
  self : Ac3FixedEncoder,
  pb : Ac3Pb,
  blk : Int32,
) -> Unit {
  let block = self.blocks[blk]
  // block switching flags
  for _ch = 0; _ch < self.fbw_channels; _ch = _ch + 1 {
    pb.put(1, 0)
  }
  // dither flags
  for _ch = 0; _ch < self.fbw_channels; _ch = _ch + 1 {
    pb.put(1, 1)
  }
  pb.put(1, 0) // dynamic range codes
  pb.put(1, if block.new_cpl_strategy { 1 } else { 0 })
  if block.new_cpl_strategy {
    pb.put(1, if block.cpl_in_use { 1 } else { 0 })
    if block.cpl_in_use {
      for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
        pb.put(1, block.channel_in_cpl[ch])
      }
      if self.channel_mode == ac3e_chmode_stereo {
        pb.put(1, 0)
      }
      let start_sub = (self.start_freq[0] - 37) / 12
      let end_sub = (self.cpl_end_freq - 37) / 12
      pb.put(4, start_sub)
      pb.put(4, end_sub - 3)
      for bnd = start_sub + 1; bnd < end_sub; bnd = bnd + 1 {
        pb.put(1, ac3_enc_cpl_band_struct[bnd])
      }
    }
  }
  if block.cpl_in_use {
    for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
      if block.channel_in_cpl[ch] != 0 {
        pb.put(1, block.new_cpl_coords[ch])
        if block.new_cpl_coords[ch] != 0 {
          pb.put(2, block.cpl_master_exp[ch])
          for bnd = 0; bnd < self.num_cpl_bands; bnd = bnd + 1 {
            pb.put(4, block.cpl_coord_exp[ch][bnd])
            pb.put(4, block.cpl_coord_mant[ch][bnd])
          }
        }
      }
    }
  }
  if self.channel_mode == ac3e_chmode_stereo {
    pb.put(1, if block.new_rematrixing_strategy { 1 } else { 0 })
    if block.new_rematrixing_strategy {
      for bnd = 0; bnd < block.num_rematrixing_bands; bnd = bnd + 1 {
        pb.put(1, block.rematrixing_flags[bnd])
      }
    }
  }
  // exponent strategy
  let ch_start_exp = if block.cpl_in_use { 0 } else { 1 }
  for ch = ch_start_exp; ch <= self.fbw_channels; ch = ch + 1 {
    pb.put(2, self.exp_strategy[ch][blk])
  }
  if self.lfe_on {
    pb.put(1, self.exp_strategy[self.lfe_channel][blk])
  }
  // bandwidth
  for ch = 1; ch <= self.fbw_channels; ch = ch + 1 {
    if self.exp_strategy[ch][blk] != ac3e_exp_reuse &&
      block.channel_in_cpl[ch] == 0 {
      pb.put(6, self.bandwidth_code)
    }
  }
  // exponents
  let ch_start2 = if block.cpl_in_use { 0 } else { 1 }
  for ch = ch_start2; ch <= self.channels; ch = ch + 1 {
    let cpl = if ch == 0 { 1 } else { 0 }
    if self.exp_strategy[ch][blk] == ac3e_exp_reuse {
      continue
    }
    pb.put(4, block.grouped_exp[ch][0] >> cpl)
    let nb_groups = ac3e_group_count(
      cpl,
      self.exp_strategy[ch][blk],
      block.end_freq[ch] - self.start_freq[ch],
    )
    for i = 1; i <= nb_groups; i = i + 1 {
      pb.put(7, block.grouped_exp[ch][i])
    }
    if ch != self.lfe_channel && cpl == 0 {
      pb.put(2, 0)
    }
  }
  // bit allocation info
  let baie = if blk == 0 { 1 } else { 0 }
  pb.put(1, baie)
  if baie != 0 {
    pb.put(2, self.slow_decay_code)
    pb.put(2, self.fast_decay_code)
    pb.put(2, self.slow_gain_code)
    pb.put(2, self.db_per_bit_code)
    pb.put(3, self.floor_code)
  }
  // snr offsets
  pb.put(1, if block.new_snr_offsets { 1 } else { 0 })
  if block.new_snr_offsets {
    pb.put(6, self.coarse_snr_offset)
    let ch_start3 = if block.cpl_in_use { 0 } else { 1 }
    for ch = ch_start3; ch <= self.channels; ch = ch + 1 {
      pb.put(4, self.fine_snr_offset[ch])
      pb.put(3, self.fast_gain_code[ch])
    }
  }
  // coupling leak
  if block.cpl_in_use {
    pb.put(1, block.new_cpl_leak)
    if block.new_cpl_leak != 0 {
      pb.put(3, 0)
      pb.put(3, 0)
    }
  }
  pb.put(1, 0) // no delta bit allocation
  pb.put(1, 0) // no data to skip
  // mantissas
  let mut got_cpl = !block.cpl_in_use
  let mut ch = 1
  let mut ch0 = 0
  while ch <= self.channels {
    if !got_cpl && ch > 1 && block.channel_in_cpl[ch - 1] != 0 {
      ch0 = ch - 1
      ch = 0
      got_cpl = true
    }
    let qmant = block.qmant[ch]
    let bap = self.ref_bap[ch][blk]
    for i = self.start_freq[ch]; i < block.end_freq[ch]; i = i + 1 {
      let q = qmant[i]
      let b = bap[i]
      if b == 0 {
        continue
      } else if b == 1 {
        if q != 128 {
          pb.put(5, q)
        }
      } else if b == 2 {
        if q != 128 {
          pb.put(7, q)
        }
      } else if b == 3 {
        pb.put_s(3, q)
      } else if b == 4 {
        if q != 128 {
          pb.put(7, q)
        }
      } else if b == 14 {
        pb.put_s(14, q)
      } else if b == 15 {
        pb.put_s(16, q)
      } else {
        pb.put_s(b - 1, q)
      }
    }
    if ch == 0 {
      ch = ch0
    }
    ch += 1
  }
}

///|
/// output_frame_end: pad and compute CRC-1 / CRC-2. */
fn Ac3FixedEncoder::output_frame_end(
  self : Ac3FixedEncoder,
  pb : Ac3Pb,
) -> Unit {
  let frame_size_58 = ((self.frame_size >> 2) + (self.frame_size >> 4)) << 1
  // zero pad
  let end_byte = (pb.bit_pos + 7) / 8
  for i = end_byte; i < self.frame_size; i = i + 1 {
    pb.buf[i] = b'\x00'
  }
  // crc1 over bytes 4..frame_size_58. C's av_crc(AV_CRC_16_ANSI) register
  // matches the plain msb-first poly-0x8005 value, and the bswap16 in the C
  // source cancels against its table layout: the net result is the raw
  // register multiplied by crc_inv, stored big-endian with no swapping.
  let crc1_raw = ac3_av_crc16_ansi(pb.buf, 4, frame_size_58 - 4)
  let crc_inv = self.crc_inv[if self.frame_size > self.frame_size_min {
      1
    } else {
      0
    }]
  let crc1m = ac3e_mul_poly(crc_inv, crc1_raw, ac3e_crc16_poly)
  pb.buf[2] = ((crc1m >> 8) & 0xFF).to_byte()
  pb.buf[3] = (crc1m & 0xFF).to_byte()
  // crc2 over frame_size_58..frame_size-2 (raw register, big-endian)
  let mut crc2 = ac3_av_crc16_ansi(
    pb.buf,
    frame_size_58,
    self.frame_size - frame_size_58 - 2,
  )
  if crc2 == 0x0b77 {
    let last = self.frame_size - 3
    pb.buf[last] = (pb.buf[last].to_int() ^ 1).to_byte()
    crc2 = crc2 ^ 0x8005
  }
  pb.buf[self.frame_size - 2] = ((crc2 >> 8) & 0xFF).to_byte()
  pb.buf[self.frame_size - 1] = (crc2 & 0xFF).to_byte()
}

///|
/// CRC-16 ANSI over buf[off..off+len) (big-endian bit order, poly 0x8005
/// reflected form used by av_crc AV_CRC_16_ANSI). */
fn ac3_av_crc16_ansi(buf : FixedArray[Byte], off : Int32, len : Int32) -> Int32 {
  // av_crc with AV_CRC_16_ANSI: poly 0x8005 (msb-first table).
  // Implement directly: process bits MSB-first per byte, poly 0x8005.
  let mut crc : Int32 = 0
  for i = off; i < off + len; i = i + 1 {
    let b = buf[i].to_int() & 0xFF
    crc = crc ^ (b << 8)
    for _j = 0; _j < 8; _j = _j + 1 {
      if (crc & 0x8000) != 0 {
        crc = (crc << 1) ^ 0x8005
      } else {
        crc = crc << 1
      }
      crc = crc & 0xFFFF
    }
  }
  crc
}

///|
/// ac3_output_frame. */
fn Ac3FixedEncoder::output_frame(self : Ac3FixedEncoder) -> Bytes {
  let pb = Ac3Pb::new(self.frame_size)
  self.output_frame_header(pb)
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    self.output_audio_block(pb, blk)
  }
  self.output_frame_end(pb)
  let out : Array[Byte] = []
  for i = 0; i < self.frame_size; i = i + 1 {
    out.push(pb.buf[i])
  }
  Bytes::from_array(out)
}

///|
/// ff_ac3_encode_frame for one frame (1536 samples per channel, planar,
/// input order = SMPTE/WAV order). */
fn Ac3FixedEncoder::encode_frame(
  self : Ac3FixedEncoder,
  samples : Array[FixedArray[Int32]],
) -> Result[Bytes, String] {
  if self.sr_code == 1 {
    self.adjust_frame_size()
  }
  self.apply_mdct(samples)
  self.cpl_on = self.cpl_enabled
  self.compute_coupling_strategy()
  if self.cpl_on {
    self.apply_channel_coupling()
  }
  self.compute_rematrixing_strategy()
  self.apply_rematrixing()
  self.extract_exponents()
  self.compute_exp_strategy()
  self.encode_exponents()
  match self.compute_bit_allocation() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.group_exponents()
  self.quantize_mantissas()
  Ok(self.output_frame())
}

///|
/// Encode planar signed 32-bit PCM in SMPTE/WAV channel order.
/// Provide one plane per channel in the layout, all with the same number
/// of samples. Pad each plane to a multiple of 1536 samples before calling.
/// A bit rate of zero selects the default for the channel count.
pub fn ff_ac3_fixed_encode_stream(
  samples : Array[FixedArray[Int32]],
  sample_rate : Int32,
  bit_rate : Int32,
  layout_mask : Int32,
) -> Result[Bytes, String] {
  match Ac3FixedEncoder::new(sample_rate, layout_mask, bit_rate) {
    Err(e) => Err(e)
    Ok(enc) => {
      if samples.length() != enc.channels {
        return Err("ac3: input channel count does not match layout")
      }
      let total = samples[0].length()
      if samples.any(fn(plane) { plane.length() != total }) {
        return Err("ac3: input planes must have equal lengths")
      }
      let frame_len = ac3e_frame_size
      if total % frame_len != 0 {
        return Err("ac3: input length must be a multiple of 1536 samples")
      }
      let out : Array[Byte] = []
      let frame_ch = Array::makei(enc.channels, _ => {
        FixedArray::make(frame_len, 0)
      })
      for off = 0; off < total; off = off + frame_len {
        for ch = 0; ch < samples.length(); ch = ch + 1 {
          let part = frame_ch[ch]
          for i = 0; i < frame_len; i = i + 1 {
            part[i] = samples[ch][off + i]
          }
        }
        match enc.encode_frame(frame_ch) {
          Ok(bytes) =>
            for b in bytes {
              out.push(b)
            }
          Err(e) => return Err(e)
        }
      }
      Ok(Bytes::from_array(out))
    }
  }
}
