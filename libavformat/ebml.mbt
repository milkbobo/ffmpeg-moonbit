///|
/// Port of the EBML reading layer of FFmpeg 9.0.2
/// `libavformat/matroskadec.c` (`ebml_read_num` .. `ebml_parse_nest`,
/// `is_ebml_id_valid`, `matroska_ebmlnum_sint`) plus the pieces of
/// `matroska.h` it needs. Every Matroska/WebM element — header, segment,
/// tracks, clusters — is walked through this layer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.
///
/// Conventions (diffs forced by MoonBit, mirroring `README.md` §6):
///   * the C's negative `AVERROR_*` returns become `Result[T, String]`
///     carrying the errno name (`AVERROR_EOF` is `Err("EOF")`); the
///     non-error sentinels `NEEDS_CHECKING` (2) and `LEVEL_ENDED` (3) stay
///     plain ints returned through `Ok`, exactly as in the C.
///   * the C's static `EbmlSyntax` tables write through `data + offset`;
///     here each row carries a `sink` closure that captures the destination
///     struct, and tables are built per parse by table-factory functions
///     (`Nest` carries a thunk so tables can reference each other without a
///     construction cycle). The sentinel `{ 0 }` row disappears (an Array
///     knows its length), and the `CHILD_OF(def.n)` sentinel chain — used to
///     end an unknown-length master when an upper-level element appears —
///     becomes an ancestor-stack of syntax tables carried through the walk.
///   * `ffio_limit`, `AV_INPUT_BUFFER_PADDING_SIZE` on binary reads and the
///     `is_counted` machinery have no equivalent here; lengths are still
///     checked against the per-type `max_lengths[]`.

// ---------------------------------------------------------------------------
// Constants (matroskadec.c / matroska.h / EBML spec)
// ---------------------------------------------------------------------------

///|
/// `EBML_UNKNOWN_LENGTH` (`UINT64_MAX`): the unknown-length marker. */
pub let ebml_unknown_length : UInt64 = 0xFFFFFFFFFFFFFFFFUL

///|
/// `NEEDS_CHECKING`: some error checks still need to be performed. */
pub let needs_checking : Int32 = 2

///|
/// `LEVEL_ENDED`: the syntax level used for parsing ended. */
pub let level_ended : Int32 = 3

///|
/// `EBML_MAX_DEPTH`: maximum EBML nesting depth. */
pub let ebml_max_depth : Int32 = 16

///|
/// `SKIP_THRESHOLD`: non-seekable mode error threshold for unknown data. */
pub let skip_threshold : Int64 = 1048576

///|
/// `UNKNOWN_EQUIV`: bytes an unknown element counts as in that check. */
pub let unknown_equiv : Int64 = 51200

///|
/// `EBML_ID_HEADER`. */
pub let ebml_id_header : UInt32 = 0x1A45DFA3

///|
/// `EBML_ID_VOID`. */
pub let ebml_id_void : UInt32 = 0xEC

///|
/// `EBML_ID_CRC32`. */
pub let ebml_id_crc32 : UInt32 = 0xBF

///|
/// `MATROSKA_ID_SEGMENT`. */
pub let matroska_id_segment : UInt32 = 0x18538067

///|
/// `MATROSKA_ID_CLUSTER` (unknown-length element policy). */
pub let matroska_id_cluster : UInt32 = 0x1F43B675

///|
/// `MATROSKA_ID_INFO`. */
pub let matroska_id_info : UInt32 = 0x1549A966

///|
/// `MATROSKA_ID_TRACKS`. */
pub let matroska_id_tracks : UInt32 = 0x1654AE6B

///|
/// `MATROSKA_ID_CUES`. */
pub let matroska_id_cues : UInt32 = 0x1C53BB6B

///|
/// `MATROSKA_ID_TAGS`. */
pub let matroska_id_tags : UInt32 = 0x1254C367

///|
/// `MATROSKA_ID_TAG`. */
pub let matroska_id_tag : UInt32 = 0x7373

///|
/// `MATROSKA_ID_TAGTARGETS`. */
pub let matroska_id_tagtargets : UInt32 = 0x63C0

