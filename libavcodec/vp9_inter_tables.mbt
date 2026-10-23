///|
/// VP9 inter-prediction tables extracted from FFmpeg 9.0.2
/// `libavcodec/vp9data.c` and `libavcodec/vp9dsp.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Trees use the same flat convention as `vp9_partition_tree`: positive
/// values are node indices (`i = tree[i * 2 + bit]`), negative values are
/// negated leaves.  `vp9_subpel_filters` is `[type][phase][tap]` with
/// type 0=FILTER_8TAP_REGULAR, 1=FILTER_8TAP_SHARP, 2=FILTER_8TAP_SMOOTH
/// (the C array's index order, not the FilterMode enum order).

///|
/// `ff_vp9_inter_mode_tree[3][2]` (leaves: ZEROMV=12, NEARESTMV=10,
/// NEARMV=11, NEWMV=13)
let vp9_inter_mode_tree : Array[Int32] = [
  -12, 1, -10, 2, -11, -13,
]

///|
/// `ff_vp9_filter_tree[2][2]` (leaves 0..2 = filter tree code; use
/// `vp9_filter_lut` to map onto FilterMode)
let vp9_filter_tree : Array[Int32] = [
  0, 1, -1, -2,
]

///|
/// `ff_vp9_filter_lut[3]`: tree code -> FilterMode
let vp9_filter_lut : Array[Int32] = [
  0, 1, 2,
]

///|
/// `ff_vp9_mv_joint_tree[3][2]` (MV_JOINT_ZERO/H/V/HV = 0..3)
let vp9_mv_joint_tree : Array[Int32] = [
  0, 1, -1, 2, -2, -3,
]

///|
/// `ff_vp9_mv_class_tree[10][2]`
let vp9_mv_class_tree : Array[Int32] = [
  0, 1, -1, 2, 3, 4, -2, -3, 5, 6, -4, -5, -6, 7, 8, 9, -7, -8, -9, -10,
]

///|
/// `ff_vp9_mv_fp_tree[3][2]`
let vp9_mv_fp_tree : Array[Int32] = [
  0, 1, -1, 2, -2, -3,
]

///|
/// `mv_ref_blk_off[N_BS_SIZES][8][2]` from `vp9mvs.c` (`find_ref_mvs`
/// neighbour scan offsets, in 8-px units, [x, y] order).
let vp9_mv_ref_blk_off : Array[Int32] = [
  // BS_64x64
  3, -1, -1, 3, 4, -1, -1, 4, -1, -1, 0, -1, -1, 0, 6, -1,
  // BS_64x32
  0, -1, -1, 0, 4, -1, -1, 2, -1, -1, 0, -3, -3, 0, 2, -1,
  // BS_32x64
  -1, 0, 0, -1, -1, 4, 2, -1, -1, -1, -3, 0, 0, -3, -1, 2,
  // BS_32x32
  1, -1, -1, 1, 2, -1, -1, 2, -1, -1, 0, -3, -3, 0, -3, -3,
  // BS_32x16
  0, -1, -1, 0, 2, -1, -1, -1, -1, 1, 0, -3, -3, 0, -3, -3,
  // BS_16x32
  -1, 0, 0, -1, -1, 2, -1, -1, 1, -1, -3, 0, 0, -3, -3, -3,
  // BS_16x16
  0, -1, -1, 0, 1, -1, -1, 1, -1, -1, 0, -3, -3, 0, -3, -3,
  // BS_16x8
  0, -1, -1, 0, 1, -1, -1, -1, 0, -2, -2, 0, -2, -1, -1, -2,
  // BS_8x16
  -1, 0, 0, -1, -1, 1, -1, -1, -2, 0, 0, -2, -1, -2, -2, -1,
  // BS_8x8 / BS_8x4 / BS_4x8 / BS_4x4
  0, -1, -1, 0, -1, -1, 0, -2, -2, 0, -1, -2, -2, -1, -2, -2,
  0, -1, -1, 0, -1, -1, 0, -2, -2, 0, -1, -2, -2, -1, -2, -2,
  0, -1, -1, 0, -1, -1, 0, -2, -2, 0, -1, -2, -2, -1, -2, -2,
  0, -1, -1, 0, -1, -1, 0, -2, -2, 0, -1, -2, -2, -1, -2, -2,
]

