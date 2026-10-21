///|
/// MoonBit port of the Matroska Cues index and cue-based seeking from
/// FFmpeg 9.0.2 `libavformat/matroskadec.c` (`matroska_parse_cues`,
/// `matroska_cuepoint`, `matroska_seek`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The parser is standalone over an in-memory file: it locates the Segment and
/// walks level-1 elements until Cues, avoiding the deferred-cue machinery of the
/// main demuxer. Cue times are raw `TimecodeScale` units (milliseconds with the
/// default 1,000,000 ns scale); `cluster_position` is relative to the Segment
/// data start, as stored in Matroska.
///
/// Out of scope: CueDuration/CueDisplay, CueCodecState, multiple tracks per
/// cue (all positions are retained), and the demuxer's lazy cluster parsing.

///|
pub struct MkvCue {
  /// CueTime in `TimecodeScale` units.
  time : Int64
  track : Int64
  /// CueClusterPosition relative to the Segment data start.
  cluster_position : Int64
  /// CueRelativePosition inside the cluster (0 when absent).
  relative_position : Int64
  /// CueBlockNumber (1 when absent, per the C default).
  block_number : Int64
}

///|
pub struct MkvCues {
  /// Absolute file offset of the Segment payload.
  segment_data_start : Int64
  cues : Array[MkvCue]
}

///|
fn cue_id(data : BytesView, pos : Int32) -> Result[(Int64, Int32), String] {
  if pos >= data.length() {
    return Err("mkv: EOF in EBML id")
  }
  let first = data[pos].to_int()
  if first == 0 {
    return Err("mkv: invalid EBML id")
  }
  let mut len = 1
  let mut mask = 0x80
  while (first & mask) == 0 {
    len = len + 1
    mask = mask >> 1
    if len > 4 {
      return Err("mkv: EBML id too long")
    }
  }
  if pos + len > data.length() {
    return Err("mkv: truncated EBML id")
  }
  let mut v = 0L
  for i in 0..<len {
    v = (v << 8) | data[pos + i].to_int().to_int64()
  }
  Ok((v, len))
}

///|
/// Read an EBML size VINT. Returns `(-1, len)` for the all-ones unknown size.
fn cue_size(data : BytesView, pos : Int32) -> Result[(Int64, Int32), String] {
  if pos >= data.length() {
    return Err("mkv: EOF in EBML size")
  }
  let first = data[pos].to_int()
  if first == 0 {
    return Err("mkv: invalid EBML size")
  }
  let mut len = 1
  let mut mask = 0x80
  while (first & mask) == 0 {
    len = len + 1
    mask = mask >> 1
    if len > 8 {
      return Err("mkv: EBML size too long")
    }
  }
  if pos + len > data.length() {
    return Err("mkv: truncated EBML size")
  }
  let mut v = (first & (mask - 1)).to_int64()
  let mut all_ones = v == (mask - 1).to_int64()
  for i in 1..<len {
    let b = data[pos + i].to_int()
    v = (v << 8) | b.to_int64()
    if b != 0xFF {
      all_ones = false
    }
  }
  if all_ones {
    Ok((-1L, len))
  } else {
    Ok((v, len))
  }
}

///|
fn cue_uint(data : BytesView, start : Int32, size : Int32) -> Int64 {
  let mut v = 0L
  for i in 0..<size {
    v = (v << 8) | data[start + i].to_int().to_int64()
  }
  v
}

///|
fn cue_find_element(
  data : BytesView,
  start : Int32,
  end : Int32,
  want : Int64,
) -> (Int32, Int32)? {
  let mut p = start
  while p < end {
    let (id, ilen) = match cue_id(data, p) {
      Ok(v) => v
      Err(_) => return None
    }
    let (size, slen) = match cue_size(data, p + ilen) {
      Ok(v) => v
      Err(_) => return None
    }
    let body = p + ilen + slen
    if size < 0L || body.to_int64() + size > end.to_int64() {
      return None
    }
    if id == want {
      return Some((body, size.to_int()))
    }
    p = body + size.to_int()
  }
  None
}

