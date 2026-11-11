///|
/// Streaming H.264 sequence encoder (`§394`): frames arrive one at a time
/// in display order, access units come out as soon as their references are
/// complete — an I picture with its parameter sets on the first frame, a P
/// access unit per following frame (`b_slices` off), or the P-then-B pair
/// of the `I, P2, B1, P4, B3, ...` schedule (`b_slices` on, the B picture
/// waits for its future reference). The encoder keeps only the pending
/// frame, the reference chain and the per-macroblock mirror: pushing a
/// frame releases the previous pending one, so the encoder-side memory is
/// constant in the sequence length.
///
/// The picture encoders are the batch entries' own: the intra picture via
/// `h264_encode_intra_frame` / `h264_encode_intra_frame_cabac`, every P
/// picture via a `H264PEncoder` over the shared reference planes and
/// per-macroblock mirror, and the B pictures via the mirror-based direct /
/// bidirectional decision of `h264_encode_b.mbt`. The contract is byte
/// equality with the batch entries (the blackbox tests pin `drain` output
/// against `h264_encode_frames` / `h264_encode_frames_cabac` /
/// `b_slices=true`), so streaming callers get bit-identical streams. The
/// two-pass rate controls (VBV/CBR and the ABR `target_bytes`) need the
/// whole sequence and are rejected at `open`.
pub struct H264StreamEncoder {
  width : Int32
  height : Int32
  qp : Int32
  level_idc : Int32
  cabac : Bool
  b_slices : Bool
  aud : Bool
  aq : Bool
  aq_strength : Int32
  stats : H264EncStats
  /// Derived geometry (macroblock-aligned strides).
  mb_width : Int32
  mb_height : Int32
  ystride : Int32
  cstride : Int32
  pheight : Int32
  priv pps : H264Pps
  /// Cross-picture per-macroblock mirror (nz persistence).
  priv states : Array[H264PMbState]
  /// The most recent reference picture's planes.
  priv mut ref_y : Array[Int32]
  priv mut ref_u : Array[Int32]
  priv mut ref_v : Array[Int32]
  /// The colocated motion history of the most recent reference picture
  /// (`b_slices` only; the next B picture's direct mode samples it).
  priv mut ref_colocated : Array[H264MbInfo]
  /// The FUTURE reference of the pending B picture (`b_slices` only):
  /// `stream_p` parks its reconstruction here so the past stays intact
  /// until the B picture is done.
  priv mut fut_y : Array[Int32]
  priv mut fut_u : Array[Int32]
  priv mut fut_v : Array[Int32]
  /// The frame waiting for its future reference (`b_slices`: the odd
  /// display position stays here until the even one arrives).
  mut pending : (Bytes, Bytes, Bytes)?
  /// Display position of the NEXT pushed frame.
  mut next_display : Int32
  /// frame_num counter of reference pictures (the IDR is 0).
  mut fn_counter : Int32
  /// Finished access units and reconstructions, in coding order.
  out : Array[Bytes]
  recons : Array[Bytes]
  mut frames_out : Int32
}

///|
/// Open a streaming encoder. `b_slices` schedules the odd display
/// positions as B pictures; the two-pass rate controls are batch-only.
pub fn H264StreamEncoder::open(
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  cabac~ : Bool = false,
  b_slices~ : Bool = false,
  aud~ : Bool = false,
  aq~ : Bool = false,
  aq_strength~ : Int32 = 1,
  stats~ : H264EncStats = H264EncStats::new(),
) -> Result[H264StreamEncoder, String] {
  if aq_strength < 0 || aq_strength > 6 {
    return Err("h264 enc: aq_strength must be in 0..=6")
  }
  if width <= 0 ||
    height <= 0 ||
    width % 2 != 0 ||
    height % 2 != 0 ||
    width > 16384 ||
    height > 16384 {
    return Err("h264 enc: invalid geometry \{width}x\{height}")
  }
  if qp < 0 || qp > 51 {
    return Err("h264 enc: qp out of range")
  }
  let p = { width, height, qp, level_idc, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  // Round-trip the parameter sets the pictures will actually carry: the
  // parsed PPS holds the dequantisation tables shared with the decoder.
  let ps = new_h264_param_sets()
  let sps_rbsp = if b_slices {
    h264_enc_sps_rbsp_b(p)
  } else if cabac {
    h264_enc_sps_rbsp_main(p)
  } else {
    h264_enc_sps_rbsp(p)
  }
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_rbsp), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = if cabac {
    h264_enc_pps_rbsp_cabac(p)
  } else {
    h264_enc_pps_rbsp(p)
  }
  match
    ff_h264_decode_picture_parameter_set(
      BitReader::new(pps_raw),
      ps,
      pps_raw.length() * 8,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: PPS round-trip failed: \{e}")
  }
  let pps = match ps.pps_list[0] {
    Some(v) => v
    None => return Err("h264 enc: no PPS after round-trip")
  }
  let states : Array[H264PMbState] = []
  for _k = 0; _k < mb_width * mb_height; _k = _k + 1 {
    states.push(new_h264_p_mb_state())
  }
  Ok({
    width,
    height,
    qp,
    level_idc,
    cabac,
    b_slices,
    aud,
    aq,
    aq_strength,
    stats,
    mb_width,
    mb_height,
    ystride,
    cstride,
    pheight,
    pps,
    states,
    ref_y: [],
    ref_u: [],
    ref_v: [],
    ref_colocated: [],
    fut_y: [],
    fut_u: [],
    fut_v: [],
    pending: None,
    next_display: 0,
    fn_counter: 0,
    out: [],
    recons: [],
    frames_out: 0,
  })
}