///|
/// `MATROSKA_ID_TAGTARGETS_TRACKUID`. */
pub let matroska_id_tagtargets_trackuid : UInt32 = 0x63C5

///|
/// `MATROSKA_ID_TAGTARGETS_CHAPTERUID`. */
pub let matroska_id_tagtargets_chapteruid : UInt32 = 0x63C4

///|
/// `MATROSKA_ID_TAGTARGETS_ATTACHUID`. */
pub let matroska_id_tagtargets_attachuid : UInt32 = 0x63C6

///|
/// `MATROSKA_ID_TAGTARGETS_TYPE`. */
pub let matroska_id_tagtargets_type : UInt32 = 0x63CA

///|
/// `MATROSKA_ID_TAGTARGETS_TYPEVALUE`. */
pub let matroska_id_tagtargets_typevalue : UInt32 = 0x68CA

///|
/// `MATROSKA_ID_SIMPLETAG`. */
pub let matroska_id_simpletag : UInt32 = 0x67C8

///|
/// `MATROSKA_ID_TAGNAME`. */
pub let matroska_id_tagname : UInt32 = 0x45A3

///|
/// `MATROSKA_ID_TAGSTRING`. */
pub let matroska_id_tagstring : UInt32 = 0x4487

///|
/// `MATROSKA_ID_TAGLANG`. */
pub let matroska_id_taglang : UInt32 = 0x447A

///|
/// `MATROSKA_ID_TAGDEFAULT` / `MATROSKA_ID_TAGDEFAULT_BUG`. */
pub let matroska_id_tagdefault : UInt32 = 0x4484

///|
/// `MATROSKA_ID_SEEKHEAD`. */
pub let matroska_id_seekhead : UInt32 = 0x114D9B74

///|
/// `MATROSKA_ID_ATTACHMENTS`. */
pub let matroska_id_attachments : UInt32 = 0x1941A469

///|
/// `MATROSKA_ID_CHAPTERS`. */
pub let matroska_id_chapters : UInt32 = 0x1043A770

// ---------------------------------------------------------------------------
// Syntax rows (the EbmlType union of matroska.h + per-row sinks)
// ---------------------------------------------------------------------------

///|
/// One parsed scalar; the payload handed to a row's sink. */
pub enum EbmlValue {
  U(UInt64)
  I(Int64)
  F(Double)
  S(String)
  B(Bytes)
  /// A master element was walked; the payload is its start position.
  Master
}

///|
/// What to do with an element id, mirroring `EbmlSyntax.type`; the variant
/// payload is the C `def` default applied when the element is empty
/// (size 0).
pub enum EbmlKind {
  /// `EBML_NONE`: recognised but skipped.
  Skip
  Uint(UInt64)
  Sint(Int64)
  Float(Double)
  /// `EBML_STR`/`EBML_UTF8`; `None` default means "no default string".
  Str(String?)
  Bin
  /// `EBML_NEST`: a master element with the given child table thunk
  /// (C: a static array; a thunk breaks reference cycles).
  Nest(() -> Array[EbmlSyntax])
  /// `EBML_LEVEL1`: like `Nest`, but the element is also registered in
  /// the level-1 element table (dedup + seekhead bookkeeping).
  Level1(() -> Array[EbmlSyntax])
  /// `EBML_STOP`: parsing stops when this id is seen (the id stays in
  /// `current_id`, unread, exactly as in the C).
  Stop
}

///|
/// One syntax row: the C `EbmlSyntax { id, type, data_offset, def }` with
/// the offset write replaced by a `sink` closure over the parsed value
/// (and the element's own start position, what `EbmlBin.pos` carries).
pub struct EbmlSyntax {
  id : UInt32
  kind : EbmlKind
  sink : ((EbmlValue, Int64) -> Result[Unit, String])?
}

///|
/// `MatroskaLevel1Element`: one level-1 element seen (or seekhead-placed). */
pub struct MkvLevel1Elem {
  id : UInt32
  /// Absolute position (0 = not yet placed; the C's sentinel).
  mut pos : Int64
  mut parsed : Bool
}

