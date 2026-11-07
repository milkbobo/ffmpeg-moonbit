///|
/// Callback boundary for adaptive-streaming resources. The orchestration
/// follows FFmpeg 9.0.2 hls.c's open_input/update_init_section/read_data and
/// dashdec.c's init/media ordering. LGPL-2.1-or-later.
/// Original HLS authors: Martin Storsjo (2010), Anssi Hannula (2013),
/// Nachiket Tarate (2021); DASH authors: samsamsam@o2.pl and Steven Liu (2017).
///
/// The caller supplies file or HTTP bytes. Offset is absolute; length=-1
/// requests the whole resource, otherwise return exactly that many bytes.
/// Errors propagate unchanged so the application can decide whether to retry.
pub type MediaFetch = (String, Int64, Int64) -> Result[Bytes, String]

///|
fn media_fetch_resource(
  fetch : MediaFetch,
  uri : String,
  range : HlsByteRange?,
) -> Result[Bytes, String] {
  if uri == "" {
    return Err("segment: empty resource URI")
  }
  let (offset, length) = match range {
    None => (0L, -1L)
    Some(r) => {
      if r.offset < 0L ||
        r.length <= 0L ||
        r.offset > 9223372036854775807L - r.length {
        return Err("segment: invalid byte range")
      }
      (r.offset, r.length)
    }
  }
  match fetch(uri, offset, length) {
    Err(e) => Err(e)
    Ok(bytes) =>
      if length >= 0L && bytes.length().to_int64() != length {
        Err("segment: response length does not match byte range")
      } else {
        Ok(bytes)
      }
  }
}

///|
/// A segment and its required initialization section. Feed `bytes()` to the
/// existing MP4/TS demuxer. Keep segments separate across discontinuities.
pub struct MediaSegmentData {
  sequence : Int64
  initialization : Bytes
  media : Bytes
  discontinuity : Bool
}

///|
/// Initialization followed by media bytes (TS segments usually have no init).
pub fn MediaSegmentData::bytes(self : MediaSegmentData) -> Bytes {
  if self.initialization.length() == 0 {
    return self.media
  }
  let out : Array[Byte] = []
  for byte in self.initialization {
    out.push(byte)
  }
  for byte in self.media {
    out.push(byte)
  }
  Bytes::from_array(out[:])
}

///|
/// Sequential HLS reader. Keys and initialization sections are cached by
/// playlist entry, preserving key rotation even when two entries share a URI.
/// Failed reads retain the cursor; GAP segments are skipped without fetching.
pub struct HlsSegmentReader {
  mut playlist : HlsPlaylist
  fetch : MediaFetch
  keys : Map[Int32, Bytes]
  maps : Map[Int32, Bytes]
  mut next_index : Int32
  mut next_sequence : Int64
  mut pending_discontinuity : Bool
}

///|
/// Create a reader for a parsed media playlist. Master-playlist selection and
/// live-playlist reloads remain application decisions.
/// live_start_index selects the initial segment of an unfinished playlist:
/// nonnegative indexes count from the start, negative indexes from the end.
/// It defaults to 0 for compatibility; use -3 for FFmpeg's usual live default.
/// Set prefer_x_start=true to honor EXT-X-START on unfinished playlists, like
/// FFmpeg's opt-in prefer_x_start. Negative offsets count back from the end;
/// out-of-range offsets clamp to the first/last segment. PRECISE sample trimming
/// stays with the decoder; this reader returns the entire selected segment.
///
/// ```mbt check
/// test {
///   let playlist = @libavformat.av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
///   let reader = @libavformat.hls_segment_reader_new(playlist, (_, _, _) => {
///     Err("no resources")
///   }).unwrap()
///   assert_true(reader.next().unwrap() is None)
/// }
///
/// test {
///   let playlist = @libavformat.av_hls_parse(
///     "#EXTM3U\n#EXT-X-START:TIME-OFFSET=-1\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts",
///   ).unwrap()
///   let reader = @libavformat.hls_segment_reader_new(
///     playlist,
///     (_, _, _) => Ok(b"segment"),
///     prefer_x_start=true,
///   ).unwrap()
///   assert_eq(reader.next().unwrap().unwrap().sequence, 1L)
/// }
/// ```
pub fn hls_segment_reader_new(
  playlist : HlsPlaylist,
  fetch : MediaFetch,
  prefer_x_start~ : Bool = false,
  live_start_index~ : Int32 = 0,
) -> Result[HlsSegmentReader, String] {
  match hls_reader_validate_playlist(playlist) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let count = playlist.segments.length()
  let live_index = if playlist.endlist || count == 0 {
    0
  } else if live_start_index < 0 {
    let index = count + live_start_index
    if index > 0 {
      index
    } else {
      0
    }
  } else if live_start_index < count {
    live_start_index
  } else {
    count - 1
  }
  let next_index = if prefer_x_start && !playlist.endlist {
    hls_start_segment_index(playlist).unwrap_or(live_index)
  } else {
    live_index
  }
  Ok({
    playlist,
    fetch,
    keys: Map([]),
    maps: Map([]),
    next_index,
    next_sequence: playlist.media_sequence + next_index.to_int64(),
    pending_discontinuity: false,
  })
}

