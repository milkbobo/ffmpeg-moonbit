///|
let demo_silence_threshold = 0.001 // -60 dBFS

///|
fn demo_min_quiet(rate : Int32) -> Int32 {
  rate / 2 + rate % 2
}

///|
fn analyze_pcm(samples : Array[Array[Double]], rate : Int32) -> String {
  guard rate > 0 && !samples.is_empty() && !samples[0].is_empty() else {
    return env_err_code(
      "AUDIO_ANALYSIS_FAILED", "音轨没有可分析的采样。",
    )
  }
  let length = samples[0].length()
  let bins = @cmp.minimum(length, 640)
  let lows = Array::make(bins, 0.0)
  let highs = Array::make(bins, 0.0)
  let mut peak = 0.0
  let silence : Array[Json] = []
  let mut quiet_start = 0
  let min_quiet = demo_min_quiet(rate)
  for i in 0..<length {
    let bin = (i.to_int64() * bins.to_int64() / length.to_int64()).to_int()
    let mut level = 0.0
    for channel in samples {
      let sample = channel[i]
      lows[bin] = @cmp.minimum(lows[bin], sample)
      highs[bin] = @cmp.maximum(highs[bin], sample)
      level = @cmp.maximum(level, sample.abs())
    }
    peak = @cmp.maximum(peak, level)
    if level >= demo_silence_threshold {
      if i - quiet_start >= min_quiet {
        silence.push(pcm_interval(quiet_start, i, rate))
      }
      quiet_start = i + 1
    }
  }
  if length - quiet_start >= min_quiet {
    silence.push(pcm_interval(quiet_start, length, rate))
  }
  let result : Json = {
    "ok": Json(true),
    "duration": Json(length.to_double() / rate.to_double()),
    "channels": Json(samples.length()),
    "rate": Json(rate),
    "peak": Json(peak),
    "lufs": match @avfilter.integrated_loudness(samples, rate) {
      Some(value) => Json(value)
      None => Json::null()
    },
    "lows": Json(lows),
    "highs": Json(highs),
    "silence": Json(silence),
  }
  result.stringify()
}

///|
fn pcm_interval(start : Int32, end : Int32, rate : Int32) -> Json {
  Json([
    start.to_double() / rate.to_double(),
    end.to_double() / rate.to_double(),
  ])
}

///|
/// Analyze the first audio stream at its original sample rate.
#export_name("ff_analyze_audio")
pub fn ff_analyze_audio(data : String) -> String {
  let audio = decode_audio_at_rate(data, 0) catch { e => return env_err(e) }
  analyze_pcm(audio.samples(), audio.sample_rate())
}
