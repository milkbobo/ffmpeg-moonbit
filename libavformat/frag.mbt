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
fn mov_sidx_lookup(
  st : MovState,
  moof_offset : Int64,
  track_id : UInt32,
) -> Int64? {
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
fn parse_sidx(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  // `avio_tell(pb)` at entry: the anchor is computed before any field is
  // read, exactly as in the C.
  let payload_start = r.avio_tell()
  let version = r.avio_r8()
  if version > 1 {
    // avpriv_request_sample: sidx version %u
    return
  }
  let _ = r.avio_rb24() // flags
  let track_id = r.avio_rb32()
  let track_opt = mov_find_track(st, track_id)
  let track = match track_opt {
    Some(t) => t
    None =>
      // could not find corresponding track id
      return
  }
  let timescale = r.avio_rb32()
  if timescale == 0 {
    raise InvalidData("invalid sidx timescale")
  }
  let (base_pts, offadd) = if version == 0 {
    (r.avio_rb32().to_int64(), r.avio_rb32().to_int64())
  } else {
    (r.avio_rb64().reinterpret_as_int64(), r.avio_rb64().reinterpret_as_int64())
  }
  let mut pts = base_pts
  // `offset = av_sat_add64(avio_tell(pb), atom.size) + offadd`: the anchor is
  // the end of the sidx box plus the declared first offset.
  let box_end = payload_start + size
  let mut offset = sat_add64(box_end, offadd)
  let _ = r.avio_rb16() // reserved
  let item_count = r.avio_rb16().reinterpret_as_int()
  if item_count == 0 {
    raise InvalidData("empty sidx")
  }
  for i = 0; i < item_count; i = i + 1 {
    if r.avio_feof() {
      raise InvalidData("EOF in sidx")
    }
    let ref_size = r.avio_rb32()
    let duration = r.avio_rb32()
    if (ref_size & 0x80000000) != 0 {
      raise InvalidData("sidx reference_type 1")
    }
    let _ = r.avio_rb32() // sap flags
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
fn mov_read_mfra(movie : Mp4Movie, r : AvioContext) -> Unit {
  // C gates the scan on a usable avio_size; an unsizeable stream skips it.
  let stream_size = match r.avio_size() {
    Ok(v) => v
    Err(_) => return
  }
  if stream_size < 8 {
    return
  }
  let original_pos = r.avio_tell()
  let _ = r.avio_seek(stream_size - 4L, SEEK_SET)
  let mfra_size = r.avio_rb32().to_int64()
  if mfra_size <= 0 || mfra_size > stream_size {
    let _ = r.avio_seek(original_pos, SEEK_SET)
    return
  }
  let _ = r.avio_seek(stream_size - mfra_size, SEEK_SET)
  if r.avio_rb32().to_int64() != mfra_size {
    let _ = r.avio_seek(original_pos, SEEK_SET)
    return
  }
  if r.avio_rl32_tag() != tag('m', 'f', 'r', 'a') {
    let _ = r.avio_seek(original_pos, SEEK_SET)
    return
  }
  // Read tfra boxes until a non-tfra box (or the buffer) ends the table.
  while r.avio_tell() + 8L <= stream_size {
    let pos = r.avio_tell()
    let size = r.avio_rb32().to_int64()
    if r.avio_rl32_tag() != tag('t', 'f', 'r', 'a') {
      break
    }
    let version = r.avio_r8().reinterpret_as_int()
    let _ = r.avio_rb24() // flags
    let track_id = r.avio_rb32()
    let field_length = r.avio_rb32()
    let item_count = r.avio_rb32().reinterpret_as_int()
    let entries : Array[MovTfraEntry] = []
    for i = 0; i < item_count; i = i + 1 {
      if r.avio_feof() {
        break
      }
      let (time, offset) = if version == 1 {
        (
          r.avio_rb64().reinterpret_as_int64(),
          r.avio_rb64().reinterpret_as_int64(),
        )
      } else {
        (r.avio_rb32().to_int64(), r.avio_rb32().to_int64())
      }
      entries.push({ time, offset, })
      // traf_size / trun_size / sample_size fields, sized by field_length.
      let mut j = 0
      while j < ((field_length >> 4) & 3).reinterpret_as_int() + 1 {
        let _ = r.avio_r8()
        j = j + 1
      }
      j = 0
      while j < ((field_length >> 2) & 3).reinterpret_as_int() + 1 {
        let _ = r.avio_r8()
        j = j + 1
      }
      j = 0
      while j < (field_length & 3).reinterpret_as_int() + 1 {
        let _ = r.avio_r8()
        j = j + 1
      }
    }
    movie.mfra.push({ track_id, entries, })
    let _ = r.avio_seek(pos + size, SEEK_SET)
  }
  let _ = r.avio_seek(original_pos, SEEK_SET)
}
