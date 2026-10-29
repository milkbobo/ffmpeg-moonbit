///|
/// Minimal subtitle-only Matroska writer: one `S_TEXT/UTF8` track (TrackType
/// 17) and Clusters of BlockGroups carrying each cue's text and duration.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One subtitle cue: start/end milliseconds and the UTF-8 text payload (no
/// trailing newline, like SRT cue text).
pub struct MkvSubtitleCue {
  start_ms : Int64
  end_ms : Int64
  text : String
}

///|
/// Construct a cue for `MkvSubtitleMuxer::write_cue`.
pub fn mkv_subtitle_cue_new(
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> MkvSubtitleCue {
  { start_ms, end_ms, text, }
}

///|
/// One `S_TEXT/UTF8` subtitle track.
pub struct MkvSubtitleMuxer {
  cues : Array[MkvSubtitleCue]
}

///|
/// New subtitle writer with an empty cue list.
pub fn mkv_subtitle_muxer_new() -> MkvSubtitleMuxer {
  { cues: [], }
}

///|
/// Add one cue; `end_ms >= start_ms` and non-empty text are required.
pub fn MkvSubtitleMuxer::write_cue(
  self : MkvSubtitleMuxer,
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> Result[Unit, String] {
  if start_ms < 0L || end_ms < start_ms || text == "" {
    return Err("EINVAL: invalid subtitle cue")
  }
  self.cues.push({ start_ms, end_ms, text, })
  Ok(())
}

///|
fn mkv_subtitle_sorted(cues : Array[MkvSubtitleCue]) -> Array[MkvSubtitleCue] {
  let out = cues.copy()
  for i in 1..<out.length() {
    let item = out[i]
    let mut j = i
    while j > 0 && out[j - 1].start_ms > item.start_ms {
      out[j] = out[j - 1]
      j = j - 1
    }
    out[j] = item
  }
  out
}

///|
/// One Cluster for `cues`: `Timecode` = the first cue's start, each cue a
/// BlockGroup (Block + BlockDuration) with a 16-bit relative timecode.
fn mkv_subtitle_cluster(
  cues : Array[MkvSubtitleCue],
  base_ms : Int64,
) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, base_ms.reinterpret_as_uint64())
  for cue in cues {
    let rel = cue.start_ms - base_ms
    let block : Array[Byte] = [
      b'\x81',
      ((rel >> 8) & 0xFF).to_int().to_byte(),
      (rel & 0xFF).to_int().to_byte(),
      b'\x00',
    ]
    for b in utf8_from_string(cue.text) {
      block.push(b)
    }
    let group : Array[Byte] = []
    webm_elem(group, 0xA1, 1, block) // Block
    webm_uint_elem(
      group,
      0x9B,
      1,
      (cue.end_ms - cue.start_ms).reinterpret_as_uint64(),
    ) // BlockDuration
    webm_elem(cluster, 0xA0, 1, group) // BlockGroup
  }
  // The demuxer's level-end pop removes a nested master's level together with
  // any parent ending at the same offset, so a Cluster whose last child is a
  // BlockGroup can swallow the next Cluster. Ending with a leaf Void keeps
  // the Cluster end unambiguous for readers (FFmpeg's own Clusters end with a
  // SimpleBlock for the same reason).
  webm_elem(cluster, 0xEC, 1, [])
  cluster
}

///|
/// Build the complete `matroska` document: EBML header, Info (timecode scale,
/// duration), the subtitle track and one Cluster per 30 s span.
pub fn MkvSubtitleMuxer::finish(self : MkvSubtitleMuxer) -> Bytes {
  let header_body : Array[Byte] = []
  webm_uint_elem(header_body, 0x4286, 2, 1UL)
  webm_uint_elem(header_body, 0x42F7, 2, 1UL)
  webm_uint_elem(header_body, 0x42F2, 2, 4UL)
  webm_uint_elem(header_body, 0x42F3, 2, 8UL)
  webm_string_elem(header_body, 0x4282, 2, "matroska")
  webm_uint_elem(header_body, 0x4287, 2, 4UL)
  webm_uint_elem(header_body, 0x4285, 2, 2UL)
  let ebml : Array[Byte] = []
  webm_elem(ebml, 0x1A45DFA3, 4, header_body)

  let cues = mkv_subtitle_sorted(self.cues)
  let mut duration = 0L
  for cue in cues {
    if cue.end_ms > duration {
      duration = cue.end_ms
    }
  }
  let info : Array[Byte] = []
  webm_uint_elem(info, 0x2AD7B1, 3, 1000000UL)
  webm_string_elem(info, 0x4D80, 2, "moonbit")
  webm_string_elem(info, 0x5741, 2, "moonbit")
  webm_float_elem(info, 0x4489, 2, duration.to_double())

  let track : Array[Byte] = []
  webm_uint_elem(track, 0xD7, 1, 1UL) // TrackNumber
  webm_uint_elem(track, 0x73C5, 2, 1UL) // TrackUID
  webm_uint_elem(track, 0x83, 1, 17UL) // TrackType: subtitle
  webm_uint_elem(track, 0x9C, 1, 0UL) // FlagLacing
  webm_string_elem(track, 0x22B59C, 3, "und") // Language
  webm_string_elem(track, 0x86, 1, "S_TEXT/UTF8") // CodecID
  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, track)
  webm_elem(tracks, 0xEC, 1, [])

  let segment_body : Array[Byte] = []
  webm_elem(segment_body, 0x1549A966, 4, info)
  webm_elem(segment_body, 0x1654AE6B, 4, tracks)
  // SimpleBlock timecodes are 16-bit: start a new Cluster every 30 s.
  let mut group : Array[MkvSubtitleCue] = []
  let mut base : Int64 = 0L
  for cue in cues {
    if group.length() > 0 && cue.start_ms - base > 30000L {
      webm_elem(segment_body, 0x1F43B675, 4, mkv_subtitle_cluster(group, base))
      group = []
    }
    if group.length() == 0 {
      base = cue.start_ms
    }
    group.push(cue)
  }
  if group.length() > 0 {
    webm_elem(segment_body, 0x1F43B675, 4, mkv_subtitle_cluster(group, base))
  }
  let segment : Array[Byte] = []
  webm_elem(segment, 0x18538067, 4, segment_body)
  let out : Array[Byte] = []
  for b in ebml {
    out.push(b)
  }
  for b in segment {
    out.push(b)
  }
  Bytes::from_array(out)
}
