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
test "h264 cabac rd: default off is byte-identical" {
  let frames = h264cab_fixture(96, 64, 4)
  let plain = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      cabac_rd=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if plain.length() != off.length() {
    fail("explicit cabac_rd=false changed the stream length")
  }
  for i = 0; i < plain.length(); i = i + 1 {
    if plain[i] != off[i] {
      fail("byte \{i} differs with cabac_rd=false")
    }
  }
  inspect(
    h264cab_md5(plain),
    content=(
      #|6df3a0d9dbd59504065d63172119081d
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
      #|1725
    ),
  )
  inspect(
    rd.length(),
    content=(
      #|1694
    ),
  )
  inspect(
    h264cab_md5(rd),
    content=(
      #|38b9a4dbf1d6b8334b211e5629fca5c4
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
  inspect(
    h264cab_md5(stream),
    content=(
      #|4ae8a3cc76a036e0d9392a65aae7fa20
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
  let pins = [
    "47e79e2c702188f62c13ce0c611fd512", "a58afcef18f6ef532c3ef2e82095c451", "f24ac493ba82612536e00f017f1cf398",
    "a7e27222b253c080eb156241792cadb9", "842f3db377231f2d968354a0699eaec5", "a5d8ce73e437d85be66f235da0eac1db",
  ]
  for i, f in frames_dec {
    inspect(h264cab_md5(f.yuvp()), content=pins[i])
  }
}
