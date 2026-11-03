/// MoonBit port of shine 3.1.1 `bitstream.c` and `l3bitstream.c`: the 32-bit
/// cached MSB-first bit writer and the frame formatter (side info, main
/// data, Huffman coding). The cache persists across frames — only
/// `bs_position` rewinds — which is what keeps the per-frame outputs
/// byte-continuous like the C encoder.

///|
/// `shine_putbits`: write `n` bits of `val` (MSB-first) into the stream.
/// `n == 0` is a no-op (the C code would shift by 32; its only zero-width
/// caller writes value 0, so this is behaviour-preserving).
fn Mp3Encoder::putbits(self : Mp3Encoder, val : Int32, n : Int32) -> Unit {
  if n == 0 {
    return
  }
  let v = val.reinterpret_as_uint()
  if self.bs_cache_bits > n {
    self.bs_cache_bits -= n
    self.bs_cache = self.bs_cache | (v << self.bs_cache_bits)
  } else {
    let n2 = n - self.bs_cache_bits
    self.bs_cache = self.bs_cache | (v >> n2)
    // the C code stores SWAB32(cache) on little-endian hosts, i.e. the word
    // goes out big-endian
    let c = self.bs_cache
    let pos = self.bs_position
    self.bs_data[pos] = (c >> 24).to_byte()
    self.bs_data[pos + 1] = (c >> 16).to_byte()
    self.bs_data[pos + 2] = (c >> 8).to_byte()
    self.bs_data[pos + 3] = c.to_byte()
    self.bs_position = pos + 4
    self.bs_cache_bits = 32 - n2
    self.bs_cache = if n2 != 0 { v << self.bs_cache_bits } else { 0U }
  }
}

///|
/// `shine_get_bits_count`.
fn Mp3Encoder::bits_count(self : Mp3Encoder) -> Int32 {
  self.bs_position * 8 + 32 - self.bs_cache_bits
}

///|
/// `shine_format_bitstream`: apply the sign bits to the quantised values and
/// write side information plus main data.
fn Mp3Encoder::format_bitstream(self : Mp3Encoder) -> Unit {
  for ch in 0..<self.channels {
    for gr in 0..<self.granules_per_frame {
      let pi = self.l3_enc[ch][gr]
      let pr = self.mdct_freq[ch][gr]
      for i in 0..<mp3enc_granule_size {
        if pr[i] < 0 && pi[i] > 0 {
          pi[i] = -pi[i]
        }
      }
    }
  }
  self.encode_side_info()
  self.encode_main_data()
}

///|
/// `encodeMainData`: scalefactors (always zero in shine) plus the Huffman
/// coded granules.
fn Mp3Encoder::encode_main_data(self : Mp3Encoder) -> Unit {
  for gr in 0..<self.granules_per_frame {
    for ch in 0..<self.channels {
      let gi = self.gr[gr][ch]
      let slen1 = mp3enc_slen1_tab[gi.scalefac_compress]
      let slen2 = mp3enc_slen2_tab[gi.scalefac_compress]
      let ix = self.l3_enc[ch][gr]
      let scalefac = self.scalefac_l[gr][ch]
      if gr == 0 || self.scfsi[ch][0] == 0 {
        for sfb in 0..<6 {
          self.putbits(scalefac[sfb], slen1)
        }
      }
      if gr == 0 || self.scfsi[ch][1] == 0 {
        for sfb in 6..<11 {
          self.putbits(scalefac[sfb], slen1)
        }
      }
      if gr == 0 || self.scfsi[ch][2] == 0 {
        for sfb in 11..<16 {
          self.putbits(scalefac[sfb], slen2)
        }
      }
      if gr == 0 || self.scfsi[ch][3] == 0 {
        for sfb in 16..<21 {
          self.putbits(scalefac[sfb], slen2)
        }
      }
      self.huffmancodebits(ix, gi)
    }
  }
}

