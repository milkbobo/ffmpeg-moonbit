// §424c binding slice: libx264.c's ROI path (setup_roi). `roi` carries
// AVRegionOfInterest per-macroblock quantisation deltas; upstream requires
// AQ on (pinned aq-mode=1 + CRF in the tests), scales the normalised
// qoffset by the QP range, and lets the first region win overlaps. The
// behavioral proof is the stream-size ordering: a full-frame negative
// offset must spend more bits, a positive one fewer, against an identical
// no-ROI baseline - decoded warning-free through the repository's pure
// H.264 decoder.

///|
/// Encode the fixture with one per-picture ROI map (None = no ROI).
fn x264_roi_encode(
  frames : Array[(Int64, Bytes, Bytes, Bytes)],
  roi_of : (Int32) -> Array[X264Roi]?,
) -> Bytes raise {
  let enc = X264Encoder::open(width=64, height=32, global_header=false, options=[
    ("preset", "ultrafast"),
    ("crf", "23"),
    ("x264-params", "keyint=250:min-keyint=250:scenecut=0:bframes=0:aq-mode=1"),
  ])
  let packets : Array[X264Packet] = []
  fn pull() raise {
    for ;; {
      match enc.receive_packet() {
        Packet(p) => packets.push(p)
        Again | Eof => break
      }
    }
  }
  for i, (pts, y, u, v) in frames {
    let roi = match roi_of(i) {
      Some(r) => r
      None => []
    }
    while !enc.send_frame(pts~, y~, u~, v~, roi~) {
      pull()
    }
    pull()
  }
  for p in enc.flush() {
    packets.push(p)
  }
  enc.close()
  x264_concat(packets)
}

///|
test "x264 roi: full-frame delta QP moves the bitstream both ways" {
  let frames = ptf_fixture(6, 64, 32)
  // Full-frame offsets: +10 QP and -10 QP on the 8-bit qp_range of 51.
  let pos : Array[X264Roi] = [
    {
      top: 0,
      bottom: 32,
      left: 0,
      right: 64,
      qoffset_num: 10,
      qoffset_den: 51,
    },
  ]
  let neg : Array[X264Roi] = [
    {
      top: 0,
      bottom: 32,
      left: 0,
      right: 64,
      qoffset_num: -10,
      qoffset_den: 51,
    },
  ]
  let base = x264_roi_encode(frames, _ => None)
  let worse = x264_roi_encode(frames, _ => Some(pos))
  let better = x264_roi_encode(frames, _ => Some(neg))
  // All three decode warning-free through the pure decoder.
  for (name, stream) in [("base", base), ("worse", worse), ("better", better)] {
    let probe = match x264_probe_frames(stream) {
      Ok(p) => p
      Err(e) => fail(e)
    }
    assert_eq(probe.errors, 0, msg=name)
    assert_eq(probe.warnings, 0, msg=name)
    assert_eq(probe.n_frames, 6, msg=name)
  }
  // The ROI deltas moved the bits in the requested directions.
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
test "x264 roi: overlap keeps the first region and shapes follow the grid" {
  let frames = ptf_fixture(4, 64, 32)
  // First region covers the whole frame at +10 QP; a second, later region
  // covering everything at -10 QP must LOSE where they overlap (upstream
  // iterates the list in reverse, so the first entry is applied last).
  let overlap : Array[X264Roi] = [
    {
      top: 0,
      bottom: 32,
      left: 0,
      right: 64,
      qoffset_num: 10,
      qoffset_den: 51,
    },
    {
      top: 0,
      bottom: 32,
      left: 0,
      right: 64,
      qoffset_num: -10,
      qoffset_den: 51,
    },
  ]
  let only_first : Array[X264Roi] = [
    {
      top: 0,
      bottom: 32,
      left: 0,
      right: 64,
      qoffset_num: 10,
      qoffset_den: 51,
    },
  ]
  let with_overlap = x264_roi_encode(frames, _ => Some(overlap))
  let with_first_only = x264_roi_encode(frames, _ => Some(only_first))
  // The losing second region must not change the outcome: with only
  // identical per-MB grids the two streams are byte-identical.
  assert_eq(with_overlap.length(), with_first_only.length())
  let probe = match x264_probe_frames(with_overlap) {
    Ok(p) => p
    Err(e) => fail(e)
  }
  assert_eq(probe.errors, 0)
  assert_eq(probe.warnings, 0)
  assert_eq(probe.n_frames, 4)
}

///|
test "x264 roi: zero denominator is rejected at the safe boundary" {
  let enc = X264Encoder::open(width=64, height=32, global_header=false, options=[
    ("preset", "ultrafast"),
  ])
  let y = Bytes::makei(64 * 32, i => ((i * 7) & 0xFF).to_byte())
  let u = Bytes::makei(32 * 16, i => (96 + i % 64).to_byte())
  let v = Bytes::makei(32 * 16, i => (160 - i % 64).to_byte())
  let bad : Array[X264Roi] = [
    { top: 0, bottom: 32, left: 0, right: 64, qoffset_num: 1, qoffset_den: 0, },
  ]
  try enc.send_frame(pts=0L, y~, u~, v~, roi=bad) catch {
    BadSideData(_) => ()
    _ => fail("zero qoffset_den accepted")
  } noraise {
    _ => fail("zero qoffset_den accepted")
  }
  enc.close()
}
