///|
/// §446b/§447a inter tile writers — all-skip single-LAST-reference
/// blocks under the §438b/§446a tool set. The per-block symbol order
/// mirrors decode_b's inter branch and `av1_inter_read_block`:
/// partition, skip=1, intra=inter, the three LAST reference-tree bools,
/// then the mode chain (GLOBALMV / NEARESTMV / NEWMV) via the `motion`
/// step, and nothing else — compound/ref-mvs/interintra/motion-mode/
/// subpel-filter are sequence-gated off, skip=1 suppresses the var-tx
/// tree and residuals.
///
/// Mirrors (all driven with the decoder's own code, the §440a pattern):
/// the CDF trajectory (`av1_cdf_copy_defaults`), the skip and partition
/// above/left edge banks, the inter neighbor state
/// (`Av1InterTileState`), and the refmvs frame state (find/splat
/// replay over the prepared reference state).

///|
/// One block: partition NONE at bl=1, the skip flag, intra=inter, LAST
/// ref tree, then `motion` (the mode chain over the refmvs stack),
/// then `tail` (the var-tx + residual symbols for skip=0 blocks; the
/// default writes nothing — skip=1 suppresses them), then the
/// publishes (refmvs splat, neighbor banks, skip edges, partition
/// write-back). `motion` returns the (mode, mv) pair it coded, feeding
/// splat_single exactly like av1_inter_read_block's return drives the
/// decoder's publish.
fn av1_enc_inter_skip_block(
  enc : Av1MsacEnc,
  cdf : Av1CdfCtx,
  rstate : Av1RefmvsFrameState,
  nstate : Av1InterTileState,
  a_skip : FixedArray[Int32],
  l_skip : FixedArray[Int32],
  a_part : FixedArray[Int32],
  l_part : FixedArray[Int32],
  bs : Int32,
  bw : Int32,
  bh : Int32,
  bx : Int32,
  by : Int32,
  skip~ : Bool = true,
  /// §463: the single reference index in dav1d's 0..6 order (0 = LAST,
  /// 1..3 = LAST2/LAST3/GOLDEN, 4..6 = BWDREF/ALTREF2/ALTREF). The ref
  /// tree, the refmvs `find` reference slot and the `splat` publish all
  /// follow it. Default 0 keeps the §446b..§462 LAST-only behaviour.
  ref_idx~ : Int32 = 0,
  motion~ : (Av1MsacEnc, Av1CdfCtx, Av1RefmvsResult) -> (Int32, (Int32, Int32)),
  tail~ : (Av1MsacEnc, Av1CdfCtx) -> Unit = (_, _) => (),
) -> Unit {
  // Partition: PARTITION_NONE at bl=1 (the geometry keeps every SB
  // whole, so both splits are available and the symbol is read).
  let xb8 = (bx & 31) >> 1
  let yb8 = (by & 31) >> 1
  let pctx = ((a_part[xb8] >> 3) & 1) + (((l_part[yb8] >> 3) & 1) << 1)
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + pctx) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_none,
  )
  let al = av1_al_part_ctx[(0 * 5 + 1) * 10 + av1_partition_none].to_int()
  let all = av1_al_part_ctx[(1 * 5 + 1) * 10 + av1_partition_none].to_int()
  for i in 0..<8 {
    a_part[xb8 + i] = al
    l_part[yb8 + i] = all
  }
  // skip flag (sctx from the a/l skip edges).
  let sctx = a_skip[bx & 31] + l_skip[by & 31]
  enc.encode_bool_adapt(cdf.skip, sctx * 2, if skip { 1U } else { 0U })
  // intra flag: 1 = inter. The reference trees take have_top/have_left;
  // everything else reads the banks unconditionally.
  let top_opt = if by > 0 { Some(nstate.top[bx & 31]) } else { None }
  let left_opt = if bx > 0 { Some(nstate.left[by & 31]) } else { None }
  let ictx = av1_inter_intra_ctx(top_opt, left_opt)
  enc.encode_bool_adapt(cdf.intra, ictx * 2, 1)
  // Reference tree → `ref_idx` (§463). Mirrors av1_inter_read_refs:
  //   bit0=0, bit2=0, bit3=b  → ref0 = b            (LAST / LAST2)
  //   bit0=0, bit2=1, bit4=b  → ref0 = 2 + b        (LAST3 / GOLDEN)
  //   bit0=1, bit1=0, bit5=b  → ref0 = 4 + b        (BWDREF / ALTREF2)
  //   bit0=1, bit1=1          → ref0 = 6            (ALTREF)
  let top_any : Av1InterNeighbor? = Some(nstate.top[bx & 31])
  let left_any : Av1InterNeighbor? = Some(nstate.left[by & 31])
  let ref_bit = (row : Int32, ctx_row : Int32, v : Int32) => {
    enc.encode_bool_adapt(
      cdf.ref_,
      (row * 3 + av1_inter_ref_tree_ctx(top_any, left_any, ctx_row)) * 2,
      v.reinterpret_as_uint(),
    )
  }
  if ref_idx >= 4 {
    ref_bit(0, 0, 1)
    if ref_idx == 6 {
      ref_bit(1, 4, 1)
    } else {
      ref_bit(1, 4, 0)
      ref_bit(5, 5, ref_idx - 4)
    }
  } else {
    ref_bit(0, 0, 0)
    if ref_idx >= 2 {
      ref_bit(2, 1, 1)
      ref_bit(4, 3, ref_idx - 2)
    } else {
      ref_bit(2, 1, 0)
      ref_bit(3, 2, ref_idx)
    }
  }
  // top_has_right: the 64x64 NONE node carries the i444 bit.
  let stack = rstate.find(0, bw, 0, bh, ref_idx + 1, -1, bs, true, by, bx)
  let (mode, mv) = motion(enc, cdf, stack)
  tail(enc, cdf)
  // Publish mirrors (decode_inter_block's writes): refmvs splat,
  // neighbor banks, skip edges.
  rstate.splat_single(ref_idx, mode, mv, false, bs, bx, by, 16, 16)
  nstate.set_block(bx, by, 16, 16, {
    intra: false,
    comp_type: 0,
    ref0: ref_idx,
    ref1: -1,
    filter0: 0,
    filter1: 0,
  })
  for i in 0..<16 {
    a_skip[(bx & 31) + i] = if skip { 1 } else { 0 }
    l_skip[(by & 31) + i] = if skip { 1 } else { 0 }
  }
}

