///|
fn playback_open_mpeg_audio(
  data : Bytes,
  format_name : String,
) -> MediaFile raise MediaError {
  let track = match av_mp3_open(data) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let (head, tail) = mpeg_audio_gapless(data, track)
  {
    format_name,
    streams: [
      {
        index: 0,
        media_type: Audio,
        codec_id: track.codec,
        sample_rate: track.sample_rate,
        channels: track.channels,
        width: 0,
        height: 0,
        extradata: None,
      },
    ],
    source: RawMpegAudio(track, data, head, tail),
    cursor: [0],
  }
}

///|
/// Read the optional LAME tag in the leading Xing/Info frame, following
/// FFmpeg's mp3dec.c. Bounds are relative to the metadata frame.
fn mpeg_audio_gapless(data : Bytes, track : RawAudioTrack) -> (Int32, Int32) {
  if track.info_frame_size == 0 || track.codec != "mp3" {
    return (0, 0)
  }
  let end = track.frames[0].pos.to_int()
  let start = end - track.info_frame_size
  let header = match
    @libavcodec.avpriv_mpegaudio_decode_header(rb32(data, start)) {
    Ok(v) => v
    Err(_) => return (0, 0)
  }
  let xing = start + 4 + xing_offset(header)
  if end - xing < 8 ||
    !(match_fourcc(data, xing, b"Xing") || match_fourcc(data, xing, b"Info")) {
    return (0, 0)
  }
  let flags = rb32(data, xing + 4)
  let mut pos = xing + 8
  let mut frame_count = 0L
  if (flags & 1U) != 0U {
    if end - pos < 4 {
      return (0, 0)
    }
    frame_count = rb32(data, pos).to_int64()
    pos += 4
  }
  if (flags & 2U) != 0U {
    pos += 4
  }
  if (flags & 4U) != 0U {
    pos += 100
  }
  if (flags & 8U) != 0U {
    pos += 4
  }
  if end - pos < 24 ||
    !(match_fourcc(data, pos, b"LAME") ||
    match_fourcc(data, pos, b"Lavf") ||
    match_fourcc(data, pos, b"Lavc")) {
    return (0, 0)
  }
  let delay = (data[pos + 21].to_int() << 4) | (data[pos + 22].to_int() >> 4)
  let padding = ((data[pos + 22].to_int() & 15) << 8) | data[pos + 23].to_int()
  let decoder_delay = 529
  let declared_samples = frame_count * track.frame_size.to_int64()
  let tail = if frame_count > 0L && track.total_samples <= declared_samples {
    let discard_from = declared_samples -
      (padding - decoder_delay).max(0).to_int64()
    (track.total_samples - discard_from)
    .max(0L)
    .min(track.total_samples)
    .to_int()
  } else {
    0
  }
  (delay + decoder_delay, tail)
}
