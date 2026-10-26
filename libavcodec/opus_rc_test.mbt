///|
test "opus entropy: public input checks do not consume state" {
  assert_true(@libavcodec.opus_rc_init(b"") is Err("opus: empty entropy frame"))
  assert_true(
    @libavcodec.opus_rc_init(Bytes::make(1276, b'\x00'))
    is Err("opus: entropy frame exceeds 1275 bytes"),
  )
  let rc = @libavcodec.opus_rc_init(b"\xff\x22\x33\x44").unwrap()
  let before = rc.tell_frac()
  assert_true(rc.decode_log(0) is Err("opus: invalid logarithmic probability"))
  assert_true(
    rc.decode_uint(1U) is Err("opus: uniform size must be at least two"),
  )
  assert_true(rc.decode_step(-1) is Err("opus: invalid step distribution"))
  assert_true(rc.decode_tri(3) is Err("opus: invalid triangular distribution"))
  assert_true(
    rc.decode_laplace(0, 100) is Err("opus: invalid Laplace distribution"),
  )
  assert_true(
    rc.decode_laplace(6000, 16385) is Err("opus: invalid Laplace distribution"),
  )
  assert_true(
    rc.decode_cdf([16, 4, 3, 16])
    is Err("opus: invalid cumulative distribution"),
  )
  assert_true(
    rc.decode_cdf([16, 4, 15]) is Err("opus: invalid cumulative distribution"),
  )
  assert_true(rc.get_raw(26) is Err("opus: invalid raw bit count"))
  assert_eq(rc.tell_frac(), before)
  assert_eq(rc.get_raw(0).unwrap(), 0U)
  assert_eq(rc.get_raw(8).unwrap(), 0x44U)
  assert_eq(rc.get_raw(24).unwrap(), 0xff2233U)
  let end = rc.tell_frac()
  assert_true(rc.get_raw(1) is Err("opus: truncated raw bits"))
  assert_eq(rc.tell_frac(), end)
}

///|
test "opus entropy: zero probability CDF bins and degenerate theta distributions" {
  let rc = @libavcodec.opus_rc_init(b"\x00\xff\xff\xff").unwrap()
  let before = rc.tell_frac()
  assert_eq(rc.decode_cdf([16, 0, 16, 16]).unwrap(), 1)
  assert_eq(rc.decode_step(0).unwrap(), 0)
  assert_eq(rc.decode_tri(0).unwrap(), 0)
  assert_eq(rc.tell_frac(), before)
}
