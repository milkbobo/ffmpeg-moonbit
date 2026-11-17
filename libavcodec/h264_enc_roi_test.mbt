///|
/// `§429` fixtures: reuse the deblock fixture (moving gradient content).
fn h264roi_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  h264dbg_fixture(64, 48, n, 1)
}

///|
/// One full-frame region: `qoffset_num / 51` is the normalised offset on the
/// 8-bit QP range (the `§424c` binding's `+10/51` / `-10/51` values).
fn h264roi_full(q : Int32) -> Array[@libavcodec.H264Roi] {
  [{ top: 0, bottom: 48, left: 0, right: 64, qoffset_num: q, qoffset_den: 51, }]
}

///|
/// Byte equality helper (`Bytes` has no structural `==` in tests).
fn h264roi_same(a : Bytes, b : Bytes) -> Bool {
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
/// Encode one IDR with the fixture and an optional ROI map.
fn h264roi_intra(aq : Bool, roi : Array[@libavcodec.H264Roi]) -> Bytes raise {
  let frames = h264roi_fixture(1)
  let (y, u, v) = frames[0]
  match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=48,
      qp=26,
      aq~,
      aq_strength=0,
      roi~,
    ) {
    Ok(e) => e.annexb
    Err(e) => fail(e)
  }
}

///|
/// `§429`: a full-frame ROI offset moves the intra bitstream in the requested
/// direction against a flat-QP baseline (`aq_strength=0` keeps AQ neutral).
test "h264 enc roi: intra full-frame delta QP moves the bitstream both ways" {
  let base = h264roi_intra(true, [])
  let worse = h264roi_intra(true, h264roi_full(10))
  let better = h264roi_intra(true, h264roi_full(-10))
  assert_true(
    worse.length() < base.length(),
    msg="worse=\{worse.length()} base=\{base.length()}",
  )
  assert_true(
    better.length() > base.length(),
    msg="better=\{better.length()} base=\{base.length()}",
  )
}

///|
/// `§429`: the CABAC intra entry applies the same per-MB offsets.
test "h264 enc roi: CABAC intra obeys the same ordering" {
  let frames = h264roi_fixture(1)
  let (y, u, v) = frames[0]
  fn enc(roi : Array[@libavcodec.H264Roi]) -> Bytes raise {
    match
      @libavcodec.h264_encode_intra_frame_cabac(
        y,
        u,
        v,
        width=64,
        height=48,
        qp=26,
        aq=true,
        aq_strength=0,
        roi~,
      ) {
      Ok(e) => e.annexb
      Err(e) => fail(e)
    }
  }

  let base = enc([])
  let worse = enc(h264roi_full(10))
  let better = enc(h264roi_full(-10))
  assert_true(
    worse.length() < base.length(),
    msg="worse=\{worse.length()} base=\{base.length()}",
  )
  assert_true(
    better.length() > base.length(),
    msg="better=\{better.length()} base=\{base.length()}",
  )
}

///|
/// `§429`: when regions overlap the FIRST entry wins (upstream iterates the
/// list in reverse), so a losing later region must not change one byte.
test "h264 enc roi: overlap keeps the first region" {
  let pos = h264roi_full(10)
  let neg = h264roi_full(-10)
  let overlap_pos_first : Array[@libavcodec.H264Roi] = [pos[0], neg[0]]
  let overlap_neg_first : Array[@libavcodec.H264Roi] = [neg[0], pos[0]]
  let across = h264roi_intra(true, overlap_pos_first)
  let only_pos = h264roi_intra(true, pos)
  assert_true(h264roi_same(across, only_pos), msg="first (+) region lost")
  let across_neg = h264roi_intra(true, overlap_neg_first)
  let only_neg = h264roi_intra(true, neg)
  assert_true(h264roi_same(across_neg, only_neg), msg="first (-) region lost")
}

///|
/// `§429`: with AQ off upstream warns once and silently skips the ROI
/// without validating it — `qoffset_den == 0` must be accepted and the
/// stream byte-identical to the no-ROI baseline.
test "h264 enc roi: AQ off skips the map without validating" {
  let base = h264roi_intra(false, [])
  let with_roi = h264roi_intra(false, h264roi_full(10))
  assert_true(h264roi_same(base, with_roi), msg="AQ-off stream changed")
  let bad : Array[@libavcodec.H264Roi] = [
    { top: 0, bottom: 48, left: 0, right: 64, qoffset_num: 1, qoffset_den: 0, },
  ]
  let skipped = h264roi_intra(false, bad)
  assert_true(h264roi_same(base, skipped), msg="AQ-off den=0 was not skipped")
}

