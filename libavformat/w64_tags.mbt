///|
/// Wave64 `summarylist` tags: UTF-16LE INFO entries keyed by RIFF fourcc
/// (FFmpeg `wavdec.c`'s summarylist branch, mapped through
/// `ff_riff_info_conv`). The writer appends the block to `W64Muxer` output.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// GUID of the Wave64 summary list (`ff_w64_guid_summarylist`).
fn w64_summary_guid() -> Bytes {
  w64_bytes([
    0xBC, 0x94, 0x5F, 0x92, 0x5A, 0x52, 0xD2, 0x11, 0x86, 0xDC, 0x00, 0xC0, 0x4F,
    0x8E, 0xDB, 0x8A,
  ])
}

///|
fn w64_tags_utf16le(value : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in value {
    let v = c.to_int()
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  // Terminating UTF-16 NUL.
  out.push(b'\x00')
  out.push(b'\x00')
  out
}

///|
fn w64_tags_decode_utf16le(data : Bytes) -> String {
  let chars : Array[Char] = []
  let mut i = 0
  while i + 1 < data.length() {
    let v = data[i].to_int() | (data[i + 1].to_int() << 8)
    if v == 0 {
      break
    }
    chars.push(v.unsafe_to_char())
    i = i + 2
  }
  String::from_array(chars[:])
}

///|
/// Read the `summarylist` tags of a Wave64 file as (generic key, UTF-8 value)
/// pairs.
pub fn w64_read_tags(file : Bytes) -> Result[Array[(String, String)], String] {
  let out : Array[(String, String)] = []
  if file.length() < 40 || file[0:16] != w64_guid_riff {
    return Err("EINVAL: missing Wave64 riff GUID")
  }
  let summary = w64_summary_guid()
  let mut pos = 40
  while pos + 24 <= file.length() {
    let guid = file[pos:pos + 16].to_owned()
    let size = wav_u64(file, pos + 16)
    if size <= 24L || pos.to_int64() + size > file.length().to_int64() {
      break
    }
    let body = pos + 24
    let payload = size.to_int() - 24
    if guid == summary {
      let end = body + payload
      if payload < 4 {
        return Err("EINVAL: truncated Wave64 summary list")
      }
      let count = wav_u32(file, body, false).to_int()
      let mut p = body + 4
      for _i = 0; _i < count; _i = _i + 1 {
        if p + 8 > end {
          break
        }
        let key = wav_fourcc(file, p)
        let len = wav_u32(file, p + 4, false).to_int()
        p = p + 8
        if len < 0 || p + len > end {
          return Err("EINVAL: truncated Wave64 summary entry")
        }
        let value = w64_tags_decode_utf16le(file[p:p + len].to_owned())
        p = p + len
        out.push((wav_info_key(key), value))
      }
    }
    let span = w64_align8(size)
    if span <= 0L {
      break
    }
    pos = pos + span.to_int()
  }
  Ok(out)
}

///|
/// Body of a `summarylist` block for `tags`: entry count, then fourcc,
/// UTF-16LE byte length (including the NUL) and the string.
fn w64_summary_payload(tags : Array[(String, String)]) -> Array[Byte] {
  let entries : Array[(String, Array[Byte])] = []
  for pair in tags {
    let key = wav_info_tag(pair.0)
    if key != "" && pair.1 != "" {
      entries.push((key, w64_tags_utf16le(pair.1)))
    }
  }
  let out : Array[Byte] = []
  let count = entries.length()
  out.push((count & 0xFF).to_byte())
  out.push(((count >> 8) & 0xFF).to_byte())
  out.push(((count >> 16) & 0xFF).to_byte())
  out.push(((count >> 24) & 0xFF).to_byte())
  for entry in entries {
    for c in entry.0 {
      out.push(c.to_int().to_byte())
    }
    let len = entry.1.length()
    out.push((len & 0xFF).to_byte())
    out.push(((len >> 8) & 0xFF).to_byte())
    out.push(((len >> 16) & 0xFF).to_byte())
    out.push(((len >> 24) & 0xFF).to_byte())
    for b in entry.1 {
      out.push(b)
    }
  }
  out
}
