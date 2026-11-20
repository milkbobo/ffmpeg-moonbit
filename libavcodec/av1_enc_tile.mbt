///|
/// AV1 tile-data writer (§440a) — the first pixel-capable slice. The
/// minimal tile is one 64x64 superblock coded as a single PARTITION_NONE
/// block: DC_PRED luma, DC_PRED chroma, TX_64X64, skip = 1 (no
/// residual). The reconstruction is then pure DC prediction from the
/// 128-mid frame border, which the in-tree decoder
/// (`av1_decode_keyframe`) must reproduce pixel-for-pixel.
///
/// The CDF trajectory is mirrored by construction: the writer mutates
/// the very `av1_cdf_copy_defaults` context the decoder will start
/// from, feeding the same `FixedArray` slots to the §438a encoder.

///|
/// Write the minimal single-SB tile for a 64x64 frame at `base_q_idx`.
/// Returns the entropy payload (the frame OBU's tile data).
pub fn av1_enc_write_minimal_tile(
  base_q_idx~ : Int32 = 100,
) -> Result[Bytes, String] {
  // The decoder starts every tile from the default CDF context.
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  // decode_sb(BL_64X64) on a 64x64 frame: have_h_split && have_v_split
  // (bw = 16 4px units > hsz = 8), so the partition symbol is read.
  // ctx 0 (fresh above/left edges), bl = 1.
  let partition_count = av1_partition_type_count[1].to_int()
  enc.encode_symbol_adapt(cdf.partition, (1 * 4 + 0) * 16, partition_count, 0)
  // decode_b: skip = 1 (no residual anywhere in the frame).
  enc.encode_bool_adapt(cdf.skip, 0, 1)
  // Key-frame luma mode: DC_PRED (symbol 0), context (0*5+0)*16 from the
  // fresh DC-filled above/left mode arrays.
  enc.encode_symbol_adapt(
    cdf.kfym,
    (0 * 5 + 0) * 16,
    av1_n_intra_pred_modes - 1,
    0,
  )
  // Chroma mode: DC_PRED. 64x64 is outside the CFL mask -> 12 symbols.
  enc.encode_symbol_adapt(
    cdf.uv_mode,
    (0 * 13 + 0) * 16,
    av1_n_uv_intra_pred_modes - 1 - 1,
    0,
  )
  // tx_size: TX_MODE_LARGEST gives TX_64X64; the depth symbol's base is
  // ((max - 1) * 3 + tctx) * 4 with the table's own max (4, NOT the
  // spec's 3 — this tree's txfm_max for TX_64X64 is 4).
  let m64 = av1_txfm_max(4)
  enc.encode_symbol_adapt(
    cdf.txsz,
    ((m64 - 1) * 3 + 0) * 4,
    if m64 < 2 {
      m64
    } else {
      2
    },
    0,
  )
  Ok(enc.done())
}

