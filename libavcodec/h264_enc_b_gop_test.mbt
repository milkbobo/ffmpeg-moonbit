// TEMP probe: isolate the B-sequence failure plane.
///|
test "probe: b-seq skeleton I+P only (n=2, no B pictures)" {
  let frames = h264b_fixture(96, 64, 2)
  let s = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(x) => x
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(s, true) {
    Ok(f) => f
    Err(e) => fail("cavlc n=2: \{e}")
  }
  inspect(dec.length(), content="2")
}

///|
test "probe: first B picture (n=3)" {
  let frames = h264b_fixture(96, 64, 3)
  let s = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(x) => x
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(s, true) {
    Ok(f) => f
    Err(e) => fail("cavlc n=3: \{e}")
  }
  inspect(dec.length(), content="3")
}

///|
test "probe: cabac b-seq skeleton I+P only (n=2)" {
  let frames = h264b_fixture(96, 64, 2)
  let s = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(x) => x
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(s, true) {
    Ok(f) => f
    Err(e) => fail("cabac n=2: \{e}")
  }
  inspect(dec.length(), content="2")
}

///|
test "probe: cabac first B picture (n=3)" {
  let frames = h264b_fixture(96, 64, 3)
  let s = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(x) => x
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(s, true) {
    Ok(f) => f
    Err(e) => fail("cabac n=3: \{e}")
  }
  inspect(dec.length(), content="3")
}
