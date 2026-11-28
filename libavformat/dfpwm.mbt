///|
/// Bare DFPWM has no header. Use the upstream defaults of 48 kHz mono.
fn dfpwm_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard !data.is_empty() else { return Err("empty raw DFPWM stream") }
  let sample_rate = 48000
  let packet_size = wav_pcm_default_packet_size(1, "dfpwm", sample_rate, 1, 0)
  let frames : Array[RawAudioFrame] = []
  for pos = 0; pos < data.length(); {
    let size = packet_size.min(data.length() - pos)
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: pos.to_int64() * 8L,
      duration: size * 8,
      is_keyframe: true,
    })
    continue pos + size
  }
  Ok({
    codec: "dfpwm",
    profile: "",
    sample_rate,
    channels: 1,
    frame_size: packet_size * 8,
    frames,
    total_samples: data.length().to_int64() * 8L,
    bit_rate: sample_rate,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Convert a mono track to raw DFPWM1a with the 48 kHz playback default.
pub fn DecodedAudio::to_dfpwm(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 else {
    raise UnsupportedCodec("raw DFPWM export requires a mono track")
  }
  let audio = self.resample_to(48000)
  dfpwm_mono_payload(audio.samples[0])
}

///|
fn dfpwm_mono_payload(samples : Array[Double]) -> Bytes {
  let pcm = Bytes::makei(samples.length(), i => {
    let s16 = @swr.swr_flt_to_s16(samples[i])
    ((s16 >> 8) + 128).to_byte()
  })
  @libavcodec.encode_dfpwm(pcm[:])
}

///|
let wav_dfpwm_guid : Bytes = b"\x3a\xc1\xfa\x38\x81\x1d\x43\x61\xa4\x0d\xce\x53\xca\x60\x7c\xd1"

///|
fn dfpwm_waveformat(rate : Int32) -> Array[Byte] {
  let fmt : Array[Byte] = []
  wav_mux_u16(fmt, 0xfffe)
  wav_mux_u16(fmt, 1)
  wav_mux_u32(fmt, rate.reinterpret_as_uint())
  wav_mux_u32(fmt, (rate / 8).reinterpret_as_uint())
  wav_mux_u16(fmt, 1)
  wav_mux_u16(fmt, 1)
  wav_mux_u16(fmt, 22)
  wav_mux_u16(fmt, 1)
  wav_mux_u32(fmt, 4U) // SPEAKER_FRONT_CENTER
  for byte in wav_dfpwm_guid {
    fmt.push(byte)
  }
  fmt
}

///|
fn dfpwm_riff(payload : Bytes, fmt : Array[Byte], frames : Int32) -> Bytes {
  let pad = payload.length() & 1
  let out : Array[Byte] = Array(capacity=80 + payload.length() + pad)
  wav_mux_tag(out, "RIFF")
  wav_mux_u32(out, (72 + payload.length() + pad).reinterpret_as_uint())
  wav_mux_tag(out, "WAVE")
  wav_mux_tag(out, "fmt ")
  wav_mux_u32(out, 40U)
  out.append(fmt)
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
/// Encode mono DFPWM1a in WAV or Sony Wave64 at the track's sample rate.
/// The fact chunk records the length before codec and container padding.
pub fn DecodedAudio::to_wav_dfpwm(
  self : DecodedAudio,
  wave64~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 else {
    raise UnsupportedCodec("WAV DFPWM export requires a mono track")
  }
  guard self.sample_rate > 0 && !self.samples[0].is_empty() else {
    raise DecodeError("WAV DFPWM: invalid sample rate or empty audio")
  }
  let payload = dfpwm_mono_payload(self.samples[0])
  let fmt = dfpwm_waveformat(self.sample_rate)
  let frames = self.samples[0].length()
  if wave64 {
    w64_mux_fact_data(payload, fmt, frames)
  } else {
    dfpwm_riff(payload, fmt, frames)
  }
}
