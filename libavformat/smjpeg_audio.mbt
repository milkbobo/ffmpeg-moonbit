///|
/// Loki SMJPEG audio framing from FFmpeg 9.0.2 smjpegdec.c and smjpegenc.c.
/// LGPL-2.1-or-later.
let smjpeg_magic : Bytes = b"\x00\x0aSMJPEG"

///|
fn probe_smjpeg(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 8 && pd.buf[:8] == smjpeg_magic {
    probe_score_max
  } else {
    0
  }
}

///|
fn smjpeg_audio_open(data : Bytes) -> Result[(RawAudioTrack, Int64), String] {
  guard data.length() >= 20 && data[:8] == smjpeg_magic else {
    return Err("smjpeg: invalid header")
  }
  let declared_ms = pb_be32(data, 12).to_int64()
  let mut pos = 16
  let mut rate = 0
  let mut channels = 0
  let mut codec = ""
  let mut video = false
  while true {
    guard data.length() - pos >= 4 else { return Err("smjpeg: missing HEND") }
    let kind = data[pos:pos + 4]
    if kind == b"HEND" {
      pos += 4
      break
    }
    guard data.length() - pos >= 8 else {
      return Err("smjpeg: truncated header chunk")
    }
    let size = pb_be32(data, pos + 4).to_int64()
    let body = pos + 8
    guard size <= (data.length() - body).to_int64() else {
      return Err("smjpeg: truncated header payload")
    }
    match kind {
      [b'_', b'S', b'N', b'D'] => {
        guard size >= 8L && codec == "" else {
          return Err("smjpeg: invalid audio header")
        }
        rate = (data[body].to_int() << 8) | data[body + 1].to_int()
        channels = data[body + 3].to_int()
        match data[body + 4:body + 8] {
          [b'A', b'P', b'C', b'M'] => codec = "adpcm_ima_smjpeg"
          [b'N', b'O', b'N', b'E'] => codec = "pcm_s16le"
          _ => return Err("smjpeg: unsupported audio codec")
        }
      }
      [b'_', b'V', b'I', b'D'] => {
        guard size >= 12L && !video else {
          return Err("smjpeg: invalid video header")
        }
        video = true
      }
      [b'_', b'T', b'X', b'T'] => {
        guard size >= 1L && size <= 512L else {
          return Err("smjpeg: invalid text chunk")
        }
      }
      _ => return Err("smjpeg: unknown header chunk")
    }
    pos = body + size.to_int()
  }
  guard rate > 0 && (channels == 1 || channels == 2) else {
    return Err("smjpeg: missing audio or invalid audio parameters")
  }
  let compressed = codec == "adpcm_ima_smjpeg"
  let frames : Array[RawAudioFrame] = []
  let mut total = 0L
  while pos < data.length() {
    guard data.length() - pos >= 4 else {
      return Err("smjpeg: truncated packet tag")
    }
    let kind = data[pos:pos + 4]
    if kind == b"DONE" {
      break
    }
    guard data.length() - pos >= 12 else {
      return Err("smjpeg: truncated packet header")
    }
    let pts = pb_be32(data, pos + 4).to_int64()
    let size = pb_be32(data, pos + 8).to_int64()
    let body = pos + 12
    guard size <= (data.length() - body).to_int64() else {
      return Err("smjpeg: truncated packet")
    }
    if kind == b"sndD" {
      let bytes = size.to_int()
      let samples = if compressed {
        let audio = bytes - 4 * channels
        guard audio > 0 && audio <= 0x3fffffff else {
          return Err("smjpeg: invalid APCM payload size")
        }
        audio * 2 / channels
      } else {
        guard bytes > 0 && bytes % (2 * channels) == 0 else {
          return Err("smjpeg: invalid PCM payload size")
        }
        bytes / (2 * channels)
      }
      frames.push({
        pos: body.to_int64(),
        size: bytes,
        pts,
        duration: samples,
        is_keyframe: true,
      })
      total += samples.to_int64()
    } else if kind != b"vidD" || !video {
      return Err("smjpeg: unexpected packet tag")
    }
    pos = body + size.to_int()
  }
  guard !frames.is_empty() else { return Err("smjpeg: missing audio packets") }
  Ok(
    (
      {
        codec,
        profile: "",
        sample_rate: rate,
        channels,
        frame_size: frames[0].duration,
        frames,
        total_samples: total,
        bit_rate: rate * channels * (if compressed { 4 } else { 16 }),
        id3v2_size: 0,
        info_frame_size: 0,
      },
      declared_ms,
    ),
  )
}

///|
/// Write an audio-only Loki SMJPEG file with signed 16-bit little-endian PCM.
pub fn DecodedAudio::to_smjpeg_pcm(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("SMJPEG PCM export requires mono or stereo")
  }
  guard self.sample_rate > 0 && self.sample_rate <= 65535 else {
    raise DecodeError("SMJPEG PCM export requires a 16-bit sample rate")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let frames = samples.length() / self.channels
  guard frames > 0 else { raise DecodeError("SMJPEG PCM: no audio samples") }
  let rate = self.sample_rate.to_int64()
  let packet_frames = 1024
  let last_start = (frames - 1) / packet_frames * packet_frames
  let duration = (last_start.to_int64() * 1000L + rate / 2L) / rate +
    ((frames - last_start).to_int64() * 1000L + rate / 2L) / rate
  guard duration <= 0xffffffffL else {
    raise DecodeError("SMJPEG PCM duration exceeds header range")
  }
  let out = smjpeg_magic.to_array()
  aiff_mux_u32be(out, 0U)
  aiff_mux_u32be(out, duration.to_int().reinterpret_as_uint())
  wav_mux_tag(out, "_SND")
  aiff_mux_u32be(out, 8U)
  aiff_mux_u16be(out, self.sample_rate)
  out.push(16)
  out.push(self.channels.to_byte())
  wav_mux_tag(out, "NONE")
  wav_mux_tag(out, "HEND")
  for start = 0; start < frames; {
    let count = (frames - start).min(packet_frames)
    let pts = (start.to_int64() * 1000L + rate / 2L) / rate
    wav_mux_tag(out, "sndD")
    aiff_mux_u32be(out, pts.to_int().reinterpret_as_uint())
    aiff_mux_u32be(out, (count * self.channels * 2).reinterpret_as_uint())
    for i in (start * self.channels)..<((start + count) * self.channels) {
      wav_mux_u16(out, samples[i])
    }
    continue start + count
  }
  wav_mux_tag(out, "DONE")
  Bytes::from_array(out)
}
