///|
/// CAF (Core Audio Format) demuxer, ported from FFmpeg 9.0.2
/// `libavformat/cafdec.c`: `desc`/`kuki`/`pakt`/`data` chunks.
///
/// Scope: ALAC (old `frma`+`alac` cookie or the new 24-byte cookie) and
/// constant-packet LPCM. The pakt chunk provides ALAC packet sizes (MPEG-4
/// descriptor lengths) and the valid-frame count. AAC/Opus/FLAC cookies are
/// not handled yet.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct CafFormat {
  /// `alac` or a `pcm_*` name.
  codec : String
  channels : Int32
  sample_rate : Int32
  bits : Int32
  /// Constant packet size (`desc` bytesPerPacket), 0 for variable ALAC.
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
  /// ALAC magic cookie in the 36-byte atom form; empty for LPCM.
  extradata : Bytes
  data_offset : Int64
  data_size : Int64
  sample_count : Int64
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
/// `ff_mp4_read_descr_len` over a byte buffer: `(length, next position)`.
fn caf_descr_len(data : Bytes, off : Int32) -> (Int32, Int32) {
  let mut len = 0
  let mut pos = off
  for _ in 0..<4 {
    if pos >= data.length() {
      break
    }
    let c = data[pos].to_int()
    pos = pos + 1
    len = (len << 7) | (c & 0x7F)
    if (c & 0x80) == 0 {
      break
    }
  }
  (len, pos)
}

///|
/// Fabricate the 36-byte ALAC atom from either cookie style.
fn caf_alac_cookie(kuki : Bytes) -> Result[Bytes, String] {
  if kuki.length() >= 48 &&
    caf_tag(kuki, 4) == "frma" &&
    caf_tag(kuki, 8) == "alac" {
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
  let mut pos = 8
  while pos + 12 <= data.length() {
    let id = caf_tag(data, pos)
    let size = caf_i64be(data, pos + 4)
    let payload = pos + 12
    let avail = data.length() - payload
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
    pos = payload + size.to_int()
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
  if tag == "alac" {
    if kuki.length() == 0 {
      return Err("caf: missing ALAC magic cookie")
    }
    let cookie = match caf_alac_cookie(kuki) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let alac_rate = caf_u32be(cookie, 32).reinterpret_as_int()
    let alac_channels = cookie[21].to_int()
    let alac_bits = cookie[17].to_int()
    let max_samples = caf_u32be(cookie, 12).reinterpret_as_int()
    let frames = if frames_per_packet > 0 {
      frames_per_packet
    } else {
      max_samples
    }
    if frames <= 0 {
      return Err("caf: invalid ALAC frame size")
    }
    let (pakt_off, pakt_size) = match pakt {
      Some(v) => v
      None => return Err("caf: ALAC requires a pakt chunk")
    }
    if pakt_size < 24 {
      return Err("caf: pakt chunk too short")
    }
    let num_packets = caf_u64be(data, pakt_off).reinterpret_as_int64()
    let valid_frames = caf_u64be(data, pakt_off + 8).reinterpret_as_int64()
    if num_packets < 0 || num_packets > 16777216L || valid_frames < 0L {
      return Err("caf: invalid pakt fields")
    }
    let packets : Array[CafPacket] = []
    let mut ppos = pakt_off + 24
    let mut offset = data_off.to_int64()
    let mut pts = 0L
    for i = 0; i < num_packets.to_int(); i = i + 1 {
      let size = if bytes_per_packet > 0 {
        bytes_per_packet
      } else {
        let (len, next) = caf_descr_len(data, ppos)
        ppos = next
        len
      }
      let duration = if i + 1 == num_packets.to_int() {
        let left = valid_frames - pts
        if left > 0L {
          left
        } else {
          frames.to_int64()
        }
      } else {
        frames.to_int64()
      }
      if size <= 0 ||
        offset + size.to_int64() > data_off.to_int64() + actual_data_size {
        return Err("caf: invalid ALAC packet size")
      }
      packets.push({ pos: offset, size, pts, duration: duration.to_int(), })
      offset = offset + size.to_int64()
      pts = pts + duration
    }
    return Ok({
      format: {
        codec: "alac",
        channels: alac_channels,
        sample_rate: alac_rate,
        bits: alac_bits,
        block_align: bytes_per_packet,
        frames_per_packet: frames,
      },
      extradata: cookie,
      data_offset: data_off.to_int64(),
      data_size: actual_data_size,
      sample_count: valid_frames,
      packets,
    })
  }
  if tag == "lpcm" {
    let is_float = (flags & 1) != 0
    let little_endian = (flags & 2) != 0
    let bit_width = if bits > 0 { bits } else { 16 }
    let codec = if is_float {
      if bit_width != 32 {
        return Err("caf: unsupported float LPCM width")
      } else if little_endian {
        "pcm_f32le"
      } else {
        "pcm_f32be"
      }
    } else if bit_width == 8 {
      "pcm_s8"
    } else if bit_width == 16 || bit_width == 24 || bit_width == 32 {
      let suffix = if little_endian { "le" } else { "be" }
      "pcm_s\{bit_width}\{suffix}"
    } else {
      return Err("caf: unsupported LPCM width")
    }
    let block_align = if bytes_per_packet > 0 {
      bytes_per_packet
    } else if is_float {
      channels * 4
    } else {
      channels * (bit_width / 8)
    }
    if block_align <= 0 {
      return Err("caf: invalid LPCM packet size")
    }
    let frames_per = if frames_per_packet > 0 { frames_per_packet } else { 1 }
    let total_frames = actual_data_size /
      block_align.to_int64() *
      frames_per.to_int64()
    let max_size = 4096 / block_align * block_align
    let packet_size = if max_size > 0 { max_size } else { block_align }
    let packets : Array[CafPacket] = []
    let mut offset = data_off.to_int64()
    let mut left = actual_data_size
    let mut pts = 0L
    while left > 0L {
      let size = if left < packet_size.to_int64() {
        left.to_int()
      } else {
        packet_size
      }
      let duration = size / block_align * frames_per
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
      extradata: b"",
      data_offset: data_off.to_int64(),
      data_size: actual_data_size,
      sample_count: total_frames,
      packets,
    })
  }
  Err("caf: unsupported format \{tag}")
}
