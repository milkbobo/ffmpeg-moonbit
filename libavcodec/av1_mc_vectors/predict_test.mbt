///|
test "AV1 block MV converts to dav1d luma and chroma phases" {
  let y = @av1_mc_core.av1_mc_plane_position(
    64, 64, 64, 64, 3, 5, 2, 2, -9, 17, 0, 0,
  )
  assert_true(!y.scaled)
  assert_eq((y.w, y.h), (8, 8))
  assert_eq((y.src_x, y.src_y), (14, 18))
  assert_eq((y.mx, y.my), (2, 14))

  let uv = @av1_mc_core.av1_mc_plane_position(
    64, 64, 64, 64, 3, 5, 2, 2, -9, 17, 1, 1,
  )
  assert_true(!uv.scaled)
  assert_eq((uv.w, uv.h), (4, 4))
  assert_eq((uv.src_x, uv.src_y), (7, 9))
  assert_eq((uv.mx, uv.my), (1, 7))
}

///|
test "AV1 scaled MV converts to dav1d start and step coordinates" {
  let y = @av1_mc_core.av1_mc_plane_position(
    64, 64, 80, 48, 2, 3, 2, 2, 7, -11, 0, 0,
  )
  assert_true(y.scaled)
  assert_eq((y.w, y.h), (8, 8))
  assert_eq((y.mx, y.my), (8640, 9792))
  assert_eq((y.step_x, y.step_y), (1280, 768))

  let uv = @av1_mc_core.av1_mc_plane_position(
    64, 64, 80, 48, 2, 3, 2, 2, 7, -11, 1, 1,
  )
  assert_eq((uv.w, uv.h), (4, 4))
  assert_eq((uv.mx, uv.my), (4400, 4848))
  assert_eq((uv.step_x, uv.step_y), (1280, 768))

  let negative = @av1_mc_core.av1_mc_plane_position(
    64, 64, 80, 48, 0, 0, 2, 2, -63, -63, 0, 0,
  )
  assert_eq((negative.mx, negative.my), (-9920, -6144))
}

///|
test "AV1 plane prediction dispatches to existing unscaled and scaled MC" {
  let src = FixedArray::makei(80 * 64, i => (i * 37 + i / 80 * 13) & 255)
  let plain = @av1_mc_core.av1_mc_predict_plane(
    src, 80, 80, 64, 80, 64, 2, 3, 2, 2, -9, 17, 0, 0, 4, 8,
  )
  let expected_plain = @av1_mc_core.av1_mc_put_unscaled(
    src, 80, 80, 64, 10, 10, 8, 8, 2, 14, 4, 8,
  )
  for i in 0..<plain.length() {
    assert_eq(plain[i], expected_plain[i])
  }

  let scaled = @av1_mc_core.av1_mc_predict_plane(
    src, 80, 80, 48, 64, 64, 2, 3, 2, 2, 7, -11, 0, 0, 0, 8,
  )
  let expected_scaled = @av1_mc_core.av1_mc_put_scaled(
    src, 80, 80, 48, 8, 8, 8640, 9792, 1280, 768, 0, 8,
  )
  for i in 0..<scaled.length() {
    assert_eq(scaled[i], expected_scaled[i])
  }
  let prep = @av1_mc_core.av1_mc_prepare_plane(
    src, 80, 80, 48, 64, 64, 2, 3, 2, 2, 7, -11, 0, 0, 0, 8,
  )
  let expected_prep = @av1_mc_core.av1_mc_prep_scaled(
    src, 80, 80, 48, 8, 8, 8640, 9792, 1280, 768, 0, 8,
  )
  for i in 0..<prep.length() {
    assert_eq(prep[i], expected_prep[i])
  }
}
