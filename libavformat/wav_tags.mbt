///|
/// RIFF `LIST`/`INFO` metadata for WAV files: reader and a post-processing
/// writer, following FFmpeg 9.0.2 `riffdec.c` (`ff_read_riff_info`) and
/// `riffenc.c` (`ff_riff_write_info`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn wav_tags_le64(data : Bytes, pos : Int32) -> Int64 {
  let mut v = 0L
  for i = 0; i < 8; i = i + 1 {
    v = v | (data[pos + i].to_int().to_int64() << (8 * i))
  }
  v
}

///|
fn wav_tags_le32(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16) |
  (data[pos + 3].to_int() << 24)
}

///|
/// `ff_riff_info_conv` read direction: native 4CC -> generic metadata key.
fn wav_info_key(id : String) -> String {
  if id == "IART" {
    "artist"
  } else if id == "ICMT" {
    "comment"
  } else if id == "ICOP" {
    "copyright"
  } else if id == "ICRD" {
    "date"
  } else if id == "IGNR" {
    "genre"
  } else if id == "ILNG" {
    "language"
  } else if id == "INAM" {
    "title"
  } else if id == "IPRD" {
    "album"
  } else if id == "IPRT" || id == "ITRK" {
    "track"
  } else if id == "ISFT" {
    "encoder"
  } else if id == "ISMP" {
    "timecode"
  } else if id == "ITCH" {
    "encoded_by"
  } else {
    id
  }
}

///|
/// `ff_riff_info_conv` write direction: generic metadata key -> native 4CC,
/// or "" when the key has no INFO representation.
fn wav_info_tag(key : String) -> String {
  if key == "artist" {
    "IART"
  } else if key == "comment" {
    "ICMT"
  } else if key == "copyright" {
    "ICOP"
  } else if key == "date" {
    "ICRD"
  } else if key == "genre" {
    "IGNR"
  } else if key == "language" {
    "ILNG"
  } else if key == "title" {
    "INAM"
  } else if key == "album" {
    "IPRD"
  } else if key == "track" {
    "IPRT"
  } else if key == "encoder" {
    "ISFT"
  } else if key == "timecode" {
    "ISMP"
  } else if key == "encoded_by" {
    "ITCH"
  } else {
    ""
  }
}

///|
/// One RIFF chunk (id + payload, padding excluded).
priv struct WavTagsChunk {
  id : String
  body : Bytes
}

///|
fn wav_tags_fourcc(data : Bytes, pos : Int32) -> String {
  let chars : Array[Char] = []
  for i = 0; i < 4; i = i + 1 {
    chars.push(data[pos + i].to_char())
  }
  String::from_array(chars[:])
}

///|
/// Split a RIFF/RF64 file into its chunks; `None` for non-RIFF input.
fn wav_tags_chunks(file : Bytes) -> Array[WavTagsChunk]? {
  if file.length() < 12 {
    return None
  }
  let magic = wav_tags_fourcc(file, 0)
  if (magic != "RIFF" && magic != "RF64") || wav_tags_fourcc(file, 8) != "WAVE" {
    return None
  }
  // RF64 stores the 64-bit data size in ds64; the data chunk itself uses the
  // 0xFFFFFFFF sentinel.
  let mut rf_data_size = -1L
  if magic == "RF64" {
    let mut scan = 12
    while scan + 8 <= file.length() {
      let sid = wav_tags_fourcc(file, scan)
      let ssize = wav_tags_le32(file, scan + 4)
      if ssize < 0 || scan + 8 + ssize > file.length() {
        break
      }
      if sid == "ds64" && ssize >= 16 {
        rf_data_size = wav_tags_le64(file, scan + 16)
        break
      }
      scan = scan + 8 + ssize + (ssize & 1)
    }
  }
  let out : Array[WavTagsChunk] = []
  let mut pos = 12
  while pos + 8 <= file.length() {
    let id = wav_tags_fourcc(file, pos)
    let mut size = wav_tags_le32(file, pos + 4)
    if size == -1 && id == "data" && rf_data_size >= 0L {
      if rf_data_size > (file.length() - pos - 8).to_int64() {
        return None
      }
      size = rf_data_size.to_int()
    }
    if size < 0 || pos + 8 + size > file.length() {
      return None
    }
    out.push({ id, body: file[pos + 8:pos + 8 + size].to_owned(), })
    pos = pos + 8 + size + (size & 1)
  }
  Some(out)
}

///|
/// Read the `LIST`/`INFO` tags of a WAV file as (generic key, UTF-8 value)
/// pairs. Native ids outside `ff_riff_info_conv` keep their four-character id.
pub fn wav_read_tags(file : Bytes) -> Result[Array[(String, String)], String] {
  let chunks = match wav_tags_chunks(file) {
    Some(c) => c
    None => return Err("EINVAL: not a RIFF/WAVE file")
  }
  let out : Array[(String, String)] = []
  for chunk in chunks {
    if chunk.id != "LIST" ||
      chunk.body.length() < 4 ||
      wav_tags_fourcc(chunk.body, 0) != "INFO" {
      continue
    }
    let body = chunk.body
    let mut pos = 4
    while pos + 8 <= body.length() {
      let id = wav_tags_fourcc(body, pos)
      let size = wav_tags_le32(body, pos + 4)
      if size < 0 || pos + 8 + size > body.length() {
        break
      }
      // The value is NUL-terminated; the size includes the terminator.
      let raw = body[pos + 8:pos + 8 + size].to_owned()
      let mut end = raw.length()
      for i = 0; i < raw.length(); i = i + 1 {
        if raw[i] == b'\x00' {
          end = i
          break
        }
      }
      out.push(
        (wav_info_key(id), utf8_to_string(raw[0:end].to_owned().to_array())),
      )
      pos = pos + 8 + size + (size & 1)
    }
  }
  Ok(out)
}