///|
fn hls_reader_validate_playlist(playlist : HlsPlaylist) -> Result[Unit, String] {
  if playlist.is_master {
    return Err("hls: select a media playlist before reading")
  }
  if playlist.media_sequence < 0L ||
    playlist.segments.length().to_int64() >
    9223372036854775807L - playlist.media_sequence {
    return Err("hls: media sequence overflow")
  }
  for index, segment in playlist.segments {
    if segment.media_sequence != playlist.media_sequence + index.to_int64() {
      return Err("hls: inconsistent segment sequence")
    }
  }
  Ok(())
}

///|
/// Replace the downloaded media playlist while preserving the next absolute
/// media sequence. Expired unread segments advance to the new window's start
/// and mark the next returned segment discontinuous. Older windows never rewind
/// the cursor. Selection options apply only when constructing the reader.
/// Entry-indexed key/init caches are cleared on every successful reload.
/// Invalid replacements leave the reader unchanged. No resources are fetched.
///
/// ```mbt check
/// test {
///   let initial = @libavformat.av_hls_parse("#EXTM3U").unwrap()
///   let reader = @libavformat.hls_segment_reader_new(initial, (_, _, _) => {
///     Ok(b"data")
///   }).unwrap()
///   assert_true(reader.next().unwrap() is None)
///   reader
///   .reload(@libavformat.av_hls_parse("#EXTM3U\n#EXTINF:1,\na.ts").unwrap())
///   .unwrap()
///   assert_eq(reader.next().unwrap().unwrap().sequence, 0L)
/// }
/// ```
pub fn HlsSegmentReader::reload(
  self : HlsSegmentReader,
  playlist : HlsPlaylist,
) -> Result[Unit, String] {
  match hls_reader_validate_playlist(playlist) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let mut sequence = self.next_sequence
  if sequence < playlist.media_sequence {
    sequence = playlist.media_sequence
    self.pending_discontinuity = true
  }
  let end = playlist.media_sequence + playlist.segments.length().to_int64()
  let index = if sequence >= end {
    playlist.segments.length()
  } else {
    (sequence - playlist.media_sequence).to_int()
  }
  self.playlist = playlist
  self.next_sequence = sequence
  self.next_index = index
  self.keys.clear()
  self.maps.clear()
  Ok(())
}

///|
fn hls_start_segment_index(playlist : HlsPlaylist) -> Int32? {
  if playlist.segments.length() == 0 || playlist.start == "" {
    return None
  }
  let attrs = hls_parse_attributes(playlist.start[:])
  let offset = @string.parse_double(hls_attr(attrs, "TIME-OFFSET", "")) catch {
    _ => return None
  }
  if offset.is_nan() || offset.is_inf() {
    return None
  }
  let mut duration = 0.0
  for segment in playlist.segments {
    if segment.duration < 0.0 ||
      segment.duration.is_nan() ||
      segment.duration.is_inf() {
      return None
    }
    duration += segment.duration
  }
  if duration.is_inf() {
    return None
  }
  let target = if offset < 0.0 { duration + offset } else { offset }
  if target <= 0.0 {
    return Some(0)
  }
  let mut end = 0.0
  for index, segment in playlist.segments {
    end += segment.duration
    if end > target {
      return Some(index)
    }
  }
  Some(playlist.segments.length() - 1)
}

