///|
/// MoonBit port of the MP4/MOV demuxer core of FFmpeg 9.0.2
/// (`libavformat/mov.c`), scoped to container parsing and sample-table
/// extraction.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope of this slice (see `README.md` for the roadmap):
///   * parsed: box traversal, `ftyp`, `moov`/`mvhd`, `trak`/`tkhd`, `mdia`/
///     `mdhd`, `hdlr`, `edts`/`elst`, `stbl`/`stsd`, `stts`, `ctts`, `stsc`,
///     `stsz`/`stz2`, `stco`/`co64`, `stss`/`stps`, and the
///     `mov_merge_tts_data` + `mov_build_index` sample-index construction.
///   * per sample: file offset, size, DTS, duration, presentation timestamp,
///     keyframe and `min_distance` flags -- mirroring what FFmpeg stores in
///     `AVIndexEntry` and later reports in `AVPacket`.
///   * not ported: AVIO/AVPacket/AVFormatContext plumbing (this parser works on
///     an in-memory buffer the caller has already read), fragmented MP4
///     (`moof`/`trun`), encryption (`cenc`), seeking, the chunked
///     "old uncompressed audio" index path, `rap_group` (sgpd/sbgp),
///     codec-specific extradata (`avcC`, `esds`, ...) and `advanced_editlist`.
///   * simplifications: per-sample timestamps are materialised up front instead
///     of being consulted lazily, the `free`/`hoov`-hiding-`moov` recovery is
///     omitted, and corrupt-count guards are tightened relative to the C code.

///| Parse failure, corresponding to the negative returns in libavformat/mov.c. */
pub suberror MovError {
  InvalidData(String)
}

// ---------------------------------------------------------------------------
// Data model (mirrors the MOV structs in libavformat/isom.h)
// ---------------------------------------------------------------------------

///| `MOVStts` from libavformat/isom.h. */
pub struct MovStts {
  count : Int
  duration : UInt
}

///| `MOVCtts` from libavformat/isom.h. */
pub struct MovCtts {
  count : Int
  offset : Int
}

///| `MOVStsc` from libavformat/isom.h. */
pub struct MovStsc {
  first : Int
  count : Int
  id : Int
}

///| `MOVElst` from libavformat/isom.h. */
pub struct MovElst {
  duration : Int64
  time : Int64
  rate : Double
}

///|
/// `MOVTimeToSample` from libavformat/mov.c: the per-sample table produced by
/// merging `stts` and `ctts`, where `offset` is the CTTS presentation offset and
/// `duration` the STTS sample duration.
pub struct MovTts {
  count : Int
  offset : Int
  duration : UInt
}

///|
/// One entry of the sample index, corresponding to FFmpeg's `AVIndexEntry`
/// (`pos`, `timestamp`, `size`, `min_distance`, `flags`) plus the presentation
/// timestamp that `mov_finalize_packet` derives from it.
pub struct Mp4Sample {
  offset : Int64
  size : UInt
  dts : Int64
  pts : Int64
  duration : UInt
  keyframe : Bool
  min_distance : UInt
}

///| Media type derived from the `hdlr` handler type (AVMediaType subset). */
pub enum Mp4MediaType {
  Video
  Audio
  Subtitle
  Unknown
}

///| True for video tracks, avoiding a structural `Eq` on `Mp4MediaType`. */
fn media_is_video(t : Mp4MediaType) -> Bool {
  match t {
    Video => true
    _ => false
  }
}

///| True for audio tracks. */
fn media_is_audio(t : Mp4MediaType) -> Bool {
  match t {
    Audio => true
    _ => false
  }
}

///|
/// Per-track state, corresponding to `MOVStreamContext` plus the stream fields
/// of `AVStream` that this slice needs.
///
/// The array-valued fields are only ever mutated in place (`push`/element
/// assignment), so they carry no `mut` marker.
pub struct Mp4Track {
  mut track_id : UInt
  mut handler : String
  mut media_type : Mp4MediaType
  mut codec : String
  mut timescale : UInt
  mut duration : UInt64
  mut width : Int
  mut height : Int
  mut sample_rate : UInt
  mut channels : UInt
  mut bits_per_sample : UInt
  mut encoder : String
  stts : Array[MovStts]
  ctts : Array[MovCtts]
  stsc : Array[MovStsc]
  mut stsz_sample_size : UInt
  mut sample_size : UInt
  sample_sizes : Array[UInt]
  mut sample_count : Int
  chunk_offsets : Array[Int64]
  keyframes : Array[UInt]
  stps : Array[UInt]
  mut keyframe_absent : Bool
  elst : Array[MovElst]
  mut stsd_version : UInt
  mut dts_shift : Int
  mut time_offset : Int64
  mut tts : Array[MovTts]
  mut has_stts : Bool
  mut has_ctts : Bool
  mut unsupported_audio_chunk_demux : Bool
  samples : Array[Mp4Sample]
}

