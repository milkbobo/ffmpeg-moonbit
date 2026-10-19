///|
/// Port of `libavformat/aviobuf.c` (FFmpeg 9.0.2): the buffered `AVIOContext`
/// layer every demuxer/muxer reads and writes through.
///
/// The C context is callback driven — `read_packet`/`write_packet`/`seek` come
/// from the caller (file protocol, network protocol, dyn buf, …) — and keeps a
/// sliding window over the stream. That model maps to MoonBit closures, so
/// `AvioContext` stays faithful to the C buffer management: `buf_ptr`/`buf_end`
/// indices into `buffer`, `pos` as the absolute position of `buf_end` (read
/// mode) or of `buffer[0]` (write mode), `fill_buffer`'s append-or-rewind
/// choice, the shrink back to `orig_buffer_size` after probing, the four seek
/// paths of `avio_seek` (in-buffer / read-forward / half-buffer backward
/// refill / protocol callback), and the dyn-buffer writer with its ×1.5+1
/// growth policy.
///
/// Conventions (MoonBit-forced diffs, see `README.md` §6 and `agent.md` §7):
///   * error returns (`AVERROR(EINVAL)` & friends) become `Result[T, String]`
///     carrying the errno name; `AVERROR_EOF` is `Err("EOF")`.
///   * read/write callbacks take `(buf, start, len)` — a slice of a
///     `FixedArray[Byte]` — instead of raw pointers. A read callback reports
///     end-of-stream with `Err("EOF")`.
///   * the seek callback receives `(offset, whence)` with the `SEEK_*` /
///     `AVSEEK_SIZE` constants below, exactly like the C one.
///   * `avio_r8` returns `UInt` (C returns `int`); values are 0..255 so every
///     C `(int)`/`(uint8_t)` use is preserved.
///   * string producers (`avio_get_str*`, `ff_get_line`) return the `String`
///     built from the bytes C would leave in `buf`, plus the C return value
///     (input bytes consumed / chars stored).
///
/// Not ported (no consumer in the migrated slices): `avio_printf`/
/// `avio_vprintf` (varargs formatting, needs an `AVBPrint` port),
/// `avio_write_marker` + `write_data_type` (mpegts muxer interleaving
/// markers), `avio_pause`/`avio_seek_time` (protocol pause/resume),
/// `ffio_rewind_with_probe_data` (input probing), `ffio_limit` and
/// `ffio_copy_url_options` (AVFormatContext/AVDictionary plumbing).

///| `IO_BUFFER_SIZE`: default AVIO buffer size (aviobuf.c). */
pub const IO_BUFFER_SIZE : Int = 32768

///| `SHORT_SEEK_THRESHOLD`: seeks up to this far ahead of the buffer are
/// served by skipping data instead of calling the protocol seek (aviobuf.c). */
pub const SHORT_SEEK_THRESHOLD : Int = 32768

///| `AV_INPUT_BUFFER_PADDING_SIZE`: input buffers end with this much zero
/// padding so bitreaders can overread (libavcodec). */
pub const AV_INPUT_BUFFER_PADDING_SIZE : Int = 64

///| Whence values for `avio_seek` and the seek callback. */
pub const SEEK_SET : Int = 0

///| See `SEEK_SET`. */
pub const SEEK_CUR : Int = 1

///| See `SEEK_SET`. `avio_seek` itself rejects it (callers resolve the size
/// first); seek callbacks must still accept it. */
pub const SEEK_END : Int = 2

///| `AVSEEK_SIZE`: passed to the seek callback to query the stream size. */
pub const AVSEEK_SIZE : Int = 0x10000

///| `AVSEEK_FORCE`: flag ignored by `avio_seek`. */
pub const AVSEEK_FORCE : Int = 0x20000

///| Read-callback type: fill `buf[start..start+len]`, return the byte count. */
pub type AvioReadPacket = (FixedArray[Byte], Int, Int) -> Result[Int, String]

///| Write-callback type: consume `buf[start..start+len]`. */
pub type AvioWritePacket = (FixedArray[Byte], Int, Int) -> Result[Int, String]

///| Seek-callback type: `(offset, whence) -> new position` (C semantics). */
pub type AvioSeekFn = (Int64, Int) -> Result[Int64, String]

///| Checksum-update callback: `(crc, data) -> new crc`. */
pub type AvioChecksumFn = (UInt, Bytes) -> UInt

///|
/// The buffered I/O context: `AVIOContext` (avio.h) plus the `FFIOContext`
/// (avio_internal.h) bookkeeping. Field doc comments carry the C name.
pub struct AvioContext {
  /// `buffer`/`buffer_size`: the sliding window (replaced on resize).
  mut buffer : FixedArray[Byte]
  mut buffer_size : Int
  /// `buf_ptr`: read/write cursor index into `buffer`.
  mut buf_ptr : Int
  /// `buf_end`: end of valid data (read mode); `buffer_size` (write mode).
  mut buf_end : Int
  /// `buf_ptr_max`: highest `buf_ptr` seen (write-mode seek-back guard).
  mut buf_ptr_max : Int
  /// `pos`: absolute position of `buf_end` (read) / of `buffer[0]` (write).
  mut pos : Int64
  mut eof_reached : Bool
  mut write_flag : Bool
  /// `error`: last errno name (`None` = no error so far).
  mut err : String?
  /// `seekable & AVIO_SEEKABLE_NORMAL`.
  seekable : Bool
  mut direct : Bool
  mut max_packet_size : Int
  // --- FFIOContext privates ---
  /// `orig_buffer_size`: size to shrink back to after probing grew the buffer.
  mut orig_buffer_size : Int
  short_seek_threshold : Int
  mut bytes_read : Int64
  mut bytes_written : Int64
  mut written_output_size : Int64
  mut seek_count : Int
  mut writeout_count : Int
  // --- checksum state ---
  mut checksum : UInt
  /// `checksum_ptr` as an index into `buffer`.
  mut checksum_ptr : Int
  mut update_checksum : AvioChecksumFn?
  // --- callbacks ---
  read_packet : AvioReadPacket?
  mut write_packet : AvioWritePacket?
  seek_fn : AvioSeekFn?
  /// `opaque` for dyn-buffer contexts (`Null` elsewhere).
  mut dynbuf : DynBuf?
}

///| `ffio_init_context`: build a context over `buffer` with the given
/// callbacks. Read mode without `read_packet` treats `buffer` as the whole
/// stream (`ffio_init_read_context`); write mode sets `buf_end` to the end of
/// the buffer (`url_resetbuf`). */
pub fn AvioContext::init_context(
    buffer : FixedArray[Byte],
    write_flag : Bool,
    read_packet : AvioReadPacket?,
    write_packet : AvioWritePacket?,
    seek_fn : AvioSeekFn?) -> AvioContext {
  let buffer_size = buffer.length()
  let s : AvioContext = {
    buffer,
    buffer_size,
    buf_ptr: 0,
    buf_end: 0,
    buf_ptr_max: 0,
    pos: 0,
    eof_reached: false,
    write_flag,
    err: None,
    seekable: seek_fn is Some(_),
    direct: false,
    max_packet_size: 0,
    orig_buffer_size: buffer_size,
    short_seek_threshold: SHORT_SEEK_THRESHOLD,
    bytes_read: 0,
    bytes_written: 0,
    written_output_size: 0,
    seek_count: 0,
    writeout_count: 0,
    checksum: 0,
    checksum_ptr: 0,
    update_checksum: None,
    read_packet,
    write_packet,
    seek_fn,
    dynbuf: None,
  }
  // url_resetbuf
  if write_flag {
    s.buf_end = buffer_size
  } else {
    s.buf_end = 0
  }
  if read_packet is None && write_flag == false {
    // whole-stream read context: the buffer is already full
    s.pos = buffer_size.to_int64()
    s.buf_end = buffer_size
  }
  s
}

