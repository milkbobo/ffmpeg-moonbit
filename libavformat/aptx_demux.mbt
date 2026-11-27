///|
/// Each 4-byte aptX or 6-byte aptX HD block has four samples per channel.
/// Match FFmpeg's 256-block packet size.
fn aptx_open(
  data : Bytes,
  format : FormatId,
  sample_rate : Int32,
) -> Result[RawAudioTrack, String] {
  guard sample_rate > 0 else { return Err("aptx: invalid sample rate") }
  let block_size = if format is AptxHd { 6 } else { 4 }
  guard !data.is_empty() && data.length() % block_size == 0 else {
    return Err("aptx: empty stream or incomplete block")
  }
  let packet_size = block_size * 256
  let frames : Array[RawAudioFrame] = []
  for pos = 0; pos < data.length(); {
    let size = packet_size.min(data.length() - pos)
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: (pos / block_size).to_int64() * 4L,
      duration: size / block_size * 4,
      is_keyframe: true,
    })
    continue pos + size
  }
  Ok({
    codec: format.name(),
    profile: "",
    sample_rate,
    channels: 2,
    frame_size: 1024,
    frames,
    total_samples: (data.length() / block_size).to_int64() * 4L,
    bit_rate: (sample_rate.to_int64() * block_size.to_int64() * 2L)
    .min(2147483647L)
    .to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Encode a stereo track to raw aptX or aptX HD at its current sample rate.
pub fn DecodedAudio::to_aptx(
  self : DecodedAudio,
  hd~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 2 else {
    raise UnsupportedCodec("raw aptX export requires a stereo track")
  }
  guard [8000, 16000, 24000, 32000, 44100, 48000].contains(self.sample_rate) else {
    raise UnsupportedCodec(
      "aptx: sample rate must be 8000, 16000, 24000, 32000, 44100 or 48000 Hz",
    )
  }
  let left = self.samples[0].map(sample => playback_pcm_quantize(sample, 32))
  let right = self.samples[1].map(sample => playback_pcm_quantize(sample, 32))
  match @libavcodec.encode_aptx(left[:], right[:], hd~) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
}
