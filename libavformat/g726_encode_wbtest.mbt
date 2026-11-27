///|
test "G.726 encoder matches FFmpeg at every code width in both bit orders" {
  let pcm = [
    0, 12507, 21188, 23443, 18732, 8746, -3137, -12931, -17328, -14753, -5873, 6616,
    18854, 27055, 28718, 23431,
  ]
  let wav = wav_muxer_new(8000, 1, 16).unwrap()
  wav.write_samples(pcm[:])
  let audio = decode_audio_file(wav.finish())
  for
    (bits, msb, lsb) in [
      (2, b"\x15\x5a\xa9\x55", b"\x54\xa5\x6a\x55"),
      (3, b"\xed\xb6\xe4\x92\x36\xdb", b"\xdf\xb6\x91\x24\xb7\x6d"),
      (
        4, b"\xf7\x77\x77\x88\x88\xb5\x75\x54", b"\x7f\x77\x77\x88\x88\x5b\x57\x45",
      ),
      (
        5, b"\xfb\xde\xf7\xbe\x10\x84\x20\xd7\xb5\x48", b"\xff\xbd\xf7\x1e\x84\x10\xc2\xf6\x9a\x42",
      ),
    ] {
    assert_eq(audio.to_g726(bits), msb)
    assert_eq(audio.to_g726(bits, little_endian=true), lsb)
  }
}

///|
test "G.726 encoder flushes remaining bits without adding codewords" {
  let pcm = [0]
  assert_eq(@libavcodec.encode_g726(pcm[:], 3).unwrap(), b"\xe0")
  assert_eq(
    @libavcodec.encode_g726(pcm[:], 3, little_endian=true).unwrap(),
    b"\x07",
  )
  assert_true(@libavcodec.encode_g726(pcm[:], 6) is Err(_))
}
