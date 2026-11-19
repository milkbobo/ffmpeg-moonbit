// 白盒：HEVC P 帧编码器（第二切片）全链路 round-trip。
// 判据与 I 帧切片相同：编码器局部重建必须与自家 HEVC 解码器的（无滤波）
// 输出逐字节一致。P 帧通过 skip/merge、AMVP+MVD 两条路径各自的语法写出。
// 注意：P 帧解码需要帧级 DPB（ff_hevc_decode_frames），单帧入口只解 I 帧。

///|
/// Encode a 2-frame sequence (I then P) and compare every reconstruction with
/// the frame-level decoder's output for the same stream.
fn hevc_enc_p_roundtrip(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  w : Int32,
  h : Int32,
  qp : Int32,
) -> Unit raise {
  let seq = match hevc_encode_sequence(frames, width=w, height=h, qp~) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  assert_true(seq.frames.length() == frames.length())
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  if decoded.length() != seq.frames.length() {
    fail("frame count \{decoded.length()} != \{seq.frames.length()}")
  }
  // Decode order equals coding order for this I/P-only stream.
  for k in 0..<seq.frames.length() {
    let enc = seq.frames[k]
    let dec = decoded[k].pic
    let pw = enc.width
    let ph = enc.height
    for i in 0..<(pw * ph) {
      if dec.y[i] != enc.recon_y[i] {
        fail(
          "frame \{k} y mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{dec.y[i]} enc=\{enc.recon_y[i]}",
        )
      }
    }
    let cw = pw >> 1
    let ch = ph >> 1
    for i in 0..<(cw * ch) {
      if dec.cb[i] != enc.recon_u[i] {
        fail(
          "frame \{k} u mismatch at \{i}: dec=\{dec.cb[i]} enc=\{enc.recon_u[i]}",
        )
      }
      if dec.cr[i] != enc.recon_v[i] {
        fail(
          "frame \{k} v mismatch at \{i}: dec=\{dec.cr[i]} enc=\{enc.recon_v[i]}",
        )
      }
    }
  }
}

///|
/// Two frames where the second is the first shifted by `(dx, dy)` samples
/// (edge-replicated), so the encoder's motion search finds a pure translation.
fn hevc_enc_shift_pair(
  w : Int32,
  h : Int32,
  dx : Int32,
  dy : Int32,
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 3 + j * 5 + 40) & 255 })
  let u0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 7 + j * 3) & 255
  })
  let v0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 5 + j * 11) & 255
  })
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  let y1 = hevc_enc_make_plane(w, h, fn(i, j) {
    y0[clamp(j + dy, h) * w + clamp(i + dx, w)]
  })
  let cw = w >> 1
  let ch = h >> 1
  let u1 = hevc_enc_make_plane(cw, ch, fn(i, j) {
    u0[clamp(j + dy, ch) * cw + clamp(i + dx, cw)]
  })
  let v1 = hevc_enc_make_plane(cw, ch, fn(i, j) {
    v0[clamp(j + dy, ch) * cw + clamp(i + dx, cw)]
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  frames.push((y0, u0, v0))
  frames.push((y1, u1, v1))
  frames
}

///|
test "hevc enc p: static picture (skip/merge path) round-trip" {
  let y = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + j * 5 + 40) & 255 })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 5 + j * 11) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  frames.push((y, u, v))
  frames.push((y.copy(), u.copy(), v.copy()))
  hevc_enc_p_roundtrip(frames, 64, 64, 26)
}

///|
test "hevc enc p: pure translation (AMVP + MVD path) round-trip" {
  for off in [(4, 0), (0, 4), (8, -4), (-12, 8)] {
    let (dx, dy) = off
    hevc_enc_p_roundtrip(hevc_enc_shift_pair(64, 64, dx, dy), 64, 64, 26)
  }
}

///|
test "hevc enc p: motion with residual (merged MV + rqt_root_cbf) round-trip" {
  // The second frame carries a static pattern plus a moving stripe, so most
  // CUs merge with the neighbour's MV and still code residual.
  let y0 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 2 + j * 3) & 255 })
  let y1 = hevc_enc_make_plane(64, 64, fn(i, j) {
    let base = (i * 2 + j * 3) & 255
    let moving = if j >= 32 && j < 48 { 24 } else { 0 }
    (base + moving) & 255
  })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 9 + j * 5) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, _) { (i * 13) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u, v),
    (y1, u.copy(), v.copy()),
  ]
  hevc_enc_p_roundtrip(frames, 64, 64, 26)
}

