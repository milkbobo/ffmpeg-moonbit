///|
test "x264 binding: 422 and 444 input planes round trip" {
  for
    (fmt, cf) in [
      (Yuv422p, 2),
      (Yuv422p10le, 2),
      (Yuv444p, 3),
      (Yuv444p10le, 3),
    ] {
    assert_true(x264_supports("libx264", fmt))
    let bps = fmt.bytes_per_sample()
    let width = if cf == 3 { 35 } else { 34 }
    let height = 19
    let cw = if cf == 3 { width } else { width / 2 }
    let enc = X264Encoder::open(
      width~,
      height~,
      pix_fmt=fmt,
      global_header=false,
      options=[("preset", "medium"), ("qp", "20"), ("bf", "0")],
    )
    let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
    for f in 0..<3 {
      fn plane(n : Int32, seed : Int32, bps : Int32) -> Bytes {
        Bytes::makei(n * bps, i => {
          let sample = (i / bps * 37 + seed * 53) %
            256 *
            (if bps == 2 { 4 } else { 1 })
          (if bps == 2 && i % 2 == 1 { sample >> 8 } else { sample & 255 }).to_byte()
        })
      }
      frames.push(
        (
          f.to_int64(),
          plane(width * height, f, bps),
          plane(cw * height, f + 1, bps),
          plane(cw * height, f + 2, bps),
        ),
      )
    }
    // Old 420-sized chroma must fail before copying from borrowed buffers.
    try
      enc.send_frame(
        pts=0L,
        y=frames[0].1,
        u=Bytes::new(17 * 9 * bps),
        v=frames[0].3,
      )
    catch {
      SendFailed(_) => ()
      _ => fail("unexpected error variant")
    } noraise {
      _ => fail("short chroma accepted")
    }
    let packets = enc.encode_all(frames)
    enc.close()
    enc.close()
    let mut stream = b""
    for p in packets {
      stream = stream + p.data
    }
    let oracle = match x264_probe_frames(stream) {
      Ok(p) => p
      Err(e) => fail(e)
    }
    assert_eq(oracle.n_frames, 3)
    assert_eq(oracle.width, width)
    assert_eq(oracle.height, height)
    assert_eq(oracle.warnings, 0)
    assert_eq(oracle.errors, 0)
    let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 3)
    let packed = match x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(packed.n_frames, 3)
    assert_eq(packed.bytes_per_sample(), bps)
    assert_eq(
      packed.kind,
      if cf == 2 {
        if bps == 1 {
          3
        } else {
          4
        }
      } else if bps == 1 {
        5
      } else {
        6
      },
    )
    for i in 0..<3 {
      assert_eq(packed.frame_y(i).length(), width * height * bps)
      assert_eq(packed.frame_u(i).length(), cw * height * bps)
      assert_eq(packed.frame_v(i).length(), cw * height * bps)
      assert_eq(
        packed.frame_y(i) + packed.frame_u(i) + packed.frame_v(i),
        decoded[i].yuvp(),
      )
      let mut hash = 14695981039346656037UL
      for b in decoded[i].yuvp() {
        hash = (hash ^ b.to_uint64()) * 1099511628211UL
      }
      assert_eq(oracle.frames[i].digest_lo, hash.to_int())
      assert_eq(oracle.frames[i].digest_hi, (hash >> 32).to_int())
    }
  }
}
