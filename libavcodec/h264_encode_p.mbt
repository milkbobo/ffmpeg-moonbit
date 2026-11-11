///|
/// Pure-MoonBit H.264 P-frame encoder, slice 2 of the port: P_Skip and
/// P_L0_16x16 macroblocks (CAVLC, Baseline 4:2:0 8-bit, flat QP, one
/// reference = the previous frame's reconstruction). The same mirroring
/// discipline as the intra slice: the motion-vector predictor replicates
/// `h264_pred_motion` / `h264_mv_fetch` / `h264_pred_pskip_motion` on a
/// per-MB mirror state, motion compensation calls the decoder's own
/// `h264_mc_luma` / `h264_mc_chroma`, the residual chain reuses the CAVLC
/// writer with the inter dequant matrices (3/4/5), and reconstruction
/// follows `h264_recon_inter_mb` — so the local reconstruction is, by
/// construction, what the decoder produces.

///|
/// Motion state mirror of one macroblock (`info.mv` / `info.ref_idx`).
priv struct H264PMbState {
  /// Quarter-pel MVs per 4x4 raster block (x = 2*i, y = 2*i+1).
  mv : Array[Int32]
  /// L0 reference per 4x4 block: -1 intra, -2 unavailable.
  ref_idx : Array[Int32]
  mut intra : Bool
  mut has_data : Bool
  nz : Array[Int32]
  /// Intra_NxN mirror for the neighbours' prediction-mode predictor (the
  /// decoder's `info.intra4x4` + `info.modes`): true only for an I8x8
  /// macroblock of this picture, with its modes 2x2-replicated on the 4x4
  /// grid.
  mut intra_nxn : Bool
  modes : Array[Int32]
}

///|
fn new_h264_p_mb_state() -> H264PMbState {
  {
    mv: Array::make(32, 0),
    ref_idx: Array::make(16, -2),
    intra: false,
    has_data: false,
    nz: Array::make(48, 0),
    intra_nxn: false,
    modes: Array::make(16, 0),
  }
}

///|
/// Per-sequence mode-decision counters. Pass one through `stats=` to the
/// public entry points when a test must prove a syntax branch was really
/// exercised: a decodable stream alone cannot distinguish an intra-coded P
/// macroblock from a cheap inter one.
pub(all) struct H264EncStats {
  mut i16_mbs : Int32
  /// Macroblocks coded with the 8x8 transform (I8x8 and inter 8x8).
  mut i8_mbs : Int32
  /// Intra 8x8 macroblocks inside P slices (a subset of `i8_mbs`).
  mut i8p_mbs : Int32
  /// Intra 4x4 macroblocks inside P slices (`intra4x4_in_p`).
  mut i4p_mbs : Int32
  mut coded_mbs : Int32
  /// The QP every picture was coded with, in coding order (constant in the
  /// flat-QP mode, the rate control's choice under `target_bytes`).
  frame_qps : Array[Int32]
  /// Macroblocks whose `mb_qp_delta` is non-zero (adaptive quantisation).
  mut dqp_mbs : Int32
  /// Access units that received at least one filler-data NAL (VBV/CBR).
  mut vbv_fills : Int32
  /// Total bits emitted under VBV/CBR, including parameter sets, SEI and
  /// filler (the CPB's actual traffic).
  mut vbv_bits : Int64
  /// Total bytes of filler NAL units, Annex B start code and NAL header
  /// included (0 when the stream is already dense enough).
  mut vbv_filler_bytes : Int32
  /// B macroblocks coded this sequence (skip, direct, L1, Bi and L0).
  mut b_mbs : Int32
  /// B macroblocks that chose the bidirectional partition.
  mut bi_mbs : Int32
  /// B macroblocks that chose the future-only (L1) partition.
  mut bl1_mbs : Int32
  /// B macroblocks coded as B_Direct_16x16 (with residual; skips count
  /// into `b_mbs` only).
  mut bdirect_mbs : Int32
}

///|
pub fn H264EncStats::new() -> H264EncStats {
  {
    i16_mbs: 0,
    i8_mbs: 0,
    i8p_mbs: 0,
    i4p_mbs: 0,
    coded_mbs: 0,
    frame_qps: [],
    dqp_mbs: 0,
    vbv_fills: 0,
    vbv_bits: 0L,
    vbv_filler_bytes: 0,
    b_mbs: 0,
    bi_mbs: 0,
    bl1_mbs: 0,
    bdirect_mbs: 0,
  }
}

///|
priv struct H264PEncoder {
  p : H264EncParams
  /// Shared decision counters (CAVLC and CABAC entries both feed these).
  stats : H264EncStats
  pps : H264Pps
  mut chroma_qp : Int32
  /// Source planes of the frame being encoded (mb-aligned strides).
  src_y : Array[Int32]
  src_u : Array[Int32]
  src_v : Array[Int32]
  /// Reconstruction planes (become the next reference).
  rec_y : Array[Int32]
  rec_u : Array[Int32]
  rec_v : Array[Int32]
  /// Reference planes (previous frame's reconstruction).
  ref_y : Array[Int32]
  ref_u : Array[Int32]
  ref_v : Array[Int32]
  ystride : Int32
  cstride : Int32
  pwidth : Int32
  pheight : Int32
  mb_width : Int32
  mb_height : Int32
  states : Array[H264PMbState]
  /// Current MB's mirror (mv/ref/nz) while coding.
  cur_nz : Array[Int32]
  /// Progressive per-4x4 mirror while coding one macroblock (the decoder's
  /// `write_back_part` timing: later partitions' predictors see earlier
  /// partitions' MVs).
  cur_mv : Array[Int32]
  cur_ref : Array[Int32]
  /// Opt-in High-profile transform_8x8 for the luma residual of inter
  /// macroblocks whose partitions are all at least 8x8.
  dct8x8 : Bool
  /// Opt-in Intra4x4 fallback in P slices (independent of `intra_in_p`'s
  /// I16x16/I8x8): the finest intra granularity for detailed textures.
  intra4x4_in_p : Bool
  /// The sequence's base QP (`pic_init_qp` of the single PPS). `p.qp` is
  /// this picture's own QP; the slice header codes the difference.
  base_qp : Int32
  /// This macroblock's QP and its `mb_qp_delta` against the decoder's
  /// running QP (adaptive quantisation; both stay at the slice QP with AQ
  /// off, so the flat path is byte-identical).
  mut mb_qp : Int32
  mut mb_dqp : Int32
  /// The decoder's running QP: only a written `mb_qp_delta` advances it
  /// (skip / cbp-zero macroblocks leave it untouched).
  mut prev_qp : Int32
  /// Per-MB luma activity and the picture average (`aq_on` false: unused).
  aq_act : Array[Int32]
  aq_avg : Int32
  aq_on : Bool
  aq_strength : Int32
  /// Opt-in CABAC bit pricing for the rate-distortion decision (`§392`).
  /// When set, the CABAC frame encoder publishes its mirror/engine/states
  /// here and `eval_plan` prices every candidate through the real CABAC
  /// syntax writer (snapshot/rollback around each candidate) instead of the
  /// CAVLC dry run. The three stay None on the CAVLC path and on the
  /// default CABAC path, so every pinned stream is unchanged.
  cabac_rd : Bool
  mut price_mirror : H264DecCtx?
  mut price_enc : H264CabacEnc?
  mut price_states : Array[Int32]?
}

///|
/// Pack encoder-side reconstruction planes in `H264Frame::yuvp()` order so
/// blackbox tests can diff them against the decoder's unfiltered output.
/// Shared by the CAVLC and CABAC sequence entries.
fn h264_enc_pack_recon(
  y : Array[Int32],
  u : Array[Int32],
  v : Array[Int32],
  w : Int32,
  h : Int32,
  ys : Int32,
  cs : Int32,
) -> Bytes {
  let out : Array[Byte] = []
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      out.push(y[row * ys + col].to_byte())
    }
  }
  for plane = 0; plane < 2; plane = plane + 1 {
    let src = if plane == 0 { u } else { v }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        out.push(src[row * cs + col].to_byte())
      }
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Encode a frame sequence: the first frame as IDR I (the intra encoder),
/// every following frame as a P picture referencing the previous frame's
/// reconstruction. Returns the Annex B stream.
/// `aud=true` emits a six-byte access unit delimiter before each picture,
/// including before the first SPS/PPS. Its cost is included in ABR and VBV.
/// `aq_strength` (0..6, default 1) controls AQ's +/- QP adjustment when
/// `aq=true`. Zero strength is byte-equivalent to disabling AQ.
pub fn h264_encode_frames(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  level_idc~ : Int32 = 30,
  pcm_first~ : Bool = false,
  intra_in_p~ : Bool = false,
  intra4x4_in_p~ : Bool = false,
  dct8x8~ : Bool = false,
  aq~ : Bool = false,
  aq_strength~ : Int32 = 1,
  aud~ : Bool = false,
  /// Opt-in (`§393`): code the odd display positions as B pictures
  /// (I, P2, B1, P4, B3, ... with POC type 0 reordering). Mutually
  /// exclusive with the rate controls and `dct8x8`.
  b_slices~ : Bool = false,
  target_bytes~ : Int32 = 0,
  vbv_maxrate~ : Int32 = 0,
  vbv_bufsize~ : Int32 = 0,
  fps~ : Int32 = 0,
  vbv_init~ : Int32 = 90,
  recon~ : Array[Bytes] = [],
  stats~ : H264EncStats = H264EncStats::new(),
) -> Result[Bytes, String] {
  if aq_strength < 0 || aq_strength > 6 {
    return Err("h264 enc: aq_strength must be in 0..=6")
  }
  if frames.length() == 0 {
    return Err("h264 enc: no frames")
  }
  if b_slices {
    if target_bytes > 0 || vbv_maxrate > 0 || vbv_bufsize > 0 || fps > 0 {
      return Err("h264 enc: b_slices and the rate controls are exclusive")
    }
    if dct8x8 {
      return Err("h264 enc: b_slices does not support dct8x8")
    }
    if frames.length() < 2 {
      return Err("h264 enc: b_slices needs at least 2 frames")
    }
    return h264_encode_frames_b(
      frames,
      width~,
      height~,
      qp~,
      level_idc~,
      aq~,
      aq_strength~,
      aud~,
      cabac=false,
      recon~,
      stats~,
    )
  }
  let n = frames.length()
  // VBV/CBR is opt-in: any of the three parameters turns it on, and the
  // two rate-control modes cannot be combined (ABR has no local buffer
  // notion, VBV assigns QPs while encoding).
  let vbv = if vbv_maxrate > 0 || vbv_bufsize > 0 || fps > 0 {
    if target_bytes > 0 {
      return Err("h264 enc: target_bytes and vbv are mutually exclusive")
    }
    match h264_vbv_new(vbv_maxrate, vbv_bufsize, fps, vbv_init) {
      Ok(v) => Some(v)
      Err(e) => return Err(e)
    }
  } else {
    None
  }
  match vbv {
    Some(v) =>
      return h264_encode_frames_vbv(
        frames,
        width~,
        height~,
        qp~,
        level_idc~,
        pcm_first~,
        intra_in_p~,
        intra4x4_in_p~,
        dct8x8~,
        aq~,
        aq_strength~,
        aud~,
        vbv=v,
        recon~,
        stats~,
      )
    None => ()
  }
  // `target_bytes > 0` turns on the two-pass average-bitrate control: `qp`
  // then is the search's starting point and the PPS base QP, and every
  // picture's own QP travels in its slice header. Off, every picture codes
  // at `qp` and the stream is byte-identical to the flat-QP encoder.
  let qps = if target_bytes > 0 {
    match
      h264_rc_solve(n, qp, target_bytes, fn(trial) {
        match
          h264_encode_frames_qps(
            frames,
            width~,
            height~,
            base_qp=qp,
            qps=trial,
            level_idc~,
            pcm_first~,
            intra_in_p~,
            intra4x4_in_p~,
            dct8x8~,
            aq~,
            aq_strength~,
            aud~,
            recon=[],
            stats=H264EncStats::new(),
          ) {
          Ok((bytes, _)) => Ok(bytes.length())
          Err(e) => Err(e)
        }
      }) {
      Ok(q) => q
      Err(e) => return Err(e)
    }
  } else {
    Array::make(n, qp)
  }
  for q in qps {
    stats.frame_qps.push(q)
  }
  match
    h264_encode_frames_qps(
      frames,
      width~,
      height~,
      base_qp=qp,
      qps~,
      level_idc~,
      pcm_first~,
      intra_in_p~,
      intra4x4_in_p~,
      dct8x8~,
      aq~,
      aq_strength~,
      aud~,
      recon~,
      stats~,
    ) {
    Ok((bytes, _)) => Ok(bytes)
    Err(e) => Err(e)
  }
}

///|
/// The VBV/CBR sequence entry: assign per-picture QPs under the CPB
/// constraint (real prefix encodes), then emit the stream with filler-data
/// NALs that keep the declared CBR buffer from overflowing. See
/// `h264_vbv_solve` / `h264_vbv_fillers`.
fn h264_encode_frames_vbv(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32,
  level_idc~ : Int32,
  pcm_first~ : Bool,
  intra_in_p~ : Bool,
  intra4x4_in_p~ : Bool,
  dct8x8~ : Bool,
  aq~ : Bool,
  aq_strength~ : Int32,
  aud~ : Bool,
  vbv~ : H264Vbv,
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
) -> Result[Bytes, String] {
  let n = frames.length()
  let (qps, sizes) = match
    h264_vbv_solve(n, qp, vbv, fn(trial) {
      match
        h264_encode_frames_qps(
          frames,
          width~,
          height~,
          base_qp=qp,
          qps=trial,
          level_idc~,
          pcm_first~,
          intra_in_p~,
          intra4x4_in_p~,
          dct8x8~,
          aq~,
          aq_strength~,
          aud~,
          recon=[],
          stats=H264EncStats::new(),
          vbv=Some(vbv),
        ) {
        Ok((_, sizes)) => Ok(sizes)
        Err(e) => Err(e)
      }
    }) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let fillers = h264_vbv_fillers(n, sizes, vbv)
  for q in qps {
    stats.frame_qps.push(q)
  }
  match
    h264_encode_frames_qps(
      frames,
      width~,
      height~,
      base_qp=qp,
      qps~,
      level_idc~,
      pcm_first~,
      intra_in_p~,
      intra4x4_in_p~,
      dct8x8~,
      aq~,
      aq_strength~,
      recon~,
      stats~,
      vbv=Some(vbv),
      fillers~,
      aud~,
    ) {
    Ok((bytes, _)) => {
      stats.vbv_bits = bytes.length().to_int64() * 8L
      for f = 0; f < n; f = f + 1 {
        if fillers[f] > 0 {
          stats.vbv_fills += 1
          stats.vbv_filler_bytes += fillers[f]
        }
      }
      Ok(bytes)
    }
    Err(e) => Err(e)
  }
}

