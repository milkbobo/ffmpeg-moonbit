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

///| `EBML_VERSION` (matroska.h): the highest EBML version supported. */
pub let ebml_version_max : UInt64 = 2

///| `Ebml` from matroska.h: the parsed EBML header fields. */
pub struct EbmlHeader {
  ///| `EBMLVersion`/`EBMLReadVersion` (both default 1 via the table).
  mut version : UInt64
  ///| `EBMLMaxSizeLength` (default 8).
  mut max_size : UInt64
  ///| `EBMLMaxIDLength` (default 4).
  mut id_length : UInt64
  ///| `DocType` (default "(none)").
  mut doctype : String
  ///| `DocTypeReadVersion` (default 1).
  mut doctype_version : UInt64
}

///| `Ebml` with the syntax-table defaults applied (the C's zero-init plus
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

///| `matroska_doctypes[]`: the doctypes FFmpeg recognises. */
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
    { id: 0x4286, kind: Skip, sink: None },
    // EBML_ID_DOCTYPEVERSION: EBML_NONE in the C
    { id: 0x4287, kind: Skip, sink: None },
  ]
}

///|
/// The `ebml_syntax[]` table: an EBML header nest, stopping at a Segment.
fn ebml_syntax_table(ebml : EbmlHeader) -> Array[EbmlSyntax] {
  [
    { id: ebml_id_header, kind: Nest(() => ebml_header_table(ebml)), sink: None },
    { id: matroska_id_segment, kind: Stop, sink: None },
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
    pb : AvioContext) -> Result[(EbmlHeader, EbmlState, EbmlHeaderNotes), String] {
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
  let notes : EbmlHeaderNotes = { supported_doctype: true, uses_unsupported_features: false }
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

///| Warning-level outcomes of the header validation (the C logs these). */
pub struct EbmlHeaderNotes {
  ///| The doctype is not matroska/webm ("Unknown EBML doctype").
  mut supported_doctype : Bool
  ///| DocTypeReadVersion 3 ("using unsupported features").
  mut uses_unsupported_features : Bool
}
