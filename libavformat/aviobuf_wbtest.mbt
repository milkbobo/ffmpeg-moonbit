///|
/// Whitebox tests for the `aviobuf.c` port (`aviobuf.mbt`).
///
/// Every expected value below is hand-derived from the C source in
/// `libavformat/aviobuf.c` (the buffer/refill/seek-path semantics), or — for
/// the CRC helpers — cross-checked against the already-validated
/// `libavutil` crc port over the same bytes ("expectations produced by
/// FFmpeg's own second implementation").
///
/// The last section re-runs the MP4 demuxer over a genuinely streaming
/// source (3-byte chunks, tiny AVIO buffer, both seekable and unseekable)
/// and asserts the same sample tables the whole-buffer `av_mov_open` tests
/// pin down.

// ---------------------------------------------------------------------------
// A chunked, counting in-memory source (stands in for a file/socket)
// ---------------------------------------------------------------------------

struct ChunkSrc {
  data : Bytes
  chunk : Int
  mut pos : Int
  mut nreads : Int
  mut nseeks : Int
  /// make AVSEEK_SIZE fail so avio_size exercises the SEEK_END fallback
  size_fails : Bool
}

fn ChunkSrc::read(self : ChunkSrc, dst : FixedArray[Byte], start : Int, len : Int) -> Result[Int, String] {
  self.nreads = self.nreads + 1
  let remaining = self.data.length() - self.pos
  if remaining <= 0 {
    return Err("EOF")
  }
  let n = if len < self.chunk { len } else { self.chunk }
  let n = if n < remaining { n } else { remaining }
  for i = 0; i < n; i = i + 1 {
    dst[start + i] = self.data[self.pos + i]
  }
  self.pos = self.pos + n
  Ok(n)
}

fn ChunkSrc::seek(self : ChunkSrc, offset : Int64, whence : Int) -> Result[Int64, String] {
  if whence == AVSEEK_SIZE {
    if self.size_fails {
      return Err("ENOSYS")
    }
    return Ok(self.data.length().to_int64())
  }
  self.nseeks = self.nseeks + 1
  let base : Int64 = if whence == SEEK_CUR {
    self.pos.to_int64() + offset
  } else if whence == SEEK_END {
    self.data.length().to_int64() + offset
  } else {
    offset
  }
  if base < 0 {
    return Err("EINVAL")
  }
  // real file protocols allow seeking past EOF (reads then return EOF)
  self.pos = base.to_int()
  Ok(base)
}

///| Seekable chunked source: `(context, source)`. */
fn open_chunked(data : Bytes, chunk : Int, buffer_size : Int) -> (AvioContext, ChunkSrc) {
  let src : ChunkSrc = { data, chunk, pos: 0, nreads: 0, nseeks: 0, size_fails: false }
  let s = AvioContext::alloc_context(
    buffer_size,
    false,
    Some((dst, start, len) => src.read(dst, start, len)),
    None,
    Some((offset, whence) => src.seek(offset, whence)),
  )
  (s, src)
}

///| Unseekable chunked source (no seek callback at all). */
fn open_chunked_unseekable(data : Bytes, chunk : Int, buffer_size : Int) -> (AvioContext, ChunkSrc) {
  let src : ChunkSrc = { data, chunk, pos: 0, nreads: 0, nseeks: 0, size_fails: false }
  let s = AvioContext::alloc_context(
    buffer_size,
    false,
    Some((dst, start, len) => src.read(dst, start, len)),
    None,
    None,
  )
  (s, src)
}

fn seq_bytes(n : Int) -> Bytes {
  let a : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    a.push(i.to_byte())
  }
  Bytes::from_array(a[:])
}

// ---------------------------------------------------------------------------
// Reads: fixed-width accessors, EOF, avio_read
// ---------------------------------------------------------------------------

