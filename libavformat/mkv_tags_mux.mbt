///|
/// Matroska `Tags` writer (FFmpeg 9.0.2 `matroskaenc.c` `mkv_write_tags`):
/// tag names are uppercased with spaces turned into underscores, and the
/// element is appended to an existing Segment for `mkv_add_tags`.

///|
/// `mkv_write_tag`'s key mangling: ASCII uppercase and `' '` -> `'_'` on the
/// UTF-8 bytes (non-ASCII bytes pass through).
fn mkv_tag_name(name : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for b in utf8_from_string(name) {
    let v = b.to_int()
    if v >= 0x61 && v <= 0x7A {
      out.push((v - 0x20).to_byte())
    } else if v == 0x20 {
      out.push(b'_')
    } else {
      out.push(b)
    }
  }
  out
}

///|
/// A `Tags` element with one `Tag` of container-level `SimpleTag`s (empty
/// `Targets`), matching what `mkv_write_tags` produces.
pub fn mkv_tags_element(tags : Array[(String, String)]) -> Array[Byte] {
  let tag_body : Array[Byte] = []
  webm_elem(tag_body, 0x63C0, 2, []) // empty Targets
  for pair in tags {
    let simple : Array[Byte] = []
    webm_elem(simple, 0x45A3, 2, mkv_tag_name(pair.0)) // TagName
    webm_elem(simple, 0x4487, 2, utf8_from_string(pair.1).to_array()) // TagString
    webm_elem(tag_body, 0x67C8, 2, simple) // SimpleTag
  }
  let tags_body : Array[Byte] = []
  webm_elem(tags_body, 0x7373, 2, tag_body) // Tag
  let out : Array[Byte] = []
  webm_elem(out, 0x1254C367, 4, tags_body)
  out
}

///|
/// EBML size VINT at `pos`: `(length, value)`; `(0, -1)` when malformed.
fn mkv_read_vint(data : Bytes, pos : Int32) -> (Int32, Int64) {
  if pos < 0 || pos >= data.length() {
    return (0, -1L)
  }
  let b = data[pos].to_int()
  let mut len = 1
  while len <= 8 && (b & (0x80 >> (len - 1))) == 0 {
    len = len + 1
  }
  if len > 8 || pos + len > data.length() {
    return (0, -1L)
  }
  let mut value = (b & (0xFF >> len)).to_int64()
  for i = 1; i < len; i = i + 1 {
    value = (value << 8) | data[pos + i].to_int().to_int64()
  }
  (len, value)
}

///|
/// Decode an EBML uint payload (big-endian, any width).
fn mkv_uint_value(body : Bytes) -> Int64 {
  let mut v = 0L
  for b in body {
    v = (v << 8) | b.to_int().to_int64()
  }
  v
}

///|
/// Encode an EBML uint with the given width (leading zero bytes allowed).
fn mkv_uint_bytes(value : Int64, width : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  for i = 0; i < width; i = i + 1 {
    out.push(((value >> (8 * (width - 1 - i))) & 0xFFL).to_int().to_byte())
  }
  out
}

///|
/// Full element bytes for `id` + `body` (minimal size VINT).
fn mkv_elem_bytes(id : UInt32, body : Array[Byte]) -> Array[Byte] {
  let mut len = 1
  if id >= 0x100U {
    len = 2
  }
  if id >= 0x10000U {
    len = 3
  }
  if id >= 0x1000000U {
    len = 4
  }
  let out : Array[Byte] = []
  webm_id(out, id, len)
  webm_size(out, body.length())
  out.append(body)
  out
}

///|
fn mkv_id_in(ids : Array[UInt32], id : UInt32) -> Bool {
  let mut hit = false
  for candidate in ids {
    if candidate == id {
      hit = true
    }
  }
  hit
}