///|
/// `ffio_init_read_context` over an in-memory buffer: the buffer becomes the
/// whole stream, exactly like the C helper — plus an in-memory seek/read
/// callback pair over the same bytes, so `avio_size` and past-the-end seeks
/// behave like on a seekable file instead of returning `ENOSYS`/`EPIPE`
/// (the C helper has no callbacks at all; demuxers never drive it directly,
/// this port uses it for `av_mov_open(Bytes)`).
pub fn AvioContext::init_read_context(buf : Bytes) -> AvioContext {
  let data : FixedArray[Byte] = FixedArray::make(buf.length(), b'\x00')
  for i = 0; i < buf.length(); i = i + 1 {
    data[i] = buf[i]
  }
  let src_pos : Array[Int] = [0]
  fn read(dst : FixedArray[Byte], start : Int, len : Int) -> Result[Int, String] {
    let remaining = data.length() - src_pos[0]
    if remaining <= 0 {
      return Err("EOF")
    }
    let n = if len < remaining { len } else { remaining }
    for i = 0; i < n; i = i + 1 {
      dst[start + i] = data[src_pos[0] + i]
    }
    src_pos[0] = src_pos[0] + n
    Ok(n)
  }
  fn seek(offset : Int64, whence : Int) -> Result[Int64, String] {
    if whence == AVSEEK_SIZE {
      return Ok(data.length().to_int64())
    }
    let base : Int64 = if whence == SEEK_CUR {
      src_pos[0].to_int64() + offset
    } else if whence == SEEK_END {
      data.length().to_int64() + offset
    } else {
      offset
    }
    if base < 0 || base > data.length().to_int64() {
      return Err("EINVAL")
    }
    src_pos[0] = base.to_int()
    Ok(base)
  }
  AvioContext::init_context(data, false, Some(read), None, Some(seek))
}

///| `avio_alloc_context`: like `init_context` but allocates the buffer. */
pub fn AvioContext::alloc_context(
    buffer_size : Int,
    write_flag : Bool,
    read_packet : AvioReadPacket?,
    write_packet : AvioWritePacket?,
    seek_fn : AvioSeekFn?) -> AvioContext {
  AvioContext::init_context(
    FixedArray::make(buffer_size, b'\x00'),
    write_flag,
    read_packet,
    write_packet,
    seek_fn,
  )
}

// ---------------------------------------------------------------------------
// Small helpers (FFMIN/FFMAX)
// ---------------------------------------------------------------------------

fn imin(a : Int, b : Int) -> Int {
  if a < b { a } else { b }
}

fn imax(a : Int, b : Int) -> Int {
  if a > b { a } else { b }
}

fn i64min(a : Int64, b : Int64) -> Int64 {
  if a < b { a } else { b }
}

///| Copy `buffer[from..from+len]` into fresh `Bytes` (C passes pointers). */
fn buffer_slice(buffer : FixedArray[Byte], from : Int, len : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < imax(len, 0); i = i + 1 {
    out.push(buffer[from + i])
  }
  Bytes::from_array(out[:])
}

///| Invoke the checksum updater over a byte range (None-safe). */
fn checksum_update(
    update : AvioChecksumFn,
    crc : UInt,
    buffer : FixedArray[Byte],
    from : Int,
    len : Int) -> UInt {
  update(crc, buffer_slice(buffer, from, len))
}

// ---------------------------------------------------------------------------
// Write path (aviobuf.c writeout .. avio_wb24)
// ---------------------------------------------------------------------------

///| `writeout`: hand `data[start..start+len]` to the write callback. */
fn writeout(s : AvioContext, data : FixedArray[Byte], start : Int, len : Int) -> Unit {
  if s.err == None {
    let ret = match s.write_packet {
      Some(f) => f(data, start, len)
      None => Ok(len)
    }
    match ret {
      Err(e) => s.err = Some(e)
      Ok(_) => {
        s.bytes_written = s.bytes_written + len.to_int64()
        if s.pos + len.to_int64() > s.written_output_size {
          s.written_output_size = s.pos + len.to_int64()
        }
      }
    }
  }
  s.writeout_count = s.writeout_count + 1
  s.pos = s.pos + len.to_int64()
}

///| `flush_buffer`: write out buffered data and reset the cursors. */
fn flush_buffer(s : AvioContext) -> Unit {
  s.buf_ptr_max = imax(s.buf_ptr, s.buf_ptr_max)
  if s.write_flag && s.buf_ptr_max > 0 {
    writeout(s, s.buffer, 0, s.buf_ptr_max)
    match s.update_checksum {
      Some(update) => {
        if s.buf_ptr_max > s.checksum_ptr {
          s.checksum = checksum_update(update, s.checksum, s.buffer, s.checksum_ptr, s.buf_ptr_max - s.checksum_ptr)
        }
        s.checksum_ptr = 0
      }
      None => ()
    }
  }
  s.buf_ptr = 0
  s.buf_ptr_max = 0
  if s.write_flag == false {
    s.buf_end = 0
  }
}

///| `avio_w8`: append one byte, flushing when the buffer fills. */
pub fn AvioContext::avio_w8(s : AvioContext, b : Int) -> Unit {
  s.buffer[s.buf_ptr] = b.to_byte()
  s.buf_ptr = s.buf_ptr + 1
  if s.buf_ptr >= s.buf_end {
    flush_buffer(s)
  }
}

///| `ffio_fill`: append `count` copies of byte `b`. */
pub fn AvioContext::ffio_fill(s : AvioContext, b : Int, count : Int64) -> Unit {
  let mut count = count
  while count > 0 {
    let len = imin(s.buf_end - s.buf_ptr, count.to_int())
    for i = 0; i < len; i = i + 1 {
      s.buffer[s.buf_ptr + i] = b.to_byte()
    }
    s.buf_ptr = s.buf_ptr + len
    if s.buf_ptr >= s.buf_end {
      flush_buffer(s)
    }
    count = count - len.to_int64()
  }
}

///| `avio_write`: append `data`. A direct context bypasses the buffer. */
pub fn AvioContext::avio_write(s : AvioContext, data : Bytes) -> Unit {
  let size = data.length()
  if size <= 0 {
    return
  }
  if s.direct && s.update_checksum is None {
    s.avio_flush()
    let tmp : FixedArray[Byte] = FixedArray::make(size, b'\x00')
    for i = 0; i < size; i = i + 1 {
      tmp[i] = data[i]
    }
    writeout(s, tmp, 0, size)
    return
  }
  let mut off = 0
  let mut left = size
  let mut go = true
  while go {
    let len = imin(s.buf_end - s.buf_ptr, left)
    for i = 0; i < len; i = i + 1 {
      s.buffer[s.buf_ptr + i] = data[off + i]
    }
    s.buf_ptr = s.buf_ptr + len
    if s.buf_ptr >= s.buf_end {
      flush_buffer(s)
    }
    off = off + len
    left = left - len
    go = left > 0
  }
  ignore(off)
}

