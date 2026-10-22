///|
/// Interleave every entropy operation on the same forward/backward frame.
/// Expected symbols AND complete arithmetic state are from original rc.c.
test "opus rc: 448 mixed entropy states match FFmpeg C" {
  let cdf : Array[Int32] = [256, 1, 5, 17, 49, 113, 193, 255, 256]
  for seed in 0..<32 {
    let bytes : Array[Byte] = []
    for i in 0..<64 {
      bytes.push(((seed * 67 + i * 29 + ((i * i) >> 2)) & 255).to_byte())
    }
    let rc = opus_rc_init(Bytes::from_array(bytes[:])).unwrap()
    for op in 0..<14 {
      let result = match op % 7 {
        0 => rc.decode_log(1 + seed % 12).unwrap()
        1 => rc.decode_cdf(cdf).unwrap()
        2 => rc.decode_uint(if op < 7 { 251U } else { 65537U }).unwrap().reinterpret_as_int()
        3 => rc.decode_step(1 + seed % 24).unwrap()
        4 => rc.decode_tri(2 * (1 + seed % 32)).unwrap()
        5 => rc.decode_laplace(6000 + seed * 13, 9000 + seed * 31).unwrap()
        _ => rc.get_raw(1 + seed % 25).unwrap().reinterpret_as_int()
      }
      let state = "\{result} \{rc.range} \{rc.value} \{rc.total_bits} \{rc.tell()} \{rc.tell_frac()}"
      assert_eq(state, opus_rc_reference_states[seed * 14 + op])
    }
  }
}

///|
test "opus rc: exact integer square root bounds" {
  for n in [0U, 1U, 2U, 3U, 4U, 255U, 256U, 65535U, 0x7fffffffU, 0xffffffffU] {
    let r = opus_rc_isqrt(n).to_uint64()
    assert_true(r * r <= n.to_uint64())
    assert_true((r + 1UL) * (r + 1UL) > n.to_uint64())
  }
}
