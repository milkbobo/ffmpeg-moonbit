///|
test "h264 c444 VBV: rejected IDR restores pending tail and queued output" {
  let flat = Bytes::make(4096, 128)
  let noise = online_b_noise(4096)
  for cabac in [false, true] {
    fn run(reject : Bool) -> Bytes raise {
      let stats = @libavcodec.H264EncStats::new()
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=64,
          height=64,
          chroma_format=3,
          cabac~,
          vbv_maxrate=32000,
          vbv_bufsize=1600,
          fps=25,
          stats~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      for _ in 0..<2 {
        match enc.push_frame(flat, flat, flat) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
      }
      if reject {
        let bits = stats.vbv_bits
        match enc.push_frame(noise, flat, flat, force_idr=true) {
          Ok(_) => fail("infeasible 4:4:4 IDR accepted")
          Err(e) => assert_true(e.contains("underflow"), msg=e)
        }
        assert_eq(enc.next_display, 2)
        assert_true(enc.pending is Some(_))
        assert_eq(stats.vbv_bits, bits)
        assert_eq(stats.frame_qps.length(), 1)
        assert_eq(enc.out.length(), 1)
        assert_eq(enc.recons.length(), 0)
      }
      match enc.push_frame(flat, flat, flat, force_idr=true) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      assert_true(enc.pending is None)
      assert_eq(enc.next_display, 3)
      assert_eq(stats.frame_qps.length(), 3)
      match enc.finish() {
        Ok(aus) => h264s_concat(aus)
        Err(e) => fail(e)
      }
    }
    let recovered = run(true)
    assert_eq(recovered, run(false))
    let decoded = match @libavcodec.h264_decode_annexb_frames(recovered, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 3)
  }
}