///|
/// Shared SB-row/frame scaffolding for the single-tile all-skip writers:
/// geometry checks, the per-tile refmvs copy, neighbor and edge mirrors,
/// the begin/reset/finish SB-row sequence, and the a_idx bank step.
/// `block` runs per 64x64 SB with the mirror banks and the SB position.
fn av1_enc_inter_skip_frame_loop(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  block : (
    Av1MsacEnc,
    Av1CdfCtx,
    Av1RefmvsFrameState,
    Av1InterTileState,
    FixedArray[Int32],
    FixedArray[Int32],
    FixedArray[Int32],
    FixedArray[Int32],
    Int32,
    Int32,
  ) -> Unit,
  on_row~ : (Int32) -> Unit = _ => (),
) -> Result[Bytes, String] {
  if width <= 0 || height <= 0 || width % 64 != 0 || height % 64 != 0 {
    return Err(
      "av1 enc: inter tile needs 64-multiple geometry (got \{width}x\{height})",
    )
  }
  if base_q_idx < 1 || base_q_idx > 255 {
    return Err("av1 enc: base_q_idx must be 1..=255")
  }
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  // Frame geometry in 4px units (decoder f.bw/f.bh).
  let bw = 2 * ((width + 7) >> 3)
  let bh = 2 * ((height + 7) >> 3)
  let sb_cols = bw >> 4
  let sb_rows = bh >> 4
  let sb128w = (bw + 31) >> 5
  // Per-tile refmvs state: a copy with a private row ring, exactly as
  // the decoder's tile setup (av1_decode6).
  let rstate : Av1RefmvsFrameState = {
    ..prepared.state,
    tile: { ..prepared.state.tile, rows: prepared.state.tile.rows.copy(), },
  }
  // Inter neighbor state: the decoder initializes both banks with
  // intra=false (its `left`/`inter_a` setup), then resets left per SB
  // row with intra=false (decode_tile_sbrow).
  let nstate = av1_inter_tile_state_new(bw, bh)
  let fresh_inter : Av1InterNeighbor = {
    intra: false,
    comp_type: 0,
    ref0: -1,
    ref1: -1,
    filter0: 3,
    filter1: 3,
  }
  for i in 0..<bw {
    nstate.top[i] = fresh_inter
  }
  nstate.reset_left(intra=false)
  // Edge mirrors: skip (4px slots, a persists across rows) and the
  // partition bits (8px slots), both zero-reset exactly as
  // av1_block_context_new/reset_keyframe.
  let a_skip : Array[FixedArray[Int32]] = []
  let a_part : Array[FixedArray[Int32]] = []
  for _ in 0..<sb128w {
    a_skip.push(FixedArray::make(32, 0))
    a_part.push(FixedArray::make(16, 0))
  }
  let l_skip = FixedArray::make(32, 0)
  let l_part = FixedArray::make(16, 0)
  for sby in 0..<sb_rows {
    let by = sby * 16
    let next8 = (by + 16) >> 1
    let bh8 = bh >> 1
    let end8 = if next8 < bh8 { next8 } else { bh8 }
    // Driver order: begin_sbrow before the tile's SB-row resets.
    rstate.begin_sbrow(sby, 0, bw >> 1, by >> 1, end8)
    for i in 0..<32 {
      l_skip[i] = 0
    }
    for i in 0..<16 {
      l_part[i] = 0
    }
    nstate.reset_left(intra=false)
    rstate.tile.init_sbrow(sby)
    on_row(by)
    let mut bank = 0 // a_idx (tile_row * sb128w + col_start >> 5 = 0)
    for sbx in 0..<sb_cols {
      let bx = sbx * 16
      block(
        enc,
        cdf,
        rstate,
        nstate,
        a_skip[bank],
        l_skip,
        a_part[bank],
        l_part,
        bx,
        by,
      )
      // The above-context bank advances on the second 64x64 of each
      // 128px column (decode_tile_sbrow's a_idx step).
      if (bx & 16) != 0 {
        bank = bank + 1
      }
    }
    rstate.finish_sbrow(0, bw >> 1, by >> 1, end8)
  }
  Ok(enc.done())
}

