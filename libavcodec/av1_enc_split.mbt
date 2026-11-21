///|
/// §498: the §449b full-residual pipeline with a per-SB partition choice.
/// Each 64x64 SB either stays a single PARTITION_NONE block predicted
/// with its 64x64 ME mv (the non-split syntax is byte-identical to
/// `av1_enc_write_me_res_tile`'s regular path) or codes PARTITION_SPLIT
/// followed by four 32x32 PARTITION_NONE blocks, each predicted from its
/// own quadrant ME mv with one TX_32X32 luma txb (the (sb*4+q) token
/// slots) and all-skip chroma. The decision minimizes the decoder's MC
/// kernel SAD: split wins when the four quadrant SADs beat the whole
/// SB's SAD by more than `split_margin` — the margin stands in for the
/// extra partition/mode syntax, mirroring a lambda-weighted RD cost
/// (1 SAD unit ~= 1 bit at the default lambda scale of §457). Chroma
/// residuals stay all_skip on split SBs; every plane's expected
/// reconstruction is computed with the decoder's own kernel so the
/// pixel round-trip holds.

///|
/// §498: the per-SB partition decision — split when the four quadrant
/// SADs beat the whole-SB SAD by more than `margin` (strictly; ties keep
/// NONE). Exposed standalone so the decision rule is testable without a
/// full encode.
pub fn av1_enc_split_decide(
  sad64 : Int64,
  sad32 : Array[Int64],
  margin : Int32,
) -> Bool {
  let mut sum : Int64 = 0L
  for s in sad32 {
    sum = sum + s
  }
  sum + margin.to_int64() < sad64
}