///|
/// `§429`: `qoffset.den == 0` is rejected at the safe boundary with the exact
/// reason (the `§424c` binding's `BadSideData` analogue), on the intra entry
/// and on the streaming push.
test "h264 enc roi: zero denominator is rejected" {
  let frames = h264roi_fixture(1)
  let (y, u, v) = frames[0]
  let bad : Array[@libavcodec.H264Roi] = [
    { top: 0, bottom: 48, left: 0, right: 64, qoffset_num: 1, qoffset_den: 0, },
  ]
  let want = "h264 enc: roi qoffset.den must not be zero"
  match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=48,
      qp=26,
      aq=true,
      roi=bad,
    ) {
    Ok(_) => fail("zero denominator accepted by the intra entry")
    Err(e) => assert_eq(e, want)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=48,
      qp=26,
      aq=true,
      aq_strength=0,
      b_slices=false,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  match enc.push_frame(y, u, v, roi=bad) {
    Ok(_) => fail("zero denominator accepted by push_frame")
    Err(e) => assert_eq(e, want)
  }
}

///|
/// `§429`: the batch P pictures carry the map (luma ROI offsets ride
/// `mb_qp_delta` like AQ; `aq_strength=0` keeps AQ neutral).
test "h264 enc roi: batch P pictures obey the ordering" {
  let frames = h264roi_fixture(4)
  fn enc(
    frames : Array[(Bytes, Bytes, Bytes)],
    roi : Array[@libavcodec.H264Roi],
  ) -> Bytes raise {
    match
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        aq=true,
        aq_strength=0,
        b_slices=false,
        roi~,
      ) {
      Ok(s) => s
      Err(e) => fail(e)
    }
  }

  let base = enc(frames, [])
  let worse = enc(frames, h264roi_full(10))
  let better = enc(frames, h264roi_full(-10))
  assert_true(
    worse.length() < base.length(),
    msg="worse=\{worse.length()} base=\{base.length()}",
  )
  assert_true(
    better.length() > base.length(),
    msg="better=\{better.length()} base=\{base.length()}",
  )
}

///|
/// `§429`: the streaming push carries a per-picture map — a P-only stream
/// equals the batch entry with the same map, and a B-scheduled push stashes
/// the map until the pending picture is actually coded.
test "h264 enc roi: streaming carries the per-picture map" {
  let frames = h264roi_fixture(3)
  let roi = h264roi_full(-10)
  // P-only: stream == batch with the same map.
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=48,
      qp=26,
      aq=true,
      aq_strength=0,
      b_slices=false,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let parts : Array[Bytes] = []
  for i = 0; i < frames.length(); i = i + 1 {
    let (y, u, v) = frames[i]
    match enc.push_frame(y, u, v, roi~) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      parts.push(au)
    }
  }
  match enc.finish() {
    Ok(t) =>
      for au in t {
        parts.push(au)
      }
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      joined.push(part[i])
    }
  }
  let stream = Bytes::from_array(joined[:])
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      aq=true,
      aq_strength=0,
      b_slices=false,
      roi~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_true(h264roi_same(stream, batch), msg="stream != batch with ROI")
  // B schedule: the odd push's map is stashed and applied when the pair is
  // coded; dropping it from that push changes the stream.
  fn stream_with(mid_roi : Array[@libavcodec.H264Roi]) -> Bytes raise {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=64,
        height=48,
        qp=26,
        aq=true,
        aq_strength=0,
        b_slices=true,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let out : Array[Byte] = []
    for i = 0; i < frames.length(); i = i + 1 {
      let (y, u, v) = frames[i]
      let r : Array[@libavcodec.H264Roi] = if i == 1 { mid_roi } else { [] }
      match enc.push_frame(y, u, v, roi=r) {
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

  let with_mid = stream_with(roi)
  let without_mid = stream_with([])
  assert_true(
    !h264roi_same(with_mid, without_mid),
    msg="pending B picture lost its ROI map",
  )
}
