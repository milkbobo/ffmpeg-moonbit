///|
/// Single-threaded refmvs row and temporal-motion state. The 37 slots mirror
/// dav1d's rt->r pointer table; the row arrays are shared between slots when
/// tile_sbrow_init exchanges the three boundary rows.
pub(all) struct Av1RefmvsTileState {
  rows : FixedArray[FixedArray[Av1Rb]]
  physical : FixedArray[FixedArray[Av1Rb]]
  rp_proj : FixedArray[Av1Rtb]
  rp_stride : Int
  iw8 : Int
  ih8 : Int
  sbsz : Int
}

///|
pub fn av1_refmvs_tile_state_new(
  rp_stride : Int,
  iw8 : Int,
  ih8 : Int,
  sbsz : Int,
) -> Av1RefmvsTileState {
  let blank : Av1Rb = {
    ref0: 0, ref1: -1, bs: 17, mf: 0,
    mv0: av1_rmv_invalid, mv1: av1_rmv_invalid,
  }
  let physical = FixedArray::makei(
    35,
    _ => FixedArray::make(rp_stride * 2, blank),
  )
  let rows = FixedArray::makei(37, i => physical[i % 35])
  let rp_proj = FixedArray::makei(
    16 * rp_stride,
    _ => { mv: av1_rmv_invalid, ref_: 0 },
  )
  { rows, physical, rp_proj, rp_stride, iw8, ih8, sbsz }
}

///|
/// `dav1d_refmvs_tile_sbrow_init` for one tile and one frame thread.
pub fn Av1RefmvsTileState::init_sbrow(
  self : Av1RefmvsTileState,
  sby : Int,
) -> Unit {
  let off = (self.sbsz * sby) & 16
  for i in 0..<self.sbsz {
    self.rows[off + 5 + i] = self.physical[i]
  }
  self.rows[off] = self.physical[self.sbsz]
  self.rows[off + 2] = self.physical[self.sbsz + 1]
  self.rows[off + 4] = self.physical[self.sbsz + 2]
  if (sby & 1) != 0 {
    for i in [0, 2, 4] {
      let old = self.rows[off + i]
      self.rows[off + i] = self.rows[off + self.sbsz + i]
      self.rows[off + self.sbsz + i] = old
    }
  }
}

///|
/// `splat_mv_c`, with `by4` identifying the top 4x4 row of the block.
pub fn Av1RefmvsTileState::splat_mv(
  self : Av1RefmvsTileState,
  block : Av1Rb,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
) -> Unit {
  let base = (by4 & 31) + 5
  for y in 0..<bh4 {
    let row = self.rows[base + y]
    for x in bx4..<(bx4 + bw4) {
      row[x] = block
    }
  }
}

///|
/// `save_tmvs_c`; rp stores one 8x8 temporal block per element.
pub fn Av1RefmvsTileState::save_tmvs(
  self : Av1RefmvsTileState,
  rp : FixedArray[Av1Rtb],
  mfmv_sign : FixedArray[Int],
  col_start8 : Int,
  col_end8 : Int,
  row_start8 : Int,
  row_end8 : Int,
) -> Unit {
  let xend = if col_end8 < self.iw8 { col_end8 } else { self.iw8 }
  let yend = if row_end8 < self.ih8 { row_end8 } else { self.ih8 }
  for y in row_start8..<yend {
    let row = self.rows[6 + ((y & 15) << 1)]
    let mut x = col_start8
    while x < xend {
      let b = row[x * 2 + 1]
      let bw8 = (av1_block_dimensions[b.bs * 4].to_int() + 1) >> 1
      let (mv, ref_) = if b.ref1 > 0 && mfmv_sign[b.ref1 - 1] != 0 &&
        av1_rmv_small(b.mv1) {
        (b.mv1, b.ref1)
      } else if b.ref0 > 0 && mfmv_sign[b.ref0 - 1] != 0 &&
        av1_rmv_small(b.mv0) {
        (b.mv0, b.ref0)
      } else {
        ((0, 0), 0)
      }
      for _ in 0..<bw8 {
        rp[y * self.rp_stride + x] = { mv, ref_ }
        x = x + 1
      }
    }
  }
}

///|
fn av1_rmv_small(mv : (Int, Int)) -> Bool {
  let (y, x) = mv
  let ay = if y < 0 { -y } else { y }
  let ax = if x < 0 { -x } else { x }
  (ay | ax) < 4096
}

