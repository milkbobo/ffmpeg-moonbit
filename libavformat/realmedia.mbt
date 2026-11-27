///|
/// RealMedia / RealAudio container demuxer (`.rm`, `.rmvb`, `.ra`): a port of
/// FFmpeg 9.0.2 `libavformat/rmdec.c` together with `rmsipr.c` (the SIPR
/// sub-packet de-scrambling) and `rm.c` (codec tags, metadata keys).
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope and deviations:
/// * The file header (`.RMF` / `.RMP`, or the bare `.ra` header of the very
///   old format), `PROP`, `CONT`, `MDPR` (audio headers of versions 3, 4 and
///   5, `VIDO` video headers, `MLTI` SureStream groups and
///   `logical-fileinfo`), `INDX` and the `DATA` chunk are all read in one
///   pass over an in-memory buffer.
/// * Audio de-interleavers: `Int0` (none), `Int4` (RA 28.8), `genr` (Cook,
///   ATRAC3), `sipr` and the AAC `vbrf` / `vbrs` variable-bitrate layouts.
///   AC-3 packets get their byte pairs swapped as in the C.
/// * Video slice assembly (`rm_assemble_video_frame`) is ported so that
///   RealVideo streams keep their frame boundaries and 9-byte slice table,
///   and so that interleaved files are walked correctly; the RealVideo
///   decoders are not part of this port. Video packets carry the timestamps
///   of their records. FFmpeg additionally runs RV30 / RV40 through the
///   `rv34` parser, which rewrites the packet timestamps from the 13-bit
///   picture timestamps of the bitstream (B-frames do not carry usable ones
///   in the records); that is not reproduced here.
/// * Streams whose FourCC FFmpeg does not know are dropped instead of being
///   kept as data streams.
/// * FFmpeg's generic demux layer fills in the timestamps of de-interleaved
///   audio packets (only the first packet of an interleaved group carries
///   one) and marks every audio packet as a keyframe (audio codecs are
///   intra-only). This port applies the same rules when it emits packets,
///   so `pts` / `keyframe` match what `ffprobe -show_packets` prints.
///
/// The port is split over three files: this one holds the tables, the data
/// model and the byte reader; `realmedia_header.mbt` parses the header
/// chunks; `realmedia_packets.mbt` walks the `DATA` chunk.

// ---------------------------------------------------------------------------
// FourCC helpers and tables
// ---------------------------------------------------------------------------

///|
/// `MKTAG(a, b, c, d)`: the little-endian word of four ASCII characters.
fn realmedia_tag(s : String) -> Int32 {
  s[0].to_int() |
  (s[1].to_int() << 8) |
  (s[2].to_int() << 16) |
  (s[3].to_int() << 24)
}

///|
/// `MKBETAG(a, b, c, d)`: the big-endian word of four ASCII characters.
fn realmedia_tag_be(s : String) -> UInt32 {
  (s[0].to_int().reinterpret_as_uint() << 24) |
  (s[1].to_int().reinterpret_as_uint() << 16) |
  (s[2].to_int().reinterpret_as_uint() << 8) |
  s[3].to_int().reinterpret_as_uint()
}

///|
/// `AV_RL32` of four bytes.
fn realmedia_le32(b : Bytes, off : Int32) -> Int32 {
  let b0 = b[off].to_int().reinterpret_as_uint()
  let b1 = b[off + 1].to_int().reinterpret_as_uint()
  let b2 = b[off + 2].to_int().reinterpret_as_uint()
  let b3 = b[off + 3].to_int().reinterpret_as_uint()
  let word = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
  word.reinterpret_as_int()
}

///|
/// `AV_WL32`.
fn realmedia_wl32(buf : Array[Byte], off : Int32, v : Int32) -> Unit {
  buf[off] = v.to_byte()
  buf[off + 1] = (v >> 8).to_byte()
  buf[off + 2] = (v >> 16).to_byte()
  buf[off + 3] = (v >> 24).to_byte()
}

///|
/// `MKTAG(0xfd, 'a', 'r', '.')`: the audio header tag, whose first byte is
/// the length of the FourCC that follows it.
let realmedia_tag_ra : UInt32 = 0x2E7261FDU