///|
/// One dc-only transform block (`eob = 1`, dc token 1, positive sign):
/// all_skip=0, no txtp bits (TX_64X64 luma derives DCT_DCT by the
/// `txfm_max + intra >= 4` rule; chroma derives it from DC_PRED),
/// eob_bin 0 (the 1024 bucket — TX_64X64 and TX_32X32 both carry
/// tx2dszctx = 6), eob_base_tok 0, dc_sign 0. The context bases reuse
/// the decoder's own `av1_get_skip_ctx` over fresh 0x40
/// coefficient-context arrays — exactly the decoder's first-block state.
fn av1_enc_txb_dc_only(
  enc : Av1MsacEnc,
  cdf : Av1CdfCtx,
  tx : Int32,
  chroma : Int32,
  bs : Int32,
  /// The decoder's coefficient-context init for this plane position:
  /// untouched planes start at 0, while a preceding skip=1 block writes
  /// 0x40 ("nothing coded") into the slots it covers. The chroma branch
  /// of `av1_get_skip_ctx` distinguishes exactly these two.
  ctx_init~ : Int32 = 0,
  /// The dc token magnitude 1..=3 (the eob-position base_tok trick:
  /// symbol tok−1; larger magnitudes need the br/golomb chain).
  tok~ : Int32 = 1,
  /// 0 positive, 1 negative.
  sign~ : Int32 = 0,
) -> Result[Unit, String] {
  if tok < 1 || tok > 3 {
    return Err("av1 enc: dc token must be 1..=3 (br chain is §443 land)")
  }
  if sign < 0 || sign > 1 {
    return Err("av1 enc: dc sign must be 0 or 1")
  }
  let lw = av1_txfm_lw(tx)
  let lh = av1_txfm_lh(tx)
  let a = FixedArray::make(1 << lw, ctx_init)
  let l = FixedArray::make(1 << lh, ctx_init)
  let sctx = av1_get_skip_ctx(tx, bs, a, 0, l, 0, chroma == 1, 1, 1)
  let t_dim_ctx = av1_txfm_ctx(tx)
  let dcs_ctx = av1_get_dc_sign_ctx(tx, a, 0, l, 0)
  // all_skip = 0: read residuals.
  enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx * 13 + sctx) * 2, 0)
  // eob_bin: bucket by tx2dszctx = min(lw,3)+min(lh,3); eob symbol 0 ->
  // eob = 0, the decoder's dc-only state (DCT_DCT is class 0, is_1d 0).
  // Bucket bases mirror decode_coefs: 16..128 share (chroma*2+is1d)*8
  // over [2][2][8] arrays, 256 uses *16 over [2][2][16], and 512/1024
  // are chroma-only [2][16] with base chroma * 16.
  let szctx = (if lw < 3 { lw } else { 3 }) + (if lh < 3 { lh } else { 3 })
  match szctx {
    0 => enc.encode_symbol_adapt(cdf.eob_bin_16, chroma * 2 * 8, 4, 0)
    1 => enc.encode_symbol_adapt(cdf.eob_bin_32, chroma * 2 * 8, 5, 0)
    2 => enc.encode_symbol_adapt(cdf.eob_bin_64, chroma * 2 * 8, 6, 0)
    3 => enc.encode_symbol_adapt(cdf.eob_bin_128, chroma * 2 * 8, 7, 0)
    4 => enc.encode_symbol_adapt(cdf.eob_bin_256, chroma * 2 * 16, 8, 0)
    5 => enc.encode_symbol_adapt(cdf.eob_bin_512, chroma * 16, 9, 0)
    _ => enc.encode_symbol_adapt(cdf.eob_bin_1024, chroma * 16, 10, 0)
  }
  // dc-only path: eob_base_tok at the dc-only ctx (0); the eob-position
  // trick maps symbol tok−1 back to the token value.
  enc.encode_symbol_adapt(
    cdf.eob_base_tok,
    (t_dim_ctx * 2 + chroma) * 16,
    2,
    tok - 1,
  )
  // dc_sign (fresh sign context -> ctx 0).
  enc.encode_bool_adapt(
    cdf.dc_sign,
    (chroma * 3 + dcs_ctx) * 2,
    sign.reinterpret_as_uint(),
  )
  Ok(())
}

///|
/// UV (chroma) dc-only transform block on TX_16X16 with the decoder's
/// fresh-zero chroma coefficient context (ccoef init 0 — the chroma
/// branch of `av1_get_skip_ctx` flags any slot != 0x40 as coded).
// fn av1_enc_txb_dc_only_uv16(
//   enc : Av1MsacEnc,
//   cdf : Av1CdfCtx,
//   tx : Int32,
//   bs : Int32,
// ) -> Unit {
//   let lw = av1_txfm_lw(tx)
//   let lh = av1_txfm_lh(tx)
//   let a = FixedArray::make(1 << lw, 0)
//   let l = FixedArray::make(1 << lh, 0)
//   let sctx = av1_get_skip_ctx(tx, bs, a, 0, l, 0, true, 1, 1)
//   let tc = av1_txfm_ctx(tx)
//   enc.encode_bool_adapt(cdf.coef_skip, (tc * 13 + sctx) * 2, 0)
//   enc.encode_symbol_adapt(cdf.eob_bin_256, (1 * 2 + 0) * 16, 8, 0)
//   enc.encode_symbol_adapt(cdf.eob_base_tok, (tc * 2 + 1) * 16, 2, 0)
//   let dcs_ctx = av1_get_dc_sign_ctx(tx, a, 0, l, 0)
//   enc.encode_bool_adapt(cdf.dc_sign, (1 * 3 + dcs_ctx) * 2, 0)
// }
//

///|
/// Write the minimal single-SB tile with an ACTIVE residual: the same
/// PARTITION_NONE 64x64 DC block as `av1_enc_write_minimal_tile`, but
/// skip = 0 and every transform block codes a single positive dc
/// coefficient (dc token 1). The decoded frame is mid-grey plus the
/// dequantised dc of `base_q_idx`, which the in-tree decoder must
/// reproduce.
pub fn av1_enc_write_minimal_residual_tile(
  base_q_idx~ : Int32 = 100,
) -> Result[Bytes, String] {
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  let partition_count = av1_partition_type_count[1].to_int()
  enc.encode_symbol_adapt(cdf.partition, (1 * 4 + 0) * 16, partition_count, 0)
  // skip = 0: residuals follow.
  enc.encode_bool_adapt(cdf.skip, 0, 0)
  enc.encode_symbol_adapt(
    cdf.kfym,
    (0 * 5 + 0) * 16,
    av1_n_intra_pred_modes - 1,
    0,
  )
  enc.encode_symbol_adapt(
    cdf.uv_mode,
    (0 * 13 + 0) * 16,
    av1_n_uv_intra_pred_modes - 1 - 1,
    0,
  )
  // TX_64X64 (depth 0). The depth base uses the table's max.
  let bs0 = av1_block_sizes[(1 * 10 + 0) * 2].to_int()
  let tx_y = av1_max_txfm_size_for_bs[bs0 * 4].to_int()
  let tx_uv = av1_max_txfm_size_for_bs[bs0 * 4 + 1].to_int()
  let m_y = av1_txfm_max(tx_y)
  enc.encode_symbol_adapt(
    cdf.txsz,
    ((m_y - 1) * 3 + 0) * 4,
    if m_y < 2 {
      m_y
    } else {
      2
    },
    0,
  )
  match av1_enc_txb_dc_only(enc, cdf, tx_y, 0, bs0) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match av1_enc_txb_dc_only(enc, cdf, tx_uv, 1, bs0, ctx_init=0) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match av1_enc_txb_dc_only(enc, cdf, tx_uv, 1, bs0, ctx_init=0) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok(enc.done())
}

