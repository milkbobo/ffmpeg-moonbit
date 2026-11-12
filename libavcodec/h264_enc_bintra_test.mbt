// Blackbox tests for the Intra16x16 macroblocks inside B slices (`§396`,
// the `intra_in_b` opt-in): a scene change inside the B picture leaves
// every inter/direct candidate with a large residual and the macroblock
// codes against its own current-frame neighbours. The gates: the
// reconstruction invariant against this repository's decoder (display
// order by POC), the intra-branch statistics, byte equality with the
// streaming encoder, and external docker-ffmpeg arbitration with pinned
// framemd5 values.

///|
/// A scene-cut fixture: the even display positions (the I/P references)
/// carry one gradient, the odd positions (the B pictures) a completely
/// different smooth gradient — nothing the past/future references can
/// predict, while the B picture's own neighbours reconstruct it cheaply.
fn h264bi_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let scene_b = f % 2 == 1 && f > 0
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let s = if scene_b {
          // A bright radial gradient: self-predictable (plane/DC modes),
          // orthogonal to the references' diagonal ramp.
          (210 - (row * 9 + col * 2 + row / 8 * 6)) & 0x7F
        } else {
          ((col * 3 + row * 2 + f * 7) & 0x3F) + 40
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let ub = if scene_b {
          (170 - ((row + col) & 0x2F)).to_byte()
        } else {
          (((col + f) & 0x3F) + 96).to_byte()
        }
        let vb = if scene_b {
          (90 + ((row * 2) & 0x2F)).to_byte()
        } else {
          (((row + f * 2) & 0x3F) + 96).to_byte()
        }
        u.push(ub)
        v.push(vb)
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
/// Reconstruct-pixel equality between the decoder's unfiltered output
/// (coding order, offset by the IDR) and the encoder's per-picture
/// recons.
fn h264bi_check_recon(
  dec : Array[@libavcodec.H264Frame],
  recon : Array[Bytes],
  w : Int32,
  h : Int32,
  first : Int32,
) -> Unit raise {
  for i in first..<dec.length() {
    let r = dec[i]
    let src = recon[i - 1]
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        if src[row * w + col] != r.y[row * r.ystride + col].to_byte() {
          fail("frame \{i} recon mismatch at \{row},\{col}")
        }
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        if src[w * h + row * (w / 2) + col] !=
          r.u[row * r.cstride + col].to_byte() {
          fail("frame \{i} u recon mismatch at \{row},\{col}")
        }
        if src[w * h + w / 2 * (h / 2) + row * (w / 2) + col] !=
          r.v[row * r.cstride + col].to_byte() {
          fail("frame \{i} v recon mismatch at \{row},\{col}")
        }
      }
    }
  }
}

///|
test "h264 enc bintra: scene-cut B pictures pick Intra16x16 (cavlc)" {
  let frames = h264bi_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      intra_in_b=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs <= 0 {
    fail("no Intra16x16 macroblocks inside the B slices")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bi_check_recon(dec, recon, 96, 64, 1)
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) =>
      if f.length() != 6 {
        fail("filtered decode: expected 6 frames, got \{f.length()}")
      }
    Err(e) => fail(e)
  }
}

