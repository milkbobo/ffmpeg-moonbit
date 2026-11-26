///|
/// Index a native, fixed-format QOA file, following FFmpeg qoadec.c.
/// PTS and duration are in PCM samples per channel.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_qoa_open(b"qoaf") is Err(_))
/// }
/// ```
pub fn av_qoa_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if data.length() < 16 || data[:4] != b"qoaf" {
    return Err("qoa: missing file header")
  }
  let total_samples = pb_be32(data, 4).to_int64()
  if total_samples == 0L {
    return Err("qoa: file sample count missing")
  }
  let first = match @libavcodec.parse_qoa_header(data[8:]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let frames : Array[RawAudioFrame] = []
  let mut pts = 0L
  for pos = 8; pos < data.length(); {
    let h = match @libavcodec.parse_qoa_header(data[pos:]) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if h.sample_rate != first.sample_rate || h.channels != first.channels {
      return Err("qoa: stream parameters changed")
    }
    if h.frame_bytes > data.length() - pos {
      return Err("qoa: truncated frame")
    }
    frames.push({
      pos: pos.to_int64(),
      size: h.frame_bytes,
      pts,
      duration: h.samples,
      is_keyframe: true,
    })
    pts += h.samples.to_int64()
    if pts > total_samples {
      return Err("qoa: frame samples exceed file sample count")
    }
    continue pos + h.frame_bytes
  }
  if pts != total_samples {
    return Err("qoa: file sample count does not match frames")
  }
  Ok({
    codec: "qoa",
    profile: "",
    sample_rate: first.sample_rate,
    channels: first.channels,
    frame_size: first.samples,
    frames,
    total_samples,
    bit_rate: 0,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
fn probe_qoa(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 16 &&
    pd.buf[:4] == b"qoaf" &&
    pb_be32(pd.buf, 4) > 0U &&
    @libavcodec.parse_qoa_header(pd.buf[8:]) is Ok(_) {
    probe_score_max
  } else {
    0
  }
}
