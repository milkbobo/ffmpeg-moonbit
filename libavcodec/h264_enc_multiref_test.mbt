// Blackbox tests for the P-slice multi-reference encoder (`§415`/`§416`;
// `§418` lifts the B-schedule restriction — see
// h264_enc_b_multiref_test.mbt for the B coverage). CAVLC
// multi-reference is fully verified: decode round-trip, the recon
// invariant (the `§415` skip/weight slot mismatches are fixed), streaming
// == batch byte identity, and external ffmpeg arbitration. CABAC uses
// the same reference history with partition-local reference write-back.

///|
fn mr_md5(data : Bytes) -> String {
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
test "h264 multiref: all P tools compose at every supported depth" {
  for depth in [8, 9, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 6)
    } else {
      h264h10_fixture(32, 32, 6, depth)
    }
    for cabac in [false, true] {
      for dct8x8 in [false, true] {
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let stream = match
          @libavcodec.video_encode(
            frames,
            codec=@libavcodec.VideoCodec::H264,
            config={
              ..@libavcodec.VideoEncConfig::new(width=32, height=32),
              cabac,
              dct8x8,
              b_slices: false,
              multi_ref: 3,
              bit_depth: depth,
              aud: true,
              weightp: true,
              aq: true,
              aq_strength: 6,
              vbv_maxrate: 200000,
              vbv_bufsize: 32000,
              fps: 25,
            },
            stats~,
            recon~,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        let nals = vbv_nals(stream)
        assert_eq(nals.filter(n => n.0 == 9).length(), 6)
        assert_true(stats.dqp_mbs > 0)
        assert_true(stats.vbv_fills > 0)
        let sizes = vbv_au_sizes(nals)
        assert_eq(sizes.length(), 6)
        let (bits, _) = vbv_cpb_check("all-tools", sizes, 200000, 32000, 25, 90)
        assert_eq(stats.vbv_bits, bits.to_int64())
        assert_eq(stats.frame_qps.length(), 6)
        assert_eq(recon.length(), 5)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, false) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 6)
        for f in decoded {
          assert_eq(f.bit_depth, depth)
        }
        for i, r in recon {
          assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()))
        }
      }
    }
  }
}

///|
test "h264 multiref: VBV history survives two frame_num wraps" {
  let frames = h264p_fixture(32, 32, 35)
  for nrefs in [3, 16] {
    for cabac in [false, true] {
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=32,
            height=32,
            qp=20,
            b_slices=false,
            multi_ref=nrefs,
            vbv_maxrate=200000,
            vbv_bufsize=32000,
            fps=25,
            stats~,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=32,
            height=32,
            qp=20,
            b_slices=false,
            multi_ref=nrefs,
            vbv_maxrate=200000,
            vbv_bufsize=32000,
            fps=25,
            stats~,
            recon~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let sizes = vbv_au_sizes(vbv_nals(stream))
      assert_eq(sizes.length(), 35)
      let (bits, _) = vbv_cpb_check(
        "multiref-wrap", sizes, 200000, 32000, 25, 90,
      )
      assert_eq(bits.to_int64(), stats.vbv_bits)
      assert_eq(stats.frame_qps.length(), 35)
      assert_eq(recon.length(), 34)
      assert_true(stats.vbv_fills > 0)
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 35)
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()))
      }
    }
  }
}

///|
test "h264 multiref: VBV enforces CPB with filler and adaptive QPs" {
  for depth in [8, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 6)
    } else {
      h264h10_fixture(32, 32, 6, depth)
    }
    for cabac in [false, true] {
      for tight in [false, true] {
        let rate = if tight { 12000 } else { 200000 }
        let buffer = if tight { 4000 } else { 32000 }
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let stream = match
          (if cabac {
            @libavcodec.h264_encode_frames_cabac(
              frames,
              width=32,
              height=32,
              qp=20,
              b_slices=false,
              multi_ref=3,
              bit_depth=depth,
              vbv_maxrate=rate,
              vbv_bufsize=buffer,
              fps=25,
              stats~,
              recon~,
            )
          } else {
            @libavcodec.h264_encode_frames(
              frames,
              width=32,
              height=32,
              qp=20,
              b_slices=false,
              multi_ref=3,
              bit_depth=depth,
              vbv_maxrate=rate,
              vbv_bufsize=buffer,
              fps=25,
              stats~,
              recon~,
            )
          }) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        let nals = vbv_nals(stream)
        // Catch silent fallback to single-reference inside either VBV
        // wrapper, even when encoder and decoder otherwise agree.
        let ps = @libavcodec.new_h264_param_sets()
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
          }
        }
        assert_eq(ps.sps_list[0].unwrap().ref_frame_count, 3)
        let sizes = vbv_au_sizes(nals)
        assert_eq(sizes.length(), 6)
        let (bits, _) = vbv_cpb_check("multiref", sizes, rate, buffer, 25, 90)
        assert_eq(bits.to_int64(), stats.vbv_bits)
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
        assert_eq(stats.frame_qps.length(), 6)
        if tight {
          assert_true(stats.frame_qps.any(q => q > 20))
        } else {
          assert_true(stats.vbv_fills > 0)
          assert_true(nals.any(n => n.0 == 12))
        }
        assert_eq(recon.length(), 5)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, false) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 6)
        for i, r in recon {
          assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()))
        }
      }
    }
  }
}

