///|
/// Broadcast Wave `bext` chunk: the writer output is byte-identical to
/// ffmpeg 9.0.2 `wavenc.c` (`-write_bext 1` with the same metadata), and the
/// reader parses the chunk back.

///|
let wav_bext_ref_b64 : String = "YmV4dHQCAABUZXN0IGRlc2NyaXB0aW9uAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAT3JpZ2luYXRvcgAAAAAAAAAAAAAAAAAAAAAAAAAAAABSRUYwMDEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADIwMjYtMTAtMzExMjozNDo1NhXNWwcAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE9UENNLEY9NDgwMDAsVz0xNixNPW1vbm8A"

///|
fn wav_bext_test_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push((s[i].to_int() & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
test "wav bext: writer matches wavenc and reader round-trips" {
  let reference = @libavutil.av_base64_decode(
    wav_bext_test_bytes(wav_bext_ref_b64),
    10000,
  ).unwrap()
  let bext = @libavformat.WavBext::new(
    description="Test description",
    originator="Originator",
    originator_reference="REF001",
    origination_date="2026-10-31",
    origination_time="12:34:56",
    time_reference=123456789UL,
    coding_history="A=PCM,F=48000,W=16,M=mono",
  )
  let mux = @libavformat.wav_muxer_new(48000, 1, 16, bext=Some(bext)).unwrap()
  mux.write_samples([0, 1, -1][:])
  let file = mux.finish()
  // The bext chunk must appear byte-for-byte as ffmpeg writes it.
  let start = file.find(reference).unwrap()
  assert_eq(start > 0, true)
  let parsed = @libavformat.wav_read_bext(file).unwrap()
  assert_eq(parsed.description, "Test description")
  assert_eq(parsed.originator, "Originator")
  assert_eq(parsed.originator_reference, "REF001")
  assert_eq(parsed.origination_date, "2026-10-31")
  assert_eq(parsed.origination_time, "12:34:56")
  assert_eq(parsed.time_reference, 123456789UL)
  assert_eq(parsed.umid.length(), 64)
  assert_eq(parsed.coding_history, "A=PCM,F=48000,W=16,M=mono")
  // Files without bext return None.
  let plain = @libavformat.wav_muxer_new(48000, 1, 16).unwrap()
  plain.write_samples([0][:])
  assert_true(@libavformat.wav_read_bext(plain.finish()) is None)
}
