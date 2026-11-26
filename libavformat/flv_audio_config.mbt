///|
priv struct FlvAudioConfig {
  codec : String
  extradata : Bytes
  sample_rate : Int32
  channels : Int32
  frame_samples : Int32
  priming : Int32
  self_delimiting : Bool
}

///|
fn flv_audio_config(codec : String, data : Bytes) -> Result[FlvAudioConfig, String] {
  let (sample_rate, channels, frame_samples, priming, self_delimiting) = match codec {
    "aac" => {
      let config = match @libavcodec.aac_parse_audio_specific_config(data) {
        Ok(v) => v.config
        Err(e) => return Err(e)
      }
      (config.sample_rate, config.channels, config.frame_length, 0, false)
    }
    "opus" => {
      let head = match @libavcodec.opus_parse_head(data) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      (48000, head.channels, 0, head.pre_skip, head.stream_count > 1)
    }
    "flac" => {
      if data.length() != 34 {
        return Err("invalid FLAC STREAMINFO")
      }
      let packed = flv_u32be(data, 10)
      let rate = (packed >> 12).reinterpret_as_int()
      if rate == 0 {
        return Err("invalid FLAC sample rate")
      }
      (rate, ((packed >> 9) & 7).reinterpret_as_int() + 1, 0, 0, false)
    }
    _ => return Err("unsupported audio sequence header")
  }
  Ok({ codec, extradata: data, sample_rate, channels, frame_samples, priming, self_delimiting })
}

///|
fn FlvAudioConfig::samples(
  self : FlvAudioConfig,
  data : BytesView,
) -> Result[Int32, String] {
  match self.codec {
    "opus" => match @libavcodec.opus_parse_packet_with(data.to_owned(), self.self_delimiting) {
      Ok(packet) => Ok(packet.total_samples())
      Err(e) => Err(e)
    }
    "flac" => @libavcodec.flac_frame_samples(data.to_owned())
    _ => Ok(self.frame_samples)
  }
}

///|
/// Parse the single-track Enhanced FLV audio prefix.
fn flv_enhanced_audio_tag(data : Bytes, body : Int32, end : Int32) -> Result[(String, Int32, Int32), String] {
  if end - body < 5 {
    return Err("flv: truncated enhanced audio tag")
  }
  let kind = data[body].to_int() & 15
  if kind == 5 {
    return Err("flv: unsupported enhanced audio multitrack tag")
  }
  let codec = match data[body + 1:body + 5].to_owned() {
    b"mp4a" => "aac"
    b".mp3" => "mp3"
    b"Opus" => "opus"
    b"fLaC" => "flac"
    b"ac-3" => "ac3"
    b"ec-3" => "eac3"
    _ => return Err("flv: unsupported enhanced audio codec")
  }
  Ok((codec, kind, body + 5))
}
