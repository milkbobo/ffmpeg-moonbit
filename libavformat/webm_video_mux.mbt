///|
/// Minimal WebM/VP9 writer: EBML header, Segment Info, one V_VP9 track and a
/// single Cluster of SimpleBlocks.  Reuses the EBML helpers from the Opus
/// writer and keeps the same level-boundary Void padding.  The EBML DocType
/// defaults to "webm" and can be switched to "matroska" for standalone .mkv
/// output (same CodecID, as written by FFmpeg `matroskaenc.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct WebmVp9Muxer {
  width : Int32
  height : Int32
  doctype : String
  packets : Array[Bytes]
  durations : Array[Int32]
  keyframes : Array[Bool]
}

///|
pub fn webm_vp9_muxer_new(
  width : Int32,
  height : Int32,
  doctype~ : String = "webm",
) -> Result[WebmVp9Muxer, String] {
  if width <= 0 || height <= 0 {
    return Err("EINVAL: invalid WebM/VP9 dimensions")
  }
  if doctype != "webm" && doctype != "matroska" {
    return Err("EINVAL: DocType must be webm or matroska")
  }
  Ok({ width, height, doctype, packets: [], durations: [], keyframes: [], })
}

///|
pub fn WebmVp9Muxer::write_packet(
  self : WebmVp9Muxer,
  packet : Bytes,
  duration~ : Int32 = 33,
  keyframe~ : Bool = false,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: empty VP9 packet or duration")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  self.keyframes.push(keyframe)
  Ok(())
}

///|
fn WebmVp9Muxer::cluster(self : WebmVp9Muxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  let mut ms = 0
  for i in 0..<self.packets.length() {
    let packet = self.packets[i]
    let block : Array[Byte] = [
      b'\x81',
      ((ms >> 8) & 0xFF).to_byte(),
      (ms & 0xFF).to_byte(),
      if self.keyframes[i] {
        b'\x80'
      } else {
        b'\x00'
      },
    ]
    for b in packet {
      block.push(b)
    }
    webm_elem(cluster, 0xA3, 1, block)
    ms = ms + self.durations[i]
  }
  cluster
}

///|
pub fn WebmVp9Muxer::finish(self : WebmVp9Muxer) -> Bytes {
  let header_body : Array[Byte] = []
  webm_uint_elem(header_body, 0x4286, 2, 1UL)
  webm_uint_elem(header_body, 0x42F7, 2, 1UL)
  webm_uint_elem(header_body, 0x42F2, 2, 4UL)
  webm_uint_elem(header_body, 0x42F3, 2, 8UL)
  webm_string_elem(header_body, 0x4282, 2, self.doctype)
  webm_uint_elem(header_body, 0x4287, 2, 4UL)
  webm_uint_elem(header_body, 0x4285, 2, 2UL)
  let ebml : Array[Byte] = []
  webm_elem(ebml, 0x1A45DFA3, 4, header_body)

  let info : Array[Byte] = []
  webm_uint_elem(info, 0x2AD7B1, 3, 1000000UL)
  webm_string_elem(info, 0x4D80, 2, "moonbit")
  webm_string_elem(info, 0x5741, 2, "moonbit")
  let mut total = 0
  for d in self.durations {
    total = total + d
  }
  webm_float_elem(info, 0x4489, 2, total.to_double())

  let video : Array[Byte] = []
  webm_uint_elem(video, 0xB0, 1, self.width.reinterpret_as_uint().to_uint64())
  webm_uint_elem(video, 0xBA, 1, self.height.reinterpret_as_uint().to_uint64())

  let track : Array[Byte] = []
  webm_uint_elem(track, 0xD7, 1, 1UL)
  webm_uint_elem(track, 0x73C5, 2, 1UL)
  webm_uint_elem(track, 0x83, 1, 1UL) // video
  webm_string_elem(track, 0x86, 1, "V_VP9")
  webm_elem(track, 0xE0, 1, video)
  webm_elem(track, 0xEC, 1, [])

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, track)
  webm_elem(tracks, 0xEC, 1, [])

  let info_elem : Array[Byte] = []
  webm_elem(info_elem, 0x1549A966, 4, info)
  let tracks_elem : Array[Byte] = []
  webm_elem(tracks_elem, 0x1654AE6B, 4, tracks)
  let cluster_body = self.cluster()
  let cluster_elem : Array[Byte] = []
  webm_elem(cluster_elem, 0x1F43B675, 4, cluster_body)
  let key_times : Array[Int64] = []
  let mut key_ms = 0L
  for i in 0..<self.packets.length() {
    if self.keyframes[i] {
      key_times.push(key_ms)
    }
    key_ms = key_ms + self.durations[i].to_int64()
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