///|
/// The parse-time state (the walker's slice of `MatroskaDemuxContext`). */
pub struct EbmlState {
  pb : AvioContext
  /// `matroska->levels[]`: (start, length) of each open master element.
  levels : Array[(Int64, UInt64)]
  /// `matroska->current_id`: an element id read but not yet consumed.
  mut current_id : UInt32
  /// `matroska->resync_pos`: last known good position.
  mut resync_pos : Int64
  /// `matroska->unknown_count`: consecutive unknown elements (non-seekable).
  mut unknown_count : Int32
  /// `matroska->is_live`: in live mode, EOF finishes parsing.
  mut is_live : Bool
  /// `matroska->level1_elems[]` (capacity 64 in the C).
  level1_elems : Array[MkvLevel1Elem]
  /// `matroska->segment_start`.
  mut segment_start : Int64
  /// `matroska->cues_parsing_deferred`: 1 deferred (default), 0 parsed,
  /// -1 broken.
  mut cues_parsing_deferred : Int32
}

///|
/// Fresh parse state over `pb`. */
pub fn EbmlState::new(pb : AvioContext) -> EbmlState {
  {
    pb,
    levels: [],
    current_id: 0,
    resync_pos: 0,
    unknown_count: 0,
    is_live: false,
    level1_elems: [],
    segment_start: 0,
    cues_parsing_deferred: 1,
  }
}

///|
/// Parse state in live mode: reaching EOF finishes parsing instead of
/// erroring (the `is_live` demuxer flag). */
pub fn EbmlState::new_live(pb : AvioContext) -> EbmlState {
  let st = EbmlState::new(pb)
  st.is_live = true
  st
}

// ---------------------------------------------------------------------------
// EBML primitives (matroskadec.c ebml_read_num .. matroska_ebmlnum_sint)
// ---------------------------------------------------------------------------

///|
/// `ebml_read_num`: read a variable-length EBML number — the first byte's
/// leading zero count gives the width; the marker bit is cleared and the
/// remaining bytes appended big-endian. Returns `(number, bytes_read)`.
pub fn ebml_read_num(
  pb : AvioContext,
  max_size : Int32,
  eof_forbidden : Bool,
) -> Result[(UInt64, Int32), String] {
  let total0 = pb.avio_r8()
  if pb.eof_reached {
    // the C err label: read error when present, else EOF vs EIO by flag
    if pb.err != None {
      return Err(pb.err.unwrap())
    }
    if eof_forbidden {
      return Err("EIO")
    }
    return Err("EOF")
  }
  // read = 8 - ff_log2_tab[first byte]
  let log2 = @libavutil.av_log2(total0)
  let read = 8 - log2
  if total0 == 0 || read > max_size {
    // 0x00 first byte, or a width beyond max_size
    return Err("EINVAL")
  }
  let mut total = total0.to_uint64() ^ (1UL << log2)
  let mut n = 1
  while n < read {
    n = n + 1
    total = (total << 8) | pb.avio_r8().to_uint64()
  }
  if pb.eof_reached {
    // eof mid-number is always fatal (`eof_forbidden = 1` in the C)
    if pb.err != None {
      return Err(pb.err.unwrap())
    }
    return Err("EIO")
  }
  Ok((total, read))
}

///|
/// `ebml_read_length`: an element length; every all-ones encoding of its
/// width maps to the unknown-length marker.
pub fn ebml_read_length(pb : AvioContext) -> Result[(UInt64, Int32), String] {
  match ebml_read_num(pb, 8, true) {
    Err(e) => Err(e)
    Ok((number, res)) => {
      let number = if number + 1UL == 1UL << (7 * res) {
        ebml_unknown_length
      } else {
        number
      }
      Ok((number, res))
    }
  }
}

///|
/// `ebml_read_uint`: big-endian unsigned of `size` bytes; `size` 0 applies
/// the default. Returns `true` for the C's NEEDS_CHECKING, `false` for the
/// plain success.
pub fn ebml_read_uint(
  pb : AvioContext,
  size : Int32,
  default_value : UInt64,
  num : (UInt64) -> Unit,
) -> Result[Bool, String] {
  if size == 0 {
    num(default_value)
    return Ok(false)
  }
  let mut v : UInt64 = 0
  let mut n = 0
  while n < size {
    n = n + 1
    v = (v << 8) | pb.avio_r8().to_uint64()
  }
  num(v)
  Ok(true)
}