///|
/// Rewrite every `targets` uint element inside the `containers` hierarchy:
/// values at or past `threshold` grow by `delta`. Value widths start at the
/// original width and widen only when needed; `growth[0]` accumulates the
/// element-size change so the caller can iterate to a stable `delta`.
fn mkv_rewrite_uints(
  data : Bytes,
  targets : Array[UInt32],
  containers : Array[UInt32],
  delta : Int64,
  threshold : Int64,
  growth : Array[Int64],
) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut pos = 0
  while pos + 2 <= data.length() {
    let (id_len, id) = mkv_read_id(data, pos)
    if id_len == 0 {
      return out
    }
    let (size_len, size) = mkv_read_vint(data, pos + id_len)
    if size_len == 0 || size < 0L {
      return out
    }
    let body_start = pos + id_len + size_len
    let body_end = body_start + size.to_int()
    if body_end > data.length() {
      return out
    }
    let old_len = id_len + size_len + size.to_int()
    let body = data[body_start:body_end].to_owned()
    if mkv_id_in(targets, id) {
      let value = mkv_uint_value(body)
      let shifted = if value >= threshold { value + delta } else { value }
      let mut width = if size.to_int() < 1 { 1 } else { size.to_int() }
      while width < 8 && shifted >= 1L << (8 * width) {
        width = width + 1
      }
      let bytes = mkv_uint_bytes(shifted, width)
      let elem = mkv_elem_bytes(id, bytes)
      growth[0] = growth[0] + elem.length().to_int64() - old_len.to_int64()
      for b in elem {
        out.push(b)
      }
    } else if mkv_id_in(containers, id) {
      let inner : Array[Int64] = [0L]
      let rewritten = mkv_rewrite_uints(
        body, targets, containers, delta, threshold, inner,
      )
      let elem = mkv_elem_bytes(id, rewritten)
      growth[0] = growth[0] + elem.length().to_int64() - old_len.to_int64()
      for b in elem {
        out.push(b)
      }
    } else {
      for i = pos; i < body_end; i = i + 1 {
        out.push(data[i])
      }
    }
    pos = body_end
  }
  out
}

///|
/// `SeekPosition` (0x53AC) inside `SeekHead` (0x114D9B74) / `SeekEntry`
/// (0x4DBB).
fn mkv_rewrite_seekhead(
  body : Bytes,
  delta : Int64,
  threshold : Int64,
  growth : Array[Int64],
) -> Array[Byte] {
  mkv_rewrite_uints(body, [0x53AC], [0x4DBB], delta, threshold, growth)
}

///|
/// `CueClusterPosition` (0xF1) inside `Cues` (0x1C53BB6B) / `CuePoint` (0xBB) /
/// `CueTrackPositions` (0xB7).
fn mkv_rewrite_cues(
  body : Bytes,
  delta : Int64,
  threshold : Int64,
  growth : Array[Int64],
) -> Array[Byte] {
  mkv_rewrite_uints(body, [0xF1], [0xBB, 0xB7], delta, threshold, growth)
}

