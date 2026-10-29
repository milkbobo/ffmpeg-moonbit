///|
/// FLAC Vorbis comments (`VORBIS_COMMENT` metadata block, type 4): reader and
/// a post-processing writer, following FFmpeg 9.0.2 `flacenc.c` /
/// `vorbiscomment.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn flac_tags_be24(data : Bytes, pos : Int32) -> Int32 {
  (data[pos].to_int() << 16) |
  (data[pos + 1].to_int() << 8) |
  data[pos + 2].to_int()
}

///|
fn flac_tags_le32(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16) |
  (data[pos + 3].to_int() << 24)
}

///|
/// FFmpeg's `ff_vorbiscomment_metadata_conv` (native name -> generic key).
fn flac_vorbis_key(name : String) -> String {
  if name == "ALBUMARTIST" {
    "album_artist"
  } else if name == "TRACKNUMBER" {
    "track"
  } else if name == "DISCNUMBER" {
    "disc"
  } else if name == "DESCRIPTION" {
    "comment"
  } else {
    name
  }
}

///|
/// Read the `VORBIS_COMMENT` block of a FLAC file as (key, value) pairs.
/// Keys keep their on-disk case; `ff_vorbiscomment_metadata_conv` names are
/// mapped to FFmpeg's generic keys.
pub fn flac_read_tags(file : Bytes) -> Result[Array[(String, String)], String] {
  if file.length() < 8 || file[0:4] != b"fLaC" {
    return Err("EINVAL: not a FLAC file")
  }
  let out : Array[(String, String)] = []
  let mut pos = 4
  while pos + 4 <= file.length() {
    let hdr = file[pos].to_int()
    let last = (hdr & 0x80) != 0
    let kind = hdr & 0x7F
    let size = flac_tags_be24(file, pos + 1)
    let body_start = pos + 4
    let body_end = body_start + size
    if body_end > file.length() {
      return Err("EINVAL: truncated FLAC metadata block")
    }
    if kind == 4 {
      if size < 8 {
        return Err("EINVAL: truncated VORBIS_COMMENT block")
      }
      let vendor_len = flac_tags_le32(file, body_start)
      if vendor_len < 0 || body_start + 4 + vendor_len + 4 > body_end {
        return Err("EINVAL: invalid VORBIS_COMMENT block")
      }
      let mut p = body_start + 4 + vendor_len
      let count = flac_tags_le32(file, p)
      p = p + 4
      if count < 0 {
        return Err("EINVAL: invalid VORBIS_COMMENT count")
      }
      for _i = 0; _i < count; _i = _i + 1 {
        if p + 4 > body_end {
          return Err("EINVAL: truncated VORBIS_COMMENT entry")
        }
        let len = flac_tags_le32(file, p)
        p = p + 4
        if len < 0 || p + len > body_end {
          return Err("EINVAL: truncated VORBIS_COMMENT entry")
        }
        let entry = utf8_to_string(file[p:p + len].to_array())
        p = p + len
        // Split "KEY=value" at the first '='; entries without one are
        // dropped like FFmpeg's vorbis comment parser.
        let eq = flac_entry_split(entry)
        match eq {
          Some((key, value)) =>
            if key != "" {
              out.push((flac_vorbis_key(key), value))
            }
          None => ()
        }
      }
    }
    pos = body_end
    if last {
      break
    }
  }
  Ok(out)
}

///|
/// Split a Vorbis comment entry at its first '='.
fn flac_entry_split(entry : String) -> (String, String)? {
  let chars = entry.to_array()
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '=' {
      return Some(
        (String::from_array(chars[:i]), String::from_array(chars[i + 1:])),
      )
    }
  }
  None
}

///|
/// A metadata block: type and payload.
priv struct FlacMetaBlock {
  kind : Int32
  body : Bytes
}

///|
fn flac_tags_le32_bytes(out : Array[Byte], v : Int32) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 24) & 0xFF).to_byte())
}

