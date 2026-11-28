///|
fn ts_opus_access_unit(packet : Bytes, start : Int32, end : Int32) -> Bytes {
  let flags = 0xe0 |
    (if start > 0 { 0x10 } else { 0 }) |
    (if end > 0 { 0x08 } else { 0 })
  let out : Array[Byte] = [b'\x7f', flags.to_byte()]
  for _ in 0..<(packet.length() / 255) {
    out.push(b'\xff')
  }
  out.push((packet.length() % 255).to_byte())
  if start > 0 {
    ts_mux_u16(out, start)
  }
  if end > 0 {
    ts_mux_u16(out, end)
  }
  for byte in packet {
    out.push(byte)
  }
  Bytes::from_array(out)
}

///|
/// Encode mono or stereo PCM as 48 kHz Opus in audio-only MPEG-TS.
/// DVB Opus access-unit headers carry sample-accurate start and end trims.
pub fn DecodedAudio::to_ts_opus(self : DecodedAudio) -> Bytes raise MediaError {
  let (packets, priming, count) = self.encode_opus()
  let mux = {
    ..ts_muxer_new(
      video=false,
      service_type=0x02,
      audio_stream_type=0x06,
      audio_registration=b"Opus",
    ),
    audio_opus_config: Some(self.channels),
  }
  let valid_end = count.to_int64() + priming.to_int64()
  let mut offset = 0L
  let mut skip = priming
  for packet in packets {
    let samples = match @libavcodec.opus_parse_packet(packet) {
      Ok(parsed) => parsed.total_samples()
      Err(error) => raise DecodeError(error)
    }
    let stop = offset + samples.to_int64()
    let start_trim = skip.min(samples)
    let end_trim = (stop - valid_end).max(0L).to_int()
    let pts = @libavutil.av_rescale(offset, 90000L, 48000L)
    mux.write_audio(pts, ts_opus_access_unit(packet, start_trim, end_trim))
    skip -= start_trim
    offset = stop
    if offset >= valid_end {
      break
    }
  }
  guard offset >= valid_end else {
    raise DecodeError("mpegts: insufficient Opus samples for presentation")
  }
  mux.finish()
}
