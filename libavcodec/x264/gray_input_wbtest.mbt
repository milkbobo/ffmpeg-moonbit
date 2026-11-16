///|
test "x264 grayscale: 8 and 10 bit input round trips with neutral decoded chroma" {
  for fmt in [Gray8, Gray10le] {
    assert_true(x264_supports("libx264", fmt))
    let bps = fmt.bytes_per_sample()
    let width = 35
    let height = 19
    for cabac in [false, true] {
      let enc = X264Encoder::open(
        width~,
        height~,
        pix_fmt=fmt,
        global_header=false,
        options=[
          ("preset", "medium"),
          ("qp", "20"),
          (
            "x264-params",
            if cabac {
              "cabac=1:bframes=2:b-adapt=0"
            } else {
              "cabac=0:bframes=2:b-adapt=0"
            },
          ),
        ],
      )
      let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
      for f in 0..<7 {
        let y = Bytes::makei(width * height * bps, i => {
          let sample = (i / bps * 37 + f * 53) %
            256 *
            (if bps == 2 { 4 } else { 1 })
          (if bps == 2 && i % 2 == 1 { sample >> 8 } else { sample & 255 }).to_byte()
        })
        frames.push((f.to_int64(), y, b"", b""))
      }
      try enc.send_frame(pts=0L, y=frames[0].1, u=b"x", v=b"") catch {
        SendFailed(_) => ()
        _ => fail("unexpected gray input error")
      } noraise {
        _ => fail("gray input accepted chroma")
      }
      let packets = enc.encode_all(frames)
      enc.close()
      assert_eq(packets.length(), 7)
      let stream = x264_concat(packets)
      let packed = match x264_decode_annexb(stream) {
        Ok(p) => p
        Err(e) => fail(e)
      }
      let probe = match x264_probe_frames(stream) {
        Ok(p) => p
        Err(e) => fail(e)
      }
      let decoded = match
        @libavcodec.h264_decode_annexb_display_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(packed.n_frames, 7)
      assert_eq(packed.bytes_per_sample(), bps)
      assert_eq(probe.warnings, 0)
      assert_eq(probe.errors, 0)
      assert_true(probe.frames.any(f => f.pict_type == 3))
      assert_eq(decoded.length(), 7)
      for i in 0..<7 {
        assert_eq(packed.frame_y(i).length(), width * height * bps)
        let chroma = Bytes::makei(18 * 10 * bps, j => {
          (if bps == 1 { 128 } else if j % 2 == 0 { 0 } else { 2 }).to_byte()
        })
        assert_eq(packed.frame_u(i), chroma)
        assert_eq(packed.frame_v(i), chroma)
        assert_true(packed.frame_y(i) + chroma + chroma == decoded[i].yuvp())
      }
    }
  }
}