///| Movie-level state, corresponding to the `MOVContext`/`AVFormatContext` fields used here. */
pub struct Mp4Movie {
  mut timescale : UInt
  mut duration : UInt64
  mut isom : Bool
  mut major_brand : String
  tracks : Array[Mp4Track]
}

fn new_track() -> Mp4Track {
  {
    track_id: 0,
    handler: "",
    media_type: Mp4MediaType::Unknown,
    codec: "",
    timescale: 0,
    duration: 0,
    width: 0,
    height: 0,
    sample_rate: 0,
    channels: 0,
    bits_per_sample: 0,
    encoder: "",
    stts: [],
    ctts: [],
    stsc: [],
    stsz_sample_size: 0,
    sample_size: 0,
    sample_sizes: [],
    sample_count: 0,
    chunk_offsets: [],
    keyframes: [],
    stps: [],
    keyframe_absent: false,
    elst: [],
    stsd_version: 0,
    dts_shift: 0,
    time_offset: 0,
    tts: [],
    has_stts: false,
    has_ctts: false,
    unsupported_audio_chunk_demux: false,
    samples: [],
  }
}

fn new_movie() -> Mp4Movie {
  { timescale: 0, duration: 0, isom: false, major_brand: "", tracks: [] }
}

///| `max_stts_delta` default from the mov demuxer options: `UINT_MAX - 48000*10`. */
let max_stts_delta : UInt = 4294487295

///| `UINT32_MAX`, used as mdhd's "unknown duration" marker in version 0. */
let u32_max_u64 : UInt64 = 0xFFFFFFFF

///| `UINT64_MAX`, the version 1 "unknown duration" marker. */
let u64_max : UInt64 = 0xFFFFFFFFFFFFFFFF

///| `INT64_MAX`, used as the "no next chunk" sentinel in `mov_build_index`. */
let i64_max : Int64 = 0x7FFFFFFFFFFFFFFF

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

///|
/// `av_clip64(x, -INT64_MAX, INT64_MAX)`: note the lower bound is
/// `-INT64_MAX`, not `INT64_MIN`, exactly as in `mov_build_index`.
fn mov_clip64(x : Int64) -> Int64 {
  if x > i64_max {
    i64_max
  } else if x < -i64_max {
    -i64_max
  } else {
    x
  }
}

///| `mov_stsc_index_valid`: `index < count - 1` (with the C unsigned wraparound). */
fn mov_stsc_index_valid(index : Int, count : Int) -> Bool {
  index < count - 1
}

///| 4CC equal to four characters, mirroring `MKTAG('a','b','c','d')`. */
fn tag(a : Char, b : Char, c : Char, d : Char) -> String {
  let chars : Array[Char] = [a, b, c, d]
  String::from_array(chars[:])
}

///| Saturating 64-bit addition (`av_sat_add64`). */
fn sat_add64(a : Int64, b : Int64) -> Int64 {
  if (a >= 0) == (b >= 0) {
    let r = a + b
    if (r >= 0) != (a >= 0) {
      if a >= 0 {
        i64_max
      } else {
        -9223372036854775808
      }
    } else {
      r
    }
  } else {
    a + b
  }
}

///| `av_rescale` for the edit-list conversion, delegating to the libavutil port. */
fn mov_rescale(a : Int64, b : UInt, c : UInt) -> Int64 {
  @libavutil.av_rescale(a, b.to_int64(), c.to_int64())
}

// ---------------------------------------------------------------------------
// Parser state and box traversal
// ---------------------------------------------------------------------------

priv struct MovState {
  movie : Mp4Movie
  mut cur : Mp4Track
  mut in_trak : Bool
}

