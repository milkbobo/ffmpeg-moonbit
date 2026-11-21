///|
priv struct ClipSource {
  data : Bytes
  video : @avf.Mp4Track
  audio : @avf.Mp4Track?
  origin : Int64
  end : Int64
}

///|
fn clip_open(data : Bytes) -> ClipSource raise {
  let movie = demo_result(@avf.av_mov_open(data))
  let videos = movie.tracks.filter(t => t.media_type is @avf.Mp4MediaType::Video)
  let audios = movie.tracks.filter(t => t.media_type is @avf.Mp4MediaType::Audio)
  guard videos.length() == 1 && audios.length() <= 1 else {
    fail("剪辑支持单视频轨和最多一条 AAC 音轨的 MP4。")
  }
  let video = videos[0]
  guard video.codec == "avc1" &&
    video.extradata is Some(_) &&
    video.timescale > 0U &&
    video.stsd_count == 1 &&
    video.cenc_scheme == 0U &&
    !video.samples.is_empty() else {
    fail("剪辑需要未加密的 H.264（avc1）MP4。")
  }
  let mut origin = video.samples[0].pts
  let mut end = origin
  for sample in video.samples {
    guard !sample.discard && sample.duration > 0U else {
      fail(
        "剪辑暂不支持含丢弃视频样本或零时长样本的时间轴。",
      )
    }
    origin = origin.min(sample.pts)
    end = end.max(sample.pts + sample.duration.to_int64())
  }
  let audio = audios.get(0)
  if audio is Some(track) {
    guard track.codec_id == "aac" &&
      track.stsd_count == 1 &&
      track.cenc_scheme == 0U &&
      track.sample_rate > 0U &&
      track.sample_rate == track.timescale &&
      track.extradata is Some(_) &&
      !track.samples.is_empty() else {
      fail(
        "剪辑需要与采样率使用相同时间基的未加密 AAC 音轨。",
      )
    }
  }
  { data, video, audio, origin, end, }
}

///|
fn clip_range(
  clip : ClipSource,
  from : Double,
  until : Double,
) -> (Int32, Int32, Int64, Int64) raise {
  let track = clip.video
  let scale = track.timescale.to_double()
  let duration = (clip.end - clip.origin).to_double() / scale
  guard !from.is_nan() &&
    from >= 0.0 &&
    from < duration &&
    !until.is_nan() &&
    until > from &&
    !until.is_inf() else {
    fail("请输入有效的裁剪起止时间。")
  }
  let mut first = -1
  let mut last = track.samples.length()
  let mut start = clip.origin
  let mut end = clip.end
  for index, sample in track.samples {
    if !demo_idr_sample(clip.data, track, index) {
      continue
    }
    let time = (sample.pts - clip.origin).to_double() / scale
    if time <= from && sample.pts >= start {
      first = index
      start = sample.pts
    }
    if time >= until && sample.pts < end {
      last = index
      end = sample.pts
    }
  }
  guard first >= 0 && first < last else {
    fail("所选区间找不到可独立解码的 H.264 IDR 起点。")
  }
  (first, last, start, end)
}

///|
priv enum ClipMux {
  Video(@avf.Mp4H264Muxer)
  AudioVideo(@avf.Mp4AvMuxer)
}

///|
fn clip_mux(clip : ClipSource) -> ClipMux raise {
  let video = clip.video
  let config = video.extradata.unwrap()
  match clip.audio {
    Some(track) =>
      AudioVideo(
        demo_result(
          @avf.mp4_av_muxer_new(
            video.width,
            video.height,
            config,
            track.sample_rate.reinterpret_as_int(),
            track.channels.reinterpret_as_int(),
            aac_config=track.extradata,
            video_language=video.language,
            audio_language=track.language,
          ),
        ),
      )
    None =>
      Video(
        demo_result(
          @avf.mp4_h264_muxer_new(
            video.width,
            video.height,
            config,
            language=video.language,
          ),
        ),
      )
  }
}

///|
fn clip_compatible(first : ClipSource, next : ClipSource) -> Bool {
  if first.video.width != next.video.width ||
    first.video.height != next.video.height ||
    first.video.extradata != next.video.extradata {
    return false
  }
  match (first.audio, next.audio) {
    (None, None) => true
    (Some(a), Some(b)) =>
      a.sample_rate == b.sample_rate &&
      a.channels == b.channels &&
      a.extradata == b.extradata
    _ => false
  }
}

///|
fn clip_ticks(value : Int64, scale : UInt32) -> Int64 {
  let units = scale.to_int64()
  // Split off whole seconds to preserve precision and avoid multiplying the full input.
  value / units * 90000L + value % units * 90000L / units
}