///|
/// Greedy CPB-constrained QP assignment. The model is the HRD leaky
/// bucket: the buffer starts `init_bits` full, each picture is removed at
/// its nominal time, and `maxrate/fps` bits arrive between removals.
/// Increasing a picture's QP is the only lever (the reference chain makes
/// the whole suffix respond), so the search is monotone:
///
/// 1. encode the sequence with the starting flat QP;
/// 2. simulate the buffer, filler schedule included, and find the first
///    access unit that does not fit;
/// 3. raise that picture's QP by the size-model jump, re-encode the whole
///    sequence, repeat until every removal fits.
///
/// Every probe is a real encode (decisions, skips and references all
/// respond to the QP), so the final assignment satisfies the constraint
/// exactly, not just in the model.
fn h264_vbv_solve(
  n : Int32,
  start_qp : Int32,
  v : H264Vbv,
  encode : (Array[Int32]) -> Result[Array[Int32], String],
) -> Result[(Array[Int32], Array[Int32]), String] {
  let q0 = if start_qp < h264_rc_qp_min {
    h264_rc_qp_min
  } else if start_qp > h264_rc_qp_max {
    h264_rc_qp_max
  } else {
    start_qp
  }
  let qps = Array::make(n, q0)
  let mut rounds = 0
  while true {
    let sizes = match encode(qps) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    // Replay the CPB over the real access units, filler included: a filler
    // is removed together with the picture it trails, so it eats into the
    // next removal's headroom. The ideal filler leaves the bucket within
    // 47 bits of full; if the next picture is that close to the declared
    // size, it must coarsen too.
    let fillers = h264_vbv_fillers(n, sizes, v)
    let mut fullness = v.init_bits
    let mut under = -1
    let mut available = 0
    for f = 0; f < n; f = f + 1 {
      let bits = (sizes[f] + fillers[f]) * 8
      if bits > fullness {
        under = f
        available = fullness
        break
      }
      fullness = fullness - bits + v.rate_bits
      if fullness > v.bufsize {
        fullness = v.bufsize
      }
    }
    if under < 0 {
      return Ok((qps, sizes))
    }
    rounds = rounds + 1
    if rounds > 2048 {
      return Err("h264 enc: vbv solver did not converge")
    }
    let jump = h264_rc_qp_jump(sizes[under] * 8, available)
    let step = if jump < 1 { 1 } else { jump }
    if qps[under] >= h264_rc_qp_max {
      return Err(
        "h264 enc: vbv underflow at picture \{under} even at QP \{h264_rc_qp_max}",
      )
    }
    let next = qps[under] + step
    qps[under] = if next > h264_rc_qp_max { h264_rc_qp_max } else { next }
  }
  Err("h264 enc: vbv solver exhausted")
}

///|
/// Filler-data schedule: for each access unit, the total NAL size (start
/// code + header + payload) that must be appended so the buffer does not
/// overflow between this removal and the next. The raw sizes come from the
/// solver's last pass, so the first removal is known to fit; a filler is
/// only ever added when the post-removal buffer can absorb it. The 48-bit
/// slack enforced by `h264_vbv_new` guarantees the minimum six-byte NAL
/// fits whenever the next arrival would otherwise overflow.
fn h264_vbv_fillers(
  n : Int32,
  sizes : Array[Int32],
  v : H264Vbv,
) -> Array[Int32] {
  let fillers = Array::make(n, 0)
  let mut fullness = v.init_bits
  for f = 0; f < n; f = f + 1 {
    let bits = sizes[f] * 8
    let after = if bits >= fullness { 0 } else { fullness - bits }
    let room = v.bufsize - after
    let mut nal = 0
    if room < v.rate_bits {
      let deficit = v.rate_bits - room
      let mut payload = (deficit + 7) / 8 - 5
      if payload < 1 {
        payload = 1
      }
      nal = payload + 5
      // The filler is removed together with this picture, so it may only
      // spend bits the post-removal bucket holds. `h264_vbv_new` keeps 48
      // bits of slack, which makes the minimum NAL always affordable here;
      // the cap is defensive anyway.
      if nal * 8 > after {
        let cap = after / 8
        nal = if cap >= 6 { cap } else { 0 }
      }
    }
    fillers[f] = nal
    let next = after - nal * 8 + v.rate_bits
    fullness = if next > v.bufsize {
      v.bufsize
    } else if next < 0 {
      0
    } else {
      next
    }
  }
  fillers
}

///|
/// The sequence encoder proper: picture `f` codes at `qps[f]` against the
/// single PPS whose `pic_init_qp` is `base_qp`. Returns the Annex B stream
/// and the byte size of every access unit (the first includes SPS + PPS).
fn h264_encode_frames_qps(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int32,
  height~ : Int32,
  base_qp~ : Int32,
  qps~ : Array[Int32],
  level_idc~ : Int32,
  pcm_first~ : Bool,
  intra_in_p~ : Bool,
  intra4x4_in_p~ : Bool,
  dct8x8~ : Bool,
  aq~ : Bool,
  aq_strength~ : Int32,
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
  vbv~ : H264Vbv? = None,
  fillers~ : Array[Int32] = [],
  aud~ : Bool = false,
) -> Result[(Bytes, Array[Int32]), String] {
  let (y0, u0, v0) = frames[0]
  let first = match
    h264_encode_intra_frame(
      y0,
      u0,
      v0,
      width~,
      height~,
      qp=qps[0],
      level_idc~,
      pcm=pcm_first,
      dct8x8~,
      stats~,
      pps_qp=base_qp,
      aq~,
      aq_strength~,
      vbv~,
    ) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let p = { width, height, qp: base_qp, level_idc, }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  let ps = new_h264_param_sets()
  match
    ff_h264_decode_seq_parameter_set(
      BitReader::new(h264_enc_sps_rbsp(p, dct8x8~)),
      ps,
      false,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = h264_enc_pps_rbsp(p, dct8x8~)
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
  fn load_plane(
    src : Bytes,
    w : Int32,
    h : Int32,
    stride : Int32,
    plane_h : Int32,
  ) -> Array[Int32] {
    let plane : Array[Int32] = Array::make(stride * plane_h, 0)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        plane[row * stride + col] = src[row * w + col].to_int()
      }
    }
    plane
  }
  let stream : Array[Bytes] = []
  if fillers.length() > 0 && fillers[0] > 0 {
    stream.push(
      h264_enc_concat([first.annexb, h264_enc_filler_nal(fillers[0] - 5)]),
    )
  } else {
    stream.push(first.annexb)
  }
  // Reference = the I frame's reconstruction (deep copy: P recon replaces
  // the reference each frame).
  if aud {
    stream[0] = h264_enc_concat([h264_enc_aud(true), stream[0]])
  }
  let mut ref_y = Array::make(ystride * pheight, 0)
  let mut ref_u = Array::make(cstride * (pheight / 2), 0)
  let mut ref_v = Array::make(cstride * (pheight / 2), 0)
  for row = 0; row < pheight; row = row + 1 {
    for col = 0; col < ystride; col = col + 1 {
      ref_y[row * ystride + col] = first.recon_y[row * ystride + col]
    }
  }
  for row = 0; row < pheight / 2; row = row + 1 {
    for col = 0; col < cstride; col = col + 1 {
      ref_u[row * cstride + col] = first.recon_u[row * cstride + col]
      ref_v[row * cstride + col] = first.recon_v[row * cstride + col]
    }
  }
  let states : Array[H264PMbState] = []
  for k = 0; k < mb_width * mb_height; k = k + 1 {
    states.push(new_h264_p_mb_state())
  }
  // Seed the persistent nz mirror from the I frame, mirroring the decoder's
  // `non_zero_count` array (allocated once, never reset between pictures).
  // Every macroblock kind overwrites the slots the nC predictor reads -
  // skip zeroes all 48, coded blocks write their count or zero - so the
  // seed is a lifecycle mirror rather than a value that survives.
  for k = 0; k < mb_width * mb_height; k = k + 1 {
    for i = 0; i < 48; i = i + 1 {
      states[k].nz[i] = first.mb_nz[k][i]
    }
  }
  for f = 1; f < frames.length(); f = f + 1 {
    let (y, u, v) = frames[f]
    let src_y_p = load_plane(y, width, height, ystride, pheight)
    let (act, act_avg) = if aq {
      h264_aq_measure(src_y_p, ystride, mb_width, mb_height)
    } else {
      (Array::make(mb_width * mb_height, 0), 0)
    }
    let enc : H264PEncoder = {
      p: { width, height, qp: qps[f], level_idc, },
      stats,
      pps,
      chroma_qp: h264_get_chroma_qp(pps, 0, qps[f]),
      src_y: src_y_p,
      src_u: load_plane(u, width / 2, height / 2, cstride, pheight / 2),
      src_v: load_plane(v, width / 2, height / 2, cstride, pheight / 2),
      rec_y: Array::make(ystride * pheight, 0),
      rec_u: Array::make(cstride * (pheight / 2), 0),
      rec_v: Array::make(cstride * (pheight / 2), 0),
      ref_y,
      ref_u,
      ref_v,
      ystride,
      cstride,
      pwidth: ystride,
      pheight,
      mb_width,
      mb_height,
      states,
      cur_nz: Array::make(48, 0),
      cur_mv: Array::make(32, 0),
      cur_ref: Array::make(16, -2),
      dct8x8,
      intra4x4_in_p,
      base_qp,
      mb_qp: qps[f],
      mb_dqp: 0,
      prev_qp: qps[f],
      aq_act: act,
      aq_avg: act_avg,
      aq_on: aq,
      aq_strength,
      cabac_rd: false,
      price_mirror: None,
      price_enc: None,
      price_states: None,
    }
    // frame_num increments per reference frame: the IDR carries 0.
    let nal = match enc.encode_p_frame(f, intra_in_p) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    let au : Array[Bytes] = []
    match vbv {
      None => ()
      Some(v) => au.push(h264_enc_sei_pic_timing(v, f * 2))
    }
    au.push(nal)
    if fillers.length() > f && fillers[f] > 0 {
      au.push(h264_enc_filler_nal(fillers[f] - 5))
    }
    if aud {
      au.insert(0, h264_enc_aud(false))
    }
    stream.push(h264_enc_concat(au))
    recon.push(
      h264_enc_pack_recon(
        enc.rec_y,
        enc.rec_u,
        enc.rec_v,
        width,
        height,
        ystride,
        cstride,
      ),
    )
    // The reconstruction becomes the next reference.
    let next_y = Array::make(ystride * pheight, 0)
    let next_u = Array::make(cstride * (pheight / 2), 0)
    let next_v = Array::make(cstride * (pheight / 2), 0)
    for row = 0; row < pheight; row = row + 1 {
      for col = 0; col < ystride; col = col + 1 {
        next_y[row * ystride + col] = enc.rec_y[row * ystride + col]
      }
    }
    for row = 0; row < pheight / 2; row = row + 1 {
      for col = 0; col < cstride; col = col + 1 {
        next_u[row * cstride + col] = enc.rec_u[row * cstride + col]
        next_v[row * cstride + col] = enc.rec_v[row * cstride + col]
      }
    }
    ref_y = next_y
    ref_u = next_u
    ref_v = next_v
  }
  // Concatenate; the per-picture sizes feed the rate control.
  let out : Array[Byte] = []
  let sizes : Array[Int32] = []
  for part in stream {
    sizes.push(part.length())
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Ok((Bytes::from_array(out[:]), sizes))
}

///|
/// The rate control's QP range. The floor keeps the search away from the
/// near-lossless QPs, whose level magnitudes approach the CAVLC escape
/// window and whose bit cost no realistic target asks for; the ceiling is
/// the format's.
let h264_rc_qp_min : Int32 = 10

///|
let h264_rc_qp_max : Int32 = 51

///|
/// `2^(k/6) * 1024` for k = 0..5: the quantiser step doubles every 6 QP,
/// and to first order the coded size halves with it.
let h264_rc_pow2_sixth : FixedArray[Int32] = [
  1024, 1149, 1290, 1448, 1625, 1825,
]

///|
/// Signed QP jump predicted by the "size halves every +6 QP" model: the
/// largest `j` with `size >= target * 2^(j/6)` (positive when the stream is
/// over the target), mirrored and negated when it is under. Integer-only,
/// so every backend takes the same search path.
fn h264_rc_qp_jump(size : Int32, target : Int32) -> Int32 {
  if size == target || size <= 0 || target <= 0 {
    return 0
  }
  let over = size > target
  let hi = (if over { size } else { target }).to_int64()
  let lo = (if over { target } else { size }).to_int64()
  let mut j = 0
  while j < 30 {
    let k = j + 1
    let scaled = (lo * h264_rc_pow2_sixth[k % 6].to_int64()) << (k / 6)
    if hi * 1024L >= scaled {
      j = k
    } else {
      break
    }
  }
  if over {
    j
  } else {
    -j
  }
}