///|
/// Write a 64x64 single-SB tile whose superblock splits into four
/// 32x32 blocks (`PARTITION_SPLIT` then four `PARTITION_NONE`s), every
/// block DC_PRED with skip = 1. Exercises the partition walk, the
/// per-block context evolution (fresh above/left slots per block
/// position) and the 32x32 tx sizing. The partition context stays at
/// its zero init throughout — the decoder writes the al-part ctx only
/// for non-SPLIT partitions, and there is nothing left after the frame.
pub fn av1_enc_write_split_tile(
  base_q_idx~ : Int32 = 100,
) -> Result[Bytes, String] {
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  // BL_64X64: PARTITION_SPLIT, ctx 0, 9 symbols.
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + 0) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_split,
  )
  // The four BL_32X32 children in raster order (left-top, right-top,
  // left-bottom, right-bottom), each PARTITION_NONE at ctx 0.
  let count2 = av1_partition_type_count[2].to_int()
  let bs0 = av1_block_sizes[(2 * 10 + 0) * 2].to_int()
  let tx = av1_max_txfm_size_for_bs[bs0 * 4].to_int()
  let m = av1_txfm_max(tx)
  let cfl = (av1_cfl_allowed_mask & (1 << bs0)) != 0
  let uv_nsym = av1_n_uv_intra_pred_modes - 1 - (if cfl { 0 } else { 1 })
  let uv_base = ((if cfl { 1 } else { 0 }) * 13 + 0) * 16
  for _sb in 0..<4 {
    enc.encode_symbol_adapt(
      cdf.partition,
      (2 * 4 + 0) * 16,
      count2,
      av1_partition_none,
    )
    // skip = 1: each block's above/left slots stay at the fresh state
    // for the next block's context derivation (bw4 slots only).
    enc.encode_bool_adapt(cdf.skip, 0, 1)
    enc.encode_symbol_adapt(cdf.kfym, 0, av1_n_intra_pred_modes - 1, 0)
    enc.encode_symbol_adapt(cdf.uv_mode, uv_base, uv_nsym, 0)
    enc.encode_symbol_adapt(
      cdf.txsz,
      ((m - 1) * 3 + 0) * 4,
      if m < 2 {
        m
      } else {
        2
      },
      0,
    )
  }
  Ok(enc.done())
}

///|
/// Write a 64x64 single-SB tile with one 64x64 block in V_PRED
/// (`kfym` symbol 1) carrying a zero angle delta (`angle_delta` symbol
/// 3 -> y_angle 0), UV in V_PRED with its own zero delta, skip = 1.
/// Exercises the directional-mode branch of the intra syntax (the
/// angle-delta symbols exist only for V..D67 modes).
pub fn av1_enc_write_directional_tile(
  base_q_idx~ : Int32 = 100,
) -> Result[Bytes, String] {
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + 0) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_none,
  )
  enc.encode_bool_adapt(cdf.skip, 0, 1)
  // Y: V_PRED (symbol 1) + zero angle delta (symbol 3 of 6, ctx 0).
  enc.encode_symbol_adapt(
    cdf.kfym,
    0,
    av1_n_intra_pred_modes - 1,
    av1_vert_pred,
  )
  enc.encode_symbol_adapt(
    cdf.angle_delta,
    (av1_vert_pred - av1_vert_pred) * 8,
    6,
    3,
  )
  // UV: V_PRED + zero delta (64x64 is not CFL-allowed -> 12 symbols,
  // base (0*13 + V_PRED) * 16).
  enc.encode_symbol_adapt(
    cdf.uv_mode,
    (0 * 13 + av1_vert_pred) * 16,
    av1_n_uv_intra_pred_modes - 1 - 1,
    av1_vert_pred,
  )
  enc.encode_symbol_adapt(
    cdf.angle_delta,
    (av1_vert_pred - av1_vert_pred) * 8,
    6,
    3,
  )
  // TX_64X64 depth 0 (V_PRED is directional; txtp derives from the mode
  // and codes no bits on this path).
  enc.encode_symbol_adapt(cdf.txsz, ((3 - 1) * 3 + 0) * 4, 2, 0)
  Ok(enc.done())
}

