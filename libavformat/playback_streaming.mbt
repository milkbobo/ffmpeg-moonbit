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
  mut reader : StreamingReader
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
  /// The variant URI chosen from a master playlist; None for media playlists
  /// and DASH sessions.
  mut variant_uri : String?
  duration : Double?
  mut finished : Bool
  /// Live (no ENDLIST) HLS sessions may be refreshed with `reload`.
  mut is_live : Bool
  /// Optional application hook that re-fetches the media playlist bytes.
  /// Left as a callback (rather than doing IO here) so the caller controls
  /// polling/backoff, exactly like `MediaFetch` for segment resources.
  mut playlist_fetch : MediaFetch?
  /// URI passed to `playlist_fetch` when refreshing a live playlist.
  mut playlist_uri : String
  /// Remaining automatic refresh attempts; 0 disables auto-refresh.
  mut reload_budget : Int32
  /// Number of successful `reload` calls, for observability/tests.
  mut reload_count : Int32
  /// Selected DASH Period/AdaptationSet/Representation. Kept so a refreshed
  /// MPD resumes on the same representation instead of re-guessing.
  mut dash_period : Int32
  mut dash_adaptation_set : Int32
  mut dash_representation : Int32
  /// Start time and duration of the last DASH segment emitted, both in the
  /// representation's timescale. A refreshed MPD resumes strictly after
  /// `last_time + last_duration`.
  mut dash_last_time : Int64
  mut dash_last_duration : Int64
  /// The refreshed window skipped segments that expired before we got to
  /// them; the next emitted segment is flagged as a discontinuity.
  mut dash_gap : Bool
  /// The MPD this session was opened from, kept so playback can continue into
  /// the next Period. Replaced by `reload_dash`.
  mut dash_mpd : DashMpd?
  /// HLS variant that declares `EXT-X-MEDIA:TYPE=AUDIO` keeps its audio in a
  /// separate rendition playlist; this is that playlist's own session.
  mut audio_track : StreamingMedia?
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
/// Normalize MP4/MOV sample-entry fourccs into FFmpeg codec names. The file
/// facade's `Mov` branch leaves fourccs such as `avc1` / `hvc1` in
/// `StreamInfo.codec_id`, but `VideoDecoder::open` expects `h264` / `hevc`.
/// Applied only to the streaming stream table so the existing file container
/// contract (and its tests) stay untouched; unknown names pass through
/// unchanged via `mov_codec_name`'s default arm.
fn streaming_normalize_codecs(streams : Array[StreamInfo]) -> Array[StreamInfo] {
  let out : Array[StreamInfo] = []
  for s in streams {
    let name = mov_codec_name(s.codec_id, "")
    out.push({ ..s, codec_id: name, })
  }
  out
}

