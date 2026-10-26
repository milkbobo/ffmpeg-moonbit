///|
/// Inter-block syntax driver after reference/MV coding: the dav1d
/// `decode_b` inter branch from the compound flag through the subpel
/// filter, including inter-intra, motion variation, warp derivation and
/// the refmvs publish.

///|
/// Neighbour state for one 128-pixel above-context bank and the current
/// superblock row's left edge. Indices are within-bank 4x4 coordinates.
/// The frame driver retains a separate top array for each bank across rows
/// and resets the shared left array at each tile superblock row. Cells start
/// as intra (dav1d resets tile edges to intra=1) and are overwritten as
/// blocks are decoded.
pub(all) struct Av1InterTileState {
  top : FixedArray[Av1InterNeighbor]
  left : FixedArray[Av1InterNeighbor]
}

///|
fn av1_inter_intra_neighbor() -> Av1InterNeighbor {
  { intra: true, comp_type: 0, ref0: -1, ref1: -1, filter0: 3, filter1: 3, }
}

///|
pub fn av1_inter_tile_state_new(w4 : Int, h4 : Int) -> Av1InterTileState {
  {
    top: FixedArray::makei(w4, _ => av1_inter_intra_neighbor()),
    left: FixedArray::makei(h4, _ => av1_inter_intra_neighbor()),
  }
}

///|
/// dav1d reset_context's inter edge defaults. Reset left at each tile SB
/// row while keeping the selected above bank from the preceding row.
pub fn Av1InterTileState::reset_left(self : Av1InterTileState, intra? : Bool = true) -> Unit {
  for i in 0..<self.left.length() {
    self.left[i] = { ..av1_inter_intra_neighbor(), intra }
  }
}

///|
/// Publish one decoded block using absolute 4x4 coordinates. The caller
/// selects the above-context bank; both edge offsets use dav1d's `& 31`.
pub fn Av1InterTileState::set_block(
  self : Av1InterTileState,
  bx4 : Int,
  by4 : Int,
  bw4 : Int,
  bh4 : Int,
  n : Av1InterNeighbor,
) -> Unit {
  let bx = bx4 & 31
  let by = by4 & 31
  for x in bx..<(bx + bw4) {
    self.top[x] = n
  }
  for y in by..<(by + bh4) {
    self.left[y] = n
  }
}

///|
/// dav1d `findoddzero` over the left/top intra contexts, used to gate OBMC.
pub fn Av1InterTileState::has_overlappable_neighbor(
  self : Av1InterTileState,
  bx4 : Int,
  by4 : Int,
  w4 : Int,
  h4 : Int,
  have_top : Bool,
  have_left : Bool,
) -> Bool {
  if have_left {
    for n in 0..<(h4 >> 1) {
      if !self.left[by4 + 1 + n * 2].intra {
        return true
      }
    }
  }
  if have_top {
    for n in 0..<(w4 >> 1) {
      if !self.top[bx4 + 1 + n * 2].intra {
        return true
      }
    }
  }
  false
}

///|
/// Inputs shared by every inter block in the tile.
pub(all) struct Av1InterBlockParams {
  bs : Int
  /// Absolute 4x4 position for refmvs lookups and publishing.
  bx4 : Int
  by4 : Int
  /// Within-SB (`& 31`) position for the a/l neighbour contexts.
  bx4_ctx : Int
  by4_ctx : Int
  w4 : Int
  h4 : Int
  tile_col_start4 : Int
  tile_col_end4 : Int
  tile_row_start4 : Int
  tile_row_end4 : Int
  top_has_right : Bool
  have_top : Bool
  have_left : Bool
  // skip mode and segment-forced references
  skip_mode : Bool
  skip_ref0 : Int
  skip_ref1 : Int
  seg_present : Bool
  seg_ref : Int
  seg_globalmv : Bool
  seg_skip : Bool
  // sequence/frame tools
  switchable_comp_refs : Bool
  inter_intra : Bool
  masked_compound : Bool
  jnt_comp : Bool
  dual_filter : Bool
  switchable_filter : Bool
  subpel_filter_mode : Int // dav1d filter mode 0..3
  switchable_motion_mode : Bool
  warp_motion : Bool
  order_hint_bits : Int
  cur_order_hint : Int
  ref_order_hint : FixedArray[Int] // 7
  ref_scaled : FixedArray[Bool] // 7
}