///| `avio_flush`: write out buffered bytes; if the cursor had been seeked
/// back below `buf_ptr_max`, restore that position afterwards. */
pub fn AvioContext::avio_flush(s : AvioContext) -> Unit {
  let seekback = if s.write_flag { imin(0, s.buf_ptr - s.buf_ptr_max) } else { 0 }
  flush_buffer(s)
  if seekback != 0 {
    let _ = s.avio_skip(seekback.to_int64())
  }
}

///| `avio_wl16`. */
pub fn AvioContext::avio_wl16(s : AvioContext, val : UInt) -> Unit {
  s.avio_w8((val & 0xFF).reinterpret_as_int())
  s.avio_w8((val >> 8).reinterpret_as_int())
}

///| `avio_wb16`. */
pub fn AvioContext::avio_wb16(s : AvioContext, val : UInt) -> Unit {
  s.avio_w8((val >> 8).reinterpret_as_int())
  s.avio_w8((val & 0xFF).reinterpret_as_int())
}

///| `avio_wl24`. */
pub fn AvioContext::avio_wl24(s : AvioContext, val : UInt) -> Unit {
  s.avio_wl16(val & 0xFFFF)
  s.avio_w8((val >> 16).reinterpret_as_int())
}

///| `avio_wb24`. */
pub fn AvioContext::avio_wb24(s : AvioContext, val : UInt) -> Unit {
  s.avio_wb16(val >> 8)
  s.avio_w8((val & 0xFF).reinterpret_as_int())
}

///| `avio_wl32`. */
pub fn AvioContext::avio_wl32(s : AvioContext, val : UInt) -> Unit {
  s.avio_w8((val & 0xFF).reinterpret_as_int())
  s.avio_w8(((val >> 8) & 0xFF).reinterpret_as_int())
  s.avio_w8(((val >> 16) & 0xFF).reinterpret_as_int())
  s.avio_w8((val >> 24).reinterpret_as_int())
}

///| `avio_wb32`. */
pub fn AvioContext::avio_wb32(s : AvioContext, val : UInt) -> Unit {
  s.avio_w8((val >> 24).reinterpret_as_int())
  s.avio_w8(((val >> 16) & 0xFF).reinterpret_as_int())
  s.avio_w8(((val >> 8) & 0xFF).reinterpret_as_int())
  s.avio_w8((val & 0xFF).reinterpret_as_int())
}

///| `avio_wl64`. */
pub fn AvioContext::avio_wl64(s : AvioContext, val : UInt64) -> Unit {
  s.avio_wl32((val & 0xFFFFFFFFUL).to_uint())
  s.avio_wl32((val >> 32).to_uint())
}

///| `avio_wb64`. */
pub fn AvioContext::avio_wb64(s : AvioContext, val : UInt64) -> Unit {
  s.avio_wb32((val >> 32).to_uint())
  s.avio_wb32((val & 0xFFFFFFFFUL).to_uint())
}

///| `ffio_wfourcc` (avio_internal.h inline): write a four-character tag. */
pub fn AvioContext::ffio_wfourcc(s : AvioContext, str : String) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    s.avio_w8(str.at(i).to_int())
  }
}

///| `avio_put_str`: write the UTF-8 bytes of `str` plus the terminating NUL
/// (C writes `strlen(str) + 1` bytes); returns that byte count. */
pub fn AvioContext::avio_put_str(s : AvioContext, str : String) -> Int {
  let data = utf8_from_string(str)
  s.avio_write(data)
  s.avio_w8(0)
  data.length() + 1
}

///|
/// `put_str16` (avio_put_str16le / avio_put_str16be): UTF-8 → UTF-16 code
/// units plus a NUL terminator; returns the byte count written (C counts
/// `ret += 2` per unit, terminator included). A C-invalid UTF-8 sequence is
/// impossible here (MoonBit strings are always valid), so the C `EINVAL`
/// path has no equivalent.
pub fn AvioContext::avio_put_str16(s : AvioContext, str : String, be : Bool) -> Int {
  let mut ret = 0
  let n = str.length()
  let mut i = 0
  while i < n {
    let u = str.at(i).to_int()
    let mut cp = u
    if u >= 0xD800 && u < 0xDC00 && i + 1 < n {
      let lo = str.at(i + 1).to_int()
      if lo >= 0xDC00 && lo < 0xE000 {
        cp = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
        i = i + 1 // consume the low surrogate too
      }
    }
    if cp < 0x10000 {
      if be {
        s.avio_wb16(cp.reinterpret_as_uint())
      } else {
        s.avio_wl16(cp.reinterpret_as_uint())
      }
      ret = ret + 2
    } else {
      let v = cp - 0x10000
      if be {
        s.avio_wb16((0xD800 + (v >> 10)).reinterpret_as_uint())
        s.avio_wb16((0xDC00 + (v & 0x3FF)).reinterpret_as_uint())
      } else {
        s.avio_wl16((0xD800 + (v >> 10)).reinterpret_as_uint())
        s.avio_wl16((0xDC00 + (v & 0x3FF)).reinterpret_as_uint())
      }
      ret = ret + 4
    }
    i = i + 1
  }
  if be {
    s.avio_wb16(0)
  } else {
    s.avio_wl16(0)
  }
  ret + 2
}

///| `avio_print_string_array`: one `str` + `\n` per entry. */
pub fn AvioContext::avio_print_string_array(s : AvioContext, strs : Array[String]) -> Unit {
  for i = 0; i < strs.length(); i = i + 1 {
    s.avio_write(utf8_from_string(strs[i]))
    s.avio_w8(10)
  }
}

// ---------------------------------------------------------------------------
// Read path (aviobuf.c read_packet_wrapper .. avio_rb64)
// ---------------------------------------------------------------------------

///| `read_packet_wrapper` for a destination that may be the context buffer
/// (`fill_buffer`) or the caller's buffer (direct `avio_read`). */
fn call_read_packet(
    s : AvioContext,
    dst : FixedArray[Byte],
    start : Int,
    len : Int) -> Result[Int, String] {
  match s.read_packet {
    Some(f) => f(dst, start, len)
    None => Err("EINVAL")
  }
}

///| `fill_buffer`: refill from the read callback, appending after `buf_end`
/// when there is room for a whole max packet, else rewinding to the start. */
fn fill_buffer(s : AvioContext) -> Unit {
  let max_buffer_size = if s.max_packet_size != 0 { s.max_packet_size } else { IO_BUFFER_SIZE }
  let dst : Int = if s.buf_end + max_buffer_size <= s.buffer_size { s.buf_end } else { 0 }
  let mut len : Int = s.buffer_size - dst
  if s.read_packet is None && s.buf_ptr >= s.buf_end {
    s.eof_reached = true
  }
  // no need to do anything if EOF already reached
  if s.eof_reached {
    return
  }
  match s.update_checksum {
    Some(update) =>
      if dst == 0 {
        if s.buf_end > s.checksum_ptr {
          s.checksum = checksum_update(update, s.checksum, s.buffer, s.checksum_ptr, s.buf_end - s.checksum_ptr)
        }
        s.checksum_ptr = 0
      }
    None => ()
  }
  // make buffer smaller in case it ended up large after probing
  if s.read_packet is Some(_) && s.orig_buffer_size != 0 && s.buffer_size > s.orig_buffer_size && len >= s.orig_buffer_size {
    if dst == 0 && s.buf_ptr != 0 {
      let _ = set_buf_size(s, s.orig_buffer_size)
      s.checksum_ptr = 0 // s->checksum_ptr = dst = s->buffer
    }
    len = s.orig_buffer_size
  }
  match call_read_packet(s, s.buffer, dst, len) {
    Err("EOF") =>
      // do not modify the buffer on EOF so a seek back needs no reread
      s.eof_reached = true
    Err(e) => {
      s.eof_reached = true
      s.err = Some(e)
    }
    Ok(n) => {
      s.pos = s.pos + n.to_int64()
      s.buf_ptr = dst
      s.buf_end = dst + n
      s.bytes_read = s.bytes_read + n.to_int64()
    }
  }
}

