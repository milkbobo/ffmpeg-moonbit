///|
test "x264 options: nested parameters preserve GOP and B-frame settings" {
  let frames = x264_fixture(6, 96, 64, 1)
  let (_, direct) = x264_run(
    frames,
    [("preset", "medium"), ("qp", "20"), ("g", "2"), ("bf", "0")],
    Yuv420p,
    false,
    0,
  )
  assert_eq(direct.length(), 6)
  for
    params in [
      "keyint=2:bframes=0", "keyint='2':bframes='0'", "keyint=\\2:bframes=\\0", "keyint= 2 :bframes= 0 ",
    ] {
    let (_, nested) = x264_run(
      frames,
      [("preset", "medium"), ("qp", "20"), ("x264-params", params)],
      Yuv420p,
      false,
      0,
    )
    assert_eq(nested.length(), 6)
    for i in 0..<6 {
      assert_eq(nested[i].pts, Some(i.to_int64()))
      assert_true(
        nested[i].data == direct[i].data,
        msg="nested option changed packet \{i}: \{params}",
      )
      assert_eq(nested[i].keyframe, i % 2 == 0)
    }
  }
}

///|
test "x264 options: rejects empty tokens and embedded NUL" {
  let nul = (0).unsafe_to_char().to_string()
  for
    options in [
      [("", "20")],
      [("qp", "")],
      [("qp" + nul + "bf", "20")],
      [("qp", "20" + nul + ":bf=0")],
    ] {
    try X264Encoder::open(width=32, height=16, options~) catch {
      EncoderUnavailable(message) =>
        assert_true(message.contains("nonempty and contain no NUL"))
      _ => fail("unexpected error")
    } noraise {
      enc => {
        enc.close()
        fail("invalid option accepted")
      }
    }
  }
}

///|
test "x264 options: malformed raw dictionary releases partially parsed entries" {
  // The safe wrapper never creates this string; exercise the C failure path.
  for _ in 0..<8 {
    let handle = x264enc_open_ffi(
      b"libx264", 32, 16, 0, 1, 25, 25, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, b"preset=medium:broken",
    )
    assert_eq(x264enc_status_ffi(handle), 1)
    assert_true(x264enc_errmsg_ffi(handle) is Some(_))
    x264enc_close_ffi(handle)
  }
}
