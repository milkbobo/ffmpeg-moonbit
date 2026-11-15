///|
/// Streaming H.264 sequence encoder (`§394`): frames arrive one at a time
/// in display order, access units come out as soon as their references are
/// complete — an I picture with its parameter sets on the first frame, a P
/// access unit per following frame (`b_slices` off), or the P-then-B pair
/// of the `I, P2, B1, P4, B3, ...` schedule (`b_slices` on, the B picture
/// waits for its future reference). The encoder keeps only the pending
/// frame, the reference chain and the per-macroblock mirror: pushing a
/// frame releases the previous pending one. The raw input/reference working
/// set is bounded; the existing reconstruction history is retained.
///
/// The picture encoders are the batch entries' own: the intra picture via
/// `h264_encode_intra_frame` / `h264_encode_intra_frame_cabac`, every P
/// picture via a `H264PEncoder` over the shared reference planes and
/// per-macroblock mirror, and the B pictures via the mirror-based direct /
/// bidirectional decision of `h264_encode_b.mbt`. Without VBV the contract is byte
/// equality with the batch entries (the blackbox tests pin `drain` output
/// against `h264_encode_frames` / `h264_encode_frames_cabac` /
/// `b_slices=true`), so streaming callers get bit-identical streams. The
/// online VBV/CBR path commits a P picture, a P/B pair, or a tail-P/IDR
/// group transactionally. B pictures wait for one future input picture.
/// ABR `target_bytes` remains a batch-entry feature.
pub struct H264StreamEncoder {
  width : Int32
  height : Int32
  qp : Int32
  level_idc : Int32
  cabac : Bool
  cabac_rd : Bool
  dct8x8 : Bool
  b_slices : Bool
  b_parts : Bool
  intra_in_b : Bool
  intra4x4_in_b : Bool
  /// Opt-in explicit weighted prediction for the P pictures (`§410`).
  weightp : Bool
  /// `§412`/`§419`: luma/chroma bit depth (8 / 9 / 10 / 12 / 14).
  bit_depth : Int32
  /// `§420`: chroma format 1 (4:2:0) or 2 (4:2:2).
  chroma_format : Int32
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
  /// `§415` multi-reference history, newest first (`refs_y[0] == ref_y`).
  /// With `b_slices` the cap grows by one slot: the B picture's future P
  /// parks at the head, and its list 0 is `refs_[1..]` — the past pictures
  /// only. P searches still cap at `nrefs`.
  priv mut refs_y : Array[Array[Int32]]
  priv mut refs_u : Array[Array[Int32]]
  priv mut refs_v : Array[Array[Int32]]
  priv nrefs : Int32
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
  /// Global display position of the current GOP's IDR.
  priv mut gop_start : Int32
  /// frame_num counter of reference pictures (the IDR is 0).
  mut fn_counter : Int32
  /// Finished access units and reconstructions, in coding order.
  out : Array[Bytes]
  recons : Array[Bytes]
  mut frames_out : Int32
  priv vbv : H264Vbv?
  priv mut vbv_fullness : Int32
  priv mut vbv_last_bp : Int32
  priv mut vbv_coded : Int32
}

///|
/// The reference history's entry cap: `nrefs` for P-only streams, one
/// more with `b_slices` (the B picture's future P parks at the head while
/// its list 0 reads `refs_[1..]`), never above 16 (the `max_num_ref_frames`
/// syntax limit).
fn H264StreamEncoder::ref_history_cap(self : H264StreamEncoder) -> Int32 {
  if self.b_slices {
    (self.nrefs + 1).min(16)
  } else {
    self.nrefs
  }
}

