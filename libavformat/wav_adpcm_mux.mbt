///|
/// Write mono or stereo ADPCM in RIFF/WAV or Wave64 from signed 16-bit PCM.
/// The codec is `adpcm_ima_wav`, `adpcm_ms` or `adpcm_yamaha`. The final
/// block is zero-padded and the fact chunk records the original sample count.
pub fn av_wav_mux_adpcm(
  samples : ArrayView[Int32],
  sample_rate : Int32,
  channels : Int32,
  codec : String,
  block_size~ : Int32 = 1024,
  wave64~ : Bool = false,
) -> Result[Bytes, String] {
  guard sample_rate > 0 else { return Err("wav: invalid ADPCM sample rate") }
  let encoded = match
    @libavcodec.encode_adpcm_wav(samples, codec, channels, block_size~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let byte_rate = sample_rate.to_int64() *
    block_size.to_int64() /
    encoded.samples_per_block.to_int64()
  let extra = encoded.extradata
  let fmt : Array[Byte] = []
  wav_mux_u16(fmt, encoded.format_tag)
  wav_mux_u16(fmt, channels)
  wav_mux_u32(fmt, sample_rate.reinterpret_as_uint())
  wav_mux_u32(fmt, byte_rate.to_int().reinterpret_as_uint())
  wav_mux_u16(fmt, block_size)
  wav_mux_u16(fmt, 4)
  wav_mux_u16(fmt, extra.length())
  for byte in extra {
    fmt.push(byte)
  }
  let frames = samples.length() / channels
  if wave64 {
    return Ok(w64_mux_fact_data(encoded.payload, fmt, frames))
  }
  let riff_size = 50 + extra.length() + encoded.payload.length()
  let out : Array[Byte] = Array(capacity=riff_size + 8)
  wav_mux_tag(out, "RIFF")
  wav_mux_u32(out, riff_size.reinterpret_as_uint())
  wav_mux_tag(out, "WAVE")
  wav_mux_tag(out, "fmt ")
  wav_mux_u32(out, fmt.length().reinterpret_as_uint())
  out.append(fmt)
  wav_mux_tag(out, "fact")
  wav_mux_u32(out, 4U)
  wav_mux_u32(out, frames.reinterpret_as_uint())
  wav_mux_tag(out, "data")
  wav_mux_u32(out, encoded.payload.length().reinterpret_as_uint())
  for b in encoded.payload {
    out.push(b)
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode the decoded mono or stereo track as ADPCM at its sample rate.
pub fn DecodedAudio::to_wav_adpcm(
  self : DecodedAudio,
  codec : String,
  block_size~ : Int32 = 1024,
  wave64~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("WAV ADPCM export requires mono or stereo")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  match
    av_wav_mux_adpcm(
      samples[:],
      self.sample_rate,
      self.channels,
      codec,
      block_size~,
      wave64~,
    ) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
}
