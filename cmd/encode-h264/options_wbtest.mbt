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
        "30", "--target-bytes", "1000",
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
    // 405: the defaults schedule B pictures; the decoder emits coding
    // order (I, P2, B1), so compare against the display-position source.
    let disp = [0, 2, 1]
    for f in 0..<3 {
      let pixels = decoded[f].yuvp()
      // Quantisation permits a small luma/chroma error.
      assert_true((pixels[0].to_int() - (40 + disp[f] * 20)).abs() <= 3)
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
  // Since §398 (B×VBV/ABR) b-slices combines with both rate controls.
  for
    extra in [
      ["--b-slices", "--target-bytes", "1000"],
      [
        "--b-slices", "--vbv-maxrate", "64000", "--vbv-bufsize", "32000", "--fps",
        "30",
      ],
    ] {
    try test_options(extra) catch {
      _ => fail("rejected valid b-slices x rate-control arguments")
    } noraise {
      _ => ()
    }
  }
  // Invalid: streaming ABR and mixed ABR/VBV are unsupported.
  for
    extra in [
      ["--stream", "--target-bytes", "1000"],
      [
        "--stream", "--vbv-maxrate", "64000", "--vbv-bufsize", "32000", "--fps",
        "30", "--target-bytes", "1000",
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
  // Invalid: b-parts with the explicit slices opt-out (§405: with the
  // defaults both are on, so only the explicit conflict is rejected).
  try test_options(["--b-parts", "--no-b-slices"]) catch {
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
  // 405: dct8x8 defaults on (High profile byte); the explicit opt-out
  // keeps the Main/Baseline profile byte.
  let plain = test_options([])
  assert_eq(plain.dct8x8, true)
  let off = test_options(["--no-dct8x8"])
  assert_eq(off.dct8x8, false)
}

///|
/// One 9/10-bit leg of the CLI bit-depth test: parse, batch-encode, stream
/// and round-trip decode at depth `bd`.
fn bit_depth_leg(bd : Int32) -> Unit raise {
  let opts = test_options(["--bit-depth", "\{bd}", "--cabac"])
  assert_eq(opts.bit_depth, bd)
  assert_eq(@codec.video_pixel_format(bd), "yuv420p\{bd}le")
  assert_eq(raw_frame_size(opts), 768)
  // Distinct luma/chroma patterns in the low byte of each 16-bit sample
  // (samples stay under 512, so 9-bit accepts them too).
  let buf : Array[Byte] = []
  for i in 0..<(768 * 2) {
    buf.push(if i % 2 == 0 { (64 + i % 97).to_byte() } else { b'\x00' })
  }
  let raw = Bytes::from_array(buf[:])
  let (batch, count) = encode_raw(raw, opts)
  assert_eq(count, 2)
  let (streamed, _) = encode_raw_stream(raw, opts)
  assert_eq(streamed, batch)
  // High 10 (110) through 10 bits, Hi444PP (244) above (`§419`).
  assert_eq(batch[5], if bd > 10 { b'\xf4' } else { b'\x6e' })
  let decoded = match @codec.h264_decode_annexb_frames(batch, false) {
    Ok(frames) => frames
    Err(e) => fail(e)
  }
  for f in decoded {
    assert_eq(f.bit_depth, bd)
  }
  // A truncated (8-bit-sized) input must be rejected, not mis-decoded.
  try encode_raw(Bytes::make(384, 0), opts) catch {
    _ => ()
  } noraise {
    _ => fail("accepted an 8-bit-sized frame at bit-depth \{bd}")
  }
}

///|
test "CLI bit-depth parses, reaches both paths, rejects bad depths" {
  // Invalid depths are rejected before any encoding.
  for bad in ["7", "11", "0", "abc"] {
    try test_options(["--bit-depth", bad]) catch {
      _ => ()
    } noraise {
      _ => fail("accepted --bit-depth \{bad}")
    }
  }
  // Default stays 8-bit with the plain yuv420p naming.
  let plain = test_options([])
  assert_eq(plain.bit_depth, 8)
  assert_eq(@codec.video_pixel_format(plain.bit_depth), "yuv420p")
  assert_eq(raw_frame_size(plain), 384)
  // 16-bit LE samples double the frame size, the stream encoder matches
  // the batch entry byte for byte, the SPS carries profile_idc 110 and the
  // decoder round-trips at the configured depth.
  bit_depth_leg(9)
  bit_depth_leg(10)
  // `§419`: 12/14-bit legs reach both paths with Hi444PP (244) parameter
  // sets; 13 stays in the rejected list above (the reference decoder
  // PATCHWELCOMEs it).
  bit_depth_leg(12)
  bit_depth_leg(14)
}

///|
/// In-memory streaming oracle: feed the same configuration to
/// `H264StreamEncoder` one frame at a time and collect its access units.
/// This isolates the encoder's streaming contract from host file I/O; the
/// CLI's `--stream` path uses `encode_stream_file` instead.
fn encode_raw_stream(data : Bytes, opts : Options) -> (Bytes, Int32) raise {
  let bpp = sample_bytes(opts.bit_depth)
  let luma = opts.width * opts.height * bpp
  let chroma = if opts.chroma_format == 2 {
    opts.width / 2 * opts.height * bpp
  } else {
    opts.width * opts.height / 4 * bpp
  }
  let frame_size = raw_frame_size(opts)
  if data.length() == 0 || data.length() % frame_size != 0 {
    fail(
      "encode-h264: input must contain complete \{@codec.video_pixel_format(opts.bit_depth, chroma_format~=opts.chroma_format)} frames (\{frame_size} bytes each)",
    )
  }
  let enc = open_stream_encoder(opts)
  let aus : Array[Bytes] = []
  let mut count = 0
  for offset = 0; offset < data.length(); offset = offset + frame_size {
    let (y, u, v) = frame_planes(data, offset, luma, chroma)
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail("encode-h264: \{e}")
    }
    for au in enc.drain() {
      aus.push(au)
    }
    count = count + 1
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail("encode-h264: \{e}")
  }
  let out : Array[Byte] = []
  for au in aus {
    for i = 0; i < au.length(); i = i + 1 {
      out.push(au[i])
    }
  }
  (Bytes::from_array(out[:]), count)
}

///|
test "CLI codec flag selects the facade codec" {
  // Default and explicit h264 agree; unknown codecs are rejected.
  assert_eq(test_options([]).codec.name(), "h264")
  assert_eq(test_options(["--codec", "h264"]).codec.name(), "h264")
  try test_options(["--codec", "hevc"]) catch {
    _ => ()
  } noraise {
    _ => fail("accepted an unimplemented codec")
  }
  // The codec rides the facade: an explicitly selected h264 encodes
  // through video_encode byte-identically to the default path.
  let opts = test_options(["--codec", "h264", "--b-slices"])
  let raw = Bytes::make(384 * 2, 128)
  let (batch, count) = encode_raw(raw, opts)
  let (streamed, stream_count) = encode_raw_stream(raw, opts)
  assert_eq(count, stream_count)
  assert_eq(batch, streamed)
}

///|
test "CLI multi-ref parses and reaches the facade" {
  // Default is the single-reference stream.
  assert_eq(test_options([]).multi_ref, 1)
  let opts = test_options(["--multi-ref", "2", "--no-b-slices", "--no-weightp"])
  assert_eq(opts.multi_ref, 2)
  // The facade rejects the B-slice combination; the CLI passes the depth
  // through untouched.
  assert_true(opts.b_slices == false)
  // A multi-reference encode decodes cleanly end to end.
  let raw = Bytes::make(384 * 3, 128)
  let (stream, count) = encode_raw(raw, opts)
  assert_eq(count, 3)
  let dec = match @codec.h264_decode_annexb_frames(stream, false) {
    Ok(frames) => frames
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 3)
}

///|
test "CLI periodic keyint agrees in batch and streaming modes" {
  assert_eq(test_options([]).keyint, 0)
  for cabac in [false, true] {
    let args = ["--no-b-slices", "--keyint", "2", "--multi-ref", "3"]
    if cabac {
      args.push("--cabac")
    }
    let opts = test_options(args)
    assert_eq(opts.keyint, 2)
    let raw = Bytes::make(384 * 5, 128)
    let (batch, count) = encode_raw(raw, opts)
    let (streamed, stream_count) = encode_raw_stream(raw, opts)
    assert_eq(count, 5)
    assert_eq(stream_count, 5)
    assert_eq(batch, streamed)
    let mut idrs = 0
    for i in 0..<(batch.length() - 4) {
      if batch[i] == 0 &&
        batch[i + 1] == 0 &&
        batch[i + 2] == 0 &&
        batch[i + 3] == 1 &&
        (batch[i + 4].to_int() & 31) == 5 {
        idrs += 1
      }
    }
    assert_eq(idrs, 3)
    let decoded = match @codec.h264_decode_annexb_frames(batch, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 5)
  }
  for
    args in [
      ["--keyint", "-1"],
      ["--keyint", "2", "--target-bytes", "1000", "--stream"],
      ["--keyint", "2", "--no-b-slices", "--stream", "--target-bytes", "1000"],
    ] {
    try test_options(args) catch {
      _ => ()
    } noraise {
      _ => fail("invalid keyint accepted")
    }
  }
}

///|
test "CLI periodic keyint accepts a batch byte budget" {
  let opts = test_options([
    "--keyint", "2", "--no-b-slices", "--target-bytes", "1000", "--multi-ref", "3",
  ])
  let (stream, count) = encode_raw(Bytes::make(384 * 5, 128), opts)
  assert_eq(count, 5)
  assert_true(stream.length() <= 1000)
  let decoded = match @codec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(decoded.length(), 5)
}

///|
test "CLI periodic B GOPs agree in batch and streaming modes" {
  for cabac in [false, true] {
    for keyint in [1, 3, 4] {
      let args = ["--keyint", keyint.to_string(), "--aq", "--aud"]
      if cabac {
        args.push("--cabac")
      }
      let opts = test_options(args)
      let raw = Bytes::make(384 * 9, 128)
      let (batch, count) = encode_raw(raw, opts)
      let (streamed, stream_count) = encode_raw_stream(raw, opts)
      assert_eq(count, 9)
      assert_eq(stream_count, 9)
      assert_eq(batch, streamed)
      let decoded = match
        @codec.h264_decode_annexb_display_frames(batch, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 9)
    }
  }
  for
    args in [
      ["--keyint", "3", "--target-bytes", "1000", "--stream"],
      [
        "--keyint", "3", "--vbv-maxrate", "64000", "--vbv-bufsize", "8000", "--fps",
        "25", "--stream", "--target-bytes", "1000",
      ],
    ] {
    try test_options(args) catch {
      _ => ()
    } noraise {
      _ => fail("periodic B rate controls accepted")
    }
  }
}

///|
test "CLI periodic P VBV agrees in batch and streaming modes" {
  for cabac in [false, true] {
    let args = [
      "--keyint", "2", "--no-b-slices", "--vbv-maxrate", "64000", "--vbv-bufsize",
      "8000", "--fps", "25", "--aud",
    ]
    if cabac {
      args.push("--cabac")
    }
    let opts = test_options(args)
    let (stream, count) = encode_raw(Bytes::make(384 * 5, 128), opts)
    assert_eq(count, 5)
    let decoded = match @codec.h264_decode_annexb_frames(stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 5)
    args.push("--stream")
    let stream_opts = test_options(args)
    let (online, online_count) = encode_raw_stream(
      Bytes::make(384 * 5, 128),
      stream_opts,
    )
    assert_eq(online_count, 5)
    assert_eq(online, stream)
  }
}

///|
test "CLI periodic B GOPs accept a whole-sequence batch budget" {
  for cabac in [false, true] {
    let args = ["--keyint", "3", "--target-bytes", "1000", "--aq", "--aud"]
    if cabac {
      args.push("--cabac")
    }
    let opts = test_options(args)
    let (stream, count) = encode_raw(Bytes::make(384 * 7, 128), opts)
    assert_eq(count, 7)
    assert_true(stream.length() <= 1000)
    let decoded = match
      @codec.h264_decode_annexb_display_frames(stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 7)
  }
}

///|
test "CLI periodic B GOPs accept continuous batch VBV" {
  for cabac in [false, true] {
    for keyint in [1, 3, 4] {
      let args = [
        "--keyint",
        keyint.to_string(),
        "--vbv-maxrate",
        "64000",
        "--vbv-bufsize",
        "8000",
        "--fps",
        "25",
        "--aud",
      ]
      if cabac {
        args.push("--cabac")
      }
      let opts = test_options(args)
      let (stream, count) = encode_raw(Bytes::make(384 * 8, 128), opts)
      assert_eq(count, 8)
      let decoded = match
        @codec.h264_decode_annexb_display_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 8)
      args.push("--stream")
      let online_opts = test_options(args)
      let (online, online_count) = encode_raw_stream(
        Bytes::make(384 * 8, 128),
        online_opts,
      )
      assert_eq(online_count, 8)
      let online_decoded = match
        @codec.h264_decode_annexb_display_frames(online, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(online_decoded.length(), 8)
    }
  }
}

///|
/// §420: the CLI carries the chroma format end to end — `--chroma 422`
/// parses, sizes the raw input as 4:2:2 and round-trips through the decoder.
test "CLI chroma 422 option round trip" {
  let opts = parse_options([
    "input.yuv", "--width", "32", "--height", "16", "--chroma", "422", "--no-b-slices",
    "--output", "out.264",
  ])
  assert_eq(opts.chroma_format, 2)
  let frame_size = raw_frame_size(opts)
  assert_eq(frame_size, 32 * 16 * 2)
  let data = Bytes::make(frame_size * 2, 100)
  for cabac in [false, true] {
    let (stream, count) = encode_raw(data, { ..opts, cabac, })
    assert_eq(count, 2)
    let decoded = match @codec.h264_decode_annexb_frames(stream, false) {
      Ok(frames) => frames
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 2)
    assert_eq(decoded[0].width, 32)
    assert_eq(decoded[0].height, 16)
    assert_eq(decoded[0].yuvp().length(), 32 * 16 * 2)
  }
  try
    ignore(
      parse_options([
        "input.yuv", "--width", "32", "--height", "16", "--chroma", "440", "--output",
        "out.264",
      ]),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("--chroma 440 accepted")
  }
}

///|
/// §421: the CLI carries 4:4:4 end to end (single IDR — the inter paths are
/// the next slice).
test "CLI chroma 444 option round trip" {
  let opts = parse_options([
    "input.yuv", "--width", "32", "--height", "16", "--chroma", "444", "--output",
    "out.264",
  ])
  assert_eq(opts.chroma_format, 3)
  let frame_size = raw_frame_size(opts)
  assert_eq(frame_size, 32 * 16 * 3)
  let data = Bytes::make(frame_size, 100)
  let (stream, count) = encode_raw(data, opts)
  assert_eq(count, 1)
  let decoded = match @codec.h264_decode_annexb_frames(stream, false) {
    Ok(frames) => frames
    Err(e) => fail(e)
  }
  assert_eq(decoded.length(), 1)
  assert_eq(decoded[0].width, 32)
  assert_eq(decoded[0].height, 16)
  assert_eq(decoded[0].yuvp().length(), 32 * 16 * 3)
}
