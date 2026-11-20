///|
/// §451a/§452 key-frame intra tile writer: 4×32x32 DC_PRED blocks with
/// real residuals (luma AND chroma) — the §449a pseudo-inverse machinery
/// applied to intra.
/// The DC prediction is simulated sequentially per block from the
/// reconstruction state (the decoder rebuilds in the same order, so
/// the predictions match by construction): block 0 (no neighbors) →
/// 128; block 1 → the left column sum; block 2 → the top row sum;
/// block 3 → both (the av1_dc_gen/gen_left/gen_top formulas, inlined).
/// Per block: partition NONE, skip=0, kfym/uv_mode DC_PRED, the txsz
/// depth symbol (TX_32X32 with the tctx mirror), then the luma
/// TX_32X32 token chain (no txtp bits — intra TX_32X32 derives
/// DCT_DCT) and the chroma TX_16X16 chains ×2 (the uv txtp derives
/// from DC_PRED's LUT, also no bits; the chroma tx size = uvtx for
/// BS_32x32 4:2:0 = TX_16X16).

///|
/// Write one 64x64 intra key tile from a 64x64 src slice (luma) plus
/// the 32x32 chroma slices. Returns the tile bytes; `expected_*` are
/// filled with this tile's reconstruction (the caller owns the plane
/// state across tiles — each tile restarts prediction at its border).
fn av1_enc_write_intra_dc_tile(
  src_y : FixedArray[Int32],
  src_y_off : Int32,
  src_y_stride : Int32,
  src_u : FixedArray[Int32],
  src_u_off : Int32,
  src_u_stride : Int32,
  src_v : FixedArray[Int32],
  dst_y : FixedArray[Int32],
  dst_y_off : Int32,
  dst_y_stride : Int32,
  dst_u : FixedArray[Int32],
  dst_u_off : Int32,
  dst_uv_stride : Int32,
  dst_v : FixedArray[Int32],
  base_q_idx : Int32,
  basis32 : Av1EncItxBasis,
  basis16 : Av1EncItxBasis,
  ydc_tbl : Int32,
  yac_tbl : Int32,
  udc_tbl : Int32,
  uac_tbl : Int32,
  chroma_tokens~ : Bool = true,
  dz_pm~ : Int32 = 0,
) -> Result[Bytes, String] {
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  let dq_shift32 = av1_imax(0, av1_txfm_ctx(3) - 2) // TX_32X32: 1
  let dq_shift16 = av1_imax(0, av1_txfm_ctx(2) - 2) // TX_16X16: 0
  // Partition-context mirror (the §443 skeleton).
  let pm_above = FixedArray::make(16, 0)
  let pm_left = FixedArray::make(16, 0)
  fn part_ctx(bl : Int32, xb8 : Int32, yb8 : Int32) -> Int32 {
    ((pm_above[xb8] >> (4 - bl)) & 1) + (((pm_left[yb8] >> (4 - bl)) & 1) << 1)
  }
  fn part_write_back(bl : Int32, xb8 : Int32, yb8 : Int32, bp : Int32) -> Unit {
    let hsz = 16 >> bl
    let n = if hsz < 16 { hsz } else { 16 }
    let al = av1_al_part_ctx[(0 * 5 + bl) * 10 + bp].to_int()
    let all = av1_al_part_ctx[(1 * 5 + bl) * 10 + bp].to_int()
    for i in 0..<n {
      pm_above[xb8 + i] = al
      pm_left[yb8 + i] = all
    }
  }
  // Mode + tx + coefficient mirrors.
  let a_mode = FixedArray::make(32, 0)
  let l_mode = FixedArray::make(32, 0)
  let a_uvmode = FixedArray::make(32, 0)
  let l_uvmode = FixedArray::make(32, 0)
  let ta = FixedArray::make(32, -1)
  let tl = FixedArray::make(32, -1)
  let a_lcoef = FixedArray::make(32, 0x40)
  let l_lcoef = FixedArray::make(32, 0x40)
  let a_ccoef = FixedArray::make(64, 0x40)
  let l_ccoef = FixedArray::make(64, 0x40)
  // BL_64X64 SPLIT (fresh ctx).
  let ctx1 = part_ctx(1, 0, 0)
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + ctx1) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_split,
  )
  // §441: the decoder does NOT write the al-part ctx back for SPLIT —
  // the sub-block partition ctx reads stay at their fresh values.
  let bs32 = av1_block_sizes[(2 * 10 + 0) * 2].to_int() // BL_32X32 NONE
  let tx_y = av1_max_txfm_size_for_bs[bs32 * 4].to_int() // TX_32X32
  let uvtx = av1_max_txfm_size_for_bs[bs32 * 4 + 1].to_int() // TX_16X16
  let m32 = av1_txfm_max(tx_y)
  let uv_base = (1 * 13 + 0) * 16 // cfl allowed, DC_PRED
  // cfl allowed at BS_32x32: the decoder's nsym = n_uv - 1 - 0 = 13.
  let uv_nsym = av1_n_uv_intra_pred_modes - 1
  let count2 = av1_partition_type_count[2].to_int()
  let sb_pos : Array[(Int32, Int32)] = [(0, 0), (8, 0), (0, 8), (8, 8)]
  let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
  // The residual buffer MUST be separate from the token output — the
  // quantizer reads res[raster(p)] for every later position after
  // writing toks[p] (scan-order ≠ raster-order).
  let resid : FixedArray[Int32] = FixedArray::make(1024, 0)
  for sb in sb_pos {
    let sbx = sb.0
    let sby = sb.1
    let x8 = (sbx & 31) >> 1
    let y8 = (sby & 31) >> 1
    let c2 = part_ctx(2, x8, y8)
    enc.encode_symbol_adapt(
      cdf.partition,
      (2 * 4 + c2) * 16,
      count2,
      av1_partition_none,
    )
    part_write_back(2, x8, y8, av1_partition_none)
    enc.encode_bool_adapt(cdf.skip, 0, 0)
    // kfym DC_PRED: the neighbors are all DC → the ctx stays 0.
    let mctx = (
        av1_intra_mode_context[a_mode[sbx]].to_int() * 5 +
        av1_intra_mode_context[l_mode[sby]].to_int()
      ) *
      16
    enc.encode_symbol_adapt(cdf.kfym, mctx, av1_n_intra_pred_modes - 1, 0)
    for i in 0..<8 {
      a_mode[sbx + i] = 0
      l_mode[sby + i] = 0
    }
    // uv_mode DC_PRED (cfl allowed at BS_32x32 → 12 symbols).
    enc.encode_symbol_adapt(cdf.uv_mode, uv_base, uv_nsym, 0)
    for i in 0..<8 {
      a_uvmode[((sbx & 31) >> 1) + i] = 0
      l_uvmode[((sby & 31) >> 1) + i] = 0
    }
    // txsz: the depth symbol with the neighbor tctx mirror.
    let tctx = (if tl[sby] >= av1_txfm_lw(tx_y) { 1 } else { 0 }) +
      (if ta[sbx] >= av1_txfm_lw(tx_y) { 1 } else { 0 })
    enc.encode_symbol_adapt(
      cdf.txsz,
      ((m32 - 1) * 3 + tctx) * 4,
      if m32 < 2 {
        m32
      } else {
        2
      },
      0,
    )
    for i in 0..<8 {
      ta[sbx + i] = tx_y
      tl[sby + i] = tx_y
    }
    // ---- DC predictions from the reconstruction state.
    // Luma 32x32 block at (sbx*4, sby*4) px.
    let px0 = sbx * 4
    let py0 = sby * 4
    let have_top = sby > 0
    let have_left = sbx > 0
    let mut dc = 128
    if have_top && have_left {
      // dc_gen: the init = (w + h) >> 1 = 32, + sums, >> ctz(w+h) = 6.
      let mut acc = 32
      for i in 0..<32 {
        acc += dst_y[dst_y_off + (py0 - 1) * dst_y_stride + px0 + i]
        acc += dst_y[dst_y_off + (py0 + i) * dst_y_stride + px0 - 1]
      }
      dc = acc >> 6
    } else if have_top {
      let mut acc = 16
      for i in 0..<32 {
        acc += dst_y[dst_y_off + (py0 - 1) * dst_y_stride + px0 + i]
      }
      dc = acc >> 5
    } else if have_left {
      let mut acc = 16
      for i in 0..<32 {
        acc += dst_y[dst_y_off + (py0 + i) * dst_y_stride + px0 - 1]
      }
      dc = acc >> 5
    }
    // Luma residual → tokens.
    for y in 0..<32 {
      for x in 0..<32 {
        resid[y * 32 + x] = src_y[src_y_off + (py0 + y) * src_y_stride + px0 + x] -
          dc
      }
    }
    let _ = av1_enc_quantize_leaf(
      resid,
      32,
      basis32,
      ydc_tbl,
      yac_tbl,
      dq_shift32,
      toks,
      signs,
      dz_pm~,
    )
    // Luma txb: coef_skip(0), no txtp bits (TX_32X32 intra), tokens.
    let lw = av1_txfm_lw(tx_y)
    let lh = av1_txfm_lh(tx_y)
    let a0 = FixedArray::make(1 << lw, 0x40)
    let l0 = FixedArray::make(1 << lh, 0x40)
    for i in 0..<(1 << lw) {
      a0[i] = a_lcoef[sbx + i]
      l0[i] = l_lcoef[sby + i]
    }
    let sctx = av1_get_skip_ctx(tx_y, bs32, a0, 0, l0, 0, false, 1, 1)
    let t_dim_ctx = av1_txfm_ctx(tx_y)
    let mut any = false
    let mut cul = 0
    for i in 0..<1024 {
      cul += toks[i]
      if toks[i] != 0 {
        any = true
      }
    }
    let res_ctx = if !any {
      enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx * 13 + sctx) * 2, 1)
      0x40
    } else {
      enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx * 13 + sctx) * 2, 0)
      av1_enc_txb_tokens(
        enc,
        cdf,
        tx_y,
        0,
        bs32,
        toks,
        signs,
        a0,
        l0,
        coef_skip_written=true,
      )
      av1_imin(cul, 63) | av1_enc_res_sign_field(toks[0], signs[0])
    }
    for i in 0..<8 {
      a_lcoef[sbx + i] = res_ctx
      l_lcoef[sby + i] = res_ctx
    }
    // The luma reconstruction into the dst planes (drives the next
    // blocks' DC predictions).
    let scratch : FixedArray[Int32] = FixedArray::make(1024, 0)
    for y in 0..<32 {
      for x in 0..<32 {
        scratch[y * 32 + x] = dc
      }
    }
    let _ = av1_enc_recon_leaf(
      scratch, 0, 32, toks, signs, 3, ydc_tbl, yac_tbl, dq_shift32,
    )
    for y in 0..<32 {
      for x in 0..<32 {
        dst_y[dst_y_off + (py0 + y) * dst_y_stride + px0 + x] = scratch[y * 32 +
          x]
      }
    }
    // ---- Chroma: one TX_16X16 txb per plane (16x16 chroma at
    // (sbx*2, sby*2) chroma px).
    for pl in 0..<2 {
      let src_p = if pl == 0 { src_u } else { src_v }
      let src_stride_p = src_u_stride
      let cpx0 = sbx * 2
      let cpy0 = sby * 2
      let c_have_top = sby > 0
      let c_have_left = sbx > 0
      // The DC pred reads THIS plane's reconstruction (dst_u for U,
      // dst_v for V) — the decoder's chroma DC pred is per-plane.
      let dst_p = if pl == 0 { dst_u } else { dst_v }
      let mut dc_p = 128
      if c_have_top && c_have_left {
        let mut acc = 16
        for i in 0..<16 {
          acc += dst_p[dst_u_off + (cpy0 - 1) * dst_uv_stride + cpx0 + i]
          acc += dst_p[dst_u_off + (cpy0 + i) * dst_uv_stride + cpx0 - 1]
        }
        dc_p = acc >> 5
      } else if c_have_top {
        let mut acc = 8
        for i in 0..<16 {
          acc += dst_p[dst_u_off + (cpy0 - 1) * dst_uv_stride + cpx0 + i]
        }
        dc_p = acc >> 4
      } else if c_have_left {
        let mut acc = 8
        for i in 0..<16 {
          acc += dst_p[dst_u_off + (cpy0 + i) * dst_uv_stride + cpx0 - 1]
        }
        dc_p = acc >> 4
      }
      if chroma_tokens {
        for y in 0..<16 {
          for x in 0..<16 {
            resid[y * 32 + x] = src_p[src_u_off +
              (cpy0 + y) * src_stride_p +
              cpx0 +
              x] -
              dc_p
          }
        }
        let _ = av1_enc_quantize_leaf(
          resid,
          32,
          basis16,
          udc_tbl,
          uac_tbl,
          dq_shift16,
          toks,
          signs,
          dz_pm~,
        )
      }
      let a_base = pl * 32 + ((sbx & 31) >> 1)
      let l_base = pl * 32 + ((sby & 31) >> 1)
      // The decoder's chroma sctx reads (1 << lw) = 4 slots for
      // TX_16X16 — not 8 (the block-0 publish in [4..8) would poison
      // block 1's ctx).
      let a0c = FixedArray::make(4, 0)
      let l0c = FixedArray::make(4, 0)
      for i in 0..<4 {
        a0c[i] = a_ccoef[a_base + i]
        l0c[i] = l_ccoef[l_base + i]
      }
      let sctx_c = av1_get_skip_ctx(uvtx, bs32, a0c, 0, l0c, 0, true, 1, 1)
      let t_dim_ctx_c = av1_txfm_ctx(uvtx)
      let mut any_c = false
      let mut cul_c = 0
      for i in 0..<256 {
        cul_c += toks[i]
        if toks[i] != 0 {
          any_c = true
        }
      }
      let res_ctx_c = if !any_c || !chroma_tokens {
        enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx_c * 13 + sctx_c) * 2, 1)
        0x40
      } else {
        enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx_c * 13 + sctx_c) * 2, 0)
        // The chroma txtp derives from DC_PRED's LUT (DCT_DCT), no
        // bits; the token chain follows (chroma flag = 1).
        av1_enc_txb_tokens(
          enc,
          cdf,
          uvtx,
          1,
          bs32,
          toks,
          signs,
          a0c,
          l0c,
          coef_skip_written=true,
        )
        av1_imin(cul_c, 63) | av1_enc_res_sign_field(toks[0], signs[0])
      }
      // The publish width = the UV TX's width in 4px units (4 for
      // TX_16X16) — the decoder publishes uv_t_dim_w slots; an 8-slot
      // publish would leak res_ctx into the next block's chroma sctx
      // window ([4..8)) and desync the coef_skip CDF slot.
      let uvw = av1_txfm_w(uvtx)
      for i in 0..<uvw {
        a_ccoef[a_base + i] = res_ctx_c
        l_ccoef[l_base + i] = res_ctx_c
      }
      // The chroma reconstruction.
      let scratch_c : FixedArray[Int32] = FixedArray::make(256, 0)
      for y in 0..<16 {
        for x in 0..<16 {
          scratch_c[y * 16 + x] = dc_p
        }
      }
      if chroma_tokens && any_c {
        let _ = av1_enc_recon_leaf(
          scratch_c, 0, 16, toks, signs, 2, udc_tbl, uac_tbl, dq_shift16,
        )
      }
      for y in 0..<16 {
        for x in 0..<16 {
          if pl == 0 {
            dst_u[dst_u_off + (cpy0 + y) * dst_uv_stride + cpx0 + x] = scratch_c[y *
              16 +
              x]
          } else {
            dst_v[dst_u_off + (cpy0 + y) * dst_uv_stride + cpx0 + x] = scratch_c[y *
              16 +
              x]
          }
        }
      }
    }
  }
  Ok(enc.done())
}
