///|
/// Sum squared sample errors without truncating high-depth macroblock costs.
fn h264_enc_plane_ssd(
  src : Array[Int32],
  rec : Array[Int32],
  base : Int32,
  stride : Int32,
  width : Int32,
  height : Int32,
) -> Int64 {
  let mut sum = 0L
  for row in 0..<height {
    for col in 0..<width {
      let i = base + row * stride + col
      let d = src[i].to_int64() - rec[i].to_int64()
      sum += d * d
    }
  }
  sum
}
