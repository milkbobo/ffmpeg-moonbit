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
///| `t.webm` first 1024 bytes (docker linuxserver/ffmpeg:9.0.2). */
let real_webm_1024_b64 : Bytes = b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQRChYECGFOAZwEAAAAAAFi7EU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggGkTbuMU6uEHFO7a1Osglik7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAj4AAAAAAABZUrmtAyK4BAAAAAAAATteBAXPFiHgM6wJaScOCnIEAIrWcg3VuZIiBAIaFVl9WUDiDgQEj44OEBfXhAOCQsIGAuoFgmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAK4BAAAAAAAAaNeBAnPFiCpgDhlwFQyMnIEAIrWcg3VuZIiBAIaGQV9PUFVTVqqDYy6gVruEBMS0AIOBAiPjg4QBMS0A4ZGfgQG1iEDncAAAAAAAYmSBEFXugQBjopNPcHVzSGVhZAEBOAGAuwAAAAAAElTDZ0DTc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz1WPAi2PFiHgM6wJaScOCZ8igRaOHRU5DT0RFUkSHk0xhdmM2My4xLjEwMiBsaWJ2cHhnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAxLjAwMDAwMDAwMABzc9ZjwItjxYgqYA4ZcBUMjGfIoUWjh0VOQ09ERVJEh5RMYXZjNjMuMS4xMDIgbGlib3B1c2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDEuMDA4MDAwMDAwAB9DtnUgViDngQCjQTeCAACA+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd39LwPHpVZOp8K2vCPACzadnLmqEqWlxlYe/1UguYnlg7XyEXXTvhpugsRLt0XENExu+Gf5j43FD/LoZj64uV354ZoWDQ5sULsHDT3qhl972vet88MoW20S3NkOBq5YGMkuTLjPM13UWAz0n5W695v5QGkX2bDnvFXiO85idfXibiZbXD9mz2tUgA/Zble337ycKIhz6S1bjohz6Us3ZAKXV3qkSp7WF7vTKsfgyOpUNcKxDj/bX4Y+5Ccak5+GYJzAGWQdlVf6+B9QgrXlfoG/7LdJWKTCpaN1u64isvLPkpE7rRaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOc4Sr8KDGTyQyJaNNzYEAAIBwPgCdASqAAA=="

///| `t.mkv` first 1024 bytes (docker linuxserver/ffmpeg:9.0.2). */
let real_mkv_1024_b64 : Bytes = b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAABBZBFNm3TAv4QQEj/HTbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIBhU27jFOrhBxTu2tTrIJBSOwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hPZ/HLMq17GDD0JATYCMTGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEuMTAyc6SQtHGem9JDvjNL4I1ffFAI+ESJiECPQAAAAAAAFlSua0CQv4TdJiGhrgEAAAAAAACB14EBc8WIp7TNIgI6LeKcgQAitZyDdW5kiIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEBfXhAOCQsIGAuoFgmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOipgFCwAr/4QAXZ0LACtoINsBEAAADAAQAAAMAUDxImoABAARozg/IElTDZ0CBv4SkUzYGc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz1mPAi2PFiKe0zSICOi3iZ8ihRaOHRU5DT0RFUkSHlExhdmM2My4xLjEwMiBsaWJ4MjY0Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMS4wMDAwMDAwMDAAH0O2dX82v4TJkcAA54EAo0/ogQAAgAAAAkYGBf//QtxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0zIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbg=="
