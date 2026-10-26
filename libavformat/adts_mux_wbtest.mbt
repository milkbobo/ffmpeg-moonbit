///|
/// ADTS muxer tests: emitted frames are parsed back by `av_adts_open`.

///|
test "adts muxer: headers and frames round-trip" {
  let mux = adts_muxer_new(48000, 2, object_type=2).unwrap()
  mux.write_frame(b"\x01\x02\x03").unwrap()
  mux.write_frame(b"\x04\x05").unwrap()
  let bytes = mux.finish()
  assert_eq(bytes.length(), 19)
  assert_eq(bytes[0], b'\xFF')
  assert_eq(bytes[1], b'\xF1')
  let track = av_adts_open(bytes).unwrap()
  assert_eq(track.codec, "aac")
  assert_eq(track.profile, "LC")
  assert_eq(track.sample_rate, 48000)
  assert_eq(track.channels, 2)
  assert_eq(track.frame_size, 1024)
  assert_eq(track.frames.length(), 2)
  assert_eq(track.frames[0].size, 10)
  assert_eq(track.frames[1].size, 9)
  assert_eq(track.total_samples, 2048L)
  assert_eq(bytes[7:10].to_owned(), b"\x01\x02\x03")
  assert_eq(bytes[17:19].to_owned(), b"\x04\x05")
}

///|
test "adts muxer: unsupported rate and oversized payload fail" {
  match adts_muxer_new(12345, 2) {
    Ok(m) =>
      match m.write_frame(b"x") {
        Ok(_) => fail("unsupported sample rate must fail")
        Err(_) => ()
      }
    Err(_) => ()
  }
  let mux = adts_muxer_new(44100, 1).unwrap()
  let big = Bytes::new(8185)
  match mux.write_frame(big) {
    Ok(_) => fail("ADTS frame length overflow must fail")
    Err(_) => ()
  }
}
