///|
priv struct AudioPostOptions {
  trim : Bool
  fade_in : Double
  fade_out : Double
  normalize : Bool
  target_lufs : Double
  ceiling_dbfs : Double
  mix_weight : Double
}

///|
fn audio_post_valid(options : AudioPostOptions) -> Bool {
  options.fade_in >= 0.0 &&
  options.fade_in <= 3600.0 &&
  options.fade_out >= 0.0 &&
  options.fade_out <= 3600.0 &&
  options.ceiling_dbfs >= -20.0 &&
  options.ceiling_dbfs <= 0.0 &&
  options.mix_weight >= 0.0 &&
  options.mix_weight <= 1.0 &&
  (
    !options.normalize ||
    (options.target_lufs >= -40.0 && options.target_lufs <= -5.0)
  )
}

///|
fn audio_post_check_pcm(samples : Array[Array[Double]]) -> Unit raise {
  guard samples.all(plane => {
    plane.all(sample => !sample.is_inf() && !sample.is_nan())
  }) else {
    fail("音轨包含无效的 PCM 采样。")
  }
}

///|
/// The incoming PCM is owned by this operation and may be modified in place.
fn apply_audio_post(
  samples : Array[Array[Double]],
  secondary : Array[Array[Double]]?,
  rate : Int32,
  options : AudioPostOptions,
) -> (Array[Array[Double]], Json) raise {
  guard !samples.is_empty() && !samples[0].is_empty() && rate > 0 else {
    fail("主音轨没有可处理的采样。")
  }
  audio_post_check_pcm(samples)
  let mixed = match secondary {
    None => samples
    Some(secondary) => {
      guard !secondary.is_empty() && !secondary[0].is_empty() else {
        fail("混音文件没有可处理的采样。")
      }
      guard samples.length() <= 2 && secondary.length() <= 2 else {
        fail("混音支持单声道和立体声。")
      }
      audio_post_check_pcm(secondary)
      demo_result(@avfilter.audio_mix(samples, secondary, options.mix_weight))
    }
  }
  let length = mixed[0].length()
  let (start, end) = if options.trim {
    @avfilter.audio_trim_range(
      mixed,
      demo_silence_threshold,
      demo_min_quiet(rate),
    )
  } else {
    (0, length)
  }
  guard end > start else { fail("去除首尾静音后没有剩余音频。") }
  let edited = if start > 0 || end < length {
    mixed.map(plane => plane[start:end].to_owned())
  } else {
    mixed
  }
  let sample_rate = rate.to_double()
  let max_fade = (end - start).to_double()
  @avfilter.audio_fade(
    edited,
    (options.fade_in * sample_rate).min(max_fade).to_int(),
    (options.fade_out * sample_rate).min(max_fade).to_int(),
  )
  let requested = if options.normalize {
    guard edited.length() <= 2 else {
      fail("LUFS 归一化支持单声道和立体声。")
    }
    guard @avfilter.integrated_loudness(edited, rate) is Some(lufs) else {
      fail(
        "音频太短、采样率过低或响度低于测量门限，无法归一化。",
      )
    }
    @math.pow(10.0, (options.target_lufs - lufs) / 20.0)
  } else {
    1.0
  }
  let limit = if options.normalize || secondary is Some(_) {
    options.ceiling_dbfs
  } else {
    0.0
  }
  // Round the ceiling down to a representable s16 magnitude.
  let ceiling = (@math.pow(10.0, limit / 20.0) * 32768.0).to_int().to_double() /
    32768.0
  let gain = @avfilter.audio_apply_gain(edited, requested, ceiling)
  let lufs = if options.normalize {
    @avfilter.integrated_loudness(edited, rate)
  } else {
    None
  }
  let summary : Json = {
    "trim_start": Json(start.to_double() / sample_rate),
    "trim_end": Json((length - end).to_double() / sample_rate),
    "lufs": match lufs {
      Some(value) => Json(value)
      None => Json::null()
    },
    "gain_db": Json(20.0 * @math.log10(gain)),
    "peak_limited": Json(gain < requested),
  }
  (edited, summary)
}

///|
fn export_processed_audio(
  source : String,
  mix_source : String,
  format : String,
  rate : Int32,
  options : AudioPostOptions,
) -> String raise {
  let audio = decode_audio_at_rate(source, rate)
  let rate = audio.sample_rate()
  let mix = if mix_source.is_empty() || options.mix_weight == 0.0 {
    None
  } else {
    Some(decode_audio_at_rate(mix_source, rate).samples())
  }
  let (samples, summary) = apply_audio_post(audio.samples(), mix, rate, options)
  let channels = samples.length()
  let bytes = demo_encode_audio(samples, rate, format)
  let duration = samples[0].length().to_double() / rate.to_double()
  env_ok(
    audio_fields(format, bytes, rate, channels, Some(duration)) +
    ",\"processing\":" +
    summary.stringify(),
  )
}

///|
/// Decode the first audio stream of each input, apply optional PCM effects
/// and export the selected audio format. An empty secondary input disables mixing.
#export_name("ff_process_audio")
pub fn ff_process_audio(
  source : String,
  mix_source : String,
  format : String,
  rate : Int32,
  trim : Bool,
  fade_in : Double,
  fade_out : Double,
  normalize : Bool,
  target_lufs : Double,
  ceiling_dbfs : Double,
  mix_weight : Double,
) -> String {
  let options = {
    trim,
    fade_in,
    fade_out,
    normalize,
    target_lufs,
    ceiling_dbfs,
    mix_weight,
  }
  guard audio_post_valid(options) &&
    demo_audio_format(format) &&
    (rate == 0 || (rate >= 8000 && rate <= 192000)) else {
    return env_err_code(
      "AUDIO_POST_FAILED", "音频后期处理参数超出范围。",
    )
  }
  export_processed_audio(source, mix_source, format, rate, options) catch {
    error => env_err_code("AUDIO_POST_FAILED", error.to_string())
  }
}
