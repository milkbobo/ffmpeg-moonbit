///|
/// `§430` fixtures: reuse the deblock fixture (moving gradients).
fn h264hint_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  h264dbg_fixture(64, 48, n, 1)
}

///|
/// One full-frame hint of the given kind.
fn h264hint_full(kind : Int32) -> @libavcodec.H264VideoHint {
  { kind, rects: [{ x: 0, y: 0, width: 64, height: 48, }], }
}

///|
/// The same hint repeated for every display position of `n` frames.
fn h264hint_all(
  n : Int32,
  hint : @libavcodec.H264VideoHint,
) -> Array[@libavcodec.H264VideoHint?] {
  let out : Array[@libavcodec.H264VideoHint?] = []
  for i = 0; i < n; i = i + 1 {
    out.push(Some(hint))
  }
  out
}

///|
/// Byte equality helper.
fn h264hint_same(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// Batch P-only encode with optional per-frame hints.
fn h264hint_batch(
  frames : Array[(Bytes, Bytes, Bytes)],
  hints : Array[@libavcodec.H264VideoHint?],
  cabac : Bool,
  pcm_first : Bool,
  deblock : Bool,
) -> Bytes raise {
  if cabac {
    match
      @libavcodec.h264_encode_frames_cabac(
        frames,
        width=64,
        height=48,
        qp=26,
        b_slices=false,
        hints~,
        deblock~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
  } else {
    match
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        b_slices=false,
        hints~,
        pcm_first~,
        deblock~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
  }
}

///|
/// `§430`: a constant full-frame hint forces every P macroblock to skip —
/// the hinted stream must be smaller than the baseline on moving content
/// (x264 trusts the hint unconditionally; both CAVLC and CABAC).
test "h264 enc hint: constant full-frame forces skips" {
  let frames = h264hint_fixture(4)
  let hint = h264hint_full(@libavcodec.h264_video_hint_constant)
  let hints = h264hint_all(4, hint)
  let base = h264hint_batch(frames, [], false, false, true)
  let hinted = h264hint_batch(frames, hints, false, false, true)
  assert_true(
    hinted.length() < base.length(),
    msg="CAVLC hinted=\{hinted.length()} base=\{base.length()}",
  )
  let base_cabac = h264hint_batch(frames, [], true, false, true)
  let hinted_cabac = h264hint_batch(frames, hints, true, false, true)
  assert_true(
    hinted_cabac.length() < base_cabac.length(),
    msg="CABAC hinted=\{hinted_cabac.length()} base=\{base_cabac.length()}",
  )
}

///|
/// `§430`: an accurate hint does not change what the encoder would pick —
/// static content with a lossless IDR makes every P macroblock a natural
/// skip, so the hinted stream is byte-identical (the `§424e` lesson).
test "h264 enc hint: accurate constant hint is a no-op" {
  let one = h264hint_fixture(1)
  let frames : Array[(Bytes, Bytes, Bytes)] = [one[0], one[0], one[0], one[0]]
  let hints = h264hint_all(
    4,
    h264hint_full(@libavcodec.h264_video_hint_constant),
  )
  let base = h264hint_batch(frames, [], false, true, false)
  let hinted = h264hint_batch(frames, hints, false, true, false)
  assert_true(
    h264hint_same(base, hinted),
    msg="accurate hint changed the stream",
  )
}

///|
/// `§430`: the two spellings of the same claim are equivalent — `Constant`
/// with an empty list means "the whole frame changed" (no skip), `Changed`
/// with an empty list means "nothing changed" (all skip), matching
/// `Constant` with a full-frame rectangle.
test "h264 enc hint: empty-rect spellings match their full-frame twins" {
  let frames = h264hint_fixture(4)
  let constant_empty : Array[@libavcodec.H264VideoHint?] = []
  for i = 0; i < 4; i = i + 1 {
    constant_empty.push(
      Some({ kind: @libavcodec.h264_video_hint_constant, rects: [], }),
    )
  }
  let changed_empty : Array[@libavcodec.H264VideoHint?] = []
  for i = 0; i < 4; i = i + 1 {
    changed_empty.push(
      Some({ kind: @libavcodec.h264_video_hint_changed, rects: [], }),
    )
  }
  let base = h264hint_batch(frames, [], false, false, true)
  let no_skip = h264hint_batch(frames, constant_empty, false, false, true)
  assert_true(h264hint_same(base, no_skip), msg="Constant([]) != no hint")
  let all_skip = h264hint_batch(frames, changed_empty, false, false, true)
  let constant_full = h264hint_batch(
    frames,
    h264hint_all(4, h264hint_full(@libavcodec.h264_video_hint_constant)),
    false,
    false,
    true,
  )
  assert_true(
    h264hint_same(all_skip, constant_full),
    msg="Changed([]) != Constant(full)",
  )
}

///|
/// `§430`: the grid rounding follows upstream — `Constant` keeps the
/// macroblocks fully inside (ceil/floor), `Changed` clears every intersecting
/// one (floor/ceil). Two spellings that cover the same grid cell are
/// byte-identical; a non-aligned `Constant` rect that misses every MB is the
/// no-hint baseline.
test "h264 enc hint: grid rounding distinguishes the kinds" {
  let frames = h264hint_fixture(4)
  let rect_of = fn(
    x : Int32,
    y : Int32,
    w : Int32,
    h : Int32,
  ) -> Array[@libavcodec.H264VideoRect] {
    [{ x, y, width: w, height: h, }]
  }
  let constant_a : Array[@libavcodec.H264VideoHint?] = []
  let constant_b : Array[@libavcodec.H264VideoHint?] = []
  let changed_a : Array[@libavcodec.H264VideoHint?] = []
  let changed_b : Array[@libavcodec.H264VideoHint?] = []
  let constant_none : Array[@libavcodec.H264VideoHint?] = []
  for i = 0; i < 4; i = i + 1 {
    // Both keep exactly macroblock (1, 1) constant.
    constant_a.push(
      Some({
        kind: @libavcodec.h264_video_hint_constant,
        rects: rect_of(16, 16, 16, 16),
      }),
    )
    constant_b.push(
      Some({
        kind: @libavcodec.h264_video_hint_constant,
        rects: rect_of(15, 16, 18, 16),
      }),
    )
    // Both clear exactly macroblock (1, 1) from the all-constant default.
    changed_a.push(
      Some({
        kind: @libavcodec.h264_video_hint_changed,
        rects: rect_of(16, 16, 16, 16),
      }),
    )
    changed_b.push(
      Some({
        kind: @libavcodec.h264_video_hint_changed,
        rects: rect_of(17, 17, 15, 15),
      }),
    )
    // Not fully inside any macroblock: the constant map stays empty.
    constant_none.push(
      Some({
        kind: @libavcodec.h264_video_hint_constant,
        rects: rect_of(17, 17, 15, 15),
      }),
    )
  }
  assert_true(
    h264hint_same(
      h264hint_batch(frames, constant_a, false, false, true),
      h264hint_batch(frames, constant_b, false, false, true),
    ),
    msg="aligned Constant spellings diverged",
  )
  assert_true(
    h264hint_same(
      h264hint_batch(frames, changed_a, false, false, true),
      h264hint_batch(frames, changed_b, false, false, true),
    ),
    msg="inset Changed spellings diverged",
  )
  let base = h264hint_batch(frames, [], false, false, true)
  let none = h264hint_batch(frames, constant_none, false, false, true)
  assert_true(
    h264hint_same(base, none),
    msg="non-aligned Constant rect marked a macroblock",
  )
}

///|
/// `§430`: an unknown hint kind is rejected with the exact reason (batch and
/// streaming push); the selectors are the `§424e` binding's 1/2 vocabulary.
test "h264 enc hint: unknown kind is rejected" {
  let frames = h264hint_fixture(2)
  let bad : @libavcodec.H264VideoHint? = Some({ kind: 3, rects: [], })
  let want = "h264 enc: unsupported video hint kind 3 (1 = constant, 2 = changed)"
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=false,
      hints=[bad, bad],
    ) {
    Ok(_) => fail("unknown hint kind accepted by the batch entry")
    Err(e) => assert_eq(e, want)
  }
  let (y, u, v) = frames[0]
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=64, height=48, qp=26) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  match enc.push_frame(y, u, v, hint=bad) {
    Ok(_) => fail("unknown hint kind accepted by push_frame")
    Err(e) => assert_eq(e, want)
  }
}