///|
test "hevc enc p: three-frame chain round-trip" {
  let y0 = hevc_enc_make_plane(96, 48, fn(i, j) { (i * 4 + j * 7) & 255 })
  let y1 = hevc_enc_make_plane(96, 48, fn(i, j) {
    y0[hevc_enc_clamp_i(j + 4, 48) * 96 + hevc_enc_clamp_i(i - 4, 96)]
  })
  let y2 = hevc_enc_make_plane(96, 48, fn(i, j) {
    y1[hevc_enc_clamp_i(j - 8, 48) * 96 + hevc_enc_clamp_i(i + 8, 96)]
  })
  let u = hevc_enc_make_plane(48, 24, fn(i, j) { (i * 3 + j * 6) & 255 })
  let v = hevc_enc_make_plane(48, 24, fn(_, j) { (j * 9) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u, v),
    (y1, u.copy(), v.copy()),
    (y2, u.copy(), v.copy()),
  ]
  hevc_enc_p_roundtrip(frames, 96, 48, 26)
}

///|
test "hevc enc p: qp ladder round-trip" {
  for qp in [12, 26, 40] {
    let frames = hevc_enc_shift_pair(64, 64, 4, 4)
    hevc_enc_p_roundtrip(frames, 64, 64, qp)
  }
}

///|
test "hevc enc p: deterministic double run" {
  let frames = hevc_enc_shift_pair(64, 64, -8, 4)
  let a = match hevc_encode_sequence(frames, width=64, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  let b = match hevc_encode_sequence(frames, width=64, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  assert_eq(a.annexb.length(), b.annexb.length())
  for i in 0..<a.annexb.length() {
    assert_eq(a.annexb[i], b.annexb[i])
  }
}

///|
test "hevc enc p: P pictures are much smaller than intra for static content" {
  // A static pair must code the P frame with (almost) no residual, so the
  // second NAL is far smaller than the first.
  let y = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 5 + j * 3) & 255 })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 2 + j * 7) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 11 + j) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
    (y.copy(), u.copy(), v.copy()),
  ]
  let seq = match hevc_encode_sequence(frames, width=64, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  let sizes : Array[Int32] = []
  for f in seq.frames {
    sizes.push(f.annexb.length())
  }
  // The P picture avoids the intra residual/prediction cost and stays well
  // below two thirds of the I frame (measured ~48% on this fixture).
  assert_true(sizes[1] * 3 < sizes[0] * 2)
}

///|
/// Build a sub-pel shifted frame with the decoder's own MC kernel, so the
/// source is exactly representable by a fractional MV and the encoder's
/// quarter-pel refinement should find it.
fn hevc_enc_qpel_shift_frame(
  src : FixedArray[Int32],
  w : Int32,
  h : Int32,
  mvx : Int32,
  mvy : Int32,
) -> FixedArray[Int32] {
  let dst : Array[Int32] = Array::make(w * h, 0)
  let ref_pic = hevc_picture_new(w, h, 0, 0)
  for i in 0..<(w * h) {
    ref_pic.y[i] = src[i]
  }
  hevc_luma_mc_uni(ref_pic.y, w, w, h, dst, w, 0, 0, mvx, mvy, w, h, 8)
  let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for i in 0..<(w * h) {
    out[i] = dst[i]
  }
  out
}

///|
test "hevc enc p: quarter-pel MV round-trip" {
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 5 + j * 3 + 40) & 255 })
  let u0 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j) & 255 })
  let v0 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 11 + j * 3) & 255 })
  // A true 1/4-pel displacement in both directions; chunk-level chroma planes
  // are kept identical, so the P CU's residual comes only from luma.
  for mv in [(1, 2), (3, -1), (-3, -3), (2, 0)] {
    let (mx, my) = mv
    let y1 = hevc_enc_qpel_shift_frame(y0, w, h, mx, my)
    let frames : Array[
      (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
    ] = [(y0, u0, v0), (y1, u0.copy(), v0.copy())]
    hevc_enc_p_roundtrip(frames, 64, 64, 26)
  }
}

