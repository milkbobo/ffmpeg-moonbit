///|
fn online_b_noise(n : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut seed = 1U
  for _ in 0..<n {
    seed = seed * 1664525U + 1013904223U
    out.push((seed >> 24).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(out[:])
}

///|
fn online_b_timing(
  stream : Bytes,
  starts : Array[Int32],
  initial : Int32,
  arrival : Int32,
  capacity : Int32,
) -> Unit raise {
  let nals = vbv_nals(stream)
  let sizes = vbv_au_sizes(nals)
  let ps = @libavcodec.new_h264_param_sets()
  let mut au = 0
  let mut fullness = initial
  let mut last_bp = 0
  let mut gop_start = 0
  let mut has_bp = false
  let mut output_ticks = -1
  let mut timing_count = 0
  for nal in nals {
    let data = vbv_nal_payload(stream, nal)
    let reader = @libavcodec.BitReader::new(data)
    if nal.0 == 7 {
      match @libavcodec.ff_h264_decode_seq_parameter_set(reader, ps, false) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    } else if nal.0 == 8 {
      match
        @libavcodec.ff_h264_decode_picture_parameter_set(
          reader,
          ps,
          data.length() * 8,
        ) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    } else if nal.0 == 6 {
      let (ty, payload) = vbv_sei_message(stream, nal)
      let b = VbvBits::new(payload)
      if ty == 0 {
        assert_true(starts.contains(au))
        assert_eq(b.ue(), 0)
        assert_eq(
          b.u(24),
          (fullness.to_int64() * 90000L / (arrival * 25).to_int64()).to_int(),
        )
        has_bp = true
      } else if ty == 1 {
        assert_eq(b.u(16), (au - last_bp) * 2)
        output_ticks = au * 2 + b.u(4)
        timing_count += 1
      }
    } else if nal.0 == 1 || nal.0 == 5 {
      assert_eq(nal.0 == 5, starts.contains(au))
      if nal.0 == 5 {
        gop_start = au
        assert_true(has_bp)
      }
      let sh = match
        @libavcodec.ff_h264_decode_slice_header(
          reader,
          nal.0,
          (stream[nal.1 + 4].to_int() >> 5) & 3,
          ps,
        ) {
        Ok(h) => h
        Err(e) => fail(e)
      }
      assert_eq(output_ticks, (gop_start + sh.pic_order_cnt_lsb / 2 + 1) * 2)
      assert_true(sizes[au] * 8 <= fullness)
      fullness = fullness - sizes[au] * 8 + arrival
      assert_true(fullness <= capacity)
      if has_bp {
        last_bp = au
        has_bp = false
      }
      au += 1
    }
  }
  assert_eq(timing_count, sizes.length())
}

///|
test "h264 online B VBV: paired scheduling, QPs, CPB and recon" {
  let mut adapted = false
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 8)
    } else {
      h264h10_fixture(32, 32, 8, depth)
    }
    for cabac in [false, true] {
      for keyint in [0, 3, 4] {
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
        let enc = match
          @libavcodec.VideoEncoder::open(
            codec=@libavcodec.H264,
            config~,
            stats~,
          ) {
          Ok(e) => e
          Err(e) => fail(e)
        }
        let aus : Array[Bytes] = []
        for i, (y, u, v) in frames {
          match enc.push_frame(y, u, v) {
            Ok(_) => ()
            Err(e) => fail(e)
          }
          let pos = if keyint == 0 { i } else { i % keyint }
          let want = if pos == 0 {
            if i > 0 && keyint % 2 == 0 {
              2
            } else {
              1
            }
          } else if pos % 2 == 1 {
            0
          } else {
            2
          }
          let ready = enc.drain()
          assert_eq(ready.length(), want)
          for au in ready {
            aus.push(au)
          }
          assert_eq(stats.frame_qps.length(), aus.length())
        }
        match enc.finish() {
          Ok(tail) =>
            for au in tail {
              aus.push(au)
            }
          Err(e) => fail(e)
        }
        assert_eq(aus.length(), 8)
        assert_eq(stats.frame_qps.length(), 8)
        assert_eq(stats.b_mbs, if keyint == 0 { 12 } else { 8 })
        adapted = adapted || stats.frame_qps.any(q => q > 10)
        let stream = idr_concat(aus)
        let starts = if keyint == 0 {
          [0]
        } else if keyint == 3 {
          [0, 3, 6]
        } else {
          [0, 4]
        }
        online_b_timing(stream, starts, 3600, 2560, 4000)
        periodic_brc_check_qps(
          stream,
          { ..config, keyint: if keyint == 0 { 20 } else { keyint }, },
          stats.frame_qps,
        )
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, false) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        let mut r = 0
        for i, f in decoded {
          if !starts.contains(i) {
            assert_eq(mr_md5(enc.h264.recons[r]), mr_md5(f.yuvp()))
            r += 1
          }
        }
        assert_eq(enc.h264.recons.length(), r)
      }
    }
  }
  assert_true(adapted)
}

