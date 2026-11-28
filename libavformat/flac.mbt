///|
/// Native FLAC metadata and frame index (FFmpeg flacdec.c / flac_parser.c).
pub struct FlacDemux {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  streaminfo : Bytes
  total_samples : Int64
  frames : Array[RawAudioFrame]
}

///|
/// FFmpeg's default FLAC speaker masks in channel-count order.
fn flac_default_channel_mask(channels : Int32) -> UInt32 {
  let masks : FixedArray[UInt32] = [
    4U, 3U, 7U, 0x33U, 0x607U, 0x60fU, 0x70fU, 0x63fU,
  ]
  masks[channels - 1]
}

///|
/// Normalize a bare STREAMINFO or the start of a native FLAC metadata stream.
fn flac_streaminfo_payload(extra : Bytes) -> Bytes? {
  let offset = if pb_match(extra, 0, "fLaC") { 8 } else { 0 }
  guard extra.length() >= offset + 34 else { return None }
  if offset != 0 &&
    ((extra[4].to_int() & 0x7f) != 0 || pb_be24(extra, 5) != 34U) {
    return None
  }
  Some(extra[offset:offset + 34].to_owned())
}

///|
/// Open a native `fLaC` stream, retaining the STREAMINFO payload and one
/// byte range per CRC-checked frame. Timestamps use PCM sample units.
pub fn av_flac_open(data : Bytes) -> Result[FlacDemux, String] {
  let mut pos = 0
  while probe_id3v2_match_at(data, pos) {
    let size = probe_id3v2_tag_len_at(data, pos)
    if size > data.length() - pos {
      return Err("flac: truncated ID3v2 tag")
    }
    pos += size
  }
  if !pb_match(data, pos, "fLaC") {
    return Err("flac: missing fLaC marker")
  }
  pos += 4
  if data.length() - pos < 38 ||
    (data[pos].to_int() & 0x7F) != 0 ||
    pb_be24(data, pos + 1) != 34U {
    return Err("flac: missing or invalid STREAMINFO")
  }
  let streaminfo = data[pos + 4:pos + 38].to_owned()
  let mut last = (data[pos].to_int() & 0x80) != 0
  pos += 38
  while !last {
    if data.length() - pos < 4 {
      return Err("flac: truncated metadata header")
    }
    let kind = data[pos].to_int() & 0x7F
    if kind == 0 || kind == 127 {
      return Err("flac: invalid metadata block type")
    }
    last = (data[pos].to_int() & 0x80) != 0
    let length = pb_be24(data, pos + 1).reinterpret_as_int()
    pos += 4
    if length > data.length() - pos {
      return Err("flac: truncated metadata block")
    }
    pos += length
  }
  flac_open_frames(data, pos, data.length(), streaminfo)
}

///|
/// Index FLAC frames in a bounded container payload, given the 34-byte
/// STREAMINFO. Wave64 may include up to seven alignment bytes in its size.
fn flac_open_frames(
  data : Bytes,
  start : Int32,
  end : Int32,
  streaminfo : Bytes,
  max_padding~ : Int32 = 0,
) -> Result[FlacDemux, String] {
  if streaminfo.length() != 34 {
    return Err("flac: invalid STREAMINFO length")
  }
  let max_blocksize = pb_be16(streaminfo, 2).reinterpret_as_int()
  let sample_rate = (pb_be24(streaminfo, 10) >> 4).reinterpret_as_int()
  let channels = ((streaminfo[12].to_int() >> 1) & 7) + 1
  let bits = (
      ((streaminfo[12].to_int() & 1) << 4) | (streaminfo[13].to_int() >> 4)
    ) +
    1
  if sample_rate <= 0 || sample_rate > 655350 || bits < 4 || max_blocksize < 16 {
    return Err("flac: invalid stream parameters")
  }
  let crc_table = match @libavutil.av_crc_init(false, 16, 0x8005) {
    Ok(table) => table
    Err(e) => return Err(e)
  }
  let frames : Array[RawAudioFrame] = []
  let mut total_samples = 0L
  let mut pos = start
  while pos < end {
    if end - pos <= max_padding && data[pos:end].iter().all(byte => byte == 0) {
      break
    }
    let (size, duration) = match
      @libavcodec.flac_frame_extent(data, pos, sample_rate, channels, bits) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if size > end - pos {
      return Err("flac: frame extends beyond the audio payload")
    }
    if duration > max_blocksize {
      return Err("flac: frame exceeds STREAMINFO block size")
    }
    if @libavutil.av_crc(crc_table, 0U, data[pos:pos + size].to_owned()) != 0U {
      return Err("flac: frame CRC mismatch")
    }
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: total_samples,
      duration,
      is_keyframe: true,
    })
    total_samples += duration.to_int64()
    pos += size
  }
  Ok({ sample_rate, channels, bits, streaminfo, total_samples, frames, })
}
