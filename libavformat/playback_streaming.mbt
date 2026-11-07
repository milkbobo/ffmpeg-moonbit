///|
/// Adaptive-streaming playback facade: HLS media playlists and DASH MPDs
/// share the same packet/PCM surface as the file containers. The playlist is
/// parsed by the existing HLS/DASH readers; each fetched segment is demuxed
/// by `MediaFile::open`, so no container or codec knowledge is duplicated.
///
/// This is a pure MoonBit slice: the resource boundary is a `MediaFetch`
/// callback supplied by the caller, mirroring FFmpeg's AVIOContext custom IO.
/// No FFI, handles, or finalizers are involved - `Bytes` is immutable and
/// GC-managed, so a fetch result can be retained across segments safely.

///|
/// Which playlist kind backs a `StreamingMedia`.
pub(all) enum StreamingKind {
  Hls
  Dash
} derive(Debug, Eq)

///|
pub extend StreamingKind with Eq::{not_equal, equal}

///|
pub extend StreamingKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A demuxed packet plus the segment it came from. `pts` is normalized onto
/// one monotonic timeline across segments.
pub(all) struct StreamingPacket {
  stream_index : Int32
  data : Bytes
  pts : Int64
  keyframe : Bool
  /// HLS absolute media sequence, or the DASH segment number/index.
  segment_sequence : Int64
  /// True on the first packet of a segment following a discontinuity.
  discontinuity : Bool
}

///|
/// The segment source behind a session. Public only because MoonBit requires
/// a public struct's field types to be public; callers never touch it.
pub(all) enum StreamingReader {
  HlsReader(HlsSegmentReader)
  DashReader(DashSegmentReader)
}

///|
/// An adaptive-streaming playback session.
pub struct StreamingMedia {
  kind : StreamingKind
  format_name : String
  reader : StreamingReader
  mut streams : Array[StreamInfo]
  /// Demuxer for the segment currently being drained; None before the first
  /// `next_packet` and between segments.
  mut current : MediaFile?
  mut current_sequence : Int64
  mut current_discontinuity : Bool
  /// Per-stream last emitted pts on the normalized timeline.
  last_pts : Array[Int64?]
  /// Per-stream last observed pts step, used to place the next segment.
  last_step : Array[Int64]
  /// Per-stream offset applied to the current segment's raw pts.
  offset : Array[Int64]
  /// True once the per-stream offset for this segment has been established.
  anchored : Array[Bool]
  /// The current segment has not emitted a packet yet (for `discontinuity`).
  mut first_in_segment : Bool
  duration : Double?
  mut finished : Bool
}

///|
/// Decode UTF-8 playlist bytes into a MoonBit string. Malformed sequences are
/// replaced with U+FFFD, matching the probe layer's lenient C-string view.
fn streaming_playlist_text(data : Bytes) -> String {
  let arr : Array[Byte] = []
  for b in data {
    arr.push(b)
  }
  utf8_to_string(arr)
}

///|
/// Saturating Int64 add: a corrupt container must not wrap the presentation
/// timeline backwards (the same guard the DASH segment parser applies to its
/// offsets and counters).
fn streaming_sat_add(a : Int64, b : Int64) -> Int64 {
  let max = 9223372036854775807L
  let min = -9223372036854775808L
  if b > 0L && a > max - b {
    max
  } else if b < 0L && a < min - b {
    min
  } else {
    a + b
  }
}

///|
/// Saturating Int64 subtract.
fn streaming_sat_sub(a : Int64, b : Int64) -> Int64 {
  let max = 9223372036854775807L
  let min = -9223372036854775808L
  if b < 0L && a > max + b {
    max
  } else if b > 0L && a < min + b {
    min
  } else {
    a - b
  }
}

///|
/// Grow the per-stream state arrays so `index` is addressable. A stream index
/// beyond a sane container limit is refused rather than turning into an
/// unbounded allocation.
fn StreamingMedia::streaming_ensure(
  self : StreamingMedia,
  index : Int32,
) -> Unit raise MediaError {
  if index < 0 {
    return
  }
  if index >= 4096 {
    raise DemuxError("streaming: stream index out of range")
  }
  while self.last_pts.length() <= index {
    self.last_pts.push(None)
    self.last_step.push(0L)
    self.offset.push(0L)
    self.anchored.push(false)
  }
}

///|
/// Reset the per-segment anchoring state. Offsets are recomputed on each
/// stream's first packet in the new segment.
fn StreamingMedia::streaming_reset_segment(self : StreamingMedia) -> Unit {
  for i = 0; i < self.anchored.length(); i = i + 1 {
    self.anchored[i] = false
    self.offset[i] = 0L
  }
  self.first_in_segment = true
}

