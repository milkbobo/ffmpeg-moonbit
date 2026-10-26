///|
/// Inter-frame syntax primitives ported from dav1d 1.5.1 `src/decode.c`.

///|
/// `read_mv_component_diff`: one MV component's NEWMV residual.
/// `comp` is 0 (y) or 1 (x). `mv_prec < 0` forces integer MVs (fp/hp bits
/// are not coded), `mv_prec > 0` enables the high-precision bit.
fn av1_read_mv_component_diff(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  comp : Int,
  mv_prec : Int,
) -> Int {
  let sign = if comp == 0 { cdf.mv0_sign } else { cdf.mv1_sign }
  let classes = if comp == 0 { cdf.mv0_classes } else { cdf.mv1_classes }
  let class0 = if comp == 0 { cdf.mv0_class0 } else { cdf.mv1_class0 }
  let class0_fp = if comp == 0 {
    cdf.mv0_class0_fp
  } else {
    cdf.mv1_class0_fp
  }
  let class0_hp = if comp == 0 { cdf.mv0_class0_hp } else { cdf.mv1_class0_hp }
  let classn = if comp == 0 { cdf.mv0_classN } else { cdf.mv1_classN }
  let classn_fp = if comp == 0 { cdf.mv0_classN_fp } else { cdf.mv1_classN_fp }
  let classn_hp = if comp == 0 { cdf.mv0_classN_hp } else { cdf.mv1_classN_hp }
  let sign_bit = msac.decode_bool_adapt(sign, 0)
  let cl = msac.decode_symbol_adapt(classes, 0, 10)
  let mut up = 0
  let mut fp = 3
  let mut hp = 1
    if cl == 0 {
      let u = msac.decode_bool_adapt(class0, 0)
      up = u.reinterpret_as_int()
      if mv_prec >= 0 {
        fp = msac.decode_symbol_adapt(class0_fp, up * 4, 3)
        if mv_prec > 0 {
          // dav1d reads class0_hp without the `up` index (always row 0).
          hp = msac.decode_bool_adapt(class0_hp, 0).reinterpret_as_int()
        }
      }
    } else {
    up = 1 << cl
    for n in 0..<cl {
      up = up |
        (msac.decode_bool_adapt(classn, n * 2).reinterpret_as_int() << n)
    }
    if mv_prec >= 0 {
      fp = msac.decode_symbol_adapt(classn_fp, 0, 3)
      if mv_prec > 0 {
        hp = msac.decode_bool_adapt(classn_hp, 0).reinterpret_as_int()
      }
    }
  }
  let diff = ((up << 3) | (fp << 1) | hp) + 1
  if sign_bit != 0 { -diff } else { diff }
}

///|
/// `read_mv_residual` from dav1d decode.c: joint + component residuals
/// relative to `ref_mv` (dav1d adds in place; this returns the new pair).
/// `mv_prec`: `hp << 1 | (!force_integer_mv)` in the caller.
pub fn av1_read_mv_residual(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  ref_y : Int,
  ref_x : Int,
  mv_prec : Int,
) -> (Int, Int) {
  let joint = msac.decode_symbol_adapt(cdf.joint, 0, 3)
  let mut y = ref_y
  let mut x = ref_x
  if (joint & 2) != 0 {
    // MV_JOINT_V = 2: y component (dav1d comp[0])
    y = y + av1_read_mv_component_diff(msac, cdf, 0, mv_prec)
  }
  if (joint & 1) != 0 {
    // MV_JOINT_H = 1: x component (dav1d comp[1])
    x = x + av1_read_mv_component_diff(msac, cdf, 1, mv_prec)
  }
  (y, x)
}