///|
/// Write the all-GLOBALMV skip-only tile (§446b): every block codes
/// GLOBALMV — identity global motion → zero MV, prediction is a block
/// copy of the reference picture.
pub fn av1_enc_write_globalmv_skip_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
) -> Result[Bytes, String] {
  let bs = av1_block_sizes[(1 * 10 + 0) * 2].to_int()
  av1_enc_inter_skip_frame_loop(prepared, width, height, base_q_idx, (
    enc,
    cdf,
    rstate,
    nstate,
    a_skip,
    l_skip,
    a_part,
    l_part,
    bx,
    by,
  ) => {
    let bw = 2 * ((width + 7) >> 3)
    let bh = 2 * ((height + 7) >> 3)
    av1_enc_inter_skip_block(
      enc,
      cdf,
      rstate,
      nstate,
      a_skip,
      l_skip,
      a_part,
      l_part,
      bs,
      bw,
      bh,
      bx,
      by,
      motion=(_enc, _cdf, stack) => {
        // GLOBALMV: newmv_mode=1 (not new), globalmv_mode=0 (global).
        _enc.encode_bool_adapt(_cdf.newmv_mode, (stack.ctx & 7) * 2, 1)
        _enc.encode_bool_adapt(
          _cdf.globalmv_mode,
          ((stack.ctx >> 3) & 1) * 2,
          0,
        )
        (2, (0, 0))
      },
    )
  })
}

///|
/// One MV component residual for NEWMV (`read_mv_component_diff`
/// mirror): sign, class, class bits / class0 bool, then the fp symbol
/// (mv_prec = 0 under our headers: fp is coded, the hp bit is not —
/// the implicit hp is 1, so every coded magnitude is even, a quarter-pel
/// multiple; full-pel components decompose with fp = 3).
fn av1_enc_write_mv_component_diff(
  enc : Av1MsacEnc,
  cdf : Av1CdfCtx,
  comp : Int32,
  diff : Int32,
  hp~ : Bool = false,
) -> Result[Unit, String] {
  if !hp && diff % 2 != 0 {
    return Err("av1 enc: mv diff must be even (high precision is off)")
  }
  let neg = diff < 0
  let mag = if neg { -diff } else { diff }
  let sign_tbl = if comp == 0 { cdf.mv0_sign } else { cdf.mv1_sign }
  let classes = if comp == 0 { cdf.mv0_classes } else { cdf.mv1_classes }
  let class0 = if comp == 0 { cdf.mv0_class0 } else { cdf.mv1_class0 }
  let class0_fp = if comp == 0 { cdf.mv0_class0_fp } else { cdf.mv1_class0_fp }
  let class0_hp = if comp == 0 { cdf.mv0_class0_hp } else { cdf.mv1_class0_hp }
  let classn = if comp == 0 { cdf.mv0_classN } else { cdf.mv1_classN }
  let classn_fp = if comp == 0 { cdf.mv0_classN_fp } else { cdf.mv1_classN_fp }
  let classn_hp = if comp == 0 { cdf.mv0_classN_hp } else { cdf.mv1_classN_hp }
  // sign first, then class (decoder order).
  let sign_bit : UInt32 = if neg { 1U } else { 0U }
  enc.encode_bool_adapt(sign_tbl, 0, sign_bit)
  // magnitude − 1 decomposes as up<<3 | fp<<1 | hp (hp fixed at 1
  // when high precision is off — the decoder's implicit even law).
  let m = mag - 1
  let up = m >> 3
  let fp = (m >> 1) & 3
  let hp_bit : UInt32 = (m & 1).reinterpret_as_uint()
  if up <= 1 {
    enc.encode_symbol_adapt(classes, 0, 10, 0)
    enc.encode_bool_adapt(class0, 0, up.reinterpret_as_uint())
    enc.encode_symbol_adapt(class0_fp, up * 4, 3, fp)
    if hp {
      // dav1d reads class0_hp without the `up` index (always row 0).
      enc.encode_bool_adapt(class0_hp, 0, hp_bit)
    }
  } else {
    // class cl covers up in [2^cl, 2^(cl+1)−1]: cl = floor(log2(up)).
    let mut cl = 0
    let mut t = up
    while t > 1 {
      t = t >> 1
      cl = cl + 1
    }
    if cl > 9 {
      return Err("av1 enc: mv magnitude out of the class-10 range")
    }
    enc.encode_symbol_adapt(classes, 0, 10, cl)
    for n in 0..<cl {
      let bit : UInt32 = ((up >> n) & 1).reinterpret_as_uint()
      enc.encode_bool_adapt(classn, n * 2, bit)
    }
    enc.encode_symbol_adapt(classn_fp, 0, 3, fp)
    if hp {
      enc.encode_bool_adapt(classn_hp, 0, hp_bit)
    }
  }
  Ok(())
}

