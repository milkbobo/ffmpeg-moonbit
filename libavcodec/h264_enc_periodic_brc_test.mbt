///|
/// Read the emitted slice headers independently of the encoder's output
/// order. These short GOPs never wrap POC, so POC/2 is the local display
/// index even though the preceding P reference is emitted before its B.
fn periodic_brc_check_qps(
  stream : Bytes,
  config : @libavcodec.VideoEncConfig,
  qps : Array[Int32],
) -> Unit raise {
  let ps = @libavcodec.new_h264_param_sets()
  let mut start = -config.keyint
  let seen = Array::make(qps.length(), false)
  for nal in vbv_nals(stream) {
    let payload = vbv_nal_payload(stream, nal)
    let reader = @libavcodec.BitReader::new(payload)
    let result = if nal.0 == 7 {
      @libavcodec.ff_h264_decode_seq_parameter_set(reader, ps, false)
    } else if nal.0 == 8 {
      @libavcodec.ff_h264_decode_picture_parameter_set(
        reader,
        ps,
        payload.length() * 8,
      )
    } else {
      Ok(())
    }
    match result {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    if nal.0 == 1 || nal.0 == 5 {
      if nal.0 == 5 {
        start += config.keyint
      }
      let ref_idc = (stream[nal.1 + 4].to_int() >> 5) & 3
      let sh = match
        @libavcodec.ff_h264_decode_slice_header(reader, nal.0, ref_idc, ps) {
        Ok(h) => h
        Err(e) => fail(e)
      }
      let display = start + sh.pic_order_cnt_lsb / 2
      assert_true(display >= 0 && display < qps.length())
      assert_false(seen[display])
      seen[display] = true
      assert_eq(sh.qscale, qps[display] + 6 * (config.bit_depth - 8))
      let expected_type = if display == start {
        2
      } else if (display - start) % 2 == 1 &&
        display + 1 < (start + config.keyint).min(qps.length()) {
        1 // B, with a future reference inside this GOP
      } else {
        0
      } // P, including an unmatched GOP tail
      assert_eq(sh.slice_type_nos, expected_type)
    }
  }
  assert_true(seen.all(v => v))
}

///|
test "h264 periodic B ABR: global budget and display-position QPs" {
  let mut mixed_qps = false
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 7)
    } else {
      h264h10_fixture(32, 32, 7, depth)
    }
    for cabac in [false, true] {
      for keyint in [3, 4] {
        let base = {
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          keyint,
          qp: 20,
          bit_depth: depth,
          aq: true,
          aq_strength: 3,
          aud: keyint == 4,
        }
        fn encode(
          config : @libavcodec.VideoEncConfig,
          stats : @libavcodec.H264EncStats,
          recon : Array[Bytes],
        ) -> Bytes raise {
          match
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
        mixed_qps = mixed_qps ||
          stats.frame_qps.any(q => q != stats.frame_qps[0])
        // Two actual B pictures, four macroblocks each. Probe counts must
        // not leak into the caller's final statistics.
        assert_eq(stats.b_mbs, 8)
        periodic_brc_check_qps(stream, base, stats.frame_qps)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 7)
        let mut r = 0
        for i, frame in decoded {
          if i % keyint != 0 {
            assert_eq(mr_md5(recon[r]), mr_md5(frame.yuvp()))
            r += 1
          }
        }
        assert_eq(recon.length(), r)
        assert_eq(
          vbv_nals(stream).filter(n => n.0 == 5).length(),
          (7 + keyint - 1) / keyint,
        )
        let again = encode(
          { ..base, target_bytes: target, },
          @libavcodec.H264EncStats::new(),
          [],
        )
        assert_eq(stream, again)
        let fallback_stats = @libavcodec.H264EncStats::new()
        let fallback = encode({ ..base, target_bytes: 1, }, fallback_stats, [])
        assert_true(fallback.length() > 1)
        assert_eq(fallback_stats.frame_qps, Array::make(7, 51))
        assert_eq(fallback, coarse)
      }
    }
  }
  assert_true(mixed_qps)
}

///|
test "h264 periodic B ABR: all-IDR, tail P and ordinary single-GOP bytes" {
  let frames = h264p_fixture(32, 32, 4)
  for cabac in [false, true] {
    let base = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      qp: 26,
      target_bytes: 1200,
    }
    for keyint in [1, 2, 20] {
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let stream = match
        @libavcodec.video_encode(
          frames,
          codec=@libavcodec.H264,
          config={ ..base, keyint, },
          stats~,
          recon~,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(stream.length() <= 1200)
      periodic_brc_check_qps(stream, { ..base, keyint, }, stats.frame_qps)
      if keyint <= 2 {
        assert_eq(stats.b_mbs, 0)
      } else {
        assert_true(stats.b_mbs > 0)
      }
      assert_eq(recon.length(), 4 - (4 + keyint - 1) / keyint)
      if keyint == 20 {
        let ordinary = match
          @libavcodec.video_encode(frames, codec=@libavcodec.H264, config=base) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_eq(stream, ordinary)
      }
    }
  }
}

///|
test "h264 periodic B ABR: invalid input preserves caller outputs" {
  let frames = h264p_fixture(32, 32, 4)
  frames[2] = (b"", frames[2].1, frames[2].2)
  let stats = @libavcodec.H264EncStats::new()
  stats.frame_qps.push(17)
  let recon = [b"existing"]
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=32, height=32),
    keyint: 3,
    target_bytes: 1000,
  }
  match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.H264,
      config~,
      stats~,
      recon~,
    ) {
    Ok(_) => fail("invalid B ABR input accepted")
    Err(_) => ()
  }
  assert_eq(stats.frame_qps, [17])
  assert_eq(stats.b_mbs, 0)
  assert_eq(recon, [b"existing"])
  match @libavcodec.VideoEncoder::open(codec=@libavcodec.H264, config~) {
    Ok(_) => fail("streaming ABR accepted")
    Err(_) => ()
  }
}
