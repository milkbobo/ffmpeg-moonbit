///|
/// §447c integer-pel motion estimation: per-64x64-superblock exhaustive
/// full-pel SAD search against the reference luma plane. The candidate
/// cost mirrors the decoder's MC exactly — `av1_mc_sample` clamps
/// out-of-picture reads to the edge — so the SAD the encoder minimizes
/// is the SAD the reconstruction will realize. Ties prefer the smaller
/// displacement (then smaller dy, dx), keeping the output deterministic
/// and the MV coding cheap.

///|
/// Full-pel SAD search over every 64x64 superblock of a
/// 64-multiple-geometry frame. Returns per-SB `(mvs_y, mvs_x)` arrays
/// in raster order; `range` bounds the search to ±range pixels.
pub fn av1_enc_me_fullpel_sad(
  src : FixedArray[Int32],
  src_stride : Int32,
  refimg : FixedArray[Int32],
  ref_stride : Int32,
  width : Int32,
  height : Int32,
  range~ : Int32 = 16,
) -> Result[(FixedArray[Int32], FixedArray[Int32]), String] {
  if width <= 0 || height <= 0 || width % 64 != 0 || height % 64 != 0 {
    return Err(
      "av1 enc: me needs 64-multiple geometry (got \{width}x\{height})",
    )
  }
  if range < 0 || range > 1024 {
    return Err("av1 enc: me range must be 0..=1024")
  }
  let sb_cols = width >> 6
  let sb_rows = height >> 6
  let mvs_y = FixedArray::make(sb_cols * sb_rows, 0)
  let mvs_x = FixedArray::make(sb_cols * sb_rows, 0)
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  for sby in 0..<sb_rows {
    for sbx in 0..<sb_cols {
      let y0 = sby * 64
      let x0 = sbx * 64
      let mut best = -1
      let mut best_dy = 0
      let mut best_dx = 0
      for dy in -range..<=range {
        for dx in -range..<=range {
          let mut sad = 0
          for y in 0..<64 {
            let sy = clamp(y0 + y + dy, height)
            let srow = (y0 + y) * src_stride
            let rrow = sy * ref_stride
            for x in 0..<64 {
              let sx = clamp(x0 + x + dx, width)
              let d = src[srow + x0 + x] - refimg[rrow + sx]
              sad = sad + (if d < 0 { -d } else { d })
            }
          }
          // Tie-break: cheaper displacement (|dy|+|dx|, then dy, dx).
          let cost = (if dy < 0 { -dy } else { dy }) +
            (if dx < 0 { -dx } else { dx })
          let better = if best < 0 {
            true
          } else if sad != best {
            sad < best
          } else {
            let bc = (if best_dy < 0 { -best_dy } else { best_dy }) +
              (if best_dx < 0 { -best_dx } else { best_dx })
            cost < bc ||
            (cost == bc && (dy < best_dy || (dy == best_dy && dx < best_dx)))
          }
          if better {
            best = sad
            best_dy = dy
            best_dx = dx
          }
        }
      }
      let sb = sby * sb_cols + sbx
      mvs_y[sb] = best_dy
      mvs_x[sb] = best_dx
    }
  }
  Ok((mvs_y, mvs_x))
}