///|
/// Open a streaming encoder. `b_slices` schedules the odd display
/// positions as B pictures. Online VBV supports both P and B schedules and keeps
/// the usual frame-QP/reconstruction history. Without VBV, bytes stay equal
/// to the original flat-QP path.
/// `cabac_rd` enables the batch encoder's exact CABAC candidate pricing;
/// it requires `cabac=true` and supports P and B pictures. `dct8x8` selects
/// the High profile 8x8 transform (I8x8, inter 8x8 and, with `b_slices`,
/// Intra 8x8 inside the B slices). `b_parts`
/// enables the sub-partitioned B kinds (16x8/8x16 and B_8x8); it requires
/// `b_slices`. `intra_in_b` enables Intra16x16 macroblocks inside the B
/// slices (scene cuts), `intra4x4_in_b` the Intra_NxN (4x4) form; both
/// also require `b_slices`.
pub fn H264StreamEncoder::open(
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  cabac~ : Bool = false,
  /// Default on (`§403`); requires `cabac`. Pass `cabac_rd~=false` for
  /// CAVLC-priced decisions.
  cabac_rd~ : Bool = true,
  /// Default on (`§403`). Pass `dct8x8~=false` for 4x4-only streams.
  dct8x8~ : Bool = true,
  /// Default on (`§403`); needs at least 2 frames per sequence.
  b_slices~ : Bool = true,
  /// Default on (`§403`); requires `b_slices`.
  b_parts~ : Bool = true,
  /// Default on (`§403`); requires `b_slices`.
  intra_in_b~ : Bool = true,
  /// Default on (`§403`); requires `b_slices`.
  intra4x4_in_b~ : Bool = true,
  /// Explicit weighted prediction for the P pictures — a fitted
  /// `pred_weight_table()` per picture, applied to every inter prediction.
  /// Opt-in in `§410`; default on since `§413` (`weightp=false` restores
  /// the unweighted headers).
  weightp~ : Bool = true,
  /// `§412`/`§419`: 8 (default), 9, 10, 12 or 14 bits; above 8 the pushed frames are
  /// `yuv420p10le` planes and the SPS is High 10 (profile_idc 110).
  bit_depth~ : Int32 = 8,
  /// `§415`: P-slice multi-reference history depth (1 = single reference).
  /// With `b_slices` the depth applies to list 0 of the B pictures too
  /// (their future P occupies one history slot, so a B sees `multi_ref`
  /// past references when the history is full — one less than the P
  /// pictures' `multi_ref` plus the single future reference).
  multi_ref~ : Int32 = 1,
  aud~ : Bool = false,
  aq~ : Bool = false,
  aq_strength~ : Int32 = 1,
  stats~ : H264EncStats = H264EncStats::new(),
  /// `§420`: chroma format, 1 (4:2:0, default) or 2 (4:2:2).
  chroma_format~ : Int32 = 1,
  /// Online VBV. Rejected emitting pushes leave encoder state intact;
  /// an odd B input is buffered until its future P arrives or finish.
  vbv_maxrate~ : Int32 = 0,
  vbv_bufsize~ : Int32 = 0,
  fps~ : Int32 = 0,
  vbv_init~ : Int32 = 90,
) -> Result[H264StreamEncoder, String] {
  if vbv_maxrate < 0 || vbv_bufsize < 0 || fps < 0 {
    return Err("h264 enc: streaming VBV parameters must be nonnegative")
  }
  let vbv = if vbv_maxrate > 0 || vbv_bufsize > 0 || fps > 0 {
    let v = match h264_vbv_new(vbv_maxrate, vbv_bufsize, fps, vbv_init) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let rate = (v.bit_rate_value_minus1 + 1) << 6
    if v.init_delay < 1 ||
      v.bufsize.to_int64() * 90000L / rate.to_int64() > 0xFFFFFFL {
      return Err("h264 enc: streaming VBV delay outside 24-bit HRD range")
    }
    Some(v)
  } else {
    None
  }
  // `cabac_rd` defaults on (`§403`) and is meaningless without CABAC, so
  // it silently no-ops instead of erroring; `cabac~` stays authoritative.
  let cabac_rd = cabac_rd && cabac
  // §405: the sub-flags default on together with `b_slices`; with the
  // slices off they degrade silently (the batch entries ignore them the
  // same way) instead of erroring.
  let b_parts = b_parts && b_slices
  let intra_in_b = intra_in_b && b_slices
  let intra4x4_in_b = intra4x4_in_b && b_slices
  if aq_strength < 0 || aq_strength > 6 {
    return Err("h264 enc: aq_strength must be in 0..=6")
  }
  if multi_ref < 1 || multi_ref > 16 {
    return Err("h264 enc: multi_ref must be in 1..=16")
  }
  if chroma_format != 1 && chroma_format != 2 {
    return Err("h264 enc: chroma_format must be 1 or 2")
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
  let p = { width, height, qp, level_idc, bit_depth, nrefs: multi_ref, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  // Round-trip the parameter sets the pictures will actually carry: the
  // parsed PPS holds the dequantisation tables shared with the decoder.
  let ps = new_h264_param_sets()
  let sps_rbsp = if b_slices {
    h264_enc_sps_rbsp_b(p, dct8x8~, chroma_format~)
  } else if cabac {
    if dct8x8 || p.bit_depth > 8 || chroma_format > 1 {
      h264_enc_sps_rbsp_high(p, chroma_format~)
    } else {
      h264_enc_sps_rbsp_main(p)
    }
  } else {
    h264_enc_sps_rbsp(p, dct8x8~, chroma_format~)
  }
  match ff_h264_decode_seq_parameter_set(BitReader::new(sps_rbsp), ps, false) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  // `§410`: the PPS carries `weighted_pred_flag`, so the streaming encoder
  // must hand the same flag to the PPS builder that its P slices use — a
  // table on the wire with `weighted_pred_flag = 0` would decode unweighted.
  let pps_raw = if cabac {
    h264_enc_pps_rbsp_cabac(p, dct8x8~, weightp~, chroma_format~)
  } else {
    h264_enc_pps_rbsp(p, dct8x8~, weightp~, chroma_format~)
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
    cabac_rd,
    dct8x8,
    b_slices,
    b_parts,
    intra_in_b,
    intra4x4_in_b,
    weightp,
    bit_depth,
    chroma_format,
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
    refs_y: [],
    refs_u: [],
    refs_v: [],
    nrefs: multi_ref,
    ref_colocated: [],
    fut_y: [],
    fut_u: [],
    fut_v: [],
    pending: None,
    next_display: 0,
    gop_start: 0,
    fn_counter: 0,
    out: [],
    recons: [],
    frames_out: 0,
    vbv,
    vbv_fullness: match vbv {
      Some(v) => v.init_bits
      None => 0
    },
    vbv_last_bp: 0,
    vbv_coded: 0,
  })
}

///|
/// Plane loader shared by the picture steps: source bytes into an
/// MB-aligned plane (zero padding beyond the visible area). Delegates to
/// `h264_enc_load_plane` so 16-bit input decodes exactly like the batch
/// entries (`§412`).
fn H264StreamEncoder::load_plane(
  self : H264StreamEncoder,
  src : Bytes,
  w : Int32,
  h : Int32,
  stride : Int32,
) -> Array[Int32] {
  h264_enc_load_plane(src, w, h, stride, self.pheight, bit_depth=self.bit_depth)
}

///|
/// Chroma plane loader: rows = `pheight` at 4:2:2, `pheight / 2` at 4:2:0.
fn H264StreamEncoder::load_chroma_plane(
  self : H264StreamEncoder,
  src : Bytes,
  w : Int32,
  h : Int32,
  stride : Int32,
) -> Array[Int32] {
  let rows = self.chroma_plane_rows()
  h264_enc_load_plane(src, w, h, stride, rows, bit_depth=self.bit_depth)
}

///|
/// The chroma plane's row count (drives every reference/rec allocation and
/// the packed recon layout).
fn H264StreamEncoder::chroma_plane_rows(self : H264StreamEncoder) -> Int32 {
  if self.chroma_format == 2 {
    self.pheight
  } else {
    self.pheight / 2
  }
}

///|
/// Validate a frame's planes against the opened geometry.
fn H264StreamEncoder::check_frame(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> Result[Unit, String] {
  let plane_bytes = h264_enc_plane_bytes(
    self.width,
    self.height,
    self.bit_depth,
  )
  let chroma_bytes = h264_enc_plane_bytes(
    self.width / 2,
    self.chroma_plane_rows(),
    self.bit_depth,
  )
  if y.length() != plane_bytes ||
    u.length() != chroma_bytes ||
    v.length() != chroma_bytes {
    return Err("h264 enc: plane size mismatch")
  }
  Ok(())
}

///|
/// Push the next frame in display order. The produced access units (if
/// any) queue up for `drain`; with `b_slices` off every push after the
/// first yields one access unit, with it on an even display position
/// yields the P-B pair and an odd one just buffers.
/// `force_idr=true` starts an independent GOP with repeated SPS/PPS and
/// clears reference history. A pending B picture is first coded as a P
/// picture against the old GOP, just like a sequence tail.
pub fn H264StreamEncoder::push_frame(
  self : H264StreamEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  force_idr~ : Bool = false,
) -> Result[Unit, String] {
  match self.check_frame(y, u, v) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match self.vbv {
    Some(vbv) => return self.push_vbv(y, u, v, vbv, force_idr~)
    None => ()
  }
  let d = self.next_display - self.gop_start
  if force_idr {
    match self.flush_pending() {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  self.next_display = self.next_display + 1
  if d == 0 || force_idr {
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
  if self.vbv is Some(v) && self.pending is Some(_) {
    let trial = self.vbv_trial()
    match trial.vbv_flush_pending(v) {
      Ok(_) => self.vbv_commit(trial)
      Err(e) => return Err(e)
    }
    return Ok(self.drain())
  }
  match self.flush_pending() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok(self.drain())
}

///|
/// Close an incomplete B pair before end-of-stream or a new IDR. Do this
/// before advancing next_display so the old picture retains its local POC.
fn H264StreamEncoder::flush_pending(
  self : H264StreamEncoder,
) -> Result[Unit, String] {
  match self.pending {
    Some((y, u, v)) =>
      match self.stream_p(y, u, v, self.next_display - self.gop_start - 1) {
        Ok(_) => self.pending = None
        Err(e) => return Err(e)
      }
    None => ()
  }
  Ok(())
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
  qp~ : Int32 = self.qp,
  vbv~ : H264Vbv? = None,
  idr_cpb_delay~ : Int32 = 0,
) -> Result[Unit, String] {
  let first = if self.cabac {
    h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=self.width,
      height=self.height,
      qp~,
      level_idc=self.level_idc,
      stats=self.stats,
      pps_qp=self.qp,
      aq=self.aq,
      aq_strength=self.aq_strength,
      b_seq=self.b_slices,
      dct8x8=self.dct8x8,
      weightp=self.weightp,
      bit_depth=self.bit_depth,
      chroma_format=self.chroma_format,
      multi_ref=self.nrefs,
      vbv~,
      idr_cpb_delay~,
    )
  } else {
    h264_encode_intra_frame(
      y,
      u,
      v,
      width=self.width,
      height=self.height,
      qp~,
      level_idc=self.level_idc,
      stats=self.stats,
      pps_qp=self.qp,
      aq=self.aq,
      aq_strength=self.aq_strength,
      b_seq=self.b_slices,
      dct8x8=self.dct8x8,
      weightp=self.weightp,
      bit_depth=self.bit_depth,
      multi_ref=self.nrefs,
      chroma_format=self.chroma_format,
      vbv~,
      idr_cpb_delay~,
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
  // `§415` multi-reference history: newest first, seeded with the I
  // frame's reconstruction.
  self.refs_y = [self.ref_y]
  self.refs_u = [self.ref_u]
  self.refs_v = [self.ref_v]
  for k = 0; k < self.mb_width * self.mb_height; k = k + 1 {
    self.states[k] = new_h264_p_mb_state()
    for i = 0; i < 48; i = i + 1 {
      self.states[k].nz[i] = first.mb_nz[k][i]
    }
  }
  self.fn_counter = 0
  self.gop_start = self.next_display - 1
  self.ref_colocated = []
  self.fut_y = []
  self.fut_u = []
  self.fut_v = []
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
  qp~ : Int32 = self.qp,
  vbv~ : H264Vbv? = None,
  cpb_delay~ : Int32 = display * 2,
  dpb_delay~ : Int32 = 0,
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
      qp,
      level_idc: self.level_idc,
      bit_depth: self.bit_depth,
      nrefs: self.nrefs,
    },
    stats: self.stats,
    pps: self.pps,
    // `§412`: `get_chroma_qp` consumes the extended quantiser QP.
    chroma_qp: h264_get_chroma_qp(
      self.pps,
      0,
      h264_enc_qp_ext(qp, self.bit_depth),
      bit_depth=self.bit_depth,
    ),
    src_y,
    src_u: self.load_chroma_plane(
      u,
      self.width / 2,
      self.chroma_plane_rows(),
      self.cstride,
    ),
    src_v: self.load_chroma_plane(
      v,
      self.width / 2,
      self.chroma_plane_rows(),
      self.cstride,
    ),
    rec_y: Array::make(self.ystride * self.pheight, 0),
    rec_u: Array::make(self.cstride * self.chroma_plane_rows(), 0),
    rec_v: Array::make(self.cstride * self.chroma_plane_rows(), 0),
    ref_y: self.ref_y,
    ref_u: self.ref_u,
    ref_v: self.ref_v,
    refs_y: self.refs_y,
    refs_u: self.refs_u,
    refs_v: self.refs_v,
    // The P search caps at the configured depth even when the B schedule
    // keeps one extra history slot (the pending B's future reference).
    nrefs: self.refs_y.length().min(self.nrefs),
    cur_ref_mb: 0,
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
    dct8x8: self.dct8x8,
    intra4x4_in_p: false,
    base_qp: self.qp,
    mb_qp: qp,
    mb_dqp: 0,
    prev_qp: qp,
    aq_act: act,
    aq_avg: act_avg,
    aq_on: self.aq,
    aq_strength: self.aq_strength,
    cabac_rd: self.cabac_rd,
    price_mirror: None,
    price_enc: None,
    price_states: None,
    b_parts: self.b_parts,
    intra_in_b: self.intra_in_b,
    intra4x4_in_b: self.intra4x4_in_b,
    weightp: self.weightp,
    pwt: new_h264_pred_weight(),
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
  let au : Array[Bytes] = []
  if self.aud {
    au.push(h264_enc_aud(false))
  }
  match vbv {
    Some(v) =>
      au.push(h264_enc_sei_pic_timing(v, cpb_delay, dpb_output_delay=dpb_delay))
    None => ()
  }
  au.push(nal)
  self.out.push(h264_enc_concat(au))
  self.recons.push(
    h264_enc_pack_recon(
      enc.rec_y,
      enc.rec_u,
      enc.rec_v,
      self.width,
      self.height,
      self.ystride,
      self.cstride,
      bit_depth=self.bit_depth,
      chroma_h=self.chroma_plane_rows(),
    ),
  )
  // `§415`: every coded picture enters the reference history (newest
  // first) — the P decoder loop resets `ref_y = refs_y[0]` per macroblock,
  // so the list must always lead with the newest reconstruction in every
  // scheduling mode. With B slices the P picture ALSO becomes the pending
  // B picture's future; `ref_*` keeps the past until the B hand-off, and
  // the history keeps one extra slot (`ref_history_cap`) so the B's list 0
  // (`refs_[1..]`) still holds `nrefs` past pictures.
  let ny = h264_b_copy_plane(enc.rec_y)
  let nu = h264_b_copy_plane(enc.rec_u)
  let nv = h264_b_copy_plane(enc.rec_v)
  self.refs_y.insert(0, ny)
  self.refs_u.insert(0, nu)
  self.refs_v.insert(0, nv)
  let cap = self.ref_history_cap()
  if self.refs_y.length() > cap {
    self.refs_y.truncate(cap)
    self.refs_u.truncate(cap)
    self.refs_v.truncate(cap)
  }
  if self.b_slices {
    // The pending B picture reads the PAST (still in ref_*) and THIS
    // picture as its future; the hand-off happens once the B picture is
    // coded. The colocated history is this picture's motion state.
    self.fut_y = ny
    self.fut_u = nu
    self.fut_v = nv
    self.ref_colocated = h264_b_colocated_from_states(self.states)
  } else {
    self.ref_y = ny
    self.ref_u = nu
    self.ref_v = nv
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
  qp~ : Int32 = self.qp,
  vbv~ : H264Vbv? = None,
  cpb_delay~ : Int32 = display * 2,
  dpb_delay~ : Int32 = 0,
) -> Result[Unit, String] {
  let src_y = self.load_plane(y, self.width, self.height, self.ystride)
  let (act, act_avg) = if self.aq {
    h264_aq_measure(src_y, self.ystride, self.mb_width, self.mb_height)
  } else {
    (Array::make(self.mb_width * self.mb_height, 0), 0)
  }
  // The B picture's list 0: the reference history minus its head — the
  // just-coded future P parks at `refs_[0]` (the `b_slices` history keeps
  // one extra slot for exactly this), the past pictures follow newest
  // first. One past entry reproduces the single-reference streams'
  // reference bit for bit.
  let past_y : Array[Array[Int32]] = []
  let past_u : Array[Array[Int32]] = []
  let past_v : Array[Array[Int32]] = []
  let pasts : Array[H264RefPic] = []
  for i in 1..<self.refs_y.length() {
    let j = i - 1
    past_y.push(self.refs_y[i])
    past_u.push(self.refs_u[i])
    past_v.push(self.refs_v[i])
    pasts.push(
      h264_b_refpic(
        self.refs_y[i],
        self.refs_u[i],
        self.refs_v[i],
        self.ystride,
        self.cstride,
        self.pheight,
        (display - 1 - j * 2) * 2,
        j,
        chroma_h=self.chroma_plane_rows(),
      ),
    )
  }
  if pasts.is_empty() {
    return Err("h264 enc: stream scheduling lost the past reference")
  }
  let enc : H264PEncoder = {
    p: {
      width: self.width,
      height: self.height,
      qp,
      level_idc: self.level_idc,
      bit_depth: self.bit_depth,
      nrefs: self.nrefs,
    },
    stats: self.stats,
    pps: self.pps,
    // `§412`: `get_chroma_qp` consumes the extended quantiser QP.
    chroma_qp: h264_get_chroma_qp(
      self.pps,
      0,
      h264_enc_qp_ext(qp, self.bit_depth),
      bit_depth=self.bit_depth,
    ),
    src_y,
    src_u: self.load_chroma_plane(
      u,
      self.width / 2,
      self.chroma_plane_rows(),
      self.cstride,
    ),
    src_v: self.load_chroma_plane(
      v,
      self.width / 2,
      self.chroma_plane_rows(),
      self.cstride,
    ),
    rec_y: Array::make(self.ystride * self.pheight, 0),
    rec_u: Array::make(self.cstride * self.chroma_plane_rows(), 0),
    rec_v: Array::make(self.cstride * self.chroma_plane_rows(), 0),
    ref_y: self.ref_y,
    ref_u: self.ref_u,
    ref_v: self.ref_v,
    refs_y: past_y,
    refs_u: past_u,
    refs_v: past_v,
    nrefs: past_y.length(),
    cur_ref_mb: 0,
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
    dct8x8: self.dct8x8,
    intra4x4_in_p: false,
    base_qp: self.qp,
    mb_qp: qp,
    mb_dqp: 0,
    prev_qp: qp,
    aq_act: act,
    aq_avg: act_avg,
    aq_on: self.aq,
    aq_strength: self.aq_strength,
    cabac_rd: self.cabac_rd,
    price_mirror: None,
    price_enc: None,
    price_states: None,
    b_parts: self.b_parts,
    intra_in_b: self.intra_in_b,
    intra4x4_in_b: self.intra4x4_in_b,
    weightp: false,
    pwt: new_h264_pred_weight(),
  }
  let fut_pic = h264_b_refpic(
    self.fut_y,
    self.fut_u,
    self.fut_v,
    self.ystride,
    self.cstride,
    self.pheight,
    (display + 1) * 2,
    1,
    chroma_h=self.chroma_plane_rows(),
  )
  let mirror = h264_b_mirror_new(
    self.mb_width,
    self.mb_height,
    self.pps,
    // `§412`: the mirror's `qscale` indexes the extended-range tables.
    h264_enc_qp_ext(qp, self.bit_depth),
    self.ystride,
    self.cstride,
    pasts,
    fut_pic,
    self.ref_colocated,
    enc.rec_y,
    enc.rec_u,
    enc.rec_v,
    display * 2,
    bit_depth=self.bit_depth,
    chroma_format=self.pps.chroma_format,
  )
  let nal = if self.cabac {
    match
      enc.encode_b_frame_cabac(
        mirror,
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
        self.fut_y,
        self.fn_counter,
        (display * 2) & 15,
        self.aq,
      ) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
  }
  let au : Array[Bytes] = []
  if self.aud {
    au.push(h264_enc_aud_b())
  }
  match vbv {
    Some(v) =>
      au.push(h264_enc_sei_pic_timing(v, cpb_delay, dpb_output_delay=dpb_delay))
    None => ()
  }
  au.push(nal)
  self.out.push(h264_enc_concat(au))
  self.recons.push(
    h264_enc_pack_recon(
      enc.rec_y,
      enc.rec_u,
      enc.rec_v,
      self.width,
      self.height,
      self.ystride,
      self.cstride,
      bit_depth=self.bit_depth,
      chroma_h=self.chroma_plane_rows(),
    ),
  )
  // The B picture is non-reference: the future P becomes the past now.
  self.ref_y = self.fut_y
  self.ref_u = self.fut_u
  self.ref_v = self.fut_v
  Ok(())
}
