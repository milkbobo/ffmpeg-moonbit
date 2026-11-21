///|
priv struct DemoPlayback {
  data : Bytes
  file : @avf.MediaFile
  video : @avf.StreamInfo
  mut decoder : @avf.VideoDecoder
  indexed : @avf.Mp4Track?
  order : Array[Int32]
  ranks : Array[Int32]
  durations : Array[Int32]
  starts : Array[Double]
  duration : Double?
  fallback_step : Double
  pending : Map[Int32, @avf.VideoFrame]
  mut frame_batch : Array[@avf.VideoFrame]
  mut batch_index : Int32
  mut packet_index : Int32
  mut first_packet : Int32
  mut frame_index : Int32
  mut end : Double
  mut eof : Bool
  mut locate_frame : (@avf.VideoFrame, Double)?
  mut decoded_pixels : Int64
  bulk : Bool
}

///|
let demo_playback : Ref[DemoPlayback?] = { val: None, }

///|
fn demo_open_player(data : Bytes, bulk~ : Bool = false) -> DemoPlayback raise {
  let file = @avf.MediaFile::open(data)
  let video = for stream in file.streams() {
    if stream.media_type == @avf.MediaType::Video {
      break Some(stream)
    }
  } nobreak {
    None
  }
  guard video is Some(video) else { fail("input has no video stream") }
  if video.width != 0 || video.height != 0 {
    demo_check_video_size(video.width, video.height)
  }
  let track = demo_mov_track(data, file, video.index)
  let (order, durations) = match track {
    Some(track) => demo_mov_timeline_for(track)
    None => ([], [])
  }
  let (duration, fallback_step) = if !durations.is_empty() {
    let mut total = 0L
    for duration in durations {
      total += duration.to_int64()
    }
    (Some(total.to_double() / 90000.0), 1.0 / 30.0)
  } else {
    match file.duration_seconds() {
      Some(total) if total > 0.0 => {
        let scan = @avf.MediaFile::open(data)
        let mut count = 0
        while scan.next_packet() is Some(packet) {
          if packet.stream_index == video.index {
            count += 1
          }
        }
        (
          Some(total),
          if count > 0 {
            total / count.to_double()
          } else {
            1.0 / 30.0
          },
        )
      }
      _ => (None, 1.0 / 30.0)
    }
  }
  let starts : Array[Double] = [0.0]
  for duration in durations {
    starts.push(starts[starts.length() - 1] + duration.to_double() / 90000.0)
  }
  let ranks = Array::make(order.length(), 0)
  for i in 0..<order.length() {
    ranks[order[i]] = i
  }
  {
    data,
    file,
    video,
    decoder: @avf.VideoDecoder::open(video),
    indexed: if video.codec_id == "h264" {
      track
    } else {
      None
    },
    order: if video.codec_id == "h264" {
      order
    } else {
      []
    },
    ranks,
    durations,
    starts,
    duration,
    fallback_step,
    pending: Map([]),
    frame_batch: [],
    batch_index: 0,
    packet_index: 0,
    first_packet: 0,
    frame_index: 0,
    end: 0.0,
    eof: false,
    locate_frame: None,
    decoded_pixels: 0L,
    bulk,
  }
}

///|
fn DemoPlayback::read_packet(self : DemoPlayback) -> @avf.MediaPacket? raise {
  guard self.indexed is Some(track) else { return self.file.next_packet() }
  guard self.packet_index < track.samples.length() else { return None }
  let sample = track.samples[self.packet_index]
  Some({
    stream_index: self.video.index,
    data: demo_video_sample(self.data, sample),
    pts: sample.pts,
    keyframe: sample.keyframe,
  })
}

///|
fn demo_video_sample(data : Bytes, sample : @avf.Mp4Sample) -> Bytes raise {
  let size = sample.size.to_int64()
  guard sample.offset >= 0L && sample.offset <= data.length().to_int64() - size else {
    fail("MP4 video sample extends past end of file")
  }
  data[sample.offset.to_int():(sample.offset + size).to_int()].to_owned()
}

///|
fn DemoPlayback::next(self : DemoPlayback) -> @avf.VideoFrame? raise {
  for ;; {
    if self.batch_index < self.frame_batch.length() {
      let frame = self.frame_batch[self.batch_index]
      self.batch_index += 1
      return Some(frame)
    }
    if !self.order.is_empty() && self.frame_index < self.order.length() {
      let index = self.order[self.frame_index]
      if index < self.first_packet {
        self.frame_index += 1
        self.end = self.starts[self.frame_index]
        continue
      }
      if self.pending.get(index) is Some(frame) {
        self.pending.remove(index)
        return Some(frame)
      }
    }
    if self.eof {
      guard self.pending.is_empty() else {
        fail("incomplete H.264 presentation timeline")
      }
      return None
    }
    match self.read_packet() {
      Some(packet) if packet.stream_index == self.video.index => {
        let frames = self.decoder.decode(packet)
        self.decoded_pixels = demo_count_video(
          frames,
          if self.bulk {
            self.decoded_pixels
          } else {
            0L
          },
        )
        if self.order.is_empty() {
          self.frame_batch = frames
          self.batch_index = 0
        } else {
          guard frames.length() == 1 else {
            fail("unsupported H.264 sample layout")
          }
          // Open GOPs may contain pictures presented before the seek point.
          if self.ranks[self.packet_index] >= self.frame_index {
            self.pending[self.packet_index] = frames[0]
          }
          self.packet_index += 1
        }
      }
      Some(_) => ()
      None => {
        self.eof = true
        self.frame_batch = self.decoder.finish_video(
          pixel_budget=demo_hevc_batch_pixels,
        )
        self.decoded_pixels = demo_count_video(
          self.frame_batch,
          if self.bulk {
            self.decoded_pixels
          } else {
            0L
          },
        )
        self.batch_index = 0
      }
    }
  }
}

