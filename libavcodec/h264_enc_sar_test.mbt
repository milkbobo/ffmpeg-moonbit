///|
/// `§426` fixtures: reuse the blocky-gradient deblock fixture so the IDR
/// stream is representative, with a tiny 2-frame cut for the batch entry.
fn h264sar_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  h264dbg_fixture(64, 48, n, 1)
}

///|
/// `§426`: the sample aspect ratio rides the SPS VUI as Extended_SAR and
/// the pure decoder hands it back on every frame. The default (0/0) keeps
/// the VUI byte-identical to the pre-`§426` streams (no aspect-ratio
/// fields at all).
test "h264 sar: aspect ratio rides the SPS VUI and round trips" {
  let frames = h264sar_fixture(3)
  fn encode_with(sar : (Int32, Int32)) -> Bytes raise {
    match
      @libavcodec.h264_encode_frames(frames, width=64, height=48, qp=26, sar~) {
      Ok(s) => s
      Err(e) => fail(e)
    }
  }
  // Non-square pixels (PAL DV 16:11): gcd-normalised Extended_SAR.
  let wide = encode_with((16, 11))
  let decoded = match @libavcodec.h264_decode_annexb_frames(wide, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(decoded.length(), 3)
  for f in decoded {
    assert_eq(f.vui.sar_num, 16, msg="wide sar_num")
    assert_eq(f.vui.sar_den, 11, msg="wide sar_den")
  }
  // Explicit square pixels.
  let square = encode_with((64, 48))
  let sdecoded = match @libavcodec.h264_decode_annexb_frames(square, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  // 64/48 normalises to 4/3.
  for f in sdecoded {
    assert_eq(f.vui.sar_num, 4, msg="normalised sar_num")
    assert_eq(f.vui.sar_den, 3, msg="normalised sar_den")
  }
  // Default: no aspect-ratio VUI (the decoder's unspecified 0/1), and the
  // streams differ because the SPS differs.
  let plain = encode_with((0, 0))
  let pdecoded = match @libavcodec.h264_decode_annexb_frames(plain, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  for f in pdecoded {
    assert_eq(f.vui.sar_num, 0, msg="unset sar_num")
    assert_eq(f.vui.sar_den, 1, msg="unset sar_den")
  }
  assert_true(wide.length() != plain.length(), msg="VUI changed the stream")
  assert_true(
    square.length() != plain.length(),
    msg="square changed the stream",
  )
}

///|
/// `§426` residuals (fixed with `§427`): the CABAC batch entry's B-line
/// dispatch and the streaming encoder's IDR both dropped `sar` — the SPS
/// they emit must carry the VUI like every other entry point.
test "h264 sar: CABAC batch and streaming IDRs carry the VUI" {
  let frames = h264sar_fixture(3)
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      sar=(16, 11),
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let cdecoded = match @libavcodec.h264_decode_annexb_frames(cabac, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  for f in cdecoded {
    assert_eq(f.vui.sar_num, 16, msg="cabac sar_num")
    assert_eq(f.vui.sar_den, 11, msg="cabac sar_den")
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=48,
      qp=26,
      sar=(16, 11),
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = match enc.finish() {
    Ok(t) => t
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      joined.push(part[i])
    }
  }
  let sdecoded = match
    @libavcodec.h264_decode_annexb_frames(Bytes::from_array(joined[:]), false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(sdecoded.length(), 3, msg="stream frame count")
  for f in sdecoded {
    assert_eq(f.vui.sar_num, 16, msg="stream sar_num")
    assert_eq(f.vui.sar_den, 11, msg="stream sar_den")
  }
}
