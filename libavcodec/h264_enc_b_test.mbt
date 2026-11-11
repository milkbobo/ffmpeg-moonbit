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
test "h264 enc b: default off is byte-identical" {
  let frames = h264b_fixture(96, 64, 4)
  let plain = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if plain.length() != off.length() {
    fail("explicit b_slices=false changed the stream length")
  }
  for i = 0; i < plain.length(); i = i + 1 {
    if plain[i] != off[i] {
      fail("byte \{i} differs with b_slices=false")
    }
  }
}

///|
test "h264 enc b: rejects invalid combinations" {
  let frames = h264b_fixture(96, 64, 4)
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      target_bytes=1000,
    ) {
    Err(_) => ()
    Ok(_) => fail("b_slices with target_bytes should fail")
  }
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      dct8x8=true,
    ) {
    Err(_) => ()
    Ok(_) => fail("b_slices with dct8x8 should fail")
  }
  match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      cabac_rd=true,
    ) {
    Err(_) => ()
    Ok(_) => fail("b_slices with cabac_rd should fail")
  }
  let single : Array[(Bytes, Bytes, Bytes)] = [frames[0]]
  match
    @libavcodec.h264_encode_frames(
      single,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Err(_) => ()
    Ok(_) => fail("b_slices with a single frame should fail")
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
  inspect(
    h264b_md5(stream),
    content=(
      #|560643f59f9263b9419d7a9b09f21413
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
  // TEMP-PROBE
  for i, f in dec {
    println("ARBDEC i=\{i} poc=\{f.poc}")
  }
  let pins = [
    "4215ee3be54b5cf3f3a8ccf97cc7ee64", "e090f33594efab799ff326a8fb42c886", "de5481133a503741d0216fa844806f3a",
    "0818a913be15c8463f994dac76e2418e", "e5739d1d31653a42483f7bfbf3929953", "1c01aeed2b8da17f736302b545dc0234",
  ]
  for i in 0..<6 {
    inspect(md5s[i], content=pins[i])
  }
}