///|
test "h264 multiref: average-byte control preserves recon and final-pass stats" {
  for depth in [8, 10] {
    let frames = if depth == 8 {
      h264p_fixture(32, 32, 5)
    } else {
      h264h10_fixture(32, 32, 5, depth)
    }
    for cabac in [false, true] {
      fn encode(
        qp : Int32,
        target : Int32,
        stats : @libavcodec.H264EncStats,
        recon : Array[Bytes],
      ) -> Bytes raise {
        match
          (if cabac {
            @libavcodec.h264_encode_frames_cabac(
              frames,
              width=32,
              height=32,
              qp~,
              target_bytes=target,
              b_slices=false,
              multi_ref=3,
              bit_depth=depth,
              stats~,
              recon~,
            )
          } else {
            @libavcodec.h264_encode_frames(
              frames,
              width=32,
              height=32,
              qp~,
              target_bytes=target,
              b_slices=false,
              multi_ref=3,
              bit_depth=depth,
              stats~,
              recon~,
            )
          }) {
          Ok(s) => s
          Err(e) => fail(e)
        }
      }
      let flat = encode(20, 0, @libavcodec.H264EncStats::new(), [])
      let coarse = encode(51, 0, @libavcodec.H264EncStats::new(), [])
      assert_true(coarse.length() < flat.length())
      let target = (flat.length() + coarse.length()) / 2
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let stream = encode(20, target, stats, recon)
      assert_true(
        stream.length() <= target,
        msg="\{stream.length()} > \{target}",
      )
      assert_eq(stats.frame_qps.length(), 5)
      assert_true(stats.frame_qps.any(q => q > 20))
      for q in stats.frame_qps {
        assert_true(q >= 0 && q <= 51)
      }
      assert_eq(recon.length(), 4)
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 5)
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()))
      }
      let fallback_stats = @libavcodec.H264EncStats::new()
      let fallback = encode(20, 1, fallback_stats, [])
      // The PPS retains the caller's base QP, so equal picture QPs need
      // not produce identical bytes (slice_qp_delta differs).
      let fallback_dec = match
        @libavcodec.h264_decode_annexb_frames(fallback, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let coarse_dec = match
        @libavcodec.h264_decode_annexb_frames(coarse, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(fallback_dec.length(), 5)
      for i, f in fallback_dec {
        assert_eq(mr_md5(f.yuvp()), mr_md5(coarse_dec[i].yuvp()))
      }
      assert_eq(fallback_stats.frame_qps.length(), 5)
      for q in fallback_stats.frame_qps {
        assert_eq(q, 51)
      }
    }
  }
}

///|
test "h264 multiref: chroma-only changes are coded and older colors are reused" {
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<7 {
    let c = Bytes::from_array(
      Array::makei(256, i => {
        (if (i / 16 / 2 + i % 16 / 2 + f % 2) % 2 == 0 { 40 } else { 210 }).to_byte()
      })[:],
    )
    frames.push((Bytes::make(1024, 128), c, c))
  }
  for cabac in [false, true] {
    let sizes : Array[Int32] = []
    for nrefs in [1, 2] {
      let recon : Array[Bytes] = []
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=32,
            height=32,
            qp=16,
            b_slices=false,
            weightp=false,
            multi_ref=nrefs,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=32,
            height=32,
            qp=16,
            b_slices=false,
            weightp=false,
            multi_ref=nrefs,
            recon~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      sizes.push(stream.length())
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 7)
      for i in 1..<7 {
        let packed = decoded[i].yuvp()
        assert_eq(mr_md5(recon[i - 1]), mr_md5(packed))
        let mut error = 0
        for j in 0..<256 {
          let d = packed[1024 + j].to_int() - frames[i].1[j].to_int()
          error += if d < 0 { -d } else { d }
        }
        assert_true(
          error < 256 * 16,
          msg="chroma error \{error} at frame \{i}, cabac=\{cabac} refs=\{nrefs}",
        )
      }
    }
    assert_true(sizes[1] < sizes[0], msg="one=\{sizes[0]}, two=\{sizes[1]}")
  }
}

