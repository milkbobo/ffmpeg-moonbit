///|
/// Whitebox tests for the EBML layer (`ebml.mbt`) and the Matroska EBML
/// header slice (`matroska.mbt`), ported from FFmpeg 9.0.2
/// `libavformat/matroskadec.c`.
///
/// VINT encodings are the EBML spec's own examples (RFC 8796 §4); the
/// header walks are hand-derived from the `ebml_header[]`/`ebml_syntax[]`
/// tables and the `ebml_parse` semantics in matroskadec.c.

// ---------------------------------------------------------------------------
// Byte builders
// ---------------------------------------------------------------------------

fn bcat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < parts.length(); i = i + 1 {
    for j = 0; j < parts[i].length(); j = j + 1 {
      out.push(parts[i][j])
    }
  }
  Bytes::from_array(out[:])
}

///| A minimal VINT for lengths/values < 128 (0x80 | v). */
fn vint1(v : Int) -> Bytes {
  Bytes::make(1, (0x80 | v).to_byte())
}

///| `el`: an element `id + vint(len) + payload`. */
fn el(id : Bytes, data : Bytes) -> Bytes {
  if data.length() < 128 {
    bcat([id, vint1(data.length()), data])
  } else {
    // 2-byte vint: 0x4000 | len
    let n = data.length()
    let len_bytes : Array[Byte] = [(0x40 | (n >> 8)).to_byte(), (0x80 | (n & 0xFF)).to_byte()]
    bcat([id, Bytes::from_array(len_bytes[:]), data])
  }
}

fn pb_of(data : Bytes) -> AvioContext {
  AvioContext::init_read_context(data)
}

// ---------------------------------------------------------------------------
// ebml_read_num / ebml_read_length (spec VINT examples)
// ---------------------------------------------------------------------------

test "ebml: read_num across the spec VINT examples" {
  // one-byte: 0x80→0, 0x81→1, 0xFF→127
  assert_eq(ebml_read_num(pb_of(b"\x80"), 8, true).unwrap(), (0UL, 1))
  assert_eq(ebml_read_num(pb_of(b"\x81"), 8, true).unwrap(), (1UL, 1))
  assert_eq(ebml_read_num(pb_of(b"\xFF"), 8, true).unwrap(), (127UL, 1))
  // two-byte: 0x4000→0, 0x40 81→1, 0x3FFF→16383
  assert_eq(ebml_read_num(pb_of(b"\x40\x00"), 8, true).unwrap(), (0UL, 2))
  assert_eq(ebml_read_num(pb_of(b"\x40\x01"), 8, true).unwrap(), (1UL, 2))
  assert_eq(ebml_read_num(pb_of(b"\x7F\xFF"), 8, true).unwrap(), (16383UL, 2))
  // three-byte: 0x200000→0, 0x1FFFFF→2097151
  assert_eq(ebml_read_num(pb_of(b"\x20\x00\x00"), 8, true).unwrap(), (0UL, 3))
  assert_eq(ebml_read_num(pb_of(b"\x3F\xFF\xFF"), 8, true).unwrap(), (2097151UL, 3))
  // eight-byte: 0x01FFFFFFFFFFFFFF → 2^56-1
  assert_eq(
    ebml_read_num(pb_of(b"\x01\xFF\xFF\xFF\xFF\xFF\xFF\xFF"), 8, true).unwrap(),
    (72057594037927935UL, 8),
  )
  // width beyond max_size (0x1F starts a 4-byte number, max 3)
  assert_eq(ebml_read_num(pb_of(b"\x1F\x00\x00\x00"), 3, true), Err("EINVAL"))
  // 0x00 is invalid as a first byte
  assert_eq(ebml_read_num(pb_of(b"\x00\x01"), 8, true), Err("EINVAL"))
  // EOF on an empty stream: EOF when allowed, EIO when forbidden
  assert_eq(ebml_read_num(pb_of(b""), 8, false), Err("EOF"))
  assert_eq(ebml_read_num(pb_of(b""), 8, true), Err("EIO"))
  // truncated multi-byte number is fatal either way
  assert_eq(ebml_read_num(pb_of(b"\x40"), 8, false), Err("EIO"))
}

