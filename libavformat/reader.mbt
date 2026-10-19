///|
/// In-memory byte reader mirroring the subset of `avio_*` used by libavformat's
/// mov demuxer: `avio_r8`, `avio_rb16/24/32/64`, `avio_rl32`, `avio_skip`,
/// `avio_tell`, `avio_seek`, `avio_feof`.
///
/// Reads past the end are clamped and raise the `eof` flag, matching AVIO's
/// behaviour of returning 0 and setting `eof_reached` rather than failing.
/// Porting to a whole-buffer reader is what lets this demuxer slice avoid
/// libavformat's AVIO layer entirely: the caller reads the file and hands over
/// the bytes.

///| A whole-buffer reader with an AVIO-like cursor. */
pub struct Mp4Reader {
  buf : Bytes
  mut pos : Int
  mut eof : Bool
}

///| Create a reader over `buf`, positioned at the start. */
pub fn Mp4Reader::new(buf : Bytes) -> Mp4Reader {
  { buf, pos: 0, eof: false }
}

///| `avio_tell`: current absolute position. */
pub fn Mp4Reader::position(self : Mp4Reader) -> Int {
  self.pos
}

///| Total buffer length. */
pub fn Mp4Reader::total_size(self : Mp4Reader) -> Int {
  self.buf.length()
}

///| `avio_feof`: true once a read has run past the end of the buffer. */
pub fn Mp4Reader::eof_reached(self : Mp4Reader) -> Bool {
  self.eof
}

///| `avio_seek`: move to `target`, clamped to the buffer. */
pub fn Mp4Reader::seek(self : Mp4Reader, target : Int) -> Unit {
  self.pos = if target < 0 {
    0
  } else if target > self.buf.length() {
    self.buf.length()
  } else {
    target
  }
}

///|
/// `avio_skip`: advance by `n` bytes (negative values rewind, as with the C
/// `avio_skip(pb, negative)` used to undo an overread). Seeking past the end
/// flags `eof` but does not fail, mirroring AVIO.
pub fn Mp4Reader::skip(self : Mp4Reader, n : Int64) -> Unit {
  if n < 0 {
    self.seek(self.pos + n.to_int())
    return
  }
  let target = self.pos.to_int64() + n
  if target > self.buf.length().to_int64() {
    self.pos = self.buf.length()
    self.eof = true
  } else {
    self.pos = target.to_int()
  }
}

///| `avio_r8`: one unsigned byte. Past-the-end reads yield 0 and set `eof`. */
pub fn Mp4Reader::read_u8(self : Mp4Reader) -> UInt {
  if self.pos >= self.buf.length() {
    self.eof = true
    return 0
  }
  let v = self.buf[self.pos].to_uint()
  self.pos = self.pos + 1
  v
}

///| `avio_rb16`: 16-bit big-endian. */
pub fn Mp4Reader::read_u16(self : Mp4Reader) -> UInt {
  let a = self.read_u8()
  let b = self.read_u8()
  (a << 8) | b
}

///| `avio_rb24`: 24-bit big-endian. */
pub fn Mp4Reader::read_u24(self : Mp4Reader) -> UInt {
  let a = self.read_u8()
  let b = self.read_u8()
  let c = self.read_u8()
  (a << 16) | (b << 8) | c
}

///| `avio_rb32`: 32-bit big-endian. */
pub fn Mp4Reader::read_u32(self : Mp4Reader) -> UInt {
  let a = self.read_u8()
  let b = self.read_u8()
  let c = self.read_u8()
  let d = self.read_u8()
  (a << 24) | (b << 16) | (c << 8) | d
}

///| `avio_rb64`: 64-bit big-endian. */
pub fn Mp4Reader::read_u64(self : Mp4Reader) -> UInt64 {
  let hi = self.read_u32().to_uint64()
  let lo = self.read_u32().to_uint64()
  (hi << 32) | lo
}

///| `avio_rb64` interpreted as a signed 64-bit value. */
pub fn Mp4Reader::read_i64(self : Mp4Reader) -> Int64 {
  self.read_u64().reinterpret_as_int64()
}

///| `avio_rl32`: 32-bit little-endian (used for 4CCs and `hdlr` subtypes). */
pub fn Mp4Reader::read_le32(self : Mp4Reader) -> UInt {
  let a = self.read_u8()
  let b = self.read_u8()
  let c = self.read_u8()
  let d = self.read_u8()
  a | (b << 8) | (c << 16) | (d << 24)
}

///|
/// Read a 4CC as an ASCII string of the four raw bytes.
/// This matches the C idiom of reading a tag with `avio_rl32`/`avio_rb32` and
/// comparing it against `MKTAG(a, b, c, d)`: both reduce to comparing the four
/// bytes in file order against the literal four characters.
pub fn Mp4Reader::read_fourcc(self : Mp4Reader) -> String {
  let chars : Array[Char] = []
  for i = 0; i < 4; i = i + 1 {
    if self.pos < self.buf.length() {
      chars.push(self.buf[self.pos].to_char())
      self.pos = self.pos + 1
    } else {
      self.eof = true
      chars.push('\u{0}')
    }
  }
  String::from_array(chars[:])
}

///|
/// Peek one byte at an absolute index without moving the cursor.
/// Returns 0 when the index is out of range.
pub fn Mp4Reader::peek_u8_at(self : Mp4Reader, index : Int) -> UInt {
  if index < 0 || index >= self.buf.length() {
    0
  } else {
    self.buf[index].to_uint()
  }
}
