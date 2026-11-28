///|
/// Westwood Studios AUD muxing from FFmpeg 9.0.2 westwood_audenc.c.
/// Copyright (c) 2021 Aidan Richmond. LGPL-2.1-or-later.
/// Write IMA ADPCM with 1024-byte chunks and the decoded track's sample rate.
pub fn DecodedAudio::to_wsaud(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("Westwood AUD export requires mono or stereo")
  }
  guard self.sample_rate >= 8000 && self.sample_rate <= 48000 else {
    raise DecodeError("Westwood AUD: sample rate must be in 8000..=48000 Hz")
  }
  let payload = self.encode_westwood_ima()
  let chunk_size = 1024
  let chunks = (payload.length() - 1) / chunk_size + 1
  let body_size = payload.length() + chunks * 8
  let pcm_size = payload.length().to_int64() * 4L
  guard pcm_size <= 0xffffffffL else {
    raise DecodeError(
      "Westwood AUD: decoded size exceeds the file header limit",
    )
  }
  let out : Array[Byte] = Array(capacity=12 + body_size)
  wav_mux_u16(out, self.sample_rate)
  wav_mux_u32(out, body_size.reinterpret_as_uint())
  wav_mux_u32(out, pcm_size.to_int().reinterpret_as_uint())
  out.push((1 + self.channels).to_byte())
  out.push(99)
  for start = 0; start < payload.length(); {
    let size = (payload.length() - start).min(chunk_size)
    wav_mux_u16(out, size)
    wav_mux_u16(out, size * 4)
    wav_mux_u32(out, 0x0000deafU)
    for byte in payload[start:start + size] {
      out.push(byte)
    }
    continue start + size
  }
  Bytes::from_array(out)
}

///|
fn DecodedAudio::encode_westwood_ima(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  match @libavcodec.encode_adpcm_ima_ws(samples[:], self.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
}
