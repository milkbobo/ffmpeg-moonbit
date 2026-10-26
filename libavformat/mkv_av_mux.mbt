///|
/// Minimal Matroska writer with one H.264 video track and one AAC audio track.
/// Packets are interleaved by millisecond timestamp in a single Cluster.
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
  events : Array[MkvAvEvent]
}

///|
pub fn mkv_av_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  sample_rate : Int32,
  channels~ : Int32 = 2,
) -> Result[MkvAvMuxer, String] {
  if width <= 0 ||
    height <= 0 ||
    avcc.length() < 7 ||
    sample_rate <= 0 ||
    channels < 1 ||
    channels > 7 {
    return Err("EINVAL: invalid MKV A/V parameters")
  }
  Ok({ width, height, avcc, sample_rate, channels, events: [], })
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
fn mkv_av_sorted(events : Array[MkvAvEvent]) -> Array[MkvAvEvent] {
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
fn MkvAvMuxer::cluster(self : MkvAvMuxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  for e in mkv_av_sorted(self.events) {
    let block : Array[Byte] = [
      if e.track == 1 {
        b'\x81'
      } else {
        b'\x82'
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
    webm_elem(cluster, 0xA3, 1, block)
  }
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
  webm_string_elem(atrack, 0x86, 1, "A_AAC")
  let private = mkv_av_aac_private(self)
  let private_body : Array[Byte] = []
  for b in private {
    private_body.push(b)
  }
  webm_elem(atrack, 0x63A2, 2, private_body)
  webm_elem(atrack, 0xE1, 1, audio)
  webm_elem(atrack, 0xEC, 1, [])

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, vtrack)
  webm_elem(tracks, 0xAE, 1, atrack)
  webm_elem(tracks, 0xEC, 1, [])

  let segment_body : Array[Byte] = []
  webm_elem(segment_body, 0x1549A966, 4, info)
  webm_elem(segment_body, 0x1654AE6B, 4, tracks)
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