///|
/// The uniform-MV mode chain (§447a): NEARESTMV when the stack's top
/// candidate equals `target`, else NEWMV with joint + component
/// residuals. With `drl` (§499) a deeper stack candidate equal to the
/// target codes NEARMV instead — three mode bools plus the drl bools,
/// with no MV payload. Shared by every uniform-MV tile writer.
fn av1_enc_write_uniform_motion(
  enc : Av1MsacEnc,
  cdf : Av1CdfCtx,
  stack : Av1RefmvsResult,
  target : (Int32, Int32),
  err : Ref[String?],
  hp~ : Bool = false,
  drl~ : Bool = false,
) -> (Int32, (Int32, Int32)) {
  // NEARESTMV candidate: the decoder's NEARESTMV return is
  // fix_precision(cands[0].mv0) unconditionally.
  let (cy, cx) = stack.cands[0].mv0
  let near = av1_rmv_fix_precision((cy, cx), false, hp)
  if near == target {
    // Not new, not global, not near: NEARESTMV.
    enc.encode_bool_adapt(cdf.newmv_mode, (stack.ctx & 7) * 2, 1)
    enc.encode_bool_adapt(cdf.globalmv_mode, ((stack.ctx >> 3) & 1) * 2, 1)
    enc.encode_bool_adapt(cdf.refmv_mode, ((stack.ctx >> 4) & 15) * 2, 0)
    return (0, near)
  }
  if drl {
    // §499 NEARMV: the decoder reads newmv=1, globalmv=1, refmv=1, then
    // drl bools walking the stack from index 1; the mv is
    // fix_precision(cands[1]) at index 1 and the raw candidate at 2/3
    // (dav1d's `drl < 2` precision rule). Coding an index stops at the
    // first zero bool, and a bool is only read while the stack has a
    // deeper candidate (cnt > index + 1).
    if stack.cnt > 1 {
      let c1 = av1_rmv_fix_precision(stack.cands[1].mv0, false, hp)
      if c1 == target {
        enc.encode_bool_adapt(cdf.newmv_mode, (stack.ctx & 7) * 2, 1)
        enc.encode_bool_adapt(cdf.globalmv_mode, ((stack.ctx >> 3) & 1) * 2, 1)
        enc.encode_bool_adapt(cdf.refmv_mode, ((stack.ctx >> 4) & 15) * 2, 1)
        if stack.cnt > 2 {
          enc.encode_bool_adapt(
            cdf.drl_bit,
            av1_inter_drl_ctx(stack.cands[1].weight, stack.cands[2].weight) * 2,
            0,
          )
        }
        return (1, c1)
      }
      if stack.cnt > 2 && stack.cands[2].mv0 == target {
        enc.encode_bool_adapt(cdf.newmv_mode, (stack.ctx & 7) * 2, 1)
        enc.encode_bool_adapt(cdf.globalmv_mode, ((stack.ctx >> 3) & 1) * 2, 1)
        enc.encode_bool_adapt(cdf.refmv_mode, ((stack.ctx >> 4) & 15) * 2, 1)
        enc.encode_bool_adapt(
          cdf.drl_bit,
          av1_inter_drl_ctx(stack.cands[1].weight, stack.cands[2].weight) * 2,
          1,
        )
        if stack.cnt > 3 {
          enc.encode_bool_adapt(
            cdf.drl_bit,
            av1_inter_drl_ctx(stack.cands[2].weight, stack.cands[3].weight) * 2,
            0,
          )
        }
        return (1, stack.cands[2].mv0)
      }
      if stack.cnt > 3 && stack.cands[3].mv0 == target {
        enc.encode_bool_adapt(cdf.newmv_mode, (stack.ctx & 7) * 2, 1)
        enc.encode_bool_adapt(cdf.globalmv_mode, ((stack.ctx >> 3) & 1) * 2, 1)
        enc.encode_bool_adapt(cdf.refmv_mode, ((stack.ctx >> 4) & 15) * 2, 1)
        enc.encode_bool_adapt(
          cdf.drl_bit,
          av1_inter_drl_ctx(stack.cands[1].weight, stack.cands[2].weight) * 2,
          1,
        )
        enc.encode_bool_adapt(
          cdf.drl_bit,
          av1_inter_drl_ctx(stack.cands[2].weight, stack.cands[3].weight) * 2,
          1,
        )
        return (1, stack.cands[3].mv0)
      }
    }
  }
  // NEWMV: newmv_mode = 0 (no globalmv/refmv bits), drl = 0 (one zero
  // bool when the stack holds extra candidates), then the joint +
  // component residuals relative to cands[0] (raw when cnt > 1,
  // precision-fixed otherwise — the decoder's ref_mv derivation).
  enc.encode_bool_adapt(cdf.newmv_mode, (stack.ctx & 7) * 2, 0)
  if stack.cnt > 1 {
    enc.encode_bool_adapt(
      cdf.drl_bit,
      av1_inter_drl_ctx(stack.cands[0].weight, stack.cands[1].weight) * 2,
      0,
    )
  }
  let ref_mv = if stack.cnt > 1 { (cy, cx) } else { near }
  let dy = target.0 - ref_mv.0
  let dx = target.1 - ref_mv.1
  let joint = (if dy != 0 { 2 } else { 0 }) + (if dx != 0 { 1 } else { 0 })
  enc.encode_symbol_adapt(cdf.joint, 0, 3, joint)
  if dy != 0 {
    match av1_enc_write_mv_component_diff(enc, cdf, 0, dy, hp~) {
      Ok(_) => ()
      Err(e) => err.val = Some(e)
    }
  }
  if dx != 0 {
    match av1_enc_write_mv_component_diff(enc, cdf, 1, dx, hp~) {
      Ok(_) => ()
      Err(e) => err.val = Some(e)
    }
  }
  (3, target)
}

