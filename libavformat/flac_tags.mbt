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
      match vorbis_comment_read(file, body_start, body_end) {
        Ok((tags, _)) =>
          for pair in tags {
            out.push(pair)
          }
        Err(e) => return Err(e)
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
/// A metadata block: type and payload.
priv struct FlacMetaBlock {
  kind : Int32
  body : Bytes
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
          body: Bytes::from_array(vorbis_comment_body("moonbit", tags)),
        })
      }
      done = true
    }
  }
  if !done && tags.length() > 0 {
    // Malformed (no STREAMINFO): still keep the comments at the front.
    let with_comment : Array[FlacMetaBlock] = [
      {
        kind: 4,
        body: Bytes::from_array(vorbis_comment_body("moonbit", tags)),
      },
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
