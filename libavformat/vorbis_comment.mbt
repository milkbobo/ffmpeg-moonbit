///|
/// Vorbis comment payload (vendor string + `KEY=value` entries), shared by
/// FLAC metadata blocks, Ogg OpusTags and Ogg Vorbis/FLAC headers. Follows
/// FFmpeg 9.0.2 `vorbiscomment.c` / `flacenc.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn vorbis_comment_le32(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16) |
  (data[pos + 3].to_int() << 24)
}

///|
fn vorbis_comment_le32_bytes(out : Array[Byte], v : Int32) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 24) & 0xFF).to_byte())
}

///|
/// FFmpeg's `ff_vorbiscomment_metadata_conv` (native name -> generic key).
fn vorbis_comment_key(name : String) -> String {
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
/// Split a Vorbis comment entry at its first '='.
fn vorbis_comment_split(entry : String) -> (String, String)? {
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
/// Parse a Vorbis comment payload in `data[pos..end]`: vendor length + vendor,
/// entry count, then length-prefixed `KEY=value` strings. Returns the tags and
/// the position after the payload.
pub fn vorbis_comment_read(
  data : Bytes,
  pos : Int32,
  end : Int32,
) -> Result[(Array[(String, String)], Int32), String] {
  if pos < 0 || end > data.length() || end - pos < 8 {
    return Err("EINVAL: truncated Vorbis comment")
  }
  let vendor_len = vorbis_comment_le32(data, pos)
  if vendor_len < 0 || pos + 4 + vendor_len + 4 > end {
    return Err("EINVAL: invalid Vorbis comment")
  }
  let mut p = pos + 4 + vendor_len
  let count = vorbis_comment_le32(data, p)
  p = p + 4
  if count < 0 {
    return Err("EINVAL: invalid Vorbis comment count")
  }
  let out : Array[(String, String)] = []
  for _i = 0; _i < count; _i = _i + 1 {
    if p + 4 > end {
      return Err("EINVAL: truncated Vorbis comment entry")
    }
    let len = vorbis_comment_le32(data, p)
    p = p + 4
    if len < 0 || p + len > end {
      return Err("EINVAL: truncated Vorbis comment entry")
    }
    let entry = utf8_to_string(data[p:p + len].to_array())
    p = p + len
    // Entries without '=' are dropped like FFmpeg's comment parser.
    match vorbis_comment_split(entry) {
      Some((key, value)) =>
        if key != "" {
          out.push((vorbis_comment_key(key), value))
        }
      None => ()
    }
  }
  Ok((out, p))
}

///|
/// Serialize a Vorbis comment payload for `tags` with the given vendor.
pub fn vorbis_comment_body(
  vendor : String,
  tags : Array[(String, String)],
) -> Array[Byte] {
  let out : Array[Byte] = []
  let v = utf8_from_string(vendor)
  vorbis_comment_le32_bytes(out, v.length())
  for b in v {
    out.push(b)
  }
  vorbis_comment_le32_bytes(out, tags.length())
  for pair in tags {
    let entry = utf8_from_string(pair.0 + "=" + pair.1)
    vorbis_comment_le32_bytes(out, entry.length())
    for b in entry {
      out.push(b)
    }
  }
  out
}
