///|
test "h264 SSD: 12 and 14 bit macroblock costs exceed Int32 safely" {
  let black = Array::make(400, 0)
  let white = Array::make(400, 16383)
  white[0] = 0 // Outside the strided 16x16 rectangle.
  black[399] = 16383
  let sum = h264_enc_plane_ssd(white, black, 22, 20, 16, 16)
  assert_eq(sum, 68711088384L)
  assert_eq(h264_enc_plane_ssd(black, white, 22, 20, 16, 16), sum)
  assert_eq(sum * 3L, 206133265152L)
  let high12 = Array::make(256, 4095)
  let zero = Array::make(256, 0)
  assert_eq(
    h264_enc_plane_ssd(high12, zero, 0, 16, 16, 16) * 3L / 2L,
    6439305600L,
  )
}

///|
test "h264 quantisation: large coefficients retain magnitude and sign" {
  assert_eq(h264_enc_quant_val(262080, 0, 0), 104830)
  assert_eq(h264_enc_quant_val(-262080, 0, 0), -104830)
  let positive = h264_enc_fdct8_quant_res(Array::make(64, 4095), 0, 0)
  let negative = h264_enc_fdct8_quant_res(Array::make(64, -4095), 0, 0)
  assert_eq(positive[0], 52415)
  assert_eq(negative[0], -52415)
}
