///|
fn playback_open_adts(data : Bytes) -> MediaFile raise MediaError {
  let track = match adts_open(data, for_playback=true) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let (asc, multiplier, channels) = playback_adts_config(data, track.frames[0])
  {
    format_name: "aac",
    streams: [
      {
        index: 0,
        media_type: Audio,
        codec_id: "aac",
        sample_rate: track.sample_rate * multiplier,
        channels,
        width: 0,
        height: 0,
        extradata: Some(asc),
      },
    ],
    source: RawAdts(track, data, multiplier),
    cursor: [0],
  }
}

///|
fn playback_adts_config(data : Bytes, first : RawAudioFrame) -> (Bytes, Int32, Int32) raise MediaError {
  let pos = first.pos.to_int()
  playback_adts_packet_config(data[pos:pos + first.size].to_owned(), first.duration)
}

///|
fn playback_adts_packet_config(packet : Bytes, duration : Int, asc? : Bytes) -> (Bytes, Int, Int) raise MediaError {
  let header = match @libavcodec.ff_adts_header_parse_buf(packet) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let asc = match asc {
    Some(asc) => asc
    None => ts_adts_to_asc(header.object_type, header.sampling_index, header.chan_config)
  }
  // The ADTS header describes the AAC core. Decode the first access unit to
  // detect implicit SBR/PS and determine the presentation sample rate/layout.
  let decoder = match @libavcodec.new_aac_decoder_from_asc(asc) {
    Ok(v) => v
    Err(e) => raise DecodeError(e)
  }
  let pcm = match decoder.decode_frame(aac_strip_adts(packet)) {
    Ok([_, ..] as v) => v
    Ok(_) => raise DecodeError("adts: first frame produced no audio")
    Err(e) => raise DecodeError(e)
  }
  let samples = pcm[0].samples.length()
  if samples != duration && samples != 2 * duration {
    raise DecodeError("adts: unexpected decoded frame length")
  }
  (asc, samples / duration, pcm.length())
}

///|
fn playback_adts_stream_info(info : StreamInfo, coded : Result[Bytes, String], asc? : Bytes) -> StreamInfo raise MediaError {
  let packet = match coded {
    Ok(packet) => packet
    Err(e) => raise DemuxError(e)
  }
  let (asc, multiplier, channels) = playback_adts_packet_config(packet, 1024, asc?)
  // Packet timestamps, when present, keep the AAC core time base. Stream
  // metadata describes the decoded output, which can have twice the core rate.
  { ..info, sample_rate: info.sample_rate * multiplier, channels, extradata: Some(asc) }
}
