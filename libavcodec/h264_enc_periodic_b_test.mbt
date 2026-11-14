///|
fn periodic_b_stream(
  frames : Array[(Bytes, Bytes, Bytes)],
  config : @libavcodec.VideoEncConfig,
  forced~ : Array[Int32] = [],
) -> Array[Bytes] raise {
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.H264, config~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for i, (y, u, v) in frames {
    match enc.push_frame(y, u, v, force_idr=forced.contains(i)) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail(e)
  }
  aus
}

///|
test "h264 periodic B: display intervals match independent GOPs" {
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 9)
    } else {
      h264h10_fixture(32, 32, 9, depth)
    }
    for cabac in [false, true] {
      for keyint in [1, 2, 3, 4, 20] {
        let config = {
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          bit_depth: depth,
          keyint,
          aq: true,
          aq_strength: 3,
          aud: keyint % 2 == 0,
        }
        let aus = periodic_b_stream(frames, config)
        assert_eq(aus.length(), 9)
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let batch = match
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
        assert_eq(idr_concat(aus), batch)
        assert_eq(stats.frame_qps.length(), 9)
        let nals = vbv_nals(batch)
        assert_eq(
          nals.filter(n => n.0 == 5).length(),
          (9 + keyint - 1) / keyint,
        )
        let decoded = match @libavcodec.h264_decode_annexb_frames(batch, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 9)
        let mut start = 0
        let mut r = 0
        while start < 9 {
          let end = (start + keyint).min(9)
          let expected = periodic_b_stream(frames[start:end].to_owned(), {
            ..config,
            keyint: 0,
          })
          assert_eq(idr_concat(aus[start:end].to_owned()), idr_concat(expected))
          // This convenience decoder returns coding order, like recon.
          for pos in 1..<(end - start) {
            if mr_md5(recon[r]) != mr_md5(decoded[start + pos].yuvp()) {
              fail(
                "recon depth=\{depth} cabac=\{cabac} keyint=\{keyint} start=\{start} pos=\{pos}",
              )
            }
            r += 1
          }
          start = end
        }
        assert_eq(recon.length(), r)
      }
    }
  }
}

///|
test "h264 periodic B: manual IDR flushes pending input and restarts interval" {
  let frames = h264p_fixture(32, 32, 13)
  for cabac in [false, true] {
    let config = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      keyint: 4,
      aud: true,
    }
    // At position 2, display position 1 is pending. At position 5 the old
    // pair is complete. Position 6 forces an immediate consecutive IDR.
    let aus = periodic_b_stream(frames, config, forced=[2, 5, 6])
    assert_eq(aus.length(), 13)
    for (start, end) in [(0, 2), (2, 5), (5, 6), (6, 10), (10, 13)] {
      let expected = periodic_b_stream(frames[start:end].to_owned(), {
        ..config,
        keyint: 0,
      })
      assert_eq(idr_concat(aus[start:end].to_owned()), idr_concat(expected))
    }
    let decoded = match
      @libavcodec.h264_decode_annexb_frames(idr_concat(aus), true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 13)
  }
}

///|
test "h264 periodic B: malformed IDR preserves pending frame and interval" {
  let frames = h264p_fixture(32, 32, 5)
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=32, height=32),
    keyint: 2,
  }
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.H264, config~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for i, (y, u, v) in frames {
    if i == 2 {
      match enc.push_frame(b"", u, v, force_idr=true) {
        Ok(_) => fail("malformed forced IDR accepted")
        Err(_) => ()
      }
      assert_eq(enc.drain().length(), 0)
    }
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail(e)
  }
  assert_eq(idr_concat(aus), idr_concat(periodic_b_stream(frames, config)))
}
