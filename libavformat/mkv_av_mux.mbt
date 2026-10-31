///|
/// Minimal Matroska writer with one H.264 video track, one AAC audio track and
/// an optional `S_TEXT/UTF8` subtitle track. Packets are interleaved by
/// millisecond timestamp in a single Cluster (16-bit relative timecodes, so all
/// timestamps must stay below 32768 ms).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct MkvAvEvent {
  pts_ms : Int64
  track : Int32
  data : Bytes
  duration_ms : Int32
  keyframe : Bool
}

///|
pub struct MkvAvMuxer {
  width : Int32
  height : Int32
  avcc : Bytes
  sample_rate : Int32
  channels : Int32
  /// Audio CodecID ("A_AAC", "A_AC3", "A_EAC3") and optional CodecPrivate.
  audio_codec_id : String
  audio_private : Bytes
  /// Encoder delay/pre-skip in samples, written as TrackEntry CodecDelay.
  audio_priming : Int32
  /// Samples to discard from the end of the last audio block.
  audio_discard_padding : Int32
  events : Array[MkvAvEvent]
  cues : Array[MkvSubtitleCue]
  tags : Array[(String, String)]
  chapters : Array[MkvChapter]
}

///|
pub fn mkv_av_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  sample_rate : Int32,
  channels~ : Int32 = 2,
  audio_codec~ : String = "A_AAC",
  audio_private~ : Bytes = b"",
  audio_priming~ : Int32 = 0,
  audio_discard_padding~ : Int32 = 0,
) -> Result[MkvAvMuxer, String] {
  if width <= 0 ||
    height <= 0 ||
    avcc.length() < 7 ||
    sample_rate <= 0 ||
    channels < 1 ||
    channels > 7 ||
    audio_priming < 0 ||
    audio_discard_padding < 0 {
    return Err("EINVAL: invalid MKV A/V parameters")
  }
  Ok({
    width,
    height,
    avcc,
    sample_rate,
    channels,
    audio_codec_id: audio_codec,
    audio_private,
    audio_priming,
    audio_discard_padding,
    events: [],
    cues: [],
    tags: [],
    chapters: [],
  })
}

///|
pub fn MkvAvMuxer::write_video(
  self : MkvAvMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
  keyframe~ : Bool = false,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration_ms <= 0 || pts_ms < 0L {
    return Err("EINVAL: invalid WebM video packet")
  }
  self.events.push({ pts_ms, track: 1, data: packet, duration_ms, keyframe, })
  Ok(())
}

///|
pub fn MkvAvMuxer::write_audio(
  self : MkvAvMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  let min_pts = -self.audio_offset_ms()
  if packet.length() == 0 || duration_ms <= 0 || pts_ms < min_pts {
    return Err("EINVAL: invalid WebM audio packet")
  }
  self.events.push({
    pts_ms,
    track: 2,
    data: packet,
    duration_ms,
    keyframe: true,
  })
  Ok(())
}

///|
fn mkv_av_aac_private(mux : MkvAvMuxer) -> Bytes {
  Bytes::from_array(mp4_av_asc(mux.sample_rate, mux.channels))
}

///|
/// Set the container-level `Tags` (SimpleTag name/value pairs).
pub fn MkvAvMuxer::set_tags(
  self : MkvAvMuxer,
  tags : Array[(String, String)],
) -> Unit {
  self.tags.clear()
  for pair in tags {
    self.tags.push(pair)
  }
}

///|
/// Set the container `Chapters`.
pub fn MkvAvMuxer::set_chapters(
  self : MkvAvMuxer,
  chapters : Array[MkvChapter],
) -> Unit {
  self.chapters.clear()
  for chapter in chapters {
    self.chapters.push(chapter)
  }
}

