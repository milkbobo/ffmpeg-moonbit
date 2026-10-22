///|
/// MoonBit port of the FFmpeg 9.0.2 Opus packet layer:
/// `libavcodec/opus/parse.c` (`ff_opus_parse_packet`), `frame_duration_tab.c`
/// and the TOC handling used by `libavcodec/opus/parser.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: TOC parsing, packet codes 0..3, equal/VBR/CBR frame splitting with
/// 16-bit Xiph lacing, padding, self-delimiting multistream boundaries,
/// per-frame offsets/sizes and the 48 kHz packet duration.
/// The SILK/CELT sample decode itself is not part of this slice.

///|
pub struct OpusPacket {
  /// TOC config index 0..31.
  config : Int32
  /// Packet code 0..3 (1, 2, 2-different-size or arbitrary frames).
  code : Int32
  stereo : Bool
  vbr : Bool
  frame_count : Int32
  /// Per-frame duration in 48 kHz samples.
  frame_duration : Int32
  /// Total packet duration in 48 kHz samples.
  total_samples : Int32
  /// Per-frame sizes in bytes.
  frame_sizes : Array[Int32]
  /// Byte offsets of frame payloads inside the packet (excluding lacing).
  frame_offsets : Array[Int32]
  /// Bytes consumed, including TOC/lacing/padding. In self-delimiting mode
  /// following bytes belong to the next logical Opus stream.
  packet_size : Int32
  /// Bytes without TOC/lacing/padding.
  data_size : Int32
  padding : Int32
  /// "silk", "hybrid" or "celt".
  mode : String
  /// "narrowband", "mediumband", "wideband", "superwideband" or "fullband".
  bandwidth : String
}

///|
/// `ff_opus_frame_duration`: samples per frame at 48 kHz by TOC config. */
let opus_frame_duration : FixedArray[Int32] = [
  480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 480,
  960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480,
  960,
]

///|
/// `xiph_lacing_16bit`: one byte, plus `4 * next` when the first is >= 252. */
fn opus_lacing_16bit(data : BytesView, pos : Ref[Int32]) -> Int32 {
  if pos.val >= data.length() {
    return -1
  }
  let mut v = data[pos.val].to_int()
  pos.val = pos.val + 1
  if v >= 252 {
    if pos.val >= data.length() {
      return -1
    }
    v = v + 4 * data[pos.val].to_int()
    pos.val = pos.val + 1
  }
  v
}

///|
/// `xiph_lacing_full`: 255-continuation length used for padding. */
fn opus_lacing_full(data : BytesView, pos : Ref[Int32]) -> Int32 {
  let mut val = 0
  for ;; {
    if pos.val >= data.length() || val > 2147483393 {
      return -1
    }
    let next = data[pos.val].to_int()
    pos.val = pos.val + 1
    val = val + next
    if next < 255 {
      break
    }
    val = val - 1
  }
  val
}

///|
/// Parse an Opus packet's TOC and frame layout.
pub fn opus_parse_packet(data : Bytes) -> Result[OpusPacket, String] {
  opus_parse_packet_with(data, false)
}

///|
/// Parse regular or self-delimiting Opus framing (RFC 6716 Appendix B).
/// The latter carries the final frame length explicitly, allowing chained
/// packets in a multistream mapping. `packet_size` identifies the next stream.
/// Zero-byte DTX frames are valid; each nonempty frame is at most 1275 bytes.
///
/// ```mbt check
/// test {
///   let packet = @libavcodec.opus_parse_packet_with(b"\x80\x01\xaa\xbb", true).unwrap()
///   assert_eq(packet.packet_size, 3)
///   assert_eq(packet.frame_offsets, [2])
/// }
/// ```
pub fn opus_parse_packet_with(
  data : Bytes,
  self_delimiting : Bool,
) -> Result[OpusPacket, String] {
  opus_parse_packet_view(data[:], self_delimiting)
}