///|
/// `ff_rm_codec_tags` (`rm.c`): codec FourCC and FFmpeg codec name.
let realmedia_codec_tags : Array[(Int32, String)] = [
  (realmedia_tag("RV10"), "rv10"),
  (realmedia_tag("RV20"), "rv20"),
  (realmedia_tag("RVTR"), "rv20"),
  (realmedia_tag("RV30"), "rv30"),
  (realmedia_tag("RV40"), "rv40"),
  (realmedia_tag("RV60"), "rv60"),
  (realmedia_tag("dnet"), "ac3"),
  (realmedia_tag("lpcJ"), "ra_144"),
  (realmedia_tag("28_8"), "ra_288"),
  (realmedia_tag("cook"), "cook"),
  (realmedia_tag("atrc"), "atrac3"),
  (realmedia_tag("sipr"), "sipr"),
  (realmedia_tag("raac"), "aac"),
  (realmedia_tag("racp"), "aac"),
  (realmedia_tag("LSD:"), "ralf"),
  (realmedia_tag("CLV1"), "clearvideo"),
]

///|
/// `ff_codec_get_id(ff_rm_codec_tags, tag)`: the codec name of a FourCC, ""
/// when unknown.
fn realmedia_codec_name(tag : Int32) -> String {
  for entry in realmedia_codec_tags {
    if entry.0 == tag {
      return entry.1
    }
  }
  ""
}

///|
let realmedia_deint_int0 : Int32 = realmedia_tag("Int0")

///|
let realmedia_deint_int4 : Int32 = realmedia_tag("Int4")

///|
let realmedia_deint_genr : Int32 = realmedia_tag("genr")

///|
let realmedia_deint_sipr : Int32 = realmedia_tag("sipr")

///|
let realmedia_deint_vbrf : Int32 = realmedia_tag("vbrf")

///|
let realmedia_deint_vbrs : Int32 = realmedia_tag("vbrs")

///|
/// `ff_sipr_subpk_size` (`rmsipr.c`), indexed by the SIPR flavor.
let realmedia_sipr_subpk_size : FixedArray[Int32] = [29, 19, 37, 20]

///|
/// `sipr_swaps` (`rmsipr.c`).
let realmedia_sipr_swaps : FixedArray[(Int32, Int32)] = [
  (0, 63),
  (1, 22),
  (2, 44),
  (3, 90),
  (5, 81),
  (7, 31),
  (8, 86),
  (9, 58),
  (10, 36),
  (12, 68),
  (13, 39),
  (14, 73),
  (15, 53),
  (16, 69),
  (17, 57),
  (19, 88),
  (20, 34),
  (21, 71),
  (24, 46),
  (25, 94),
  (26, 54),
  (28, 75),
  (29, 50),
  (32, 70),
  (33, 92),
  (35, 74),
  (38, 85),
  (40, 56),
  (42, 87),
  (43, 65),
  (45, 59),
  (48, 79),
  (49, 93),
  (51, 89),
  (55, 95),
  (61, 76),
  (67, 83),
  (77, 80),
]

///|
/// `ff_rm_reorder_sipr_data` (`rmsipr.c`): swap 4-bit nibble blocks of the
/// `sub_packet_h` sub-packets that make up one group.
fn realmedia_reorder_sipr(
  buf : Array[Byte],
  h : Int32,
  framesize : Int32,
) -> Unit {
  // nibbles per sub-packet
  let bs = h * framesize * 2 / 96
  for n = 0; n < realmedia_sipr_swaps.length(); n = n + 1 {
    let swap = realmedia_sipr_swaps[n]
    let mut i = bs * swap.0
    let mut o = bs * swap.1
    for _j = 0; _j < bs; _j = _j + 1 {
      let bi = i >> 1
      let bo = o >> 1
      let xi = i & 1
      let xo = o & 1
      let x = (buf[bi].to_int() >> (4 * xi)) & 0xF
      let y = (buf[bo].to_int() >> (4 * xo)) & 0xF
      let keep_o = buf[bo].to_int() & (0xF << (4 * (1 - xo)))
      let keep_i = buf[bi].to_int() & (0xF << (4 * (1 - xi)))
      buf[bo] = ((x << (4 * xo)) | keep_o).to_byte()
      buf[bi] = ((y << (4 * xi)) | keep_i).to_byte()
      i += 1
      o += 1
    }
  }
}

///|
/// `RAW_PACKET_SIZE`: the packet length of the old `.ra` format when the
/// header carries no frame size.
let realmedia_raw_packet_size : Int32 = 1000

// ---------------------------------------------------------------------------
// data model
// ---------------------------------------------------------------------------

