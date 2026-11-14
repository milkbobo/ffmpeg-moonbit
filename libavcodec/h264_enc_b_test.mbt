// Blackbox tests for the B-slice sequence encoder (`§393`): `b_slices`
// codes the odd display positions as bidirectionally predicted pictures
// (I, P2, B1, P4, B3, ... coding order, POC type 0 reordering). The gates:
// the reconstruction invariant against this repository's decoder (which
// reorders to display order by POC), the B-branch statistics, determinism,
// the default-off path staying byte-identical, and external docker-ffmpeg
// arbitration with pinned framemd5 values.

///|
fn h264b_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    // A bright box sweeping across a gradient: past and future references
    // bracket every B picture's content.
    let bx = f * 6 % (w - 16)
    let by = f * 4 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f) & 0xFF
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox && (col == bx || col == bx + 15 || row == by || row == by + 15) {
          s = 40
        } else if inbox {
          s = 220
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col + f) & 0x3F) + 96).to_byte())
        v.push((((row + f * 2) & 0x3F) + 96).to_byte())
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
fn h264b_md5(data : Bytes) -> String {
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
/// Sort a decoded frame list by POC (display order) and return the packed
/// YUV MD5s. The repository's batch decoder returns frames in decoding
/// order; the display order is what ffmpeg's framemd5 arbitrates.
fn h264b_display_md5s(frames : Array[@libavcodec.H264Frame]) -> Array[String] {
  // Selection by POC (display order 0,2,4,... for our fixtures): explicit
  // lookup instead of an in-place sort, so the order is beyond doubt.
  let out : Array[String] = []
  for k in 0..<frames.length() {
    let want = k * 2
    let mut found = false
    for f in frames {
      if f.poc == want {
        out.push(h264b_md5(f.yuvp()))
        found = true
        break
      }
    }
    if !found {
      abort("no frame with poc \{want}")
    }
  }
  out
}

///|
test "h264 enc b: round trip equals encoder reconstruction (cavlc)" {
  let frames = h264b_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Coding order I, P2, B1, P4, B3, P5 -> five recons after the I.
  if recon.length() != 5 {
    fail("expected 5 recons, got \{recon.length()}")
  }
  if stats.b_mbs <= 0 {
    fail("no B macroblocks coded: the B path was not exercised")
  }
  for skip_lf in [true, false] {
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, skip_lf) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    if dec.length() != 6 {
      fail("expected 6 frames, got \{dec.length()}")
    }
  }
  // Unfiltered decode equals the encoder reconstructions. The recons are
  // in coding order (P2, B1, P4, B3, P5); the decoder outputs coding
  // order too, offset by the IDR.
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  for i in 1..<6 {
    let r = dec[i]
    let src = recon[i - 1]
    for row = 0; row < 64; row = row + 1 {
      for col = 0; col < 96; col = col + 1 {
        if src[row * 96 + col] != r.y[row * r.ystride + col].to_byte() {
          fail("frame \{i} recon mismatch at \{row},\{col}")
        }
      }
    }
  }
}

///|
test "h264 enc b: round trip equals encoder reconstruction (cabac)" {
  let frames = h264b_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.b_mbs <= 0 {
    fail("no B macroblocks coded: the B path was not exercised")
  }
  for skip_lf in [true, false] {
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, skip_lf) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    if dec.length() != 6 {
      fail("expected 6 frames, got \{dec.length()}")
    }
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  for i in 1..<6 {
    let r = dec[i]
    let src = recon[i - 1]
    for row = 0; row < 64; row = row + 1 {
      for col = 0; col < 96; col = col + 1 {
        if src[row * 96 + col] != r.y[row * r.ystride + col].to_byte() {
          fail("frame \{i} recon mismatch at \{row},\{col}")
        }
      }
    }
  }
}

///|
test "h264 enc b: deterministic (both entropies)" {
  let frames = h264b_fixture(96, 64, 6)
  let s1 = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let s2 = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if s1.length() != s2.length() {
    fail("cavlc length mismatch")
  }
  for i = 0; i < s1.length(); i = i + 1 {
    if s1[i] != s2[i] {
      fail("cavlc byte \{i} differs")
    }
  }
  let c1 = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let c2 = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if c1.length() != c2.length() {
    fail("cabac length mismatch")
  }
  for i = 0; i < c1.length(); i = i + 1 {
    if c1[i] != c2[i] {
      fail("cabac byte \{i} differs")
    }
  }
}