///|
/// Fetch the next segment and hand its bytes to the existing demuxer. A
/// reader error leaves every cursor untouched, so the same segment is retried
/// on the next call (the C readers already guarantee this).
fn StreamingMedia::streaming_load_segment(
  self : StreamingMedia,
) -> Unit raise MediaError {
  let next = match self.reader {
    HlsReader(r) => r.next()
    DashReader(r) => r.next()
  }
  let segment = match next {
    Err(e) => raise DemuxError("streaming: \{e}")
    Ok(None) => {
      self.finished = true
      self.current = None
      return
    }
    Ok(Some(s)) => s
  }
  let mf = MediaFile::open(segment.bytes())
  if self.streams.length() == 0 {
    self.streams = mf.streams()
  }
  self.current = Some(mf)
  self.current_sequence = segment.sequence
  self.current_discontinuity = segment.discontinuity
  self.streaming_reset_segment()
}

///|
/// Normalize one packet's pts onto the session timeline. The first segment
/// keeps its raw container timestamps. Later segments are shifted so their
/// first packet of each stream follows the previous segment's last packet by
/// that stream's last observed step - FFmpeg's hls.c/dashdec.c continuity
/// rule expressed without a shared AVFormatContext. Discontinuities keep the
/// timeline monotonic too, but are flagged so the decoder can be reset.
fn StreamingMedia::streaming_normalize(
  self : StreamingMedia,
  pkt : MediaPacket,
) -> StreamingPacket raise MediaError {
  self.streaming_ensure(pkt.stream_index)
  let s = pkt.stream_index
  if !self.anchored[s] {
    self.anchored[s] = true
    self.offset[s] = match self.last_pts[s] {
      None => 0L
      Some(last) =>
        streaming_sat_sub(streaming_sat_add(last, self.last_step[s]), pkt.pts)
    }
  }
  let pts = streaming_sat_add(pkt.pts, self.offset[s])
  match self.last_pts[s] {
    Some(last) => {
      let step = streaming_sat_sub(pts, last)
      self.last_step[s] = if step > 0L { step } else { self.last_step[s] }
    }
    None => ()
  }
  self.last_pts[s] = Some(pts)
  let discontinuity = self.current_discontinuity && self.first_in_segment
  self.first_in_segment = false
  {
    stream_index: s,
    data: pkt.data,
    pts,
    keyframe: pkt.keyframe,
    segment_sequence: self.current_sequence,
    discontinuity,
  }
}

///|
/// Construct a session from a reader. The playlist's stream table is filled
/// on the first packet fetch, once a segment has actually been downloaded, so
/// construction itself performs no IO.
fn streaming_from_reader(
  kind : StreamingKind,
  format_name : String,
  reader : StreamingReader,
  duration : Double?,
) -> StreamingMedia {
  {
    kind,
    format_name,
    reader,
    streams: [],
    current: None,
    current_sequence: 0L,
    current_discontinuity: false,
    last_pts: [],
    last_step: [],
    offset: [],
    anchored: [],
    first_in_segment: true,
    duration,
    finished: false,
  }
}

///|
/// Open an already-parsed HLS media playlist.
///
/// # Example
/// ```mbt check
/// test {
///   let playlist = @libavformat.av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
///   let media = @libavformat.StreamingMedia::open_hls(playlist, (_, _, _) => {
///     Err("no resources")
///   })
///   assert_true(media.next_packet() is None)
/// }
/// ```
pub fn StreamingMedia::open_hls(
  playlist : HlsPlaylist,
  fetch : MediaFetch,
  prefer_x_start~ : Bool = false,
  live_start_index~ : Int32 = 0,
) -> StreamingMedia raise MediaError {
  if playlist.is_master {
    raise DemuxError("hls: master playlist is not a media playlist")
  }
  let reader = match
    hls_segment_reader_new(playlist, fetch, prefer_x_start~, live_start_index~) {
    Err(e) => raise DemuxError("hls: \{e}")
    Ok(r) => r
  }
  let mut total = 0.0
  for seg in playlist.segments {
    if seg.duration > 0.0 {
      total = total + seg.duration
    }
  }
  let duration = if total > 0.0 { Some(total) } else { None }
  streaming_from_reader(Hls, "hls", HlsReader(reader), duration)
}

///|
/// Open one DASH representation. The three indexes select a Period,
/// AdaptationSet and Representation of the parsed MPD; out-of-range values
/// raise `DemuxError` rather than being silently clamped.
pub fn StreamingMedia::open_dash(
  mpd : DashMpd,
  fetch : MediaFetch,
  period~ : Int32 = 0,
  adaptation_set~ : Int32 = 0,
  representation~ : Int32 = 0,
) -> StreamingMedia raise MediaError {
  if period < 0 || period >= mpd.periods.length() {
    raise DemuxError("dash: period index out of range")
  }
  let sets = mpd.periods[period].adaptation_sets
  if adaptation_set < 0 || adaptation_set >= sets.length() {
    raise DemuxError("dash: adaptation set index out of range")
  }
  let reps = sets[adaptation_set].representations
  if representation < 0 || representation >= reps.length() {
    raise DemuxError("dash: representation index out of range")
  }
  let reader = dash_segment_reader_new(reps[representation], fetch)
  let duration = if mpd.media_presentation_duration > 0.0 {
    Some(mpd.media_presentation_duration)
  } else {
    None
  }
  streaming_from_reader(Dash, "dash", DashReader(reader), duration)
}

