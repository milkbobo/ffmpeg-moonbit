///|
fn demo_audio_format(format : String) -> Bool {
  ["wav", "flac", "wv", "ac3", "ogg"].contains(format)
}

///|
fn demo_encode_vorbis(
  samples : Array[Array[Double]],
  rate : Int32,
) -> Bytes raise {
  let enc = demo_result(@avc.vorbis_encoder_new(rate, samples.length()))
  guard enc.extradata() is Some(headers) else { fail("missing Vorbis headers") }
  let (id, comment, setup) = @avc.vorbis_e2e_split_extradata(headers)
  let mux = demo_result(@avf.ogg_vorbis_muxer_new(id, comment, setup))
  let block_size = 1024
  let total = samples[0].length()
  // The first packet primes the overlap. One extra block drains the tail.
  for start = 0; start < total + block_size; start = start + block_size {
    let queue = Array::makei(block_size / enc.frame_size, frame => {
      Array::makei(enc.frame_size * 2, i => {
        let pos = start + frame * enc.frame_size + i / 2
        if pos < total {
          samples[i % 2][pos]
        } else {
          0.0
        }
      })
    })
    let packet = demo_result(enc.encode(queue, 0, queue.length(), false))
    let duration = start.min(total) - (start - block_size).max(0).min(total)
    mux.write_packet(packet, duration)
  }
  mux.finish()
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
      demo_encode_vorbis(samples, rate)
    }
    "ac3" => {
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
      demo_result(
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
