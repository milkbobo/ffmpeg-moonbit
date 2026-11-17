///|
/// `§423` fixtures: blocky gradients so the deblock has real edges to work
/// on (the stream is only a valid test of the filter if filtering changes
/// pixels).
fn h264dbg_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
  chroma : Int32,
  bit_depth~ : Int32 = 8,
) -> Array[(Bytes, Bytes, Bytes)] {
  let cw = if chroma == 3 { w } else { w / 2 }
  let ch = if chroma == 1 { h / 2 } else { h }
  let scale = 1 << (bit_depth - 8)
  fn put_sample(out : Array[Byte], v : Int32, bit_depth : Int32) {
    if bit_depth > 8 {
      out.push((v & 0xFF).to_byte())
      out.push(((v >> 8) & 0xFF).to_byte())
    } else {
      out.push((v & 0xFF).to_byte())
    }
  }

  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let base = (col * 3 + row * 5 + f * 11) & 0xFF
        let blocky = if (col / 5 + row / 3) % 2 == 0 { 0 } else { 60 }
        put_sample(y, ((base + blocky) & 0xFF) * scale, bit_depth)
      }
    }
    for row = 0; row < ch; row = row + 1 {
      for col = 0; col < cw; col = col + 1 {
        put_sample(
          u,
          ((col * 2 + row * 3 + f * 7 + 30) & 0xFF) * scale,
          bit_depth,
        )
        put_sample(v, ((col * 5 + row + f * 2 + 80) & 0xFF) * scale, bit_depth)
      }
    }
    frames.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  frames
}

///|
fn h264dbg_pack_planes(
  y : Array[Int32],
  u : Array[Int32],
  v : Array[Int32],
  w : Int32,
  h : Int32,
  ys : Int32,
  cs : Int32,
  chroma : Int32,
  bit_depth~ : Int32 = 8,
) -> Bytes {
  let cw = if chroma == 3 { w } else { w / 2 }
  let ch = if chroma == 1 { h / 2 } else { h }
  let out : Array[Byte] = []
  fn put(out : Array[Byte], v : Int32, bit_depth : Int32) {
    if bit_depth > 8 {
      out.push((v & 0xFF).to_byte())
      out.push(((v >> 8) & 0xFF).to_byte())
    } else {
      out.push((v & 0xFF).to_byte())
    }
  }

  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      put(out, y[row * ys + col], bit_depth)
    }
  }
  for row = 0; row < ch; row = row + 1 {
    for col = 0; col < cw; col = col + 1 {
      put(out, u[row * cs + col], bit_depth)
    }
  }
  for row = 0; row < ch; row = row + 1 {
    for col = 0; col < cw; col = col + 1 {
      put(out, v[row * cs + col], bit_depth)
    }
  }
  Bytes::from_array(out[:])
}

///|
test "h264 deblock: IDR reconstruction equals filtered decode" {
  for chroma in [1, 2, 3] {
    for cabac in [false, true] {
      let frames = h264dbg_fixture(96, 64, 1, chroma)
      let (y, u, v) = frames[0]
      let result = if cabac {
        @libavcodec.h264_encode_intra_frame_cabac(
          y,
          u,
          v,
          width=96,
          height=64,
          qp=26,
          chroma_format=chroma,
        )
      } else {
        @libavcodec.h264_encode_intra_frame(
          y,
          u,
          v,
          width=96,
          height=64,
          qp=26,
          chroma_format=chroma,
        )
      }
      let enc = match result {
        Ok(e) => e
        Err(e) => fail("cf=\{chroma} cabac=\{cabac}: \{e}")
      }
      let filtered = match
        @libavcodec.h264_decode_annexb_frames(enc.annexb, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let plain = match
        @libavcodec.h264_decode_annexb_frames(enc.annexb, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let recon = h264dbg_pack_planes(
        enc.recon_y,
        enc.recon_u,
        enc.recon_v,
        96,
        64,
        enc.ystride,
        enc.cstride,
        chroma,
      )
      // The fixture must exercise the filter: the decoder's default output
      // differs from its skip-loop-filter output.
      assert_true(
        mr_md5(filtered[0].yuvp()) != mr_md5(plain[0].yuvp()),
        msg="fixture must change under the deblock",
      )
      assert_eq(
        mr_md5(recon),
        mr_md5(filtered[0].yuvp()),
        msg="cf=\{chroma} cabac=\{cabac} filtered",
      )
      assert_true(
        mr_md5(recon) != mr_md5(plain[0].yuvp()),
        msg="recon must carry filtered pixels",
      )
    }
  }
}

///|
test "h264 deblock: I+P sequences equal filtered decode" {
  for chroma in [1, 2, 3] {
    for cabac in [false, true] {
      let frames = h264dbg_fixture(96, 64, 5, chroma)
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=chroma,
          b_slices=false,
          recon~,
          deblock=true,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=chroma,
          b_slices=false,
          recon~,
          deblock=true,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail("cf=\{chroma} cabac=\{cabac}: \{e}")
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let plain = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(recon.length(), 4)
      assert_eq(decoded.length(), 5)
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(decoded[i + 1].yuvp()),
          msg="cf=\{chroma} cabac=\{cabac} frame=\{i}",
        )
        assert_true(
          mr_md5(r) != mr_md5(plain[i + 1].yuvp()),
          msg="frame \{i} must be filtered",
        )
      }
    }
  }
}