///|
/// `ebml_read_sint`: big-endian signed — the first byte is sign-extended to
/// 64 bits and the rest appended in wrapping u64 arithmetic, exactly as the
/// C builds it.
pub fn ebml_read_sint(
  pb : AvioContext,
  size : Int32,
  default_value : Int64,
  num : (Int64) -> Unit,
) -> Result[Bool, String] {
  if size == 0 {
    num(default_value)
    return Ok(false)
  }
  let first = pb.avio_r8()
  // sign_extend(avio_r8(pb), 8): the byte's bit 7 fills the upper 56 bits
  let mut v : UInt64 = if (first & 0x80) != 0 {
    0xFFFFFFFFFFFFFFFFUL
  } else {
    0UL
  }
  v = (v << 8) | first.to_uint64()
  let mut n = 1
  while n < size {
    n = n + 1
    v = (v << 8) | pb.avio_r8().to_uint64()
  }
  num(v.reinterpret_as_int64())
  Ok(true)
}

///|
/// `ebml_read_float`: 4-byte (binary32) or 8-byte (binary64) big-endian
/// float; any other non-zero size is invalid.
pub fn ebml_read_float(
  pb : AvioContext,
  size : Int32,
  default_value : Double,
  num : (Double) -> Unit,
) -> Result[Bool, String] {
  if size == 0 {
    num(default_value)
    return Ok(false)
  }
  if size == 4 {
    num(f32_bits_to_double(pb.avio_rb32()))
    return Ok(true)
  }
  if size == 8 {
    num(f64_bits_to_double(pb.avio_rb64()))
    return Ok(true)
  }
  Err("EINVAL")
}

///|
/// `av_int2float` + widen: u32 bits read as binary32, widened to Double. */
fn f32_bits_to_double(bits : UInt32) -> Double {
  let sign : Double = if (bits & 0x80000000) != 0 { -1.0 } else { 1.0 }
  let exp = ((bits >> 23) & 0xFF).reinterpret_as_int()
  let mant = (bits & 0x7FFFFF).to_double()
  if exp == 0xFF {
    if mant != 0.0 {
      return @double.not_a_number
    }
    return sign * @double.infinity
  }
  if exp == 0 {
    // subnormal (or zero): mant / 2^23 * 2^-126
    return sign * mant * 1.401298464324817e-45
  }
  sign * (1.0 + mant / 8388608.0) * pow2_i(exp - 127)
}

///|
/// `av_int2double`: u64 bits read as binary64. */
fn f64_bits_to_double(bits : UInt64) -> Double {
  let sign : Double = if bits >> 63 != 0UL { -1.0 } else { 1.0 }
  let exp = ((bits >> 52) & 0x7FFUL).reinterpret_as_int64().to_int()
  let mant = (bits & 0xFFFFFFFFFFFFFUL).to_double()
  if exp == 0x7FF {
    if mant != 0.0 {
      return @double.not_a_number
    }
    return sign * @double.infinity
  }
  if exp == 0 {
    return sign * mant * pow2_i(-1074)
  }
  sign * (1.0 + mant / 4503599627370496.0) * pow2_i(exp - 1023)
}

///|
/// 2^n by squaring for the float reconstructions (n in [-1074, 1023]). */
fn pow2_i(n : Int32) -> Double {
  if n >= 0 {
    let mut r = 1.0
    let mut b = 2.0
    let mut e = n
    while e > 0 {
      if (e & 1) == 1 {
        r = r * b
      }
      b = b * b
      e = e >> 1
    }
    r
  } else {
    1.0 / pow2_i(-n)
  }
}

