///|
/// MoonBit port of the HLS playlist layer from FFmpeg 9.0.2
/// `libavformat/hls.c` (`parse_playlist`, `parse_playlist_line`,
/// `parse_media_playlist`, `parse_master_playlist`, attribute and byte-range
/// helpers) and `libavformat/hlsproto.c` URL handling.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: parsing of already-downloaded M3U8 text — master variants, media
/// renditions, I-frame streams, segment URIs/durations/byte ranges, keys, maps,
/// discontinuities, gaps and program date-time. segment_io.mbt fetches
/// initialization/key/media resources through a caller-provided callback and
/// hls_crypto.mbt decrypts AES-128 segments; network IO stays with the caller.
///
/// Out of scope: EXT-X-START, EXT-X-SESSION-KEY/DATA, EXT-X-SKIP delta
/// updates (tags are accepted and ignored), LL-HLS partial segments, and
/// parsing the segment payload itself (use the existing TS/MP4 demuxers).

///|
/// A byte range on a segment/map (`EXT-X-BYTERANGE`); `offset` is -1 when the
/// tag omitted it (meaning "follow the previous range"). */
pub struct HlsByteRange {
  length : Int64
  offset : Int64
}

///|
/// One media segment. */
pub struct HlsSegment {
  uri : String
  duration : Double
  title : String
  byterange : HlsByteRange?
  discontinuity : Bool
  gap : Bool
  /// Index into `HlsPlaylist.keys`, or -1 when no key applies.
  key_index : Int32
  /// Index into `HlsPlaylist.maps`, or -1 when no map applies.
  map_index : Int32
  program_date_time : String
  /// Absolute sequence number (`EXT-X-MEDIA-SEQUENCE` + index).
  media_sequence : Int64
}

///|
/// `EXT-X-KEY`. `method == "NONE"` is represented by the segment's key index
/// going back to -1 rather than by a key entry. */
pub struct HlsKey {
  method_ : String
  uri : String
  iv : String
  key_format : String
  key_format_versions : String
}

///|
/// `EXT-X-MAP` initialization section. */
pub struct HlsMap {
  uri : String
  byterange : HlsByteRange?
  /// Key in effect when the initialization section was declared.
  key_index : Int32
}

///|
/// `EXT-X-MEDIA` rendition. */
pub struct HlsRendition {
  type_ : String
  group_id : String
  name : String
  language : String
  is_default : Bool
  autoselect : Bool
  forced : Bool
  uri : String
  channels : String
  instream_id : String
}

///|
/// One `EXT-X-STREAM-INF` / `EXT-X-I-FRAME-STREAM-INF` variant. */
pub struct HlsStreamInfo {
  bandwidth : Int64
  average_bandwidth : Int64
  codecs : String
  width : Int32
  height : Int32
  frame_rate : String
  audio : String
  video : String
  subtitles : String
  closed_captions : String
  hdcp_level : String
  uri : String
  is_i_frame : Bool
}

///|
/// A parsed playlist. `is_master` distinguishes the two shapes. */
pub struct HlsPlaylist {
  mut is_master : Bool
  mut version : Int32
  mut target_duration : Int32
  mut media_sequence : Int64
  mut discontinuity_sequence : Int64
  mut playlist_type : String
  mut endlist : Bool
  mut i_frames_only : Bool
  mut independent_segments : Bool
  mut start : String
  streams : Array[HlsStreamInfo]
  renditions : Array[HlsRendition]
  keys : Array[HlsKey]
  maps : Array[HlsMap]
  segments : Array[HlsSegment]
}

///|
fn hls_parse_i64(s : StringView, default : Int64) -> Int64 {
  @string.parse_int64(s) catch {
    _ => default
  }
}

///|
fn hls_parse_i32(s : StringView, default : Int32) -> Int32 {
  @string.parse_int(s) catch {
    _ => default
  }
}

///|
fn hls_parse_double(s : StringView, default : Double) -> Double {
  @string.parse_double(s) catch {
    _ => default
  }
}

///|
fn hls_trim_line(line : StringView) -> StringView {
  line.trim(chars="\r\n\t ")
}

///|
fn hls_split_once(s : StringView, sep : Char) -> (StringView, StringView) {
  for i in 0..<s.length() {
    if s[i].to_int() == sep.to_int() {
      return (s[0:i], s[i + 1:])
    }
  }
  (s, "")
}

