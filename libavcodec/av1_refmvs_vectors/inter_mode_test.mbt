///|
test "AV1 inter mode readers stay within candidate and mode bounds" {
  let (rf, rows, rp, _) = av1_refmvs_test_build(1)
  let single = @libavcodec.av1_refmvs_find(
    rf, rows, rp, 40, 0, 32, 0, 32, 1, -1, 17, true, 8, 4,
  )
  let compound = @libavcodec.av1_refmvs_find(
    rf, rows, rp, 40, 0, 32, 0, 32, 1, 4, 17, true, 8, 4,
  )
  for fill in [b'\x00', b'\x55', b'\xaa', b'\xff'] {
    let data : Array[Byte] = []
    for _ in 0..<64 {
      data.push(fill)
    }
    let buf = Bytes::from_array(data)
    let cdf1 = @libavcodec.av1_cdf_copy_defaults(100)
    let msac1 = @libavcodec.Av1Msac::init(buf, false)
    let one = @libavcodec.av1_inter_read_single_mv(
      msac1, cdf1, rf, single, 0, 17, 8, 4, false,
    )
    assert_true(one.mode >= 0 && one.mode < 4)
    assert_true(one.drl_idx >= 0 && one.drl_idx < 4)
    let cdf2 = @libavcodec.av1_cdf_copy_defaults(100)
    let msac2 = @libavcodec.Av1Msac::init(buf, false)
    let two = @libavcodec.av1_inter_read_compound_mv(
      msac2, cdf2, rf, compound, 0, 3, 17, 8, 4,
    )
    assert_true(two.mode >= 0 && two.mode < 8)
    assert_true(two.drl_idx >= 0 && two.drl_idx < 4)
  }
}
