/// Range-coder encoder round trip: encode a deterministic symbol sequence,
/// decode it back with the existing `OpusRangeDecoder`, and require identical
/// values (including the raw-bits tail and the encoder's Laplace rewrite).

///|
fn[T] opus_enc_test_ok(r : Result[T, String]) -> T {
  match r {
    Ok(v) => v
    Err(e) => {
      println("opus enc rc test error: \{e}")
      abort("unexpected error")
    }
  }
}

///|
fn opus_enc_rc_roundtrip() -> Unit raise {
  let enc = @libavcodec.OpusRangeEncoder::new()
  enc.init()
  // deterministic symbol stream exercising every encoder primitive
  let cdf : Array[Int32] = [8, 2, 5, 6, 8]
  let laps : Array[Int] = []
  let raws : Array[UInt32] = []
  for k in 0..<7 {
    let v = (k * 3 + 1) % 4
    enc.encode_cdf(v, cdf)
    enc.encode_log(k & 1, 3)
    enc.encode_uint(((k * 137 + 11) % 1000).reinterpret_as_uint(), 1000U)
    enc.encode_uint_step(((k * 3) % 7).reinterpret_as_uint(), 4)
    enc.encode_uint_tri(((k * 5) % 9).reinterpret_as_uint(), 8)
    let q = ((k * 11) % 23) - 11
    let (_, out) = enc.encode_laplace(q, 22000U, 8672)
    laps.push(out)
    enc.put_raw(((k * 89 + 3) & 0xFF).reinterpret_as_uint(), 8)
    raws.push(((k * 89 + 3) & 0xFF).reinterpret_as_uint())
  }
  let size = (enc.tell_frac() + 7) >> 3
  let dst : FixedArray[Byte] = FixedArray::make(size, b'\x00')
  enc.end(dst, 0, size)
  let bytes : Array[Byte] = []
  for i in 0..<size {
    bytes.push(dst[i])
  }
  let dec = opus_enc_test_ok(@libavcodec.opus_rc_init(Bytes::from_array(bytes)))
  for k in 0..<7 {
    let v = (k * 3 + 1) % 4
    assert_eq(dec.decode_cdf(cdf).unwrap(), v)
    assert_eq(dec.decode_log(3).unwrap(), k & 1)
    assert_eq(dec.decode_uint(1000U).unwrap(), ((k * 137 + 11) % 1000).reinterpret_as_uint())
    assert_eq(dec.decode_step(4).unwrap(), (k * 3) % 7)
    assert_eq(dec.decode_tri(8).unwrap(), (k * 5) % 9)
    assert_eq(dec.decode_laplace(22000, 8672).unwrap(), laps[k])
    assert_eq(dec.get_raw(8).unwrap(), raws[k])
  }
}

///|
test "opus_rc_encoder_roundtrip" {
  opus_enc_rc_roundtrip()
}