///|
/// Two-pass average-bitrate control over a whole sequence. `encode` codes
/// the sequence with one QP per picture and reports the total byte size;
/// the result is the per-picture QP assignment of the best stream that
/// does not exceed `target` bytes:
///
/// 1. **Bracket** the flat QP: probe `start_qp`, jump by the size model,
///    then walk to the smallest flat QP `q_hi` that fits; `q_lo = q_hi - 1`
///    does not.
/// 2. **Dither** between the two: a flat-QP step moves the size by ~12%,
///    so the last `k` pictures take `q_hi` and the rest `q_lo`, with `k`
///    bisected to the smallest count that fits. Trailing pictures first -
///    nothing references the end of a P-only sequence, so coarsening them
///    costs the least; the I picture (reference of everything) goes last.
///
/// Every probe is a real encode (decisions, skips and references all
/// respond to the QP), so the returned assignment is exact, not modelled.
/// The search stays inside `[h264_rc_qp_min, h264_rc_qp_max]`: when even
/// the coarsest QP exceeds the target that flat assignment is returned
/// (best effort); when the finest fits, the flat finest.
fn h264_rc_solve(
  n : Int32,
  start_qp : Int32,
  target : Int32,
  encode : (Array[Int32]) -> Result[Int32, String],
) -> Result[Array[Int32], String] {
  let memo : Array[Int32] = Array::make(52, -1)
  let flat = fn(q : Int32) -> Result[Int32, String] {
    if memo[q] >= 0 {
      return Ok(memo[q])
    }
    match encode(Array::make(n, q)) {
      Ok(size) => {
        memo[q] = size
        Ok(size)
      }
      Err(e) => Err(e)
    }
  }
  let mut q = if start_qp < h264_rc_qp_min {
    h264_rc_qp_min
  } else if start_qp > h264_rc_qp_max {
    h264_rc_qp_max
  } else {
    start_qp
  }
  let mut size = match flat(q) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Model jumps (at most two): land near the boundary in one or two probes
  // instead of walking there. Under the target the jump stops one step
  // short, so the walk below never has to climb back.
  for _i = 0; _i < 2; _i = _i + 1 {
    let jump = h264_rc_qp_jump(size, target)
    let step = if jump < 0 { jump + 1 } else { jump }
    let mut nq = q + step
    if nq < h264_rc_qp_min {
      nq = h264_rc_qp_min
    }
    if nq > h264_rc_qp_max {
      nq = h264_rc_qp_max
    }
    if nq == q {
      break
    }
    q = nq
    size = match flat(q) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  // Walk up until the flat stream fits.
  while size > target && q < h264_rc_qp_max {
    q = q + 1
    size = match flat(q) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  if size > target {
    return Ok(Array::make(n, h264_rc_qp_max))
  }
  // Walk down while the next finer flat QP still fits.
  while q > h264_rc_qp_min {
    let finer = match flat(q - 1) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if finer <= target {
      q = q - 1
    } else {
      break
    }
  }
  if q == h264_rc_qp_min {
    return Ok(Array::make(n, h264_rc_qp_min))
  }
  let q_hi = q
  let q_lo = q - 1
  let assign = fn(k : Int32) -> Array[Int32] {
    let qps : Array[Int32] = Array::make(n, q_lo)
    for f = n - k; f < n; f = f + 1 {
      qps[f] = q_hi
    }
    qps
  }
  // k = 0 is flat q_lo (over the target), k = n flat q_hi (fits).
  let mut lo_k = 0
  let mut hi_k = n
  while hi_k - lo_k > 1 {
    let mid = (lo_k + hi_k) / 2
    let trial = match encode(assign(mid)) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if trial <= target {
      hi_k = mid
    } else {
      lo_k = mid
    }
  }
  Ok(assign(hi_k))
}

///|
fn H264PEncoder::encode_p_frame(
  self : H264PEncoder,
  frame_num : Int32,
  intra_in_p : Bool,
  poc_lsb~ : Int32 = -1,
) -> Result[Bytes, String] {
  // Fresh picture: the availability markers reset (every frame is a new
  // slice, so previous-frame macroblocks are unavailable to `mv_fetch`)
  // but the nz mirror persists - uncoded blocks' nC reads see the previous
  // frame's counts.
  for k = 0; k < self.states.length(); k = k + 1 {
    let st = self.states[k]
    for i = 0; i < 32; i = i + 1 {
      st.mv[i] = 0
    }
    for i = 0; i < 16; i = i + 1 {
      st.ref_idx[i] = -2
    }
    st.intra = false
    st.has_data = false
  }
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(5) // slice_type: P (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num (log2_max_frame_num = 4)
  if poc_lsb >= 0 {
    r.put(poc_lsb & 15, 4) // pic_order_cnt_lsb (POC type 0 sequences)
  }
  // num_ref_idx_active_override_flag = 0 (PPS default 1 reference)
  r.put_bit(0)
  // ref_pic_list_modification: ref_pic_list_modification_flag_l0 = 0
  r.put_bit(0)
  // dec_ref_pic_marking (nal_ref_idc != 0, non-IDR):
  r.put_bit(0) // adaptive_ref_pic_marking_mode_flag
  r.put_se(self.p.qp - self.base_qp) // slice_qp_delta
  let mut skip_run = 0
  for mb_y = 0; mb_y < self.mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < self.mb_width; mb_x = mb_x + 1 {
      let mb_idx = mb_y * self.mb_width + mb_x
      // Adaptive quantisation: this MB's QP offset rides `mb_qp_delta`.
      self.mb_qp = self.p.qp
      self.mb_dqp = 0
      if self.aq_on {
        let adj = h264_aq_adj(
          self.aq_act[mb_idx],
          self.aq_avg,
          self.aq_strength,
        )
        let mut mq = self.p.qp + adj
        if mq < 0 {
          mq = 0
        }
        if mq > 51 {
          mq = 51
        }
        self.mb_qp = mq
        self.mb_dqp = mq - self.prev_qp
        self.chroma_qp = h264_get_chroma_qp(self.pps, 0, mq)
      }
      let (pmvx, pmvy) = self.pred_pskip(mb_x, mb_y)
      let (_, _, skip_sad) = self.me_fixed(mb_x, mb_y, 0, 0, 16, 16, pmvx, pmvy)
      let plan = if skip_sad == 0 {
        Skip
      } else {
        self.decide_plan(mb_x, mb_y, intra_in_p)
      }
      if plan is I16(_, _, _) {
        self.stats.i16_mbs += 1
      }
      if plan is I8(_, _) {
        self.stats.i8p_mbs += 1
      }
      if plan is I4(_, _) {
        self.stats.i4p_mbs += 1
      }
      if !(plan is Skip) {
        self.stats.coded_mbs += 1
      }
      // The pending skip run is flushed only once a CODED macroblock is
      // known. Rate-distortion may turn a macroblock whose predictor SAD
      // is nonzero into a Skip, and that decision has to extend the run -
      // emitting mb_skip_run before the decision would leave the decoder
      // reading a skipped macroblock as a coded one.
      if plan is Skip {
        skip_run = skip_run + 1
        self.commit_skip(mb_idx, pmvx, pmvy)
        continue
      }
      r.put_ue(skip_run)
      skip_run = 0
      match self.write_coded_mb(mb_x, mb_y, plan, r, self.mb_qp) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  // A trailing skip run IS coded (spec 7.4.4: the slice data ends with the
  // pending mb_skip_run when the last macroblocks are skipped).
  if skip_run > 0 {
    r.put_ue(skip_run)
  }
  r.trailing_bits()
  Ok(h264_enc_nal(r, 3, 1))
}

///|

///|
/// The decided macroblock plan: partitions with quarter-pel MVs.
priv enum H264PPlan {
  Skip
  /// P_L0_16x16.
  Part16x16(Int32, Int32)
  /// P_L0_16x8: top, bottom.
  Part16x8(Int32, Int32, Int32, Int32)
  /// P_L0_8x16: left, right.
  Part8x16(Int32, Int32, Int32, Int32)
  /// P_8x8: four sub types (0 8x8 / 1 8x4 / 2 4x8 / 3 4x4) and the
  /// quarter-pel MVs of every sub partition in `h264_sub_partitions` order.
  Part8x8(Int32, Int32, Int32, Int32, Array[Int32])
  /// Intra16x16 fallback in a P slice: the signalling prediction mode
  /// (encoder numbering DC/H/V/Plane), the availability-checked effective
  /// mode the prediction runs on, and the chroma prediction mode.
  I16(Int32, Int32, Int32)
  /// Intra 8x8 (I_NxN + transform_size_8x8_flag) in a P slice: the four
  /// signalled `pred8x8l` modes in block order and the chroma prediction
  /// mode. Only produced under `dct8x8`.
  I8(Array[Int32], Int32)
  /// Intra 4x4 (I_NxN) in a P slice: the sixteen signalled `pred4x4` modes
  /// on the 4x4 grid (grid-indexed) and the chroma prediction mode. Only
  /// produced under `intra4x4_in_p`.
  I4(Array[Int32], Int32)
}

///|
/// Partition ME: +-16 integer SAD (zero MV first, strictly-better
/// replacements) refined through the decoder's MC filter over the 3x3
/// subpel neighbourhood. Returns the quarter-pel MV and its MC SAD.
fn H264PEncoder::me_part(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  ox : Int32,
  oy : Int32,
  w : Int32,
  h : Int32,
) -> (Int32, Int32, Int32) {
  let src_row = mb_y * 16 + oy
  let src_col = mb_x * 16 + ox
  let mut best_x = 0
  let mut best_y = 0
  let mut best_sad = h264_p_sad_int(
    self.src_y,
    self.ref_y,
    src_row,
    src_col,
    self.ystride,
    mb_x * 16 + ox,
    mb_y * 16 + oy,
    w~,
    h~,
    self.pwidth,
    self.pheight,
  )
  for dy = -16; dy <= 16; dy = dy + 1 {
    for dx = -16; dx <= 16; dx = dx + 1 {
      if dx == 0 && dy == 0 {
        continue
      }
      let sad = h264_p_sad_int(
        self.src_y,
        self.ref_y,
        src_row,
        src_col,
        self.ystride,
        mb_x * 16 + ox + dx,
        mb_y * 16 + oy + dy,
        w~,
        h~,
        self.pwidth,
        self.pheight,
      )
      if sad < best_sad {
        best_sad = sad
        best_x = dx
        best_y = dy
      }
    }
  }
  let mcbuf : Array[Int32] = Array::make(256, 0)
  h264_mc_luma(
    mcbuf,
    0,
    16,
    self.ref_y,
    mb_x * 16 + ox + (best_x >> 2),
    mb_y * 16 + oy + (best_y >> 2),
    self.ystride,
    w,
    h,
    best_x & 3,
    best_y & 3,
    self.pwidth,
    self.pheight,
    bit_depth=8,
  )
  let mut best_qx = best_x * 4
  let mut best_qy = best_y * 4
  let mut best_qsad = h264_p_sad_mc(
    self.src_y,
    mcbuf,
    src_row,
    src_col,
    self.ystride,
    self.pheight,
    self.pwidth,
    w~,
    h~,
  )
  for sy = -1; sy <= 1; sy = sy + 1 {
    for sx = -1; sx <= 1; sx = sx + 1 {
      if sx == 0 && sy == 0 {
        continue
      }
      let qx = best_x * 4 + sx
      let qy = best_y * 4 + sy
      if qx >= 0 && qy >= 0 {
        h264_mc_luma(
          mcbuf,
          0,
          16,
          self.ref_y,
          mb_x * 16 + ox + (qx >> 2),
          mb_y * 16 + oy + (qy >> 2),
          self.ystride,
          w,
          h,
          qx & 3,
          qy & 3,
          self.pwidth,
          self.pheight,
          bit_depth=8,
        )
        let sad = h264_p_sad_mc(
          self.src_y,
          mcbuf,
          src_row,
          src_col,
          self.ystride,
          self.pheight,
          self.pwidth,
          w~,
          h~,
        )
        if sad < best_qsad {
          best_qsad = sad
          best_qx = qx
          best_qy = qy
        }
      }
    }
  }
  (best_qx, best_qy, best_qsad)
}

///|
/// MC a fixed MV (no search): the skip check. Returns the MC SAD.
fn H264PEncoder::me_fixed(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  ox : Int32,
  oy : Int32,
  w : Int32,
  h : Int32,
  mvx : Int32,
  mvy : Int32,
) -> (Int32, Int32, Int32) {
  let src_row = mb_y * 16 + oy
  let src_col = mb_x * 16 + ox
  let mcbuf : Array[Int32] = Array::make(256, 0)
  h264_mc_luma(
    mcbuf,
    0,
    16,
    self.ref_y,
    mb_x * 16 + ox + (mvx >> 2),
    mb_y * 16 + oy + (mvy >> 2),
    self.ystride,
    w,
    h,
    mvx & 3,
    mvy & 3,
    self.pwidth,
    self.pheight,
    bit_depth=8,
  )
  let sad = h264_p_sad_mc(
    self.src_y,
    mcbuf,
    src_row,
    src_col,
    self.ystride,
    self.pheight,
    self.pwidth,
    w~,
    h~,
  )
  (mvx, mvy, sad)
}

///|
/// Rate-distortion evaluation of one coded plan: SSD(src, recon) over the
/// luma macroblock plus the EXACT syntax bit count (the real CAVLC writer
/// runs against a throwaway bit buffer). Returns (ssd, bits).
///
/// The dry run mutates `rec_y`/`cur_nz`/`cur_mv`, so the progressive motion
/// mirror is reset to its macroblock-entry value first: every candidate is
/// priced from the same state the final write sees (`write_coded_mb` resets
/// it identically). Without this, a later candidate's mvd predictor reads
/// the previous candidate's MVs through `mv_fetch`'s same-MB path. `cur_nz`
/// needs no snapshot - `code_mb_residuals` re-seeds it from `states[mb].nz`
/// on every call - and `rec_y` is overwritten by the winning plan's own
/// `code_mb_residuals` before the slice is finished.
fn H264PEncoder::eval_plan(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
  qp : Int32,
) -> (Int32, Int32) {
  for i = 0; i < 32; i = i + 1 {
    self.cur_mv[i] = 0
  }
  for i = 0; i < 16; i = i + 1 {
    self.cur_ref[i] = -2
  }
  let coded = self.code_mb_residuals(mb_x, mb_y, plan, qp)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut ssd = 0
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let d = self.src_y[ybase + row * self.ystride + col] -
        self.rec_y[ybase + row * self.ystride + col]
      ssd = ssd + d * d
    }
  }
  match (self.price_mirror, self.price_enc, self.price_states) {
    (Some(ctx), Some(enc), Some(states)) => {
      // CABAC RD pricing (opt-in): replay this candidate's syntax through
      // the real engine and context states, measure the emitted bits, then
      // roll everything back so the next candidate starts from the same
      // prefix state. The measured bits are exactly the bits the final
      // write of this plan would add, not an approximation.
      let bits = self.eval_cabac_bits(ctx, enc, states, mb_x, mb_y, plan, coded)
      (ssd, bits)
    }
    _ => {
      let cw = H264Rbsp::new()
      // Pricing replays the syntax writer, whose `mb_qp_delta` sites advance
      // the running-QP mirror and the delta counter; both belong to the real
      // write only (the CABAC path prices through this same CAVLC writer).
      let saved_prev_qp = self.prev_qp
      let saved_dqp_mbs = self.stats.dqp_mbs
      self.write_mb_syntax(mb_x, mb_y, plan, coded, cw)
      self.prev_qp = saved_prev_qp
      self.stats.dqp_mbs = saved_dqp_mbs
      (ssd, cw.bw.buf.length() * 8 + cw.bw.nbits)
    }
  }
}

///|
/// One CABAC-priced candidate (the `§392` core): snapshot the arithmetic
/// engine, the context states and every mirror field the syntax writer
/// touches for the macroblock being priced, run the real
/// `write_cabac_mb_syntax`, count the bits the engine produced, then restore
/// the snapshot. The skip flag and `end_of_slice` terminate bin are constant
/// across candidates and stay outside the measurement.
fn H264PEncoder::eval_cabac_bits(
  self : H264PEncoder,
  ctx : H264DecCtx,
  enc : H264CabacEnc,
  states : Array[Int32],
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
  coded : H264PMbCode,
) -> Int32 {
  let mb_idx = mb_y * self.mb_width + mb_x
  let info = ctx.infos[mb_idx]
  // Engine snapshot: the three scalars plus the emitted-bit length.
  let s_low = enc.low
  let s_range = enc.range
  let s_outstanding = enc.outstanding
  let s_bits = enc.bits.length()
  // Context states snapshot (the writer adapts them in place).
  let s_states = Array::make(states.length(), 0)
  for i = 0; i < states.length(); i = i + 1 {
    s_states[i] = states[i]
  }
  // Mirror snapshot: the scalars the writer advances plus the current
  // macroblock's info fields (later macroblocks read them as neighbour
  // contexts, and the winning write must start from the pre-MB values).
  let s_qscale = ctx.qscale
  let s_last_qdiff = ctx.last_qscale_diff
  let s_cur_intra = ctx.cur_mb_is_intra
  let s_mb_type = info.mb_type_bits
  let s_cbp_all = info.cbp_all
  let s_chroma_mode = info.chroma_mode
  let s_intra4x4 = info.intra4x4
  let s_transform = info.transform_8x8
  let s_qp = info.qp
  let s_dqp_mbs = self.stats.dqp_mbs
  // Motion snapshot of the macroblock being priced: the syntax writer's
  // `h264_write_back_ref` / `h264_write_back_part` fill the current MB's
  // slots progressively, and partition predictors read not-yet-written
  // current-MB slots (the decoder sees them unavailable). A losing
  // candidate must not leave its values there for the next candidate or
  // the winner's real write - the same reset the CAVLC path's `cur_mv` /
  // `cur_ref` zeroing provides.
  let s_mv = Array::make(32, 0)
  let s_mvd = Array::make(32, 0)
  let s_ref = Array::make(16, 0)
  let s_mv1 = Array::make(32, 0)
  let s_mvd1 = Array::make(32, 0)
  let s_ref1 = Array::make(16, 0)
  for i = 0; i < 32; i = i + 1 {
    s_mv[i] = info.mv[i]
    s_mvd[i] = info.mvd[i]
    s_mv1[i] = info.mv1[i]
    s_mvd1[i] = info.mvd1[i]
  }
  for i = 0; i < 16; i = i + 1 {
    s_ref[i] = info.ref_idx[i]
    s_ref1[i] = info.ref_idx1[i]
  }
  // The decoder's nC semantics: every macroblock overwrites the slots the
  // predictor reads, so pricing starts from the cleared pre-MB state.
  for i = 0; i < 48; i = i + 1 {
    info.nz[i] = 0
  }
  self.write_cabac_mb_syntax(ctx, enc, states, mb_x, mb_y, plan, coded)
  let bits = enc.bits.length() - s_bits
  // Rollback: engine, states, mirror scalars, the info fields and the
  // current macroblock's motion slots.
  enc.low = s_low
  enc.range = s_range
  enc.outstanding = s_outstanding
  enc.bits.truncate(s_bits)
  for i = 0; i < states.length(); i = i + 1 {
    states[i] = s_states[i]
  }
  ctx.qscale = s_qscale
  ctx.last_qscale_diff = s_last_qdiff
  ctx.cur_mb_is_intra = s_cur_intra
  info.mb_type_bits = s_mb_type
  info.cbp_all = s_cbp_all
  info.chroma_mode = s_chroma_mode
  info.intra4x4 = s_intra4x4
  info.transform_8x8 = s_transform
  info.qp = s_qp
  self.stats.dqp_mbs = s_dqp_mbs
  for i = 0; i < 32; i = i + 1 {
    info.mv[i] = s_mv[i]
    info.mvd[i] = s_mvd[i]
    info.mv1[i] = s_mv1[i]
    info.mvd1[i] = s_mvd1[i]
  }
  for i = 0; i < 16; i = i + 1 {
    info.ref_idx[i] = s_ref[i]
    info.ref_idx1[i] = s_ref1[i]
  }
  // Leave the nz slots cleared for the next candidate and, after the last
  // one, for the winner's real write (uncoded blocks must read as zero).
  for i = 0; i < 48; i = i + 1 {
    info.nz[i] = 0
  }
  bits
}

///|
/// SSD-domain mode lambda, scaled by 2^10: `0.85 * 2^((qp-12)/3)`, the
/// H.264 reference-software convention for SSD distortion (the SAD-domain
/// motion lambda uses half the exponent, `0.85 * 2^((qp-12)/6)`; the SSD
/// weight keeps the same 0.85 coefficient rather than squaring it). Built
/// from repeated doublings and the cube root of two so no libm `pow` is
/// needed.
fn h264_rd_lambda(qp : Int32) -> Int32 {
  let cbrt2 = 1.2599210498948732
  let mut lam = 0.85
  let mut k = qp - 12
  while k >= 3 {
    lam = lam * 2.0
    k = k - 3
  }
  while k > 0 {
    lam = lam * cbrt2
    k = k - 1
  }
  while k <= -3 {
    lam = lam / 2.0
    k = k + 3
  }
  while k < 0 {
    lam = lam / cbrt2
    k = k + 1
  }
  (lam * 1024.0).to_int()
}

///|
/// SSD of the source against the reference at a FIXED MV: the P_Skip
/// candidate's distortion (a skipped macroblock has no syntax of its own,
/// so its rate is priced at zero - the shared `mb_skip_run` is amortised).
fn H264PEncoder::me_fixed_ssd(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Int32 {
  let mcbuf : Array[Int32] = Array::make(256, 0)
  h264_mc_luma(
    mcbuf,
    0,
    16,
    self.ref_y,
    mb_x * 16 + (mvx >> 2),
    mb_y * 16 + (mvy >> 2),
    self.ystride,
    16,
    16,
    mvx & 3,
    mvy & 3,
    self.pwidth,
    self.pheight,
    bit_depth=8,
  )
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut ssd = 0
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let d = self.src_y[ybase + row * self.ystride + col] -
        mcbuf[row * 16 + col]
      ssd = ssd + d * d
    }
  }
  ssd
}

