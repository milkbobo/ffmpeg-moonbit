///|
/// Minimal MJPEG/PNG-in-Matroska writers: one `V_MJPEG` or `V_PNG` video
/// track and a single Cluster of SimpleBlocks.  The still-image packets are
/// stored verbatim (JPEG/PNG files), so no CodecPrivate is written; timestamps
/// are non-negative milliseconds within the cluster.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct MkvStillEvent {
  pts_ms : Int64
  data : Bytes
  duration_ms : Int32
}

///|
pub struct MkvStillMuxer {
  codec_id : String
  /// Extra CodecPrivate bytes; PNG uses a `V_MS/VFW/FOURCC` BITMAPINFOHEADER.
  private : Bytes
  width : Int32
  height : Int32
  events : Array[MkvStillEvent]
}

///|
fn mkv_still_muxer_new(
  codec_id : String,
  private : Bytes,
  width : Int32,
  height : Int32,
) -> Result[MkvStillMuxer, String] {
  if width <= 0 || height <= 0 {
    return Err("EINVAL: invalid MKV still-image dimensions")
  }
  Ok({ codec_id, private, width, height, events: [], })
}

///|
fn mkv_still_put_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push((v & 0xFF).to_byte())
  dst.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn mkv_still_put_u32(dst : Array[Byte], v : UInt32) -> Unit {
  dst.push((v & 0xFFU).to_byte())
  dst.push(((v >> 8) & 0xFFU).to_byte())
  dst.push(((v >> 16) & 0xFFU).to_byte())
  dst.push(((v >> 24) & 0xFFU).to_byte())
}

///|
/// `BITMAPINFOHEADER` for a `V_MS/VFW/FOURCC` PNG track, as FFmpeg's
/// Matroska muxer writes it (biCompression = `MPNG`, 24 bpp).
fn mkv_png_bmp_header(width : Int32, height : Int32) -> Bytes {
  let out : Array[Byte] = []
  mkv_still_put_u32(out, 40U)
  mkv_still_put_u32(out, width.reinterpret_as_uint())
  mkv_still_put_u32(out, height.reinterpret_as_uint())
  mkv_still_put_u16(out, 1)
  mkv_still_put_u16(out, 24)
  mkv_still_put_u32(out, 0x474E504DU) // "MPNG"
  for _ in 0..<5 {
    mkv_still_put_u32(out, 0U)
  }
  Bytes::from_array(out)
}

///|
/// One MJPEG (`V_MJPEG`) video track; packets are complete JPEG images.
pub fn mkv_mjpeg_muxer_new(
  width : Int32,
  height : Int32,
) -> Result[MkvStillMuxer, String] {
  mkv_still_muxer_new("V_MJPEG", b"", width, height)
}

///|
/// One PNG (`V_PNG`) video track; packets are complete PNG images.
pub fn mkv_png_muxer_new(
  width : Int32,
  height : Int32,
) -> Result[MkvStillMuxer, String] {
  mkv_still_muxer_new(
    "V_MS/VFW/FOURCC",
    mkv_png_bmp_header(width, height),
    width,
    height,
  )
}

///|
pub fn MkvStillMuxer::write_packet(
  self : MkvStillMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration_ms <= 0 || pts_ms < 0L {
    return Err("EINVAL: invalid MKV still-image packet")
  }
  self.events.push({ pts_ms, data: packet, duration_ms, })
  Ok(())
}

///|
fn MkvStillMuxer::cluster(self : MkvStillMuxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  for e in self.events {
    let block : Array[Byte] = [
      b'\x81',
      ((e.pts_ms >> 8) & 0xFF).to_int().to_byte(),
      (e.pts_ms & 0xFF).to_int().to_byte(),
      b'\x80',
    ]
    for b in e.data {
      block.push(b)
    }
    webm_elem(cluster, 0xA3, 1, block)
  }
  cluster
}

///|
pub fn MkvStillMuxer::finish(self : MkvStillMuxer) -> Bytes {
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

  let track : Array[Byte] = []
  webm_uint_elem(track, 0xD7, 1, 1UL)
  webm_uint_elem(track, 0x73C5, 2, 1UL)
  webm_uint_elem(track, 0x83, 1, 1UL) // video
  webm_string_elem(track, 0x86, 1, self.codec_id)
  if self.private.length() > 0 {
    let private_body : Array[Byte] = []
    for b in self.private {
      private_body.push(b)
    }
    webm_elem(track, 0x63A2, 2, private_body)
  }
  webm_elem(track, 0xE0, 1, video)
  webm_elem(track, 0xEC, 1, [])

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, track)
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