///|
/// Fetch the next segment and hand its bytes to the existing demuxer. A
/// reader error leaves every cursor untouched, so the same segment is retried
/// on the next call (the C readers already guarantee this).
fn StreamingMedia::streaming_load_segment(
  self : StreamingMedia,
) -> Unit raise MediaError {
  // A live window can be extended by the application. Retry in a loop (not
  // recursively) so a large refresh budget cannot grow the stack; each
  // successful refresh consumes one budget unit.
  let segment = for ;; {
    let next = match self.reader {
      HlsReader(r) => r.next()
      DashReader(r) => r.next()
    }
    match next {
      Err(e) => raise DemuxError("streaming: \{e}")
      Ok(Some(s)) => break s
      Ok(None) => {
        // A multi-Period MPD continues into the next Period before the
        // session is allowed to end; a live window then gets a refresh.
        if self.kind == Dash && self.streaming_advance_period() {
          continue
        }
        if self.streaming_auto_reload() {
          continue
        }
        self.finished = true
        self.current = None
        return
      }
    }
  }
  let mf = MediaFile::open(segment.bytes())
  if self.streams.length() == 0 {
    self.streams = streaming_normalize_codecs(mf.streams())
  }
  // Remember where this DASH segment sits on the representation's timeline so
  // a refreshed MPD can resume after it.
  match self.reader {
    DashReader(r) => {
      self.dash_last_time = r.last_time()
      self.dash_last_duration = r.last_duration()
    }
    HlsReader(_) => ()
  }
  let mut discontinuity = segment.discontinuity
  if self.dash_gap {
    // The refreshed window skipped segments we never played; the decoder has
    // to be reset or the timeline would silently bridge the hole.
    discontinuity = true
    self.dash_gap = false
  }
  self.current = Some(mf)
  self.current_sequence = segment.sequence
  self.current_discontinuity = discontinuity
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
      Some(last) => {
        // A segment carrying a single packet has no observable intra-segment
        // step (for example one AAC frame per TS segment with PES pts=0).
        // Fall back to one container tick so the timeline still advances
        // instead of stalling every later segment at the same pts.
        let step = if self.last_step[s] > 0L { self.last_step[s] } else { 1L }
        streaming_sat_sub(streaming_sat_add(last, step), pkt.pts)
      }
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
    variant_uri: None,
    duration,
    finished: false,
    is_live: false,
    playlist_fetch: None,
    playlist_uri: "",
    reload_budget: 0,
    reload_count: 0,
    dash_period: 0,
    dash_adaptation_set: 0,
    dash_representation: 0,
    dash_last_time: -1L,
    dash_last_duration: 0L,
    dash_gap: false,
    dash_mpd: None,
    audio_track: None,
  }
}

///|
/// Replace the live HLS media playlist and resume reading. `reload` keeps
/// the normalized timeline, stream table and decoder-relevant state intact:
/// only the segment cursor moves, following `HlsSegmentReader::reload`'s
/// overlap/expiry rules. A rejected playlist leaves the session untouched so
/// the caller can retry. DASH sessions and VOD playlists are refused.
pub fn StreamingMedia::reload(
  self : StreamingMedia,
  playlist : HlsPlaylist,
) -> Unit raise MediaError {
  if self.kind != Hls {
    raise DemuxError("reload: only HLS sessions can be reloaded")
  }
  if playlist.is_master {
    raise DemuxError("reload: expected a media playlist")
  }
  let reader = match self.reader {
    HlsReader(r) => r
    DashReader(_) =>
      raise DemuxError("reload: only HLS sessions can be reloaded")
  }
  match reader.reload(playlist) {
    Err(e) => raise DemuxError("reload: \{e}")
    Ok(_) => ()
  }
  // The old segment was fully drained before reload was requested, so no
  // packet is lost. Keep last_pts/last_step: the new window must continue on
  // the same monotonic timeline.
  self.current = None
  self.streaming_reset_segment()
  self.finished = false
  self.reload_count += 1
}

///|
/// Parse and install a refreshed media playlist from raw bytes. `base_uri`
/// resolves relative segment URIs; pass the playlist's own absolute URI (same
/// value used at `open`) so URI resolution stays stable across refreshes.
pub fn StreamingMedia::reload_bytes(
  self : StreamingMedia,
  playlist : Bytes,
  base_uri~ : String = "",
) -> Unit raise MediaError {
  let parsed = match
    av_hls_parse(streaming_playlist_text(playlist), base_uri~) {
    Ok(p) => p
    Err(e) => raise DemuxError("reload: \{e}")
  }
  self.reload(parsed)
}

///|
/// True for an HLS media playlist without `EXT-X-ENDLIST` or a DASH MPD with
/// `type="dynamic"`. Only such sessions can be usefully refreshed; VOD
/// presentations always end at their last segment.
pub fn StreamingMedia::is_live(self : StreamingMedia) -> Bool {
  self.is_live
}

