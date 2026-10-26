///|
/// Inter residual coefficient walk from dav1d `recon_b_inter`:
/// `read_coef_tree` (luma, driven by the var-tx split masks) and the chroma
/// `uvtx` loops with luma-txtp inheritance. Coefficient decoding itself is
/// injected so the walk can be compared against C independently of the
/// already-validated `decode_coefs`.

///|
/// Per-leaf coefficient reader. Arguments are the above/left coefficient
/// context arrays and their offsets, the transform size, the plane (0 luma,
/// 1/2 chroma) and the luma transform type used for chroma derivation.
/// Returns `(eob, txtp, res_ctx)`; `eob < 0` means all-skip.
pub(all) struct Av1CoefReader {
  decode : (
    FixedArray[Int32],
    Int32,
    FixedArray[Int32],
    Int32,
    Int32,
    Int32,
    Bool,
    Int32,
  ) -> (Int32, Int32, Int32)
}

///|
fn av1_coef_ctx_fill(
  ctx : FixedArray[Int32],
  off : Int32,
  n : Int32,
  v : Int32,
) -> Unit {
  for i in 0..<n {
    ctx[off + i] = v
  }
}

///|
fn av1_txtp_map_fill(
  map : FixedArray[Byte],
  off : Int32,
  w : Int32,
  h : Int32,
  txtp : Int32,
) -> Unit {
  let b = txtp.to_byte()
  for y in 0..<h {
    for x in 0..<w {
      map[off + y * 32 + x] = b
    }
  }
}

///|
/// `read_coef_tree`: descend the var-tx split masks, decode one coefficient
/// block per leaf and publish its context into `a->lcoef`/`l->lcoef` and
/// `txtp_map`. `bx`/`by` are absolute 4x4 coordinates; `bw`/`bh` are the
/// frame dimensions in 4x4 units (context fill lengths are clipped there).
fn av1_read_coef_tree(
  reader : Av1CoefReader,
  tx : Int32,
  depth : Int32,
  split0 : UInt32,
  split1 : UInt32,
  x_off : Int32,
  y_off : Int32,
  abx : Int32,
  aby : Int32,
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
  a_lcoef : FixedArray[Int32],
  l_lcoef : FixedArray[Int32],
  txtp_map : FixedArray[Byte],
  apply : ((Int32, Int32, Int32, Int32, Int32) -> Unit)?,
) -> Unit {
  let txw = av1_txfm_w(tx)
  let txh = av1_txfm_h(tx)
  let split = if depth == 0 { split0 } else if depth == 1 { split1 } else { 0U }
  let bit = y_off * 4 + x_off
  if depth < 2 && ((split >> bit) & 1U) != 0U {
    let sub = av1_txfm_sub(tx)
    let txsw = av1_txfm_w(sub)
    let txsh = av1_txfm_h(sub)
    av1_read_coef_tree(
      reader,
      sub,
      depth + 1,
      split0,
      split1,
      x_off * 2,
      y_off * 2,
      abx,
      aby,
      bx,
      by,
      bw,
      bh,
      a_lcoef,
      l_lcoef,
      txtp_map,
      apply,
    )
    if txw >= txh && bx + txsw < bw {
      av1_read_coef_tree(
        reader,
        sub,
        depth + 1,
        split0,
        split1,
        x_off * 2 + 1,
        y_off * 2,
        abx,
        aby,
        bx + txsw,
        by,
        bw,
        bh,
        a_lcoef,
        l_lcoef,
        txtp_map,
        apply,
      )
    }
    if txh >= txw && by + txsh < bh {
      av1_read_coef_tree(
        reader,
        sub,
        depth + 1,
        split0,
        split1,
        x_off * 2,
        y_off * 2 + 1,
        abx,
        aby,
        bx,
        by + txsh,
        bw,
        bh,
        a_lcoef,
        l_lcoef,
        txtp_map,
        apply,
      )
      if txw >= txh && bx + txsw < bw {
        av1_read_coef_tree(
          reader,
          sub,
          depth + 1,
          split0,
          split1,
          x_off * 2 + 1,
          y_off * 2 + 1,
          abx,
          aby,
          bx + txsw,
          by + txsh,
          bw,
          bh,
          a_lcoef,
          l_lcoef,
          txtp_map,
          apply,
        )
      }
    }
  } else {
    let bx4 = bx & 31
    let by4 = by & 31
    let (eob, txtp, res_ctx) = (reader.decode)(
      a_lcoef, bx4, l_lcoef, by4, tx, 0, false, 0,
    )
    let wlen = av1_imin(txw, bw - bx)
    let hlen = av1_imin(txh, bh - by)
    if wlen > 0 {
      av1_coef_ctx_fill(a_lcoef, bx4, wlen, res_ctx)
    }
    if hlen > 0 {
      av1_coef_ctx_fill(l_lcoef, by4, hlen, res_ctx)
    }
    av1_txtp_map_fill(txtp_map, by4 * 32 + bx4, txw, txh, txtp)
    if eob >= 0 {
      match apply {
        Some(f) => f(bx - abx, by - aby, tx, txtp, eob)
        None => ()
      }
    }
  }
}