///|
/// Body of a `LIST` chunk holding an `INFO` list from `tags`; keys without a
/// native id and empty values are skipped (`ff_riff_write_info`).
fn wav_info_list_body(tags : Array[(String, String)]) -> Array[Byte] {
  let out : Array[Byte] = []
  for b in b"INFO" {
    out.push(b)
  }
  for pair in tags {
    let tag = wav_info_tag(pair.0)
    let value = utf8_from_string(pair.1)
    if tag != "" && value.length() > 0 {
      for c in tag {
        out.push(c.to_int().to_byte())
      }
      let len = value.length() + 1
      out.push((len & 0xFF).to_byte())
      out.push(((len >> 8) & 0xFF).to_byte())
      out.push(((len >> 16) & 0xFF).to_byte())
      out.push(((len >> 24) & 0xFF).to_byte())
      for b in value {
        out.push(b)
      }
      out.push(b'\x00')
      if (len & 1) == 1 {
        out.push(b'\x00')
      }
    }
  }
  out
}

///|
/// Replace the `LIST`/`INFO` tags of a WAV file with `tags` (an empty list
/// drops the chunk). The new LIST goes right after `fmt `; audio data and all
/// other chunks are preserved. The RIFF (or RF64 `ds64`) size is rewritten.
pub fn wav_add_tags(
  file : Bytes,
  tags : Array[(String, String)],
) -> Result[Bytes, String] {
  let chunks = match wav_tags_chunks(file) {
    Some(c) => c
    None => return Err("EINVAL: not a RIFF/WAVE file")
  }
  let rf64 = wav_tags_fourcc(file, 0) == "RF64"
  let kept : Array[WavTagsChunk] = []
  for chunk in chunks {
    let is_info = chunk.id == "LIST" &&
      chunk.body.length() >= 4 &&
      wav_tags_fourcc(chunk.body, 0) == "INFO"
    if !is_info {
      kept.push(chunk)
    }
  }
  let list_body = wav_info_list_body(tags)
  let ordered : Array[WavTagsChunk] = []
  let mut inserted = false
  for chunk in kept {
    ordered.push(chunk)
    if !inserted && chunk.id == "fmt " {
      if list_body.length() > 4 {
        ordered.push({ id: "LIST", body: Bytes::from_array(list_body), })
      }
      inserted = true
    }
  }
  if !inserted && list_body.length() > 4 {
    let with_list : Array[WavTagsChunk] = [
      { id: "LIST", body: Bytes::from_array(list_body), },
    ]
    for chunk in ordered {
      with_list.push(chunk)
    }
    return Ok(wav_tags_assemble(file, with_list, rf64))
  }
  Ok(wav_tags_assemble(file, ordered, rf64))
}

///|
/// Serialize the RIFF header + chunks, patching the RIFF (or `ds64`) size.
fn wav_tags_assemble(
  file : Bytes,
  chunks : Array[WavTagsChunk],
  rf64 : Bool,
) -> Bytes {
  let body : Array[Byte] = []
  for chunk in chunks {
    for c in chunk.id {
      body.push(c.to_int().to_byte())
    }
    let size = chunk.body.length()
    let stored = if rf64 && chunk.id == "data" { 0xFFFFFFFF } else { size }
    body.push((stored & 0xFF).to_byte())
    body.push(((stored >> 8) & 0xFF).to_byte())
    body.push(((stored >> 16) & 0xFF).to_byte())
    body.push(((stored >> 24) & 0xFF).to_byte())
    for b in chunk.body {
      body.push(b)
    }
    if (size & 1) == 1 {
      body.push(b'\x00')
    }
  }
  let out : Array[Byte] = []
  for i = 0; i < 12; i = i + 1 {
    out.push(file[i])
  }
  // Patch the RIFF size (RF64 keeps the 0xFFFFFFFF sentinel and stores the
  // real size in ds64 instead).
  if !rf64 {
    let riff_size = body.length() + 4
    out[4] = (riff_size & 0xFF).to_byte()
    out[5] = ((riff_size >> 8) & 0xFF).to_byte()
    out[6] = ((riff_size >> 16) & 0xFF).to_byte()
    out[7] = ((riff_size >> 24) & 0xFF).to_byte()
  }
  for b in body {
    out.push(b)
  }
  if rf64 {
    // Patch the ds64 riffSize (first u64 of the ds64 body) if present.
    let scan = Bytes::from_array(out)
    let mut pos = 12
    while pos + 8 <= scan.length() {
      let id = wav_tags_fourcc(scan, pos)
      let size = wav_tags_le32(scan, pos + 4)
      if size < 0 || pos + 8 + size > scan.length() {
        break
      }
      if id == "ds64" && size >= 16 {
        let riff_size = (out.length() - 8).to_int64()
        for i = 0; i < 8; i = i + 1 {
          out[pos + 8 + i] = ((riff_size >> (8 * i)) & 0xFFL).to_int().to_byte()
        }
        break
      }
      pos = pos + 8 + size + (size & 1)
    }
  }
  Bytes::from_array(out)
}