///|

///|
/// The decoder's res_ctx sign field (decode_coefs): dc_sign_level
/// starts at 1<<6 and is only rewritten when the dc token is nonzero —
/// (dc_sign - 1) & 128. A dc-less leaf (ac-only) therefore publishes
/// 1<<6, not the dc-positive 1<<7.
fn av1_enc_res_sign_field(dc_tok : Int32, dc_sign : Int32) -> Int32 {
  if dc_tok == 0 {
    1 << 6
  } else if dc_sign == 0 {
    1 << 7
  } else {
    0
  }
}

///|
/// §443 token-domain transform-block writer — the write-side twin of the
/// decoder's `av1_decode_coefs` for the DCT_DCT (tx_class 0, is_1d 0)
/// non-lossless path with seg_id 0 and a nonzero qidx. `toks` holds one
/// entry per scan position (dc at 0; the value IS the quantised level,
/// with >= 15 coded as the hi_tok escape plus a golomb extension in the
/// sign walk) and `signs` the per-position sign (1 = negative). `a`/`l`
/// are the decoder-side above/left coefficient-context arrays with their
/// reset_keyframe init values already in place. The eob is the highest
/// nonzero scan index; `toks[eob]` must be >= 1 and `toks[i]` 0 for
/// i > eob.
///
/// The levels buffer evolves exactly like the decoder's (transposed
/// x*stride+y layout, clear region (4<<slw)+2 rows) so every
/// `av1_get_lo_ctx` derivation lands on the same context; the
/// sign/golomb emission order is the decoder's rc chain, which visits
/// the nonzero ac positions in ASCENDING scan order after dc_sign.
fn av1_enc_txb_tokens(
  enc : Av1MsacEnc,
  cdf : Av1CdfCtx,
  tx : Int32,
  chroma : Int32,
  bs : Int32,
  toks : FixedArray[Int32],
  signs : FixedArray[Int32],
  a : FixedArray[Int32],
  l : FixedArray[Int32],
  /// When true the caller already wrote the coef_skip bool (and any
  /// txtp bits the frame's txtp derivation needs) — the chain starts at
  /// the eob symbols (inter TX_32X32 luma inserts a txtp_inter3 bool
  /// between the two).
  coef_skip_written~ : Bool = false,
) -> Unit {
  let lw = av1_txfm_lw(tx)
  let lh = av1_txfm_lh(tx)
  let slw = if lw < 3 { lw } else { 3 }
  let slh = if lh < 3 { lh } else { 3 }
  let szctx = slw + slh
  let t_dim_ctx = av1_txfm_ctx(tx)
  let sctx = av1_get_skip_ctx(tx, bs, a, 0, l, 0, chroma == 1, 1, 1)
  // all_skip = 0: read residuals. (txtp: DCT_DCT derives with no bits on
  // every caller — >= 32x32 luma by the txfm_max+intra >= 4 rule, chroma via
  // the DC_PRED uv-mode LUT.)
  if !coef_skip_written {
    enc.encode_bool_adapt(cdf.coef_skip, (t_dim_ctx * 13 + sctx) * 2, 0)
  }
  // eob = last nonzero scan position.
  // The coefficient count: (4 << lw) x (4 << lh) pixels — lw counts
  // 4px units, so the naive 1 << (lw + lh) undercounts by 4^2 (the
  // §443 specs only used the first 64 scan positions and never hit
  // this; full-residual tokens past scan position 63 were silently
  // dropped by the eob scan while the expected reconstruction kept
  // them).
  let scan_len = (4 << lw) * (4 << lh)
  let mut eob = 0
  let mut i = scan_len - 1
  while i > 0 {
    if toks[i] != 0 {
      eob = i
      break
    }
    i = i - 1
  }
  // eob_bin: eob in [2<<k, 4<<k) codes bin k+2 with the second-highest
  // bit as eob_hi_bit and the k bits below it as raw bools.
  let eob_bin = if eob <= 1 {
    eob
  } else {
    av1_ulog2(eob.reinterpret_as_uint()) + 1
  }
  match szctx {
    0 => enc.encode_symbol_adapt(cdf.eob_bin_16, chroma * 2 * 8, 4, eob_bin)
    1 => enc.encode_symbol_adapt(cdf.eob_bin_32, chroma * 2 * 8, 5, eob_bin)
    2 => enc.encode_symbol_adapt(cdf.eob_bin_64, chroma * 2 * 8, 6, eob_bin)
    3 => enc.encode_symbol_adapt(cdf.eob_bin_128, chroma * 2 * 8, 7, eob_bin)
    4 => enc.encode_symbol_adapt(cdf.eob_bin_256, chroma * 2 * 16, 8, eob_bin)
    5 => enc.encode_symbol_adapt(cdf.eob_bin_512, chroma * 16, 9, eob_bin)
    _ => enc.encode_symbol_adapt(cdf.eob_bin_1024, chroma * 16, 10, eob_bin)
  }
  if eob_bin > 1 {
    enc.encode_bool_adapt(
      cdf.eob_hi_bit,
      ((t_dim_ctx * 2 + chroma) * 11 + eob_bin) * 2,
      ((eob >> (eob_bin - 2)) & 1).reinterpret_as_uint(),
    )
    enc.encode_bools(
      eob_bin - 2,
      (eob & ((1 << (eob_bin - 2)) - 1)).reinterpret_as_uint(),
    )
  }
  let eob_cdf_base = (t_dim_ctx * 2 + chroma) * 16
  let hi_cdf_base = (av1_imin(t_dim_ctx, 3) * 2 + chroma) * 84
  let lo_cdf_base = (t_dim_ctx * 2 + chroma) * 164
  // The decoder's levels run: transposed layout, class-0 square geometry
  // (lo_ctx_tbl = 0 for tx < 5).
  let stride = 4 << slh
  let clear_rows = (4 << slw) + 2
  let levels = FixedArray::make(stride * clear_rows, b'\x00')
  let shift = slh + 2
  let mask = (4 << slh) - 1
  if eob != 0 {
    // eob coefficient (first coded, context from the eob size buckets).
    let rc_e = av1_scan(tx, eob)
    let x_e = rc_e >> shift
    let y_e = rc_e & mask
    let ctx_e = 1 +
      (if eob > 2 << szctx { 1 } else { 0 }) +
      (if eob > 4 << szctx { 1 } else { 0 })
    let tok_e = toks[eob]
    let lvl_tok_e = if tok_e <= 2 {
      enc.encode_symbol_adapt(
        cdf.eob_base_tok,
        eob_cdf_base + ctx_e * 4,
        2,
        tok_e - 1,
      )
      tok_e * 0x41
    } else {
      enc.encode_symbol_adapt(cdf.eob_base_tok, eob_cdf_base + ctx_e * 4, 2, 2)
      let bctx = if (x_e | y_e) > 1 { 14 } else { 7 }
      enc.encode_hi_tok(cdf.br_tok, hi_cdf_base + bctx * 4, tok_e)
      // hi_tok caps at 15 (the escape symbol); the golomb expansion is
      // consumed later and never enters the levels byte.
      av1_imin(tok_e, 15) + (3 << 6)
    }
    levels[x_e * stride + y_e] = lvl_tok_e.to_byte()
    // ac coefficients, scan order downwards — every position below eob
    // codes a base_tok (0 included), contexts from the evolving levels.
    let mut i2 = eob - 1
    while i2 > 0 {
      let rc_i = av1_scan(tx, i2)
      let x = rc_i >> shift
      let y = rc_i & mask
      let lvl_idx = x * stride + y
      let (c2, mag2) = av1_get_lo_ctx(levels, lvl_idx, 0, 0, x, y, stride)
      let y_or_x = y | x
      let tok = toks[i2]
      let lvl_tok = if tok == 0 {
        enc.encode_symbol_adapt(cdf.base_tok, lo_cdf_base + c2 * 4, 3, 0)
        0
      } else if tok <= 2 {
        enc.encode_symbol_adapt(cdf.base_tok, lo_cdf_base + c2 * 4, 3, tok)
        tok * 0x41
      } else {
        enc.encode_symbol_adapt(cdf.base_tok, lo_cdf_base + c2 * 4, 3, 3)
        let mag = mag2 & 63
        let bctx = (if y_or_x > 1 { 14 } else { 7 }) +
          (if mag > 12 { 6 } else { (mag + 1) >> 1 })
        enc.encode_hi_tok(cdf.br_tok, hi_cdf_base + bctx * 4, tok)
        av1_imin(tok, 15) + (3 << 6)
      }
      levels[lvl_idx] = lvl_tok.to_byte()
      i2 = i2 - 1
    }
    // dc token (class-0 context 0; br ctx from the three corner levels).
    let dc_tok = toks[0]
    if dc_tok <= 2 {
      enc.encode_symbol_adapt(cdf.base_tok, lo_cdf_base, 3, dc_tok)
    } else {
      enc.encode_symbol_adapt(cdf.base_tok, lo_cdf_base, 3, 3)
      let mag = (
          levels[0 * stride + 1].to_int() +
          levels[1 * stride + 0].to_int() +
          levels[1 * stride + 1].to_int()
        ) &
        63
      let bctx = if mag > 12 { 6 } else { (mag + 1) >> 1 }
      enc.encode_hi_tok(cdf.br_tok, hi_cdf_base + bctx * 4, dc_tok)
    }
  } else {
    // dc-only: eob_base_tok at ctx 0 carries the dc token directly.
    let dc_tok = toks[0]
    if dc_tok <= 1 {
      enc.encode_symbol_adapt(cdf.eob_base_tok, eob_cdf_base, 2, 0)
    } else if dc_tok == 2 {
      enc.encode_symbol_adapt(cdf.eob_base_tok, eob_cdf_base, 2, 1)
    } else {
      enc.encode_symbol_adapt(cdf.eob_base_tok, eob_cdf_base, 2, 2)
      enc.encode_hi_tok(cdf.br_tok, hi_cdf_base, dc_tok)
    }
  }
  // dc sign + golomb extension, then the ac sign walk: the decoder's rc
  // chain visits nonzero ac positions in ascending scan order.
  if toks[0] != 0 {
    let dcs_ctx = av1_get_dc_sign_ctx(tx, a, 0, l, 0)
    enc.encode_bool_adapt(
      cdf.dc_sign,
      (chroma * 3 + dcs_ctx) * 2,
      signs[0].reinterpret_as_uint(),
    )
    if toks[0] >= 15 {
      enc.encode_golomb(toks[0] - 15)
    }
  }
  let mut i3 = 1
  while i3 <= eob {
    if toks[i3] != 0 {
      enc.encode_bool_equi(signs[i3].reinterpret_as_uint())
      if toks[i3] >= 15 {
        enc.encode_golomb(toks[i3] - 15)
      }
    }
    i3 = i3 + 1
  }
}

