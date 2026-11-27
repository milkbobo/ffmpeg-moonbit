///|
fn wav_flac_demux(
  data : Bytes,
  fmt : WavFormat,
  data_offset : Int64,
  data_size : Int64,
  wave64~ : Bool,
) -> Result[WavDemux, String] {
  // Some writers carry the native FLAC marker and metadata block
  // header. Normalize both forms to the decoder's 34-byte STREAMINFO.
  let extra = fmt.extradata
  let offset = if pb_match(extra, 0, "fLaC") { 8 } else { 0 }
  if extra.length() - offset < 34 ||
    (
      offset != 0 &&
      ((extra[4].to_int() & 0x7F) != 0 || pb_be24(extra, 5) != 34U)
    ) {
    return Err("wav: missing FLAC STREAMINFO")
  }
  let streaminfo = extra[offset:offset + 34].to_owned()
  let max_padding = if wave64 { 7 } else { 0 }
  let track = match
    flac_open_frames(
      data,
      data_offset.to_int(),
      (data_offset + data_size).to_int(),
      streaminfo,
      max_padding~,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let format : WavFormat = {
    ..fmt,
    sample_rate: track.sample_rate,
    channels: track.channels,
    bits_per_sample: track.bits,
    extradata: streaminfo,
  }
  Ok(wav_indexed_demux(format, data_offset, track.frames, track.total_samples))
}
