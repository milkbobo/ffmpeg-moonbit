///|
/// Streaming HEVC sequence encoder (`§459`): frames arrive one at a time in
/// display order, access units come out as soon as their references are
/// complete — the IDR with its parameter sets on the first push, one P access
/// unit per following push (`b_slices` off), or the P-then-B pair of the
/// `I, P2, B1, P4, B3, ...` schedule (`b_slices` on: an odd display position
/// parks as pending until its future anchor arrives; a trailing odd position
/// flushes as a tail P in `finish`). With `inter = false` every push codes an
/// IDR (the §448 all-intra batch schedule).
///
/// The contract is byte equality with the batch entries: concatenating the
/// drained access units reproduces `hevc_encode_sequence`'s Annex B stream
/// for the same frames and settings, flat QP or CRF alike — the §458
/// controller is display-causal, so the per-push QP recurrence is the same
/// formula the batch driver runs over the whole array, and the §459
/// `anchor_gap_two` fix keeps odd-length B schedules referenceable. The
/// encoder keeps the reference chain, the pending B picture and (under CRF)
/// the previous luma plane — a bounded working set.

///|
pub struct HevcStreamEncoder {
  width : Int32
  height : Int32
  qp : Int32
  /// `§458`: negative = off (the flat `qp` is the per-picture QP).
  crf : Double
  /// `inter = false` codes every push as an IDR (the §448 schedule).
  inter : Bool
  b_slices : Bool
  bit_depth : Int32
  chroma_format_idc : Int32
  /// `§460`: opt-in chroma SAO.
  sao_chroma : Bool
  /// `§461`: opt-in edge-offset SAO mode.
  sao_eo : Bool
  priv crf_rc : HevcCrf?
  /// The previous push's luma plane (the CRF SAD sample source).
  priv mut prev_y : FixedArray[Int32]?
  /// The most recently coded anchor (L0 for the next P and for a pending B).
  priv mut ref_pic : HevcPicture
  /// The anchor before `ref_pic` (a pending B's L0).
  priv mut prev_anchor : HevcPicture
  /// The B picture waiting for its future anchor: (y, u, v, qp, display).
  priv mut pending : (
    FixedArray[Int32],
    FixedArray[Int32],
    FixedArray[Int32],
    Int32,
    Int32,
  )?
  /// Display position of the NEXT pushed frame.
  priv mut next_display : Int32
  /// `§462` streaming ABR: target bits per second (0 = off) and the
  /// controller state — the coded-bit total, the picture count and the
  /// working QP (the accepted picture's final QP, so the walk carries).
  abr_rate : Int64
  abr_fps : Int32
  priv mut abr_bits : Int64
  priv mut abr_pics : Int32
  priv mut abr_qp : Int32
  /// Finished pictures (access unit + reconstruction), coding order.
  out : Array[HevcEncodedFrame]
}

///|
/// Open a streaming encoder. The parameters mirror `hevc_encode_sequence`'s:
/// `qp` is the flat per-picture QP (ignored under `crf >= 0`), `crf` 0.0..=51.0
/// selects the §458 per-picture QPs (negative = off), `inter = false` makes
/// every push an IDR, `b_slices` enables the interleaved I/P/B schedule,
/// `bit_depth` 8/10/12 and `chroma_format_idc` 1/2/3 pick the coding format;
/// `sao_chroma = true` (§460) opts the Cb/Cr planes into SAO and
/// `sao_eo = true` (§461) lets the edge-offset mode compete with the band.
pub fn HevcStreamEncoder::open(
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  crf~ : Double = -1.0,
  inter~ : Bool = true,
  b_slices~ : Bool = false,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
  sao_chroma~ : Bool = false,
  sao_eo~ : Bool = false,
  /// `§462` streaming ABR: average bits per second to track. A single-pass
  /// controller — every picture's QP starts from the cumulative deviation
  /// against `target_bitrate / fps` (only ever climbing above the caller's
  /// flat `qp`; the rate is a budget ceiling). Requires `fps > 0` and is
  /// mutually exclusive with `crf`; without it the QP stays flat
  /// (byte-identical to the pre-§462 streams).
  target_bitrate~ : Int32 = 0,
  fps~ : Int32 = 0,
) -> Result[HevcStreamEncoder, String] {
  if width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0 {
    return Err("hevc enc: dimensions must be even and positive")
  }
  if bit_depth != 8 && bit_depth != 10 && bit_depth != 12 {
    return Err("hevc enc: bit_depth must be 8, 10 or 12")
  }
  if chroma_format_idc < 0 || chroma_format_idc > 3 {
    return Err("hevc enc: chroma_format_idc must be 0, 1, 2 or 3")
  }
  if sao_chroma && chroma_format_idc == 0 {
    return Err("hevc enc: sao_chroma needs chroma_format_idc != 0")
  }
  if qp < 0 || qp > 51 {
    return Err("hevc enc: qp out of range")
  }
  if crf > 51.0 {
    return Err("hevc enc: crf must be in 0.0..=51.0")
  }
  if target_bitrate < 0 {
    return Err("hevc enc: target_bitrate must be nonnegative")
  }
  if target_bitrate > 0 {
    if fps <= 0 {
      return Err("hevc enc: target_bitrate needs fps > 0")
    }
    if crf >= 0.0 {
      return Err("hevc enc: crf and target_bitrate are mutually exclusive")
    }
    if target_bitrate.to_int64() / fps.to_int64() < 1L {
      return Err("hevc enc: target_bitrate below one bit per picture")
    }
  }
  Ok({
    width,
    height,
    qp,
    crf,
    inter,
    b_slices,
    bit_depth,
    chroma_format_idc,
    sao_chroma,
    sao_eo,
    abr_rate: target_bitrate.to_int64(),
    abr_fps: fps,
    abr_bits: 0L,
    abr_pics: 0,
    abr_qp: qp,
    crf_rc: if crf >= 0.0 {
      Some(HevcCrf::create(crf))
    } else {
      None
    },
    prev_y: None,
    ref_pic: hevc_picture_new(0, 0, 0, 0),
    prev_anchor: hevc_picture_new(0, 0, 0, 0),
    pending: None,
    next_display: 0,
    out: [],
  })
}