///|
/// One media properties header (`MDPR`): a stream.
pub(all) struct RealMediaTrack {
  /// Stream number of the `MDPR`, matched against the packet headers (plus
  /// `index << 16` for the alternate streams of an `MLTI` group).
  stream_number : Int32
  media_type : MediaType
  /// FFmpeg codec name ("cook", "sipr", "ra_144", "ra_288", "ac3", "aac",
  /// "rv40", ...).
  codec : String
  /// The codec FourCC as stored (little-endian word; 0 for the version 3
  /// audio header, which has none).
  codec_tag : Int32
  bit_rate : Int64
  /// Audio only (0 on other streams).
  sample_rate : Int32
  channels : Int32
  /// Video only (0 on other streams).
  width : Int32
  height : Int32
  /// `block_align` after the codec-specific adjustments of
  /// `rm_read_audio_stream_info`: the size of one packet as emitted here.
  block_align : Int32
  /// Codec private bytes of the header.
  extradata : Bytes
  /// `MDPR` title and MIME type.
  title : String
  mime_type : String
  /// `MDPR` start time and duration in milliseconds.
  start_time : Int64
  duration : Int64
  /// Video frame rate as the reduced `fps field / 0x10000` (numerator and
  /// denominator, both 0 when the header has no frame rate).
  frame_rate_num : Int32
  frame_rate_den : Int32
  /// Interleaver FourCC (`Int0`, `Int4`, `genr`, `sipr`, `vbrf`, `vbrs`); 0
  /// on video streams.
  deint_id : Int32
  sub_packet_h : Int32
  sub_packet_size : Int32
  coded_framesize : Int32
  audio_framesize : Int32
}

///|
/// One packet as the demuxer hands it out, in file (interleave) order.
pub(all) struct RealMediaPacket {
  /// Index into `RealMediaDemux::tracks`.
  stream_index : Int32
  data : Bytes
  /// Presentation timestamp in milliseconds (see the module notes on the
  /// filled-in timestamps of de-interleaved audio).
  pts : Int64
  /// Every audio packet is a keyframe, as FFmpeg's intra-only rule says.
  keyframe : Bool
  /// Offset of the packet bytes in the file when the packet is one
  /// contiguous run of file bytes, else -1.
  pos : Int64
}

///|
/// One `INDX` entry.
pub(all) struct RealMediaIndexEntry {
  /// Index into `RealMediaDemux::tracks`.
  stream_index : Int32
  /// Milliseconds.
  timestamp : Int64
  /// File offset the entry points at.
  pos : Int64
}

///|
/// A parsed RealMedia file.
pub struct RealMediaDemux {
  tracks : Array[RealMediaTrack]
  packets : Array[RealMediaPacket]
  index : Array[RealMediaIndexEntry]
  /// `(key, value)` tags in file order: the `CONT` title, author, copyright
  /// and comment, the version 3 audio header's tags and the
  /// `logical-fileinfo` properties.
  metadata : Array[(String, String)]
  /// The `PROP` chunk's duration in milliseconds (`AV_NOPTS_VALUE` when a
  /// stream reports a duration of its own, as FFmpeg does).
  duration : Int64
  /// The number of packets the `PROP` chunk announces (0 when unknown).
  nb_packets : Int64
  /// The header is a bare `.ra` audio header (no `PROP` / `DATA` chunks).
  old_format : Bool
  /// Empty when the file was read to its end; otherwise the reason the
  /// packet walk stopped early (a truncated or damaged chunk). The packets
  /// read before the failure are kept, as FFmpeg's demuxer hands them out
  /// before reporting the error.
  read_error : String
}

///|
/// The kind of a stream while the header is being parsed.
priv enum RealMediaKind {
  RealMediaKindUnknown
  RealMediaKindAudio
  RealMediaKindVideo
}

