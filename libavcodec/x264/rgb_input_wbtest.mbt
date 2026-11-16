///|
test "x264 binding: packed RGB input through libx264rgb" {
  for fmt in [Bgr0, Bgr24, Rgb24] {
    assert_true(x264_supports("libx264rgb", fmt))
    let width = 34
    let height = 18
    let bpp = fmt.bytes_per_pixel()
    let enc = X264Encoder::open(
      width~,
      height~,
      pix_fmt=fmt,
      codec="libx264rgb",
      global_header=false,
      options=[("preset", "medium"), ("qp", "20"), ("bf", "0")],
    )
    let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
    for f in 0..<3 {
      frames.push(
        (
          f.to_int64(),
          Bytes::makei(width * height * bpp, i => {
            (i * 7 + f * 91 + 13).to_byte()
          }),
          b"",
          b"",
        ),
      )
    }
    // Packed input carries no chroma planes: both must be rejected
    // before copying from borrowed buffers.
    try enc.send_frame(pts=0L, y=frames[0].1, u=frames[0].1, v=b"") catch {
      SendFailed(_) => ()
      _ => fail("unexpected error variant")
    } noraise {
      _ => fail("chroma plane accepted for packed input")
    }
    try
      enc.send_frame(pts=0L, y=Bytes::new(width * height), u=b"", v=b"")
    catch {
      SendFailed(_) => ()
      _ => fail("unexpected error variant")
    } noraise {
      _ => fail("single-byte-per-pixel plane accepted for packed input")
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
    // x264 keeps RGB input as 4:4:4 in GBR plane order.
    assert_eq(packed.kind, 7)
    assert_eq(packed.bytes_per_sample(), 1)
    for i in 0..<3 {
      assert_eq(packed.frame_y(i).length(), width * height)
      assert_eq(packed.frame_u(i).length(), width * height)
      assert_eq(packed.frame_v(i).length(), width * height)
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