///|
/// `load_tmvs_c` projects temporal blocks from selected reference frames.
pub fn Av1RefmvsTileState::load_tmvs(
  self : Av1RefmvsTileState,
  init : Av1RefmvsFrameInit,
  rp_ref : FixedArray[FixedArray[Av1Rtb]],
  col_start8 : Int,
  col_end8 : Int,
  row_start8 : Int,
  row_end8 : Int,
) -> Unit {
  let yend = if row_end8 < self.ih8 { row_end8 } else { self.ih8 }
  let xstart = if col_start8 > 8 { col_start8 - 8 } else { 0 }
  let xend = if col_end8 + 8 < self.iw8 { col_end8 + 8 } else { self.iw8 }
  for y in row_start8..<yend {
    for x in col_start8..<col_end8 {
      let idx = (y & 15) * self.rp_stride + x
      self.rp_proj[(y & 15) * self.rp_stride + x] = {
        mv: av1_rmv_invalid, ref_: self.rp_proj[idx].ref_,
      }
    }
  }
  for n in 0..<init.n_mfmvs {
    let ref2cur = init.mfmv_ref2cur[n]
    if ref2cur == -2147483647 - 1 {
      continue
    }
    let ref_idx = init.mfmv_ref[n]
    let ref_sign = ref_idx - 4
    let src = rp_ref[ref_idx]
    for y in row_start8..<yend {
      let y_sb_align = y & -8
      let y_proj_start = if y_sb_align > row_start8 { y_sb_align } else { row_start8 }
      let y_proj_end = if y_sb_align + 8 < yend { y_sb_align + 8 } else { yend }
      let mut x = xstart
      while x < xend {
        let b = src[y * self.rp_stride + x]
        if b.ref_ == 0 {
          x = x + 1
          continue
        }
        let ref2ref = init.mfmv_ref2ref[n][b.ref_ - 1]
        if ref2ref == 0 {
          x = x + 1
          continue
        }
        let (dy, dx) = av1_rmv_projection(b.mv, ref2cur, ref2ref)
        let pos_y = y + av1_rmv_apply_sign(
          (if dy < 0 { -dy } else { dy }) >> 6, dy ^ ref_sign,
        )
        let mut pos_x = x + av1_rmv_apply_sign(
          (if dx < 0 { -dx } else { dx }) >> 6, dx ^ ref_sign,
        )
        while true {
          let x_sb_align = x & -8
          let lo = if x_sb_align - 8 > col_start8 { x_sb_align - 8 } else { col_start8 }
          let hi = if x_sb_align + 16 < col_end8 { x_sb_align + 16 } else { col_end8 }
          if pos_y >= y_proj_start && pos_y < y_proj_end &&
            pos_x >= lo && pos_x < hi {
            self.rp_proj[(pos_y & 15) * self.rp_stride + pos_x] = {
              mv: b.mv, ref_: ref2ref,
            }
          }
          x = x + 1
          if x >= xend {
            break
          }
          let next = src[y * self.rp_stride + x]
          if next.ref_ != b.ref_ || next.mv != b.mv {
            break
          }
          pos_x = pos_x + 1
        }
      }
    }
  }
}

///|
/// Frame-level single-threaded refmvs state. `rp` is retained for the next
/// frame's temporal MV projection after all superblock rows have been saved.
pub(all) struct Av1RefmvsFrameState {
  rf : Av1Rf
  init : Av1RefmvsFrameInit
  tile : Av1RefmvsTileState
  rp : FixedArray[Av1Rtb]
  rp_ref : FixedArray[FixedArray[Av1Rtb]]
}

///|
pub fn av1_refmvs_frame_state_new(
  rf : Av1Rf,
  init : Av1RefmvsFrameInit,
  rp_ref : FixedArray[FixedArray[Av1Rtb]],
  rp_stride : Int,
  iw8 : Int,
  ih8 : Int,
  sbsz : Int,
) -> Av1RefmvsFrameState {
  let frame_rf : Av1Rf = {
    iw4: rf.iw4,
    ih4: rf.ih4,
    sign_bias: init.sign_bias,
    pocdiff: init.pocdiff,
    hp: rf.hp,
    force_integer_mv: rf.force_integer_mv,
    use_ref_frame_mvs: init.use_ref_frame_mvs,
    gm_types: rf.gm_types,
    gm_matrices: rf.gm_matrices,
  }
  {
    rf: frame_rf,
    init,
    tile: av1_refmvs_tile_state_new(rp_stride, iw8, ih8, sbsz),
    rp: FixedArray::makei(
      rp_stride * ih8,
      _ => { mv: (0, 0), ref_: 0 },
    ),
    rp_ref,
  }
}

///|
/// Start one superblock row before entropy-decoding its blocks.
pub fn Av1RefmvsFrameState::begin_sbrow(
  self : Av1RefmvsFrameState,
  sby : Int,
  col_start8 : Int,
  col_end8 : Int,
  row_start8 : Int,
  row_end8 : Int,
) -> Unit {
  self.tile.init_sbrow(sby)
  if self.init.use_ref_frame_mvs {
    self.tile.load_tmvs(
      self.init, self.rp_ref, col_start8, col_end8,
      row_start8, row_end8,
    )
  }
}

///|
/// Save one decoded superblock row into this frame's temporal MV map.
pub fn Av1RefmvsFrameState::finish_sbrow(
  self : Av1RefmvsFrameState,
  col_start8 : Int,
  col_end8 : Int,
  row_start8 : Int,
  row_end8 : Int,
) -> Unit {
  self.tile.save_tmvs(
    self.rp, self.init.mfmv_sign, col_start8, col_end8,
    row_start8, row_end8,
  )
}

///|
/// Read a block's spatial and projected temporal candidates from the active
/// row buffers. Reference indices here use dav1d's 1..7 convention.
pub fn Av1RefmvsFrameState::find(
  self : Av1RefmvsFrameState,
  tile_col_start4 : Int,
  tile_col_end4 : Int,
  tile_row_start4 : Int,
  tile_row_end4 : Int,
  ref0 : Int,
  ref1 : Int,
  bs : Int,
  top_has_right : Bool,
  by4 : Int,
  bx4 : Int,
) -> Av1RefmvsResult {
  av1_refmvs_find(
    self.rf, self.tile.rows, self.tile.rp_proj, self.tile.rp_stride,
    tile_col_start4, tile_col_end4, tile_row_start4, tile_row_end4,
    ref0, ref1, bs, top_has_right, by4, bx4,
  )
}

///|
/// Publish a decoded inter block's MV into the spatial row ring.
pub fn Av1RefmvsFrameState::splat(
  self : Av1RefmvsFrameState,
  block : Av1Rb,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
) -> Unit {
  self.tile.splat_mv(block, bx4, by4, bw4, bh4)
}
