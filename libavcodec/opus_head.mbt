///|
/// Opus identification and channel mapping, ported from FFmpeg 9.0.2
/// opus/parse.c (ff_opus_parse_extradata), vorbis_data.c and opus/dec.c.
/// Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla Corporation.
/// LGPL-2.1-or-later. The OpusHead signature is checked explicitly; this
/// parser accepts actual container extradata, not C's missing-header fallback.
pub struct OpusHead {
  version : Int32
  channels : Int32
  pre_skip : Int32
  /// Informational source rate; decoding always runs at 48 kHz.
  input_sample_rate : UInt32
  /// Signed Q8 dB gain from the header; not applied by the packet layer.
  output_gain : Int32
  mapping_family : Int32
  stream_count : Int32
  coupled_count : Int32
  /// Original header ordering, including 255 for silence.
  channel_map : Array[Int32]
  /// FFmpeg output order (Vorbis family 1 reordered to native layout).
  output_map : Array[OpusChannelMap]
}

///|
/// One output channel's source; a repeated mapping uses `copy_from` to
/// identify its earlier output. Silent channels have stream_index=-1.
pub struct OpusChannelMap {
  stream_index : Int32
  channel_index : Int32
  silence : Bool
  copy_from : Int32?
}

///|
let opus_vorbis_reorder : Array[Array[Int32]] = [
  [0],
  [0, 1],
  [0, 2, 1],
  [0, 1, 2, 3],
  [0, 2, 1, 3, 4],
  [0, 2, 1, 5, 3, 4],
  [0, 2, 1, 6, 5, 3, 4],
  [0, 2, 1, 7, 5, 6, 3, 4],
]

///|
/// Parse OpusHead mapping families 0 (mono/stereo), 1 (Vorbis order),
/// 2 (ambisonics) and 255 (unspecified), matching FFmpeg's native decoder.
/// Unknown versions/families and out-of-range stream/channel maps fail.
/// Input sample rate is metadata; pre-skip is measured at 48 kHz.
///
/// ```mbt check
/// test {
///   let head = @libavcodec.opus_parse_head(
///     b"OpusHead\x01\x02\x38\x01\x80\xbb\x00\x00\x00\x00\x00",
///   ).unwrap()
///   assert_eq(head.pre_skip, 312)
///   assert_eq(head.stream_count, 1)
///   assert_eq(head.coupled_count, 1)
///   let streams = head.parse_packet(b"\x80\xaa").unwrap()
///   assert_eq(streams.length(), 1)
///   assert_eq(streams[0].packet.total_samples, 120)
/// }
/// ```
pub fn opus_parse_head(data : Bytes) -> Result[OpusHead, String] {
  if data.length() < 19 {
    return Err("opus: truncated OpusHead")
  }
  if data[0:8].to_owned() != b"OpusHead" {
    return Err("opus: invalid OpusHead signature")
  }
  let version = data[8].to_int()
  if version > 15 {
    return Err("opus: unsupported OpusHead version")
  }
  let channels = data[9].to_int()
  if channels == 0 {
    return Err("opus: zero channel count")
  }
  let pre_skip = data[10].to_int() | (data[11].to_int() << 8)
  let input_sample_rate = data[12].to_uint() |
    (data[13].to_uint() << 8) |
    (data[14].to_uint() << 16) |
    (data[15].to_uint() << 24)
  let gain = data[16].to_int() | (data[17].to_int() << 8)
  let output_gain = if gain >= 32768 { gain - 65536 } else { gain }
  let family = data[18].to_int()
  let (stream_count, coupled_count, channel_map) = if family == 0 {
    if channels > 2 {
      return Err("opus: mapping family 0 requires mono or stereo")
    }
    (1, channels - 1, [ for i in 0..<channels => i ])
  } else if family == 1 || family == 2 || family == 255 {
    if data.length() < 21 + channels {
      return Err("opus: truncated OpusHead mapping")
    }
    let stream_count = data[19].to_int()
    let coupled_count = data[20].to_int()
    if stream_count == 0 ||
      coupled_count > stream_count ||
      stream_count + coupled_count > 255 {
      return Err("opus: invalid stream or coupled stream count")
    }
    if family == 1 && channels > 8 {
      return Err("opus: mapping family 1 exceeds eight channels")
    }
    if family == 2 {
      let mut root = 1
      while (root + 1) * (root + 1) <= channels {
        root += 1
      }
      if channels > 227 ||
        !(channels == root * root || channels == root * root + 2) {
        return Err("opus: invalid ambisonic channel count")
      }
    }
    (
      stream_count,
      coupled_count,
      [
        for i in 0..<channels => data[21 + i].to_int()
      ],
    )
  } else {
    return Err("opus: unsupported OpusHead mapping family")
  }
  let output_map : Array[OpusChannelMap] = []
  let indices : Array[Int32] = []
  for i in 0..<channels {
    let source = if family == 1 {
      opus_vorbis_reorder[channels - 1][i]
    } else {
      i
    }
    let index = channel_map[source]
    indices.push(index)
    if index == 255 {
      output_map.push({
        stream_index: -1,
        channel_index: 0,
        silence: true,
        copy_from: None,
      })
      continue
    }
    if index >= stream_count + coupled_count {
      return Err("opus: channel map outside coded channels")
    }
    let mut copy_from = None
    for j in 0..<i {
      if indices[j] == index {
        copy_from = Some(j)
        break
      }
    }
    let (stream_index, channel_index) = if index < 2 * coupled_count {
      (index / 2, index & 1)
    } else {
      (index - coupled_count, 0)
    }
    output_map.push({ stream_index, channel_index, silence: false, copy_from, })
  }
  Ok({
    version,
    channels,
    pre_skip,
    input_sample_rate,
    output_gain,
    mapping_family: family,
    stream_count,
    coupled_count,
    channel_map,
    output_map,
  })
}

///|
/// One logical stream inside a multistream packet. Frame offsets in `packet`
/// are relative to this stream; add `offset` to index the original packet.
pub struct OpusStreamPacket {
  offset : Int32
  packet : OpusPacket
}

///|
/// Split one container packet into its logical Opus streams. All but the
/// final stream use self-delimiting framing, and all streams must represent
/// the same number of 48 kHz samples (their individual frame counts can differ).
/// Empty packets fail; packet loss concealment is handled by the frame decoder.
pub fn OpusHead::parse_packet(
  self : OpusHead,
  data : Bytes,
) -> Result[Array[OpusStreamPacket], String] {
  let streams : Array[OpusStreamPacket] = []
  let mut offset = 0
  let mut samples = -1
  for i in 0..<self.stream_count {
    let packet = match
      opus_parse_packet_view(data[offset:], i + 1 < self.stream_count) {
      Ok(p) => p
      Err(e) => return Err(e)
    }
    if samples >= 0 && samples != packet.total_samples {
      return Err("opus: mismatching multistream sample counts")
    }
    samples = packet.total_samples
    streams.push({ offset, packet, })
    offset += packet.packet_size
  }
  Ok(streams)
}