///|
/// Dispatch one box to its parser, mirroring the `mov_default_parse_table`
/// lookup in `mov_read_default`. Unknown boxes are skipped, like the C
/// fall-through that skips unregistered leaf atoms.
fn parse_box(st : MovState, r : Mp4Reader, kind : String, size : Int64) -> Unit raise MovError {
  if kind == "trak" {
    parse_trak(st, r, size)
  } else if kind == "moov" || kind == "mdia" || kind == "minf" || kind == "stbl" || kind == "edts" {
    // Container boxes: recurse, as mov_read_moov/mdia/minf/stbl/edts do.
    parse_default(st, r, size)
  } else if kind == "ftyp" {
    parse_ftyp(st, r)
  } else if kind == "mvhd" {
    parse_mvhd(st, r)
  } else if kind == "tkhd" {
    parse_tkhd(st, r)
  } else if kind == "mdhd" {
    parse_mdhd(st, r)
  } else if kind == "hdlr" {
    parse_hdlr(st, r)
  } else if kind == "elst" {
    parse_elst(st, r, size)
  } else if kind == "stsd" {
    parse_stsd(st, r, size)
  } else if kind == "stts" {
    parse_stts(st, r, size)
  } else if kind == "ctts" {
    parse_ctts(st, r, size)
  } else if kind == "stsc" {
    parse_stsc(st, r, size)
  } else if kind == "stsz" {
    parse_stsz(st, r, size, false)
  } else if kind == "stz2" {
    parse_stsz(st, r, size, true)
  } else if kind == "stco" {
    parse_stco(st, r, size, false)
  } else if kind == "co64" {
    parse_stco(st, r, size, true)
  } else if kind == "stss" {
    parse_stss(st, r)
  } else if kind == "stps" {
    parse_stps(st, r)
  } else {
    r.skip(size)
  }
}

///|
/// Walk the child boxes of a container whose payload is `parent_size` bytes.
/// Corresponds to `mov_read_default`.
///
/// `consumed` tracks the position within the parent, so the loop mirrors the
/// intent of the C `while (total_size <= atom.size - 8)` guard while also
/// terminating on the actual byte budget. The `trak`/`mdat`-outside-`moov`
/// diagnostic and the non-seekable early return are omitted.
fn parse_default(st : MovState, r : Mp4Reader, parent_size : Int64) -> Unit raise MovError {
  let mut consumed : Int64 = 0
  while consumed <= parent_size - 8 {
    let box_start = r.position().to_int64()
    let size32 = r.read_u32().to_int64()
    let kind = r.read_fourcc()
    if r.eof_reached() {
      break
    }
    let mut header : Int64 = 8
    let mut size = size32
    if size32 == 1 {
      // 64-bit extended size: `avio_rb64(pb) - 8` on top of the 8 bytes read.
      size = r.read_u64().reinterpret_as_int64()
      header = 16
    } else if size32 == 0 {
      // The box extends to the end of its parent.
      size = parent_size - consumed
    }
    // `a.size -= 8` in the C code: the payload excludes the whole header.
    let mut payload = size - header
    if payload < 0 {
      break
    }
    // `a.size = FFMIN(a.size, atom.size - total_size)`
    let avail = parent_size - consumed - header
    if payload > avail {
      payload = avail
    }
    if payload < 0 {
      break
    }
    parse_box(st, r, kind, payload)
    // Consume whatever the parser left behind, or rewind if it overread.
    let left = payload - (r.position().to_int64() - box_start - header)
    if left > 0 {
      r.skip(left)
    } else if left < 0 {
      r.skip(left)
    }
    consumed = consumed + header + payload
  }
}

// ---------------------------------------------------------------------------
// Individual box parsers
// ---------------------------------------------------------------------------

///| `mov_read_ftyp`: the major brand decides whether the file is treated as ISO BMFF. */
fn parse_ftyp(st : MovState, r : Mp4Reader) -> Unit {
  let major = r.read_fourcc()
  let _ = r.read_u32() // minor version
  st.movie.major_brand = major
  if major != tag('q', 't', ' ', ' ') {
    st.movie.isom = true
  }
}

///| `mov_read_mvhd`. */
fn parse_mvhd(st : MovState, r : Mp4Reader) -> Unit {
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  // creation and modification times (mov_metadata_creation_time)
  if version == 1 {
    r.skip(16)
  } else {
    r.skip(8)
  }
  let raw_ts = r.read_u32()
  st.movie.timescale = if raw_ts.reinterpret_as_int() <= 0 { 1 } else { raw_ts }
  st.movie.duration = if version == 1 {
    r.read_u64()
  } else {
    r.read_u32().to_uint64()
  }
}

///| `mov_read_mdhd`. */
fn parse_mdhd(st : MovState, r : Mp4Reader) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  if st.cur.timescale != 0 {
    raise InvalidData("multiple mdhd")
  }
  let version = r.read_u8()
  if version > 1 {
    raise InvalidData("unsupported mdhd version")
  }
  let _ = r.read_u24() // flags
  if version == 1 {
    r.skip(16)
  } else {
    r.skip(8)
  }
  let raw_ts = r.read_u32()
  if raw_ts.reinterpret_as_int() <= 0 {
    raise InvalidData("invalid mdhd time scale")
  }
  st.cur.timescale = raw_ts
  let dur = if version == 1 {
    r.read_u64()
  } else {
    r.read_u32().to_uint64()
  }
  let unknown = if version == 1 { u64_max } else { u32_max_u64 }
  st.cur.duration = if dur == unknown { 0 } else { dur }
  let _ = r.read_u16() // language
  let _ = r.read_u16() // quality
}

