///|
test "APE 3.80 frames recover word alignment and bit offsets" {
  let data : Array[Byte] = [b'M', b'A', b'C', b' ']
  ape_file_write_le(data, 3800, 2)
  ape_file_write_le(data, 2000, 2)
  ape_file_write_le(data, 32, 2)
  ape_file_write_le(data, 2, 2)
  ape_file_write_le(data, 44100, 4)
  ape_file_write_le(data, 0, 4)
  ape_file_write_le(data, 0, 4)
  ape_file_write_le(data, 2, 4)
  ape_file_write_le(data, 9, 4)
  ape_file_write_le(data, 42, 4)
  ape_file_write_le(data, 47, 4)
  data.push(b'\x00')
  data.push(b'\x03')
  for byte in 0..<22 {
    data.push(byte.to_byte())
  }
  let bytes = Bytes::from_array(data)
  let media = MediaFile::open(bytes)
  assert_eq(media.format_name(), "ape")
  let first = media.next_packet().unwrap()
  let last = media.next_packet().unwrap()
  assert_eq(first.pts, 0L)
  assert_eq(last.pts, 9216L)
  assert_eq(ape_file_u32(first.data, 0), 9216L)
  assert_eq(ape_file_u32(last.data, 0), 9L)
  assert_eq(ape_file_u32(first.data, 4), 0L)
  assert_eq(ape_file_u32(last.data, 4), 11L)
  assert_eq(first.data.length(), 20)
  assert_eq(last.data[8], b'\x04')
  assert_true(media.next_packet() is None)
  assert_true(av_ape_open(bytes[:40].to_owned()) is Err(_))
}

///|
test "APE 3.99 reads the descriptor before the seek table" {
  let data : Array[Byte] = [b'M', b'A', b'C', b' ']
  for value in [3990, 0] {
    ape_file_write_le(data, value, 2)
  }
  for value in [52, 24, 4, 0, 16, 0, 0, 0, 0, 0, 0] {
    ape_file_write_le(data, value, 4)
  }
  for value in [3000, 32] {
    ape_file_write_le(data, value, 2)
  }
  for value in [294912, 8, 1] {
    ape_file_write_le(data, value, 4)
  }
  for value in [24, 1] {
    ape_file_write_le(data, value, 2)
  }
  ape_file_write_le(data, 48000, 4)
  ape_file_write_le(data, 80, 4)
  for byte in 0..<16 {
    data.push(byte.to_byte())
  }
  let demux = av_ape_open(Bytes::from_array(data)).unwrap()
  let (packet, pts) = demux.packet(0).unwrap()
  assert_eq(demux.bits, 24)
  assert_eq(demux.sample_rate, 48000)
  assert_eq(demux.total_samples, 8L)
  assert_eq(pts, 0L)
  assert_eq(packet.length(), 24)
  assert_eq(packet[23], b'\x0f')
}
