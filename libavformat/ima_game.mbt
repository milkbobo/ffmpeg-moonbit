///|
/// FFmpeg 9.0.2 kvag.c and apm.c, Copyright (C) 2020 Zane van Iperen.
/// LGPL-2.1-or-later.
fn probe_kvag(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 4 && pd.buf[:4] == b"KVAG" {
    probe_score_extension + 1
  } else {
    0
  }
}

///|
fn probe_apm(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 100 &&
    data[:2] == b"\x00\x20" &&
    data[20:24] == b"vs12" &&
    data[96:100] == b"DATA" {
    probe_score_max - 1
  } else {
    0
  }
}

///|
fn ima_game_open(data : Bytes, apm~ : Bool) -> Result[RawAudioTrack, String] {
  let view = data[:]
  let (start, rate, channels, declared_size, codec) = if apm {
    guard probe_apm(ProbeData::new(data)) != 0 &&
      wav_u32(view, 16, false) == 80L &&
      wav_u16(view, 14, false) == 4 else {
      return Err("apm: invalid header")
    }
    guard wav_u32(view, 40, false) == 0L else {
      return Err("apm: saved samples are unsupported")
    }
    (
      100,
      wav_u32(view, 4, false),
      wav_u16(view, 2, false),
      wav_u32(view, 28, false),
      "adpcm_ima_apm",
    )
  } else {
    guard data.length() >= 14 && view[:4] == b"KVAG" else {
      return Err("kvag: invalid header")
    }
    (
      14,
      wav_u32(view, 8, false),
      if wav_u16(view, 12, false) == 0 {
        1
      } else {
        2
      },
      wav_u32(view, 4, false),
      "adpcm_ima_ssi",
    )
  }
  guard rate > 0L &&
    rate <= (if apm { 0x0fffffffL } else { 0x7fffffffL }) &&
    (channels == 1 || channels == 2) else {
    return Err("SSI/APM: invalid sample rate or channel count")
  }
  let remaining = data.length() - start
  guard remaining > 0 && (!apm || remaining % channels == 0) else {
    return Err("SSI/APM: missing or incomplete audio payload")
  }
  let frames : Array[RawAudioFrame] = []
  for pos = start; pos < data.length(); {
    let size = (data.length() - pos).min(4096)
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: (pos - start).to_int64() * 2L / channels.to_int64(),
      duration: size * 2 / channels,
      is_keyframe: pos == start,
    })
    continue pos + size
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate.to_int(),
    channels,
    frame_size: 4096 * 2 / channels,
    frames,
    total_samples: declared_size * 2L / channels.to_int64(),
    bit_rate: (rate * channels.to_int64() * 4L).min(0x7fffffffL).to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Write Simon & Schuster KVAG, or Rayman 2 APM with apm=true.
/// Both formats preserve the decoded mono or stereo track's sample rate.
pub fn DecodedAudio::to_ima_game(
  self : DecodedAudio,
  apm~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("SSI/APM export requires mono or stereo")
  }
  let rate = self.sample_rate
  guard rate > 0 && (!apm || rate <= 0x0fffffff) else {
    raise DecodeError("SSI/APM: invalid sample rate")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let payload = match
    @libavcodec.encode_ima_game(samples[:], self.channels, apm~) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
  let out : Array[Byte] = []
  let size = payload.length().reinterpret_as_uint()
  if apm {
    wav_mux_u16(out, 0x2000)
    wav_mux_u16(out, self.channels)
    wav_mux_u32(out, rate.reinterpret_as_uint())
    wav_mux_u32(out, (rate * self.channels * 2).reinterpret_as_uint())
    wav_mux_u16(out, 1024)
    wav_mux_u16(out, 4)
    wav_mux_u32(out, 80U)
    wav_mux_tag(out, "vs12")
    wav_mux_u32(out, size + 100U)
    wav_mux_u32(out, size)
    wav_mux_u32(out, 0xffffffffU)
    for _ in 0..<60 {
      out.push(0)
    }
    wav_mux_tag(out, "DATA")
  } else {
    wav_mux_tag(out, "KVAG")
    wav_mux_u32(out, size)
    wav_mux_u32(out, rate.reinterpret_as_uint())
    wav_mux_u16(out, self.channels - 1)
  }
  for b in payload {
    out.push(b)
  }
  Bytes::from_array(out)
}