///| `mov_read_tkhd`. */
fn parse_tkhd(st : MovState, r : Mp4Reader) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  // Each trak has exactly one tkhd; `st->id` starts at -1 in mov_read_trak.
  if st.cur.track_id != 0 {
    raise InvalidData("duplicate tkhd")
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  if version == 1 {
    r.skip(16)
  } else {
    r.skip(8)
  }
  st.cur.track_id = r.read_u32()
  let _ = r.read_u32() // reserved
  if version == 1 {
    r.skip(8)
  } else {
    r.skip(4)
  }
  r.skip(8) // two reserved dwords
  r.skip(8) // layer, alternate group, volume, reserved
  r.skip(36) // 3x3 display matrix (16.16 / 2.30 fixed point)
  let width = r.read_u32()
  let height = r.read_u32()
  st.cur.width = width.reinterpret_as_int() >> 16
  st.cur.height = height.reinterpret_as_int() >> 16
}

///| `mov_read_hdlr`. */
fn parse_hdlr(st : MovState, r : Mp4Reader) -> Unit {
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let _ = r.read_fourcc() // component type ('mhlr'/'dhlr')
  let kind = r.read_fourcc() // component subtype
  if !st.in_trak {
    return
  }
  st.cur.handler = kind
  st.cur.media_type = if kind == tag('v', 'i', 'd', 'e') {
    Mp4MediaType::Video
  } else if kind == tag('s', 'o', 'u', 'n') {
    Mp4MediaType::Audio
  } else if kind == tag('s', 'u', 'b', 'p') || kind == tag('c', 'l', 'c', 'p') {
    Mp4MediaType::Subtitle
  } else {
    Mp4MediaType::Unknown
  }
}

///| `mov_read_elst`. */
fn parse_elst(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  let entry_size : Int64 = if version == 1 { 20 } else { 12 }
  let mut remaining = size - 8
  let declared = r.read_u32().reinterpret_as_int()
  let mut edit_count = declared
  if remaining != declared.to_int64() * entry_size {
    // Non-strict compliance: derive the entry count from the atom size.
    edit_count = (remaining / entry_size).to_int()
  }
  for i = 0; i < edit_count; i = i + 1 {
    if remaining <= 0 || r.eof_reached() {
      break
    }
    let duration : Int64 = if version == 1 {
      r.read_i64()
    } else {
      r.read_u32().to_int64()
    }
    let time : Int64 = if version == 1 {
      r.read_i64()
    } else {
      r.read_u32().reinterpret_as_int().to_int64()
    }
    remaining = remaining - (if version == 1 { 16 } else { 8 })
    let rate = r.read_u32().to_double() / 65536.0
    remaining = remaining - 4
    if duration < 0 {
      raise InvalidData("invalid edit list duration")
    }
    st.cur.elst.push({ duration, time, rate })
  }
}

///|
/// `mov_read_stsd`, embedding the sample-entry layouts of
/// `mov_parse_stsd_video` and `mov_parse_stsd_audio`.
fn parse_stsd(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries <= 0 || entries.to_int64() > size / 8 || entries > 1024 {
    raise InvalidData("invalid STSD entries")
  }
  st.cur.stsd_version = version
  // Only the primary sample description is modelled; the rest are skipped the
  // way `mov_skip_multiple_stsd` skips non-primary entries.
  let entry_start = r.position().to_int64()
  let entry_size = r.read_u32().to_int64()
  let format = r.read_fourcc()
  if entry_size >= 16 {
    let _ = r.read_u32() // reserved
    let _ = r.read_u16() // reserved
    let _ = r.read_u16() // dref_id
  } else if entry_size <= 7 {
    raise InvalidData("invalid size in stsd")
  }
  st.cur.codec = format
  if media_is_video(st.cur.media_type) {
    parse_stsd_video(st, r)
  } else if media_is_audio(st.cur.media_type) {
    parse_stsd_audio(st, r)
  }
  // Skip the remainder of this entry (avcC/esds/wave/... extradata).
  let used = r.position().to_int64() - entry_start
  if entry_size > used {
    r.skip(entry_size - used)
  }
  for i = 1; i < entries; i = i + 1 {
    let s = r.read_u32().to_int64()
    if s < 8 {
      break
    }
    r.skip(s - 4)
  }
}

