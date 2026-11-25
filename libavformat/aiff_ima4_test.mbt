///|
/// Two complete stereo IMA4 blocks after a two-byte SSND offset, followed by
/// one incomplete byte, the SSND pad, and an ANNO chunk larger than one block.
/// COMM deliberately declares three blocks so that stream duration and packet
/// availability are tested independently (see upstream aiffdec.c).
fn aiff_ima4_stereo_with_tail() -> Bytes {
  let header = b"FORM\x00\x00\x01\x18AIFCFVER\x00\x00\x00\x04\xa2\x80\x51\x40COMM\x00\x00\x00\x18\x00\x02\x00\x00\x00\x03\x00\x10\x40\x0b\xfa\x00\x00\x00\x00\x00\x00\x00ima4\x00\x00SSND\x00\x00\x00\x93\x00\x00\x00\x02\x00\x00\x00\x00\xff\xff"
  let anno = b"ANNO\x00\x00\x00\x44"
  let data : Array[Byte] = []
  for byte in header {
    data.push(byte)
  }
  for _ in 0..<138 {
    data.push(0)
  }
  for byte in anno {
    data.push(byte)
  }
  for _ in 0..<68 {
    data.push(b'x')
  }
  Bytes::from_array(data)
}

///|
test "aiff IMA4: COMM counts blocks and SSND bounds complete stereo packets" {
  let file = aiff_ima4_stereo_with_tail()
  let demux = @libavformat.av_aiff_open(file).unwrap()
  assert_eq(demux.format.codec, "adpcm_ima_qt")
  assert_eq(demux.format.channels, 2)
  assert_eq(demux.format.sample_rate, 8000)
  assert_eq(demux.format.bits, 16)
  assert_eq(demux.format.block_align, 68)
  assert_eq(demux.sample_count, 192L)
  assert_eq(demux.data_offset, 74L)
  assert_eq(demux.data_size, 136L)
  assert_eq(demux.packets.length(), 2)
  for i, packet in demux.packets {
    assert_eq(packet.pos, 74L + i.to_int64() * 68L)
    assert_eq(packet.size, 68)
    assert_eq(packet.pts, i.to_int64() * 64L)
    assert_eq(packet.duration, 64)
  }
}

///|
test "aiff PCM: declared count cannot consume the SSND pad or a later chunk" {
  let file = b"FORM\x00\x00\x00\x3cAIFFCOMM\x00\x00\x00\x12\x00\x01\x00\x00\x00\x0a\x00\x10\x40\x0b\xfa\x00\x00\x00\x00\x00\x00\x00SSND\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00\x00\x00\x12\x34\xff\x00ANNO\x00\x00\x00\x02ok"
  let demux = @libavformat.av_aiff_open(file).unwrap()
  assert_eq(demux.format.codec, "pcm_s16be")
  assert_eq(demux.format.block_align, 2)
  assert_eq(demux.sample_count, 1L)
  assert_eq(demux.data_offset, 54L)
  assert_eq(demux.data_size, 2L)
  assert_eq(demux.packets.length(), 1)
  assert_eq(demux.packets[0].duration, 1)
}

///|
test "aiff IMA4: reject SSND offsets larger than the chunk payload" {
  let file = aiff_ima4_stereo_with_tail()
  let invalid = Bytes::from_array([
    for i in 0..<file.length() => match i {
      64 => 0x7f
      65 | 66 | 67 => 0xff
      _ => file[i]
    }
  ])
  match @libavformat.av_aiff_open(invalid) {
    Err(message) => assert_eq(message, "aiff: invalid SSND offset")
    Ok(_) => fail("expected an invalid SSND offset")
  }
}
