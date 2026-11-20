///|
/// §449b: the §449a full-residual pipeline extended with chroma. Per
/// SB the luma mv8 drives the MC prediction on all three planes (the
/// kernel handles the 4:2:0 subsampling), the luma residual quantizes
/// into 4 TX_32X32 leaves and each chroma plane into one TX_32X32 txb
/// (the u/v dequant tables mirror fill_dq's plane slots — the frame's
/// dq_u_* offsets are zero, so udc = uac = base_q_idx), and the
/// expected reconstruction of every plane is computed with the same
/// kernel and returned for the pixel round-trip assertion.

///|
/// Encode a per-superblock ME + full-residual 4:2:0 inter frame OBU:
/// returns the OBU plus the expected Y/U/V planes (raster, plane
/// strides = w/cw) the decoder must realize pixel-for-pixel.
pub fn av1_enc_write_me_res420_inter_frame_obu(
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
  /// §463: the reference slot (0..7) this frame predicts from. The frame
  /// header's seven ref_frame_idx entries all point here, and the refmvs
  /// prepared state gathers the same slot, so every block's LAST (or the
  /// `ref_idx~` reference) resolves to this picture. Default 0 = the
  /// previous frame's slot, i.e. the pre-§463 single-reference behaviour.
  ref_slot~ : Int32 = 0,
  /// §464: the slot this frame's reconstruction is written to
  /// (refresh_frame_flags). Defaults to `ref_slot` (the pre-§464 shape);
  /// a session that rings its slots passes the next slot here so a
  /// prediction source and a refresh target can differ.
  refresh_slot~ : Int32 = -1,
  /// §463: which reference index (dav1d 0..6) the blocks code. The frame
  /// header maps it to `ref_slot`, so any index resolves to the same
  /// picture; coding a non-LAST index exercises the ref tree.
  ref_idx~ : Int32 = 0,
  /// §466: precomputed 1/8-pel per-SB MVs. Motion estimation depends only
  /// on (src, ref) — not on the qindex — so a caller sweeping several q
  /// values for one reference can run ME once and pass the result in,
  /// skipping the full-pel search plus sub-pel refinement. Both arrays
  /// must hold one entry per 64x64 SB; when omitted ME runs as before.
  precomputed_mvs_y8? : FixedArray[Int32],
  precomputed_mvs_x8? : FixedArray[Int32],
  /// §468c: loop-filter levels for the frame header. Non-zero makes the
  /// decoder deblock, so the encoder applies the same filter to its
  /// expected planes before returning them. Default 0 keeps it off.
  loop_filter_level0~ : Int32 = 0,
  loop_filter_level1~ : Int32 = 0,
  loop_filter_sharpness~ : Int32 = 0,
) -> Result[
  (Bytes, FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
  String,
] {
  let w = seq.width
  let h = seq.height
  if w % 64 != 0 || h % 64 != 0 {
    return Err(
      "av1 enc: me res420 frame needs 64-multiple geometry (got \{w}x\{h})",
    )
  }
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  if cw % 32 != 0 || ch % 32 != 0 {
    return Err("av1 enc: me res420 frame needs 64-multiple chroma geometry")
  }
  let sb_cols = w >> 6
  let sb_rows = h >> 6
  let n_sb = sb_cols * sb_rows
  // 1. ME on luma. §466: when the caller supplies precomputed MVs, the
  //    search is skipped entirely — the result is identical because ME
  //    depends only on (src, ref), not on the qindex.
  let (ry, rx) = match (precomputed_mvs_y8, precomputed_mvs_x8) {
    (Some(py), Some(px)) =>
      if py.length() != n_sb || px.length() != n_sb {
        return Err(
          "av1 enc: precomputed MVs need one entry per 64x64 SB (\{n_sb})",
        )
      } else {
        (py, px)
      }
    (None, None) => {
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
      match
        av1_enc_me_subpel_refine(
          src_y, src_y_stride, ref_y, ref_y_stride, w, h, iy, ix,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    _ => return Err("av1 enc: precomputed MVs need both y and x arrays")
  }
  // 2. Dequant tables: ydc/yac for luma, udc/uac for chroma (the
  //    frame's dq_u_* offsets are zero, so udc = uac = base_q_idx).
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
  // 3. Per SB: predict all planes, quantize luma (4 leaves) and chroma
  //    (1 txb per plane), compose the expected reconstruction.
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
      // Luma prediction + residual.
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
      for y in 0..<64 {
        for x in 0..<64 {
          let s = src_y[(y0 + y) * src_y_stride + x0 + x]
          resid[y * 64 + x] = s - pred_y[y * 64 + x]
          expected_y[(y0 + y) * w + x0 + x] = pred_y[y * 64 + x]
        }
      }
      // Chroma predictions (the kernel handles the subsampled mv).
      // Chroma MC: EVERYTHING stays in the luma 4px-unit domain — the
      // decoder passes the same bx4/bw4 as luma and only flips the
      // ss_h/ss_v flags (the kernel derives the subsampled plane size
      // and phase itself).
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
      // Luma leaves.
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
      // Chroma planes: one TX_32X32 txb each.
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
  // 4. Syntax.
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
  if ref_slot < 0 || ref_slot > 7 {
    return Err("av1 enc: ref_slot must be 0..=7")
  }
  if ref_idx < 0 || ref_idx > 6 {
    return Err("av1 enc: ref_idx must be 0..=6")
  }
  let prepared = match
    refs.prepare_frame(
      [ref_slot, ref_slot, ref_slot, ref_slot, ref_slot, ref_slot, ref_slot],
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
      ref_idx~,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  // §463: every ref_frame_idx entry maps to `ref_slot`, so whichever
  // reference index the blocks code resolves to that picture. §464: the
  // reconstruction refreshes `out_slot`, which may differ from the
  // prediction source when the session rings its slots.
  let out_slot = if refresh_slot < 0 { ref_slot } else { refresh_slot }
  if out_slot < 0 || out_slot > 7 {
    return Err("av1 enc: refresh_slot must be 0..=7")
  }
  let ref_frame_idx : Array[Int32] = [
    ref_slot, ref_slot, ref_slot, ref_slot, ref_slot, ref_slot, ref_slot,
  ]
  let obu = match
    av1_enc_write_inter_frame_obu(seq, {
      ..Av1InterFrameEncConfig::default(),
      base_q_idx,
      ref_frame_idx,
      refresh_frame_flags: 1 << out_slot,
      loop_filter_level0,
      loop_filter_level1,
      loop_filter_sharpness,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  // §468c: mirror the decoder's deblocking on the expected planes.
  if loop_filter_level0 != 0 ||
    loop_filter_level1 != 0 ||
    loop_filter_sharpness != 0 {
    let hdr = match av1_parse_frame_header(obu, seq) {
      Ok(h) => h
      Err(e) => return Err(e)
    }
    // This entry codes every superblock with a full residual, so no SB is
    // skipped.
    let skips = FixedArray::make(n_sb, false)
    let _ = av1_enc_deblock_frame_inter(
      expected_y,
      w,
      expected_u,
      expected_v,
      cw,
      w,
      h,
      hdr,
      skips,
      !seq.monochrome,
      1,
      1,
      8,
    )
  }
  refs.refresh(prepared, 1 << out_slot)
  Ok((obu, expected_y, expected_u, expected_v))
}
