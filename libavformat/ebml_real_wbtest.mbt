///|
/// Real-file cross-validation for the EBML header slice.
///
/// Files generated with docker `linuxserver/ffmpeg:9.0.2`
/// (`-f lavfi testsrc2+sine`, libvpx+libopus → webm, libx264+aac → mkv);
/// the first 64 bytes carry the complete EBML header plus the start of the
/// Segment element (unknown-length, `01 00…`), which is everything this
/// slice reads. Expected values match `ffprobe`'s EBML header dump.

///| `t.webm` header region (22763-byte file). */
let real_webm_head_b64 : Bytes = b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQRChYECGFOAZwEAAAAAAFi7EU2bdLpNu4tTq4QVSalmUw=="

///| `t.mkv` header region (16792-byte file). */
let real_mkv_head_b64 : Bytes = b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAABBZBFNm3TAv4QQEj/HTQ=="

test "matroska: real webm EBML header (docker ffmpeg)" {
  let bytes = @libavutil.av_base64_decode(real_webm_head_b64, 100).unwrap()
  let (ebml, st, notes) = matroska_read_ebml_header(AvioContext::init_read_context(bytes)).unwrap()
  // 42F7=1, 42F2=4, 42F3=8, 4282="webm", 4285=2 (4287 DocTypeVersion 4 skipped)
  assert_eq(ebml.version, 1UL)
  assert_eq(ebml.id_length, 4UL)
  assert_eq(ebml.max_size, 8UL)
  assert_eq(ebml.doctype, "webm")
  assert_eq(ebml.doctype_version, 2UL)
  assert_eq(notes.supported_doctype, true)
  assert_eq(notes.uses_unsupported_features, false)
  // The next element is the Segment (unknown length); a second walk over
  // the same syntax table hits EBML_STOP with the Segment id in hand.
  assert_eq(ebml_parse(st, ebml_syntax_table(ebml), []), Ok(1))
  assert_eq(st.current_id, matroska_id_segment)
}

test "matroska: real mkv EBML header (docker ffmpeg)" {
  let bytes = @libavutil.av_base64_decode(real_mkv_head_b64, 100).unwrap()
  let (ebml, st, notes) = matroska_read_ebml_header(AvioContext::init_read_context(bytes)).unwrap()
  assert_eq(ebml.version, 1UL)
  assert_eq(ebml.id_length, 4UL)
  assert_eq(ebml.max_size, 8UL)
  assert_eq(ebml.doctype, "matroska")
  assert_eq(ebml.doctype_version, 2UL)
  assert_eq(notes.supported_doctype, true)
  assert_eq(ebml_parse(st, ebml_syntax_table(ebml), []), Ok(1))
  assert_eq(st.current_id, matroska_id_segment)
}
