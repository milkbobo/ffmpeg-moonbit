///|
/// Vorbis encoder, part 3: windowing/MDCT, audio movement and the frame
/// driver.  See `vorbis_encode.mbt`.

///| `apply_window_and_mdct` (long window only; the encoder always emits
/// mode 1 = long blocks).
fn vorbis_enc_apply_window_and_mdct(enc : VorbisEncoder) -> Unit {
  let channels = enc.channels
  let win = enc.win[1]
  let window_len = 1 << (enc.log2_blocksize[1] - 1)
  let n = (1 << enc.log2_blocksize[1]).to_double() / 4.0
  for channel = 0; channel < channels; channel = channel + 1 {
    let base = channel * window_len * 2
    // vector_fmul(offset, offset, win, window_len)
    for i = 0; i < window_len; i = i + 1 {
      enc.samples[base + i] = enc.samples[base + i] * win[i]
    }
    // vector_fmul_scalar(offset, offset, 1/n, window_len)
    for i = 0; i < window_len; i = i + 1 {
      enc.samples[base + i] = enc.samples[base + i] * (1.0 / n)
    }
    let base2 = base + window_len
    // vector_fmul_reverse(offset, offset, win, window_len)
    for i = 0; i < window_len; i = i + 1 {
      enc.samples[base2 + i] = enc.samples[base2 + i] * win[window_len - 1 - i]
    }
    // vector_fmul_scalar(offset, offset, 1/n, window_len)
    for i = 0; i < window_len; i = i + 1 {
      enc.samples[base2 + i] = enc.samples[base2 + i] * (1.0 / n)
    }
    // MDCT of 2*window_len samples -> window_len coefficients.
    let input_len = 2 * window_len
    let mdct_in : Array[Double] = Array::make(input_len, 0.0)
    for i = 0; i < input_len; i = i + 1 {
      mdct_in[i] = enc.samples[base + i]
    }
    let coefs = wma_enc_mdct_fwd(mdct_in, window_len)
    let dst_base = channel * window_len
    for i = 0; i < window_len; i = i + 1 {
      enc.coeffs[dst_base + i] = coefs[i]
    }
  }
}

///| `move_audio`: assemble the next 2*window_len samples from the saved
/// overlap plus queued input frames (`sf_size` = frame_size = 64 samples).
/// `queue` holds interleaved frames of `frame_size * channels` samples each.
fn vorbis_enc_move_audio(
  enc : VorbisEncoder,
  queue : Array[Array[Double]],
  qi : Int32,
  nsub : Int32,
) -> Unit {
  let channels = enc.channels
  let frame_size = 1 << (enc.log2_blocksize[1] - 1)
  let sf_size = enc.frame_size
  let subframes = frame_size / sf_size
  // Copy samples from last frame into current frame.  The buffers are
  // channel-major with a 2*frame_size window per channel, so both the saved
  // copy and the zero fill must be done per channel (C memcpys
  // `samples + 2*ch*frame_size <- saved + ch*frame_size`).
  if enc.have_saved != 0 {
    for ch = 0; ch < channels; ch = ch + 1 {
      let dst = 2 * ch * frame_size
      let src = ch * frame_size
      for i = 0; i < frame_size; i = i + 1 {
        enc.samples[dst + i] = enc.saved[src + i]
      }
    }
  } else {
    for ch = 0; ch < channels; ch = ch + 1 {
      let dst = 2 * ch * frame_size
      for i = 0; i < frame_size; i = i + 1 {
        enc.samples[dst + i] = 0.0
      }
    }
  }
  for sf = 0; sf < subframes && sf < nsub; sf = sf + 1 {
    let cur = queue[qi + sf]
    for ch = 0; ch < channels; ch = ch + 1 {
      let offset = 2 * ch * frame_size + frame_size + sf * sf_size
      let save = ch * frame_size + sf * sf_size
      for i = 0; i < sf_size; i = i + 1 {
        let v = cur[i * channels + ch]
        enc.samples[offset + i] = v
        enc.saved[save + i] = v
      }
    }
  }
  enc.have_saved = 1
  // C mirrors the whole window into a scratch buffer (a psy-model leftover
  // that is never read); keep the same copy for faithfulness.
  let win_len = 2 * channels * frame_size
  for i = 0; i < win_len; i = i + 1 {
    enc.scratch[i] = enc.samples[i]
  }
}

