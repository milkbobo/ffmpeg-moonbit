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
  mv : Array[Int]
  /// L0 reference per 4x4 block: -1 intra, -2 unavailable.
  ref_idx : Array[Int]
  mut intra : Bool
  mut has_data : Bool
  nz : Array[Int]
}

///|
fn new_h264_p_mb_state() -> H264PMbState {
  {
    mv: Array::make(32, 0),
    ref_idx: Array::make(16, -2),
    intra: false,
    has_data: false,
    nz: Array::make(48, 0),
  }
}

///|
priv struct H264PEncoder {
  p : H264EncParams
  pps : H264Pps
  chroma_qp : Int
  /// Source planes of the frame being encoded (mb-aligned strides).
  src_y : Array[Int]
  src_u : Array[Int]
  src_v : Array[Int]
  /// Reconstruction planes (become the next reference).
  rec_y : Array[Int]
  rec_u : Array[Int]
  rec_v : Array[Int]
  /// Reference planes (previous frame's reconstruction).
  ref_y : Array[Int]
  ref_u : Array[Int]
  ref_v : Array[Int]
  ystride : Int
  cstride : Int
  pwidth : Int
  pheight : Int
  mb_width : Int
  mb_height : Int
  states : Array[H264PMbState]
  /// Current MB's mirror (mv/ref/nz) while coding.
  cur_nz : Array[Int]
}