///|
/// `encodeSideInfo`.
fn Mp3Encoder::encode_side_info(self : Mp3Encoder) -> Unit {
  self.putbits(0x7ff, 11)
  self.putbits(self.version, 2)
  self.putbits(1, 2) // layer = LAYER_III
  self.putbits(1, 1) // !crc (crc is always 0)
  self.putbits(self.bitrate_index, 4)
  self.putbits(self.samplerate_index % 3, 2)
  self.putbits(self.padding, 1)
  self.putbits(0, 1) // ext
  self.putbits(self.mode, 2)
  self.putbits(0, 2) // mode_ext
  self.putbits(self.copyright, 1)
  self.putbits(self.original, 1)
  self.putbits(self.emph, 2)
  if self.version == mp3enc_mpeg_i {
    self.putbits(0, 9) // main_data_begin: the reservoir is always empty
    if self.channels == 2 {
      self.putbits(0, 3) // private_bits
    } else {
      self.putbits(0, 5)
    }
  } else {
    self.putbits(0, 8)
    if self.channels == 2 {
      self.putbits(0, 2)
    } else {
      self.putbits(0, 1)
    }
  }
  if self.version == mp3enc_mpeg_i {
    for ch in 0..<self.channels {
      for band in 0..<4 {
        self.putbits(self.scfsi[ch][band], 1)
      }
    }
  }
  for gr in 0..<self.granules_per_frame {
    for ch in 0..<self.channels {
      let gi = self.gr[gr][ch]
      self.putbits(gi.part2_3_length, 12)
      self.putbits(gi.big_values, 9)
      self.putbits(gi.global_gain, 8)
      if self.version == mp3enc_mpeg_i {
        self.putbits(gi.scalefac_compress, 4)
      } else {
        self.putbits(gi.scalefac_compress, 9)
      }
      self.putbits(0, 1) // blocksplit_flag: shine never splits blocks
      for region in 0..<3 {
        self.putbits(gi.table_select[region], 5)
      }
      self.putbits(gi.region0_count, 4)
      self.putbits(gi.region1_count, 3)
      if self.version == mp3enc_mpeg_i {
        self.putbits(gi.preflag, 1)
      }
      self.putbits(gi.scalefac_scale, 1)
      self.putbits(gi.count1table_select, 1)
    }
  }
}

///|
/// `Huffmancodebits`: write the big values region and the count1 region, pad
/// to `part2_3_length` with one-bits.
fn Mp3Encoder::huffmancodebits(
  self : Mp3Encoder,
  ix : Array[Int32],
  gi : Mp3EncGranule,
) -> Unit {
  let start_bits = self.bits_count()
  // 1: Write the bigvalues
  let bigvalues = gi.big_values << 1
  let sfb_base = self.samplerate_index * 23
  let region1_start = mp3enc_scale_fact_band_index[sfb_base +
    gi.region0_count +
    1]
  let region2_start = mp3enc_scale_fact_band_index[sfb_base +
    gi.region0_count +
    gi.region1_count +
    2]
  let mut i = 0
  while i < bigvalues {
    // get table pointer
    let idx = (if i >= region1_start { 1 } else { 0 }) +
      (if i >= region2_start { 1 } else { 0 })
    let tableindex = gi.table_select[idx]
    // get huffman code
    if tableindex != 0 {
      self.huffman_code(tableindex, ix[i], ix[i + 1])
    }
    i += 2
  }
  // 2: Write count1 area
  let count1_table = gi.count1table_select + 32
  let count1_end = bigvalues + (gi.count1 << 2)
  let mut i = bigvalues
  while i < count1_end {
    let v = ix[i]
    let w = ix[i + 1]
    let x = ix[i + 2]
    let y = ix[i + 3]
    self.huffman_coder_count1(count1_table, v, w, x, y)
    i += 4
  }
  let bits = self.bits_count() - start_bits
  let stuffing = gi.part2_3_length - gi.part2_length - bits
  if stuffing != 0 {
    // Due to the nature of the Huffman code tables, we pad with ones
    let stuffing_words = stuffing / 32
    let remaining_bits = stuffing % 32
    for _w in 0..<stuffing_words {
      self.putbits(-1, 32)
    }
    if remaining_bits != 0 {
      self.putbits((1 << remaining_bits) - 1, remaining_bits)
    }
  }
}