test "ebml: read_length maps all-ones widths to the unknown marker" {
  assert_eq(ebml_read_length(pb_of(b"\xFF")).unwrap(), (ebml_unknown_length, 1))
  assert_eq(
    ebml_read_length(pb_of(b"\x01\xFF\xFF\xFF\xFF\xFF\xFF\xFF")).unwrap(),
    (ebml_unknown_length, 8),
  )
  assert_eq(ebml_read_length(pb_of(b"\x82")).unwrap(), (2UL, 1))
  // 0xFE: the largest one-byte length that is not all ones
  assert_eq(ebml_read_length(pb_of(b"\xFE")).unwrap(), (126UL, 1))
}

// ---------------------------------------------------------------------------
// scalar readers
// ---------------------------------------------------------------------------

test "ebml: read_uint / read_sint" {
  let mut got : UInt64 = 0
  let _ = ebml_read_uint(pb_of(b"\x01\x02\x03\x04"), 4, 99, v => got = v)
  assert_eq(got, 0x01020304UL)
  let _ = ebml_read_uint(pb_of(b""), 0, 77, v => got = v)
  assert_eq(got, 77UL)
  let mut si : Int64 = 0
  let _ = ebml_read_sint(pb_of(b"\xFF"), 1, 5, v => si = v)
  assert_eq(si, -1L)
  let _ = ebml_read_sint(pb_of(b"\x80"), 1, 5, v => si = v)
  assert_eq(si, -128L)
  let _ = ebml_read_sint(pb_of(b"\x7F"), 1, 5, v => si = v)
  assert_eq(si, 127L)
  let _ = ebml_read_sint(pb_of(b"\xFF\xFF"), 2, 5, v => si = v)
  assert_eq(si, -1L)
  let _ = ebml_read_sint(pb_of(b"\x40\x00"), 2, 5, v => si = v)
  assert_eq(si, 16384L)
  let _ = ebml_read_sint(pb_of(b""), 0, -7, v => si = v)
  assert_eq(si, -7L)
}

test "ebml: read_float (binary32/64, inf/nan, defaults, bad size)" {
  let mut f = 0.0
  // binary32 1.5 = 0x3FC00000; 2.5(binary64) = 0x4004000000000000
  let _ = ebml_read_float(pb_of(b"\x3F\xC0\x00\x00"), 4, 9.0, v => f = v)
  assert_eq(f, 1.5)
  let _ = ebml_read_float(
    pb_of(b"\x40\x04\x00\x00\x00\x00\x00\x00"),
    8,
    9.0,
    v => f = v,
  )
  assert_eq(f, 2.5)
  // ±inf and NaN from both widths
  let _ = ebml_read_float(pb_of(b"\x7F\x80\x00\x00"), 4, 0.0, v => f = v)
  assert_eq(f > 0.0 && f == f * 2.0, true) // +inf
  let _ = ebml_read_float(pb_of(b"\xFF\x80\x00\x00"), 4, 0.0, v => f = v)
  assert_eq(f < 0.0 && f == f * 2.0, true) // -inf
  let _ = ebml_read_float(
    pb_of(b"\x7F\xF0\x00\x00\x00\x00\x00\x01"),
    8,
    0.0,
    v => f = v,
  )
  assert_eq(f != f, true) // NaN
  // default on size 0; invalid size
  let _ = ebml_read_float(pb_of(b""), 0, 6.5, v => f = v)
  assert_eq(f, 6.5)
  assert_eq(ebml_read_float(pb_of(b"\x00"), 5, 0.0, _ => ()).unwrap_err_(), "EINVAL")
}

///| Tiny helper: the error string of a Result (test-only). */
fn Result::unwrap_err_(r : Result[Bool, String]) -> String {
  match r {
    Err(e) => e
    Ok(_) => ""
  }
}