///| `mov_parse_stsd_video`: VisualSampleEntry fields (the 16 header bytes are already read). */
fn parse_stsd_video(st : MovState, r : Mp4Reader) -> Unit {
  if st.movie.isom {
    r.skip(4) // pre_defined
    r.skip(12) // pre_defined
  } else {
    let _ = r.read_u16() // version
    let _ = r.read_u16() // revision level
    let _ = r.read_le32() // vendor
    let _ = r.read_u32() // temporal quality
    let _ = r.read_u32() // spatial quality
  }
  st.cur.width = r.read_u16().reinterpret_as_int()
  st.cur.height = r.read_u16().reinterpret_as_int()
  let _ = r.read_u32() // horiz resolution
  let _ = r.read_u32() // vert resolution
  let _ = r.read_u32() // data size, always 0
  let _ = r.read_u16() // frames per sample
  let mut len = r.read_u8().reinterpret_as_int()
  if len > 31 {
    len = 31
  }
  let chars : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    chars.push(r.read_u8().to_byte().to_char())
  }
  st.cur.encoder = String::from_array(chars[:])
  if len < 31 {
    r.skip((31 - len).to_int64())
  }
  st.cur.bits_per_sample = r.read_u16()
}

///| `mov_parse_stsd_audio`: AudioSampleEntry fields (the 16 header bytes are already read). */
fn parse_stsd_audio(st : MovState, r : Mp4Reader) -> Unit {
  let _ = r.read_u16() // version
  if st.movie.isom {
    r.skip(6) // reserved
  } else {
    let _ = r.read_u16() // revision level
    let _ = r.read_le32() // vendor
  }
  st.cur.channels = r.read_u16()
  st.cur.bits_per_sample = r.read_u16()
  let _ = r.read_u16() // compression id
  let _ = r.read_u16() // packet size
  st.cur.sample_rate = r.read_u32() >> 16
}

///| `mov_read_stts`, including the `max_stts_delta` clipping and DTS drift correction. */
fn parse_stts(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  // Corrupt counts are rejected up front; the C code relies on allocation
  // failure instead.
  if entries < 0 || entries.to_int64() * 8 > size - 8 {
    raise InvalidData("invalid STTS entries")
  }
  let mut corrected_dts : Int64 = 0
  let mut current_dts : Int64 = 0
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    let sample_count = r.read_u32()
    let sample_duration = r.read_u32()
    let mut duration = sample_duration
    if sample_duration > max_stts_delta {
      // A huge delta is assumed to be a negative correction cast to uint32.
      let delta_magnitude = sample_duration.reinterpret_as_int()
      duration = 1
      let inc = (if delta_magnitude < 0 {
        delta_magnitude.to_int64()
      } else {
        1
      }) * sample_count.to_int64()
      corrected_dts = sat_add64(corrected_dts, inc)
    } else {
      corrected_dts = sat_add64(
        corrected_dts,
        sample_duration.to_int64() * sample_count.to_int64(),
      )
    }
    current_dts = current_dts + duration.to_int64() * sample_count.to_int64()
    if current_dts > corrected_dts {
      let divisor = if sample_count.reinterpret_as_int() > 1 {
        sample_count.to_int64()
      } else {
        1
      }
      let drift = (current_dts - corrected_dts) / divisor
      let correction = if duration.to_int64() > drift {
        drift
      } else {
        duration.to_int64() - 1
      }
      current_dts = current_dts - correction * sample_count.to_int64()
      duration = (duration.to_int64() - correction).reinterpret_as_uint64().to_uint()
    }
    st.cur.stts.push({ count: sample_count.reinterpret_as_int(), duration })
  }
}

///| `mov_read_ctts`: per-entry presentation offsets, plus the `dts_shift` they imply. */
fn parse_ctts(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries < 0 || entries.to_int64() * 8 > size - 8 {
    raise InvalidData("invalid CTTS entries")
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    let count = r.read_u32().reinterpret_as_int()
    let offset = r.read_u32().reinterpret_as_int()
    if count <= 0 {
      continue
    }
    st.cur.ctts.push({ count, offset })
    // Any entry but the last: a negative offset forces an index-wide DTS shift
    // (mov_update_dts_shift).
    if i + 2 < entries && offset < 0 {
      let shift = -offset
      if shift > st.cur.dts_shift {
        st.cur.dts_shift = shift
      }
    }
  }
}