///|
test "h264 multiref: reference eviction survives two frame_num wraps" {
  let frames = h264p_fixture(32, 32, 35)
  for nrefs in [3, 16] {
    for cabac in [false, true] {
      let recon : Array[Bytes] = []
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=32,
            height=32,
            qp=26,
            b_slices=false,
            multi_ref=nrefs,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=32,
            height=32,
            qp=26,
            b_slices=false,
            multi_ref=nrefs,
            recon~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(dec.length(), 35)
      assert_eq(recon.length(), 34)
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(dec[i + 1].yuvp()), msg="frame \{i + 1}")
      }
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=32,
          height=32,
          qp=26,
          b_slices=false,
          cabac~,
          multi_ref=nrefs,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let out : Array[Byte] = []
      for (y, u, v) in frames {
        match enc.push_frame(y, u, v) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          for b in au {
            out.push(b)
          }
        }
      }
      match enc.finish() {
        Ok(aus) =>
          for au in aus {
            for b in au {
              out.push(b)
            }
          }
        Err(e) => fail(e)
      }
      assert_eq(mr_md5(Bytes::from_array(out[:])), mr_md5(stream))
    }
  }
}

///|
test "h264 multiref: CABAC recon and streaming agree across reference counts" {
  for nrefs in [2, 3, 16] {
    for dct8x8 in [false, true] {
      let frames = mr_toggle_fixture(7)
      let recon : Array[Bytes] = []
      let batch = match
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          b_slices=false,
          multi_ref=nrefs,
          dct8x8~,
          recon~,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(batch, false) {
        Ok(f) => f
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), frames.length())
      assert_eq(recon.length(), frames.length() - 1)
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()))
      }
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=96,
          height=64,
          qp=26,
          cabac=true,
          b_slices=false,
          multi_ref=nrefs,
          dct8x8~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let out : Array[Byte] = []
      for (y, u, v) in frames {
        match enc.push_frame(y, u, v) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          for b in au {
            out.push(b)
          }
        }
      }
      match enc.finish() {
        Ok(aus) =>
          for au in aus {
            for b in au {
              out.push(b)
            }
          }
        Err(e) => fail(e)
      }
      assert_eq(mr_md5(Bytes::from_array(out[:])), mr_md5(batch))
    }
  }
}

///|
test "h264 multiref: CABAC motion reference write-back preserves recon" {
  for rd in [false, true] {
    for depth in [8, 10] {
      let frames = if depth == 8 {
        h264p_fixture(96, 64, 6)
      } else {
        h264h10_fixture(96, 64, 6, depth)
      }
      let recon : Array[Bytes] = []
      let stream = match
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          b_slices=false,
          multi_ref=2,
          cabac_rd=rd,
          bit_depth=depth,
          recon~,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(f) => f
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 6)
      assert_eq(recon.length(), 5)
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(decoded[i + 1].yuvp()))
      }
    }
  }
}

///|
test "h264 multiref: multi_ref=1 is byte-identical to the default" {
  let frames = h264p_fixture(96, 64, 5)
  for cabac in [false, true] {
    let default_stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=26)
      } else {
        @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26)
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let explicit_one = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          multi_ref=1,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          multi_ref=1,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_eq(mr_md5(default_stream), mr_md5(explicit_one))
  }
}

///|
test "h264 multiref: two references round-trip with the recon invariant" {
  let frames = h264p_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 6)
  assert_eq(recon.length(), 5)
  // `§416`: the recon invariant holds — the `§415` divergences (skips
  // committed after the reference switch, weighted MC reading entry-0
  // offsets for entry-1 references) are fixed.
  for i, r in recon {
    assert_eq(
      mr_md5(r),
      mr_md5(dec[i + 1].yuvp()),
      msg="P frame \{i + 1}: encoder recon != decoder recon",
    )
  }
  // The parameter sets signal the active count: SPS max_num_ref_frames
  // and the PPS default L0 count are 2 — a full decode already proved
  // the parser consumes the per-partition ref_idx elements.
  if dec[1].bit_depth != 8 {
    fail("multiref stream decoded at the wrong depth")
  }
}

