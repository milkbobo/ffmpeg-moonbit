///|
/// LOAS carries the decoder configuration in-band, including in WAV 0x1602.
/// Expose byte-aligned AAC access units with timestamps in PCM samples.
fn playback_open_loas(data : Bytes, format_name : String) -> MediaFile raise MediaError {
  let track = match @libavcodec.latm_parse_stream(data) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  if track.frames.is_empty() {
    raise DemuxError("latm: no AAC access units")
  }
  let config = match @libavcodec.aac_parse_audio_specific_config(track.asc) {
    Ok(v) => v.config
    Err(e) => raise DemuxError(e)
  }
  {
    format_name,
    streams: [
      {
        index: 0,
        media_type: Audio,
        codec_id: "aac_latm",
        sample_rate: config.sample_rate,
        channels: config.channels,
        width: 0,
        height: 0,
        extradata: Some(track.asc),
      },
    ],
    source: LoasAac(track, config.sample_rate, config.frame_length),
    cursor: [0],
  }
}
