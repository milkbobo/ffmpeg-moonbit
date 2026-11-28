///|
fn demo_audio_format(format : String) -> Bool {
  ["wav", "flac", "wv", "ac3", "spdif", "ogg"].contains(format)
}

///|
fn demo_encode_audio(
  samples : Array[Array[Double]],
  rate : Int32,
  format : String,
) -> Bytes raise {
  guard samples.get(0) is Some(first) && !first.is_empty() else {
    fail("音轨没有可导出的样本。")
  }
  let channels = samples.length()
  match format {
    "ogg" => {
      guard channels == 2 else {
        fail("Ogg/Vorbis 导出需要立体声音轨。")
      }
      demo_result(@avf.av_ogg_encode_vorbis(samples, rate))
    }
    "ac3" | "spdif" => {
      guard channels == 1 || channels == 2 else {
        fail("AC-3 导出支持单声道和立体声。")
      }
      guard [32000, 44100, 48000].contains(rate) else {
        fail("请选择 32、44.1 或 48 kHz 采样率。")
      }
      let padded = (first.length() + 1535) / 1536 * 1536
      let planes = samples.map(plane => {
        FixedArray::makei(padded, i => {
          if i < plane.length() {
            @swr.swr_flt_to_s16(plane[i]) << 16
          } else {
            0
          }
        })
      })
      let ac3 = demo_result(
        @avc.ff_ac3_fixed_encode_stream(
          planes,
          rate,
          0,
          if channels == 1 {
            4
          } else {
            3
          },
        ),
      )
      if format == "spdif" {
        demo_result(@avf.av_spdif_mux(ac3, codec="ac3"))
      } else {
        ac3
      }
    }
    "wv" | "flac" | "wav" => {
      let pcm = @swr.swr_flt_planar_to_s16(samples, channels)
      match format {
        "wv" => demo_result(@avc.ff_wavpack_encode(pcm[:], rate, channels, 16))
        "flac" => demo_result(@avc.flac_encode(pcm, channels, rate, 16)).file()
        _ => {
          let mux = demo_result(@avf.wav_muxer_new(rate, channels, 16))
          mux.write_samples(pcm[:])
          mux.finish()
        }
      }
    }
    _ => fail("不支持的音频输出格式。")
  }
}

///|
/// Export the first audio track in the selected file format.
#export_name("ff_export_audio")
pub fn ff_export_audio(data : String, rate : Int32, format : String) -> String {
  guard demo_audio_format(format) &&
    (rate == 0 || (rate >= 8000 && rate <= 192000)) else {
    return env_err_code(
      "AUDIO_CONVERSION_FAILED", "音频导出参数超出范围。",
    )
  }
  let audio = decode_audio_at_rate(data, rate) catch { e => return env_err(e) }
  let bytes = demo_encode_audio(audio.samples(), audio.sample_rate(), format) catch {
    e => return env_err_code("AUDIO_CONVERSION_FAILED", e.to_string())
  }
  audio_result(audio, format, bytes)
}
