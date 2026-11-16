// Blackbox tests for B-schedule multi-reference encoding (`§418`). The
// B pictures' list 0 holds the past reference entries (the future P parks
// at the history head); the P pictures between them search the newest
// `multi_ref` entries exactly like the P-only streams. Gates: decode
// round-trip with the recon invariant (coding order, offset by the IDR),
// streaming == batch byte identity, parameter-set declarations, and a
// toggle scene where the B's best reference is the picture two back.

///|
/// The P pictures (even display d) alternate two patterns every other P;
/// every B picture (odd display d >= 3) shows the pattern of the P TWO
/// back, so its best list 0 entry is reference index 1 once the history
/// holds two pasts — the case B multi-reference exists for. B1 (d=1) has
/// only the IDR behind it and matches it.
fn bmrb_toggle_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let phase = if f % 2 == 0 {
      f / 2 % 2
    } else if f >= 3 {
      (f - 3) / 2 % 2
    } else {
      0
    }
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
test "h264 b multiref: round trip with the recon invariant at every depth" {
  let frames = h264b_fixture(96, 64, 7)
  for nrefs in [2, 3, 16] {
    for cabac in [false, true] {
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=26,
            multi_ref=nrefs,
            recon~,
            stats~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=26,
            multi_ref=nrefs,
            recon~,
            stats~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(stats.b_mbs > 0)
      // The parameter sets declare the capacity: the B SPS reserves one
      // slot more than the PPS's list 0 default (the B's future P).
      let ps = @libavcodec.new_h264_param_sets()
      let mut saw_sps = false
      let mut saw_pps = false
      for nal in vbv_nals(stream) {
        let payload = @libavcodec.BitReader::new(vbv_nal_payload(stream, nal))
        if nal.0 == 7 {
          match
            @libavcodec.ff_h264_decode_seq_parameter_set(payload, ps, false) {
            Ok(_) => saw_sps = true
            Err(e) => fail(e)
          }
        } else if nal.0 == 8 {
          match
            @libavcodec.ff_h264_decode_picture_parameter_set(
              payload,
              ps,
              vbv_nal_payload(stream, nal).length() * 8,
            ) {
            Ok(_) => saw_pps = true
            Err(e) => fail(e)
          }
        }
      }
      assert_true(saw_sps)
      assert_true(saw_pps)
      // At depth 16 the DPB clamps to the 16-frame syntax limit (the
      // oldest past slot drops instead).
      assert_eq(ps.sps_list[0].unwrap().ref_frame_count, (nrefs + 1).min(16))
      assert_eq(ps.pps_list[0].unwrap().ref_count_l0, nrefs)
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(dec.length(), 7)
      assert_eq(recon.length(), 6)
      // Coding order I, P2, B1, P4, B3, P6, B5: the recons and the
      // decoder's output agree one-to-one after the IDR.
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(dec[i + 1].yuvp()),
          msg="nrefs=\{nrefs} cabac=\{cabac} frame \{i}",
        )
      }
    }
  }
}

///|
test "h264 b multiref: streaming matches the batch stream byte for byte" {
  let frames = h264b_fixture(96, 64, 7)
  for nrefs in [2, 3] {
    for cabac in [false, true] {
      let batch = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=26,
            multi_ref=nrefs,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=26,
            multi_ref=nrefs,
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
      assert_eq(
        mr_md5(Bytes::from_array(out[:])),
        mr_md5(batch),
        msg="nrefs=\{nrefs} cabac=\{cabac}",
      )
    }
  }
}

///|
test "h264 b multiref: explicit one equals the default B stream" {
  let frames = h264b_fixture(96, 64, 6)
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
test "h264 b multiref: a toggle scene codes far smaller with two refs" {
  let frames = bmrb_toggle_fixture(9)
  let one = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
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
      multi_ref=2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Every B from display 3 on matches the reference two back; with two
  // references those B pictures become near-skips on their true match.
  assert_true(
    two.length() * 10 < one.length() * 9,
    msg="toggle scene: two-ref \{two.length()} B not clearly smaller than one-ref \{one.length()} B",
  )
  let dec = match @libavcodec.h264_decode_annexb_frames(two, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 9)
}

///|
test "h264 b multiref: warm-up history and the b tool set compose" {
  // Four frames: IDR, B1, P2, B3 — B1's list 0 holds a single past (the
  // IDR) while the parameter sets declare three, exercising the
  // num_ref_idx_active_override path in the B slice header.
  let frames = h264b_fixture(96, 64, 4)
  for cabac in [false, true] {
    let recon : Array[Bytes] = []
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          b_parts=true,
          intra_in_b=true,
          intra4x4_in_b=true,
          dct8x8=true,
          multi_ref=3,
          recon~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
          b_parts=true,
          intra_in_b=true,
          intra4x4_in_b=true,
          dct8x8=true,
          multi_ref=3,
          recon~,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 4)
    assert_eq(recon.length(), 3)
    for i, r in recon {
      assert_eq(mr_md5(r), mr_md5(dec[i + 1].yuvp()), msg="frame \{i}")
    }
  }
}

