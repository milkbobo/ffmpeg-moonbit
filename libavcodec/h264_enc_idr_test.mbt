///|
test "h264 stream: forced IDR starts independent multi-reference GOPs" {
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 8)
    } else {
      h264h10_fixture(32, 32, 8, depth)
    }
    for
      (cabac, aud) in [
        (false, false),
        (false, true),
        (true, false),
        (true, true),
      ] {
      let config = {
        ..@libavcodec.VideoEncConfig::new(width=32, height=32),
        cabac,
        b_slices: false,
        multi_ref: 3,
        bit_depth: depth,
        aq: true,
        aq_strength: 6,
        aud,
      }
      let enc = match
        @libavcodec.VideoEncoder::open(
          codec=@libavcodec.VideoCodec::H264,
          config~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for i, (y, u, v) in frames {
        match enc.push_frame(y, u, v, force_idr=i == 0 || i == 3 || i == 4) {
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
      assert_eq(aus.length(), 8)
      let stream = idr_concat(aus)
      let nals = vbv_nals(stream)
      for ty in [5, 7, 8] {
        assert_eq(nals.filter(n => n.0 == ty).length(), 3)
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 8)
      for (start, end) in [(0, 3), (3, 4), (4, 8)] {
        let segment = frames[start:end].to_owned()
        let expected = match
          @libavcodec.video_encode(
            segment,
            codec=@libavcodec.VideoCodec::H264,
            config~,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_eq(
          mr_md5(idr_concat(aus[start:end].to_owned())),
          mr_md5(expected),
        )
        let independent = match
          @libavcodec.h264_decode_annexb_frames(expected, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(independent.length(), end - start)
        for i, f in independent {
          assert_eq(mr_md5(f.yuvp()), mr_md5(decoded[start + i].yuvp()))
        }
      }
    }
  }
}

///|
fn idr_concat(aus : Array[Bytes]) -> Bytes {
  let data : Array[Byte] = []
  for au in aus {
    for byte in au {
      data.push(byte)
    }
  }
  Bytes::from_array(data[:])
}

///|
test "h264 keyint: unsupported combinations fail explicitly" {
  let base = @libavcodec.VideoEncConfig::new(width=32, height=32)
  let frames = h264p_fixture(32, 32, 2)
  for
    config in [
      { ..base, keyint: -1, },
      { ..base, keyint: 2, target_bytes: 1000, multi_ref: 2, },
      { ..base, keyint: 2, multi_ref: 2, },
      {
        ..base,
        keyint: 2,
        vbv_maxrate: 64000,
        vbv_bufsize: 8000,
        fps: 25,
        target_bytes: 1000,
      },
      { ..base, keyint: 2, b_slices: false, fps: 25, },
      {
        ..base,
        keyint: 2,
        b_slices: false,
        vbv_maxrate: 200000,
        vbv_bufsize: 0,
        fps: 25,
      },
    ] {
    match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.VideoCodec::H264,
        config~,
      ) {
      Ok(_) => fail("unsupported keyint configuration accepted")
      Err(_) => ()
    }
  }
  match
    @libavcodec.video_encode([], codec=@libavcodec.VideoCodec::H264, config={
      ..base,
      keyint: 2,
      b_slices: false,
    }) {
    Ok(_) => fail("empty periodic sequence accepted")
    Err(_) => ()
  }
}

///|
test "h264 keyint: periodic batch GOPs match independent encodes" {
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 8)
    } else {
      h264h10_fixture(32, 32, 8, depth)
    }
    for cabac in [false, true] {
      for keyint in [0, 1, 3, 20] {
        let config = {
          ..@libavcodec.VideoEncConfig::new(width=32, height=32),
          cabac,
          keyint,
          b_slices: false,
          multi_ref: 3,
          bit_depth: depth,
          aq: true,
          aq_strength: 6,
          aud: true,
        }
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let stream = match
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
        let interval = if keyint == 0 { 8 } else { keyint }
        let idrs = (8 + interval - 1) / interval
        assert_eq(vbv_nals(stream).filter(n => n.0 == 5).length(), idrs)
        assert_eq(stats.frame_qps.length(), 8)
        assert_eq(recon.length(), 8 - idrs)
        let independent : Array[Bytes] = []
        for start = 0; start < 8; start = start + interval {
          let segment = frames[start:(start + interval).min(8)].to_owned()
          match
            @libavcodec.video_encode(
              segment,
              codec=@libavcodec.VideoCodec::H264,
              config={ ..config, keyint: 0, },
            ) {
            Ok(s) => independent.push(s)
            Err(e) => fail(e)
          }
        }
        assert_eq(mr_md5(stream), mr_md5(idr_concat(independent)))
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 8)
        let mut r = 0
        for i in 0..<8 {
          if i % interval != 0 {
            assert_eq(mr_md5(recon[r]), mr_md5(decoded[i].yuvp()))
            r += 1
          }
        }
      }
    }
  }
}

///|
test "h264 keyint: manual IDR restarts the periodic interval" {
  let frames = h264p_fixture(32, 32, 8)
  for cabac in [false, true] {
    let enc = match
      @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config={
        ..@libavcodec.VideoEncConfig::new(width=32, height=32),
        cabac,
        b_slices: false,
        multi_ref: 3,
        keyint: 3,
      }) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    for i, (y, u, v) in frames {
      match enc.push_frame(y, u, v, force_idr=i == 1) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      let aus = enc.drain()
      assert_eq(aus.length(), 1)
      assert_eq(
        vbv_nals(aus[0]).any(n => n.0 == 5),
        i == 0 || i == 1 || i == 4 || i == 7,
      )
    }
  }
}

///|
test "h264 stream: malformed B-frame IDR request does not consume input" {
  let frames = h264p_fixture(32, 32, 3)
  let enc = match @libavcodec.H264StreamEncoder::open(width=32, height=32) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let (y, u, v) = frames[0]
  match enc.push_frame(y, u, v, force_idr=true) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  let (_, u, v) = frames[1]
  match enc.push_frame(b"", u, v, force_idr=true) {
    Ok(_) => fail("malformed forced IDR accepted")
    Err(e) => assert_true(e.contains("plane size"))
  }
  for (y, u, v) in frames[1:] {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let aus = match enc.finish() {
    Ok(a) => a
    Err(e) => fail(e)
  }
  let expected = match
    @libavcodec.h264_encode_frames(frames, width=32, height=32) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(mr_md5(idr_concat(aus)), mr_md5(expected))
}