///|
/// Encode a frame sequence: the first frame as IDR I (the intra encoder),
/// every following frame as a P picture referencing the previous frame's
/// reconstruction. Returns the Annex B stream.
pub fn h264_encode_frames(
  frames : Array[(Bytes, Bytes, Bytes)],
  width~ : Int,
  height~ : Int,
  qp~ : Int = 26,
  level_idc~ : Int = 30,
  pcm_first~ : Bool = false,
) -> Result[Bytes, String] {
  if frames.length() == 0 {
    return Err("h264 enc: no frames")
  }
  let (y0, u0, v0) = frames[0]
  let first = match
    h264_encode_intra_frame(
      y0,
      u0,
      v0,
      width~,
      height~,
      qp~,
      level_idc~,
      pcm=pcm_first,
    ) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let p = { width, height, qp, level_idc }
  let mb_width = p.mb_width()
  let mb_height = p.mb_height()
  let ystride = mb_width * 16
  let cstride = mb_width * 8
  let pheight = mb_height * 16
  let ps = new_h264_param_sets()
  match
    ff_h264_decode_seq_parameter_set(
      BitReader::new(h264_enc_sps_rbsp(p)),
      ps,
      false,
    ) {
    Ok(_) => ()
    Err(e) => return Err("h264 enc: SPS round-trip failed: \{e}")
  }
  let pps_raw = h264_enc_pps_rbsp(p)
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
  let chroma_qp = h264_get_chroma_qp(pps, 0, qp)
  fn load_plane(
    src : Bytes,
    w : Int,
    h : Int,
    stride : Int,
    plane_h : Int,
  ) -> Array[Int] {
    let plane : Array[Int] = Array::make(stride * plane_h, 0)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        plane[row * stride + col] = src[row * w + col].to_int()
      }
    }
    plane
  }
  let stream : Array[Bytes] = [first.annexb]
  // Reference = the I frame's reconstruction (deep copy: P recon replaces
  // the reference each frame).
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
  for f = 1; f < frames.length(); f = f + 1 {
    let (y, u, v) = frames[f]
    let enc : H264PEncoder = {
      p,
      pps,
      chroma_qp,
      src_y: load_plane(y, width, height, ystride, pheight),
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
    }
    // frame_num increments per reference frame: the IDR carries 0.
    let nal = match enc.encode_p_frame(f) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    stream.push(nal)
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
  // Concatenate.
  let out : Array[Byte] = []
  for part in stream {
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Ok(Bytes::from_array(out[:]))
}

///|
fn H264PEncoder::encode_p_frame(
  self : H264PEncoder,
  frame_num : Int,
) -> Result[Bytes, String] {
  // Reset the per-frame mirror (fresh picture).
  for k = 0; k < self.states.length(); k = k + 1 {
    let st = self.states[k]
    for i = 0; i < 32; i = i + 1 {
      st.mv[i] = 0
    }
    for i = 0; i < 16; i = i + 1 {
      st.ref_idx[i] = -2
    }
    st.intra = false
    for i = 0; i < 48; i = i + 1 {
      st.nz[i] = 0
    }
  }
  let r = H264Rbsp::new()
  r.put_ue(0) // first_mb_in_slice
  r.put_ue(5) // slice_type: P (all slices)
  r.put_ue(0) // pic_parameter_set_id
  r.put(frame_num & 15, 4) // frame_num (log2_max_frame_num = 4)
  // num_ref_idx_active_override_flag = 0 (PPS default 1 reference)
  r.put_bit(0)
  // ref_pic_list_modification: ref_pic_list_modification_flag_l0 = 0
  r.put_bit(0)
  // dec_ref_pic_marking (nal_ref_idc != 0, non-IDR):
  r.put_bit(0) // adaptive_ref_pic_marking_mode_flag
  r.put_se(0) // slice_qp_delta
  let qp = self.p.qp
  let mut skip_run = 0
  for mb_y = 0; mb_y < self.mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < self.mb_width; mb_x = mb_x + 1 {
      let mb_idx = mb_y * self.mb_width + mb_x
      let decision = self.decide_macroblock(mb_x, mb_y)
      if true {
  
      }
      if decision.skip {
        skip_run = skip_run + 1
        self.commit_skip(mb_idx, decision.mvx, decision.mvy)
        continue
      }
      // A coded macroblock ends the skip run.
      r.put_ue(skip_run)
      skip_run = 0
      match self.write_coded_mb(mb_x, mb_y, decision, r, qp) {
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
priv struct H264PDecision {
  skip : Bool
  mvx : Int
  mvy : Int
}

///|
/// Motion search + mode decision for one macroblock. Integer-pel SAD over
/// a +-16 window in raster order (strictly-better keeps the first best,
/// which makes the search deterministic), then a quarter-pel refinement
/// over the 3x3 subpel neighbourhood through the decoder's own MC filter.
fn H264PEncoder::decide_macroblock(
  self : H264PEncoder,
  mb_x : Int,
  mb_y : Int,
) -> H264PDecision {
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  // Integer-pel search. The zero MV is evaluated first and later
  // candidates must be STRICTLY better - translation-invariant content
  // (gradients, flat areas) ties many MVs at the same SAD, and the zero
  // bias keeps those deterministic and cheap.
  let mut best_x = 0
  let mut best_y = 0
  let mut best_sad = h264_p_sad_int(
    self.src_y,
    self.ref_y,
    ybase,
    self.ystride,
    mb_x * 16,
    mb_y * 16,
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
        ybase,
        self.ystride,
        mb_x * 16 + dx,
        mb_y * 16 + dy,
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
  // Quarter-pel refinement: the 3x3 subpel neighbourhood of the best
  // integer position, evaluated through the decoder's MC filter.
  let mcbuf : Array[Int] = Array::make(256, 0)
  let mut best_qx = best_x * 4
  let mut best_qy = best_y * 4
  // The integer-pel candidate seeds the refinement (zero-subpel bias).
  h264_mc_luma(
    mcbuf,
    0,
    16,
    self.ref_y,
    mb_x * 16 + (best_qx >> 2),
    mb_y * 16 + (best_qy >> 2),
    self.ystride,
    16,
    16,
    best_qx & 3,
    best_qy & 3,
    self.pwidth,
    self.pheight,
    bit_depth=8,
  )
  let mut best_qsad = h264_p_sad_mc(self.src_y, mcbuf, ybase, self.ystride)
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
          mb_x * 16 + (qx >> 2),
          mb_y * 16 + (qy >> 2),
          self.ystride,
          16,
          16,
          qx & 3,
          qy & 3,
          self.pwidth,
          self.pheight,
          bit_depth=8,
        )
        let sad = h264_p_sad_mc(self.src_y, mcbuf, ybase, self.ystride)
        if best_qsad < 0 || sad < best_qsad {
          best_qsad = sad
          best_qx = qx
          best_qy = qy
        }
      }
    }
  }
  // Skip check: the P_Skip predictor MV with zero residual.
  let (pmvx, pmvy) = self.pred_pskip(mb_x, mb_y)
  h264_mc_luma(
    mcbuf,
    0,
    16,
    self.ref_y,
    mb_x * 16 + (pmvx >> 2),
    mb_y * 16 + (pmvy >> 2),
    self.ystride,
    16,
    16,
    pmvx & 3,
    pmvy & 3,
    self.pwidth,
    self.pheight,
    bit_depth=8,
  )
  let skip_sad = h264_p_sad_mc(self.src_y, mcbuf, ybase, self.ystride)
  if skip_sad == 0 && pmvx == best_qx && pmvy == best_qy {
    return { skip: true, mvx: pmvx, mvy: pmvy }
  }
  { skip: false, mvx: best_qx, mvy: best_qy }
}

///|
fn h264_p_sad_int(
  src : Array[Int],
  ref_plane : Array[Int],
  src_off : Int,
  stride : Int,
  ref_x : Int,
  ref_y : Int,
  pw : Int,
  ph : Int,
) -> Int {
  // Edge replication matches the MC clamp: the +-16 search window reads
  // outside the plane near picture borders.
  let mut sad = 0
  for row = 0; row < 16; row = row + 1 {
    let ry = h264_mc_clamp(ref_y + row, ph)
    let srow = src_off + row * stride
    for col = 0; col < 16; col = col + 1 {
      let rx = h264_mc_clamp(ref_x + col, pw)
      let d = src[srow + col] - ref_plane[ry * stride + rx]
      sad = sad + (if d < 0 { -d } else { d })
    }
  }
  sad
}

///|
fn h264_p_sad_mc(
  src : Array[Int],
  mc : Array[Int],
  src_off : Int,
  stride : Int,
) -> Int {
  let mut sad = 0
  for row = 0; row < 16; row = row + 1 {
    for col = 0; col < 16; col = col + 1 {
      let d = src[src_off + row * stride + col] - mc[row * 16 + col]
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
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  bx : Int,
  by : Int,
) -> (Int, Int, Int) {
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
    } else {
      if mb_y <= 0 {
        -1
      } else {
        mb_idx - self.mb_width
      }
    }
  } else {
    mb_y * self.mb_width + ax / 4
  }
  if nmb < 0 || nmb >= self.states.length() {
    return (-2, 0, 0)
  }
  let st = self.states[nmb]
  if nmb != mb_idx && !st.has_data {
    return (-2, 0, 0)
  }
  if st.intra {
    return (-1, 0, 0)
  }
  let idx = (ay % 4) * 4 + ax % 4
  (st.ref_idx[idx], st.mv[2 * idx], st.mv[2 * idx + 1])
}

///|
/// `h264_pred_motion` mirror (single reference, frame MBs). */
fn H264PEncoder::pred_motion(
  self : H264PEncoder,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  bx : Int,
  by : Int,
  part_w : Int,
) -> (Int, Int) {
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
  mb_x : Int,
  mb_y : Int,
) -> (Int, Int) {
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
  mb_idx : Int,
  mvx : Int,
  mvy : Int,
) -> Unit {
  let st = self.states[mb_idx]
  for i = 0; i < 16; i = i + 1 {
    st.mv[2 * i] = mvx
    st.mv[2 * i + 1] = mvy
    st.ref_idx[i] = 0
  }
  st.intra = false
  st.has_data = true
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
  mb_x : Int,
  mb_y : Int,
  mvx : Int,
  mvy : Int,
  ox : Int,
  oy : Int,
  w : Int,
  h : Int,
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
/// Write one coded P_L0_16x16 macroblock: syntax, residual, reconstruction
/// and the mirror-state commit.
fn H264PEncoder::write_coded_mb(
  self : H264PEncoder,
  mb_x : Int,
  mb_y : Int,
  decision : H264PDecision,
  r : H264Rbsp,
  qp : Int,
) -> Result[Unit, String] {
  let mb_idx = mb_y * self.mb_width + mb_x
  for i = 0; i < 48; i = i + 1 {
    self.cur_nz[i] = 0
  }
  let mvx = decision.mvx
  let mvy = decision.mvy
  // mvd relative to the median predictor (ref 0 always present here).
  let (pmvx, pmvy) = self.pred_motion(mb_idx, mb_x, mb_y, 0, 0, 4)
  // ---- residual + reconstruction before syntax (nz needed for nC) ----
  let mb : Array[Int] = Array::make(768, 0)
  let qmul_y = h264_build_dequant4(self.pps, 3, qp)
  let mut luma_cbp = 0
  let luma_store : Array[Int] = Array::make(256, 0)
  let ybase = mb_y * 16 * self.ystride + mb_x * 16
  let cbase = mb_y * 8 * self.cstride + mb_x * 8
  // MC the chosen MV into the reconstruction planes first (the residual
  // transform reads prediction + source from there).
  self.mc_into_rec(mb_x, mb_y, mvx, mvy, 0, 0, 16, 16)
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * self.ystride + gx * 4
    let res : Array[Int] = Array::make(16, 0)
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
  // Chroma residuals (dequant matrices 4/5, DC 4 + AC 15 like intra).
  let qmul_c = [
    h264_build_dequant4(self.pps, 4, self.chroma_qp),
    h264_build_dequant4(self.pps, 5, self.chroma_qp),
  ]
  let chroma_dc_store : Array[Array[Int]] = [
    Array::make(16, 0),
    Array::make(16, 0),
  ]
  let chroma_ac_store : Array[Array[Int]] = [
    Array::make(64, 0),
    Array::make(64, 0),
  ]
  let chroma_dc_nz : Array[Bool] = [false, false]
  for c = 0; c < 2; c = c + 1 {
    let src = if c == 0 { self.src_u } else { self.src_v }
    let rec = if c == 0 { self.rec_u } else { self.rec_v }
    let sums : Array[Int] = Array::make(4, 0)
    for i = 0; i < 4; i = i + 1 {
      let bx = (i % 2) * 4
      let by = (i / 2) * 4
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
    let dc_store : Array[Int] = Array::make(4, 0)
    ignore(
      h264_enc_chroma_dc_hadamard_quant(
        sums,
        dc_store,
        0,
        self.chroma_qp,
      ),
    )
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
      let bx = (i % 2) * 4
      let by = (i / 2) * 4
      let res : Array[Int] = Array::make(16, 0)
      for row = 0; row < 4; row = row + 1 {
        for col = 0; col < 4; col = col + 1 {
          res[row * 4 + col] = src[cbase + (by + row) * self.cstride + bx + col] -
            rec[cbase + (by + row) * self.cstride + bx + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(
        res,
        0,
        self.chroma_qp,
      )
      levels[0] = 0 // storage position 0 is the DC slot
      let mut total = 0
      for s = 0; s < 16; s = s + 1 {
        chroma_ac_store[c][16 * i + s] = levels[s]
        if levels[s] != 0 {
          total = total + 1
          mb[256 + 256 * c + 16 * i + s] = h264_enc_dequant_level(levels[s], qmul_c[c][s])
        }
      }
      self.cur_nz[16 + 16 * c + i] = total
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
  // Chroma reconstruction (AC levels exist only when ccbp == 2).
  for c = 0; c < 2; c = c + 1 {
    let plane = if c == 0 { self.rec_u } else { self.rec_v }
    if chroma_dc_nz[c] {
      h264_chroma_dc_dequant_idct(
        mb,
        256 + 256 * c,
        qmul_c[c][0],
        bit_depth=8,
      )
    }
    for i = 0; i < 4; i = i + 1 {
      let bx = (i % 2) * 4
      let by = (i / 2) * 4
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
  // Luma reconstruction (per-8x8 cbp bits, inter dequant already applied).
  for i = 0; i < 16; i = i + 1 {
    let gx = h264_luma_block_x[i]
    let gy = h264_luma_block_y[i]
    let g = gy * 4 + gx
    let off = ybase + gy * 4 * self.ystride + gx * 4
    if (luma_cbp & (1 << (i / 4))) != 0 && self.cur_nz[g] != 0 {
      if self.cur_nz[g] == 1 && mb[16 * i] != 0 {
        h264_idct_dc_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      } else {
        h264_idct_add(self.rec_y, off, self.ystride, mb, 16 * i, bit_depth=8)
      }
    }
  }
  // ---- syntax ----
  r.put_ue(0) // mb_type: P_L0_16x16
  // ref_idx_l0: one reference active -> not coded.
  let mvdx = mvx - pmvx
  let mvdy = mvy - pmvy
  r.put_se(mvdx)
  r.put_se(mvdy)
  let cbp = luma_cbp | (chroma_c_cbp << 4)
  r.put_ue(h264_enc_inter_cbp_golomb(cbp))
  if cbp != 0 {
    r.put_se(0) // mb_qp_delta
  }
  // Luma residual: inter blocks code all 16 coefficients (scan start 0).
  for i8 = 0; i8 < 4; i8 = i8 + 1 {
    if (luma_cbp & (1 << i8)) != 0 {
      for i4 = 0; i4 < 4; i4 = i4 + 1 {
        let i = i8 * 4 + i4
        let gx = h264_luma_block_x[i]
        let gy = h264_luma_block_y[i]
        let view = scan_view_at(luma_store, i, h264_zigzag_scan_t, 0, 16)
        let nc = self.nc_luma(mb_idx, mb_x, mb_y, gx, gy)
        ignore(h264_enc_write_residual(r, view, 16, nc))
      }
    }
  }
  if chroma_c_cbp != 0 {
    for c = 0; c < 2; c = c + 1 {
      let dc4 : Array[Int] = [
        chroma_dc_store[c][0],
        chroma_dc_store[c][1],
        chroma_dc_store[c][2],
        chroma_dc_store[c][3],
      ]
      ignore(h264_enc_write_residual(r, dc4, 4, 0))
    }
  }
  if chroma_c_cbp == 2 {
    for c = 0; c < 2; c = c + 1 {
      for i = 0; i < 4; i = i + 1 {
        let view = scan_view_at(
          chroma_ac_store[c],
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
  // Commit the mirror state.
  let st = self.states[mb_idx]
  for i = 0; i < 16; i = i + 1 {
    st.mv[2 * i] = mvx
    st.mv[2 * i + 1] = mvy
    st.ref_idx[i] = 0
  }
  st.intra = false
  st.has_data = true
  for i = 0; i < 48; i = i + 1 {
    st.nz[i] = self.cur_nz[i]
  }
  Ok(())
}

///|
fn H264PEncoder::nc_luma(
  self : H264PEncoder,
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  gx : Int,
  gy : Int,
) -> Int {
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
  mb_idx : Int,
  mb_x : Int,
  mb_y : Int,
  c : Int,
  i : Int,
) -> Int {
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
fn h264_enc_inter_cbp_golomb(cbp : Int) -> Int {
  for i = 0; i < 48; i = i + 1 {
    if h264_golomb_to_inter_cbp[i] == cbp {
      return i
    }
  }
  0
}
