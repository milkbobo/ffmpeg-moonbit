///|
fn av1_tile_test_header(columns : Int32, size_bytes : Int32) -> Av1FrameHeader {
  let seq = av1_parse_sequence_header(b"\x81\x00\x0c\x00").unwrap()
  let shown = av1_parse_frame_header(b"\x1a\x01\x80", seq).unwrap()
  { ..shown, show_existing_frame: false, tile_cols: columns, tile_rows: 1,
    tile_cols_log2: av1_tile_log2(1, columns), tile_rows_log2: 0,
    tile_size_bytes_minus1: size_bytes - 1, header_bits: 0 }
}

///|
test "av1 tiles: real 2x2 libaom stream matches C offsets sizes and payload MD5" {
  let packet = @libavutil.av_base64_decode(av1_tiles4_obu_b64, 65536).unwrap()
  let seq = av1_parse_sequence_header(packet).unwrap()
  let header = av1_parse_frame_header(packet, seq).unwrap()
  assert_eq((header.tile_cols, header.tile_rows), (2, 2))
  assert_eq(header.header_bits, 104)
  assert_eq(header.tile_size_bytes_minus1, 1)
  let group = av1_parse_tile_group(packet, header).unwrap()
  let tiles = av1_extract_tiles(packet, header).unwrap()
  assert_eq(tiles.length(), 4)
  for i in 0..<4 {
    let (offset, size, md5) = av1_tiles4_reference[i]
    assert_eq(group.tile_offsets[i], offset)
    assert_eq(group.tile_sizes[i], size)
    assert_eq(tiles[i].offset, group.payload_offset + offset)
    assert_eq((tiles[i].row, tiles[i].column), (i / 2, i % 2))
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, tiles[i].data, tiles[i].data.length())
    assert_eq(h264_hex(digest, 16), md5)
  }
}

///|
test "av1 tiles: interleaved size fields skip each compressed payload" {
  // get_tiles_info reads a size then skips that tile, not a size array.
  let bytes : Bytes = b"\x22\x0e\x00\x01\x90\xff\x02\x12\x34\x56\x00\xab\xde\xad\xbe\xef"
  let header = av1_tile_test_header(4, 1)
  let group = av1_parse_tile_group(bytes, header).unwrap()
  assert_eq(group.tile_sizes, [2, 3, 1, 4])
  assert_eq(group.tile_offsets, [2, 5, 9, 10])
  assert_eq(group.data_offset, 2)
  assert_eq(group.data_size, 10)
  let tiles = av1_extract_tiles(bytes, header).unwrap()
  let expected : Array[Bytes] = [b"\x90\xff", b"\x12\x34\x56", b"\xab", b"\xde\xad\xbe\xef"]
  for i in 0..<4 {
    assert_eq(tiles[i].index, i)
    assert_eq(tiles[i].row, 0)
    assert_eq(tiles[i].column, i)
    assert_eq(tiles[i].data, expected[i])
    assert_eq(bytes[tiles[i].offset:tiles[i].offset + expected[i].length()].to_owned(), expected[i])
  }
  let single = av1_parse_tile_group(b"\x22\x03\x11\x22\x33", av1_tile_test_header(1, 1)).unwrap()
  assert_eq(single.tile_sizes, [3])
  assert_eq(single.tile_offsets, [0])
}

///|
test "av1 tiles: ordered partial groups and incomplete or overlapping groups" {
  let header = av1_tile_test_header(4, 1)
  let first : Bytes = b"\x22\x04\x88\x00\xaa\xbb"
  let last : Bytes = b"\x22\x05\xd8\x01\xcc\xdd\xee"
  let all : Bytes = b"\x22\x04\x88\x00\xaa\xbb\x22\x05\xd8\x01\xcc\xdd\xee"
  let tiles = av1_extract_tiles(all, header).unwrap()
  assert_eq(tiles.length(), 4)
  assert_eq(tiles[2].data, b"\xcc\xdd")
  assert_eq(tiles[3].data, b"\xee")
  assert_true(av1_extract_tiles(first, header) is Err("av1: incomplete tile groups"))
  assert_true(av1_extract_tiles(last, header) is Err("av1: noncontiguous tile groups"))
  assert_true(av1_extract_tiles(b"\x22\x04\x88\x00\xaa\xbb\x22\x04\x88\x00\xaa\xbb", header) is Err("av1: noncontiguous tile groups"))
}

///|
test "av1 tiles: reject oversized sizes, truncated headers and invalid OBU bits" {
  let header = av1_tile_test_header(4, 1)
  assert_true(av1_parse_tile_group(b"\x22\x02\x00\xff", header) is Err("av1: tile sizes exceed OBU"))
  assert_true(av1_parse_tile_group(b"\x22\x01\x00", header) is Err("av1: truncated tile size"))
  assert_true(av1_parse_tile_group(b"\x22\x00", header) is Err("av1: truncated tile group header"))
  assert_true(av1_parse_tile_group(b"\x22\x01\x01", header) is Err("av1: nonzero tile group alignment bit"))
  assert_true(av1_parse_tile_group(b"\xa2\x00", header) is Err("av1: OBU forbidden bit set"))
  assert_true(av1_parse_tile_group(b"\x23\x00", header) is Err("av1: OBU reserved bit set"))
  assert_true(av1_parse_tile_group(b"\x26", header) is Err("av1: truncated OBU extension"))
  assert_true(av1_parse_tile_group(b"\x22\x80\x80\x80\x80\x10", header) is Err("av1: bad OBU size"))
  let wide = av1_tile_test_header(2, 4)
  assert_true(av1_parse_tile_group(b"\x22\x05\x00\xff\xff\xff\xff", wide) is Err("av1: tile sizes exceed OBU"))
}