///|
test "hevc enc p: half-pel MV round-trip at qp extremes" {
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 4 + j * 9) & 255 })
  let u0 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 3 + j * 5) & 255 })
  let v0 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 13 + j) & 255 })
  let y1 = hevc_enc_qpel_shift_frame(y0, w, h, 2, -2)
  for qp in [10, 42] {
    let frames : Array[
      (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
    ] = [(y0, u0, v0), (y1.copy(), u0.copy(), v0.copy())]
    hevc_enc_p_roundtrip(frames, 64, 64, qp)
  }
}

///|
test "hevc enc p: intra-favoured new content round-trip" {
  // The second frame is a completely different pattern: inter prediction
  // from frame 0 is useless, so the RD decision should pick intra CUs. This
  // exercises the P-slice intra CU path (skip_flag=0 + pred_mode_flag=1 +
  // the shared intra body) and its tab_mvf / tab_ipm bookkeeping.
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 3 + j * 2) & 255 })
  let y1 = hevc_enc_make_plane(w, h, fn(i, j) {
    (255 - i * 4 - j * 7 + (if (i / 8 + j / 8) % 2 == 0 { 40 } else { 0 })) &
    255
  })
  let u0 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v0 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 11 + j) & 255 })
  let u1 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 13 + j * 5) & 255 })
  let v1 = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 3 + j * 17) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
    (y1, u1, v1),
  ]
  hevc_enc_p_roundtrip(frames, 64, 64, 26)
}

///|
test "hevc enc p: alternating inter/intra across three frames" {
  // Frame 1 is a shifted copy of frame 0 (inter-favoured), frame 2 is new
  // content (intra-favoured). This checks that mode state and neighbour tables
  // do not leak between frames of different decisions.
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 5 + j * 3) & 255 })
  let y1 = hevc_enc_make_plane(w, h, fn(i, j) {
    y0[hevc_enc_clamp_i(j + 4, h) * w + hevc_enc_clamp_i(i - 4, w)]
  })
  let y2 = hevc_enc_make_plane(w, h, fn(i, j) {
    (i * 9 + j * 11 + (if j < 24 { 60 } else { 0 })) & 255
  })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 3 + j * 6) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(_, j) { (j * 9) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u, v),
    (y1, u.copy(), v.copy()),
    (y2, u.copy(), v.copy()),
  ]
  hevc_enc_p_roundtrip(frames, 64, 64, 26)
}

///|
/// Round-trip a sequence that uses B slices: the coding order differs from the
/// display order, so the decoded frames are matched by POC rather than by index.
fn hevc_enc_b_roundtrip(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  w : Int32,
  h : Int32,
  qp : Int32,
) -> Unit raise {
  let seq = match
    hevc_encode_sequence(frames, width=w, height=h, qp~, b_slices=true) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  assert_true(seq.frames.length() == frames.length())
  // The coder must actually have produced B slices.
  let mut n_b = 0
  for f in seq.frames {
    if f.slice_type == hevc_slice_b {
      n_b = n_b + 1
    }
  }
  assert_true(n_b > 0)
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  if decoded.length() != seq.frames.length() {
    fail("frame count \{decoded.length()} != \{seq.frames.length()}")
  }
  for k in 0..<seq.frames.length() {
    let enc = seq.frames[k]
    // Locate the decoded picture with the same POC as this coded picture.
    let mut found = -1
    for d in 0..<decoded.length() {
      if decoded[d].poc == enc.poc {
        found = d
      }
    }
    if found < 0 {
      fail("no decoded frame with poc \{enc.poc}")
    }
    let dec = decoded[found].pic
    let pw = enc.width
    let ph = enc.height
    let mut bad = 0
    let mut first = ""
    let mut edges = 0
    for i in 0..<(pw * ph) {
      if dec.y[i] != enc.recon_y[i] {
        if bad == 0 {
          first = "(\{i % pw},\{i / pw}) dec=\{dec.y[i]} enc=\{enc.recon_y[i]}"
        }
        bad = bad + 1
        let xx = i % pw
        let yy = i / pw
        if (xx & 7) == 0 || (yy & 7) == 0 {
          edges = edges + 1
        }
      }
    }
    if bad > 0 {
      fail(
        "poc \{enc.poc} y mismatches=\{bad}/\{pw * ph} edges=\{edges} first=\{first} qp=\{qp}",
      )
    }
    let cw = pw >> 1
    let ch = ph >> 1
    for i in 0..<(cw * ch) {
      if dec.cb[i] != enc.recon_u[i] {
        fail("poc \{enc.poc} u mismatch at \{i}")
      }
      if dec.cr[i] != enc.recon_v[i] {
        fail("poc \{enc.poc} v mismatch at \{i}")
      }
    }
  }
}

