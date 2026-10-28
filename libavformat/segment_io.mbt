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
  playlist : HlsPlaylist
  fetch : MediaFetch
  keys : Map[Int32, Bytes]
  maps : Map[Int32, Bytes]
  mut next_index : Int32
}

///|
/// Create a reader for a parsed media playlist. Master-playlist selection and
/// live-playlist reloads remain application decisions.
///
/// ```mbt check
/// test {
///   let playlist = @libavformat.av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
///   let reader = @libavformat.hls_segment_reader_new(playlist, (_, _, _) => {
///     Err("no resources")
///   }).unwrap()
///   assert_true(reader.next().unwrap() is None)
/// }
/// ```
pub fn hls_segment_reader_new(
  playlist : HlsPlaylist,
  fetch : MediaFetch,
) -> Result[HlsSegmentReader, String] {
  if playlist.is_master {
    return Err("hls: select a media playlist before reading")
  }
  Ok({ playlist, fetch, keys: Map([]), maps: Map([]), next_index: 0, })
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
  let mut discontinuity = false
  while index < self.playlist.segments.length() &&
        self.playlist.segments[index].gap {
    discontinuity = discontinuity || self.playlist.segments[index].discontinuity
    index += 1
  }
  if index >= self.playlist.segments.length() {
    self.next_index = index
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
pub struct DashSegmentReader {
  representation : DashRepresentation
  fetch : MediaFetch
  mut initialization : Bytes?
  mut next_index : Int32
  mut index_loaded : Bool
  index_offsets : Array[(Int64, Int64)]
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
  let init = match self.initialization {
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
/// Parse a `sidx` box fetched from `[index_start, ...)`.
fn dash_parse_sidx(
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
  let box_size = dash_sidx_u32(data, 0)
  if box_size < 24L || box_size > data.length().to_int64() {
    return Err("dash: invalid sidx size")
  }
  let version = data[8].to_int()
  let mut first_offset = 0L
  let mut count_off = 0
  let mut entries_off = 0
  if version == 0 {
    first_offset = dash_sidx_u32(data, 24)
    count_off = 30
    entries_off = 32
  } else if version == 1 {
    first_offset = dash_sidx_u64(data, 28)
    count_off = 38
    entries_off = 40
  } else {
    return Err("dash: unsupported sidx version")
  }
  let count = (data[count_off].to_int() << 8) | data[count_off + 1].to_int()
  if entries_off + count * 12 > box_size.to_int() {
    return Err("dash: sidx references out of bounds")
  }
  let sizes : Array[Int64] = []
  for i = 0; i < count; i = i + 1 {
    let off = entries_off + 12 * i
    let word = dash_sidx_u32(data, off)
    sizes.push(word & 0x7FFFFFFFL)
  }
  Ok({ media_start: index_start + box_size + first_offset, sizes, })
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
