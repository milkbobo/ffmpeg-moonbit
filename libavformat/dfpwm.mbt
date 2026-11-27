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
  let samples = audio.samples[0]
  let pcm = Bytes::makei(samples.length(), i => {
    let s16 = @swr.swr_flt_to_s16(samples[i])
    ((s16 >> 8) + 128).to_byte()
  })
  @libavcodec.encode_dfpwm(pcm[:])
}
