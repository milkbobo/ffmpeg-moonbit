// Blackbox tests for the 12/14-bit encoder path (`§419`): above 10 bits
// the parameter sets switch to High 4:4:4 Predictive (profile_idc 244 —
// the only profile with bit_depth_luma_minus8 up to 6, even at 4:2:0),
// and the SPS's bit_depth_*_minus8 read 4/6. 11/13 stay rejected (the
// reference decoder PATCHWELCOMEs them). Gates mirror the High 10 family:
// decode round-trip with the recon invariant, streaming == batch byte
// identity, parameter-set declarations, and FFmpeg arbitration anchors.

///|
test "h264 h1214: round trip with the recon invariant at 12 and 14 bits" {
  for depth in [12, 14] {
    for cabac in [false, true] {
      let frames = h264h10_fixture(96, 64, 6, depth)
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=26,
            bit_depth=depth,
            recon~,
            stats~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=26,
            bit_depth=depth,
            recon~,
            stats~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(stats.b_mbs > 0)
      // The parameter sets declare Hi444PP with the matching depth.
      let ps = @libavcodec.new_h264_param_sets()
      let mut profile = 0
      for nal in vbv_nals(stream) {
        if nal.0 == 7 {
          let payload = vbv_nal_payload(stream, nal)
          profile = payload[0].to_int()
          match
            @libavcodec.ff_h264_decode_seq_parameter_set(
              @libavcodec.BitReader::new(payload),
              ps,
              false,
            ) {
            Ok(_) => ()
            Err(e) => fail(e)
          }
        }
      }
      assert_eq(profile, 244)
      assert_eq(ps.sps_list[0].unwrap().bit_depth_luma, depth)
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(dec.length(), 6)
      for f in dec {
        assert_eq(f.bit_depth, depth)
      }
      assert_eq(recon.length(), 5)
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(dec[i + 1].yuvp()),
          msg="depth=\{depth} cabac=\{cabac} frame \{i}",
        )
      }
    }
  }
}

///|
test "h264 h1214: streaming matches the batch stream byte for byte" {
  let frames = h264h10_fixture(96, 64, 7, 14)
  for cabac in [false, true] {
    let batch = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          bit_depth=14,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          bit_depth=14,
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
        bit_depth=14,
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

///|
test "h264 h1214: composes with the tool set and multi-reference" {
  for depth in [12, 14] {
    for cabac in [false, true] {
      let frames = h264h10_fixture(96, 64, 7, depth)
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let stream = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=96,
            height=64,
            qp=24,
            bit_depth=depth,
            b_parts=true,
            intra_in_b=true,
            intra4x4_in_b=true,
            dct8x8=true,
            multi_ref=3,
            aq=true,
            aq_strength=3,
            aud=true,
            recon~,
            stats~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=96,
            height=64,
            qp=24,
            bit_depth=depth,
            b_parts=true,
            intra_in_b=true,
            intra4x4_in_b=true,
            dct8x8=true,
            multi_ref=3,
            aq=true,
            aq_strength=3,
            aud=true,
            recon~,
            stats~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(stats.dqp_mbs > 0)
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(dec.length(), 7)
      for i, r in recon {
        assert_eq(mr_md5(r), mr_md5(dec[i + 1].yuvp()), msg="frame \{i}")
      }
    }
  }
}

///|
test "h264 h1214: depth validation keeps 11 and 13 rejected" {
  let frames = h264h10_fixture(96, 64, 3, 10)
  for bad in [7, 11, 13, 15, 16] {
    match
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        qp=26,
        bit_depth=bad,
      ) {
      Ok(_) => fail("bit depth \{bad} accepted")
      Err(_) => ()
    }
    match
      @libavcodec.h264_encode_frames_cabac(
        frames,
        width=96,
        height=64,
        qp=26,
        bit_depth=bad,
      ) {
      Ok(_) => fail("CABAC bit depth \{bad} accepted")
      Err(_) => ()
    }
  }
}

///|
/// External arbitration anchors (`§419`): CAVLC 12-bit and CABAC 14-bit
/// streams for the docker ffmpeg framemd5 oracle. The display MD5s pin
/// FFmpeg's deblocked output; `ARBH12:`/`ARBH14:` carry the annexb bytes
/// for re-arbitration.
test "h264 h1214: ffmpeg-arbitrated streams" {
  for depth in [12, 14] {
    let cabac = depth == 14
    let frames = h264h10_fixture(96, 64, 6, depth)
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          bit_depth=depth,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
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
    println("ARBH\{depth}:\{dump}")
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
    let mut md5s = "HMD5 d=\{depth}:"
    for f in by_display {
      md5s = md5s + " " + mr_md5(f.yuvp())
    }
    println(md5s)
    // FFmpeg-arbitrated display MD5s (docker framemd5, zero warnings).
    let pins = if depth == 12 {
      // §422e re-arbitration: the B inter 8x8 RD choice changed the
      // display B frames (the CABAC 14-bit arm kept its pins).
      [
        "7e438cb6f062cef70088bd8d0cdcdf7c", "f662ecb6c9ba4c3a3b723164c968524c", "f9ce7d2644c1db89dbef34eca9137132",
        "b55a155509b0ec6ea6180751d44b14c8", "1fe9aebc56087d25140917665c861e46", "3b4e305e47daa4354485fee8362b3e68",
      ]
    } else {
      // §422e re-arbitration on top of `WIDE_RD_QUANT` (the display B
      // frames changed again). docker framemd5 zero warnings, identical
      // to the local default decode.
      [
        "3049a1723fc9a2a0fd6d0de7ed7777cb", "92dcabd72d34af5bf0eabe72f4f3de8b", "a55731200b878966828cebd8dca378fc",
        "127901e9075f4c2078baf3d66c42e595", "12c03b183a5899505902afb53aa3cca8", "e2b0c4e5505c673fbe669679f7854d5f",
      ]
    }
    for i, f in by_display {
      assert_eq(mr_md5(f.yuvp()), pins[i], msg="depth=\{depth} frame \{i}")
    }
  }
}
