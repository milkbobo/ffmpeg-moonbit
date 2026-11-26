///|
/// Index raw SBC or mSBC frames. Packet offsets address their original bytes
/// and PTS counts PCM samples per channel. Frame bitpool can vary.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_sbc_open(b"") is Err("sbc: empty stream"))
/// }
/// ```
pub fn av_sbc_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if data.is_empty() {
    return Err("sbc: empty stream")
  }
  let first = match @libavcodec.parse_sbc_header(data[:]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let frames : Array[RawAudioFrame] = []
  let mut pos = 0
  let mut pts = 0L
  while pos < data.length() {
    let header = match @libavcodec.parse_sbc_header(data[pos:]) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if header.frame_bytes > data.length() - pos {
      return Err("sbc: truncated frame")
    }
    if header.sample_rate != first.sample_rate ||
      header.channels != first.channels ||
      header.subbands != first.subbands ||
      header.msbc != first.msbc {
      return Err("sbc: stream parameters changed")
    }
    let duration = header.blocks * header.subbands
    frames.push({
      pos: pos.to_int64(),
      size: header.frame_bytes,
      pts,
      duration,
      is_keyframe: true,
    })
    pos += header.frame_bytes
    pts += duration.to_int64()
  }
  Ok({
    codec: "sbc",
    profile: if first.msbc {
      "mSBC"
    } else {
      "SBC"
    },
    sample_rate: first.sample_rate,
    channels: first.channels,
    frame_size: first.blocks * first.subbands,
    frames,
    total_samples: pts,
    bit_rate: (data.length().to_int64() *
    8L *
    first.sample_rate.to_int64() /
    pts).to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// FFmpeg's raw SBC format uses the extension. Buffer-only playback probes
/// the protected header and checks the next frame boundary when available.
fn probe_sbc(pd : ProbeData) -> Int32 {
  guard @libavcodec.parse_sbc_header(pd.buf[:]) is Ok(first) &&
    first.frame_bytes <= pd.buf.length() else {
    return 0
  }
  if first.frame_bytes == pd.buf.length() ||
    @libavcodec.parse_sbc_header(pd.buf[first.frame_bytes:]) is Ok(_) {
    probe_score_extension + 3
  } else {
    probe_score_extension / 2
  }
}
