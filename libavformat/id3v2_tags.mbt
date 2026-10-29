///|
/// ID3v2 tag reader and writer for MP3/ADTS payloads, following FFmpeg
/// 9.0.2 `id3v2.c` / `id3v2enc.c`: text frames (`T***`), user-defined
/// `TXXX` and `COMM`, versions 2.3 and 2.4.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn id3v2_synchsafe(data : Bytes, pos : Int32) -> Int32 {
  ((data[pos].to_int() & 0x7F) << 21) |
  ((data[pos + 1].to_int() & 0x7F) << 14) |
  ((data[pos + 2].to_int() & 0x7F) << 7) |
  (data[pos + 3].to_int() & 0x7F)
}

///|
fn id3v2_be32(data : Bytes, pos : Int32) -> Int32 {
  (data[pos].to_int() << 24) |
  (data[pos + 1].to_int() << 16) |
  (data[pos + 2].to_int() << 8) |
  data[pos + 3].to_int()
}

///|
fn id3v2_syncsafe_bytes(out : Array[Byte], v : Int32) -> Unit {
  out.push(((v >> 21) & 0x7F).to_byte())
  out.push(((v >> 14) & 0x7F).to_byte())
  out.push(((v >> 7) & 0x7F).to_byte())
  out.push((v & 0x7F).to_byte())
}