///| `avio_r8`: one byte, 0 at EOF (the failed read raises `eof_reached`). */
pub fn AvioContext::avio_r8(s : AvioContext) -> UInt {
  if s.buf_ptr >= s.buf_end {
    fill_buffer(s)
  }
  if s.buf_ptr < s.buf_end {
    let v = s.buffer[s.buf_ptr].to_uint()
    s.buf_ptr = s.buf_ptr + 1
    v
  } else {
    0
  }
}

///| `avio_read`: read up to `size` bytes into `buf[offset..]`; returns the
/// byte count, `Err("EOF")` when nothing could be read at EOF, or the stored
/// error. Requests larger than the buffer (or direct contexts) bypass it. */
pub fn AvioContext::avio_read_into(
    s : AvioContext,
    buf : FixedArray[Byte],
    offset : Int,
    size : Int) -> Result[Int, String] {
  let size1 = size
  let mut size = size
  let mut dst = offset
  let mut done = false
  while size > 0 && done == false {
    let mut len = imin(s.buf_end - s.buf_ptr, size)
    if len == 0 || s.write_flag {
      if (s.direct || size > s.buffer_size) && s.update_checksum is None && s.read_packet is Some(_) {
        // bypass the buffer and read data directly into buf
        match call_read_packet(s, buf, dst, size) {
          Err("EOF") => {
            s.eof_reached = true
            done = true
          }
          Err(e) => {
            s.eof_reached = true
            s.err = Some(e)
            done = true
          }
          Ok(n) => {
            s.pos = s.pos + n.to_int64()
            s.bytes_read = s.bytes_read + n.to_int64()
            size = size - n
            dst = dst + n
            // reset the buffer
            s.buf_ptr = 0
            s.buf_end = 0
          }
        }
      } else {
        fill_buffer(s)
        len = s.buf_end - s.buf_ptr
        if len == 0 {
          done = true
        }
      }
    } else {
      for i = 0; i < len; i = i + 1 {
        buf[dst + i] = s.buffer[s.buf_ptr + i]
      }
      dst = dst + len
      s.buf_ptr = s.buf_ptr + len
      size = size - len
    }
  }
  if size1 == size {
    match s.err {
      Some(e) => return Err(e)
      None => if s.avio_feof() {
        return Err("EOF")
      }
    }
  }
  Ok(size1 - size)
}

///| `avio_read` returning `Bytes` (the common MoonBit-facing shape). */
pub fn AvioContext::avio_read(s : AvioContext, size : Int) -> Result[Bytes, String] {
  let buf : FixedArray[Byte] = FixedArray::make(imax(size, 0), b'\x00')
  match s.avio_read_into(buf, 0, size) {
    Err(e) => Err(e)
    Ok(n) => Ok(buffer_slice(buf, 0, n))
  }
}

///| `ffio_read_size`: exactly `size` bytes or `Err("INVALIDDATA")`. */
pub fn AvioContext::ffio_read_size(s : AvioContext, size : Int) -> Result[Bytes, String] {
  match s.avio_read(size) {
    Ok(data) => if data.length() == size { Ok(data) } else { Err("INVALIDDATA") }
    Err("EOF") => Err("INVALIDDATA")
    Err(e) => Err(e)
  }
}

///| `ffio_read_indirect`: C returns a pointer into the context buffer when
/// the request is already buffered; MoonBit has no borrowed slices, so this
/// always copies but keeps the fast path that avoids the `avio_read` loop. */
pub fn AvioContext::ffio_read_indirect(s : AvioContext, size : Int) -> Bytes {
  if s.buf_end - s.buf_ptr >= size && s.write_flag == false {
    let out = buffer_slice(s.buffer, s.buf_ptr, size)
    s.buf_ptr = s.buf_ptr + size
    return out
  }
  match s.avio_read(size) {
    Ok(data) => data
    Err(_) => b""
  }
}

///| `avio_read_partial`: return what is buffered, filling at most once. */
pub fn AvioContext::avio_read_partial(s : AvioContext, size : Int) -> Result[Bytes, String] {
  if size < 0 {
    return Err("EINVAL")
  }
  let mut len = s.buf_end - s.buf_ptr
  if len == 0 {
    fill_buffer(s)
    len = s.buf_end - s.buf_ptr
  }
  if len > size {
    len = size
  }
  let out = buffer_slice(s.buffer, s.buf_ptr, len)
  s.buf_ptr = s.buf_ptr + len
  if len == 0 {
    match s.err {
      Some(e) => return Err(e)
      None => if s.avio_feof() {
        return Err("EOF")
      }
    }
  }
  Ok(out)
}

///| `avio_rl16`. */
pub fn AvioContext::avio_rl16(s : AvioContext) -> UInt {
  let mut val = s.avio_r8()
  val = val | (s.avio_r8() << 8)
  val
}

///| `avio_rl24`. */
pub fn AvioContext::avio_rl24(s : AvioContext) -> UInt {
  let mut val = s.avio_rl16()
  val = val | (s.avio_r8() << 16)
  val
}

///| `avio_rl32`. */
pub fn AvioContext::avio_rl32(s : AvioContext) -> UInt {
  let mut val = s.avio_rl16()
  val = val | (s.avio_rl16() << 16)
  val
}

///| `avio_rl64`. */
pub fn AvioContext::avio_rl64(s : AvioContext) -> UInt64 {
  let mut val = s.avio_rl32().to_uint64()
  val = val | (s.avio_rl32().to_uint64() << 32)
  val
}

///| `avio_rb16`. */
pub fn AvioContext::avio_rb16(s : AvioContext) -> UInt {
  let mut val = s.avio_r8() << 8
  val = val | s.avio_r8()
  val
}

///| `avio_rb24`. */
pub fn AvioContext::avio_rb24(s : AvioContext) -> UInt {
  let mut val = s.avio_rb16() << 8
  val = val | s.avio_r8()
  val
}

///| `avio_rb32`. */
pub fn AvioContext::avio_rb32(s : AvioContext) -> UInt {
  let mut val = s.avio_rb16() << 16
  val = val | s.avio_rb16()
  val
}

///| `avio_rb64`. */
pub fn AvioContext::avio_rb64(s : AvioContext) -> UInt64 {
  let mut val = s.avio_rb32().to_uint64() << 32
  val = val | s.avio_rb32().to_uint64()
  val
}

///|
/// The mov demuxer's atom-tag read: C reads the type with `avio_rl32` and
/// compares against `MKTAG(a,b,c,d)`; both reduce to the four file-order
/// bytes, returned here as a 4-character string. Past-EOF reads yield NUL
/// characters, matching `avio_r8` returning 0.
pub fn AvioContext::avio_rl32_tag(s : AvioContext) -> String {
  let chars : Array[Char] = []
  for i = 0; i < 4; i = i + 1 {
    chars.push(s.avio_r8().to_byte().to_char())
  }
  String::from_array(chars[:])
}

// ---------------------------------------------------------------------------
// Seek / size / EOF (aviobuf.c avio_seek .. avio_feof)
// ---------------------------------------------------------------------------

