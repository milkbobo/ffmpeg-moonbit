///|
/// iTunes metadata (`udta/meta/ilst`) writer: FFmpeg 9.0.2 `mov_write_udta_tag`
/// and `mov_write_ilst_tag`, exposed as a post-processing step for finished
/// MP4 files.

///|
/// `ilst` atom for an FFmpeg metadata key, or empty when the key has no
/// iTunes representation (`mov_write_ilst_tag`).
fn mp4_metadata_atom(key : String) -> String {
  if key == "title" {
    "\u{00A9}nam"
  } else if key == "artist" {
    "\u{00A9}ART"
  } else if key == "album_artist" {
    "aART"
  } else if key == "composer" {
    "\u{00A9}wrt"
  } else if key == "album" {
    "\u{00A9}alb"
  } else if key == "date" {
    "\u{00A9}day"
  } else if key == "encoding_tool" {
    "\u{00A9}too"
  } else if key == "comment" {
    "\u{00A9}cmt"
  } else if key == "genre" {
    "\u{00A9}gen"
  } else if key == "copyright" {
    "cprt"
  } else if key == "grouping" {
    "\u{00A9}grp"
  } else if key == "lyrics" {
    "\u{00A9}lyr"
  } else if key == "description" {
    "desc"
  } else if key == "synopsis" {
    "ldes"
  } else if key == "show" {
    "tvsh"
  } else if key == "episode_id" {
    "tven"
  } else if key == "network" {
    "tvnn"
  } else if key == "keywords" {
    "keyw"
  } else {
    ""
  }
}

///|
/// `data` box for a string tag: FullBox with data type 1 (UTF-8) and an
/// empty locale.
fn mp4_metadata_data(value : String) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, 1U)
  mp4_u32(body, 0U)
  for b in utf8_from_string(value) {
    body.push(b)
  }
  mp4_box("data", body)
}

///|
/// `chpl` box (Nero chapters): version 1, an unknown zero word, the count, and
/// per chapter an 8-byte start in 1/10,000,000 s units plus a length-prefixed
/// title (`mov_write_chpl_tag`).
fn mp4_chpl_box(chapters : Array[Mp4Chapter]) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, 0x01000000U) // version 1, flags 0
  mp4_u32(body, 0U) // unknown
  let count = if chapters.length() > 255 { 255 } else { chapters.length() }
  body.push(count.to_byte())
  for i = 0; i < count; i = i + 1 {
    let ch = chapters[i]
    for k = 0; k < 8; k = k + 1 {
      body.push(((ch.start_100ns >> (8 * (7 - k))) & 0xFFL).to_int().to_byte())
    }
    let title = utf8_from_string(ch.title)
    let len = if title.length() > 255 { 255 } else { title.length() }
    body.push(len.to_byte())
    for j = 0; j < len; j = j + 1 {
      body.push(title[j])
    }
  }
  mp4_box("chpl", body)
}

///|
/// `udta` box holding an iTunes `meta` (FullBox with an `mdir` handler around
/// `ilst`) and/or a `chpl` chapter box; tags without an iTunes atom are
/// skipped.
fn mp4_udta_box(
  tags : Array[(String, String)],
  chapters : Array[Mp4Chapter],
) -> Array[Byte] {
  let body : Array[Byte] = []
  if tags.length() > 0 {
    let ilst_body : Array[Byte] = []
    for pair in tags {
      let atom = mp4_metadata_atom(pair.0)
      if atom != "" {
        let item = mp4_box(atom, mp4_metadata_data(pair.1))
        for b in item {
          ilst_body.push(b)
        }
      }
    }
    let ilst = mp4_box("ilst", ilst_body)
    let hdlr_body : Array[Byte] = []
    mp4_u32(hdlr_body, 0U) // pre_defined
    mp4_tag(hdlr_body, "mdir")
    mp4_tag(hdlr_body, "appl")
    for _ in 0..<3 {
      mp4_u32(hdlr_body, 0U)
    }
    hdlr_body.push(b'\x00') // empty handler name
    let hdlr = mp4_full_box("hdlr", 0, 0, hdlr_body)
    let meta = mp4_full_box("meta", 0, 0, mp4_cat([hdlr, ilst]))
    for b in meta {
      body.push(b)
    }
  }
  if chapters.length() > 0 {
    for b in mp4_chpl_box(chapters) {
      body.push(b)
    }
  }
  mp4_box("udta", body)
}

