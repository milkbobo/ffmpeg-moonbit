///|
/// Amiga MAUD layout from FFmpeg 9.0.2 iff.c and the SoX MAUD handler.
fn probe_maud(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 12 && data[:4] == b"FORM" && data[8:12] == b"MAUD" {
    probe_score_max
  } else {
    0
  }
}

///|
fn maud_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_maud(ProbeData::new(data)) > 0 else {
    return Err("maud: invalid FORM")
  }
  let size = pb_be32(data, 4).to_int64()
  guard size >= 4L && size <= (data.length() - 8).to_int64() else {
    return Err("maud: invalid FORM size")
  }
  let end = 8 + size.to_int()
  let mut header = -1
  let mut body = -1
  let mut body_size = 0
  for pos = 12; pos < end; {
    guard pos <= end - 8 else { return Err("maud: truncated chunk header") }
    let start = pos + 8
    let length = pb_be32(data, pos + 4).to_int64()
    let padded = length + (length & 1L)
    guard padded <= (end - start).to_int64() else {
      return Err("maud: truncated chunk")
    }
    match wav_fourcc(data[:], pos) {
      "MHDR" => {
        guard header < 0 && length >= 32L else {
          return Err("maud: invalid MHDR chunk")
        }
        header = start
      }
      "MDAT" => {
        guard body < 0 else { return Err("maud: duplicate MDAT chunk") }
        body = start
        body_size = length.to_int()
      }
      _ => ()
    }
    continue start + padded.to_int()
  }
  guard header >= 0 && body >= 0 && body_size > 0 else {
    return Err("maud: missing MHDR or audio payload")
  }
  let divisor = pb_be16(data, header + 12).to_int64()
  guard divisor != 0L else { return Err("maud: zero clock divisor") }
  let rate = pb_be32(data, header + 8).to_int64() / divisor
  let channels = pb_be16(data, header + 16).reinterpret_as_int()
  guard rate >= 1L && rate <= 0x7fffffffL && channels > 0 && channels <= 512 else {
    return Err("maud: invalid stream parameters")
  }
  let (codec, width) = match
    (pb_be16(data, header + 4), pb_be16(data, header + 18)) {
    (8U, 0U) => ("pcm_u8", 1)
    (16U, 0U) => ("pcm_s16be", 2)
    (8U, 2U) => ("pcm_alaw", 1)
    (8U, 3U) => ("pcm_mulaw", 1)
    _ => return Err("maud: unsupported sample encoding")
  }
  guard body_size % (channels * width) == 0 else {
    return Err("maud: incomplete sample frame")
  }
  Ok(
    raw_pcm_track(body + body_size, body, codec, rate.to_int(), channels, width),
  )
}

///|
/// Write mono or stereo Amiga MAUD with integer PCM or G.711.
pub fn DecodedAudio::to_maud(
  self : DecodedAudio,
  codec~ : String = "pcm_s16be",
) -> Bytes raise MediaError {
  let (width, compression) = match codec {
    "pcm_u8" => (1, 0)
    "pcm_s16be" => (2, 0)
    "pcm_alaw" => (1, 2)
    "pcm_mulaw" => (1, 3)
    _ => raise UnsupportedCodec("MAUD export: " + codec)
  }
  let channels = self.channels
  guard (channels == 1 || channels == 2) && self.sample_rate > 0 else {
    raise UnsupportedCodec(
      "MAUD export requires mono or stereo and a valid sample rate",
    )
  }
  let frames = self.samples[0].length()
  let samples = frames.to_int64() * channels.to_int64()
  let size = samples * width.to_int64()
  let pad = size & 1L
  guard frames > 0 && size + pad <= 0x7fffffffL - 60L else {
    raise DecodeError("maud: invalid audio payload size")
  }
  let out : Array[Byte] = Array(capacity=60 + (size + pad).to_int())
  wav_mux_tag(out, "FORM")
  aiff_mux_u32be(out, (52L + size + pad).to_int().reinterpret_as_uint())
  wav_mux_tag(out, "MAUD")
  wav_mux_tag(out, "MHDR")
  aiff_mux_u32be(out, 32U)
  aiff_mux_u32be(out, samples.to_int().reinterpret_as_uint())
  aiff_mux_u16be(out, width * 8)
  aiff_mux_u16be(out, if compression == 0 { width * 8 } else { 16 })
  aiff_mux_u32be(out, self.sample_rate.reinterpret_as_uint())
  aiff_mux_u16be(out, 1) // sample clock divisor
  aiff_mux_u16be(out, channels - 1)
  aiff_mux_u16be(out, channels)
  aiff_mux_u16be(out, compression)
  for _ in 0..<12 {
    out.push(0)
  }
  wav_mux_tag(out, "MDAT")
  aiff_mux_u32be(out, size.to_int().reinterpret_as_uint())
  if compression == 0 {
    for frame in 0..<frames {
      for plane in self.samples {
        let sample = playback_pcm_quantize(plane[frame], width * 8)
        if width == 1 {
          out.push((sample + 128).to_byte())
        } else {
          aiff_mux_u16be(out, sample)
        }
      }
    }
  } else {
    let s16 = @swr.swr_flt_planar_to_s16(self.samples, channels) catch {
      error => raise DecodeError(error.to_string())
    }
    let payload = if compression == 2 {
      @libavcodec.pcm_alaw_encode(s16[:])
    } else {
      @libavcodec.pcm_mulaw_encode(s16[:])
    }
    for byte in payload {
      out.push(byte)
    }
  }
  if pad != 0L {
    out.push(0)
  }
  Bytes::from_array(out)
}