///|
/// One stream: the track parameters plus the `RMStream` state the packet
/// walk needs.
priv struct RealMediaStream {
  mut kind : RealMediaKind
  stream_number : Int32
  mut codec : String
  mut codec_tag : Int32
  mut bit_rate : Int64
  mut sample_rate : Int32
  mut channels : Int32
  mut width : Int32
  mut height : Int32
  mut block_align : Int32
  mut extradata : Bytes
  mut title : String
  mut mime_type : String
  mut start_time : Int64
  mut duration : Int64
  mut frame_rate_num : Int32
  mut frame_rate_den : Int32
  mut deint_id : Int32
  mut sub_packet_h : Int32
  mut sub_packet_size : Int32
  mut coded_framesize : Int32
  mut audio_framesize : Int32
  /// `RMStream.pkt` of an interleaved audio stream: the
  /// `audio_framesize * sub_packet_h` de-interleaving buffer (empty for
  /// pass-through streams).
  mut audio_buf : Array[Byte]
  /// `RMStream.pkt` of a video stream: the frame assembly buffer, `None`
  /// once a completed frame was moved out.
  mut video_buf : Array[Byte]?
  mut videobufsize : Int32
  mut videobufpos : Int32
  mut curpic_num : Int32
  mut cur_slice : Int32
  mut slices : Int32
  mut pktpos : Int64
  mut audiotimestamp : Int64
  mut sub_packet_cnt : Int32
  sub_packet_lengths : FixedArray[Int32]
  /// Timestamp bookkeeping of FFmpeg's `compute_pkt_fields`: the running
  /// `cur_dts`, whether no packet with a real timestamp has been seen yet
  /// (the C keeps such packets relative to `RELATIVE_TS_BASE` and shifts
  /// them when the first real timestamp arrives) and which emitted packets
  /// are still relative.
  mut cur_dts : Int64
  mut ts_relative : Bool
  relative_packets : Array[Int32]
}

///|
priv struct RealMediaState {
  io : RealMediaIo
  mut streams : Array[RealMediaStream]
  packets : Array[RealMediaPacket]
  index : Array[RealMediaIndexEntry]
  metadata : Array[(String, String)]
  mut old_format : Bool
  mut remaining_len : Int32
  mut current_stream : Int32
  mut audio_stream_num : Int32
  mut audio_pkt_cnt : Int32
}

///|
/// The byte reader: an `AVIOContext` over the whole file. `eof` mirrors
/// `AVIOContext.eof_reached` - raised by a read past the end, cleared by a
/// seek - so the `avio_feof` loops behave as in the C.
priv struct RealMediaIo {
  data : Bytes
  mut pos : Int32
  mut eof : Bool
}

// ---------------------------------------------------------------------------
// byte reader
// ---------------------------------------------------------------------------

///|
fn RealMediaIo::new(data : Bytes) -> RealMediaIo {
  { data, pos: 0, eof: false, }
}

///|
/// `avio_r8`.
fn RealMediaIo::r8(self : RealMediaIo) -> Int32 {
  if self.pos < 0 || self.pos >= self.data.length() {
    self.eof = true
    0
  } else {
    let v = self.data[self.pos].to_int()
    self.pos += 1
    v
  }
}

///|
/// `avio_rb16`.
fn RealMediaIo::rb16(self : RealMediaIo) -> Int32 {
  let hi = self.r8()
  (hi << 8) | self.r8()
}

///|
/// `avio_rb32`, as the non-negative value the C assigns to an `int64_t`.
fn RealMediaIo::rb32(self : RealMediaIo) -> Int64 {
  let hi = self.rb16().to_int64()
  (hi << 16) | self.rb16().to_int64()
}

///|
/// `avio_rb64`.
fn RealMediaIo::rb64(self : RealMediaIo) -> Int64 {
  let hi = self.rb32()
  (hi << 32) | self.rb32()
}

///|
/// `avio_rl32`.
fn RealMediaIo::rl32(self : RealMediaIo) -> Int32 {
  let b0 = self.r8().reinterpret_as_uint()
  let b1 = self.r8().reinterpret_as_uint()
  let b2 = self.r8().reinterpret_as_uint()
  let b3 = self.r8().reinterpret_as_uint()
  let word = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
  word.reinterpret_as_int()
}

