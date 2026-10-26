///|
fn av1_cdf_reset_counts(
  table : FixedArray[UInt16],
  stride : Int32,
  count : Int32,
) -> Unit {
  for base = 0; base < table.length(); base = base + stride {
    table[base + count] = 0
  }
}

///|
/// dav1d cdf.c dav1d_cdf_thread_update resets adaptation counts at the
/// active symbol count, which is often before a padded row's last entry.
/// Inter tables in key/intra snapshots have not been adapted and remain
/// defaults, so resetting their zero counts is also valid.
pub fn Av1CdfCtx::for_reference(self : Av1CdfCtx) -> Av1CdfCtx {
  let c = self.copy()
  av1_cdf_reset_counts(c.eob_bin_16, 8, 4)
  av1_cdf_reset_counts(c.eob_bin_32, 8, 5)
  av1_cdf_reset_counts(c.eob_bin_64, 8, 6)
  av1_cdf_reset_counts(c.eob_bin_128, 8, 7)
  av1_cdf_reset_counts(c.eob_bin_256, 16, 8)
  av1_cdf_reset_counts(c.eob_bin_512, 16, 9)
  av1_cdf_reset_counts(c.eob_bin_1024, 16, 10)
  av1_cdf_reset_counts(c.eob_base_tok, 4, 2)
  av1_cdf_reset_counts(c.base_tok, 4, 3)
  av1_cdf_reset_counts(c.br_tok, 4, 3)
  av1_cdf_reset_counts(c.eob_hi_bit, 2, 1)
  av1_cdf_reset_counts(c.coef_skip, 2, 1)
  av1_cdf_reset_counts(c.dc_sign, 2, 1)
  for group in 0..<2 {
    for mode in 0..<13 {
      c.uv_mode[(group * 13 + mode) * 16 + 12 + group] = 0
    }
  }
  for bl in 0..<5 {
    for ctx in 0..<4 {
      c.partition[(bl * 4 + ctx) * 16 +
      (if bl == 0 { 7 } else if bl == 4 { 3 } else { 9 })] = 0
    }
  }
  av1_cdf_reset_counts(c.cfl_alpha, 16, 15)
  av1_cdf_reset_counts(c.txtp_inter1, 16, 15)
  c.txtp_inter2[11] = 0
  av1_cdf_reset_counts(c.txtp_intra1, 8, 6)
  av1_cdf_reset_counts(c.txtp_intra2, 8, 4)
  c.cfl_sign[7] = 0
  av1_cdf_reset_counts(c.angle_delta, 8, 6)
  c.filter_intra[4] = 0
  av1_cdf_reset_counts(c.seg_id, 8, 7)
  av1_cdf_reset_counts(c.pal_sz, 8, 6)
  for pl in 0..<2 {
    for size in 0..<7 {
      for ctx in 0..<5 {
        c.color_map[((pl * 7 + size) * 5 + ctx) * 8 + size + 1] = 0
      }
    }
  }
  for cat in 0..<4 {
    for ctx in 0..<3 {
      c.txsz[(cat * 3 + ctx) * 4 + av1_imin(cat + 1, 2)] = 0
    }
  }
  c.delta_q[3] = 0
  av1_cdf_reset_counts(c.delta_lf, 4, 3)
  c.restore_switchable[2] = 0
  c.restore_wiener[1] = 0
  c.restore_sgrproj[1] = 0
  av1_cdf_reset_counts(c.txtp_inter3, 2, 1)
  av1_cdf_reset_counts(c.use_filter_intra, 2, 1)
  av1_cdf_reset_counts(c.txpart, 2, 1)
  av1_cdf_reset_counts(c.skip, 2, 1)
  av1_cdf_reset_counts(c.pal_y, 2, 1)
  av1_cdf_reset_counts(c.pal_uv, 2, 1)
  av1_cdf_reset_counts(c.y_mode, 16, 12)
  av1_cdf_reset_counts(c.wedge_idx, 16, 15)
  av1_cdf_reset_counts(c.comp_inter_mode, 8, 7)
  av1_cdf_reset_counts(c.filter, 4, 2)
  av1_cdf_reset_counts(c.interintra_mode, 4, 3)
  av1_cdf_reset_counts(c.motion_mode, 4, 2)
  av1_cdf_reset_counts(c.skip_mode, 2, 1)
  av1_cdf_reset_counts(c.newmv_mode, 2, 1)
  av1_cdf_reset_counts(c.globalmv_mode, 2, 1)
  av1_cdf_reset_counts(c.refmv_mode, 2, 1)
  av1_cdf_reset_counts(c.drl_bit, 2, 1)
  av1_cdf_reset_counts(c.intra, 2, 1)
  av1_cdf_reset_counts(c.comp, 2, 1)
  av1_cdf_reset_counts(c.comp_dir, 2, 1)
  av1_cdf_reset_counts(c.jnt_comp, 2, 1)
  av1_cdf_reset_counts(c.mask_comp, 2, 1)
  av1_cdf_reset_counts(c.wedge_comp, 2, 1)
  av1_cdf_reset_counts(c.ref_, 2, 1)
  av1_cdf_reset_counts(c.comp_fwd_ref, 2, 1)
  av1_cdf_reset_counts(c.comp_bwd_ref, 2, 1)
  av1_cdf_reset_counts(c.comp_uni_ref, 2, 1)
  av1_cdf_reset_counts(c.seg_pred, 2, 1)
  for i in 0..<4 {
    c.interintra[i * 2 + 1] = 0
  }
  av1_cdf_reset_counts(c.interintra_wedge, 2, 1)
  av1_cdf_reset_counts(c.obmc, 2, 1)
  for
    (classes, sign, class0, fp0, hp0, classn, fpn, hpn) in [
      (
        c.mv0_classes,
        c.mv0_sign,
        c.mv0_class0,
        c.mv0_class0_fp,
        c.mv0_class0_hp,
        c.mv0_classN,
        c.mv0_classN_fp,
        c.mv0_classN_hp,
      ),
      (
        c.mv1_classes,
        c.mv1_sign,
        c.mv1_class0,
        c.mv1_class0_fp,
        c.mv1_class0_hp,
        c.mv1_classN,
        c.mv1_classN_fp,
        c.mv1_classN_hp,
      ),
    ] {
    classes[10] = 0
    sign[1] = 0
    class0[1] = 0
    av1_cdf_reset_counts(fp0, 4, 3)
    hp0[1] = 0
    av1_cdf_reset_counts(classn, 2, 1)
    fpn[3] = 0
    hpn[1] = 0
  }
  c.joint[3] = 0
  c
}
