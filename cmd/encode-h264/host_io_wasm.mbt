// Whole-file host I/O fallback for wasm and js.
//
// The MoonBit wasm host exposes only `@fs.read_file_to_bytes` /
// `@fs.write_bytes_to_file`, so unlike the native backend these readers and
// writers cannot grow with the sequence length. The encoder itself still
// consumes one frame at a time and the writer appends access units in
// order; only the host-side buffers are whole-file. The surface matches
// host_io_native.mbt so options.mbt stays target-neutral.

///|
struct FrameReader {
  data : Bytes
  mut pos : Int32
}

///|
fn FrameReader::open(utf8_path : Bytes) -> FrameReader raise {
  let path = @utf8.decode_lossy(utf8_path)
  let data = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => fail("encode-h264: cannot read '\{path}': \{msg}")
  }
  { data, pos: 0, }
}

///|
fn FrameReader::size(self : FrameReader) -> Int64 {
  self.data.length().to_int64()
}

///|
/// One full frame, `None` at a clean end of file. A partial trailing frame
/// is an input error, matching the native reader.
fn FrameReader::read(self : FrameReader, frame_size : Int32) -> Bytes? raise {
  let left = self.data.length() - self.pos
  if left == 0 {
    None
  } else if left < frame_size {
    fail(
      "encode-h264: truncated input frame: expected \{frame_size} bytes, got \{left}",
    )
  } else {
    let frame = self.data[self.pos:self.pos + frame_size].to_owned()
    self.pos = self.pos + frame_size
    Some(frame)
  }
}

///|
fn FrameReader::close(self : FrameReader) -> Unit {
  self.pos = self.data.length()
}

///|
struct FrameWriter {
  path : String
  out : Array[Byte]
}

///|
fn FrameWriter::open(utf8_path : Bytes) -> FrameWriter {
  { path: @utf8.decode_lossy(utf8_path), out: [], }
}

///|
fn FrameWriter::write(self : FrameWriter, data : Bytes) -> Unit {
  self.out.append(data.to_array()[:])
}

///|
fn FrameWriter::close(self : FrameWriter) -> Unit raise {
  @fs.write_bytes_to_file(self.path, Bytes::from_array(self.out[:])) catch {
    @fs.IOError(msg) => fail("encode-h264: cannot write '\{self.path}': \{msg}")
  }
}