///|
/// Fully decoded inter block (before reconstruction).
pub(all) struct Av1InterBlock {
  bs : Int
  ref0 : Int
  ref1 : Int
  comp_type : Int
  wedge_idx : Int
  mode : Int
  drl_idx : Int
  mv0 : (Int, Int)
  mv1 : (Int, Int)
  interintra : Av1InterIntraSyntax
  motion_mode : Int
  warp : FixedArray[Int]?
  warp_type : Int
  warp_alpha : Int
  warp_beta : Int
  warp_gamma : Int
  warp_delta : Int
  mask0 : UInt64
  mask1 : UInt64
  find_ctx : Int
  filter0 : Int
  filter1 : Int
  filter2d : Int
  mask_sign : Int
  skip_mode : Bool
  has_subpel_filter : Bool
}

///|
/// Read one inter block: reference pairs and MVs (`av1_inter_read_block_motion`),
/// compound mask, inter-intra, motion variation (with `find_matching_ref`/
/// `derive_warpmv` for warp), subpel filters, then publish the block to the
/// refmvs state.
pub fn av1_inter_read_block(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  rstate : Av1RefmvsFrameState,
  nstate : Av1InterTileState,
  params : Av1InterBlockParams,
) -> Av1InterBlock {
  let bw4 = av1_block_dimensions[params.bs * 4].to_int()
  let bh4 = av1_block_dimensions[params.bs * 4 + 1].to_int()
  let top = if params.have_top {
    Some(nstate.top[params.bx4_ctx])
  } else {
    None
  }
  let left = if params.have_left {
    Some(nstate.left[params.by4_ctx])
  } else {
    None
  }
  // dav1d's mask/jnt/filter contexts read the a/l arrays unconditionally
  // (tile-edge entries are pre-reset to intra); only the reference trees
  // and the compound flag take have_top/have_left.
  let top_any = Some(nstate.top[params.bx4_ctx])
  let left_any = Some(nstate.left[params.by4_ctx])
  let motion = av1_inter_read_block_motion(
    msac, cdf, rstate, top, left,
    {
      bs: params.bs,
      bx4: params.bx4,
      by4: params.by4,
      tile_col_start4: params.tile_col_start4,
      tile_col_end4: params.tile_col_end4,
      tile_row_start4: params.tile_row_start4,
      tile_row_end4: params.tile_row_end4,
      top_has_right: params.top_has_right,
      switchable_comp_refs: params.switchable_comp_refs,
      skip_mode: params.skip_mode,
      skip_ref0: params.skip_ref0,
      skip_ref1: params.skip_ref1,
      seg_present: params.seg_present,
      seg_ref: params.seg_ref,
      seg_globalmv: params.seg_globalmv,
      seg_skip: params.seg_skip,
    },
  )
  let is_comp = motion.ref1 >= 0
  // compound mask (dav1d: skip mode is fixed average)
  let mut comp_type = 0
  let mut wedge_idx = 0
  let mut mask_sign = 0
  if params.skip_mode {
    comp_type = 2
  } else if is_comp {
    let mask = av1_inter_read_compound_mask(
      msac, cdf, params.masked_compound, params.jnt_comp, params.bs,
      av1_inter_mask_comp_ctx(
        nstate.top[params.bx4_ctx], nstate.left[params.by4_ctx],
      ),
      av1_inter_jnt_comp_ctx(
        params.order_hint_bits, params.cur_order_hint,
        params.ref_order_hint[motion.ref0], params.ref_order_hint[motion.ref1],
        nstate.top[params.bx4_ctx], nstate.left[params.by4_ctx],
      ),
    )
    comp_type = mask.comp_type
    wedge_idx = mask.wedge_idx
    mask_sign = mask.mask_sign
  }
  // Inter-intra and motion variation are only coded for single-reference
  // blocks (dav1d keeps them inside the single-ref `else` branch).
  let single = !is_comp
  let none_ii : Av1InterIntraSyntax = { kind: 0, mode: 0, wedge_idx: 0 }
  let ii = if single {
    av1_inter_read_interintra(msac, cdf, params.inter_intra, params.bs)
  } else {
    none_ii
  }
  // motion variation
  let min_wh = if bw4 < bh4 { bw4 } else { bh4 }
  let warped_global = !rstate.rf.force_integer_mv && motion.mode == 2 &&
    rstate.rf.gm_types[motion.ref0] > 1
  let mm_enabled = single && params.switchable_motion_mode && ii.kind == 0 &&
    min_wh >= 2 && !warped_global &&
    nstate.has_overlappable_neighbor(
      params.bx4_ctx, params.by4_ctx, params.w4, params.h4,
      params.have_top, params.have_left,
    )
  let mut motion_mode = 0
  let mut warp : FixedArray[Int]? = None
  let mut warp_type = 0
  let mut warp_alpha = 0
  let mut warp_beta = 0
  let mut warp_gamma = 0
  let mut warp_delta = 0
  let mut mask0 = 0UL
  let mut mask1 = 0UL
  let mut has_subpel = motion.has_subpel_filter
  if mm_enabled {
    let (masks0, masks1) = av1_inter_find_matching_ref(
      rstate.tile.rows, params.bx4, params.by4, bw4, bh4, params.w4,
      params.h4, params.have_left, params.have_top, params.top_has_right,
      params.tile_col_end4, motion.ref0,
    )
    mask0 = masks0
    mask1 = masks1
    let allow_warp = !params.ref_scaled[motion.ref0] &&
      !rstate.rf.force_integer_mv && params.warp_motion &&
      (masks0 | masks1) != 0UL
    motion_mode = av1_inter_read_motion_mode(
      msac, cdf, true, allow_warp, params.bs,
    )
    if motion_mode == 2 {
      has_subpel = false
      let w = av1_inter_derive_warpmv(
        rstate.tile.rows, params.bx4, params.by4, bw4, bh4, masks0, masks1,
        motion.mv0,
      )
      warp = Some(w.matrix)
      warp_type = w.typ
      warp_alpha = w.alpha
      warp_beta = w.beta
      warp_gamma = w.gamma
      warp_delta = w.delta
    }
  }
  // subpel filter
  let f0_ctx = av1_inter_filter_ctx(
    top_any, left_any, if is_comp { 1 } else { 0 }, 0, motion.ref0,
  )
  let f1_ctx = av1_inter_filter_ctx(
    top_any, left_any, if is_comp { 1 } else { 0 }, 1, motion.ref0,
  )
  let filters = av1_inter_read_filter(
    msac, cdf, params.switchable_filter, has_subpel, params.dual_filter,
    params.subpel_filter_mode, f0_ctx, f1_ctx,
  )
  // publish
  if is_comp {
    rstate.splat_compound(
      motion.ref0, motion.ref1, motion.mode, motion.mv0, motion.mv1,
      params.bs, params.bx4, params.by4, bw4, bh4,
    )
  } else {
    rstate.splat_single(
      motion.ref0, motion.mode, motion.mv0, ii.kind != 0, params.bs,
      params.bx4, params.by4, bw4, bh4,
    )
  }
  {
    bs: params.bs,
    ref0: motion.ref0,
    ref1: motion.ref1,
    comp_type,
    wedge_idx,
    mode: motion.mode,
    drl_idx: motion.drl_idx,
    mv0: motion.mv0,
    mv1: motion.mv1,
    interintra: ii,
    motion_mode,
    warp,
    warp_type,
    warp_alpha,
    warp_beta,
    warp_gamma,
    warp_delta,
    mask0,
    mask1,
    find_ctx: motion.find_ctx,
    filter0: filters.filter0,
    filter1: filters.filter1,
    filter2d: filters.filter2d,
    mask_sign,
    skip_mode: params.skip_mode,
    has_subpel_filter: has_subpel,
  }
}