///| `vorbis_encode_frame`: consume queued 64-sample frames; when at least
/// one full MDCT block is buffered, emit one packet.  Returns the packet
/// bytes (empty = need more input).
///
/// Mirrors the C's queueing semantics: with `frame_size = 64` and a 2048
/// block, 16 queued frames (1024 new samples) trigger a packet; at flush
/// the remainder is padded with zero frames.
pub fn VorbisEncoder::encode(
  self : VorbisEncoder,
  queue : Array[Array[Double]],
  qi : Int32,
  nqueued : Int32,
  flush : Bool,
) -> Result[Bytes, String] {
  let frame_size = 1 << (self.log2_blocksize[1] - 1)
  let need_more = nqueued * self.frame_size < frame_size
  if need_more && !flush {
    return Ok(b"")
  }
  // Pad the queue with empty frames for the last packet.
  let mut nsub = nqueued
  let queue_mut = queue
  if flush && nqueued * self.frame_size < frame_size {
    let frames_needed = frame_size / self.frame_size - nqueued
    for _i in 0..<frames_needed {
      queue_mut.push(Array::make(self.frame_size * self.channels, 0.0))
      nsub = nsub + 1
    }
  }
  vorbis_enc_move_audio(self, queue_mut, qi, nsub)
  vorbis_enc_apply_window_and_mdct(self)
  let bw = VorbisBitWriter::new()
  bw.put(0, 1) // magic bit
  bw.put(1, vorbis_enc_ilog(self.modes.length() - 1)) // mode 1 (long)
  let mode = self.modes[1]
  let mapping = self.mappings[mode.mapping]
  if mode.blockflag != 0 {
    bw.put(1, 1) // previous windowflag
    bw.put(1, 1) // next windowflag
  }
  let channels = self.channels
  for i = 0; i < channels; i = i + 1 {
    let fc = self.floors[mapping.floor[mapping.mux[i]]]
    let posts : Array[Int32] = Array::make(vorbis_enc_max_floor_values, 0)
    let frame_size2 = 1 << (self.log2_blocksize[1] - 1)
    let ch_base = i * frame_size2
    vorbis_enc_floor_fit(
      self,
      fc,
      self.coeffs,
      ch_base,
      posts,
      frame_size2,
    )
    if !vorbis_enc_floor_encode(
        self,
        fc,
        bw,
        posts,
        self.floor,
        ch_base,
        frame_size2,
      ) {
      return Err("vorbis_enc: output buffer is too small")
    }
  }
  let half = 1 << (self.log2_blocksize[1] - 1)
  for i = 0; i < channels * half; i = i + 1 {
    self.coeffs[i] = self.coeffs[i] / self.floor[i]
  }
  for i = 0; i < mapping.coupling_steps; i = i + 1 {
    let mag_off = mapping.magnitude[i] * half
    let ang_off = mapping.angle[i] * half
    for j = 0; j < half; j = j + 1 {
      let a = self.coeffs[ang_off + j]
      self.coeffs[ang_off + j] = self.coeffs[ang_off + j] - self.coeffs[mag_off + j]
      if self.coeffs[mag_off + j] > 0 {
        self.coeffs[ang_off + j] = -self.coeffs[ang_off + j]
      }
      if self.coeffs[ang_off + j] < 0 {
        self.coeffs[mag_off + j] = a
      }
    }
  }
  if !vorbis_enc_residue_encode(
      self,
      self.residues[mapping.residue[mapping.mux[0]]],
      bw,
      self.coeffs,
      half,
      self.channels,
    ) {
    return Err("vorbis_enc: output buffer is too small")
  }
  Ok(bw.finish())
}

///| The xiph-packed three-header extradata.
pub fn VorbisEncoder::extradata(self : VorbisEncoder) -> Bytes? {
  self.extradata
}

///| Interleaved s16-ranged tone frame generator (64-sample frames); public
/// for the libavformat E2E test.
pub fn vorbis_e2e_tone(n : Int32, ch : Int32, t0 : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(n * ch, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = (t0 + i).to_double()
    for c = 0; c < ch; c = c + 1 {
      let phase = if c == 1 { 0.31 } else { 0.0 }
      let v = 12000.0 *
        @math.sin(2.0 * 3.14159265358979323846 * 440.0 * t / 44100.0 + phase) +
        5000.0 * @math.sin(2.0 * 3.14159265358979323846 * 4400.0 * t / 44100.0)
      let fl = @math.floor(v)
      let diff = v - fl
      let r = if diff > 0.5 {
        fl + 1.0
      } else if diff < 0.5 {
        fl
      } else if fl.mod(2.0) != 0.0 {
        fl + 1.0
      } else {
        fl
      }
      out[i * ch + c] = r / 32768.0
    }
  }
  out
}
///| Split the xiph-packed extradata into (id, comment, setup); public for
/// the libavformat E2E test.
pub fn vorbis_e2e_split_extradata(data : Bytes) -> (Bytes, Bytes, Bytes) {
  let h0len = data[1].to_int()
  let h1len = data[2].to_int()
  let h0 = data.clamped_view(start=3, end=3 + h0len).to_owned()
  let h1 = data.clamped_view(start=3 + h0len, end=3 + h0len + h1len).to_owned()
  let h2 = data.clamped_view(start=3 + h0len + h1len, end=data.length()).to_owned()
  (h0, h1, h2)
}