///|
/// Add an `S_TEXT/UTF8` cue; the subtitle track is written only when at least
/// one cue exists.
pub fn MkvAvMuxer::write_subtitle(
  self : MkvAvMuxer,
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> Result[Unit, String] {
  if start_ms < 0L || end_ms < start_ms || text == "" {
    return Err("EINVAL: invalid subtitle cue")
  }
  self.cues.push(({ start_ms, end_ms, text, } : MkvSubtitleCue))
  Ok(())
}

///|
/// One cluster block: a SimpleBlock for video/audio, a BlockGroup for
/// subtitles (BlockDuration carries the cue length).
priv struct MkvAvBlock {
  pts_ms : Int64
  dts_ms : Int64
  track : Int32
  data : Bytes
  duration_ms : Int64
  keyframe : Bool
  group : Bool
  discard_padding_ns : Int64
}

///|
/// Minimal-width two's-complement EBML signed integer.
fn mkv_sint_elem(
  dst : Array[Byte],
  id : UInt32,
  id_len : Int32,
  value : Int64,
) -> Unit {
  let mut width = 1
  while width < 8 {
    let min = -(1L << (8 * width - 1))
    let max = (1L << (8 * width - 1)) - 1L
    if value >= min && value <= max {
      break
    }
    width = width + 1
  }
  let body : Array[Byte] = []
  for i in 0..<width {
    body.push(((value >> (8 * (width - 1 - i))) & 0xFFL).to_int().to_byte())
  }
  webm_elem(dst, id, id_len, body)
}

///|
/// Audio codec delay expressed in the millisecond cluster timescale, rounded
/// like av_rescale_q (AV_ROUND_NEAR_INF).
fn MkvAvMuxer::audio_offset_ms(self : MkvAvMuxer) -> Int64 {
  if self.audio_priming <= 0 || self.sample_rate <= 0 {
    0L
  } else {
    (self.audio_priming.to_int64() * 1000L + self.sample_rate.to_int64() / 2L) /
    self.sample_rate.to_int64()
  }
}

///|
/// All blocks of the single Cluster, stably ordered by timestamp.
fn mkv_av_blocks(mux : MkvAvMuxer) -> Array[MkvAvBlock] {
  let out : Array[MkvAvBlock] = []
  // Per-track decode order is preserved: blocks interleave by accumulated
  // DTS, while the SimpleBlock timecode keeps the presentation timestamp.
  let mut video_dts = 0L
  let audio_offset = mux.audio_offset_ms()
  let mut audio_dts = audio_offset
  let mut audio_total = 0
  for e in mux.events {
    if e.track == 2 {
      audio_total = audio_total + 1
    }
  }
  let mut audio_index = 0
  for e in mux.events {
    let pts = if e.track == 2 { e.pts_ms + audio_offset } else { e.pts_ms }
    let discard_ns = if e.track == 2 {
      let last = audio_index == audio_total - 1
      audio_index = audio_index + 1
      if last && mux.audio_discard_padding > 0 {
        (
          mux.audio_discard_padding.to_int64() * 1000000000L +
          mux.sample_rate.to_int64() / 2L
        ) /
        mux.sample_rate.to_int64()
      } else {
        0L
      }
    } else {
      0L
    }
    let dts = if e.track == 1 {
      let d = video_dts
      video_dts = video_dts + e.duration_ms.to_int64()
      d
    } else if e.track == 2 {
      let d = audio_dts
      audio_dts = audio_dts + e.duration_ms.to_int64()
      d
    } else {
      pts
    }
    out.push({
      pts_ms: pts,
      dts_ms: dts,
      track: e.track,
      data: e.data,
      duration_ms: e.duration_ms.to_int64(),
      keyframe: e.keyframe,
      group: false,
      discard_padding_ns: discard_ns,
    })
  }
  for cue in mkv_subtitle_sorted(mux.cues) {
    out.push({
      pts_ms: cue.start_ms,
      dts_ms: cue.start_ms,
      track: 3,
      data: utf8_from_string(cue.text),
      duration_ms: cue.end_ms - cue.start_ms,
      keyframe: false,
      group: true,
      discard_padding_ns: 0L,
    })
  }
  for i = 1; i < out.length(); i = i + 1 {
    let item = out[i]
    let mut j = i
    while j > 0 && out[j - 1].dts_ms > item.dts_ms {
      out[j] = out[j - 1]
      j = j - 1
    }
    out[j] = item
  }
  out
}

///|
fn MkvAvMuxer::cluster(self : MkvAvMuxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  for e in mkv_av_blocks(self) {
    let block : Array[Byte] = [
      if e.track == 1 {
        b'\x81'
      } else if e.track == 2 {
        b'\x82'
      } else {
        b'\x83'
      },
      ((e.pts_ms >> 8) & 0xFF).to_int().to_byte(),
      (e.pts_ms & 0xFF).to_int().to_byte(),
      if e.keyframe {
        b'\x80'
      } else {
        b'\x00'
      },
    ]
    for b in e.data {
      block.push(b)
    }
    if e.group || e.discard_padding_ns != 0L {
      let group : Array[Byte] = []
      webm_elem(group, 0xA1, 1, block) // Block
      if e.group {
        webm_uint_elem(group, 0x9B, 1, e.duration_ms.reinterpret_as_uint64())
      }
      if e.discard_padding_ns != 0L {
        mkv_sint_elem(group, 0x75A2, 2, e.discard_padding_ns)
      }
      webm_elem(cluster, 0xA0, 1, group) // BlockGroup
    } else {
      webm_elem(cluster, 0xA3, 1, block)
    }
  }
  // Keep the last child a leaf so a level ending exactly at the Cluster end
  // does not swallow a following Cluster (same workaround as the subtitle
  // writer).
  webm_elem(cluster, 0xEC, 1, [])
  cluster
}

///|
pub fn MkvAvMuxer::finish(self : MkvAvMuxer) -> Bytes {
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

  let info : Array[Byte] = []
  webm_uint_elem(info, 0x2AD7B1, 3, 1000000UL)
  webm_string_elem(info, 0x4D80, 2, "moonbit")
  webm_string_elem(info, 0x5741, 2, "moonbit")
  let mut duration = 0L
  for e in self.events {
    let end = e.pts_ms + e.duration_ms.to_int64()
    if end > duration {
      duration = end
    }
  }
  for cue in self.cues {
    if cue.end_ms > duration {
      duration = cue.end_ms
    }
  }
  webm_float_elem(info, 0x4489, 2, duration.to_double())

  let video : Array[Byte] = []
  webm_uint_elem(video, 0xB0, 1, self.width.reinterpret_as_uint().to_uint64())
  webm_uint_elem(video, 0xBA, 1, self.height.reinterpret_as_uint().to_uint64())
  let vtrack : Array[Byte] = []
  webm_uint_elem(vtrack, 0xD7, 1, 1UL)
  webm_uint_elem(vtrack, 0x73C5, 2, 1UL)
  webm_uint_elem(vtrack, 0x83, 1, 1UL)
  webm_string_elem(vtrack, 0x86, 1, "V_MPEG4/ISO/AVC")
  let avcc_body : Array[Byte] = []
  for b in self.avcc {
    avcc_body.push(b)
  }
  webm_elem(vtrack, 0x63A2, 2, avcc_body)
  webm_elem(vtrack, 0xE0, 1, video)
  webm_elem(vtrack, 0xEC, 1, [])

  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, self.sample_rate.to_double())
  webm_uint_elem(
    audio,
    0x9F,
    1,
    self.channels.reinterpret_as_uint().to_uint64(),
  )
  let atrack : Array[Byte] = []
  webm_uint_elem(atrack, 0xD7, 1, 2UL)
  webm_uint_elem(atrack, 0x73C5, 2, 2UL)
  webm_uint_elem(atrack, 0x83, 1, 2UL)
  webm_string_elem(atrack, 0x86, 1, self.audio_codec_id)
  if self.audio_priming > 0 {
    let delay_ns = (
        self.audio_priming.to_int64() * 1000000000L +
        self.sample_rate.to_int64() / 2L
      ) /
      self.sample_rate.to_int64()
    webm_uint_elem(atrack, 0x56AA, 2, delay_ns.reinterpret_as_uint64())
  }
  let private = if self.audio_private.length() > 0 {
    self.audio_private
  } else {
    mkv_av_aac_private(self)
  }
  if private.length() > 0 {
    let private_body : Array[Byte] = []
    for b in private {
      private_body.push(b)
    }
    webm_elem(atrack, 0x63A2, 2, private_body)
  }
  webm_elem(atrack, 0xE1, 1, audio)
  webm_elem(atrack, 0xEC, 1, [])

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, vtrack)
  webm_elem(tracks, 0xAE, 1, atrack)
  if self.cues.length() > 0 {
    let strack : Array[Byte] = []
    webm_uint_elem(strack, 0xD7, 1, 3UL) // TrackNumber
    webm_uint_elem(strack, 0x73C5, 2, 3UL) // TrackUID
    webm_uint_elem(strack, 0x83, 1, 17UL) // TrackType: subtitle
    webm_uint_elem(strack, 0x9C, 1, 0UL) // FlagLacing
    webm_string_elem(strack, 0x22B59C, 3, "und") // Language
    webm_string_elem(strack, 0x86, 1, "S_TEXT/UTF8")
    webm_elem(tracks, 0xAE, 1, strack)
  }
  webm_elem(tracks, 0xEC, 1, [])

  let info_elem : Array[Byte] = []
  webm_elem(info_elem, 0x1549A966, 4, info)
  let tracks_elem : Array[Byte] = []
  webm_elem(tracks_elem, 0x1654AE6B, 4, tracks)
  let mid : Array[Array[Byte]] = []
  if self.chapters.length() > 0 {
    // The helpers return complete level-1 elements.
    mid.push(mkv_chapters_element(self.chapters))
  }
  if self.tags.length() > 0 {
    mid.push(mkv_tags_element(self.tags))
  }
  let cluster_body = self.cluster()
  let cluster_elem : Array[Byte] = []
  webm_elem(cluster_elem, 0x1F43B675, 4, cluster_body)
  let key_times : Array[Int64] = []
  for e in self.events {
    if e.track == 1 && e.keyframe {
      key_times.push(e.pts_ms)
    }
  }
  let (seekhead, cues) = mkv_seekhead_cues_mid(
    info_elem, tracks_elem, mid, cluster_elem, key_times,
  )
  let segment_body : Array[Byte] = []
  for part in [seekhead, info_elem, tracks_elem] {
    for b in part {
      segment_body.push(b)
    }
  }
  for part in mid {
    for b in part {
      segment_body.push(b)
    }
  }
  for part in [cluster_elem, cues] {
    for b in part {
      segment_body.push(b)
    }
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

///|
/// H.264 + AC-3 A/V Matroska muxer.
pub fn mkv_av_ac3_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  sample_rate : Int32,
  channels : Int32,
) -> Result[MkvAvMuxer, String] {
  mkv_av_muxer_new(
    width,
    height,
    avcc,
    sample_rate,
    channels~,
    audio_codec="A_AC3",
  )
}

///|
/// H.264 + E-AC-3 A/V Matroska muxer.
pub fn mkv_av_eac3_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  sample_rate : Int32,
  channels : Int32,
) -> Result[MkvAvMuxer, String] {
  mkv_av_muxer_new(
    width,
    height,
    avcc,
    sample_rate,
    channels~,
    audio_codec="A_EAC3",
  )
}
