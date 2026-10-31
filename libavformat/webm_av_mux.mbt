///|
/// Minimal WebM writer with one VP9 video track and one Opus audio track.
/// Packets are interleaved by millisecond timestamp in a single Cluster.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct WebmAvEvent {
  pts_ms : Int64
  track : Int32
  data : Bytes
  duration_ms : Int32
  keyframe : Bool
}

///|
pub struct WebmAvMuxer {
  width : Int32
  height : Int32
  channels : Int32
  pre_skip : Int32
  /// Samples to discard from the end of the last Opus block.
  audio_discard_padding : Int32
  events : Array[WebmAvEvent]
}

///|
pub fn webm_av_muxer_new(
  width : Int32,
  height : Int32,
  channels~ : Int32 = 2,
  pre_skip~ : Int32 = 0,
  audio_discard_padding~ : Int32 = 0,
) -> Result[WebmAvMuxer, String] {
  if width <= 0 ||
    height <= 0 ||
    channels < 1 ||
    channels > 2 ||
    pre_skip < 0 ||
    audio_discard_padding < 0 {
    return Err("EINVAL: invalid WebM A/V parameters")
  }
  Ok({ width, height, channels, pre_skip, audio_discard_padding, events: [], })
}

///|
pub fn WebmAvMuxer::write_video(
  self : WebmAvMuxer,
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
pub fn WebmAvMuxer::write_audio(
  self : WebmAvMuxer,
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
/// Opus pre-skip rescaled to the millisecond cluster timescale (48 kHz),
/// rounded half away from zero like the Opus-only writer.
fn WebmAvMuxer::audio_offset_ms(self : WebmAvMuxer) -> Int64 {
  if self.pre_skip <= 0 {
    0L
  } else {
    (self.pre_skip.to_int64() * 1000L + 24000L) / 48000L
  }
}

///|
fn webm_av_opus_head(mux : WebmAvMuxer) -> Bytes {
  let head : Array[Byte] = []
  for b in b"OpusHead" {
    head.push(b)
  }
  head.push(b'\x01')
  head.push(mux.channels.to_byte())
  head.push((mux.pre_skip & 0xFF).to_byte())
  head.push(((mux.pre_skip >> 8) & 0xFF).to_byte())
  for i in 0..<4 {
    head.push(((48000 >> (8 * i)) & 0xFF).to_byte())
  }
  head.push(b'\x00')
  head.push(b'\x00')
  head.push(b'\x00')
  Bytes::from_array(head)
}

///|
fn webm_av_sorted(events : Array[WebmAvEvent]) -> Array[WebmAvEvent] {
  let out = events.copy()
  for i in 1..<out.length() {
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
fn WebmAvMuxer::cluster(self : WebmAvMuxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  let audio_offset = self.audio_offset_ms()
  let sorted = webm_av_sorted(self.events)
  let mut audio_left = 0
  for e in sorted {
    if e.track == 2 {
      audio_left = audio_left + 1
    }
  }
  for e in sorted {
    let pts = if e.track == 2 { e.pts_ms + audio_offset } else { e.pts_ms }
    let block : Array[Byte] = [
      if e.track == 1 {
        b'\x81'
      } else {
        b'\x82'
      },
      ((pts >> 8) & 0xFF).to_int().to_byte(),
      (pts & 0xFF).to_int().to_byte(),
      if e.keyframe {
        b'\x80'
      } else {
        b'\x00'
      },
    ]
    for b in e.data {
      block.push(b)
    }
    if e.track == 2 {
      audio_left = audio_left - 1
    }
    if e.track == 2 && audio_left == 0 && self.audio_discard_padding > 0 {
      let group : Array[Byte] = []
      webm_elem(group, 0xA1, 1, block)
      let pad_ns = (
          self.audio_discard_padding.to_int64() * 1000000000L + 24000L
        ) /
        48000L
      mkv_sint_elem(group, 0x75A2, 2, pad_ns)
      webm_elem(cluster, 0xA0, 1, group)
    } else {
      webm_elem(cluster, 0xA3, 1, block)
    }
  }
  cluster
}

///|
pub fn WebmAvMuxer::finish(self : WebmAvMuxer) -> Bytes {
  let header_body : Array[Byte] = []
  webm_uint_elem(header_body, 0x4286, 2, 1UL)
  webm_uint_elem(header_body, 0x42F7, 2, 1UL)
  webm_uint_elem(header_body, 0x42F2, 2, 4UL)
  webm_uint_elem(header_body, 0x42F3, 2, 8UL)
  webm_string_elem(header_body, 0x4282, 2, "webm")
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
  webm_float_elem(info, 0x4489, 2, duration.to_double())

  let video : Array[Byte] = []
  webm_uint_elem(video, 0xB0, 1, self.width.reinterpret_as_uint().to_uint64())
  webm_uint_elem(video, 0xBA, 1, self.height.reinterpret_as_uint().to_uint64())
  let vtrack : Array[Byte] = []
  webm_uint_elem(vtrack, 0xD7, 1, 1UL)
  webm_uint_elem(vtrack, 0x73C5, 2, 1UL)
  webm_uint_elem(vtrack, 0x83, 1, 1UL)
  webm_string_elem(vtrack, 0x86, 1, "V_VP9")
  webm_elem(vtrack, 0xE0, 1, video)
  webm_elem(vtrack, 0xEC, 1, [])

  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, 48000.0)
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
  webm_string_elem(atrack, 0x86, 1, "A_OPUS")
  let head = webm_av_opus_head(self)
  let head_body : Array[Byte] = []
  for b in head {
    head_body.push(b)
  }
  webm_elem(atrack, 0x63A2, 2, head_body)
  if self.pre_skip > 0 {
    let delay_ns = (self.pre_skip.to_int64() * 1000000000L + 24000L) / 48000L
    webm_uint_elem(atrack, 0x56AA, 2, delay_ns.reinterpret_as_uint64())
  }
  webm_uint_elem(atrack, 0x56BB, 2, 80000000UL) // SeekPreRoll (80 ms)
  webm_elem(atrack, 0xE1, 1, audio)
  webm_elem(atrack, 0xEC, 1, [])

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, vtrack)
  webm_elem(tracks, 0xAE, 1, atrack)
  webm_elem(tracks, 0xEC, 1, [])

  let info_elem : Array[Byte] = []
  webm_elem(info_elem, 0x1549A966, 4, info)
  let tracks_elem : Array[Byte] = []
  webm_elem(tracks_elem, 0x1654AE6B, 4, tracks)
  let cluster_body = self.cluster()
  let cluster_elem : Array[Byte] = []
  webm_elem(cluster_elem, 0x1F43B675, 4, cluster_body)
  let key_times : Array[Int64] = []
  for e in self.events {
    if e.track == 1 && e.keyframe {
      key_times.push(e.pts_ms)
    }
  }
  let (seekhead, cues) = mkv_seekhead_cues(
    info_elem, tracks_elem, cluster_elem, key_times,
  )
  let segment_body : Array[Byte] = []
  for part in [seekhead, info_elem, tracks_elem, cluster_elem, cues] {
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
