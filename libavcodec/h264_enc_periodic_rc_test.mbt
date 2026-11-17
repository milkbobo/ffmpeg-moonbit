///|
test "h264 periodic ABR: one budget covers all GOPs and headers" {
  for depth in [8, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 7)
    } else {
      h264h10_fixture(32, 32, 7, depth)
    }
    for cabac in [false, true] {
      let base = {
        ..@libavcodec.VideoEncConfig::new(width=32, height=32),
        cabac,
        qp: 20,
        keyint: 3,
        b_slices: false,
        multi_ref: 3,
        bit_depth: depth,
        aud: true,
        aq: true,
        aq_strength: 3,
      }
      fn encode(
        config : @libavcodec.VideoEncConfig,
        stats : @libavcodec.H264EncStats,
        recon : Array[Bytes],
      ) -> Bytes raise {
        match
          @libavcodec.video_encode(
            frames,
            codec=@libavcodec.VideoCodec::H264,
            config~,
            stats~,
            recon~,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
      }
      let fine = encode(base, @libavcodec.H264EncStats::new(), [])
      let coarse = encode(
        { ..base, qp: 51, },
        @libavcodec.H264EncStats::new(),
        [],
      )
      assert_true(fine.length() > coarse.length())
      let target = (fine.length() + coarse.length()) / 2
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let stream = encode({ ..base, target_bytes: target, }, stats, recon)
      assert_true(stream.length() <= target)
      assert_eq(stats.frame_qps.length(), 7)
      assert_true(stats.frame_qps.any(q => q > 20))
      assert_eq(recon.length(), 4)
      let nals = vbv_nals(stream)
      for ty in [5, 7, 8] {
        assert_eq(nals.filter(n => n.0 == ty).length(), 3)
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 7)
      let mut r = 0
      for i in 0..<7 {
        if i % 3 != 0 {
          assert_eq(mr_md5(recon[r]), mr_md5(decoded[i].yuvp()))
          r += 1
        }
      }
      let fallback_stats = @libavcodec.H264EncStats::new()
      let fallback = encode({ ..base, target_bytes: 1, }, fallback_stats, [])
      for q in fallback_stats.frame_qps {
        assert_eq(q, 51)
      }
      assert_eq(fallback_stats.frame_qps.length(), 7)
      let worst = match @libavcodec.h264_decode_annexb_frames(fallback, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let reference = match
        @libavcodec.h264_decode_annexb_frames(coarse, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      for i, f in worst {
        assert_eq(mr_md5(f.yuvp()), mr_md5(reference[i].yuvp()))
      }
    }
  }
}

///|
test "h264 periodic ABR: malformed planes fail before probes mutate stats" {
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let frames = h264p_fixture(32, 32, 4)
  frames[2] = (b"", frames[2].1, frames[2].2)
  match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config={
        ..@libavcodec.VideoEncConfig::new(width=32, height=32),
        b_slices: false,
        keyint: 3,
        target_bytes: 1000,
      },
      stats~,
      recon~,
    ) {
    Ok(_) => fail("malformed periodic input accepted")
    Err(_) => ()
  }
  assert_eq(stats.frame_qps.length(), 0)
  assert_eq(recon.length(), 0)
}

///|
test "h264 periodic ABR: all-IDR and single-GOP bounds" {
  let frames = h264p_fixture(32, 32, 4)
  for cabac in [false, true] {
    let base = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      qp: 26,
      b_slices: false,
      multi_ref: 3,
      target_bytes: 1000,
    }
    for keyint in [1, 20] {
      let recon : Array[Bytes] = []
      let stream = match
        @libavcodec.video_encode(
          frames,
          codec=@libavcodec.VideoCodec::H264,
          config={ ..base, keyint, },
          recon~,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(stream.length() <= 1000)
      assert_eq(recon.length(), if keyint == 1 { 0 } else { 3 })
      assert_eq(
        vbv_nals(stream).filter(n => n.0 == 5).length(),
        if keyint == 1 {
          4
        } else {
          1
        },
      )
      if keyint == 20 {
        let ordinary = match
          @libavcodec.video_encode(
            frames,
            codec=@libavcodec.VideoCodec::H264,
            config=base,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_eq(stream, ordinary)
      }
    }
  }
}