test "ebml: read_ascii and read_binary" {
  assert_eq(ebml_read_ascii(pb_of(b"abc"), 3, None).unwrap(), (Some("abc"), false))
  // not NUL-terminated in the stream; NULs are ordinary bytes
  assert_eq(ebml_read_ascii(pb_of(b"a\x00c"), 3, None).unwrap(), (Some("a\u{0}c"), false))
  // size 0 with a default
  assert_eq(ebml_read_ascii(pb_of(b""), 0, Some("dflt")).unwrap(), (Some("dflt"), false))
  // short read: no string, needs checking
  assert_eq(ebml_read_ascii(pb_of(b"ab"), 3, None).unwrap(), (None, true))
  // binary keeps the payload and the position after the header
  let (b, p) = ebml_read_binary(pb_of(b"\x01\x02"), 2, 42L).unwrap()
  ignore(p)
  assert_eq(b, Some(b"\x01\x02"))
  let (b2, _) = ebml_read_binary(pb_of(b"\x01"), 2, 0L).unwrap()
  assert_eq(b2, None)
}

test "ebml: matroska_ebmlnum_sint rebias" {
  assert_eq(matroska_ebmlnum_sint(pb_of(b"\x81")).unwrap(), (-62L, 1))
  assert_eq(matroska_ebmlnum_sint(pb_of(b"\xFF")).unwrap(), (64L, 1))
  assert_eq(matroska_ebmlnum_sint(pb_of(b"\x40\x00")).unwrap(), (-8191L, 2))
}

test "ebml: is_ebml_id_valid marker/width agreement" {
  assert_eq(is_ebml_id_valid(0x1A45DFA3), true) // EBML header, 4 bytes
  assert_eq(is_ebml_id_valid(0x18538067), true) // Segment, 4 bytes
  assert_eq(is_ebml_id_valid(0x1549A966), true) // Info, 4 bytes
  assert_eq(is_ebml_id_valid(0xEC), true) // Void, 1 byte
  assert_eq(is_ebml_id_valid(0xBF), true) // CRC32, 1 byte
  assert_eq(is_ebml_id_valid(0), false)
  // 0xFF: marker at bit 7, exactly a 1-byte id (valid per the C formula)
  assert_eq(is_ebml_id_valid(0xFF), true)
  // 0x1FF and 0x1234: the marker position disagrees with the byte count
  assert_eq(is_ebml_id_valid(0x1FF), false)
  assert_eq(is_ebml_id_valid(0x1234), false)
}

// ---------------------------------------------------------------------------
// the generic walker: sint/float/bin/str rows (also used by later slices)
// ---------------------------------------------------------------------------