///|
/// Index of the AdaptationSet in `sets` that continues `current`: an exact
/// content-type+codecs match wins, then a MIME-type match, and only then the
/// same position - and only when that position carries the same content type,
/// so a Period with nothing but subtitles cannot silently turn the session
/// into a subtitle reader. `None` means playback should stop at that Period.
fn dash_period_match_set(
  sets : Array[DashAdaptationSet],
  current : DashAdaptationSet,
  fallback : Int32,
) -> Int32? {
  for i = 0; i < sets.length(); i = i + 1 {
    if sets[i].content_type == current.content_type &&
      sets[i].codecs == current.codecs {
      return Some(i)
    }
  }
  if current.mime_type != "" {
    for i = 0; i < sets.length(); i = i + 1 {
      if sets[i].mime_type == current.mime_type {
        return Some(i)
      }
    }
  }
  if fallback >= 0 && fallback < sets.length() &&
    sets[fallback].content_type == current.content_type {
    Some(fallback)
  } else {
    None
  }
}

///|
/// Index of the Representation inside a Period's set that continues the
/// current one: the same codec at the same position is preferred, then the
/// first same-codec entry, then position 0.
fn dash_period_match_representation(
  reps : Array[DashRepresentation],
  codec : String,
  fallback : Int32,
) -> Int32 {
  if fallback >= 0 && fallback < reps.length() && reps[fallback].codec == codec {
    return fallback
  }
  for i = 0; i < reps.length(); i = i + 1 {
    if reps[i].codec == codec {
      return i
    }
  }
  0
}

///|
/// Run the stream table through `DashMpd`'s Period chain: when the selected
/// Period runs out of segments, move to the next one that carries a matching
/// AdaptationSet. Returns false when there is no next Period, in which case
/// the caller falls back to live refresh / end of stream.
///
/// Every Period starts its own media timeline, so the continuation is flagged
/// as a discontinuity (FFmpeg's `dashdec` does the same unless the MPD
/// declares timestamp continuity) and the segment cursor is reset.
fn StreamingMedia::streaming_advance_period(
  self : StreamingMedia,
) -> Bool {
  let mpd = match self.dash_mpd {
    None => return false
    Some(m) => m
  }
  let next = self.dash_period + 1
  if next >= mpd.periods.length() {
    return false
  }
  let current_sets = mpd.periods[self.dash_period].adaptation_sets
  if self.dash_adaptation_set < 0 ||
    self.dash_adaptation_set >= current_sets.length() {
    return false
  }
  let current = current_sets[self.dash_adaptation_set]
  let sets = mpd.periods[next].adaptation_sets
  let set_index = match
    dash_period_match_set(sets, current, self.dash_adaptation_set) {
    None => return false
    Some(i) => i
  }
  let reps = sets[set_index].representations
  if reps.length() == 0 || current.representations.length() == 0 {
    return false
  }
  let current_rep = current.representations[
    if self.dash_representation >= 0 &&
      self.dash_representation < current.representations.length() {
      self.dash_representation
    } else {
      0
    }
  ]
  let rep_index = dash_period_match_representation(
    reps,
    current_rep.codec,
    self.dash_representation,
  )
  let fetch = match self.reader {
    DashReader(r) => r.fetch
    HlsReader(_) => return false
  }
  self.reader = DashReader(dash_segment_reader_new(reps[rep_index], fetch))
  self.dash_period = next
  self.dash_adaptation_set = set_index
  self.dash_representation = rep_index
  self.dash_last_time = -1L
  self.dash_last_duration = 0L
  // A Period boundary restarts the media timeline.
  self.dash_gap = true
  self.current = None
  self.streaming_reset_segment()
  self.finished = false
  true
}

///|
/// Number of successful playlist reloads on this session.
pub fn StreamingMedia::reload_count(self : StreamingMedia) -> Int32 {
  self.reload_count
}

///|
/// Index of the DASH Period currently being played. Multi-Period MPDs advance
/// here on their own once a Period runs out of segments; HLS sessions stay
/// at 0.
pub fn StreamingMedia::period_index(self : StreamingMedia) -> Int32 {
  self.dash_period
}

