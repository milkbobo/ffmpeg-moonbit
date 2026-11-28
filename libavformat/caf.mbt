///|
/// CAF (Core Audio Format) demuxer, ported from FFmpeg 9.0.2
/// `libavformat/cafdec.c`: `desc`/`kuki`/`pakt`/`data` chunks.
///
/// Supports ALAC, AAC-LC, FLAC, Opus, MPEG audio, AC-3, AMR-NB, LPCM,
/// G.711, MACE, GSM, and Apple IMA4. The pakt chunk conveys padding
/// and variable packet sizes and durations (MPEG-4 descriptor lengths).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct CafFormat {
  /// Audio codec name, such as `alac`, `mace3`, or `pcm_s16le`.
  codec : String
  channels : Int32
  sample_rate : Int32
  bits : Int32
  /// Constant packet size (`desc` bytesPerPacket), 0 when variable.
  block_align : Int32
  frames_per_packet : Int32
}

///|
pub struct CafPacket {
  pos : Int64
  size : Int32
  pts : Int64
  duration : Int32
}

///|
pub struct CafDemux {
  format : CafFormat
  /// Speaker mask when the chan chunk describes channels in WAVE order.
  channel_mask : UInt32
  /// Decoder configuration extracted or constructed from the CAF chunks.
  extradata : Bytes
  data_offset : Int64
  data_size : Int64
  sample_count : Int64
  /// Leading decoder samples outside the presentation.
  priming : Int32
  packets : Array[CafPacket]
}

