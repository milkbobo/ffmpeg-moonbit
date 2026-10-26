///|
/// Inputs available after skip-mode and segmentation syntax in decode_b.
/// References use dav1d's 0..6 indices; `forced_ref` is -1 when unset.
pub(all) struct Av1InterMotionParams {
  bs : Int
  bx4 : Int
  by4 : Int
  tile_col_start4 : Int
  tile_col_end4 : Int
  tile_row_start4 : Int
  tile_row_end4 : Int
  top_has_right : Bool
  switchable_comp_refs : Bool
  skip_mode : Bool
  skip_ref0 : Int
  skip_ref1 : Int
  forced_ref : Int
  force_global : Bool
}

///|
/// Motion syntax output before compound masking, interpolation filters,
/// transform decoding, and pixel reconstruction.
pub(all) struct Av1InterMotion {
  ref0 : Int
  ref1 : Int
  mode : Int
  drl_idx : Int
  mv0 : (Int, Int)
  mv1 : (Int, Int)
  has_subpel_filter : Bool
  skip_mode : Bool
}

///|
/// Reference selection and MV coding from dav1d's inter `decode_b` branch.
/// The caller publishes the block to refmvs after reading the remaining
/// inter syntax, because inter-intra prediction changes its second ref.
pub fn av1_inter_read_block_motion(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  state : Av1RefmvsFrameState,
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
  params : Av1InterMotionParams,
) -> Av1InterMotion {
  let bw4 = av1_block_dimensions[params.bs * 4].to_int()
  let bh4 = av1_block_dimensions[params.bs * 4 + 1].to_int()
  let is_comp = if params.skip_mode {
    true
  } else if params.switchable_comp_refs && params.forced_ref < 0 &&
    !params.force_global && bw4 > 1 && bh4 > 1 {
    msac.decode_bool_adapt(
      cdf.comp, av1_inter_comp_ctx(top, left) * 2,
    ) != 0
  } else {
    false
  }
  let (ref0, ref1) = if params.skip_mode {
    (params.skip_ref0, params.skip_ref1)
  } else if is_comp {
    av1_inter_read_refs(msac, cdf, top, left, true)
  } else if params.forced_ref >= 0 {
    (params.forced_ref, -1)
  } else if params.force_global {
    (0, -1)
  } else {
    av1_inter_read_refs(msac, cdf, top, left, false)
  }
  let stack = state.find(
    params.tile_col_start4, params.tile_col_end4,
    params.tile_row_start4, params.tile_row_end4,
    ref0 + 1, if is_comp { ref1 + 1 } else { -1 },
    params.bs, params.top_has_right, params.by4, params.bx4,
  )
  if params.skip_mode {
    return {
      ref0, ref1, mode: 0, drl_idx: 0,
      mv0: av1_rmv_fix_precision(
        stack.cands[0].mv0, state.rf.force_integer_mv, state.rf.hp,
      ),
      mv1: av1_rmv_fix_precision(
        stack.cands[0].mv1, state.rf.force_integer_mv, state.rf.hp,
      ),
      has_subpel_filter: false, skip_mode: true,
    }
  }
  if is_comp {
    let mv = av1_inter_read_compound_mv(
      msac, cdf, state.rf, stack, ref0, ref1,
      params.bs, params.by4, params.bx4,
    )
    return {
      ref0, ref1, mode: mv.mode, drl_idx: mv.drl_idx,
      mv0: mv.mv0, mv1: mv.mv1,
      has_subpel_filter: mv.has_subpel_filter, skip_mode: false,
    }
  }
  let mv = av1_inter_read_single_mv(
    msac, cdf, state.rf, stack, ref0,
    params.bs, params.by4, params.bx4, params.force_global,
  )
  {
    ref0, ref1: -1, mode: mv.mode, drl_idx: mv.drl_idx,
    mv0: mv.mv, mv1: (0, 0),
    has_subpel_filter: mv.has_subpel_filter, skip_mode: false,
  }
}