test "avio: BE/LE accessors across 1-byte chunks" {
  // bytes 00 01 02 ... 10, one byte per read callback call
  let (s, src) = open_chunked(seq_bytes(17), 1, 8)
  assert_eq(s.avio_rb16(), 0x0001)
  assert_eq(s.avio_rb24(), 0x020304)
  assert_eq(s.avio_rb32(), 0x05060708)
  assert_eq(s.avio_rb64(), 0x090A0B0C0D0E0F10)
  assert_eq(s.avio_tell(), 17L)
  assert_eq(src.nreads, 17)

  let (s2, _) = open_chunked(seq_bytes(17), 1, 8)
  assert_eq(s2.avio_rl16(), 0x0100)
  assert_eq(s2.avio_rl24(), 0x040302)
  assert_eq(s2.avio_rl32(), 0x08070605)
  assert_eq(s2.avio_rl64(), 0x100F0E0D0C0B0A09)
}

test "avio: EOF semantics of r8/feof and recovery by seek" {
  let (s, _) = open_chunked(b"\x01\x02\x03", 8, 8)
  // rb32 past the end: 3 real bytes then a 0 (C: avio_r8 returns 0 at EOF)
  assert_eq(s.avio_rb32(), 0x01020300)
  assert_eq(s.avio_r8(), 0)
  assert_eq(s.avio_feof(), true)
  // avio_feof retests (clear + refill), a true EOF stays EOF
  assert_eq(s.avio_feof(), true)
  // a successful seek clears eof_reached (end of avio_seek)
  assert_eq(s.avio_seek(0L, SEEK_SET).unwrap(), 0L)
  assert_eq(s.avio_feof(), false)
  assert_eq(s.avio_r8(), 1)
}

test "avio: avio_read exact / short at EOF / error at EOF / big bypass" {
  let (s, _) = open_chunked(seq_bytes(10), 4, 4)
  let a = s.avio_read(7).unwrap()
  assert_eq(a.length(), 7)
  assert_eq(a[0], b'\x00')
  assert_eq(a[6], b'\x06')
  // only 3 bytes remain
  let b = s.avio_read(5).unwrap()
  assert_eq(b.length(), 3)
  assert_eq(b[0], b'\x07')
  // nothing left: AVERROR_EOF
  assert_eq(s.avio_read(1), Err("EOF"))
  // request larger than the buffer bypasses it (single direct read)
  let (s2, _) = open_chunked(seq_bytes(30), 7, 4)
  let c = s2.avio_read(20).unwrap()
  assert_eq(c.length(), 20)
  assert_eq(c[19], b'\x13')
  assert_eq(s2.avio_tell(), 20L)
}

test "avio: ffio_read_size and avio_read_partial" {
  let (s, _) = open_chunked(seq_bytes(5), 4, 4)
  // 5 available, 8 requested → INVALIDDATA (ffio_read_size)
  assert_eq(s.ffio_read_size(8), Err("INVALIDDATA"))
  // read_partial returns what is buffered without looping
  let (s2, _) = open_chunked(seq_bytes(9), 4, 4)
  let p = s2.avio_read_partial(2).unwrap()
  assert_eq(p.length(), 2)
  let p2 = s2.avio_read_partial(100).unwrap()
  assert_eq(p2.length(), 2) // the rest of the 4-byte fill, no refill
  assert_eq(s2.avio_tell(), 4L)
}

// ---------------------------------------------------------------------------
// Seek paths (aviobuf.c avio_seek branch selection)
// ---------------------------------------------------------------------------

test "avio: in-buffer seek hits no callbacks" {
  let (s, src) = open_chunked(seq_bytes(30), 8, 8)
  assert_eq(s.avio_read(4).unwrap().length(), 4)
  assert_eq(s.avio_seek(2L, SEEK_SET).unwrap(), 2L)
  assert_eq(src.nseeks, 0)
  assert_eq(s.avio_r8(), 2)
  // SEEK_CUR/0 is avio_tell, side-effect free
  assert_eq(s.avio_seek(0L, SEEK_CUR).unwrap(), 3L)
  assert_eq(src.nreads, 1)
}

