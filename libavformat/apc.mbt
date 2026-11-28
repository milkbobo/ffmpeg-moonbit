///|
/// CRYO APC from FFmpeg 9.0.2 apc.c, Copyright (c) 2007 Anssi Hannula.
/// LGPL-2.1-or-later.
fn probe_apc(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 8 && pd.buf[:8] == b"CRYO_APC" {
    probe_score_max
  } else {
    0
  }
}

///|
fn apc_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() > 32 && data[:8] == b"CRYO_APC" else {
    return Err("apc: missing header or audio payload")
  }
  let rate = wav_u32(data[:], 16, false)
  guard rate > 0L && rate <= 0x7fffffffL else {
    return Err("apc: invalid sample rate")
  }
  let channels = if wav_u32(data[:], 28, false) == 0L { 1 } else { 2 }
  let frames : Array[RawAudioFrame] = []
  for pos = 32; pos < data.length(); {
    let size = (data.length() - pos).min(4096)
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: (pos - 32).to_int64() * 2L / channels.to_int64(),
      duration: size * 2 / channels,
      is_keyframe: pos == 32,
    })
    continue pos + size
  }
  Ok({
    codec: "adpcm_ima_apc",
    profile: "",
    sample_rate: rate.to_int(),
    channels,
    frame_size: 4096 * 2 / channels,
    frames,
    total_samples: (data.length() - 32).to_int64() * 2L / channels.to_int64(),
    bit_rate: (rate * channels.to_int64() * 4L).min(0x7fffffffL).to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