///|
/// Shared skeleton of the §442/§443 split-residual tiles: one 64x64
/// superblock, PARTITION_SPLIT into four 32x32 PARTITION_NONE DC_PRED
/// blocks; block 0 carries the caller's Y token spec on its TX_32X32
/// (U/V all_skip), blocks 1-3 are skip = 1. Carries the partition-ctx
/// and tx-ctx mirrors; the bl=2 layer codes NONE (the bl=3 walk and its
/// partition-ctx evolution stay a separate slice).
fn av1_enc_write_split_residual_tile(
  y_toks : FixedArray[Int32],
  y_signs : FixedArray[Int32],
  base_q_idx : Int32,
) -> Bytes {
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  // Partition-context mirror: above/left arrays with the decoder's own
  // al-part semantics (NONE/H/V write back; SPLIT does not; BL_8X8
  // always writes).
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
  // BL_64X64 SPLIT (ctx 0, fresh mirror).
  let ctx1 = part_ctx(1, 0, 0)
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + ctx1) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_split,
  )
  // Four BL_32X32 PARTITION_NONE blocks (each writes the al-part ctx
  // back over 4 slots; n = imin(hsz=4, 16)).
  let count2 = av1_partition_type_count[2].to_int()
  let bs0 = av1_block_sizes[(2 * 10 + 0) * 2].to_int()
  let tx_y = av1_max_txfm_size_for_bs[bs0 * 4].to_int()
  let tx_uv = av1_max_txfm_size_for_bs[bs0 * 4 + 1].to_int()
  let m_y = av1_txfm_max(tx_y)
  let cfl = (av1_cfl_allowed_mask & (1 << bs0)) != 0
  let uv_nsym = av1_n_uv_intra_pred_modes - 1 - (if cfl { 0 } else { 1 })
  let uv_base = ((if cfl { 1 } else { 0 }) * 13 + 0) * 16
  let sb_pos : Array[(Int32, Int32)] = [(0, 0), (8, 0), (0, 8), (8, 8)]
  // Tx-size context mirror: the decoder's a.tx_intra / l.tx_intra slots
  // (reset_keyframe inits them to -1; a coded block writes its tx over
  // the covered 4px slots). The depth symbol's base derives from the
  // neighbours' tx via (left >= lh ? 1 : 0) + (above >= lw ? 1 : 0).
  let ta = FixedArray::make(32, -1)
  let tl = FixedArray::make(32, -1)
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
    let first = sbx == 0 && sby == 0
    if first {
      // skip = 0: block 0 codes a residual.
      enc.encode_bool_adapt(cdf.skip, 0, 0)
      enc.encode_symbol_adapt(cdf.kfym, 0, av1_n_intra_pred_modes - 1, 0)
      enc.encode_symbol_adapt(cdf.uv_mode, uv_base, uv_nsym, 0)
      let m32 = av1_txfm_max(tx_y)
      let tctx = (if tl[sby] >= av1_txfm_lh(tx_y) { 1 } else { 0 }) +
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
      // Y coefficient payload from the token spec. Fresh keyframe luma
      // coefficient contexts are 0x40 (reset_keyframe) — the skip-ctx
      // and dc-sign derivations read their bits.
      let lw = av1_txfm_lw(tx_y)
      let lh = av1_txfm_lh(tx_y)
      let a0 = FixedArray::make(1 << lw, 0x40)
      let l0 = FixedArray::make(1 << lh, 0x40)
      av1_enc_txb_tokens(enc, cdf, tx_y, 0, bs0, y_toks, y_signs, a0, l0)
      // U/V: all_skip = 1. The fresh keyframe chroma coefficient
      // contexts are 0x40 ("nothing coded") — ca/cl flag nothing and
      // sctx stays 7.
      let cw = av1_txfm_lw(tx_uv)
      let ch = av1_txfm_lh(tx_uv)
      let au = FixedArray::make(1 << cw, 0x40)
      let lu = FixedArray::make(1 << ch, 0x40)
      let sctx_c = av1_get_skip_ctx(tx_uv, bs0, au, 0, lu, 0, true, 1, 1)
      let tc_c = av1_txfm_ctx(tx_uv)
      enc.encode_bool_adapt(cdf.coef_skip, (tc_c * 13 + sctx_c) * 2, 1)
      enc.encode_bool_adapt(cdf.coef_skip, (tc_c * 13 + sctx_c) * 2, 1)
    } else {
      enc.encode_bool_adapt(cdf.skip, 0, 1)
      enc.encode_symbol_adapt(cdf.kfym, 0, av1_n_intra_pred_modes - 1, 0)
      enc.encode_symbol_adapt(cdf.uv_mode, uv_base, uv_nsym, 0)
      let tctx = (if tl[sby] >= av1_txfm_lh(tx_y) { 1 } else { 0 }) +
        (if ta[sbx] >= av1_txfm_lw(tx_y) { 1 } else { 0 })
      enc.encode_symbol_adapt(
        cdf.txsz,
        ((m_y - 1) * 3 + tctx) * 4,
        if m_y < 2 {
          m_y
        } else {
          2
        },
        0,
      )
      // The coded tx rides the context mirror (TX_32X32 covers 8 4px
      // slots of this 8-slot block).
      for i in 0..<8 {
        ta[sbx + i] = tx_y
        tl[sby + i] = tx_y
      }
    }
  }
  enc.done()
}

