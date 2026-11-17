///|
fn stream_vbv_encode(
  frames : Array[(Bytes, Bytes, Bytes)],
  config : @libavcodec.VideoEncConfig,
  stats : @libavcodec.H264EncStats,
) -> Bytes raise {
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.H264, config~, stats~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for i, (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    let ready = enc.drain()
    assert_eq(ready.length(), 1)
    assert_eq(stats.frame_qps.length(), i + 1)
    aus.push(ready[0])
  }
  let tail = match enc.finish() {
    Ok(t) => t
    Err(e) => fail(e)
  }
  assert_eq(tail.length(), 0)
  idr_concat(aus)
}

///|
test "h264 stream VBV: online output matches batch without future input" {
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 7)
    } else {
      h264h10_fixture(32, 32, 7, depth)
    }
    for cabac in [false, true] {
      for keyint in [0, 3] {
        let config = {
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          keyint,
          b_slices: false,
          multi_ref: 3,
          bit_depth: depth,
          qp: 10,
          aq: true,
          aq_strength: 3,
          aud: keyint == 3,
          vbv_maxrate: 64000,
          vbv_bufsize: 4000,
          fps: 25,
        }
        let stats = @libavcodec.H264EncStats::new()
        let stream = stream_vbv_encode(frames, config, stats)
        let batch_stats = @libavcodec.H264EncStats::new()
        let batch = match
          @libavcodec.video_encode(
            frames,
            codec=@libavcodec.H264,
            config~,
            stats=batch_stats,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_eq(stream, batch)
        assert_eq(stats.frame_qps, batch_stats.frame_qps)
        assert_eq(stats.i16_mbs, batch_stats.i16_mbs)
        assert_eq(stats.i8_mbs, batch_stats.i8_mbs)
        assert_eq(stats.i8p_mbs, batch_stats.i8p_mbs)
        assert_eq(stats.coded_mbs, batch_stats.coded_mbs)
        assert_eq(stats.dqp_mbs, batch_stats.dqp_mbs)
        assert_eq(stats.vbv_fills, batch_stats.vbv_fills)
        assert_eq(stats.vbv_filler_bytes, batch_stats.vbv_filler_bytes)
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
        ignore(
          vbv_cpb_check(
            "online",
            vbv_au_sizes(vbv_nals(stream)),
            64000,
            4000,
            25,
            90,
          ),
        )
      }
    }
  }
}

///|
test "h264 stream VBV: invalid options and first-frame underflow do not emit" {
  let base = @libavcodec.VideoEncConfig::new(width=32, height=32)
  for
    config in [
      // `§418` made the online B VBV x multi_ref combination legal — see
      // h264_enc_b_multiref_test.mbt for the positive coverage.
      { ..base, b_slices: false, fps: 25, },
      { ..base, b_slices: false, vbv_maxrate: -1, },
      {
        ..base,
        b_slices: false,
        vbv_maxrate: 64000,
        vbv_bufsize: 8000,
        fps: 25,
        target_bytes: 1000,
      },
    ] {
    match @libavcodec.VideoEncoder::open(codec=@libavcodec.H264, config~) {
      Ok(_) => fail("unsupported streaming configuration accepted")
      Err(_) => ()
    }
  }
  let stats = @libavcodec.H264EncStats::new()
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=32,
      height=32,
      b_slices=false,
      vbv_maxrate=6400,
      vbv_bufsize=320,
      fps=25,
      stats~,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for _ in 0..<2 {
    match
      enc.push_frame(
        Bytes::make(1024, 128),
        Bytes::make(256, 128),
        Bytes::make(256, 128),
      ) {
      Ok(_) => fail("impossible first IDR accepted")
      Err(e) => assert_true(e.contains("underflow"))
    }
    assert_eq(enc.next_display, 0)
    assert_eq(enc.drain().length(), 0)
    assert_eq(enc.recons.length(), 0)
    assert_eq(stats.frame_qps.length(), 0)
    assert_eq(stats.vbv_bits, 0L)
    assert_eq(stats.i16_mbs + stats.i8_mbs, 0)
  }
}