///|
/// SAD between source and reconstruction over an 8x8 chroma block.
fn H264PEncoder::chroma_sad(
  self : H264PEncoder,
  src : Array[Int32],
  rec : Array[Int32],
  cbase : Int32,
) -> Int32 {
  let mut sad = 0
  for row = 0; row < 8; row = row + 1 {
    for col = 0; col < 8; col = col + 1 {
      let d = src[cbase + row * self.cstride + col] -
        rec[cbase + row * self.cstride + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// Chroma intra prediction mode decision: the four signalling modes are
/// checked for availability (the prediction runs on the effective mode),
/// scored by SAD over both planes and the winner's prediction is left in
/// the reconstruction planes (the residual pass re-applies it).
fn H264PEncoder::pick_chroma(
  self : H264PEncoder,
  cbase : Int32,
  top : Bool,
  left : Bool,
) -> Int32 {
  let mut best_sig = 0
  let mut best_eff = 0
  let mut best_cost = -1
  for sig = 0; sig < 4; sig = sig + 1 {
    let eff = match h264_check_intra_pred_mode(sig, top, left) {
      Ok(v) => v
      Err(_) => -1
    }
    if eff < 0 {
      continue
    }
    let ok_u = h264_pred8x8(
      self.rec_u,
      cbase,
      self.cstride,
      eff,
      top,
      left,
      bit_depth=8,
    )
    let ok_v = h264_pred8x8(
      self.rec_v,
      cbase,
      self.cstride,
      eff,
      top,
      left,
      bit_depth=8,
    )
    if ok_u is Ok(_) && ok_v is Ok(_) {
      let cost = self.chroma_sad(self.src_u, self.rec_u, cbase) +
        self.chroma_sad(self.src_v, self.rec_v, cbase)
      if best_cost < 0 || cost < best_cost {
        best_cost = cost
        best_sig = sig
        best_eff = eff
      }
    }
  }
  ignore(
    h264_pred8x8(
      self.rec_u,
      cbase,
      self.cstride,
      best_eff,
      top,
      left,
      bit_depth=8,
    ),
  )
  ignore(
    h264_pred8x8(
      self.rec_v,
      cbase,
      self.cstride,
      best_eff,
      top,
      left,
      bit_depth=8,
    ),
  )
  best_sig
}

///|
/// Intra16x16 luma candidate search: the four signalling modes are checked
/// for availability (top/left edges remap V/H/Plane), scored by prediction
/// SAD, and the winner is returned as `(signalling mode, effective mode)`.
fn H264PEncoder::pick_i16(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
) -> (Int32, Int32)? {
  let top_avail = mb_y > 0
  let left_avail = mb_x > 0
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let mut best_sig = 0
  let mut best_eff = -1
  let mut best_sad = -1
  for sig = 0; sig < 4; sig = sig + 1 {
    let eff = match h264_check_intra_pred_mode(sig, top_avail, left_avail) {
      Ok(v) => v
      Err(_) => -1
    }
    if eff < 0 {
      continue
    }
    if h264_pred16x16(
        self.rec_y,
        ybase,
        self.ystride,
        eff,
        top_avail,
        left_avail,
        bit_depth=8,
      )
      is Ok(_) {
      let mut sad = 0
      for row = 0; row < 16; row = row + 1 {
        for col = 0; col < 16; col = col + 1 {
          let d = self.src_y[ybase + row * self.ystride + col] -
            self.rec_y[ybase + row * self.ystride + col]
          sad = sad + (if d < 0 { -d } else { d })
        }
      }
      if best_sad < 0 || sad < best_sad {
        best_sad = sad
        best_sig = sig
        best_eff = eff
      }
    }
  }
  if best_eff < 0 {
    None
  } else {
    Some((best_sig, best_eff))
  }
}

///|
/// Mode decision by rate-distortion cost `SSD + lambda * bits`: P_Skip
/// against 16x16 / 16x8 / 8x16 / 8x8, each partition's MVs from the SAD+MC
/// search and each 8x8's sub-mode from SAD; when `allow_intra` is set
/// (CABAC P slices) the Intra16x16 fallback joins the same comparison.
/// Candidates must be STRICTLY cheaper, so the earlier (coarser,
/// bit-cheaper) mode wins ties.
fn H264PEncoder::decide_plan(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  allow_intra : Bool,
) -> H264PPlan {
  let qp = self.mb_qp
  // Int64 throughout: a macroblock's SSD reaches ~1.7e7 and the 2^10
  // scaling pushes the cost past 2^31, where Int (32-bit) wraps negative
  // and makes every high-distortion Skip look like the cheapest candidate.
  let lam = h264_rd_lambda(qp).to_int64()
  let (pmvx, pmvy) = self.pred_pskip(mb_x, mb_y)
  let mut best_cost = self.me_fixed_ssd(mb_x, mb_y, pmvx, pmvy).to_int64() *
    1024L
  let mut plan = Skip
  let (x16, y16, _) = self.me_part(mb_x, mb_y, 0, 0, 16, 16)
  let p16 = Part16x16(x16, y16)
  let (ssd16, bits16) = self.eval_plan(mb_x, mb_y, p16, qp)
  let c16 = ssd16.to_int64() * 1024L + lam * bits16.to_int64()
  if c16 < best_cost {
    best_cost = c16
    plan = p16
  }
  let (tx, ty, _) = self.me_part(mb_x, mb_y, 0, 0, 16, 8)
  let (bx, by, _) = self.me_part(mb_x, mb_y, 0, 8, 16, 8)
  let p168 = Part16x8(tx, ty, bx, by)
  let (ssd168, bits168) = self.eval_plan(mb_x, mb_y, p168, qp)
  let c168 = ssd168.to_int64() * 1024L + lam * bits168.to_int64()
  if c168 < best_cost {
    best_cost = c168
    plan = p168
  }
  let (lx, ly, _) = self.me_part(mb_x, mb_y, 0, 0, 8, 16)
  let (rx, ry, _) = self.me_part(mb_x, mb_y, 8, 0, 8, 16)
  let p816 = Part8x16(lx, ly, rx, ry)
  let (ssd816, bits816) = self.eval_plan(mb_x, mb_y, p816, qp)
  let c816 = ssd816.to_int64() * 1024L + lam * bits816.to_int64()
  if c816 < best_cost {
    best_cost = c816
    plan = p816
  }
  let subs : Array[Int32] = Array::make(4, 0)
  let mvs : Array[Int32] = []
  for k = 0; k < 4; k = k + 1 {
    let x8 = k % 2
    let y8 = k / 2
    let (z0x, z0y, s8) = self.me_part(mb_x, mb_y, x8 * 8, y8 * 8, 8, 8)
    let (t1x, t1y, t1) = self.me_part(mb_x, mb_y, x8 * 8, y8 * 8, 8, 4)
    let (t2x, t2y, t2) = self.me_part(mb_x, mb_y, x8 * 8, y8 * 8 + 4, 8, 4)
    let (l1x, l1y, l1) = self.me_part(mb_x, mb_y, x8 * 8, y8 * 8, 4, 8)
    let (r1x, r1y, r2) = self.me_part(mb_x, mb_y, x8 * 8 + 4, y8 * 8, 4, 8)
    let (a1x, a1y, a1) = self.me_part(mb_x, mb_y, x8 * 8, y8 * 8, 4, 4)
    let (b1x, b1y, b2) = self.me_part(mb_x, mb_y, x8 * 8 + 4, y8 * 8, 4, 4)
    let (c1x, c1y, c3) = self.me_part(mb_x, mb_y, x8 * 8, y8 * 8 + 4, 4, 4)
    let (d1x, d1y, d4) = self.me_part(mb_x, mb_y, x8 * 8 + 4, y8 * 8 + 4, 4, 4)
    let mut sub = 0
    let mut sub_sad = s8
    let mut sub_mvs = [z0x, z0y]
    if t1 + t2 < sub_sad {
      sub = 1
      sub_sad = t1 + t2
      sub_mvs = [t1x, t1y, t2x, t2y]
    }
    if l1 + r2 < sub_sad {
      sub = 2
      sub_sad = l1 + r2
      sub_mvs = [l1x, l1y, r1x, r1y]
    }
    if a1 + b2 + c3 + d4 < sub_sad {
      sub = 3
      sub_sad = a1 + b2 + c3 + d4
      sub_mvs = [a1x, a1y, b1x, b1y, c1x, c1y, d1x, d1y]
    }
    subs[k] = sub
    for m in sub_mvs {
      mvs.push(m)
    }
  }
  let p88 = Part8x8(subs[0], subs[1], subs[2], subs[3], mvs)
  let (ssd88, bits88) = self.eval_plan(mb_x, mb_y, p88, qp)
  if ssd88.to_int64() * 1024L + lam * bits88.to_int64() < best_cost {
    plan = p88
  }
  // Intra16x16 fallback (CABAC P slices only): a scene change or a moving
  // edge can leave every inter partition with a large residual; coding the
  // MB against its own current-frame neighbours then wins the same
  // `SSD + lambda * bits` comparison. The mode is picked by prediction SAD
  // first (like the intra encoder), then the full residual/reconstruction
  // cost is measured by `eval_plan`. Added last, so ties stay inter.
  if allow_intra {
    match self.pick_i16(mb_x, mb_y) {
      Some((sig, eff)) => {
        let cbase = mb_y * 8 * self.cstride + mb_x * 8
        let chroma_mode = self.pick_chroma(cbase, mb_y > 0, mb_x > 0)
        let pi16 = I16(sig, eff, chroma_mode)
        let (ssd16x, bits16x) = self.eval_plan(mb_x, mb_y, pi16, qp)
        let c16x = ssd16x.to_int64() * 1024L + lam * bits16x.to_int64()
        if c16x < best_cost {
          best_cost = c16x
          plan = pi16
        }
      }
      None => ()
    }
  }
  // Intra 8x8 (I_NxN + transform_size_8x8_flag) under `dct8x8`: textured
  // content the single 16x16 predictor cannot follow. The shared I8x8 pass
  // picks the four `pred8x8l` modes by prediction SAD (sequentially, on
  // its own reconstruction); `eval_plan` then replays those modes and
  // prices the plan like every other candidate. Added after I16x16, so
  // ties stay with the cheaper-to-signal 16x16 form.
  if allow_intra && self.dct8x8 {
    let scratch_store : Array[Int32] = Array::make(256, 0)
    let scratch_modes : Array[Int32] = Array::make(16, 0)
    let scratch_mb : Array[Int32] = Array::make(768, 0)
    if h264_enc_luma_i8_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        scratch_store,
        scratch_modes,
        scratch_mb,
        h264_enc_i8_avail(mb_x, mb_y, self.mb_width),
      )
      is Ok(_) {
      // Grid cells 0/2/8/10 hold the four blocks' signalled modes.
      let raw_modes : Array[Int32] = [
        scratch_modes[0],
        scratch_modes[2],
        scratch_modes[8],
        scratch_modes[10],
      ]
      let cbase = mb_y * 8 * self.cstride + mb_x * 8
      let chroma_mode = self.pick_chroma(cbase, mb_y > 0, mb_x > 0)
      let pi8 = I8(raw_modes, chroma_mode)
      let (ssd8x, bits8x) = self.eval_plan(mb_x, mb_y, pi8, qp)
      let c8x = ssd8x.to_int64() * 1024L + lam * bits8x.to_int64()
      if c8x < best_cost {
        best_cost = c8x
        plan = pi8
      }
    }
  }
  // Intra 4x4 (I_NxN) under `intra4x4_in_p`: the finest intra granularity,
  // sixteen independently-predicted 4x4 blocks for detailed textures the
  // 16x16/8x8 predictors cannot follow. The shared I4x4 pass picks the
  // modes by prediction SAD on its own reconstruction; `eval_plan` replays
  // them and prices the plan. Added after I8x8, so ties stay with the
  // cheaper-to-signal coarser forms.
  if self.intra4x4_in_p {
    let scratch_store : Array[Int32] = Array::make(256, 0)
    let scratch_modes : Array[Int32] = Array::make(16, 0)
    let scratch_mb : Array[Int32] = Array::make(768, 0)
    if h264_enc_luma_i4_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        scratch_store,
        scratch_modes,
        scratch_mb,
        h264_enc_i4_avail(mb_x, mb_y, self.mb_width),
      )
      is Ok(_) {
      let raw_modes : Array[Int32] = Array::make(16, 0)
      for g = 0; g < 16; g = g + 1 {
        raw_modes[g] = scratch_modes[g]
      }
      let cbase = mb_y * 8 * self.cstride + mb_x * 8
      let chroma_mode = self.pick_chroma(cbase, mb_y > 0, mb_x > 0)
      let pi4 = I4(raw_modes, chroma_mode)
      let (ssd4x, bits4x) = self.eval_plan(mb_x, mb_y, pi4, qp)
      let c4x = ssd4x.to_int64() * 1024L + lam * bits4x.to_int64()
      if c4x < best_cost {
        best_cost = c4x
        plan = pi4
      }
    }
  }
  plan
}

///|
fn h264_p_sad_int(
  src : Array[Int32],
  ref_plane : Array[Int32],
  src_row : Int32,
  src_col : Int32,
  stride : Int32,
  ref_x : Int32,
  ref_y : Int32,
  w~ : Int32 = 16,
  h~ : Int32 = 16,
  pw : Int32,
  ph : Int32,
) -> Int32 {
  // Edge replication matches the MC clamp on BOTH planes: the +-16 search
  // window and bottom/right partitions read outside the visible area.
  let mut sad = 0
  for row = 0; row < h; row = row + 1 {
    let ry = h264_mc_clamp(ref_y + row, ph)
    let sy = h264_mc_clamp(src_row + row, ph)
    for col = 0; col < w; col = col + 1 {
      let rx = h264_mc_clamp(ref_x + col, pw)
      let sx = h264_mc_clamp(src_col + col, pw)
      let d = src[sy * stride + sx] - ref_plane[ry * stride + rx]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
fn h264_p_sad_mc(
  src : Array[Int32],
  mc : Array[Int32],
  src_row : Int32,
  src_col : Int32,
  stride : Int32,
  ph : Int32,
  pw : Int32,
  w~ : Int32 = 16,
  h~ : Int32 = 16,
) -> Int32 {
  // The MC buffer keeps the 16-row stride; only the partition's rows are
  // compared (larger partitions' SADs cover proportionally more samples).
  let mut sad = 0
  for row = 0; row < h; row = row + 1 {
    let sy = h264_mc_clamp(src_row + row, ph)
    for col = 0; col < w; col = col + 1 {
      let sx = h264_mc_clamp(src_col + col, pw)
      let d = src[sy * stride + sx] - mc[row * 16 + col]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
/// `h264_mv_fetch` mirror over the encoder's own per-MB state (frame MBs
/// only, single slice, single reference).
fn H264PEncoder::mv_fetch(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
) -> (Int32, Int32, Int32) {
  let ax = mb_x * 4 + bx
  let ay = mb_y * 4 + by
  if ax < 0 || ax >= self.mb_width * 4 || ay < 0 || ay >= self.mb_height * 4 {
    return (-2, 0, 0)
  }
  let nmb = if by < 0 {
    if bx < 0 {
      let tl = mb_idx - self.mb_width - 1
      let row_ok = mb_x > 0 && mb_y > 0
      if !row_ok {
        -1
      } else {
        tl
      }
    } else if bx >= 4 {
      let tr = mb_idx - self.mb_width + 1
      let row_ok = mb_x < self.mb_width - 1 && mb_y > 0
      if !row_ok {
        -1
      } else {
        tr
      }
    } else if mb_y <= 0 {
      -1
    } else {
      mb_idx - self.mb_width
    }
  } else {
    mb_y * self.mb_width + ax / 4
  }
  if nmb < 0 || nmb >= self.states.length() {
    return (-2, 0, 0)
  }
  let idx = ay % 4 * 4 + ax % 4
  // The current macroblock's own blocks read the PROGRESSIVE mirror
  // (partitions written so far), exactly like the decoder reading the
  // partially filled `mv` array of the MB being decoded.
  if nmb == mb_idx {
    return (self.cur_ref[idx], self.cur_mv[2 * idx], self.cur_mv[2 * idx + 1])
  }
  let st = self.states[nmb]
  if !st.has_data {
    return (-2, 0, 0)
  }
  if st.intra {
    return (-1, 0, 0)
  }
  (st.ref_idx[idx], st.mv[2 * idx], st.mv[2 * idx + 1])
}

///|
/// `h264_pred_motion` mirror (single reference, frame MBs). */
fn H264PEncoder::pred_motion(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
  part_w : Int32,
) -> (Int32, Int32) {
  let a = self.mv_fetch(mb_idx, mb_x, mb_y, bx - 1, by)
  let b = self.mv_fetch(mb_idx, mb_x, mb_y, bx, by - 1)
  let mut c = self.mv_fetch(mb_idx, mb_x, mb_y, bx + part_w, by - 1)
  if c.0 == -2 {
    c = self.mv_fetch(mb_idx, mb_x, mb_y, bx - 1, by - 1)
  }
  let mut match_count = 0
  if c.0 == 0 {
    match_count = match_count + 1
  }
  if b.0 == 0 {
    match_count = match_count + 1
  }
  if a.0 == 0 {
    match_count = match_count + 1
  }
  if match_count > 1 {
    (h264_mid3(a.1, b.1, c.1), h264_mid3(a.2, b.2, c.2))
  } else if match_count == 1 {
    if a.0 == 0 {
      (a.1, a.2)
    } else if b.0 == 0 {
      (b.1, b.2)
    } else {
      (c.1, c.2)
    }
  } else if b.0 == -2 && c.0 == -2 && a.0 != -2 {
    (a.1, a.2)
  } else {
    (h264_mid3(a.1, b.1, c.1), h264_mid3(a.2, b.2, c.2))
  }
}

///|
/// `h264_pred_pskip_motion` mirror. */
fn H264PEncoder::pred_pskip(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
) -> (Int32, Int32) {
  let mb_idx = mb_y * self.mb_width + mb_x
  let l = self.mv_fetch(mb_idx, mb_x, mb_y, -1, 0)
  if l.0 == -2 || (l.0 == 0 && l.1 == 0 && l.2 == 0) {
    return (0, 0)
  }
  let t = self.mv_fetch(mb_idx, mb_x, mb_y, 0, -1)
  if t.0 == -2 || (t.0 == 0 && t.1 == 0 && t.2 == 0) {
    return (0, 0)
  }
  self.pred_motion(mb_idx, mb_x, mb_y, 0, 0, 4)
}

///|
fn H264PEncoder::commit_skip(
  self : H264PEncoder,
  mb_idx : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  let st = self.states[mb_idx]
  for i = 0; i < 16; i = i + 1 {
    st.mv[2 * i] = mvx
    st.mv[2 * i + 1] = mvy
    st.ref_idx[i] = 0
  }
  st.intra = false
  st.has_data = true
  // `decode_mb_skip` (h264_mvpred.h:939) opens with
  // `memset(h->non_zero_count[mb_xy], 0, 48)`: a skipped macroblock zeroes
  // the counts, it does not inherit the previous frame's. Every macroblock
  // kind fully overwrites the slots the nC predictor reads, so nothing of
  // the previous picture survives into the next one's predictions.
  for i = 0; i < 48; i = i + 1 {
    st.nz[i] = 0
  }
  // Reconstruction: MC straight into the reconstruction planes.
  let mb_x = mb_idx % self.mb_width
  let mb_y = mb_idx / self.mb_width
  self.mc_into_rec(mb_x, mb_y, mvx, mvy, 0, 0, 16, 16)
}

///|
/// MC one region from the reference into the reconstruction planes
/// (luma 6-tap qpel + chroma bilinear), the `h264_recon_inter_mb` mirror
/// for frame macroblocks without weighting.
fn H264PEncoder::mc_into_rec(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  mvx : Int32,
  mvy : Int32,
  ox : Int32,
  oy : Int32,
  w : Int32,
  h : Int32,
) -> Unit {
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  h264_mc_luma(
    self.rec_y,
    ybase + oy * self.ystride + ox,
    self.ystride,
    self.ref_y,
    mb_x * 16 + ox + (mvx >> 2),
    mb_y * 16 + oy + (mvy >> 2),
    self.ystride,
    w,
    h,
    mvx & 3,
    mvy & 3,
    self.pwidth,
    self.pheight,
    bit_depth=8,
  )
  let cw = 16 >> 1
  let chh = 16 >> 1
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  let csx = ox >> 1
  let csy = oy >> 1
  let ccw = w >> 1
  let cch = h >> 1
  for plane_pair in [(self.rec_u, self.ref_u), (self.rec_v, self.ref_v)] {
    let (plane, ref_plane) = plane_pair
    h264_mc_chroma(
      plane,
      cbase + csy * self.cstride + csx,
      self.cstride,
      ref_plane,
      mb_x * cw + csx,
      mb_y * chh + csy,
      mvx,
      mvy,
      self.cstride,
      ccw,
      cch,
      self.pwidth / 2,
      self.pheight / 2,
    )
  }
}

///|
/// Fill the progressive mirror for one partition (`write_back_part`).
fn H264PEncoder::fill_part(
  self : H264PEncoder,
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Unit {
  for y = 0; y < bh; y = y + 1 {
    for x = 0; x < bw; x = x + 1 {
      let i = (by + y) * 4 + bx + x
      self.cur_mv[2 * i] = mvx
      self.cur_mv[2 * i + 1] = mvy
      self.cur_ref[i] = 0
    }
  }
}

///|
/// `h264_pred_16x8_motion` mirror: partition i (0 top, 1 bottom).
fn H264PEncoder::pred_16x8(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  i : Int32,
) -> (Int32, Int32) {
  if i == 0 {
    let t = self.mv_fetch(mb_idx, mb_x, mb_y, 0, -1)
    if t.0 == 0 {
      return (t.1, t.2)
    }
  } else {
    let l = self.mv_fetch(mb_idx, mb_x, mb_y, -1, 2)
    if l.0 == 0 {
      return (l.1, l.2)
    }
  }
  self.pred_motion(mb_idx, mb_x, mb_y, 0, 2 * i, 4)
}

///|
/// `h264_pred_8x16_motion` mirror: partition i (0 left, 1 right).
fn H264PEncoder::pred_8x16(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  i : Int32,
) -> (Int32, Int32) {
  if i == 0 {
    let l = self.mv_fetch(mb_idx, mb_x, mb_y, -1, 0)
    if l.0 == 0 {
      return (l.1, l.2)
    }
  } else {
    let mut diag = self.mv_fetch(mb_idx, mb_x, mb_y, 4, -1)
    if diag.0 == -2 {
      diag = self.mv_fetch(mb_idx, mb_x, mb_y, 1, -1)
    }
    if diag.0 == 0 {
      return (diag.1, diag.2)
    }
  }
  self.pred_motion(mb_idx, mb_x, mb_y, 2 * i, 0, 2)
}

///|
/// The residual-coding results of one P macroblock: everything the syntax
/// writer needs, shared by the final write and the RD evaluation.
priv struct H264PMbCode {
  luma_cbp : Int32
  chroma_c_cbp : Int32
  luma_store : Array[Int32]
  /// Intra16x16 Hadamard DC levels (all zero for inter plans).
  luma_dc_store : Array[Int32]
  chroma_dc_store : Array[Array[Int32]]
  chroma_ac_store : Array[Array[Int32]]
  /// High-profile transform_8x8: the luma residual was coded as four 8x8
  /// blocks in `luma8_store` (4 x 64 transposed levels) instead of sixteen
  /// 4x4 blocks. Always false for intra plans (I16 has no transform size).
  dct8 : Bool
  luma8_store : Array[Int32]
}

///|
/// `dct8x8_allowed` of the P-slice decoder: the PPS flag plus "every
/// sub-partition is at least 8x8" (P_L0_16x16/16x8/8x16 always qualify;
/// P_8x8 only when all four sub_mb_types are 0, i.e. plain 8x8).
fn h264_p_dct8x8_allowed(dct8x8 : Bool, plan : H264PPlan) -> Bool {
  if !dct8x8 {
    return false
  }
  match plan {
    I16(_, _, _) => false
    I4(_, _) => false
    // An I8 plan IS 8x8; the inter-tail flag logic never runs for it (the
    // intra arm writes its own unconditional flag bit after mb_type).
    I8(_, _) => true
    Part8x8(s0, s1, s2, s3, _) => s0 == 0 && s1 == 0 && s2 == 0 && s3 == 0
    Part16x16(_, _) | Part16x8(_, _, _, _) | Part8x16(_, _, _, _) => true
    Skip => false
  }
}

///|
/// Re-apply the winning intra prediction into the reconstruction planes.
/// Every `code_mb_residuals` call (RD dry runs and the final write) starts
/// from the prediction: an inter candidate leaves its own reconstruction in
/// `rec_*`, and only MC (or this helper) overwrites it.
fn H264PEncoder::predict_i16_planes(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  eff : Int32,
  chroma_sig : Int32,
) -> Unit {
  let top = mb_y > 0
  let left = mb_x > 0
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  ignore(
    h264_pred16x16(self.rec_y, ybase, self.ystride, eff, top, left, bit_depth=8),
  )
  self.predict_intra_chroma(mb_x, mb_y, chroma_sig)
}

///|
/// Lay the intra chroma prediction of both planes (`h264_pred8x8` on the
/// availability-checked mode) - shared by the I16 and I8 intra plans; the
/// luma prediction belongs to each plan's own pass.
fn H264PEncoder::predict_intra_chroma(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  chroma_sig : Int32,
) -> Unit {
  let top = mb_y > 0
  let left = mb_x > 0
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  let ceff = match h264_check_intra_pred_mode(chroma_sig, top, left) {
    Ok(v) => v
    Err(_) => 0 // pick_chroma only returns availability-feasible modes
  }
  ignore(
    h264_pred8x8(self.rec_u, cbase, self.cstride, ceff, top, left, bit_depth=8),
  )
  ignore(
    h264_pred8x8(self.rec_v, cbase, self.cstride, ceff, top, left, bit_depth=8),
  )
}

///|
/// MC every partition of `plan` into the reconstruction planes (or, for an
/// intra plan, lay down its prediction).
fn H264PEncoder::mc_plan(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
) -> Unit {
  match plan {
    Skip => ()
    I16(_, eff, cm) => self.predict_i16_planes(mb_x, mb_y, eff, cm)
    I8(_, cm) => self.predict_intra_chroma(mb_x, mb_y, cm)
    I4(_, cm) => self.predict_intra_chroma(mb_x, mb_y, cm)
    Part16x16(x, y) => self.mc_into_rec(mb_x, mb_y, x, y, 0, 0, 16, 16)
    Part16x8(tx, ty, bx, by) => {
      self.mc_into_rec(mb_x, mb_y, tx, ty, 0, 0, 16, 8)
      self.mc_into_rec(mb_x, mb_y, bx, by, 0, 8, 16, 8)
    }
    Part8x16(lx, ly, rx, ry) => {
      self.mc_into_rec(mb_x, mb_y, lx, ly, 0, 0, 8, 16)
      self.mc_into_rec(mb_x, mb_y, rx, ry, 8, 0, 8, 16)
    }
    Part8x8(_, _, _, _, mvs) => {
      let mut mi = 0
      for k = 0; k < 4; k = k + 1 {
        let x8 = k % 2
        let y8 = k / 2
        let parts2 = h264_sub_partitions(subs_of_plan(plan, k), x8, y8)
        for part in parts2 {
          let (x, y, w, h) = part
          self.mc_into_rec(mb_x, mb_y, mvs[mi], mvs[mi + 1], x, y, w, h)
          mi = mi + 2
        }
      }
    }
  }
}

///|
/// Residual coding of one P macroblock for the given plan: MC the
/// partitions, transform+quantise the residual, fill the dequantised
/// coefficient buffer and run the reconstruction. Fills `cur_nz` (the nC
/// mirror) and returns the coded stores.
fn H264PEncoder::code_mb_residuals(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
  qp : Int32,
) -> H264PMbCode {
  // `fill_decode_caches` seeds the nC cache from the persistent
  // `non_zero_count[mb_xy]`. Every slot the predictor can read is then
  // overwritten below (coded blocks get their count, uncoded ones zero),
  // so the seed never survives into a prediction - it is kept only to
  // mirror the decoder's cache lifecycle.
  let mb_idx0 = mb_y * self.mb_width + mb_x
  let is_i16 = match plan {
    I16(_, _, _) => true
    _ => false
  }
  // The CAVLC decoder's intra path starts from a zeroed non_zero_count for
  // the picture and only writes the counts its cbp actually signals; an
  // I16x16 MB with cbp&15 == 0 writes no luma counts at all. Inheriting the
  // inter macroblocks' cross-picture seed here leaks stale values into the
  // DC/AC VLC table choice (`h264_block0_nc` saw 1/13/3 where the decoder
  // saw 0) and desynchronises the bitstream from the first MB whose nc
  // crosses a table boundary.
  let is_i8 = match plan {
    I8(_, _) => true
    _ => false
  }
  let is_i4 = match plan {
    I4(_, _) => true
    _ => false
  }
  let is_intra = is_i16 || is_i8 || is_i4
  let dct8 = is_i8 || h264_p_dct8x8_allowed(self.dct8x8, plan)
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = if is_intra { 0 } else { self.states[mb_idx0].nz[i] }
  }
  if dct8 {
    // The CAVLC nC mirror of an 8x8DCT macroblock is filled progressively
    // by the syntax layer (per-sub-list counts, then the quadrant's leader
    // sum - the mirror of `h264_cavlc_luma8`); the decoder's uncoded
    // quadrants read fresh zero counts, so the seed must not survive.
    for g = 0; g < 16; g = g + 1 {
      self.cur_nz[g] = 0
    }
  }
  let mb : Array[Int32] = Array::make(768, 0)
  // Intra uses the intra dequant matrices (luma 0, chroma 1/2); inter uses
  // 3 and 4/5. The decoder picks by mb_type, so the reconstruction must
  // follow the same split or the two pictures drift apart.
  let qmul_y = h264_build_dequant4(
    self.pps,
    if is_i16 || is_i4 {
      0
    } else {
      3
    },
    qp,
  )
  let qmul8 = if dct8 {
    h264_build_dequant8(self.pps, if is_i8 { 0 } else { 3 }, qp)
  } else {
    Array::make(64, 0)
  }
  let mut luma_cbp = 0
  let luma_store : Array[Int32] = Array::make(256, 0)
  let luma8_store : Array[Int32] = Array::make(256, 0)
  let luma_dc_store : Array[Int32] = Array::make(16, 0)
  let i16_ac_nz : Array[Int32] = Array::make(16, 0)
  let chroma_ac_nz_mirror : Array[Int32] = Array::make(48, 0)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  self.mc_plan(mb_x, mb_y, plan)
  if is_i16 {
    // Intra16x16: Hadamard DC from the 16 block sums, then AC transforms
    // over the FULL residual with levels[0] discarded (§382: clearing the
    // (0,0) sample before the fdct pollutes every AC block).
    let sums : Array[Int32] = Array::make(16, 0)
    for g = 0; g < 16; g = g + 1 {
      let bx = h264_luma_block_x[g]
      let by = h264_luma_block_y[g]
      let off = ybase + by * 4 * self.ystride + bx * 4
      let mut sum = 0
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          sum = sum +
            self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      sums[by * 4 + bx] = sum
    }
    ignore(h264_enc_luma_dc_hadamard_quant(sums, 0, 4, luma_dc_store, 0, qp))
    let mut any_ac = false
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, qp)
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        let lv = if s == 0 { 0 } else { levels[s] }
        luma_store[16 * i + s] = lv
        if lv != 0 {
          total = total + 1
          mb[16 * i + s] = h264_enc_dequant_level(lv, qmul_y[s])
        }
      }
      i16_ac_nz[g] = total
      if total != 0 {
        any_ac = true
      }
    }
    if any_ac {
      luma_cbp = 15
      // The decoder writes all 16 AC counts only when cbp&15 != 0;
      // otherwise `nz` keeps the previous picture's values (our seed).
      for g = 0; g < 16; g = g + 1 {
        self.cur_nz[g] = i16_ac_nz[g]
      }
    }
  } else if is_i8 {
    // Intra 8x8 (I_NxN + transform_size_8x8_flag): the shared sequential
    // pass re-predicts each block from the plan's modes, quantises,
    // reconstructs (intra matrix 0) and fills `luma8_store`; the CAVLC nC
    // mirror is filled progressively by the syntax writer (the luma cells
    // were zeroed above - the decoder's intra path starts from fresh
    // zero counts).
    let raw_modes = match plan {
      I8(m, _) => m
      _ => abort("unreachable: is_i8 without an I8 plan")
    }
    let scratch_modes : Array[Int32] = Array::make(16, 0)
    match
      h264_enc_luma_i8_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        luma8_store,
        scratch_modes,
        mb,
        h264_enc_i8_avail(mb_x, mb_y, self.mb_width),
        fixed_modes=raw_modes,
      ) {
      Ok((_, cbp)) => luma_cbp = cbp
      Err(e) => abort("h264 enc: I8 replay failed: \{e}")
    }
  } else if is_i4 {
    // Intra 4x4 (I_NxN): the shared sequential pass re-predicts each 4x4
    // block from the plan's modes, quantises, reconstructs (intra matrix 0)
    // and fills `luma_store`; the nC mirror is set per block here like the
    // inter 4x4 path (the decoder reads fresh zero counts for uncoded blocks).
    let raw_modes = match plan {
      I4(m, _) => m
      _ => abort("unreachable: is_i4 without an I4 plan")
    }
    let scratch_modes : Array[Int32] = Array::make(16, 0)
    match
      h264_enc_luma_i4_pass(
        self.src_y,
        self.rec_y,
        self.ystride,
        mb_x,
        mb_y,
        self.pps,
        qp,
        luma_store,
        scratch_modes,
        mb,
        h264_enc_i4_avail(mb_x, mb_y, self.mb_width),
        fixed_modes=raw_modes,
      ) {
      Ok((_, cbp)) => luma_cbp = cbp
      Err(e) => abort("h264 enc: I4 replay failed: \{e}")
    }
    for i = 0; i < 16; i = i + 1 {
      let g = h264_luma_block_y[i] * 4 + h264_luma_block_x[i]
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        if luma_store[16 * i + s] != 0 {
          total = total + 1
        }
      }
      self.cur_nz[g] = total
    }
  } else if dct8 {
    // Inter 8x8DCT luma: four 8x8 blocks, cbp bit per block, each block's
    // CAVLC residual written later as four interleaved sub-lists by the
    // syntax layer (which also fills the nC mirror progressively).
    for i8 = 0; i8 < 4; i8 = i8 + 1 {
      let bx8 = i8 % 2
      let by8 = i8 / 2
      let off = ybase + by8 * 8 * self.ystride + bx8 * 8
      let res : Array[Int32] = Array::make(64, 0)
      for row = 0; row < 8; row = row + 1 {
        for col = 0; col < 8; col = col + 1 {
          res[row * 8 + col] = self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      let levels = h264_enc_fdct8_quant_res(res, 0, qp)
      let mut total = 0
      for s = 0; s < 64; s = s + 1 {
        luma8_store[64 * i8 + s] = levels[s]
        if levels[s] != 0 {
          total = total + 1
          mb[64 * i8 + s] = h264_enc_dequant_level(levels[s], qmul8[s])
        }
      }
      if total != 0 {
        luma_cbp = luma_cbp | (1 << i8)
        // `h264_idct8_add4`'s nz shortcut (see the intra path).
        if total == 1 && mb[64 * i8] != 0 {
          h264_idct8_dc_add(
            self.rec_y,
            off,
            self.ystride,
            mb,
            64 * i8,
            bit_depth=8,
          )
        } else {
          h264_idct8_add(
            self.rec_y,
            off,
            self.ystride,
            mb,
            64 * i8,
            bit_depth=8,
          )
        }
      }
    }
  } else {
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = self.src_y[off + row * self.ystride + col] -
            self.rec_y[off + row * self.ystride + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, qp)
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        luma_store[16 * i + s] = levels[s]
        if levels[s] != 0 {
          total = total + 1
          mb[16 * i + s] = h264_enc_dequant_level(levels[s], qmul_y[s])
        }
      }
      self.cur_nz[g] = total
      if total != 0 {
        luma_cbp = luma_cbp | (1 << (i / 4))
      }
    }
  }
  let qmul_c = [
    h264_build_dequant4(self.pps, if is_intra { 1 } else { 4 }, self.chroma_qp),
    h264_build_dequant4(self.pps, if is_intra { 2 } else { 5 }, self.chroma_qp),
  ]
  let chroma_dc_store : Array[Array[Int32]] = [
    Array::make(16, 0),
    Array::make(16, 0),
  ]
  let chroma_ac_store : Array[Array[Int32]] = [
    Array::make(64, 0),
    Array::make(64, 0),
  ]
  let chroma_dc_nz : Array[Bool] = [false, false]
  for c = 0; c < 2; c = c + 1 {
    let src = if c == 0 { self.src_u } else { self.src_v }
    let rec = if c == 0 { self.rec_u } else { self.rec_v }
    let sums : Array[Int32] = Array::make(4, 0)
    for i = 0; i < 4; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let mut sum = 0
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          sum = sum +
            src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      sums[i] = sum
    }
    let dc_store : Array[Int32] = Array::make(4, 0)
    ignore(h264_enc_chroma_dc_hadamard_quant(sums, dc_store, 0, self.chroma_qp))
    chroma_dc_store[c] = dc_store
    chroma_dc_nz[c] = dc_store[0] != 0 ||
      dc_store[1] != 0 ||
      dc_store[2] != 0 ||
      dc_store[3] != 0
    for s = 0; s < 4; s = s + 1 {
      let lv = dc_store[s]
      if lv != 0 {
        mb[256 + 256 * c + 16 * s] = lv
      }
    }
    for i = 0; i < 4; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let res : Array[Int32] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, self.chroma_qp)
      levels[0] = 0 // storage position 0 is the DC slot
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        chroma_ac_store[c][16 * i + s] = levels[s]
        if levels[s] != 0 {
          total = total + 1
          mb[256 + 256 * c + 16 * i + s] = h264_enc_dequant_level(
            levels[s],
            qmul_c[c][s],
          )
        }
      }
      chroma_ac_nz_mirror[16 + 16 * c + i] = total
    }
  }
  let chroma_c_cbp = if chroma_dc_nz[0] || chroma_dc_nz[1] {
    let any_ac = chroma_ac_nz_count(chroma_ac_store)
    if any_ac {
      2
    } else {
      1
    }
  } else {
    0
  }
  // The nC mirror has to follow the SYNTAX, not the quantiser output.
  // Inter decoder (`h264_cavlc.c:1136`): unsigned chroma AC is zeroed by
  // `fill_rectangle(..., 0, 1)`. Intra decoder (`h264_decode_mb_cavlc_
  // intra`): the counts are only touched when cbp&0x20 != 0, otherwise the
  // previous picture's values survive - which is exactly the seed still in
  // `cur_nz`.
  if is_intra {
    if chroma_c_cbp == 2 {
      for c = 0; c < 2; c = c + 1 {
        for i = 0; i < 4; i = i + 1 {
          self.cur_nz[16 + 16 * c + i] = chroma_ac_nz_mirror[16 + 16 * c + i]
        }
      }
    }
  } else {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
        self.cur_nz[16 + 16 * c + i] = chroma_ac_nz_mirror[16 + 16 * c + i]
      }
    }
    if chroma_c_cbp != 2 {
      for c = 0; c < 2; c = c + 1 {
        for i = 0; i < 4; i = i + 1 {
          self.cur_nz[16 + 16 * c + i] = 0
        }
      }
    }
  }
  for c = 0; c < 2; c = c + 1 {
    let plane = if c == 0 { self.rec_u } else { self.rec_v }
    if chroma_dc_nz[c] {
      h264_chroma_dc_dequant_idct(mb, 256 + 256 * c, qmul_c[c][0], bit_depth=8)
    }
    for i = 0; i < 4; i = i + 1 {
      let bx = i % 2 * 4
      let by = i / 2 * 4
      let off = cbase + by * self.cstride + bx
      let bo = 256 + 256 * c + 16 * i
      let nzv = if chroma_c_cbp == 2 {
        chroma_block_nz(chroma_ac_store[c], i)
      } else {
        0
      }
      if nzv != 0 {
        h264_idct_add(plane, off, self.cstride, mb, bo, bit_depth=8)
      } else if mb[bo] != 0 {
        h264_idct_dc_add(plane, off, self.cstride, mb, bo, bit_depth=8)
      }
    }
  }
  if is_i16 {
    // `h264_recon_mb`'s I16 order: scatter the Hadamard DC first, then the
    // per-block IDCT (or the DC-only add for blocks with no AC levels).
    let mut dc_total = 0
    for s = 0; s < 16; s = s + 1 {
      if luma_dc_store[s] != 0 {
        dc_total = dc_total + 1
      }
    }
    if dc_total > 0 {
      let dc_raw : Array[Int32] = Array::make(16, 0)
      for s = 0; s < 16; s = s + 1 {
        dc_raw[s] = luma_dc_store[s]
      }
      h264_luma_dc_dequant_idct(mb, 0, dc_raw, 0, qmul_y[0], bit_depth=8)
    }
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      if i16_ac_nz[g] != 0 {
        h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      } else if mb[16 * i] != 0 {
        h264_idct_dc_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      }
    }
  } else if !dct8 && !is_i4 {
    for i = 0; i < 16; i = i + 1 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let g = gy * 4 + gx
      let off = ybase + gy * 4 * self.ystride + gx * 4
      if (luma_cbp & (1 << (i / 4))) != 0 && self.cur_nz[g] != 0 {
        if self.cur_nz[g] == 1 && mb[16 * i] != 0 {
          h264_idct_dc_add(
            self.rec_y,
            off,
            self.ystride,
            mb,
            16 * i,
            bit_depth=8,
          )
        } else {
          h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
        }
      }
    }
  }
  {
    luma_cbp,
    chroma_c_cbp,
    luma_store,
    luma_dc_store,
    chroma_dc_store,
    chroma_ac_store,
    dct8,
    luma8_store,
  }
}