///|
/// §442's AC-structure tile, now a dc-only special case of the §443
/// token writer: block 0's Y codes a single positive dc token 1
/// (eob = 0), everything else is the split skeleton.
pub fn av1_enc_write_ac_tile(
  base_q_idx~ : Int32 = 200,
) -> Result[Bytes, String] {
  let toks = FixedArray::make(1024, 0)
  let signs = FixedArray::make(1024, 0)
  toks[0] = 1
  Ok(av1_enc_write_split_residual_tile(toks, signs, base_q_idx))
}

///|
/// §443 tile: the split skeleton with block 0's Y coding the caller's
/// token spec (TX_32X32 scan order, 1024 slots) — real ac coefficients
/// through the base_tok / br_tok / golomb chain.
pub fn av1_enc_write_ac_token_tile(
  y_toks : FixedArray[Int32],
  y_signs : FixedArray[Int32],
  base_q_idx~ : Int32 = 200,
) -> Result[Bytes, String] {
  if y_toks.length() != 1024 || y_signs.length() != 1024 {
    return Err("token spec must have 1024 slots (TX_32X32 scan order)")
  }
  Ok(av1_enc_write_split_residual_tile(y_toks, y_signs, base_q_idx))
}

///|
/// §445 intra-mode tile writer: the split skeleton (64x64 → four 32x32
/// PARTITION_NONE blocks, all skip = 1) with FULL intra-mode syntax —
/// any kfym symbol, angle deltas for directional modes (Y and UV), and
/// the kfym context derived from a mode mirror (the decoder's
/// `a.mode`/`l.mode` 4px-slot arrays, reset_keyframe init 0 = DC_PRED,
/// write-back over bw4/bh4). `blocks` holds one
/// (y_mode, y_angle, uv_mode, uv_angle) tuple per block in raster
/// order; angles are −3..=2 (0 for non-directional modes).
///
/// The decode-success oracle covers the context mirror: a wrong kfym
/// CDF slot derails the decoder's arithmetic immediately (overread).
pub fn av1_enc_write_modes_tile(
  blocks : Array[(Int32, Int32, Int32, Int32)],
  base_q_idx~ : Int32 = 100,
) -> Result[Bytes, String] {
  if blocks.length() != 4 {
    return Err("modes tile takes exactly 4 blocks (64x64 SPLIT -> 4x32x32)")
  }
  let ok_mode = (m : Int32) => m >= 0 && m <= av1_paeth_pred
  let ok_angle = (a : Int32) => a >= -3 && a <= 2
  for blk in blocks {
    if !ok_mode(blk.0) || !ok_mode(blk.2) {
      return Err("intra modes must be 0..=12 (PAETH); CFL is a later slice")
    }
    if !ok_angle(blk.1) || !ok_angle(blk.3) {
      return Err("angle deltas must be -3..=2")
    }
  }
  let cdf = av1_cdf_copy_defaults(base_q_idx)
  let enc = Av1MsacEnc::init(false)
  // Partition-context mirror (as the split skeleton).
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
  // BL_64X64 SPLIT (ctx 0, fresh mirror).
  let ctx1 = part_ctx(1, 0, 0)
  enc.encode_symbol_adapt(
    cdf.partition,
    (1 * 4 + ctx1) * 16,
    av1_partition_type_count[1].to_int(),
    av1_partition_split,
  )
  let count2 = av1_partition_type_count[2].to_int()
  let bs0 = av1_block_sizes[(2 * 10 + 0) * 2].to_int()
  let tx_y = av1_max_txfm_size_for_bs[bs0 * 4].to_int()
  let m_y = av1_txfm_max(tx_y)
  let cfl = (av1_cfl_allowed_mask & (1 << bs0)) != 0
  let uv_nsym = av1_n_uv_intra_pred_modes - 1 - (if cfl { 0 } else { 1 })
  let sb_pos : Array[(Int32, Int32)] = [(0, 0), (8, 0), (0, 8), (8, 8)]
  // Tx-size context mirror (as §442: ta/tl inited -1, TX_32X32 written
  // back over the covered 4px slots).
  let ta = FixedArray::make(32, -1)
  let tl = FixedArray::make(32, -1)
  // §445 kfym mode mirror: the decoder's a.mode/l.mode slots, keyframe
  // init 0 (DC_PRED), y_mode written back over bw4/bh4 after coding.
  let a_mode = FixedArray::make(32, av1_dc_pred)
  let l_mode = FixedArray::make(32, av1_dc_pred)
  // Skip-context mirror: sctx = a.skip[bx4] + l.skip[by4] — a skip=1
  // block writes 1 back, so later blocks see a nonzero ctx (the §445
  // probe caught this: §441's split tile had silently derailed here,
  // masked by constant-edge predictions).
  let a_skip = FixedArray::make(32, 0)
  let l_skip = FixedArray::make(32, 0)
  for bi in 0..<4 {
    let sbx = sb_pos[bi].0
    let sby = sb_pos[bi].1
    let (y_mode, y_angle, uv_mode, uv_angle) = blocks[bi]
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
    let sctx = a_skip[sbx] + l_skip[sby]
    enc.encode_bool_adapt(cdf.skip, sctx * 2, 1)
    // kfym: context from the mode mirror (av1_intra_mode_context maps
    // the 13 modes onto 5 buckets; base (above*5 + left) * 16).
    let mctx = av1_intra_mode_context[a_mode[sbx]].to_int() * 5 +
      av1_intra_mode_context[l_mode[sby]].to_int()
    enc.encode_symbol_adapt(
      cdf.kfym,
      mctx * 16,
      av1_n_intra_pred_modes - 1,
      y_mode,
    )
    // Y angle delta: only for the directional modes V..VL (1..=8), 6
    // symbols, base (mode - V_PRED) * 8.
    if y_mode >= av1_vert_pred && y_mode <= av1_vert_left_pred {
      enc.encode_symbol_adapt(
        cdf.angle_delta,
        (y_mode - av1_vert_pred) * 8,
        6,
        y_angle + 3,
      )
    }
    // uv_mode: base rides the luma mode directly (cfl_allowed adds the
    // +13 bank and one more symbol).
    let uv_base = ((if cfl { 1 } else { 0 }) * 13 + y_mode) * 16
    enc.encode_symbol_adapt(cdf.uv_mode, uv_base, uv_nsym, uv_mode)
    if uv_mode >= av1_vert_pred && uv_mode <= av1_vert_left_pred {
      enc.encode_symbol_adapt(
        cdf.angle_delta,
        (uv_mode - av1_vert_pred) * 8,
        6,
        uv_angle + 3,
      )
    }
    // txsz depth on the tx mirror.
    let tctx = (if tl[sby] >= av1_txfm_lh(tx_y) { 1 } else { 0 }) +
      (if ta[sbx] >= av1_txfm_lw(tx_y) { 1 } else { 0 })
    enc.encode_symbol_adapt(
      cdf.txsz,
      ((m_y - 1) * 3 + tctx) * 4,
      if m_y < 2 {
        m_y
      } else {
        2
      },
      0,
    )
    // Write-backs: tx over 8 slots, mode over bw4/bh4 (8 for 32x32).
    for i in 0..<8 {
      ta[sbx + i] = tx_y
      tl[sby + i] = tx_y
      a_mode[sbx + i] = y_mode
      l_mode[sby + i] = y_mode
      a_skip[sbx + i] = 1
      l_skip[sby + i] = 1
    }
  }
  Ok(enc.done())
}
