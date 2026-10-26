///|
test "AV1 reference trees produce valid single and compound indices" {
  let top : @libavcodec.Av1InterNeighbor = {
    intra: false,
    comp_type: 0,
    ref0: 0,
    ref1: -1,
    filter0: 3,
    filter1: 3,
  }
  let left : @libavcodec.Av1InterNeighbor = {
    intra: false,
    comp_type: 1,
    ref0: 4,
    ref1: 6,
    filter0: 3,
    filter1: 3,
  }
  let expected : FixedArray[(Int32, Int32)] = [
    (0, -1),
    (0, 1),
    (4, -1),
    (0, 4),
    (6, -1),
    (0, 6),
    (6, -1),
    (3, 6),
  ]
  for fill_idx, fill in [b'\x00', b'\x55', b'\xaa', b'\xff'] {
    let data : Array[Byte] = []
    for _ in 0..<64 {
      data.push(fill)
    }
    let buf = Bytes::from_array(data)
    for compound in [false, true] {
      let msac = @libavcodec.Av1Msac::init(buf, false)
      let cdf = @libavcodec.av1_cdf_copy_defaults(100)
      let (a, b) = @libavcodec.av1_inter_read_refs(
        msac,
        cdf,
        Some(top),
        Some(left),
        compound,
      )
      let case_idx = fill_idx * 2 + (if compound { 1 } else { 0 })
      assert_eq((a, b), expected[case_idx])
      assert_true(a >= 0 && a < 7)
      if compound {
        assert_true(b >= 0 && b < 7 && a != b)
      } else {
        assert_eq(b, -1)
      }
    }
  }
}