///|
fn HlsSegmentReader::decrypt(
  self : HlsSegmentReader,
  data : Bytes,
  key_index : Int32,
  sequence : Int64,
  is_map : Bool,
) -> Result[Bytes, String] {
  if key_index < 0 {
    return Ok(data)
  }
  guard self.playlist.keys.get(key_index) is Some(key) else {
    return Err("hls: invalid key index")
  }
  if key.method_ != "AES-128" || key.key_format != "identity" {
    return Err("hls: only identity AES-128 encryption is supported")
  }
  let iv = if key.iv == "" {
    if is_map {
      return Err("hls: encrypted initialization requires an explicit IV")
    }
    hls_iv_from_sequence(sequence)
  } else {
    match hls_parse_iv(key.iv) {
      Some(value) => value
      None => return Err("hls: invalid AES-128 IV")
    }
  }
  let material = match self.keys.get(key_index) {
    Some(value) => value
    None => {
      let value = match media_fetch_resource(self.fetch, key.uri, None) {
        Ok(value) => value
        Err(e) => return Err(e)
      }
      if value.length() != 16 {
        return Err("hls: AES-128 key must be 16 bytes")
      }
      self.keys[key_index] = value
      value
    }
  }
  hls_decrypt_aes128(material, iv, data)
}

///|
/// Fetch the next nongap media segment, or None at the playlist's current end.
/// `None` does not imply ENDLIST for a live playlist. A retry after Err reads
/// the same segment. Cached initialization is returned with every fragment.
pub fn HlsSegmentReader::next(
  self : HlsSegmentReader,
) -> Result[MediaSegmentData?, String] {
  let mut index = self.next_index
  let mut discontinuity = self.pending_discontinuity
  while index < self.playlist.segments.length() &&
        self.playlist.segments[index].gap {
    discontinuity = discontinuity || self.playlist.segments[index].discontinuity
    index += 1
  }
  if index >= self.playlist.segments.length() {
    self.next_index = index
    let sequence = self.playlist.media_sequence + index.to_int64()
    if sequence > self.next_sequence {
      self.next_sequence = sequence
    }
    self.pending_discontinuity = discontinuity
    return Ok(None)
  }
  let segment = self.playlist.segments[index]
  let init = if segment.map_index < 0 {
    b""
  } else {
    match self.maps.get(segment.map_index) {
      Some(value) => value
      None => {
        guard self.playlist.maps.get(segment.map_index) is Some(map) else {
          return Err("hls: invalid initialization index")
        }
        let range = match map.byterange {
          Some(r) if r.offset < 0L => Some({ ..r, offset: 0L, })
          other => other
        }
        let bytes = match media_fetch_resource(self.fetch, map.uri, range) {
          Ok(value) => value
          Err(e) => return Err(e)
        }
        let bytes = match
          self.decrypt(bytes, map.key_index, segment.media_sequence, true) {
          Ok(value) => value
          Err(e) => return Err(e)
        }
        self.maps[segment.map_index] = bytes
        bytes
      }
    }
  }
  let data = match
    media_fetch_resource(self.fetch, segment.uri, segment.byterange) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let media = match
    self.decrypt(data, segment.key_index, segment.media_sequence, false) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  self.next_index = index + 1
  self.next_sequence = segment.media_sequence + 1L
  self.pending_discontinuity = false
  Ok(
    Some({
      sequence: segment.media_sequence,
      initialization: init,
      media,
      discontinuity: discontinuity || segment.discontinuity,
    }),
  )
}

///|
/// DASH SegmentTemplate/SegmentList reader for one selected representation.
/// Initialization is fetched once; failed media reads can be retried.
/// For one complete media resource sharing its initialization URI, the full
/// resource is fetched alone because it already contains the initialization.
pub struct DashSegmentReader {
  representation : DashRepresentation
  fetch : MediaFetch
  mut initialization : Bytes?
  mut next_index : Int32
  mut index_loaded : Bool
  index_offsets : Array[(Int64, Int64)]
  /// Start time and duration (in the representation's timescale) of the last
  /// segment handed out. `last_time` stays -1 until the first `next`, and for
  /// the single-file `sidx` path where there is no per-segment timing.
  /// A refreshed live MPD resumes strictly after it.
  mut last_time : Int64
  mut last_duration : Int64
}

///|
pub fn dash_segment_reader_new(
  representation : DashRepresentation,
  fetch : MediaFetch,
) -> DashSegmentReader {
  {
    representation,
    fetch,
    initialization: None,
    next_index: 0,
    index_loaded: false,
    index_offsets: [],
    last_time: -1L,
    last_duration: 0L,
  }
}

///|
/// Start time of the last segment `next` returned (-1 before the first, or
/// when the representation is a single-file `sidx` resource).
pub fn DashSegmentReader::last_time(self : DashSegmentReader) -> Int64 {
  self.last_time
}

///|
/// Duration of the last segment `next` returned (0 before the first).
pub fn DashSegmentReader::last_duration(self : DashSegmentReader) -> Int64 {
  self.last_duration
}