test "ebml: walker delivers sint, float, bin and str payloads" {
  // A custom master (id 0x2E0000) framing a VOID plus one sint/float/bin/str
  // element each; the top table nests into it and the walk ends with the
  // level (the last child exactly completes the master).
  let mut sint_got : Int64 = 0
  let mut float_got = 0.0
  let mut bin_got = b""
  let mut str_got = ""
  let child_table : Array[EbmlSyntax] = [
    { id: 0xEC, kind: Skip, sink: None },
    {
      id: 0x4488,
      kind: Sint(0),
      sink: Some((v, _) => {
        match v {
          I(i) => {
            sint_got = i
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: 0x4489,
      kind: Float(0.0),
      sink: Some((v, _) => {
        match v {
          F(x) => {
            float_got = x
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: 0x448A,
      kind: Bin,
      sink: Some((v, _) => {
        match v {
          B(x) => {
            bin_got = x
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
    {
      id: 0x448B,
      kind: Str(None),
      sink: Some((v, _) => {
        match v {
          S(x) => {
            str_got = x
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
  ]
  let children = bcat([
    b"\xEC",
    vint1(3),
    b"\x00\x00\x00", // VOID, skipped
    el(b"\x44\x88", b"\xFF\xFB"), // sint -5
    el(b"\x44\x89", b"\x3F\x80\x00\x00"), // float 1.0
    el(b"\x44\x8A", b"\xAA\xBB"),
    el(b"\x44\x8B", b"hi"),
  ])
  let data = bcat([b"\x2E\x00\x00", vint1(children.length()), children])
  let top : Array[EbmlSyntax] = [
    { id: 0x2E0000, kind: Nest(() => child_table), sink: None },
  ]
  let st = EbmlState::new(pb_of(data))
  assert_eq(ebml_parse(st, top, []), Ok(0))
  assert_eq(sint_got, -5L)
  assert_eq(float_got, 1.0)
  assert_eq(bin_got, b"\xAA\xBB")
  assert_eq(str_got, "hi")
}

// ---------------------------------------------------------------------------
// the EBML header (matroska.mbt)
// ---------------------------------------------------------------------------

///| A full synthetic EBML stream: header children + optional trailing ids. */
fn ebml_stream(
    doctype : Bytes,
    unknown_header_len : Bool,
    trailing : Bytes) -> Bytes {
  let children : Array[Bytes] = [
    el(b"\x42\x86", b"\x01"), // EBMLVersion (skipped)
    el(b"\x42\xF7", b"\x01"), // EBMLReadVersion = 1
    el(b"\x42\xF2", b"\x04"), // EBMLMaxIDLength = 4
    el(b"\x42\xF3", b"\x08"), // EBMLMaxSizeLength = 8
    el(b"\x42\x82", doctype),
    el(b"\x42\x87", b"\x02"), // DocTypeVersion (skipped)
    el(b"\x42\x85", b"\x02"), // DocTypeReadVersion = 2
  ]
  let body = bcat(children)
  let header_len : Bytes = if unknown_header_len {
    b"\xFF"
  } else {
    vint1(body.length())
  }
  bcat([b"\x1A\x45\xDF\xA3", header_len, body, trailing])
}

test "matroska: EBML header parse with a Segment stop" {
  let stream = ebml_stream(b"matroska", false, b"\x18\x53\x80\x67")
  let (ebml, st, notes) = matroska_read_ebml_header(pb_of(stream)).unwrap()
  assert_eq(ebml.version, 1UL)
  assert_eq(ebml.max_size, 8UL)
  assert_eq(ebml.id_length, 4UL)
  assert_eq(ebml.doctype, "matroska")
  assert_eq(ebml.doctype_version, 2UL)
  assert_eq(notes.supported_doctype, true)
  assert_eq(notes.uses_unsupported_features, false)
  // One element was walked (the header); nothing further was read, so
  // current_id is empty. The Segment stop fires on the *next* parse call
  // (as in the C, where matroska_read_header then parses matroska_segments).
  assert_eq(st.current_id, 0)
  // webm doctype is recognised the same way
  let (e2, _, n2) = matroska_read_ebml_header(
    pb_of(ebml_stream(b"webm", false, b"\x18\x53\x80\x67")),
  ).unwrap()
  assert_eq(e2.doctype, "webm")
  assert_eq(n2.supported_doctype, true)
}

test "matroska: unknown-length header ends at the Segment (CHILD_OF)" {
  // Header size 0xFF (unknown): the level ends when the Segment id — an
  // element of the enclosing ebml_syntax table — appears.
  let stream = ebml_stream(b"webm", true, b"\x18\x53\x80\x67")
  let (ebml, _, _) = matroska_read_ebml_header(pb_of(stream)).unwrap()
  assert_eq(ebml.doctype, "webm")
  assert_eq(ebml.doctype_version, 2UL)
}

test "matroska: header defaults apply for absent elements" {
  // Only the DocType: everything else keeps the table defaults.
  let children = el(b"\x42\x82", b"webm")
  let stream = bcat([
    b"\x1A\x45\xDF\xA3",
    vint1(children.length()),
    children,
    b"\x18\x53\x80\x67",
  ])
  let (ebml, _, notes) = matroska_read_ebml_header(pb_of(stream)).unwrap()
  assert_eq(ebml.version, 1UL)
  assert_eq(ebml.max_size, 8UL)
  assert_eq(ebml.id_length, 4UL)
  assert_eq(ebml.doctype_version, 1UL)
  assert_eq(notes.supported_doctype, true)
}

test "matroska: doctype and version notes/rejections" {
  // Unknown doctype: warning-level (flagged, still Ok)
  let (e1, _, n1) = matroska_read_ebml_header(
    pb_of(ebml_stream(b"foo", false, b"\x18\x53\x80\x67")),
  ).unwrap()
  assert_eq(e1.doctype, "foo")
  assert_eq(n1.supported_doctype, false)
  // DocTypeReadVersion 3: "using unsupported features" warning flag
  let children = bcat([el(b"\x42\x82", b"matroska"), el(b"\x42\x85", b"\x03")])
  let stream = bcat([
    b"\x1A\x45\xDF\xA3",
    vint1(children.length()),
    children,
    b"\x18\x53\x80\x67",
  ])
  let (e2, _, n2) = matroska_read_ebml_header(pb_of(stream)).unwrap()
  assert_eq(e2.doctype_version, 3UL)
  assert_eq(n2.uses_unsupported_features, true)
  // DocTypeReadVersion 4: AVERROR_PATCHWELCOME
  let children4 = bcat([el(b"\x42\x82", b"matroska"), el(b"\x42\x85", b"\x04")])
  let stream4 = bcat([
    b"\x1A\x45\xDF\xA3",
    vint1(children4.length()),
    children4,
    b"\x18\x53\x80\x67",
  ])
  assert_eq(
    matroska_read_ebml_header(pb_of(stream4)).unwrap_err_hdr(),
    "PATCHWELCOME",
  )
}

///| Test-only: the error of a header read. */
fn Result::unwrap_err_hdr(r : Result[(EbmlHeader, EbmlState, EbmlHeaderNotes), String]) -> String {
  match r {
    Err(e) => e
    Ok(_) => ""
  }
}

test "matroska: broken headers" {
  // empty stream: EOF
  assert_eq(matroska_read_ebml_header(pb_of(b"")).unwrap_err_hdr(), "EOF")
  // header without a trailing Segment: the one-element walk still succeeds
  // (the C's missing-segment failure happens later, in segment parsing)
  let no_seg = ebml_stream(b"matroska", false, b"")
  let (ns_ebml, _, _) = matroska_read_ebml_header(pb_of(no_seg)).unwrap()
  assert_eq(ns_ebml.doctype, "matroska")
  // an element exceeding the containing master
  let bad = bcat([b"\x1A\x45\xDF\xA3", vint1(2), el(b"\x42\xF7", b"\x01")])
  assert_eq(matroska_read_ebml_header(pb_of(bad)).unwrap_err_hdr(), "EINVAL")
  // a VOID and a CRC32 inside the header are skipped silently
  let children = bcat([
    b"\xEC",
    vint1(2),
    b"\x00\x00",
    b"\xBF",
    vint1(2),
    b"\x00\x00",
    el(b"\x42\x82", b"webm"),
  ])
  let stream = bcat([
    b"\x1A\x45\xDF\xA3",
    vint1(children.length()),
    children,
    b"\x18\x53\x80\x67",
  ])
  let (ebml, _, _) = matroska_read_ebml_header(pb_of(stream)).unwrap()
  assert_eq(ebml.doctype, "webm")
}

test "ebml: live mode treats EOF as the end of parsing" {
  let st = EbmlState::new_live(pb_of(b""))
  // ebml_parse on an empty live stream returns the stop code (1)
  let table : Array[EbmlSyntax] = [{ id: ebml_id_header, kind: Skip, sink: None }]
  assert_eq(ebml_parse(st, table, []), Ok(1))
}

test "ebml: zero-length master completes without children" {
  // A master of length 0: the level pops immediately, no payload read.
  let data = bcat([b"\x1A\x45\xDF\xA3", vint1(0), b"\x18\x53\x80\x67"])
  let (ebml, _, _) = matroska_read_ebml_header(pb_of(data)).unwrap()
  // all defaults (no children parsed)
  assert_eq(ebml.doctype, "(none)")
  assert_eq(ebml.doctype_version, 1UL)
  assert_eq(ebml.version, 1UL)
}