///|
/// `avio_seek`: absolute (`SEEK_SET`) or relative (`SEEK_CUR`) seek with the
/// C path selection — inside the buffer first, then (reads only) skip
/// forward while within `short_seek_threshold` of the buffer or when the
/// protocol is not seekable, then a half-buffer backward refill, finally the
/// protocol seek callback. `avio_seek(s, 0, SEEK_CUR)` is `avio_tell` without
/// side effects.
pub fn AvioContext::avio_seek(
    s : AvioContext,
    offset : Int64,
    whence : Int) -> Result[Int64, String] {
  let whence = whence & AVSEEK_FORCE.lnot()
  if (whence & AVSEEK_SIZE) != 0 {
    return match s.seek_fn {
      Some(f) => f(offset, AVSEEK_SIZE)
      None => Err("ENOSYS")
    }
  }
  let buffer_size = s.buf_end
  // pos is the absolute position the beginning of the buffer corresponds to
  let mut pos = s.pos - (if s.write_flag { 0L } else { buffer_size.to_int64() })
  if whence != SEEK_CUR && whence != SEEK_SET {
    return Err("EINVAL")
  }
  let mut offset = offset
  if whence == SEEK_CUR {
    let offset1 = pos + s.buf_ptr.to_int64()
    if offset == 0 {
      return Ok(offset1)
    }
    if offset > 9223372036854775807L - offset1 {
      return Err("EINVAL")
    }
    offset = offset + offset1
  }
  if offset < 0 {
    return Err("EINVAL")
  }
  let short_seek = s.short_seek_threshold
  let offset1 = offset - pos
  s.buf_ptr_max = imax(s.buf_ptr_max, s.buf_ptr)
  if (s.direct == false || s.seek_fn is None) && offset1 >= 0 && offset1 <= (if s.write_flag { s.buf_ptr_max } else { buffer_size }).to_int64() {
    // can do the seek inside the buffer
    s.buf_ptr = offset1.to_int()
  } else if (s.seekable == false || offset1 <= buffer_size.to_int64() + short_seek.to_int64()) && s.write_flag == false && offset1 >= 0 && (s.direct == false || s.seek_fn is None) {
    // serve the forward seek by reading
    while s.pos < offset && s.eof_reached == false {
      fill_buffer(s)
    }
    if s.eof_reached {
      return Err("EOF")
    }
    s.buf_ptr = s.buf_end - (s.pos - offset).to_int()
  } else if s.write_flag == false && offset1 < 0 && (-offset1) < (buffer_size >> 1).to_int64() && s.seek_fn is Some(_) && offset > 0 {
    // half-buffer backward refill: rewind the source behind the target and
    // refill, then retry (the retry hits the in-buffer path)
    pos = pos - i64min((buffer_size >> 1).to_int64(), pos)
    match (s.seek_fn.unwrap())(pos, SEEK_SET) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    s.buf_end = 0
    s.buf_ptr = 0
    s.pos = pos
    s.eof_reached = false
    fill_buffer(s)
    return s.avio_seek(offset, SEEK_SET)
  } else {
    if s.write_flag {
      flush_buffer(s)
    }
    match s.seek_fn {
      None => return Err("EPIPE")
      Some(f) =>
        match f(offset, SEEK_SET) {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
    }
    s.seek_count = s.seek_count + 1
    if s.write_flag == false {
      s.buf_end = 0
    }
    s.buf_ptr = 0
    s.buf_ptr_max = 0
    s.checksum_ptr = 0
    s.pos = offset
  }
  s.eof_reached = false
  Ok(offset)
}

///| `avio_skip`. */
pub fn AvioContext::avio_skip(s : AvioContext, offset : Int64) -> Result[Int64, String] {
  s.avio_seek(offset, SEEK_CUR)
}

///| `avio_tell` (avio.h inline: `avio_seek(s, 0, SEEK_CUR)`). */
pub fn AvioContext::avio_tell(s : AvioContext) -> Int64 {
  s.pos - (if s.write_flag { 0L } else { s.buf_end.to_int64() }) + s.buf_ptr.to_int64()
}

///| `avio_size`: ask the callback with `AVSEEK_SIZE`, fall back to
/// `SEEK_END`-minus-one plus a restore (the restore targets `s->pos`, i.e.
/// the buffer end, exactly like the C code). */
pub fn AvioContext::avio_size(s : AvioContext) -> Result[Int64, String] {
  if s.written_output_size != 0 {
    return Ok(s.written_output_size)
  }
  match s.seek_fn {
    None => Err("ENOSYS")
    Some(f) =>
      match f(0L, AVSEEK_SIZE) {
        Ok(size) => Ok(size)
        Err(_) =>
          match f(-1L, SEEK_END) {
            Err(e) => Err(e)
            Ok(size) => {
              let _ = f(s.pos, SEEK_SET)
              Ok(size + 1)
            }
          }
      }
  }
}

///| `avio_feof`: clears and retests the flag, so a reader that appended more
/// data after a previous EOF can continue. */
pub fn AvioContext::avio_feof(s : AvioContext) -> Bool {
  if s.eof_reached {
    s.eof_reached = false
    fill_buffer(s)
  }
  s.eof_reached
}

// ---------------------------------------------------------------------------
// String reading (aviobuf.c ff_get_line / avio_get_str / GET_STR16)
// ---------------------------------------------------------------------------

///| `ff_get_line`: read until `\n`, `\r` or EOF. As in C, a `\n`/`\r`
/// terminator is consumed AND stored (the loop's store happens before the
/// stop test); `\r\n` is collapsed to the stored `\r` only when a `\n`
/// follows. Returns the line and the stored length. */
pub fn AvioContext::ff_get_line(s : AvioContext, maxlen : Int) -> (String, Int) {
  let out : Array[Char] = []
  let mut c : UInt = 0
  let mut run = true
  while run {
    c = s.avio_r8()
    if c != 0 && out.length() < maxlen - 1 {
      out.push(c.to_byte().to_char())
    }
    run = c != 10 && c != 13 && c != 0
  }
  if c == 13 {
    // CRLF: peek the \n and unread anything else
    let c2 = s.avio_r8()
    if c2 != 10 && s.avio_feof() == false {
      let _ = s.avio_skip(-1L)
    }
  }
  (String::from_array(out[:]), out.length())
}

///| `ff_get_chomp_line`: `ff_get_line` plus trailing whitespace removal. */
pub fn AvioContext::ff_get_chomp_line(s : AvioContext, maxlen : Int) -> (String, Int) {
  let (line, len) = s.ff_get_line(maxlen)
  let mut len = len
  let chars = line.to_array()
  while len > 0 && av_isspace(chars[len - 1]) {
    len = len - 1
  }
  (String::from_array(chars[0:len]), len)
}

fn av_isspace(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0B}' || c == '\u{0C}'
}