///|
fn hls_unquote(v : StringView) -> String {
  let t = v.trim(chars=" \t")
  if t.length() >= 2 && t[0] == '"' && t[t.length() - 1] == '"' {
    t[1:t.length() - 1].to_owned()
  } else {
    t.to_owned()
  }
}

///|
/// Split a tag's comma-separated `NAME=VALUE` list, respecting quoted values
/// (which may contain commas, e.g. `CODECS="avc1.42c00a,mp4a.40.2"`).
pub fn hls_parse_attributes(text : StringView) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let n = text.length()
  let mut start = 0
  let mut quoted = false
  for i in 0..<n {
    let c = text[i]
    if c.to_int() == '"'.to_int() {
      quoted = !quoted
    } else if c.to_int() == ','.to_int() && !quoted {
      let part = text[start:i]
      let (k, v) = hls_split_once(part, '=')
      if k.length() > 0 {
        out.push((k.trim(chars=" \t").to_owned(), hls_unquote(v)))
      }
      start = i + 1
    }
  }
  if start < n {
    let part = text[start:]
    let (k, v) = hls_split_once(part, '=')
    if k.length() > 0 {
      out.push((k.trim(chars=" \t").to_owned(), hls_unquote(v)))
    }
  }
  out
}

///|
fn hls_attr(
  attrs : Array[(String, String)],
  name : String,
  default : String,
) -> String {
  for pair in attrs {
    let (k, v) = pair
    if k == name {
      return v
    }
  }
  default
}

///|
/// Parse `EXT-X-BYTERANGE:<length>[@<offset>]`. */
pub fn hls_parse_byterange(text : StringView) -> HlsByteRange? {
  let (len_s, off_s) = hls_split_once(text, '@')
  let len = hls_parse_i64(len_s, -1L)
  if len < 0L {
    return None
  }
  let off = if off_s.length() > 0 { hls_parse_i64(off_s, 0L) } else { -1L }
  Some({ length: len, offset: off, })
}

///|
/// Resolve a playlist-relative URI against the playlist URL. Handles absolute
/// URLs, scheme-relative URLs, absolute paths, and `.`/`..` segments.
pub fn hls_resolve_uri(base : String, reference : String) -> String {
  if reference == "" {
    return base
  }
  if reference.contains("://") ||
    reference.has_prefix("data:") ||
    reference.has_prefix("skd:") {
    return reference
  }
  if base == "" {
    return reference
  }
  let scheme_end = base.find("://")
  let (scheme, after) : (String, String) = match scheme_end {
    Some(i) => (base[0:i].to_owned(), base[i + 3:].to_owned())
    None => ("", base)
  }
  let slash = after.find("/")
  let authority = match slash {
    Some(i) => after[0:i].to_owned()
    None => after
  }
  let path = match slash {
    Some(i) => after[i:].to_owned()
    None => "/"
  }
  if reference.has_prefix("//") {
    return "\{scheme}:\{reference}"
  }
  if reference.has_prefix("/") {
    if scheme != "" {
      return "\{scheme}://\{authority}\{reference}"
    }
    return reference
  }
  let dir = match path.rev_find("/") {
    Some(i) => path[0:i]
    None => ""
  }
  let joined = if dir == "" { reference } else { "\{dir}/\{reference}" }
  if scheme != "" {
    "\{scheme}://\{authority}\{hls_normalize_path(joined)}"
  } else {
    hls_normalize_path(joined)
  }
}

///|
fn hls_normalize_path(path : String) -> String {
  let absolute = path.has_prefix("/")
  let trailing = path.has_suffix("/") && path != "/"
  let parts : Array[String] = []
  for p in path.split("/") {
    match p.to_owned() {
      "" | "." => ()
      ".." => if parts.length() > 0 { ignore(parts.pop()) }
      seg => parts.push(seg)
    }
  }
  let joined = parts.join("/")
  let base = if absolute { "/\{joined}" } else { joined }
  if trailing && base != "" && !base.has_suffix("/") {
    base + "/"
  } else {
    base
  }
}

