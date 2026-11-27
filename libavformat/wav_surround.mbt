///|
fn wav_surround_demux(
  payload : BytesView,
  fmt : WavFormat,
  data_offset : Int64,
  wave64~ : Bool,
) -> Result[WavDemux, String] {
  if fmt.codec == "dts" {
    let max_tail_padding = if wave64 { 7 } else { 3 }
    return dts_open(payload, max_tail_padding~).map(track => {
      wav_dts_demux(track, fmt, data_offset)
    })
  }
  let track = match ac3_open(payload.to_owned(), fixed_format=true) {
    Ok(track) => track
    Err(e) => return Err("wav: invalid AC-3/E-AC-3 payload: " + e)
  }
  let format : WavFormat = {
    ..fmt,
    codec: track.codec,
    sample_rate: track.sample_rate,
    channels: track.channels,
  }
  Ok(
    wav_indexed_demux(
      format,
      data_offset,
      track.frames,
      track.total_samples,
      frame_offset=data_offset,
    ),
  )
}

///|
fn wav_dts_demux(
  track : DtsTrack,
  fmt : WavFormat,
  data_offset : Int64,
) -> WavDemux {
  let format : WavFormat = {
    ..fmt,
    codec: "dts",
    sample_rate: track.sample_rate,
    channels: track.channels,
  }
  wav_indexed_demux(
    format,
    data_offset,
    track.frames,
    track.total_samples,
    frame_offset=data_offset,
  )
}

///|
fn wav_probe_dts_cd(payload : BytesView, wave64~ : Bool) -> DtsTrack? {
  // A complete sequence starting at the data chunk boundary distinguishes
  // a PCM carrier from audio that happens to contain a valid DTS sync word.
  guard @libavcodec.parse_dca_core_header(payload) is Ok(first) &&
    first.sample_rate == 44100 else {
    return None
  }
  let max_tail_padding = if wave64 { 7 } else { 3 }
  match dts_open(payload, max_tail_padding~) {
    Ok(track) if track.frames.length() >= 2 => Some(track)
    _ => None
  }
}
