///|
/// DSF planar DSD and uncompressed DSDIFF, following FFmpeg dsfdec.c
/// (copyright 2014 Peter Ross) and iff.c (LGPL-2.1-or-later).
pub struct DsdTrack {
  codec : String
  sample_rate : Int32
  channels : Int32
  total_samples : Int64
  frames : Array[RawAudioFrame]
  /// Physical spacing between channel planes in a padded DSF final block.
  /// Zero when the indexed packets are already contiguous.
  padded_plane_stride : Int32
}

///|
fn dsd_index(
  start : Int32,
  count : Int64,
  channels : Int32,
  packet_samples : Int32,
) -> Array[RawAudioFrame] {
  let frames : Array[RawAudioFrame] = []
  for pts = 0L, pos = start.to_int64(); pts < count; {
    let duration = (count - pts).min(packet_samples.to_int64()).to_int()
    let size = duration * channels
    frames.push({ pos, size, pts, duration, is_keyframe: true, })
    continue pts + duration.to_int64(), pos + size.to_int64()
  }
  frames
}

///|
/// Open a version-1 DSF file. The sample count excludes padding in each
/// channel's final block. A trailing metadata chunk is outside the audio.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_dsf_open(b"DSD ") is Err(_))
/// }
/// ```
pub fn av_dsf_open(data : Bytes) -> Result[DsdTrack, String] {
  let src = data[:]
  if data.length() < 92 || src[:4] != b"DSD " || wav_u64(src, 4) != 28L {
    return Err("dsf: invalid DSD header")
  }
  if src[28:32] != b"fmt " ||
    wav_u64(src, 32) != 52L ||
    pb_le32(data, 40) != 1U ||
    pb_le32(data, 44) != 0U {
    return Err("dsf: unsupported fmt chunk")
  }
  let channel_type = pb_le32(data, 48).to_int64()
  let channels = pb_le32(data, 52).reinterpret_as_int()
  let layouts = [0, 1, 2, 3, 4, 4, 5, 6]
  if channels < 1 ||
    channels > 64 ||
    (
      channel_type >= 1L &&
      channel_type <= 7L &&
      layouts[channel_type.to_int()] != channels
    ) {
    return Err("dsf: invalid channel count")
  }
  let rate = pb_le32(data, 56).to_int64() / 8L
  let codec = match pb_le32(data, 60) {
    1U => "dsd_lsbf_planar"
    8U => "dsd_msbf_planar"
    _ => return Err("dsf: invalid bit order")
  }
  let count = wav_u64(src, 64) / 8L
  let stride = pb_le32(data, 72).to_int64()
  if rate == 0L ||
    count <= 0L ||
    stride == 0L ||
    stride * channels.to_int64() > 0x7fffffffL {
    return Err("dsf: invalid stream parameters")
  }
  let chunk = wav_u64(src, 84)
  if src[80:84] != b"data" ||
    chunk < 12L ||
    chunk > (data.length() - 80).to_int64() {
    return Err("dsf: invalid data chunk")
  }
  let data_size = chunk - 12L
  if count > data_size / channels.to_int64() {
    return Err("dsf: truncated audio")
  }
  let packed = count * channels.to_int64()
  let padded = (count + stride - 1L) / stride * stride * channels.to_int64()
  if data_size != packed && data_size != padded {
    return Err("dsf: invalid channel block padding")
  }
  Ok({
    codec,
    sample_rate: rate.to_int(),
    channels,
    total_samples: count,
    frames: dsd_index(92, count, channels, stride.to_int()),
    padded_plane_stride: if data_size > packed {
      stride.to_int()
    } else {
      0
    },
  })
}

///|
fn dsdiff_chunk(
  data : Bytes,
  pos : Int32,
  limit : Int32,
) -> Result[(String, Int32, Int32, Int32), String] {
  if limit - pos < 12 {
    return Err("dff: truncated chunk header")
  }
  let body = pos + 12
  let size = pb_be64(data, pos + 4)
  if size > (limit - body).to_int64().reinterpret_as_uint64() {
    return Err("dff: chunk exceeds its parent")
  }
  let end = body + size.to_int()
  if (size & 1UL) != 0UL && end == limit {
    return Err("dff: missing chunk padding")
  }
  Ok((wav_fourcc(data[:], pos), body, end, end + (size & 1UL).to_int()))
}