///|
/// Plane loader shared by the picture steps: source bytes into an
/// MB-aligned plane (zero padding beyond the visible area).
fn H264StreamEncoder::load_plane(
  self : H264StreamEncoder,
  src : Bytes,
  w : Int32,
  h : Int32,
  stride : Int32,
) -> Array[Int32] {
  let plane : Array[Int32] = Array::make(stride * self.pheight, 0)
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      plane[row * stride + col] = src[row * w + col].to_int()
    }
  }
  plane
}

///|
/// Validate a frame's planes against the opened geometry.
fn H264StreamEncoder::check_frame(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> Result[Unit, String] {
  let luma = self.width * self.height
  let chroma = self.width / 2 * (self.height / 2)
  if y.length() != luma || u.length() != chroma || v.length() != chroma {
    return Err("h264 enc: plane size mismatch")
  }
  Ok(())
}

///|
/// Push the next frame in display order. The produced access units (if
/// any) queue up for `drain`; with `b_slices` off every push after the
/// first yields one access unit, with it on an even display position
/// yields the P-B pair and an odd one just buffers.
pub fn H264StreamEncoder::push_frame(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> Result[Unit, String] {
  match self.check_frame(y, u, v) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let d = self.next_display
  self.next_display = self.next_display + 1
  if d == 0 {
    return self.stream_idr(y, u, v)
  }
  if !self.b_slices {
    return self.stream_p(y, u, v, d)
  }
  if d % 2 == 1 {
    self.pending = Some((y, u, v))
    return Ok(())
  }
  // Even position: the pending B picture's future reference. Code this P
  // picture first, then the B picture against past+future.
  let (by, bu, bv) = match self.pending {
    Some(t) => t
    None => return Err("h264 enc: stream scheduling lost the B picture")
  }
  self.pending = None
  match self.stream_p(y, u, v, d) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.stream_b(by, bu, bv, d - 1)
}

///|
/// Flush: with `b_slices` a trailing odd display position has no future
/// reference and codes as a P picture. Returns the remaining access units.
pub fn H264StreamEncoder::finish(
  self : H264StreamEncoder,
) -> Result[Array[Bytes], String] {
  if self.b_slices {
    match self.pending {
      Some((y, u, v)) => {
        let d = self.next_display - 1
        self.pending = None
        match self.stream_p(y, u, v, d) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      None => ()
    }
  }
  Ok(self.drain())
}

///|
/// Take the finished access units (coding order; decoders reorder to
/// display order via the POC when `b_slices` is on).
pub fn H264StreamEncoder::drain(self : H264StreamEncoder) -> Array[Bytes] {
  let out : Array[Bytes] = []
  for au in self.out {
    out.push(au)
    self.frames_out = self.frames_out + 1
  }
  self.out.clear()
  out
}

///|
/// The first picture: the intra encoder carries the SPS/PPS (and the B
/// schedule's POC type 0). Its reconstruction seeds the reference chain.
fn H264StreamEncoder::stream_idr(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> Result[Unit, String] {
  let first = if self.cabac {
    h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=self.width,
      height=self.height,
      qp=self.qp,
      level_idc=self.level_idc,
      stats=self.stats,
      pps_qp=self.qp,
      aq=self.aq,
      aq_strength=self.aq_strength,
      b_seq=self.b_slices,
    )
  } else {
    h264_encode_intra_frame(
      y,
      u,
      v,
      width=self.width,
      height=self.height,
      qp=self.qp,
      level_idc=self.level_idc,
      stats=self.stats,
      pps_qp=self.qp,
      aq=self.aq,
      aq_strength=self.aq_strength,
      b_seq=self.b_slices,
    )
  }
  let first = match first {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let au = if self.aud {
    h264_enc_concat([h264_enc_aud(true), first.annexb])
  } else {
    first.annexb
  }
  self.out.push(au)
  self.ref_y = h264_b_copy_plane(first.recon_y)
  self.ref_u = h264_b_copy_plane(first.recon_u)
  self.ref_v = h264_b_copy_plane(first.recon_v)
  for k = 0; k < self.mb_width * self.mb_height; k = k + 1 {
    for i = 0; i < 48; i = i + 1 {
      self.states[k].nz[i] = first.mb_nz[k][i]
    }
  }
  Ok(())
}

///|
/// One P picture against the current reference. Identical per-picture
/// construction to the batch entries' loop, so the bytes match.
fn H264StreamEncoder::stream_p(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  display : Int32,
) -> Result[Unit, String] {
  self.fn_counter = self.fn_counter + 1
  let src_y = self.load_plane(y, self.width, self.height, self.ystride)
  let (act, act_avg) = if self.aq {
    h264_aq_measure(src_y, self.ystride, self.mb_width, self.mb_height)
  } else {
    (Array::make(self.mb_width * self.mb_height, 0), 0)
  }
  let enc : H264PEncoder = {
    p: {
      width: self.width,
      height: self.height,
      qp: self.qp,
      level_idc: self.level_idc,
    },
    stats: self.stats,
    pps: self.pps,
    chroma_qp: h264_get_chroma_qp(self.pps, 0, self.qp),
    src_y,
    src_u: self.load_plane(u, self.width / 2, self.height / 2, self.cstride),
    src_v: self.load_plane(v, self.width / 2, self.height / 2, self.cstride),
    rec_y: Array::make(self.ystride * self.pheight, 0),
    rec_u: Array::make(self.cstride * (self.pheight / 2), 0),
    rec_v: Array::make(self.cstride * (self.pheight / 2), 0),
    ref_y: self.ref_y,
    ref_u: self.ref_u,
    ref_v: self.ref_v,
    ystride: self.ystride,
    cstride: self.cstride,
    pwidth: self.ystride,
    pheight: self.pheight,
    mb_width: self.mb_width,
    mb_height: self.mb_height,
    states: self.states,
    cur_nz: Array::make(48, 0),
    cur_mv: Array::make(32, 0),
    cur_ref: Array::make(16, -2),
    dct8x8: false,
    intra4x4_in_p: false,
    base_qp: self.qp,
    mb_qp: self.qp,
    mb_dqp: 0,
    prev_qp: self.qp,
    aq_act: act,
    aq_avg: act_avg,
    aq_on: self.aq,
    aq_strength: self.aq_strength,
    cabac_rd: false,
    price_mirror: None,
    price_enc: None,
    price_states: None,
  }
  let poc_lsb = if self.b_slices { (display * 2) & 15 } else { -1 }
  let nal = if self.cabac {
    match enc.encode_p_frame_cabac(self.fn_counter, false, poc_lsb~) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
  } else {
    match enc.encode_p_frame(self.fn_counter, false, poc_lsb~) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
  }
  let au = if self.aud {
    h264_enc_concat([h264_enc_aud(false), nal])
  } else {
    nal
  }
  self.out.push(au)
  self.recons.push(
    h264_enc_pack_recon(
      enc.rec_y,
      enc.rec_u,
      enc.rec_v,
      self.width,
      self.height,
      self.ystride,
      self.cstride,
    ),
  )
  if self.b_slices {
    // The pending B picture reads the PAST (still in ref_*) and THIS
    // picture as its future; the hand-off happens once the B picture is
    // coded. The colocated history is this picture's motion state.
    self.fut_y = h264_b_copy_plane(enc.rec_y)
    self.fut_u = h264_b_copy_plane(enc.rec_u)
    self.fut_v = h264_b_copy_plane(enc.rec_v)
    self.ref_colocated = h264_b_colocated_from_states(self.states)
  } else {
    self.ref_y = h264_b_copy_plane(enc.rec_y)
    self.ref_u = h264_b_copy_plane(enc.rec_u)
    self.ref_v = h264_b_copy_plane(enc.rec_v)
  }
  Ok(())
}

///|
/// One B picture at an odd display position: past = the reference before
/// the just-coded P (still in `ref_*`), future = the P picture's
/// reconstruction (`fut_*`). The mirror shares the encoder's
/// reconstruction planes (see `h264_encode_b.mbt`); afterwards the future
/// becomes the past of everything that follows.
fn H264StreamEncoder::stream_b(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  display : Int32,
) -> Result[Unit, String] {
  let src_y = self.load_plane(y, self.width, self.height, self.ystride)
  let (act, act_avg) = if self.aq {
    h264_aq_measure(src_y, self.ystride, self.mb_width, self.mb_height)
  } else {
    (Array::make(self.mb_width * self.mb_height, 0), 0)
  }
  let enc : H264PEncoder = {
    p: {
      width: self.width,
      height: self.height,
      qp: self.qp,
      level_idc: self.level_idc,
    },
    stats: self.stats,
    pps: self.pps,
    chroma_qp: h264_get_chroma_qp(self.pps, 0, self.qp),
    src_y,
    src_u: self.load_plane(u, self.width / 2, self.height / 2, self.cstride),
    src_v: self.load_plane(v, self.width / 2, self.height / 2, self.cstride),
    rec_y: Array::make(self.ystride * self.pheight, 0),
    rec_u: Array::make(self.cstride * (self.pheight / 2), 0),
    rec_v: Array::make(self.cstride * (self.pheight / 2), 0),
    ref_y: self.ref_y,
    ref_u: self.ref_u,
    ref_v: self.ref_v,
    ystride: self.ystride,
    cstride: self.cstride,
    pwidth: self.ystride,
    pheight: self.pheight,
    mb_width: self.mb_width,
    mb_height: self.mb_height,
    states: self.states,
    cur_nz: Array::make(48, 0),
    cur_mv: Array::make(32, 0),
    cur_ref: Array::make(16, -2),
    dct8x8: false,
    intra4x4_in_p: false,
    base_qp: self.qp,
    mb_qp: self.qp,
    mb_dqp: 0,
    prev_qp: self.qp,
    aq_act: act,
    aq_avg: act_avg,
    aq_on: self.aq,
    aq_strength: self.aq_strength,
    cabac_rd: false,
    price_mirror: None,
    price_enc: None,
    price_states: None,
  }
  let past_pic = h264_b_refpic(
    self.ref_y,
    self.ref_u,
    self.ref_v,
    self.ystride,
    self.cstride,
    self.pheight,
    (display - 1) * 2,
    0,
  )
  let fut_pic = h264_b_refpic(
    self.fut_y,
    self.fut_u,
    self.fut_v,
    self.ystride,
    self.cstride,
    self.pheight,
    (display + 1) * 2,
    1,
  )
  let mirror = h264_b_mirror_new(
    self.mb_width,
    self.mb_height,
    self.pps,
    self.qp,
    self.ystride,
    self.cstride,
    past_pic,
    fut_pic,
    self.ref_colocated,
    enc.rec_y,
    enc.rec_u,
    enc.rec_v,
    display * 2,
  )
  let nal = if self.cabac {
    match
      enc.encode_b_frame_cabac(
        mirror,
        self.ref_y,
        self.fut_y,
        self.fn_counter,
        (display * 2) & 15,
        self.aq,
      ) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
  } else {
    match
      enc.encode_b_frame(
        mirror,
        self.ref_y,
        self.fut_y,
        self.fn_counter,
        (display * 2) & 15,
        self.aq,
      ) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
  }
  let au = if self.aud { h264_enc_concat([h264_enc_aud_b(), nal]) } else { nal }
  self.out.push(au)
  self.recons.push(
    h264_enc_pack_recon(
      enc.rec_y,
      enc.rec_u,
      enc.rec_v,
      self.width,
      self.height,
      self.ystride,
      self.cstride,
    ),
  )
  // The B picture is non-reference: the future P becomes the past now.
  self.ref_y = self.fut_y
  self.ref_u = self.fut_u
  self.ref_v = self.fut_v
  Ok(())
}
