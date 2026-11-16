///|
test "x264 binding: semi-planar NV12/NV21/NV16/NV20 input" {
  for (fmt, packed_kind) in [(Nv12, 0), (Nv21, 0), (Nv16, 3), (Nv20le, 4)] {
    assert_true(x264_supports("libx264", fmt))
    let bps = fmt.bytes_per_sample()
    // 4:2:0 x264 requires even dimensions; the 4:2:2 pair also exercises
    // an odd height (full-height chroma, ceil'd luma halves).
    let width = 34
    let height = if fmt == Nv16 || fmt == Nv20le { 19 } else { 18 }
    let cw = width / 2
    let ch = if fmt == Nv16 || fmt == Nv20le {
      height
    } else {
      height / 2 + height % 2
    }
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
      // One interleaved U+V plane: `n` is the total sample count. Even
      // samples come from a U stream, odd samples from a V stream, so
      // Nv21 (V then U) produces genuinely different chroma content.
      fn interleaved(n : Int32, seed : Int32, bps : Int32) -> Bytes {
        Bytes::makei(n * bps, i => {
          let s = i / bps
          let sample = (
              s / 2 * 37 + (if s % 2 == 0 { seed * 53 } else { seed * 71 + 29 })
            ) %
            256 *
            (if bps == 2 { 4 } else { 1 })
          (if bps == 2 && i % 2 == 1 { sample >> 8 } else { sample & 255 }).to_byte()
        })
      }
      frames.push(
        (
          f.to_int64(),
          plane(width * height, f, bps),
          interleaved(cw * ch * 2, f + 1, bps),
          b"",
        ),
      )
    }
    // Semi-planar input must not carry a separate V plane, and the packed
    // plane must be the full interleaved size: both rejections happen
    // before copying from borrowed buffers.
    try
      enc.send_frame(pts=0L, y=frames[0].1, u=frames[0].2, v=Bytes::new(1))
    catch {
      SendFailed(_) => ()
      _ => fail("unexpected error variant")
    } noraise {
      _ => fail("non-empty v accepted for semi-planar input")
    }
    try
      enc.send_frame(pts=0L, y=frames[0].1, u=Bytes::new(cw * ch * bps), v=b"")
    catch {
      SendFailed(_) => ()
      _ => fail("unexpected error variant")
    } noraise {
      _ => fail("planar-sized chroma accepted for semi-planar input")
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
    assert_eq(packed.kind, packed_kind)
    assert_eq(packed.bytes_per_sample(), bps)
    for i in 0..<3 {
      assert_eq(packed.frame_y(i).length(), width * height * bps)
      assert_eq(packed.frame_u(i).length(), cw * ch * bps)
      assert_eq(packed.frame_v(i).length(), cw * ch * bps)
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
