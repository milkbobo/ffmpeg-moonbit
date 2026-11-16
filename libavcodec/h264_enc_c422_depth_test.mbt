///|
/// §422d fixture: 4:2:2 planes at `depth` (little-endian 16-bit samples
/// above 8 bits). Moving luma box, column-gradient Cb and row-stepped Cr at
/// full chroma height, as in `§420` but depth-lifted.
fn c422d_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
  depth : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        y.push(((col * 2 + row * 3 + f * 7) & 0xFF).to_byte())
      }
    }
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col + f * 3) & 0x3F) + 96).to_byte())
        v.push((((row / 2 + f) & 0x3F) + 96).to_byte())
      }
    }
    let lift = (plane : Array[Byte]) => {
      if depth == 8 {
        Bytes::from_array(plane[:])
      } else {
        let bytes : Array[Byte] = []
        for b in plane {
          let value = b.to_int() << (depth - 8)
          bytes.push((value & 255).to_byte())
          bytes.push((value >> 8).to_byte())
        }
        Bytes::from_array(bytes[:])
      }
    }
    frames.push((lift(y), lift(u), lift(v)))
  }
  frames
}

///|
/// §422d: 4:2:2 at 9/10/12/14 bits round-trips in both entropies. The
/// parameter sets stay High 4:2:2 (122) through 10 bits and switch to
/// Hi444PP (244) above it — the only profile family that carries
/// bit_depth_minus8 > 2 — while chroma_format_idc stays 2. The recon
/// invariant (encoder recon == local skip-filter decode, encode order)
/// holds for the default B schedule.
test "h264 c422 depth: round trip in both entropies" {
  for bit_depth in [9, 10, 12, 14] {
    for cabac in [false, true] {
      let frames = c422d_fixture(96, 64, 7, bit_depth)
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=26,
            chroma_format=2,
            bit_depth~,
            recon~,
            stats~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=26,
            chroma_format=2,
            bit_depth~,
            recon~,
            stats~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail("depth=\{bit_depth} cabac=\{cabac}: \{e}")
      }
      assert_true(stats.b_mbs > 0)
      let ps = @libavcodec.new_h264_param_sets()
      let mut profile = 0
      for nal in vbv_nals(stream) {
        if nal.0 == 7 {
          profile = vbv_nal_payload(stream, nal)[0].to_int()
          match
            @libavcodec.ff_h264_decode_seq_parameter_set(
              @libavcodec.BitReader::new(vbv_nal_payload(stream, nal)),
              ps,
              false,
            ) {
            Ok(_) => ()
            Err(e) => fail("depth=\{bit_depth} sps: \{e}")
          }
        }
      }
      assert_eq(
        profile,
        if bit_depth > 10 {
          244
        } else {
          122
        },
        msg="depth=\{bit_depth} cabac=\{cabac}",
      )
      let sps = ps.sps_list[0].unwrap()
      assert_eq(sps.chroma_format_idc, 2)
      assert_eq(sps.bit_depth_luma, bit_depth)
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail("depth=\{bit_depth} cabac=\{cabac} decode: \{e}")
      }
      assert_eq(dec.length(), 7)
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(dec[i + 1].yuvp()),
          msg="depth=\{bit_depth} cabac=\{cabac} frame \{i}",
        )
      }
    }
  }
}

///|
/// §422d: the streaming encoder reproduces the batch stream byte for byte
/// at depth (both profile families: 122 at 10 bits, 244 at 12).
test "h264 c422 depth: streaming matches the batch bytes" {
  for bit_depth in [10, 12] {
    let frames = c422d_fixture(96, 64, 5, bit_depth)
    for cabac in [false, true] {
      let batch = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=26,
            chroma_format=2,
            bit_depth~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=26,
            chroma_format=2,
            bit_depth~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=96,
          height=64,
          qp=26,
          cabac~,
          chroma_format=2,
          bit_depth~,
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
      assert_eq(
        mr_md5(Bytes::from_array(out[:])),
        mr_md5(batch),
        msg="depth=\{bit_depth} cabac=\{cabac}",
      )
    }
  }
}

