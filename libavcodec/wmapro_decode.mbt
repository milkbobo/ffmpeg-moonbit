///|
/// WMA Pro frame and subframe decoding (`decode_tilehdr` .. `decode_frame`),
/// split out of `wmapro.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// errors
// ---------------------------------------------------------------------------

///|
/// How the C treats a failure inside a frame.
priv enum WmaproErr {
  /// A bitstream error: the C sets `packet_loss` and drops the frame.
  Broken(String)
  /// A feature the C refuses with `AVERROR_PATCHWELCOME`.
  Unsupported(String)
}

///|
let wmapro_huff_vec1_size : Int32 = 101

///|
/// `ff_wma_get_large_val`: 8 bits, lengthened by a unary prefix to at most
/// 31 bits.
fn WmaproBits::read_large_val(self : WmaproBits) -> Int32 {
  let mut n_bits = 8
  if self.read1() != 0U {
    n_bits += 8
    if self.read1() != 0U {
      n_bits += 8
      if self.read1() != 0U {
        n_bits += 7
      }
    }
  }
  self.read_long(n_bits).reinterpret_as_int()
}

// ---------------------------------------------------------------------------
// frame layout
// ---------------------------------------------------------------------------

///|
/// `decode_subframe_length`.
fn WmaProDecoder::decode_subframe_length(
  self : WmaProDecoder,
  offset : Int32,
) -> Result[Int32, WmaproErr] {
  let mut frame_len_shift = 0

  // no need to read from the bitstream when only one length is possible
  if offset == self.samples_per_frame - self.min_samples_per_subframe {
    return Ok(self.min_samples_per_subframe)
  }
  if self.gb.size_bits - self.gb.count() < 1 {
    return Err(Broken("wmapro: broken frame: subframe length missing"))
  }

  // 1 bit indicates if the subframe is of maximum length
  if self.max_subframe_len_bit {
    if self.gb.read1() != 0U {
      frame_len_shift = 1 +
        self.gb.read(self.subframe_len_bits - 1).reinterpret_as_int()
    }
  } else {
    frame_len_shift = self.gb.read(self.subframe_len_bits).reinterpret_as_int()
  }
  let subframe_len = self.samples_per_frame >> frame_len_shift

  // sanity check the length
  if subframe_len < self.min_samples_per_subframe ||
    subframe_len > self.samples_per_frame {
    return Err(Broken("wmapro: broken frame: subframe_len \{subframe_len}"))
  }
  Ok(subframe_len)
}