///| `mov_read_stsc`, including the validation pass that repairs corrupt tables. */
fn parse_stsc(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries.to_int64() * 12 + 4 > size {
    raise InvalidData("invalid STSC size")
  }
  if entries <= 0 {
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    let first = r.read_u32().reinterpret_as_int()
    let count = r.read_u32().reinterpret_as_int()
    let id = r.read_u32().reinterpret_as_int()
    st.cur.stsc.push({ first, count, id })
  }
  // Validity pass, walking backwards exactly like the C loop.
  let mut i = st.cur.stsc.length() - 1
  while i >= 0 {
    let first_min = i.to_int64() + 1
    let e = st.cur.stsc[i]
    let forward_bad = i + 1 < st.cur.stsc.length() && e.first >= st.cur.stsc[i + 1].first
    let backward_bad = i > 0 && e.first <= st.cur.stsc[i - 1].first
    if forward_bad || backward_bad || e.first.to_int64() < first_min || e.count < 1 || e.id < 1 {
      if i + 1 >= st.cur.stsc.length() {
        if e.count == 0 && i > 0 {
          // Drop a trailing zero-count entry.
          let _ = st.cur.stsc.pop()
          i = i - 1
          continue
        }
        let mut first = if e.first.to_int64() > first_min {
          e.first
        } else {
          first_min.to_int()
        }
        if i > 0 && first <= st.cur.stsc[i - 1].first {
          first = st.cur.stsc[i - 1].first + 1
        }
        let count = if e.count > 1 { e.count } else { 1 }
        let id = if e.id > 1 { e.id } else { 1 }
        st.cur.stsc[i] = { first, count, id }
      } else {
        // Replace this entry by the next valid one.
        st.cur.stsc[i] = {
          first: st.cur.stsc[i + 1].first - 1,
          count: st.cur.stsc[i + 1].count,
          id: st.cur.stsc[i + 1].id,
        }
      }
    }
    i = i - 1
  }
}

///| `mov_read_stsz` / `mov_read_stz2`. */
fn parse_stsz(
  st : MovState,
  r : Mp4Reader,
  size : Int64,
  stz2 : Bool
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let mut sample_size : UInt = 0
  let mut field_size = 32
  if !stz2 {
    sample_size = r.read_u32()
    if st.cur.sample_size == 0 {
      st.cur.sample_size = sample_size
    }
    st.cur.stsz_sample_size = sample_size
  } else {
    let _ = r.read_u24() // reserved
    field_size = r.read_u8().reinterpret_as_int()
  }
  let entries = r.read_u32().reinterpret_as_int()
  if entries < 0 {
    raise InvalidData("invalid STSZ entries")
  }
  st.cur.sample_count = entries
  if sample_size != 0 {
    // Constant sample size: no per-sample table follows.
    return
  }
  if field_size != 4 && field_size != 8 && field_size != 16 && field_size != 32 {
    raise InvalidData("invalid sample field size")
  }
  if entries == 0 {
    return
  }
  if entries.to_int64() * field_size.to_int64() > (size - 12) * 8 {
    raise InvalidData("STSZ atom truncated")
  }
  // `get_bits_long(&gb, field_size)` is an MSB-first bit reader; reproduce it so
  // that 4-bit (stz2) fields pack two samples per byte.
  let base = r.position()
  let mut bitpos = 0
  for i = 0; i < entries; i = i + 1 {
    let mut v : UInt = 0
    for b = 0; b < field_size; b = b + 1 {
      let shift = 7 - bitpos % 8
      let bit = (r.peek_u8_at(base + bitpos / 8) >> shift) & 1
      v = (v << 1) | bit
      bitpos = bitpos + 1
    }
    st.cur.sample_sizes.push(v)
  }
  r.skip((bitpos / 8).to_int64())
}

///| `mov_read_stco` / `mov_read_co64`. */
fn parse_stco(
  st : MovState,
  r : Mp4Reader,
  size : Int64,
  co64 : Bool
) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let raw_entries = r.read_u32()
  let entry_size : Int64 = if co64 { 8 } else { 4 }
  // Clamp the declared count to what the atom can hold, as mov_read_stco does.
  let cap0 : Int64 = (size - 8) / entry_size
  let cap : Int64 = if cap0 < 0 { 0L } else { cap0 }
  let raw : Int64 = raw_entries.reinterpret_as_int().to_int64()
  let entries : Int = if raw < cap { raw.to_int() } else { cap.to_int() }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    if co64 {
      let off = r.read_i64()
      // An impossible (negative) chunk offset is clamped to 0, as in the C code.
      st.cur.chunk_offsets.push(if off < 0 { 0 } else { off })
    } else {
      st.cur.chunk_offsets.push(r.read_u32().to_int64())
    }
  }
}

///| `mov_read_stss`: sync-sample (keyframe) table. */
fn parse_stss(st : MovState, r : Mp4Reader) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries <= 0 {
    // An empty stss means every sample is a sync sample.
    st.cur.keyframe_absent = true
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    st.cur.keyframes.push(r.read_u32())
  }
}