///|
/// Encode a per-superblock ME + dc-token inter frame OBU (§447c): the
/// header via `av1_enc_write_inter_frame_obu` (default config) and one
/// `av1_enc_write_me_dc_tile` payload. Same reference-store contract as
/// the other inter entries (the preceding key frame refreshed it).
pub fn av1_enc_write_me_dc_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  base_q_idx~ : Int32 = 100,
  mvs_y~ : FixedArray[Int32],
  mvs_x~ : FixedArray[Int32],
  dc_toks~ : FixedArray[Int32],
  dc_signs~ : FixedArray[Int32],
) -> Result[Bytes, String] {
  if seq.width % 64 != 0 || seq.height % 64 != 0 {
    return Err(
      "av1 enc: me inter frame needs 64-multiple geometry (got \{seq.width}x\{seq.height})",
    )
  }
  let rf : Av1Rf = {
    iw4: 0,
    ih4: 0,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp: false,
    force_integer_mv: false,
    use_ref_frame_mvs: false,
    gm_types: FixedArray::make(7, 0),
    gm_matrices: FixedArray::makei(7, _ => FixedArray::make(6, 0)),
  }
  let prepared = match
    refs.prepare_frame(
      [0, 0, 0, 0, 0, 0, 0],
      seq.order_hint_bits,
      0,
      seq.width,
      seq.height,
      false,
      rf,
      16,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let tile = match
    av1_enc_write_me_dc_tile(
      prepared,
      seq.width,
      seq.height,
      base_q_idx,
      mvs_y,
      mvs_x,
      dc_toks,
      dc_signs,
      mono=seq.monochrome,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let obu = match
    av1_enc_write_inter_frame_obu(seq, {
      ..Av1InterFrameEncConfig::default(),
      base_q_idx,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  refs.refresh(prepared, 1)
  Ok(obu)
}

///|
/// Encode a uniform sub-pel skip-only inter frame OBU (§448): the
/// header via `av1_enc_write_inter_frame_obu` and a
/// `av1_enc_write_subpel8_skip_tile` payload with an explicit 1/8-pel
/// target (components even unless `hp~` — high precision). Same
/// reference-store contract as the other inter entries.
pub fn av1_enc_write_subpel_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  base_q_idx~ : Int32 = 100,
  mv_y8~ : Int32,
  mv_x8~ : Int32,
  hp~ : Bool = false,
) -> Result[Bytes, String] {
  if seq.width % 64 != 0 || seq.height % 64 != 0 {
    return Err(
      "av1 enc: subpel inter frame needs 64-multiple geometry (got \{seq.width}x\{seq.height})",
    )
  }
  let rf : Av1Rf = {
    iw4: 0,
    ih4: 0,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp,
    force_integer_mv: false,
    use_ref_frame_mvs: false,
    gm_types: FixedArray::make(7, 0),
    gm_matrices: FixedArray::makei(7, _ => FixedArray::make(6, 0)),
  }
  let prepared = match
    refs.prepare_frame(
      [0, 0, 0, 0, 0, 0, 0],
      seq.order_hint_bits,
      0,
      seq.width,
      seq.height,
      false,
      rf,
      16,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let tile = match
    av1_enc_write_subpel8_skip_tile(
      prepared,
      seq.width,
      seq.height,
      base_q_idx,
      mv_y8,
      mv_x8,
      hp~,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let obu = match
    av1_enc_write_inter_frame_obu(seq, {
      ..Av1InterFrameEncConfig::default(),
      base_q_idx,
      allow_high_precision: hp,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  refs.refresh(prepared, 1)
  Ok(obu)
}

///|
/// The decoder's MC kernel, re-exported for tests and future encoder
/// prediction: one plane at `(bx4, by4)` with an explicit 1/8-pel mv.
pub fn av1_enc_mc_predict(
  src : FixedArray[Int32],
  stride : Int32,
  ref_width : Int32,
  ref_height : Int32,
  cur_width : Int32,
  cur_height : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  mv_y8 : Int32,
  mv_x8 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  filter2d : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  @av1_mc_core.av1_mc_predict_plane(
    src, stride, ref_width, ref_height, cur_width, cur_height, bx4, by4, bw4, bh4,
    mv_y8, mv_x8, ss_h, ss_v, filter2d, bitdepth,
  )
}

///|
/// Sub-pel ME refinement (§448b half-pel; §454 + quarter-pel): take the
/// full-pel SAD result and re-score, per SB, a half-pel stage (the
/// integer shift plus its four axial half-pel neighbors) followed by a
/// quarter-pel stage (the eight quarter-pel neighbors of the stage-1
/// winner, diagonals included) — every candidate scored by running the
/// decoder's own MC kernel (`av1_enc_mc_predict`, EIGHTTAP, clamped
/// edge reads) over the SB and measuring SAD against the source. The
/// cost the encoder minimizes is therefore bit-exact with the
/// reconstruction the decoder will realize: a candidate with SAD 0
/// decodes pixel-identical to the source. Ties keep the earlier stage's
/// winner (strictly-better replacement only — flat content stays at the
/// integer MV). Quarter components are even (1/8-pel units), so hp=0
/// frames code them; eighth/odd phases need allow_high_precision.
/// The caller must pass the reference the decoder will actually read
/// (a reconstructed key frame, not the pre-encode source). Returns the
/// refined per-SB mv pairs in 1/8-pel units (y, x).
pub fn av1_enc_me_subpel_refine(
  src : FixedArray[Int32],
  src_stride : Int32,
  refimg : FixedArray[Int32],
  ref_stride : Int32,
  width : Int32,
  height : Int32,
  mvs_y : FixedArray[Int32],
  mvs_x : FixedArray[Int32],
  hp~ : Bool = false,
) -> Result[(FixedArray[Int32], FixedArray[Int32]), String] {
  if width <= 0 || height <= 0 || width % 64 != 0 || height % 64 != 0 {
    return Err(
      "av1 enc: subpel refine needs 64-multiple geometry (got \{width}x\{height})",
    )
  }
  let sb_cols = width >> 6
  let sb_rows = height >> 6
  if mvs_y.length() != sb_cols * sb_rows || mvs_x.length() != sb_cols * sb_rows {
    return Err("av1 enc: subpel refine needs one mv pair per SB")
  }
  let out_y = FixedArray::make(sb_cols * sb_rows, 0)
  let out_x = FixedArray::make(sb_cols * sb_rows, 0)
  // Stage 1: the integer shift and the four axial half-pel neighbors
  // (even components only — hp off).
  let cands : Array[(Int32, Int32)] = [(0, 0), (4, 0), (-4, 0), (0, 4), (0, -4)]
  // Stage 2: the quarter-pel neighbors of the stage-1 winner — axial
  // and diagonal.
  let qcands : Array[(Int32, Int32)] = [
    (2, 0),
    (-2, 0),
    (0, 2),
    (0, -2),
    (2, 2),
    (2, -2),
    (-2, 2),
    (-2, -2),
  ]
  // Stage 3 (hp frames only): the eighth-pel neighbors of the stage-2
  // winner — odd components, codable with allow_high_precision.
  let ecands : Array[(Int32, Int32)] = [
    (1, 0),
    (-1, 0),
    (0, 1),
    (0, -1),
    (1, 1),
    (1, -1),
    (-1, 1),
    (-1, -1),
  ]
  // Per-SB SAD of the kernel prediction for one candidate.
  fn sb_sad(sby : Int32, sbx : Int32, mv8 : (Int32, Int32)) -> Int64 {
    let pred = av1_enc_mc_predict(
      refimg,
      ref_stride,
      width,
      height,
      width,
      height,
      sbx * 16,
      sby * 16,
      16,
      16,
      mv8.0,
      mv8.1,
      0,
      0,
      0,
      8,
    )
    let y0 = sby * 64
    let x0 = sbx * 64
    let mut sad : Int64 = 0L
    for y in 0..<64 {
      for x in 0..<64 {
        let d = src[(y0 + y) * src_stride + x0 + x] - pred[y * 64 + x]
        sad = sad + (if d < 0 { -d.to_int64() } else { d.to_int64() })
      }
    }
    sad
  }
  for sby in 0..<sb_rows {
    for sbx in 0..<sb_cols {
      let sb = sby * sb_cols + sbx
      let base8 : (Int32, Int32) = (mvs_y[sb] * 8, mvs_x[sb] * 8)
      let mut best = sb_sad(sby, sbx, base8)
      let mut best8 = base8
      for c in cands {
        let cand8 : (Int32, Int32) = (base8.0 + c.0, base8.1 + c.1)
        let sad = sb_sad(sby, sbx, cand8)
        if sad < best {
          best = sad
          best8 = cand8
        }
      }
      // Stage 2 around the stage-1 winner.
      for c in qcands {
        let cand8 : (Int32, Int32) = (best8.0 + c.0, best8.1 + c.1)
        let sad = sb_sad(sby, sbx, cand8)
        if sad < best {
          best = sad
          best8 = cand8
        }
      }
      // Stage 3 around the stage-2 winner (eighth phases, hp frames).
      if hp {
        for c in ecands {
          let cand8 : (Int32, Int32) = (best8.0 + c.0, best8.1 + c.1)
          let sad = sb_sad(sby, sbx, cand8)
          if sad < best {
            best = sad
            best8 = cand8
          }
        }
      }
      out_y[sb] = best8.0
      out_x[sb] = best8.1
    }
  }
  Ok((out_y, out_x))
}

///|
/// §498: kernel SAD of one `size` x `size` block at `(x0, y0)` under an
/// explicit 1/8-pel mv — the decoder's own MC kernel, so the distortion
/// the partition decision minimizes is the one the reconstruction
/// realizes. Luma only (the split decision rides the luma residual).
fn av1_enc_kernel_sad_block(
  src : FixedArray[Int32],
  src_stride : Int32,
  refimg : FixedArray[Int32],
  ref_stride : Int32,
  width : Int32,
  height : Int32,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  mv_y8 : Int32,
  mv_x8 : Int32,
) -> Int64 {
  let pred = av1_enc_mc_predict(
    refimg,
    ref_stride,
    width,
    height,
    width,
    height,
    x0 >> 2,
    y0 >> 2,
    size >> 2,
    size >> 2,
    mv_y8,
    mv_x8,
    0,
    0,
    0,
    8,
  )
  let mut sad : Int64 = 0L
  for y in 0..<size {
    let srow = (y0 + y) * src_stride + x0
    for x in 0..<size {
      let d = src[srow + x] - pred[y * size + x]
      sad = sad + (if d < 0 { -d.to_int64() } else { d.to_int64() })
    }
  }
  sad
}

///|
/// §498: full-pel SAD search for one block — the per-SB loop of
/// `av1_enc_me_fullpel_sad` generalized to sub-64 blocks, so a partition
/// decision can compare a 64x64 candidate against its four 32x32
/// quadrants. Same tie-break as the frame-level search (cheaper
/// displacement first, then dy, dx). Returns `(best_dy, best_dx,
/// best_sad)` in full-pel units.
pub fn av1_enc_me_fullpel_sad_block(
  src : FixedArray[Int32],
  src_stride : Int32,
  refimg : FixedArray[Int32],
  ref_stride : Int32,
  width : Int32,
  height : Int32,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  range~ : Int32 = 16,
) -> Result[(Int32, Int32, Int32), String] {
  if size <= 0 || size % 4 != 0 || size > 64 {
    return Err("av1 enc: me block size must be a 4..=64 multiple of 4")
  }
  if x0 < 0 || y0 < 0 || x0 + size > width || y0 + size > height {
    return Err("av1 enc: me block outside the frame")
  }
  if range < 0 || range > 1024 {
    return Err("av1 enc: me range must be 0..=1024")
  }
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  let mut best = -1
  let mut best_dy = 0
  let mut best_dx = 0
  for dy in -range..<=range {
    for dx in -range..<=range {
      let mut sad = 0
      for y in 0..<size {
        let sy = clamp(y0 + y + dy, height)
        let srow = (y0 + y) * src_stride
        let rrow = sy * ref_stride
        for x in 0..<size {
          let sx = clamp(x0 + x + dx, width)
          let d = src[srow + x0 + x] - refimg[rrow + sx]
          sad = sad + (if d < 0 { -d } else { d })
        }
      }
      let cost = (if dy < 0 { -dy } else { dy }) +
        (if dx < 0 { -dx } else { dx })
      let better = if best < 0 {
        true
      } else if sad != best {
        sad < best
      } else {
        let bc = (if best_dy < 0 { -best_dy } else { best_dy }) +
          (if best_dx < 0 { -best_dx } else { best_dx })
        cost < bc ||
        (cost == bc && (dy < best_dy || (dy == best_dy && dx < best_dx)))
      }
      if better {
        best = sad
        best_dy = dy
        best_dx = dx
      }
    }
  }
  Ok((best_dy, best_dx, best))
}

///|
/// §498: kernel-SAD sub-pel refinement for one block — the per-SB
/// stages of `av1_enc_me_subpel_refine` (integer + axial half-pel, then
/// the quarter-pel neighborhood, then eighth-pel when hp) generalized to
/// sub-64 blocks. Takes the full-pel result and returns the refined
/// 1/8-pel mv plus the winner's kernel SAD (the distortion value for the
/// partition decision). Ties keep the earlier stage's winner.
pub fn av1_enc_me_subpel_refine_block(
  src : FixedArray[Int32],
  src_stride : Int32,
  refimg : FixedArray[Int32],
  ref_stride : Int32,
  width : Int32,
  height : Int32,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
  mv_y : Int32,
  mv_x : Int32,
  hp~ : Bool = false,
) -> Result[(Int32, Int32, Int64), String] {
  if size <= 0 || size % 4 != 0 || size > 64 {
    return Err("av1 enc: refine block size must be a 4..=64 multiple of 4")
  }
  if x0 < 0 || y0 < 0 || x0 + size > width || y0 + size > height {
    return Err("av1 enc: refine block outside the frame")
  }
  let cands : Array[(Int32, Int32)] = [(0, 0), (4, 0), (-4, 0), (0, 4), (0, -4)]
  let qcands : Array[(Int32, Int32)] = [
    (2, 0),
    (-2, 0),
    (0, 2),
    (0, -2),
    (2, 2),
    (2, -2),
    (-2, 2),
    (-2, -2),
  ]
  let ecands : Array[(Int32, Int32)] = [
    (1, 0),
    (-1, 0),
    (0, 1),
    (0, -1),
    (1, 1),
    (1, -1),
    (-1, 1),
    (-1, -1),
  ]
  let base8 : (Int32, Int32) = (mv_y * 8, mv_x * 8)
  let mut best = av1_enc_kernel_sad_block(
    src,
    src_stride,
    refimg,
    ref_stride,
    width,
    height,
    x0,
    y0,
    size,
    base8.0,
    base8.1,
  )
  let mut best8 = base8
  for c in cands {
    let cand8 : (Int32, Int32) = (base8.0 + c.0, base8.1 + c.1)
    let sad = av1_enc_kernel_sad_block(
      src, src_stride, refimg, ref_stride, width, height, x0, y0, size, cand8.0, cand8.1,
    )
    if sad < best {
      best = sad
      best8 = cand8
    }
  }
  for c in qcands {
    let cand8 : (Int32, Int32) = (best8.0 + c.0, best8.1 + c.1)
    let sad = av1_enc_kernel_sad_block(
      src, src_stride, refimg, ref_stride, width, height, x0, y0, size, cand8.0, cand8.1,
    )
    if sad < best {
      best = sad
      best8 = cand8
    }
  }
  if hp {
    for c in ecands {
      let cand8 : (Int32, Int32) = (best8.0 + c.0, best8.1 + c.1)
      let sad = av1_enc_kernel_sad_block(
        src, src_stride, refimg, ref_stride, width, height, x0, y0, size, cand8.0, cand8.1,
      )
      if sad < best {
        best = sad
        best8 = cand8
      }
    }
  }
  Ok((best8.0, best8.1, best))
}

///|
/// Encode a per-superblock sub-pel ME + dc-token inter frame OBU
/// (§448b): the mv arrays are 1/8-pel pairs (e.g. the output of
/// `av1_enc_me_subpel_refine`), passed through to the tile writer's
/// `mv8` path. Same reference-store contract as the other entries.
pub fn av1_enc_write_me8_dc_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  base_q_idx~ : Int32 = 100,
  mvs_y8~ : FixedArray[Int32],
  mvs_x8~ : FixedArray[Int32],
  dc_toks~ : FixedArray[Int32],
  dc_signs~ : FixedArray[Int32],
  hp~ : Bool = false,
) -> Result[Bytes, String] {
  if seq.width % 64 != 0 || seq.height % 64 != 0 {
    return Err(
      "av1 enc: me8 inter frame needs 64-multiple geometry (got \{seq.width}x\{seq.height})",
    )
  }
  let rf : Av1Rf = {
    iw4: 0,
    ih4: 0,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp,
    force_integer_mv: false,
    use_ref_frame_mvs: false,
    gm_types: FixedArray::make(7, 0),
    gm_matrices: FixedArray::makei(7, _ => FixedArray::make(6, 0)),
  }
  let prepared = match
    refs.prepare_frame(
      [0, 0, 0, 0, 0, 0, 0],
      seq.order_hint_bits,
      0,
      seq.width,
      seq.height,
      false,
      rf,
      16,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let tile = match
    av1_enc_write_me_dc_tile(
      prepared,
      seq.width,
      seq.height,
      base_q_idx,
      mvs_y8,
      mvs_x8,
      dc_toks,
      dc_signs,
      mono=seq.monochrome,
      mv8=true,
      hp~,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let obu = match
    av1_enc_write_inter_frame_obu(seq, {
      ..Av1InterFrameEncConfig::default(),
      base_q_idx,
      allow_high_precision: hp,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  refs.refresh(prepared, 1)
  Ok(obu)
}

///|
/// Encode a per-superblock ME + full-residual inter frame OBU (§449a):
/// per SB the integer SAD search refines to a half-pel `mv8`, the MC
/// kernel predicts from `refimg`, the residual `src − pred` quantizes
/// through the pseudo-inverse itx basis against the frame's dequant
/// tables, and the reconstruction the decoder will realize is computed
/// with the same kernel — returned alongside the OBU for the pixel
/// round-trip assertion. Chroma stays all_skip (pure MC). Luma-only
/// `expected` plane in raster order (`width` × `height`).
pub fn av1_enc_write_me_res_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  src : FixedArray[Int32],
  src_stride : Int32,
  refimg : FixedArray[Int32],
  ref_stride : Int32,
  base_q_idx~ : Int32 = 200,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
) -> Result[(Bytes, FixedArray[Int32], FixedArray[Int32]), String] {
  let w = seq.width
  let h = seq.height
  if w % 64 != 0 || h % 64 != 0 {
    return Err(
      "av1 enc: me res frame needs 64-multiple geometry (got \{w}x\{h})",
    )
  }
  let sb_cols = w >> 6
  let sb_rows = h >> 6
  let n_sb = sb_cols * sb_rows
  // 1. ME: integer search + half-pel refinement, per SB.
  let (iy, ix) = match
    av1_enc_me_fullpel_sad(src, src_stride, refimg, ref_stride, w, h, range~) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let (ry, rx) = match
    av1_enc_me_subpel_refine(src, src_stride, refimg, ref_stride, w, h, iy, ix) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // 2. Dequant tables (8-bit, no segmentation — our frame headers).
  let dq_tbl = if seq.bitdepth == 8 {
    av1_dq_tbl_0
  } else if seq.bitdepth == 10 {
    av1_dq_tbl_1
  } else {
    av1_dq_tbl_2
  }
  let dc_tbl = dq_tbl[base_q_idx * 2].to_int()
  let ac_tbl = dq_tbl[base_q_idx * 2 + 1].to_int()
  // dq_shift = max(0, t_dim_ctx - 2); TX_32X32 t_dim_ctx = 3 -> 1.
  let dq_shift = av1_imax(0, av1_txfm_ctx(3) - 2)
  // 3. Pseudo-inverse basis for TX_32X32 (probed once per call).
  let basis = av1_enc_itx_basis32()
  // 4. Per SB: predict, residual, quantize into the token specs, and
  //    compose the expected reconstruction (pred + itx(dequant)).
  let tok_specs : FixedArray[Int32] = FixedArray::make(n_sb * 4 * 1024, 0)
  let sign_specs : FixedArray[Int32] = FixedArray::make(n_sb * 4 * 1024, 0)
  let expected : FixedArray[Int32] = FixedArray::make(w * h, 0)
  let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
  let resid : FixedArray[Int32] = FixedArray::make(64 * 64, 0)
  let leaf_r : FixedArray[Int32] = FixedArray::make(1024, 0)
  for sby in 0..<sb_rows {
    for sbx in 0..<sb_cols {
      let sb = sby * sb_cols + sbx
      let mv8 : (Int32, Int32) = (ry[sb], rx[sb])
      // Prediction: the decoder's MC kernel, luma 64x64 at the SB.
      let pred = av1_enc_mc_predict(
        refimg,
        ref_stride,
        w,
        h,
        w,
        h,
        sbx * 16,
        sby * 16,
        16,
        16,
        mv8.0,
        mv8.1,
        0,
        0,
        0,
        8,
      )
      let y0 = sby * 64
      let x0 = sbx * 64
      // Residual (raster 64x64) and the expected plane's prediction.
      for y in 0..<64 {
        for x in 0..<64 {
          let s = src[(y0 + y) * src_stride + x0 + x]
          resid[y * 64 + x] = s - pred[y * 64 + x]
          expected[(y0 + y) * w + x0 + x] = pred[y * 64 + x]
        }
      }
      // Four TX_32X32 leaves: quantize each against the basis.
      for li in 0..<4 {
        let lx = li % 2 * 32
        let ly = li / 2 * 32
        // Leaf residual view: rows of the 64x64 residual, 32 columns.
        for r in 0..<32 {
          for c in 0..<32 {
            leaf_r[r * 32 + c] = resid[(ly + r) * 64 + lx + c]
          }
        }
        let (eob, _cul) = av1_enc_quantize_leaf(
          leaf_r,
          32,
          basis,
          dc_tbl,
          ac_tbl,
          dq_shift,
          toks,
          signs,
          dz_pm~,
        )
        ignore(eob)
        let base = (sb * 4 + li) * 1024
        for i in 0..<1024 {
          tok_specs[base + i] = toks[i]
          sign_specs[base + i] = signs[i]
        }
        // Expected reconstruction: dequant + the decoder's itx on top
        // of the prediction block (in place, clamped like the decoder).
        // Copy the prediction block into a scratch (itxfm_add mutates
        // its coeff array, and dst must hold pred for the add+clip).
        let scratch : FixedArray[Int32] = FixedArray::make(1024, 0)
        for r in 0..<32 {
          for c in 0..<32 {
            scratch[r * 32 + c] = pred[(ly + r) * 64 + lx + c]
          }
        }
        for i in 0..<1024 {
          toks[i] = tok_specs[base + i]
          signs[i] = sign_specs[base + i]
        }
        let _ = av1_enc_recon_leaf(
          scratch, 0, 32, toks, signs, 3, dc_tbl, ac_tbl, dq_shift,
        )
        for r in 0..<32 {
          for c in 0..<32 {
            expected[(y0 + ly + r) * w + x0 + lx + c] = scratch[r * 32 + c]
          }
        }
      }
    }
  }
  // 5. Syntax: the reference-store mirror and the tile writer.
  let rf : Av1Rf = {
    iw4: 0,
    ih4: 0,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp: false,
    force_integer_mv: false,
    use_ref_frame_mvs: false,
    gm_types: FixedArray::make(7, 0),
    gm_matrices: FixedArray::makei(7, _ => FixedArray::make(6, 0)),
  }
  let prepared = match
    refs.prepare_frame(
      [0, 0, 0, 0, 0, 0, 0],
      seq.order_hint_bits,
      0,
      w,
      h,
      false,
      rf,
      16,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let tile = match
    av1_enc_write_me_res_tile(
      prepared,
      w,
      h,
      base_q_idx,
      ry,
      rx,
      tok_specs,
      sign_specs,
      mono=seq.monochrome,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let obu = match
    av1_enc_write_inter_frame_obu(seq, {
      ..Av1InterFrameEncConfig::default(),
      base_q_idx,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  refs.refresh(prepared, 1)
  Ok((obu, expected, ry))
}
