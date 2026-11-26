///|
/// Native TTA1 demuxing follows FFmpeg `libavformat/tta.c` (copyright 2006
/// Alex Beregszaszi, LGPL-2.1-or-later). Header and seek table CRCs are
/// skipped, as in FFmpeg's default demux path.
pub struct TtaTrack {
  header : @libavcodec.TtaHeader
  extradata : Bytes
  frames : Array[RawAudioFrame]
}

///|
/// Index the frames in an unencrypted native TTA file. Frame offsets address
/// the original file, including any leading ID3v2 tags.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_tta_open(b"TTA1") is Err(_))
/// }
/// ```
pub fn av_tta_open(data : Bytes) -> Result[TtaTrack, String] {
  let mut start = 0
  while probe_id3v2_match_at(data, start) {
    let len = probe_id3v2_tag_len_at(data, start)
    if len > data.length() - start {
      return Err("tta: truncated ID3v2 tag")
    }
    start += len
  }
  if data.length() - start < 22 {
    return Err("tta: truncated header")
  }
  let extradata = data[start:start + 22].to_owned()
  let header = match @libavcodec.tta_parse_header(extradata) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if header.sample_rate > 1000000 {
    return Err("tta: invalid sample rate")
  }
  let nominal = header.frame_samples.to_int64()
  let n = (header.total_samples + nominal - 1L) / nominal
  let table = start + 22
  let table_end = table.to_int64() + n * 4L + 4L
  if table_end > data.length().to_int64() {
    return Err("tta: truncated seek table")
  }
  let mut pos = table_end.to_int()
  let frames : Array[RawAudioFrame] = []
  for i in 0..<n.to_int() {
    let size = pb_le32(data, table + i * 4).to_int64()
    let pts = i.to_int64() * nominal
    let duration = (header.total_samples - pts).min(nominal).to_int()
    if size < 5L || size > (data.length() - pos).to_int64() {
      return Err("tta: invalid frame size")
    }
    frames.push({
      pos: pos.to_int64(),
      size: size.to_int(),
      pts,
      duration,
      is_keyframe: true,
    })
    pos += size.to_int()
  }
  Ok({ header, extradata, frames, })
}

///|
fn probe_tta(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() < 14 || data[:4] != b"TTA1" {
    return 0
  }
  let kind_and_channels = pb_le32(data, 4)
  let format = kind_and_channels & 0xffffU
  if (format == 1U || format == 2U) &&
    kind_and_channels >> 16 > 0U &&
    (pb_le32(data, 8) & 0xffffU) > 0U &&
    pb_le32(data, 10) > 0U {
    probe_score_extension + 30
  } else {
    0
  }
}
