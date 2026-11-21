///|
fn video_issue(start : Double, end : Double) -> Json {
  Json([start, end])
}

///|
fn issue_luma(frame : @avf.VideoFrame) -> Array[Int32] {
  let width = frame.width()
  let height = frame.height()
  let bits = frame.bit_depth()
  let bytes = frame.yuv_bytes()
  let columns = width.min(96)
  let rows = height.min(54)
  Array::makei(columns * rows, fn(i) {
    let x = (2 * (i % columns) + 1) * width / (2 * columns)
    let y = (2 * (i / columns) + 1) * height / (2 * rows)
    let offset = y * width + x
    if bits > 8 {
      (bytes[2 * offset].to_int() | (bytes[2 * offset + 1].to_int() << 8)) >>
      (bits - 8)
    } else {
      bytes[offset].to_int()
    }
  })
}

///|
fn issue_similar(reference : Array[Int32], current : Array[Int32]) -> Bool {
  guard reference.length() == current.length() else { return false }
  let mut difference = 0
  for i in 0..<current.length() {
    difference += (reference[i] - current[i]).abs()
  }
  // Mean luma difference at most 0.001 of full scale.
  difference * 1000 <= current.length() * 255
}

///|
fn demo_video_issues(data : Bytes) -> Json raise {
  let player = demo_open_player(data, bulk=true)
  guard ["h264", "hevc", "vp9", "av1"].contains(player.video.codec_id) else {
    fail("故障检测支持 H.264、HEVC、VP9 和 AV1 视频。")
  }
  let black : Array[Json] = []
  let frozen : Array[Json] = []
  let mut black_start : Double? = None
  let mut freeze_start = 0.0
  let mut reference : Array[Int32] = []
  let mut geometry = (0, 0)
  let mut freeze_frames = 0
  while player.next() is Some(frame) {
    let start = player.advance()
    let luma = issue_luma(frame)
    let size = (frame.width(), frame.height())
    let mut dark = 0
    for value in luma {
      if value <= 32 {
        dark += 1
      }
    }
    if dark * 100 >= luma.length() * 98 {
      if black_start is None {
        black_start = Some(start)
      }
    } else if black_start is Some(from) {
      if start - from >= 2.0 - 1.0e-9 {
        black.push(video_issue(from, start))
      }
      black_start = None
    }
    if size == geometry && issue_similar(reference, luma) {
      freeze_frames += 1
    } else {
      if freeze_frames >= 2 && start - freeze_start >= 2.0 - 1.0e-9 {
        frozen.push(video_issue(freeze_start, start))
      }
      reference = luma
      geometry = size
      freeze_start = start
      freeze_frames = 1
    }
  }
  guard player.frame_index > 0 else {
    fail("视频没有可检测的画面。")
  }
  if black_start is Some(from) && player.end - from >= 2.0 - 1.0e-9 {
    black.push(video_issue(from, player.end))
  }
  if freeze_frames >= 2 && player.end - freeze_start >= 2.0 - 1.0e-9 {
    frozen.push(video_issue(freeze_start, player.end))
  }
  {
    "black": Json(black),
    "frozen": Json(frozen),
    "estimated": Json(player.durations.is_empty()),
  }
}

///|
#export_name("ff_video_issues")
pub fn ff_video_issues(data : String) -> String {
  let issues = demo_video_issues(u0100_to_bytes(data)) catch {
    error => return env_err_code("VIDEO_DIAGNOSTICS_FAILED", error.to_string())
  }
  env_ok("\"issues\":" + issues.stringify())
}