///|
/// Undo ID3v2 unsynchronisation (`0xFF 0x00` becomes `0xFF`).
fn id3v2_deunsync(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  while i < data.length() {
    out.push(data[i])
    if data[i] == b'\xFF' && i + 1 < data.length() && data[i + 1] == b'\x00' {
      i = i + 1
    }
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
/// Decode an ID3v2 text payload (first byte selects the encoding).
fn id3v2_text(payload : Bytes) -> String {
  if payload.length() == 0 {
    return ""
  }
  let enc = payload[0].to_int()
  let body = payload[1:].to_owned()
  let chars : Array[Char] = []
  if enc == 0 {
    // ISO-8859-1: bytes are code points.
    for b in body {
      chars.push(b.to_char())
    }
  } else if enc == 3 {
    let text = utf8_to_string(body.to_array())
    return id3v2_trim_nul(text)
  } else {
    // UTF-16 with BOM (enc 1) or big-endian (enc 2).
    let mut start = 0
    let mut big = enc == 2
    if enc == 1 && body.length() >= 2 {
      if body[0] == b'\xFF' && body[1] == b'\xFE' {
        big = false
        start = 2
      } else if body[0] == b'\xFE' && body[1] == b'\xFF' {
        big = true
        start = 2
      }
    }
    let mut i = start
    while i + 1 < body.length() {
      let v = if big {
        (body[i].to_int() << 8) | body[i + 1].to_int()
      } else {
        body[i].to_int() | (body[i + 1].to_int() << 8)
      }
      if v != 0 {
        chars.push(v.unsafe_to_char())
      }
      i = i + 2
    }
  }
  id3v2_trim_nul(String::from_array(chars[:]))
}

///|
fn id3v2_trim_nul(text : String) -> String {
  let chars = text.to_array()
  let mut end = chars.length()
  while end > 0 && chars[end - 1] == '\u{0}' {
    end = end - 1
  }
  String::from_array(chars[:end])
}

///|
/// FFmpeg's `ff_id3v2_metadata_conv` native frame id -> generic key.
fn id3v2_key(id : String) -> String {
  if id == "TIT2" {
    "title"
  } else if id == "TPE1" {
    "artist"
  } else if id == "TPE2" {
    "album_artist"
  } else if id == "TALB" {
    "album"
  } else if id == "TDRC" || id == "TYER" || id == "TDOR" {
    "date"
  } else if id == "TCON" {
    "genre"
  } else if id == "TRCK" {
    "track"
  } else if id == "TCOM" {
    "composer"
  } else if id == "TENC" || id == "TSSE" {
    "encoder"
  } else if id == "TCOP" {
    "copyright"
  } else if id == "TPOS" {
    "disc"
  } else if id == "COMM" {
    "comment"
  } else {
    id
  }
}

///|
/// Read the ID3v2 tag at the start of `file`. Files without a tag return an
/// empty list; a malformed tag is an error.
pub fn id3v2_read_tags(file : Bytes) -> Result[Array[(String, String)], String] {
  let out : Array[(String, String)] = []
  if file.length() < 10 || file[0:3] != b"ID3" {
    return Ok(out)
  }
  let major = file[3].to_int()
  if major != 3 && major != 4 {
    return Err("EINVAL: unsupported ID3v2 version")
  }
  let flags = file[5].to_int()
  let size = id3v2_synchsafe(file, 6)
  let end = 10 + size
  if end > file.length() {
    return Err("EINVAL: truncated ID3v2 tag")
  }
  let mut body = file[10:end].to_owned()
  if (flags & 0x80) != 0 {
    body = id3v2_deunsync(body)
  }
  let mut pos = 0
  // Extended header: version 3 has a plain 32-bit size (excluding itself),
  // version 4 a synchsafe size that includes itself.
  if (flags & 0x40) != 0 {
    if body.length() < 4 {
      return Err("EINVAL: truncated ID3v2 extended header")
    }
    if major == 4 {
      pos = id3v2_synchsafe(body, 0)
    } else {
      pos = id3v2_be32(body, 0) + 4
    }
    if pos < 0 || pos > body.length() {
      return Err("EINVAL: invalid ID3v2 extended header")
    }
  }
  while pos + 10 <= body.length() {
    let id = String::from_array([
      body[pos].to_char(),
      body[pos + 1].to_char(),
      body[pos + 2].to_char(),
      body[pos + 3].to_char(),
    ])
    if id == "\u{0}\u{0}\u{0}\u{0}" {
      break
    }
    let frame_size = if major == 4 {
      id3v2_synchsafe(body, pos + 4)
    } else {
      id3v2_be32(body, pos + 4)
    }
    if frame_size < 0 || pos + 10 + frame_size > body.length() {
      return Err("EINVAL: truncated ID3v2 frame")
    }
    let payload = body[pos + 10:pos + 10 + frame_size].to_owned()
    pos = pos + 10 + frame_size
    if id == "TXXX" {
      // description \0 value, both in the payload's encoding.
      if payload.length() > 1 {
        let enc = payload[0]
        let rest = payload[1:].to_owned()
        let sep = if enc == b'\x01' || enc == b'\x02' {
          // UTF-16 NUL is two bytes.
          let mut found = -1
          let mut i = 0
          while i + 1 < rest.length() {
            if rest[i] == b'\x00' && rest[i + 1] == b'\x00' {
              found = i
              break
            }
            i = i + 2
          }
          found
        } else {
          let mut found = -1
          for i = 0; i < rest.length(); i = i + 1 {
            if rest[i] == b'\x00' {
              found = i
              break
            }
          }
          found
        }
        if sep >= 0 {
          let desc_bytes : Array[Byte] = [enc]
          for i = 0; i < sep; i = i + 1 {
            desc_bytes.push(rest[i])
          }
          let value_bytes : Array[Byte] = [enc]
          let step = if enc == b'\x01' || enc == b'\x02' { 2 } else { 1 }
          for i = sep + step; i < rest.length(); i = i + 1 {
            value_bytes.push(rest[i])
          }
          let desc = id3v2_text(Bytes::from_array(desc_bytes))
          let value = id3v2_text(Bytes::from_array(value_bytes))
          if desc != "" {
            out.push((desc, value))
          }
        }
      }
    } else if id == "COMM" {
      // encoding, 3-byte language, description \0 text
      if payload.length() > 4 {
        let enc = payload[0]
        let rest = payload[4:].to_owned()
        let step = if enc == b'\x01' || enc == b'\x02' { 2 } else { 1 }
        let mut sep = -1
        let mut i = 0
        while i + step <= rest.length() {
          if step == 2 {
            if i + 1 < rest.length() &&
              rest[i] == b'\x00' &&
              rest[i + 1] == b'\x00' {
              sep = i
              break
            }
          } else if rest[i] == b'\x00' {
            sep = i
            break
          }
          i = i + step
        }
        let start = if sep >= 0 { sep + step } else { 0 }
        let value_bytes : Array[Byte] = [enc]
        for i = start; i < rest.length(); i = i + 1 {
          value_bytes.push(rest[i])
        }
        out.push(("comment", id3v2_text(Bytes::from_array(value_bytes))))
      }
    } else if id.length() == 4 && id[0:1] == "T" && payload.length() > 0 {
      out.push((id3v2_key(id), id3v2_text(payload)))
    }
  }
  Ok(out)
}

///|
/// Native frame id for a generic metadata key, or "" to write a `TXXX`
/// frame instead.
fn id3v2_frame_id(key : String) -> String {
  if key == "title" {
    "TIT2"
  } else if key == "artist" {
    "TPE1"
  } else if key == "album_artist" {
    "TPE2"
  } else if key == "album" {
    "TALB"
  } else if key == "date" {
    "TDRC"
  } else if key == "genre" {
    "TCON"
  } else if key == "track" {
    "TRCK"
  } else if key == "composer" {
    "TCOM"
  } else if key == "encoder" {
    "TSSE"
  } else if key == "copyright" {
    "TCOP"
  } else if key == "disc" {
    "TPOS"
  } else {
    ""
  }
}

///|
/// Build an ID3v2.4 tag (UTF-8 text frames, `TXXX` for other keys); empty
/// input yields an empty byte string.
pub fn id3v2_write_tag(tags : Array[(String, String)]) -> Result[Bytes, String] {
  let frames : Array[Byte] = []
  for pair in tags {
    if pair.0 == "" {
      continue
    }
    let id = id3v2_frame_id(pair.0)
    let value = utf8_from_string(pair.1)
    if id != "" {
      let body : Array[Byte] = [b'\x03']
      for b in value {
        body.push(b)
      }
      body.push(b'\x00')
      id3v2_write_frame(frames, id, body)
    } else {
      // TXXX: encoding, description \0 value
      let desc = utf8_from_string(pair.0)
      let body : Array[Byte] = [b'\x03']
      for b in desc {
        body.push(b)
      }
      body.push(b'\x00')
      for b in value {
        body.push(b)
      }
      body.push(b'\x00')
      id3v2_write_frame(frames, "TXXX", body)
    }
  }
  if frames.length() == 0 {
    return Ok(b"")
  }
  let out : Array[Byte] = []
  out.push(b'I')
  out.push(b'D')
  out.push(b'3')
  out.push(b'\x04')
  out.push(b'\x00')
  out.push(b'\x00')
  id3v2_syncsafe_bytes(out, frames.length())
  for b in frames {
    out.push(b)
  }
  Ok(Bytes::from_array(out))
}

///|
/// One ID3v2.4 frame: id, synchsafe size, empty flags, payload.
fn id3v2_write_frame(
  out : Array[Byte],
  id : String,
  body : Array[Byte],
) -> Unit {
  for c in id {
    out.push(c.to_int().to_byte())
  }
  id3v2_syncsafe_bytes(out, body.length())
  out.push(b'\x00')
  out.push(b'\x00')
  for b in body {
    out.push(b)
  }
}

///|
/// Replace the leading ID3v2 tag of a payload (MP3/ADTS) with `tags`; an
/// empty list strips the tag. Trailing audio bytes are preserved.
pub fn id3v2_add_tags(
  file : Bytes,
  tags : Array[(String, String)],
) -> Result[Bytes, String] {
  let mut audio_start = 0
  if file.length() >= 10 && file[0:3] == b"ID3" {
    let flags = file[5].to_int()
    let size = id3v2_synchsafe(file, 6)
    audio_start = 10 + size
    if (flags & 0x10) != 0 {
      audio_start = audio_start + 10 // footer
    }
    if audio_start > file.length() {
      return Err("EINVAL: truncated ID3v2 tag")
    }
  }
  let tag = match id3v2_write_tag(tags) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let out : Array[Byte] = []
  for b in tag {
    out.push(b)
  }
  for i = audio_start; i < file.length(); i = i + 1 {
    out.push(file[i])
  }
  Ok(Bytes::from_array(out))
}