///|
/// `ebml_read_ascii`: `size` bytes as a string (EBML strings are not
/// NUL-terminated; the C allocates one byte more). Returns
/// `(string, needs_checking)`; `None` string marks a short read, where the
/// C leaves the destination untouched and defers to the EOF check.
pub fn ebml_read_ascii(
  pb : AvioContext,
  size : Int32,
  default_value : String?,
) -> Result[(String?, Bool), String] {
  if size == 0 && default_value is Some(_) {
    return Ok((default_value, false))
  }
  match pb.avio_read(size) {
    Err(e) => Err(e)
    Ok(bytes) => {
      if bytes.length() != size {
        return Ok((None, true))
      }
      Ok((Some(mkv_utf8_to_string_bytes(bytes)), false))
    }
  }
}

///|
/// Bytes → MoonBit string, lenient UTF-8 (U+FFFD on malformed input). */
fn mkv_utf8_to_string_bytes(data : Bytes) -> String {
  let chars : Array[Char] = []
  let mut i = 0
  while i < data.length() {
    let b0 = data[i].to_int()
    let mut cp : Int32 = 0xFFFD
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
      let v = cp - 0x10000
      chars.push((0xD800 + (v >> 10)).unsafe_to_char())
      chars.push((0xDC00 + (v & 0x3FF)).unsafe_to_char())
    }
    i = i + 1 + extra
  }
  String::from_array(chars[:])
}

///|
/// `ebml_read_binary`: `length` payload bytes plus their absolute position
/// (the C stores `EbmlBin { data, size, pos }`; the position is `pos_alt`,
/// right after the element header).
pub fn ebml_read_binary(
  pb : AvioContext,
  length : Int32,
  pos : Int64,
) -> Result[(Bytes?, Int64), String] {
  match pb.avio_read(length) {
    Err(e) => Err(e)
    Ok(bytes) => {
      if bytes.length() != length {
        // short read: destination stays unset, NEEDS_CHECKING
        return Ok((None, pos))
      }
      Ok((Some(bytes), pos))
    }
  }
}

///|
/// `ebml_read_master`: push a level for a master of `length` starting at
/// `pos`; beyond `EBML_MAX_DEPTH` it is `ENOSYS`.
pub fn ebml_read_master(
  st : EbmlState,
  length : UInt64,
  pos : Int64,
) -> Result[Unit, String] {
  if st.levels.length() >= ebml_max_depth {
    return Err("ENOSYS")
  }
  st.levels.push((pos, length))
  Ok(())
}

///|
/// `matroska_ebmlnum_sint`: a signed EBML number as used by laced block
/// sizes — read unsigned, then rebias by the width's marker value.
pub fn matroska_ebmlnum_sint(
  pb : AvioContext,
) -> Result[(Int64, Int32), String] {
  match ebml_read_num(pb, 8, true) {
    Err(e) => Err(e)
    Ok((unum, res)) => {
      let bias = (1L << (7 * res - 1)) - 1L
      Ok((unum.reinterpret_as_int64() - bias, res))
    }
  }
}

///|
/// `is_ebml_id_valid`: the marker-bit position must agree with the id's
/// byte length — `av_log2(id)` bits imply `(bits + 7) / 8` bytes and the
/// leading length bit must sit exactly at `8 - bits % 8`.
pub fn is_ebml_id_valid(id : UInt32) -> Bool {
  if id == 0 {
    return false
  }
  let bits = @libavutil.av_log2(id)
  (bits + 7) / 8 == 8 - bits % 8
}

// ---------------------------------------------------------------------------
// The generic walker (matroskadec.c ebml_parse / ebml_parse_nest)
// ---------------------------------------------------------------------------

///|
/// `ebml_parse_id`: the row for `id`, or `None` (the C's sentinel row). */
fn ebml_find_syntax(syntax : Array[EbmlSyntax], id : UInt32) -> EbmlSyntax? {
  for i = 0; i < syntax.length(); i = i + 1 {
    if syntax[i].id == id {
      return Some(syntax[i])
    }
  }
  None
}

///|
/// length (u64) as Int64 payload size (values are < 2^63 in any sane file;
/// the C's implicit uint64->int64 conversion).
fn i64_of_len(length : UInt64) -> Int64 {
  (length & 0x7FFFFFFFFFFFFFFFUL).reinterpret_as_int64()
}