///|
fn caf_tag(data : Bytes, off : Int32) -> String {
  let out = StringBuilder()
  for i = 0; i < 4; i = i + 1 {
    out.write_char(data[off + i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn caf_u16be(data : Bytes, off : Int32) -> Int32 {
  (data[off].to_int() << 8) | data[off + 1].to_int()
}

///|
fn caf_u32be(data : Bytes, off : Int32) -> UInt32 {
  (data[off].to_uint() << 24) |
  (data[off + 1].to_uint() << 16) |
  (data[off + 2].to_uint() << 8) |
  data[off + 3].to_uint()
}

///|
fn caf_u64be(data : Bytes, off : Int32) -> UInt64 {
  (caf_u32be(data, off).to_uint64() << 32) |
  caf_u32be(data, off + 4).to_uint64()
}

///|
fn caf_i64be(data : Bytes, off : Int32) -> Int64 {
  caf_u64be(data, off).reinterpret_as_int64()
}

///|
fn caf_read_channel_mask(data : Bytes, off : Int32) -> UInt32 {
  match caf_u32be(data, off) {
    0x10000U => {
      let bitmap = caf_u32be(data, off + 4)
      if bitmap <= 0x3ffffU {
        bitmap
      } else {
        0U
      }
    }
    0x00640001U => 0x4U
    0x00650002U | 0x00660002U => 0x3U
    0x006c0004U => 0x33U
    0x00710003U => 0x7U
    0x00730004U => 0x107U
    0x00750005U => 0x607U
    0x00790006U => 0x60fU
    0x00830003U => 0x103U
    0x00840004U => 0x603U
    _ => 0U
  }
}

///|
/// `ff_mp4_read_descr_len` over a byte buffer: `(length, next position)`.
fn caf_descr_len(data : Bytes, off : Int32, end : Int32) -> (Int32, Int32)? {
  let mut len = 0
  let mut pos = off
  for _ in 0..<4 {
    guard pos < end else { return None }
    let c = data[pos].to_int()
    pos = pos + 1
    len = (len << 7) | (c & 0x7F)
    if (c & 0x80) == 0 {
      return Some((len, pos))
    }
  }
  None
}

///|
/// Fabricate the 36-byte ALAC atom from either cookie style.
fn caf_alac_cookie(kuki : Bytes) -> Result[Bytes, String] {
  if kuki.length() >= 12 &&
    caf_tag(kuki, 4) == "frma" &&
    caf_tag(kuki, 8) == "alac" {
    if kuki.length() < 48 {
      return Err("caf: truncated ALAC magic cookie")
    }
    return Ok(kuki[12:48].to_owned())
  }
  if kuki.length() >= 24 {
    let out : Array[Byte] = []
    out.push(b'\x00')
    out.push(b'\x00')
    out.push(b'\x00')
    out.push(b'\x24')
    for b in b"alac" {
      out.push(b)
    }
    for b in b"\x00\x00\x00\x00" {
      out.push(b)
    }
    for i = 0; i < 24; i = i + 1 {
      out.push(kuki[i])
    }
    return Ok(Bytes::from_array(out))
  }
  Err("caf: invalid ALAC magic cookie")
}

///|
/// Parse a CAF file into a stream description and packets.
pub fn av_caf_open(data : Bytes) -> Result[CafDemux, String] {
  if data.length() < 8 ||
    data[0] != b'c' ||
    data[1] != b'a' ||
    data[2] != b'f' ||
    data[3] != b'f' {
    return Err("caf: missing caff header")
  }
  if caf_u16be(data, 4) != 1 {
    return Err("caf: unsupported version")
  }
  let mut desc : (Int32, Int32)? = None
  let mut kuki : Bytes = b""
  let mut pakt : (Int32, Int32)? = None
  let mut data_off = -1
  let mut data_size = 0L
  let mut channel_mask = 0U
  let mut pos = 8
  while pos <= data.length() - 12 {
    let id = caf_tag(data, pos)
    let size = caf_i64be(data, pos + 4)
    let payload = pos + 12
    let avail = data.length() - payload
    if (size < 0L && (id != "data" || size != -1L)) ||
      (size > avail.to_int64() && id != "data") {
      return Err("caf: invalid chunk size")
    }
    let actual = if size < 0 {
      avail.to_int64()
    } else if size > avail.to_int64() {
      avail.to_int64()
    } else {
      size
    }
    let end = payload + actual.to_int()
    if id == "desc" {
      desc = Some((payload, actual.to_int()))
    } else if id == "kuki" {
      kuki = data[payload:end].to_owned()
    } else if id == "pakt" {
      pakt = Some((payload, actual.to_int()))
    } else if id == "chan" && actual >= 12L {
      channel_mask = caf_read_channel_mask(data, payload)
    } else if id == "data" {
      if actual < 4L {
        return Err("caf: truncated data chunk")
      }
      data_off = payload + 4
      data_size = actual - 4L
    }
    if size < 0 {
      break
    }
    pos = end
  }
  let (desc_off, desc_size) = match desc {
    Some(v) => v
    None => return Err("caf: missing desc chunk")
  }
  if desc_size < 32 {
    return Err("caf: desc chunk too short")
  }
  let decl_rate = caf_u64be(data, desc_off).reinterpret_as_double().to_int()
  let tag = caf_tag(data, desc_off + 8)
  let flags = caf_u32be(data, desc_off + 12).reinterpret_as_int()
  let bytes_per_packet = caf_u32be(data, desc_off + 16).reinterpret_as_int()
  let frames_per_packet = caf_u32be(data, desc_off + 20).reinterpret_as_int()
  let channels = caf_u32be(data, desc_off + 24).reinterpret_as_int()
  let bits = caf_u32be(data, desc_off + 28).reinterpret_as_int()
  if channels < 1 ||
    channels > 32 ||
    frames_per_packet < 0 ||
    bytes_per_packet < 0 {
    return Err("caf: invalid desc fields")
  }
  if data_off < 0 {
    return Err("caf: missing data chunk")
  }
  let actual_data_size = if data_size > (data.length() - data_off).to_int64() {
    (data.length() - data_off).to_int64()
  } else {
    data_size
  }
  let direct_codec = match tag {
    ".mp1" => "mp1"
    ".mp2" => "mp2"
    ".mp3" | "ms\u0000U" => "mp3"
    "ac-3" => "ac3"
    "samr" => "amrnb"
    _ => ""
  }
  if tag == "alac" ||
    tag == "aac " ||
    tag == "aacl" ||
    tag == "flac" ||
    tag == "opus" ||
    direct_codec != "" {
    let mut aac_frame_length = 0
    let (codec, cookie, rate, channel_count, bit_width) = match tag {
      "alac" => {
        if kuki.is_empty() {
          return Err("caf: missing ALAC magic cookie")
        }
        let cookie = match caf_alac_cookie(kuki) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        (
          "alac",
          cookie,
          caf_u32be(cookie, 32).reinterpret_as_int(),
          cookie[21].to_int(),
          cookie[17].to_int(),
        )
      }
      "aac " | "aacl" => {
        guard caf_aac_cookie(kuki) is Some(asc) else {
          return Err("caf: invalid AAC magic cookie")
        }
        let parsed = match @libavcodec.aac_parse_audio_specific_config(asc) {
          Ok(v) => v
          Err(e) => return Err("caf: \{e}")
        }
        aac_frame_length = parsed.config.frame_length
        ("aac", asc, parsed.config.sample_rate, parsed.config.channels, bits)
      }
      "flac" => {
        guard caf_flac_cookie(kuki) is Some(info) else {
          return Err("caf: invalid FLAC magic cookie")
        }
        let packed = caf_u32be(info, 10)
        (
          "flac",
          info,
          (packed >> 12).reinterpret_as_int(),
          ((packed >> 9) & 7).reinterpret_as_int() + 1,
          ((packed >> 4) & 31).reinterpret_as_int() + 1,
        )
      }
      "opus" => {
        if channels > 2 || decl_rate <= 0 {
          return Err("caf: invalid mono/stereo Opus stream parameters")
        }
        ("opus", b"", 48000, channels, bits)
      }
      "samr" => {
        if channels != 1 || decl_rate != 8000 {
          return Err("caf: expected mono AMR-NB at 8000 Hz")
        }
        ("amrnb", b"", 8000, 1, bits)
      }
      _ => (direct_codec, b"", decl_rate, channels, bits)
    }
    let label = if codec == "alac" { "ALAC" } else { codec }
    if rate <= 0 || channel_count <= 0 {
      return Err("caf: invalid \{label} stream parameters")
    }
    let fixed = codec != "alac" && bytes_per_packet > 0 && frames_per_packet > 0
    let (declared, valid_frames, priming, remainder, table_start, table_end) = match
      pakt {
      Some((off, size)) => {
        if size < 24 {
          return Err("caf: pakt chunk too short")
        }
        (
          caf_i64be(data, off),
          caf_i64be(data, off + 8),
          caf_u32be(data, off + 16).reinterpret_as_int(),
          caf_u32be(data, off + 20).reinterpret_as_int(),
          off + 24,
          off + size,
        )
      }
      None if fixed => (0L, 0L, 0, 0, 0, 0)
      None => return Err("caf: \{label} requires a pakt chunk")
    }
    let num_packets = if fixed && declared == 0L {
      actual_data_size / bytes_per_packet.to_int64()
    } else {
      declared
    }
    if num_packets < 0L ||
      num_packets > 16777216L ||
      valid_frames < 0L ||
      priming < 0 ||
      (codec != "alac" && remainder < 0) {
      return Err("caf: invalid pakt fields")
    }
    if codec == "opus" && priming > 65535 {
      return Err("caf: invalid Opus priming")
    }
    let packets : Array[CafPacket] = []
    let mut ppos = table_start
    let mut offset = data_off.to_int64()
    let mut pts = -priming.to_int64()
    let mut ac3_mask = 0U
    let mpeg_audio = codec == "mp1" || codec == "mp2" || codec == "mp3"
    let flac_frames = if codec == "flac" {
      let end = (offset + actual_data_size).to_int()
      let track = match flac_open_frames(data, data_off, end, cookie) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      guard track.frames.length().to_int64() == num_packets else {
        return Err("caf: FLAC packet table does not cover the data chunk")
      }
      track.frames
    } else {
      []
    }
    for i = 0; i < num_packets.to_int(); i = i + 1 {
      let size = if bytes_per_packet > 0 {
        bytes_per_packet
      } else {
        guard caf_descr_len(data, ppos, table_end) is Some((len, next)) else {
          return Err("caf: truncated \{label} packet table")
        }
        ppos = next
        len
      }
      let frames = if frames_per_packet > 0 {
        frames_per_packet
      } else {
        guard caf_descr_len(data, ppos, table_end) is Some((len, next)) else {
          return Err("caf: truncated \{label} packet table")
        }
        ppos = next
        len
      }
      let duration = if i + 1 == num_packets.to_int() {
        if codec != "alac" {
          frames - remainder
        } else if valid_frames > pts && valid_frames < pts + frames.to_int64() {
          (valid_frames - pts).to_int()
        } else {
          frames
        }
      } else {
        frames
      }
      if size <= 0 ||
        duration <= 0 ||
        offset + size.to_int64() > data_off.to_int64() + actual_data_size {
        return Err("caf: invalid \{label} packet size")
      }
      if codec == "ac3" {
        let start = offset.to_int()
        let prefix = data[start:start + size.min(128)].to_owned()
        guard @libavcodec.ac3_parse_header(prefix) is Ok(header) &&
          header.bitstream_id <= 10 &&
          header.frame_size == size &&
          header.sample_rate == rate &&
          header.channels == channel_count &&
          frames == 1536 else {
          return Err("caf: AC-3 frame does not match its packet description")
        }
        let mask = ac3_channel_mask(header)
        guard ac3_mask == 0U || ac3_mask == mask else {
          return Err("caf: changing AC-3 channel layout")
        }
        ac3_mask = mask
      }
      if codec == "flac" {
        let frame = flac_frames[i]
        guard frame.pos == offset &&
          frame.size == size &&
          frame.duration == frames else {
          return Err("caf: FLAC frame does not match its packet description")
        }
      }
      if codec == "opus" {
        let start = offset.to_int()
        let packet = data[start:start + size].to_owned()
        guard @libavcodec.opus_parse_packet(packet) is Ok(parsed) &&
          parsed.total_samples() == frames else {
          return Err("caf: Opus packet duration does not match its description")
        }
      }
      if aac_frame_length > 0 && frames % aac_frame_length != 0 {
        return Err(
          "caf: AAC packet duration does not match AudioSpecificConfig",
        )
      }
      if mpeg_audio {
        guard caf_mpeg_header(data, offset.to_int(), size) is Some(info) &&
          info.codec == codec &&
          info.sample_rate == rate &&
          info.channels == channel_count &&
          info.samples_per_frame == frames else {
          return Err(
            "caf: MPEG audio frame does not match its packet description",
          )
        }
      }
      packets.push({ pos: offset, size, pts, duration, })
      offset = offset + size.to_int64()
      pts = pts + duration.to_int64()
    }
    if codec == "ac3" &&
      (packets.is_empty() || offset != data_off.to_int64() + actual_data_size) {
      return Err("caf: AC-3 packet table does not cover the data chunk")
    }
    if codec == "opus" &&
      (packets.is_empty() || offset != data_off.to_int64() + actual_data_size) {
      return Err("caf: Opus packet table does not cover the data chunk")
    }
    if codec == "aac" &&
      (packets.is_empty() || offset != data_off.to_int64() + actual_data_size) {
      return Err("caf: AAC packet table does not cover the data chunk")
    }
    if mpeg_audio &&
      (packets.is_empty() || offset != data_off.to_int64() + actual_data_size) {
      return Err("caf: MPEG audio packet table does not cover the data chunk")
    }
    let sample_count = if codec == "alac" { valid_frames } else { pts }
    if sample_count < 0L {
      return Err("caf: packet table has negative duration")
    }
    return Ok({
      format: {
        codec,
        channels: channel_count,
        sample_rate: rate,
        bits: bit_width,
        block_align: bytes_per_packet,
        frames_per_packet,
      },
      channel_mask: if channel_mask.popcnt() == channel_count {
        channel_mask
      } else if codec == "flac" {
        flac_default_channel_mask(channel_count)
      } else {
        ac3_mask
      },
      extradata: if codec == "opus" {
        caf_opus_head(channel_count, decl_rate, priming)
      } else {
        cookie
      },
      data_offset: data_off.to_int64(),
      data_size: actual_data_size,
      sample_count,
      priming,
      packets,
    })
  }
  let wav_adpcm = tag == "ms\u0000\u0011" || tag == "ms\u0000\u0002"
  let compressed = match tag {
    "MAC3" => Some(("mace3", 2 * channels, 6, 2))
    "MAC6" => Some(("mace6", channels, 6, 2))
    "ima4" => Some(("adpcm_ima_qt", 34 * channels, 64, 8))
    "agsm" => Some(("gsm", 33, 160, 1))
    "ms\u00001" => Some(("gsm_ms", 65, 320, 1))
    "ms\u0000\u0011" => {
      let headers = 4 * channels
      guard (bits == 0 || bits == 4) &&
        channels <= 8 &&
        bytes_per_packet >= headers &&
        bytes_per_packet % headers == 0 &&
        bytes_per_packet <= 0x3fffffff else {
        return Err("caf: invalid WAV IMA ADPCM block")
      }
      Some(
        (
          "adpcm_ima_wav",
          bytes_per_packet,
          (bytes_per_packet / channels - 4) * 2 + 1,
          8,
        ),
      )
    }
    "ms\u0000\u0002" => {
      let headers = 7 * channels
      guard (bits == 0 || bits == 4) &&
        channels <= 6 &&
        bytes_per_packet >= headers &&
        bytes_per_packet <= 0x3fffffff else {
        return Err("caf: invalid Microsoft ADPCM block")
      }
      Some(
        (
          "adpcm_ms",
          bytes_per_packet,
          (bytes_per_packet - headers) * 2 / channels + 2,
          6,
        ),
      )
    }
    _ => None
  }
  let g711 = tag == "alaw" || tag == "ulaw"
  if tag == "lpcm" || compressed is Some(_) || g711 {
    if decl_rate <= 0 {
      let format = match tag {
        "MAC3" | "MAC6" => "MACE"
        "alaw" | "ulaw" => "G.711"
        "lpcm" => "LPCM"
        _ => tag
      }
      return Err("caf: invalid \{format} sample rate")
    }
    let (codec, bit_width, frames_per, block_align) = if compressed
      is Some((codec, size, frames, max_channels)) {
      if channels > max_channels ||
        bytes_per_packet != size ||
        frames_per_packet != frames {
        let format = if tag == "MAC3" || tag == "MAC6" { "MACE" } else { codec }
        return Err("caf: invalid \{format} packet layout")
      }
      (codec, if wav_adpcm { 4 } else { bits }, frames, size)
    } else if g711 {
      if frames_per_packet <= 0 ||
        bytes_per_packet.to_int64() !=
        channels.to_int64() * frames_per_packet.to_int64() {
        return Err("caf: invalid G.711 packet layout")
      }
      (mov_codec_name(tag, ""), 8, frames_per_packet, bytes_per_packet)
    } else {
      let is_float = (flags & 1) != 0
      let little_endian = (flags & 2) != 0
      let bit_width = if bits > 0 { bits } else { 16 }
      let codec = if is_float {
        if bit_width != 32 && bit_width != 64 {
          return Err("caf: unsupported float LPCM width")
        }
        let suffix = if little_endian { "le" } else { "be" }
        "pcm_f\{bit_width}\{suffix}"
      } else if bit_width == 8 {
        "pcm_s8"
      } else if bit_width == 16 || bit_width == 24 || bit_width == 32 {
        let suffix = if little_endian { "le" } else { "be" }
        "pcm_s\{bit_width}\{suffix}"
      } else {
        return Err("caf: unsupported LPCM width")
      }
      let frames_per = if frames_per_packet > 0 { frames_per_packet } else { 1 }
      let packed_size = channels.to_int64() *
        (bit_width / 8).to_int64() *
        frames_per.to_int64()
      if packed_size > 0x7fffffffL ||
        (bytes_per_packet > 0 && bytes_per_packet.to_int64() != packed_size) {
        return Err("caf: invalid LPCM packet size")
      }
      (codec, bit_width, frames_per, packed_size.to_int())
    }
    let available_blocks = actual_data_size / block_align.to_int64()
    let gsm = tag == "agsm" || tag == "ms\u00001"
    if wav_adpcm && actual_data_size % block_align.to_int64() != 0L {
      return Err("caf: incomplete WAV ADPCM block")
    }
    if gsm && actual_data_size % block_align.to_int64() != 0L {
      return Err("caf: incomplete GSM block")
    }
    let (blocks, priming, remainder) = if compressed is Some(_) &&
      pakt is Some((table, size)) {
      if size < 24 {
        return Err("caf: packet table too short")
      }
      let declared = caf_i64be(data, table)
      let priming = caf_u32be(data, table + 16).reinterpret_as_int()
      let remainder = caf_u32be(data, table + 20).reinterpret_as_int()
      let blocks = if declared == 0L { available_blocks } else { declared }
      if blocks < 0L ||
        blocks > available_blocks ||
        priming < 0 ||
        remainder < 0 ||
        remainder >= frames_per ||
        priming.to_int64() + remainder.to_int64() >
        blocks * frames_per.to_int64() {
        return Err("caf: invalid fixed packet table")
      }
      (blocks, priming, remainder)
    } else {
      (available_blocks, 0, 0)
    }
    let total_frames = blocks * frames_per.to_int64() -
      priming.to_int64() -
      remainder.to_int64()
    let packet_data_size = if compressed is Some(_) || g711 {
      blocks * block_align.to_int64()
    } else {
      actual_data_size
    }
    let max_size = 4096 / block_align * block_align
    let packet_size = if compressed is Some(_) || max_size == 0 {
      block_align
    } else {
      max_size
    }
    let packets : Array[CafPacket] = []
    let mut offset = data_off.to_int64()
    let mut left = packet_data_size
    let mut pts = -priming.to_int64()
    while left > 0L {
      let size = if left < packet_size.to_int64() {
        left.to_int()
      } else {
        packet_size
      }
      let duration = size / block_align * frames_per -
        (if left == size.to_int64() { remainder } else { 0 })
      if tag == "agsm" && (data[offset.to_int()].to_int() & 0xf0) != 0xd0 {
        return Err("caf: missing GSM frame magic")
      }
      packets.push({ pos: offset, size, pts, duration, })
      offset = offset + size.to_int64()
      pts = pts + duration.to_int64()
      left = left - size.to_int64()
    }
    return Ok({
      format: {
        codec,
        channels,
        sample_rate: decl_rate,
        bits: bit_width,
        block_align,
        frames_per_packet: frames_per,
      },
      channel_mask: if channel_mask.popcnt() == channels {
        channel_mask
      } else {
        0U
      },
      extradata: b"",
      data_offset: data_off.to_int64(),
      data_size: packet_data_size,
      sample_count: total_frames,
      priming,
      packets,
    })
  }
  Err("caf: unsupported format \{tag}")
}
