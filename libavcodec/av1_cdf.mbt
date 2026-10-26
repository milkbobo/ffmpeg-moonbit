///|
/// Per-frame working CDF context mirroring dav1d's `CdfContext` (src/cdf.h):
/// one flat `FixedArray[UInt16]` per field, dims and strides identical to
/// upstream (including SIMD padding slots). `av1_cdf_copy_defaults` is
/// `dav1d_cdf_thread_init_static` + `dav1d_cdf_thread_copy`: mode CDFs come
/// from `default_cdf`, coefficient CDFs from `default_coef_cdf[qcat]` with
/// qcat = (qidx > 20) + (qidx > 60) + (qidx > 120).

///|
pub struct Av1CdfCtx {
  // CdfCoefContext: [2][2][8] etc., strides in comments at each field.
  eob_bin_16 : FixedArray[UInt16] // [2][2][8]
  eob_bin_32 : FixedArray[UInt16] // [2][2][8]
  eob_bin_64 : FixedArray[UInt16] // [2][2][8]
  eob_bin_128 : FixedArray[UInt16] // [2][2][8]
  eob_bin_256 : FixedArray[UInt16] // [2][2][16]
  eob_bin_512 : FixedArray[UInt16] // [2][16]
  eob_bin_1024 : FixedArray[UInt16] // [2][16]
  eob_base_tok : FixedArray[UInt16] // [5][2][4][4]
  base_tok : FixedArray[UInt16] // [5][2][41][4]
  br_tok : FixedArray[UInt16] // [4][2][21][4]
  eob_hi_bit : FixedArray[UInt16] // [5][2][11][2]
  coef_skip : FixedArray[UInt16] // [5][13][2]
  dc_sign : FixedArray[UInt16] // [2][3][2]
  // CdfModeContext (keyframe-relevant subset first, then inter fields kept
  // for parity with upstream so future inter work reuses the same struct).
  uv_mode : FixedArray[UInt16] // [2][13][16]
  partition : FixedArray[UInt16] // [5][4][16]
  cfl_alpha : FixedArray[UInt16] // [6][16]
  txtp_inter1 : FixedArray[UInt16] // [2][16]
  txtp_inter2 : FixedArray[UInt16] // [16]
  txtp_intra1 : FixedArray[UInt16] // [2][13][8]
  txtp_intra2 : FixedArray[UInt16] // [3][13][8]
  cfl_sign : FixedArray[UInt16] // [8]
  angle_delta : FixedArray[UInt16] // [8][8]
  filter_intra : FixedArray[UInt16] // [8]
  seg_id : FixedArray[UInt16] // [3][8]
  pal_sz : FixedArray[UInt16] // [2][7][8]
  color_map : FixedArray[UInt16] // [2][7][5][8]
  txsz : FixedArray[UInt16] // [4][3][4]
  delta_q : FixedArray[UInt16] // [4]
  delta_lf : FixedArray[UInt16] // [5][4]
  restore_switchable : FixedArray[UInt16] // [4]
  restore_wiener : FixedArray[UInt16] // [2]
  restore_sgrproj : FixedArray[UInt16] // [2]
  txtp_inter3 : FixedArray[UInt16] // [4][2]
  use_filter_intra : FixedArray[UInt16] // [22][2]
  txpart : FixedArray[UInt16] // [7][3][2]
  skip : FixedArray[UInt16] // [3][2]
  pal_y : FixedArray[UInt16] // [7][3][2]
  pal_uv : FixedArray[UInt16] // [2][2]
  intrabc : FixedArray[UInt16] // [2]
  y_mode : FixedArray[UInt16] // [4][16]
  wedge_idx : FixedArray[UInt16] // [9][16]
  comp_inter_mode : FixedArray[UInt16] // [8][8]
  filter : FixedArray[UInt16] // [2][8][4]
  interintra_mode : FixedArray[UInt16] // [4][4]
  motion_mode : FixedArray[UInt16] // [22][4]
  skip_mode : FixedArray[UInt16] // [3][2]
  newmv_mode : FixedArray[UInt16] // [6][2]
  globalmv_mode : FixedArray[UInt16] // [2][2]
  refmv_mode : FixedArray[UInt16] // [6][2]
  drl_bit : FixedArray[UInt16] // [3][2]
  intra : FixedArray[UInt16] // [4][2]
  comp : FixedArray[UInt16] // [5][2]
  comp_dir : FixedArray[UInt16] // [5][2]
  jnt_comp : FixedArray[UInt16] // [6][2]
  mask_comp : FixedArray[UInt16] // [6][2]
  wedge_comp : FixedArray[UInt16] // [9][2]
  ref_ : FixedArray[UInt16] // [6][3][2]
  comp_fwd_ref : FixedArray[UInt16] // [3][3][2]
  comp_bwd_ref : FixedArray[UInt16] // [2][3][2]
  comp_uni_ref : FixedArray[UInt16] // [3][3][2]
  seg_pred : FixedArray[UInt16] // [3][2]
  interintra : FixedArray[UInt16] // [7][2]
  interintra_wedge : FixedArray[UInt16] // [7][2]
  obmc : FixedArray[UInt16] // [22][2]
  // CdfMvContext: both components share the default table (comp[1] is
  // initialised from the same default per dav1d_cdf_thread_copy).
  mv0_classes : FixedArray[UInt16] // [16]
  mv0_sign : FixedArray[UInt16] // [2]
  mv0_class0 : FixedArray[UInt16] // [2]
  mv0_class0_fp : FixedArray[UInt16] // [2][4]
  mv0_class0_hp : FixedArray[UInt16] // [2]
  mv0_classN : FixedArray[UInt16] // [10][2]
  mv0_classN_fp : FixedArray[UInt16] // [4]
  mv0_classN_hp : FixedArray[UInt16] // [2]
  mv1_classes : FixedArray[UInt16] // [16]
  mv1_sign : FixedArray[UInt16] // [2]
  mv1_class0 : FixedArray[UInt16] // [2]
  mv1_class0_fp : FixedArray[UInt16] // [2][4]
  mv1_class0_hp : FixedArray[UInt16] // [2]
  mv1_classN : FixedArray[UInt16] // [10][2]
  mv1_classN_fp : FixedArray[UInt16] // [4]
  mv1_classN_hp : FixedArray[UInt16] // [2]
  joint : FixedArray[UInt16] // [4]
  kfym : FixedArray[UInt16] // [5][5][16]
}