///|
test "h264 enc bintra: scene-cut B pictures pick Intra16x16 (cabac)" {
  let frames = h264bi_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      intra_in_b=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs <= 0 {
    fail("no Intra16x16 macroblocks inside the B slices under CABAC")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bi_check_recon(dec, recon, 96, 64, 1)
}

///|
test "h264 enc bintra: scene-cut B pictures pick Intra16x16 (cabac rd)" {
  let frames = h264bi_fixture(96, 64, 4)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      intra_in_b=true,
      cabac_rd=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs <= 0 {
    fail("no Intra16x16 macroblocks inside the B slices under CABAC RD")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 4 {
    fail("expected 4 frames, got \{dec.length()}")
  }
  h264bi_check_recon(dec, recon, 96, 64, 1)
}

///|
test "h264 enc bintra: streaming encoder is byte-identical to the batch" {
  let frames = h264bi_fixture(96, 64, 6)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      intra_in_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      intra_in_b=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let streamed : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      streamed.push(au)
    }
  }
  match enc.finish() {
    Ok(au) =>
      for part in au {
        streamed.push(part)
      }
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for part in streamed {
    for i in 0..<part.length() {
      joined.push(part[i])
    }
  }
  let joined_bytes = Bytes::from_array(joined[:])
  if joined_bytes.length() != batch.length() {
    fail(
      "streamed \{joined_bytes.length()} bytes vs batch \{batch.length()} bytes",
    )
  }
  for i in 0..<batch.length() {
    if joined_bytes[i] != batch[i] {
      fail("stream/batch byte mismatch at \{i}")
    }
  }
  // intra_in_b without b_slices must be rejected by the stream opener.
  match
    @libavcodec.H264StreamEncoder::open(width=64, height=64, intra_in_b=true) {
    Ok(_) => fail("intra_in_b without b_slices must fail")
    Err(_) => ()
  }
}

///|
/// Display-order packed-YUV MD5s (the framemd5 arbitration order).
fn h264bi_display_md5s(frames : Array[@libavcodec.H264Frame]) -> Array[String] {
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
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// scene-cut I/P/B stream codes two Intra16x16 B pictures and decodes in
/// the reference implementation with zero warnings, in DISPLAY order
/// (POC reordering), every deblocked frame matching this repository's
/// decoder byte-for-byte (pinned framemd5 MD5s, obtained via the
/// ARBBINTRA dump route).
test "h264 enc bintra: ffmpeg-arbitrated six frames (96x64, QP 22)" {
  let frames = h264bi_fixture(96, 64, 6)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      intra_in_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i in 0..<stream.length() {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBINTRA:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames")
  }
  let md5s = h264bi_display_md5s(dec)
  for md5 in md5s {
    println("ARBBINTRAMD5:\{md5}")
  }
  let pins = [
    "2ee9cae30c5978acfe03e23b4bcc3d74", "c67c47cd7c0624823646d05ed6e73b9a", "60cdcdfca15b74cdff1b49d00463be16",
    "c67c47cd7c0624823646d05ed6e73b9a", "7b2972576e3f0ee3c899bbd7a150d253", "947e78f8f462b58eadda5480f66b5738",
  ]
  for i in 0..<6 {
    inspect(md5s[i], content=pins[i])
  }
}

///|
/// A fine-texture scene-cut fixture: the B pictures are constant per 4x4
/// block (a block-hash pattern), so the sixteen 4x4 predictors track it
/// block by block while the single I16x16 predictor and every inter
/// candidate cannot.
fn h264bi4_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let scene_b = f % 2 == 1 && f > 0
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let s = if scene_b {
          let bx = col / 4
          let by = row / 4
          60 + ((bx * 7 + by * 13 + f * 5) & 0x3F) * 2
        } else {
          ((col * 3 + row * 2 + f * 7) & 0x3F) + 40
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let ub = if scene_b {
          (170 - ((row + col) & 0x2F)).to_byte()
        } else {
          (((col + f) & 0x3F) + 96).to_byte()
        }
        let vb = if scene_b {
          (90 + ((row * 2) & 0x2F)).to_byte()
        } else {
          (((row + f * 2) & 0x3F) + 96).to_byte()
        }
        u.push(ub)
        v.push(vb)
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
test "h264 enc bi4: fine-texture B pictures pick Intra4x4 (cavlc)" {
  let frames = h264bi4_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=18,
      b_slices=true,
      intra4x4_in_b=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i4p_mbs <= 0 {
    fail("no Intra4x4 macroblocks inside the B slices")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bi_check_recon(dec, recon, 96, 64, 1)
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) =>
      if f.length() != 6 {
        fail("filtered decode: expected 6 frames, got \{f.length()}")
      }
    Err(e) => fail(e)
  }
}

///|
test "h264 enc bi4: fine-texture B pictures pick Intra4x4 (cabac)" {
  let frames = h264bi4_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=18,
      b_slices=true,
      intra4x4_in_b=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i4p_mbs <= 0 {
    fail("no Intra4x4 macroblocks inside the B slices under CABAC")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bi_check_recon(dec, recon, 96, 64, 1)
}

///|
test "h264 enc bi4: streaming encoder is byte-identical to the batch" {
  let frames = h264bi4_fixture(64, 64, 4)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=64,
      qp=20,
      b_slices=true,
      intra4x4_in_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=64,
      qp=20,
      b_slices=true,
      intra4x4_in_b=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let streamed : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      streamed.push(au)
    }
  }
  match enc.finish() {
    Ok(au) =>
      for part in au {
        streamed.push(part)
      }
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for part in streamed {
    for i in 0..<part.length() {
      joined.push(part[i])
    }
  }
  let joined_bytes = Bytes::from_array(joined[:])
  if joined_bytes.length() != batch.length() {
    fail(
      "streamed \{joined_bytes.length()} bytes vs batch \{batch.length()} bytes",
    )
  }
  for i in 0..<batch.length() {
    if joined_bytes[i] != batch[i] {
      fail("stream/batch byte mismatch at \{i}")
    }
  }
  // intra4x4_in_b without b_slices must be rejected by the stream opener.
  match
    @libavcodec.H264StreamEncoder::open(width=64, height=64, intra4x4_in_b=true) {
    Ok(_) => fail("intra4x4_in_b without b_slices must fail")
    Err(_) => ()
  }
}

///|
/// Display-order packed-YUV MD5s of the fine-texture stream (the
/// framemd5 arbitration order).
fn h264bi4_display_md5s(frames : Array[@libavcodec.H264Frame]) -> Array[String] {
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
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// fine-texture I/P/B stream codes Intra4x4 B macroblocks and decodes in
/// the reference implementation with zero warnings, in DISPLAY order
/// (POC reordering), every deblocked frame matching this repository's
/// decoder byte-for-byte (pinned framemd5 MD5s, obtained via the ARBBI4
/// dump route).
test "h264 enc bi4: ffmpeg-arbitrated six frames (96x64, QP 18)" {
  let frames = h264bi4_fixture(96, 64, 6)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=18,
      b_slices=true,
      intra4x4_in_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i in 0..<stream.length() {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBI4:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames")
  }
  let md5s = h264bi4_display_md5s(dec)
  for md5 in md5s {
    println("ARBBI4MD5:\{md5}")
  }
  let pins = [
    "8123205a72cae4bfd209c448bb42fe6f", "dcc556dfe40339f31443e945548dc067", "cd1c2449c3a2d9a02203c2e917d55d56",
    "811cbefba136977c0966429cbebb487e", "641def1012f507dae51392251d05b56f", "ca4bab8aa324678d80cc7942c9768ba0",
  ]
  for i in 0..<6 {
    inspect(md5s[i], content=pins[i])
  }
}

///|
/// A coarse-texture scene-cut fixture: the B pictures are constant per
/// 8x8 block (a block-hash pattern), so the four pred8x8l predictors
/// track it block by block while the single I16x16 predictor cannot and
/// the 4x4 form wastes bits on 16 mode codewords.
fn h264bi8_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let scene_b = f % 2 == 1 && f > 0
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let s = if scene_b {
          let bx = col / 8
          let by = row / 8
          70 + ((bx * 11 + by * 5 + f * 3) & 0x1F) * 4
        } else {
          ((col * 3 + row * 2 + f * 7) & 0x3F) + 40
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let ub = if scene_b {
          (170 - ((row + col) & 0x2F)).to_byte()
        } else {
          (((col + f) & 0x3F) + 96).to_byte()
        }
        let vb = if scene_b {
          (90 + ((row * 2) & 0x2F)).to_byte()
        } else {
          (((row + f * 2) & 0x3F) + 96).to_byte()
        }
        u.push(ub)
        v.push(vb)
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

///|
test "h264 enc bi8: High-profile b_seq IDR roundtrip and arbitration" {
  let frames = h264bi8_fixture(96, 64, 1)
  let stream = match
    @libavcodec.h264_encode_intra_frame(
      frames[0].0,
      frames[0].1,
      frames[0].2,
      width=96,
      height=64,
      qp=20,
      dct8x8=true,
      b_seq=true,
    ) {
    Ok(e) => e.annexb
    Err(e) => fail(e)
  }
  ignore(frames)
  let mut dump = ""
  for i in 0..<stream.length() {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBDC8:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 1 {
    fail("expected 1 frame, got \{dec.length()}")
  }
  let md5 = h264b_md5(dec[0].yuvp())
  println("ARBBDC8MD5:\{md5}")
  // Pinned once docker ffmpeg agreed (the High-profile b_seq IDR).
  inspect(md5, content="208469698064f1d80620d092ca2bb19e")
}
