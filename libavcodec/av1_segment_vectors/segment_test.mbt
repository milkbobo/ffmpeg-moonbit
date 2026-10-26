///|
test "segment branches and terminal CDFs match dav1d" {
  for c in 0..<96 {
    let variant = c % 12
    let current = FixedArray::makei(64 * 64, i => ((i * 3 + c) % 8).to_byte())
    let previous = FixedArray::makei(64 * 64, i => {
      (3 + (i * 5 + c) % 5).to_byte()
    })
    previous[36 * 64 + 39] = (c % 3).to_byte()
    current[34 * 64 + 35] = (c % 8).to_byte()
    current[33 * 64 + 36] = (c / 4 % 8).to_byte()
    current[33 * 64 + 35] = (if c % 4 == 0 {
      c % 8
    } else if c % 4 == 1 {
      c / 4 % 8
    } else {
      (c + 2) % 8
    }).to_byte()
    let bytes : Array[Byte] = []
    let mut seed = 0x12345678U + c.reinterpret_as_uint() * 977U
    for _ in 0..<512 {
      seed = seed * 1664525U + 1013904223U
      bytes.push(((seed >> 16) & 255U).to_byte())
    }
    let msac = @libavcodec.Av1Msac::init(Bytes::from_array(bytes), c >= 48)
    let cdf = @libavcodec.av1_cdf_copy_defaults(80)
    let ctx : @libavcodec.Av1SegmentContext = {
      msac,
      cdf,
      enabled: true,
      update_map: variant >= 2,
      temporal: variant >= 6,
      preskip: variant % 2 != 0,
      last_active: c % 8,
      current,
      previous: if c % 3 != 0 {
        Some(previous)
      } else {
        None
      },
      stride: 64,
    }
    let (id, pred) = ctx.read_id(
      36,
      34,
      4,
      3,
      c / 3 % 2 != 0,
      c / 5 % 2 != 0,
      c % 2 + c / 2 % 2,
      c / 12 % 2 != 0,
    )
    let actual : Array[UInt32] = [
      id.reinterpret_as_uint(),
      pred.reinterpret_as_uint(),
      msac.rng,
      (msac.dif >> 32).to_uint(),
    ]
    for value in cdf.seg_pred {
      actual.push(value.to_uint())
    }
    for value in cdf.seg_id {
      actual.push(value.to_uint())
    }
    for i in 0..<34 {
      assert_eq(
        actual[i],
        segment_reference[c * 34 + i],
        msg="case \{c}, field \{i}",
      )
    }
  }
}
