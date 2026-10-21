///|
/// HEVC coefficient scan tables from FFmpeg 9.0.2 `libavcodec/hevc/cabac.c`,
/// converted to flat MoonBit arrays. The 4x4/8x8 diagonal coordinate tables
/// already live in `hevc_ps.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub let hevc_scan_1x1 : Array[Int32] = [0]

///|
pub let hevc_horiz_scan2x2_x : Array[Int32] = [0, 1, 0, 1]

///|
pub let hevc_horiz_scan2x2_y : Array[Int32] = [0, 0, 1, 1]

///|
pub let hevc_horiz_scan4x4_x : Array[Int32] = [
  0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3,
]

///|
pub let hevc_horiz_scan4x4_y : Array[Int32] = [
  0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
]

///|
pub let hevc_diag_scan2x2_x : Array[Int32] = [0, 0, 1, 1]

///|
pub let hevc_diag_scan2x2_y : Array[Int32] = [0, 1, 0, 1]

///|
/// `diag_scan2x2_inv[2][2]` flattened. */
pub let hevc_diag_scan2x2_inv : Array[Int32] = [0, 2, 1, 3]

///|
/// `diag_scan4x4_inv[4][4]` flattened. */
pub let hevc_diag_scan4x4_inv : Array[Int32] = [
  0, 2, 5, 9, 1, 4, 8, 12, 3, 7, 11, 14, 6, 10, 13, 15,
]

///|
/// `diag_scan8x8_inv[8][8]` flattened. */
pub let hevc_diag_scan8x8_inv : Array[Int32] = [
  0, 2, 5, 9, 14, 20, 27, 35, 1, 4, 8, 13, 19, 26, 34, 42, 3, 7, 12, 18, 25, 33,
  41, 48, 6, 11, 17, 24, 32, 40, 47, 53, 10, 16, 23, 31, 39, 46, 52, 57, 15, 22,
  30, 38, 45, 51, 56, 60, 21, 29, 37, 44, 50, 55, 59, 62, 28, 36, 43, 49, 54, 58,
  61, 63,
]

///|
/// `horiz_scan8x8_inv[8][8]` flattened. */
pub let hevc_horiz_scan8x8_inv : Array[Int32] = [
  0, 1, 2, 3, 16, 17, 18, 19, 4, 5, 6, 7, 20, 21, 22, 23, 8, 9, 10, 11, 24, 25, 26,
  27, 12, 13, 14, 15, 28, 29, 30, 31, 32, 33, 34, 35, 48, 49, 50, 51, 36, 37, 38,
  39, 52, 53, 54, 55, 40, 41, 42, 43, 56, 57, 58, 59, 44, 45, 46, 47, 60, 61, 62,
  63,
]
