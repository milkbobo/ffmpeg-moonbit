// Blackbox tests for the unified video-encode facade (`§414`): the batch
// entry must be byte-identical to the codec's own entry points (it is a
// pure forwarder) and the streaming entry to `H264StreamEncoder`; the
// facade additionally owns the pixel-format naming, the codec selector
// and the streaming/rate-control exclusion that used to live in the CLI.

///|
fn ve_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "video enc: multiref VBV forwards to both batch encoders" {
  let frames = h264p_fixture(32, 32, 6)
  for cabac in [false, true] {
    let config = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      b_slices: false,
      multi_ref: 3,
      qp: 20,
      vbv_maxrate: 200000,
      vbv_bufsize: 32000,
      fps: 25,
    }
    let via = match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.VideoCodec::H264,
        config~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let direct = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=32,
          height=32,
          qp=20,
          b_slices=false,
          multi_ref=3,
          vbv_maxrate=200000,
          vbv_bufsize=32000,
          fps=25,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=32,
          height=32,
          qp=20,
          b_slices=false,
          multi_ref=3,
          vbv_maxrate=200000,
          vbv_bufsize=32000,
          fps=25,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_eq(ve_md5(via), ve_md5(direct))
  }
}

///|
test "video enc: multiref average-byte targeting forwards to both encoders" {
  let frames = h264p_fixture(32, 32, 5)
  for cabac in [false, true] {
    let config = {
      ..@libavcodec.VideoEncConfig::new(width=32, height=32),
      cabac,
      b_slices: false,
      multi_ref: 3,
      qp: 20,
      target_bytes: 300,
    }
    let via = match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.VideoCodec::H264,
        config~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let direct = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=32,
          height=32,
          qp=20,
          target_bytes=300,
          b_slices=false,
          multi_ref=3,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=32,
          height=32,
          qp=20,
          target_bytes=300,
          b_slices=false,
          multi_ref=3,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_eq(ve_md5(via), ve_md5(direct))
  }
}

///|
test "video enc: facade batch is byte-identical to the h264 entries" {
  let frames = h264p_fixture(96, 64, 6)
  for cabac in [false, true] {
    let config = {
      ..@libavcodec.VideoEncConfig::new(width=96, height=64),
      cabac,
    }
    let via = match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.VideoCodec::H264,
        config~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let direct = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          cabac_rd=config.cabac_rd,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          width=config.width,
          height=config.height,
          qp=config.qp,
          aq=config.aq,
          aq_strength=config.aq_strength,
          aud=config.aud,
          bit_depth=config.bit_depth,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          width=config.width,
          height=config.height,
          qp=config.qp,
          aq=config.aq,
          aq_strength=config.aq_strength,
          aud=config.aud,
          bit_depth=config.bit_depth,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_eq(ve_md5(via), ve_md5(direct))
    // The B-GOP default stays on through the facade.
    let dec = match @libavcodec.h264_decode_annexb_frames(via, true) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 6)
  }
}

///|
test "video enc: facade forwards rate controls byte-identically" {
  let frames = h264_rc_fixture(5)
  for
    (tag, config, cabac) in [
      (
        "abr",
        {
          ..@libavcodec.VideoEncConfig::new(width=64, height=48),
          target_bytes: 1500,
        },
        false,
      ),
      (
        "vbv-cavlc",
        {
          ..@libavcodec.VideoEncConfig::new(width=64, height=48),
          vbv_maxrate: 90000,
          vbv_bufsize: 18000,
          fps: 30,
        },
        false,
      ),
      (
        "vbv-cabac",
        {
          ..@libavcodec.VideoEncConfig::new(width=64, height=48),
          cabac: true,
          vbv_maxrate: 60000,
          vbv_bufsize: 12000,
          fps: 30,
        },
        true,
      ),
    ] {
    let via = match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.VideoCodec::H264,
        config~,
      ) {
      Ok(s) => s
      Err(e) => fail("\{tag}: \{e}")
    }
    let direct = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          cabac_rd=config.cabac_rd,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          width=config.width,
          height=config.height,
          qp=config.qp,
          aq=config.aq,
          aq_strength=config.aq_strength,
          aud=config.aud,
          target_bytes=config.target_bytes,
          vbv_maxrate=config.vbv_maxrate,
          vbv_bufsize=config.vbv_bufsize,
          fps=config.fps,
          bit_depth=config.bit_depth,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          width=config.width,
          height=config.height,
          qp=config.qp,
          aq=config.aq,
          aq_strength=config.aq_strength,
          aud=config.aud,
          target_bytes=config.target_bytes,
          vbv_maxrate=config.vbv_maxrate,
          vbv_bufsize=config.vbv_bufsize,
          fps=config.fps,
          bit_depth=config.bit_depth,
        )
      }) {
      Ok(s) => s
      Err(e) => fail("\{tag}: \{e}")
    }
    assert_eq(ve_md5(via), ve_md5(direct), msg=tag)
  }
}

