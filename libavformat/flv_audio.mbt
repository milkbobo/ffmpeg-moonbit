///|
/// An FLV audio tag's codec payload and millisecond timestamp.
pub struct FlvAudioPacket {
  pos : Int32
  size : Int32
  pts : Int64
}

///|
/// A single FLV audio track. Video and script tags are skipped.
pub struct FlvAudioDemux {
  codec : String
  sample_rate : Int32
  channels : Int32
  extradata : Bytes?
  /// Initial decoder samples outside the presentation.
  priming : Int32
  packets : Array[FlvAudioPacket]
  duration : Double
}

///|
fn flv_u24be(data : Bytes, pos : Int32) -> Int32 {
  (data[pos].to_int() << 16) |
  (data[pos + 1].to_int() << 8) |
  data[pos + 2].to_int()
}

///|
fn flv_u32be(data : Bytes, pos : Int32) -> UInt32 {
  (data[pos].to_uint() << 24) | flv_u24be(data, pos + 1).reinterpret_as_uint()
}

///|
fn flv_header_end(data : Bytes) -> Int32? {
  guard data.length() >= 13 &&
    data[0] == b'F' &&
    data[1] == b'L' &&
    data[2] == b'V' &&
    data[3] == 1 else {
    return None
  }
  let offset = flv_u32be(data, 5)
  guard offset >= 9U && offset.to_uint64() <= (data.length() - 4).to_uint64() else {
    return None
  }
  Some(offset.reinterpret_as_int())
}

///|
fn probe_flv(pd : ProbeData) -> Int32 {
  if flv_header_end(pd.buf) is Some(_) {
    probe_score_max
  } else {
    0
  }
}

///|
/// Split MP3 frames in one tag, deriving timestamps from its first frame.
fn flv_mp3_frames(
  data : Bytes,
  first : Int32,
  end : Int32,
  pts : Int64,
  packets : Array[FlvAudioPacket],
) -> Result[(Int32, Int32, Int32), String] {
  let mut pos = first
  let mut samples = 0
  let mut rate = 0
  let mut channels = 0
  while pos < end {
    if end - pos < 4 {
      return Err("flv: truncated MP3 header")
    }
    let header = match
      @libavcodec.avpriv_mpegaudio_decode_header(flv_u32be(data, pos)) {
      Ok(v) => v
      Err(_) => return Err("flv: invalid MP3 header")
    }
    if header.layer != 3 ||
      header.frame_size < 4 ||
      header.frame_size > end - pos {
      return Err("flv: invalid MP3 frame size")
    }
    if pos == first {
      rate = header.sample_rate
      channels = header.nb_channels
    } else if rate != header.sample_rate || channels != header.nb_channels {
      return Err("flv: audio stream parameters changed")
    }
    let delta = (samples.to_int64() * 1000L + rate.to_int64() / 2L) /
      rate.to_int64()
    packets.push({ pos, size: header.frame_size, pts: pts + delta, })
    pos += header.frame_size
    samples += if header.lsf == 0 { 1152 } else { 576 }
  }
  Ok((rate, channels, samples))
}

