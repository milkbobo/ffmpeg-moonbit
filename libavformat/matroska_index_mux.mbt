///|
/// SeekHead + Cues writer shared by the single-cluster WebM muxers.
/// Positions are relative to the Segment data start, as Matroska requires.

///|
/// Fixed-width (8-byte) EBML unsigned integer: keeps the SeekHead size
/// independent of the position values.
fn mkv_fixed_uint_elem(
  dst : Array[Byte],
  id : UInt32,
  id_len : Int32,
  value : UInt64,
) -> Unit {
  let body : Array[Byte] = []
  for i in 0..<8 {
    body.push(((value >> (8 * (7 - i))) & 0xFFUL).to_int().to_byte())
  }
  webm_elem(dst, id, id_len, body)
}

///|
fn mkv_seek_entry(dst : Array[Byte], id : UInt32, position : Int64) -> Unit {
  let body : Array[Byte] = []
  let id_body : Array[Byte] = []
  for i in 0..<4 {
    id_body.push(((id >> (8 * (3 - i))) & 0xFFU).to_byte())
  }
  webm_elem(body, 0x53AB, 2, id_body) // SeekID
  mkv_fixed_uint_elem(body, 0x53AC, 2, position.reinterpret_as_uint64())
  webm_elem(dst, 0x4DBB, 2, body)
}

///|
/// Build `(SeekHead, Cues)` for children laid out as
/// `SeekHead | Info | Tracks | Cluster(s) | Cues`. `key_times_ms` are the
/// video keyframe presentation times; all cues point at the first cluster.
fn mkv_seekhead_cues(
  info : Array[Byte],
  tracks : Array[Byte],
  cluster : Array[Byte],
  key_times_ms : Array[Int64],
) -> (Array[Byte], Array[Byte]) {
  let has_cues = key_times_ms.length() > 0
  // Measure the SeekHead with the final number of entries (fixed widths).
  let dummy : Array[Byte] = []
  mkv_seek_entry(dummy, 0x1549A966U, 0L) // Info
  mkv_seek_entry(dummy, 0x1654AE6BU, 0L) // Tracks
  if has_cues {
    mkv_seek_entry(dummy, 0x1C53BB6BU, 0L) // Cues
  }
  let probe : Array[Byte] = []
  webm_elem(probe, 0x114D9B74, 4, dummy)
  let seekhead_len = probe.length()
  let info_pos = seekhead_len.to_int64()
  let tracks_pos = info_pos + info.length().to_int64()
  let cluster_pos = tracks_pos + tracks.length().to_int64()
  let cues_pos = cluster_pos + cluster.length().to_int64()
  let seekhead_body : Array[Byte] = []
  mkv_seek_entry(seekhead_body, 0x1549A966U, info_pos)
  mkv_seek_entry(seekhead_body, 0x1654AE6BU, tracks_pos)
  if has_cues {
    mkv_seek_entry(seekhead_body, 0x1C53BB6BU, cues_pos)
  }
  let seekhead : Array[Byte] = []
  webm_elem(seekhead, 0x114D9B74, 4, seekhead_body)
  let cues : Array[Byte] = []
  if has_cues {
    let cues_body : Array[Byte] = []
    for t in key_times_ms {
      let pos_body : Array[Byte] = []
      webm_uint_elem(pos_body, 0xF7, 1, 1UL) // CueTrack
      webm_uint_elem(pos_body, 0xF1, 1, cluster_pos.reinterpret_as_uint64())
      let point : Array[Byte] = []
      webm_uint_elem(point, 0xB3, 1, t.reinterpret_as_uint64())
      webm_elem(point, 0xB7, 1, pos_body)
      webm_elem(cues_body, 0xBB, 1, point)
    }
    webm_elem(cues, 0x1C53BB6B, 4, cues_body)
  }
  (seekhead, cues)
}