///|
/// Parse `EXT-X-STREAM-INF`/`EXT-X-I-FRAME-STREAM-INF` attributes. */
fn hls_parse_stream_inf(
  attrs : Array[(String, String)],
  is_i_frame : Bool,
) -> HlsStreamInfo {
  let resolution = hls_attr(attrs, "RESOLUTION", "")
  let (w, h) = if resolution != "" {
    let (ws, hs) = hls_split_once(resolution[:], 'x')
    (hls_parse_i32(ws, 0), hls_parse_i32(hs, 0))
  } else {
    (0, 0)
  }
  {
    bandwidth: hls_parse_i64(hls_attr(attrs, "BANDWIDTH", "")[:], 0L),
    average_bandwidth: hls_parse_i64(
      hls_attr(attrs, "AVERAGE-BANDWIDTH", "")[:],
      0L,
    ),
    codecs: hls_attr(attrs, "CODECS", ""),
    width: w,
    height: h,
    frame_rate: hls_attr(attrs, "FRAME-RATE", ""),
    audio: hls_attr(attrs, "AUDIO", ""),
    video: hls_attr(attrs, "VIDEO", ""),
    subtitles: hls_attr(attrs, "SUBTITLES", ""),
    closed_captions: hls_attr(attrs, "CLOSED-CAPTIONS", ""),
    hdcp_level: hls_attr(attrs, "HDCP-LEVEL", ""),
    uri: hls_attr(attrs, "URI", ""),
    is_i_frame,
  }
}