///|
/// Push the next frame in display order. The produced pictures (if any)
/// queue up for `drain`: with `b_slices` off every push yields one access
/// unit (the first carries the parameter sets); with it on an even display
/// position yields the P-B pair and an odd one just buffers.
pub fn HevcStreamEncoder::push_frame(
  self : HevcStreamEncoder,
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
) -> Result[Unit, String] {
  match
    hevc_enc_guard_frame(
      y,
      u,
      v,
      self.width,
      self.height,
      bit_depth=self.bit_depth,
      chroma_format_idc=self.chroma_format_idc,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let i = self.next_display
  self.next_display = self.next_display + 1
  // §458: the display-causal QP for this push (first push = the baseline);
  // the raw luma joins the SAD source afterwards. §462: with ABR on the
  // controller's suggestion replaces the flat QP (CRF is rejected at open).
  let pic_qp = if self.abr_rate != 0L {
    self.abr_suggest()
  } else {
    match self.crf_rc {
      Some(rc) => {
        let qp = match self.prev_y {
          None => rc.base
          Some(prev) =>
            rc.qp_for(hevc_enc_crf_sad(prev, y, self.width, self.height))
        }
        qp
      }
      None => self.qp
    }
  }
  self.prev_y = Some(y.copy())
  if !self.inter || i == 0 {
    // The §448 schedule: every picture an IDR, parameter sets on the first.
    return self.code_idr(y, u, v, i, pic_qp, i == 0)
  }
  if self.b_slices && i % 2 == 1 {
    // A B picture: it waits for the future anchor the next even push codes.
    self.pending = Some((y.copy(), u.copy(), v.copy(), pic_qp, i))
    return Ok(())
  }
  // A P anchor. Under the B schedule its L0 sits two display steps back (the
  // parked B at i-1 exists whenever this even position does); otherwise the
  // default -1.
  let delta = if self.b_slices { -2 } else { -1 }
  match self.code_anchor(y, u, v, i, pic_qp, delta) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.code_pending_b()
}

///|
/// Flush: a trailing pending B has no future reference and codes as a P
/// anchor one display step after the last one (the default delta). Returns
/// the remaining access units; an encoder that never saw a push errors like
/// the batch entry's empty frame array.
pub fn HevcStreamEncoder::finish(
  self : HevcStreamEncoder,
) -> Result[Array[Bytes], String] {
  match self.pending {
    Some((y, u, v, qp, i)) => {
      self.pending = None
      match self.code_anchor(y, u, v, i, qp, -1) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    None => ()
  }
  if self.next_display == 0 {
    return Err("hevc enc: no frames")
  }
  Ok(self.drain())
}

///|
/// Take the finished access units (coding order; decoders reorder to display
/// order via the POC when `b_slices` is on).
pub fn HevcStreamEncoder::drain(self : HevcStreamEncoder) -> Array[Bytes] {
  let out : Array[Bytes] = []
  for f in self.out {
    out.push(f.annexb)
  }
  self.out.clear()
  out
}

///|
/// Code one picture through the batch frame encoder and queue it. The
/// reference-chain rotation runs for anchors only (the batch loop's
/// `if !is_b` block): the picture just coded becomes the next L0, the old
/// L0 moves to `prev_anchor` for the B that follows it.
fn HevcStreamEncoder::code_picture(
  self : HevcStreamEncoder,
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  poc : Int32,
  qp : Int32,
  with_ps : Bool,
  slice_type : Int32,
  l0 : HevcPicture,
  l1~ : HevcPicture = hevc_picture_new(0, 0, 0, 0),
  rps_delta~ : Int32 = -1,
  rotate~ : Bool = false,
) -> Result[Unit, String] {
  let frame = match
    hevc_enc_frame_ex(
      y,
      u,
      v,
      self.width,
      self.height,
      qp,
      with_ps,
      slice_type,
      poc,
      l0,
      self.inter,
      self.bit_depth,
      self.chroma_format_idc,
      ref_pic_l1=l1,
      rps_delta~,
      sao_chroma=self.sao_chroma,
      sao_eo=self.sao_eo,
    ) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  // §462: every accepted picture feeds the ABR controller (its coded bits
  // and final QP); a no-op with ABR off.
  self.abr_note(frame.annexb.length().to_int64() * 8L, qp)
  let recon = {
    width: frame.width,
    height: frame.height,
    cw: frame.width / hevc_sub_width_c[self.chroma_format_idc],
    ch: frame.height / hevc_sub_height_c[self.chroma_format_idc],
    y: frame.recon_y.copy(),
    cb: frame.recon_u.copy(),
    cr: frame.recon_v.copy(),
  }
  if rotate {
    if self.ref_pic.width > 0 {
      self.prev_anchor = self.ref_pic
    }
    self.ref_pic = recon
  }
  self.out.push(frame)
  Ok(())
}

///|
fn HevcStreamEncoder::code_idr(
  self : HevcStreamEncoder,
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  poc : Int32,
  qp : Int32,
  with_ps : Bool,
) -> Result[Unit, String] {
  self.code_picture(
    y,
    u,
    v,
    poc,
    qp,
    with_ps,
    hevc_slice_i,
    self.ref_pic,
    rotate=true,
  )
}

///|
fn HevcStreamEncoder::code_anchor(
  self : HevcStreamEncoder,
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  poc : Int32,
  qp : Int32,
  rps_delta : Int32,
) -> Result[Unit, String] {
  self.code_picture(
    y,
    u,
    v,
    poc,
    qp,
    false,
    hevc_slice_p,
    self.ref_pic,
    rps_delta~,
    rotate=true,
  )
}

///|
/// The B picture parked by the previous odd push: L0 is the anchor before
/// the one just coded, L1 the one just coded.
fn HevcStreamEncoder::code_pending_b(
  self : HevcStreamEncoder,
) -> Result[Unit, String] {
  match self.pending {
    Some((y, u, v, qp, i)) => {
      self.pending = None
      self.code_picture(
        y,
        u,
        v,
        i,
        qp,
        false,
        hevc_slice_b,
        self.prev_anchor,
        l1=self.ref_pic,
      )
    }
    None => Ok(())
  }
}

///|
/// `§462` streaming ABR suggestion: every picture's QP starts from the
/// cumulative deviation against `target_bitrate / fps`, predicted by the
/// "size halves every +6 QP" model (`h264_rc_qp_jump` — shared with the
/// H.264 controller), damped against a three-picture window and clamped to
/// +1..+3 QP per picture so the QP walks rather than leaps. The QP only
/// climbs above the caller's flat value — the rate is a budget ceiling, and
/// a single-pass encoder cannot know that a cheap present hides an
/// expensive future. `abr_qp` carries the last accepted picture's QP.
fn HevcStreamEncoder::abr_suggest(self : HevcStreamEncoder) -> Int32 {
  if self.abr_rate == 0L {
    return self.qp
  }
  let budget = self.abr_rate / self.abr_fps.to_int64()
  let ahead = self.abr_bits - budget * self.abr_pics.to_int64()
  let window = budget * 3L
  let corr = if window <= 0L || ahead <= 0L {
    0
  } else {
    h264_rc_qp_jump(
      ahead.min(0x3FFFFFFFL).to_int(),
      window.min(0x3FFFFFFFL).to_int(),
    )
    .max(1)
    .min(3)
  }
  let q = self.abr_qp + corr
  if q < 0 {
    0
  } else if q > 51 {
    51
  } else {
    q
  }
}

///|
/// `§462`: fold one accepted picture into the ABR controller. No-op with
/// ABR off, so the default streams stay byte-identical.
fn HevcStreamEncoder::abr_note(
  self : HevcStreamEncoder,
  bits : Int64,
  qp : Int32,
) -> Unit {
  if self.abr_rate == 0L {
    return
  }
  self.abr_bits = self.abr_bits + bits
  self.abr_pics = self.abr_pics + 1
  self.abr_qp = if qp < 0 { 0 } else if qp > 51 { 51 } else { qp }
}
