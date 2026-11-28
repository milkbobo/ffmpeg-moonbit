///|
/// Yamaha SMAF audio-track layout from FFmpeg 9.0.2 mmf.c.
/// Copyright (c) 2005 Vidar Madsen. LGPL-2.1-or-later.
let mmf_rates : FixedArray[Int32] = [4000, 8000, 11025, 22050, 44100]

///|
fn probe_mmf(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 12 && data[:4] == b"MMMD" && data[8:12] == b"CNTI" {
    probe_score_max
  } else {
    0
  }
}

///|
fn mmf_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 8 && data[:4] == b"MMMD" else {
    return Err("mmf: invalid file header")
  }
  let file_end = pb_be32(data, 4).to_int64() + 8L
  guard file_end <= data.length().to_int64() else {
    return Err("mmf: truncated file")
  }
  let end = file_end.to_int()
  let mut track = 8
  while track <= end - 8 &&
        (data[track:track + 4] == b"CNTI" || data[track:track + 4] == b"OPDA") {
    let body = track + 8
    let size = pb_be32(data, track + 4).to_int64()
    guard size <= (end - body).to_int64() else {
      return Err("mmf: truncated metadata chunk")
    }
    track = body + size.to_int()
  }
  guard track <= end - 14 && data[track:track + 3] == b"ATR" else {
    return Err("mmf: missing SMAF audio track")
  }
  let body = track + 8
  let track_size = pb_be32(data, track + 4).to_int64()
  guard track_size >= 6L && track_size <= (end - body).to_int64() else {
    return Err("mmf: invalid audio track size")
  }
  let track_end = body + track_size.to_int()
  let params = data[body + 2].to_int()
  let rate_code = params & 15
  guard data[body] == 0 &&
    (params & 0x70) == 0x10 &&
    rate_code < mmf_rates.length() else {
    return Err("mmf: unsupported SMAF waveform format")
  }
  let rate = mmf_rates[rate_code]
  let channels = (params >> 7) + 1
  for chunk = body + 6; chunk <= track_end - 8; {
    let start = chunk + 8
    let size = pb_be32(data, chunk + 4).to_int64()
    guard size <= (track_end - start).to_int64() else {
      return Err("mmf: truncated audio subchunk")
    }
    if data[chunk:chunk + 3] == b"Awa" {
      guard size > 0L else { return Err("mmf: empty waveform") }
      let frames : Array[RawAudioFrame] = []
      let wave_end = start + size.to_int()
      for pos = start; pos < wave_end; {
        let bytes = (wave_end - pos).min(4096)
        frames.push({
          pos: pos.to_int64(),
          size: bytes,
          pts: (pos - start).to_int64() * 2L / channels.to_int64(),
          duration: bytes * 2 / channels,
          is_keyframe: pos == start,
        })
        continue pos + bytes
      }
      return Ok({
        codec: "adpcm_yamaha",
        profile: "",
        sample_rate: rate,
        channels,
        frame_size: frames[0].duration,
        frames,
        total_samples: size * 2L / channels.to_int64(),
        bit_rate: rate * 4 * channels,
        id3v2_size: 0,
        info_frame_size: 0,
      })
    }
    let tag = data[chunk:chunk + 4]
    guard tag == b"Atsq" || tag == b"AspI" else {
      return Err("mmf: unsupported audio subchunk")
    }
    continue start + size.to_int()
  }
  Err("mmf: missing waveform")
}

///|
fn mmf_write_gate(out : Array[Byte], ticks : Int32) -> Unit {
  if ticks < 128 {
    out.push(ticks.to_byte())
  } else {
    let value = ticks - 128
    out.push((0x80 | (value >> 7)).to_byte())
    out.push((value & 0x7f).to_byte())
  }
}

///|
/// Encode one mono or stereo Yamaha ADPCM waveform in a SMAF audio track.
/// The last 1024-byte ADPCM block is padded with silence.
pub fn DecodedAudio::to_mmf(self : DecodedAudio) -> Bytes raise MediaError {
  let channels = self.channels
  guard channels == 1 || channels == 2 else {
    raise UnsupportedCodec("MMF export requires mono or stereo")
  }
  let rate = self.sample_rate
  let mut rate_code = 0
  while rate_code < mmf_rates.length() && mmf_rates[rate_code] != rate {
    rate_code += 1
  }
  guard rate_code < mmf_rates.length() else {
    raise DecodeError(
      "MMF export requires 4000, 8000, 11025, 22050 or 44100 Hz",
    )
  }
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("MMF: no audio samples") }
  let block_samples = 2048 / channels
  let payload_size = ((frames - 1).to_int64() / block_samples.to_int64() + 1L) *
    1024L
  let gate = payload_size * 500L / rate.to_int64()
  guard gate <= 16511L else {
    raise DecodeError("MMF waveform exceeds the two-byte SMAF gate time")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let payload = match
    @libavcodec.encode_adpcm_wav(samples[:], "adpcm_yamaha", channels) {
    Ok(encoded) => encoded.payload
    Err(error) => raise DecodeError(error)
  }

  let out = b"MMMD".to_array()
  let track_size = 6 + 8 + 16 + 8 + payload.length()
  aiff_mux_u32be(out, (13 + 16 + 8 + track_size).reinterpret_as_uint())
  wav_mux_tag(out, "CNTI")
  aiff_mux_u32be(out, 5U)
  out.append([0, 1, 1, 0, 0])
  wav_mux_tag(out, "OPDA")
  aiff_mux_u32be(out, 8U)
  wav_mux_tag(out, "VN:Lavf,")
  wav_mux_tag(out, "ATR\u0000")
  aiff_mux_u32be(out, track_size.reinterpret_as_uint())
  let stereo = channels - 1
  out.append([0, 0, (stereo * 128 + 16 + rate_code).to_byte(), 0, 2, 2])
  wav_mux_tag(out, "Atsq")
  aiff_mux_u32be(out, 16U)
  let sequence_end = out.length() + 16
  out.push(0)
  out.push((stereo * 64 + 1).to_byte())
  mmf_write_gate(out, gate.to_int())
  mmf_write_gate(out, gate.to_int())
  out.append([0xff, 0])
  while out.length() < sequence_end {
    out.push(0)
  }
  wav_mux_tag(out, "Awa\u0001")
  aiff_mux_u32be(out, payload.length().reinterpret_as_uint())
  for byte in payload {
    out.push(byte)
  }
  Bytes::from_array(out)
}