///|
/// Encode a per-SB partitioned full-residual 4:2:0 inter frame OBU.
/// Chroma residuals are all-skip on every SB (the session's me_res420
/// convention), so only the luma source planes are consumed; the chroma
/// source content does not affect the output. Returns the OBU, the
/// expected Y/U/V planes (raster, plane strides = w/cw) and the per-SB
/// split flags the writer realized.
pub fn av1_enc_write_me_res_part420_inter_frame_obu(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  src_y : FixedArray[Int32],
  src_y_stride : Int32,
  ref_y : FixedArray[Int32],
  ref_y_stride : Int32,
  ref_u : FixedArray[Int32],
  ref_u_stride : Int32,
  ref_v : FixedArray[Int32],
  base_q_idx~ : Int32 = 200,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
  ref_slot~ : Int32 = 0,
  refresh_slot~ : Int32 = -1,
  ref_idx~ : Int32 = 0,
  /// §498: the SAD margin for the NONE/SPLIT decision (SAD units; 1 unit
  /// ~= 1 bit at the default RD lambda scale). 0 splits on any strict
  /// quadrant win; ties and losses keep the 64x64 NONE partition.
  split_margin~ : Int32 = 0,
  /// §499: NEARMV stack hits (drl bools, no MV payload) instead of NEWMV
  /// when a deeper refmv candidate equals the target.
  drl~ : Bool = false,
) -> Result[
  (
    Bytes,
    FixedArray[Int32],
    FixedArray[Int32],
    FixedArray[Int32],
    FixedArray[Bool],
  ),
  String,
] {
  let w = seq.width
  let h = seq.height
  if w % 64 != 0 || h % 64 != 0 {
    return Err(
      "av1 enc: me res part frame needs 64-multiple geometry (got \{w}x\{h})",
    )
  }
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  if cw % 32 != 0 || ch % 32 != 0 {
    return Err("av1 enc: me res part frame needs 64-multiple chroma geometry")
  }
  let sb_cols = w >> 6
  let sb_rows = h >> 6
  let n_sb = sb_cols * sb_rows
  // 1. Whole-SB ME on luma (same search as me_res420).
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
  // 2. Quadrant ME (32x32): full-pel search then kernel refinement; the
  //    refined kernel SADs feed the partition decision.
  let qy8 : FixedArray[Int32] = FixedArray::make(n_sb * 4, 0)
  let qx8 : FixedArray[Int32] = FixedArray::make(n_sb * 4, 0)
  let splits : FixedArray[Bool] = FixedArray::make(n_sb, false)
  for sby in 0..<sb_rows {
    for sbx in 0..<sb_cols {
      let sb = sby * sb_cols + sbx
      let x0 = sbx * 64
      let y0 = sby * 64
      let sad64 = av1_enc_kernel_sad_block(
        src_y, src_y_stride, ref_y, ref_y_stride, w, h, x0, y0, 64, ry[sb], rx[sb],
      )
      let q_sads : Array[Int64] = []
      for q in 0..<4 {
        let qx0 = x0 + (q % 2) * 32
        let qy0 = y0 + (q / 2) * 32
        let (iy, ix, _) = match
          av1_enc_me_fullpel_sad_block(
            src_y,
            src_y_stride,
            ref_y,
            ref_y_stride,
            w,
            h,
            qx0,
            qy0,
            32,
            range~,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let (ry8, rx8, sad) = match
          av1_enc_me_subpel_refine_block(
            src_y,
            src_y_stride,
            ref_y,
            ref_y_stride,
            w,
            h,
            qx0,
            qy0,
            32,
            iy,
            ix,
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        qy8[sb * 4 + q] = ry8
        qx8[sb * 4 + q] = rx8
        q_sads.push(sad)
      }
      splits[sb] = av1_enc_split_decide(sad64, q_sads, split_margin)
    }
  }
  // 3. Dequant tables (as me_res420).
  let dq_tbl = if seq.bitdepth == 8 {
    av1_dq_tbl_0
  } else if seq.bitdepth == 10 {
    av1_dq_tbl_1
  } else {
    av1_dq_tbl_2
  }
  let ydc_tbl = dq_tbl[base_q_idx * 2].to_int()
  let yac_tbl = dq_tbl[base_q_idx * 2 + 1].to_int()
  let dq_shift = av1_imax(0, av1_txfm_ctx(3) - 2)
  let basis = av1_enc_itx_basis32()
  // 4. Per SB: predict all planes, quantize luma into the (sb*4+q) token
  //    slots (NONE: the four 32x32 leaves of the 64x64 residual; SPLIT:
  //    one 32x32 leaf per quadrant), and compose the expected
  //    reconstruction. Chroma stays all-skip on every SB — the same
  //    convention as the session's me_res420 path — so its expected
  //    planes are the raw MC predictions.
  let tok_specs : FixedArray[Int32] = FixedArray::make(n_sb * 4 * 1024, 0)
  let sign_specs : FixedArray[Int32] = FixedArray::make(n_sb * 4 * 1024, 0)
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
      let y0 = sby * 64
      let x0 = sbx * 64
      let cy0 = sby * 32
      let cx0 = sbx * 32
      if splits[sb] {
        // ---- SPLIT SB: one 32x32 prediction per quadrant with its own
        // mv; chroma has no residual (all_skip), so its expected planes
        // are the raw predictions.
        for q in 0..<4 {
          let qx4 = sbx * 16 + (q % 2) * 8
          let qy4 = sby * 16 + (q / 2) * 8
          let qx0 = x0 + (q % 2) * 32
          let qy0 = y0 + (q / 2) * 32
          let mvq : (Int32, Int32) = (qy8[sb * 4 + q], qx8[sb * 4 + q])
          let pred_y = av1_enc_mc_predict(
            ref_y,
            ref_y_stride,
            w,
            h,
            w,
            h,
            qx4,
            qy4,
            8,
            8,
            mvq.0,
            mvq.1,
            0,
            0,
            0,
            8,
          )
          for y in 0..<32 {
            for x in 0..<32 {
              leaf_r[y * 32 + x] = src_y[(qy0 + y) * src_y_stride + qx0 + x] -
                pred_y[y * 32 + x]
              expected_y[(qy0 + y) * w + qx0 + x] = pred_y[y * 32 + x]
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
          let base = (sb * 4 + q) * 1024
          for i in 0..<1024 {
            tok_specs[base + i] = toks[i]
            sign_specs[base + i] = signs[i]
          }
          let scratch : FixedArray[Int32] = FixedArray::make(1024, 0)
          for r in 0..<32 {
            for c in 0..<32 {
              scratch[r * 32 + c] = pred_y[r * 32 + c]
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
              expected_y[(qy0 + r) * w + qx0 + c] = scratch[r * 32 + c]
            }
          }
          // Chroma predictions (luma 4px-domain positions; the kernel
          // derives the subsampled geometry itself).
          for pl in 0..<2 {
            let ref_p = if pl == 0 { ref_u } else { ref_v }
            let expected_p = if pl == 0 { expected_u } else { expected_v }
            let pred_p = av1_enc_mc_predict(
              ref_p,
              ref_u_stride,
              w,
              h,
              w,
              h,
              qx4,
              qy4,
              8,
              8,
              mvq.0,
              mvq.1,
              1,
              1,
              0,
              8,
            )
            let cqx0 = cx0 + (q % 2) * 16
            let cqy0 = cy0 + (q / 2) * 16
            for y in 0..<16 {
              for x in 0..<16 {
                expected_p[(cqy0 + y) * cw + cqx0 + x] = pred_p[y * 16 + x]
              }
            }
          }
        }
      } else {
        // ---- NONE SB: the §449b path (64x64 prediction, four 32x32
        // luma leaves, one TX_32X32 chroma txb per plane).
        let mv8 : (Int32, Int32) = (ry[sb], rx[sb])
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
        // Chroma: no residual (all-skip), expected = the prediction.
        for y in 0..<32 {
          for x in 0..<32 {
            expected_u[(cy0 + y) * cw + cx0 + x] = pred_u[y * 32 + x]
            expected_v[(cy0 + y) * cw + cx0 + x] = pred_v[y * 32 + x]
          }
        }
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
      }
    }
  }
  // 5. Syntax.
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
      ref_idx~,
      splits=Some(splits),
      split_mvs_y8=Some(qy8),
      split_mvs_x8=Some(qx8),
      drl~,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
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
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  // Deblocking note: this entry codes loop-filter levels 0 (the default
  // config), so no in-loop filtering mirrors are needed. Deblocking with
  // split SBs (partition-aware edge masks) is future work.
  refs.refresh(prepared, 1 << out_slot)
  Ok((obu, expected_y, expected_u, expected_v, splits))
}
