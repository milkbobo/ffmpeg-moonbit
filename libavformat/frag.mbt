///|
/// Fragment-index boxes of the MP4/MOV demuxer, ported from FFmpeg 9.0.2
/// `libavformat/mov.c` (`mov_read_sidx`, `mov_read_mfra`, `read_tfra`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// FFmpeg feeds `sidx`/`mfra` into its `frag_index` (keyed by moof offset) to
/// drive `mov_seek_fragment` and duration bookkeeping; this port keeps the
/// parsed references on `Mp4Movie` and consults them where the C would (the
/// `trun` DTS fallback and the sidx-derived track duration). The "is the file
/// complete" tail of `mov_read_sidx` (which re-reads the trailing mfra size
/// to decide `frag_index.complete`) is covered by the end-of-parse mfra scan
/// in `av_mov_open` instead.

///|
/// `mov_sidx_lookup`: the sidx reference whose fragment starts exactly at
/// `moof_offset` for `track_id`, if any. This is what
/// `get_frag_stream_info(&c->frag_index, index, track_id)->sidx_pts` yields
/// in the `trun` DTS selection.
fn mov_sidx_lookup(st : MovState, moof_offset : Int64, track_id : UInt) -> Int64? {
  for i = 0; i < st.movie.sidx_refs.length(); i = i + 1 {
    let e = st.movie.sidx_refs[i]
    if e.offset == moof_offset && e.track_id == track_id {
      return Some(e.pts)
    }
  }
  None
}

///|
/// `mov_read_sidx`: segment index. Each reference marks the byte offset of a
/// subsegment (its `moof`) and its earliest presentation time; the
/// accumulated presentation times also become the track duration.
fn parse_sidx(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  // `avio_tell(pb)` at entry: the anchor is computed before any field is
  // read, exactly as in the C.
  let payload_start = r.position().to_int64()
  let version = r.read_u8()
  if version > 1 {
    // avpriv_request_sample: sidx version %u
    return
  }
  let _ = r.read_u24() // flags
  let track_id = r.read_u32()
  let track_opt = mov_find_track(st, track_id)
  let track = match track_opt {
    Some(t) => t
    None =>
      // could not find corresponding track id
      return
  }
  let timescale = r.read_u32()
  if timescale == 0 {
    raise InvalidData("invalid sidx timescale")
  }
  let (base_pts, offadd) = if version == 0 {
    (r.read_u32().to_int64(), r.read_u32().to_int64())
  } else {
    (r.read_i64(), r.read_i64())
  }
  let mut pts = base_pts
  // `offset = av_sat_add64(avio_tell(pb), atom.size) + offadd`: the anchor is
  // the end of the sidx box plus the declared first offset.
  let box_end = payload_start + size
  let mut offset = sat_add64(box_end, offadd)
  let _ = r.read_u16() // reserved
  let item_count = r.read_u16().reinterpret_as_int()
  if item_count == 0 {
    raise InvalidData("empty sidx")
  }
  for i = 0; i < item_count; i = i + 1 {
    if r.eof_reached() {
      raise InvalidData("EOF in sidx")
    }
    let ref_size = r.read_u32()
    let duration = r.read_u32()
    if (ref_size & 0x80000000) != 0 {
      raise InvalidData("sidx reference_type 1")
    }
    let _ = r.read_u32() // sap flags
    // `av_rescale_q(pts, sidx timescale, track timescale)`.
    let timestamp = mov_rescale(pts, track.timescale, timescale)
    st.movie.sidx_refs.push({
      track_id,
      offset,
      pts: timestamp,
      size: ref_size,
      duration,
    })
    offset = offset + ref_size.to_int64()
    pts = pts + duration.to_int64()
  }
  // `st->duration = sc->track_end = pts` (in sidx timescale units, as in C).
  track.track_end = pts
  track.duration = pts.reinterpret_as_uint64()
  track.has_sidx = true
}

///|
/// `mov_read_mfra`: look for a trailing `mfra` box and parse its `tfra`
/// tables. Scans from the end of the buffer; any mismatch leaves the movie
/// untouched, matching the C's "doesn't look like mfra" bail-outs.
fn mov_read_mfra(movie : Mp4Movie, r : Mp4Reader) -> Unit {
  let stream_size = r.total_size().to_int64()
  if stream_size < 8 {
    return
  }
  let original_pos = r.position()
  r.seek((stream_size - 4).to_int())
  let mfra_size = r.read_u32().to_int64()
  if mfra_size <= 0 || mfra_size > stream_size {
    r.seek(original_pos)
    return
  }
  r.seek((stream_size - mfra_size).to_int())
  if r.read_u32().to_int64() != mfra_size {
    r.seek(original_pos)
    return
  }
  if r.read_fourcc() != tag('m', 'f', 'r', 'a') {
    r.seek(original_pos)
    return
  }
  // Read tfra boxes until a non-tfra box (or the buffer) ends the table.
  while r.position() + 8 <= stream_size.to_int() {
    let pos = r.position().to_int64()
    let size = r.read_u32().to_int64()
    if r.read_fourcc() != tag('t', 'f', 'r', 'a') {
      break
    }
    let version = r.read_u8().reinterpret_as_int()
    let _ = r.read_u24() // flags
    let track_id = r.read_u32()
    let field_length = r.read_u32()
    let item_count = r.read_u32().reinterpret_as_int()
    let entries : Array[MovTfraEntry] = []
    for i = 0; i < item_count; i = i + 1 {
      if r.eof_reached() {
        break
      }
      let (time, offset) = if version == 1 {
        (r.read_i64(), r.read_i64())
      } else {
        (r.read_u32().to_int64(), r.read_u32().to_int64())
      }
      entries.push({ time, offset })
      // traf_size / trun_size / sample_size fields, sized by field_length.
      let mut j = 0
      while j < ((field_length >> 4) & 3).reinterpret_as_int() + 1 {
        let _ = r.read_u8()
        j = j + 1
      }
      j = 0
      while j < ((field_length >> 2) & 3).reinterpret_as_int() + 1 {
        let _ = r.read_u8()
        j = j + 1
      }
      j = 0
      while j < (field_length & 3).reinterpret_as_int() + 1 {
        let _ = r.read_u8()
        j = j + 1
      }
    }
    movie.mfra.push({ track_id, entries })
    r.seek((pos + size).to_int())
  }
  r.seek(original_pos)
}