///|
/// Open legacy or single-track Enhanced FLV audio. Packet timestamps retain
/// their unsigned millisecond values from the file.
///
/// ```mbt check
/// test {
///   assert_true(
///     @libavformat.av_flv_audio_open(b"FLV") is Err("flv: invalid header"),
///   )
/// }
/// ```
pub fn av_flv_audio_open(data : Bytes) -> Result[FlvAudioDemux, String] {
  guard flv_header_end(data) is Some(header_end) else {
    return Err("flv: invalid header")
  }
  if flv_u32be(data, header_end) != 0U {
    return Err("flv: invalid initial previous tag size")
  }
  let mut pos = header_end + 4
  let mut config : FlvAudioConfig? = None
  let mut stream : (String, Int32, Int32)? = None
  let mut end_time = 0.0
  let packets : Array[FlvAudioPacket] = []
  while pos < data.length() {
    if data.length() - pos < 15 {
      return Err("flv: truncated tag")
    }
    let tag = data[pos].to_int()
    let size = flv_u24be(data, pos + 1)
    let pts = flv_u24be(data, pos + 4).to_int64() |
      (data[pos + 7].to_int64() << 24)
    let body = pos + 11
    if size > data.length() - body - 4 {
      return Err("flv: truncated tag payload")
    }
    let end = body + size
    if flv_u32be(data, end) != (11 + size).reinterpret_as_uint() {
      return Err("flv: invalid previous tag size")
    }
    pos = end + 4
    if (tag & 31) != 8 || size == 0 {
      continue
    }
    if tag != 8 {
      return Err("flv: unsupported audio tag flags")
    }
    let flags = data[body].to_int()
    let format = flags >> 4
    let (codec, kind, start) = match format {
      9 =>
        match flv_enhanced_audio_tag(data, body, end) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      10 => {
        if end - body < 2 {
          return Err("flv: truncated AAC tag")
        }
        ("aac", data[body + 1].to_int(), body + 2)
      }
      1 => ("adpcm_swf", 1, body + 1)
      2 => ("mp3", 1, body + 1)
      7 => ("pcm_alaw", 1, body + 1)
      8 => ("pcm_mulaw", 1, body + 1)
      0 | 3 =>
        (if (flags & 2) != 0 { "pcm_s16le" } else { "pcm_u8" }, 1, body + 1)
      _ => return Err("flv: unsupported sound format \{format}")
    }
    if kind == 0 {
      if codec == "aac" || codec == "opus" || codec == "flac" {
        let extradata = data[start:end].to_owned()
        if config is Some(previous) {
          // The FLV muxer emits final FLAC length, frame sizes and MD5 at EOF.
          let flac_update = codec == "flac" &&
            previous.codec == "flac" &&
            extradata.length() == 34 &&
            flv_u32be(previous.extradata, 10) >> 4 ==
            flv_u32be(extradata, 10) >> 4
          if previous.codec != codec ||
            (previous.extradata != extradata && !flac_update) {
            return Err("flv: audio sequence header changed")
          }
          if flac_update {
            config = Some({ ..previous, extradata, })
          }
        } else {
          config = match flv_audio_config(codec, extradata) {
            Ok(v) => Some(v)
            Err(e) => return Err("flv: \{e}")
          }
        }
      }
      continue
    }
    if format == 9 && kind == 4 {
      // Native and unspecified layouts use the codec's channel order.
      let payload = end - start
      if payload < 2 || data[start + 1] == 0 {
        return Err("flv: truncated channel configuration")
      }
      match data[start] {
        0 if payload == 2 => ()
        1 if payload == 6 => ()
        _ => return Err("flv: unsupported channel configuration")
      }
      continue
    }
    if format == 9 && kind == 2 {
      continue
    }
    if codec == "flac" && kind == 1 && start == end {
      continue
    }
    if kind != 1 || start >= end {
      return Err("flv: invalid coded audio tag")
    }
    let payload = end - start
    let (rate, channels, samples) = match codec {
      "aac" | "opus" | "flac" => {
        guard config is Some(active) && active.codec == codec else {
          return Err("flv: missing \{codec} sequence header")
        }
        let samples = match active.samples(data[start:end]) {
          Ok(v) => v
          Err(e) => return Err("flv: \{e}")
        }
        (active.sample_rate, active.channels, samples)
      }
      "mp3" => {
        let (rate, channels, samples) = match
          flv_mp3_frames(data, start, end, pts, packets) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        (rate, channels, samples)
      }
      "ac3" | "eac3" => {
        let header = match
          @libavcodec.ac3_parse_header(data[start:end].to_owned()) {
          Ok(v) => v
          Err(e) => return Err("flv: \{e}")
        }
        if header.frame_size != payload ||
          (header.bitstream_id > 10) != (codec == "eac3") {
          return Err("flv: invalid Dolby audio frame")
        }
        (header.sample_rate, header.channels, 256 * header.num_blocks)
      }
      "adpcm_swf" => {
        let rate = 44100 << ((flags >> 2) & 3) >> 3
        let channels = (flags & 1) + 1
        let samples = match
          @libavcodec.swf_adpcm_samples(data[start:end], channels) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        (rate, channels, samples)
      }
      _ => {
        let channels = (flags & 1) + 1
        let (rate, width) = match codec {
          "pcm_alaw" | "pcm_mulaw" => (8000, 1)
          "pcm_s16le" => (44100 << ((flags >> 2) & 3) >> 3, 2)
          _ => (44100 << ((flags >> 2) & 3) >> 3, 1)
        }
        let stride = channels * width
        if payload % stride != 0 {
          return Err("flv: incomplete PCM sample frame")
        }
        (rate, channels, payload / stride)
      }
    }
    let parameters = (codec, rate, channels)
    if stream is Some(previous) && previous != parameters {
      return Err("flv: audio stream parameters changed")
    }
    stream = Some(parameters)
    if codec != "mp3" {
      packets.push({ pos: start, size: payload, pts, })
    }
    end_time = end_time.max(
      pts.to_double() / 1000.0 + samples.to_double() / rate.to_double(),
    )
  }
  guard stream is Some((codec, sample_rate, channels)) else {
    return Err("flv: no audio packets")
  }
  let (extradata, priming) = match config {
    Some(active) if active.codec == codec =>
      (Some(active.extradata), active.priming)
    _ => (None, 0)
  }
  Ok({
    codec,
    sample_rate,
    channels,
    extradata,
    priming,
    packets,
    duration: (end_time -
    packets[0].pts.to_double() / 1000.0 -
    priming.to_double() / sample_rate.to_double()).max(0.0),
  })
}
