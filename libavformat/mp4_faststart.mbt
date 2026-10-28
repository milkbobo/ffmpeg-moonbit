///|
/// `-movflags +faststart` equivalent for the non-fragmented writers in this
/// package: rewrite `ftyp`+`mdat`+`moov` as `ftyp`+`moov`+`mdat`, shifting
/// every `stco`/`co64` chunk offset by the moved `moov` size.
///
/// Scope: files with exactly those three top-level boxes (all MP4 writers
/// here emit that layout). Fragmented files are rejected.

///|
fn mp4_fs_u32(buf : Array[Byte], off : Int32) -> UInt32 {
  (buf[off].to_uint() << 24) |
  (buf[off + 1].to_uint() << 16) |
  (buf[off + 2].to_uint() << 8) |
  buf[off + 3].to_uint()
}

///|
fn mp4_fs_put_u32(buf : Array[Byte], off : Int32, v : UInt32) -> Unit {
  buf[off] = ((v >> 24) & 0xFF).to_byte()
  buf[off + 1] = ((v >> 16) & 0xFF).to_byte()
  buf[off + 2] = ((v >> 8) & 0xFF).to_byte()
  buf[off + 3] = (v & 0xFF).to_byte()
}

///|
fn mp4_fs_tag(buf : Array[Byte], off : Int32) -> String {
  let out = StringBuilder()
  for i = 0; i < 4; i = i + 1 {
    out.write_char(buf[off + i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn mp4_fs_tag_bytes(buf : Bytes, off : Int32) -> String {
  let out = StringBuilder()
  for i = 0; i < 4; i = i + 1 {
    out.write_char(buf[off + i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn mp4_fs_is_parent(tag : String) -> Bool {
  tag == "moov" ||
  tag == "trak" ||
  tag == "mdia" ||
  tag == "minf" ||
  tag == "stbl" ||
  tag == "edts" ||
  tag == "dinf"
}

///|
/// Add `delta` to every chunk offset below `[start, end)`.
fn mp4_fs_patch_offsets(
  buf : Array[Byte],
  start : Int32,
  end : Int32,
  delta : Int64,
) -> Result[Unit, String] {
  let mut off = start
  while off + 8 <= end {
    let size = mp4_fs_u32(buf, off).reinterpret_as_int()
    if size < 8 || off + size > end {
      return Err("EINVAL: invalid MP4 box size")
    }
    let tag = mp4_fs_tag(buf, off + 4)
    if tag == "stco" {
      if size < 16 {
        return Err("EINVAL: invalid stco box")
      }
      let count = mp4_fs_u32(buf, off + 12).reinterpret_as_int()
      if 16 + 4 * count > size {
        return Err("EINVAL: invalid stco entry count")
      }
      for i = 0; i < count; i = i + 1 {
        let pos = off + 16 + 4 * i
        let old = mp4_fs_u32(buf, pos).to_int64()
        let new = old + delta
        if new > 0xFFFFFFFFL {
          return Err("EINVAL: faststart offset overflows stco")
        }
        mp4_fs_put_u32(buf, pos, new.to_int().reinterpret_as_uint())
      }
    } else if tag == "co64" {
      if size < 16 {
        return Err("EINVAL: invalid co64 box")
      }
      let count = mp4_fs_u32(buf, off + 12).reinterpret_as_int()
      if 16 + 8 * count > size {
        return Err("EINVAL: invalid co64 entry count")
      }
      for i = 0; i < count; i = i + 1 {
        let pos = off + 16 + 8 * i
        let old = (mp4_fs_u32(buf, pos).to_int64() << 32) |
          mp4_fs_u32(buf, pos + 4).to_int64()
        let new = old + delta
        let hi = (new >> 32).to_int().reinterpret_as_uint()
        let lo = (new & 0xFFFFFFFFL).to_int().reinterpret_as_uint()
        mp4_fs_put_u32(buf, pos, hi)
        mp4_fs_put_u32(buf, pos + 4, lo)
      }
    } else if mp4_fs_is_parent(tag) {
      match mp4_fs_patch_offsets(buf, off + 8, off + size, delta) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    off = off + size
  }
  Ok(())
}

///|
pub fn mp4_faststart(data : Bytes) -> Result[Bytes, String] {
  let len = data.length()
  let boxes : Array[(String, Int32, Int32)] = []
  let mut off = 0
  while off + 8 <= len {
    let size = ((data[off].to_uint() << 24) |
    (data[off + 1].to_uint() << 16) |
    (data[off + 2].to_uint() << 8) |
    data[off + 3].to_uint()).reinterpret_as_int()
    if size < 8 || off + size > len {
      return Err("EINVAL: invalid MP4 box size")
    }
    boxes.push((mp4_fs_tag_bytes(data, off + 4), off, size))
    off = off + size
  }
  if off != len ||
    boxes.length() != 3 ||
    boxes[0].0 != "ftyp" ||
    boxes[1].0 != "mdat" ||
    boxes[2].0 != "moov" {
    return Err("EINVAL: mp4_faststart expects ftyp+mdat+moov")
  }
  let moov_start = boxes[2].1
  let moov_size = boxes[2].2
  let moov : Array[Byte] = []
  for i = 0; i < moov_size; i = i + 1 {
    moov.push(data[moov_start + i])
  }
  match mp4_fs_patch_offsets(moov, 8, moov_size, moov_size.to_int64()) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let out : Array[Byte] = []
  for i = 0; i < boxes[0].2; i = i + 1 {
    out.push(data[i])
  }
  for b in moov {
    out.push(b)
  }
  for i = boxes[1].1; i < boxes[1].1 + boxes[1].2; i = i + 1 {
    out.push(data[i])
  }
  Ok(Bytes::from_array(out))
}