///|
test "video enc: streaming facade matches H264StreamEncoder and the batch" {
  let frames = h264p_fixture(96, 64, 5)
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    b_slices: false,
  }
  let via = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config~) {
    Ok(enc) => enc
    Err(e) => fail(e)
  }
  let streamed : Array[Byte] = []
  for (y, u, v) in frames {
    match via.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in via.drain() {
      for b in au {
        streamed.push(b)
      }
    }
  }
  match via.finish() {
    Ok(tail) =>
      for au in tail {
        for b in au {
          streamed.push(b)
        }
      }
    Err(e) => fail(e)
  }
  let joined = Bytes::from_array(streamed[:])
  // Same bytes through the codec's own streaming entry.
  let direct = match
    @libavcodec.H264StreamEncoder::open(
      width=config.width,
      height=config.height,
      qp=config.qp,
      cabac=config.cabac,
      cabac_rd=config.cabac_rd,
      dct8x8=config.dct8x8,
      b_slices=config.b_slices,
      b_parts=config.b_parts,
      intra_in_b=config.intra_in_b,
      intra4x4_in_b=config.intra4x4_in_b,
      weightp=config.weightp,
      bit_depth=config.bit_depth,
    ) {
    Ok(enc) => enc
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match direct.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let direct_bytes = match direct.finish() {
    Ok(aus) => {
      let mut total = 0
      for au in aus {
        total = total + au.length()
      }
      let buf : Array[Byte] = Array::make(total, b'\x00')
      let mut pos = 0
      for au in aus {
        for i = 0; i < au.length(); i = i + 1 {
          buf[pos] = au[i]
          pos = pos + 1
        }
      }
      Bytes::from_array(buf[:])
    }
    Err(e) => fail(e)
  }
  assert_eq(ve_md5(joined), ve_md5(direct_bytes))
  // And the batch entry agrees with both (the long-standing stream==batch
  // invariant, pinned here through the facade).
  let batch = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(ve_md5(joined), ve_md5(batch))
  // Reporting accessors.
  assert_eq(via.codec_name(), "h264")
  assert_eq(via.pixel_format(), "yuv420p")
  assert_eq(via.width(), 96)
  assert_eq(via.height(), 64)
}

///|
test "video enc: pixel format naming and High 10 through the facade" {
  assert_eq(@libavcodec.video_pixel_format(8), "yuv420p")
  assert_eq(@libavcodec.video_pixel_format(9), "yuv420p9le")
  assert_eq(@libavcodec.video_pixel_format(10), "yuv420p10le")
  let frames = h264h10_fixture(96, 64, 3, 10)
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    cabac: true,
    bit_depth: 10,
  }
  let stream = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // High 10 profile byte after the SPS NAL header.
  assert_eq(stream[5], b'\x6e')
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  for f in dec {
    assert_eq(f.bit_depth, 10)
  }
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  assert_eq(enc.pixel_format(), "yuv420p10le")
}

///|
test "video enc: facade error surface" {
  // ABR remains batch-only; incomplete VBV is rejected.
  match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config={
      ..@libavcodec.VideoEncConfig::new(width=64, height=48),
      target_bytes: 1500,
    }) {
    Ok(_) => fail("streaming accepted target_bytes")
    Err(_) => ()
  }
  match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config={
      ..@libavcodec.VideoEncConfig::new(width=64, height=48),
      vbv_maxrate: 90000,
      vbv_bufsize: 0,
      fps: 30,
    }) {
    Ok(_) => fail("streaming accepted incomplete VBV")
    Err(_) => ()
  }
  // Codec-level validation passes through unchanged (bad depth, geometry).
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=64, height=48),
    bit_depth: 11,
  }
  match
    @libavcodec.video_encode(
      h264_rc_fixture(2),
      codec=@libavcodec.VideoCodec::H264,
      config~,
    ) {
    Ok(_) => fail("facade accepted bit_depth 11")
    Err(e) => assert_true(e.contains("bit depth"), msg=e)
  }
  let bad_geom = @libavcodec.VideoEncConfig::new(width=63, height=48)
  match
    @libavcodec.video_encode(
      h264_rc_fixture(2),
      codec=@libavcodec.VideoCodec::H264,
      config=bad_geom,
    ) {
    Ok(_) => fail("facade accepted odd width")
    Err(_) => ()
  }
  let codec = @libavcodec.VideoCodec::H264
  match
    @libavcodec.VideoEncoder::open(
      codec~,
      config=@libavcodec.VideoEncConfig::new(width=63, height=48),
    ) {
    Ok(_) => fail("streaming accepted odd width")
    Err(_) => ()
  }
}