///|
/// `inter_mode_ctx_lut[14][14]` from `vp9block.c` (`decode_mode`):
/// context from above/left stored mode values.
let vp9_inter_mode_ctx_lut : Array[Int32] = [
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 1, 3,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 1, 3,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 1, 0, 3,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 3, 3, 3, 4,
]

///|
/// `ff_vp9_subpel_filters[3][16][8]` from `vp9dsp.c`, flattened.
/// Type index follows the C array: 0=regular, 1=sharp, 2=smooth.
let vp9_subpel_filters : Array[Int32] = [
  // FILTER_8TAP_REGULAR
  0, 0, 0, 128, 0, 0, 0, 0,
  0, 1, -5, 126, 8, -3, 1, 0,
  -1, 3, -10, 122, 18, -6, 2, 0,
  -1, 4, -13, 118, 27, -9, 3, -1,
  -1, 4, -16, 112, 37, -11, 4, -1,
  -1, 5, -18, 105, 48, -14, 4, -1,
  -1, 5, -19, 97, 58, -16, 5, -1,
  -1, 6, -19, 88, 68, -18, 5, -1,
  -1, 6, -19, 78, 78, -19, 6, -1,
  -1, 5, -18, 68, 88, -19, 6, -1,
  -1, 5, -16, 58, 97, -19, 5, -1,
  -1, 4, -14, 48, 105, -18, 5, -1,
  -1, 4, -11, 37, 112, -16, 4, -1,
  -1, 3, -9, 27, 118, -13, 4, -1,
  0, 2, -6, 18, 122, -10, 3, -1,
  0, 1, -3, 8, 126, -5, 1, 0,
  // FILTER_8TAP_SHARP
  0, 0, 0, 128, 0, 0, 0, 0,
  -1, 3, -7, 127, 8, -3, 1, 0,
  -2, 5, -13, 125, 17, -6, 3, -1,
  -3, 7, -17, 121, 27, -10, 5, -2,
  -4, 9, -20, 115, 37, -13, 6, -2,
  -4, 10, -23, 108, 48, -16, 8, -3,
  -4, 10, -24, 100, 59, -19, 9, -3,
  -4, 11, -24, 90, 70, -21, 10, -4,
  -4, 11, -23, 80, 80, -23, 11, -4,
  -4, 10, -21, 70, 90, -24, 11, -4,
  -3, 9, -19, 59, 100, -24, 10, -4,
  -3, 8, -16, 48, 108, -23, 10, -4,
  -2, 6, -13, 37, 115, -20, 9, -4,
  -2, 5, -10, 27, 121, -17, 7, -3,
  -1, 3, -6, 17, 125, -13, 5, -2,
  0, 1, -3, 8, 127, -7, 3, -1,
  // FILTER_8TAP_SMOOTH
  0, 0, 0, 128, 0, 0, 0, 0,
  -3, -1, 32, 64, 38, 1, -3, 0,
  -2, -2, 29, 63, 41, 2, -3, 0,
  -2, -2, 26, 63, 43, 4, -4, 0,
  -2, -3, 24, 62, 46, 5, -4, 0,
  -2, -3, 21, 60, 49, 7, -4, 0,
  -1, -4, 18, 59, 51, 9, -4, 0,
  -1, -4, 16, 57, 53, 12, -4, -1,
  -1, -4, 14, 55, 55, 14, -4, -1,
  -1, -4, 12, 53, 57, 16, -4, -1,
  0, -4, 9, 51, 59, 18, -4, -1,
  0, -4, 7, 49, 60, 21, -3, -2,
  0, -4, 5, 46, 62, 24, -3, -2,
  0, -4, 4, 43, 63, 26, -2, -2,
  0, -3, 2, 41, 63, 29, -2, -2,
  0, -3, 1, 38, 64, 32, -1, -3,
]

///|
/// C `subpel filter type` lookup from `FilterMode`: regular/smooth/sharp/
/// bilinear -> table row (regular=0, sharp=1, smooth=2; bilinear never
/// reaches the 8-tap path).
fn vp9_filter_to_table(mode : Int32) -> Int32 {
  match mode {
    1 => 2 // FILTER_8TAP_SMOOTH
    2 => 1 // FILTER_8TAP_SHARP
    _ => 0 // FILTER_8TAP_REGULAR
  }
}
