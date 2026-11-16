///|
priv enum H264VbvPicture {
  Idr
  P
  B
}

///|
/// Buffer odd display positions. Every emitting push is transactional:
/// a P/B pair or an old tail P plus a new IDR commits as one group.
fn H264StreamEncoder::push_vbv(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  vbv : H264Vbv,
  force_idr~ : Bool,
) -> Result[Unit, String] {
  let display = self.next_display - self.gop_start
  if self.b_slices && self.next_display > 0 && !force_idr && display % 2 == 1 {
    self.pending = Some((y, u, v))
    self.next_display += 1
    return Ok(())
  }
  let trial = self.vbv_trial()
  if self.next_display == 0 || force_idr {
    match trial.vbv_flush_pending(vbv) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    trial.next_display += 1
    match trial.vbv_picture(y, u, v, vbv, 0, Idr) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else if !self.b_slices {
    trial.next_display += 1
    match trial.vbv_picture(y, u, v, vbv, display, P) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    let (by, bu, bv) = match trial.pending {
      Some(f) => f
      None => return Err("h264 enc: stream scheduling lost the B picture")
    }
    trial.next_display += 1
    match trial.vbv_picture(y, u, v, vbv, display, P) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match trial.vbv_picture(by, bu, bv, vbv, display - 1, B) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    trial.pending = None
    // AU/recon order stays P then B; QP history stays display order.
    let p_qp = trial.stats.frame_qps[0]
    trial.stats.frame_qps[0] = trial.stats.frame_qps[1]
    trial.stats.frame_qps[1] = p_qp
  }
  self.vbv_commit(trial)
  Ok(())
}

///|
fn H264StreamEncoder::vbv_flush_pending(
  self : H264StreamEncoder,
  vbv : H264Vbv,
) -> Result[Unit, String] {
  match self.pending {
    Some((y, u, v)) =>
      match
        self.vbv_picture(
          y,
          u,
          v,
          vbv,
          self.next_display - self.gop_start - 1,
          P,
        ) {
        Ok(_) => self.pending = None
        Err(e) => return Err(e)
      }
    None => ()
  }
  Ok(())
}

///|
/// Shared references and PPS are read-only; mutable mirrors and queues
/// belong to the trial. This also isolates partially successful groups.
fn H264StreamEncoder::vbv_trial(self : H264StreamEncoder) -> H264StreamEncoder {
  {
    ..self,
    stats: H264EncStats::new(),
    states: self.states.map(st => {
      ..st,
      mv: st.mv.copy(),
      ref_idx: st.ref_idx.copy(),
      nz: st.nz.copy(),
      modes: st.modes.copy(),
    }),
    refs_y: self.refs_y.copy(),
    refs_u: self.refs_u.copy(),
    refs_v: self.refs_v.copy(),
    out: [],
    recons: [],
  }
}

///|
fn H264StreamEncoder::vbv_commit(
  self : H264StreamEncoder,
  trial : H264StreamEncoder,
) -> Unit {
  for i in 0..<self.states.length() {
    self.states[i] = trial.states[i]
  }
  self.ref_y = trial.ref_y
  self.ref_u = trial.ref_u
  self.ref_v = trial.ref_v
  self.refs_y = trial.refs_y
  self.refs_u = trial.refs_u
  self.refs_v = trial.refs_v
  self.ref_colocated = trial.ref_colocated
  self.fut_y = trial.fut_y
  self.fut_u = trial.fut_u
  self.fut_v = trial.fut_v
  self.pending = trial.pending
  self.next_display = trial.next_display
  self.fn_counter = trial.fn_counter
  self.gop_start = trial.gop_start
  self.vbv_fullness = trial.vbv_fullness
  self.vbv_last_bp = trial.vbv_last_bp
  self.vbv_coded = trial.vbv_coded
  self.abr_bits = trial.abr_bits
  self.abr_pics = trial.abr_pics
  self.abr_qp = trial.abr_qp
  for au in trial.out {
    self.out.push(au)
  }
  for frame in trial.recons {
    self.recons.push(frame)
  }
  self.stats.add_picture(trial.stats)
  for qp in trial.stats.frame_qps {
    self.stats.frame_qps.push(qp)
  }
  self.stats.vbv_bits += trial.stats.vbv_bits
  self.stats.vbv_fills += trial.stats.vbv_fills
  self.stats.vbv_filler_bytes += trial.stats.vbv_filler_bytes
}

///|
/// Search a single decode-order removal. The caller owns input scheduling;
/// the accepted picture advances only CPB/DPB state and coded-picture time.
fn H264StreamEncoder::vbv_picture(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  vbv : H264Vbv,
  display : Int32,
  kind : H264VbvPicture,
) -> Result[Unit, String] {
  let idr = kind is Idr
  let frame_vbv = if idr && self.vbv_coded > 0 {
    let rate = (vbv.bit_rate_value_minus1 + 1) << 6
    let delay = (self.vbv_fullness.to_int64() * 90000L / rate.to_int64())
      .to_int()
      .max(1)
    {
      ..vbv,
      init_bits: self.vbv_fullness,
      init_delay: delay,
      init_delay_offset: (vbv.bufsize.to_int64() * 90000L / rate.to_int64()).to_int() -
      delay,
    }
  } else {
    vbv
  }
  let cpb_delay = (self.vbv_coded - self.vbv_last_bp) % 32768 * 2
  let dpb_delay = if self.b_slices {
    (self.gop_start + display + 1 - self.vbv_coded) * 2
  } else {
    0
  }
  // §422f: ABR (if on) proposes the starting QP; the VBV climb stacks on
  // top and `abr_note` (called inside the accepted trial's picture step)
  // folds the final QP and the emitted bits into the controller.
  let mut qp = self.abr_suggest().max(h264_rc_qp_min).min(h264_rc_qp_max)
  while true {
    let trial = self.vbv_trial()
    let result = match kind {
      Idr =>
        trial.stream_idr(
          y,
          u,
          v,
          qp~,
          vbv=Some(frame_vbv),
          idr_cpb_delay=cpb_delay,
        )
      P =>
        trial.stream_p(
          y,
          u,
          v,
          display,
          qp~,
          vbv=Some(frame_vbv),
          cpb_delay~,
          dpb_delay~,
        )
      B =>
        trial.stream_b(
          y,
          u,
          v,
          display,
          qp~,
          vbv=Some(frame_vbv),
          cpb_delay~,
          dpb_delay~,
        )
    }
    match result {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let raw = trial.out[0]
    let filler = h264_vbv_fillers(1, [raw.length()], {
        ..vbv,
        init_bits: self.vbv_fullness,
      })[0]
    let bits = (raw.length() + filler) * 8
    if bits <= self.vbv_fullness {
      let next_fullness = self.vbv_fullness - bits + vbv.rate_bits
      if next_fullness > vbv.bufsize {
        return Err("h264 enc: streaming VBV overflow")
      }
      trial.vbv_fullness = next_fullness
      if idr {
        trial.vbv_last_bp = self.vbv_coded
      }
      trial.vbv_coded += 1
      if filler > 0 {
        trial.out[0] = h264_enc_concat([raw, h264_enc_filler_nal(filler - 5)])
      }
      trial.stats.vbv_bits = bits.to_int64()
      if filler > 0 {
        trial.stats.vbv_fills = 1
        trial.stats.vbv_filler_bytes = filler
      }
      self.vbv_commit(trial)
      return Ok(())
    }
    if qp == h264_rc_qp_max {
      return Err(
        "h264 enc: streaming VBV underflow at AU \{self.vbv_coded} even at QP \{qp}",
      )
    }
    qp = (qp + h264_rc_qp_jump(raw.length() * 8, self.vbv_fullness).max(1)).min(
      h264_rc_qp_max,
    )
  }
  Err("h264 enc: streaming VBV exhausted")
}

///|
fn H264EncStats::add_picture(self : H264EncStats, other : H264EncStats) -> Unit {
  self.i16_mbs += other.i16_mbs
  self.i8_mbs += other.i8_mbs
  self.i8p_mbs += other.i8p_mbs
  self.i4p_mbs += other.i4p_mbs
  self.coded_mbs += other.coded_mbs
  self.dqp_mbs += other.dqp_mbs
  self.b_mbs += other.b_mbs
  self.bi_mbs += other.bi_mbs
  self.bl1_mbs += other.bl1_mbs
  self.bdirect_mbs += other.bdirect_mbs
  self.bpart_mbs += other.bpart_mbs
  self.b8x8_mbs += other.b8x8_mbs
  self.bi16_mbs += other.bi16_mbs
  self.bi4_mbs += other.bi4_mbs
  self.bi8_mbs += other.bi8_mbs
}