test "avio: short forward seek is served by reading, not the callback" {
  let (s, src) = open_chunked(seq_bytes(30), 8, 8)
  let _ = s.avio_read(4).unwrap()
  // buffer covers [0,8); target 9 is beyond it but within
  // buffer_size + short_seek_threshold → fill_buffer loop
  assert_eq(s.avio_seek(9L, SEEK_SET).unwrap(), 9L)
  assert_eq(src.nseeks, 0)
  assert_eq(src.nreads, 2)
  assert_eq(s.avio_r8(), 9)
}

test "avio: far forward/backward seeks go through the callback" {
  let (s, src) = open_chunked(seq_bytes(30), 8, 8)
  let _ = s.avio_read(4).unwrap()
  // offset1 > buffer_size + short_seek_threshold → protocol seek
  assert_eq(s.avio_seek(40000L, SEEK_SET).unwrap(), 40000L)
  assert_eq(src.nseeks, 1)
  // backward far beyond the buffer → protocol seek again
  assert_eq(s.avio_seek(0L, SEEK_SET).unwrap(), 0L)
  assert_eq(src.nseeks, 2)
  assert_eq(s.avio_r8(), 0)
  assert_eq(s.seek_count, 2)
}

test "avio: backward seek within half a buffer refills instead" {
  // 16-byte buffer, read to fill [0,16), step to 14, seek back to 1:
  // offset1 = 1 - 0 = 1 ... use a case where the buffer start moved:
  // after reading 24 bytes the window is [16,24) (pos=24, buf covers 16..24).
  let (s, _) = open_chunked(seq_bytes(40), 8, 8)
  let _ = s.avio_read(24).unwrap()
  assert_eq(s.avio_tell(), 24L)
  // window start pos = 24 - 8 = 16; seek(14): offset1 = -2, |offset1| < 8>>1
  // → half-buffer rewind (one callback seek) + refill + in-buffer retry
  assert_eq(s.avio_seek(14L, SEEK_SET).unwrap(), 14L)
  assert_eq(s.avio_r8(), 14)
}

test "avio: seek past EOF returns AVERROR_EOF and keeps the cursor" {
  let (s, _) = open_chunked(seq_bytes(30), 8, 8)
  let _ = s.avio_read(4).unwrap()
  assert_eq(s.avio_seek(35L, SEEK_SET), Err("EOF"))
  // the read-forward branch refilled until EOF; the cursor is left at the
  // start of the last (partial) window — exactly where C's fill loop stops
  assert_eq(s.avio_tell(), 24L)
}

test "avio: unseekable source skips forward but cannot go back" {
  let (s, _) = open_chunked_unseekable(seq_bytes(40), 8, 8)
  assert_eq(s.avio_read(4).unwrap().length(), 4)
  // forward seek on a non-seekable protocol: read-forward loop
  assert_eq(s.avio_seek(12L, SEEK_SET).unwrap(), 12L)
  assert_eq(s.avio_r8(), 12)
  // in-buffer backward still works (the data is still buffered)
  assert_eq(s.avio_seek(10L, SEEK_SET).unwrap(), 10L)
  assert_eq(s.avio_r8(), 10)
  // behind the window without a callback → EPIPE (C avio_seek)
  assert_eq(s.avio_seek(0L, SEEK_SET), Err("EPIPE"))
  // and avio_size has nothing to ask
  assert_eq(s.avio_size(), Err("ENOSYS"))
}

test "avio: avio_size via AVSEEK_SIZE and the SEEK_END fallback" {
  let (s, _) = open_chunked(seq_bytes(30), 8, 8)
  assert_eq(s.avio_size().unwrap(), 30L)
  // source whose AVSEEK_SIZE fails: seek(-1, SEEK_END)+1
  let src : ChunkSrc = { data: seq_bytes(30), chunk: 8, pos: 0, nreads: 0, nseeks: 0, size_fails: true }
  let s2 = AvioContext::alloc_context(
    8,
    false,
    Some((dst, start, len) => src.read(dst, start, len)),
    None,
    Some((offset, whence) => src.seek(offset, whence)),
  )
  assert_eq(s2.avio_size().unwrap(), 30L)
}