///|
test "h264 b multiref: periodic IDR and batch rate controls compose" {
  let frames = h264b_fixture(96, 64, 9)
  for
    config in [
      {
        ..@libavcodec.VideoEncConfig::new(width=96, height=64),
        keyint: 4,
        multi_ref: 2,
      },
      {
        ..@libavcodec.VideoEncConfig::new(width=96, height=64),
        keyint: 4,
        multi_ref: 2,
        target_bytes: 6000,
      },
      {
        ..@libavcodec.VideoEncConfig::new(width=96, height=64),
        keyint: 4,
        multi_ref: 2,
        vbv_maxrate: 200000,
        vbv_bufsize: 32000,
        fps: 25,
      },
    ] {
    let stats = @libavcodec.H264EncStats::new()
    let stream = match
      @libavcodec.video_encode(
        frames,
        codec=@libavcodec.VideoCodec::H264,
        config~,
        stats~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 9)
    if config.target_bytes > 0 {
      assert_true(stream.length() <= config.target_bytes)
    }
    if config.vbv_maxrate > 0 {
      let sizes = vbv_au_sizes(vbv_nals(stream))
      let (bits, _) = vbv_cpb_check(
        "b-multiref-keyint",
        sizes,
        config.vbv_maxrate,
        config.vbv_bufsize,
        25,
        90,
      )
      assert_eq(bits.to_int64(), stats.vbv_bits)
    }
  }
}

///|
test "h264 b multiref: online streaming VBV composes" {
  let frames = h264b_fixture(96, 64, 9)
  let stats = @libavcodec.H264EncStats::new()
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      multi_ref=2,
      vbv_maxrate=120000,
      vbv_bufsize=16000,
      fps=25,
      stats~,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let out : Array[Bytes] = []
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      out.push(au)
    }
  }
  match enc.finish() {
    Ok(aus) =>
      for au in aus {
        out.push(au)
      }
    Err(e) => fail(e)
  }
  assert_eq(out.length(), 9)
  let blob : Array[Byte] = []
  for au in out {
    for b in au {
      blob.push(b)
    }
  }
  let stream = Bytes::from_array(blob[:])
  let sizes = vbv_au_sizes(vbv_nals(stream))
  let (bits, _) = vbv_cpb_check(
    "b-multiref-online", sizes, 120000, 16000, 25, 90,
  )
  assert_eq(bits.to_int64(), stats.vbv_bits)
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 9)
}

///|
/// External arbitration anchors (`§418`): CAVLC depth-2 and CABAC depth-3
/// B-schedule multi-reference streams for the docker ffmpeg framemd5
/// oracle (see AGENT_HANDOFF_2026-11-14_H264_B_MULTIREF.md). The display
/// MD5s pin FFmpeg's deblocked output; `ARBMR2:`/`ARBMR3:` carry the
/// annexb bytes for re-arbitration.
test "h264 b multiref: ffmpeg-arbitrated streams" {
  let frames = bmrb_toggle_fixture(9)
  for cabac in [false, true] {
    let nrefs = if cabac { 3 } else { 2 }
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          multi_ref=nrefs,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
          multi_ref=nrefs,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let mut dump = ""
    for i = 0; i < stream.length(); i = i + 1 {
      dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
    }
    println("ARBMR\{nrefs}:\{dump}")
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 9)
    let disp = h264p_decode_to_display(9)
    let by_display : Array[@libavcodec.H264Frame] = Array::make(9, dec[0])
    for i, f in dec {
      by_display[disp[i]] = f
    }
    let mut md5s = "MRMD5 nrefs=\{nrefs}:"
    for f in by_display {
      md5s = md5s + " " + mr_md5(f.yuvp())
    }
    println(md5s)
    // FFmpeg-arbitrated display MD5s (docker framemd5, zero warnings;
    // CAVLC nrefs=2 and CABAC nrefs=3 both match every frame).
    let pins = if nrefs == 2 {
      // §422e re-arbitration: the B inter 8x8 RD choice changed the four
      // B pictures (P frames byte-identical).
      [
        "4e4da0761a12604f40b43e6516a75390", "049f1d561f6322286d8b073f41df5e05", "c26fd86e823e4b81998d64320e501372",
        "534dbcc819df3455a9287982bbdbbdf8", "1302a890f6802a2043b47f8b4fea741d", "2c79cf5aba3866d921253fac780b6d86",
        "f60e31bbe113fca7218a940c426f0532", "6d8571cd2a952a7ee07186de9c53872f", "16766379db4fc3c0ea4072bc91d6fdac",
      ]
    } else {
      // §422e re-arbitration (the four B pictures).
      [
        "b30bf6018077f7560485b96e9a65fb11", "a59b9ce5be0cd8d19cec11942870523e", "f08b818bd0f419b9f3fc8251c4abca7f",
        "06bac29fd7f3d86adb490f5291472f7e", "f17ce41c8ced0d69eea6dba44646cb01", "24cd6600e525c4daecc2d202e6330125",
        "9512c71cab2c04d8b810baa5188250d7", "ac82682fce4f1b0968aff9cbf2b40038", "57127f4d1ef8d6581ddeba4c0f2020bf",
      ]
    }
    for i, f in by_display {
      assert_eq(mr_md5(f.yuvp()), pins[i], msg="nrefs=\{nrefs} frame \{i}")
    }
  }
}

///|
test "h264 b multiref: high bit depths compose" {
  for depth in [9, 10] {
    let frames = h264h10_fixture(96, 64, 7, depth)
    for cabac in [false, true] {
      let recon : Array[Bytes] = []
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=26,
            bit_depth=depth,
            multi_ref=2,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=26,
            bit_depth=depth,
            multi_ref=2,
            recon~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(dec.length(), 7)
      for f in dec {
        assert_eq(f.bit_depth, depth)
      }
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(dec[i + 1].yuvp()), msg="depth=\{depth}")
      }
    }
  }
}