///|
/// Emit the syntax of one coded P macroblock. `mv_state` says whether the
/// mvd predictors may read the progressive mirror (`true` for the final
/// write; the RD evaluation passes `false` and zero MVs because the
/// mirror is not filled yet - mvd sizes differ by a couple of bits only,
/// and the search keeps the zero-biased MVs anyway).
fn H264PEncoder::write_mb_syntax(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
  coded : H264PMbCode,
  r : H264Rbsp,
) -> Unit {
  let mb_idx = mb_y * self.mb_width + mb_x
  let is_intra = match plan {
    I16(_, _, _) | I8(_, _) | I4(_, _) => true
    _ => false
  }
  match plan {
    Skip => return
    I8(raw_modes, chroma_mode) => {
      // Intra_NxN in a P slice: mb_type 5 is the I-slice intra table's 0
      // shifted by 5. The transform flag follows immediately (the
      // decoder's shared intra path reads it for every I_NxN once the PPS
      // enables the mode), then one prediction mode per 8x8 block, the
      // chroma mode, the INTRA cbp codeword and mb_qp_delta when cbp != 0.
      r.put_ue(5)
      r.put_bit(1) // transform_size_8x8_flag
      let cur : Array[Int32] = Array::make(16, 0)
      for k = 0; k < 4; k = k + 1 {
        for dy = 0; dy < 2; dy = dy + 1 {
          for dx = 0; dx < 2; dx = dx + 1 {
            cur[(k / 2 * 2 + dy) * 4 + k % 2 * 2 + dx] = raw_modes[k]
          }
        }
      }
      for k = 0; k < 4; k = k + 1 {
        let predicted = self.pred_nxn_mode(
          mb_idx,
          mb_x,
          mb_y,
          k % 2 * 2,
          k / 2 * 2,
          cur,
        )
        let mode = raw_modes[k]
        if mode == predicted {
          r.put_bit(1)
        } else {
          r.put_bit(0)
          r.put(if mode > predicted { mode - 1 } else { mode }, 3)
        }
      }
      r.put_ue(chroma_mode)
      let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
      r.put_ue(h264_enc_cbp_golomb(cbp))
      if cbp != 0 {
        r.put_se(self.mb_dqp) // mb_qp_delta
        self.prev_qp = self.mb_qp
        if self.mb_dqp != 0 {
          self.stats.dqp_mbs += 1
        }
      }
      self.write_luma8_cavlc(r, mb_idx, mb_x, mb_y, coded)
    }
    I4(raw_modes, chroma_mode) => {
      // Intra_NxN in a P slice: mb_type 5 (the I-slice intra table's 0
      // shifted by 5). The transform flag follows only when the PPS enables
      // 8x8DCT (the I4x4 form writes 0); then one prediction mode per 4x4
      // block, the chroma mode, the INTRA cbp codeword and mb_qp_delta when
      // cbp != 0, then the sixteen cbp-gated 4x4 luma residuals. Chroma
      // residual is the shared tail below.
      r.put_ue(5)
      if self.dct8x8 {
        r.put_bit(0) // transform_size_8x8_flag
      }
      for i = 0; i < 16; i = i + 1 {
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let g = gy * 4 + gx
        let predicted = self.pred_nxn_mode(
          mb_idx, mb_x, mb_y, gx, gy, raw_modes,
        )
        let mode = raw_modes[g]
        if mode == predicted {
          r.put_bit(1)
        } else {
          r.put_bit(0)
          r.put(if mode > predicted { mode - 1 } else { mode }, 3)
        }
      }
      r.put_ue(chroma_mode)
      let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
      r.put_ue(h264_enc_cbp_golomb(cbp))
      if cbp != 0 {
        r.put_se(self.mb_dqp) // mb_qp_delta
        self.prev_qp = self.mb_qp
        if self.mb_dqp != 0 {
          self.stats.dqp_mbs += 1
        }
      }
      for i8 = 0; i8 < 4; i8 = i8 + 1 {
        if (coded.luma_cbp & (1 << i8)) != 0 {
          for i4 = 0; i4 < 4; i4 = i4 + 1 {
            let i = i8 * 4 + i4
            let gx = h264_luma_block_x[i]
            let gy = h264_luma_block_y[i]
            let view = scan_view_at(
              coded.luma_store,
              i,
              h264_zigzag_scan_t,
              0,
              16,
            )
            let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
            ignore(h264_enc_write_residual(r, view, 16, nc))
          }
        }
      }
    }
    I16(sig, _, chroma_mode) => {
      // Intra16x16 in a P slice: mb_type 5..30 is the I-slice intra table
      // shifted by 5. The decoder derives cbp from the mb_type group, so
      // no cbp codeword is written here; mb_qp_delta is unconditional.
      let group = if coded.luma_cbp != 0 {
        3 + coded.chroma_c_cbp
      } else {
        coded.chroma_c_cbp
      }
      // Encoder pred8 numbering DC/H/V/Plane -> spec Table 7-11 V/H/DC/Plane.
      let spec_mode = match sig {
        0 => 2
        1 => 1
        2 => 0
        _ => 3
      }
      r.put_ue(5 + 1 + spec_mode + 4 * group)
      r.put_ue(chroma_mode)
      r.put_se(self.mb_dqp)
      self.prev_qp = self.mb_qp
      if self.mb_dqp != 0 {
        self.stats.dqp_mbs += 1
      }
      let dc_scan : Array[Int32] = scan_view_at(
        coded.luma_dc_store,
        0,
        h264_zigzag_scan_t,
        0,
        16,
      )
      ignore(
        h264_enc_write_residual(
          r,
          dc_scan,
          16,
          self.nc_block0(mb_idx, mb_x, mb_y),
        ),
      )
      if coded.luma_cbp != 0 {
        for i = 0; i < 16; i = i + 1 {
          let gx = h264_luma_block_x[i]
          let gy = h264_luma_block_y[i]
          let view = scan_view_at(
            coded.luma_store,
            i,
            h264_zigzag_scan_t,
            1,
            15,
          )
          let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
          let n = h264_enc_write_residual(r, view, 15, nc)
          self.cur_nz[gy * 4 + gx] = n
        }
      }
    }
    Part16x16(mvx, mvy) => {
      r.put_ue(0) // mb_type: P_L0_16x16
      let (pmvx, pmvy) = self.pred_motion(mb_idx, mb_x, mb_y, 0, 0, 4)
      r.put_se(mvx - pmvx)
      r.put_se(mvy - pmvy)
      self.fill_part(0, 0, 4, 4, mvx, mvy)
    }
    Part16x8(tx, ty, bx2, by2) => {
      r.put_ue(1) // mb_type: P_L0_16x8
      let (p0x, p0y) = self.pred_16x8(mb_idx, mb_x, mb_y, 0)
      r.put_se(tx - p0x)
      r.put_se(ty - p0y)
      self.fill_part(0, 0, 4, 2, tx, ty)
      let (p1x, p1y) = self.pred_16x8(mb_idx, mb_x, mb_y, 1)
      r.put_se(bx2 - p1x)
      r.put_se(by2 - p1y)
      self.fill_part(0, 2, 4, 2, bx2, by2)
    }
    Part8x16(lx, ly, rx, ry) => {
      r.put_ue(2) // mb_type: P_L0_8x16
      let (p0x, p0y) = self.pred_8x16(mb_idx, mb_x, mb_y, 0)
      r.put_se(lx - p0x)
      r.put_se(ly - p0y)
      self.fill_part(0, 0, 2, 4, lx, ly)
      let (p1x, p1y) = self.pred_8x16(mb_idx, mb_x, mb_y, 1)
      r.put_se(rx - p1x)
      r.put_se(ry - p1y)
      self.fill_part(2, 0, 2, 4, rx, ry)
    }
    Part8x8(s0, s1, s2, s3, mvs) => {
      r.put_ue(3) // mb_type: P_8x8
      r.put_ue(s0)
      r.put_ue(s1)
      r.put_ue(s2)
      r.put_ue(s3)
      let subs = [s0, s1, s2, s3]
      let mut mi = 0
      for k = 0; k < 4; k = k + 1 {
        let x8 = k % 2
        let y8 = k / 2
        let parts2 = h264_sub_partitions(subs[k], x8, y8)
        for part in parts2 {
          let (x, y, w, h) = part
          let mvx = mvs[mi]
          let mvy = mvs[mi + 1]
          mi = mi + 2
          let (pmvx, pmvy) = self.pred_motion(
            mb_idx,
            mb_x,
            mb_y,
            x / 4,
            y / 4,
            w / 4,
          )
          r.put_se(mvx - pmvx)
          r.put_se(mvy - pmvy)
          self.fill_part(x / 4, y / 4, w / 4, h / 4, mvx, mvy)
        }
      }
    }
  }
  if !is_intra {
    let cbp = coded.luma_cbp | (coded.chroma_c_cbp << 4)
    r.put_ue(h264_enc_inter_cbp_golomb(cbp))
    // transform_size_8x8_flag sits between the cbp codeword and
    // mb_qp_delta: the decoder reads it whenever dct8x8_allowed holds and
    // the luma cbp is non-zero (`h264_inter_residual_cavlc`).
    if h264_p_dct8x8_allowed(self.dct8x8, plan) && (cbp & 15) != 0 {
      r.put_bit(if coded.dct8 { 1 } else { 0 })
    }
    if cbp != 0 {
      r.put_se(self.mb_dqp) // mb_qp_delta
      self.prev_qp = self.mb_qp
      if self.mb_dqp != 0 {
        self.stats.dqp_mbs += 1
      }
    }
    if coded.dct8 {
      self.write_luma8_cavlc(r, mb_idx, mb_x, mb_y, coded)
    } else {
      for i8 = 0; i8 < 4; i8 = i8 + 1 {
        if (coded.luma_cbp & (1 << i8)) != 0 {
          for i4 = 0; i4 < 4; i4 = i4 + 1 {
            let i = i8 * 4 + i4
            let gx = h264_luma_block_x[i]
            let gy = h264_luma_block_y[i]
            let view = scan_view_at(
              coded.luma_store,
              i,
              h264_zigzag_scan_t,
              0,
              16,
            )
            let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
            ignore(h264_enc_write_residual(r, view, 16, nc))
          }
        }
      }
    }
  }
  // Chroma residual syntax is shared by inter and intra P macroblocks.
  if coded.chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
      let dc4 : Array[Int32] = [
        coded.chroma_dc_store[c][0],
        coded.chroma_dc_store[c][1],
        coded.chroma_dc_store[c][2],
        coded.chroma_dc_store[c][3],
      ]
      ignore(h264_enc_write_residual(r, dc4, 4, 0))
    }
  }
  if coded.chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
        let view = scan_view_at(
          coded.chroma_ac_store[c],
          i,
          h264_zigzag_scan_t,
          1,
          15,
        )
        let nc = self.nc_chroma(mb_idx, mb_x, mb_y, c, i)
        ignore(h264_enc_write_residual(r, view, 15, nc))
      }
    }
  }
}

