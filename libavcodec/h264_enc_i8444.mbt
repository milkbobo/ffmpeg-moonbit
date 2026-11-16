///|
/// Three-plane I8x8 replay: luma chooses the four shared prediction modes,
/// Cb/Cr replay those modes using their own intra dequantisation matrices.
fn h264_enc_i8444_pass(
  src : Array[Array[Int32]],
  rec : Array[Array[Int32]],
  stride : Int32,
  mb_x : Int32,
  mb_y : Int32,
  mb_width : Int32,
  pps : H264Pps,
  qps : Array[Int32],
  levels : Array[Int32],
  modes : Array[Int32],
  bit_depth : Int32,
  fixed_modes~ : Array[Int32] = [],
) -> Result[Int32, String] {
  let mut cbp = 0
  for p in 0..<3 {
    let store = Array::make(256, 0)
    let mb = Array::make(256, 0)
    let fixed = if p == 0 {
      fixed_modes
    } else {
      [modes[0], modes[2], modes[8], modes[10]]
    }
    match
      h264_enc_luma_i8_pass(
        src[p],
        rec[p],
        stride,
        mb_x,
        mb_y,
        pps,
        qps[p],
        store,
        modes,
        mb,
        h264_enc_i8_avail(mb_x, mb_y, mb_width),
        fixed_modes=fixed,
        bit_depth~,
        matrix=p,
      ) {
      Ok((_, pattern)) => cbp = cbp | pattern
      Err(e) => return Err(e)
    }
    for i in 0..<256 {
      levels[256 * p + i] = store[i]
    }
  }
  Ok(cbp)
}
