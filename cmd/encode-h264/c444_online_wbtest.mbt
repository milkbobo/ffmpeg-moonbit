///|
test "CLI 444 high depth: default B tools, periodic IDR and online VBV" {
  for bit_depth in [10, 14] {
    for cabac in [false, true] {
      for vbv in [false, true] {
        let args = [
          "input.yuv",
          "--width",
          "32",
          "--height",
          "32",
          "--chroma",
          "444",
          "--bit-depth",
          bit_depth.to_string(),
          "--keyint",
          "2",
          "--multi-ref",
          "3",
          "--aq",
          "--aud",
          "--output",
          "out.264",
        ]
        if cabac {
          args.push("--cabac")
        }
        if vbv {
          for
            arg in [
              "--vbv-maxrate", "320000", "--vbv-bufsize", "128000", "--fps", "25",
            ] {
            args.push(arg)
          }
        }
        let opts = parse_options(args)
        let bytes : Array[Byte] = []
        for f in 0..<6 {
          for p in 0..<3 {
            for i in 0..<1024 {
              let value = ((i % 32 * 2 + i / 32 * 3 + f * 7 + p * 40) & 255) <<
                (bit_depth - 8)
              bytes.push((value & 255).to_byte())
              bytes.push((value >> 8).to_byte())
            }
          }
        }
        let raw = Bytes::from_array(bytes[:])
        let (batch, count) = encode_raw(raw, opts)
        let (stream, streamed) = encode_raw_stream(raw, opts)
        assert_eq(count, 6)
        assert_eq(streamed, 6)
        if !vbv {
          assert_eq(batch, stream)
        }
        for encoded in [batch, stream] {
          let frames = match @codec.h264_decode_annexb_frames(encoded, true) {
            Ok(d) => d
            Err(e) => fail(e)
          }
          assert_eq(frames.length(), 6)
          for frame in frames {
            assert_eq(frame.bit_depth, bit_depth)
            assert_eq(frame.yuvp().length(), 32 * 32 * 3 * 2)
          }
        }
      }
    }
  }
}
