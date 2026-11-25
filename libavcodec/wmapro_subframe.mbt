///|
/// WMA Pro scale factors, subframe reconstruction and the frame loop
/// (`decode_scale_factors` .. `decode_frame`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// scale factors
// ---------------------------------------------------------------------------

///|
/// `decode_scale_factors`.
fn WmaProDecoder::decode_scale_factors(
  self : WmaProDecoder,
) -> Result[Unit, WmaproErr] {
  for i in 0..<self.channels_for_cur_subframe {
    let c = self.channel_indexes_for_cur_subframe[i]
    let other = if self.channel[c].scale_factor_idx != 0 { 0 } else { 1 }
    self.channel[c].scale_factors = self.channel[c].saved_scale_factors[other]
    let sf = self.channel[c].scale_factors

    // resample scale factors for the new block size: the factors may be
    // resampled several times before new values arrive, so the last
    // transmitted ones stay in `saved_scale_factors`
    if self.channel[c].reuse_sf {
      let sf_off = self.sf_offsets[self.table_idx][self.channel[c].table_idx]
      let saved = self.channel[c].saved_scale_factors[self.channel[c].scale_factor_idx]
      for b in 0..<self.num_bands {
        sf[b] = saved[sf_off[b]]
      }
    }
    if self.channel[c].cur_subframe == 0 || self.gb.read1() != 0U {
      if !self.channel[c].reuse_sf {
        // decode DPCM coded scale factors
        self.channel[c].scale_factor_step = self.gb.read(2).reinterpret_as_int() + 1
        let mut val = 45 / self.channel[c].scale_factor_step
        for b in 0..<self.num_bands {
          val += self.gb.read_vlc(self.sf_vlc)
          sf[b] = val
        }
      } else {
        // run level decode differences to the resampled factors
        let mut b = 0
        while b < self.num_bands {
          let idx = self.gb.read_vlc(self.sf_rl_vlc)
          if idx == 1 {
            break
          }
          let (val, sign, skip) = if idx == 0 {
            let code = self.gb.read(14)
            (
              (code >> 6).reinterpret_as_int(),
              (code & 1U).reinterpret_as_int() - 1,
              ((code & 0x3FU) >> 1).reinterpret_as_int(),
            )
          } else {
            (
              wmapro_scale_rl_level[idx],
              self.gb.read1().reinterpret_as_int() - 1,
              wmapro_scale_rl_run[idx],
            )
          }
          b += skip
          if b >= self.num_bands {
            return Err(Broken("wmapro: invalid scale factor coding"))
          }
          sf[b] += (val ^ sign) - sign
          b += 1
        }
      }

      // swap buffers
      self.channel[c].scale_factor_idx = other
      self.channel[c].table_idx = self.table_idx
      self.channel[c].reuse_sf = true
    }

    // calculate new scale factor maximum
    self.channel[c].max_scale_factor = sf[0]
    for b in 1..<self.num_bands {
      if sf[b] > self.channel[c].max_scale_factor {
        self.channel[c].max_scale_factor = sf[b]
      }
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// reconstruction
// ---------------------------------------------------------------------------

///|
/// `inverse_channel_transform`: the per band channel decorrelation.
fn WmaProDecoder::inverse_channel_transform(self : WmaProDecoder) -> Unit {
  let data = FixedArray::make(wmapro_max_channels, 0.0)
  for i in 0..<self.num_chgroups {
    let n = self.chgroup[i].num_channels
    if !self.chgroup[i].transform {
      continue
    }
    for b in 0..<self.num_bands {
      let start = self.sfb_offsets[self.table_idx][b]
      let band_end = self.sfb_offsets[self.table_idx][b + 1]
      let end = if band_end < self.subframe_len { band_end } else { self.subframe_len }
      if self.chgroup[i].transform_band[b] == 1 {
        // multiply values with the decorrelation_matrix
        for y in start..<end {
          for k in 0..<n {
            let ch = self.chgroup[i].channel_data[k]
            data[k] = self.channel[ch].out[self.channel[ch].coeffs + y]
          }
          let mat = self.chgroup[i].decorrelation_matrix
          let mut m = 0
          for k in 0..<n {
            let mut sum = 0.0
            for j in 0..<n {
              sum += data[j] * mat[m]
              m += 1
            }
            let ch = self.chgroup[i].channel_data[k]
            self.channel[ch].out[self.channel[ch].coeffs + y] = sum
          }
        }
      } else if self.nb_channels == 2 {
        let gain = 181.0 / 128.0
        for k in 0..<n {
          let ch = self.chgroup[i].channel_data[k]
          let base = self.channel[ch].coeffs
          for y in start..<end {
            self.channel[ch].out[base + y] = self.channel[ch].out[base + y] *
              gain
          }
        }
      }
    }
  }
}

///|
/// `wmapro_window`: the sine window and the overlap-add, in place on the
/// channel's output buffer.
fn WmaProDecoder::apply_window(self : WmaProDecoder) -> Unit {
  for i in 0..<self.channels_for_cur_subframe {
    let c = self.channel_indexes_for_cur_subframe[i]
    let mut winlen = self.channel[c].prev_block_len
    let mut start = self.channel[c].coeffs - (winlen >> 1)
    if self.subframe_len < winlen {
      start += (winlen - self.subframe_len) >> 1
      winlen = self.subframe_len
    }
    let window = self.windows[wma_log2(winlen) - wmapro_block_min_bits]
    winlen = winlen >> 1
    wmapro_fmul_window(self.channel[c].out, start, window, winlen)
    self.channel[c].prev_block_len = self.subframe_len
  }
}

// ---------------------------------------------------------------------------
// subframe
// ---------------------------------------------------------------------------

///|
/// `decode_subframe`: one subframe (block) of the channels that share it.
fn WmaProDecoder::decode_subframe(
  self : WmaProDecoder,
) -> Result[Unit, WmaproErr] {
  let mut offset = self.samples_per_frame
  let mut subframe_len = self.samples_per_frame
  let mut total_samples = self.samples_per_frame * self.nb_channels
  let mut transmit_coeffs = false

  // reset channel context and find the next block offset and size: the
  // next block of the channel with the smallest number of decoded
  // samples
  for i in 0..<self.nb_channels {
    self.channel[i].grouped = false
    if offset > self.channel[i].decoded_samples {
      offset = self.channel[i].decoded_samples
      subframe_len = self.channel[i].subframe_len[self.channel[i].cur_subframe]
    }
  }
  // A tile without subframes leaves the C dividing by zero.
  if subframe_len <= 0 {
    return Err(Broken("wmapro: broken frame: empty tile"))
  }

  // get a list of all channels that contain the estimated block
  self.channels_for_cur_subframe = 0
  for i in 0..<self.nb_channels {
    let cur_subframe = self.channel[i].cur_subframe

    // subtract already processed samples
    total_samples -= self.channel[i].decoded_samples

    // and count if there are multiple subframes that match our profile
    if offset == self.channel[i].decoded_samples &&
      subframe_len == self.channel[i].subframe_len[cur_subframe] {
      total_samples -= self.channel[i].subframe_len[cur_subframe]
      self.channel[i].decoded_samples +=
        self.channel[i].subframe_len[cur_subframe]
      self.channel_indexes_for_cur_subframe[self.channels_for_cur_subframe] = i
      self.channels_for_cur_subframe += 1
    }
  }

  // check if the frame will be complete after processing the estimated
  // block
  if total_samples == 0 {
    self.parsed_all_subframes = true
  }

  // number of scale factor bands and their offsets
  self.table_idx = wma_log2(self.samples_per_frame / subframe_len)
  self.num_bands = self.num_sfb[self.table_idx]
  let cur_subwoofer_cutoff = self.subwoofer_cutoffs[self.table_idx]

  // configure the decoder for the current subframe
  offset += self.samples_per_frame >> 1
  for i in 0..<self.channels_for_cur_subframe {
    let c = self.channel_indexes_for_cur_subframe[i]
    self.channel[c].coeffs = offset
  }
  self.subframe_len = subframe_len
  self.esc_len = wma_log2(subframe_len - 1) + 1

  // skip extended header if any
  if self.gb.read1() != 0U {
    let mut num_fill_bits = self.gb.read(2).reinterpret_as_int()
    if num_fill_bits == 0 {
      let len = self.gb.read(4).reinterpret_as_int()
      num_fill_bits = (if len == 0 {
        0U
      } else {
        self.gb.read(len)
      }).reinterpret_as_int() +
        1
    }
    if self.gb.count() + num_fill_bits > self.num_saved_bits {
      return Err(Broken("wmapro: invalid number of fill bits"))
    }
    self.gb.skip_long(num_fill_bits)
  }

  // no idea for what the following bit is used
  if self.gb.read1() != 0U {
    return Err(Unsupported("wmapro: reserved bit is set"))
  }
  match self.decode_channel_transform() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  for i in 0..<self.channels_for_cur_subframe {
    let c = self.channel_indexes_for_cur_subframe[i]
    self.channel[c].transmit_coefs = self.gb.read1() != 0U
    if self.channel[c].transmit_coefs {
      transmit_coeffs = true
    }
  }
  if transmit_coeffs {
    let mut quant_step = (90 * self.bits_per_sample) >> 4

    // decode number of vector coded coefficients
    self.transmit_num_vec_coeffs = self.gb.read1() != 0U
    if self.transmit_num_vec_coeffs {
      let num_bits = wma_log2((subframe_len + 3) / 4) + 1
      for i in 0..<self.channels_for_cur_subframe {
        let c = self.channel_indexes_for_cur_subframe[i]
        let num_vec_coeffs = self.gb.read(num_bits).reinterpret_as_int() << 2
        if num_vec_coeffs > subframe_len {
          return Err(Broken("wmapro: num_vec_coeffs \{num_vec_coeffs} is too large"))
        }
        self.channel[c].num_vec_coeffs = num_vec_coeffs
      }
    } else {
      for i in 0..<self.channels_for_cur_subframe {
        let c = self.channel_indexes_for_cur_subframe[i]
        self.channel[c].num_vec_coeffs = subframe_len
      }
    }

    // decode quantization step
    let mut step = self.gb.read_signed(6)
    quant_step += step
    if step == -32 || step == 31 {
      let sign = (if step == 31 { 1 } else { 0 }) - 1
      let mut quant = 0
      let mut run = true
      while run {
        if self.gb.count() + 5 < self.num_saved_bits {
          step = self.gb.read(5).reinterpret_as_int()
          if step == 31 {
            quant += 31
          } else {
            run = false
          }
        } else {
          run = false
        }
      }
      quant_step += ((quant + step) ^ sign) - sign
    }

    // decode quantization step modifiers for every channel
    if self.channels_for_cur_subframe == 1 {
      let c = self.channel_indexes_for_cur_subframe[0]
      self.channel[c].quant_step = quant_step
    } else {
      let modifier_len = self.gb.read(3).reinterpret_as_int()
      for i in 0..<self.channels_for_cur_subframe {
        let c = self.channel_indexes_for_cur_subframe[i]
        self.channel[c].quant_step = quant_step
        if self.gb.read1() != 0U {
          if modifier_len != 0 {
            self.channel[c].quant_step +=
              self.gb.read(modifier_len).reinterpret_as_int() +
              1
          } else {
            self.channel[c].quant_step += 1
          }
        }
      }
    }

    // decode scale factors
    match self.decode_scale_factors() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }

  // parse coefficients
  for i in 0..<self.channels_for_cur_subframe {
    let c = self.channel_indexes_for_cur_subframe[i]
    if self.channel[c].transmit_coefs && self.gb.count() < self.num_saved_bits {
      self.decode_coeffs(c)
    } else {
      let base = self.channel[c].coeffs
      for k in 0..<subframe_len {
        self.channel[c].out[base + k] = 0.0
      }
    }
  }

  if transmit_coeffs {
    let tx_idx = wma_log2(subframe_len) - wmapro_block_min_bits

    // reconstruct the per channel data
    self.inverse_channel_transform()
    for i in 0..<self.channels_for_cur_subframe {
      let c = self.channel_indexes_for_cur_subframe[i]
      let base = self.channel[c].coeffs
      let sf = self.channel[c].scale_factors
      if c == self.lfe_channel {
        for k in cur_subwoofer_cutoff..<subframe_len {
          self.tmp[k] = 0.0
        }
      }

      // inverse quantization and rescaling
      for b in 0..<self.num_bands {
        let band_end = self.sfb_offsets[self.table_idx][b + 1]
        let end = if band_end < subframe_len { band_end } else { subframe_len }
        let exp = self.channel[c].quant_step -
          (self.channel[c].max_scale_factor - sf[b]) *
          self.channel[c].scale_factor_step
        let quant = @math.pow(10.0, exp.to_double() / 20.0)
        let start = self.sfb_offsets[self.table_idx][b]
        for k in start..<end {
          self.tmp[k] = self.channel[c].out[base + k] * quant
        }
      }

      // apply imdct (imdct_half == DCTIV with reverse)
      wmapro_imdct(
        self.imdct_cos,
        self.imdct_mask,
        self.samples_per_frame / subframe_len,
        self.tmp,
        self.channel[c].out,
        base,
        subframe_len,
        self.tx_scale[tx_idx],
      )
    }
  }

  // window and overlap-add
  self.apply_window()

  // handled one subframe
  for i in 0..<self.channels_for_cur_subframe {
    let c = self.channel_indexes_for_cur_subframe[i]
    if self.channel[c].cur_subframe >= self.channel[c].num_subframes {
      return Err(Broken("wmapro: broken subframe"))
    }
    self.channel[c].cur_subframe += 1
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// frame
// ---------------------------------------------------------------------------

///|
/// `decode_frame` into `frame` (one row of `samples_per_frame` doubles per
/// channel). Returns `(got_frame, more_frames)`. A broken frame is dropped
/// and the packet marked lost, as in the C.
fn WmaProDecoder::decode_frame(
  self : WmaProDecoder,
  frame : Array[Array[Double]],
) -> Result[(Bool, Bool), WmaproErr] {
  // get frame length
  let mut frame_len = 0
  if self.len_prefix {
    frame_len = self.gb.read(self.log2_frame_size).reinterpret_as_int()
  }

  // decode tile information
  match self.decode_tilehdr() {
    Err(Broken(msg)) => {
      self.last_error = msg
      self.packet_loss = true
      return Ok((false, false))
    }
    Err(e) => {
      // The C drops the frame (`packet_loss`) before it answers the error.
      self.packet_loss = true
      return Err(e)
    }
    Ok(_) => ()
  }

  // read postproc transform
  if self.nb_channels > 1 && self.gb.read1() != 0U {
    if self.gb.read1() != 0U {
      for _ in 0..<(self.nb_channels * self.nb_channels) {
        self.gb.skip(4)
      }
    }
  }

  // read drc info
  if self.dynamic_range_compression {
    let _ = self.gb.read(8)
  }
  if self.gb.read1() != 0U {
    if self.gb.read1() != 0U {
      self.trim_start = self.gb.read(wma_log2(self.samples_per_frame * 2)).reinterpret_as_int()
    }
    if self.gb.read1() != 0U {
      self.trim_end = self.gb.read(wma_log2(self.samples_per_frame * 2)).reinterpret_as_int()
    }
  } else {
    self.trim_start = 0
    self.trim_end = 0
  }

  // reset subframe states
  self.parsed_all_subframes = false
  for i in 0..<self.nb_channels {
    self.channel[i].decoded_samples = 0
    self.channel[i].cur_subframe = 0
    self.channel[i].reuse_sf = false
  }

  // decode all subframes
  while !self.parsed_all_subframes {
    match self.decode_subframe() {
      Err(Broken(msg)) => {
        self.last_error = msg
        self.packet_loss = true
        return Ok((false, false))
      }
      Err(e) => {
        self.packet_loss = true
        return Err(e)
      }
      Ok(_) => ()
    }
  }

  // copy samples to the output buffer
  for i in 0..<self.nb_channels {
    let out = self.channel[i].out
    let row = frame[i]
    for k in 0..<self.samples_per_frame {
      row[k] = out[k]
    }

    // reuse second half of the IMDCT output for the next frame
    for k in 0..<(self.samples_per_frame >> 1) {
      out[k] = out[self.samples_per_frame + k]
    }
  }
  let mut got_frame = true
  if self.skip_frame {
    self.skip_frame = false
    got_frame = false
  }
  let used = self.gb.count() - self.frame_offset
  if self.len_prefix {
    if frame_len != used + 2 {
      self.last_error = "wmapro: frame would have to skip \{frame_len - used - 1} bits"
      self.packet_loss = true
      return Ok((got_frame, false))
    }

    // skip the rest of the frame data
    self.gb.skip_long(frame_len - used - 1)
  } else {
    while self.gb.count() < self.num_saved_bits && self.gb.read1() == 0U {
      ()
    }
  }

  // decode trailer bit
  let more_frames = self.gb.read1() != 0U
  Ok((got_frame, more_frames))
}