///|
/// `avio_rb32` as a big-endian FourCC word.
fn RealMediaIo::rb32_tag(self : RealMediaIo) -> UInt32 {
  let b0 = self.r8().reinterpret_as_uint()
  let b1 = self.r8().reinterpret_as_uint()
  let b2 = self.r8().reinterpret_as_uint()
  let b3 = self.r8().reinterpret_as_uint()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
/// `avio_skip`.
fn RealMediaIo::skip(self : RealMediaIo, n : Int64) -> Unit {
  self.pos = (self.pos.to_int64() + n).clamp(min=0L, max=2147483647L).to_int()
}

///|
/// `avio_seek(SEEK_SET)` on a seekable source.
fn RealMediaIo::seek(self : RealMediaIo, p : Int64) -> Unit {
  self.pos = p.clamp(min=0L, max=2147483647L).to_int()
  self.eof = false
}

///|
/// Bytes left in the file (`avio_size - avio_tell`), never negative.
fn RealMediaIo::remaining(self : RealMediaIo) -> Int64 {
  (self.data.length().to_int64() - self.pos.to_int64()).max(0L)
}

///|
/// `get_strl`: exactly `len` bytes are consumed whatever happens; the string
/// is the part before the first NUL, cut at 1023 bytes, decoded as UTF-8
/// like the rest of the port's `avio_get_str`.
fn RealMediaIo::str(self : RealMediaIo, len : Int64) -> String {
  let bytes : Array[Byte] = []
  for i = 0L; i < len; i = i + 1L {
    let b = self.r8()
    if b == 0 {
      self.skip(len - i - 1L)
      break
    }
    if i < 1023L {
      bytes.push(b.to_byte())
    }
  }
  utf8_to_string(bytes)
}

///|
/// `get_str8`: a one-byte length followed by the string.
fn RealMediaIo::str8(self : RealMediaIo) -> String {
  let len = self.r8()
  self.str(len.to_int64())
}

///|
/// `av_get_packet`: up to `n` bytes at the cursor; a short read raises
/// `eof`, as `avio_read` does. Returns the bytes and their offset.
fn RealMediaIo::take(self : RealMediaIo, n : Int64) -> (Bytes, Int32) {
  let start = self.pos
  let count = n.min(self.remaining())
  if count < n {
    self.eof = true
  }
  if count <= 0L {
    return (b"", start)
  }
  self.pos = start + count.to_int()
  (self.data[start:self.pos].to_owned(), start)
}

///|
/// `readfull`: `n` bytes into `dst` at `dst_off`; a short read is zero-filled
/// (the C logs "Failed to fully read block" and carries on).
fn RealMediaIo::read_full(
  self : RealMediaIo,
  dst : Array[Byte],
  dst_off : Int32,
  n : Int32,
) -> Unit {
  let count = n.min(self.remaining().to_int()).max(0)
  if count < n {
    self.eof = true
  }
  for i = 0; i < count; i = i + 1 {
    dst[dst_off + i] = self.data[self.pos + i]
  }
  for i = count; i < n; i = i + 1 {
    dst[dst_off + i] = b'\x00'
  }
  self.pos += count
}

///|
/// `ffio_read_size`: exactly `n` bytes, or an error naming the shortfall.
fn RealMediaIo::read_exact(
  self : RealMediaIo,
  n : Int64,
) -> Result[Bytes, String] {
  if n < 0L {
    return Err("realmedia: negative read size")
  }
  if n > self.remaining() {
    self.eof = true
    return Err("realmedia: failed to read \{n} bytes")
  }
  let start = self.pos
  self.pos = start + n.to_int()
  Ok(self.data[start:self.pos].to_owned())
}

///|
/// `rm_read_extradata` (`ff_get_extradata`).
fn RealMediaIo::extradata(
  self : RealMediaIo,
  size : Int64,
) -> Result[Bytes, String] {
  if size < 0L || size >= 16777216L {
    return Err("realmedia: extradata size too large")
  }
  match self.read_exact(size) {
    Ok(b) => Ok(b)
    Err(_) => Err("realmedia: truncated extradata")
  }
}

// ---------------------------------------------------------------------------
// probe
// ---------------------------------------------------------------------------

///|
/// `rm_probe` (`rmdec.c`): `.RMF` / `.RMP` followed by a two-byte version
/// of zero, or the `.ra` magic of the old format. Bytes outside the buffer
/// read as zero, as the C's probe padding does.
fn probe_realmedia(pd : ProbeData) -> Int32 {
  let b = pd.buf
  let rmf = pb_u8(b, 0) == 0x2EU &&
    pb_u8(b, 1) == 0x52U &&
    pb_u8(b, 2) == 0x4DU &&
    (pb_u8(b, 3) == 0x46U || pb_u8(b, 3) == 0x50U) &&
    pb_u8(b, 4) == 0U &&
    pb_u8(b, 5) == 0U
  let ra = pb_u8(b, 0) == 0x2EU &&
    pb_u8(b, 1) == 0x72U &&
    pb_u8(b, 2) == 0x61U &&
    pb_u8(b, 3) == 0xFDU
  if rmf || ra {
    probe_score_max
  } else {
    0
  }
}