///|
/// The uniform-MV skip tile core: every block targets `target8` (an
/// explicit 1/8-pel pair within ±8192, the class-10 magnitude limit;
/// components must be even unless high precision is on). The first
/// block codes NEWMV (joint + component residuals against the empty
/// stack); once the stack's top candidate equals the target the writer
/// switches to NEARESTMV (three bools, no MV payload).
fn av1_enc_write_uniform8_skip_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  target8 : (Int32, Int32),
  hp~ : Bool = false,
) -> Result[Bytes, String] {
  let (ty8, tx8) = target8
  if !hp && (ty8 % 2 != 0 || tx8 % 2 != 0) {
    return Err("av1 enc: mv components must be even (high precision off)")
  }
  if ty8 < -8192 || ty8 > 8192 || tx8 < -8192 || tx8 > 8192 {
    return Err("av1 enc: mv out of the class-10 magnitude range")
  }
  let target = target8
  let bs = av1_block_sizes[(1 * 10 + 0) * 2].to_int()
  // The component writer can only fail on odd or oversized diffs; odd
  // is statically impossible here (hp forces even, and every stack
  // reference is (0,0) or target), but the Ref keeps the path honest.
  let err : Ref[String?] = Ref(None)
  let payload = match
    av1_enc_inter_skip_frame_loop(prepared, width, height, base_q_idx, (
      enc,
      cdf,
      rstate,
      nstate,
      a_skip,
      l_skip,
      a_part,
      l_part,
      bx,
      by,
    ) => {
      let bw = 2 * ((width + 7) >> 3)
      let bh = 2 * ((height + 7) >> 3)
      av1_enc_inter_skip_block(
        enc,
        cdf,
        rstate,
        nstate,
        a_skip,
        l_skip,
        a_part,
        l_part,
        bs,
        bw,
        bh,
        bx,
        by,
        motion=(enc2, cdf2, stack) => {
          av1_enc_write_uniform_motion(enc2, cdf2, stack, target, err, hp~)
        },
      )
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  match err.val {
    Some(e) => Err(e)
    None => Ok(payload)
  }
}

///|
/// The uniform-MV skip-only tile (§447a): full-pel `(mv_y, mv_x)`
/// convenience wrapper over the 1/8-pel core.
pub fn av1_enc_write_newmv_skip_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  mv_y : Int32,
  mv_x : Int32,
) -> Result[Bytes, String] {
  if mv_y < -1024 || mv_y > 1024 || mv_x < -1024 || mv_x > 1024 {
    return Err("av1 enc: full-pel mv out of ±1024 range")
  }
  av1_enc_write_uniform8_skip_tile(
    prepared,
    width,
    height,
    base_q_idx,
    (mv_y * 8, mv_x * 8),
  )
}

///|
/// The uniform sub-pel skip-only tile (§448): the same core with an
/// explicit 1/8-pel target — any even components (quarter-pel
/// multiples; half-pel = ±4).
pub fn av1_enc_write_subpel8_skip_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  mv_y8 : Int32,
  mv_x8 : Int32,
  hp~ : Bool = false,
) -> Result[Bytes, String] {
  av1_enc_write_uniform8_skip_tile(
    prepared,
    width,
    height,
    base_q_idx,
    (mv_y8, mv_x8),
    hp~,
  )
}

