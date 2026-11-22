///|
/// Monkey's Audio packet framing, ported from FFmpeg libavformat/ape.c
/// (LGPL-2.1-or-later).
priv struct ApeFileHeader {
  header_end : Int64
  seek_offset : Int64
  seek_bytes : Int64
  wav_header_bytes : Int64
  wav_tail_bytes : Int64
  blocks : Int64
  final_blocks : Int64
  count : Int64
  sample_rate : Int64
  channels : Int32
  bits : Int32
  compression : Int32
  flags : Int32
}

///|
priv struct ApePacketSpan {
  start : Int32
  size : Int32
  skip : Int32
  blocks : Int32
  pts : Int64
}

///|
/// Indexed Monkey's Audio file. Packets are assembled lazily from the
/// original bytes, including the eight-byte decoder prefix.
pub struct ApeDemux {
  data : Bytes
  priv spans : Array[ApePacketSpan]
  sample_rate : Int32
  channels : Int32
  bits : Int32
  extradata : Bytes
  total_samples : Int64
}

///|
fn ape_file_u16(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() | (data[pos + 1].to_int() << 8)
}

///|
fn probe_ape(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() < 6 || data[:4] != b"MAC "[:] {
    return 0
  }
  let version = ape_file_u16(data, 4)
  if version >= 3800 && version <= 3990 {
    100
  } else {
    25
  }
}

///|
fn ape_file_u32(data : Bytes, pos : Int32) -> Int64 {
  ape_file_u16(data, pos).to_int64() |
  (ape_file_u16(data, pos + 2).to_int64() << 16)
}

///|
fn ape_file_write_le(out : Array[Byte], value : Int32, size : Int32) -> Unit {
  for byte in 0..<size {
    out.push((value >> (byte * 8)).to_byte())
  }
}

///|
fn ape_file_header(
  data : Bytes,
  start : Int32,
  version : Int32,
) -> Result[ApeFileHeader, String] {
  let available = (data.length() - start).to_int64()
  if version >= 3980 {
    guard available >= 52L else { return Err("ape: truncated descriptor") }
    let descriptor = ape_file_u32(data, start + 8)
    let hsize = ape_file_u32(data, start + 12)
    guard descriptor >= 52L && hsize >= 24L && descriptor + hsize <= available else {
      return Err("ape: invalid descriptor or header length")
    }
    let header = start + descriptor.to_int()
    Ok({
      header_end: descriptor + hsize,
      seek_offset: descriptor + hsize,
      seek_bytes: ape_file_u32(data, start + 16),
      wav_header_bytes: ape_file_u32(data, start + 20),
      wav_tail_bytes: ape_file_u32(data, start + 32),
      blocks: ape_file_u32(data, header + 4),
      final_blocks: ape_file_u32(data, header + 8),
      count: ape_file_u32(data, header + 12),
      bits: ape_file_u16(data, header + 16),
      channels: ape_file_u16(data, header + 18),
      sample_rate: ape_file_u32(data, header + 20),
      compression: ape_file_u16(data, header),
      flags: ape_file_u16(data, header + 2),
    })
  } else {
    guard available >= 32L else { return Err("ape: truncated legacy header") }
    let compression = ape_file_u16(data, start + 6)
    let flags = ape_file_u16(data, start + 8)
    let count = ape_file_u32(data, start + 24)
    let mut header_end = 32L + (if (flags & 4) != 0 { 4L } else { 0L })
    let mut seek_bytes = count * 4L
    if (flags & 16) != 0 {
      guard header_end + 4L <= available else {
        return Err("ape: truncated seek table length")
      }
      seek_bytes = ape_file_u32(data, start + header_end.to_int()) * 4L
      header_end += 4L
    }
    let wave = ape_file_u32(data, start + 16)
    Ok({
      header_end,
      seek_offset: header_end + (if (flags & 32) == 0 { wave } else { 0L }),
      seek_bytes,
      wav_header_bytes: wave,
      wav_tail_bytes: ape_file_u32(data, start + 20),
      blocks: if version >= 3950 {
        294912L
      } else if version >= 3900 || compression >= 4000 {
        73728L
      } else {
        9216L
      },
      final_blocks: ape_file_u32(data, start + 28),
      count,
      bits: if (flags & 1) != 0 {
        8
      } else if (flags & 8) != 0 {
        24
      } else {
        16
      },
      channels: ape_file_u16(data, start + 10),
      sample_rate: ape_file_u32(data, start + 12),
      compression,
      flags,
    })
  }
}