///|
/// Read the single/compound reference-frame tree in dav1d decode_b.
/// Returned indices are 0..6; a single-reference block uses -1 for ref1.
pub fn av1_inter_read_refs(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
  is_comp : Bool,
) -> (Int, Int) {
  let bit = (table : FixedArray[UInt16], row : Int, ctx : Int) => {
    msac.decode_bool_adapt(table, (row * 3 + ctx) * 2).reinterpret_as_int()
  }
  if is_comp {
    let dir = msac.decode_bool_adapt(
      cdf.comp_dir, av1_inter_comp_dir_ctx(top, left) * 2,
    )
    if dir != 0 {
      let fwd0 = av1_inter_ref_tree_ctx(top, left, 1)
      let r0 = if bit(cdf.comp_fwd_ref, 0, fwd0) != 0 {
        2 + bit(cdf.comp_fwd_ref, 2, av1_inter_ref_tree_ctx(top, left, 3))
      } else {
        bit(cdf.comp_fwd_ref, 1, av1_inter_ref_tree_ctx(top, left, 2))
      }
      let r1 = if bit(cdf.comp_bwd_ref, 0, av1_inter_ref_tree_ctx(top, left, 4)) != 0 {
        6
      } else {
        4 + bit(cdf.comp_bwd_ref, 1, av1_inter_ref_tree_ctx(top, left, 5))
      }
      return (r0, r1)
    }
    if bit(cdf.comp_uni_ref, 0, av1_inter_ref_tree_ctx(top, left, 0)) != 0 {
      return (4, 6)
    }
    let mut r1 = 1 + bit(
      cdf.comp_uni_ref, 1, av1_inter_ref_tree_ctx(top, left, 6),
    )
    if r1 == 2 {
      r1 = r1 + bit(
        cdf.comp_uni_ref, 2, av1_inter_ref_tree_ctx(top, left, 3),
      )
    }
    return (0, r1)
  }
  if bit(cdf.ref_, 0, av1_inter_ref_tree_ctx(top, left, 0)) != 0 {
    if bit(cdf.ref_, 1, av1_inter_ref_tree_ctx(top, left, 4)) != 0 {
      return (6, -1)
    }
    return (
      4 + bit(cdf.ref_, 5, av1_inter_ref_tree_ctx(top, left, 5)), -1,
    )
  }
  if bit(cdf.ref_, 2, av1_inter_ref_tree_ctx(top, left, 1)) != 0 {
    return (
      2 + bit(cdf.ref_, 4, av1_inter_ref_tree_ctx(top, left, 3)), -1,
    )
  }
  (bit(cdf.ref_, 3, av1_inter_ref_tree_ctx(top, left, 2)), -1)
}

///|
/// dav1d `InterPredMode` values: nearest, near, global, new.
pub(all) struct Av1InterSingleMv {
  mode : Int
  drl_idx : Int
  mv : (Int, Int)
  has_subpel_filter : Bool
}

///|
/// Decode single-reference mode, DRL index, and MV after refmvs_find.
/// A segment's skip/globalmv feature sets `force_global`.
pub fn av1_inter_read_single_mv(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  rf : Av1Rf,
  stack : Av1RefmvsResult,
  ref_idx : Int,
  bs : Int,
  by4 : Int,
  bx4 : Int,
  force_global : Bool,
) -> Av1InterSingleMv {
  let bw4 = av1_block_dimensions[bs * 4].to_int()
  let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
  let narrow = (if bw4 < bh4 { bw4 } else { bh4 }) == 1
  let gmt = rf.gm_types[ref_idx]
  let ctx = stack.ctx
  if force_global || msac.decode_bool_adapt(cdf.newmv_mode, (ctx & 7) * 2) != 0 {
    if force_global ||
      msac.decode_bool_adapt(cdf.globalmv_mode, ((ctx >> 3) & 1) * 2) == 0 {
      let mv = av1_rmv_get_gmv_2d(
        gmt, rf.gm_matrices[ref_idx], bx4, by4, bw4, bh4,
        rf.hp, rf.force_integer_mv,
      )
      return {
        mode: 2, drl_idx: 0, mv,
        has_subpel_filter: narrow || gmt == 1,
      }
    }
    if msac.decode_bool_adapt(cdf.refmv_mode, ((ctx >> 4) & 15) * 2) != 0 {
      let mut drl = 1
      if stack.cnt > 2 {
        drl = drl + msac.decode_bool_adapt(
          cdf.drl_bit, av1_inter_drl_ctx(
            stack.cands[1].weight, stack.cands[2].weight,
          ) * 2,
        ).reinterpret_as_int()
        if drl == 2 && stack.cnt > 3 {
          drl = drl + msac.decode_bool_adapt(
            cdf.drl_bit, av1_inter_drl_ctx(
              stack.cands[2].weight, stack.cands[3].weight,
            ) * 2,
          ).reinterpret_as_int()
        }
      }
      let mv = stack.cands[drl].mv0
      return {
        mode: 1, drl_idx: drl,
        mv: if drl < 2 {
          av1_rmv_fix_precision(mv, rf.force_integer_mv, rf.hp)
        } else {
          mv
        },
        has_subpel_filter: true,
      }
    }
    return {
      mode: 0, drl_idx: 0,
      mv: av1_rmv_fix_precision(
        stack.cands[0].mv0, rf.force_integer_mv, rf.hp,
      ),
      has_subpel_filter: true,
    }
  }
  let mut drl = 0
  if stack.cnt > 1 {
    drl = drl + msac.decode_bool_adapt(
      cdf.drl_bit, av1_inter_drl_ctx(
        stack.cands[0].weight, stack.cands[1].weight,
      ) * 2,
    ).reinterpret_as_int()
    if drl == 1 && stack.cnt > 2 {
      drl = drl + msac.decode_bool_adapt(
        cdf.drl_bit, av1_inter_drl_ctx(
          stack.cands[1].weight, stack.cands[2].weight,
        ) * 2,
      ).reinterpret_as_int()
    }
  }
  let base = stack.cands[drl].mv0
  let ref_mv = if stack.cnt > 1 {
    base
  } else {
    av1_rmv_fix_precision(base, rf.force_integer_mv, rf.hp)
  }
  let (y, x) = ref_mv
  let mv_prec = (if rf.hp { 1 } else { 0 }) -
    (if rf.force_integer_mv { 1 } else { 0 })
  {
    mode: 3, drl_idx: drl,
    mv: av1_read_mv_residual(msac, cdf, y, x, mv_prec),
    has_subpel_filter: true,
  }
}