///|
/// `matroska_find_level1_elem`: the registry entry for a level-1 element —
/// reused when the id matches (SeekHead/Tags also match on position),
/// newly allocated otherwise. Cluster and malformed ids never register.
fn matroska_find_level1_elem(
  st : EbmlState,
  id : UInt32,
  pos : Int64,
) -> MkvLevel1Elem? {
  if is_ebml_id_valid(id) == false {
    return None
  }
  if id == matroska_id_cluster {
    return None
  }
  for i = 0; i < st.level1_elems.length(); i = i + 1 {
    if st.level1_elems[i].id == id {
      if st.level1_elems[i].pos == pos ||
        (id != matroska_id_seekhead && id != matroska_id_tags) {
        return Some(st.level1_elems[i])
      }
    }
  }
  if st.level1_elems.length() >= 64 {
    return None // "Too many level1 elements"
  }
  let elem : MkvLevel1Elem = { id, pos: 0, parsed: false, }
  st.level1_elems.push(elem)
  Some(elem)
}

///|
/// The per-type length maximums of `ebml_parse` (`max_lengths[]`). */
fn ebml_max_length(kind : EbmlKind) -> UInt64 {
  match kind {
    Skip => ebml_unknown_length - 1UL // forbid unknown-length EBML_NONE
    Uint(_) => 8UL
    Sint(_) => 8UL
    Float(_) => 8UL
    Str(_) => 0x1000000UL // max. 16 MB for strings
    Bin => 0x10000000UL // max. 256 MB for binary data
    _ => 0UL // no limit for masters / stop
  }
}

///|

///|
/// The EBML_NEST/EBML_LEVEL1 arm of `ebml_parse`: push the level, run the
/// segment/cues bookkeeping, register level-1 elements and walk children.
fn walk_master(
  st : EbmlState,
  r : EbmlSyntax,
  id : UInt32,
  pos : Int64,
  pos_alt : Int64,
  length : UInt64,
  children : () -> Array[EbmlSyntax],
  ancestors : Array[Array[EbmlSyntax]],
  syntax : Array[EbmlSyntax],
  level1 : Bool,
) -> Result[Int32, String] {
  match ebml_read_master(st, length, pos_alt) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if id == matroska_id_segment {
    st.segment_start = pos_alt
  }
  if id == matroska_id_cues {
    st.cues_parsing_deferred = 0
  }
  if level1 {
    match matroska_find_level1_elem(st, id, pos) {
      Some(elem) => {
        if elem.pos == 0 {
          // Zero is not a valid position for a level 1 element.
          elem.pos = pos
        }
        elem.parsed = true
      }
      None => ()
    }
  }
  if length == 0UL {
    // an empty master completes immediately (ebml_parse_nest's
    // zero-length shortcut pops the level and returns)
    let _ = st.levels.pop()
    match deliver(r, Some(EbmlValue::Master), pos_alt) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    return Ok(0)
  }
  ancestors.push(syntax)
  let nested = ebml_parse_nest(st, children(), ancestors)
  let _ = ancestors.pop()
  match nested {
    Err(e) => Err(e)
    Ok(v) => {
      match deliver(r, Some(EbmlValue::Master), pos_alt) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      Ok(v)
    }
  }
}