///|
/// Parse an M3U8 document. `base_uri` is used only to resolve segment/variant
/// URIs; pass "" to keep them relative.
pub fn av_hls_parse(
  text : String,
  base_uri~ : String = "",
) -> Result[HlsPlaylist, String] {
  let playlist : HlsPlaylist = {
    is_master: false,
    version: 1,
    target_duration: 0,
    media_sequence: 0L,
    discontinuity_sequence: 0L,
    playlist_type: "",
    endlist: false,
    i_frames_only: false,
    independent_segments: false,
    start: "",
    streams: [],
    renditions: [],
    keys: [],
    maps: [],
    segments: [],
  }
  let mut saw_header = false
  let mut pending_stream : HlsStreamInfo? = None
  let mut pending_duration = 0.0
  let mut pending_title = ""
  let mut pending_byterange : HlsByteRange? = None
  let mut pending_discontinuity = false
  let mut pending_gap = false
  let mut pending_pdt = ""
  let mut current_key = -1
  let mut current_map = -1
  let mut prev_range_end = 0L
  let mut line_no = 0
  for raw_line in text.split("\n") {
    line_no = line_no + 1
    let mut line = hls_trim_line(raw_line)
    if line_no == 1 && line.length() > 0 && line[0].to_int() == 0xFEFF {
      line = line[1:]
    }
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#EXTM3U") {
      saw_header = true
      continue
    }
    if line.has_prefix("#EXT-X-VERSION:") {
      playlist.version = hls_parse_i32(line[15:], 1)
    } else if line.has_prefix("#EXT-X-TARGETDURATION:") {
      playlist.target_duration = hls_parse_i32(line[22:], 0)
    } else if line.has_prefix("#EXT-X-MEDIA-SEQUENCE:") {
      playlist.media_sequence = hls_parse_i64(line[22:], 0L)
    } else if line.has_prefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
      playlist.discontinuity_sequence = hls_parse_i64(line[30:], 0L)
    } else if line.has_prefix("#EXT-X-PLAYLIST-TYPE:") {
      playlist.playlist_type = line[21:].to_owned()
    } else if line.has_prefix("#EXT-X-ENDLIST") {
      playlist.endlist = true
    } else if line.has_prefix("#EXT-X-I-FRAMES-ONLY") {
      playlist.i_frames_only = true
    } else if line.has_prefix("#EXT-X-INDEPENDENT-SEGMENTS") {
      playlist.independent_segments = true
    } else if line.has_prefix("#EXT-X-START:") {
      playlist.start = line[13:].to_owned()
    } else if line.has_prefix("#EXT-X-STREAM-INF:") {
      playlist.is_master = true
      pending_stream = Some(
        hls_parse_stream_inf(hls_parse_attributes(line[18:]), false),
      )
    } else if line.has_prefix("#EXT-X-I-FRAME-STREAM-INF:") {
      playlist.is_master = true
      let info = hls_parse_stream_inf(hls_parse_attributes(line[26:]), true)
      playlist.streams.push({
        ..info,
        uri: hls_resolve_uri(base_uri, info.uri),
      })
    } else if line.has_prefix("#EXT-X-MEDIA:") {
      let attrs = hls_parse_attributes(line[13:])
      playlist.renditions.push({
        type_: hls_attr(attrs, "TYPE", ""),
        group_id: hls_attr(attrs, "GROUP-ID", ""),
        name: hls_attr(attrs, "NAME", ""),
        language: hls_attr(attrs, "LANGUAGE", ""),
        is_default: hls_attr(attrs, "DEFAULT", "NO") == "YES",
        autoselect: hls_attr(attrs, "AUTOSELECT", "NO") == "YES",
        forced: hls_attr(attrs, "FORCED", "NO") == "YES",
        uri: hls_resolve_uri(base_uri, hls_attr(attrs, "URI", "")),
        channels: hls_attr(attrs, "CHANNELS", ""),
        instream_id: hls_attr(attrs, "INSTREAM-ID", ""),
      })
    } else if line.has_prefix("#EXTINF:") {
      let (dur_s, title) = hls_split_once(line[8:], ',')
      pending_duration = hls_parse_double(dur_s, 0.0)
      pending_title = title.to_owned()
    } else if line.has_prefix("#EXT-X-BYTERANGE:") {
      pending_byterange = hls_parse_byterange(line[17:])
    } else if line.has_prefix("#EXT-X-KEY:") {
      let attrs = hls_parse_attributes(line[11:])
      let key_method = hls_attr(attrs, "METHOD", "")
      if key_method == "NONE" {
        current_key = -1
      } else {
        playlist.keys.push({
          method_: key_method,
          uri: hls_resolve_uri(base_uri, hls_attr(attrs, "URI", "")),
          iv: hls_attr(attrs, "IV", ""),
          key_format: hls_attr(attrs, "KEYFORMAT", "identity"),
          key_format_versions: hls_attr(attrs, "KEYFORMATVERSIONS", "1"),
        })
        current_key = playlist.keys.length() - 1
      }
    } else if line.has_prefix("#EXT-X-MAP:") {
      let attrs = hls_parse_attributes(line[11:])
      let br = hls_attr(attrs, "BYTERANGE", "")
      playlist.maps.push({
        uri: hls_resolve_uri(base_uri, hls_attr(attrs, "URI", "")),
        key_index: current_key,
        byterange: if br == "" {
          None
        } else {
          hls_parse_byterange(br[:])
        },
      })
      current_map = playlist.maps.length() - 1
    } else if line.has_prefix("#EXT-X-DISCONTINUITY") {
      pending_discontinuity = true
    } else if line.has_prefix("#EXT-X-GAP") {
      pending_gap = true
    } else if line.has_prefix("#EXT-X-PROGRAM-DATE-TIME:") {
      pending_pdt = line[25:].to_owned()
    } else if line.has_prefix("#") {
      // Comment or an unsupported tag; the C skips these as well.
      continue
    } else {
      let uri = line.to_owned()
      match pending_stream {
        Some(info) => {
          playlist.streams.push({ ..info, uri: hls_resolve_uri(base_uri, uri), })
          pending_stream = None
        }
        None => {
          let range = match pending_byterange {
            Some(r) =>
              Some({
                length: r.length,
                offset: if r.offset >= 0L {
                  r.offset
                } else {
                  prev_range_end
                },
              })
            None => None
          }
          let seq = playlist.media_sequence +
            playlist.segments.length().to_int64()
          playlist.segments.push({
            uri: hls_resolve_uri(base_uri, uri),
            duration: pending_duration,
            title: pending_title,
            byterange: range,
            discontinuity: pending_discontinuity,
            gap: pending_gap,
            key_index: current_key,
            map_index: current_map,
            program_date_time: pending_pdt,
            media_sequence: seq,
          })
          match range {
            Some(r) => prev_range_end = r.offset + r.length
            None => prev_range_end = 0L
          }
          pending_duration = 0.0
          pending_title = ""
          pending_byterange = None
          pending_discontinuity = false
          pending_gap = false
          pending_pdt = ""
        }
      }
    }
  }
  if !saw_header {
    return Err("EINVAL: missing #EXTM3U")
  }
  Ok(playlist)
}
