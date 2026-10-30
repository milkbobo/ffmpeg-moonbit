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
) -> Result[MkvAvMuxer, String] {
  if width <= 0 ||
    height <= 0 ||
    avcc.length() < 7 ||
    sample_rate <= 0 ||
    channels < 1 ||
    channels > 7 {
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
  if packet.length() == 0 || duration_ms <= 0 || pts_ms < 0L {
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
  track : Int32
  data : Bytes
  duration_ms : Int64
  keyframe : Bool
  group : Bool
}

///|
/// All blocks of the single Cluster, stably ordered by timestamp.
fn mkv_av_blocks(mux : MkvAvMuxer) -> Array[MkvAvBlock] {
  let out : Array[MkvAvBlock] = []
  for e in mux.events {
    out.push({
      pts_ms: e.pts_ms,
      track: e.track,
      data: e.data,
      duration_ms: e.duration_ms.to_int64(),
      keyframe: e.keyframe,
      group: false,
    })
  }
  for cue in mkv_subtitle_sorted(mux.cues) {
    out.push({
      pts_ms: cue.start_ms,
      track: 3,
      data: utf8_from_string(cue.text),
      duration_ms: cue.end_ms - cue.start_ms,
      keyframe: false,
      group: true,
    })
  }
  for i = 1; i < out.length(); i = i + 1 {
    let item = out[i]
    let mut j = i
    while j > 0 && out[j - 1].pts_ms > item.pts_ms {
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
    if e.group {
      let group : Array[Byte] = []
      webm_elem(group, 0xA1, 1, block) // Block
      webm_uint_elem(group, 0x9B, 1, e.duration_ms.reinterpret_as_uint64())
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

  let segment_body : Array[Byte] = []
  webm_elem(segment_body, 0x1549A966, 4, info)
  webm_elem(segment_body, 0x1654AE6B, 4, tracks)
  if self.chapters.length() > 0 {
    // The helpers return complete level-1 elements.
    for b in mkv_chapters_element(self.chapters) {
      segment_body.push(b)
    }
  }
  if self.tags.length() > 0 {
    for b in mkv_tags_element(self.tags) {
      segment_body.push(b)
    }
  }
  webm_elem(segment_body, 0x1F43B675, 4, self.cluster())
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