///|
/// §422d external arbitration anchors: a 10-bit CAVLC and a 12-bit CABAC
/// 4:2:2 stream for the docker ffmpeg framemd5 oracle; `ARBC22D10:` /
/// `ARBC22D12:` carry the annexb bytes for re-arbitration. The display
/// MD5s pin FFmpeg's deblocked output.
test "h264 c422 depth: ffmpeg-arbitrated streams" {
  for depth in [10, 12] {
    let cabac = depth == 12
    let frames = c422d_fixture(96, 64, 6, depth)
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=2,
          bit_depth=depth,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=2,
          bit_depth=depth,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let mut dump = ""
    for i = 0; i < stream.length(); i = i + 1 {
      dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
    }
    println("ARBC22D\{depth}:\{dump}")
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 6)
    let disp = h264p_decode_to_display(6)
    let by_display : Array[@libavcodec.H264Frame] = Array::make(6, dec[0])
    for i, f in dec {
      by_display[disp[i]] = f
    }
    let mut md5s = "C422DMD5 d=\{depth}:"
    for f in by_display {
      md5s = md5s + " " + mr_md5(f.yuvp())
    }
    println(md5s)
    // FFmpeg-arbitrated display MD5s (docker framemd5, zero warnings,
    // identical to the local default decode).
    let pins = if depth == 10 {
      // §422e re-arbitration: the B inter 8x8 RD choice changed frames
      // 1/3/5 (the CABAC 12-bit arm kept its 4x4 winners and pins).
      [
        "f9694f078d474a895e6b9cdd9e782dff", "4de5ebca95315636bf188ffa8b3c56c2", "a9df55160abea7aa3e4266255c5ac97d",
        "e48e320883e666f02918220ab31a3098", "55529990344effea214208103816db12", "d2157c6b1b06f038ceb7321c088507b6",
      ]
    } else {
      // §422e re-arbitration (the two display B frames).
      [
        "93a1440884d20df22e6a2693f72ffacb", "b508478788b05a073f036ca7902117fb", "365beec190a84c48a02d8dd4f0da15a4",
        "83cba42635b87c2a35a1389e3b50e6aa", "86685a61cd3d91aa36bb6b6edb455e32", "51885294e9c2573063906f8554d0d842",
      ]
    }
    for i, f in by_display {
      assert_eq(mr_md5(f.yuvp()), pins[i], msg="depth=\{depth} frame \{i}")
    }
  }
}

///|
/// §422d: the online VBV path with the default B tools open — multi-ref,
/// AQ, AUD, a forced IDR behind a pending B — behaves at 4:2:2 depth like
/// the §421 online-depth matrix does at 4:4:4: six AUs, per-AU QPs, VBV
/// bits matching the emitted bytes, and the four inter recons equal to the
/// local skip-filter decode.
test "h264 c422 depth: online VBV with default B tools and forced IDR" {
  for bit_depth in [10, 12] {
    let frames = c422d_fixture(32, 32, 6, bit_depth)
    for cabac in [false, true] {
      let stats = @libavcodec.H264EncStats::new()
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=32,
          height=32,
          qp=26,
          chroma_format=2,
          bit_depth~,
          cabac~,
          multi_ref=3,
          aq=true,
          aud=true,
          vbv_maxrate=320000,
          vbv_bufsize=128000,
          fps=25,
          stats~,
        ) {
        Ok(e) => e
        Err(e) => fail("depth=\{bit_depth} cabac=\{cabac}: \{e}")
      }
      let aus : Array[Bytes] = []
      for i in 0..<6 {
        let (y, u, v) = frames[i]
        match enc.push_frame(y, u, v, force_idr=i == 2) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          aus.push(au)
        }
      }
      match enc.finish() {
        Ok(tail) => {
          assert_eq(tail.length(), 1)
          for au in tail {
            aus.push(au)
          }
        }
        Err(e) => fail(e)
      }
      assert_eq(aus.length(), 6)
      assert_eq(stats.frame_qps.length(), 6)
      assert_eq(
        stats.vbv_bits,
        h264s_concat(aus).length().to_int64() * 8L,
        msg="depth=\{bit_depth} cabac=\{cabac}",
      )
      let decoded = match
        @libavcodec.h264_decode_annexb_frames(h264s_concat(aus), true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 6)
      assert_eq(enc.recons.length(), 4)
      for (i, coded) in [(0, 1), (1, 3), (2, 4), (3, 5)] {
        assert_true(
          h264s_bytes_eq(enc.recons[i], decoded[coded].yuvp()),
          msg="depth=\{bit_depth} cabac=\{cabac} coded=\{coded}",
        )
      }
    }
  }
}
