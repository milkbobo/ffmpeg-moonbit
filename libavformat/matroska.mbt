///|
/// Matroska/WebM demuxer slice 1: the EBML header, ported from FFmpeg 9.0.2
/// `libavformat/matroskadec.c` — the `ebml_header[]`/`ebml_syntax[]`
/// tables and the validation chain at the top of `matroska_read_header`.
///
/// The C's static syntax tables write through `data + offset`; here the
/// tables are built per parse by a factory whose `sink` closures capture the
/// `EbmlHeader`, and the defaults of `ebml_parse_nest`'s pre-pass are applied
/// by constructing the header with them (the C starts from `Ebml ebml = {0}`
/// and overwrites with the defaults). The `CHILD_OF(ebml_syntax)` row — the
/// sentinel that ends an unknown-length EBML header when a Segment id
/// appears — is carried as the ancestor stack of the walker.

///|
/// `EBML_VERSION` (matroska.h): the highest EBML version supported. */
pub let ebml_version_max : UInt64 = 2

///|
/// `Ebml` from matroska.h: the parsed EBML header fields. */
pub struct EbmlHeader {
  /// `EBMLVersion`/`EBMLReadVersion` (both default 1 via the table).
  mut version : UInt64
  /// `EBMLMaxSizeLength` (default 8).
  mut max_size : UInt64
  /// `EBMLMaxIDLength` (default 4).
  mut id_length : UInt64
  /// `DocType` (default "(none)").
  mut doctype : String
  /// `DocTypeReadVersion` (default 1).
  mut doctype_version : UInt64
}

///|
/// `Ebml` with the syntax-table defaults applied (the C's zero-init plus
/// `ebml_parse_nest`'s default pass in one step). */
fn new_ebml_header() -> EbmlHeader {
  {
    version: 1, // EBML_ID_EBMLREADVERSION default EBML_VERSION
    max_size: 8,
    id_length: 4,
    doctype: "(none)",
    doctype_version: 1,
  }
}

///|
/// `matroska_doctypes[]`: the doctypes FFmpeg recognises. */
let matroska_doctypes : Array[String] = ["matroska", "webm"]