///|
/// Replace the live DASH MPD and resume reading. The selected
/// Period/AdaptationSet/Representation is kept unless overridden, segments
/// already emitted are skipped by start time (so a refreshed sliding window
/// neither repeats nor loses packets), and a window that dropped segments in
/// between is flagged as a discontinuity on the next emitted segment. A
/// rejected MPD leaves the session untouched so the caller can retry.
///
/// A refreshed window that lists nothing new is not an error: the cursor
/// simply stays at the end and `next_packet` reports `None` again, matching
/// FFmpeg's `dashdec` polling behaviour.
pub fn StreamingMedia::reload_dash(
  self : StreamingMedia,
  mpd : DashMpd,
  period~ : Int32 = -1,
  adaptation_set~ : Int32 = -1,
  representation~ : Int32 = -1,
) -> Unit raise MediaError {
  if self.kind != Dash {
    raise DemuxError("reload_dash: only DASH sessions can be reloaded")
  }
  let fetch = match self.reader {
    DashReader(r) => r.fetch
    HlsReader(_) =>
      raise DemuxError("reload_dash: only DASH sessions can be reloaded")
  }
  let p = if period >= 0 { period } else { self.dash_period }
  let a = if adaptation_set >= 0 { adaptation_set } else {
    self.dash_adaptation_set
  }
  let r = if representation >= 0 { representation } else {
    self.dash_representation
  }
  if p < 0 || p >= mpd.periods.length() {
    raise DemuxError("dash: period index out of range")
  }
  let sets = mpd.periods[p].adaptation_sets
  if a < 0 || a >= sets.length() {
    raise DemuxError("dash: adaptation set index out of range")
  }
  let reps = sets[a].representations
  if r < 0 || r >= reps.length() {
    raise DemuxError("dash: representation index out of range")
  }
  if reps[r].segments.length() == 0 {
    // Single-file SegmentBase representations address one static resource by
    // byte index; there is no segment list to continue through.
    raise DemuxError("reload_dash: representation lists no segments")
  }
  let fresh = dash_segment_reader_new(reps[r], fetch)
  // Resume strictly after the last segment we played. `None` means the whole
  // window is already behind us - keep the cursor parked at the end.
  let next_time = fresh.skip_through_time(self.dash_last_time)
  let gap = match next_time {
    None => false
    Some(t) => {
      if self.dash_last_time < 0L {
        false
      } else {
        let expected = streaming_sat_add(
          self.dash_last_time,
          self.dash_last_duration,
        )
        t > expected
      }
    }
  }
  self.reader = DashReader(fresh)
  self.dash_period = p
  self.dash_adaptation_set = a
  self.dash_representation = r
  self.dash_mpd = Some(mpd)
  // Sticky: a second refresh must not clear a gap the first one detected
  // before the decoder has actually been reset.
  self.dash_gap = self.dash_gap || gap
  self.current = None
  self.streaming_reset_segment()
  self.finished = false
  self.reload_count += 1
}

///|
/// Try one automatic refresh using the hook supplied at `open`. Returns true
/// when the playlist/MPD was successfully replaced. A fetch/parse failure is
/// mapped to `DemuxError` (the caller can retry the same `next_packet` call).
/// Exhausting the budget is not an error: the session just ends.
fn StreamingMedia::streaming_auto_reload(
  self : StreamingMedia,
) -> Bool raise MediaError {
  if !self.is_live || self.reload_budget <= 0 {
    return false
  }
  match self.playlist_fetch {
    None => false
    Some(fetch) => {
      let data = match fetch(self.playlist_uri, 0L, -1L) {
        Ok(v) => v
        Err(e) => raise DemuxError("reload: control fetch failed: \{e}")
      }
      if self.kind == Dash {
        let parsed = match
          av_dash_parse(
            streaming_playlist_text(data),
            base_uri=self.playlist_uri,
          ) {
          Ok(p) => p
          Err(e) => raise DemuxError("reload: \{e}")
        }
        self.reload_dash(parsed)
      } else {
        let parsed = match
          av_hls_parse(
            streaming_playlist_text(data),
            base_uri=self.playlist_uri,
          ) {
          Ok(p) => p
          Err(e) => raise DemuxError("reload: \{e}")
        }
        if parsed.is_master {
          raise DemuxError("reload: refreshed playlist must be a media playlist")
        }
        self.reload(parsed)
      }
      self.reload_budget -= 1
      true
    }
  }
}