///|
/// Advance the cursor past every segment that starts at or before `time` and
/// report the start time of the next one. `None` means the window did not
/// move: every segment it lists has already been played, so the caller should
/// poll again later instead of treating the session as finished.
pub fn DashSegmentReader::skip_through_time(
  self : DashSegmentReader,
  time : Int64,
) -> Int64? {
  let segments = self.representation.segments
  while self.next_index < segments.length() &&
        segments[self.next_index].time <= time {
    self.next_index += 1
  }
  if self.next_index >= segments.length() {
    None
  } else {
    Some(segments[self.next_index].time)
  }
}

///|
pub fn DashSegmentReader::next(
  self : DashSegmentReader,
) -> Result[MediaSegmentData?, String] {
  let rep = self.representation
  let using_index = rep.segments.length() == 0 && rep.index_range != ""
  if !using_index && self.next_index >= rep.segments.length() {
    return Ok(None)
  }
  // A complete single-file resource already includes its initialization.
  // Prepending the same file's prefix shifts MP4 sample offsets and duplicates
  // its moov; keep separately hosted initialization sections unchanged.
  let whole_file_with_init = !using_index &&
    rep.segments.length() == 1 &&
    rep.segments[0].media_range == "" &&
    rep.segments[0].uri == rep.initialization
  let init = if whole_file_with_init {
    b""
  } else {
    match self.initialization {
      Some(bytes) => bytes
      None => {
        let bytes = if rep.initialization == "" {
          b""
        } else {
          let range = match dash_resource_range(rep.initialization_range) {
            Ok(value) => value
            Err(e) => return Err(e)
          }
          match media_fetch_resource(self.fetch, rep.initialization, range) {
            Ok(value) => value
            Err(e) => return Err(e)
          }
        }
        self.initialization = Some(bytes)
        bytes
      }
    }
  }
  if using_index {
    if !self.index_loaded {
      let range = match dash_resource_range(rep.index_range) {
        Ok(Some(value)) => value
        Ok(None) => return Err("dash: missing SegmentBase index range")
        Err(e) => return Err(e)
      }
      let index_bytes = match
        media_fetch_resource(self.fetch, rep.base_url, Some(range)) {
        Ok(value) => value
        Err(e) => return Err(e)
      }
      let sidx = match dash_parse_sidx(index_bytes, range.offset) {
        Ok(value) => value
        Err(e) => return Err(e)
      }
      let mut offset = sidx.media_start
      for size in sidx.sizes {
        self.index_offsets.push((offset, size))
        offset = offset + size
      }
      self.index_loaded = true
    }
    if self.next_index >= self.index_offsets.length() {
      return Ok(None)
    }
    let (offset, size) = self.index_offsets[self.next_index]
    let media = match
      media_fetch_resource(
        self.fetch,
        rep.base_url,
        Some({ offset, length: size, }),
      ) {
      Ok(value) => value
      Err(e) => return Err(e)
    }
    let sequence = self.next_index.to_int64()
    self.next_index += 1
    return Ok(
      Some({ sequence, initialization: init, media, discontinuity: false, }),
    )
  }
  let segment = rep.segments[self.next_index]
  let range = match dash_resource_range(segment.media_range) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let media = match media_fetch_resource(self.fetch, segment.uri, range) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  self.last_time = segment.time
  self.last_duration = segment.duration
  self.next_index += 1
  Ok(
    Some({
      sequence: segment.number,
      initialization: init,
      media,
      discontinuity: false,
    }),
  )
}

///|
/// Parsed `sidx` (segment index) for a single-file SegmentBase
/// representation. `media_start` is the absolute offset of the first
/// referenced subsegment; `sizes` are the subsegment byte lengths.
priv struct DashSidx {
  media_start : Int64
  sizes : Array[Int64]
}

///|
fn dash_sidx_u32(data : Bytes, off : Int32) -> Int64 {
  (data[off].to_int64() << 24) |
  (data[off + 1].to_int64() << 16) |
  (data[off + 2].to_int64() << 8) |
  data[off + 3].to_int64()
}

///|
fn dash_sidx_u64(data : Bytes, off : Int32) -> Int64 {
  (dash_sidx_u32(data, off) << 32) | dash_sidx_u32(data, off + 4)
}

