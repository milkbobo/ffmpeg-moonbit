///|
/// Raw AAC (ADTS) and MPEG-audio (MP1/MP2/MP3) stream framing, following the
/// frame walk of FFmpeg 9.0.2 `libavformat/aacdec.c` / `libavformat/mp3dec.c`
/// and `libavcodec/adts_header.c` + `libavcodec/mpegaudiodecheader.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The demuxers in the C read fixed-size chunks and leave frame splitting to
/// the codec parser. This port materialises frames eagerly (the same design as
/// the MP4/Matroska slices): every returned frame spans one complete ADTS or
/// MPEG-audio frame, so its `pos`/`size` match `ffprobe -show_packets`.
///
/// Out of scope: ID3 tag *contents* (only the v2 size and v1 footer are
/// skipped), Xing/VBRI duration/TOC fields (the leading Xing/Info frame is
/// detected and skipped, matching the C parser), and resync heuristics beyond
/// byte-wise sync scanning.

// ---------------------------------------------------------------------------
// data model
// ---------------------------------------------------------------------------

///|
/// One frame of a raw audio stream. */
pub struct RawAudioFrame {
  /// Byte offset in the input.
  pos : Int64
  /// Frame size in bytes, including the ADTS/MPEG header.
  size : Int32
  /// Presentation time in PCM sample units (frame-aligned, starts at 0).
  pts : Int64
  /// Duration in PCM samples.
  duration : Int32
  is_keyframe : Bool
}

///|
/// A parsed raw audio stream. */
pub struct RawAudioTrack {
  /// "aac", "mp3", "mp2" or "mp1".
  codec : String
  /// ADTS profile name ("Main"/"LC"/"SSR"/"LTP") or "".
  profile : String
  sample_rate : Int32
  channels : Int32
  /// PCM samples per coded frame (1024 for ADTS, 1152/576 for MP3).
  frame_size : Int32
  frames : Array[RawAudioFrame]
  total_samples : Int64
  /// Average bit rate (AAC) or the first frame's bit rate (MPEG audio).
  bit_rate : Int32
  /// Bytes of a leading ID3v2 tag.
  id3v2_size : Int32
  /// Bytes of a skipped leading Xing/Info/VBRI frame (MPEG audio).
  info_frame_size : Int32
}

// ---------------------------------------------------------------------------
// ID3v2 helpers (id3v2.c)
// ---------------------------------------------------------------------------

///|
/// `ID3v2_HEADER_SIZE`. */
let id3v2_header_size : Int32 = 10

///|
/// `ff_id3v2_match(buf, "ID3")`. */
pub fn ff_id3v2_match(buf : Bytes) -> Bool {
  if buf.length() < id3v2_header_size {
    return false
  }
  buf[0] == b'I' &&
  buf[1] == b'D' &&
  buf[2] == b'3' &&
  buf[3] != b'\xFF' &&
  buf[4] != b'\xFF' &&
  (buf[6].to_int() & 0x80) == 0 &&
  (buf[7].to_int() & 0x80) == 0 &&
  (buf[8].to_int() & 0x80) == 0 &&
  (buf[9].to_int() & 0x80) == 0
}

///|
/// `ff_id3v2_tag_len`: total tag size including the 10-byte header and the
/// optional 10-byte footer. */
pub fn ff_id3v2_tag_len(buf : Bytes) -> Int32 {
  if buf.length() < id3v2_header_size {
    return 0
  }
  let mut len = ((buf[6].to_int() & 0x7F) << 21) +
    ((buf[7].to_int() & 0x7F) << 14) +
    ((buf[8].to_int() & 0x7F) << 7) +
    (buf[9].to_int() & 0x7F) +
    id3v2_header_size
  if (buf[5].to_int() & 0x10) != 0 {
    len = len + id3v2_header_size
  }
  len
}