///|
/// Pick a playable variant from an HLS master playlist. I-frame-only
/// renditions are skipped because they cannot be played standalone. By
/// default the highest-bandwidth variant wins, matching FFmpeg's
/// `hls_read_header` selection when no bandwidth cap is configured;
/// `variant` overrides it with an explicit index into `playlist.streams`.
fn streaming_pick_variant(
  playlist : HlsPlaylist,
  variant : Int32?,
) -> HlsStreamInfo raise MediaError {
  let streams = playlist.streams
  let index = match variant {
    Some(i) => {
      if i < 0 || i >= streams.length() {
        raise DemuxError("hls: variant index out of range")
      }
      i
    }
    None => {
      let mut best = -1
      let mut best_bandwidth = -1L
      for i = 0; i < streams.length(); i = i + 1 {
        let s = streams[i]
        if !s.is_i_frame && s.uri != "" && s.bandwidth > best_bandwidth {
          best = i
          best_bandwidth = s.bandwidth
        }
      }
      if best < 0 {
        raise DemuxError("hls: master playlist has no playable variant")
      }
      best
    }
  }
  let chosen = streams[index]
  if chosen.is_i_frame {
    raise DemuxError("hls: selected variant is I-frame only")
  }
  if chosen.uri == "" {
    raise DemuxError("hls: selected variant has an empty URI")
  }
  chosen
}

///|
/// Pick the audio rendition a variant's `AUDIO=` group names: a URI-bearing
/// `TYPE=AUDIO` member of that group, preferring `DEFAULT=YES`. Returns `None`
/// when the variant declares no group, or when the group only holds muxed
/// (`URI`-less) entries that cannot be opened on their own.
fn streaming_pick_audio_rendition(
  master : HlsPlaylist,
  group : String,
) -> HlsRendition? {
  if group == "" {
    return None
  }
  let mut fallback : HlsRendition? = None
  for r in master.renditions {
    if r.type_ == "AUDIO" && r.group_id == group && r.uri != "" {
      if r.is_default {
        return Some(r)
      }
      if fallback is None {
        fallback = Some(r)
      }
    }
  }
  fallback
}