///|
/// Residual half of `recon_b_inter`: luma coefficient tree over the block's
/// `16x16` windows, then per-plane chroma coefficient blocks at `uvtx`.
/// `w4`/`h4` are the visible luma dimensions in 4x4 units and `cw4`/`ch4`
/// the visible chroma dimensions; `abx`/`aby` are the block origin in
/// absolute 4x4 units, `bw`/`bh` the frame dimensions.
pub fn av1_read_inter_residual(
  reader : Av1CoefReader,
  bs : Int32,
  tx_max : Int32,
  split0 : UInt32,
  split1 : UInt32,
  uvtx : Int32,
  w4 : Int32,
  h4 : Int32,
  cw4 : Int32,
  ch4 : Int32,
  ss_h : Int32,
  ss_v : Int32,
  has_chroma : Bool,
  abx : Int32,
  aby : Int32,
  bw : Int32,
  bh : Int32,
  a_lcoef : FixedArray[Int32],
  l_lcoef : FixedArray[Int32],
  a_ccoef : FixedArray[Int32],
  l_ccoef : FixedArray[Int32],
  txtp_map : FixedArray[Byte],
  apply_y : ((Int32, Int32, Int32, Int32, Int32) -> Unit)?,
  apply_uv : ((Int32, Int32, Int32, Int32, Int32, Int32) -> Unit)?,
) -> Unit {
  let bw4 = av1_block_dimensions[bs * 4].to_int()
  let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
  let ytx_w = av1_txfm_w(tx_max)
  let ytx_h = av1_txfm_h(tx_max)
  let mut init_y = 0
  while init_y < bh4 {
    let mut init_x = 0
    while init_x < bw4 {
      let y_end = av1_imin(h4, init_y + 16)
      let x_end = av1_imin(w4, init_x + 16)
      let mut y = init_y
      let mut y_off = if init_y != 0 { 1 } else { 0 }
      while y < y_end {
        let mut x = init_x
        let mut x_off = if init_x != 0 { 1 } else { 0 }
        while x < x_end {
          av1_read_coef_tree(
            reader,
            tx_max,
            0,
            split0,
            split1,
            x_off,
            y_off,
            abx,
            aby,
            abx + x,
            aby + y,
            bw,
            bh,
            a_lcoef,
            l_lcoef,
            txtp_map,
            apply_y,
          )
          x = x + ytx_w
          x_off = x_off + 1
        }
        y = y + ytx_h
        y_off = y_off + 1
      }
      // chroma coefficient blocks
      if has_chroma {
        let uvw = av1_txfm_w(uvtx)
        let uvh = av1_txfm_h(uvtx)
        for pl in 0..<2 {
          let base = pl * 32
          let mut cy = init_y >> ss_v
          let cy_end = av1_imin(ch4, (init_y + 16) >> ss_v)
          while cy < cy_end {
            let mut cx = init_x >> ss_h
            let cx_end = av1_imin(cw4, (init_x + 16) >> ss_h)
            while cx < cx_end {
              let luma_txtp = txtp_map[((aby & 31) + (cy << ss_v)) * 32 +
              (abx & 31) +
              (cx << ss_h)].to_int()
              let a_base = base + ((abx & 31) >> ss_h) + cx
              let l_base = base + ((aby & 31) >> ss_v) + cy
              let (eob, txtp, res_ctx) = (reader.decode)(
                a_ccoef,
                a_base,
                l_ccoef,
                l_base,
                uvtx,
                1 + pl,
                false,
                luma_txtp,
              )
              let ctw = av1_imin(uvw, (bw - abx - (cx << ss_h) + ss_h) >> ss_h)
              let cth = av1_imin(uvh, (bh - aby - (cy << ss_v) + ss_v) >> ss_v)
              if ctw > 0 {
                av1_coef_ctx_fill(a_ccoef, a_base, ctw, res_ctx)
              }
              if cth > 0 {
                av1_coef_ctx_fill(l_ccoef, l_base, cth, res_ctx)
              }
              if eob >= 0 {
                match apply_uv {
                  Some(f) => f(pl, cx, cy, uvtx, txtp, eob)
                  None => ()
                }
              }
              cx = cx + uvw
            }
            cy = cy + uvh
          }
        }
      }
      init_x = init_x + 16
    }
    init_y = init_y + 16
  }
}
