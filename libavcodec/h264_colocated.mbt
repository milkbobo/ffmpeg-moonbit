///|
/// Colocated frame/field addressing from FFmpeg 9.0.2 h264_direct.c,
/// pred_spatial_direct_motion / pred_temp_direct_motion and fill_colmap.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
priv struct H264Colocated {
  info : H264MbInfo
  block : Int32
  field : Bool
  row : Int32
}

///|
/// col_parity: ties select bottom; Int64 subtraction also handles INT_MAX
/// for an as-yet undecoded field without overflowing an Int32.
fn h264_col_parity(pic : H264RefPic, poc : Int32) -> Int32 {
  if (pic.field_poc_top.to_int64() - poc.to_int64()).abs() >=
    (pic.field_poc_bottom.to_int64() - poc.to_int64()).abs() {
    1
  } else {
    0
  }
}

///|
fn h264_colocated_sample(
  ctx : H264DecCtx,
  index : Int32,
  gx : Int32,
  gy : Int32,
) -> Result[H264Colocated, String] {
  let pic = ctx.ref_list1[0]
  let mx = index % ctx.mb_width
  let my = index / ctx.mb_width
  let field = ctx.colocated_field_picture || ctx.colocated[index].field_mb
  let (row, x, y) = if field && !ctx.mb_field {
    // A frame MB sees one half of the closest colocated field MB.
    (
      (my & -2) + h264_col_parity(pic, ctx.poc),
      gx / 2 * 3,
      (my & 1) * 2 + gy / 2,
    )
  } else if !field && ctx.mb_field {
    // A field MB spans two frame MBs. Its upper/lower 8x8 groups sample
    // row 0 of the first and row 2 of the second frame MB (b4_stride *= 6).
    ((my & -2) + gy / 2, gx / 2 * 3, gy / 2 * 2)
  } else {
    let row = if ctx.field_picture && !ctx.colocated_mbaff && pic.parity != 0 {
      (my & -2) + pic.parity - 1
    } else {
      my
    }
    (
      row,
      if ctx.direct_8x8 {
        gx / 2 * 3
      } else {
        gx
      },
      if ctx.direct_8x8 {
        gy / 2 * 3
      } else {
        gy
      },
    )
  }
  let target = row * ctx.mb_width + mx
  guard target >= 0 && target < ctx.colocated.length() else {
    return Err("missing colocated field history")
  }
  Ok({ info: ctx.colocated[target], block: y * 4 + x, field, row, })
}

///|
/// Reference ids use 4*identity + structure for every picture. MBAFF motion
/// caches number fields relative to the current MB's parity; restore physical
/// parity before matching a PAFF or frame list. The current field selects a
/// field view of a frame reference, as fill_colmap's rfield pass does.
fn h264_direct_ref(
  ctx : H264DecCtx,
  source : H264Colocated,
  identity : Int32,
  parity : Int32,
) -> Int32 {
  if identity < 0 {
    return 0
  }
  let mut wanted = identity
  if ctx.colocated_mbaff && source.field && (source.row & 1) != 0 {
    wanted = (wanted & -4) + (3 - (wanted & 3))
  }
  if ctx.mb_field {
    if (wanted & 3) == 3 {
      wanted = (wanted & -4) + parity + 1
    }
  } else {
    wanted = wanted | 3
  }
  let count = if ctx.mb_aff && ctx.mb_field {
    ctx.ref_count0 * 2
  } else {
    ctx.ref_count0
  }
  for refi in 0..<count {
    let entry = h264_ref_entry(ctx, refi, ctx.mb_field, parity)
    if entry >= ctx.ref_list0.length() {
      continue
    }
    let pic = ctx.ref_list0[entry]
    let actual = pic.identity * 4 +
      (if pic.parity == 0 { 3 } else { pic.parity })
    if actual == wanted {
      return refi
    }
  }
  0
}
