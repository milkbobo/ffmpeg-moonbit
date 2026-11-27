///|
/// Synthesize OpusHead from DVB Opus configurations 0–8
/// (mpegts.c's opus_stream_cnt and opus_channel_map).
fn ts_opus_head(code : Int32) -> Bytes? {
  if code < 0 || code > 8 {
    return None
  }
  let channels = if code == 0 { 2 } else { code }
  let family = if code == 0 { 255 } else if code > 2 { 1 } else { 0 }
  let head = b"OpusHead\x01".to_array()
  head.push(channels.to_byte())
  head.append(b"\x00\x00\x80\xbb\x00\x00\x00\x00".to_array())
  head.push(family.to_byte())
  if family != 0 {
    let coupled = [1, 0, 1, 1, 2, 2, 2, 3, 3][code]
    let mapping = [
        b"\x00", b"\x00\x01", b"\x00\x02\x01", b"\x00\x01\x02\x03", b"\x00\x04\x01\x02\x03",
        b"\x00\x04\x01\x02\x03\x05", b"\x00\x04\x01\x02\x03\x05\x06", b"\x00\x06\x01\x02\x03\x04\x05\x07",
      ][channels - 1]
    head.push((channels - coupled).to_byte())
    head.push(coupled.to_byte())
    head.append(mapping.to_array())
  }
  Some(Bytes::from_array(head))
}

///|
priv struct TsOpusControl {
  payload_start : Int32
  payload_end : Int32
  trim_start : Int32
  trim_end : Int32
}

///|
/// Parse the transport-only control header, including the Xiph-laced
/// payload length, optional trims and optional control extension.
fn ts_opus_control(data : BytesView) -> Result[TsOpusControl, String] {
  if data.length() < 3 || (ts_rb16(data, 0) & 0xFFE0) != 0x7FE0 {
    return Err("mpegts: invalid Opus control header")
  }
  let flags = data[1].to_int()
  let mut pos = 2
  let mut size = 0
  while pos < data.length() {
    let value = data[pos].to_int()
    pos += 1
    if value > data.length() - pos - size {
      return Err("mpegts: truncated Opus payload")
    }
    size += value
    if value < 255 {
      break
    }
  }
  let mut trim_start = 0
  let mut trim_end = 0
  if (flags & 0x10) != 0 {
    if data.length() - pos < 2 {
      return Err("mpegts: truncated Opus start trim")
    }
    trim_start = ts_rb16(data, pos)
    pos += 2
  }
  if (flags & 0x08) != 0 {
    if data.length() - pos < 2 {
      return Err("mpegts: truncated Opus end trim")
    }
    trim_end = ts_rb16(data, pos)
    pos += 2
  }
  if (flags & 0x04) != 0 {
    if pos >= data.length() {
      return Err("mpegts: truncated Opus control extension")
    }
    let length = data[pos].to_int()
    pos += 1
    if length > data.length() - pos {
      return Err("mpegts: truncated Opus control extension")
    }
    pos += length
  }
  if size == 0 || size > data.length() - pos {
    return Err("mpegts: truncated or empty Opus payload")
  }
  Ok({ payload_start: pos, payload_end: pos + size, trim_start, trim_end, })
}

///|
fn playback_ts_index_opus(
  demux : TsDemux,
  stream_index : Int32,
  extra : Bytes,
  output : Map[Int32, TsAudioPes],
) -> Unit raise MediaError {
  let head = match @libavcodec.opus_parse_head(extra) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let (es, pes) = ts_join_audio_pes(demux, stream_index)
  let frames : Array[TsAudioFrame] = []
  let mut pos = 0
  while pos < es.length() {
    let control = match ts_opus_control(es[pos:]) {
      Ok(v) => v
      Err(e) => raise DemuxError(e)
    }
    let end = pos + control.payload_end
    let payload = es[pos + control.payload_start:end].to_owned()
    let samples = match head.parse_packet(payload) {
      Ok(v) => v[0].packet.total_samples
      Err(e) => raise DemuxError("mpegts: " + e)
    }
    if control.trim_start + control.trim_end > samples {
      raise DemuxError("mpegts: Opus trim exceeds packet duration")
    }
    // Keep the control header with this packet so the decoder can apply
    // the trim to the exact frame, including trims at splice boundaries.
    frames.push({
      start: pos,
      end,
      data: es[pos:end].to_owned(),
      samples,
      keyframe: true,
    })
    pos = end
  }
  ts_index_audio_frames(demux, stream_index, 48000, pes, frames, output)
}
