///|
test "lcg probe" {
  let buf = av1_mvres_test_lcg(0x12345678, 8)
  let mut s = ""
  for i in 0..<8 {
    s = s + "\{buf[i].to_int()} "
  }
  println("MB lcg bytes: " + s)
  let msac = @libavcodec.Av1Msac::init(
    av1_mvres_test_lcg(0x12345678, 8192),
    false,
  )
  println("rng \{msac.rng} dif \{msac.dif} cnt \{msac.cnt} pos \{msac.pos}")
}
