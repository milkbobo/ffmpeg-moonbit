///|
/// WebVTT segment writer for HLS subtitle renditions (FFmpeg 9.0.2
/// `webvttenc.c` layout: `WEBVTT` marker plus absolute cue timestamps).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One WebVTT cue with absolute millisecond times.
pub struct HlsVttCue {
  start_ms : Int64
  end_ms : Int64
  text : String
}

///|
pub fn hls_vtt_cue_new(
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> HlsVttCue {
  { start_ms, end_ms, text, }
}

///|
pub fn HlsVttCue::start_ms(self : HlsVttCue) -> Int64 {
  self.start_ms
}

///|
pub fn HlsVttCue::end_ms(self : HlsVttCue) -> Int64 {
  self.end_ms
}

///|
pub fn HlsVttCue::text(self : HlsVttCue) -> String {
  self.text
}

///|
/// An `X-TIMESTAMP-MAP` header, both sides converted to milliseconds. The
/// MPEG-TS side arrives in 90 kHz ticks, the local side as a WebVTT time.
pub struct HlsVttTimestampMap {
  mpegts_ms : Int64
  local_ms : Int64
}

///|
pub fn HlsVttTimestampMap::mpegts_ms(self : HlsVttTimestampMap) -> Int64 {
  self.mpegts_ms
}

///|
pub fn HlsVttTimestampMap::local_ms(self : HlsVttTimestampMap) -> Int64 {
  self.local_ms
}

///|
/// One parsed WebVTT document: its cues plus the `X-TIMESTAMP-MAP` header when
/// the segment declares one.
pub struct HlsVttDocument {
  cues : Array[HlsVttCue]
  timestamp_map : HlsVttTimestampMap?
}

///|
pub fn HlsVttDocument::cues(self : HlsVttDocument) -> Array[HlsVttCue] {
  self.cues
}

///|
/// The `X-TIMESTAMP-MAP` the document declared, if any. Reported rather than
/// applied: mapping it onto a presentation timeline needs the MPEG-TS clock of
/// the muxed stream, which a subtitle rendition playlist does not carry.
pub fn HlsVttDocument::timestamp_map(self : HlsVttDocument) -> HlsVttTimestampMap? {
  self.timestamp_map
}

///|
/// `HH:MM:SS.mmm` timestamp.
fn hls_vtt_timestamp(ms : Int64) -> String {
  let v = if ms < 0L { 0L } else { ms }
  let h = v / 3600000L
  let m = v / 60000L % 60L
  let s = v / 1000L % 60L
  let milli = v % 1000L
  let two = fn(x : Int64) -> String { if x < 10L { "0\{x}" } else { "\{x}" } }
  let three = fn(x : Int64) -> String {
    if x < 10L {
      "00\{x}"
    } else if x < 100L {
      "0\{x}"
    } else {
      "\{x}"
    }
  }
  "\{two(h)}:\{two(m)}:\{two(s)}.\{three(milli)}"
}

///|
/// One WebVTT segment with the cues' absolute times. Like FFmpeg's
/// `webvttenc.c`, no `X-TIMESTAMP-MAP` is written: cue times stay on the
/// playlist timeline, which is what FFmpeg's HLS demuxer expects.
pub fn hls_write_vtt_segment(cues : ArrayView[HlsVttCue]) -> String {
  let sb = StringBuilder()
  sb.write_string("WEBVTT\n")
  for cue in cues {
    sb.write_string("\n")
    sb.write_string(hls_vtt_timestamp(cue.start_ms))
    sb.write_string(" --> ")
    sb.write_string(hls_vtt_timestamp(cue.end_ms))
    sb.write_string("\n")
    sb.write_string(cue.text)
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// Decimal digits to Int64, or None when the field is empty or not numeric.
/// Hand-rolled because `@string.parse_int` raises and the cue parser wants a
/// plain `Option`.
fn hls_vtt_digits(text : StringView) -> Int64? {
  if text.length() == 0 {
    return None
  }
  let mut value = 0L
  for i = 0; i < text.length(); i = i + 1 {
    let digit = text[i].to_int() - '0'.to_int()
    if digit < 0 || digit > 9 {
      return None
    }
    value = value * 10L + digit.to_int64()
  }
  Some(value)
}

///|
/// Parse a WebVTT timestamp: `HH:MM:SS.mmm`, `MM:SS.mmm`, or `SS.mmm`.
/// A comma decimal separator is accepted because writers in the wild emit it.
/// Returns milliseconds, or None when the field is malformed.
fn hls_vtt_parse_time(field : StringView) -> Int64? {
  let text = field.trim(chars=" \t").to_owned()
  if text.length() == 0 {
    return None
  }
  let parts : Array[String] = []
  for part in text.split(":") {
    parts.push(part.to_owned())
  }
  let (hour_text, minute_text, second_text) = if parts.length() == 3 {
    (parts[0], parts[1], parts[2])
  } else if parts.length() == 2 {
    ("0", parts[0], parts[1])
  } else if parts.length() == 1 {
    ("0", "0", parts[0])
  } else {
    return None
  }
  let hours = match hls_vtt_digits(hour_text) {
    Some(v) => v
    None => return None
  }
  let minutes = match hls_vtt_digits(minute_text) {
    Some(v) => v
    None => return None
  }
  let (whole_text, fraction_text) = match second_text.find(".") {
    Some(i) => (second_text[0:i].to_owned(), second_text[i + 1:].to_owned())
    None =>
      match second_text.find(",") {
        Some(i) => (second_text[0:i].to_owned(), second_text[i + 1:].to_owned())
        None => (second_text, "")
      }
  }
  let seconds = match hls_vtt_digits(whole_text) {
    Some(v) => v
    None => return None
  }
  let mut millis = 0L
  let mut scale = 100L
  for i = 0; i < fraction_text.length() && i < 3; i = i + 1 {
    let digit = fraction_text[i].to_int() - '0'.to_int()
    if digit < 0 || digit > 9 {
      return None
    }
    millis = millis + digit.to_int64() * scale
    scale = scale / 10L
  }
  Some(((hours * 60L + minutes) * 60L + seconds) * 1000L + millis)
}

///|
/// Split one cue's timing line (`start --> end [settings]`) into absolute
/// millisecond bounds. Cue settings after the end timestamp are ignored, as
/// the port has no renderer to apply them to.
///
/// The two bounds are whitespace-separated from the `-->` arrow on both
/// sides (`start --> end`, not `start-->end`), so the fields are trimmed
/// before parsing rather than fed to the number reader raw.
fn hls_vtt_parse_timing(line : String) -> Result[(Int64, Int64), String] {
  let arrow = match line.find("-->") {
    Some(i) => i
    None => return Err("vtt: cue line has no --> separator")
  }
  let start_field = line[0:arrow].trim(chars=" \t").to_owned()
  let body = line[arrow + 3:].trim(chars=" \t").to_owned()
  // The end timestamp is the first whitespace-delimited token of what
  // follows; the rest is cue settings.
  let mut end_at = body.length()
  for sep in [" ", "\t"] {
    match body.find(sep) {
      Some(i) =>
        if i < end_at {
          end_at = i
        }
      None => ()
    }
  }
  let end_field = body[0:end_at].to_owned()
  let start = match hls_vtt_parse_time(start_field) {
    Some(v) => v
    None => return Err("vtt: bad cue start timestamp '\{start_field}'")
  }
  let end = match hls_vtt_parse_time(end_field) {
    Some(v) => v
    None => return Err("vtt: bad cue end timestamp '\{end_field}'")
  }
  if end < start {
    return Err("vtt: cue ends before it starts (\{start} -> \{end})")
  }
  Ok((start, end))
}

///|
/// `X-TIMESTAMP-MAP=MPEGTS:<90kHz ticks>,LOCAL:<vtt time>`, both sides turned
/// into milliseconds. Either side may appear on its own; the other then keeps
/// `0`. Returns `None` when neither side parses, so a malformed header degrades
/// to "no map declared" instead of failing the whole segment.
fn hls_vtt_timestamp_map(line : String) -> HlsVttTimestampMap? {
  let at = match line.find("=") {
    Some(i) => i
    None => return None
  }
  let mut mpegts_ms = -1L
  let mut local_ms = -1L
  for field in line[at + 1:].split(",") {
    let text = field.trim(chars=" \t")
    if text.has_prefix("MPEGTS:") {
      // Ticks are 90 kHz, so 90 ticks make one millisecond.
      match hls_vtt_digits(text[7:]) {
        Some(ticks) => mpegts_ms = ticks / 90L
        None => ()
      }
    } else if text.has_prefix("LOCAL:") {
      match hls_vtt_parse_time(text[6:]) {
        Some(ms) => local_ms = ms
        None => ()
      }
    }
  }
  if mpegts_ms < 0L && local_ms < 0L {
    return None
  }
  let mpegts_side = if mpegts_ms < 0L { 0L } else { mpegts_ms }
  let local_side = if local_ms < 0L { 0L } else { local_ms }
  Some({ mpegts_ms: mpegts_side, local_ms: local_side })
}

///|
/// Parse one WebVTT document (an HLS subtitle segment, or a standalone `.vtt`)
/// into cues with absolute millisecond times.
///
/// The `WEBVTT` signature is required. `NOTE`/`STYLE`/`REGION` blocks and the
/// cue identifier line are skipped; a cue's text is every line after its
/// timing line, joined with `\n`. Cue settings (`align:`, `line:`, ...) are
/// dropped - there is no renderer downstream to honor them.
///
/// An `X-TIMESTAMP-MAP` header is parsed and reported but *not* applied: cue
/// times are taken as given, because mapping the header onto a presentation
/// timeline needs the MPEG-TS clock of the muxed stream, which a subtitle
/// rendition playlist does not carry.
pub fn hls_vtt_parse_document(text : String) -> Result[HlsVttDocument, String] {
  let lines : Array[String] = []
  for line in text.split("\n") {
    let owned = line.to_owned()
    // A trailing CR is the CRLF artifact, not content.
    if owned.has_suffix("\r") {
      lines.push(owned[0:owned.length() - 1].to_owned())
    } else {
      lines.push(owned)
    }
  }
  let mut cursor = 0
  // A BOM may precede the signature.
  while cursor < lines.length() && lines[cursor].trim(chars=" \t").length() == 0 {
    cursor = cursor + 1
  }
  if cursor >= lines.length() {
    return Err("vtt: empty document")
  }
  let signature = lines[cursor]
  let mut signature_text = signature
  if signature_text.has_prefix("\u{FEFF}") {
    signature_text = signature_text[1:].to_owned()
  }
  if !signature_text.trim(chars=" \t").has_prefix("WEBVTT") {
    return Err("vtt: missing WEBVTT signature")
  }
  let cues : Array[HlsVttCue] = []
  let block : Array[String] = []
  let mut timestamp_map : HlsVttTimestampMap? = None
  // The WEBVTT header region is the signature line plus the metadata lines up
  // to the first blank line. `X-TIMESTAMP-MAP` only counts there: a `NOTE`
  // body that happens to spell the header name must not be picked up.
  let mut in_header = true
  let flush = fn() -> Result[Unit, String] {
    if block.length() == 0 {
      return Ok(())
    }
    let mut timing_at = -1
    for i = 0; i < block.length(); i = i + 1 {
      if block[i].find("-->") is Some(_) {
        timing_at = i
        break
      }
    }
    if timing_at < 0 {
      // Header metadata, NOTE, STYLE or REGION: nothing to emit.
      block.clear()
      return Ok(())
    }
    let (start, end) = match hls_vtt_parse_timing(block[timing_at]) {
      Ok(v) => v
      Err(e) => {
        block.clear()
        return Err(e)
      }
    }
    let text_lines : Array[String] = []
    for i in (timing_at + 1)..<block.length() {
      text_lines.push(block[i])
    }
    cues.push(hls_vtt_cue_new(start, end, text_lines.join("\n")))
    block.clear()
    Ok(())
  }
  for i in (cursor + 1)..<lines.length() {
    let line = lines[i]
    let trimmed = line.trim(chars=" \t")
    if in_header && trimmed.has_prefix("X-TIMESTAMP-MAP") {
      match hls_vtt_timestamp_map(trimmed.to_owned()) {
        Some(map) =>
          if timestamp_map is None {
            timestamp_map = Some(map)
          }
        None => ()
      }
    }
    if trimmed.length() == 0 {
      in_header = false
      match flush() {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else {
      match trimmed.find("-->") {
        Some(_) => in_header = false
        None => ()
      }
      block.push(line)
    }
  }
  match flush() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok({ cues, timestamp_map })
}

///|
/// Parse one WebVTT document into just its cues. See `hls_vtt_parse_document`
/// when the `X-TIMESTAMP-MAP` header matters too.
pub fn hls_vtt_parse(text : String) -> Result[Array[HlsVttCue], String] {
  match hls_vtt_parse_document(text) {
    Ok(document) => Ok(document.cues)
    Err(e) => Err(e)
  }
}

///|
/// Decode a subtitle segment's bytes as UTF-8, replacing malformed sequences
/// with U+FFFD (the same leniency the playlist decoder applies).
fn hls_vtt_text(data : Bytes) -> String {
  let arr : Array[Byte] = []
  for b in data {
    arr.push(b)
  }
  utf8_to_string(arr)
}

///|
/// `EXTINF` seconds to whole milliseconds, rounding to the nearest millisecond
/// so that a playlist of `2.002`-second segments does not drift one tick per
/// segment. Non-positive and non-finite durations contribute nothing.
fn hls_vtt_segment_ms(duration : Double) -> Int64 {
  if !(duration > 0.0) {
    return 0L
  }
  let ms = duration * 1000.0 + 0.5
  if ms >= 9223372036854775807.0 {
    return 9223372036854775807L
  }
  ms.to_int64()
}

///|
/// A collected WebVTT subtitle track: every cue its segments declared, in
/// milliseconds on the presentation timeline, in segment order. Filled either
/// from an HLS `EXT-X-MEDIA:TYPE=SUBTITLES` rendition or from a DASH `text`
/// AdaptationSet, which is why the name carries no container prefix.
///
/// The two cursors exist so a live refresh appends only what is new:
/// `next_start_ms`/`last_sequence` track the HLS rendition playlist,
/// `collected` tracks the DASH segment addresses. They are never both in play -
/// a track is filled by one source only.
pub struct SubtitleTrack {
  language : String
  name : String
  forced : Bool
  /// The playlist (HLS rendition) or MPD (DASH) the track came from.
  source_uri : String
  cues : Array[HlsVttCue]
  /// Presentation position (ms) where the next uncollected segment starts.
  /// HLS accumulates it from `EXTINF` - a live playlist lists only its current
  /// window, so the window's own durations cannot say where it sits. DASH uses
  /// it as a monotone floor under the segment's declared time, for windows that
  /// restart their timeline.
  mut next_start_ms : Int64
  /// HLS: highest `media_sequence` already collected: absolute, monotonic and
  /// unique per segment, unlike the index into a sliding window.
  mut last_sequence : Int64
  /// DASH: `uri@mediaRange` keys already collected. A duration-based
  /// `SegmentTemplate` restarts both its sequence numbers and its times when the
  /// window slides, so the segment's own address is the only stable key.
  collected : Map[String, Bool]
}

///|
/// An empty track. `open` is "new + append", which is what keeps the live
/// refresh path from drifting away from the first-window path.
fn subtitle_track_new(
  language : String,
  name : String,
  forced : Bool,
  source_uri : String,
) -> SubtitleTrack {
  {
    language,
    name,
    forced,
    source_uri,
    cues: [],
    next_start_ms: 0L,
    last_sequence: -1L,
    collected: Map([]),
  }
}

///|
pub fn SubtitleTrack::language(self : SubtitleTrack) -> String {
  self.language
}

///|
pub fn SubtitleTrack::name(self : SubtitleTrack) -> String {
  self.name
}

///|
pub fn SubtitleTrack::forced(self : SubtitleTrack) -> Bool {
  self.forced
}

///|
pub fn SubtitleTrack::source_uri(self : SubtitleTrack) -> String {
  self.source_uri
}

///|
pub fn SubtitleTrack::cue_count(self : SubtitleTrack) -> Int {
  self.cues.length()
}

///|
pub fn SubtitleTrack::cue(self : SubtitleTrack, index : Int) -> HlsVttCue? {
  if index < 0 || index >= self.cues.length() {
    return None
  }
  Some(self.cues[index])
}

///|
pub fn SubtitleTrack::cues(self : SubtitleTrack) -> Array[HlsVttCue] {
  self.cues
}

///|
/// Append one segment's cues to `out`, placed on the presentation timeline.
///
/// Cue times are read as *absolute* first (what `hls_write_vtt_segment` writes,
/// and what a packager that keeps cues on the timeline writes). Authors that
/// instead write segment-relative times are handled by a rule that cannot
/// misfire: a segment whose last cue ends at or before the segment's own start
/// was authored relative to the segment, so it is shifted into place. For the
/// first segment the shift is zero either way, so the rule is never a guess
/// there. This is shared by the HLS rendition and DASH `text` paths, which
/// differ only in how the segment start is computed.
fn subtitle_place_cues(
  out : Array[HlsVttCue],
  document : HlsVttDocument,
  segment_start_ms : Int64,
) -> Unit {
  let mut last_end = -1L
  for cue in document.cues {
    if cue.end_ms > last_end {
      last_end = cue.end_ms
    }
  }
  let shift = if last_end >= 0L && last_end <= segment_start_ms {
    segment_start_ms
  } else {
    0L
  }
  for cue in document.cues {
    out.push(hls_vtt_cue_new(cue.start_ms + shift, cue.end_ms + shift, cue.text))
  }
}

///|
/// Append the cues of every not-yet-collected segment of `playlist` to `track`,
/// returning how many cues were added. Nothing is committed until the whole
/// pass succeeds, so a fetch or parse failure leaves the track (and its
/// cursors) exactly as it was and the same refresh can be retried.
fn hls_subtitle_track_append(
  track : SubtitleTrack,
  playlist : HlsPlaylist,
  fetch : MediaFetch,
) -> Result[Int, String] {
  if playlist.is_master {
    return Err("vtt: expected a subtitle media playlist, got a master")
  }
  let fresh : Array[HlsVttCue] = []
  let mut next_start = track.next_start_ms
  let mut last_sequence = track.last_sequence
  for segment in playlist.segments {
    // The window overlaps what was already read; those durations are already
    // folded into `next_start`, so skipping without advancing is correct.
    if segment.media_sequence <= last_sequence {
      continue
    }
    if segment.uri == "" {
      return Err("vtt: subtitle segment has an empty URI")
    }
    let data = match fetch(segment.uri, 0L, -1L) {
      Ok(v) => v
      Err(e) => return Err("vtt: segment \{segment.uri} fetch failed: \{e}")
    }
    let document = match hls_vtt_parse_document(hls_vtt_text(data)) {
      Ok(d) => d
      Err(e) => return Err("vtt: segment \{segment.uri}: \{e}")
    }
    subtitle_place_cues(fresh, document, next_start)
    next_start = next_start + hls_vtt_segment_ms(segment.duration)
    last_sequence = segment.media_sequence
  }
  let added = fresh.length()
  for cue in fresh {
    track.cues.push(cue)
  }
  track.next_start_ms = next_start
  track.last_sequence = last_sequence
  Ok(added)
}

///|
/// Fetch and parse every segment of an HLS subtitle rendition playlist.
///
/// See `subtitle_place_cues` for how a segment's cues are placed on the
/// timeline. A `discontinuity` segment does not reset the accumulated timeline
/// here - cue times are absolute in the common case, so `EXT-X-DISCONTINUITY`
/// does not move them.
pub fn hls_subtitle_track_open(
  playlist : HlsPlaylist,
  fetch : MediaFetch,
  source_uri : String,
  rendition : HlsRendition?,
) -> Result[SubtitleTrack, String] {
  let (language, name, forced) = match rendition {
    Some(r) => (r.language, r.name, r.forced)
    None => ("", "", false)
  }
  let track = subtitle_track_new(language, name, forced, source_uri)
  match hls_subtitle_track_append(track, playlist, fetch) {
    Ok(_) => Ok(track)
    Err(e) => Err(e)
  }
}
