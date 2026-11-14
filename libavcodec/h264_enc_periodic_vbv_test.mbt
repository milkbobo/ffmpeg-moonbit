///|
test "h264 periodic VBV: continuous CPB and buffering periods" {
  let mut adapted = false
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 8)
    } else {
      h264h10_fixture(32, 32, 8, depth)
    }
    for cabac in [false, true] {
      for keyint in [1, 3] {
        let config = {
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          keyint,
          b_slices: false,
          multi_ref: 3,
          bit_depth: depth,
          qp: 10,
          aud: true,
          aq: true,
          aq_strength: 3,
          vbv_maxrate: 64000,
          vbv_bufsize: 8000,
          fps: 25,
        }
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let stream = match
          @libavcodec.video_encode(
            frames,
            codec=@libavcodec.H264,
            config~,
            stats~,
            recon~,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        let nals = vbv_nals(stream)
        let sizes = vbv_au_sizes(nals)
        assert_eq(sizes.length(), 8)
        ignore(vbv_cpb_check("periodic", sizes, 64000, 8000, 25, 90))
        assert_eq(stats.frame_qps.length(), 8)
        adapted = adapted || stats.frame_qps.any(q => q > 10)
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
        assert_eq(stats.vbv_fills, nals.filter(n => n.0 == 12).length())
        let mut filler_bytes = 0
        for (ty, s, e) in nals {
          if ty == 12 {
            filler_bytes += e - s
          }
        }
        assert_eq(stats.vbv_filler_bytes, filler_bytes)
        let mut fullness = 7200
        let mut au = 0
        let mut bp_count = 0
        let mut timing_count = 0
        for nal in nals {
          if nal.0 == 6 {
            let (ty, payload) = vbv_sei_message(stream, nal)
            let b = VbvBits::new(payload)
            if ty == 0 {
              assert_eq(b.ue(), 0)
              assert_eq(au % keyint, 0)
              assert_eq(
                b.u(24),
                (fullness.to_int64() * 90000L / 64000L).to_int(),
              )
              ignore(b.u(24))
              bp_count += 1
            } else if ty == 1 {
              let ticks = if au == 0 {
                0
              } else if au % keyint == 0 {
                keyint * 2
              } else {
                au % keyint * 2
              }
              assert_eq(b.u(16), ticks)
              assert_eq(b.u(4), 0)
              timing_count += 1
            }
          }
          if nal.0 == 1 || nal.0 == 5 {
            fullness = fullness - sizes[au] * 8 + 2560
            au += 1
          }
        }
        assert_eq(timing_count, 8)
        assert_eq(bp_count, (8 + keyint - 1) / keyint)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 8)
        let mut r = 0
        for i, frame in decoded {
          if i % keyint != 0 {
            assert_eq(mr_md5(recon[r]), mr_md5(frame.yuvp()))
            r += 1
          }
        }
        assert_eq(recon.length(), r)
      }
    }
  }
  assert_true(adapted)
}

///|
test "h264 periodic VBV: filler carries CPB fullness across IDR" {
  let frames = Array::make(
    9,
    (Bytes::make(1024, 128), Bytes::make(256, 128), Bytes::make(256, 128)),
  )
  for cabac in [false, true] {
    let stats = @libavcodec.H264EncStats::new()
    let stream = match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.H264,
        config={
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          b_slices: false,
          keyint: 2,
          vbv_maxrate: 128000,
          vbv_bufsize: 16000,
          fps: 25,
          aud: true,
        },
        stats~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let nals = vbv_nals(stream)
    assert_true(stats.vbv_filler_bytes > 0)
    ignore(
      vbv_cpb_check("filler IDR", vbv_au_sizes(nals), 128000, 16000, 25, 90),
    )
    let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 9)
  }
}

///|
test "h264 periodic VBV: invalid input and infeasible CPB leave stats untouched" {
  let good = h264p_fixture(32, 32, 4)
  let bad = good.copy()
  bad[2] = (b"", good[2].1, good[2].2)
  let base = {
    ..@libavcodec.VideoEncConfig::new(width=32, height=32),
    keyint: 2,
    b_slices: false,
    vbv_maxrate: 64000,
    vbv_bufsize: 8000,
    fps: 25,
  }
  for
    (frames, config) in [
      (bad, base),
      (good, { ..base, target_bytes: 1000, }),
      (good, { ..base, vbv_maxrate: 6400, vbv_bufsize: 320, }),
      (good, { ..base, vbv_maxrate: 64, vbv_bufsize: 12800, }),
      (good, { ..base, vbv_maxrate: 64000000, vbv_bufsize: 128, fps: 1000000, }),
    ] {
    let stats = @libavcodec.H264EncStats::new()
    let recon : Array[Bytes] = []
    match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.H264,
        config~,
        stats~,
        recon~,
      ) {
      Ok(_) => fail("invalid periodic VBV input accepted")
      Err(_) => ()
    }
    assert_eq(stats.frame_qps.length(), 0)
    assert_eq(stats.vbv_bits, 0L)
    assert_eq(stats.vbv_fills, 0)
    assert_eq(recon.length(), 0)
  }
}

///|
test "h264 periodic VBV: a single GOP preserves ordinary VBV bytes" {
  let frames = h264p_fixture(32, 32, 4)
  for cabac in [false, true] {
    fn encode(keyint : Int32) -> Bytes raise {
      match
        @libavcodec.video_encode(frames, codec=@libavcodec.H264, config={
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          keyint,
          b_slices: false,
          multi_ref: 3,
          aud: true,
          vbv_maxrate: 64000,
          vbv_bufsize: 8000,
          fps: 25,
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
    }
    assert_eq(encode(0), encode(20))
  }
}
