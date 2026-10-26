///|
/// Exact counter offsets and retained padding from dav1d 1.5.1
/// dav1d_cdf_thread_update on independent deterministic input arrays.
/// Regenerate with scripts/emit_av1_cdf_reference_vectors.mbtx.
test "reference CDF counts match dav1d" {
  let source = @libavcodec.av1_cdf_copy_defaults(80)
  for j in 0..<source.eob_bin_16.length() {
    source.eob_bin_16[j] = ((j * 17 + 0 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_bin_32.length() {
    source.eob_bin_32[j] = ((j * 17 + 1 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_bin_64.length() {
    source.eob_bin_64[j] = ((j * 17 + 2 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_bin_128.length() {
    source.eob_bin_128[j] = ((j * 17 + 3 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_bin_256.length() {
    source.eob_bin_256[j] = ((j * 17 + 4 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_bin_512.length() {
    source.eob_bin_512[j] = ((j * 17 + 5 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_bin_1024.length() {
    source.eob_bin_1024[j] = ((j * 17 + 6 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_base_tok.length() {
    source.eob_base_tok[j] = ((j * 17 + 7 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.base_tok.length() {
    source.base_tok[j] = ((j * 17 + 8 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.br_tok.length() {
    source.br_tok[j] = ((j * 17 + 9 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.eob_hi_bit.length() {
    source.eob_hi_bit[j] = ((j * 17 + 10 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.coef_skip.length() {
    source.coef_skip[j] = ((j * 17 + 11 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.dc_sign.length() {
    source.dc_sign[j] = ((j * 17 + 12 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.uv_mode.length() {
    source.uv_mode[j] = ((j * 17 + 13 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.partition.length() {
    source.partition[j] = ((j * 17 + 14 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.cfl_alpha.length() {
    source.cfl_alpha[j] = ((j * 17 + 15 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txtp_inter1.length() {
    source.txtp_inter1[j] = ((j * 17 + 16 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txtp_inter2.length() {
    source.txtp_inter2[j] = ((j * 17 + 17 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txtp_intra1.length() {
    source.txtp_intra1[j] = ((j * 17 + 18 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txtp_intra2.length() {
    source.txtp_intra2[j] = ((j * 17 + 19 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.cfl_sign.length() {
    source.cfl_sign[j] = ((j * 17 + 20 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.angle_delta.length() {
    source.angle_delta[j] = ((j * 17 + 21 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.filter_intra.length() {
    source.filter_intra[j] = ((j * 17 + 22 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.seg_id.length() {
    source.seg_id[j] = ((j * 17 + 23 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.pal_sz.length() {
    source.pal_sz[j] = ((j * 17 + 24 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.color_map.length() {
    source.color_map[j] = ((j * 17 + 25 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txsz.length() {
    source.txsz[j] = ((j * 17 + 26 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.delta_q.length() {
    source.delta_q[j] = ((j * 17 + 27 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.delta_lf.length() {
    source.delta_lf[j] = ((j * 17 + 28 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.restore_switchable.length() {
    source.restore_switchable[j] = ((j * 17 + 29 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.restore_wiener.length() {
    source.restore_wiener[j] = ((j * 17 + 30 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.restore_sgrproj.length() {
    source.restore_sgrproj[j] = ((j * 17 + 31 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txtp_inter3.length() {
    source.txtp_inter3[j] = ((j * 17 + 32 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.use_filter_intra.length() {
    source.use_filter_intra[j] = ((j * 17 + 33 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.txpart.length() {
    source.txpart[j] = ((j * 17 + 34 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.skip.length() {
    source.skip[j] = ((j * 17 + 35 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.pal_y.length() {
    source.pal_y[j] = ((j * 17 + 36 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.pal_uv.length() {
    source.pal_uv[j] = ((j * 17 + 37 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.intrabc.length() {
    source.intrabc[j] = ((j * 17 + 38 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.y_mode.length() {
    source.y_mode[j] = ((j * 17 + 39 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.wedge_idx.length() {
    source.wedge_idx[j] = ((j * 17 + 40 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.comp_inter_mode.length() {
    source.comp_inter_mode[j] = ((j * 17 + 41 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.filter.length() {
    source.filter[j] = ((j * 17 + 42 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.interintra_mode.length() {
    source.interintra_mode[j] = ((j * 17 + 43 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.motion_mode.length() {
    source.motion_mode[j] = ((j * 17 + 44 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.skip_mode.length() {
    source.skip_mode[j] = ((j * 17 + 45 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.newmv_mode.length() {
    source.newmv_mode[j] = ((j * 17 + 46 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.globalmv_mode.length() {
    source.globalmv_mode[j] = ((j * 17 + 47 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.refmv_mode.length() {
    source.refmv_mode[j] = ((j * 17 + 48 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.drl_bit.length() {
    source.drl_bit[j] = ((j * 17 + 49 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.intra.length() {
    source.intra[j] = ((j * 17 + 50 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.comp.length() {
    source.comp[j] = ((j * 17 + 51 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.comp_dir.length() {
    source.comp_dir[j] = ((j * 17 + 52 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.jnt_comp.length() {
    source.jnt_comp[j] = ((j * 17 + 53 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mask_comp.length() {
    source.mask_comp[j] = ((j * 17 + 54 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.wedge_comp.length() {
    source.wedge_comp[j] = ((j * 17 + 55 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.ref_.length() {
    source.ref_[j] = ((j * 17 + 56 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.comp_fwd_ref.length() {
    source.comp_fwd_ref[j] = ((j * 17 + 57 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.comp_bwd_ref.length() {
    source.comp_bwd_ref[j] = ((j * 17 + 58 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.comp_uni_ref.length() {
    source.comp_uni_ref[j] = ((j * 17 + 59 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.seg_pred.length() {
    source.seg_pred[j] = ((j * 17 + 60 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.interintra.length() {
    source.interintra[j] = ((j * 17 + 61 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.interintra_wedge.length() {
    source.interintra_wedge[j] = ((j * 17 + 62 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.obmc.length() {
    source.obmc[j] = ((j * 17 + 63 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_classes.length() {
    source.mv0_classes[j] = ((j * 17 + 64 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_sign.length() {
    source.mv0_sign[j] = ((j * 17 + 65 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_class0.length() {
    source.mv0_class0[j] = ((j * 17 + 66 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_class0_fp.length() {
    source.mv0_class0_fp[j] = ((j * 17 + 67 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_class0_hp.length() {
    source.mv0_class0_hp[j] = ((j * 17 + 68 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_classN.length() {
    source.mv0_classN[j] = ((j * 17 + 69 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_classN_fp.length() {
    source.mv0_classN_fp[j] = ((j * 17 + 70 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv0_classN_hp.length() {
    source.mv0_classN_hp[j] = ((j * 17 + 71 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_classes.length() {
    source.mv1_classes[j] = ((j * 17 + 72 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_sign.length() {
    source.mv1_sign[j] = ((j * 17 + 73 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_class0.length() {
    source.mv1_class0[j] = ((j * 17 + 74 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_class0_fp.length() {
    source.mv1_class0_fp[j] = ((j * 17 + 75 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_class0_hp.length() {
    source.mv1_class0_hp[j] = ((j * 17 + 76 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_classN.length() {
    source.mv1_classN[j] = ((j * 17 + 77 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_classN_fp.length() {
    source.mv1_classN_fp[j] = ((j * 17 + 78 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.mv1_classN_hp.length() {
    source.mv1_classN_hp[j] = ((j * 17 + 79 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.joint.length() {
    source.joint[j] = ((j * 17 + 80 * 101) % 30000).to_uint16()
  }
  for j in 0..<source.kfym.length() {
    source.kfym[j] = ((j * 17 + 81 * 101) % 30000).to_uint16()
  }
  let result = source.for_reference()
  assert_eq(result.eob_bin_16.length(), 32)
  {
    let mut hash = 0L
    for value in result.eob_bin_16 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 345762351L, msg="eob_bin_16")
  }
  assert_eq(result.eob_bin_32.length(), 32)
  {
    let mut hash = 0L
    for value in result.eob_bin_32 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 413017660L, msg="eob_bin_32")
  }
  assert_eq(result.eob_bin_64.length(), 32)
  {
    let mut hash = 0L
    for value in result.eob_bin_64 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 154777449L, msg="eob_bin_64")
  }
  assert_eq(result.eob_bin_128.length(), 32)
  {
    let mut hash = 0L
    for value in result.eob_bin_128 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 280066019L, msg="eob_bin_128")
  }
  assert_eq(result.eob_bin_256.length(), 64)
  {
    let mut hash = 0L
    for value in result.eob_bin_256 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 958069885L, msg="eob_bin_256")
  }
  assert_eq(result.eob_bin_512.length(), 32)
  {
    let mut hash = 0L
    for value in result.eob_bin_512 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 37782798L, msg="eob_bin_512")
  }
  assert_eq(result.eob_bin_1024.length(), 32)
  {
    let mut hash = 0L
    for value in result.eob_bin_1024 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 142340139L, msg="eob_bin_1024")
  }
  assert_eq(result.eob_base_tok.length(), 160)
  {
    let mut hash = 0L
    for value in result.eob_base_tok {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 437828637L, msg="eob_base_tok")
  }
  assert_eq(result.base_tok.length(), 1640)
  {
    let mut hash = 0L
    for value in result.base_tok {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 921508219L, msg="base_tok")
  }
  assert_eq(result.br_tok.length(), 672)
  {
    let mut hash = 0L
    for value in result.br_tok {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 93362746L, msg="br_tok")
  }
  assert_eq(result.eob_hi_bit.length(), 220)
  {
    let mut hash = 0L
    for value in result.eob_hi_bit {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 488579110L, msg="eob_hi_bit")
  }
  assert_eq(result.coef_skip.length(), 130)
  {
    let mut hash = 0L
    for value in result.coef_skip {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 229217372L, msg="coef_skip")
  }
  assert_eq(result.dc_sign.length(), 12)
  {
    let mut hash = 0L
    for value in result.dc_sign {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 663449207L, msg="dc_sign")
  }
  assert_eq(result.uv_mode.length(), 416)
  {
    let mut hash = 0L
    for value in result.uv_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 76031157L, msg="uv_mode")
  }
  assert_eq(result.partition.length(), 320)
  {
    let mut hash = 0L
    for value in result.partition {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 701558588L, msg="partition")
  }
  assert_eq(result.cfl_alpha.length(), 96)
  {
    let mut hash = 0L
    for value in result.cfl_alpha {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 943824520L, msg="cfl_alpha")
  }
  assert_eq(result.txtp_inter1.length(), 32)
  {
    let mut hash = 0L
    for value in result.txtp_inter1 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 408120563L, msg="txtp_inter1")
  }
  assert_eq(result.txtp_inter2.length(), 16)
  {
    let mut hash = 0L
    for value in result.txtp_inter2 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 981654025L, msg="txtp_inter2")
  }
  assert_eq(result.txtp_intra1.length(), 208)
  {
    let mut hash = 0L
    for value in result.txtp_intra1 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 433203578L, msg="txtp_intra1")
  }
  assert_eq(result.txtp_intra2.length(), 312)
  {
    let mut hash = 0L
    for value in result.txtp_intra2 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 768783557L, msg="txtp_intra2")
  }
  assert_eq(result.cfl_sign.length(), 8)
  {
    let mut hash = 0L
    for value in result.cfl_sign {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 106280749L, msg="cfl_sign")
  }
  assert_eq(result.angle_delta.length(), 64)
  {
    let mut hash = 0L
    for value in result.angle_delta {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 109533712L, msg="angle_delta")
  }
  assert_eq(result.filter_intra.length(), 8)
  {
    let mut hash = 0L
    for value in result.filter_intra {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 837673400L, msg="filter_intra")
  }
  assert_eq(result.seg_id.length(), 24)
  {
    let mut hash = 0L
    for value in result.seg_id {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 687106716L, msg="seg_id")
  }
  assert_eq(result.pal_sz.length(), 112)
  {
    let mut hash = 0L
    for value in result.pal_sz {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 694124934L, msg="pal_sz")
  }
  assert_eq(result.color_map.length(), 560)
  {
    let mut hash = 0L
    for value in result.color_map {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 621652208L, msg="color_map")
  }
  assert_eq(result.txsz.length(), 48)
  {
    let mut hash = 0L
    for value in result.txsz {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 788855490L, msg="txsz")
  }
  assert_eq(result.delta_q.length(), 4)
  {
    let mut hash = 0L
    for value in result.delta_q {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 83962632L, msg="delta_q")
  }
  assert_eq(result.delta_lf.length(), 20)
  {
    let mut hash = 0L
    for value in result.delta_lf {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 470547884L, msg="delta_lf")
  }
  assert_eq(result.restore_switchable.length(), 4)
  {
    let mut hash = 0L
    for value in result.restore_switchable {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 90091925L, msg="restore_switchable")
  }
  assert_eq(result.restore_wiener.length(), 2)
  {
    let mut hash = 0L
    for value in result.restore_wiener {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 93930L, msg="restore_wiener")
  }
  assert_eq(result.restore_sgrproj.length(), 2)
  {
    let mut hash = 0L
    for value in result.restore_sgrproj {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 97061L, msg="restore_sgrproj")
  }
  assert_eq(result.txtp_inter3.length(), 8)
  {
    let mut hash = 0L
    for value in result.txtp_inter3 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 369404474L, msg="txtp_inter3")
  }
  assert_eq(result.use_filter_intra.length(), 44)
  {
    let mut hash = 0L
    for value in result.use_filter_intra {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 374647561L, msg="use_filter_intra")
  }
  assert_eq(result.txpart.length(), 42)
  {
    let mut hash = 0L
    for value in result.txpart {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 509300967L, msg="txpart")
  }
  assert_eq(result.skip.length(), 6)
  {
    let mut hash = 0L
    for value in result.skip {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 310483850L, msg="skip")
  }
  assert_eq(result.pal_y.length(), 42)
  {
    let mut hash = 0L
    for value in result.pal_y {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 767498063L, msg="pal_y")
  }
  assert_eq(result.pal_uv.length(), 4)
  {
    let mut hash = 0L
    for value in result.pal_uv {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 111445868L, msg="pal_uv")
  }
  assert_eq(result.y_mode.length(), 64)
  {
    let mut hash = 0L
    for value in result.y_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 8726139L, msg="y_mode")
  }
  assert_eq(result.wedge_idx.length(), 144)
  {
    let mut hash = 0L
    for value in result.wedge_idx {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 319362634L, msg="wedge_idx")
  }
  assert_eq(result.comp_inter_mode.length(), 64)
  {
    let mut hash = 0L
    for value in result.comp_inter_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 569738322L, msg="comp_inter_mode")
  }
  assert_eq(result.filter.length(), 64)
  {
    let mut hash = 0L
    for value in result.filter {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 854100319L, msg="filter")
  }
  assert_eq(result.interintra_mode.length(), 16)
  {
    let mut hash = 0L
    for value in result.interintra_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 233387464L, msg="interintra_mode")
  }
  assert_eq(result.motion_mode.length(), 88)
  {
    let mut hash = 0L
    for value in result.motion_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 355600890L, msg="motion_mode")
  }
  assert_eq(result.skip_mode.length(), 6)
  {
    let mut hash = 0L
    for value in result.skip_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 256046377L, msg="skip_mode")
  }
  assert_eq(result.newmv_mode.length(), 12)
  {
    let mut hash = 0L
    for value in result.newmv_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 743972501L, msg="newmv_mode")
  }
  assert_eq(result.globalmv_mode.length(), 4)
  {
    let mut hash = 0L
    for value in result.globalmv_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 141566088L, msg="globalmv_mode")
  }
  assert_eq(result.refmv_mode.length(), 12)
  {
    let mut hash = 0L
    for value in result.refmv_mode {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 866356225L, msg="refmv_mode")
  }
  assert_eq(result.drl_bit.length(), 6)
  {
    let mut hash = 0L
    for value in result.drl_bit {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 834271392L, msg="drl_bit")
  }
  assert_eq(result.intra.length(), 8)
  {
    let mut hash = 0L
    for value in result.intra {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 403520696L, msg="intra")
  }
  assert_eq(result.comp.length(), 10)
  {
    let mut hash = 0L
    for value in result.comp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 271643880L, msg="comp")
  }
  assert_eq(result.comp_dir.length(), 10)
  {
    let mut hash = 0L
    for value in result.comp_dir {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 759740854L, msg="comp_dir")
  }
  assert_eq(result.jnt_comp.length(), 12)
  {
    let mut hash = 0L
    for value in result.jnt_comp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 172315528L, msg="jnt_comp")
  }
  assert_eq(result.mask_comp.length(), 12)
  {
    let mut hash = 0L
    for value in result.mask_comp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 233507390L, msg="mask_comp")
  }
  assert_eq(result.wedge_comp.length(), 18)
  {
    let mut hash = 0L
    for value in result.wedge_comp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 155159283L, msg="wedge_comp")
  }
  assert_eq(result.ref_.length(), 36)
  {
    let mut hash = 0L
    for value in result.ref_ {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 49928469L, msg="ref_")
  }
  assert_eq(result.comp_fwd_ref.length(), 18)
  {
    let mut hash = 0L
    for value in result.comp_fwd_ref {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 728447803L, msg="comp_fwd_ref")
  }
  assert_eq(result.comp_bwd_ref.length(), 12)
  {
    let mut hash = 0L
    for value in result.comp_bwd_ref {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 478274838L, msg="comp_bwd_ref")
  }
  assert_eq(result.comp_uni_ref.length(), 18)
  {
    let mut hash = 0L
    for value in result.comp_uni_ref {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 301736316L, msg="comp_uni_ref")
  }
  assert_eq(result.seg_pred.length(), 6)
  {
    let mut hash = 0L
    for value in result.seg_pred {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 674390171L, msg="seg_pred")
  }
  assert_eq(result.interintra.length(), 14)
  {
    let mut hash = 0L
    for value in result.interintra {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 875668696L, msg="interintra")
  }
  assert_eq(result.interintra_wedge.length(), 14)
  {
    let mut hash = 0L
    for value in result.interintra_wedge {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 843832434L, msg="interintra_wedge")
  }
  assert_eq(result.obmc.length(), 44)
  {
    let mut hash = 0L
    for value in result.obmc {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 285854277L, msg="obmc")
  }
  assert_eq(result.mv0_classes.length(), 16)
  {
    let mut hash = 0L
    for value in result.mv0_classes {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 949497413L, msg="mv0_classes")
  }
  assert_eq(result.mv0_sign.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv0_sign {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 203515L, msg="mv0_sign")
  }
  assert_eq(result.mv0_class0.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv0_class0 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 206646L, msg="mv0_class0")
  }
  assert_eq(result.mv0_class0_fp.length(), 8)
  {
    let mut hash = 0L
    for value in result.mv0_class0_fp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 600589437L, msg="mv0_class0_fp")
  }
  assert_eq(result.mv0_class0_hp.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv0_class0_hp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 212908L, msg="mv0_class0_hp")
  }
  assert_eq(result.mv0_classN.length(), 20)
  {
    let mut hash = 0L
    for value in result.mv0_classN {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 620142493L, msg="mv0_classN")
  }
  assert_eq(result.mv0_classN_fp.length(), 4)
  {
    let mut hash = 0L
    for value in result.mv0_classN_fp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 217653201L, msg="mv0_classN_fp")
  }
  assert_eq(result.mv0_classN_hp.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv0_classN_hp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 222301L, msg="mv0_classN_hp")
  }
  assert_eq(result.mv1_classes.length(), 16)
  {
    let mut hash = 0L
    for value in result.mv1_classes {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 329525830L, msg="mv1_classes")
  }
  assert_eq(result.mv1_sign.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv1_sign {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 228563L, msg="mv1_sign")
  }
  assert_eq(result.mv1_class0.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv1_class0 {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 231694L, msg="mv1_class0")
  }
  assert_eq(result.mv1_class0_fp.length(), 8)
  {
    let mut hash = 0L
    for value in result.mv1_class0_fp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 52831248L, msg="mv1_class0_fp")
  }
  assert_eq(result.mv1_class0_hp.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv1_class0_hp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 237956L, msg="mv1_class0_hp")
  }
  assert_eq(result.mv1_classN.length(), 20)
  {
    let mut hash = 0L
    for value in result.mv1_classN {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 341222993L, msg="mv1_classN")
  }
  assert_eq(result.mv1_classN_fp.length(), 4)
  {
    let mut hash = 0L
    for value in result.mv1_classN_fp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 242525865L, msg="mv1_classN_fp")
  }
  assert_eq(result.mv1_classN_hp.length(), 2)
  {
    let mut hash = 0L
    for value in result.mv1_classN_hp {
      hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
    }
    assert_eq(hash, 247349L, msg="mv1_classN_hp")
  }
  assert_eq(result.joint.length(), 4)
  let mut hash = 0L
  for value in result.joint {
    hash = (hash * 31L + value.to_int().to_int64()) % 1000000007L
  }
  assert_eq(hash, 248744031L, msg="joint")
}
