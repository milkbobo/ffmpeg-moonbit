///|
/// Argonaut Games ASF from FFmpeg 9.0.2 argo_asf.c.
/// Copyright (C) 2020 Zane van Iperen. LGPL-2.1-or-later.
fn probe_argo_asf(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 24 && data[:4] == b"ASF\x00" else { return 0 }
  let major = wav_u16(data[:], 4, false)
  let minor = wav_u16(data[:], 6, false)
  if (major, minor) is ((1, 1) | (1, 2) | (2, 1)) {
    probe_score_extension + 1
  } else {
    probe_score_extension / 2
  }
}

///|
fn argo_asf_open(data : Bytes) -> Result[RawAudioTrack, String] {
  let view = data[:]
  guard probe_argo_asf(ProbeData::new(data)) > 0 &&
    wav_u32(view, 8, false) == 1L else {
    return Err("argo ASF: expected one audio chunk")
  }
  let offset = wav_u32(view, 12, false)
  guard offset >= 24L && offset + 20L <= data.length().to_int64() else {
    return Err("argo ASF: invalid audio chunk offset")
  }
  let chunk = offset.to_int()
  let blocks = wav_u32(view, chunk, false)
  let flags = wav_u32(view, chunk + 16, false)
  guard wav_u32(view, chunk + 4, false) == 32L && (flags == 13L || flags == 15L) else {
    return Err("argo ASF: unsupported audio chunk parameters")
  }
  let rate = if wav_u16(view, 4, false) == 1 && wav_u16(view, 6, false) == 1 {
    // FX Fighter's v1.1 files store 44100 for audio sampled at 22050 Hz.
    22050
  } else {
    wav_u16(view, chunk + 12, false)
  }
  guard rate > 0 else { return Err("argo ASF: invalid sample rate") }
  let channels = if flags == 15L { 2 } else { 1 }
  let block_size = channels * 17
  let start = chunk + 20
  guard blocks > 0L &&
    blocks * block_size.to_int64() <= (data.length() - start).to_int64() else {
    return Err("argo ASF: missing or truncated ADPCM blocks")
  }
  let frames : Array[RawAudioFrame] = []
  let block_count = blocks.to_int()
  for block = 0; block < block_count; {
    let count = (block_count - block).min(32)
    frames.push({
      pos: start.to_int64() + block.to_int64() * block_size.to_int64(),
      size: count * block_size,
      pts: block.to_int64() * 32L,
      duration: count * 32,
      is_keyframe: block == 0,
    })
    continue block + count
  }
  Ok({
    codec: "adpcm_argo",
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: 32,
    frames,
    total_samples: blocks * 32L,
    bit_rate: rate * channels * 4,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Write Argonaut ASF v2.1 at the decoded track rate. The optional embedded
/// name is stored as up to eight bytes and is zero-padded.
pub fn DecodedAudio::to_argo_asf(
  self : DecodedAudio,
  name~ : Bytes = b"audio",
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("argo ASF export requires mono or stereo")
  }
  guard self.sample_rate > 0 && self.sample_rate <= 65535 else {
    raise DecodeError("argo ASF: sample rate must be in 1..=65535 Hz")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let payload = match @libavcodec.encode_adpcm_argo(samples[:], self.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
  let out : Array[Byte] = Array(capacity=44 + payload.length())
  wav_mux_tag(out, "ASF")
  out.push(0)
  wav_mux_u16(out, 2)
  wav_mux_u16(out, 1)
  wav_mux_u32(out, 1U)
  wav_mux_u32(out, 24U)
  for i in 0..<8 {
    out.push(if i < name.length() { name[i] } else { 0 })
  }
  wav_mux_u32(
    out,
    (payload.length() / (17 * self.channels)).reinterpret_as_uint(),
  )
  wav_mux_u32(out, 32U)
  wav_mux_u32(out, 0U)
  wav_mux_u16(out, self.sample_rate)
  wav_mux_u16(out, 0xffff)
  wav_mux_u32(out, if self.channels == 2 { 15U } else { 13U })
  for byte in payload {
    out.push(byte)
  }
  Bytes::from_array(out)
}