///|
fn cue_parse_point(data : BytesView, body : Int32, size : Int32) -> MkvCue? {
  let end = body + size
  let time = match cue_find_element(data, body, end, 0xB3L) {
    Some((s, n)) => cue_uint(data, s, n)
    None => 0L
  }
  let mut track = 0L
  let mut cluster = -1L
  let mut relative = 0L
  let mut block = 1L
  let mut p = body
  while p < end {
    let (id, ilen) = match cue_id(data, p) {
      Ok(v) => v
      Err(_) => return None
    }
    let (sz, slen) = match cue_size(data, p + ilen) {
      Ok(v) => v
      Err(_) => return None
    }
    let cbody = p + ilen + slen
    if sz < 0L || cbody.to_int64() + sz > end.to_int64() {
      return None
    }
    let csize = sz.to_int()
    if id == 0xB7L {
      // CueTrackPositions
      let cend = cbody + csize
      let mut q = cbody
      while q < cend {
        let (cid, cil) = match cue_id(data, q) {
          Ok(v) => v
          Err(_) => return None
        }
        let (csz, csl) = match cue_size(data, q + cil) {
          Ok(v) => v
          Err(_) => return None
        }
        let dbody = q + cil + csl
        if csz < 0L || dbody.to_int64() + csz > cend.to_int64() {
          return None
        }
        let dn = csz.to_int()
        if cid == 0xF7L {
          track = cue_uint(data, dbody, dn)
        } else if cid == 0xF1L {
          cluster = cue_uint(data, dbody, dn)
        } else if cid == 0xF0L {
          relative = cue_uint(data, dbody, dn)
        } else if cid == 0x5378L {
          block = cue_uint(data, dbody, dn)
        }
        q = dbody + dn
      }
    }
    p = cbody + csize
  }
  if cluster < 0L {
    return None
  }
  Some({
    time,
    track,
    cluster_position: cluster,
    relative_position: relative,
    block_number: block,
  })
}

///|
/// Parse every CuePoint of the first Cues element in an in-memory MKV/WebM.
pub fn av_matroska_parse_cues(data : Bytes) -> Result[MkvCues, String] {
  let n = data.length()
  let mut pos = 0
  // EBML header.
  let (header_id, hlen) = match cue_id(data, pos) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if header_id != 0x1A45DFA3L {
    return Err("mkv: missing EBML header")
  }
  let (hsize, hslen) = match cue_size(data, pos + hlen) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if hsize < 0L {
    return Err("mkv: EBML header size unknown")
  }
  pos = pos + hlen + hslen + hsize.to_int()
  // Segment.
  let (seg_id, slen) = match cue_id(data, pos) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if seg_id != 0x18538067L {
    return Err("mkv: missing Segment")
  }
  let (seg_size, ssize) = match cue_size(data, pos + slen) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let segment_start = pos + slen + ssize
  let segment_end = if seg_size < 0L {
    n
  } else {
    let e = segment_start.to_int64() + seg_size
    if e > n.to_int64() {
      n
    } else {
      e.to_int()
    }
  }
  let mut p = segment_start
  while p < segment_end {
    let (id, ilen) = match cue_id(data, p) {
      Ok(v) => v
      Err(_) => return Err("mkv: malformed Segment element")
    }
    let (size, szlen) = match cue_size(data, p + ilen) {
      Ok(v) => v
      Err(_) => return Err("mkv: malformed Segment size")
    }
    let body = p + ilen + szlen
    if size < 0L {
      return Err("mkv: unknown-size level-1 element not supported")
    }
    if id == 0x1C53BB6BL {
      let cues : Array[MkvCue] = []
      let end = body + size.to_int()
      let mut q = body
      while q < end {
        let (cid, cil) = match cue_id(data, q) {
          Ok(v) => v
          Err(_) => break
        }
        let (csz, csl) = match cue_size(data, q + cil) {
          Ok(v) => v
          Err(_) => break
        }
        let cbody = q + cil + csl
        if csz < 0L || cbody.to_int64() + csz > end.to_int64() {
          break
        }
        if cid == 0xBBL {
          match cue_parse_point(data, cbody, csz.to_int()) {
            Some(c) => cues.push(c)
            None => ()
          }
        }
        q = cbody + csz.to_int()
      }
      return Ok({ segment_data_start: segment_start.to_int64(), cues, })
    }
    p = body + size.to_int()
  }
  Err("mkv: no Cues element")
}

///|
/// Cue-based seek: the last cue at or before `time` (first cue when the target
/// precedes all of them), matching `matroska_seek`'s `av_index_search_timestamp`
/// with `AVSEEK_FLAG_BACKWARD`.
pub fn mkv_seek_cue(cues : MkvCues, time : Int64) -> MkvCue? {
  if cues.cues.length() == 0 {
    return None
  }
  let mut lo = 0
  let mut hi = cues.cues.length() - 1
  let mut found = 0
  while lo <= hi {
    let mid = (lo + hi) / 2
    if cues.cues[mid].time <= time {
      found = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  Some(cues.cues[found])
}