///|
fn dsdiff_properties(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> Result[(Int32, Int32, String), String] {
  if end - start < 4 || data[start:start + 4] != b"SND " {
    return Err("dff: missing SND property type")
  }
  let mut rate = 0
  let mut channels = 0
  let mut codec = ""
  for pos = start + 4; pos < end; {
    let (tag, body, stop, next) = match dsdiff_chunk(data, pos, end) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match tag {
      "FS  " if stop - body >= 4 =>
        rate = (pb_be32(data, body).to_int64() / 8L).to_int()
      "CHNL" if stop - body >= 2 => {
        channels = pb_be16(data, body).reinterpret_as_int()
        if channels < 1 || channels > 64 || stop - body < 2 + 4 * channels {
          return Err("dff: invalid channel list")
        }
      }
      "CMPR" => {
        if stop - body < 4 {
          return Err("dff: unsupported compression")
        }
        codec = match data[body:body + 4] {
          [b'D', b'S', b'D', b' '] => "dsd_msbf"
          [b'D', b'S', b'T', b' '] => "dst"
          _ => return Err("dff: unsupported compression")
        }
      }
      _ => ()
    }
    continue next
  }
  if rate <= 0 || channels <= 0 || codec == "" {
    return Err("dff: missing DSD stream properties")
  }
  Ok((rate, channels, codec))
}

///|
fn dsdiff_dst_track(
  data : Bytes,
  start : Int32,
  end : Int32,
  sample_rate : Int32,
  channels : Int32,
) -> Result[DsdTrack, String] {
  let duration = @libavcodec.dst_frame_samples(sample_rate)
  if duration == 0 || channels < 1 || channels > 6 {
    return Err("dff: unsupported DST stream parameters")
  }
  let mut count = 0L
  let mut pts = 0L
  let frames : Array[RawAudioFrame] = []
  for pos = start; pos < end; {
    let (tag, body, stop, next) = match dsdiff_chunk(data, pos, end) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match tag {
      "FRTE" => {
        if stop - body < 6 || pb_be16(data, body + 4) != 75U {
          return Err("dff: invalid DST frame rate")
        }
        count = pb_be32(data, body).to_int64()
      }
      "DSTF" => {
        let size = stop - body
        if size < 2 {
          return Err("dff: empty DST frame")
        }
        frames.push({
          pos: body.to_int64(),
          size,
          pts,
          duration,
          is_keyframe: true,
        })
        pts += duration.to_int64()
      }
      _ => () // Includes optional DSTC CRC chunks, as in FFmpeg.
    }
    continue next
  }
  if frames.is_empty() || count != frames.length().to_int64() {
    return Err("dff: invalid DST frame count")
  }
  Ok({
    codec: "dst",
    sample_rate,
    channels,
    total_samples: pts,
    frames,
    padded_plane_stride: 0,
  })
}

///|
/// Open interleaved DSD or DST-compressed audio in a DSDIFF file.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_dff_open(b"FRM8") is Err(_))
/// }
/// ```
pub fn av_dff_open(data : Bytes) -> Result[DsdTrack, String] {
  if data.length() < 16 || data[:4] != b"FRM8" || data[12:16] != b"DSD " {
    return Err("dff: invalid DSD form")
  }
  let size = pb_be64(data, 4)
  if size < 4UL ||
    size > (data.length() - 12).to_int64().reinterpret_as_uint64() {
    return Err("dff: invalid form size")
  }
  let limit = 12 + size.to_int()
  let mut rate = 0
  let mut channels = 0
  let mut codec = ""
  let mut start = -1
  let mut length = 0
  let mut dst_body : (Int32, Int32)? = None
  for pos = 16; pos < limit; {
    let (tag, body, end, next) = match dsdiff_chunk(data, pos, limit) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match tag {
      "PROP" =>
        match dsdiff_properties(data, body, end) {
          Ok((r, c, encoding)) => {
            rate = r
            channels = c
            codec = encoding
          }
          Err(e) => return Err(e)
        }
      "DSD " => {
        start = body
        length = end - body
      }
      "DST " => dst_body = Some((body, end))
      _ => ()
    }
    continue next
  }
  if codec == "dst" {
    guard dst_body is Some((body, end)) else {
      return Err("dff: missing DST audio chunk")
    }
    return dsdiff_dst_track(data, body, end, rate, channels)
  }
  if start < 0 || length == 0 || channels <= 0 || length % channels != 0 {
    return Err("dff: invalid interleaved DSD payload")
  }
  let total_samples = (length / channels).to_int64()
  Ok({
    codec: "dsd_msbf",
    sample_rate: rate,
    channels,
    total_samples,
    frames: dsd_index(start, total_samples, channels, 8192),
    padded_plane_stride: 0,
  })
}

///|
fn probe_dsf(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 12 &&
    pd.buf[:4] == b"DSD " &&
    wav_u64(pd.buf[:], 4) == 28L {
    probe_score_max
  } else {
    0
  }
}

///|
fn probe_dff(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 16 && pd.buf[:4] == b"FRM8" && pd.buf[12:16] == b"DSD " {
    probe_score_max
  } else {
    0
  }
}