///|
/// Resolve a master playlist to one media playlist. The variant's absolute
/// URI becomes the base for the child playlist's relative segment URIs, so
/// `MediaFetch` sees exactly the same URIs `av_hls_parse` resolved. Only one
/// level of master indirection is allowed; a nested master is refused rather
/// than followed (it would be an unbounded fetch loop controlled by the server).
///
/// A variant that declares `AUDIO="group"` gets its audio from a separate
/// `EXT-X-MEDIA` rendition playlist (FFmpeg's `hls_read_header` resolves the
/// same way): that rendition is opened as its own session and `decode_audio`
/// follows it. `av_hls_parse` has already resolved the rendition URI against
/// the master's base URI, so it is used as-is.
fn streaming_open_master(
  master : HlsPlaylist,
  fetch : MediaFetch,
  variant~ : Int32?,
  prefer_x_start~ : Bool,
  live_start_index~ : Int32,
  playlist_fetch~ : MediaFetch?,
  max_reloads~ : Int32,
) -> StreamingMedia raise MediaError {
  let chosen = streaming_pick_variant(master, variant)
  let data = match fetch(chosen.uri, 0L, -1L) {
    Ok(v) => v
    Err(e) => raise DemuxError("hls: variant fetch failed: \{e}")
  }
  let media = match
    av_hls_parse(streaming_playlist_text(data), base_uri=chosen.uri) {
    Ok(p) => p
    Err(e) => raise DemuxError("hls: variant playlist: \{e}")
  }
  if media.is_master {
    raise DemuxError("hls: nested master playlists are not supported")
  }
  let session = StreamingMedia::open_hls(
    media,
    fetch,
    prefer_x_start~,
    live_start_index~,
    playlist_fetch~,
    // A live variant refreshes its own media playlist, never the master.
    playlist_uri=chosen.uri,
    max_reloads~,
  )
  session.variant_uri = Some(chosen.uri)
  match streaming_pick_audio_rendition(master, chosen.audio) {
    None => ()
    Some(rendition) => {
      let url = rendition.uri
      let audio_bytes = match fetch(url, 0L, -1L) {
        Ok(v) => v
        Err(e) => raise DemuxError("hls: audio rendition fetch failed: \{e}")
      }
      let audio_playlist = match
        av_hls_parse(streaming_playlist_text(audio_bytes), base_uri=url) {
        Ok(p) => p
        Err(e) => raise DemuxError("hls: audio rendition playlist: \{e}")
      }
      if audio_playlist.is_master {
        raise DemuxError("hls: nested master playlists are not supported")
      }
      session.audio_track = Some(
        StreamingMedia::open_hls(
          audio_playlist,
          fetch,
          prefer_x_start~,
          live_start_index~,
          playlist_fetch~,
          playlist_uri=url,
          max_reloads~,
        ),
      )
    }
  }
  session
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
  playlist_fetch~ : MediaFetch? = None,
  playlist_uri~ : String = "",
  max_reloads~ : Int32 = 0,
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
  let session = streaming_from_reader(Hls, "hls", HlsReader(reader), duration)
  session.is_live = !playlist.endlist
  session.playlist_fetch = playlist_fetch
  session.playlist_uri = if playlist_uri != "" {
    playlist_uri
  } else {
    "live.m3u8"
  }
  session.reload_budget = if max_reloads > 0 && session.is_live {
    max_reloads
  } else {
    0
  }
  session
}

