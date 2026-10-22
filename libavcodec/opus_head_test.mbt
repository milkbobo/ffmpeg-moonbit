///|
fn opus_test_head(channels : Int, family : Int, streams : Int, coupled : Int, map : Array[Byte]) -> Bytes {
  let prefix = b"OpusHead\x01" + Bytes::from_array([channels.to_byte()][:]) +
    b"\x38\x01\x44\xac\x00\x00\x80\xff" + Bytes::from_array([family.to_byte()][:])
  if family == 0 { prefix } else {
    prefix + Bytes::from_array([streams.to_byte(), coupled.to_byte()][:]) + Bytes::from_array(map[:])
  }
}

///|
test "opus head: families, signed gain, rate metadata, duplicates and silence" {
  for channels in [1,2] {
    let head = @libavcodec.opus_parse_head(opus_test_head(channels, 0, 0, 0, [])).unwrap()
    assert_eq(head.channels, channels)
    assert_eq(head.pre_skip, 312)
    assert_eq(head.input_sample_rate, 44100U)
    assert_eq(head.output_gain, -128)
    assert_eq(head.stream_count, 1)
    assert_eq(head.coupled_count, channels - 1)
    assert_eq(head.channel_map, [for i in 0..<channels => i])
  }
  // Family 2 preserves ACN ordering; 4 = (1+1)^2.
  let ambi = @libavcodec.opus_parse_head(opus_test_head(4, 2, 4, 0, [0,1,2,3])).unwrap()
  for i, map in ambi.output_map {
    assert_eq(map.stream_index, i)
    assert_eq(map.channel_index, 0)
    assert_true(!map.silence && map.copy_from is None)
  }
  // Unspecified layouts allow duplicate and silent output channels, as C does.
  let custom = @libavcodec.opus_parse_head(opus_test_head(4, 255, 1, 1, [1,0,1,255])).unwrap()
  assert_eq(custom.output_map[0].stream_index, 0)
  assert_eq(custom.output_map[0].channel_index, 1)
  assert_eq(custom.output_map[1].channel_index, 0)
  assert_true(custom.output_map[2].copy_from is Some(0))
  assert_true(custom.output_map[3].silence)
  assert_eq(custom.output_map[3].stream_index, -1)
}

///|
test "opus head: invalid and truncated headers have specific errors" {
  let valid = opus_test_head(6, 1, 4, 2, [0,4,1,2,3,5])
  for n in 0..<19 {
    assert_true(@libavcodec.opus_parse_head(valid[:n].to_owned()) is Err("opus: truncated OpusHead"))
  }
  for n in 19..<27 {
    assert_true(@libavcodec.opus_parse_head(valid[:n].to_owned()) is Err("opus: truncated OpusHead mapping"))
  }
  let invalid : Array[(Bytes, String)] = [
    (b"opusHead" + valid[8:].to_owned(), "opus: invalid OpusHead signature"),
    (b"OpusHead\x10" + valid[9:].to_owned(), "opus: unsupported OpusHead version"),
    (opus_test_head(0,0,0,0,[]), "opus: zero channel count"),
    (opus_test_head(3,0,0,0,[]), "opus: mapping family 0 requires mono or stereo"),
    (opus_test_head(2,3,1,1,[0,1]), "opus: unsupported OpusHead mapping family"),
    (opus_test_head(2,255,0,0,[0,1]), "opus: invalid stream or coupled stream count"),
    (opus_test_head(2,255,1,2,[0,1]), "opus: invalid stream or coupled stream count"),
    (opus_test_head(2,255,255,1,[0,1]), "opus: invalid stream or coupled stream count"),
    (opus_test_head(9,1,9,0,[0,1,2,3,4,5,6,7,8]), "opus: mapping family 1 exceeds eight channels"),
    (opus_test_head(5,2,5,0,[0,1,2,3,4]), "opus: invalid ambisonic channel count"),
    (opus_test_head(2,255,1,0,[0,1]), "opus: channel map outside coded channels"),
  ]
  for (data, error) in invalid {
    match @libavcodec.opus_parse_head(data) { Err(e) => assert_eq(e, error); Ok(_) => fail("accepted invalid OpusHead") }
  }
}

///|
test "opus multistream: different frame counts, padding, DTX and truncation" {
  let head = @libavcodec.opus_parse_head(opus_test_head(2,255,2,0,[0,1])).unwrap()
  // First stream: two 2.5 ms frames, second stream: one 5 ms frame.
  let packets = head.parse_packet(b"\x81\x01\x11\x22\x88\x33").unwrap()
  assert_eq(packets.length(), 2)
  assert_eq(packets[0].packet.frame_count, 2)
  assert_eq(packets[1].packet.frame_count, 1)
  assert_eq(packets[0].packet.total_samples, 240)
  assert_eq(packets[1].packet.total_samples, 240)
  assert_eq(packets[1].offset, 4)
  let padded = head.parse_packet(b"\x83\x41\x02\x01\xaa\x00\x00\x80\xbb").unwrap()
  assert_eq(padded[0].packet.padding, 2)
  assert_eq(padded[0].packet.packet_size, 7)
  assert_eq(padded[1].offset, 7)
  let dtx = head.parse_packet(b"\x80\x00\x80").unwrap()
  assert_eq(dtx[0].packet.frame_sizes, [0])
  assert_eq(dtx[1].packet.frame_sizes, [0])
  assert_true(head.parse_packet(b"\x80\x01\xaa\x88\xbb") is Err("opus: mismatching multistream sample counts"))
  assert_true(head.parse_packet(b"\x80\x01\xaa") is Err("opus: empty packet"))
  assert_true(head.parse_packet(b"\x80\x02\xaa") is Err("opus: bad self-delimited frame length"))
  // Largest legal stream/channel count, including unused-byte boundaries.
  let maximum = @libavcodec.opus_parse_head(opus_test_head(255,255,255,0,
    [for i in 0..<255 => i.to_byte()])).unwrap()
  let payload : Array[Byte] = []
  for _ in 0..<254 { payload.push(b'\x80'); payload.push(b'\x00') }
  payload.push(b'\x80')
  let maximum_streams = maximum.parse_packet(Bytes::from_array(payload[:])).unwrap()
  assert_eq(maximum_streams.length(), 255)
  for i, stream in maximum_streams {
    assert_eq(stream.offset, 2 * i)
    assert_eq(stream.packet.total_samples, 120)
    assert_eq(stream.packet.frame_sizes, [0])
  }
}