///|
/// The `ebml_header[]` table of matroskadec.c, wired to an `EbmlHeader`.
/// EBMLVersion and DocTypeVersion are `EBML_NONE` in the C (skipped);
/// the trailing `CHILD_OF(ebml_syntax)` row is the ancestor stack.
fn ebml_header_table(ebml : EbmlHeader) -> Array[EbmlSyntax] {
  [
    // EBML_ID_EBMLREADVERSION → ebml.version (default EBML_VERSION)
    {
      id: 0x42F7,
      kind: Uint(ebml_version_max),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            ebml.version = u
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    // EBML_ID_EBMLMAXSIZELENGTH → ebml.max_size (default 8)
    {
      id: 0x42F3,
      kind: Uint(8),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            ebml.max_size = u
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    // EBML_ID_EBMLMAXIDLENGTH → ebml.id_length (default 4)
    {
      id: 0x42F2,
      kind: Uint(4),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            ebml.id_length = u
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    // EBML_ID_DOCTYPE → ebml.doctype (default "(none)")
    {
      id: 0x4282,
      kind: Str(Some("(none)")),
      sink: Some((v, _) => {
        match v {
          S(s) => {
            ebml.doctype = s
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    // EBML_ID_DOCTYPEREADVERSION → ebml.doctype_version (default 1)
    {
      id: 0x4285,
      kind: Uint(1),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            ebml.doctype_version = u
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    // EBML_ID_EBMLVERSION: EBML_NONE in the C
    { id: 0x4286, kind: Skip, sink: None, },
    // EBML_ID_DOCTYPEVERSION: EBML_NONE in the C
    { id: 0x4287, kind: Skip, sink: None, },
  ]
}

///|
/// The `ebml_syntax[]` table: an EBML header nest, stopping at a Segment.
fn ebml_syntax_table(ebml : EbmlHeader) -> Array[EbmlSyntax] {
  [
    {
      id: ebml_id_header,
      kind: Nest(() => ebml_header_table(ebml)),
      sink: None,
    },
    { id: matroska_id_segment, kind: Stop, sink: None, },
  ]
}

///|
/// The EBML-header read + validation chain of `matroska_read_header`'s
/// head: parse the header, reject what FFmpeg reports missing
/// (`AVERROR_PATCHWELCOME` as `Err("ENOSYS")`), warn-level doctype checks
/// surface as the returned flags. `Err` means header parsing failed.
/// On success the parse state is left at the Segment element (its id still
/// in `current_id`), ready for the next slice.
pub fn matroska_read_ebml_header(
  pb : AvioContext,
) -> Result[(EbmlHeader, EbmlState, EbmlHeaderNotes), String] {
  let ebml = new_ebml_header()
  let st = EbmlState::new(pb)
  let res = ebml_parse(st, ebml_syntax_table(ebml), [])
  match res {
    // one element walked successfully: the EBML header
    Ok(0) => ()
    // EBML_STOP before any header, or "File ended prematurely"
    Err(e) => return Err(e)
    Ok(_) => return Err("EINVAL")
  }
  let notes : EbmlHeaderNotes = {
    supported_doctype: true,
    uses_unsupported_features: false,
  }
  if ebml.version > ebml_version_max ||
    ebml.max_size > 8 ||
    ebml.id_length > 4 ||
    ebml.doctype_version > 3 {
    // avpriv_report_missing_feature + AVERROR_PATCHWELCOME
    return Err("PATCHWELCOME")
  } else if ebml.doctype_version == 3 {
    // "EBML header using unsupported features" — warning in the C
    notes.uses_unsupported_features = true
  }
  let mut known = false
  for i = 0; i < matroska_doctypes.length(); i = i + 1 {
    if ebml.doctype == matroska_doctypes[i] {
      known = true
      break
    }
  }
  if known == false {
    // "Unknown EBML doctype" — a warning unless AV_EF_EXPLODE
    notes.supported_doctype = false
  }
  Ok((ebml, st, notes))
}

///|
/// Warning-level outcomes of the header validation (the C logs these). */
pub struct EbmlHeaderNotes {
  /// The doctype is not matroska/webm ("Unknown EBML doctype").
  mut supported_doctype : Bool
  /// DocTypeReadVersion 3 ("using unsupported features").
  mut uses_unsupported_features : Bool
}

// ---------------------------------------------------------------------------
// Segment / Info / SeekHead (matroska_read_header's main walk)
// ---------------------------------------------------------------------------

///|
/// `MATROSKA_ID_TIMECODESCALE`. */
pub let matroska_id_timecodescale : UInt32 = 0x2AD7B1

///|
/// `MATROSKA_ID_DURATION`. */
pub let matroska_id_duration : UInt32 = 0x4489

///|
/// `MATROSKA_ID_TITLE`. */
pub let matroska_id_title : UInt32 = 0x7BA9

///|
/// `MATROSKA_ID_WRITINGAPP`. */
pub let matroska_id_writingapp : UInt32 = 0x5741

///|
/// `MATROSKA_ID_MUXINGAPP`. */
pub let matroska_id_muxingapp : UInt32 = 0x4D80

///|
/// `MATROSKA_ID_DATEUTC`. */
pub let matroska_id_dateutc : UInt32 = 0x4461

///|
/// `MATROSKA_ID_SEGMENTUID`. */
pub let matroska_id_segmentuid : UInt32 = 0x73A4

///|
/// `MATROSKA_ID_SEEKENTRY`. */
pub let matroska_id_seekentry : UInt32 = 0x4DBB

///|
/// `MATROSKA_ID_SEEKID`. */
pub let matroska_id_seekid : UInt32 = 0x53AB

///|
/// `MATROSKA_ID_SEEKPOSITION`. */
pub let matroska_id_seekposition : UInt32 = 0x53AC

///|
/// `MatroskaSeekhead`: one SeekHead entry (id + position in the segment). */
pub struct MkvSeekhead {
  mut id : UInt32
  mut pos : UInt64
}

///|
/// The segment-level state this slice produces (a slice of
/// `MatroskaDemuxContext`): Info fields, the SeekHead list, and where the
/// first Cluster starts.
pub struct MatroskaHeader {
  /// `matroska->time_scale` (Info TimecodeScale, default 1000000).
  mut time_scale : UInt64
  /// `matroska->duration` (Info Duration, a float in time_scale units).
  mut duration : Double
  /// `matroska->title`.
  mut title : String?
  /// `matroska->muxingapp` (Info MuxingApp).
  mut muxingapp : String?
  /// `matroska->date_utc` (raw 8-byte payload).
  mut date_utc : Bytes?
  /// `matroska->seekhead[]`.
  seekhead : Array[MkvSeekhead]
  /// `matroska->segment_start`.
  mut segment_start : Int64
  /// `si->data_offset`: the first Cluster's start (-1 when none was seen).
  mut first_cluster_pos : Int64
  /// `matroska->is_webm` (from the EBML header doctype).
  mut is_webm : Bool
  /// `matroska->tracks[]` (the Tracks slice).
  tracks : Array[MkvTrack]
  /// Demuxed packets in stream order (the C's packet queue).
  packets : Array[MkvPacket]
}

///|
/// Info defaults per `ebml_parse_nest`'s pre-pass. */
fn new_matroska_header() -> MatroskaHeader {
  {
    time_scale: 1000000UL,
    duration: 0.0,
    title: None,
    muxingapp: None,
    date_utc: None,
    seekhead: [],
    segment_start: 0,
    first_cluster_pos: -1L,
    is_webm: false,
    tracks: [],
    packets: [],
  }
}

///|
/// The `matroska_info[]` table wired to a `MatroskaHeader`.
/// WritingApp and SegmentUID are `EBML_NONE` in the C.
fn matroska_info_table(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_timecodescale,
      kind: Uint(1000000UL),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            mh.time_scale = u
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: matroska_id_duration,
      kind: Float(0.0),
      sink: Some((v, _) => {
        match v {
          F(f) => {
            mh.duration = f
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: matroska_id_title,
      kind: Str(None),
      sink: Some((v, _) => {
        match v {
          S(s) => {
            mh.title = Some(s)
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    { id: matroska_id_writingapp, kind: Skip, sink: None, },
    {
      id: matroska_id_muxingapp,
      kind: Str(None),
      sink: Some((v, _) => {
        match v {
          S(s) => {
            mh.muxingapp = Some(s)
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: matroska_id_dateutc,
      kind: Bin,
      sink: Some((v, _) => {
        match v {
          B(b) => {
            mh.date_utc = Some(b)
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    { id: matroska_id_segmentuid, kind: Skip, sink: None, },
  ]
}

///|
/// The `matroska_seekhead_entry[]` table for the entry at `idx`; the
/// SeekEntry master's children thunk creates the entry (with the C's
/// default pos -1) right before this table is built.
fn matroska_seekhead_entry_table(
  mh : MatroskaHeader,
  idx : Int32,
) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_seekid,
      kind: Uint(0),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            mh.seekhead[idx].id = (u & 0xFFFFFFFFUL)
              .to_int()
              .reinterpret_as_uint()
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: matroska_id_seekposition,
      kind: Uint(0xFFFFFFFFFFFFFFFFUL),
      sink: Some((v, _) => {
        match v {
          U(u) => {
            mh.seekhead[idx].pos = u
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
  ]
}

///|
/// The `matroska_seekhead[]` table; each SeekEntry appends one element to
/// the list (the C's EbmlList grow at master-start with defaults applied).
fn matroska_seekhead_table(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_seekentry,
      kind: Nest(() => {
        mh.seekhead.push({ id: 0, pos: 0xFFFFFFFFFFFFFFFFUL, })
        let idx = mh.seekhead.length() - 1
        matroska_seekhead_entry_table(mh, idx)
      }),
      sink: None,
    },
  ]
}

///|
/// The `matroska_segment[]` table: the walk stops at the first Cluster.
/// Tracks/Attachments/Chapters/Cues/Tags are recognised (skipped silently)
/// until their slices land; Info and SeekHead parse.
fn matroska_segment_table(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  [
    { id: matroska_id_cluster, kind: Stop, sink: None, },
    {
      id: matroska_id_info,
      kind: Level1(() => matroska_info_table(mh)),
      sink: None,
    },
    {
      id: matroska_id_seekhead,
      kind: Level1(() => matroska_seekhead_table(mh)),
      sink: None,
    },
    {
      id: matroska_id_tracks,
      kind: Level1(() => matroska_tracks_table(mh)),
      sink: None,
    },
    { id: matroska_id_attachments, kind: Skip, sink: None, },
    { id: matroska_id_chapters, kind: Skip, sink: None, },
    { id: matroska_id_cues, kind: Skip, sink: None, },
    { id: matroska_id_tags, kind: Skip, sink: None, },
  ]
}

///|
/// The `matroska_segments[]` table (the top-level Segment nest). */
fn matroska_segments_table(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_segment,
      kind: Nest(() => matroska_segment_table(mh)),
      sink: None,
    },
  ]
}

// ---------------------------------------------------------------------------
// resync / reset_status (matroskadec.c)
// ---------------------------------------------------------------------------

///|
/// `matroska_reset_status`: rewind (when `position >= 0`), preset
/// `current_id`, reset the level stack to one unknown-length level and
/// clear the unknown-element bookkeeping.
fn matroska_reset_status(
  st : EbmlState,
  id : UInt32,
  position : Int64,
) -> Result[Unit, String] {
  if position >= 0L {
    match st.pb.avio_seek(position, SEEK_SET) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  st.current_id = id
  st.levels.clear()
  st.levels.push((0L, ebml_unknown_length))
  st.unknown_count = 0
  st.resync_pos = if position >= 0L { position } else { st.pb.avio_tell() }
  if id != 0 {
    st.resync_pos = st.resync_pos -
      ((@libavutil.av_log2(id) + 7) / 8).to_int64()
  }
  Ok(())
}

///|
/// `matroska_resync`: scan forward byte-wise for a level-1 element id
/// (sliding 32-bit window) and re-arm the parser there; the level is set
/// to unknown length so data beyond a damaged segment end survives.
fn matroska_resync(st : EbmlState, last_pos : Int64) -> Result[Unit, String] {
  let pb = st.pb
  if last_pos < pb.avio_tell() {
    match pb.avio_seek(last_pos + 1L, SEEK_SET) {
      Err(_) => {
        // seek to the desired resync point failed: earliest point instead
        let _ = pb.avio_seek(0L, SEEK_SET)
      }
      Ok(_) => ()
    }
  }
  let mut id = pb.avio_rb32()
  while pb.avio_feof() == false {
    if id == matroska_id_info ||
      id == matroska_id_tracks ||
      id == matroska_id_cues ||
      id == matroska_id_tags ||
      id == matroska_id_seekhead ||
      id == matroska_id_attachments ||
      id == matroska_id_cluster ||
      id == matroska_id_chapters {
      // Prepare the context for parsing of a level 1 element; treat the
      // segment as unknown length (an error got us here).
      let _ = matroska_reset_status(st, id, -1L)
      st.levels.clear()
      st.levels.push((0L, ebml_unknown_length))
      return Ok(())
    }
    id = (id << 8) | pb.avio_r8()
  }
  Err("EOF")
}

// ---------------------------------------------------------------------------
// execute_seekhead (matroskadec.c)
// ---------------------------------------------------------------------------

///|
/// `matroska_parse_seekhead_entry`: seek to `pos` and parse one level-1
/// element there with a dummy unknown-length level, then restore the
/// cursor and parse state.
fn matroska_parse_seekhead_entry(
  st : EbmlState,
  mh : MatroskaHeader,
  pos : Int64,
) -> Result[Unit, String] {
  let saved_id = st.current_id
  let before_pos = st.pb.avio_tell()
  let mut ret : Result[Unit, String] = Ok(())
  match st.pb.avio_seek(pos, SEEK_SET) {
    Err(e) => ret = Err(e)
    Ok(_) =>
      if st.levels.length() >= ebml_max_depth {
        ret = Err("EINVAL")
      } else {
        // a dummy level so the seekhead level is not lost ("a crude hack")
        st.levels.push((0L, ebml_unknown_length))
        st.current_id = 0
        match
          ebml_parse(st, matroska_segment_table(mh), [
            matroska_segments_table(mh),
          ]) {
          Err(e) => ret = Err(e)
          Ok(level_ended_code) =>
            if level_ended_code == level_ended {
              // this can only happen beyond EOF
              ret = Err("EOF")
            }
        }
      }
  }
  // Seek back; in all instances where this is used it is safe to reset the
  // level stack to one unknown-length level.
  let ret2 = matroska_reset_status(st, saved_id, before_pos)
  match ret {
    Err(e) => Err(e)
    Ok(_) => ret2
  }
}

///|
/// `matroska_execute_seekhead`: for every seekhead entry not yet parsed,
/// jump to it and parse it (cues stay deferred). Seekable sources only.
fn matroska_execute_seekhead(st : EbmlState, mh : MatroskaHeader) -> Unit {
  if st.pb.seekable == false {
    return
  }
  for i = 0; i < mh.seekhead.length(); i = i + 1 {
    let id = mh.seekhead[i].id
    let pos = mh.seekhead[i].pos.reinterpret_as_int64() + st.segment_start
    if pos < st.segment_start {
      continue
    }
    let elem = match matroska_find_level1_elem(st, id, pos) {
      None => continue
      Some(e) => e
    }
    if elem.parsed {
      continue
    }
    elem.pos = pos
    // defer cues parsing until cue data is actually needed
    if id == matroska_id_cues {
      continue
    }
    match matroska_parse_seekhead_entry(st, mh, pos) {
      Err(_) => {
        // mark the index as broken
        st.cues_parsing_deferred = -1
        break
      }
      Ok(_) => elem.parsed = true
    }
  }
}

// ---------------------------------------------------------------------------
// matroska_read_header's walk + entry point
// ---------------------------------------------------------------------------

///|
/// The segment walk of `matroska_read_header` after the EBML header: parse
/// the Segment, resyncing on damage until a Cluster stop is reached, then
/// execute the SeekHead. `current_id` holds the Cluster id on success.
fn matroska_read_segment(
  st : EbmlState,
  mh : MatroskaHeader,
) -> Result[Unit, String] {
  let mut pos = st.pb.avio_tell()
  let mut res = ebml_parse(st, matroska_segments_table(mh), [])
  let mut rounds = 0
  while res != Ok(1) {
    rounds = rounds + 1
    if rounds > 64 {
      // defensive: the C relies on EOF terminating the resync loop
      return Err("EINVAL")
    }
    match res {
      Err(e) =>
        if e == "EIO" {
          // EOF is translated to EIO: exit the loop
          return Err(e)
        }
      Ok(_) => ()
    }
    match matroska_resync(st, pos) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    pos = st.pb.avio_tell()
    res = ebml_parse(st, matroska_segment_table(mh), [])
    match res {
      Err("EIO") => return Err("EIO")
      _ => ()
    }
  }
  mh.segment_start = st.segment_start
  // If the walk stopped on a Cluster, its start (id already read, length
  // not) is the packet data offset; walk every cluster and queue packets.
  if st.current_id == matroska_id_cluster {
    mh.first_cluster_pos = st.pb.avio_tell() - 4L
    match matroska_walk_clusters(st, mh) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  matroska_execute_seekhead(st, mh)
  Ok(())
}

///|
/// `av_matroska_open`: parse the EBML header and the first segment of a
/// Matroska/WebM stream (Info + SeekHead; the walk stops at the first
/// Cluster). Track/cluster parsing are later slices.
pub fn av_matroska_open(buf : Bytes) -> Result[MatroskaHeader, String] {
  let pb = AvioContext::init_read_context(buf)
  let (ebml, st, notes) = match matroska_read_ebml_header(pb) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let mh = new_matroska_header()
  mh.is_webm = ebml.doctype == "webm"
  match matroska_read_segment(st, mh) {
    Err(e) => Err(e)
    Ok(_) => {
      // unknown doctype stays a warning in the C; surface it via is_webm
      ignore(notes)
      Ok(mh)
    }
  }
}