///|
/// Write the uniform-MV skip=0 zero-residual tile (§447b): same motion
/// chain as §447a, but skip=0 walks the residual syntax — one var-tx
/// split bool (no split → TX_64X64), then all_skip coefficient bools
/// for luma and both chroma planes (eob = −1, no coefficients). The
/// reconstruction is still the MC prediction; the slice validates the
/// var-tx + coefficient-context chain end to end.
pub fn av1_enc_write_newmv_zero_residual_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  mv_y : Int32,
  mv_x : Int32,
  mono~ : Bool = false,
) -> Result[Bytes, String] {
  if mv_y < -1024 || mv_y > 1024 || mv_x < -1024 || mv_x > 1024 {
    return Err("av1 enc: full-pel mv out of ±1024 range")
  }
  let target : (Int32, Int32) = (mv_y * 8, mv_x * 8)
  let bs = av1_block_sizes[(1 * 10 + 0) * 2].to_int()
  let layout = if mono { 0 } else { 1 } // I400 / I420
  let max_ytx = av1_max_txfm_size_for_bs[bs * 4].to_int()
  let uvtx = av1_max_txfm_size_for_bs[bs * 4 + layout].to_int()
  let ss = if mono { 0 } else { 1 }
  // Tx + coefficient context mirrors: a banks persist across rows, the
  // l banks reset per SB row (reset_keyframe values — tx = TX_64X64 = 4,
  // coefficient slots = 0x40 "nothing coded").
  let sb128w = (2 * ((width + 7) >> 3) + 31) >> 5
  let a_tx : Array[FixedArray[Int32]] = []
  let a_lcoef : Array[FixedArray[Int32]] = []
  let a_ccoef : Array[FixedArray[Int32]] = []
  for _ in 0..<sb128w {
    a_tx.push(FixedArray::make(32, 4))
    a_lcoef.push(FixedArray::make(32, 0x40))
    a_ccoef.push(FixedArray::make(64, 0x40))
  }
  let l_tx = FixedArray::make(32, 4)
  let l_lcoef = FixedArray::make(32, 0x40)
  let l_ccoef = FixedArray::make(64, 0x40)
  let err : Ref[String?] = Ref(None)
  let payload = match
    av1_enc_inter_skip_frame_loop(
      prepared,
      width,
      height,
      base_q_idx,
      (enc, cdf, rstate, nstate, a_skip, l_skip, a_part, l_part, bx, by) => {
        let bw = 2 * ((width + 7) >> 3)
        let bh = 2 * ((height + 7) >> 3)
        // The a banks rotate with the loop's a_idx step; the residual
        // tail owns its mirrors, so re-derive the bank from bx like the
        // decoder's a_idx (0 for the first 128px column, +1 after).
        let bank = bx >> 5
        let a_tx_b = a_tx[bank]
        let a_lcoef_b = a_lcoef[bank]
        let a_ccoef_b = a_ccoef[bank]
        av1_enc_inter_skip_block(
          enc,
          cdf,
          rstate,
          nstate,
          a_skip,
          l_skip,
          a_part,
          l_part,
          bs,
          bw,
          bh,
          bx,
          by,
          skip=false,
          motion=(enc2, cdf2, stack) => {
            av1_enc_write_uniform_motion(enc2, cdf2, stack, target, err)
          },
          tail=(enc2, cdf2) => {
            // var-tx: switchable (TX_MODE_LARGEST) + skip=0 → one
            // read_tx_tree call for the 64x64 block: a single split
            // bool at cat = 2*(4 - txfm_max(from)) - depth.
            let lw = av1_txfm_lw(max_ytx)
            let lh = av1_txfm_lh(max_ytx)
            let cat = 2 * (4 - av1_txfm_max(max_ytx))
            let a_bit = if a_tx_b[bx & 31] < lw { 1 } else { 0 }
            let l_bit = if l_tx[by & 31] < lh { 1 } else { 0 }
            enc2.encode_bool_adapt(
              cdf2.txpart,
              (cat * 3 + a_bit + l_bit) * 2,
              0,
            )
            // No split → the leaf fills the tx contexts with lw/lh.
            for i in 0..<(1 << lw) {
              a_tx_b[(bx & 31) + i] = lw
            }
            for i in 0..<(1 << lh) {
              l_tx[(by & 31) + i] = lh
            }
            // Luma all_skip (one 64x64 leaf, no split masks).
            let t_dim_ctx = av1_txfm_ctx(max_ytx)
            let sctx = av1_get_skip_ctx(
              max_ytx,
              bs,
              a_lcoef_b,
              bx & 31,
              l_lcoef,
              by & 31,
              false,
              ss,
              ss,
            )
            enc2.encode_bool_adapt(
              cdf2.coef_skip,
              (t_dim_ctx * 13 + sctx) * 2,
              1,
            )
            let wlen = av1_imin(av1_txfm_w(max_ytx), bw - bx)
            let hlen = av1_imin(av1_txfm_h(max_ytx), bh - by)
            for i in 0..<wlen {
              a_lcoef_b[(bx & 31) + i] = 0x40
            }
            for i in 0..<hlen {
              l_lcoef[(by & 31) + i] = 0x40
            }
            // Chroma: one all_skip per plane at uvtx (420: TX_32X32).
            if !mono {
              let t_dim_ctx_c = av1_txfm_ctx(uvtx)
              for pl in 0..<2 {
                let a_base = pl * 32 + ((bx & 31) >> ss)
                let l_base = pl * 32 + ((by & 31) >> ss)
                let sctx_c = av1_get_skip_ctx(
                  uvtx, bs, a_ccoef_b, a_base, l_ccoef, l_base, true, ss, ss,
                )
                enc2.encode_bool_adapt(
                  cdf2.coef_skip,
                  (t_dim_ctx_c * 13 + sctx_c) * 2,
                  1,
                )
                let ctw = av1_imin(av1_txfm_w(uvtx), (bw - bx + ss) >> ss)
                let cth = av1_imin(av1_txfm_h(uvtx), (bh - by + ss) >> ss)
                for i in 0..<ctw {
                  a_ccoef_b[a_base + i] = 0x40
                }
                for i in 0..<cth {
                  l_ccoef[l_base + i] = 0x40
                }
              }
            }
          },
        )
      },
      on_row=_by => {
        for i in 0..<32 {
          l_tx[i] = 4
          l_lcoef[i] = 0x40
          l_ccoef[i] = 0x40
          l_ccoef[32 + i] = 0x40
        }
      },
    ) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  match err.val {
    Some(e) => Err(e)
    None => Ok(payload)
  }
}

