///|
test "h264 stream: visible chroma dimensions with macroblock padding" {
  for chroma_format in [1, 2, 3] {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=34,
        height=18,
        chroma_format~,
        b_slices=false,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let cw = if chroma_format == 3 { 34 } else { 17 }
    let ch = if chroma_format == 1 { 9 } else { 18 }
    let y = Bytes::from_array(Array::make(34 * 18, b'\x80')[:])
    let c = Bytes::from_array(Array::make(cw * ch, b'\x80')[:])
    for _ in 0..<2 {
      match enc.push_frame(y, c, c) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    }
    assert_eq(enc.recons[0].length(), 34 * 18 + 2 * cw * ch)
  }
}

///|
test "h264 stream c444: CAVLC I/P equals batch and reconstruction" {
  for multi_ref in [1, 3] {
    for aq in [false, true] {
      let frames = c444_fixture(4)
      let batch = match
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=3,
          b_slices=false,
          multi_ref~,
          aq~,
          aud=true,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=96,
          height=64,
          qp=24,
          chroma_format=3,
          b_slices=false,
          multi_ref~,
          aq~,
          aud=true,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for (y, u, v) in frames {
        match enc.push_frame(y, u, v) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        let ready = enc.drain()
        assert_eq(ready.length(), 1)
        aus.push(ready[0])
      }
      match enc.finish() {
        Ok(tail) => assert_eq(tail.length(), 0)
        Err(e) => fail(e)
      }
      let stream = h264s_concat(aus)
      assert_true(h264s_bytes_eq(stream, batch))
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 4)
      // Streaming reconstruction history contains inter pictures only.
      assert_eq(enc.recons.length(), 3)
      for i in 0..<3 {
        assert_eq(enc.recons[i].length(), 96 * 64 * 3)
        assert_true(h264s_bytes_eq(enc.recons[i], decoded[i + 1].yuvp()))
      }
    }
  }
}

///|
/// `§421` chain note: the 4:4:4 B-schedule refusals (b_parts / intra_in_b /
/// intra4x4_in_b / dct8x8) were lifted one tool per slice; with all four
/// landed the "unsupported schedules rejected at open" negative here is
/// obsolete and was removed. Positive coverage lives in the c444_b, bparts,
/// bi4/bi8/bi16, binter8 and online-depth stream tests.
test "h264 stream c444: short chroma rejected before state advances" {
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      chroma_format=3,
      b_slices=false,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let (y, u, v) = c444_fixture(1)[0]
  match enc.push_frame(y, b"", v) {
    Ok(_) => fail("empty chroma accepted")
    Err(_) => ()
  }
  assert_eq(enc.next_display, 0)
  match enc.push_frame(y, u, v) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  assert_eq(enc.drain().length(), 1)
}
