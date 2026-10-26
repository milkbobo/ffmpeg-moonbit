///|
/// Coordinates and filter phases for one AV1 reference plane. Motion vectors
/// are in luma 1/8-pixel units; the scale and step fields use dav1d's
/// `ScalableMotionParams` 1/16384 and 1/1024 units respectively.
pub(all) struct Av1McPlanePosition {
  w : Int32
  h : Int32
  scaled : Bool
  src_x : Int32
  src_y : Int32
  mx : Int32
  my : Int32
  step_x : Int32
  step_y : Int32
}

///|
fn av1_mc_scale_position(origin : Int32, scale : Int32) -> Int32 {
  let value = origin.to_int64() * scale.to_int64() +
    (scale - 0x4000).to_int64() * 8L
  let abs_value = if value < 0L { -value } else { value }
  let rounded = ((abs_value + 128L) >> 8).to_int()
  (if value < 0L { -rounded } else { rounded }) + 32
}

///|
/// Convert a block origin and MV to the arguments expected by dav1d's
/// unscaled or scaled MC kernels. The current and reference dimensions are
/// full-resolution luma dimensions; `ss_h`/`ss_v` describe this plane.
pub fn av1_mc_plane_position(
  cur_width : Int32,
  cur_height : Int32,
  ref_width : Int32,
  ref_height : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  mv_y : Int32,
  mv_x : Int32,
  ss_h : Int32,
  ss_v : Int32,
) -> Av1McPlanePosition {
  let h_mul = 4 >> ss_h
  let v_mul = 4 >> ss_v
  let w = bw4 * h_mul
  let h = bh4 * v_mul
  if cur_width == ref_width && cur_height == ref_height {
    return {
      w,
      h,
      scaled: false,
      src_x: bx4 * h_mul + (mv_x >> (3 + ss_h)),
      src_y: by4 * v_mul + (mv_y >> (3 + ss_v)),
      mx: (mv_x & (15 >> (1 - ss_h))) << (1 - ss_h),
      my: (mv_y & (15 >> (1 - ss_v))) << (1 - ss_v),
      step_x: 1024,
      step_y: 1024,
    }
  }
  let scale_x = ((ref_width << 14) + (cur_width >> 1)) / cur_width
  let scale_y = ((ref_height << 14) + (cur_height >> 1)) / cur_height
  let orig_x = ((bx4 * h_mul) << 4) + mv_x * (1 << (1 - ss_h))
  let orig_y = ((by4 * v_mul) << 4) + mv_y * (1 << (1 - ss_v))
  {
    w,
    h,
    scaled: true,
    src_x: 0,
    src_y: 0,
    mx: av1_mc_scale_position(orig_x, scale_x),
    my: av1_mc_scale_position(orig_y, scale_y),
    step_x: (scale_x + 8) >> 4,
    step_y: (scale_y + 8) >> 4,
  }
}

///|
/// Predict a single plane from a decoded reference frame. Edge samples are
/// repeated by the underlying kernels, matching dav1d's edge emulation.
pub fn av1_mc_predict_plane(
  src : FixedArray[Int32],
  stride : Int32,
  ref_width : Int32,
  ref_height : Int32,
  cur_width : Int32,
  cur_height : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  mv_y : Int32,
  mv_x : Int32,
  ss_h : Int32,
  ss_v : Int32,
  filter_type : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let pos = av1_mc_plane_position(
    cur_width, cur_height, ref_width, ref_height, bx4, by4, bw4, bh4, mv_y, mv_x,
    ss_h, ss_v,
  )
  let plane_w = (ref_width + ss_h) >> ss_h
  let plane_h = (ref_height + ss_v) >> ss_v
  if pos.scaled {
    av1_mc_put_scaled(
      src,
      stride,
      plane_w,
      plane_h,
      pos.w,
      pos.h,
      pos.mx,
      pos.my,
      pos.step_x,
      pos.step_y,
      filter_type,
      bitdepth,
    )
  } else {
    av1_mc_put_unscaled(
      src,
      stride,
      plane_w,
      plane_h,
      pos.src_x,
      pos.src_y,
      pos.w,
      pos.h,
      pos.mx,
      pos.my,
      filter_type,
      bitdepth,
    )
  }
}

///|
/// Prepare one plane at compound-prediction precision for avg/mask blending.
pub fn av1_mc_prepare_plane(
  src : FixedArray[Int32],
  stride : Int32,
  ref_width : Int32,
  ref_height : Int32,
  cur_width : Int32,
  cur_height : Int32,
  bx4 : Int32,
  by4 : Int32,
  bw4 : Int32,
  bh4 : Int32,
  mv_y : Int32,
  mv_x : Int32,
  ss_h : Int32,
  ss_v : Int32,
  filter_type : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let pos = av1_mc_plane_position(
    cur_width, cur_height, ref_width, ref_height, bx4, by4, bw4, bh4, mv_y, mv_x,
    ss_h, ss_v,
  )
  let plane_w = (ref_width + ss_h) >> ss_h
  let plane_h = (ref_height + ss_v) >> ss_v
  if pos.scaled {
    av1_mc_prep_scaled(
      src,
      stride,
      plane_w,
      plane_h,
      pos.w,
      pos.h,
      pos.mx,
      pos.my,
      pos.step_x,
      pos.step_y,
      filter_type,
      bitdepth,
    )
  } else {
    av1_mc_prep_unscaled(
      src,
      stride,
      plane_w,
      plane_h,
      pos.src_x,
      pos.src_y,
      pos.w,
      pos.h,
      pos.mx,
      pos.my,
      filter_type,
      bitdepth,
    )
  }
}
