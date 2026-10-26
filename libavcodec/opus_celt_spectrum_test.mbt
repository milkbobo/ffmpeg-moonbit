///|
test "opus CELT: TF subdivision supports sixteen PVQ blocks" {
  let rc = @libavcodec.opus_rc_init(b"\xff\x00\x88\x61").unwrap()
  let band = rc.decode_celt_band(32, 1, 2, 16, 1.0).unwrap()
  assert_eq(band.coefficients.length(), 32)
  let mask = band.collapse_mask
  assert_true(mask != 0U && (mask & (mask - 1U)) == 0U)
  let mut energy = 0.0
  for value in band.coefficients {
    energy += value.to_double() * value.to_double()
  }
  assert_true((energy - 1.0).abs() < 0.000001)
}

///|
test "opus CELT: canonical silence commits history without changing its input" {
  for channels in [1, 2] {
    for size in 0..<4 {
      let history = @libavcodec.OpusCeltHistory::new()
      let rc = @libavcodec.opus_rc_init(b"\xff\xfe").unwrap()
      let frame = rc
        .decode_celt_coefficients(history, channels, 120 << size, 0, 13)
        .unwrap()
      assert_true(frame.silence && !frame.transient && !frame.anticollapse)
      assert_eq(frame.blocks, 1)
      assert_eq(frame.coefficients.length(), channels)
      assert_eq(frame.history.seed, rc.range)
      for row in frame.coefficients {
        for value in row {
          assert_eq(value, 0.0)
        }
      }
      for channel in 0..<2 {
        for band in 0..<21 {
          assert_eq(
            frame.history.energy[channel * 21 + band],
            if band < 13 {
              -28.0
            } else {
              0.0
            },
          )
        }
      }
      assert_eq(history.energy, Array::make(42, 0.0))
      assert_eq(history.previous, Array::make(84, -28.0))
    }
  }
}

///|
test "opus CELT: malformed public spectral state fails before entropy consumption" {
  let history = @libavcodec.OpusCeltHistory::new()
  history.previous.push(-28.0)
  let rc = @libavcodec.opus_rc_init(b"\x00\x23\x88\x61").unwrap()
  let before = rc.tell_frac()
  assert_true(
    rc.decode_celt_coefficients(history, 1, 120, 0, 13)
    is Err("opus: invalid CELT spectral history"),
  )
  let bad = @libavcodec.OpusCeltHistory::new()
  bad.previous[0] = Float::reinterpret_from_uint(0x7fc00000U)
  assert_true(
    rc.decode_celt_coefficients(bad, 1, 120, 0, 13)
    is Err("opus: nonfinite CELT spectral history"),
  )
  assert_eq(rc.tell_frac(), before)
  let setup_rc = @libavcodec.opus_rc_init(b"\xff\xfe").unwrap()
  let setup = setup_rc.decode_celt_setup(1, 120, 0, 13).unwrap()
  let mark = setup_rc.tell_frac()
  setup.tf_change.push(0)
  assert_true(
    setup_rc.decode_celt_spectrum(setup)
    is Err("opus: invalid CELT spectrum band arrays"),
  )
  assert_eq(setup_rc.tell_frac(), mark)
}