///|
/// `udta` box carrying iTunes `tags` (no chapters).
pub fn mp4_metadata_udta(tags : Array[(String, String)]) -> Array[Byte] {
  mp4_udta_box(tags, [])
}

///|
/// Rewrite the file-level `udta` box of a finished MP4 with the given `tags`
/// and `chapters`; `None` keeps the values already in the file. The `moov`
/// box must not precede any `mdat` box (the muxers here write it last, and
/// `mp4_faststart` should run afterwards), so the existing chunk offsets stay
/// valid; boxes after `moov` simply shift.
fn mp4_rewrite_udta(
  file : Bytes,
  tags : Array[(String, String)]?,
  chapters : Array[Mp4Chapter]?,
) -> Result[Bytes, String] {
  if file.length() < 8 {
    return Err("EINVAL: truncated MP4")
  }
  let mut pos = 0
  let mut moov_start = -1
  let mut moov_size = 0
  let mut mdat_after_moov = false
  while pos + 8 <= file.length() {
    let size = mov_meta_u32(file, pos)
    if size < 8 || pos + size > file.length() {
      return Err("EINVAL: truncated MP4")
    }
    let kind = mov_meta_fourcc(file, pos + 4)
    if kind == "moov" {
      moov_start = pos
      moov_size = size
    } else if kind == "mdat" && moov_start >= 0 {
      mdat_after_moov = true
    }
    pos = pos + size
  }
  if moov_start < 0 {
    return Err("EINVAL: MP4 has no moov box")
  }
  if mdat_after_moov {
    return Err("EINVAL: moov precedes mdat; add metadata before faststart")
  }
  let out : Array[Byte] = []
  for i = 0; i < moov_start; i = i + 1 {
    out.push(file[i])
  }
  let body : Array[Byte] = []
  let moov_end = moov_start + moov_size
  let existing = new_movie()
  let mut p = moov_start + 8
  while p + 8 <= moov_end {
    let size = mov_meta_u32(file, p)
    if size < 8 || p + size > moov_end {
      return Err("EINVAL: truncated moov box")
    }
    if mov_meta_fourcc(file, p + 4) == "udta" {
      let udta : Array[Byte] = []
      for i = p + 8; i < p + size; i = i + 1 {
        udta.push(file[i])
      }
      mov_walk_metadata(Bytes::from_array(udta), existing, "")
    } else {
      for i = p; i < p + size; i = i + 1 {
        body.push(file[i])
      }
    }
    p = p + size
  }
  let final_tags = match tags {
    Some(t) => t
    None => existing.metadata
  }
  let final_chapters = match chapters {
    Some(c) => c
    None => existing.chapters
  }
  if final_tags.length() > 0 || final_chapters.length() > 0 {
    for b in mp4_udta_box(final_tags, final_chapters) {
      body.push(b)
    }
  }
  for b in mp4_box("moov", body) {
    out.push(b)
  }
  for i = moov_start + moov_size; i < file.length(); i = i + 1 {
    out.push(file[i])
  }
  Ok(Bytes::from_array(out))
}

///|
/// Replace the file-level iTunes tags of a finished MP4 file with `tags`
/// (existing tags are dropped, like FFmpeg's `-metadata` replacement);
/// chapters already present are preserved.
pub fn mp4_add_metadata(
  file : Bytes,
  tags : Array[(String, String)],
) -> Result[Bytes, String] {
  mp4_rewrite_udta(file, Some(tags), None)
}

///|
/// Replace the `chpl` chapters of a finished MP4 file with `chapters`;
/// existing tags are preserved. FFmpeg's reader prefers chapters from a
/// QuickTime chapter track when the file carries one, so the rewritten
/// `chpl` atom is authoritative for files written by the muxers here.
pub fn mp4_add_chapters(
  file : Bytes,
  chapters : Array[Mp4Chapter],
) -> Result[Bytes, String] {
  mp4_rewrite_udta(file, None, Some(chapters))
}
