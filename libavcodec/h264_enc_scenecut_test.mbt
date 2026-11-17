// Blackbox tests for §436: streaming scene-cut detection (x264
// `--scenecut`). The proxy pair is the inter SAD against the previous
// display frame vs the frame's spatial gradient; a push whose inter
// residual reaches `(100 - scenecut)%` of the gradient codes as an IDR,
// closing the GOP (a pending B first codes as a tail P). Off (0, the
// default) keeps every stream byte-identical.

///|
/// Two smooth scenes with a hard cut: A (frames 0..cut-1) is a slow
/// gradient drift, B (frames cut..n-1) a different, inverted texture —
/// the inter SAD at the cut is the full frame energy while each scene's
/// own frames stay highly predictable.
fn h264scn_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
  cut : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  let cw = w / 2
  let ch = h / 2
  for k in 0..<n {
    let scene_b = k >= cut
    let drift = if scene_b { 0 } else { k }
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch, b'\x00')
    for row in 0..<h {
      for col in 0..<w {
        let base = (col * 3 + row * 5 + col * row % 17 * 2) % 170 + 40 + drift
        y[row * w + col] = if scene_b {
          (235 - base).to_byte()
        } else {
          base.to_byte()
        }
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        let ub = 96 + (col * 5 + row * 3) % 48
        let vb = 150 - (col * 3 + row * 5) % 40
        u[row * cw + col] = if scene_b {
          (255 - ub).to_byte()
        } else {
          ub.to_byte()
        }
        v[row * cw + col] = if scene_b {
          (255 - vb).to_byte()
        } else {
          vb.to_byte()
        }
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
/// Count `recovery_point` SEI messages: SEI NALs (nal type 6) whose
/// payload type byte is 6 (every SEI of this encoder rides its own NAL,
/// so the first payload byte decides — pic_timing/buffering_period are
/// separate NALs and must not count).
fn h264scn_count_recovery_sei(stream : Bytes) -> Int32 {
  let len = stream.length()
  let mut i = 0
  let mut count = 0
  while i + 3 <= len {
    if stream[i] == b'\x00' &&
      stream[i + 1] == b'\x00' &&
      (
        stream[i + 2] == b'\x01' ||
        (i + 3 < len && stream[i + 2] == b'\x00' && stream[i + 3] == b'\x01')
      ) {
      let head = if stream[i + 2] == b'\x01' { i + 3 } else { i + 4 }
      if head < len &&
        (stream[head] & 0x1f).to_int() == 6 &&
        head + 1 < len &&
        stream[head + 1].to_int() == 6 {
        count = count + 1
      }
      i = head
    } else {
      i = i + 1
    }
  }
  count
}

///|
/// Count the Annex B NAL units of one type (5 = IDR slice, 7 = SPS —
/// every IDR AU re-emits the parameter sets).
fn h264scn_count_nal(stream : Bytes, want : Int32) -> Int32 {
  let len = stream.length()
  let mut i = 0
  let mut count = 0
  while i + 3 <= len {
    if stream[i] == b'\x00' &&
      stream[i + 1] == b'\x00' &&
      (
        stream[i + 2] == b'\x01' ||
        (i + 3 < len && stream[i + 2] == b'\x00' && stream[i + 3] == b'\x01')
      ) {
      let head = if stream[i + 2] == b'\x01' { i + 3 } else { i + 4 }
      if head < len && (stream[head] & 0x1f).to_int() == want {
        count = count + 1
      }
      i = head
    } else {
      i = i + 1
    }
  }
  count
}

///|
/// Encode a frame array through a fresh streaming encoder (AU join).
fn h264scn_stream(
  frames : Array[(Bytes, Bytes, Bytes)],
  scenecut : Int32,
  b_slices~ : Bool = true,
  crf~ : Double = -1.0,
  vbv~ : (Int32, Int32, Int32) = (0, 0, 0),
) -> (Bytes, Int32) raise {
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      b_slices~,
      crf~,
      scenecut~,
      vbv_maxrate=vbv.0,
      vbv_bufsize=vbv.1,
      fps=vbv.2,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  (Bytes::from_array(bytes[:]), parts.length())
}

///|
test "h264 enc scenecut: default off is byte-identical" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let (plain, _) = h264scn_stream(frames, 0)
  let (off, _) = h264scn_stream(frames, 0)
  if plain != off {
    fail("scenecut=0 changed the default stream")
  }
  // One IDR (the sequence head), and its AU carries the parameter sets.
  if h264scn_count_nal(plain, 5) != 1 {
    fail("expected exactly one IDR slice NAL")
  }
}

///|
test "h264 enc scenecut: hard cut inserts an IDR, B schedule intact" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  // The cut sits at display 3 — an odd position, so with the B schedule
  // a pending B must close as a tail P before the new GOP's IDR.
  let (cut_stream, _) = h264scn_stream(frames, 40)
  if h264scn_count_nal(cut_stream, 5) != 2 {
    fail(
      "expected the cut to insert a second IDR, got \{h264scn_count_nal(cut_stream, 5)}",
    )
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(cut_stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  if dec.length() != 8 {
    fail("expected 8 decoded frames, got \{dec.length()}")
  }
  // The default stream (off) has one IDR and decodes the same count.
  let (off_stream, _) = h264scn_stream(frames, 0)
  let dec0 = match @libavcodec.h264_decode_annexb_frames(off_stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  if dec0.length() != 8 {
    fail("baseline decode failed")
  }
}

///|
test "h264 enc scenecut: smooth motion never cuts" {
  // No scene change at all: the drift frames stay predictable.
  let frames = h264scn_fixture(96, 64, 8, 1000)
  let (stream, _) = h264scn_stream(frames, 40)
  if h264scn_count_nal(stream, 5) != 1 {
    fail("smooth sequence must not cut")
  }
  // A truly static run (identical frames) never cuts even at the most
  // aggressive threshold — the inter SAD stays zero (scenecut=100 means
  // "cut on ANY inter activity", the x264 extreme, and static frames
  // have none).
  let static_frames = h264scn_fixture(96, 64, 6, 1000).map(fn(f) { f })
  let mut i = 1
  while i < static_frames.length() {
    static_frames[i] = static_frames[0]
    i = i + 1
  }
  let (aggr, _) = h264scn_stream(static_frames, 100)
  if h264scn_count_nal(aggr, 5) != 1 {
    fail("static sequence cut even with inter==0")
  }
}

///|
test "h264 enc scenecut: explicit pict_type wins over the detector" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=96, height=64, qp=26, scenecut=40) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for i, (y, u, v) in frames {
    // Force the cut frame to stay a P picture.
    let pt = if i == 3 {
      @libavcodec.h264_pict_type_p
    } else {
      @libavcodec.h264_pict_type_auto
    }
    match enc.push_frame(y, u, v, pict_type=pt) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  let stream = Bytes::from_array(bytes[:])
  if h264scn_count_nal(stream, 5) != 1 {
    fail("explicit P at the cut must suppress the auto IDR")
  }
}

///|
test "h264 enc scenecut: composes with CRF and online VBV" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let (crf_stream, _) = h264scn_stream(frames, 40, crf=23.0)
  if h264scn_count_nal(crf_stream, 5) != 2 {
    fail("crf composition lost the cut IDR")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(crf_stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  if dec.length() != 8 {
    fail("crf+scenecut decode failed: \{dec.length()} frames")
  }
  let (vbv_stream, _) = h264scn_stream(frames, 40, vbv=(150000, 120000, 25))
  let dec2 = match @libavcodec.h264_decode_annexb_frames(vbv_stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  if dec2.length() != 8 {
    fail("vbv+scenecut decode failed: \{dec2.length()} frames")
  }
  if h264scn_count_nal(vbv_stream, 5) < 2 {
    fail("vbv composition lost the cut IDR")
  }
}

///|
test "h264 enc scenecut: facade passthrough equals the direct encoder" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let (direct, _) = h264scn_stream(frames, 40)
  let config : @libavcodec.VideoEncConfig = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    scenecut: 40,
  }
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  if Bytes::from_array(bytes[:]) != direct {
    fail("facade scenecut stream differs from the direct encoder")
  }
}

///|
test "h264 enc scenecut: range validation" {
  match @libavcodec.H264StreamEncoder::open(width=96, height=64, scenecut=101) {
    Err(e) => inspect(e, content="h264 enc: scenecut must be in 0..=100")
    Ok(_) => fail("scenecut=101 was accepted")
  }
  match @libavcodec.H264StreamEncoder::open(width=96, height=64, scenecut=-1) {
    Err(e) => inspect(e, content="h264 enc: scenecut must be in 0..=100")
    Ok(_) => fail("scenecut=-1 was accepted")
  }
}

///|
/// `§437`: open-GOP cuts — the detected cut codes as a non-IDR keyframe
/// whose AU carries a `recovery_point` SEI (type 6), instead of an IDR.
test "h264 enc scenecut: open-gop keyframe with recovery point SEI" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      scenecut=40,
      open_gop=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  let stream = Bytes::from_array(bytes[:])
  // No second IDR — the cut is a non-IDR keyframe; its AU declares the
  // recovery point instead.
  if h264scn_count_nal(stream, 5) != 1 {
    fail("open-gop must not insert a second IDR")
  }
  if h264scn_count_recovery_sei(stream) != 1 {
    fail("expected exactly one recovery-point SEI NAL")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  if dec.length() != 8 {
    fail("expected 8 decoded frames, got \{dec.length()}")
  }
  // The SEI's recovery_frame_cnt (= 0) lands on the keyframe's picture.
  let mut recovery_frames = 0
  for f in dec {
    if f.sei_recovery_frame_cnt == 0 {
      recovery_frames = recovery_frames + 1
    }
  }
  if recovery_frames != 1 {
    fail("expected exactly one recovery-point frame, got \{recovery_frames}")
  }
}

///|
test "h264 enc scenecut: open-gop composes with online VBV" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      scenecut=40,
      open_gop=true,
      vbv_maxrate=150000,
      vbv_bufsize=120000,
      fps=25,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  let stream = Bytes::from_array(bytes[:])
  if h264scn_count_nal(stream, 5) != 1 ||
    h264scn_count_recovery_sei(stream) != 1 {
    fail("vbv composition lost the open-gop shape")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  if dec.length() != 8 {
    fail("vbv+open-gop decode failed: \{dec.length()} frames")
  }
}

///|
test "h264 enc scenecut: open-gop needs scenecut and explicit keyframes stay bare" {
  match
    @libavcodec.H264StreamEncoder::open(width=96, height=64, open_gop=true) {
    Err(e) => inspect(e, content="h264 enc: open_gop requires scenecut > 0")
    Ok(_) => fail("open_gop without scenecut was accepted")
  }
  // An explicit Keyframe request keeps the §431 bytes (no SEI).
  let frames = h264scn_fixture(96, 64, 8, 3)
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      scenecut=40,
      open_gop=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for i, (y, u, v) in frames {
    let pt = if i == 3 {
      @libavcodec.h264_pict_type_keyframe
    } else {
      @libavcodec.h264_pict_type_auto
    }
    match enc.push_frame(y, u, v, pict_type=pt) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  let stream = Bytes::from_array(bytes[:])
  if h264scn_count_recovery_sei(stream) != 0 {
    fail("explicit keyframe requests must not carry a recovery SEI")
  }
  // The same pushes without the explicit request (auto cut) do carry it
  // — this is the §431/§437 byte distinction.
  let (auto_stream, _) = h264scn_open_stream(frames)
  if h264scn_count_recovery_sei(auto_stream) != 1 {
    fail("auto cut must carry the recovery SEI")
  }
}

///|
/// Open-GOP encode helper (auto cuts only).
fn h264scn_open_stream(
  frames : Array[(Bytes, Bytes, Bytes)],
) -> (Bytes, Int32) raise {
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      scenecut=40,
      open_gop=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  (Bytes::from_array(bytes[:]), parts.length())
}

///|
test "h264 enc scenecut: open-gop facade passthrough" {
  let frames = h264scn_fixture(96, 64, 8, 3)
  let (direct, _) = h264scn_open_stream(frames)
  let config : @libavcodec.VideoEncConfig = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    scenecut: 40,
    open_gop: true,
  }
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let parts = enc.drain()
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let bytes : Array[Byte] = []
  for au in parts {
    for i = 0; i < au.length(); i = i + 1 {
      bytes.push(au[i])
    }
  }
  if Bytes::from_array(bytes[:]) != direct {
    fail("facade open-gop stream differs from the direct encoder")
  }
}
