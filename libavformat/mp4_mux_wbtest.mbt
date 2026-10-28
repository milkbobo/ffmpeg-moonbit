///|
/// AAC-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
test "mp4 muxer: AAC samples round-trip through the demuxer" {
  let mux = mp4_aac_muxer_new(48000, 2).unwrap()
  mux.write_packet(b"\x00\x01\x02\x03").unwrap()
  mux.write_packet(b"\x04\x05\x06\x07\x08\x09").unwrap()
  mux.write_packet(b"\x0A\x0B").unwrap()
  let bytes = mux.finish()
  assert_eq(bytes[4:8].to_owned(), b"ftyp")
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.timescale, 48000U)
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "mp4a")
  assert_eq(track.codec_id, "aac")
  assert_eq(track.sample_rate, 48000U)
  assert_eq(track.channels, 2U)
  assert_eq(track.frame_length, 1024)
  assert_eq(track.extradata.unwrap(), Bytes::from_array([0x11, 0x90]))
  assert_eq(track.samples.length(), 3)
  let sizes : Array[Int32] = [4, 6, 2]
  let payloads : Array[Bytes] = [
    b"\x00\x01\x02\x03", b"\x04\x05\x06\x07\x08\x09", b"\x0A\x0B",
  ]
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.size, sizes[i].reinterpret_as_uint())
    assert_eq(sample.dts, (i * 1024).to_int64())
    assert_eq(sample.duration, 1024U)
    let start = sample.offset.to_int()
    assert_eq(
      bytes[start:start + sample.size.reinterpret_as_int()].to_owned(),
      payloads[i],
    )
  }
}

///|
test "mp4 muxer: invalid AAC parameters are rejected" {
  match mp4_aac_muxer_new(12345, 2) {
    Ok(_) => fail("unsupported sample rate must fail")
    Err(_) => ()
  }
  let mux = mp4_aac_muxer_new(44100, 1).unwrap()
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty packet must fail")
    Err(_) => ()
  }
}

///|
test "mp4 muxer: AAC priming is signalled via elst" {
  let mux = mp4_aac_muxer_new(44100, 1, priming=1024).unwrap()
  for _ in 0..<3 {
    mux.write_packet(b"\x00\x01").unwrap()
  }
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.timescale, 44100U)
  let track = movie.tracks[0]
  assert_eq(track.samples.length(), 3)
  // The edit starts one AAC frame into the media, so the demuxer trims the
  // encoder delay exactly like a real `movenc` file.
  assert_eq(track.skip_samples, 1024)
  let zero = mp4_aac_muxer_new(44100, 1).unwrap()
  zero.write_packet(b"\x00\x01").unwrap()
  assert_eq(av_mov_open(zero.finish()).unwrap().tracks[0].skip_samples, 0)
}

///|
test "mp4 muxer: negative AAC priming is rejected" {
  match mp4_aac_muxer_new(44100, 1, priming=-1) {
    Ok(_) => fail("negative priming must fail")
    Err(_) => ()
  }
}
