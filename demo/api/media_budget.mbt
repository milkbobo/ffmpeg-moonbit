///|
let demo_audio_sample_budget = 12000000L

///|
let demo_video_pixel_budget = 6000000000L

///|
// The current HEVC decoder retains the entire batch in memory.
let demo_hevc_batch_pixels = 48000000L

///|
fn demo_check_video_size(width : Int32, height : Int32) -> Unit raise {
  guard width > 0 &&
    height > 0 &&
    width <= 4096 &&
    height <= 4096 &&
    width.to_int64() * height.to_int64() <= 4096L * 2160L else {
    fail("视频画面超过 4096 × 2160 像素预算。")
  }
}

///|
fn demo_count_video(
  frames : Array[@avf.VideoFrame],
  pixels : Int64,
  limit~ : Int64 = demo_video_pixel_budget,
) -> Int64 raise {
  let mut total = pixels
  for frame in frames {
    demo_check_video_size(frame.width(), frame.height())
    total += frame.width().to_int64() * frame.height().to_int64()
    guard total <= limit else { fail("已达到视频解码像素预算。") }
  }
  total
}

///|
fn demo_decode_audio(data : Bytes) -> @avf.DecodedAudio raise @avf.MediaError {
  @avf.decode_audio_file(data, sample_budget=demo_audio_sample_budget)
}

///|
fn demo_resample_audio(
  audio : @avf.DecodedAudio,
  rate : Int32,
) -> @avf.DecodedAudio raise @avf.MediaError {
  if rate <= 0 || rate == audio.sample_rate() {
    return audio
  }
  guard audio.sample_rate() > 0 else {
    raise @avf.DecodeError("invalid source sample rate")
  }
  let frames = audio
    .samples()
    .get(0)
    .map(plane => plane.length())
    .unwrap_or(0)
    .to_int64()
  let src_rate = audio.sample_rate().to_int64()
  let target_frames = (frames * rate.to_int64() + src_rate - 1L) / src_rate
  guard target_frames * audio.channels().to_int64() <= demo_audio_sample_budget else {
    raise @avf.DecodeError("resampled audio sample budget exceeded")
  }
  audio.resample_to(rate)
}
