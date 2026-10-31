///|
/// Minimal MKV/HEVC writer: EBML header, Segment Info, one
/// `V_MPEGH/ISO/HEVC` track and a single Cluster of SimpleBlocks.  Codec
/// packets are written verbatim (the caller supplies length-prefixed NALs
/// matching the hvcC `lengthSizeMinusOne`), mirroring the H.264 writer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct MkvHevcMuxer {
  width : Int32
  height : Int32
  hvcc : Bytes
  packets : Array[Bytes]
  durations : Array[Int32]
  keyframes : Array[Bool]
  /// Optional presentation timestamp in ms per packet (-1 = cumulative).
  pts : Array[Int64]
}

///|
pub fn mkv_hevc_muxer_new(
  width : Int32,
  height : Int32,
  hvcc : Bytes,
) -> Result[MkvHevcMuxer, String] {
  if width <= 0 || height <= 0 || hvcc.length() < 23 {
    return Err("EINVAL: invalid MKV/HEVC parameters")
  }
  Ok({
    width,
    height,
    hvcc,
    packets: [],
    durations: [],
    keyframes: [],
    pts: [],
  })
}

///|
pub fn MkvHevcMuxer::write_packet(
  self : MkvHevcMuxer,
  packet : Bytes,
  duration~ : Int32 = 33,
  keyframe~ : Bool = false,
  pts_ms~ : Int64 = -1L,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 || (pts_ms < 0L && pts_ms != -1L) {
    return Err("EINVAL: empty HEVC packet or duration")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  self.keyframes.push(keyframe)
  self.pts.push(pts_ms)
  Ok(())
}

///|
fn MkvHevcMuxer::cluster(self : MkvHevcMuxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  let mut ms = 0
  for i in 0..<self.packets.length() {
    let packet = self.packets[i]
    let t = if self.pts[i] >= 0L { self.pts[i].to_int() } else { ms }
    let block : Array[Byte] = [
      b'\x81',
      ((t >> 8) & 0xFF).to_byte(),
      (t & 0xFF).to_byte(),
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
pub fn MkvHevcMuxer::finish(self : MkvHevcMuxer) -> Bytes {
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
  webm_string_elem(track, 0x86, 1, "V_MPEGH/ISO/HEVC")
  let hvcc_body : Array[Byte] = []
  for b in self.hvcc {
    hvcc_body.push(b)
  }
  webm_elem(track, 0x63A2, 2, hvcc_body)
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
    let t = if self.pts[i] >= 0L { self.pts[i] } else { key_ms }
    if self.keyframes[i] {
      key_times.push(t)
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
