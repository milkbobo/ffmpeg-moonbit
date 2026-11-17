// Blackbox tests for §435: constant rate factor (x264 --crf). The value
// is the baseline QP; every later picture bends around it by its temporal
// complexity (luma SAD vs the previous display frame) relative to the
// running mean. The fixture below alternates exact-copy frames (SAD 0)
// and uniform +40 shifts (constant SAD), so the expected QP sequence is
// exactly computable. The recurrence is display-causal, which the
// stream==batch byte-equality cases pin.

///|
/// `[A, A+40, A+40, A, A, A+40]`: every odd display position moves by the
/// same constant delta against its predecessor, every even position >= 2
/// is an exact copy — complexity samples [S, 0, S, 0, S] with identical S.
fn h264crf_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  let cw = w / 2
  let ch = h / 2
  for k in 0..<n {
    let shift = if k == 1 || k == 2 || k == 5 { 40 } else { 0 }
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch, b'\x00')
    for row in 0..<h {
      for col in 0..<w {
        let base = (col * 3 + row * 5 + col * row % 17 * 2) % 110 + 60
        y[row * w + col] = (base + shift).to_byte()
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        u[row * cw + col] = (96 + (col * 5 + row * 3) % 48).to_byte()
        v[row * cw + col] = (150 - (col * 3 + row * 5) % 40).to_byte()
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
/// Concatenate access units (each test file is its own blackbox unit).
fn h264crf_concat(aus : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for au in aus {
    for i = 0; i < au.length(); i = i + 1 {
      out.push(au[i])
    }
  }
  Bytes::from_array(out[:])
}

///|
test "h264 enc crf: default off is byte-identical" {
  let frames = h264crf_fixture(96, 64, 6)
  let plain = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26, crf=-1.0) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if plain != off {
    fail("crf=-1 changed the default stream")
  }
  let stats = @libavcodec.H264EncStats::new()
  let _ = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      crf=23.0,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Baseline QP round(23) heads the display-order QP record.
  if stats.frame_qps[0] != 23 {
    fail("expected baseline 23 at picture 0, got \{stats.frame_qps[0]}")
  }
}

///|
test "h264 enc crf: complexity-weighted QP schedule (cavlc B line)" {
  let frames = h264crf_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      crf=23.0,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Samples [S, 0, S, 0, S]: picture 1 sits at the mean (baseline),
  // exact-copy pictures saturate +6, moving pictures refine below the
  // baseline as static samples dilute the mean (3/2 then 5/3 ratios at
  // qcompress 0.6 -> -1.404 and -1.769 QP).
  let want = [23, 23, 29, 22, 29, 21]
  for i in 0..<6 {
    if stats.frame_qps[i] != want[i] {
      fail("picture \{i}: expected QP \{want[i]}, got \{stats.frame_qps[i]}")
    }
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 decoded frames, got \{dec.length()}")
  }
  if recon.length() != 5 {
    fail("expected 5 recons, got \{recon.length()}")
  }
  for i in 0..<recon.length() {
    let r = dec[i + 1]
    let src = recon[i]
    for row = 0; row < 64; row = row + 1 {
      for col = 0; col < 96; col = col + 1 {
        if src[row * 96 + col] != r.y[row * r.ystride + col].to_byte() {
          fail("crf recon mismatch at slot \{i}, \{row},\{col}")
        }
      }
    }
  }
}

///|
test "h264 enc crf: CABAC entry and quality monotonicity" {
  let frames = h264crf_fixture(96, 64, 6)
  let stats = @libavcodec.H264EncStats::new()
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      crf=23.0,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let want = [23, 23, 29, 22, 29, 21]
  for i in 0..<6 {
    if stats.frame_qps[i] != want[i] {
      fail(
        "cabac picture \{i}: expected QP \{want[i]}, got \{stats.frame_qps[i]}",
      )
    }
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(cabac, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("cabac crf stream failed to decode")
  }
  // Finer CRF costs more bytes on both entropy paths (identical QP
  // schedules; only the baseline moves 18 vs 28).
  let size = fn(crf : Double, cabac : Bool) -> Int32 raise {
    let stream = if cabac {
      match
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          crf~,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
    } else {
      match
        @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26, crf~) {
        Ok(s) => s
        Err(e) => fail(e)
      }
    }
    stream.length()
  }
  if size(18.0, false) <= size(28.0, false) {
    fail("cavlc crf 18 did not cost more than crf 28")
  }
  if size(18.0, true) <= size(28.0, true) {
    fail("cabac crf 18 did not cost more than crf 28")
  }
  // Decimals round to the baseline (18.4 -> 18).
  let a = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26, crf=18.4) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let b = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26, crf=18.0) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if a != b {
    fail("crf 18.4 did not round to the 18 baseline")
  }
}