///|
test "h264 deblock: B schedules equal filtered decode" {
  for chroma in [1, 3] {
    for cabac in [false, true] {
      let frames = h264dbg_fixture(96, 64, 5, chroma)
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=chroma,
          b_slices=true,
          recon~,
          deblock=true,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=chroma,
          b_slices=true,
          recon~,
          deblock=true,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail("cf=\{chroma} cabac=\{cabac}: \{e}")
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(recon.length(), 4)
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(decoded[i + 1].yuvp()),
          msg="cf=\{chroma} cabac=\{cabac} frame=\{i}",
        )
      }
    }
  }
}

///|
test "h264 deblock: ten-bit B schedule equals filtered decode" {
  let frames = h264dbg_fixture(96, 64, 5, 1, bit_depth=10)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      bit_depth=10,
      b_slices=true,
      recon~,
      deblock=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(recon.length(), 4)
  for i, r in recon {
    assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()), msg="frame=\{i}")
  }
}

///|
test "h264 deblock: streaming equals batch and filtered" {
  for b_slices in [false, true] {
    let frames = h264dbg_fixture(96, 64, 5, 1)
    let batch_recon : Array[Bytes] = []
    let batch = match
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        qp=26,
        b_slices~,
        recon=batch_recon,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let enc = match
      @libavcodec.H264StreamEncoder::open(width=96, height=64, qp=26, b_slices~) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let aus : Array[Bytes] = []
    for (y, u, v) in frames {
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
    assert_eq(
      mr_md5(h264s_concat(aus)),
      mr_md5(batch),
      msg="b_slices=\{b_slices}",
    )
    let decoded = match @libavcodec.h264_decode_annexb_frames(batch, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(enc.recons.length(), batch_recon.length())
    for i, r in enc.recons {
      assert_eq(
        mr_md5(r),
        mr_md5(decoded[i + 1].yuvp()),
        msg="stream recon frame=\{i}",
      )
    }
  }
}

///|
test "h264 deblock: facade forwards the flag" {
  let frames = h264dbg_fixture(96, 64, 5, 1)
  let direct = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      deblock=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    b_slices: false,
    deblock: true,
  }
  let via_facade = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(mr_md5(via_facade), mr_md5(direct))
}

///|
test "h264 deblock: default on with explicit opt-out" {
  let frames = h264dbg_fixture(96, 64, 3, 1)
  assert_true(
    @libavcodec.VideoEncConfig::new(width=96, height=64).deblock,
    msg="facade default must enable deblocking",
  )
  for cabac in [false, true] {
    let default_recon : Array[Bytes] = []
    let off_recon : Array[Bytes] = []
    let default_result = if cabac {
      @libavcodec.h264_encode_frames_cabac(
        frames,
        width=96,
        height=64,
        qp=26,
        b_slices=false,
        recon=default_recon,
      )
    } else {
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        qp=26,
        b_slices=false,
        recon=default_recon,
      )
    }
    let off_result = if cabac {
      @libavcodec.h264_encode_frames_cabac(
        frames,
        width=96,
        height=64,
        qp=26,
        b_slices=false,
        recon=off_recon,
        deblock=false,
      )
    } else {
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        qp=26,
        b_slices=false,
        recon=off_recon,
        deblock=false,
      )
    }
    let default_stream = match default_result {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let off_stream = match off_result {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_true(
      default_stream != off_stream,
      msg="cabac=\{cabac}: opt-out must preserve the legacy stream",
    )
    let filtered = match
      @libavcodec.h264_decode_annexb_frames(default_stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    let plain = match @libavcodec.h264_decode_annexb_frames(off_stream, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    for i in 0..<default_recon.length() {
      assert_eq(
        mr_md5(default_recon[i]),
        mr_md5(filtered[i + 1].yuvp()),
        msg="cabac=\{cabac}: default frame=\{i}",
      )
      assert_eq(
        mr_md5(off_recon[i]),
        mr_md5(plain[i + 1].yuvp()),
        msg="cabac=\{cabac}: opt-out frame=\{i}",
      )
    }
  }
}

///|
/// External arbitration (`docker ffmpeg-moonbit-ffref:nine`, FFmpeg 9.0.2):
/// this deblock-enabled CABAC B-schedule stream decodes with zero warnings
/// to `6ed6c2cec81a95e66e174817d4c3cf8a` (display order, packed yuv420p),
/// which equals the local decode; `-skip_loop_filter all` yields
/// `c0c67a327a578a5d497c2b4f3422dec6`, proving the filter is active.
test "h264 deblock: ffmpeg-arbitrated CABAC B stream" {
  let frames = h264dbg_fixture(96, 64, 5, 1)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=true,
      deblock=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let disp = match
    @libavcodec.h264_decode_annexb_display_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  let out : Array[Byte] = []
  for f in disp {
    let p = f.yuvp()
    for i = 0; i < p.length(); i = i + 1 {
      out.push(p[i])
    }
  }
  assert_eq(
    mr_md5(Bytes::from_array(out[:])),
    "6ed6c2cec81a95e66e174817d4c3cf8a",
  )
}

///|
/// `§423` × `§415`/`§418`: the synthetic reference identities drive the
/// bS=1 decision, so multi-reference P and B schedules must filter the same
/// way the decoder does.
test "h264 deblock: multi-reference recon equals filtered decode" {
  for b_slices in [false, true] {
    for cabac in [false, true] {
      let frames = h264dbg_fixture(96, 64, 7, 1)
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          b_slices~,
          multi_ref=3,
          recon~,
          deblock=true,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          b_slices~,
          multi_ref=3,
          recon~,
          deblock=true,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail("b_slices=\{b_slices} cabac=\{cabac}: \{e}")
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(recon.length(), 6)
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(decoded[i + 1].yuvp()),
          msg="b_slices=\{b_slices} cabac=\{cabac} frame=\{i}",
        )
      }
    }
  }
}