///|
/// Open an HLS media playlist or a DASH MPD from its raw bytes. The kind is
/// detected from the content (`#EXTM3U` prefix, or an `<MPD` element), so no
/// filename or MIME hint is needed - unlike `av_probe_input_format`, which
/// only scores HLS at maximum with such a hint.
///
/// ```mbt check
/// test {
///   let media = @libavformat.StreamingMedia::open(b"#EXTM3U\n#EXT-X-ENDLIST", (
///     _,
///     _,
///     _,
///   ) => Err("no resources"))
///   assert_eq(media.format_name(), "hls")
///   assert_true(media.next_packet() is None)
/// }
/// ```
pub fn StreamingMedia::open(
  playlist : Bytes,
  fetch : MediaFetch,
  base_uri~ : String = "",
  prefer_x_start~ : Bool = false,
  live_start_index~ : Int32 = 0,
) -> StreamingMedia raise MediaError {
  let text = streaming_playlist_text(playlist)
  let trimmed = text.trim(chars=" \t\r\n")
  if trimmed.has_prefix("#EXTM3U") {
    let parsed = match av_hls_parse(text, base_uri~) {
      Err(e) => raise DemuxError("hls: \{e}")
      Ok(p) => p
    }
    return StreamingMedia::open_hls(
      parsed,
      fetch,
      prefer_x_start~,
      live_start_index~,
    )
  }
  if text.contains("<MPD") {
    let parsed = match av_dash_parse(text, base_uri~) {
      Err(e) => raise DemuxError("dash: \{e}")
      Ok(p) => p
    }
    return StreamingMedia::open_dash(parsed, fetch)
  }
  raise FormatNotFound
}

///|
/// ffprobe-style format name ("hls" / "dash").
pub fn StreamingMedia::format_name(self : StreamingMedia) -> String {
  self.format_name
}

///|
/// Playlist kind.
pub fn StreamingMedia::kind(self : StreamingMedia) -> StreamingKind {
  self.kind
}

///|
/// The stream table, taken from the first fetched segment. It is empty until
/// the first `next_packet`/`decode_audio` call has fetched a segment.
pub fn StreamingMedia::streams(self : StreamingMedia) -> Array[StreamInfo] {
  self.streams
}

///|
/// Declared playlist duration in seconds, when the manifest carries one.
/// Live playlists without a duration return `None`.
pub fn StreamingMedia::duration_seconds(self : StreamingMedia) -> Double? {
  self.duration
}

///|
/// Next packet across all segments, with pts on one continuous timeline, or
/// `None` when the playlist is exhausted. A `MediaFetch` failure raises
/// `DemuxError` and leaves the cursor intact, so the same segment can be
/// retried by calling again.
pub fn StreamingMedia::next_packet(
  self : StreamingMedia,
) -> StreamingPacket? raise MediaError {
  if self.finished {
    return None
  }
  for ;; {
    if self.current is None {
      self.streaming_load_segment()
      if self.finished {
        break None
      }
    }
    match self.current {
      None => break None
      Some(mf) =>
        match mf.next_packet() {
          Some(pkt) => break Some(self.streaming_normalize(pkt))
          None => self.current = None
        }
    }
  }
}

///|
/// Decode the first audio stream across every segment into one continuous
/// PCM buffer. The decoder stays alive across segment boundaries so codec
/// overlap (AAC/MP3/Opus) is preserved; a discontinuity reopens it, matching
/// FFmpeg's decoder flush on `AV_DISCONTINUITY`. Already-consumed packets are
/// not replayed - call this on a fresh session for the whole playlist.
pub fn StreamingMedia::decode_audio(
  self : StreamingMedia,
) -> DecodedAudio raise MediaError {
  // Loading a segment fills the stream table without consuming a packet.
  if self.streams.length() == 0 && self.current is None && !self.finished {
    self.streaming_load_segment()
  }
  let mut audio = -1
  for i = 0; i < self.streams.length(); i = i + 1 {
    if audio < 0 && self.streams[i].media_type == MediaType::Audio {
      audio = i
    }
  }
  if audio < 0 {
    raise UnsupportedCodec("no audio stream in \{self.format_name}")
  }
  let info = self.streams[audio]
  let mut dec = AudioDecoder::open(info)
  let rows : Array[Array[Double]] = []
  for _ch = 0; _ch < dec.channels(); _ch = _ch + 1 {
    rows.push([])
  }
  while true {
    match self.next_packet() {
      None => break
      Some(sp) => {
        if sp.stream_index != audio {
          continue
        }
        if sp.discontinuity {
          dec = AudioDecoder::open(info)
        }
        let frames = dec.decode_all({
          stream_index: sp.stream_index,
          data: sp.data,
          pts: sp.pts,
          keyframe: sp.keyframe,
        })
        for f in frames {
          for ch = 0; ch < dec.channels(); ch = ch + 1 {
            for i = 0; i < f.nb_samples; i = i + 1 {
              rows[ch].push(f.samples[ch][i])
            }
          }
        }
      }
    }
  }
  {
    samples: rows,
    sample_rate: dec.sample_rate(),
    channels: dec.channels(),
    format_name: self.format_name,
    codec_id: info.codec_id,
    duration_seconds: self.duration,
  }
}
