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
  /// Finished pictures (access unit + reconstruction), coding order.
  out : Array[HevcEncodedFrame]
}

///|
/// Open a streaming encoder. The parameters mirror `hevc_encode_sequence`'s:
/// `qp` is the flat per-picture QP (ignored under `crf >= 0`), `crf` 0.0..=51.0
/// selects the §458 per-picture QPs (negative = off), `inter = false` makes
/// every push an IDR, `b_slices` enables the interleaved I/P/B schedule,
/// `bit_depth` 8/10/12 and `chroma_format_idc` 1/2/3 pick the coding format.
pub fn HevcStreamEncoder::open(
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  crf~ : Double = -1.0,
  inter~ : Bool = true,
  b_slices~ : Bool = false,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Result[HevcStreamEncoder, String] {
  if width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0 {
    return Err("hevc enc: dimensions must be even and positive")
  }
  if bit_depth != 8 && bit_depth != 10 && bit_depth != 12 {
    return Err("hevc enc: bit_depth must be 8, 10 or 12")
  }
  if chroma_format_idc < 1 || chroma_format_idc > 3 {
    return Err("hevc enc: chroma_format_idc must be 1, 2 or 3")
  }
  if qp < 0 || qp > 51 {
    return Err("hevc enc: qp out of range")
  }
  if crf > 51.0 {
    return Err("hevc enc: crf must be in 0.0..=51.0")
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
  // the raw luma joins the SAD source afterwards.
  let pic_qp = match self.crf_rc {
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
    ) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
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