///|
fn clip_write_video(
  mux : ClipMux,
  clip : ClipSource,
  first : Int32,
  last : Int32,
  start : Int64,
  end : Int64,
) -> Int64 raise {
  let track = clip.video
  let mut offset = 0L
  let mut expected_dts = track.samples[first].dts
  for i in first..<last {
    let sample = track.samples[i]
    let next = expected_dts + sample.duration.to_int64()
    guard sample.dts == expected_dts && sample.pts >= start && sample.pts < end else {
      fail(
        "视频区间包含跨切点的画面或不连续的解码时间戳。",
      )
    }
    let next_offset = clip_ticks(
      next - track.samples[first].dts,
      track.timescale,
    )
    let duration = next_offset - offset
    let cts = clip_ticks(sample.pts - start, track.timescale) - offset
    guard duration > 0L &&
      duration <= 0x7FFFFFFFL &&
      cts >= -0x80000000L &&
      cts <= 0x7FFFFFFFL else {
      fail("视频时间戳超出 MP4 写入范围。")
    }
    let data = demo_video_sample(clip.data, sample)
    match mux {
      Video(mux) =>
        demo_result(
          mux.write_packet(
            data,
            duration=duration.to_int(),
            keyframe=sample.keyframe,
            cts=cts.to_int(),
          ),
        )
      AudioVideo(mux) =>
        demo_result(
          mux.write_video(
            data,
            duration=duration.to_int(),
            keyframe=sample.keyframe,
            cts=cts.to_int(),
          ),
        )
    }
    offset = next_offset
    expected_dts = next
  }
  guard (offset - clip_ticks(end - start, track.timescale)).abs() <= 1L else {
    fail(
      "视频解码时长与显示时长不一致，无法安全拼接该区间。",
    )
  }
  offset
}

///|
fn clip_write_audio(
  mux : @avf.Mp4AvMuxer,
  clip : ClipSource,
  track : @avf.Mp4Track,
  start : Int64,
  end : Int64,
  video_total : Int64,
  audio_total : Int64,
) -> Int64 raise {
  let scale = track.timescale.to_double()
  let from = start.to_double() / clip.video.timescale.to_double() * scale
  let until = end.to_double() / clip.video.timescale.to_double() * scale
  let mut duration = audio_total
  let mut edge = 0L
  let mut first = true
  let mut tolerance = 0L
  for sample in track.samples {
    if sample.discard || sample.duration == 0U {
      continue
    }
    let step = sample.duration.to_int64()
    let midpoint = sample.pts.to_double() + step.to_double() / 2.0
    if midpoint < from || midpoint >= until {
      continue
    }
    guard step <= 0x7FFFFFFFL &&
      (if first {
        (sample.pts.to_double() - from).abs() <= step.to_double()
      } else {
        sample.pts == edge
      }) else {
      fail("AAC 时间轴不连续或与视频切点不对齐。")
    }
    demo_result(
      mux.write_audio(
        demo_video_sample(clip.data, sample),
        duration=step.to_int(),
      ),
    )
    duration += step
    edge = sample.pts + step
    tolerance = tolerance.max(step)
    first = false
  }
  guard !first &&
    (duration.to_double() - video_total.to_double() * scale / 90000.0).abs() <=
    tolerance.to_double() else {
    fail("AAC 与视频的时长偏差超过一个音频包。")
  }
  duration
}

///|
fn clip_edit(
  clips : Array[ClipSource],
  range : (Double, Double)?,
) -> (Bytes, Double, Double) raise {
  let first = clips[0]
  let mux = clip_mux(first)
  let mut video_total = 0L
  let mut audio_total = 0L
  let mut actual_start = 0.0
  for clip in clips {
    guard clip_compatible(first, clip) else {
      fail("拼接文件的 H.264 配置、尺寸或 AAC 参数不一致。")
    }
    let (a, b, start, end) = match range {
      Some((from, until)) => clip_range(clip, from, until)
      None => {
        guard clip.video.samples[0].pts == clip.origin &&
          demo_idr_sample(clip.data, clip.video, 0) else {
          fail("每段视频须从可独立解码的 H.264 IDR 开始。")
        }
        (0, clip.video.samples.length(), clip.origin, clip.end)
      }
    }
    actual_start = (start - clip.origin).to_double() /
      clip.video.timescale.to_double()
    video_total += clip_write_video(mux, clip, a, b, start, end)
    if mux is AudioVideo(mux) && clip.audio is Some(track) {
      audio_total = clip_write_audio(
        mux, clip, track, start, end, video_total, audio_total,
      )
    }
  }
  let data = match mux {
    Video(mux) => mux.finish()
    AudioVideo(mux) => mux.finish()
  }
  (data, actual_start, actual_start + video_total.to_double() / 90000.0)
}

///|
fn clip_result(result : (Bytes, Double, Double)) -> String {
  let (data, start, end) = result
  env_ok(
    "\"mp4\":\"" +
    bytes_to_u0100(data) +
    "\",\"start\":" +
    start.to_string() +
    ",\"end\":" +
    end.to_string(),
  )
}

///|
#export_name("ff_trim_mp4")
pub fn ff_trim_mp4(data : String, start : Double, end : Double) -> String {
  let result = clip_edit([clip_open(u0100_to_bytes(data))], Some((start, end))) catch {
    error => return env_err_code("MP4_EDIT_FAILED", error.to_string())
  }
  clip_result(result)
}

///|
let pending_clips : Array[ClipSource] = []

///|
#export_name("ff_concat_add")
pub fn ff_concat_add(data : String) -> String {
  let clip = clip_open(u0100_to_bytes(data)) catch {
    error => return env_err_code("MP4_EDIT_FAILED", error.to_string())
  }
  pending_clips.push(clip)
  env_ok("\"count\":" + pending_clips.length().to_string())
}

///|
#export_name("ff_concat_clear")
pub fn ff_concat_clear() -> Unit {
  pending_clips.clear()
}

///|
#export_name("ff_concat_finish")
pub fn ff_concat_finish() -> String {
  guard pending_clips.length() >= 2 else {
    return env_err_code("MP4_EDIT_FAILED", "请选择至少两段 MP4。")
  }
  let result = clip_edit(pending_clips, None) catch {
    error => return env_err_code("MP4_EDIT_FAILED", error.to_string())
  }
  clip_result(result)
}
