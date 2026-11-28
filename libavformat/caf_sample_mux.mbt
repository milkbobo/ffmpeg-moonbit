///|
/// Write CAF with 32-/64-bit floating-point PCM or G.711 A-law/μ-law.
pub fn DecodedAudio::to_caf_samples(
  self : DecodedAudio,
  codec : String,
) -> Bytes raise MediaError {
  let (tag, width, flags) = match codec {
    "pcm_f32le" => ("lpcm", 4, 3U)
    "pcm_f32be" => ("lpcm", 4, 1U)
    "pcm_f64le" => ("lpcm", 8, 3U)
    "pcm_f64be" => ("lpcm", 8, 1U)
    "pcm_alaw" => ("alaw", 1, 0U)
    "pcm_mulaw" => ("ulaw", 1, 0U)
    _ => raise UnsupportedCodec("CAF export: " + codec)
  }
  let channels = self.channels
  guard self.sample_rate > 0 && channels > 0 && channels <= 32 else {
    raise DecodeError("caf: invalid sample rate or channel count")
  }
  let frames = self.samples[0].length()
  let align = width * channels
  let size = frames.to_int64() * align.to_int64()
  guard frames > 0 && size <= 0x7fffffffL - 92L else {
    raise DecodeError("caf: invalid audio payload size")
  }
  let desc : Array[Byte] = []
  caf_mux_double(desc, self.sample_rate.to_double())
  caf_mux_tag(desc, tag)
  caf_mux_u32be(desc, flags)
  caf_mux_u32be(desc, align.reinterpret_as_uint())
  caf_mux_u32be(desc, 1U)
  caf_mux_u32be(desc, channels.reinterpret_as_uint())
  caf_mux_u32be(desc, (width * 8).reinterpret_as_uint())
  let out : Array[Byte] = Array(capacity=92 + size.to_int())
  caf_mux_tag(out, "caff")
  caf_mux_u16be(out, 1)
  caf_mux_u16be(out, 0)
  caf_mux_chunk(out, "desc", desc)
  let mask = if self.channel_mask != 0U {
    self.channel_mask
  } else if channels == 1 {
    4U
  } else if channels == 2 {
    3U
  } else {
    0U
  }
  if mask <= 0x3ffffU && mask.popcnt() == channels {
    let layout : Array[Byte] = []
    let tag = match mask {
      4U => 0x00640001U
      3U => 0x00650002U
      _ => 0x10000U
    }
    caf_mux_u32be(layout, tag)
    caf_mux_u32be(layout, if tag == 0x10000U { mask } else { 0U })
    caf_mux_u32be(layout, 0U)
    caf_mux_chunk(out, "chan", layout)
  }
  caf_mux_tag(out, "data")
  caf_mux_u64be(out, (size + 4L).reinterpret_as_uint64())
  caf_mux_u32be(out, 0U)
  if width == 1 {
    let samples = @swr.swr_flt_planar_to_s16(self.samples, channels) catch {
      error => raise DecodeError(error.to_string())
    }
    let encoded = if tag == "alaw" {
      @libavcodec.pcm_alaw_encode(samples[:])
    } else {
      @libavcodec.pcm_mulaw_encode(samples[:])
    }
    for byte in encoded {
      out.push(byte)
    }
  } else {
    let big_endian = (flags & 2U) == 0U
    for frame in 0..<frames {
      for plane in self.samples {
        let sample = plane[frame]
        if width == 4 {
          wav_mux_w32(
            out,
            Float::from_double(sample).reinterpret_as_uint(),
            big_endian,
          )
        } else if big_endian {
          caf_mux_u64be(out, sample.reinterpret_as_uint64())
        } else {
          wav_mux_u64(
            out,
            sample.reinterpret_as_uint64().reinterpret_as_int64(),
          )
        }
      }
    }
  }
  Bytes::from_array(out)
}