///|
/// `§430`: streaming carries the per-picture hint — the P-only stream equals
/// the batch entry with the same hints, and an odd B push stashes the hint
/// until the pending picture is coded.
test "h264 enc hint: streaming carries the per-picture hint" {
  let frames = h264hint_fixture(3)
  let hint = h264hint_full(@libavcodec.h264_video_hint_constant)
  let hints = h264hint_all(3, hint)
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=48,
      qp=26,
      b_slices=false,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let parts : Array[Byte] = []
  for i = 0; i < frames.length(); i = i + 1 {
    let (y, u, v) = frames[i]
    match enc.push_frame(y, u, v, hint=Some(hint)) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      for k = 0; k < au.length(); k = k + 1 {
        parts.push(au[k])
      }
    }
  }
  match enc.finish() {
    Ok(t) =>
      for au in t {
        for k = 0; k < au.length(); k = k + 1 {
          parts.push(au[k])
        }
      }
    Err(e) => fail(e)
  }
  let stream = Bytes::from_array(parts[:])
  let batch = h264hint_batch(frames, hints, false, false, true)
  assert_true(h264hint_same(stream, batch), msg="stream != batch with hints")
  // B schedule: the odd push's hint is stashed and applied when the pair is
  // coded; dropping it from that push changes the stream.
  fn stream_with(mid_hint : @libavcodec.H264VideoHint?) -> Bytes raise {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=64,
        height=48,
        qp=26,
        b_slices=true,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let out : Array[Byte] = []
    for i = 0; i < frames.length(); i = i + 1 {
      let (y, u, v) = frames[i]
      let h = if i == 1 { mid_hint } else { None }
      match enc.push_frame(y, u, v, hint=h) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      for au in enc.drain() {
        for k = 0; k < au.length(); k = k + 1 {
          out.push(au[k])
        }
      }
    }
    match enc.finish() {
      Ok(t) =>
        for au in t {
          for k = 0; k < au.length(); k = k + 1 {
            out.push(au[k])
          }
        }
      Err(e) => fail(e)
    }
    Bytes::from_array(out[:])
  }

  let with_mid = stream_with(Some(hint))
  let without_mid = stream_with(None)
  assert_true(
    !h264hint_same(with_mid, without_mid),
    msg="pending B picture lost its hint",
  )
}
