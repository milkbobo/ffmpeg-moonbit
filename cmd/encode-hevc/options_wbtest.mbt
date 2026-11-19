///|
test "encode-hevc: defaults and happy paths" {
  let o = parse_options([
    "in.yuv", "--width", "64", "--height", "64", "--output", "out.265",
  ])
  assert_eq(o.width, 64)
  assert_eq(o.height, 64)
  assert_eq(o.qp, 26)
  assert_eq(o.crf, -1.0)
  assert_eq(o.bit_depth, 8)
  assert_eq(o.chroma_format, 1)
  assert_false(o.b_slices)
  assert_false(o.all_intra)
  assert_eq(raw_frame_size(o), 64 * 64 * 3 / 2)
  let b = parse_options([
    "in.yuv", "--width", "64", "--height", "64", "--output", "out.265", "--crf",
    "28.5", "--chroma", "422", "--bit-depth", "10", "--b-slices",
  ])
  assert_eq(b.crf, 28.5)
  assert_eq(b.chroma_format, 2)
  assert_eq(b.bit_depth, 10)
  assert_true(b.b_slices)
  // 10-bit 4:2:2: luma 64*64*2 bytes + chroma 32*64*2*2.
  assert_eq(raw_frame_size(b), 64 * 64 * 2 + 32 * 64 * 2 * 2)
}

///|
test "encode-hevc: rejections" {
  for
    bad in [
      ["in.yuv", "--width", "63", "--height", "64", "--output", "o"],
      ["in.yuv", "--width", "64", "--height", "64"],
      [
        "in.yuv", "--width", "64", "--height", "64", "--output", "o", "--crf", "52",
      ],
      [
        "in.yuv", "--width", "64", "--height", "64", "--output", "o", "--crf", "nan",
      ],
      [
        "in.yuv", "--width", "64", "--height", "64", "--output", "o", "--bit-depth",
        "9",
      ],
      [
        "in.yuv", "--width", "64", "--height", "64", "--output", "o", "--chroma",
        "411",
      ],
      [
        "in.yuv", "--width", "64", "--height", "64", "--output", "o", "--qp", "52",
      ],
      [
        "in.yuv", "--width", "64", "--height", "64", "--output", "o", "--nope", "1",
      ],
      ["in.yuv", "--width", "64", "--height", "64", "--output", "o", "--qp"],
      ["--width", "64", "--height", "64", "--output", "o"],
    ] {
    let args : Array[String] = bad
    let ok = try {
      ignore(parse_options(args))
      true
    } catch {
      _ => false
    }
    assert_false(ok, msg="expected rejection")
  }
}
