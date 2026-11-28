///|
/// Creative Voice block layout from FFmpeg 9.0.2 vocenc.c.
/// Copyright (c) 2006 Aurelien Jacobs. LGPL-2.1-or-later.
fn voc_mux_block(out : Array[Byte], kind : Byte, size : Int32) -> Unit {
  out.push(kind)
  wav_mux_u16(out, size)
  out.push((size >> 16).to_byte())
}

///|
/// Write Creative VOC with unsigned 8-bit PCM, signed 16-bit PCM, or G.711.
pub fn DecodedAudio::to_voc(
  self : DecodedAudio,
  codec~ : String = "pcm_s16le",
) -> Bytes raise MediaError {
  let (tag, width) = match codec {
    "pcm_u8" => (0, 1)
    "pcm_s16le" => (4, 2)
    "pcm_alaw" => (6, 1)
    "pcm_mulaw" => (7, 1)
    _ => raise UnsupportedCodec("VOC export: " + codec)
  }
  let rate = self.sample_rate
  let channels = self.channels
  guard rate > 0 && channels >= 1 && channels <= 64 else {
    raise DecodeError("voc: invalid sample rate or channel count")
  }
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("voc: no audio samples") }
  let packet_frames = 1024
  let packets = (frames - 1) / packet_frames + 1
  let align = width * channels
  let max_size = 47L +
    packets.to_int64() * 4L +
    frames.to_int64() * align.to_int64()
  guard max_size <= 0x7fffffffL else {
    raise DecodeError("voc: PCM exceeds output buffer limit")
  }

  // Keep the sample rate exact by falling back to a type 9 block.
  let mono_divisor = (1000000L + rate.to_int64() / 2L) / rate.to_int64()
  let channel_rate = rate.to_int64() * channels.to_int64()
  let stereo_divisor = (256000000L + channel_rate / 2L) / channel_rate
  let legacy = tag == 0 &&
    mono_divisor >= 1L &&
    mono_divisor <= 256L &&
    (
      (channels == 1 && 1000000L / mono_divisor == rate.to_int64()) ||
      (
        channels == 2 &&
        stereo_divisor >= 1L &&
        stereo_divisor <= 65536L &&
        256000000L / (2L * stereo_divisor) == rate.to_int64()
      )
    )
  let out = voc_magic.to_array()
  wav_mux_u16(out, 26)
  wav_mux_u16(out, 0x0114)
  wav_mux_u16(out, 0x1233 - 0x0114)
  for start = 0; start < frames; {
    let count = (frames - start).min(packet_frames)
    let size = count * align
    if start > 0 {
      voc_mux_block(out, 2, size)
    } else if legacy {
      if channels == 2 {
        voc_mux_block(out, 8, 4)
        wav_mux_u16(out, 65536 - stereo_divisor.to_int())
        out.append([0, 1])
      }
      voc_mux_block(out, 1, size + 2)
      out.push((256 - mono_divisor.to_int()).to_byte())
      out.push(0)
    } else {
      voc_mux_block(out, 9, size + 12)
      wav_mux_u32(out, rate.reinterpret_as_uint())
      out.push((width * 8).to_byte())
      out.push(channels.to_byte())
      wav_mux_u16(out, tag)
      wav_mux_u32(out, 0U)
    }
    match tag {
      0 | 4 =>
        for frame in start..<(start + count) {
          for plane in self.samples {
            if tag == 0 {
              out.push((playback_pcm_quantize(plane[frame], 8) + 128).to_byte())
            } else {
              wav_mux_u16(out, playback_pcm_quantize(plane[frame], 16))
            }
          }
        }
      _ => {
        let samples = Array::makei(count * channels, i => {
          let sample = self.samples[i % channels][start + i / channels]
          playback_pcm_quantize(sample, 16)
        })
        let encoded = if tag == 6 {
          @libavcodec.pcm_alaw_encode(samples[:])
        } else {
          @libavcodec.pcm_mulaw_encode(samples[:])
        }
        for byte in encoded {
          out.push(byte)
        }
      }
    }
    continue start + count
  }
  out.push(0)
  Bytes::from_array(out)
}
