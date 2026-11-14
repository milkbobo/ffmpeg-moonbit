///|
test "h264 periodic B VBV: CPB and HRD follow decode order across GOPs" {
  let mut adapted = false
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 8)
    } else {
      h264h10_fixture(32, 32, 8, depth)
    }
    for cabac in [false, true] {
      for keyint in [3, 4] {
        let config = {
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          keyint,
          bit_depth: depth,
          qp: 10,
          aq: true,
          aq_strength: 3,
          aud: keyint == 4,
          vbv_maxrate: 64000,
          vbv_bufsize: 4000,
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
        ignore(vbv_cpb_check("periodic B", sizes, 64000, 4000, 25, 90))
        let sps = vbv_sps_info(stream, nals)
        assert_eq(sps.max_num_reorder_frames, 1)
        assert_eq(sps.max_dec_frame_buffering, 2)
        assert_eq(stats.frame_qps.length(), 8)
        assert_eq(stats.b_mbs, 8)
        adapted = adapted || stats.frame_qps.any(q => q > 10)
        periodic_brc_check_qps(stream, config, stats.frame_qps)
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
        assert_eq(stats.vbv_fills, nals.filter(n => n.0 == 12).length())
        let mut filler_bytes = 0
        for (ty, s, e) in nals {
          if ty == 12 {
            filler_bytes += e - s
          }
        }
        assert_eq(stats.vbv_filler_bytes, filler_bytes)
        let mut au = 0
        let mut fullness = 3600
        let mut bp_count = 0
        let mut timing_count = 0
        let ps = @libavcodec.new_h264_param_sets()
        let mut out_ticks = -1
        for nal in nals {
          if nal.0 == 7 {
            match
              @libavcodec.ff_h264_decode_seq_parameter_set(
                @libavcodec.BitReader::new(vbv_nal_payload(stream, nal)),
                ps,
                false,
              ) {
              Ok(_) => ()
              Err(e) => fail(e)
            }
          } else if nal.0 == 8 {
            let payload = vbv_nal_payload(stream, nal)
            match
              @libavcodec.ff_h264_decode_picture_parameter_set(
                @libavcodec.BitReader::new(payload),
                ps,
                payload.length() * 8,
              ) {
              Ok(_) => ()
              Err(e) => fail(e)
            }
          } else if nal.0 == 6 {
            let (ty, payload) = vbv_sei_message(stream, nal)
            let b = VbvBits::new(payload)
            if ty == 0 {
              assert_eq(au % keyint, 0)
              assert_eq(b.ue(), 0)
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
              let delay = b.u(4)
              assert_true(delay == 0 || delay == 2 || delay == 4)
              out_ticks = au * 2 + delay
              timing_count += 1
            }
          } else if nal.0 == 1 || nal.0 == 5 {
            let sh = match
              @libavcodec.ff_h264_decode_slice_header(
                @libavcodec.BitReader::new(vbv_nal_payload(stream, nal)),
                nal.0,
                (stream[nal.1 + 4].to_int() >> 5) & 3,
                ps,
              ) {
              Ok(h) => h
              Err(e) => fail(e)
            }
            let display = au / keyint * keyint + sh.pic_order_cnt_lsb / 2
            assert_eq(out_ticks, (display + 1) * 2)
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
test "h264 periodic B VBV: all-IDR, filler and single-GOP compatibility" {
  let frames = Array::make(
    6,
    (Bytes::make(1024, 128), Bytes::make(256, 128), Bytes::make(256, 128)),
  )
  for cabac in [false, true] {
    let base = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      aud: true,
      vbv_maxrate: 128000,
      vbv_bufsize: 16000,
      fps: 25,
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
      assert_true(stats.vbv_filler_bytes > 0)
      assert_eq(stats.frame_qps.length(), 6)
      ignore(
        vbv_cpb_check(
          "B filler",
          vbv_au_sizes(vbv_nals(stream)),
          128000,
          16000,
          25,
          90,
        ),
      )
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 6)
      assert_eq(recon.length(), 6 - (6 + keyint - 1) / keyint)
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
test "h264 periodic B VBV: failed probes preserve caller state" {
  let good = h264p_fixture(32, 32, 4)
  let bad = good.copy()
  bad[2] = (b"", good[2].1, good[2].2)
  let base = {
    ..@libavcodec.VideoEncConfig::new(width=32, height=32),
    keyint: 3,
    vbv_maxrate: 64000,
    vbv_bufsize: 8000,
    fps: 25,
  }
  for
    (frames, config) in [
      (bad, base),
      (good, { ..base, target_bytes: 1000, }),
      (good, { ..base, vbv_maxrate: 6400, vbv_bufsize: 320, }),
    ] {
    let stats = @libavcodec.H264EncStats::new()
    stats.frame_qps.push(17)
    let recon = [b"existing"]
    match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.H264,
        config~,
        stats~,
        recon~,
      ) {
      Ok(_) => fail("invalid periodic B VBV input accepted")
      Err(_) => ()
    }
    assert_eq(stats.frame_qps, [17])
    assert_eq(stats.vbv_bits, 0L)
    assert_eq(stats.vbv_filler_bytes, 0)
    assert_eq(recon, [b"existing"])
  }
}
