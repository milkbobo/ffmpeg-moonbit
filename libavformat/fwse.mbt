///|
/// Capcom MT Framework sound from FFmpeg 9.0.2 fwse.c.
/// Copyright (c) 2020 Paul B Mahol. LGPL-2.1-or-later.
fn probe_fwse(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 20 && data[:4] == b"FWSE" else { return 0 }
  let version = wav_u32(data[:], 4, false)
  let channels = wav_u32(data[:], 16, false)
  if (version == 2L || version == 3L) && (channels == 1L || channels == 2L) {
    probe_score_max / 4 * 3
  } else {
    0
  }
}

///|
fn fwse_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 28 && probe_fwse(ProbeData::new(data)) > 0 else {
    return Err("fwse: invalid header")
  }
  let view = data[:]
  let offset = wav_u32(view, 12, false)
  let rate = wav_u32(view, 24, false)
  guard offset >= 28L && offset < data.length().to_int64() else {
    return Err("fwse: invalid audio data offset")
  }
  guard rate > 0L && rate <= 0x7fffffffL else {
    return Err("fwse: invalid sample rate")
  }
  let channels = wav_u32(view, 16, false).to_int()
  let start = offset.to_int()
  guard (data.length() - start) % channels == 0 else {
    return Err("fwse: incomplete channel pair")
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
    codec: "adpcm_ima_mtf",
    profile: "",
    sample_rate: rate.to_int(),
    channels,
    frame_size: 4096 * 2 / channels,
    frames,
    total_samples: wav_u32(view, 20, false),
    bit_rate: (rate * channels.to_int64() * 4L).min(0x7fffffffL).to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
