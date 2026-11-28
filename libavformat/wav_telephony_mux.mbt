///|
/// Write a mono WAVEFORMATEX stream with a fact chunk for its input length.
fn wav_mux_telephony(
  payload : Bytes,
  tag : Int32,
  rate : Int32,
  byte_rate : Int32,
  align : Int32,
  bits : Int32,
  frames : Int32,
) -> Bytes {
  let pad = payload.length() & 1
  let out : Array[Byte] = Array(capacity=58 + payload.length() + pad)
  wav_mux_tag(out, "RIFF")
  wav_mux_u32(out, (50 + payload.length() + pad).reinterpret_as_uint())
  wav_mux_tag(out, "WAVE")
  wav_mux_tag(out, "fmt ")
  wav_mux_u32(out, 18U)
  wav_mux_u16(out, tag)
  wav_mux_u16(out, 1)
  wav_mux_u32(out, rate.reinterpret_as_uint())
  wav_mux_u32(out, byte_rate.reinterpret_as_uint())
  wav_mux_u16(out, align)
  wav_mux_u16(out, bits)
  wav_mux_u16(out, 0)
  wav_mux_tag(out, "fact")
  wav_mux_u32(out, 4U)
  wav_mux_u32(out, frames.reinterpret_as_uint())
  wav_mux_tag(out, "data")
  wav_mux_u32(out, payload.length().reinterpret_as_uint())
  for byte in payload {
    out.push(byte)
  }
  if pad != 0 {
    out.push(0)
  }
  Bytes::from_array(out)
}

///|
/// Encode a mono track as 64 kb/s G.722 in RIFF/WAV at 16 kHz.
pub fn DecodedAudio::to_wav_g722(self : DecodedAudio) -> Bytes raise MediaError {
  let audio = self.resample_to(16000)
  let payload = audio.to_g722()
  guard !payload.is_empty() else {
    raise DecodeError("G.722 WAV: no audio samples")
  }
  // FFmpeg's muxer reports 16000 bytes/s for this WAVEFORMATEX tag.
  wav_mux_telephony(
    payload,
    0x028f,
    16000,
    16000,
    1,
    4,
    audio.samples[0].length(),
  )
}

///|
/// Encode a mono track as G.726 in RIFF/WAV at 8 kHz, MSB-first.
pub fn DecodedAudio::to_wav_g726(
  self : DecodedAudio,
  bits : Int32,
) -> Bytes raise MediaError {
  let audio = self.resample_to(8000)
  let payload = audio.to_g726(bits)
  guard !payload.is_empty() else {
    raise DecodeError("G.726 WAV: no audio samples")
  }
  let align = if bits % 2 == 0 { 1 } else { bits }
  wav_mux_telephony(
    payload,
    0x0045,
    8000,
    bits * 1000,
    align,
    bits,
    audio.samples[0].length(),
  )
}