///|
/// Decode UTF-8 bytes to a MoonBit string, replacing malformed sequences with
/// U+FFFD (lenient — C consumers keep the raw bytes; what callers depend on
/// is the consumed-count return value, which is produced by the callers).
fn utf8_to_string(data : Array[Byte]) -> String {
  let chars : Array[Char] = []
  let mut i = 0
  while i < data.length() {
    let b0 = data[i].to_int()
    let mut cp : Int = 0xFFFD
    let mut extra = 0
    if b0 < 0x80 {
      cp = b0
    } else if b0 >= 0xC2 && b0 < 0xE0 {
      cp = b0 & 0x1F
      extra = 1
    } else if b0 >= 0xE0 && b0 < 0xF0 {
      cp = b0 & 0x0F
      extra = 2
    } else if b0 >= 0xF0 && b0 < 0xF5 {
      cp = b0 & 0x07
      extra = 3
    }
    let mut ok = true
    if extra > 0 {
      let mut j = 0
      while j < extra && i + 1 + j < data.length() {
        let b = data[i + 1 + j].to_int()
        if (b & 0xC0) == 0x80 {
          cp = (cp << 6) | (b & 0x3F)
        } else {
          ok = false
        }
        j = j + 1
      }
      if ok == false || j != extra {
        cp = 0xFFFD
        extra = 0
      }
    }
    if cp <= 0xFFFF {
      chars.push(cp.unsafe_to_char())
    } else {
      // astral plane → surrogate pair (MoonBit strings are UTF-16)
      let v = cp - 0x10000
      chars.push((0xD800 + (v >> 10)).unsafe_to_char())
      chars.push((0xDC00 + (v & 0x3FF)).unsafe_to_char())
    }
    i = i + 1 + extra
  }
  String::from_array(chars[:])
}