///|
/// 8x8DCT luma residual in CAVLC (the mirror of `h264_cavlc_luma8`): four
/// interleaved 16-coefficient lists per coded quadrant, the nC of each
/// derived at its own 4x4 grid cell and filled into the mirror as it is
/// written, then the quadrant's leader cell accumulates the quadrant total
/// (`nnz[0] += nnz[1] + nnz[8] + nnz[9]`). Shared by the inter 8x8 residual
/// and the Intra 8x8 macroblock.
fn H264PEncoder::write_luma8_cavlc(
  self : H264PEncoder,
  r : H264Rbsp,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  coded : H264PMbCode,
) -> Unit {
  for q = 0; q < 4; q = q + 1 {
    if (coded.luma_cbp & (1 << q)) != 0 {
      for sub = 0; sub < 4; sub = sub + 1 {
        let index = 4 * q + sub
        let gx = h264_luma_block_x[index]
        let gy = h264_luma_block_y[index]
        let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
        let view = h264_cavlc8_sub_view(coded.luma8_store, q, sub)
        self.cur_nz[gy * 4 + gx] = h264_enc_write_residual(r, view, 16, nc)
      }
      let leader = h264_luma_block_grid[4 * q]
      self.cur_nz[leader] = self.cur_nz[leader] +
        self.cur_nz[leader + 1] +
        self.cur_nz[leader + 4] +
        self.cur_nz[leader + 5]
    }
  }
}

