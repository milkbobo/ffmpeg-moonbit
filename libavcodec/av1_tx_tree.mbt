///|
/// `read_tx_tree`/`read_vartx_tree` from dav1d decode.c: inter transform
/// partitioning from `max_txfm_size_for_bs` down the `txpart` tree, plus the
/// `a->tx`/`l.tx` context updates consumed by the next block.

///|
pub(all) struct Av1VarTxTree {
  /// `b->max_ytx` (luma tx at tree root; TX_4X4 for lossless/coded-4x4).
  max_ytx : Int32
  /// `b->uvtx` (chroma tx; always the block's max for inter).
  uvtx : Int32
  /// `b->tx_split0` / `b->tx_split1`: split masks for depth 0/1.
  split0 : UInt32
  split1 : UInt32
}

///|
/// `dav1d_memset_pow2[lw]`: fill `1 << len_lw` context entries.
fn av1_tx_ctx_fill(
  tx : FixedArray[Int32],
  off : Int32,
  len_lw : Int32,
  value : Int32,
) -> Unit {
  for i in 0..<(1 << len_lw) {
    tx[off + i] = value
  }
}

///|
/// `read_tx_tree`, recursing into `t_dim->sub` while `txpart` says split and
/// the transform is larger than 8x8. Context writes use the block's
/// within-64x64-SB offsets, so callers pass absolute `bx`/`by`.
fn av1_read_tx_tree(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  from : Int32,
  depth : Int32,
  masks : FixedArray[UInt32],
  x_off : Int32,
  y_off : Int32,
  a_tx : FixedArray[Int32],
  l_tx : FixedArray[Int32],
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let txw = av1_txfm_lw(from)
  let txh = av1_txfm_lh(from)
  let bx4 = bx & 31
  let by4 = by & 31
  let mut is_split = 0
  if depth < 2 && from > 0 {
    let cat = 2 * (4 - av1_txfm_max(from)) - depth
    let a = if a_tx[bx4] < txw { 1 } else { 0 }
    let l = if l_tx[by4] < txh { 1 } else { 0 }
    is_split = msac
      .decode_bool_adapt(cdf.txpart, (cat * 3 + a + l) * 2)
      .reinterpret_as_int()
    if is_split != 0 {
      let d = depth
      masks[d] = masks[d] | (1U << (y_off * 4 + x_off))
    }
  }
  if is_split != 0 && av1_txfm_max(from) > 1 {
    let sub = av1_txfm_sub(from)
    let txsw = av1_txfm_w(sub)
    let txsh = av1_txfm_h(sub)
    av1_read_tx_tree(
      msac,
      cdf,
      sub,
      depth + 1,
      masks,
      x_off * 2,
      y_off * 2,
      a_tx,
      l_tx,
      bx,
      by,
      bw,
      bh,
    )
    if txw >= txh && bx + txsw < bw {
      av1_read_tx_tree(
        msac,
        cdf,
        sub,
        depth + 1,
        masks,
        x_off * 2 + 1,
        y_off * 2,
        a_tx,
        l_tx,
        bx + txsw,
        by,
        bw,
        bh,
      )
    }
    if txh >= txw && by + txsh < bh {
      av1_read_tx_tree(
        msac,
        cdf,
        sub,
        depth + 1,
        masks,
        x_off * 2,
        y_off * 2 + 1,
        a_tx,
        l_tx,
        bx,
        by + txsh,
        bw,
        bh,
      )
      if txw >= txh && bx + txsw < bw {
        av1_read_tx_tree(
          msac,
          cdf,
          sub,
          depth + 1,
          masks,
          x_off * 2 + 1,
          y_off * 2 + 1,
          a_tx,
          l_tx,
          bx + txsw,
          by + txsh,
          bw,
          bh,
        )
      }
    }
  } else {
    // split at <= 8x8 (or depth limit) records TX_4X4, else the tx size.
    let value = if is_split != 0 { 0 } else { txw }
    av1_tx_ctx_fill(a_tx, bx4, txw, value)
    let value_h = if is_split != 0 { 0 } else { txh }
    av1_tx_ctx_fill(l_tx, by4, txh, value_h)
  }
}

///|
/// `read_vartx_tree`: sets the inter block's `max_ytx`/`uvtx` and decodes the
/// `txpart` split masks, updating the `tx` contexts. `layout` is dav1d's
/// pixel layout index (0 = I400, 1 = I420, 2 = I422, 3 = I444).
pub fn av1_read_vartx_tree(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  bs : Int32,
  skip : Bool,
  lossless : Bool,
  switchable : Bool,
  layout : Int32,
  a_tx : FixedArray[Int32],
  l_tx : FixedArray[Int32],
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
) -> Av1VarTxTree {
  let bw4 = av1_block_dimensions[bs * 4].to_int()
  let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
  // dav1d: lw/lh of the block, for TX_SWITCHABLE skip/lossless context fills.
  let bw_lw = av1_block_dimensions[bs * 4 + 2].to_int()
  let bh_lh = av1_block_dimensions[bs * 4 + 3].to_int()
  let mut max_ytx = av1_max_txfm_size_for_bs[bs * 4].to_int()
  let mut uvtx = av1_max_txfm_size_for_bs[bs * 4 + layout].to_int()
  let masks = FixedArray::make(2, 0U)
  if !skip && (lossless || max_ytx == 0) {
    max_ytx = 0 // TX_4X4
    uvtx = 0
    if switchable {
      av1_tx_ctx_fill(a_tx, bx & 31, bw_lw, 0)
      av1_tx_ctx_fill(l_tx, by & 31, bh_lh, 0)
    }
  } else if !switchable || skip {
    if switchable {
      av1_tx_ctx_fill(a_tx, bx & 31, bw_lw, bw_lw)
      av1_tx_ctx_fill(l_tx, by & 31, bh_lh, bh_lh)
    }
  } else {
    let ytx_w = av1_txfm_w(max_ytx)
    let ytx_h = av1_txfm_h(max_ytx)
    let mut y = 0
    let mut y_off = 0
    while y < bh4 {
      let mut x = 0
      let mut x_off = 0
      while x < bw4 {
        av1_read_tx_tree(
          msac,
          cdf,
          max_ytx,
          0,
          masks,
          x_off,
          y_off,
          a_tx,
          l_tx,
          bx + x,
          by + y,
          bw,
          bh,
        )
        x = x + ytx_w
        x_off = x_off + 1
      }
      y = y + ytx_h
      y_off = y_off + 1
    }
  }
  { max_ytx, uvtx, split0: masks[0], split1: masks[1], }
}
