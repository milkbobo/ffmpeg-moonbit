///|
test "opus PVQ: signed two-dimensional order and zero codebook" {
  assert_eq(@libavcodec.opus_pvq_size(2, 1).unwrap(), 4U)
  let expected = [[1, 0], [0, 1], [0, -1], [-1, 0]]
  for i in 0..<4 {
    let vector = @libavcodec.opus_pvq_unrank(2, 1, i.reinterpret_as_uint()).unwrap()
    assert_eq(vector.pulses, expected[i])
    assert_eq(vector.norm_squared, 1L)
  }
  let rc = @libavcodec.opus_rc_init(b"\xff\x23\x88\x61").unwrap()
  let before = rc.tell_frac()
  let zero = rc.decode_pulses(176, 0).unwrap()
  assert_eq(zero.pulses, Array::make(176, 0))
  assert_eq(zero.norm_squared, 0L)
  assert_eq(rc.tell_frac(), before)
}

///|
test "opus PVQ: invalid public parameters leave entropy state unchanged" {
  let rc = @libavcodec.opus_rc_init(b"\x00\x23\x88\x61").unwrap()
  let before = rc.tell_frac()
  for
    (n, k) in [(0, 1), (1, 1), (177, 1), (2, -1), (2, 176), (14, 14), (40, 40)] {
    assert_true(
      rc.decode_pulses(n, k)
      is Err("opus: unsupported PVQ dimensions or pulse count"),
    )
  }
  assert_true(
    @libavcodec.opus_pvq_unrank(2, 1, 4U)
    is Err("opus: PVQ index outside codebook"),
  )
  assert_true(
    @libavcodec.opus_pvq_unrank(2, 0, 1U)
    is Err("opus: PVQ index outside codebook"),
  )
  assert_true(
    rc.decode_celt_band(8, 0, 0, 1, 1.0)
    is Err("opus: CELT band requires positive pulse count"),
  )
  for spread in [-1, 4] {
    assert_true(
      rc.decode_celt_band(8, 1, spread, 1, 1.0)
      is Err("opus: invalid CELT spread"),
    )
  }
  for blocks in [0, 3, 16] {
    assert_true(
      rc.decode_celt_band(8, 1, 0, blocks, 1.0)
      is Err("opus: invalid CELT block count"),
    )
  }
  assert_true(
    rc.decode_celt_band(6, 1, 0, 4, 1.0)
    is Err("opus: invalid CELT block count"),
  )
  let gains : Array[Float] = [
    -1.0,
    Float::reinterpret_from_uint(0x7f800000U),
    Float::reinterpret_from_uint(0x7fc00000U),
  ]
  for gain in gains {
    assert_true(
      rc.decode_celt_band(8, 1, 0, 1, gain)
      is Err("opus: invalid CELT band gain"),
    )
  }
  assert_eq(rc.tell_frac(), before)
  let band = rc.decode_celt_band(8, 1, 2, 8, 0.0).unwrap()
  for value in band.coefficients {
    assert_eq(value, 0.0)
  }
}
