///|
test "opus CELT: mono/stereo silence at all four frame lengths" {
  for channels in [1, 2] {
    let decoder = @libavcodec.OpusCeltDecoder::new(channels).unwrap()
    for samples in [120, 240, 480, 960, 120] {
      let pcm = decoder.decode_frame(b"\xff\xfe", samples, 13).unwrap()
      assert_eq(pcm, [ for _ in 0..<channels => Array::make(samples, 0.0) ])
    }
    decoder.reset()
    assert_eq(
      decoder.decode_frame(b"\xff\xfe", 120, 21).unwrap(),
      [
        for _ in 0..<channels => Array::make(120, 0.0)
      ],
    )
  }
}

///|
test "opus CELT: reject invalid output channels and bandwidth" {
  for channels in [0, 3, -1] {
    assert_true(
      @libavcodec.OpusCeltDecoder::new(channels)
      is Err("opus: invalid CELT output channels"),
    )
  }
  let decoder = @libavcodec.OpusCeltDecoder::new(1).unwrap()
  assert_true(
    decoder.decode_frame(b"\xff\xfe", 120, 20)
    is Err("opus: invalid CELT bandwidth"),
  )
  assert_true(decoder.decode_frame(b"", 120, 13) is Err(_))
  assert_true(decoder.decode_frame(b"\xff\xfe", 119, 13) is Err(_))
}