///|
fn DemoPlayback::advance(self : DemoPlayback) -> Double {
  let start = self.end
  let index = self.frame_index
  self.end += if index < self.durations.length() {
    self.durations[index].to_double() / 90000.0
  } else {
    self.fallback_step
  }
  self.frame_index += 1
  start
}

///|
fn demo_idr_sample(
  data : Bytes,
  track : @avf.Mp4Track,
  index : Int32,
) -> Bool raise {
  let sample = track.samples[index]
  guard sample.keyframe &&
    track.extradata is Some(config) &&
    config.length() >= 5 &&
    config[0] == b'\x01' else {
    return false
  }
  let width = (config[4].to_int() & 3) + 1
  let bytes = demo_video_sample(data, sample)
  let mut offset = 0
  while offset + width < bytes.length() {
    let mut length = 0L
    for i in 0..<width {
      length = (length << 8) | bytes[offset + i].to_int64()
    }
    offset += width
    guard length > 0L && length <= (bytes.length() - offset).to_int64() else {
      return false
    }
    if (bytes[offset].to_int() & 31) == 5 {
      return true
    }
    offset += length.to_int()
  }
  false
}

///|
fn DemoPlayback::index_at(
  self : DemoPlayback,
  target : Double,
  count : Int32,
) -> Int32 {
  if self.starts.length() != count + 1 {
    return (target / self.fallback_step).to_int().max(0).min(count - 1)
  }
  let mut lo = 0
  let mut hi = count
  while lo + 1 < hi {
    let mid = lo + (hi - lo) / 2
    if self.starts[mid] <= target {
      lo = mid
    } else {
      hi = mid
    }
  }
  lo
}

///|
fn DemoPlayback::seek_indexed(
  self : DemoPlayback,
  target : Double,
) -> Bool raise {
  if self.indexed is Some(track) {
    let position = self.index_at(target, self.order.length())
    let mut key = position
    while key > 0 && !demo_idr_sample(self.data, track, self.order[key]) {
      key -= 1
    }
    self.decoder = @avf.VideoDecoder::open(self.video)
    self.first_packet = if key == 0 { 0 } else { self.order[key] }
    self.packet_index = self.first_packet
    self.pending.clear()
    self.frame_index = key
    self.end = self.starts[key]
    self.eof = false
    return true
  }
  // HEVC decoding already materializes the entire clip at first playback.
  if self.video.codec_id == "hevc" && self.eof && !self.frame_batch.is_empty() {
    let index = self.index_at(target, self.frame_batch.length())
    self.batch_index = index
    self.frame_index = index
    self.end = if self.starts.length() == self.frame_batch.length() + 1 {
      self.starts[index]
    } else {
      index.to_double() * self.fallback_step
    }
    return true
  }
  false
}

///|
#export_name("ff_player_seek")
pub fn ff_player_seek(target : Double) -> String {
  guard demo_playback.val is Some(player) else {
    return env_err_code("PLAYBACK_FAILED", "video player is not initialized")
  }
  player.locate_frame = None
  let current = try {
    if player.seek_indexed(target) || (!player.eof && target >= player.end) {
      player
    } else {
      demo_open_player(player.data, bulk=player.bulk)
    }
  } catch {
    error => return env_err_code("PLAYBACK_FAILED", error.to_string())
  }
  demo_playback.val = Some(current)
  env_ok("\"progress\":" + current.end.to_string())
}

///|
#export_name("ff_player_open")
pub fn ff_player_open(data : String) -> String {
  demo_player_open(data, false)
}

///|
#export_name("ff_player_open_bulk")
pub fn ff_player_open_bulk(data : String) -> String {
  demo_player_open(data, true)
}

///|
fn demo_player_open(data : String, bulk : Bool) -> String {
  demo_playback.val = None
  let player = demo_open_player(u0100_to_bytes(data), bulk~) catch {
    error => return env_err_code("PLAYBACK_FAILED", error.to_string())
  }
  demo_playback.val = Some(player)
  let duration = match player.duration {
    Some(seconds) => seconds.to_string()
    None => "null"
  }
  env_ok("\"duration\":" + duration)
}

///|
#export_name("ff_player_frame")
pub fn ff_player_frame(target : Double, max_width : Int32) -> String {
  demo_player_read(target, max_width, 0)
}

///|
#export_name("ff_player_close")
pub fn ff_player_close() -> Unit {
  demo_playback.val = None
}

///|
#export_name("ff_player_locate")
pub fn ff_player_locate(target : Double, max_width : Int32) -> String {
  demo_player_read(target, max_width, 8)
}

///|
fn demo_player_read(
  target : Double,
  max_width : Int32,
  budget : Int32,
) -> String {
  guard demo_playback.val is Some(player) else {
    return env_err_code("PLAYBACK_FAILED", "video player is not initialized")
  }
  let mut selected = if budget > 0 { player.locate_frame } else { None }
  player.locate_frame = None
  for i = 0; ; i = i + 1 {
    if budget > 0 && i == budget {
      player.locate_frame = selected
      return env_ok("\"progress\":" + player.end.to_string())
    }
    let frame = player.next() catch {
      error => return env_err_code("PLAYBACK_FAILED", error.to_string())
    }
    guard frame is Some(frame) else { break }
    let start = player.advance()
    selected = Some((frame, start))
    if player.end > target {
      break
    }
  }
  match selected {
    Some((frame, start)) =>
      render_video_rgb(
        frame,
        max_width,
        fields="\"start\":" +
          start.to_string() +
          ",\"end\":" +
          player.end.to_string() +
          ",",
      )
    None => env_ok("\"eof\":true")
  }
}
