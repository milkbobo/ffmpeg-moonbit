///|
test "h264 high amplitude: signed 4x4 and 8x8 quantisation error bounds" {
  for bit_depth in [10, 12, 14] {
    let center = 1 << (bit_depth - 1)
    let amplitude = center - 1
    for dct8 in [false, true] {
      let size = if dct8 { 8 } else { 4 }
      for qp_user in [0, 26] {
        let qp = h264_enc_qp_ext(qp_user, bit_depth)
        for pattern in 0..<4 {
          let res = Array::makei(size * size, i => {
            let positive = match pattern {
              0 => true
              1 => false
              2 => (i / size + i % size) % 2 == 0
              _ => i % size < size / 2
            }
            if positive {
              amplitude
            } else {
              -amplitude
            }
          })
          let pps = new_h264_pps()
          let qmul = if dct8 {
            h264_build_dequant8(pps, 0, qp)
          } else {
            h264_build_dequant4(pps, 0, qp)
          }
          let levels = if dct8 {
            h264_enc_fdct8_quant_res(res, 0, qp)
          } else {
            h264_enc_fdct_quant_res(res, 0, qp)
          }
          let mb = Array::makei(size * size, i => {
            h264_enc_dequant_level(levels[i], qmul[i], bit_depth~)
          })
          let plane = Array::make(size * size, center)
          if dct8 {
            h264_idct8_add(plane, 0, size, mb, 0, bit_depth~)
          } else {
            h264_idct_add(plane, 0, size, mb, 0, bit_depth~)
          }
          let bound = (2 + (1 << (qp_user / 6))) << (bit_depth - 8)
          for i in 0..<(size * size) {
            assert_true(
              (plane[i] - center - res[i]).abs() <= bound,
              msg="depth=\{bit_depth} dct8=\{dct8} qp=\{qp_user} pattern=\{pattern} sample=\{i} got=\{plane[i]} expected=\{center + res[i]} bound=\{bound}",
            )
          }
        }
      }
    }
  }
}