///|
/// Find a top-level `sidx` in an MPD indexRange response. Skip complete boxes
/// before it; index_start is the absolute start of the response in the file.
fn dash_parse_sidx(
  data : Bytes,
  index_start : Int64,
) -> Result[DashSidx, String] {
  if index_start < 0L {
    return Err("dash: sidx offset overflow")
  }
  let mut pos = 0
  while pos < data.length() {
    if data.length() - pos < 8 {
      return Err("dash: truncated index box header")
    }
    let mut size = dash_sidx_u32(data, pos)
    let mut header = 8L
    if size == 1L {
      if data.length() - pos < 16 {
        return Err("dash: truncated index box header")
      }
      size = dash_sidx_u64(data, pos + 8)
      header = 16L
    } else if size == 0L {
      size = (data.length() - pos).to_int64()
    }
    if size < header || size > (data.length() - pos).to_int64() {
      return Err("dash: invalid index box size")
    }
    if data[pos + 4] == b's' &&
      data[pos + 5] == b'i' &&
      data[pos + 6] == b'd' &&
      data[pos + 7] == b'x' {
      if index_start > 9223372036854775807L - pos.to_int64() {
        return Err("dash: sidx offset overflow")
      }
      return dash_parse_sidx_box(
        data[pos:pos + size.to_int()].to_owned(),
        index_start + pos.to_int64(),
      )
    }
    pos += size.to_int()
  }
  Err("dash: SegmentBase index contains no sidx")
}

///|
/// Parse one validated top-level sidx. Offsets are relative to this box's end,
/// rather than the end of the complete MPD indexRange response.
fn dash_parse_sidx_box(
  data : Bytes,
  index_start : Int64,
) -> Result[DashSidx, String] {
  if data.length() < 8 ||
    data[4] != b's' ||
    data[5] != b'i' ||
    data[6] != b'd' ||
    data[7] != b'x' {
    return Err("dash: SegmentBase index does not start with sidx")
  }
  let mut box_size = dash_sidx_u32(data, 0)
  let mut header = 8
  if box_size == 1L {
    if data.length() < 16 {
      return Err("dash: truncated sidx extended header")
    }
    box_size = dash_sidx_u64(data, 8)
    header = 16
  } else if box_size == 0L {
    box_size = data.length().to_int64()
  }
  if box_size < (header + 4).to_int64() || box_size > data.length().to_int64() {
    return Err("dash: invalid sidx size")
  }
  let version = data[header].to_int()
  let (count_off, entries_off) = match version {
    0 => (header + 22, header + 24)
    1 => (header + 30, header + 32)
    _ => return Err("dash: unsupported sidx version")
  }
  if entries_off.to_int64() > box_size {
    return Err("dash: truncated sidx header")
  }
  if dash_sidx_u32(data, header + 8) == 0L {
    return Err("dash: invalid sidx timescale")
  }
  let first_offset = if version == 0 {
    dash_sidx_u32(data, header + 16)
  } else {
    dash_sidx_u64(data, header + 20)
  }
  let count = (data[count_off].to_int() << 8) | data[count_off + 1].to_int()
  if entries_off + count * 12 > box_size.to_int() {
    return Err("dash: sidx references out of bounds")
  }
  let sizes : Array[Int64] = []
  let max_offset = 9223372036854775807L
  if index_start < 0L ||
    first_offset < 0L ||
    index_start > max_offset - box_size ||
    first_offset > max_offset - index_start - box_size {
    return Err("dash: sidx offset overflow")
  }
  let media_start = index_start + box_size + first_offset
  let mut end = media_start
  for i = 0; i < count; i = i + 1 {
    let off = entries_off + 12 * i
    let word = dash_sidx_u32(data, off)
    if (word & 0x80000000L) != 0L {
      return Err("dash: hierarchical sidx references are unsupported")
    }
    let size = word & 0x7FFFFFFFL
    if size == 0L {
      return Err("dash: empty sidx reference")
    }
    if size > max_offset - end {
      return Err("dash: sidx offset overflow")
    }
    sizes.push(size)
    end += size
  }
  Ok({ media_start, sizes, })
}

///|
fn dash_resource_range(text : String) -> Result[HlsByteRange?, String] {
  if text == "" {
    return Ok(None)
  }
  let parts = text.split("-").collect()
  if parts.length() != 2 {
    return Err("dash: invalid resource byte range")
  }
  let start = @string.parse_int64(parts[0]) catch {
    _ => return Err("dash: invalid resource byte range")
  }
  let end = @string.parse_int64(parts[1]) catch {
    _ => return Err("dash: invalid resource byte range")
  }
  if start < 0L || end < start || end - start == 9223372036854775807L {
    return Err("dash: invalid resource byte range")
  }
  Ok(Some({ offset: start, length: end - start + 1L, }))
}
