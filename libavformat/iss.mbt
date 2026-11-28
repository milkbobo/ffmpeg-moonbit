///|
/// Funcom ISS header based on FFmpeg 9.0.2 iss.c.
/// Copyright (c) 2008 Jaikrishnan Menon. LGPL-2.1-or-later.
fn probe_iss(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 15 && pd.buf[:15] == b"IMA_ADPCM_Sound" {
    probe_score_max
  } else {
    0
  }
}

///|
fn iss_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_iss(ProbeData::new(data)) > 0 else {
    return Err("iss: invalid signature")
  }
  let fields : Array[String] = []
  let mut start = 0
  for _ in 0..<10 {
    let mut finish = start
    while finish < data.length() && data[finish] != b' ' && data[finish] != 0 {
      finish += 1
    }
    guard finish < data.length() else { return Err("iss: truncated header") }
    let field = StringBuilder()
    for i in start..<(start + (finish - start).min(19)) {
      field.write_char(data[i].to_int().unsafe_to_char())
    }
    fields.push(field.to_string())
    // Some headers terminate the file ID with NUL before its separator.
    start = finish + 1
    if data[finish] == 0 && start < data.length() {
      start += 1
    }
  }
  guard fields[0] == "IMA_ADPCM_Sound" else {
    return Err("iss: invalid signature")
  }
  let (size, stereo, divisor) = (
    @string.parse_int(fields[1]),
    @string.parse_int(fields[4]),
    @string.parse_int(fields[6]),
  ) catch {
    _ => return Err("iss: invalid numeric header field")
  }
  let channels = if stereo != 0 { 2 } else { 1 }
  let rate = if divisor > 0 { 44100 / divisor } else { 44100 }
  let payload_size = data.length() - start
  guard rate > 0 &&
    size > 4 * channels &&
    size <= 0x3fffffff &&
    payload_size > 0 &&
    payload_size % size == 0 else {
    return Err("iss: invalid sample rate or incomplete audio packets")
  }
  let duration = (size - 4 * channels) * 2 / channels
  let frames : Array[RawAudioFrame] = []
  let mut pts = 0L
  for pos = start; pos < data.length(); pos = pos + size {
    frames.push({ pos: pos.to_int64(), size, pts, duration, is_keyframe: true, })
    pts += duration.to_int64()
  }
  Ok({
    codec: "adpcm_ima_iss",
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: duration,
    frames,
    total_samples: pts,
    bit_rate: rate * channels * 4,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