///|
/// Append a `Tags` element carrying `tags` to a finished Matroska/WebM file.
/// The element is inserted before the first Cluster (where FFmpeg's demuxer
/// reads it), and all `SeekHead`/`Cues` positions that refer to the shifted
/// clusters are rewritten. Existing `Tags` elements are kept (Matroska tags
/// are additive), so appended strings win in readers that keep the last
/// value of a key.
pub fn mkv_add_tags(
  file : Bytes,
  tags : Array[(String, String)],
) -> Result[Bytes, String] {
  if tags.length() == 0 {
    return Ok(file)
  }
  if file.length() < 12 {
    return Err("EINVAL: truncated Matroska")
  }
  if !(file[0].to_int() == 0x1A &&
    file[1].to_int() == 0x45 &&
    file[2].to_int() == 0xDF &&
    file[3].to_int() == 0xA3) {
    return Err("EINVAL: not an EBML file")
  }
  let (header_len, header_size) = mkv_read_vint(file, 4)
  if header_len == 0 || header_size < 0L {
    return Err("EINVAL: invalid EBML header")
  }
  let segment_pos = 4 + header_len + header_size.to_int()
  let (seg_id_len, seg_id) = mkv_read_id(file, segment_pos)
  if seg_id_len != 4 || seg_id != 0x18538067U {
    return Err("EINVAL: missing Matroska Segment")
  }
  let size_pos = segment_pos + 4
  let (size_len, size) = mkv_read_vint(file, size_pos)
  if size_len == 0 || size < 0L || size == (1L << (7 * size_len)) - 1L {
    return Err("EINVAL: unknown Segment size")
  }
  let body_start = size_pos + size_len
  if body_start + size.to_int() != file.length() {
    return Err("EINVAL: Segment is not the last element")
  }
  let body = file[body_start:file.length()].to_owned()
  let elem = mkv_tags_element(tags)
  // Locate the first Cluster (the insertion point) and the index elements.
  let insert_pos : Array[Int64] = [body.length().to_int64()]
  let has_cluster : Array[Bool] = [false]
  let seekheads : Array[(Int32, Int32)] = []
  let cues : Array[(Int32, Int32)] = []
  let mut pos = 0
  while pos + 2 <= body.length() {
    let (id_len, id) = mkv_read_id(body, pos)
    if id_len == 0 {
      break
    }
    let (len_len, len) = mkv_read_vint(body, pos + id_len)
    if len_len == 0 || len < 0L {
      break
    }
    let b_start = pos + id_len + len_len
    let b_end = b_start + len.to_int()
    if b_end > body.length() {
      break
    }
    if id == 0x1F43B675U && !has_cluster[0] {
      has_cluster[0] = true
      insert_pos[0] = pos.to_int64()
    }
    if id == 0x114D9B74U {
      seekheads.push((b_start, b_end))
    }
    if id == 0x1C53BB6BU {
      cues.push((b_start, b_end))
    }
    pos = b_end
  }
  // Iterate the shift: rewriting index uints can widen them, which moves the
  // clusters again.
  let base = elem.length().to_int64()
  let mut delta = base
  let mut rounds = 0
  while rounds < 4 {
    let growth : Array[Int64] = [0L]
    for span in seekheads {
      let _ = mkv_rewrite_seekhead(
        body[span.0:span.1].to_owned(),
        delta,
        insert_pos[0],
        growth,
      )
    }
    for span in cues {
      if span.0.to_int64() < insert_pos[0] {
        let _ = mkv_rewrite_cues(
          body[span.0:span.1].to_owned(),
          delta,
          insert_pos[0],
          growth,
        )
      }
    }
    if delta == base + growth[0] {
      break
    }
    delta = base + growth[0]
    rounds = rounds + 1
  }
  // Assemble: children in order, index bodies rewritten, Tags before the
  // first Cluster.
  let out_body : Array[Byte] = []
  let inserted : Array[Bool] = [false]
  pos = 0
  while pos + 2 <= body.length() {
    let (id_len, id) = mkv_read_id(body, pos)
    if id_len == 0 {
      break
    }
    let (len_len, len) = mkv_read_vint(body, pos + id_len)
    if len_len == 0 || len < 0L {
      break
    }
    let b_start = pos + id_len + len_len
    let b_end = b_start + len.to_int()
    if b_end > body.length() {
      break
    }
    if id == 0x1F43B675U && !inserted[0] {
      for b in elem {
        out_body.push(b)
      }
      inserted[0] = true
    }
    if id == 0x114D9B74U {
      let growth : Array[Int64] = [0L]
      let inner = mkv_rewrite_seekhead(
        body[b_start:b_end].to_owned(),
        delta,
        insert_pos[0],
        growth,
      )
      for b in mkv_elem_bytes(id, inner) {
        out_body.push(b)
      }
    } else if id == 0x1C53BB6BU {
      let growth : Array[Int64] = [0L]
      let inner = mkv_rewrite_cues(
        body[b_start:b_end].to_owned(),
        delta,
        insert_pos[0],
        growth,
      )
      for b in mkv_elem_bytes(id, inner) {
        out_body.push(b)
      }
    } else {
      for i = pos; i < b_end; i = i + 1 {
        out_body.push(body[i])
      }
    }
    pos = b_end
  }
  if !inserted[0] {
    for b in elem {
      out_body.push(b)
    }
  }
  let out : Array[Byte] = []
  for i = 0; i < size_pos; i = i + 1 {
    out.push(file[i])
  }
  webm_size(out, out_body.length())
  out.append(out_body)
  Ok(Bytes::from_array(out))
}

///|
/// EBML element id at `pos`: `(length, id with the marker bits kept)`, or
/// `(0, 0)` when malformed.
fn mkv_read_id(data : Bytes, pos : Int32) -> (Int32, UInt32) {
  if pos < 0 || pos >= data.length() {
    return (0, 0U)
  }
  let b = data[pos].to_int()
  let mut len = 1
  while len <= 4 && (b & (0x80 >> (len - 1))) == 0 {
    len = len + 1
  }
  if len > 4 || pos + len > data.length() {
    return (0, 0U)
  }
  let mut value = b.reinterpret_as_uint()
  for i = 1; i < len; i = i + 1 {
    value = (value << 8) | data[pos + i].to_uint()
  }
  (len, value)
}