// ---------------------------------------------------------------------------
// Write path
// ---------------------------------------------------------------------------

///| A write callback collecting every flushed slice into one byte array. */
fn sink_collector(out : Array[Byte]) -> AvioWritePacket {
  (buf : FixedArray[Byte], start : Int, len : Int) => {
    for i = 0; i < len; i = i + 1 {
      out.push(buf[start + i])
    }
    Ok(len)
  }
}

fn bytes_of(a : Array[Byte]) -> Bytes {
  Bytes::from_array(a[:])
}

test "avio: write accessors buffer then flush" {
  let out : Array[Byte] = []
  let s = AvioContext::alloc_context(64, true, None, Some(sink_collector(out)), None)
  s.avio_wb32(0xDEADBEEF)
  s.avio_wb16(0x0102)
  s.avio_wl16(0x0304)
  s.avio_wb24(0x050607)
  s.avio_wl24(0x08090A)
  s.avio_wl32(0x0B0C0D0E)
  s.avio_flush()
  assert_eq(bytes_of(out), b"\xDE\xAD\xBE\xEF\x01\x02\x04\x03\x05\x06\x07\x0A\x09\x08\x0E\x0D\x0C\x0B")
  assert_eq(s.bytes_written, 18L)
}

test "avio: wb64/wl64/put_str/print_string_array" {
  let out : Array[Byte] = []
  let s = AvioContext::alloc_context(64, true, None, Some(sink_collector(out)), None)
  s.avio_wb64(0x1122334455667788UL)
  s.avio_wl64(0x1122334455667788UL)
  assert_eq(s.avio_put_str("hi"), 3)
  s.avio_print_string_array(["a", "b"])
  s.avio_flush()
  assert_eq(
    bytes_of(out),
    b"\x11\x22\x33\x44\x55\x66\x77\x88\x88\x77\x66\x55\x44\x33\x22\x11hi\x00a\nb\n",
  )
}

test "avio: write seek-back keeps the unflushed tail (avio_flush)" {
  let out : Array[Byte] = []
  let s = AvioContext::alloc_context(16, true, None, Some(sink_collector(out)), None)
  s.avio_write(b"ABCDE")
  // SEEK_CUR back by 2; avio_seek's in-buffer fast path
  assert_eq(s.avio_skip(-2L).unwrap(), 3L)
  s.avio_write(b"XY")
  // flush: buf_ptr_max is 5, so bytes 0..5 go out and the cursor is restored
  // to 5 (the C avio_flush seekback logic)
  s.avio_flush()
  assert_eq(bytes_of(out), b"ABCXY")
  assert_eq(s.avio_tell(), 5L)
}

test "avio: put_str16 le/be with BMP and astral characters" {
  let out : Array[Byte] = []
  let s = AvioContext::alloc_context(64, true, None, Some(sink_collector(out)), None)
  // 'h' U+0068, 'ï' U+00EF, '€' U+20AC — all BMP, one UTF-16 unit each
  let ret = s.avio_put_str16("hï€", false)
  s.avio_flush()
  assert_eq(ret, 8) // 2 + 2 + 2 data + 2 terminator
  assert_eq(bytes_of(out), b"h\x00\xEF\x00\xAC\x20\x00\x00")
  let out2 : Array[Byte] = []
  let s2 = AvioContext::alloc_context(64, true, None, Some(sink_collector(out2)), None)
  let ret2 = s2.avio_put_str16("hï€", true)
  s2.avio_flush()
  assert_eq(ret2, 8)
  assert_eq(bytes_of(out2), b"\x00h\x00\xEF\x20\xAC\x00\x00")
  // U+1F600 needs a surrogate pair: D83D DE00 + terminator = 6 bytes
  let out3 : Array[Byte] = []
  let s3 = AvioContext::alloc_context(64, true, None, Some(sink_collector(out3)), None)
  let ret3 = s3.avio_put_str16("\u{1F600}", false)
  s3.avio_flush()
  assert_eq(ret3, 6)
  assert_eq(bytes_of(out3), b"\x3D\xD8\x00\xDE\x00\x00")
}