///| `mov_read_stps`: partial-sync (open-GOP) sample table. */
fn parse_stps(st : MovState, r : Mp4Reader) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u32() // version + flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries <= 0 {
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    st.cur.stps.push(r.read_u32())
  }
}

///| `mov_read_trak`: parse one track's boxes, then build its sample index. */
fn parse_trak(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  st.in_trak = true
  st.cur = new_track()
  parse_default(st, r, size)
  st.in_trak = false
  mov_build_index(st, st.cur)
  st.movie.tracks.push(st.cur)
}

// ---------------------------------------------------------------------------
// mov_merge_tts_data and mov_build_index
// ---------------------------------------------------------------------------

///|
/// `mov_merge_tts_data`: expand `stts` and `ctts` into a per-sample table where
/// each entry carries one sample's duration and one sample's CTTS offset, with
/// `count` set to 1 (the C code sets the same after the expansion).
/// `has_stts`/`has_ctts` keep the presence flags that C preserves in
/// `stts_count`/`ctts_count` after freeing the original arrays.
fn mov_merge_tts_data(track : Mp4Track) -> Unit raise MovError {
  let has_ctts = track.ctts.length() > 0
  let has_stts = track.stts.length() > 0
  if !has_ctts && !has_stts {
    return
  }
  if track.sample_count <= 0 {
    raise InvalidData("no sample count for tts merge")
  }
  let n = track.sample_count
  let tts : Array[MovTts] = Array::make(n, { count: 0, offset: 0, duration: 0 })
  let mut idx = 0
  if has_ctts {
    for i = 0; i < track.ctts.length(); i = i + 1 {
      let e = track.ctts[i]
      let mut j = 0
      while j < e.count && idx < n {
        tts[idx] = { count: 1, offset: e.offset, duration: 0 }
        idx = idx + 1
        j = j + 1
      }
    }
    track.has_ctts = true
  }
  // The stts pass restarts at sample 0, filling in the durations that the ctts
  // pass left at zero (C resets `idx = 0` between the two loops).
  idx = 0
  if has_stts {
    for i = 0; i < track.stts.length(); i = i + 1 {
      let e = track.stts[i]
      let mut j = 0
      while j < e.count && idx < n {
        let prev = tts[idx]
        tts[idx] = { count: 1, offset: prev.offset, duration: e.duration }
        idx = idx + 1
        j = j + 1
      }
    }
    track.has_stts = true
  }
  track.tts = tts
}