///|
/// Encode a complete all-GLOBALMV skip-only inter frame OBU (§446b):
/// header via `av1_enc_write_inter_frame_obu` (default config — refresh
/// slot 0, all seven refs on slot 0) and the single all-GLOBALMV tile.
/// `refs` is the encoder's reference-store mirror: the preceding key
/// frame must have refreshed it (refresh_without_mvs with 0xFF). The
/// store's slot 0 is refreshed with this frame in return, so a chain of
/// static inter frames works.
pub fn av1_enc_write_globalmv_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  base_q_idx~ : Int32 = 100,
) -> Result[Bytes, String] {
  if seq.width % 64 != 0 || seq.height % 64 != 0 {
    return Err(
      "av1 enc: globalmv inter frame needs 64-multiple geometry (got \{seq.width}x\{seq.height})",
    )
  }
  // The rf the decoder derives from our header (prepare_header):
  // high precision off, integer MV off, identity global motion.
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
    av1_enc_write_globalmv_skip_tile(
      prepared,
      seq.width,
      seq.height,
      base_q_idx,
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
  // The frame's refresh_frame_flags = 1 (slot 0).
  refs.refresh(prepared, 1)
  Ok(obu)
}

///|
/// Encode a uniform-translation inter frame OBU (§447a/§447b):
/// every block codes the same full-pel `(mv_y, mv_x)` (NEWMV on the
/// first blocks, NEARESTMV once the stack carries the target). With
/// `skip=false` (§447b) the blocks walk the residual syntax instead —
/// one var-tx split bool and all_skip coefficient bools per block,
/// reconstruction unchanged. Same reference-store contract as the
/// GLOBALMV entry.
pub fn av1_enc_write_translated_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  base_q_idx~ : Int32 = 100,
  mv_y~ : Int32,
  mv_x~ : Int32,
  skip~ : Bool = true,
) -> Result[Bytes, String] {
  if seq.width % 64 != 0 || seq.height % 64 != 0 {
    return Err(
      "av1 enc: translated inter frame needs 64-multiple geometry (got \{seq.width}x\{seq.height})",
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
  let tile = if skip {
    match
      av1_enc_write_newmv_skip_tile(
        prepared,
        seq.width,
        seq.height,
        base_q_idx,
        mv_y,
        mv_x,
      ) {
      Ok(t) => t
      Err(e) => return Err(e)
    }
  } else {
    match
      av1_enc_write_newmv_zero_residual_tile(
        prepared,
        seq.width,
        seq.height,
        base_q_idx,
        mv_y,
        mv_x,
        mono=seq.monochrome,
      ) {
      Ok(t) => t
      Err(e) => return Err(e)
    }
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
/// Write the per-superblock ME + dc-token inter tile (§447c): each
/// 64x64 block targets its own full-pel `(mvs_y, mvs_x)` (raster order)
/// through the shared uniform-motion chain (NEARESTMV when the stack's
/// top candidate hits, NEWMV otherwise), then the skip=0 residual
/// syntax: one var-tx split bool (no split) and the luma txb — all_skip
/// for `dc_toks[sb] = 0`, else a dc-only token 1..=3 with sign (eob=0,
/// the eob-position base_tok trick). Chroma stays all_skip. The
/// coefficient-context mirror follows the decoder: all_skip leaves
/// 0x40, a coded dc leaves res_ctx = tok | (positive ? 1<<7 : 0)
/// (`av1_decode_coefs`: cul_level | (sign−1)&(2<<6)).
pub fn av1_enc_write_me_dc_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  mvs_y : FixedArray[Int32],
  mvs_x : FixedArray[Int32],
  dc_toks : FixedArray[Int32],
  dc_signs : FixedArray[Int32],
  mono~ : Bool = false,
  /// When true the mv arrays are already in 1/8-pel units (sub-pel
  /// targets from `av1_enc_me_subpel_refine`); the default multiplies
  /// by 8 (full-pel input).
  mv8~ : Bool = false,
  /// High-precision mvs: odd 1/8-pel components become codable (the
  /// frame entry must set allow_high_precision to match).
  hp~ : Bool = false,
) -> Result[Bytes, String] {
  if width <= 0 || height <= 0 || width % 64 != 0 || height % 64 != 0 {
    return Err(
      "av1 enc: me tile needs 64-multiple geometry (got \{width}x\{height})",
    )
  }
  let sb_cols = width >> 6
  let sb_rows = height >> 6
  let n_sb = sb_cols * sb_rows
  if mvs_y.length() != n_sb ||
    mvs_x.length() != n_sb ||
    dc_toks.length() != n_sb ||
    dc_signs.length() != n_sb {
    return Err(
      "av1 enc: me tile needs \{n_sb} per-SB entries (got \{mvs_y.length()}/\{mvs_x.length()}/\{dc_toks.length()}/\{dc_signs.length()})",
    )
  }
  for i in 0..<n_sb {
    if mvs_y[i] < -1024 ||
      mvs_y[i] > 1024 ||
      mvs_x[i] < -1024 ||
      mvs_x[i] > 1024 {
      return Err("av1 enc: full-pel mv out of ±1024 range")
    }
    if dc_toks[i] < 0 || dc_toks[i] > 3 {
      return Err("av1 enc: dc token must be 0..=3")
    }
    if dc_signs[i] < 0 || dc_signs[i] > 1 {
      return Err("av1 enc: dc sign must be 0 or 1")
    }
  }
  if base_q_idx < 1 || base_q_idx > 255 {
    return Err("av1 enc: base_q_idx must be 1..=255")
  }
  let bs = av1_block_sizes[(1 * 10 + 0) * 2].to_int()
  let layout = if mono { 0 } else { 1 } // I400 / I420
  let max_ytx = av1_max_txfm_size_for_bs[bs * 4].to_int()
  let uvtx = av1_max_txfm_size_for_bs[bs * 4 + layout].to_int()
  let ss = if mono { 0 } else { 1 }
  // Tx + coefficient context mirrors (as §447b; the l banks reset per
  // SB row via on_row).
  let sb128w = (2 * ((width + 7) >> 3) + 31) >> 5
  let a_tx : Array[FixedArray[Int32]] = []
  let a_lcoef : Array[FixedArray[Int32]] = []
  let a_ccoef : Array[FixedArray[Int32]] = []
  for _ in 0..<sb128w {
    a_tx.push(FixedArray::make(32, 4))
    a_lcoef.push(FixedArray::make(32, 0x40))
    a_ccoef.push(FixedArray::make(64, 0x40))
  }
  let l_tx = FixedArray::make(32, 4)
  let l_lcoef = FixedArray::make(32, 0x40)
  let l_ccoef = FixedArray::make(64, 0x40)
  let err : Ref[String?] = Ref(None)
  let payload = match
    av1_enc_inter_skip_frame_loop(
      prepared,
      width,
      height,
      base_q_idx,
      (enc, cdf, rstate, nstate, a_skip, l_skip, a_part, l_part, bx, by) => {
        let bw = 2 * ((width + 7) >> 3)
        let bh = 2 * ((height + 7) >> 3)
        let sbx = bx >> 4
        let sby = by >> 4
        let sb = sby * sb_cols + sbx
        let target : (Int32, Int32) = if mv8 {
          (mvs_y[sb], mvs_x[sb])
        } else {
          (mvs_y[sb] * 8, mvs_x[sb] * 8)
        }
        let tok = dc_toks[sb]
        let sign = dc_signs[sb]
        let bank = bx >> 5
        let a_tx_b = a_tx[bank]
        let a_lcoef_b = a_lcoef[bank]
        let a_ccoef_b = a_ccoef[bank]
        av1_enc_inter_skip_block(
          enc,
          cdf,
          rstate,
          nstate,
          a_skip,
          l_skip,
          a_part,
          l_part,
          bs,
          bw,
          bh,
          bx,
          by,
          skip=false,
          motion=(enc2, cdf2, stack) => {
            av1_enc_write_uniform_motion(enc2, cdf2, stack, target, err, hp~)
          },
          tail=(enc2, cdf2) => {
            // var-tx split bool (no split), as §447b.
            let lw = av1_txfm_lw(max_ytx)
            let lh = av1_txfm_lh(max_ytx)
            let cat = 2 * (4 - av1_txfm_max(max_ytx))
            let a_bit = if a_tx_b[bx & 31] < lw { 1 } else { 0 }
            let l_bit = if l_tx[by & 31] < lh { 1 } else { 0 }
            enc2.encode_bool_adapt(
              cdf2.txpart,
              (cat * 3 + a_bit + l_bit) * 2,
              0,
            )
            for i in 0..<(1 << lw) {
              a_tx_b[(bx & 31) + i] = lw
            }
            for i in 0..<(1 << lh) {
              l_tx[(by & 31) + i] = lh
            }
            // Luma txb: all_skip or a dc-only token.
            let t_dim_ctx = av1_txfm_ctx(max_ytx)
            let sctx = av1_get_skip_ctx(
              max_ytx,
              bs,
              a_lcoef_b,
              bx & 31,
              l_lcoef,
              by & 31,
              false,
              ss,
              ss,
            )
            let wlen = av1_imin(av1_txfm_w(max_ytx), bw - bx)
            let hlen = av1_imin(av1_txfm_h(max_ytx), bh - by)
            let res_ctx = tok | (if sign == 0 { 1 << 7 } else { 0 })
            if tok == 0 {
              enc2.encode_bool_adapt(
                cdf2.coef_skip,
                (t_dim_ctx * 13 + sctx) * 2,
                1,
              )
            } else {
              enc2.encode_bool_adapt(
                cdf2.coef_skip,
                (t_dim_ctx * 13 + sctx) * 2,
                0,
              )
              enc2.encode_symbol_adapt(cdf2.eob_bin_1024, 0, 10, 0)
              enc2.encode_symbol_adapt(
                cdf2.eob_base_tok,
                (t_dim_ctx * 2 + 0) * 16,
                2,
                tok - 1,
              )
              let dcs = av1_get_dc_sign_ctx(
                max_ytx,
                a_lcoef_b,
                bx & 31,
                l_lcoef,
                by & 31,
              )
              let sbit : UInt32 = if sign != 0 { 1U } else { 0U }
              enc2.encode_bool_adapt(cdf2.dc_sign, (0 * 3 + dcs) * 2, sbit)
            }
            for i in 0..<wlen {
              a_lcoef_b[(bx & 31) + i] = if tok == 0 { 0x40 } else { res_ctx }
            }
            for i in 0..<hlen {
              l_lcoef[(by & 31) + i] = if tok == 0 { 0x40 } else { res_ctx }
            }
            // Chroma: all_skip per plane (as §447b).
            if !mono {
              let t_dim_ctx_c = av1_txfm_ctx(uvtx)
              for pl in 0..<2 {
                let a_base = pl * 32 + ((bx & 31) >> ss)
                let l_base = pl * 32 + ((by & 31) >> ss)
                let sctx_c = av1_get_skip_ctx(
                  uvtx, bs, a_ccoef_b, a_base, l_ccoef, l_base, true, ss, ss,
                )
                enc2.encode_bool_adapt(
                  cdf2.coef_skip,
                  (t_dim_ctx_c * 13 + sctx_c) * 2,
                  1,
                )
                let ctw = av1_imin(av1_txfm_w(uvtx), (bw - bx + ss) >> ss)
                let cth = av1_imin(av1_txfm_h(uvtx), (bh - by + ss) >> ss)
                for i in 0..<ctw {
                  a_ccoef_b[a_base + i] = 0x40
                }
                for i in 0..<cth {
                  l_ccoef[l_base + i] = 0x40
                }
              }
            }
          },
        )
      },
      on_row=_by => {
        for i in 0..<32 {
          l_tx[i] = 4
          l_lcoef[i] = 0x40
          l_ccoef[i] = 0x40
          l_ccoef[32 + i] = 0x40
        }
      },
    ) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  match err.val {
    Some(e) => Err(e)
    None => Ok(payload)
  }
}