///| Encode a MoonBit string as UTF-8 bytes (for the `avio_put_str*` family). */
fn utf8_from_string(str : String) -> Bytes {
  let out : Array[Byte] = []
  let n = str.length()
  let mut i = 0
  while i < n {
    let u = str.at(i).to_int()
    let mut cp = u
    if u >= 0xD800 && u < 0xDC00 && i + 1 < n {
      let lo = str.at(i + 1).to_int()
      if lo >= 0xDC00 && lo < 0xE000 {
        cp = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
        i = i + 1 // consume the low surrogate too
      }
    }
    if cp < 0x80 {
      out.push(cp.to_byte())
    } else if cp < 0x800 {
      out.push((0xC0 | (cp >> 6)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      out.push((0xE0 | (cp >> 12)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else {
      out.push((0xF0 | (cp >> 18)).to_byte())
      out.push((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    }
    i = i + 1
  }
  Bytes::from_array(out[:])
}

///|
/// `avio_get_str`: read up to `maxlen` input bytes, stopping after a NUL;
/// `buflen` caps the produced string (C's output buffer including its
/// terminator). Returns the string (terminator excluded) and the input bytes
/// consumed — the C return value counts the terminator when present.
pub fn AvioContext::avio_get_str(
    s : AvioContext,
    maxlen : Int,
    buflen : Int) -> Result[(String, Int), String] {
  if buflen <= 0 {
    return Err("EINVAL")
  }
  let cap = imin(buflen - 1, maxlen) // reserve 1 byte for the terminating 0
  let out : Array[Byte] = []
  for i = 0; i < cap; i = i + 1 {
    let c = s.avio_r8()
    if c == 0 {
      return Ok((utf8_to_string(out), i + 1))
    }
    out.push(c.to_byte())
  }
  let mut i = cap
  while i < maxlen {
    if s.avio_r8() == 0 {
      return Ok((utf8_to_string(out), i + 1))
    }
    i = i + 1
  }
  Ok((utf8_to_string(out), maxlen))
}

///|
/// `avio_get_str16le`/`avio_get_str16be` (C macro `GET_STR16`): read UTF-16
/// code units (byte order per `be`), stop at a NUL unit, re-encode as UTF-8
/// capped by `buflen` (the cap counts the stored bytes, terminator
/// excluded). Returns the string and the input **byte** count, which counts
/// the terminating unit — exactly the C `ret`.
pub fn AvioContext::avio_get_str16(
    s : AvioContext,
    be : Bool,
    maxlen : Int,
    buflen : Int) -> Result[(String, Int), String] {
  if buflen <= 0 {
    return Err("EINVAL")
  }
  let out : Array[Byte] = []
  let mut ret = 0
  fn read_unit(s : AvioContext, be : Bool, ret : Int, maxlen : Int) -> (Int, Int) {
    let r = ret + 2
    if r <= maxlen {
      let u = if be { s.avio_rb16() } else { s.avio_rl16() }
      (r, u.reinterpret_as_int() & 0xFFFF)
    } else {
      (r, 0) // C: (ret += 2) <= maxlen ? read(pb) : 0
    }
  }
  let mut done = false
  while ret + 1 < maxlen && done == false {
    // GET_UTF16: a surrogate pair is two units combined into one code point
    let (r1, u1) = read_unit(s, be, ret, maxlen)
    ret = r1
    let mut ch = u1
    let hi = u1 - 0xD800
    if hi >= 0 && hi < 0x800 {
      let (r2, u2) = read_unit(s, be, ret, maxlen)
      ret = r2
      let lo = u2 - 0xDC00
      if lo < 0 || lo > 0x3FF || hi > 0x3FF {
        done = true // GET_UTF16 ERROR → break
        ch = 0
      } else {
        ch = (hi << 10) + lo + 0x10000
      }
    }
    if done == false {
      if ch == 0 {
        done = true
      } else {
        // PUT_UTF8 with the `q - buf < buflen - 1` store guard
        let utf8 : Array[Byte] = []
        if ch < 0x80 {
          utf8.push(ch.to_byte())
        } else if ch < 0x800 {
          utf8.push((0xC0 | (ch >> 6)).to_byte())
          utf8.push((0x80 | (ch & 0x3F)).to_byte())
        } else if ch < 0x10000 {
          utf8.push((0xE0 | (ch >> 12)).to_byte())
          utf8.push((0x80 | ((ch >> 6) & 0x3F)).to_byte())
          utf8.push((0x80 | (ch & 0x3F)).to_byte())
        } else {
          utf8.push((0xF0 | (ch >> 18)).to_byte())
          utf8.push((0x80 | ((ch >> 12) & 0x3F)).to_byte())
          utf8.push((0x80 | ((ch >> 6) & 0x3F)).to_byte())
          utf8.push((0x80 | (ch & 0x3F)).to_byte())
        }
        for i = 0; i < utf8.length(); i = i + 1 {
          if out.length() < buflen - 1 {
            out.push(utf8[i])
          }
        }
      }
    }
  }
  Ok((utf8_to_string(out), ret))
}

// ---------------------------------------------------------------------------
// Variable-length integers (aviobuf.c ffio_read_varlen / leb)
// ---------------------------------------------------------------------------

///| `ffio_read_varlen`: 7 bits per byte, high bit = continue. */
pub fn AvioContext::ffio_read_varlen(s : AvioContext) -> UInt64 {
  let mut val : UInt64 = 0
  let mut tmp : UInt = 0
  let mut run = true
  while run {
    tmp = s.avio_r8()
    val = (val << 7) + (tmp & 127).to_uint64()
    run = (tmp & 128) != 0
  }
  val
}

///| `ffio_read_leb`: little-endian base-128, at most 8 bytes. */
pub fn AvioContext::ffio_read_leb(s : AvioContext) -> UInt {
  let mut leb : UInt = 0
  let mut i = 0
  let mut more = true
  while more {
    let byte = s.avio_r8()
    let bits = byte & 0x7F
    more = (byte & 0x80) != 0
    if i <= 4 {
      leb = leb | (bits << (i * 7))
    }
    i = i + 1
    if i == 8 {
      break
    }
  }
  leb
}

///| `ffio_write_leb`. */
pub fn AvioContext::ffio_write_leb(s : AvioContext, val : UInt) -> Unit {
  let log2 = if val == 0 {
    0
  } else {
    let mut v = val
    let mut n = 0
    while v > 1 {
      v = v >> 1
      n = n + 1
    }
    n
  }
  let len = (log2 + 7) / 7
  for i = 0; i < len; i = i + 1 {
    let mut byte = (val >> (7 * i)) & 0x7F
    if i < len - 1 {
      byte = byte | 0x80
    }
    s.avio_w8(byte.reinterpret_as_int())
  }
}

///| `ffio_write_lines`: rewrite line endings — `\r`, `\n` and `\r\n` in the
/// input each become `ending` (default `\n`). */
pub fn AvioContext::ffio_write_lines(s : AvioContext, buf : Bytes, ending : String?) -> Unit {
  let ending = match ending {
    Some(e) => e
    None => "\n"
  }
  let mut off = 0
  while off < buf.length() {
    let mut len = 0
    let mut last : Byte = b'\x00'
    while off + len < buf.length() {
      last = buf[off + len]
      len = len + 1
      if last == b'\r' || last == b'\n' {
        break
      }
    }
    s.avio_write(buffer_slice_of(buf, off, len))
    for i = 0; i < ending.length(); i = i + 1 {
      s.avio_w8(ending.at(i).to_int())
    }
    off = off + len
    if off < buf.length() && last == b'\r' && buf[off] == b'\n' {
      off = off + 1
    }
  }
}

fn buffer_slice_of(buf : Bytes, from : Int, len : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < imax(len, 0); i = i + 1 {
    out.push(buf[from + i])
  }
  Bytes::from_array(out[:])
}

// ---------------------------------------------------------------------------
// Checksum (aviobuf.c ff_crc* / ffio_init_checksum)
// ---------------------------------------------------------------------------

///| `ff_crc04C11DB7_update`: CRC-32 (`AV_CRC_32_IEEE`). */
pub fn ff_crc04C11DB7_update(checksum : UInt, buf : Bytes) -> UInt {
  match @libavutil.av_crc_init(false, 32, 0x04C11DB7) {
    Ok(ctx) => @libavutil.av_crc(ctx, checksum, buf)
    Err(_) => checksum
  }
}

///| `ff_crcEDB88320_update`: CRC-32 reflected (`AV_CRC_32_IEEE_LE`). */
pub fn ff_crcEDB88320_update(checksum : UInt, buf : Bytes) -> UInt {
  match @libavutil.av_crc_init(true, 32, 0xEDB88320) {
    Ok(ctx) => @libavutil.av_crc(ctx, checksum, buf)
    Err(_) => checksum
  }
}

///| `ff_crcA001_update`: CRC-16 ANSI reflected (`AV_CRC_16_ANSI_LE`). */
pub fn ff_crcA001_update(checksum : UInt, buf : Bytes) -> UInt {
  match @libavutil.av_crc_init(true, 16, 0xA001) {
    Ok(ctx) => @libavutil.av_crc(ctx, checksum, buf)
    Err(_) => checksum
  }
}

///| `update_checksum` helper: fold in everything up to `buf_ptr` (used
/// before the seekback machinery moves data inside the buffer). */
fn update_checksum_to_ptr(s : AvioContext) -> Unit {
  match s.update_checksum {
    Some(update) =>
      if s.buf_ptr > s.checksum_ptr {
        s.checksum = checksum_update(update, s.checksum, s.buffer, s.checksum_ptr, s.buf_ptr - s.checksum_ptr)
      }
    None => ()
  }
}

///| `ffio_init_checksum`. */
pub fn AvioContext::ffio_init_checksum(
    s : AvioContext,
    update : AvioChecksumFn?,
    checksum : UInt) -> Unit {
  s.update_checksum = update
  if s.update_checksum is Some(_) {
    s.checksum = checksum
    s.checksum_ptr = s.buf_ptr
  }
}

///| `ffio_get_checksum`: fold in the pending range and stop updating. */
pub fn AvioContext::ffio_get_checksum(s : AvioContext) -> UInt {
  if s.update_checksum is Some(_) {
    update_checksum_to_ptr(s)
    s.update_checksum = None
  }
  s.checksum
}

// ---------------------------------------------------------------------------
// Buffer sizing (aviobuf.c set_buf_size / ffio_realloc_buf / ffio_ensure_seekback)
// ---------------------------------------------------------------------------

///| `set_buf_size`: replace the buffer with a fresh one of `buf_size`. */
fn set_buf_size(s : AvioContext, buf_size : Int) -> Result[Unit, String] {
  s.buffer = FixedArray::make(buf_size, b'\x00')
  s.orig_buffer_size = buf_size
  s.buffer_size = buf_size
  s.buf_ptr = 0
  s.buf_ptr_max = 0
  // url_resetbuf
  if s.write_flag {
    s.buf_end = buf_size
  } else {
    s.buf_end = 0
  }
  Ok(())
}

///| `ffio_realloc_buf`: grow to `buf_size`, preserving buffered data. */
pub fn AvioContext::ffio_realloc_buf(s : AvioContext, buf_size : Int) -> Result[Unit, String] {
  if s.buffer_size == 0 {
    return set_buf_size(s, buf_size)
  }
  if buf_size <= s.buffer_size {
    return Ok(())
  }
  let data_size = if s.write_flag { s.buf_ptr } else { s.buf_end - s.buf_ptr }
  let nb : FixedArray[Byte] = FixedArray::make(buf_size, b'\x00')
  if data_size > 0 {
    let src = if s.write_flag { 0 } else { s.buf_ptr }
    for i = 0; i < data_size; i = i + 1 {
      nb[i] = s.buffer[src + i]
    }
  }
  s.buffer = nb
  s.orig_buffer_size = buf_size
  s.buffer_size = buf_size
  if s.write_flag {
    s.buf_ptr = data_size
    s.buf_ptr_max = data_size
    s.buf_end = buf_size
  } else {
    s.buf_ptr = 0
    s.buf_end = data_size
  }
  Ok(())
}

///| `ffio_ensure_seekback`: guarantee `buf_size` bytes of seek-back behind
/// the cursor by moving (and growing) the buffer; a no-op when the source is
/// seekable, since a real seek can always go back. */
pub fn AvioContext::ffio_ensure_seekback(
    s : AvioContext,
    buf_size : Int64) -> Result[Unit, String] {
  let max_buffer_size = if s.max_packet_size != 0 { s.max_packet_size } else { IO_BUFFER_SIZE }
  let filled = s.buf_end - s.buf_ptr
  if buf_size <= filled.to_int64() {
    return Ok(())
  }
  if buf_size > 9223372036854775807L - max_buffer_size.to_int64() {
    return Err("EINVAL")
  }
  let buf_size = buf_size + max_buffer_size.to_int64() - 1
  if buf_size + s.buf_ptr.to_int64() <= s.buffer_size.to_int64() || s.seekable || s.read_packet is None {
    return Ok(())
  }
  if buf_size <= s.buffer_size.to_int64() {
    update_checksum_to_ptr(s)
    // memmove(s->buffer, s->buf_ptr, filled)
    for i = 0; i < filled; i = i + 1 {
      s.buffer[i] = s.buffer[s.buf_ptr + i]
    }
  } else {
    let nb : FixedArray[Byte] = FixedArray::make(buf_size.to_int(), b'\x00')
    update_checksum_to_ptr(s)
    for i = 0; i < filled; i = i + 1 {
      nb[i] = s.buffer[s.buf_ptr + i]
    }
    s.buffer = nb
    s.buffer_size = buf_size.to_int()
  }
  s.buf_ptr = 0
  s.buf_end = filled
  s.checksum_ptr = 0
  Ok(())
}

// ---------------------------------------------------------------------------
// Dyn buffers (aviobuf.c DynBuffer .. ffio_close_null_buf)
// ---------------------------------------------------------------------------

///| `DynBuffer`: the growing backing store behind a write-only context. */
struct DynBuf {
  mut data : FixedArray[Byte]
  mut allocated : Int
  mut pos : Int
  mut size : Int
  io_buffer : FixedArray[Byte] // the context's own small write buffer
  io_buffer_size : Int
}

///| `dyn_buf_write` as a closure over `d` (growth ×1.5 + 1, like C). */
fn dyn_buf_write_fn(d : DynBuf) -> AvioWritePacket {
  (buf : FixedArray[Byte], start : Int, len : Int) => {
    let new_size = d.pos + len
    if new_size > d.allocated {
      let mut new_allocated = if d.allocated != 0 { d.allocated } else { new_size }
      while new_size > new_allocated {
        new_allocated = new_allocated + new_allocated / 2 + 1
      }
      let nb : FixedArray[Byte] = FixedArray::make(new_allocated, b'\x00')
      let keep = if d.size < d.data.length() { d.size } else { d.data.length() }
      for i = 0; i < keep; i = i + 1 {
        nb[i] = d.data[i]
      }
      d.data = nb
      d.allocated = new_allocated
    }
    for i = 0; i < len; i = i + 1 {
      d.data[d.pos + i] = buf[start + i]
    }
    d.pos = new_size
    if d.pos > d.size {
      d.size = d.pos
    }
    Ok(len)
  }
}

///| `dyn_packet_buf_write`: a WB32 length header before each write. */
fn dyn_packet_buf_write_fn(d : DynBuf) -> AvioWritePacket {
  let plain = dyn_buf_write_fn(d)
  (buf : FixedArray[Byte], start : Int, len : Int) => {
    let header : FixedArray[Byte] = FixedArray::make(4, b'\x00')
    let u = len.reinterpret_as_uint()
    header[0] = ((u >> 24) & 0xFF).to_byte()
    header[1] = ((u >> 16) & 0xFF).to_byte()
    header[2] = ((u >> 8) & 0xFF).to_byte()
    header[3] = (u & 0xFF).to_byte()
    match plain(header, 0, 4) {
      Err(e) => Err(e)
      Ok(_) => plain(buf, start, len)
    }
  }
}

///| `dyn_buf_seek`: seek within the written data (`SEEK_SET`/`CUR`/`END`). */
fn dyn_buf_seek_fn(d : DynBuf) -> AvioSeekFn {
  (offset : Int64, whence : Int) => {
    let mut offset = offset
    if whence == SEEK_CUR {
      offset = offset + d.pos.to_int64()
    } else if whence == SEEK_END {
      offset = offset + d.size.to_int64()
    }
    if offset < 0 {
      return Err("EINVAL")
    }
    d.pos = offset.to_int()
    Ok(0L)
  }
}

fn url_open_dyn_buf_internal(max_packet_size : Int) -> AvioContext {
  let io_buffer_size = if max_packet_size != 0 { max_packet_size } else { 1024 }
  let io_buffer : FixedArray[Byte] = FixedArray::make(io_buffer_size, b'\x00')
  let d : DynBuf = {
    data: FixedArray::make(0, b'\x00'),
    allocated: 0,
    pos: 0,
    size: 0,
    io_buffer,
    io_buffer_size,
  }
  let write : AvioWritePacket = if max_packet_size != 0 {
    dyn_packet_buf_write_fn(d)
  } else {
    dyn_buf_write_fn(d)
  }
  let seek : AvioSeekFn? = if max_packet_size != 0 { None } else { Some(dyn_buf_seek_fn(d)) }
  let s = AvioContext::init_context(io_buffer, true, None, Some(write), seek)
  s.max_packet_size = max_packet_size
  s.dynbuf = Some(d)
  s
}

///| `avio_open_dyn_buf`: a write context collecting into a growing buffer. */
pub fn avio_open_dyn_buf() -> AvioContext {
  url_open_dyn_buf_internal(0)
}

///| `ffio_open_dyn_packet_buf`: every flush is prefixed with a WB32 size. */
pub fn ffio_open_dyn_packet_buf(max_packet_size : Int) -> Result[AvioContext, String] {
  if max_packet_size <= 0 {
    return Err("EINVAL")
  }
  Ok(url_open_dyn_buf_internal(max_packet_size))
}

///|
/// `avio_get_dyn_buf`: the accumulated bytes. When nothing has been flushed
/// to the backing store yet, the pending bytes still sitting in the context's
/// write buffer are the result (the C fast path); otherwise flush first.
pub fn AvioContext::avio_get_dyn_buf(s : AvioContext) -> Bytes {
  match s.dynbuf {
    Some(d) => {
      if s.err == None && d.size == 0 {
        return buffer_slice(s.buffer, 0, imax(s.buf_ptr, s.buf_ptr_max))
      }
      s.avio_flush()
      buffer_slice(d.data, 0, d.size)
    }
    None => b""
  }
}

///| `ffio_reset_dyn_buf`: drop the contents, keep the context usable. */
pub fn AvioContext::ffio_reset_dyn_buf(s : AvioContext) -> Unit {
  match s.dynbuf {
    Some(d) => {
      let max_packet_size = s.max_packet_size
      let _ = AvioContext::init_context(d.io_buffer, true, None, s.write_packet, s.seek_fn)
      // re-arm the fresh context fields onto `s` (C reinitializes in place)
      s.buffer = d.io_buffer
      s.buffer_size = d.io_buffer_size
      s.buf_ptr = 0
      s.buf_ptr_max = 0
      s.buf_end = d.io_buffer_size
      s.pos = 0
      s.eof_reached = false
      s.write_flag = true
      s.err = None
      s.direct = false
      s.max_packet_size = max_packet_size
      s.orig_buffer_size = d.io_buffer_size
      s.checksum = 0
      s.checksum_ptr = 0
      s.update_checksum = None
      d.pos = 0
      d.size = 0
    }
    None => ()
  }
}

///|
/// `avio_close_dyn_buf`: flush, zero-pad (unless a packet buffer), and
/// detach the accumulated bytes; the returned `Bytes` excludes the padding
/// (C returns `size - padding` as the usable length).
pub fn AvioContext::avio_close_dyn_buf(s : AvioContext) -> Bytes {
  let mut padding = 0
  if s.max_packet_size == 0 {
    s.ffio_fill(0, AV_INPUT_BUFFER_PADDING_SIZE.to_int64())
    padding = AV_INPUT_BUFFER_PADDING_SIZE
  }
  s.avio_flush()
  match s.dynbuf {
    Some(d) => buffer_slice(d.data, 0, imax(d.size - padding, 0))
    None => b""
  }
}

///| `ffio_open_null_buf`: a write context that only counts bytes. */
pub fn ffio_open_null_buf() -> AvioContext {
  let s = avio_open_dyn_buf()
  s.write_packet = Some((_, _, len) => Ok(len))
  s
}

///| `ffio_close_null_buf`: the total byte count (or the stored error). */
pub fn AvioContext::ffio_close_null_buf(s : AvioContext) -> Int {
  s.avio_flush()
  match s.err {
    Some(_) => -1
    None => s.bytes_written.to_int()
  }
}
