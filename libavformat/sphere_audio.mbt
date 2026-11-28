///|
/// NIST SPHERE fields from FFmpeg 9.0.2 nistspheredec.c.
/// Copyright (c) 2012 Paul B Mahol. LGPL-2.1-or-later.
let sphere_magic : Bytes = b"NIST_1A\n"

///|
let sphere_encodings : FixedArray[(String, String, String, Int32, String)] = [
  ("pcm_s8", "pcm", "1", 1, "pcm_s8"),
  ("pcm_s16le", "pcm", "01", 2, "pcm_s16be"),
  ("pcm_s24le", "pcm", "01", 3, "pcm_s24be"),
  ("pcm_s32le", "pcm", "01", 4, "pcm_s32be"),
  ("pcm_alaw", "alaw", "1", 1, "pcm_alaw"),
  ("pcm_mulaw", "ulaw", "1", 1, "pcm_mulaw"),
]

///|
fn probe_sphere(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 8 && pd.buf[:8] == sphere_magic {
    probe_score_max
  } else {
    0
  }
}

///|
fn sphere_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_sphere(ProbeData::new(data)) > 0 else {
    return Err("sphere: invalid signature")
  }
  let mut line_end = 8
  while line_end < data.length() && data[line_end] != b'\n' && line_end - 8 < 32 {
    line_end += 1
  }
  guard line_end < data.length() && data[line_end] == b'\n' else {
    return Err("sphere: missing header size")
  }
  let start = @string.parse_int(
    probe_ascii(data[8:line_end].to_owned())[:].trim(),
  ) catch {
    _ => return Err("sphere: invalid header size")
  }
  guard start > line_end + 1 && start <= data.length() else {
    return Err("sphere: truncated header")
  }
  let header = probe_ascii(data[line_end + 1:start].to_owned())
  let mut rate = 0
  let mut channels = 0
  let mut width = 0
  let mut valid_bits = 0
  let mut coding = "pcm"
  let mut order = "01"
  let mut ended = false
  for raw_line in header.split("\n") {
    let line = raw_line.trim()
    if line == "end_head" {
      ended = true
      break
    }
    let fields = line
      .replace_all(old="\t", new=" ")
      .split(" ")
      .filter(field => !field.is_empty())
      .take(3)
      .collect()
    match fields {
      [key, "-i", value] =>
        match key {
          "sample_rate"
          | "channel_count"
          | "sample_n_bytes"
          | "sample_sig_bits" => {
            let num = @string.parse_int(value) catch {
              _ => return Err("sphere: invalid numeric field")
            }
            match key {
              "sample_rate" => rate = num
              "channel_count" => channels = num
              "sample_n_bytes" => width = num
              _ => valid_bits = num
            }
          }
          _ => ()
        }
      ["sample_coding", _, value] => coding = value.to_lower().to_owned()
      ["sample_byte_format", _, value] => order = value.to_lower().to_owned()
      _ => ()
    }
  }
  guard ended && rate > 0 && channels > 0 && channels <= 512 else {
    return Err("sphere: missing end_head or invalid stream parameters")
  }
  if coding == "mu-law" || (coding == "pcm" && order == "mu-law") {
    coding = "ulaw"
  }
  if width == 0 && valid_bits > 0 && valid_bits <= 32 {
    width = (valid_bits + 7) / 8
  }
  if width == 0 && (coding == "alaw" || coding == "ulaw") {
    width = 1
  }
  guard width >= 1 && width <= 4 && valid_bits >= 0 && valid_bits <= width * 8 else {
    return Err("sphere: invalid sample width")
  }
  let be = match order {
    "01" | "012" | "0123" => false
    "10" | "210" | "3210" => true
    "1" | "mu-law" if width == 1 => false
    _ => return Err("sphere: unsupported sample byte order")
  }
  for (little, name, _, bytes, big) in sphere_encodings {
    if name == coding && bytes == width {
      guard (data.length() - start) % (width * channels) == 0 else {
        return Err("sphere: incomplete PCM frame")
      }
      return Ok(
        raw_pcm_track(
          data.length(),
          start,
          if be {
            big
          } else {
            little
          },
          rate,
          channels,
          width,
        ),
      )
    }
  }
  Err("sphere: unsupported encoding")
}

///|
/// Write NIST SPHERE with signed integer PCM or G.711.
pub fn DecodedAudio::to_sphere(
  self : DecodedAudio,
  codec~ : String = "pcm_s16le",
) -> Bytes raise MediaError {
  let mut encoding = None
  for (little, name, order, width, big) in sphere_encodings {
    if codec == little || codec == big {
      let be = codec != little
      encoding = Some((name, if be { "10" } else { order }, width, be))
      break
    }
  }
  guard encoding is Some((name, order, width, be)) else {
    raise UnsupportedCodec("SPHERE export: " + codec)
  }
  guard self.channels > 0 && self.channels <= 512 && self.sample_rate > 0 else {
    raise DecodeError("sphere: invalid stream parameters")
  }
  let frames = self.samples[0].length()
  let payload = frames.to_int64() * self.channels.to_int64() * width.to_int64()
  guard payload <= 0x7fffffffL - 1024L else {
    raise DecodeError("sphere: PCM exceeds output buffer limit")
  }
  let header = "NIST_1A\n   1024\nchannel_count -i \{self.channels}\nsample_count -i \{frames}\nsample_rate -i \{self.sample_rate}\nsample_n_bytes -i \{width}\nsample_sig_bits -i \{width * 8}\nsample_byte_format -s\{order.length()} \{order}\nsample_coding -s\{name.length()} \{name}\nend_head\n"
  let out : Array[Byte] = Array(capacity=1024 + payload.to_int())
  wav_mux_tag(out, header)
  for _ in out.length()..<1024 {
    out.push(b' ')
  }
  if name == "pcm" {
    for frame in 0..<frames {
      for plane in self.samples {
        let sample = playback_pcm_quantize(plane[frame], width * 8)
        for byte in 0..<width {
          let shift = (if be { width - 1 - byte } else { byte }) * 8
          out.push((sample >> shift).to_byte())
        }
      }
    }
  } else {
    let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
      error => raise DecodeError(error.to_string())
    }
    let encoded = if name == "alaw" {
      @libavcodec.pcm_alaw_encode(samples[:])
    } else {
      @libavcodec.pcm_mulaw_encode(samples[:])
    }
    for byte in encoded {
      out.push(byte)
    }
  }
  Bytes::from_array(out)
}