// ---------------------------------------------------------------------------
// Dyn buffers
// ---------------------------------------------------------------------------

test "avio: dyn buf accumulate/get/close without padding" {
  let s = avio_open_dyn_buf()
  s.avio_wb32(1)
  s.avio_write(b"xyz")
  let _ = s.avio_put_str("A")
  // get_dyn_buf flushes; contents visible before close
  assert_eq(s.avio_get_dyn_buf(), b"\x00\x00\x00\x01xyzA\x00")
  s.avio_w8(0x42)
  let data = s.avio_close_dyn_buf()
  // the 64-byte AV_INPUT_BUFFER_PADDING_SIZE is written but excluded
  assert_eq(data, b"\x00\x00\x00\x01xyzA\x00B")
}

test "avio: dyn buf reset drops contents" {
  let s = avio_open_dyn_buf()
  s.avio_write(b"aa")
  s.ffio_reset_dyn_buf()
  s.avio_write(b"bb")
  assert_eq(s.avio_close_dyn_buf(), b"bb")
}

test "avio: dyn packet buf prefixes WB32 lengths" {
  let s = ffio_open_dyn_packet_buf(8).unwrap()
  s.avio_write(b"12345")
  s.avio_flush()
  assert_eq(s.avio_close_dyn_buf(), b"\x00\x00\x00\x05\x31\x32\x33\x34\x35")
}

test "avio: null buf counts bytes" {
  let s = ffio_open_null_buf()
  s.avio_wb32(0)
  s.avio_write(b"abcdefghij")
  assert_eq(s.ffio_close_null_buf(), 14)
}

// ---------------------------------------------------------------------------
// String reading
// ---------------------------------------------------------------------------

test "avio: avio_get_str stops at NUL, counts the terminator" {
  let (s, _) = open_chunked(b"AB\x00CD", 8, 8)
  let (str, used) = s.avio_get_str(5, 10).unwrap()
  assert_eq(str, "AB")
  assert_eq(used, 3)
  assert_eq(s.avio_tell(), 3L)
  // no NUL within maxlen: consumes exactly maxlen
  let (s2, _) = open_chunked(b"ABCDE", 8, 8)
  let (str2, used2) = s2.avio_get_str(3, 10).unwrap()
  assert_eq(str2, "ABC")
  assert_eq(used2, 3)
  // buflen truncates the copy but the input is still consumed to the NUL
  let (s3, _) = open_chunked(b"AB\x00CD", 8, 8)
  let (str3, used3) = s3.avio_get_str(5, 2).unwrap()
  assert_eq(str3, "A")
  assert_eq(used3, 3)
  assert_eq(s3.avio_tell(), 3L)
}

test "avio: avio_get_str16le reads UTF-16, NUL unit terminates" {
  // units: 'A', 0 → bytes 41 00 00 00
  let (s, _) = open_chunked(b"\x41\x00\x00\x00", 8, 8)
  let (str, used) = s.avio_get_str16(false, 4, 16).unwrap()
  assert_eq(str, "A")
  assert_eq(used, 4)
  // surrogate pair D83D DE00 = U+1F600, then terminator
  let (s2, _) = open_chunked(b"\x3D\xD8\x00\xDE\x00\x00", 8, 8)
  let (str2, used2) = s2.avio_get_str16(false, 8, 16).unwrap()
  assert_eq(str2, "\u{1F600}")
  assert_eq(used2, 6)
  // big-endian variant
  let (s3, _) = open_chunked(b"\x00\x41\x00\x00", 8, 8)
  let (str3, used3) = s3.avio_get_str16(true, 4, 16).unwrap()
  assert_eq(str3, "A")
  assert_eq(used3, 4)
}