///|
pub(all) struct Av1InterCompoundMv {
  mode : Int
  drl_idx : Int
  mv0 : (Int, Int)
  mv1 : (Int, Int)
  has_subpel_filter : Bool
}

///|
/// Read compound inter mode, DRL, and both MVs after refmvs_find.
pub fn av1_inter_read_compound_mv(
  msac : Av1Msac,
  cdf : Av1CdfCtx,
  rf : Av1Rf,
  stack : Av1RefmvsResult,
  ref_idx0 : Int,
  ref_idx1 : Int,
  bs : Int,
  by4 : Int,
  bx4 : Int,
) -> Av1InterCompoundMv {
  let mode = msac.decode_symbol_adapt(cdf.comp_inter_mode, stack.ctx * 8, 7)
  let modes : FixedArray[(Int, Int)] = [
    (0, 0), (1, 1), (0, 3), (3, 0),
    (1, 3), (3, 1), (2, 2), (3, 3),
  ]
  let (m0, m1) = modes[mode]
  let mut drl = if m0 == 1 || m1 == 1 { 1 } else { 0 }
  if mode == 7 {
    if stack.cnt > 1 {
      drl = drl + msac.decode_bool_adapt(
        cdf.drl_bit, av1_inter_drl_ctx(
          stack.cands[0].weight, stack.cands[1].weight,
        ) * 2,
      ).reinterpret_as_int()
      if drl == 1 && stack.cnt > 2 {
        drl = drl + msac.decode_bool_adapt(
          cdf.drl_bit, av1_inter_drl_ctx(
            stack.cands[1].weight, stack.cands[2].weight,
          ) * 2,
        ).reinterpret_as_int()
      }
    }
  } else if m0 == 1 || m1 == 1 {
    if stack.cnt > 2 {
      drl = drl + msac.decode_bool_adapt(
        cdf.drl_bit, av1_inter_drl_ctx(
          stack.cands[1].weight, stack.cands[2].weight,
        ) * 2,
      ).reinterpret_as_int()
      if drl == 2 && stack.cnt > 3 {
        drl = drl + msac.decode_bool_adapt(
          cdf.drl_bit, av1_inter_drl_ctx(
            stack.cands[2].weight, stack.cands[3].weight,
          ) * 2,
        ).reinterpret_as_int()
      }
    }
  }
  let bw4 = av1_block_dimensions[bs * 4].to_int()
  let bh4 = av1_block_dimensions[bs * 4 + 1].to_int()
  let narrow = (if bw4 < bh4 { bw4 } else { bh4 }) == 1
  let has_filter = Ref(narrow || mode != 6)
  let read_one = (idx : Int, kind : Int, ref_idx : Int) => {
    if kind == 2 {
      if rf.gm_types[ref_idx] == 1 {
        has_filter.val = true
      }
      av1_rmv_get_gmv_2d(
        rf.gm_types[ref_idx], rf.gm_matrices[ref_idx],
        bx4, by4, bw4, bh4, rf.hp, rf.force_integer_mv,
      )
    } else {
      let base = if idx == 0 { stack.cands[drl].mv0 } else {
        stack.cands[drl].mv1
      }
      if kind == 3 {
        let (y, x) = base
        let mv_prec = (if rf.hp { 1 } else { 0 }) -
          (if rf.force_integer_mv { 1 } else { 0 })
        av1_read_mv_residual(msac, cdf, y, x, mv_prec)
      } else {
        av1_rmv_fix_precision(base, rf.force_integer_mv, rf.hp)
      }
    }
  }
  let mv0 = read_one(0, m0, ref_idx0)
  let mv1 = read_one(1, m1, ref_idx1)
  { mode, drl_idx: drl, mv0, mv1, has_subpel_filter: has_filter.val }
}