///|
/// A two-position toggle: even pictures show pattern A, odd pictures
/// pattern B. Every odd P picture's best reference is the picture two
/// back (the previous A), which multi-reference finds and single
/// -reference cannot — the case the tool exists for.
fn mr_toggle_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let phase = f % 2
    let bx = if phase == 0 { 8 } else { 56 }
    let by = if phase == 0 { 8 } else { 32 }
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 3 + row * 5) & 0x7F
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox && (col == bx || col == bx + 15 || row == by || row == by + 15) {
          s = 30
        } else if inbox {
          s = 210
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((96 + ((col / 2 + phase * 8) & 0x3F)).to_byte())
        v.push((96 + ((row / 2 + phase * 4) & 0x3F)).to_byte())
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
test "h264 multiref: a toggle scene codes far smaller with two refs" {
  let frames = mr_toggle_fixture(7)
  let one = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=1,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let two = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // The odd pictures become near-skips against their true match two back;
  // the two-reference stream must be dramatically smaller (the syntax
  // overhead of ref_idx/PWT entries is a few bytes per picture). With
  // YUV distortion priced, require at least 10% savings rather than the
  // old luma-only decision's 20%; the color residuals are now retained.
  assert_true(
    two.length() * 10 < one.length() * 9,
    msg="toggle scene: two-ref \{two.length()} B not clearly smaller than one-ref \{one.length()} B",
  )
  let dec = match @libavcodec.h264_decode_annexb_frames(two, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 7)
}

///|
test "h264 multiref: streaming matches the batch stream" {
  let frames = h264p_fixture(96, 64, 6)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
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
  let out : Array[Byte] = []
  for au in aus {
    for b in au {
      out.push(b)
    }
  }
  assert_eq(mr_md5(Bytes::from_array(out[:])), mr_md5(batch))
}

///|
test "h264 multiref: High 10 composes" {
  let frames = h264h10_fixture(96, 64, 4, 10)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      bit_depth=10,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  for f in dec {
    assert_eq(f.bit_depth, 10)
  }
  for i, r in recon {
    assert_eq(mr_md5(r), mr_md5(dec[i + 1].yuvp()))
  }
}

///|
test "h264 multiref: combination and range validation" {
  let frames = h264p_fixture(96, 64, 4)
  // Even the headers cannot fit this legal, tiny CPB. Do not emit an
  // invalid stream after reaching the coarsest QP.
  for cabac in [false, true] {
    match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          b_slices=false,
          multi_ref=2,
          vbv_maxrate=64,
          vbv_bufsize=256,
          fps=25,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          b_slices=false,
          multi_ref=2,
          vbv_maxrate=64,
          vbv_bufsize=256,
          fps=25,
        )
      }) {
      Ok(_) => fail("impossible multi-reference CPB was accepted")
      Err(e) => assert_true(e.contains("vbv underflow"), msg=e)
    }
  }
  // `§418`: B slices with multi-reference now encode (previously rejected)
  // and round-trip through the decoder.
  for cabac in [false, true] {
    let recon : Array[Bytes] = []
    let bstream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          multi_ref=2,
          recon~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          multi_ref=2,
          recon~,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let bdec = match @libavcodec.h264_decode_annexb_frames(bstream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(bdec.length(), 4)
    assert_eq(recon.length(), 3)
    for i, r in recon {
      assert_eq(mr_md5(r), mr_md5(bdec[i + 1].yuvp()))
    }
  }
  match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      vbv_bufsize=1500,
    ) {
    Ok(_) => fail("CABAC multi_ref accepted incomplete VBV parameters")
    Err(_) => ()
  }
  // Incomplete VBV parameter groups remain invalid.
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      vbv_bufsize=1500,
    ) {
    Ok(_) => fail("multi_ref accepted incomplete VBV parameters")
    Err(_) => ()
  }
  // Range: 0 and 17 are out of the documented 1..=16.
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=0,
    ) {
    Ok(_) => fail("multi_ref accepted 0")
    Err(_) => ()
  }
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=17,
    ) {
    Ok(_) => fail("multi_ref accepted 17")
    Err(_) => ()
  }
  // A depth beyond the sequence length degrades to the picture count.
  let two = match
    @libavcodec.h264_encode_frames(
      [frames[0], frames[1]],
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=4,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(two, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 2)
}