test "avio: ff_get_line keeps the terminator, chomp trims it" {
  let (s, _) = open_chunked(b"hello\nworld\r\nend", 8, 8)
  let (l1, n1) = s.ff_get_line(1024)
  assert_eq(l1, "hello\n")
  assert_eq(n1, 6)
  let (c2, n2) = s.ff_get_chomp_line(1024)
  assert_eq(c2, "world")
  assert_eq(n2, 5)
  // final line without a newline ends at EOF
  let (l3, n3) = s.ff_get_line(1024)
  assert_eq(l3, "end")
  assert_eq(n3, 3)
  assert_eq(s.avio_feof(), true)
}

// ---------------------------------------------------------------------------
// Variable-length integers
// ---------------------------------------------------------------------------

test "avio: leb and varlen round trips" {
  let s = avio_open_dyn_buf()
  s.ffio_write_leb(0)
  s.ffio_write_leb(300)
  s.ffio_write_leb(127)
  let data = s.avio_close_dyn_buf()
  assert_eq(data, b"\x00\xAC\x02\x7F")
  let (s2, _) = open_chunked(data, 4, 4)
  assert_eq(s2.ffio_read_leb(), 0)
  assert_eq(s2.ffio_read_leb(), 300)
  assert_eq(s2.ffio_read_leb(), 127)
  // ffio_read_varlen: 7 bits per byte, high bit continues
  let (s3, _) = open_chunked(b"\x81\x80\x80\x00", 4, 4)
  assert_eq(s3.ffio_read_varlen(), 2097152UL)
}

// ---------------------------------------------------------------------------
// Checksum (cross-checked against the libavutil crc port)
// ---------------------------------------------------------------------------

test "avio: crc helpers match libavutil tables over the same bytes" {
  let data = b"123456789"
  // ff_crcEDB88320_update == av_crc(AV_CRC_32_IEEE_LE table, 0, data)
  let expect_le = @libavutil.av_crc(
    @libavutil.av_crc_init(true, 32, 0xEDB88320).unwrap(),
    0,
    data,
  )
  assert_eq(ff_crcEDB88320_update(0, data), expect_le)
  let expect_be = @libavutil.av_crc(
    @libavutil.av_crc_init(false, 32, 0x04C11DB7).unwrap(),
    0,
    data,
  )
  assert_eq(ff_crc04C11DB7_update(0, data), expect_be)
  let expect16 = @libavutil.av_crc(
    @libavutil.av_crc_init(true, 16, 0xA001).unwrap(),
    0,
    data,
  )
  assert_eq(ff_crcA001_update(0, data), expect16)
}

test "avio: streaming checksum equals one-shot over the same range" {
  // read 6 bytes in 3+3 through a 4-byte buffer: the fill_buffer checksum
  // bookkeeping must fold in exactly the bytes that crossed buf_ptr
  let (s, _) = open_chunked(b"abcdef", 3, 4)
  s.ffio_init_checksum(Some(ff_crcEDB88320_update), 0)
  let a = s.avio_read(3).unwrap()
  let b = s.avio_read(3).unwrap()
  ignore(a)
  ignore(b)
  let got = s.ffio_get_checksum()
  assert_eq(got, ff_crcEDB88320_update(0, b"abcdef"))
  // and on the write path: flush_buffer folds the flushed range. The value
  // is read before avio_close_dyn_buf, whose zero padding would otherwise
  // join the fold (C callers never keep a checksum active across a close)
  let s2 = avio_open_dyn_buf()
  s2.ffio_init_checksum(Some(ff_crcEDB88320_update), 0)
  s2.avio_write(b"abc")
  s2.avio_write(b"def")
  s2.avio_flush()
  assert_eq(s2.ffio_get_checksum(), ff_crcEDB88320_update(0, b"abcdef"))
  let _ = s2.avio_close_dyn_buf()
}

// ---------------------------------------------------------------------------
// Seekback guarantee
// ---------------------------------------------------------------------------

