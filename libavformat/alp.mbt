///|
/// ALP container from FFmpeg 9.0.2 `alp.c`.
/// Copyright (C) 2020 Zane van Iperen. LGPL-2.1-or-later.
fn probe_alp(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 14 &&
    data[:4] == b"ALP " &&
    data[8:14] == b"ADPCM\x00" &&
    (data[4:8] == b"\x08\x00\x00\x00" || data[4:8] == b"\x0c\x00\x00\x00") {
    probe_score_max - 1
  } else {
    0
  }
}

///|
fn alp_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_alp(ProbeData::new(data)) != 0 else {
    return Err("alp: invalid header")
  }
  let pcm = data[4] == b'\x0c'
  let start = if pcm { 20 } else { 16 }
  guard data.length() > start else { return Err("alp: missing audio payload") }
  let rate = if pcm { wav_u32(data[:], 16, false) } else { 22050L }
  guard rate >= 1L && rate <= 44100L else {
    return Err("alp: invalid sample rate")
  }
  let channels = data[15].to_int()
  guard channels == 1 || channels == 2 else {
    return Err("alp: expected mono or stereo")
  }
  let payload_size = data.length() - start
  guard payload_size % channels == 0 else {
    return Err("alp: incomplete channel pair")
  }
  let packet_size = 4096
  let frames : Array[RawAudioFrame] = []
  for pos = start; pos < data.length(); {
    let size = packet_size.min(data.length() - pos)
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
    codec: "adpcm_ima_alp",
    profile: "",
    sample_rate: rate.to_int(),
    channels,
    frame_size: packet_size * 2 / channels,
    frames,
    total_samples: payload_size.to_int64() * 2L / channels.to_int64(),
    bit_rate: rate.to_int() * channels * 4,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Write an ALP TUN file at 22.05 kHz, or a PCM variant at the track's rate.
pub fn DecodedAudio::to_alp(
  self : DecodedAudio,
  pcm~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("ALP export requires mono or stereo")
  }
  let audio = if pcm { self } else { self.resample_to(22050) }
  let rate = audio.sample_rate
  guard rate > 0 && rate <= 44100 else {
    raise UnsupportedCodec("ALP PCM sample rate must be between 1 and 44100 Hz")
  }
  let samples = @swr.swr_flt_planar_to_s16(audio.samples, audio.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let payload = match @libavcodec.encode_ima_alp(samples[:], audio.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
  let header : Array[Byte] = [
    b'A',
    b'L',
    b'P',
    b' ',
    if pcm {
      12
    } else {
      8
    },
    0,
    0,
    0,
    b'A',
    b'D',
    b'P',
    b'C',
    b'M',
    0,
    0,
    audio.channels.to_byte(),
  ]
  if pcm {
    for i in 0..<4 {
      header.push((rate >> (8 * i)).to_byte())
    }
  }
  Bytes::makei(header.length() + payload.length(), i => {
    if i < header.length() {
      header[i]
    } else {
      payload[i - header.length()]
    }
  })
}