///|
/// `mov_build_index`: turn the sample tables into a per-sample index.
///
/// The chunked "old uncompressed audio" path is not ported: when it would apply
/// (`stts` reduces to a single entry of duration 1 on an audio track), the track
/// is flagged with `unsupported_audio_chunk_demux` and produces no samples.
fn mov_build_index(st : MovState, track : Mp4Track) -> Unit raise MovError {
  let mut current_dts : Int64 = 0
  let mut stsc_index = 0
  let mut stss_index = 0
  let mut stps_index = 0

  // Edit list: adjust the first DTS (non-advanced-editlist behaviour).
  if track.elst.length() > 0 {
    let mut empty_duration : Int64 = 0
    let mut start_time : Int64 = 0
    let mut edit_start_index = 0
    for i = 0; i < track.elst.length(); i = i + 1 {
      let e = track.elst[i]
      if i == 0 && e.time == -1 {
        // An empty first edit carries the stream start time in movie timebase.
        empty_duration = e.duration
        edit_start_index = 1
      } else if i == edit_start_index && e.time >= 0 {
        start_time = e.time
      }
    }
    if (empty_duration != 0 || start_time != 0) && st.movie.timescale > 0 {
      if empty_duration != 0 {
        empty_duration = mov_rescale(empty_duration, track.timescale, st.movie.timescale)
      }
      track.time_offset = start_time - empty_duration
      current_dts = -mov_clip64(track.time_offset)
    }
  }

  let audio_special = media_is_audio(track.media_type) &&
    track.stts.length() == 1 &&
    track.stts[0].duration == 1
  if audio_special {
    track.unsupported_audio_chunk_demux = true
    return
  }

  current_dts = current_dts - track.dts_shift.to_int64()

  mov_merge_tts_data(track)
  if track.sample_count <= 0 || track.tts.length() == 0 || track.stsc.length() == 0 ||
    track.chunk_offsets.length() == 0 {
    return
  }

  let key_off = if (track.keyframes.length() > 0 && track.keyframes[0] > 0) ||
    (track.stps.length() > 0 && track.stps[0] > 0) {
    1
  } else {
    0
  }

  let mut current_sample = 0
  let mut stts_sample = 0
  let mut distance : UInt = 0
  let mut stts_index = 0

  for i = 0; i < track.chunk_offsets.length(); i = i + 1 {
    let next_offset = if i + 1 < track.chunk_offsets.length() {
      track.chunk_offsets[i + 1]
    } else {
      i64_max
    }
    let mut current_offset = track.chunk_offsets[i]
    while mov_stsc_index_valid(stsc_index, track.stsc.length()) &&
      i + 1 == track.stsc[stsc_index + 1].first {
      stsc_index = stsc_index + 1
    }

    // The `stsz` sanity fixups from mov_build_index.
    if next_offset > current_offset &&
      track.sample_size > 0 &&
      track.sample_size < track.stsz_sample_size &&
      track.stsc[stsc_index].count.to_int64() * track.stsz_sample_size.to_int64() >
      next_offset - current_offset {
      track.stsz_sample_size = track.sample_size
    }
    if track.stsz_sample_size > 0 && track.stsz_sample_size < track.sample_size {
      track.stsz_sample_size = track.sample_size
    }

    for j = 0; j < track.stsc[stsc_index].count; j = j + 1 {
      if current_sample >= track.sample_count {
        raise InvalidData("wrong sample count")
      }
      let mut keyframe = false
      if !track.keyframe_absent &&
        (track.keyframes.length() == 0 ||
          (current_sample + key_off).reinterpret_as_uint() == track.keyframes[stss_index]) {
        keyframe = true
        if stss_index + 1 < track.keyframes.length() {
          stss_index = stss_index + 1
        }
      } else if track.stps.length() > 0 &&
        (current_sample + key_off).reinterpret_as_uint() == track.stps[stps_index] {
        keyframe = true
        if stps_index + 1 < track.stps.length() {
          stps_index = stps_index + 1
        }
      }
      if track.keyframe_absent &&
        track.stps.length() == 0 &&
        (media_is_audio(track.media_type) || (i == 0 && j == 0)) {
        keyframe = true
      }
      if keyframe {
        distance = 0
      }
      let sample_size = if track.stsz_sample_size > 0 {
        track.stsz_sample_size
      } else if current_sample < track.sample_sizes.length() {
        track.sample_sizes[current_sample]
      } else {
        raise InvalidData("missing sample size")
      }
      let duration = track.tts[stts_index].duration
      // Only the primary sample description (stsc id 1) is indexed, matching
      // FFmpeg's pseudo_stream_id filtering for the primary stream.
      if track.stsc[stsc_index].id == 1 {
        let pts = if track.has_ctts {
          current_dts + track.dts_shift.to_int64() + track.tts[stts_index].offset.to_int64()
        } else {
          current_dts
        }
        track.samples.push({
          offset: current_offset,
          size: sample_size,
          dts: current_dts,
          pts,
          duration,
          keyframe,
          min_distance: distance,
        })
      }
      current_offset = current_offset + sample_size.to_int64()
      current_dts = current_dts + duration.to_int64()
      distance = distance + 1
      stts_sample = stts_sample + 1
      current_sample = current_sample + 1
      if stts_index + 1 < track.tts.length() && stts_sample == track.tts[stts_index].count {
        stts_sample = 0
        stts_index = stts_index + 1
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

///|
/// `av_mov_open`: parse an in-memory MP4/MOV container.
///
/// Walking top-level boxes mirrors `mov_read_default` called from
/// `mov_read_header` with `atom.type == 'root'`. Malformed input is reported as
/// `Err`, mirroring the negative return codes in libavformat/mov.c.
pub fn av_mov_open(buf : Bytes) -> Result[Mp4Movie, String] {
  let movie = new_movie()
  let st : MovState = { movie, cur: new_track(), in_trak: false }
  let r = Mp4Reader::new(buf)
  let total = r.total_size().to_int64()
  try {
    let mut consumed : Int64 = 0
    while consumed <= total - 8 {
      let box_start = r.position().to_int64()
      let size32 = r.read_u32().to_int64()
      let kind = r.read_fourcc()
      if r.eof_reached() {
        break
      }
      let mut header : Int64 = 8
      let mut size = size32
      if size32 == 1 {
        size = r.read_u64().reinterpret_as_int64()
        header = 16
      } else if size32 == 0 {
        size = total - consumed
      }
      let mut payload = size - header
      if payload < 0 {
        break
      }
      let avail = total - consumed - header
      if payload > avail {
        payload = avail
      }
      if payload < 0 {
        break
      }
      parse_box(st, r, kind, payload)
      let left = payload - (r.position().to_int64() - box_start - header)
      if left != 0 {
        r.skip(left)
      }
      consumed = consumed + header + payload
    }
    Ok(movie)
  } catch {
    InvalidData(msg) => Err(msg)
  }
}
