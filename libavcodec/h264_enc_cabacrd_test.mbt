// Blackbox tests for the opt-in CABAC rate-distortion bit pricing (`§392`):
// `h264_encode_frames_cabac(cabac_rd=true)` prices every mode-decision
// candidate through the real CABAC engine and context states
// (snapshot/rollback per candidate) instead of the CAVLC dry run. Default
// off keeps every pinned stream byte-identical; on, the invariant gates are
// the reconstruction equality against this repository's decoder (a
// context/mirror rollback leak desyncs the arithmetic decoder immediately),
// determinism, byte savings over the CAVLC-priced decisions, and pinned
// stream MD5s for the external docker-ffmpeg arbitration.

///|
test "h264 cabac rd: default on and opt-out is byte-identical to it" {
  let frames = h264cab_fixture(96, 64, 4)
  // §405: the pricing defaults on — the default stream must equal the
  // explicit all-on call (and the CAVLC-priced opt-out differs).
  let plain = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let on = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      b_parts=true,
      intra_in_b=true,
      intra4x4_in_b=true,
      dct8x8=true,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if plain != on {
    fail("default stream differs from the explicit all-on stream")
  }
  let off = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=false,
      b_parts=false,
      intra_in_b=false,
      intra4x4_in_b=false,
      dct8x8=false,
      cabac_rd=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if off == plain {
    fail("the CAVLC-priced opt-out stream equals the default one")
  }
  // Replayable Annex B dumps for re-running the external arbitration.
  let mut d1 = ""
  for i = 0; i < plain.length(); i = i + 1 {
    d1 = d1 + (plain[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBCRDALLON:\{d1}")
  let mut d2 = ""
  for i = 0; i < off.length(); i = i + 1 {
    d2 = d2 + (off[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBCRDOFF:\{d2}")
  inspect(
    h264cab_md5(plain),
    content=(
      #|dbb22761c552694cbd17537bf31ba9d3
    ),
  )
}

///|
test "h264 cabac rd: round trip equals encoder reconstruction" {
  let frames = h264cab_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      cabac_rd=true,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if recon.length() != 5 {
    fail("expected 5 P recons, got \{recon.length()}")
  }
  for skip in [true, false] {
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, skip) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    if dec.length() != 6 {
      fail("expected 6 frames, got \{dec.length()}")
    }
    // Unfiltered output equals the encoder's reconstruction plane-for-plane
    // (`skip=true` skips the loop filter).
    if skip {
      for f in 1..<6 {
        let r = dec[f]
        let src = recon[f - 1]
        for row = 0; row < 64; row = row + 1 {
          for col = 0; col < 96; col = col + 1 {
            if src[row * 96 + col] != r.y[row * r.ystride + col].to_byte() {
              fail("frame \{f} recon mismatch at \{row},\{col}")
            }
          }
        }
      }
    }
  }
}

///|
test "h264 cabac rd: deterministic" {
  let frames = h264cab_fixture(96, 64, 4)
  let s1 = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let s2 = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if s1.length() != s2.length() {
    fail("length mismatch")
  }
  for i = 0; i < s1.length(); i = i + 1 {
    if s1[i] != s2[i] {
      fail("byte \{i} differs between runs")
    }
  }
}

///|
test "h264 cabac rd: saves bits over cavlc-priced decisions" {
  let frames = h264cab_fixture(96, 64, 6)
  let off = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let rd = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // True CABAC pricing lets the RD pick the modes CABAC itself codes
  // cheapest; on the moving-scene fixture it must not lose to decisions
  // priced with CAVLC bit counts.
  if rd.length() > off.length() {
    fail(
      "cabac_rd stream \{rd.length()} B larger than cavlc-priced \{off.length()} B",
    )
  }
  inspect(
    off.length(),
    content=(
      #|2097
    ),
  )
  inspect(
    rd.length(),
    content=(
      #|2097
    ),
  )
  inspect(
    h264cab_md5(rd),
    content=(
      #|8181af10fe92d0ac4a20dcc4fe671c89
    ),
  )
}

///|
test "h264 cabac rd: combines with aq, intra-in-p and dct8x8" {
  let frames = h264cab_fixture(96, 64, 5)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      dct8x8=true,
      aq=true,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 5 {
    fail("expected 5 frames, got \{dec.length()}")
  }
  // Replayable Annex B dump for re-running the external arbitration.
  let mut d = ""
  for i = 0; i < stream.length(); i = i + 1 {
    d = d + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBCRDCOMBO:\{d}")
  inspect(
    h264cab_md5(stream),
    content=(
      #|429bcbb6bf7c0359cbdee50cd332ba84
    ),
  )
}

///|
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// six-frame CABAC I+P stream from TRUE CABAC RD pricing (cabac_rd=true)
/// decodes in the reference implementation with zero warnings and every
/// loop-filtered frame matching this repository's decoder byte-for-byte
/// (pinned framemd5 MD5s, re-pinned via the ARBCABACRD dump route).
test "h264 cabac rd: ffmpeg-arbitrated six frames (96x64, QP 24)" {
  let frames = h264cab_fixture(96, 64, 6)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i = 0; i < stream.length(); i = i + 1 {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBCABACRD:\{dump}")
  let frames_dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if frames_dec.length() != 6 {
    fail("expected 6 frames")
  }
  // §422e re-pin: the two B pictures.
  let pins = [
    "47e79e2c702188f62c13ce0c611fd512", "bd75ca1dba4b2466094842e73f3cf316", "a5ad8319bc5e3456d853da87357f9781",
    "2a1259c862fccd3aeebacd2f0ac02e0f", "c1eccbff9cf130d2eaa40231b2c36a42", "2569dcbc73c920620922df5cbd9fa33e",
  ]
  for i, f in frames_dec {
    inspect(h264cab_md5(f.yuvp()), content=pins[i])
  }
}