///|
/// `decode_tilehdr`: how the frame is split into subframes, per channel.
fn WmaProDecoder::decode_tilehdr(
  self : WmaProDecoder,
) -> Result[Unit, WmaproErr] {
  let num_samples = FixedArray::makei(wmapro_max_channels, _ => 0)
  let contains_subframe = FixedArray::makei(wmapro_max_channels, _ => 0)
  let mut channels_for_cur_subframe = self.nb_channels
  let mut fixed_channel_layout = false
  let mut min_channel_len = 0

  // reset tiling information
  for c in 0..<self.nb_channels {
    self.channel[c].num_subframes = 0
  }
  if self.max_num_subframes == 1 || self.gb.read1() != 0U {
    fixed_channel_layout = true
  }

  // loop until the frame data is split between the subframes
  while true {
    let bits_before = self.gb.count()

    // check which channels contain the subframe
    for c in 0..<self.nb_channels {
      if num_samples[c] == min_channel_len {
        if fixed_channel_layout ||
          channels_for_cur_subframe == 1 ||
          min_channel_len ==
          self.samples_per_frame - self.min_samples_per_subframe {
          contains_subframe[c] = 1
        } else {
          contains_subframe[c] = self.gb.read1().reinterpret_as_int()
        }
      } else {
        contains_subframe[c] = 0
      }
    }

    // get subframe length, subframe_len == 0 is not allowed
    let subframe_len = match self.decode_subframe_length(min_channel_len) {
      Ok(len) =>
        if len <= 0 {
          return Err(Broken("wmapro: broken frame: subframe_len \{len}"))
        } else {
          len
        }
      Err(e) => return Err(e)
    }

    // add subframes to the individual channels and find new
    // min_channel_len
    min_channel_len += subframe_len
    for c in 0..<self.nb_channels {
      if contains_subframe[c] != 0 {
        let n = self.channel[c].num_subframes
        if n >= wmapro_max_subframes {
          return Err(Broken("wmapro: broken frame: num subframes > 31"))
        }
        self.channel[c].subframe_len[n] = subframe_len
        num_samples[c] += subframe_len
        self.channel[c].num_subframes = n + 1
        if num_samples[c] > self.samples_per_frame {
          return Err(
            Broken("wmapro: broken frame: channel len > samples_per_frame"),
          )
        }
      } else if num_samples[c] <= min_channel_len {
        if num_samples[c] < min_channel_len {
          channels_for_cur_subframe = 0
          min_channel_len = num_samples[c]
        }
        channels_for_cur_subframe += 1
      }
    }
    if min_channel_len >= self.samples_per_frame {
      break
    }
    // The C loops until the frame is split. On garbage every channel can
    // decline the subframe while the reader, clamped at the frame's end,
    // stops advancing; that would never end.
    if self.gb.count() == bits_before {
      return Err(Broken("wmapro: broken frame: tile header makes no progress"))
    }
  }
  for c in 0..<self.nb_channels {
    let mut offset = 0
    for i in 0..<self.channel[c].num_subframes {
      self.channel[c].subframe_offset[i] = offset
      offset += self.channel[c].subframe_len[i]
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// channel transforms
// ---------------------------------------------------------------------------

///|
/// `decode_decorrelation_matrix` for group `g`.
fn WmaProDecoder::decode_decorrelation_matrix(
  self : WmaProDecoder,
  g : Int32,
) -> Unit {
  let n = self.chgroup[g].num_channels
  let mat = self.chgroup[g].decorrelation_matrix
  for i in 0..<(self.nb_channels * self.nb_channels) {
    mat[i] = 0.0
  }
  let rotation_offset = FixedArray::makei(
    wmapro_max_channels * wmapro_max_channels,
    _ => 0,
  )
  let mut offset = 0
  for i in 0..<((n * (n - 1)) >> 1) {
    rotation_offset[i] = self.gb.read(6).reinterpret_as_int()
  }
  for i in 0..<n {
    mat[n * i + i] = if self.gb.read1() != 0U { 1.0 } else { -1.0 }
  }
  for i in 1..<n {
    for x in 0..<i {
      for y in 0..<(i + 1) {
        let v1 = mat[x * n + y]
        let v2 = mat[i * n + y]
        let rot = rotation_offset[offset + x]
        let sinv = if rot < 32 { self.sin64[rot] } else { self.sin64[64 - rot] }
        let cosv = if rot < 32 {
          self.sin64[32 - rot]
        } else {
          -self.sin64[rot - 32]
        }
        mat[y + x * n] = v1 * sinv - v2 * cosv
        mat[y + i * n] = v1 * cosv + v2 * sinv
      }
    }
    offset += i
  }
}

///|
/// `decode_channel_transform`.
fn WmaProDecoder::decode_channel_transform(
  self : WmaProDecoder,
) -> Result[Unit, WmaproErr] {
  // in the one channel case channel transforms are pointless
  self.num_chgroups = 0
  if self.nb_channels > 1 {
    let mut remaining_channels = self.channels_for_cur_subframe
    if self.gb.read1() != 0U {
      return Err(Unsupported("wmapro: channel transform bit is not supported"))
    }
    while remaining_channels > 0 &&
          self.num_chgroups < self.channels_for_cur_subframe {
      let g = self.num_chgroups
      self.chgroup[g].num_channels = 0
      self.chgroup[g].transform = false

      // decode channel mask
      if remaining_channels > 2 {
        for i in 0..<self.channels_for_cur_subframe {
          let channel_idx = self.channel_indexes_for_cur_subframe[i]
          if !self.channel[channel_idx].grouped && self.gb.read1() != 0U {
            self.chgroup[g].channel_data[self.chgroup[g].num_channels] = channel_idx
            self.chgroup[g].num_channels += 1
            self.channel[channel_idx].grouped = true
          }
        }
      } else {
        self.chgroup[g].num_channels = remaining_channels
        let mut k = 0
        for i in 0..<self.channels_for_cur_subframe {
          let channel_idx = self.channel_indexes_for_cur_subframe[i]
          if !self.channel[channel_idx].grouped {
            self.chgroup[g].channel_data[k] = channel_idx
            k += 1
          }
          self.channel[channel_idx].grouped = true
        }
      }

      // decode transform type
      let nc = self.chgroup[g].num_channels
      let mat = self.chgroup[g].decorrelation_matrix
      if nc == 2 {
        if self.gb.read1() != 0U {
          if self.gb.read1() != 0U {
            return Err(Unsupported("wmapro: unknown channel transform type"))
          }
        } else {
          self.chgroup[g].transform = true
          if self.nb_channels == 2 {
            mat[0] = 1.0
            mat[1] = -1.0
            mat[2] = 1.0
            mat[3] = 1.0
          } else {
            // cos(pi/4)
            mat[0] = 0.70703125
            mat[1] = -0.70703125
            mat[2] = 0.70703125
            mat[3] = 0.70703125
          }
        }
      } else if nc > 2 {
        if self.gb.read1() != 0U {
          self.chgroup[g].transform = true
          if self.gb.read1() != 0U {
            self.decode_decorrelation_matrix(g)
          } else if nc > 6 {
            return Err(
              Unsupported("wmapro: coupled channels > 6 are not supported"),
            )
          } else {
            let base = wmapro_default_decorrelation_offset(nc)
            for k in 0..<(nc * nc) {
              mat[k] = wmapro_default_decorrelation_matrices[base + k]
            }
          }
        }
      }

      // decode transform on / off
      if self.chgroup[g].transform {
        if self.gb.read1() == 0U {
          // transform can be enabled for individual bands
          for i in 0..<self.num_bands {
            self.chgroup[g].transform_band[i] = self.gb
              .read1()
              .reinterpret_as_int()
          }
        } else {
          for i in 0..<self.num_bands {
            self.chgroup[g].transform_band[i] = 1
          }
        }
      }
      remaining_channels -= self.chgroup[g].num_channels
      self.num_chgroups += 1
    }
  }
  Ok(())
}

///|
/// `default_decorrelation[n]`: the offset of the n x n default matrix.
fn wmapro_default_decorrelation_offset(n : Int32) -> Int32 {
  match n {
    1 => 0
    2 => 1
    3 => 5
    4 => 14
    5 => 30
    _ => 55
  }
}

// ---------------------------------------------------------------------------
// coefficients and scale factors
// ---------------------------------------------------------------------------

///|
/// `decode_coeffs`: the coefficients of channel `c` (`0 ..< subframe_len`).
/// The C ignores this function's result; a reported failure only lands in
/// `last_error`.
fn WmaProDecoder::decode_coeffs(self : WmaProDecoder, c : Int32) -> Unit {
  let vlctable = self.gb.read1() != 0U
  let vlc = self.coef_vlc[if vlctable { 1 } else { 0 }]
  let run = if vlctable { wmapro_coef1_run } else { wmapro_coef0_run }
  let level = if vlctable { wmapro_coef1_level } else { wmapro_coef0_level }
  let mut rl_mode = false
  let mut cur_coeff = 0
  let mut num_zeros = 0
  let base = self.channel[c].coeffs
  let out = self.channel[c].out
  let vals = FixedArray::makei(4, _ => 0)

  // decode vector coefficients (consumes up to 167 bits per iteration for
  // 4 vector coded large values)
  while (self.transmit_num_vec_coeffs || !rl_mode) &&
        cur_coeff + 3 < self.channel[c].num_vec_coeffs {
    let idx = self.gb.read_vlc(self.vec4_vlc)
    if idx < 0 {
      for i in 0..<2 {
        let idx2 = self.gb.read_vlc(self.vec2_vlc)
        if idx2 < 0 {
          let mut v0 = self.gb.read_vlc(self.vec1_vlc)
          if v0 == wmapro_huff_vec1_size - 1 {
            v0 += self.gb.read_large_val()
          }
          let mut v1 = self.gb.read_vlc(self.vec1_vlc)
          if v1 == wmapro_huff_vec1_size - 1 {
            v1 += self.gb.read_large_val()
          }
          vals[2 * i] = v0
          vals[2 * i + 1] = v1
        } else {
          vals[2 * i] = idx2 >> 4
          vals[2 * i + 1] = idx2 & 0xF
        }
      }
    } else {
      vals[0] = idx >> 12
      vals[1] = (idx >> 8) & 0xF
      vals[2] = (idx >> 4) & 0xF
      vals[3] = idx & 0xF
    }

    // decode sign
    for i in 0..<4 {
      let v = vals[i]
      if v != 0 {
        let negative = self.gb.read1() == 0U
        out[base + cur_coeff] = if negative {
          -v.reinterpret_as_uint().to_double()
        } else {
          v.reinterpret_as_uint().to_double()
        }
        num_zeros = 0
      } else {
        out[base + cur_coeff] = 0.0

        // switch to run level mode when subframe_len / 128 zeros were
        // found in a row
        num_zeros += 1
        if num_zeros > self.subframe_len >> 8 {
          rl_mode = true
        }
      }
      cur_coeff += 1
    }
  }

  // decode run level coded coefficients
  if cur_coeff < self.subframe_len {
    for i in cur_coeff..<self.subframe_len {
      out[base + i] = 0.0
    }
    self.decode_run_level(c, vlc, run, level, cur_coeff)
  }
}

///|
/// `ff_wma_run_level_decode` with `version = 1` (WMA Pro): the rest of
/// channel `c` from coefficient `offset0`. The C returns an error on a
/// broken escape or an overflow; its caller ignores it, so the reason only
/// lands in `last_error`.
fn WmaProDecoder::decode_run_level(
  self : WmaProDecoder,
  c : Int32,
  vlc : WmaproVlc,
  run : FixedArray[Int32],
  level : FixedArray[Int32],
  offset0 : Int32,
) -> Unit {
  let base = self.channel[c].coeffs
  let out = self.channel[c].out
  let coef_mask = self.subframe_len - 1
  let mut offset = offset0
  while offset < self.subframe_len {
    let code = self.gb.read_vlc(vlc)
    if code > 1 {
      // normal code
      offset += run[code]
      let negative = self.gb.read1() == 0U
      let v = level[code].to_double()
      out[base + (offset & coef_mask)] = if negative { -v } else { v }
    } else if code == 1 {
      // EOB
      break
    } else {
      // escape decode
      let lvl = self.gb.read_large_val()
      if self.gb.read1() != 0U {
        if self.gb.read1() != 0U {
          if self.gb.read1() != 0U {
            self.last_error = "wmapro: broken escape sequence"
            return
          }
          offset += self.gb.read(self.esc_len).reinterpret_as_int() + 4
        } else {
          offset += self.gb.read(2).reinterpret_as_int() + 1
        }
      }
      let negative = self.gb.read1() == 0U
      out[base + (offset & coef_mask)] = if negative {
        -lvl.to_double()
      } else {
        lvl.to_double()
      }
    }
    offset += 1
  }

  // NOTE: EOB can be omitted
  if offset > self.subframe_len {
    self.last_error = "wmapro: overflow in spectral RLE, ignoring"
  }
}