///|
/// `ebml_parse`: read one element, dispatch it against `syntax` and return
/// the C result code — 0 ok, 1 stop, `LEVEL_ENDED` when the current master
/// completed. `ancestors` carries the enclosing syntax tables, outermost
/// first (the C's `CHILD_OF` sentinel chain), for the unknown-length master
/// termination check.
pub fn ebml_parse(
  st : EbmlState,
  syntax : Array[EbmlSyntax],
  ancestors : Array[Array[EbmlSyntax]],
) -> Result[Int32, String] {
  let pb = st.pb
  let mut pos = pb.avio_tell()
  let mut update_pos = true
  let mut pos_alt : Int64 = 0
  if st.current_id == 0 {
    match ebml_read_num(pb, 4, false) {
      Err(e) => {
        if e == "EOF" && pb.eof_reached {
          if st.is_live {
            // in live mode, finish parsing if EOF is reached
            return Ok(1)
          }
          if st.levels.length() > 0 && pos == pb.avio_tell() {
            if st.levels[st.levels.length() - 1].1 == ebml_unknown_length {
              // Unknown-length levels automatically end at EOF.
              let _ = st.levels.pop()
              return Ok(level_ended)
            }
          }
        }
        return Err(e)
      }
      Ok((id64, res)) => {
        st.current_id = ((id64 | (1UL << (7 * res))) & 0xFFFFFFFFUL)
          .to_int()
          .reinterpret_as_uint()
        pos_alt = pos + res.to_int64()
      }
    }
  } else {
    pos_alt = pos
    // pos -= (av_log2(current_id) + 7) / 8: back over the id bytes, so the
    // resync position is the element's true start
    pos = pos - ((@libavutil.av_log2(st.current_id) + 7) / 8).to_int64()
  }
  let id = st.current_id
  let mut row : EbmlSyntax? = ebml_find_syntax(syntax, id)
  if row is None && id != ebml_id_void && id != ebml_id_crc32 {
    // Unknown-length levels end when an element belonging to an upper
    // level of the hierarchy appears (the C's def.n chain walk).
    if st.levels.length() > 0 &&
      st.levels[st.levels.length() - 1].1 == ebml_unknown_length {
      let mut ai = ancestors.length()
      while ai > 0 {
        ai = ai - 1
        if ebml_find_syntax(ancestors[ai], id) is Some(_) {
          let _ = st.levels.pop()
          return Ok(level_ended)
        }
      }
    }
    // Unknown entry: do not treat its start as a resync point.
    update_pos = false
  }
  if row is None {
    row = Some({ id, kind: Skip, sink: None, })
  }
  let r = row.unwrap()
  if r.kind is Stop {
    return Ok(1)
  }
  st.current_id = 0
  let (length, lenres) = match ebml_read_length(pb) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  pos_alt = pos_alt + lenres.to_int64()
  // Does the element fit into the open master? (level_check)
  let mut level_check = 0
  if st.levels.length() > 0 {
    let lvl = st.levels[st.levels.length() - 1]
    if length != ebml_unknown_length && lvl.1 != ebml_unknown_length {
      let elem_end = pos_alt + i64_of_len(length)
      let level_end = lvl.0 + lvl.1.reinterpret_as_int64()
      if elem_end == level_end {
        level_check = level_ended
      } else if elem_end > level_end {
        // element exceeds the containing master element
        return Err("EINVAL")
      }
    } else if length == ebml_unknown_length && lvl.1 != ebml_unknown_length {
      // unknown-sized element inside a parent with finite size
      return Err("EINVAL")
    } else if length == ebml_unknown_length &&
      lvl.1 == ebml_unknown_length &&
      id != matroska_id_cluster &&
      r.kind is Nest(_) {
      // Only clusters and segments are unknown-length per the spec; other
      // unknown-length masters are accepted but are no resync point.
      update_pos = false
    }
  }
  let maxlen = ebml_max_length(r.kind)
  if maxlen != 0UL && length > maxlen {
    return Err("EINVAL")
  }
  if pb.seekable == false {
    // The non-seekable heuristic against damaged data (SKIP_THRESHOLD).
    if update_pos {
      st.unknown_count = 0
    } else {
      let mut dist = i64_of_len(length) +
        unknown_equiv * st.unknown_count.to_int64()
      st.unknown_count = st.unknown_count + 1
      if st.unknown_count > 3 {
        dist = dist + pos_alt - st.resync_pos
      }
      if dist > skip_threshold {
        return Err("EINVAL")
      }
    }
  }
  if update_pos {
    // an element that is allowed here and passed all checks: its start is
    // the "last known good" position
    st.resync_pos = pos
  }
  // Read the payload. Value None = not delivered (short read); nc marks the
  // C's NEEDS_CHECKING which defers to the EOF check below.
  let mut value : EbmlValue? = None
  let mut nc = false
  match r.kind {
    Skip =>
      if length != 0UL {
        match pb.avio_skip(i64_of_len(length) - 1L) {
          Err(e) => return Err(e)
          Ok(_) => {
            // skipping length-1 then one byte checks that the element was
            // properly skipped even without a file size
            let _ = pb.avio_r8()
            nc = true
          }
        }
      }
    Uint(def) => {
      let mut got : UInt64 = 0
      let rc = ebml_read_uint(pb, i64_of_len(length).to_int(), def, v => got = v)
      match rc {
        Err(e) => return Err(e)
        Ok(v) => {
          value = Some(EbmlValue::U(got))
          nc = v
        }
      }
    }
    Sint(def) => {
      let mut got : Int64 = 0
      let rc = ebml_read_sint(pb, i64_of_len(length).to_int(), def, v => got = v)
      match rc {
        Err(e) => return Err(e)
        Ok(v) => {
          value = Some(EbmlValue::I(got))
          nc = v
        }
      }
    }
    Float(def) => {
      let mut got = 0.0
      let rc = ebml_read_float(pb, i64_of_len(length).to_int(), def, v => {
        got = v
      })
      match rc {
        Err(e) => return Err(e)
        Ok(v) => {
          value = Some(EbmlValue::F(got))
          nc = v
        }
      }
    }
    Str(def) =>
      match ebml_read_ascii(pb, i64_of_len(length).to_int(), def) {
        Err(e) => return Err(e)
        Ok((s, v)) => {
          if s is Some(str) {
            value = Some(EbmlValue::S(str))
          }
          nc = v
        }
      }
    Bin =>
      match ebml_read_binary(pb, i64_of_len(length).to_int(), pos_alt) {
        Err(e) => return Err(e)
        Ok((b, p)) => {
          if b is Some(bytes) {
            value = Some(EbmlValue::B(bytes))
          } else {
            ignore(p)
          }
          nc = true
        }
      }
    Nest(children) =>
      return walk_master(
        st, r, id, pos, pos_alt, length, children, ancestors, syntax, false,
      )
    Level1(children) =>
      return walk_master(
        st, r, id, pos, pos_alt, length, children, ancestors, syntax, true,
      )
    Stop => return Ok(1)
  }
  // The common tail: NEEDS_CHECKING defers to the EOF check, then the
  // level check; the value is already delivered (the C wrote it in place).
  match deliver(r, value, pos_alt) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if nc {
    if pb.eof_reached {
      if pb.err != None {
        return Err(pb.err.unwrap())
      }
      // "File ended prematurely": EOF maps to EIO here
      return Err("EIO")
    }
  } else {
    nc = false
  }
  if level_check == level_ended && st.levels.length() > 0 {
    let mut pos_now = pb.avio_tell()
    // Pop every level that ends exactly here (unknown-length levels can
    // never match: start + UNKNOWN_LENGTH wraps past any position).
    while st.levels.length() > 0 {
      let lvl = st.levels[st.levels.length() - 1]
      let end = (lvl.0.reinterpret_as_uint64() + lvl.1).reinterpret_as_int64()
      if pos_now == end {
        let _ = st.levels.pop()
        pos_now = pb.avio_tell()
      } else {
        break
      }
    }
  }
  Ok(level_check)
}

///|
/// Run a row's sink (the C's in-place write through `data + offset`). */
fn deliver(
  r : EbmlSyntax,
  value : EbmlValue?,
  pos : Int64,
) -> Result[Unit, String] {
  match (r.sink, value) {
    (Some(f), Some(v)) => f(v, pos)
    _ => Ok(())
  }
}

///|
/// `ebml_parse_nest`: loop `ebml_parse` until the level ends or a stop is
/// hit; `LEVEL_ENDED` normalises to 0 (the master completed cleanly). The
/// C's default-value pre-pass lives in the table factories: defaults are
/// applied by the caller that builds the destination struct.
pub fn ebml_parse_nest(
  st : EbmlState,
  syntax : Array[EbmlSyntax],
  ancestors : Array[Array[EbmlSyntax]],
) -> Result[Int32, String] {
  let mut res = 0
  let mut go = true
  while go {
    res = match ebml_parse(st, syntax, ancestors) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    go = res == 0
  }
  if res == level_ended {
    return Ok(0)
  }
  Ok(res)
}
