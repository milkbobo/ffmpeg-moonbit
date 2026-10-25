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
