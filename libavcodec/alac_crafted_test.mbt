///|
/// Hand-crafted ALAC packets for the decoder paths the reference encoder does
/// not emit: uncompressed elements, the implicit `max_samples_per_frame` size,
/// 20/32-bit output scaling, and malformed-cookie/packet rejection.

///|
fn alac_test_cookie(
  max_samples : UInt32,
  sample_size : Int32,
  channels : Int32,
  sample_rate : UInt32,
) -> Bytes {
  let out : Array[Byte] = []
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x24')
  for b in b"alac" {
    out.push(b)
  }
  for b in b"\x00\x00\x00\x00" {
    out.push(b)
  }
  out.push(((max_samples >> 24) & 0xFF).to_byte())
  out.push(((max_samples >> 16) & 0xFF).to_byte())
  out.push(((max_samples >> 8) & 0xFF).to_byte())
  out.push((max_samples & 0xFF).to_byte())
  out.push(b'\x00') // compatible version
  out.push(sample_size.to_byte())
  out.push(b'\x28') // history mult 40
  out.push(b'\x0a') // initial history 10
  out.push(b'\x0e') // rice limit 14
  out.push(channels.to_byte())
  for b in b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" {
    out.push(b)
  }
  out.push(((sample_rate >> 24) & 0xFF).to_byte())
  out.push(((sample_rate >> 16) & 0xFF).to_byte())
  out.push(((sample_rate >> 8) & 0xFF).to_byte())
  out.push((sample_rate & 0xFF).to_byte())
  Bytes::from_array(out)
}

///|
fn alac_test_uncompressed_packet(
  element : Int32,
  has_size : Bool,
  nb_samples : Int32,
  sample_size : Int32,
  samples : Array[Int32],
  with_end~ : Bool = true,
) -> Bytes {
  let bw = @libavcodec.BitWriter::new()
  bw.put(element.reinterpret_as_uint(), 3)
  bw.put(0, 4) // element instance
  bw.put(0, 12) // unused header bits
  bw.put_bit(if has_size { 1 } else { 0 })
  bw.put(0, 2) // extra bits
  bw.put_bit(1) // not compressed
  if has_size {
    bw.put(nb_samples.reinterpret_as_uint(), 32)
  }
  for v in samples {
    bw.put(v.reinterpret_as_uint(), sample_size)
  }
  if with_end {
    bw.put(7, 3) // TYPE_END
  }
  bw.finish()
}

///|
test "alac: uncompressed mono element with explicit size" {
  let cookie = alac_test_cookie(8U, 16, 1, 8000U)
  let dec = @libavcodec.alac_decoder_new(cookie).unwrap()
  let packet = alac_test_uncompressed_packet(0, true, 3, 16, [1, -2, 3])
  let frame = dec.decode_frame(packet).unwrap()
  assert_eq(frame.sample_rate, 8000)
  assert_eq(frame.channels, 1)
  assert_eq(frame.bits, 16)
  assert_eq(frame.nb_samples, 3)
  assert_eq(frame.samples, [1, -2, 3])
  assert_eq(frame.pcm_bytes(), b"\x01\x00\xfe\xff\x03\x00")
}

///|
test "alac: uncompressed stereo uses max_samples_per_frame" {
  let cookie = alac_test_cookie(4U, 16, 2, 44100U)
  let dec = @libavcodec.alac_decoder_new(cookie).unwrap()
  let samples : Array[Int32] = [10, -10, 20, -20, 30, -30, 40, -40]
  let packet = alac_test_uncompressed_packet(1, false, 4, 16, samples)
  let frame = dec.decode_frame(packet).unwrap()
  assert_eq(frame.nb_samples, 4)
  assert_eq(frame.samples, samples)
}

///|
test "alac: 20-bit and 32-bit output scaling" {
  let dec20 = @libavcodec.alac_decoder_new(alac_test_cookie(4U, 20, 1, 8000U)).unwrap()
  let f20 = dec20
    .decode_frame(alac_test_uncompressed_packet(0, true, 2, 20, [1, -1]))
    .unwrap()
  assert_eq(f20.samples, [4096, -4096])
  let dec32 = @libavcodec.alac_decoder_new(alac_test_cookie(4U, 32, 1, 8000U)).unwrap()
  let f32 = dec32
    .decode_frame(
      alac_test_uncompressed_packet(0, true, 2, 32, [1, -2147483647 - 1]),
    )
    .unwrap()
  assert_eq(f32.samples, [1, -2147483648])
  assert_eq(f32.pcm_bytes().length(), 8)
}

///|
test "alac: rejects invalid cookies and packets" {
  let short_cookie = @libavcodec.alac_decoder_new(b"\x00\x00\x00\x24")
  assert_true(short_cookie is Err(_))
  let bad_depth : Array[Byte] = []
  for b in alac_test_cookie(4096U, 16, 1, 44100U) {
    bad_depth.push(b)
  }
  bad_depth[17] = b'\x11'
  let bad_depth_cookie = @libavcodec.alac_decoder_new(
    Bytes::from_array(bad_depth),
  )
  assert_true(bad_depth_cookie is Err(_))
  let dec = @libavcodec.alac_decoder_new(alac_test_cookie(4U, 16, 1, 44100U)).unwrap()
  // No end tag.
  let no_end = alac_test_uncompressed_packet(
    0,
    true,
    2,
    16,
    [1, 2],
    with_end=false,
  )
  assert_true(dec.decode_frame(no_end) is Err(_))
  // Channel count larger than the cookie.
  let cpe = alac_test_uncompressed_packet(1, true, 2, 16, [0, 0, 0, 0])
  assert_true(dec.decode_frame(cpe) is Err(_))
}