///|
/// Open one DASH representation. The three indexes select a Period,
/// AdaptationSet and Representation of the parsed MPD; out-of-range values
/// raise `DemuxError` rather than being silently clamped.
///
/// A `type="dynamic"` MPD opens as a live session: `is_live()` is true and
/// `reload_dash` (or the optional `mpd_fetch~` automatic refresh) can extend
/// the window. Static MPDs end at their last segment.
pub fn StreamingMedia::open_dash(
  mpd : DashMpd,
  fetch : MediaFetch,
  period~ : Int32 = 0,
  adaptation_set~ : Int32 = 0,
  representation~ : Int32 = 0,
  mpd_fetch~ : MediaFetch? = None,
  mpd_uri~ : String = "",
  max_reloads~ : Int32 = 0,
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
  let session = streaming_from_reader(Dash, "dash", DashReader(reader), duration)
  session.dash_period = period
  session.dash_adaptation_set = adaptation_set
  session.dash_representation = representation
  session.dash_mpd = Some(mpd)
  session.is_live = mpd.type_ == "dynamic"
  session.playlist_fetch = mpd_fetch
  session.playlist_uri = mpd_uri
  session.reload_budget = if max_reloads > 0 && session.is_live {
    max_reloads
  } else {
    0
  }
  session
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
  variant~ : Int32? = None,
  playlist_fetch~ : MediaFetch? = None,
  max_reloads~ : Int32 = 0,
) -> StreamingMedia raise MediaError {
  let text = streaming_playlist_text(playlist)
  let trimmed = text.trim(chars=" \t\r\n")
  if trimmed.has_prefix("#EXTM3U") {
    let parsed = match av_hls_parse(text, base_uri~) {
      Err(e) => raise DemuxError("hls: \{e}")
      Ok(p) => p
    }
    if parsed.is_master {
      return streaming_open_master(
        parsed,
        fetch,
        variant~,
        prefer_x_start~,
        live_start_index~,
        playlist_fetch~,
        max_reloads~,
      )
    }
    return StreamingMedia::open_hls(
      parsed,
      fetch,
      prefer_x_start~,
      live_start_index~,
      playlist_fetch~,
      playlist_uri=if base_uri != "" { base_uri } else { "live.m3u8" },
      max_reloads~,
    )
  }
  if text.contains("<MPD") {
    let parsed = match av_dash_parse(text, base_uri~) {
      Err(e) => raise DemuxError("dash: \{e}")
      Ok(p) => p
    }
    return StreamingMedia::open_dash(
      parsed,
      fetch,
      mpd_fetch=playlist_fetch,
      mpd_uri=base_uri,
      max_reloads~,
    )
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
/// The variant URI chosen from a master playlist, or `None` when the input
/// was already a media playlist or a DASH MPD.
pub fn StreamingMedia::variant_uri(self : StreamingMedia) -> String? {
  self.variant_uri
}

///|
/// The separate `EXT-X-MEDIA` audio rendition this session's variant delegates
/// to, or `None` when the variant carries its own audio. `decode_audio`
/// already follows it with the default `DEFAULT=YES` rendition; this accessor
/// is for callers that want to drive another rendition or inspect the track.
pub fn StreamingMedia::audio_track(self : StreamingMedia) -> StreamingMedia? {
  self.audio_track
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
  // A variant that delegates its audio to an `EXT-X-MEDIA` rendition has no
  // audio stream of its own; follow the rendition so `decode_audio` returns
  // actual PCM instead of `UnsupportedCodec`.
  match self.audio_track {
    Some(track) => return track.decode_audio()
    None => ()
  }
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

///|
/// Decode the first video stream across every segment into pictures in
/// presentation order. Decoder state (reference frames, CABAC contexts and
/// the H.264 reorder buffer) survives segment boundaries. On a discontinuity
/// the pending batch is flushed and the decoder is rebuilt, matching
/// FFmpeg's `AV_DISCONTINUITY` reset; the trailing `finish_video` drains
/// HEVC's batch and any held-back reorder pictures at end of stream.
/// Already-consumed packets are not replayed - call this on a fresh session.
pub fn StreamingMedia::decode_video(
  self : StreamingMedia,
) -> Array[VideoFrame] raise MediaError {
  // Loading a segment fills the stream table without consuming a packet.
  if self.streams.length() == 0 && self.current is None && !self.finished {
    self.streaming_load_segment()
  }
  let mut video = -1
  for i = 0; i < self.streams.length(); i = i + 1 {
    if video < 0 && self.streams[i].media_type == MediaType::Video {
      video = i
    }
  }
  if video < 0 {
    raise UnsupportedCodec("no video stream in \{self.format_name}")
  }
  let info = self.streams[video]
  let mut dec = VideoDecoder::open(info)
  let frames : Array[VideoFrame] = []
  while true {
    match self.next_packet() {
      None => break
      Some(sp) => {
        if sp.stream_index != video {
          continue
        }
        if sp.discontinuity {
          // HEVC buffers every packet until finish_video; dropping that
          // batch on a reset would silently lose the previous segment's
          // pictures.
          for f in dec.finish_video() {
            frames.push(f)
          }
          dec = VideoDecoder::open(info)
        }
        for
          f in dec.decode({
            stream_index: sp.stream_index,
            data: sp.data,
            pts: sp.pts,
            keyframe: sp.keyframe,
          }) {
          frames.push(f)
        }
      }
    }
  }
  for f in dec.finish_video() {
    frames.push(f)
  }
  frames
}
