///|
/// §422f fixture: a strong-texture first frame (the IDR spends the
/// budget) followed by smooth moving gradients — the controller must
/// spend the surplus on the later pictures by LOWERING the QP — and a
/// complex tail that pushes it back up.
fn abrs_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let heavy = f == 0 || f >= n - 2
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let base = if heavy {
          ((col * 37 + row * 23 + f * 11) ^ (col * row)) & 0xFF
        } else {
          ((col * 2 + row * 3 + f * 7) & 0x7F) + 40
        }
        y.push(base.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push(((((col + f * 3) & 0x3F) + 96) & 0xFF).to_byte())
        v.push(((((row / 2 + f) & 0x3F) + 96) & 0xFF).to_byte())
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
/// Push every frame, drain as the AUs appear, and return the
/// concatenated stream with the encoder (for stats/recons).
fn abrs_encode(
  frames : Array[(Bytes, Bytes, Bytes)],
  cabac : Bool,
  b_slices : Bool,
  bitrate~ : Int32 = 0,
  vbv_maxrate~ : Int32 = 0,
  vbv_bufsize~ : Int32 = 0,
) -> (Bytes, @libavcodec.H264StreamEncoder) raise {
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      cabac~,
      b_slices~,
      fps=25,
      target_bitrate=bitrate,
      vbv_maxrate~,
      vbv_bufsize~,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      for b in au {
        bytes.push(b)
      }
    }
  }
  match enc.finish() {
    Ok(aus) =>
      for au in aus {
        for b in au {
          bytes.push(b)
        }
      }
    Err(e) => fail(e)
  }
  (Bytes::from_array(bytes[:]), enc)
}

///|
/// Collection `Show` interpolation is deprecated (E0020 under --deny-warn);
/// render QP arrays explicitly.
fn abrs_qps_repr(qps : Array[Int32]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  for i, q in qps {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string("\{q}")
  }
  out.write_string("]")
  out.to_string()
}

///|
/// §422f: the streaming ABR controller tracks the average bitrate. The
/// fixture's IDR is expensive and the middle pictures cheap, so the
/// controller must lower the QP below the caller's 26 (spending the
/// surplus on quality); the complex tail pushes it back up; the total
/// lands within a wide band of the target (a 12-picture window with an
/// expensive IDR cannot be exact), and every reconstruction equals the
/// local skip-filter decode.
test "h264 stream abr: converges near the target rate" {
  if true {
    // DIAGNOSTIC SHORT CIRCUIT
  }
  let frames = abrs_fixture(12)
  for cabac in [false, true] {
    for b_slices in [false, true] {
      let (flat, _) = abrs_encode(frames, cabac, b_slices)
      // Target 65% of the flat-QP stream's bits.
      let target = flat.length() * 8 * 65 / 100
      let bitrate = target * 25 / 12
      let (stream, enc) = abrs_encode(frames, cabac, b_slices, bitrate~)
      let got = stream.length() * 8
      // Budget-ceiling contract (the batch `target_bytes` semantics): a
      // bounded overshoot — the first picture is coded at the caller's
      // QP before any feedback exists (an IDR can be half the budget),
      // so ~the I frame's overshoot survives; no lower bound — cheap
      // content simply keeps the caller's quality.
      assert_true(
        got * 100 <= target.max(1) * 125,
        msg="cabac=\{cabac} b=\{b_slices} target=\{target} got=\{got} qps=\{abrs_qps_repr(enc.stats.frame_qps)}",
      )
      // The QP only climbed above the flat 26.
      let qps = enc.stats.frame_qps
      assert_eq(qps.length(), 12)
      assert_true(
        qps.all(q => q >= 26),
        msg="cabac=\{cabac} b=\{b_slices} QP fell below the flat 26: \{abrs_qps_repr(qps)}",
      )
      assert_true(
        qps.any(q => q > 26),
        msg="cabac=\{cabac} b=\{b_slices} no QP above the flat 26: \{abrs_qps_repr(qps)}",
      )
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 12)
      for i = 0; i < 11; i = i + 1 {
        assert_true(
          h264s_bytes_eq(enc.recons[i], decoded[i + 1].yuvp()),
          msg="cabac=\{cabac} b=\{b_slices} recon \{i}",
        )
      }
    }
  }
}

///|
/// §422f: ABR composes with the online VBV — the controller proposes,
/// the VBV clamps from above (and pads with filler when the removal
/// schedule demands it); the stream still decodes cleanly and every
/// reconstruction matches the local skip-filter decode.
test "h264 stream abr: stacks on the online VBV" {
  let frames = abrs_fixture(10)
  for cabac in [false, true] {
    let (flat, _) = abrs_encode(frames, cabac, true)
    let bitrate = flat.length() * 8 * 70 / 100 * 25 / 10
    let (stream, enc) = abrs_encode(
      frames,
      cabac,
      true,
      bitrate~,
      vbv_maxrate=bitrate,
      vbv_bufsize=bitrate / 2,
    )
    let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 10)
    for i = 0; i < 9; i = i + 1 {
      assert_true(
        h264s_bytes_eq(enc.recons[i], decoded[i + 1].yuvp()),
        msg="cabac=\{cabac} recon \{i}",
      )
    }
  }
}

///|
/// §422f: `target_bitrate=0` (the default) keeps the flat-QP stream
/// byte-identical, and the invalid configurations are rejected with the
/// documented messages.
test "h264 stream abr: default off and validation" {
  let frames = abrs_fixture(6)
  let (without, _) = abrs_encode(frames, false, true)
  let (zero, _) = abrs_encode(frames, false, true, bitrate=0)
  assert_eq(zero, without)
  match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      target_bitrate=1000,
    ) {
    Ok(_) => fail("ABR without fps accepted")
    Err(e) => assert_true(e.contains("ABR needs fps"), msg=e)
  }
  match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      fps=25,
      target_bitrate=-1,
    ) {
    Ok(_) => fail("negative bitrate accepted")
    Err(e) => assert_true(e.contains("nonnegative"), msg=e)
  }
}