///|
// Shared view parser avoids copying the remaining packet for each substream.
fn opus_parse_packet_view(
  data : BytesView,
  self_delimiting : Bool,
) -> Result[OpusPacket, String] {
  let len = data.length()
  if len < 1 {
    return Err("opus: empty packet")
  }
  let toc = data[0].to_int()
  let code = toc & 0x3
  let stereo = ((toc >> 2) & 1) != 0
  let config = (toc >> 3) & 0x1F
  if config >= opus_frame_duration.length() {
    return Err("opus: invalid TOC config")
  }
  if code >= 2 && len < 2 {
    return Err("opus: truncated TOC")
  }
  let pos = Ref(1)
  let mut frame_count = 1
  let mut vbr = false
  let sizes : Array[Int32] = []
  let mut padding = 0
  let mut data_end = len
  if code == 0 {
    if self_delimiting {
      let size = opus_lacing_16bit(data, pos)
      if size < 0 || size > len - pos.val {
        return Err("opus: bad self-delimited frame length")
      }
      data_end = pos.val + size
    }
    let frame_bytes = data_end - pos.val
    sizes.push(frame_bytes)
  } else if code == 1 {
    frame_count = 2
    if self_delimiting {
      let size = opus_lacing_16bit(data, pos)
      if size < 0 || size > (len - pos.val) / 2 {
        return Err("opus: bad self-delimited frame length")
      }
      data_end = pos.val + 2 * size
    }
    let frame_bytes = data_end - pos.val
    if frame_bytes % 2 != 0 {
      return Err("opus: odd code 1 payload")
    }
    sizes.push(frame_bytes / 2)
    sizes.push(frame_bytes / 2)
  } else if code == 2 {
    frame_count = 2
    vbr = true
    let first = opus_lacing_16bit(data, pos)
    if first < 0 {
      return Err("opus: bad frame length")
    }
    sizes.push(first)
    if self_delimiting {
      let size = opus_lacing_16bit(data, pos)
      if size < 0 || size > len - pos.val - first {
        return Err("opus: bad self-delimited frame length")
      }
      data_end = pos.val + first + size
    }
    let second = data_end - pos.val - first
    if second < 0 {
      return Err("opus: truncated code 2 packet")
    }
    sizes.push(second)
  } else {
    let count_byte = data[pos.val].to_int()
    pos.val = pos.val + 1
    frame_count = count_byte & 0x3F
    padding = (count_byte >> 6) & 1
    vbr = ((count_byte >> 7) & 1) != 0
    if frame_count == 0 || frame_count > 48 {
      return Err("opus: invalid frame count")
    }
    if padding != 0 {
      padding = opus_lacing_full(data, pos)
      if padding < 0 {
        return Err("opus: bad padding length")
      }
    } else {
      padding = 0
    }
    if vbr {
      let mut total = 0
      for _ in 0..<(frame_count - 1) {
        let f = opus_lacing_16bit(data, pos)
        if f < 0 {
          return Err("opus: bad VBR frame length")
        }
        sizes.push(f)
        total = total + f
      }
      if self_delimiting {
        let size = opus_lacing_16bit(data, pos)
        if size < 0 || size > len - pos.val - total - padding {
          return Err("opus: bad self-delimited frame length")
        }
        data_end = pos.val + total + size + padding
      }
      let remaining = data_end - pos.val - padding
      if remaining < total {
        return Err("opus: VBR sizes exceed packet")
      }
      sizes.push(remaining - total)
    } else {
      if self_delimiting {
        let size = opus_lacing_16bit(data, pos)
        if size < 0 || padding > len - pos.val || size > (len - pos.val - padding) / frame_count {
          return Err("opus: bad self-delimited frame length")
        }
        data_end = pos.val + size * frame_count + padding
      }
      let frame_bytes = data_end - pos.val - padding
      if frame_bytes < 0 { return Err("opus: padding exceeds packet") }
      if frame_bytes % frame_count != 0 {
        return Err("opus: CBR payload not divisible by frame count")
      }
      for _ in 0..<frame_count {
        sizes.push(frame_bytes / frame_count)
      }
    }
    data_end = data_end - padding
  }
  let offsets : Array[Int32] = []
  let mut offset = pos.val
  for size in sizes {
    if size < 0 || size > 1275 { return Err("opus: frame size exceeds 1275 bytes") }
    offsets.push(offset)
    offset += size
  }
  let frame_duration = opus_frame_duration[config]
  let total_samples = frame_duration * frame_count
  if total_samples > 5760 {
    return Err("opus: packet longer than 120 ms")
  }
  let mode = if config < 12 {
    "silk"
  } else if config < 16 {
    "hybrid"
  } else {
    "celt"
  }
  let bandwidth = if config < 12 {
    match config >> 2 {
      0 => "narrowband"
      1 => "mediumband"
      2 => "wideband"
      _ => "fullband"
    }
  } else if config < 16 {
    if config >= 14 {
      "fullband"
    } else {
      "superwideband"
    }
  } else {
    match (config - 16) >> 2 {
      0 => "narrowband"
      1 => "wideband"
      2 => "superwideband"
      _ => "fullband"
    }
  }
  Ok({
    config,
    code,
    stereo,
    vbr,
    frame_count,
    frame_duration,
    total_samples,
    frame_sizes: sizes,
    frame_offsets: offsets,
    packet_size: data_end + padding,
    data_size: data_end - pos.val,
    padding,
    mode,
    bandwidth,
  })
}
