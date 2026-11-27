///|
/// §449a per-superblock ME + full-residual inter tile writer: each
/// 64x64 block targets its 1/8-pel `(mvs_y8, mvs_x8)` through the
/// shared uniform-motion chain, then the skip=0 residual syntax with a
/// var-tx SPLIT — one root split bool (TX_64X64 → four TX_32X32
/// leaves) and four leaf split bools, then four luma TX_32X32 txb
/// chains from the caller's §443 token specs (all_skip when a leaf
/// quantized to zero; a txtp_inter3 bool rides every coded leaf — the
/// inter TX_32X32 DCT_DCT selector), then the chroma U/V pair —
/// all_skip by default, or full TX_32X32 token chains when
/// `chroma_toks`/`chroma_signs` are supplied (§449b: per SB 2 planes ×
/// 1024 scan-order slots; the chroma txtp derives from the luma's with
/// no bits). The coefficient-context mirror follows the decoder: per
/// txb res_ctx = min(cul,63) | (dc positive ? 1<<7 : 0) published to
/// the a/l banks over the txb's columns (all_skip leaves 0x40), and
/// the tx banks fill with the leaf's lw after each leaf bool.

///|
/// §498: one split SB — PARTITION_SPLIT at bl=1 followed by four 32x32
/// PARTITION_NONE blocks, each with its own reference tree, motion chain
/// (quadrant mv from the caller's ME), a no-split TX_32X32 luma txb and
/// all-skip chroma. Mirrors decode_sb's SPLIT recursion (no a/l write-back
/// at bl=1; the per-sub-block bl=2 NONE write-back happens after each
/// sub-block) and decode_b's inter branch at bl=2, with the sub-blocks'
/// `top_has_right` from the intra edge tree (quadrants 0..2 carry it, the
/// bottom-right one does not).
fn av1_enc_inter_split_sb(
  enc : Av1MsacEnc,
  cdf : Av1CdfCtx,
  rstate : Av1RefmvsFrameState,
  nstate : Av1InterTileState,
  a_skip : FixedArray[Int32],
  l_skip : FixedArray[Int32],
  a_part : FixedArray[Int32],
  l_part : FixedArray[Int32],
  a_tx : FixedArray[Int32],
  l_tx : FixedArray[Int32],
  a_lcoef : FixedArray[Int32],
  l_lcoef : FixedArray[Int32],
  a_ccoef : FixedArray[Int32],
  l_ccoef : FixedArray[Int32],
  bw : Int32,
  bh : Int32,
  bx : Int32,
  by : Int32,
  ref_idx : Int32,
  mono : Bool,
  layout : Int32,
  ss : Int32,
  mvs_y8 : FixedArray[Int32],
  mvs_x8 : FixedArray[Int32],
  tok_specs : FixedArray[Int32],
  sign_specs : FixedArray[Int32],
  sb : Int32,
  err : Ref[String?],
  drl : Bool,
  /// §500: per-quadrant chroma token specs ((sb*8+q*2+pl)*256, TX_16X16
  /// scan order); an empty array keeps the §498 all-skip chroma.
  sct : FixedArray[Int32],
  scs : FixedArray[Int32],
) -> Unit {
  let bs32 = av1_block_sizes[(2 * 10 + 0) * 2].to_int()
  let uvtx32 = av1_max_txfm_size_for_bs[bs32 * 4 + layout].to_int()
  // ---- PARTITION_SPLIT at bl=1. The decoder's write-back is skipped for
  // SPLIT at bl < 4, so the banks stay as the previous blocks left them.
  let xb8 = (bx & 31) >> 1
  let yb8 = (by & 31) >> 1
  let pctx = ((a_part[xb8] >> 3) & 1) + (((l_part[yb8] >> 3) & 1) << 1)
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + pctx) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_split,
  )
  for q in 0..<4 {
    let qx4 = bx + q % 2 * 8
    let qy4 = by + q / 2 * 8
    // PARTITION_NONE at bl=2 (both edge splits are available for every
    // 32x32 quadrant under 64-multiple geometry).
    let xb8q = (qx4 & 31) >> 1
    let yb8q = (qy4 & 31) >> 1
    let pctxq = ((a_part[xb8q] >> 2) & 1) + (((l_part[yb8q] >> 2) & 1) << 1)
    enc.encode_symbol_adapt(
      cdf.partition,
      (2 * 4 + pctxq) * 16,
      av1_partition_type_count[2].to_int(),
      av1_partition_none,
    )
    // Split sub-blocks always code skip = 0.
    let sctxq = a_skip[qx4 & 31] + l_skip[qy4 & 31]
    enc.encode_bool_adapt(cdf.skip, sctxq * 2, 0U)
    let top_opt = if qy4 > 0 { Some(nstate.top[qx4 & 31]) } else { None }
    let left_opt = if qx4 > 0 { Some(nstate.left[qy4 & 31]) } else { None }
    let ictx = av1_inter_intra_ctx(top_opt, left_opt)
    enc.encode_bool_adapt(cdf.intra, ictx * 2, 1U)
    let top_any : Av1InterNeighbor? = Some(nstate.top[qx4 & 31])
    let left_any : Av1InterNeighbor? = Some(nstate.left[qy4 & 31])
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
    let stack = rstate.find(
      0,
      bw,
      0,
      bh,
      ref_idx + 1,
      -1,
      bs32,
      q != 3,
      qy4,
      qx4,
    )
    let target_q : (Int32, Int32) = (mvs_y8[sb * 4 + q], mvs_x8[sb * 4 + q])
    let (mode, mv) = av1_enc_write_uniform_motion(
      enc,
      cdf,
      stack,
      target_q,
      err,
      drl~,
    )
    // ---- residual tail: no-split TX_32X32 luma txb + all-skip chroma.
    // var-tx root bool at depth 0 from TX_32X32: cat = 2*(4-3)-0 = 2.
    let a_bit = if a_tx[qx4 & 31] < 3 { 1 } else { 0 }
    let l_bit = if l_tx[qy4 & 31] < 3 { 1 } else { 0 }
    enc.encode_bool_adapt(cdf.txpart, (2 * 3 + a_bit + l_bit) * 2, 0U)
    for i in 0..<8 {
      a_tx[(qx4 & 31) + i] = 3
      l_tx[(qy4 & 31) + i] = 3
    }
    let t_dim_ctx = av1_txfm_ctx(3)
    let a_leaf = FixedArray::make(8, 0)
    let l_leaf = FixedArray::make(8, 0)
    for i in 0..<8 {
      a_leaf[i] = a_lcoef[(qx4 & 31) + i]
      l_leaf[i] = l_lcoef[(qy4 & 31) + i]
    }
    let sctx = av1_get_skip_ctx(3, bs32, a_leaf, 0, l_leaf, 0, false, ss, ss)
    let base = (sb * 4 + q) * 1024
    let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
    let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
    let mut cul = 0
    let mut any = false
    for i2 in 0..<1024 {
      toks[i2] = tok_specs[base + i2]
      signs[i2] = sign_specs[base + i2]
      cul += toks[i2]
      if toks[i2] != 0 {
        any = true
      }
    }
    let res_ctx = if !any {
      enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx * 13 + sctx) * 2, 1U)
      0x40
    } else {
      enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx * 13 + sctx) * 2, 0U)
      enc.encode_bool_adapt(cdf.txtp_inter3, av1_txfm_min(3) * 2, 1U)
      av1_enc_txb_tokens(
        enc,
        cdf,
        3,
        0,
        bs32,
        toks,
        signs,
        a_leaf,
        l_leaf,
        coef_skip_written=true,
      )
      av1_imin(cul, 63) | av1_enc_res_sign_field(toks[0], signs[0])
    }
    for i2 in 0..<8 {
      a_lcoef[(qx4 & 31) + i2] = res_ctx
      l_lcoef[(qy4 & 31) + i2] = res_ctx
    }
    // Chroma: per plane at the sub-block's uvtx (TX_16X16 for a 32x32
    // 4:2:0 block) — all_skip, or a full §443 token chain from the
    // §500 quadrant specs (the chroma txtp derives from the luma's with
    // no bits, as §449b).
    if !mono {
      let t_dim_ctx_c = av1_txfm_ctx(uvtx32)
      for pl in 0..<2 {
        let a_base = pl * 32 + ((qx4 & 31) >> 1)
        let l_base = pl * 32 + ((qy4 & 31) >> 1)
        let sctx_c = av1_get_skip_ctx(
          uvtx32, bs32, a_ccoef, a_base, l_ccoef, l_base, true, ss, ss,
        )
        let ctw = av1_imin(av1_txfm_w(uvtx32), (bw - qx4 + 1) >> 1)
        let cth = av1_imin(av1_txfm_h(uvtx32), (bh - qy4 + 1) >> 1)
        let a_leaf_c = FixedArray::make(4, 0)
        let l_leaf_c = FixedArray::make(4, 0)
        for i2 in 0..<4 {
          a_leaf_c[i2] = a_ccoef[a_base + i2]
          l_leaf_c[i2] = l_ccoef[l_base + i2]
        }
        let base_c = (sb * 8 + q * 2 + pl) * 256
        let toks_c : FixedArray[Int32] = FixedArray::make(256, 0)
        let signs_c : FixedArray[Int32] = FixedArray::make(256, 0)
        let mut cul_c = 0
        let mut any_c = false
        if sct.length() > 0 {
          for i2 in 0..<256 {
            toks_c[i2] = sct[base_c + i2]
            signs_c[i2] = scs[base_c + i2]
            cul_c += toks_c[i2]
            if toks_c[i2] != 0 {
              any_c = true
            }
          }
        }
        let res_ctx_c = if !any_c {
          enc.encode_bool_adapt(
            cdf.coef_skip,
            (t_dim_ctx_c * 13 + sctx_c) * 2,
            1U,
          )
          0x40
        } else {
          enc.encode_bool_adapt(
            cdf.coef_skip,
            (t_dim_ctx_c * 13 + sctx_c) * 2,
            0U,
          )
          av1_enc_txb_tokens(
            enc,
            cdf,
            uvtx32,
            1,
            bs32,
            toks_c,
            signs_c,
            a_leaf_c,
            l_leaf_c,
            coef_skip_written=true,
          )
          av1_imin(cul_c, 63) | av1_enc_res_sign_field(toks_c[0], signs_c[0])
        }
        for i2 in 0..<ctw {
          a_ccoef[a_base + i2] = res_ctx_c
        }
        for i2 in 0..<cth {
          l_ccoef[l_base + i2] = res_ctx_c
        }
      }
    }
    // ---- publishes: refmvs splat, neighbor banks, skip edges, then the
    // bl=2 partition write-back (the decoder writes it after the
    // sub-block's decode_b, over min(hsz=4, 16) = 4 8px slots).
    rstate.splat_single(ref_idx, mode, mv, false, bs32, qx4, qy4, 8, 8)
    nstate.set_block(qx4, qy4, 8, 8, {
      intra: false,
      comp_type: 0,
      ref0: ref_idx,
      ref1: -1,
      filter0: 0,
      filter1: 0,
    })
    for i in 0..<8 {
      a_skip[(qx4 & 31) + i] = 0
      l_skip[(qy4 & 31) + i] = 0
    }
    let alq = av1_al_part_ctx[(0 * 5 + 2) * 10 + av1_partition_none].to_int()
    let allq = av1_al_part_ctx[(1 * 5 + 2) * 10 + av1_partition_none].to_int()
    for i in 0..<4 {
      a_part[xb8q + i] = alq
      l_part[yb8q + i] = allq
    }
  }
}