test "avio: ffio_ensure_seekback grows the window for unseekable sources" {
  // C pattern: ensure the look-back before reading (input probing), so the
  // probed bytes stay inside the window without a seek callback
  let (s, src) = open_chunked_unseekable(seq_bytes(40), 2, 16)
  let _ = s.ffio_ensure_seekback(12L)
  let first = s.avio_read(12).unwrap()
  assert_eq(first.length(), 12)
  let reads_before = src.nreads
  // window covers [0,12): the rewind is served in-buffer, no callbacks
  assert_eq(s.avio_seek(0L, SEEK_SET).unwrap(), 0L)
  assert_eq(src.nreads, reads_before)
  let again = s.avio_read(12).unwrap()
  for i = 0; i < 12; i = i + 1 {
    assert_eq(again[i], i.to_byte())
  }
  // fill_buffer shrinks an over-grown buffer back to orig_buffer_size
  let _ = s.avio_read(8).unwrap()
  assert_true(s.buffer_size == 16)
}

// ---------------------------------------------------------------------------
// MP4 demuxer over a genuinely streaming source
// ---------------------------------------------------------------------------

test "avio: mov demux over chunked seekable source matches whole-file parse" {
  // the same construction as the "video sample table" test in mp4_wbtest.mbt
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 640, 360)),
    stts_box([(10, 100)]),
    [],
    stsc_box([(1, 2, 1)]),
    stsz_box(50, 10),
    stco_box([1000, 2000, 3000, 4000, 5000]),
    stss_box([1, 7]),
  )
  let trak = build_trak(
    tkhd_box(1, 5000, 640, 360),
    mdhd_box(1000, 5000),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = bytes_of(build_movie(mvhd_box(1000, 5000), trak, false))
  // 3-byte chunks through a 7-byte buffer: every read crosses refills
  let (pb, _) = open_chunked(data, 3, 7)
  let movie = av_mov_open_avio(pb).unwrap()
  assert_eq(movie.timescale, 1000)
  assert_eq(movie.tracks.length(), 1)
  let t = movie.tracks[0]
  assert_eq(t.codec, "avc1")
  assert_eq(t.samples.length(), 10)
  assert_eq(t.samples[0].offset, 1000)
  assert_eq(t.samples[1].offset, 1050)
  assert_eq(t.samples[2].offset, 2000)
  assert_eq(t.samples[9].offset, 5050)
  for i = 0; i < 10; i = i + 1 {
    assert_eq(t.samples[i].size, 50)
    assert_eq(t.samples[i].duration, 100)
    assert_eq(t.samples[i].dts, (i * 100).to_int64())
    assert_eq(t.samples[i].pts, (i * 100).to_int64())
  }
  assert_eq(t.samples[0].keyframe, true)
  assert_eq(t.samples[6].keyframe, true)
  assert_eq(t.samples[7].keyframe, false)
}

test "avio: mov demux over an unseekable source still builds the tables" {
  // the same construction as "mp4: variable sample sizes from stsz" in
  // mp4_wbtest.mbt; avio_size fails (no seek callback) so the top-level
  // walk is bounded by eof instead of the stream size
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 16, 16)),
    stts_box([(3, 50)]),
    [],
    stsc_box([(1, 3, 1)]),
    stsz_variable_box([10, 20, 30]),
    stco_box([700]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 150, 16, 16),
    mdhd_box(1000, 150),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = bytes_of(build_movie(mvhd_box(1000, 150), trak, false))
  let (pb, _) = open_chunked_unseekable(data, 5, 11)
  let movie = av_mov_open_avio(pb).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let t = movie.tracks[0]
  assert_eq(t.sample_sizes, [10, 20, 30])
  assert_eq(t.samples.length(), 3)
  assert_eq(t.samples[0].offset, 700)
  assert_eq(t.samples[0].size, 10)
  assert_eq(t.samples[1].offset, 710)
  assert_eq(t.samples[1].size, 20)
  assert_eq(t.samples[2].offset, 730)
  assert_eq(t.samples[2].size, 30)
  assert_eq(t.samples[2].dts, 100)
}
