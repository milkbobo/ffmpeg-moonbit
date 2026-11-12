///|
test "CLI B pictures reach the batch encoder in both entropies" {
  for cabac in [false, true] {
    let opts = test_options(
      if cabac {
        ["--b-slices", "--cabac"]
      } else {
        ["--b-slices"]
      },
    )
    let raw = Bytes::make(384 * 3, 128)
    let (batch, _) = encode_raw(raw, opts)
    let (streamed, _) = encode_raw_stream(raw, opts)
    assert_eq(batch, streamed)
  }
}

///|
test "CLI CABAC RD streaming agrees with batch" {
  for b_slices in [false, true] {
    let opts = test_options([
      "--cabac", "--cabac-rd", "--stream", "--aq", "--aud",
    ])
    let opts = { ..opts, b_slices, }
    let raw = Bytes::make(384 * 3, 128)
    let (batch, count) = encode_raw(raw, opts)
    let (streamed, stream_count) = encode_raw_stream(raw, opts)
    assert_eq(stream_count, count)
    assert_eq(streamed, batch)
  }
}

///|
test "CLI rejects unsupported streaming and CABAC RD combinations" {
  for
    extra in [
      ["--cabac-rd"],
      ["--stream", "--target-bytes", "1000"],
      [
        "--stream", "--vbv-maxrate", "64000", "--vbv-bufsize", "32000", "--fps",
        "30",
      ],
      ["--cabac", "--cabac-rd", "--cabac-rd"],
    ] {
    try test_options(extra) catch {
      _ => ()
    } noraise {
      _ => fail("accepted unsupported options")
    }
  }
}

///|
fn test_options(extra : Array[String]) -> Options raise {
  let args = [
    "input.yuv", "--width", "16", "--height", "16", "--output", "out.264",
  ]
  for arg in extra {
    args.push(arg)
  }
  parse_options(args)
}

///|
test "CLI rejects malformed arguments before file access" {
  for
    extra in [
      ["--unknown"],
      ["--qp"],
      ["--qp", "abc"],
      ["--qp", "52"],
      ["--qp", "-1"],
      ["--aq-strength", "-1"],
      ["--aq-strength", "7"],
      ["--aq-strength", "abc"],
      ["--cabac", "--cabac"],
      ["--width", "18"],
      ["--target-bytes", "-1"],
      ["--fps", "30"],
      [
        "--vbv-maxrate", "64000", "--vbv-bufsize", "32000", "--fps", "30", "--target-bytes",
        "1000",
      ],
    ] {
    try test_options(extra) catch {
      _ => ()
    } noraise {
      _ => fail("accepted invalid arguments")
    }
  }
  for
    args in [
      [],
      ["in.yuv"],
      ["in.yuv", "--width", "3", "--height", "16", "--output", "out.264"],
      ["same", "--width", "16", "--height", "16", "--output", "same"],
    ] {
    try parse_options(args) catch {
      _ => ()
    } noraise {
      _ => fail("accepted incomplete options")
    }
  }
}

///|
test "CLI AQ strength parses and reaches encoder" {
  let opts = test_options(["--aq", "--aq-strength", "6"])
  assert_eq(opts.aq_strength, 6)
  assert_eq(opts.aq, true)
  assert_eq(test_options([]).aq_strength, 1)
  let (stream, _) = encode_raw(Bytes::make(384, 128), opts)
  assert_true(stream.length() > 0)
}

///|
test "CLI rejects empty or truncated raw frames" {
  let opts = test_options([])
  for data in [b"", Bytes::make(383, 0), Bytes::make(385, 0)] {
    try encode_raw(data, opts) catch {
      _ => ()
    } noraise {
      _ => fail("accepted partial frame")
    }
  }
}

///|
test "CLI non macroblock aligned geometry preserves visible planes" {
  let opts = parse_options([
    "input.yuv", "--width", "18", "--height", "18", "--output", "out.264",
  ])
  for cabac in [false, true] {
    let (stream, count) = encode_raw(Bytes::make(18 * 18 * 3 / 2, 128), {
      ..opts,
      cabac,
    })
    assert_eq(count, 1)
    let decoded = match @codec.h264_decode_annexb_frames(stream, false) {
      Ok(frames) => frames
      Err(e) => fail(e)
    }
    assert_eq(decoded[0].width, 18)
    assert_eq(decoded[0].height, 18)
    assert_eq(decoded[0].yuvp().length(), 486)
  }
}