///|
/// `h264_pred_intra_mode` mirror for the P encoder: the minimum of the
/// left/top signalled modes. A neighbour macroblock contributes its modes
/// only when it is Intra_NxN (`intra_nxn`), DC (2) when it is any other
/// available macroblock; an unavailable neighbour forces DC. `cur` holds
/// the current macroblock's modes on the 4x4 grid.
fn H264PEncoder::pred_nxn_mode(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  gx : Int32,
  gy : Int32,
  cur : Array[Int32],
) -> Int32 {
  let left = if gx > 0 {
    cur[gy * 4 + gx - 1]
  } else if mb_x > 0 {
    let li = self.states[mb_idx - 1]
    if li.intra_nxn {
      li.modes[gy * 4 + 3]
    } else {
      2
    }
  } else {
    -1
  }
  let top = if gy > 0 {
    cur[(gy - 1) * 4 + gx]
  } else if mb_y > 0 {
    let ti = self.states[mb_idx - self.mb_width]
    if ti.intra_nxn {
      ti.modes[3 * 4 + gx]
    } else {
      2
    }
  } else {
    -1
  }
  if left < 0 || top < 0 {
    2
  } else if left < top {
    left
  } else {
    top
  }
}

///|
/// Commit the mirror state after writing the winning plan.
fn H264PEncoder::commit_plan_state(
  self : H264PEncoder,
  mb_idx : Int32,
  plan : H264PPlan,
) -> Unit {
  let st = self.states[mb_idx]
  for i = 0; i < 16; i = i + 1 {
    st.mv[2 * i] = self.cur_mv[2 * i]
    st.mv[2 * i + 1] = self.cur_mv[2 * i + 1]
    st.ref_idx[i] = self.cur_ref[i]
  }
  // An intra macroblock in a P slice makes its MVs unavailable to the
  // neighbours' motion predictors (decoder: `IS_INTRA` -> ref_cache -1).
  st.intra = match plan {
    I16(_, _, _) | I8(_, _) | I4(_, _) => true
    _ => false
  }
  st.has_data = true
  for i = 0; i < 48; i = i + 1 {
    st.nz[i] = self.cur_nz[i]
  }
  // Intra_NxN mirror for the neighbours' mode predictor.
  match plan {
    I8(raw_modes, _) => {
      st.intra_nxn = true
      for k = 0; k < 4; k = k + 1 {
        for dy = 0; dy < 2; dy = dy + 1 {
          for dx = 0; dx < 2; dx = dx + 1 {
            st.modes[(k / 2 * 2 + dy) * 4 + k % 2 * 2 + dx] = raw_modes[k]
          }
        }
      }
    }
    I4(raw_modes, _) => {
      st.intra_nxn = true
      for g = 0; g < 16; g = g + 1 {
        st.modes[g] = raw_modes[g]
      }
    }
    _ => st.intra_nxn = false
  }
}

