///|
/// Ported from `libavutil/display.c`: display transformation matrices.

///|
/// `av_display_rotation_set`: a clockwise-rotation display matrix from an
/// angle in degrees. Entries are 16.16 fixed point; the C's cast to
/// int32_t truncates toward zero.
pub fn av_display_rotation_set(matrix : Array[Int32], angle : Double) -> Unit {
  let radians = -angle * 3.141592653589793 / 180.0
  let c = @math.cos(radians)
  let s = @math.sin(radians)
  for i = 0; i < 9; i = i + 1 {
    matrix[i] = 0
  }
  matrix[0] = (c * 65536.0).to_int()
  matrix[1] = (-s * 65536.0).to_int()
  matrix[3] = (s * 65536.0).to_int()
  matrix[4] = (c * 65536.0).to_int()
  matrix[8] = 1 << 30
}

///|
/// `av_display_matrix_flip`. */
pub fn av_display_matrix_flip(
  matrix : Array[Int32],
  hflip : Int32,
  vflip : Int32,
) -> Unit {
  let flip : Array[Int32] = [
    1 - 2 * (if hflip != 0 { 1 } else { 0 }),
    1 - 2 * (if vflip != 0 { 1 } else { 0 }),
    1,
  ]
  if hflip != 0 || vflip != 0 {
    for i = 0; i < 9; i = i + 1 {
      matrix[i] = matrix[i] * flip[i % 3]
    }
  }
}
