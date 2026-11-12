// Native chunked host I/O for `--stream` (see host_io_stub.c). The reader
// owns a `FILE*` and returns one packed YUV420P frame per call; the writer
// appends one finished access unit per call. Both handles are external
// objects with finalizers, and the explicit close keeps the writer's
// buffered bytes on disk before the CLI prints its summary.
//
// The wasm/js backend cannot open host files in chunks and uses the
// whole-file fallback in host_io_wasm.mbt. Both implementations take the
// path as UTF-8 bytes (the native FFI representation) and expose the same
// FrameReader/FrameWriter surface, so options.mbt stays target-neutral.

///|
priv type FrameReader

///|
#borrow(path)
extern "c" fn reader_open_ffi(path : Bytes) -> FrameReader = "h264cli_reader_open"

///|
#borrow(reader)
extern "c" fn reader_error_ffi(reader : FrameReader) -> Bytes? = "h264cli_reader_error"

///|
#borrow(reader)
extern "c" fn reader_size_ffi(reader : FrameReader) -> Int64 = "h264cli_reader_size"

///|
#borrow(reader, buf)
extern "c" fn reader_read_ffi(reader : FrameReader, buf : Bytes) -> Int32 = "h264cli_reader_read"

///|
#borrow(reader)
extern "c" fn reader_close_ffi(reader : FrameReader) -> Unit = "h264cli_reader_close"

///|
priv type FrameWriter

///|
#borrow(path)
extern "c" fn writer_open_ffi(path : Bytes) -> FrameWriter = "h264cli_writer_open"

///|
#borrow(writer)
extern "c" fn writer_error_ffi(writer : FrameWriter) -> Bytes? = "h264cli_writer_error"

///|
#borrow(writer, buf)
extern "c" fn writer_write_ffi(writer : FrameWriter, buf : Bytes) -> Int32 = "h264cli_writer_write"

///|
#borrow(writer)
extern "c" fn writer_close_ffi(writer : FrameWriter) -> Int32 = "h264cli_writer_close"

///|
fn FrameReader::open(path : Bytes) -> FrameReader raise {
  let reader = reader_open_ffi(path)
  match reader_error_ffi(reader) {
    Some(msg) => fail("encode-h264: \{@utf8.decode_lossy(msg)}")
    None => reader
  }
}

///|
fn FrameReader::last_error(self : FrameReader) -> String {
  match reader_error_ffi(self) {
    Some(msg) => @utf8.decode_lossy(msg)
    None => "I/O error"
  }
}

///|
fn FrameReader::size(self : FrameReader) -> Int64 raise {
  let size = reader_size_ffi(self)
  if size < 0 {
    fail("encode-h264: \{self.last_error()}")
  }
  size
}

///|
/// One full frame, `None` at a clean end of file. A partial trailing frame
/// is an input error, not a short read: the CLI contract accepts only whole
/// YUV420P frames.
fn FrameReader::read(self : FrameReader, frame_size : Int32) -> Bytes? raise {
  let buf = Bytes::make(frame_size, 0)
  let n = reader_read_ffi(self, buf)
  if n == frame_size {
    Some(buf)
  } else if n == 0 {
    None
  } else if n < 0 {
    fail("encode-h264: \{self.last_error()}")
  } else {
    fail(
      "encode-h264: truncated input frame: expected \{frame_size} bytes, got \{n}",
    )
  }
}

///|
fn FrameReader::close(self : FrameReader) -> Unit {
  reader_close_ffi(self)
}

///|
fn FrameWriter::open(path : Bytes) -> FrameWriter raise {
  let writer = writer_open_ffi(path)
  match writer_error_ffi(writer) {
    Some(msg) => fail("encode-h264: \{@utf8.decode_lossy(msg)}")
    None => writer
  }
}

///|
fn FrameWriter::last_error(self : FrameWriter) -> String {
  match writer_error_ffi(self) {
    Some(msg) => @utf8.decode_lossy(msg)
    None => "I/O error"
  }
}

///|
fn FrameWriter::write(self : FrameWriter, data : Bytes) -> Unit raise {
  if writer_write_ffi(self, data) != 0 {
    fail("encode-h264: \{self.last_error()}")
  }
}

///|
fn FrameWriter::close(self : FrameWriter) -> Unit raise {
  if writer_close_ffi(self) != 0 {
    fail("encode-h264: \{self.last_error()}")
  }
}