///|
test "h264 enc crf: streaming equals batch (B and P schedules)" {
  let frames = h264crf_fixture(96, 64, 6)
  for b_slices in [true, false] {
    let batch = match
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        qp=26,
        b_slices~,
        crf=23.0,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=96,
        height=64,
        qp=26,
        b_slices~,
        crf=23.0,
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
    let tail = match enc.finish() {
      Ok(t) => t
      Err(e) => fail(e)
    }
    let parts : Array[Bytes] = []
    for au in enc.drain() {
      parts.push(au)
    }
    for au in tail {
      parts.push(au)
    }
    if parts.length() == 0 {
      fail("streaming crf produced no access units")
    }
    let joined = h264crf_concat(parts)
    if joined != batch {
      fail(
        "streaming crf != batch (b_slices=\{b_slices}): \{joined.length()} vs \{batch.length()} bytes",
      )
    }
  }
}

///|
test "h264 enc crf: VBV composes on both batch and streaming" {
  let frames = h264crf_fixture(96, 64, 6)
  // A tight bucket: the CRF schedule must climb wherever the CPB demands
  // (the solver only ever raises QPs, so every picture stays >= its CRF
  // assignment).
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      crf=23.0,
      vbv_maxrate=20000,
      vbv_bufsize=6000,
      fps=25,
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
    fail("expected 6 decoded frames under crf+vbv, got \{dec.length()}")
  }
  for q in stats.frame_qps {
    if q < 21 {
      fail("crf+vbv dropped below the CRF floor: QP \{q}")
    }
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      crf=23.0,
      vbv_maxrate=20000,
      vbv_bufsize=6000,
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
  match enc.finish() {
    Ok(t) => {
      let all = enc.drain()
      for au in t {
        all.push(au)
      }
      let dec2 = match
        @libavcodec.h264_decode_annexb_frames(h264crf_concat(all), false) {
        Ok(f) => f
        Err(e) => fail(e)
      }
      if dec2.length() != 6 {
        fail("streaming crf+vbv decoded \{dec2.length()} frames")
      }
    }
    Err(e) => fail(e)
  }
}

///|
test "h264 enc crf: exclusions and range" {
  let frames = h264crf_fixture(96, 64, 4)
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      crf=23.0,
      target_bytes=1000,
    ) {
    Err(e) =>
      inspect(
        e,
        content="h264 enc: crf and target_bytes are mutually exclusive",
      )
    Ok(_) => fail("crf+target_bytes was accepted")
  }
  match @libavcodec.h264_encode_frames(frames, width=96, height=64, crf=51.5) {
    Err(e) => inspect(e, content="h264 enc: crf must be in 0.0..=51.0")
    Ok(_) => fail("crf>51 was accepted")
  }
  match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      crf=23.0,
      target_bytes=1000,
    ) {
    Err(e) =>
      inspect(
        e,
        content="h264 enc: crf and target_bytes are mutually exclusive",
      )
    Ok(_) => fail("cabac crf+target_bytes was accepted")
  }
  match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      crf=23.0,
      target_bitrate=100000,
      fps=25,
    ) {
    Err(e) =>
      inspect(
        e,
        content="h264 enc: crf and target_bitrate are mutually exclusive",
      )
    Ok(_) => fail("streaming crf+abr was accepted")
  }
  // Forced pict_types follow the target_bytes/VBV exclusion contract.
  match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, crf=23.0, pict_types=[
      0, 3, 3, 3,
    ]) {
    Err(e) =>
      inspect(
        e,
        content="h264 enc: pict_types is not supported with target_bytes or VBV (use the streaming encoder)",
      )
    Ok(_) => fail("crf+forced pict_types was accepted")
  }
}

///|
test "h264 enc crf: facade passthrough equals the batch entry" {
  let frames = h264crf_fixture(96, 64, 6)
  let direct = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26, crf=23.0) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let config : @libavcodec.VideoEncConfig = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    crf: 23.0,
  }
  let facade = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if facade != direct {
    fail("facade crf stream differs from the batch entry")
  }
  // The facade rejects the same mode clash with its own prefix.
  match
    @libavcodec.video_encode(frames, codec=@libavcodec.VideoCodec::H264, config={
      ..config,
      target_bytes: 1000,
    }) {
    Err(e) =>
      inspect(
        e,
        content="video enc: crf and target_bytes are mutually exclusive",
      )
    Ok(_) => fail("facade crf+target_bytes was accepted")
  }
}
