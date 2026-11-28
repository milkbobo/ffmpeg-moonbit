///|
/// Berkeley/IRCAM/CARL Sound Format from FFmpeg 9.0.2 ircam*.c.
/// Copyright (c) 2012 Paul B Mahol. LGPL-2.1-or-later.
let ircam_codecs : FixedArray[(Int64, String, String, Int32)] = [
  (0x00001L, "pcm_s8", "pcm_s8", 1),
  (0x00002L, "pcm_s16le", "pcm_s16be", 2),
  (0x00003L, "pcm_s24le", "pcm_s24be", 3),
  (0x00004L, "pcm_f32le", "pcm_f32be", 4),
  (0x00008L, "pcm_f64le", "pcm_f64be", 8),
  (0x10001L, "pcm_alaw", "pcm_alaw", 1),
  (0x20001L, "pcm_mulaw", "pcm_mulaw", 1),
  (0x40004L, "pcm_s32le", "pcm_s32be", 4),
]

///|
let ircam_header_size = 1024

///|
fn ircam_big_endian(data : BytesView) -> Bool? {
  match wav_u32(data, 0, false) {
    0x64A30100L | 0x64A30300L | 0x0002A364L => Some(true)
    0x64A30200L | 0x64A30400L | 0x0001A364L | 0x0003A364L => Some(false)
    _ => None
  }
}

///|
fn probe_ircam(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 16 &&
    ircam_big_endian(data[:]) is Some(_) &&
    wav_u32(data[:], 4, false) != 0L &&
    wav_u32(data[:], 8, false) != 0L {
    probe_score_max * 3 / 4
  } else {
    0
  }
}

///|
fn ircam_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= ircam_header_size else {
    return Err("ircam: truncated header")
  }
  let view = data[:]
  guard ircam_big_endian(view) is Some(be) else {
    return Err("ircam: unrecognized header")
  }
  let rate = Float::reinterpret_from_uint(
    wav_u32(view, 4, be).to_int().reinterpret_as_uint(),
  ).to_double()
  let channels = wav_u32(view, 8, be)
  guard rate > 0.5 && rate <= 2147483647.0 && channels >= 1L && channels <= 512L else {
    return Err("ircam: invalid sample rate or channel count")
  }
  let rate_floor = rate.floor().to_int()
  let fraction = rate - rate_floor.to_double()
  let sample_rate = if fraction > 0.5 ||
    (fraction == 0.5 && rate_floor % 2 == 1) {
    rate_floor + 1
  } else {
    rate_floor
  }
  let codec_tag = wav_u32(view, 12, be)
  for entry in ircam_codecs {
    let (tag, le, big, width) = entry
    if tag == codec_tag {
      let ch = channels.to_int()
      let payload = data.length() - ircam_header_size
      guard payload % (ch * width) == 0 else {
        return Err("ircam: incomplete PCM frame")
      }
      return Ok(
        raw_pcm_track(
          data.length(),
          ircam_header_size,
          if be {
            big
          } else {
            le
          },
          sample_rate,
          ch,
          width,
        ),
      )
    }
  }
  Err("ircam: unsupported encoding tag")
}

///|
/// Write little-endian IRCAM with the specified PCM or G.711 codec.
pub fn DecodedAudio::to_ircam(
  self : DecodedAudio,
  codec~ : String = "pcm_s16le",
) -> Bytes raise MediaError {
  let mut tag = 0L
  let mut width = 0
  for entry in ircam_codecs {
    let (code, le, _, bytes) = entry
    if codec == le {
      tag = code
      width = bytes
      break
    }
  }
  guard width > 0 else { raise UnsupportedCodec("IRCAM export: " + codec) }
  let rate = Float::from_int(self.sample_rate)
  guard rate >= 1.0F &&
    rate.to_double() <= 2147483647.0 &&
    self.channels >= 1 &&
    self.channels <= 512 else {
    raise DecodeError("ircam: invalid sample rate or channel count")
  }
  let frames = self.samples[0].length()
  let payload = frames.to_int64() * self.channels.to_int64() * width.to_int64()
  guard payload <= 0x7fffffffL - ircam_header_size.to_int64() else {
    raise DecodeError("ircam: PCM exceeds output buffer limit")
  }
  let out : Array[Byte] = Array(capacity=ircam_header_size + payload.to_int())
  wav_mux_u32(out, 0x0001A364U)
  wav_mux_u32(out, rate.reinterpret_as_uint())
  wav_mux_u32(out, self.channels.reinterpret_as_uint())
  wav_mux_u32(out, tag.to_int().reinterpret_as_uint())
  for _ in 16..<ircam_header_size {
    out.push(0)
  }
  if codec == "pcm_alaw" || codec == "pcm_mulaw" {
    let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
      error => raise DecodeError(error.to_string())
    }
    let encoded = if codec == "pcm_alaw" {
      @libavcodec.pcm_alaw_encode(samples[:])
    } else {
      @libavcodec.pcm_mulaw_encode(samples[:])
    }
    for byte in encoded {
      out.push(byte)
    }
  } else {
    for frame in 0..<frames {
      for plane in self.samples {
        let sample = plane[frame]
        match codec {
          "pcm_f32le" =>
            wav_mux_u32(out, Float::from_double(sample).reinterpret_as_uint())
          "pcm_f64le" =>
            wav_mux_u64(
              out,
              sample.reinterpret_as_uint64().reinterpret_as_int64(),
            )
          _ => {
            let quantized = playback_pcm_quantize(sample, width * 8)
            for byte in 0..<width {
              out.push((quantized >> (8 * byte)).to_byte())
            }
          }
        }
      }
    }
  }
  Bytes::from_array(out)
}
