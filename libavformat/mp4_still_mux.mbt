///|
/// Minimal MJPEG/PNG-in-MP4 writers.  The caller supplies complete JPEG or
/// PNG images; the writer emits one video track with a `jpeg`/`png ` visual
/// sample entry (the fourccs FFmpeg's MOV muxer uses) and the non-fragmented
/// sample tables consumed by the MOV demuxer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct Mp4StillMuxer {
  width : Int32
  height : Int32
  timescale : Int32
  tag : String
  packets : Array[Bytes]
  durations : Array[Int32]
  keyframes : Array[Bool]
}

///|
fn mp4_still_muxer_new(
  tag : String,
  width : Int32,
  height : Int32,
  timescale : Int32,
) -> Result[Mp4StillMuxer, String] {
  if width <= 0 || height <= 0 || timescale <= 0 {
    return Err("EINVAL: invalid still-image MP4 parameters")
  }
  Ok({
    width,
    height,
    timescale,
    tag,
    packets: [],
    durations: [],
    keyframes: [],
  })
}

///|
/// One MJPEG (`jpeg` sample entry) video track; packets are complete JPEGs.
pub fn mp4_mjpeg_muxer_new(
  width : Int32,
  height : Int32,
  timescale~ : Int32 = 90000,
) -> Result[Mp4StillMuxer, String] {
  mp4_still_muxer_new("jpeg", width, height, timescale)
}

///|
/// One PNG (`png ` sample entry) video track; packets are complete PNGs.
pub fn mp4_png_muxer_new(
  width : Int32,
  height : Int32,
  timescale~ : Int32 = 90000,
) -> Result[Mp4StillMuxer, String] {
  mp4_still_muxer_new("png ", width, height, timescale)
}

///|
pub fn Mp4StillMuxer::write_packet(
  self : Mp4StillMuxer,
  packet : Bytes,
  duration~ : Int32 = 3000,
  keyframe~ : Bool = true,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: empty still-image packet or duration")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  self.keyframes.push(keyframe)
  Ok(())
}

///|
pub fn Mp4StillMuxer::finish(self : Mp4StillMuxer) -> Bytes {
  let entry = mp4_visual_entry(self.width, self.height, self.tag, "", b"")
  mp4_video_document(
    self.width,
    self.height,
    self.timescale,
    entry,
    self.packets,
    self.durations,
    self.keyframes,
  )
}