///|
test "CLI multi-frame plane splitting and both entropy modes" {
  let raw : Array[Byte] = Array::make(384 * 3, 128)
  // Different Y and U/V values expose swapped planes or frame offsets.
  for f in 0..<3 {
    for i in 0..<256 {
      raw[f * 384 + i] = (40 + f * 20).to_byte()
    }
    for i in 256..<320 {
      raw[f * 384 + i] = 90
    }
    for i in 320..<384 {
      raw[f * 384 + i] = 170
    }
  }
  for
    extra in [
      [],
      ["--cabac"],
      ["--aq", "--aud"],
      [
        "--cabac", "--aud", "--vbv-maxrate", "64000", "--vbv-bufsize", "32000", "--fps",
        "30",
      ],
      ["--aud", "--target-bytes", "1000"],
    ] {
    let opts = test_options(extra)
    let (stream, count) = encode_raw(Bytes::from_array(raw[:]), opts)
    assert_eq(count, 3)
    let decoded = match @codec.h264_decode_annexb_frames(stream, false) {
      Ok(frames) => frames
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 3)
    for f in 0..<3 {
      let pixels = decoded[f].yuvp()
      // Quantisation permits a small luma/chroma error.
      assert_true((pixels[0].to_int() - (40 + f * 20)).abs() <= 3)
      assert_true((pixels[256].to_int() - 90).abs() <= 3)
      assert_true((pixels[320].to_int() - 170).abs() <= 3)
    }
  }
}

///|
test "CLI accepts stream and b-slices, rejects their bad combinations" {
  // Valid: stream alone, b-slices alone, both together.
  for
    extra in [
      ["--stream"],
      ["--b-slices"],
      ["--stream", "--b-slices"],
      ["--stream", "--cabac"],
    ] {
    try test_options(extra) catch {
      _ => fail("rejected valid arguments")
    } noraise {
      _ => ()
    }
  }
  // Invalid: b-slices with either rate control.
  for
    extra in [
      ["--b-slices", "--target-bytes", "1000"],
      [
        "--b-slices", "--vbv-maxrate", "64000", "--vbv-bufsize", "32000", "--fps",
        "30",
      ],
    ] {
    try test_options(extra) catch {
      _ => ()
    } noraise {
      _ => fail("accepted invalid arguments")
    }
  }
}

///|
test "CLI b-parts requires b-slices and reaches the batch and stream paths" {
  // Invalid: b-parts alone.
  try test_options(["--b-parts"]) catch {
    _ => ()
  } noraise {
    _ => fail("accepted b-parts without b-slices")
  }
  // Valid: with b-slices, batch and stream agree byte for byte.
  let opts = test_options(["--b-slices", "--b-parts"])
  assert_true(opts.b_parts)
  let raw = Bytes::make(384 * 3, 128)
  let (batch, count) = encode_raw(raw, opts)
  let (streamed, stream_count) = encode_raw_stream(raw, opts)
  assert_eq(stream_count, count)
  assert_eq(streamed, batch)
  // The flat fixture stays skip/direct dominated; a real exercise of the
  // partition kinds lives in the libavcodec bparts tests.
  assert_eq(batch.length() > 0, true)
}

///|
test "CLI dct8x8 reaches the batch and stream paths in both entropies" {
  let raw = Bytes::make(384 * 3, 128)
  for cabac in [false, true] {
    for b_slices in [false, true] {
      let extra : Array[String] = ["--dct8x8"]
      if cabac {
        extra.push("--cabac")
      }
      if b_slices {
        extra.push("--b-slices")
      }
      let opts = test_options(extra)
      assert_true(opts.dct8x8)
      let (batch, count) = encode_raw(raw, opts)
      let (streamed, stream_count) = encode_raw_stream(raw, opts)
      assert_eq(stream_count, count)
      assert_eq(streamed, batch)
      // The High profile SPS (profile_idc 100) must reach the stream:
      // start code (4 bytes), SPS NAL header, then profile_idc.
      assert_eq(batch[5], b'\x64')
    }
  }
  // Off by default: the Main/Baseline profile byte stays put.
  let plain = test_options([])
  assert_eq(plain.dct8x8, false)
}
