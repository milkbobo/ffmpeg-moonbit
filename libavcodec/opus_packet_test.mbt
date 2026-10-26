///|
test "opus framing: self-delimiting codes preserve frame spans and following stream" {
  let vectors : Array[(Bytes, Array[Int32], Array[Int32], Int32)] = [
    (b"\x80\x02\x11\x22\xee", [2], [2], 4),
    (b"\x81\x01\x11\x22\xee", [2, 3], [1, 1], 4),
    (b"\x82\x01\x02\x11\x22\x33\xee", [3, 4], [1, 2], 6),
    (b"\x83\x02\x01\x11\x22\xee", [3, 4], [1, 1], 5),
    (b"\x83\x82\x01\x02\x11\x22\x33\xee", [4, 5], [1, 2], 7),
    (b"\x83\xc2\x02\x01\x02\x11\x22\x33\x00\x00\xee", [5, 6], [1, 2], 10),
  ]
  for vector in vectors {
    let packet = @libavcodec.opus_parse_packet_with(vector.0, true).unwrap()
    assert_eq(packet.frame_offsets, vector.1)
    assert_eq(packet.frame_sizes, vector.2)
    assert_eq(packet.packet_size, vector.3)
    assert_eq(vector.0[packet.packet_size], b'\xee')
    for i in 0..<packet.frame_count {
      let start = packet.frame_offsets[i]
      assert_true(start >= 1)
      assert_true(
        start + packet.frame_sizes[i] <= packet.packet_size - packet.padding,
      )
    }
  }
}

///|
test "opus framing: reject oversized frames and negative CBR payload" {
  let huge = Bytes::from_array(Array::make(1277, b'\x00')[:])
  assert_true(
    @libavcodec.opus_parse_packet(huge)
    is Err("opus: frame size exceeds 1275 bytes"),
  )
  assert_true(
    @libavcodec.opus_parse_packet(b"\x83\x41\x01")
    is Err("opus: padding exceeds packet"),
  )
  for
    data in [
      b"\x80\x03\x01", b"\x81\x02\x01", b"\x82\x01\x03\x01", b"\x83\x02\x02\x01",
    ] {
    assert_true(
      @libavcodec.opus_parse_packet_with(data, true)
      is Err("opus: bad self-delimited frame length"),
    )
  }
  let dtx = @libavcodec.opus_parse_packet_with(b"\x80\x00\xee", true).unwrap()
  assert_eq(dtx.frame_sizes, [0])
  assert_eq(dtx.packet_size, 2)
}
