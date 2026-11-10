///|
/// The shared High-profile I8x8 luma pass of the CAVLC and CABAC intra
/// encoders: per 8x8 block (z-order 0..3), pick the best availability-checked
/// `pred8x8l` mode by SAD, predict, forward-transform + quantise, dequantise
/// into `mb` and reconstruct through `h264_idct8_add`. The 0..3 block order
/// mirrors the decoder's reconstruction, so each block predicts from exactly
/// the neighbours the decoder will use. Fills `store` (4 x 64 transposed
/// levels) and the raw signalled modes into `modes` (2x2 replication, the
/// decoder's fill); returns `(cost, cbp)` with the post-quantisation SAD and
/// one cbp bit per non-empty block.
///
/// `avail(bx8, by8)` provides the reconstruction-side availability of one
/// 8x8 block as `(top, left, topright, topleft)` - `h264_recon_full_plane`'s
/// I8x8-branch semantics. The CABAC encoder derives it from its decoder
/// mirror; the CAVLC intra encoder (single slice, no constrained intra
/// prediction) uses the geometric form.
fn h264_enc_luma_i8_pass(
  src_y : Array[Int32],
  rec_y : Array[Int32],
  ystride : Int32,
  mb_x : Int32,
  mb_y : Int32,
  pps : H264Pps,
  qp : Int32,
  store : Array[Int32],
  modes : Array[Int32],
  mb : Array[Int32],
  avail : (Int32, Int32) -> (Bool, Bool, Bool, Bool),
) -> Result[(Int32, Int32), String] {
  let qmul8 = h264_build_dequant8(pps, 0, qp)
  let ybase = mb_y * 16 * ystride + mb_x * 16
  let mut cost = 0
  let mut cbp = 0
  for i8 = 0; i8 < 4; i8 = i8 + 1 {
    let bx8 = i8 % 2
    let by8 = i8 / 2
    let off = ybase + by8 * 8 * ystride + bx8 * 8
    let (top, left, topright, topleft) = avail(bx8, by8)
    let mut best_sig = 0
    let mut best_eff : Int32 = -1
    let mut best_sad = -1
    for sig = 0; sig < 9; sig = sig + 1 {
      let eff = match h264_check_intra4x4_mode(sig, top, left) {
        Ok(v) => v
        Err(_) => -1
      }
      if eff < 0 {
        continue
      }
      if h264_pred8x8l(
          rec_y,
          off,
          ystride,
          eff,
          top,
          left,
          topright,
          topleft~,
          bit_depth=8,
        )
        is Err(_) {
        continue
      }
      let sad = h264_enc_sad8(src_y, rec_y, off, ystride)
      if best_sad < 0 || sad < best_sad {
        best_sad = sad
        best_sig = sig
        best_eff = eff
      }
    }
    if best_eff < 0 {
      return Err("h264 enc: no feasible intra8x8 mode")
    }
    match
      h264_pred8x8l(
        rec_y,
        off,
        ystride,
        best_eff,
        top,
        left,
        topright,
        topleft~,
        bit_depth=8,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    for dy = 0; dy < 2; dy = dy + 1 {
      for dx = 0; dx < 2; dx = dx + 1 {
        modes[(by8 * 2 + dy) * 4 + bx8 * 2 + dx] = best_sig
      }
    }
    let res : Array[Int32] = Array::make(64, 0)
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        res[row * 8 + col] = src_y[off + row * ystride + col] -
          rec_y[off + row * ystride + col]
      }
    }
    let levels = h264_enc_fdct8_quant_res(res, 0, qp)
    let mut total = 0
    for s = 0; s < 64; s = s + 1 {
      store[64 * i8 + s] = levels[s]
      if levels[s] != 0 {
        total = total + 1
        mb[64 * i8 + s] = h264_enc_dequant_level(levels[s], qmul8[s])
      }
    }
    if total != 0 {
      cbp = cbp | (1 << i8)
      // `h264_idct8_add4`'s nz shortcut: a lone DC level takes the flat
      // DC add, anything else the full inverse transform.
      if total == 1 && mb[64 * i8] != 0 {
        h264_idct8_dc_add(rec_y, off, ystride, mb, 64 * i8, bit_depth=8)
      } else {
        h264_idct8_add(rec_y, off, ystride, mb, 64 * i8, bit_depth=8)
      }
    }
    cost = cost + h264_enc_sad8(src_y, rec_y, off, ystride)
  }
  Ok((cost, cbp))
}

///|
/// Geometric availability for a single-slice all-intra picture (the CAVLC
/// intra encoder): every macroblock decoded before this one in raster order
/// is an intra neighbour, so availability reduces to frame geometry.
fn h264_enc_i8_avail(
  mb_x : Int32,
  mb_y : Int32,
  mb_width : Int32,
) -> (Int32, Int32) -> (Bool, Bool, Bool, Bool) {
  fn(bx8 : Int32, by8 : Int32) -> (Bool, Bool, Bool, Bool) {
    let top = by8 > 0 || mb_y > 0
    let left = bx8 > 0 || mb_x > 0
    // The topright samples of a top-row block sit above the MB's own
    // right half for bx8 = 0 and above the top-right MB for bx8 = 1;
    // an inner-row block sees its same-MB left neighbour.
    let topright = if by8 == 0 {
      top && (bx8 == 0 || mb_x < mb_width - 1)
    } else {
      bx8 == 0
    }
    // `h264_intra_topleft`'s geometric form: same-MB / top MB / left MB /
    // top-left MB corner samples.
    let topleft = if bx8 > 0 {
      by8 > 0 || mb_y > 0
    } else if by8 > 0 {
      mb_x > 0
    } else {
      mb_x > 0 && mb_y > 0
    }
    (top, left, topright, topleft)
  }
}

///|
/// The `sub`-th interleaved CAVLC coefficient list of 8x8DCT quadrant `q`:
/// list element k is the transposed-8x8 zigzag position `4*k + sub` of the
/// quadrant's 64 levels (`zigzag_scan8x8_cavlc` - the lists share one
/// global zigzag order, unlike CABAC's four independent block scans).
fn h264_cavlc8_sub_view(
  store : Array[Int32],
  q : Int32,
  sub : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(16, 0)
  for k = 0; k < 16; k = k + 1 {
    out[k] = store[64 * q + h264_zigzag_scan8x8[4 * k + sub]]
  }
  out
}