///|
/// Write one coded P macroblock: residual coding + syntax + state commit.
fn H264PEncoder::write_coded_mb(
  self : H264PEncoder,
  mb_x : Int32,
  mb_y : Int32,
  plan : H264PPlan,
  r : H264Rbsp,
  qp : Int32,
) -> Result[Unit, String] {
  for i = 0; i < 32; i = i + 1 {
    self.cur_mv[i] = 0
  }
  for i = 0; i < 16; i = i + 1 {
    self.cur_ref[i] = -2
  }
  let coded = self.code_mb_residuals(mb_x, mb_y, plan, qp)
  if coded.dct8 {
    self.stats.i8_mbs += 1
  }
  self.write_mb_syntax(mb_x, mb_y, plan, coded, r)
  let mb_idx = mb_y * self.mb_width + mb_x
  self.commit_plan_state(mb_idx, plan)
  Ok(())
}

///|
/// The k-th sub type of an 8x8 plan (helper for the parts enumeration).
fn subs_of_plan(plan : H264PPlan, k : Int32) -> Int32 {
  match plan {
    Part8x8(s0, s1, s2, s3, _) =>
      match k {
        0 => s0
        1 => s1
        2 => s2
        _ => s3
      }
    _ => 0
  }
}

///|
/// nC for the I16x16 luma DC block (`h264_block0_nc`): the retained counts
/// of luma block 0's left/top neighbours, from the persistent mirror.
fn H264PEncoder::nc_block0(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let left = if mb_x > 0 { self.states[mb_idx - 1].nz[3] } else { 64 }
  let top = if mb_y > 0 {
    self.states[mb_idx - self.mb_width].nz[12]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
fn H264PEncoder::nc_luma(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  gx : Int32,
  gy : Int32,
) -> Int32 {
  let left = if gx > 0 {
    self.cur_nz[gy * 4 + gx - 1]
  } else if mb_x > 0 {
    self.states[mb_idx - 1].nz[gy * 4 + 3]
  } else {
    64
  }
  let top = if gy > 0 {
    self.cur_nz[(gy - 1) * 4 + gx]
  } else if mb_y > 0 {
    self.states[mb_idx - self.mb_width].nz[3 * 4 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
fn H264PEncoder::nc_chroma(
  self : H264PEncoder,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  c : Int32,
  i : Int32,
) -> Int32 {
  let base = 16 + 16 * c
  let gx = i % 2
  let gy = i / 2
  let left = if gx > 0 {
    self.cur_nz[base + i - 1]
  } else if mb_x > 0 {
    self.states[mb_idx - 1].nz[base + 1 + 2 * gy]
  } else {
    64
  }
  let top = if gy > 0 {
    self.cur_nz[base + i - 2]
  } else if mb_y > 0 {
    self.states[mb_idx - self.mb_width].nz[base + 2 + gx]
  } else {
    64
  }
  h264_pred_non_zero_count(left, top)
}

///|
/// Inverse of `h264_golomb_to_inter_cbp` (48-entry 4:2:0 table). */
fn h264_enc_inter_cbp_golomb(cbp : Int32) -> Int32 {
  for i = 0; i < 48; i = i + 1 {
    if h264_golomb_to_inter_cbp[i] == cbp {
      return i
    }
  }
  0
}
