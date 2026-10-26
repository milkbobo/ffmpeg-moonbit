///|
/// Inter-block syntax after reference/mode/MV selection: compound masking,
/// inter-intra, motion variation and subpel filter selection. Ports the
/// corresponding blocks of dav1d 1.5.1 `decode_b` together with the
/// `dav1d_wedge_ctx_lut`, `dav1d_filter_2d` and allowed-size tables.

///|
/// `dav1d_wedge_ctx_lut`: wedge CDF context per block size (0 elsewhere).
let av1_wedge_ctx_lut : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 6, 5, 8, 0, 4, 3, 2, 0, 7, 1, 0, 0, 0, 0, 0,
]

///|
/// `dav1d_filter_2d[filter1][filter0]` flattened. `Dav1dFilterMode` is
/// REGULAR=0, SMOOTH=1, SHARP=2, BILINEAR=3; values are dav1d `Filter2d`
/// (0..8 = 8-tap combinations, 9 = bilinear).
let av1_filter_2d : FixedArray[Int] = [
  0, 1, 2, 0,
  6, 7, 8, 0,
  3, 4, 5, 0,
  0, 0, 0, 9,
]

///|
/// `wedge_allowed_mask`: 32x32, 32x16, 32x8, 16x32, 16x16, 16x8, 8x32,
/// 8x16 and 8x8.
pub fn av1_inter_wedge_allowed(bs : Int) -> Bool {
  match bs {
    7 | 8 | 9 | 11 | 12 | 13 | 15 | 16 | 17 => true
    _ => false
  }
}

///|
/// `interintra_allowed_mask`: wedge sizes minus 32x8 and 8x32.
pub fn av1_interintra_allowed(bs : Int) -> Bool {
  match bs {
    7 | 8 | 11 | 12 | 13 | 16 | 17 => true
    _ => false
  }
}

///|
/// Result of the masked-compound decision. `comp_type` uses dav1d's
/// `CompInterType` (1 weighted, 2 average, 3 segment, 4 wedge); 0 means
/// no compound. `mask_sign` is only read for segment/wedge.
pub(all) struct Av1InterCompoundSyntax {
  comp_type : Int
  wedge_idx : Int
  mask_sign : Int
}

///|
/// `interintra` / `interintra_mode` / `interintra_wedge` / `wedge_idx`.
/// `kind` is dav1d `InterIntraType` (0 none, 1 blend, 2 wedge).
pub(all) struct Av1InterIntraSyntax {
  kind : Int
  mode : Int
  wedge_idx : Int
}

///|
/// Subpel filter pair plus the combined `Filter2d` index.
pub(all) struct Av1InterFilterSyntax {
  filter0 : Int
  filter1 : Int
  filter2d : Int
}

///|
/// Read the compound mask type after both MVs (`is_segwedge`, `jnt_comp`,
/// `wedge_comp`, `wedge_idx` and the equi-probable mask sign).
pub fn av1_inter_read_compound_mask(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  masked_compound : Bool,
  jnt_comp : Bool,
  bs : Int,
  mask_ctx : Int,
  jnt_ctx : Int,
) -> Av1InterCompoundSyntax {
  let mut wedge_idx = 0
  let mut mask_sign = 0
  let mut is_segwedge = false
  if masked_compound {
    is_segwedge = msac.decode_bool_adapt(cdf.mask_comp, mask_ctx * 2) != 0
  }
  let comp_type = if !is_segwedge {
    if jnt_comp {
      1 + msac.decode_bool_adapt(cdf.jnt_comp, jnt_ctx * 2).reinterpret_as_int()
    } else {
      2
    }
  } else {
    let comp = if av1_inter_wedge_allowed(bs) {
      let ctx = av1_wedge_ctx_lut[bs]
      let c = 4 - msac.decode_bool_adapt(cdf.wedge_comp, ctx * 2).reinterpret_as_int()
      if c == 4 {
        wedge_idx = msac.decode_symbol_adapt(cdf.wedge_idx, ctx * 16, 15)
      }
      c
    } else {
      3
    }
    mask_sign = msac.decode_bool_equi().reinterpret_as_int()
    comp
  }
  { comp_type, wedge_idx, mask_sign }
}

///|
/// Read inter-intra flags after the inter mode/MV. `inter_intra` is the
/// sequence-header tool flag; the size gate comes from `interintra_allowed`.
pub fn av1_inter_read_interintra(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  inter_intra : Bool,
  bs : Int,
) -> Av1InterIntraSyntax {
  let none : Av1InterIntraSyntax = { kind: 0, mode: 0, wedge_idx: 0 }
  if !inter_intra || !av1_interintra_allowed(bs) {
    return none
  }
  let grp = av1_ymode_size_context[bs].to_int()
  if msac.decode_bool_adapt(cdf.interintra, grp * 2) == 0 {
    return none
  }
  let mode = msac.decode_symbol_adapt(cdf.interintra_mode, grp * 4, 3)
  let wedge_ctx = av1_wedge_ctx_lut[bs]
  let kind = 1 +
    msac.decode_bool_adapt(cdf.interintra_wedge, wedge_ctx * 2).reinterpret_as_int()
  let mut wedge_idx = 0
  if kind == 2 {
    wedge_idx = msac.decode_symbol_adapt(cdf.wedge_idx, wedge_ctx * 16, 15)
  }
  { kind, mode, wedge_idx }
}

///|
/// Read motion variation when the block allows OBMC. `enabled` mirrors
/// dav1d's condition (`switchable_motion_mode`, no inter-intra, at least
/// 2x2 units, no warped global MV, an overlappable neighbour). `allow_warp`
/// bundles the warped-motion and scaled-reference checks.
pub fn av1_inter_read_motion_mode(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  enabled : Bool,
  allow_warp : Bool,
  bs : Int,
) -> Int {
  if !enabled {
    return 0
  }
  if allow_warp {
    msac.decode_symbol_adapt(cdf.motion_mode, bs * 4, 2)
  } else {
    msac.decode_bool_adapt(cdf.obmc, bs * 2).reinterpret_as_int()
  }
}

///|
/// Read the switchable subpel filter pair. `subpel_mode` is the frame
/// header's fixed filter when the tool is not switchable; `ctx0`/`ctx1` are
/// `get_filter_ctx` results for horizontal/vertical.
pub fn av1_inter_read_filter(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  switchable : Bool,
  has_subpel_filter : Bool,
  dual_filter : Bool,
  subpel_mode : Int,
  ctx0 : Int,
  ctx1 : Int,
) -> Av1InterFilterSyntax {
  let filter0 = if !switchable {
    subpel_mode
  } else if has_subpel_filter {
    msac.decode_symbol_adapt(cdf.filter, ctx0 * 4, 2)
  } else {
    0
  }
  let filter1 = if !switchable {
    subpel_mode
  } else if has_subpel_filter {
    if dual_filter {
      msac.decode_symbol_adapt(cdf.filter, (8 + ctx1) * 4, 2)
    } else {
      filter0
    }
  } else {
    0
  }
  { filter0, filter1, filter2d: av1_filter_2d[filter1 * 4 + filter0] }
}

///|
/// Combine a horizontal/vertical switchable filter pair into dav1d `Filter2d`
/// (neighbour blocks store the two filter modes separately).
pub fn av1_inter_filter2d(filter0 : Int, filter1 : Int) -> Int {
  av1_filter_2d[filter1 * 4 + filter0]
}
