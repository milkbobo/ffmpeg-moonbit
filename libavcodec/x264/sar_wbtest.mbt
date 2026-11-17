// §425 binding slice: sample aspect ratio. `sar` rides libx264.c's open
// path (av_reduce into the SPS VUI aspect-ratio fields); the pure decoder
// hands the parsed VUI back on every frame (`H264Frame.vui.sar_num/den`),
// which makes the round trip directly assertable.

///|
fn x264_sar_fixture(n : Int32) -> Array[(Int64, Bytes, Bytes, Bytes)] {
  ptf_fixture(n, 32, 16)
}

///|
test "x264 sar: aspect ratio rides the SPS VUI and round trips" {
  let frames = x264_sar_fixture(2)
  fn encode_with(sar : (Int32, Int32)) -> Bytes raise {
    let enc = X264Encoder::open(
      width=32,
      height=16,
      global_header=false,
      sar~,
      options=[
        ("preset", "ultrafast"),
        ("x264-params", "keyint=250:min-keyint=250:scenecut=0:bframes=0"),
      ],
    )
    let packets = enc.encode_all(frames)
    enc.close()
    x264_concat(packets)
  }
  // Non-square pixels (PAL DV 16:11): the VUI carries the fraction.
  let wide = encode_with((16, 11))
  let probe = match x264_probe_frames(wide) {
    Ok(p) => p
    Err(e) => fail(e)
  }
  assert_eq(probe.errors, 0)
  assert_eq(probe.warnings, 0)
  let decoded = match
    @libavcodec.h264_decode_annexb_display_frames(wide, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  for f in decoded {
    assert_eq(f.vui.sar_num, 16, msg="wide sar_num")
    assert_eq(f.vui.sar_den, 11, msg="wide sar_den")
  }
  // Explicit square pixels: aspect_ratio_idc 1.
  let square = encode_with((1, 1))
  let sdecoded = match
    @libavcodec.h264_decode_annexb_display_frames(square, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  for f in sdecoded {
    assert_eq(f.vui.sar_num, 1, msg="square sar_num")
    assert_eq(f.vui.sar_den, 1, msg="square sar_den")
  }
  // Default: no aspect-ratio VUI — the decoder's unspecified fraction is
  // 0/1 (C vui.sar's default), and the streams differ because the SPS
  // differs.
  let plain = encode_with((0, 0))
  let pdecoded = match
    @libavcodec.h264_decode_annexb_display_frames(plain, false) {
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
