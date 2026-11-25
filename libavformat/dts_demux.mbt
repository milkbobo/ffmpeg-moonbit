///|
/// Raw DTS core framing, based on FFmpeg `libavformat/dtsdec.c` (LGPL-2.1-
/// or-later, copyright 2008 Benjamin Larsson). Unlike FFmpeg's chunk reader
/// plus parser, this indexes complete core packets directly by header size.
/// Extension substreams are not supported.
pub struct DtsTrack {
  sample_rate : Int
  channels : Int
  /// Samples per channel in the first frame. Each packet has its own duration.
  frame_size : Int
  /// Source byte offsets and sizes; timestamps are in PCM samples from zero.
  frames : Array[RawAudioFrame]
  total_samples : Int64
}

///|
fn dts_has_extension(src : BytesView) -> Bool {
  src is [0x64, 0x58, 0x20, 0x25, ..]
}

///|
fn dts_find_start(data : Bytes) -> Result[(Int, @libavcodec.DcaCoreHeader), String] {
  // Cap prefix resynchronization; this demuxer is for raw core streams, not
  // for finding DTS payloads embedded deep inside unrelated files.
  for pos in 0..<data.length().min(4096) {
    let src = data[pos:]
    if dts_has_extension(src) {
      return Err("dts: extension substream is not supported")
    }
    if @libavcodec.parse_dca_core_header(src) is Ok(h) {
      return Ok((pos, h))
    }
  }
  Err("dts: no valid core header")
}

///|
fn dts_next_boundary(data : Bytes, end : Int) -> Int {
  // Some streams align packets to a 32-bit boundary. Do not include padding in
  // the packet and never skip a nonzero byte (including a partial sync word).
  let limit = (data.length() - end).min(3)
  for i in 0..<limit {
    if data[end + i] != 0 {
      return end + i
    }
  }
  end + limit
}

///|
/// Index complete DTS core packets in 16-bit or 14-bit BE/LE packing. Packet
/// data stays unchanged; its offsets and sizes index the original `data`.
/// The stream must use a constant sample rate and channel count.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_dts_open(b"") is Err("dts: no valid core header"))
/// }
/// ```
pub fn av_dts_open(data : Bytes) -> Result[DtsTrack, String] {
  let (start, first) = match dts_find_start(data) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let frames : Array[RawAudioFrame] = []
  for pos = start, h = first, pts = 0L; ; {
    if h.frame_size > data.length() - pos {
      return Err("dts: truncated core frame")
    }
    if h.sample_rate != first.sample_rate || h.channels != first.channels {
      return Err("dts: core stream parameters change between frames")
    }
    frames.push({
      pos: pos.to_int64(),
      size: h.frame_size,
      pts,
      duration: h.samples,
      is_keyframe: true,
    })
    let total_samples = pts + h.samples.to_int64()
    let next = dts_next_boundary(data, pos + h.frame_size)
    if next == data.length() {
      return Ok({
        sample_rate: first.sample_rate,
        channels: first.channels,
        frame_size: first.samples,
        frames,
        total_samples,
      })
    }
    let src = data[next:]
    if dts_has_extension(src) {
      return Err("dts: extension substream is not supported")
    }
    match @libavcodec.parse_dca_core_header(src) {
      Ok(next_h) => continue next, next_h, total_samples
      Err(e) => return Err(e)
    }
  }
}

///|
/// Probe only core streams. A complete leading frame suffices; if preceded
/// by junk, require two consecutive complete frames with matching parameters.
fn probe_dts(pd : ProbeData) -> Int {
  let (pos, first) = match dts_find_start(pd.buf) {
    Ok(v) => v
    Err(_) => return 0
  }
  if first.frame_size > pd.buf.length() - pos {
    return 0
  }
  let next = dts_next_boundary(pd.buf, pos + first.frame_size)
  let src = pd.buf[next:]
  if dts_has_extension(src) {
    return 0
  }
  let continued = @libavcodec.parse_dca_core_header(src) is Ok(h) &&
    h.frame_size <= src.length() &&
    first.sample_rate == h.sample_rate &&
    first.channels == h.channels
  if pos == 0 && (src.is_empty() || continued) {
    // DTS payload can contain false MPEG audio syncs. Prefer an exact
    // leading DTS frame boundary over the MPEG audio scan score (52).
    probe_score_extension + 3
  } else if pos == 0 || continued {
    probe_score_extension + 1
  } else {
    0
  }
}
