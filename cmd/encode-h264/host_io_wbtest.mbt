///|
/// Test-only temp-file cleanup: a crashed earlier run may have left the
/// file behind, and `remove_file` raises when it does not exist.
fn host_test_cleanup(path : String) -> Unit raise {
  if @fs.path_exists(path) {
    @fs.remove_file(path)
  }
}

///|
/// Distinct luma/chroma values per frame catch plane swaps and frame
/// offsets in the chunked read path.
fn host_test_raw(frames : Int32, luma : Int32, chroma : Int32) -> Bytes {
  let raw : Array[Byte] = []
  for f in 0..<frames {
    for i in 0..<luma {
      raw.push((30 + f * 17 + i % 13).to_byte())
    }
    for _ in 0..<chroma {
      raw.push((80 + f * 5).to_byte())
    }
    for _ in 0..<chroma {
      raw.push((160 + f * 3).to_byte())
    }
  }
  Bytes::from_array(raw[:])
}

///|
test "chunked host stream is byte-identical to the batch encoder" {
  let input = "encode-h264-hostio-in.tmp"
  let output = "encode-h264-hostio-out.tmp"
  host_test_cleanup(input)
  host_test_cleanup(output)
  let opts = {
    ..test_options(["--stream", "--cabac", "--aud", "--b-slices"]),
    input,
    output,
  }
  let luma = 16 * 16
  let chroma = luma / 4
  let raw = host_test_raw(5, luma, chroma)
  @fs.write_bytes_to_file(input, raw)
  let (count, bytes) = encode_stream_file(opts)
  let (want, want_count) = encode_raw(raw, opts)
  assert_eq(count, 5)
  assert_eq(count, want_count)
  assert_eq(bytes, want.length())
  assert_eq(@fs.read_file_to_bytes(output), want)
  host_test_cleanup(input)
  host_test_cleanup(output)
}

///|
test "host reader yields whole frames and a clean EOF" {
  let path = "encode-h264-hostio-reader.tmp"
  host_test_cleanup(path)
  let luma = 16 * 16
  let chroma = luma / 4
  let frame_size = luma + chroma * 2
  let raw = host_test_raw(2, luma, chroma)
  @fs.write_bytes_to_file(path, raw)
  let reader = FrameReader::open(@utf8.encode(path))
  assert_eq(reader.size(), (frame_size * 2).to_int64())
  let first = match reader.read(frame_size) {
    Some(frame) => frame
    None => fail("host reader reported EOF on the first frame")
  }
  assert_eq(first, raw[:frame_size].to_owned())
  let second = match reader.read(frame_size) {
    Some(frame) => frame
    None => fail("host reader reported EOF on the second frame")
  }
  assert_eq(second, raw[frame_size:frame_size * 2].to_owned())
  assert_eq(reader.read(frame_size), None)
  reader.close()
  host_test_cleanup(path)
}

///|
test "host reader rejects a partial trailing frame" {
  let path = "encode-h264-hostio-trunc.tmp"
  host_test_cleanup(path)
  let frame_size = 16 * 16 * 3 / 2
  @fs.write_bytes_to_file(path, Bytes::make(frame_size + 7, 1))
  let reader = FrameReader::open(@utf8.encode(path))
  let _ = match reader.read(frame_size) {
    Some(frame) => frame
    None => fail("host reader reported EOF on the first frame")
  }
  try reader.read(frame_size) catch {
    _ => ()
  } noraise {
    _ => fail("host reader accepted a truncated frame")
  }
  reader.close()
  host_test_cleanup(path)
}

///|
test "chunked host stream rejects a partial frame before opening output" {
  let input = "encode-h264-hostio-bad-in.tmp"
  let output = "encode-h264-hostio-bad-out.tmp"
  host_test_cleanup(input)
  host_test_cleanup(output)
  @fs.write_bytes_to_file(input, Bytes::make(383, 0))
  let opts = { ..test_options(["--stream"]), input, output, }
  try encode_stream_file(opts) catch {
    _ => ()
  } noraise {
    _ => fail("accepted a truncated input")
  }
  assert_false(@fs.path_exists(output))
  host_test_cleanup(input)
  host_test_cleanup(output)
}

///|
test "chunked host stream reports an unwritable output" {
  let input = "encode-h264-hostio-dir-in.tmp"
  let output = "encode-h264-hostio-dir.tmp"
  host_test_cleanup(input)
  if @fs.path_exists(output) {
    @fs.remove_dir(output)
  }
  let luma = 16 * 16
  let raw = host_test_raw(1, luma, luma / 4)
  @fs.write_bytes_to_file(input, raw)
  @fs.create_dir(output)
  let opts = { ..test_options(["--stream"]), input, output, }
  try encode_stream_file(opts) catch {
    _ => ()
  } noraise {
    _ => fail("accepted a directory as output")
  }
  @fs.remove_dir(output)
  host_test_cleanup(input)
}
