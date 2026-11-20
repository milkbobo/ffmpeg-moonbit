///|
/// §458: per-superblock skip/MV mode decision for AV1 inter frames.
///
/// The §449b baseline codes every 64x64 SB as NEWMV + full residual.
/// That is wasteful for static SBs: when the best MV is zero and the
/// residual is at the quantizer's noise floor, the decoder needs only a
/// GLOBALMV skip (three ref-tree bools + two motion bools, no var-tx or
/// token chain) and reconstructs a pure block copy of the reference.
///
/// This file adds a deterministic, integer-only decision:
///
///   skip(sb) = (mv8 == (0,0)) && (raw_sad(src, ref) * 100 <=
///                                  skip_sad_pct * 64*64*255/100)
///
/// i.e. skip when the source already sits within `skip_sad_pct` percent of
/// the reference's per-pixel dynamic range. Static content skips; moving
/// content keeps the proven residual chain. All planes' expected
/// reconstruction is composed from the exact kernel prediction plus the
/// exact itx reconstruction (skip SBs: prediction only), so the decoder
/// realizes it pixel-for-pixel by construction.

///|
/// Encode a per-superblock skip/MV 4:2:0 inter frame: returns the OBU plus
/// the expected Y/U/V planes the decoder must realize. `skip_sad_pct` is
/// the integer percentage (0..=100) of full-range SAD per SB below which
/// a zero-MV SB is coded as GLOBALMV skip. `skip_sad_pct=0` disables
/// skipping entirely (identical to §449b apart from the flag wiring).
pub fn av1_enc_write_me_skip420_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  src_y : FixedArray[Int32],
  src_y_stride : Int32,
  src_u : FixedArray[Int32],
  src_u_stride : Int32,
  src_v : FixedArray[Int32],
  ref_y : FixedArray[Int32],
  ref_y_stride : Int32,
  ref_u : FixedArray[Int32],
  ref_u_stride : Int32,
  ref_v : FixedArray[Int32],
  base_q_idx~ : Int32 = 200,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
  skip_sad_pct~ : Int32 = 0,
  /// §460: when true the skip decision is allowed on non-zero MVs and the
  /// coded MV goes through the uniform (NEWMV/NEARESTMV) chain — the MV the
  /// decoder realizes equals the ME target used for the prediction, so
  /// expected stays exact. Default false keeps §458's zero-MV GLOBALMV skip.
  skip_uniform~ : Bool = false,
) -> Result[
  (Bytes, FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
  String,
] {
  let w = seq.width
  let h = seq.height
  if w % 64 != 0 || h % 64 != 0 {
    return Err(
      "av1 enc: me skip420 frame needs 64-multiple geometry (got \{w}x\{h})",
    )
  }
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  if cw % 32 != 0 || ch % 32 != 0 {
    return Err("av1 enc: me skip420 frame needs 64-multiple chroma geometry")
  }
  if skip_sad_pct < 0 || skip_sad_pct > 100 {
    return Err("av1 enc: skip_sad_pct must be 0..=100")
  }
  let sb_cols = w >> 6
  let sb_rows = h >> 6
  let n_sb = sb_cols * sb_rows
  // 1. ME: full-pel search + sub-pel refinement, exactly the §449b path.
  let (iy, ix) = match
    av1_enc_me_fullpel_sad(
      src_y,
      src_y_stride,
      ref_y,
      ref_y_stride,
      w,
      h,
      range~,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let (ry, rx) = match
    av1_enc_me_subpel_refine(
      src_y, src_y_stride, ref_y, ref_y_stride, w, h, iy, ix,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // 2. Per-SB skip decision.
  //    §458 (skip_uniform=false): zero MV only, SAD against the plain
  //      reference block copy (the GLOBALMV reconstruction).
  //    §460 (skip_uniform=true): any MV, SAD against the MC prediction at
  //      the ME target mv8 — the exact image the decoder will realize for
  //      a NEWMV/NEARESTMV skip. Both use the decoder's own MC kernel.
  let skips = FixedArray::make(n_sb, false)
  if skip_sad_pct > 0 {
    let threshold : Int64 = skip_sad_pct.to_int64() * (64L * 64L * 255L) / 100L
    for sby in 0..<sb_rows {
      for sbx in 0..<sb_cols {
        let sb = sby * sb_cols + sbx
        if skip_uniform || (ry[sb] == 0 && rx[sb] == 0) {
          let y0 = sby * 64
          let x0 = sbx * 64
          let mut sad : Int64 = 0L
          if skip_uniform && (ry[sb] != 0 || rx[sb] != 0) {
            let pred = av1_enc_mc_predict(
              ref_y,
              ref_y_stride,
              w,
              h,
              w,
              h,
              sbx * 16,
              sby * 16,
              16,
              16,
              ry[sb],
              rx[sb],
              0,
              0,
              0,
              8,
            )
            for y in 0..<64 {
              for x in 0..<64 {
                let d = src_y[(y0 + y) * src_y_stride + x0 + x] -
                  pred[y * 64 + x]
                sad += (if d < 0 { -d } else { d }).to_int64()
              }
            }
          } else {
            for y in 0..<64 {
              for x in 0..<64 {
                let d = src_y[(y0 + y) * src_y_stride + x0 + x] -
                  ref_y[(y0 + y) * ref_y_stride + x0 + x]
                sad += (if d < 0 { -d } else { d }).to_int64()
              }
            }
          }
          if sad <= threshold {
            skips[sb] = true
          }
        }
      }
    }
  }
  // 3. Dequant tables and pseudo-inverse basis (§449b).
  let dq_tbl = if seq.bitdepth == 8 {
    av1_dq_tbl_0
  } else if seq.bitdepth == 10 {
    av1_dq_tbl_1
  } else {
    av1_dq_tbl_2
  }
  let ydc_tbl = dq_tbl[base_q_idx * 2].to_int()
  let yac_tbl = dq_tbl[base_q_idx * 2 + 1].to_int()
  let udc_tbl = dq_tbl[base_q_idx * 2].to_int()
  let uac_tbl = dq_tbl[base_q_idx * 2 + 1].to_int()
  let dq_shift = av1_imax(0, av1_txfm_ctx(3) - 2)
  let basis = av1_enc_itx_basis32()
  let tok_specs : FixedArray[Int32] = FixedArray::make(n_sb * 4 * 1024, 0)
  let sign_specs : FixedArray[Int32] = FixedArray::make(n_sb * 4 * 1024, 0)
  let chroma_toks : FixedArray[Int32] = FixedArray::make(n_sb * 2 * 1024, 0)
  let chroma_signs : FixedArray[Int32] = FixedArray::make(n_sb * 2 * 1024, 0)
  let expected_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  let expected_u : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  let expected_v : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
  let resid : FixedArray[Int32] = FixedArray::make(64 * 64, 0)
  let leaf_r : FixedArray[Int32] = FixedArray::make(1024, 0)
  for sby in 0..<sb_rows {
    for sbx in 0..<sb_cols {
      let sb = sby * sb_cols + sbx
      let mv8 : (Int32, Int32) = (ry[sb], rx[sb])
      let y0 = sby * 64
      let x0 = sbx * 64
      let cy0 = sby * 32
      let cx0 = sbx * 32
      let pred_y = av1_enc_mc_predict(
        ref_y,
        ref_y_stride,
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
      // Skip SB: reconstruction is the pure zero-MV block copy (pred is
      // exactly that because mv8 == (0,0) is enforced by the decision).
      if skips[sb] {
        for y in 0..<64 {
          for x in 0..<64 {
            expected_y[(y0 + y) * w + x0 + x] = pred_y[y * 64 + x]
          }
        }
        let pred_u = av1_enc_mc_predict(
          ref_u,
          ref_u_stride,
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
          1,
          1,
          0,
          8,
        )
        let pred_v = av1_enc_mc_predict(
          ref_v,
          ref_u_stride,
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
          1,
          1,
          0,
          8,
        )
        for y in 0..<32 {
          for x in 0..<32 {
            expected_u[(cy0 + y) * cw + cx0 + x] = pred_u[y * 32 + x]
            expected_v[(cy0 + y) * cw + cx0 + x] = pred_v[y * 32 + x]
          }
        }
        continue
      }
      // Non-skip SB: the exact §449b residual chain.
      for y in 0..<64 {
        for x in 0..<64 {
          let s = src_y[(y0 + y) * src_y_stride + x0 + x]
          resid[y * 64 + x] = s - pred_y[y * 64 + x]
          expected_y[(y0 + y) * w + x0 + x] = pred_y[y * 64 + x]
        }
      }
      let pred_u = av1_enc_mc_predict(
        ref_u,
        ref_u_stride,
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
        1,
        1,
        0,
        8,
      )
      let pred_v = av1_enc_mc_predict(
        ref_v,
        ref_u_stride,
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
        1,
        1,
        0,
        8,
      )
      for li in 0..<4 {
        let lx = li % 2 * 32
        let ly = li / 2 * 32
        for r in 0..<32 {
          for c in 0..<32 {
            leaf_r[r * 32 + c] = resid[(ly + r) * 64 + lx + c]
          }
        }
        let _ = av1_enc_quantize_leaf(
          leaf_r,
          32,
          basis,
          ydc_tbl,
          yac_tbl,
          dq_shift,
          toks,
          signs,
          dz_pm~,
        )
        let base = (sb * 4 + li) * 1024
        for i in 0..<1024 {
          tok_specs[base + i] = toks[i]
          sign_specs[base + i] = signs[i]
        }
        let scratch : FixedArray[Int32] = FixedArray::make(1024, 0)
        for r in 0..<32 {
          for c in 0..<32 {
            scratch[r * 32 + c] = pred_y[(ly + r) * 64 + lx + c]
          }
        }
        for i in 0..<1024 {
          toks[i] = tok_specs[base + i]
          signs[i] = sign_specs[base + i]
        }
        let _ = av1_enc_recon_leaf(
          scratch, 0, 32, toks, signs, 3, ydc_tbl, yac_tbl, dq_shift,
        )
        for r in 0..<32 {
          for c in 0..<32 {
            expected_y[(y0 + ly + r) * w + x0 + lx + c] = scratch[r * 32 + c]
          }
        }
      }
      for pl in 0..<2 {
        let src_p = if pl == 0 { src_u } else { src_v }
        let pred_p = if pl == 0 { pred_u } else { pred_v }
        let expected_p = if pl == 0 { expected_u } else { expected_v }
        for y in 0..<32 {
          for x in 0..<32 {
            let s = src_p[(cy0 + y) * src_u_stride + cx0 + x]
            resid[y * 32 + x] = s - pred_p[y * 32 + x]
            expected_p[(cy0 + y) * cw + cx0 + x] = pred_p[y * 32 + x]
          }
        }
        let _ = av1_enc_quantize_leaf(
          resid,
          32,
          basis,
          udc_tbl,
          uac_tbl,
          dq_shift,
          toks,
          signs,
          dz_pm~,
        )
        let base_c = (sb * 2 + pl) * 1024
        for i in 0..<1024 {
          chroma_toks[base_c + i] = toks[i]
          chroma_signs[base_c + i] = signs[i]
        }
        let scratch : FixedArray[Int32] = FixedArray::make(1024, 0)
        for r in 0..<32 {
          for c in 0..<32 {
            scratch[r * 32 + c] = pred_p[r * 32 + c]
          }
        }
        for i in 0..<1024 {
          toks[i] = chroma_toks[base_c + i]
          signs[i] = chroma_signs[base_c + i]
        }
        let _ = av1_enc_recon_leaf(
          scratch, 0, 32, toks, signs, 3, udc_tbl, uac_tbl, dq_shift,
        )
        for r in 0..<32 {
          for c in 0..<32 {
            expected_p[(cy0 + r) * cw + cx0 + c] = scratch[r * 32 + c]
          }
        }
      }
    }
  }
  // 4. Syntax: reference mirror, tile writer with per-SB skip flags.
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
      mono=false,
      chroma_toks=Some(chroma_toks),
      chroma_signs=Some(chroma_signs),
      skip_flags=Some(skips),
      skip_uniform~,
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
  Ok((obu, expected_y, expected_u, expected_v))
}