///|
test "h264 stream VBV: rejected trial preserves references, stats and queued output" {
  let flat = (
    Bytes::make(1024, 128),
    Bytes::make(256, 128),
    Bytes::make(256, 128),
  )
  let noise = Bytes::from_array(
    Array::makei(1024, i => ((i * 73 + i / 7 * 29) & 255).to_byte())[:],
  )
  for cabac in [false, true] {
    let config = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      b_slices: false,
      multi_ref: 3,
      vbv_maxrate: 32000,
      vbv_bufsize: 1600,
      fps: 25,
      aud: true,
    }
    let stats = @libavcodec.H264EncStats::new()
    let enc = match
      @libavcodec.VideoEncoder::open(codec=@libavcodec.H264, config~, stats~) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    match enc.push_frame(flat.0, flat.1, flat.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    let bits = stats.vbv_bits
    let coded = stats.coded_mbs
    let qps = stats.frame_qps.copy()
    match enc.push_frame(b"", flat.1, flat.2, force_idr=true) {
      Ok(_) => fail("invalid plane accepted")
      Err(_) => ()
    }
    match enc.push_frame(noise, flat.1, flat.2, force_idr=true) {
      Ok(_) => fail("infeasible IDR accepted")
      Err(e) => assert_true(e.contains("underflow"))
    }
    assert_eq(stats.vbv_bits, bits)
    assert_eq(stats.coded_mbs, coded)
    assert_eq(stats.frame_qps, qps)
    match enc.push_frame(flat.0, flat.1, flat.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    let aus = enc.drain()
    assert_eq(aus.length(), 2)
    let reference = stream_vbv_encode(
      [flat, flat],
      config,
      @libavcodec.H264EncStats::new(),
    )
    assert_eq(idr_concat(aus), reference)
    assert_eq(stats.frame_qps.length(), 2)
  }
}

///|
test "h264 stream VBV: manual IDR uses continuous fullness and timing" {
  let frames = h264p_fixture(32, 32, 7)
  for cabac in [false, true] {
    let stats = @libavcodec.H264EncStats::new()
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=32,
        height=32,
        cabac~,
        b_slices=false,
        multi_ref=3,
        vbv_maxrate=64000,
        vbv_bufsize=8000,
        fps=25,
        aud=true,
        stats~,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let aus : Array[Bytes] = []
    let mut fullness = 7200
    let mut last_bp = 0
    for i, (y, u, v) in frames {
      match enc.push_frame(y, u, v, force_idr=i == 3 || i == 4) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      let ready = enc.drain()
      assert_eq(ready.length(), 1)
      let au = ready[0]
      for nal in vbv_nals(au) {
        if nal.0 == 6 {
          let (ty, payload) = vbv_sei_message(au, nal)
          let b = VbvBits::new(payload)
          if ty == 0 {
            assert_eq(b.ue(), 0)
            assert_eq(b.u(24), (fullness.to_int64() * 90000L / 64000L).to_int())
          } else if ty == 1 {
            assert_eq(b.u(16), (i - last_bp) * 2)
          }
        }
      }
      if i == 3 || i == 4 {
        last_bp = i
      }
      fullness = fullness - au.length() * 8 + 2560
      aus.push(au)
    }
    let stream = idr_concat(aus)
    ignore(
      vbv_cpb_check(
        "manual online",
        vbv_au_sizes(vbv_nals(stream)),
        64000,
        8000,
        25,
        90,
      ),
    )
    assert_eq(stats.frame_qps.length(), 7)
    assert_eq(enc.recons.length(), 4)
    let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    let mut r = 0
    for i, f in decoded {
      if i != 0 && i != 3 && i != 4 {
        assert_eq(mr_md5(enc.recons[r]), mr_md5(f.yuvp()))
        r += 1
      }
    }
  }
}