///|
fn cdf_copy(src : FixedArray[UInt16]) -> FixedArray[UInt16] {
  src.copy()
}

///|
/// `dav1d_cdf_thread_copy` with `dav1d_cdf_thread_init_static`'s qcat rule.
pub fn av1_cdf_copy_defaults(qidx : Int32) -> Av1CdfCtx {
  let qcat = (if qidx > 120 { 1 } else { 0 }) +
    (if qidx > 60 { 1 } else { 0 }) +
    (if qidx > 20 { 1 } else { 0 })
  let coef = qcat
  let _ = coef
  let c : Av1CdfCtx = {
    eob_bin_16: qsel(
      qidx, av1_cdf_coef0_eob_bin_16, av1_cdf_coef1_eob_bin_16, av1_cdf_coef2_eob_bin_16,
      av1_cdf_coef3_eob_bin_16,
    ).copy(),
    eob_bin_32: qsel(
      qidx, av1_cdf_coef0_eob_bin_32, av1_cdf_coef1_eob_bin_32, av1_cdf_coef2_eob_bin_32,
      av1_cdf_coef3_eob_bin_32,
    ).copy(),
    eob_bin_64: qsel(
      qidx, av1_cdf_coef0_eob_bin_64, av1_cdf_coef1_eob_bin_64, av1_cdf_coef2_eob_bin_64,
      av1_cdf_coef3_eob_bin_64,
    ).copy(),
    eob_bin_128: qsel(
      qidx, av1_cdf_coef0_eob_bin_128, av1_cdf_coef1_eob_bin_128, av1_cdf_coef2_eob_bin_128,
      av1_cdf_coef3_eob_bin_128,
    ).copy(),
    eob_bin_256: qsel(
      qidx, av1_cdf_coef0_eob_bin_256, av1_cdf_coef1_eob_bin_256, av1_cdf_coef2_eob_bin_256,
      av1_cdf_coef3_eob_bin_256,
    ).copy(),
    eob_bin_512: qsel(
      qidx, av1_cdf_coef0_eob_bin_512, av1_cdf_coef1_eob_bin_512, av1_cdf_coef2_eob_bin_512,
      av1_cdf_coef3_eob_bin_512,
    ).copy(),
    eob_bin_1024: qsel(
      qidx, av1_cdf_coef0_eob_bin_1024, av1_cdf_coef1_eob_bin_1024, av1_cdf_coef2_eob_bin_1024,
      av1_cdf_coef3_eob_bin_1024,
    ).copy(),
    eob_base_tok: qsel(
      qidx, av1_cdf_coef0_eob_base_tok, av1_cdf_coef1_eob_base_tok, av1_cdf_coef2_eob_base_tok,
      av1_cdf_coef3_eob_base_tok,
    ).copy(),
    base_tok: qsel(
      qidx, av1_cdf_coef0_base_tok, av1_cdf_coef1_base_tok, av1_cdf_coef2_base_tok,
      av1_cdf_coef3_base_tok,
    ).copy(),
    br_tok: qsel(
      qidx, av1_cdf_coef0_br_tok, av1_cdf_coef1_br_tok, av1_cdf_coef2_br_tok, av1_cdf_coef3_br_tok,
    ).copy(),
    eob_hi_bit: qsel(
      qidx, av1_cdf_coef0_eob_hi_bit, av1_cdf_coef1_eob_hi_bit, av1_cdf_coef2_eob_hi_bit,
      av1_cdf_coef3_eob_hi_bit,
    ).copy(),
    coef_skip: qsel(
      qidx, av1_cdf_coef0_skip, av1_cdf_coef1_skip, av1_cdf_coef2_skip, av1_cdf_coef3_skip,
    ).copy(),
    dc_sign: qsel(
      qidx, av1_cdf_coef0_dc_sign, av1_cdf_coef1_dc_sign, av1_cdf_coef2_dc_sign,
      av1_cdf_coef3_dc_sign,
    ).copy(),
    uv_mode: av1_cdf_uv_mode.copy(),
    partition: av1_cdf_partition.copy(),
    cfl_alpha: av1_cdf_cfl_alpha.copy(),
    txtp_inter1: av1_cdf_txtp_inter1.copy(),
    txtp_inter2: av1_cdf_txtp_inter2.copy(),
    txtp_intra1: av1_cdf_txtp_intra1.copy(),
    txtp_intra2: av1_cdf_txtp_intra2.copy(),
    cfl_sign: av1_cdf_cfl_sign.copy(),
    angle_delta: av1_cdf_angle_delta.copy(),
    filter_intra: av1_cdf_filter_intra.copy(),
    seg_id: av1_cdf_seg_id.copy(),
    pal_sz: av1_cdf_pal_sz.copy(),
    color_map: av1_cdf_color_map.copy(),
    txsz: av1_cdf_txsz.copy(),
    delta_q: av1_cdf_delta_q.copy(),
    delta_lf: av1_cdf_delta_lf.copy(),
    restore_switchable: av1_cdf_restore_switchable.copy(),
    restore_wiener: av1_cdf_restore_wiener.copy(),
    restore_sgrproj: av1_cdf_restore_sgrproj.copy(),
    txtp_inter3: av1_cdf_txtp_inter3.copy(),
    use_filter_intra: av1_cdf_use_filter_intra.copy(),
    txpart: av1_cdf_txpart.copy(),
    skip: av1_cdf_skip.copy(),
    pal_y: av1_cdf_pal_y.copy(),
    pal_uv: av1_cdf_pal_uv.copy(),
    intrabc: av1_cdf_intrabc.copy(),
    y_mode: av1_cdf_y_mode.copy(),
    wedge_idx: av1_cdf_wedge_idx.copy(),
    comp_inter_mode: av1_cdf_comp_inter_mode.copy(),
    filter: av1_cdf_filter.copy(),
    interintra_mode: av1_cdf_interintra_mode.copy(),
    motion_mode: av1_cdf_motion_mode.copy(),
    skip_mode: av1_cdf_skip_mode.copy(),
    newmv_mode: av1_cdf_newmv_mode.copy(),
    globalmv_mode: av1_cdf_globalmv_mode.copy(),
    refmv_mode: av1_cdf_refmv_mode.copy(),
    drl_bit: av1_cdf_drl_bit.copy(),
    intra: av1_cdf_intra.copy(),
    comp: av1_cdf_comp.copy(),
    comp_dir: av1_cdf_comp_dir.copy(),
    jnt_comp: av1_cdf_jnt_comp.copy(),
    mask_comp: av1_cdf_mask_comp.copy(),
    wedge_comp: av1_cdf_wedge_comp.copy(),
    ref_: av1_cdf_ref.copy(),
    comp_fwd_ref: av1_cdf_comp_fwd_ref.copy(),
    comp_bwd_ref: av1_cdf_comp_bwd_ref.copy(),
    comp_uni_ref: av1_cdf_comp_uni_ref.copy(),
    seg_pred: av1_cdf_seg_pred.copy(),
    interintra: av1_cdf_interintra.copy(),
    interintra_wedge: av1_cdf_interintra_wedge.copy(),
    obmc: av1_cdf_obmc.copy(),
    mv0_classes: av1_cdf_mv0_classes.copy(),
    mv0_sign: av1_cdf_mv0_sign.copy(),
    mv0_class0: av1_cdf_mv0_class0.copy(),
    mv0_class0_fp: av1_cdf_mv0_class0_fp.copy(),
    mv0_class0_hp: av1_cdf_mv0_class0_hp.copy(),
    mv0_classN: av1_cdf_mv0_classN.copy(),
    mv0_classN_fp: av1_cdf_mv0_classN_fp.copy(),
    mv0_classN_hp: av1_cdf_mv0_classN_hp.copy(),
    mv1_classes: av1_cdf_mv1_classes.copy(),
    mv1_sign: av1_cdf_mv1_sign.copy(),
    mv1_class0: av1_cdf_mv1_class0.copy(),
    mv1_class0_fp: av1_cdf_mv1_class0_fp.copy(),
    mv1_class0_hp: av1_cdf_mv1_class0_hp.copy(),
    mv1_classN: av1_cdf_mv1_classN.copy(),
    mv1_classN_fp: av1_cdf_mv1_classN_fp.copy(),
    mv1_classN_hp: av1_cdf_mv1_classN_hp.copy(),
    joint: av1_cdf_joint.copy(),
    kfym: av1_cdf_kfym.copy(),
  }
  ignore(cdf_copy)
  c
}

///|
fn qsel(
  qidx : Int32,
  a : FixedArray[UInt16],
  b : FixedArray[UInt16],
  c : FixedArray[UInt16],
  d : FixedArray[UInt16],
) -> FixedArray[UInt16] {
  if qidx <= 20 {
    a
  } else if qidx <= 60 {
    b
  } else if qidx <= 120 {
    c
  } else {
    d
  }
}