///|
/// Skip a leading ID3v2 tag if present. */
fn id3_skip(data : Bytes) -> Int32 {
  if !ff_id3v2_match(data) {
    return 0
  }
  let len = ff_id3v2_tag_len(data)
  if len > data.length() {
    data.length()
  } else {
    len
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

///|
/// Big-endian 32-bit read (AV_RB32). */
fn rb32(data : Bytes, pos : Int32) -> UInt32 {
  if pos < 0 || pos + 4 > data.length() {
    return 0U
  }
  (data[pos].to_uint() << 24) |
  (data[pos + 1].to_uint() << 16) |
  (data[pos + 2].to_uint() << 8) |
  data[pos + 3].to_uint()
}

///|
/// Compare four bytes against an ASCII tag. */
fn match_fourcc(data : Bytes, pos : Int32, tag : Bytes) -> Bool {
  if pos < 0 || pos + 4 > data.length() || tag.length() < 4 {
    return false
  }
  data[pos] == tag[0] &&
  data[pos + 1] == tag[1] &&
  data[pos + 2] == tag[2] &&
  data[pos + 3] == tag[3]
}

///|
/// `ff_mpeg4audio_channels` subset used for ADTS channel_configuration. */
fn adts_channels(chan_config : Int32) -> Int32 {
  if chan_config >= 1 && chan_config <= 6 {
    chan_config
  } else if chan_config == 7 {
    8
  } else {
    0
  }
}

///|
/// ADTS `profile_objecttype` (object_type - 1). */
fn adts_profile_name(object_type : Int32) -> String {
  match object_type {
    1 => "Main"
    2 => "LC"
    3 => "SSR"
    4 => "LTP"
    _ => ""
  }
}

// ---------------------------------------------------------------------------
// AAC ADTS
// ---------------------------------------------------------------------------

///|
/// Parse a raw ADTS AAC stream. Frames are split on `aac_frame_length`; each
/// returned frame includes its 7-byte ADTS header (plus CRC when present).
pub fn av_adts_open(data : Bytes) -> Result[RawAudioTrack, String] {
  let start = id3_skip(data)
  let frames : Array[RawAudioFrame] = []
  let mut pos = start
  let mut pts : Int64 = 0
  let mut sample_rate = 0
  let mut channels = 0
  let mut frame_size = 0
  let mut profile = ""
  while pos + @libavcodec.av_aac_adts_header_size <= data.length() {
    let hdr = data
      .clamped_view(start=pos, end=pos + @libavcodec.av_aac_adts_header_size)
      .to_owned()
    let header = match @libavcodec.ff_adts_header_parse_buf(hdr) {
      Ok(h) => h
      Err(_) => {
        // Resync one byte at a time (the C parser's av_parser_parse2 loop).
        pos = pos + 1
        continue
      }
    }
    if frames.length() == 0 {
      sample_rate = header.sample_rate
      channels = adts_channels(header.chan_config)
      frame_size = header.samples
      profile = adts_profile_name(header.object_type)
    } else if header.sample_rate != sample_rate {
      // A format change mid-stream is not representable in one track.
      break
    }
    let len = header.frame_length
    if pos + len > data.length() {
      break
    }
    frames.push({
      pos: pos.to_int64(),
      size: len,
      pts,
      duration: header.samples,
      is_keyframe: true,
    })
    pts = pts + header.samples.to_int64()
    pos = pos + len
  }
  if frames.length() == 0 {
    return Err("EINVAL")
  }
  let bit_rate = if pts > 0L {
    ((data.length() - start).to_int64() * 8L * sample_rate.to_int64() / pts).to_int()
  } else {
    0
  }
  Ok({
    codec: "aac",
    profile,
    sample_rate,
    channels,
    frame_size,
    frames,
    total_samples: pts,
    bit_rate,
    id3v2_size: start,
    info_frame_size: 0,
  })
}

// ---------------------------------------------------------------------------
// AMR-NB
// ---------------------------------------------------------------------------

///|
/// `#!AMR\n` / `#!AMR-WB\n` file signature (`libavformat/amr.c`). */
fn amr_header_len(data : Bytes) -> Int32 {
  if data.length() >= 6 &&
    data[0] == b'#' &&
    data[1] == b'!' &&
    data[2] == b'A' &&
    data[3] == b'M' &&
    data[4] == b'R' &&
    data[5] == b'\n' {
    return 6
  }
  if data.length() >= 9 &&
    data[0] == b'#' &&
    data[1] == b'!' &&
    data[2] == b'A' &&
    data[3] == b'M' &&
    data[4] == b'R' &&
    data[5] == b'-' &&
    data[6] == b'W' &&
    data[7] == b'B' &&
    data[8] == b'\n' {
    return 9
  }
  0
}

///|
/// Parse a raw AMR-NB stream: the optional `#!AMR\n` magic followed by RFC
/// 4867 frames (a table-of-contents byte plus speech payload).  Each packet
/// includes its TOC byte, as in the C demuxer; `frame_size` is 160 samples.
pub fn av_amr_open(data : Bytes) -> Result[RawAudioTrack, String] {
  let magic_len = amr_header_len(data)
  if magic_len >= 9 {
    return Err("unsupported AMR-WB stream")
  }
  let start = if magic_len == 6 { magic_len } else { 0 }
  let frames : Array[RawAudioFrame] = []
  let mut pos = start
  let mut pts : Int64 = 0
  while pos < data.length() {
    let frame = data[pos:].to_owned()
    let size = @libavcodec.amrnb_frame_size(frame)
    if size <= 0 || pos + size > data.length() {
      break
    }
    frames.push({
      pos: pos.to_int64(),
      size,
      pts,
      duration: 160,
      is_keyframe: true,
    })
    pts = pts + 160L
    pos = pos + size
  }
  if frames.length() == 0 {
    return Err("EINVAL")
  }
  Ok({
    codec: "amr_nb",
    profile: "",
    sample_rate: 8000,
    channels: 1,
    frame_size: 160,
    frames,
    total_samples: pts,
    bit_rate: 0,
    id3v2_size: start,
    info_frame_size: 0,
  })
}

// ---------------------------------------------------------------------------
// AC-3
// ---------------------------------------------------------------------------

///|
/// Parse a raw AC-3 stream (`libavformat/ac3dec.c`): frames are split on the
/// header frame size, which varies per frame at 44.1 kHz.  Each frame yields
/// `num_blocks * 256` samples (normally 1536).
pub fn av_ac3_open(data : Bytes) -> Result[RawAudioTrack, String] {
  let start = id3_skip(data)
  let frames : Array[RawAudioFrame] = []
  let mut pos = start
  let mut pts : Int64 = 0
  let mut sample_rate = 0
  let mut channels = 0
  let mut frame_size = 0
  let mut bit_rate = 0
  while pos + 8 <= data.length() {
    if data[pos] != b'\x0B' || data[pos + 1] != b'\x77' {
      // Resync one byte at a time, like the parser.
      pos = pos + 1
      continue
    }
    let hdr = match @libavcodec.ac3_parse_header(data[pos:].to_owned()) {
      Ok(h) => h
      Err(_) => {
        pos = pos + 1
        continue
      }
    }
    let duration = hdr.num_blocks * 256
    if hdr.frame_size <= 0 || pos + hdr.frame_size > data.length() {
      break
    }
    if frames.length() == 0 {
      sample_rate = hdr.sample_rate
      channels = hdr.channels
      frame_size = duration
      bit_rate = hdr.bit_rate
    } else if hdr.sample_rate != sample_rate || hdr.channels != channels {
      // A format change mid-stream is not representable in one track.
      break
    }
    frames.push({
      pos: pos.to_int64(),
      size: hdr.frame_size,
      pts,
      duration,
      is_keyframe: true,
    })
    pts = pts + duration.to_int64()
    pos = pos + hdr.frame_size
  }
  if frames.length() == 0 {
    return Err("EINVAL")
  }
  Ok({
    codec: "ac3",
    profile: "",
    sample_rate,
    channels,
    frame_size,
    frames,
    total_samples: pts,
    bit_rate,
    id3v2_size: start,
    info_frame_size: 0,
  })
}

// ---------------------------------------------------------------------------
// MPEG audio
// ---------------------------------------------------------------------------

///|
/// Xing/Info tag offset from the end of the 4-byte frame header
/// (`xing_offtbl[lsf == 1][nb_channels == 1]`). */
fn xing_offset(h : @libavcodec.MpaDecodeHeader) -> Int32 {
  if h.lsf == 1 {
    if h.nb_channels == 1 {
      9
    } else {
      17
    }
  } else if h.nb_channels == 1 {
    17
  } else {
    32
  }
}

///|
/// Whether this frame is a Xing/Info/VBRI metadata frame. */
fn mpa_is_info_frame(
  data : Bytes,
  pos : Int32,
  h : @libavcodec.MpaDecodeHeader,
) -> Bool {
  if match_fourcc(data, pos + 4 + xing_offset(h), b"Xing") ||
    match_fourcc(data, pos + 4 + xing_offset(h), b"Info") {
    return true
  }
  // VBRI is always 32 bytes after the end of the MPEG header.
  match_fourcc(data, pos + 4 + 32, b"VBRI")
}

///|
/// Parse a raw MPEG-audio stream. The leading Xing/Info/VBRI frame (if any) is
/// reported via `info_frame_size` and excluded from `frames`, matching the C
/// parser's packet stream. A trailing ID3v1 tag is ignored.
pub fn av_mp3_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if data.length() < 4 {
    return Err("EINVAL")
  }
  let start = id3_skip(data)
  let mut end = data.length()
  if end >= 128 && match_fourcc(data, end - 128, b"TAG") {
    end = end - 128
  }
  // Find the first valid frame header.
  let mut pos = start
  let mut first = -1
  while pos + 4 <= end {
    let header = rb32(data, pos)
    if @libavcodec.ff_mpa_check_header(header) {
      match @libavcodec.avpriv_mpegaudio_decode_header(header) {
        Ok(h) =>
          if !h.free_format && pos + h.frame_size <= end {
            first = pos
            break
          }
        Err(_) => ()
      }
    }
    pos = pos + 1
  }
  if first < 0 {
    return Err("EINVAL")
  }
  let first_header = match
    @libavcodec.avpriv_mpegaudio_decode_header(rb32(data, first)) {
    Ok(v) => v
    Err(_) => return Err("EINVAL")
  }
  let stream_info = match @libavcodec.ff_mpa_decode_header(rb32(data, first)) {
    Ok(v) => v
    Err(_) => return Err("EINVAL")
  }
  let mut info_frame_size = 0
  let mut pos = first
  if mpa_is_info_frame(data, pos, first_header) {
    info_frame_size = first_header.frame_size
    pos = pos + first_header.frame_size
  }
  let frames : Array[RawAudioFrame] = []
  let mut pts : Int64 = 0
  while pos + 4 <= end {
    let header = rb32(data, pos)
    if !@libavcodec.ff_mpa_check_header(header) {
      break
    }
    let h = match @libavcodec.avpriv_mpegaudio_decode_header(header) {
      Ok(v) => v
      Err(_) => break
    }
    if h.free_format || h.frame_size <= 0 || pos + h.frame_size > end {
      break
    }
    if h.sample_rate != first_header.sample_rate ||
      h.layer != first_header.layer ||
      h.lsf != first_header.lsf {
      break
    }
    frames.push({
      pos: pos.to_int64(),
      size: h.frame_size,
      pts,
      duration: stream_info.samples_per_frame,
      is_keyframe: true,
    })
    pts = pts + stream_info.samples_per_frame.to_int64()
    pos = pos + h.frame_size
  }
  if frames.length() == 0 {
    return Err("EINVAL")
  }
  Ok({
    codec: stream_info.codec,
    profile: "",
    sample_rate: stream_info.sample_rate,
    channels: stream_info.channels,
    frame_size: stream_info.samples_per_frame,
    frames,
    total_samples: pts,
    bit_rate: stream_info.bit_rate,
    id3v2_size: start,
    info_frame_size,
  })
}