///|
/// `shine_abs_and_sign`: map `x` to its absolute value and return the sign
/// bit (1 for x <= 0, like the C code).
fn mp3enc_abs_and_sign(x : Int32) -> (Int32, Int32) {
  if x > 0 {
    (x, 0)
  } else {
    (-x, 1)
  }
}

///|
/// `shine_huffman_coder_count1`: one count1 quadruple (values 0/1) plus its
/// sign bits.
fn Mp3Encoder::huffman_coder_count1(
  self : Mp3Encoder,
  h : Int32,
  v0 : Int32,
  w0 : Int32,
  x0 : Int32,
  y0 : Int32,
) -> Unit {
  let (v, signv) = mp3enc_abs_and_sign(v0)
  let (w, signw) = mp3enc_abs_and_sign(w0)
  let (x, signx) = mp3enc_abs_and_sign(x0)
  let (y, signy) = mp3enc_abs_and_sign(y0)
  let p = v + (w << 1) + (x << 2) + (y << 3)
  self.putbits(mp3enc_huff_code(h, p), mp3enc_huff_len(h, p))
  let mut code : UInt32 = 0U
  let mut cbits = 0
  if v != 0 {
    code = signv.reinterpret_as_uint()
    cbits = 1
  }
  if w != 0 {
    code = (code << 1) | signw.reinterpret_as_uint()
    cbits += 1
  }
  if x != 0 {
    code = (code << 1) | signx.reinterpret_as_uint()
    cbits += 1
  }
  if y != 0 {
    code = (code << 1) | signy.reinterpret_as_uint()
    cbits += 1
  }
  self.putbits(code.reinterpret_as_int(), cbits)
}

///|
/// `shine_HuffmanCode`: one big-values pair, following the pseudocode of
/// page 98 of the IS.
fn Mp3Encoder::huffman_code(
  self : Mp3Encoder,
  table_select : Int32,
  x0 : Int32,
  y0 : Int32,
) -> Unit {
  let (x1, signx) = mp3enc_abs_and_sign(x0)
  let (y1, signy) = mp3enc_abs_and_sign(y0)
  let mut x = x1
  let mut y = y1
  let h = table_select
  let ylen = mp3enc_huff_ylen(h)
  if table_select > 15 {
    // ESC-table is used
    let linbits = mp3enc_huff_linbits(h)
    let mut linbitsx = 0
    let mut linbitsy = 0
    if x > 14 {
      linbitsx = x - 15
      x = 15
    }
    if y > 14 {
      linbitsy = y - 15
      y = 15
    }
    let idx = x * ylen + y
    let code = mp3enc_huff_code(h, idx)
    let cbits = mp3enc_huff_len(h, idx)
    let mut ext : UInt32 = 0U
    let mut xbits = 0
    if x > 14 {
      ext = ext | linbitsx.reinterpret_as_uint()
      xbits += linbits
    }
    if x != 0 {
      ext = ext << 1
      ext = ext | signx.reinterpret_as_uint()
      xbits += 1
    }
    if y > 14 {
      ext = ext << linbits
      ext = ext | linbitsy.reinterpret_as_uint()
      xbits += linbits
    }
    if y != 0 {
      ext = ext << 1
      ext = ext | signy.reinterpret_as_uint()
      xbits += 1
    }
    self.putbits(code, cbits)
    self.putbits(ext.reinterpret_as_int(), xbits)
  } else {
    // No ESC-words
    let idx = x * ylen + y
    let mut code = mp3enc_huff_code(h, idx).reinterpret_as_uint()
    let mut cbits = mp3enc_huff_len(h, idx)
    if x != 0 {
      code = code << 1
      code = code | signx.reinterpret_as_uint()
      cbits += 1
    }
    if y != 0 {
      code = code << 1
      code = code | signy.reinterpret_as_uint()
      cbits += 1
    }
    self.putbits(code.reinterpret_as_int(), cbits)
  }
}
