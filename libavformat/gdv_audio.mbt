///|
/// Gremlin Digital Video audio indexing, from FFmpeg 9.0.2 gdv.c.
/// Copyright (c) 2017 Paul B Mahol. LGPL-2.1-or-later.
fn probe_gdv(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 4 && pd.buf[:4] == b"\x94\x19\x11\x29" {
    probe_score_max
  } else {
    0
  }
}

///|
fn gdv_audio_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 24 && probe_gdv(ProbeData::new(data)) > 0 else {
    return Err("gdv: invalid header")
  }
  let view = data[:]
  let fps = wav_u16(view, 8, false)
  let flags = wav_u16(view, 10, false)
  let rate = wav_u16(view, 12, false)
  guard (flags & 1) != 0 else { return Err("gdv: no audio track") }
  guard fps > 0 && rate > 0 else {
    return Err("gdv: invalid frame or sample rate")
  }
  let channels = if (flags & 2) != 0 { 2 } else { 1 }
  let width = if (flags & 4) != 0 { 2 } else { 1 }
  let compressed = (flags & 8) != 0
  let alignment = channels * (if compressed { 1 } else { width })
  let size = rate / fps * channels * width / (if compressed { 2 } else { 1 })
  guard size > 0 && size % alignment == 0 else {
    return Err("gdv: invalid audio packet size")
  }
  let codec = if compressed {
    "gremlin_dpcm"
  } else if width == 2 {
    "pcm_s16le"
  } else {
    "pcm_u8"
  }
  let start = if (wav_u16(view, 14, false) & 1) != 0 { 24 + 768 } else { 24 }
  guard start < data.length() else { return Err("gdv: missing audio data") }
  let frames : Array[RawAudioFrame] = []
  let duration = size / alignment
  let mut pts = 0L
  for pos = start; pos < data.length(); {
    guard data.length() - pos >= size + 8 else {
      return Err("gdv: truncated audio/video packet pair")
    }
    let video = pos + size
    guard wav_u16(view, video, false) == 0x1305 else {
      return Err("gdv: invalid video packet marker")
    }
    let next = video + 8
    let video_size = wav_u16(view, video + 2, false)
    guard video_size <= data.length() - next else {
      return Err("gdv: truncated video packet")
    }
    frames.push({
      pos: pos.to_int64(),
      size,
      pts,
      duration,
      is_keyframe: !compressed || pos == start,
    })
    pts += duration.to_int64()
    continue next + video_size
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: duration,
    frames,
    total_samples: pts,
    bit_rate: rate * alignment * 8,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