///|
pub fn av1_enc_write_me_res_tile(
  prepared : Av1RefmvsPreparedFrame,
  width : Int32,
  height : Int32,
  base_q_idx : Int32,
  mvs_y8 : FixedArray[Int32],
  mvs_x8 : FixedArray[Int32],
  tok_specs : FixedArray[Int32],
  sign_specs : FixedArray[Int32],
  mono~ : Bool = false,
  chroma_toks~ : FixedArray[Int32]? = None,
  chroma_signs~ : FixedArray[Int32]? = None,
  /// §458: per-SB skip decision. A skipped SB codes GLOBALMV (zero MV)
  /// with no residual symbols — its prediction is a direct block copy —
  /// while a non-skipped SB takes the full residual chain below. When
  /// omitted every SB is non-skip, preserving the §449b behavior.
  /// Skipped SBs must carry mv8 = (0, 0); the residual token slots for a
  /// skipped SB are ignored by the writer.
  skip_flags~ : FixedArray[Bool]? = None,
  /// §460: when true, a skipped SB codes its mv8 through the uniform
  /// motion chain (NEWMV/NEARESTMV, so the coded MV equals `mvs_*8[sb]`)
  /// instead of GLOBALMV — this is NEARMV skip for non-zero MVs. The
  /// zero-MV guard is lifted in this mode. Default false keeps §458.
  skip_uniform~ : Bool = false,
  /// §463: the single reference index (dav1d 0..6) every block codes.
  ref_idx~ : Int32 = 0,
  /// §498: per-SB partition decision. A split SB codes PARTITION_SPLIT
  /// followed by four 32x32 NONE blocks, each with its own motion chain
  /// (from `split_mvs_*8`, quadrant order TL/TR/BL/BR) and one TX_32X32
  /// luma txb (the same (sb*4+q) token slots the 64x64 NONE path uses for
  /// its leaves); chroma stays all_skip on split SBs. When omitted every
  /// SB keeps the 64x64 NONE partition, preserving the §449b output.
  /// A split SB must not be skipped (skip suppresses the partition).
  splits~ : FixedArray[Bool]? = None,
  split_mvs_y8~ : FixedArray[Int32]? = None,
  split_mvs_x8~ : FixedArray[Int32]? = None,
  /// §499: NEARMV stack hits (drl bools, no MV payload) instead of NEWMV
  /// when a deeper refmv candidate equals the target. Default false keeps
  /// the §447a chain byte-identical.
  drl~ : Bool = false,
  /// §500: per-quadrant chroma token specs for split SBs —
  /// (sb*8 + q*2 + pl) * 256 slots of TX_16X16 scan order. When omitted
  /// (or empty) split SBs keep all-skip chroma (§498 behaviour).
  split_chroma_toks~ : FixedArray[Int32]? = None,
  split_chroma_signs~ : FixedArray[Int32]? = None,
) -> Result[Bytes, String] {
  if width <= 0 || height <= 0 || width % 64 != 0 || height % 64 != 0 {
    return Err(
      "av1 enc: me res tile needs 64-multiple geometry (got \{width}x\{height})",
    )
  }
  let sb_cols = width >> 6
  let sb_rows = height >> 6
  let n_sb = sb_cols * sb_rows
  if mvs_y8.length() != n_sb ||
    mvs_x8.length() != n_sb ||
    tok_specs.length() != n_sb * 4 * 1024 ||
    sign_specs.length() != n_sb * 4 * 1024 {
    return Err("av1 enc: me res tile needs per-SB mv and 4x1024 token entries")
  }
  let ct = chroma_toks.unwrap_or(FixedArray::make(0, 0))
  let cs = chroma_signs.unwrap_or(FixedArray::make(0, 0))
  let chroma_full = ct.length() > 0
  let skips = skip_flags.unwrap_or(FixedArray::make(n_sb, false))
  if skips.length() != n_sb {
    return Err("av1 enc: me res tile needs one skip flag per SB")
  }
  for i in 0..<n_sb {
    if skips[i] && !skip_uniform && (mvs_y8[i] != 0 || mvs_x8[i] != 0) {
      return Err(
        "av1 enc: a skipped SB must have mv8 = (0, 0) unless skip_uniform",
      )
    }
  }
  // §498: split flags and per-quadrant MVs; §500: split chroma tokens.
  let sp = splits.unwrap_or(FixedArray::make(n_sb, false))
  let smy = split_mvs_y8.unwrap_or(FixedArray::make(0, 0))
  let smx = split_mvs_x8.unwrap_or(FixedArray::make(0, 0))
  let sct = split_chroma_toks.unwrap_or(FixedArray::make(0, 0))
  let scs = split_chroma_signs.unwrap_or(FixedArray::make(0, 0))
  let mut any_split = false
  for i in 0..<n_sb {
    if sp[i] {
      any_split = true
      if skips[i] {
        return Err("av1 enc: a split SB cannot be skipped")
      }
    }
  }
  if any_split &&
    (smy.length() != n_sb * 4 || smx.length() != n_sb * 4 || splits is None) {
    return Err(
      "av1 enc: split SBs need 4 quadrant mv entries per SB (got \{smy.length()}/\{smx.length()})",
    )
  }
  if sct.length() > 0 &&
    (mono || sct.length() != n_sb * 8 * 256 || scs.length() != n_sb * 8 * 256) {
    return Err(
      "av1 enc: split chroma token specs need 8x256 entries per SB (non-mono)",
    )
  }
  if chroma_full &&
    (mono || ct.length() != n_sb * 2 * 1024 || cs.length() != n_sb * 2 * 1024) {
    return Err(
      "av1 enc: chroma token specs need 2x1024 entries per SB (non-mono)",
    )
  }
  if base_q_idx < 1 || base_q_idx > 255 {
    return Err("av1 enc: base_q_idx must be 1..=255")
  }
  let bs = av1_block_sizes[(1 * 10 + 0) * 2].to_int()
  let layout = if mono { 0 } else { 1 } // I400 / I420
  let uvtx = av1_max_txfm_size_for_bs[bs * 4 + layout].to_int()
  let ss = if mono { 0 } else { 1 }
  // TX_32X32 constants for the split leaves.
  let tx_leaf = 3
  let lw_leaf = av1_txfm_lw(tx_leaf) // 3
  let t_dim_ctx_leaf = av1_txfm_ctx(tx_leaf)
  let t_dim_min_leaf = av1_txfm_min(tx_leaf)
  // Tx + coefficient context mirrors (init = reset_keyframe; l banks
  // reset per SB row via on_row; a banks per 128px column).
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
        let target : (Int32, Int32) = (mvs_y8[sb], mvs_x8[sb])
        let is_skip = skips[sb]
        let is_split = sp[sb]
        let bank = bx >> 5
        let a_tx_b = a_tx[bank]
        let a_lcoef_b = a_lcoef[bank]
        let a_ccoef_b = a_ccoef[bank]
        if is_split {
          av1_enc_inter_split_sb(
            enc, cdf, rstate, nstate, a_skip, l_skip, a_part, l_part, a_tx_b, l_tx,
            a_lcoef_b, l_lcoef, a_ccoef_b, l_ccoef, bw, bh, bx, by, ref_idx, mono,
            layout, ss, smy, smx, tok_specs, sign_specs, sb, err, drl, sct, scs,
          )
        } else {
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
            skip=is_skip,
            ref_idx~,
            motion=(enc2, cdf2, stack) => {
              if is_skip && !skip_uniform {
                // GLOBALMV: newmv_mode=1 (not new), globalmv_mode=0
                // (identity GM → zero MV). Mirrors §446b's skip writer.
                enc2.encode_bool_adapt(cdf2.newmv_mode, (stack.ctx & 7) * 2, 1)
                enc2.encode_bool_adapt(
                  cdf2.globalmv_mode,
                  ((stack.ctx >> 3) & 1) * 2,
                  0,
                )
                (2, (0, 0))
              } else {
                // §460 NEARMV skip (and the usual skip=0 path): the uniform
                // chain codes NEWMV or NEARESTMV so the coded MV equals
                // `target` (= the frame's ME result). Skip still suppresses
                // the residual tail, so only the MV bits are spent.
                av1_enc_write_uniform_motion(
                  enc2,
                  cdf2,
                  stack,
                  target,
                  err,
                  drl~,
                )
              }
            },
            tail=(enc2, cdf2) => {
              if is_skip {
                // Skip=1 reads no tx/token symbols, but the decoder still
                // fills the context banks: vartx fill for a whole block at
                // its lw/lh (switchable path, `av1_read_vartx_tree`) and
                // zero coef contexts (0x40, `av1_recon_b_inter` skip path).
                // Mirroring them keeps the next block's contexts in sync.
                let bw_lw = av1_block_dimensions[bs * 4 + 2].to_int()
                let bh_lh = av1_block_dimensions[bs * 4 + 3].to_int()
                for i in 0..<(1 << bw_lw) {
                  a_tx_b[(bx & 31) + i] = bw_lw
                }
                for i in 0..<(1 << bh_lh) {
                  l_tx[(by & 31) + i] = bh_lh
                }
                let bw4 = av1_block_dimensions[bs * 4].to_int()
                let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
                for i in 0..<bw4 {
                  a_lcoef_b[(bx & 31) + i] = 0x40
                }
                for i in 0..<bh4 {
                  l_lcoef[(by & 31) + i] = 0x40
                }
                if !mono {
                  let cbw4 = (bw4 + ss) >> ss
                  let cbh4 = (bh4 + ss) >> ss
                  for pl in 0..<2 {
                    let a_base = pl * 32 + ((bx & 31) >> ss)
                    let l_base = pl * 32 + ((by & 31) >> ss)
                    for i in 0..<cbw4 {
                      a_ccoef_b[a_base + i] = 0x40
                    }
                    for i in 0..<cbh4 {
                      l_ccoef[l_base + i] = 0x40
                    }
                  }
                }
              } else {
                // ---- var-tx tree: root split bool, then four leaf bools.
                // Root: cat = 2*(4 - txfm_max(TX_64X64)) - 0 = 0, ctx from
                // the tx banks (comparison against TX_64X64's lw = 4).
                let a_bit0 = if a_tx_b[bx & 31] < 4 { 1 } else { 0 }
                let l_bit0 = if l_tx[by & 31] < 4 { 1 } else { 0 }
                enc2.encode_bool_adapt(
                  cdf2.txpart,
                  (0 * 3 + a_bit0 + l_bit0) * 2,
                  1,
                )
                // Leaves in tree order TL, TR, BL, BR; cat = 1, ctx from
                // the banks against the leaf lw (fresh 4s and earlier
                // leaf fills both read as 0 bits — 4 < 3 and 3 < 3 are
                // false), each filling its 8 slots with lw.
                let leaf0 = (0, 0)
                let leaf1 = (8, 0)
                let leaf2 = (0, 8)
                let leaf3 = (8, 8)
                for leaf in [leaf0, leaf1, leaf2, leaf3] {
                  let ax = (bx + leaf.0) & 31
                  let ly = (by + leaf.1) & 31
                  let a_bit = if a_tx_b[ax] < lw_leaf { 1 } else { 0 }
                  let l_bit = if l_tx[ly] < lw_leaf { 1 } else { 0 }
                  enc2.encode_bool_adapt(
                    cdf2.txpart,
                    (1 * 3 + a_bit + l_bit) * 2,
                    0,
                  )
                  for i in 0..<(1 << lw_leaf) {
                    a_tx_b[ax + i] = lw_leaf
                    l_tx[ly + i] = lw_leaf
                  }
                }
                // ---- four luma TX_32X32 txb chains.
                for li in 0..<4 {
                  let leaf = match li {
                    0 => leaf0
                    1 => leaf1
                    2 => leaf2
                    _ => leaf3
                  }
                  let ax = (bx + leaf.0) & 31
                  let ly = (by + leaf.1) & 31
                  // Per-leaf context copies (the token writer reads them
                  // at offset 0; the decoder reads the banks directly —
                  // identical values).
                  let a_leaf = FixedArray::make(8, 0)
                  let l_leaf = FixedArray::make(8, 0)
                  for i in 0..<8 {
                    a_leaf[i] = a_lcoef_b[ax + i]
                    l_leaf[i] = l_lcoef[ly + i]
                  }
                  let sctx = av1_get_skip_ctx(
                    tx_leaf, bs, a_leaf, 0, l_leaf, 0, false, ss, ss,
                  )
                  let base = (sb * 4 + li) * 1024
                  let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
                  let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
                  for i in 0..<1024 {
                    toks[i] = tok_specs[base + i]
                    signs[i] = sign_specs[base + i]
                  }
                  let mut cul = 0
                  let mut any = false
                  for i2 in 0..<1024 {
                    cul += toks[i2]
                    if toks[i2] != 0 {
                      any = true
                    }
                  }
                  let res_ctx = if !any {
                    enc2.encode_bool_adapt(
                      cdf2.coef_skip,
                      (t_dim_ctx_leaf * 13 + sctx) * 2,
                      1,
                    )
                    0x40
                  } else {
                    enc2.encode_bool_adapt(
                      cdf2.coef_skip,
                      (t_dim_ctx_leaf * 13 + sctx) * 2,
                      0,
                    )
                    // Inter TX_32X32 luma reads one txtp_inter3 bool
                    // (DCT_DCT selector; the txfm_max == 3 branch).
                    enc2.encode_bool_adapt(
                      cdf2.txtp_inter3,
                      t_dim_min_leaf * 2,
                      1,
                    )
                    av1_enc_txb_tokens(
                      enc2,
                      cdf2,
                      tx_leaf,
                      0,
                      bs,
                      toks,
                      signs,
                      a_leaf,
                      l_leaf,
                      coef_skip_written=true,
                    )
                    av1_imin(cul, 63) |
                    av1_enc_res_sign_field(toks[0], signs[0])
                  }
                  for i2 in 0..<8 {
                    a_lcoef_b[ax + i2] = res_ctx
                    l_lcoef[ly + i2] = res_ctx
                  }
                }
                // ---- chroma U/V at uvtx: all_skip (§447b) or full token
                // chains (§449b — the chroma txtp derives from the luma's
                // with no bits; the txb covers the whole 64x64 block's
                // 4:2:0 chroma at TX_32X32).
                if !mono {
                  let t_dim_ctx_c = av1_txfm_ctx(uvtx)
                  for pl in 0..<2 {
                    let a_base = pl * 32 + ((bx & 31) >> ss)
                    let l_base = pl * 32 + ((by & 31) >> ss)
                    let sctx_c = av1_get_skip_ctx(
                      uvtx, bs, a_ccoef_b, a_base, l_ccoef, l_base, true, ss, ss,
                    )
                    let ctw = av1_imin(av1_txfm_w(uvtx), (bw - bx + ss) >> ss)
                    let cth = av1_imin(av1_txfm_h(uvtx), (bh - by + ss) >> ss)
                    // Per-plane context copies (8 chroma columns — the
                    // chroma sctx reads (1 << lw) = 8 slots for TX_32X32)
                    // and the token spec, hoisted so the sctx and the
                    // all_skip decision share one source of truth.
                    let a_leaf = FixedArray::make(8, 0)
                    let l_leaf = FixedArray::make(8, 0)
                    for i2 in 0..<8 {
                      a_leaf[i2] = a_ccoef_b[a_base + i2]
                      l_leaf[i2] = l_ccoef[l_base + i2]
                    }
                    let base_c = (sb * 2 + pl) * 1024
                    let toks_c : FixedArray[Int32] = FixedArray::make(1024, 0)
                    let signs_c : FixedArray[Int32] = FixedArray::make(1024, 0)
                    let mut cul_c = 0
                    let mut any_c = false
                    if chroma_full {
                      for i2 in 0..<1024 {
                        toks_c[i2] = ct[base_c + i2]
                        signs_c[i2] = cs[base_c + i2]
                        cul_c += toks_c[i2]
                        if toks_c[i2] != 0 {
                          any_c = true
                        }
                      }
                    }
                    let res_ctx_c = if !any_c {
                      enc2.encode_bool_adapt(
                        cdf2.coef_skip,
                        (t_dim_ctx_c * 13 + sctx_c) * 2,
                        1,
                      )
                      0x40
                    } else {
                      enc2.encode_bool_adapt(
                        cdf2.coef_skip,
                        (t_dim_ctx_c * 13 + sctx_c) * 2,
                        0,
                      )
                      // The chroma txtp derives from the luma's (both
                      // DCT_DCT) with no bits; the token chain follows.
                      // The chroma ctx flag is 0/1 (both U and V read as
                      // chroma) — NOT the plane index.
                      av1_enc_txb_tokens(
                        enc2,
                        cdf2,
                        uvtx,
                        1,
                        bs,
                        toks_c,
                        signs_c,
                        a_leaf,
                        l_leaf,
                        coef_skip_written=true,
                      )
                      av1_imin(cul_c, 63) |
                      av1_enc_res_sign_field(toks_c[0], signs_c[0])
                    }
                    for i2 in 0..<ctw {
                      a_ccoef_b[a_base + i2] = res_ctx_c
                    }
                    for i2 in 0..<cth {
                      l_ccoef[l_base + i2] = res_ctx_c
                    }
                  }
                } // end residual (skip=false) branch
              }
            },
          )
        }
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