///|
test "h264 enc b: defaults are the full B-line and opt-out restores it" {
  let frames = h264b_fixture(96, 64, 4)
  let default_ = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let all_on = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      b_parts=true,
      intra_in_b=true,
      intra4x4_in_b=true,
      dct8x8=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if default_ != all_on {
    fail("default stream differs from the explicit all-on stream")
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=false,
      b_parts=false,
      intra_in_b=false,
      intra4x4_in_b=false,
      dct8x8=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if off == default_ {
    fail("the opt-out stream equals the default (all-on) one")
  }
}

///|
test "h264 enc b: rejects invalid combinations" {
  let frames = h264b_fixture(96, 64, 4)
  // b_slices with a rate control is SUPPORTED since §398; the flat
  // combination must still code (a tiny target forces coarse QPs).
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      target_bytes=6000,
    ) {
    Err(e) => fail(e)
    Ok(_) => ()
  }
  // §405: a one-frame sequence degrades b_slices to the I-only stream
  // instead of erroring (a lone picture can never hold a B).
  let single : Array[(Bytes, Bytes, Bytes)] = [frames[0]]
  match
    @libavcodec.h264_encode_frames(
      single,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Err(e) => fail("single frame with b_slices should degrade, got \{e}")
    Ok(s) =>
      match @libavcodec.h264_decode_annexb_frames(s, true) {
        Ok(d) => if d.length() != 1 { fail("expected 1 frame") }
        Err(e) => fail(e)
      }
  }
}

///|
test "h264 enc b: aud and aq combine" {
  let frames = h264b_fixture(96, 64, 6)
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=true,
      aud=true,
      aq=true,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  let mut dq = ""
  for i = 0; i < stream.length(); i = i + 1 {
    dq = dq + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBAQ:\{dq}")
  inspect(
    h264b_md5(stream),
    content=(
      #|a01d82fe9318af99a55462ad3cbcc624
    ),
  )
  inspect(
    stats.b_mbs > 0,
    content=(
      #|true
    ),
  )
}

///|
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// six-frame I/P/B stream decodes in the reference implementation with
/// zero warnings, in DISPLAY order (POC reordering), and every deblocked
/// frame matches this repository's decoder byte-for-byte (pinned framemd5
/// MD5s, re-pinned via the ARBB dump route).
test "h264 enc b: ffmpeg-arbitrated six frames (96x64, QP 24)" {
  let frames = h264b_fixture(96, 64, 6)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i = 0; i < stream.length(); i = i + 1 {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBB:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames")
  }
  let md5s = h264b_display_md5s(dec)
  // Re-pinned against the C decoder by x264_wbtest's "legacy six-frame
  // B snapshots" test after the shared P prediction/chroma corrections.
  let pins = [
    "4215ee3be54b5cf3f3a8ccf97cc7ee64", "79cb6cd97cc795b5c41fb50ccd5db048", "683deaf38ca7e61d3ae43498af9ac29b",
    "3f4df718ec0e87c8731c03e167873591", "b59196a0d5e18e260f87add844c5a855", "6853569a483390780d73ef9d826c7bf2",
  ]
  for i in 0..<6 {
    inspect(md5s[i], content=pins[i])
  }
}

///|
/// §405 regression: `b_slices + b_parts + intra4x4_in_b + dct8x8` CABAC
/// used to break the reconstruction invariant (a leftover intra trial
/// `intra4x4` flag on an inter neighbour made the writer code the
/// intra4x4 rem-bits against a different most-probable mode than the
/// decoder derives — bins parse, pixels diverge). The pre-write clear in
/// `encode_b_frame_cabac` fixes it; this guards the recon invariant on
/// the sweeping-box fixture that reproduces.
test "h264 enc b: all-on cabac keeps the recon invariant" {
  let frames = h264b_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stream = match
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
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  if recon.length() != 5 {
    fail("expected 5 recons, got \{recon.length()}")
  }
  for i in 1..<6 {
    let r = dec[i]
    let src = recon[i - 1]
    for row in 0..<64 {
      for col in 0..<96 {
        if src[row * 96 + col] != r.y[row * r.ystride + col].to_byte() {
          fail("frame \{i} recon mismatch at \{row},\{col}")
        }
      }
    }
  }
}