///|
test "h264 online B VBV: manual IDR flush and all-IDR short GOPs" {
  let flat = (
    Bytes::make(1024, 128),
    Bytes::make(256, 128),
    Bytes::make(256, 128),
  )
  for cabac in [false, true] {
    for keyint in [0, 1, 2] {
      let stats = @libavcodec.H264EncStats::new()
      let enc = match
        @libavcodec.VideoEncoder::open(
          codec=@libavcodec.H264,
          config={
            ..@libavcodec.VideoEncConfig::new(width=32, height=32),
            cabac,
            keyint,
            aud: true,
            vbv_maxrate: 128000,
            vbv_bufsize: 16000,
            fps: 25,
          },
          stats~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for i in 0..<9 {
        match
          enc.push_frame(
            flat.0,
            flat.1,
            flat.2,
            force_idr=keyint == 0 && [2, 5, 6].contains(i),
          ) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          aus.push(au)
        }
      }
      match enc.finish() {
        Ok(t) =>
          for au in t {
            aus.push(au)
          }
        Err(e) => fail(e)
      }
      let starts = if keyint == 0 {
        [0, 2, 5, 6]
      } else if keyint == 1 {
        [0, 1, 2, 3, 4, 5, 6, 7, 8]
      } else {
        [0, 2, 4, 6, 8]
      }
      assert_eq(aus.length(), 9)
      assert_eq(stats.frame_qps.length(), 9)
      assert_true(stats.vbv_filler_bytes > 0)
      online_b_timing(idr_concat(aus), starts, 14400, 5120, 16000)
    }
  }
}

///|
test "h264 online B VBV: failed B rolls back future P and permits tail recovery" {
  let flat = (
    Bytes::make(4096, 128),
    Bytes::make(1024, 128),
    Bytes::make(1024, 128),
  )
  let noise = online_b_noise(4096)
  for cabac in [false, true] {
    let stats = @libavcodec.H264EncStats::new()
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=64,
        height=64,
        cabac~,
        vbv_maxrate=32000,
        vbv_bufsize=1600,
        fps=25,
        stats~,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    match enc.push_frame(flat.0, flat.1, flat.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    match enc.push_frame(noise, flat.1, flat.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    let bits = stats.vbv_bits
    match enc.push_frame(flat.0, flat.1, flat.2) {
      Ok(_) => fail("infeasible B accepted")
      Err(e) => assert_true(e.contains("AU 2"), msg=e)
    }
    assert_eq(enc.next_display, 2)
    assert_true(enc.pending is Some(_))
    assert_eq(stats.vbv_bits, bits)
    assert_eq(stats.frame_qps.length(), 1)
    assert_eq(stats.b_mbs, 0)
    assert_eq(enc.recons.length(), 0)
    let aus = match enc.finish() {
      Ok(t) => t
      Err(e) => fail(e)
    }
    assert_eq(aus.length(), 2)
    assert_eq(enc.next_display, 2)
    assert_true(enc.pending is None)
    assert_eq(stats.frame_qps.length(), 2)
    assert_eq(stats.b_mbs, 0)
    assert_eq(enc.recons.length(), 1)
    let reference = match
      @libavcodec.H264StreamEncoder::open(
        width=64,
        height=64,
        cabac~,
        vbv_maxrate=32000,
        vbv_bufsize=1600,
        fps=25,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    match reference.push_frame(flat.0, flat.1, flat.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    match reference.push_frame(noise, flat.1, flat.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    let expected = match reference.finish() {
      Ok(t) => t
      Err(e) => fail(e)
    }
    assert_eq(idr_concat(aus), idr_concat(expected))
  }
}

///|
test "h264 online B VBV: failed IDR rolls back tail and permits retry" {
  let flat = (
    Bytes::make(4096, 128),
    Bytes::make(1024, 128),
    Bytes::make(1024, 128),
  )
  let noise = online_b_noise(4096)
  for cabac in [false, true] {
    fn run(reject : Bool) -> Bytes raise {
      let stats = @libavcodec.H264EncStats::new()
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=64,
          height=64,
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
        match enc.push_frame(flat.0, flat.1, flat.2) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
      }
      if reject {
        let bits = stats.vbv_bits
        match enc.push_frame(b"", flat.1, flat.2) {
          Ok(_) => fail("bad future plane accepted")
          Err(_) => ()
        }
        match enc.push_frame(noise, flat.1, flat.2, force_idr=true) {
          Ok(_) => fail("infeasible IDR accepted")
          Err(e) => assert_true(e.contains("AU 2"), msg=e)
        }
        assert_eq(enc.next_display, 2)
        assert_true(enc.pending is Some(_))
        assert_eq(stats.vbv_bits, bits)
        assert_eq(stats.frame_qps.length(), 1)
      }
      match enc.push_frame(flat.0, flat.1, flat.2, force_idr=true) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      assert_eq(stats.frame_qps.length(), 3)
      assert_eq(enc.next_display, 3)
      assert_true(enc.pending is None)
      let aus = match enc.finish() {
        Ok(t) => t
        Err(e) => fail(e)
      }
      assert_eq(aus.length(), 3)
      idr_concat(aus)
    }
    assert_eq(run(true), run(false))
  }
}