///|
/// Body of a `VORBIS_COMMENT` block: vendor "moonbit", then `KEY=value`
/// entries with little-endian length prefixes.
fn flac_vorbis_comment_body(tags : Array[(String, String)]) -> Array[Byte] {
  let out : Array[Byte] = []
  let vendor = utf8_from_string("moonbit")
  flac_tags_le32_bytes(out, vendor.length())
  for b in vendor {
    out.push(b)
  }
  flac_tags_le32_bytes(out, tags.length())
  for pair in tags {
    let entry = utf8_from_string(pair.0 + "=" + pair.1)
    flac_tags_le32_bytes(out, entry.length())
    for b in entry {
      out.push(b)
    }
  }
  out
}

///|
/// Replace the `VORBIS_COMMENT` metadata block of a FLAC file with `tags`
/// (an empty list removes the block). Other metadata blocks and all frames are
/// preserved; the last-block flag is rewritten.
pub fn flac_add_tags(
  file : Bytes,
  tags : Array[(String, String)],
) -> Result[Bytes, String] {
  if file.length() < 8 || file[0:4] != b"fLaC" {
    return Err("EINVAL: not a FLAC file")
  }
  for pair in tags {
    if pair.0 == "" || pair.0.contains("=") || pair.0.contains("\u{0}") {
      return Err("EINVAL: invalid Vorbis comment key")
    }
  }
  let blocks : Array[FlacMetaBlock] = []
  let mut pos = 4
  let mut frames_start = file.length()
  while pos + 4 <= file.length() {
    let hdr = file[pos].to_int()
    let last = (hdr & 0x80) != 0
    let kind = hdr & 0x7F
    let size = flac_tags_be24(file, pos + 1)
    let body_start = pos + 4
    let body_end = body_start + size
    if body_end > file.length() {
      return Err("EINVAL: truncated FLAC metadata block")
    }
    if kind != 4 {
      blocks.push({ kind, body: file[body_start:body_end].to_owned(), })
    }
    pos = body_end
    if last {
      frames_start = pos
      break
    }
  }
  // A new comment block goes right after STREAMINFO.
  let inserted : Array[FlacMetaBlock] = []
  let mut done = false
  for block in blocks {
    inserted.push(block)
    if !done && block.kind == 0 {
      if tags.length() > 0 {
        inserted.push({
          kind: 4,
          body: Bytes::from_array(flac_vorbis_comment_body(tags)),
        })
      }
      done = true
    }
  }
  if !done && tags.length() > 0 {
    // Malformed (no STREAMINFO): still keep the comments at the front.
    let with_comment : Array[FlacMetaBlock] = [
      { kind: 4, body: Bytes::from_array(flac_vorbis_comment_body(tags)), },
    ]
    for block in inserted {
      with_comment.push(block)
    }
    return Ok(flac_tags_assemble(file, with_comment, frames_start))
  }
  Ok(flac_tags_assemble(file, inserted, frames_start))
}

///|
/// Serialize the `fLaC` marker + metadata blocks + frames.
fn flac_tags_assemble(
  file : Bytes,
  blocks : Array[FlacMetaBlock],
  frames_start : Int32,
) -> Bytes {
  let out : Array[Byte] = []
  for b in b"fLaC" {
    out.push(b)
  }
  for i = 0; i < blocks.length(); i = i + 1 {
    let block = blocks[i]
    let last = if i == blocks.length() - 1 { 0x80 } else { 0x00 }
    out.push((last | block.kind).to_byte())
    let size = block.body.length()
    out.push(((size >> 16) & 0xFF).to_byte())
    out.push(((size >> 8) & 0xFF).to_byte())
    out.push((size & 0xFF).to_byte())
    for b in block.body {
      out.push(b)
    }
  }
  for i = frames_start; i < file.length(); i = i + 1 {
    out.push(file[i])
  }
  Bytes::from_array(out)
}
