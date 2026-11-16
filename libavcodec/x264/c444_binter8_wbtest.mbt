///|
test "pure H264 c444 B inter8: FFmpeg pixels and diagnostics" {
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<5 {
    let planes : Array[Bytes] = []
    for p in 0..<3 {
      planes.push(
        Bytes::from_array(
          Array::makei(1024, i => {
            let row = i / 32
            let col = i % 32
            let noise = if f % 2 == 1 {
              (row * 7 + col * 11 + p * 3) % 17
            } else {
              0
            }
            ((col * 3 + row * 2 + f * 3 + p * 40 + noise) & 255).to_byte()
          })[:],
        ),
      )
    }
    frames.push((planes[0], planes[1], planes[2]))
  }
  for cabac in [false, true] {
    let result = if cabac {
      @libavcodec.h264_encode_frames_cabac(
        frames,
        width=32,
        height=32,
        qp=20,
        chroma_format=3,
        dct8x8=true,
      )
    } else {
      @libavcodec.h264_encode_frames(
        frames,
        width=32,
        height=32,
        qp=20,
        chroma_format=3,
        dct8x8=true,
      )
    }
    let stream = match result {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let pixels = match x264_probe_frames(stream) {
      Ok(p) => p
      Err(e) => fail(e)
    }
    let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(pixels.n_frames, 5)
    assert_eq(pixels.warnings, 0)
    assert_eq(pixels.errors, 0)
    for (i, coded) in [(0, 0), (1, 2), (2, 1), (3, 4), (4, 3)] {
      let mut hash = 14695981039346656037UL
      for b in decoded[coded].yuvp() {
        hash = (hash ^ b.to_uint64()) * 1099511628211UL
      }
      assert_eq(pixels.frames[i].digest_lo, hash.to_int())
      assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
      assert_eq(pixels.frames[i].decode_error_flags, 0)
    }
  }
}