///|
pub fn av_ape_open(data : Bytes) -> Result[ApeDemux, String] {
  let start = id3_skip(data)
  let available = (data.length() - start).to_int64()
  guard available >= 6L && data[start:start + 4] == b"MAC "[:] else {
    return Err("ape: missing signature")
  }
  let version = ape_file_u16(data, start + 4)
  guard version >= 3800 && version <= 3990 else {
    return Err("ape: unsupported version")
  }
  let header = match ape_file_header(data, start, version) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  guard header.count > 0L &&
    header.seek_bytes / 4L >= header.count &&
    header.blocks > 0L &&
    header.blocks <= 268435447L &&
    header.final_blocks > 0L &&
    header.final_blocks <= header.blocks &&
    header.sample_rate > 0L &&
    header.sample_rate <= 2147483647L &&
    (header.channels == 1 || header.channels == 2) else {
    return Err("ape: invalid frame or audio parameters")
  }
  let bit_table = header.seek_offset + header.seek_bytes
  let first = header.header_end +
    header.seek_bytes +
    header.wav_header_bytes +
    (if version < 3810 { header.count } else { 0L })
  let audio_end = available - header.wav_tail_bytes
  guard bit_table <= first && first < audio_end else {
    return Err("ape: truncated seek table or audio data")
  }
  let count = header.count.to_int()
  let seek = start + header.seek_offset.to_int()
  let bits = start + bit_table.to_int()
  let spans = []
  let mut pos = first
  for i in 0..<count {
    let last = i == count - 1
    let next = if last {
      audio_end
    } else {
      ape_file_u32(data, seek + (i + 1) * 4)
    }
    guard next > pos && next <= audio_end else {
      return Err("ape: invalid frame offset")
    }
    let align = ((pos - first) & 3L).to_int()
    let offset = pos - align.to_int64()
    let bytes = next - pos
    let mut size = if last { bytes & -4L } else { bytes }
    size = (size + align.to_int64() + 3L) & -4L
    let mut skip = align
    if version < 3810 {
      let bit = data[bits + i].to_int()
      guard bit < 8 else { return Err("ape: invalid seek bit offset") }
      skip = align * 8 + bit
      if !last && data[bits + i + 1] != b'\x00' {
        size += 4L
      }
    }
    size = size.min(available - offset)
    guard size > 0L && size <= 2147483639L else {
      return Err("ape: invalid packet size")
    }
    spans.push(ApePacketSpan::{
      start: start + offset.to_int(),
      size: size.to_int(),
      skip,
      blocks: (if last { header.final_blocks } else { header.blocks }).to_int(),
      pts: i.to_int64() * header.blocks,
    })
    pos = next
  }
  let extra : Array[Byte] = []
  ape_file_write_le(extra, version, 2)
  ape_file_write_le(extra, header.compression, 2)
  ape_file_write_le(extra, header.flags, 2)
  Ok({
    data,
    spans,
    sample_rate: header.sample_rate.to_int(),
    channels: header.channels,
    bits: header.bits,
    extradata: Bytes::from_array(extra),
    total_samples: (header.count - 1L) * header.blocks + header.final_blocks,
  })
}

///|
fn ApeDemux::packet(self : ApeDemux, index : Int32) -> (Bytes, Int64)? {
  guard self.spans.get(index) is Some(span) else { return None }
  let out = Array(capacity=span.size + 8)
  ape_file_write_le(out, span.blocks, 4)
  ape_file_write_le(out, span.skip, 4)
  for byte in self.data[span.start:span.start + span.size] {
    out.push(byte)
  }
  Some((Bytes::from_array(out), span.pts))
}