///|
test "hevc enc b: ipb round-trip matches the decoder" {
  // Display order 0,1,2,3; coding order 0,2,1,3.
  let y0 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + j * 5) & 255 })
  let y1 = hevc_enc_make_plane(64, 64, fn(i, j) {
    let a = (i * 3 + j * 5) & 255
    let b = (i * 3 + (j + 2) * 5) & 255
    (a + b) / 2
  })
  let y2 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + (j + 4) * 5) & 255 })
  let y3 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + (j + 6) * 5) & 255 })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, _) { (i * 11) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u, v),
    (y1, u.copy(), v.copy()),
    (y2, u.copy(), v.copy()),
    (y3, u.copy(), v.copy()),
  ]
  hevc_enc_b_roundtrip(frames, 64, 64, 26)
}

///|
test "hevc enc b: constant frames round-trip" {
  let y = hevc_enc_make_plane(64, 64, fn(_, _) { 128 })
  let u = hevc_enc_make_plane(32, 32, fn(_, _) { 128 })
  let v = hevc_enc_make_plane(32, 32, fn(_, _) { 128 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
    (y.copy(), u.copy(), v.copy()),
    (y.copy(), u.copy(), v.copy()),
    (y.copy(), u.copy(), v.copy()),
  ]
  hevc_enc_b_roundtrip(frames, 64, 64, 26)
}

///|
test "hevc enc b: inline rps parses to the intended reference deltas" {
  // A B slice writes an inline RPS with one negative (-1) and one positive
  // (+1) picture; the header must round-trip to exactly that.
  let y = hevc_enc_make_plane(32, 32, fn(i, j) { (i + j) & 255 })
  let u = hevc_enc_make_plane(16, 16, fn(i, j) { (i * 3 + j) & 255 })
  let v = hevc_enc_make_plane(16, 16, fn(i, _) { (i * 5) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
    (y.copy(), u.copy(), v.copy()),
    (y.copy(), u.copy(), v.copy()),
    (y.copy(), u.copy(), v.copy()),
  ]
  let seq = match
    hevc_encode_sequence(frames, width=32, height=32, qp=26, b_slices=true) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  assert_eq(decoded.length(), 4)
}

///|
test "hevc enc b: b frame equal to the future anchor" {
  // Display order 0,1,2,3; the B picture (poc 1) repeats poc 2 exactly, so L1
  // alone predicts it perfectly and the CU should take a skip/merge path.
  let y0 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + j * 5) & 255 })
  let y2 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + (j + 4) * 5) & 255 })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, _) { (i * 11) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u, v),
    (y2.copy(), u.copy(), v.copy()),
    (y2.copy(), u.copy(), v.copy()),
    (y2.copy(), u.copy(), v.copy()),
  ]
  hevc_enc_b_roundtrip(frames, 64, 64, 26)
}

///|
test "hevc enc b: b frame equal to the previous anchor" {
  // The B picture (poc 1) repeats poc 0 exactly, so L0 with MV 0 predicts it
  // perfectly and the inter path must reproduce it bit-exactly.
  let y0 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + j * 5) & 255 })
  let y2 = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 3 + (j + 4) * 5) & 255 })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, _) { (i * 11) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u, v),
    (y0.copy(), u.copy(), v.copy()),
    (y2.copy(), u.copy(), v.copy()),
    (y2.copy(), u.copy(), v.copy()),
  ]
  hevc_enc_b_roundtrip(frames, 64, 64, 26)
}