///|
/// Walk the EBML children of `data`, calling `f(id, body)` for each element.
fn mkv_walk_elements(data : Bytes, f : (UInt32, Bytes) -> Unit) -> Unit {
  let mut pos = 0
  while pos + 2 <= data.length() {
    let (id_len, id) = mkv_read_id(data, pos)
    if id_len == 0 {
      return
    }
    let (size_len, size) = mkv_read_vint(data, pos + id_len)
    if size_len == 0 || size < 0L {
      return
    }
    let body_start = pos + id_len + size_len
    let body_end = body_start + size.to_int()
    if body_end > data.length() {
      return
    }
    f(id, data[body_start:body_end].to_owned())
    pos = body_end
  }
}

///|
/// True when a `Targets` payload names a track/chapter/attachment UID.
fn mkv_targets_nonzero(targets : Bytes) -> Bool {
  let hit : Array[Bool] = [false]
  mkv_walk_elements(targets, (id, body) => {
    if id == 0x63C5 || id == 0x63C4 || id == 0x63C6 {
      for b in body {
        if b != b'\x00' {
          hit[0] = true
        }
      }
    }
  })
  hit[0]
}

///|
/// Collect one `Tags` payload's SimpleTags into `out` (container-level `Tag`
/// elements only, like `matroska_convert_tags`).
fn mkv_collect_tags(body : Bytes, out : Array[(String, String)]) -> Unit {
  mkv_walk_elements(body, (id, tag) => {
    if id != 0x7373 {
      return
    }
    let targeted : Array[Bool] = [false]
    mkv_walk_elements(tag, (cid, child) => {
      if cid == 0x63C0 && mkv_targets_nonzero(child) {
        targeted[0] = true
      }
    })
    if targeted[0] {
      return
    }
    mkv_walk_elements(tag, (cid, child) => {
      if cid != 0x67C8 {
        return
      }
      let name : Array[String] = [""]
      let value : Array[String] = [""]
      mkv_walk_elements(child, (sid, simple) => {
        if sid == 0x45A3 {
          name[0] = utf8_to_string(simple.to_array())
        } else if sid == 0x4487 {
          value[0] = utf8_to_string(simple.to_array())
        }
      })
      if name[0] != "" && value[0] != "" {
        out.push((matroska_metadata_key(name[0]), value[0]))
      }
    })
  })
}

///|
/// Byte-level `Tags` scan of a whole Matroska file: the streaming parse stops
/// at the first Cluster, so a `Tags` element placed after the Clusters (a
/// legal position that the muxers here do not produce) would otherwise be
/// missed. Replaces `mh.metadata` when at least one `Tags` element is found;
/// leaves the streaming result alone when the Segment cannot be walked
/// (unknown sizes).
pub fn matroska_scan_tags(file : Bytes, mh : MatroskaHeader) -> Unit {
  if file.length() < 12 {
    return
  }
  let (header_len, header_size) = mkv_read_vint(file, 4)
  if header_len == 0 || header_size < 0L {
    return
  }
  let segment_pos = 4 + header_len + header_size.to_int()
  let (seg_id_len, seg_id) = mkv_read_id(file, segment_pos)
  if seg_id_len != 4 || seg_id != 0x18538067U {
    return
  }
  let (size_len, size) = mkv_read_vint(file, segment_pos + 4)
  if size_len == 0 || size < 0L || size == (1L << (7 * size_len)) - 1L {
    return
  }
  let body_start = segment_pos + 4 + size_len
  if body_start + size.to_int() > file.length() {
    return
  }
  let body = file[body_start:body_start + size.to_int()].to_owned()
  let found : Array[(String, String)] = []
  let seen : Array[Bool] = [false]
  mkv_walk_elements(body, (id, el) => {
    if id == 0x1254C367 {
      seen[0] = true
      mkv_collect_tags(el, found)
    }
  })
  if seen[0] {
    mh.metadata.clear()
    for pair in found {
      mh.metadata.push(pair)
    }
  }
}
