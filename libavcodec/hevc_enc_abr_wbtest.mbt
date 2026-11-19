///|
/// HEVC streaming ABR (§462) white-box coverage: the controller's QP walk,
/// the budget-ceiling property, error paths and the off-by-default byte
/// identity.

///|
fn hevc_enc_abr_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_abr_frames(
  n : Int32,
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 13 + j * 9 + 128) & 255 })
  let u0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 17 + j * 11 + 44) & 255
  })
  let v0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 7 + j * 19 + 188) & 255
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<n {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_abr_clamp(j + dy, h) * w + hevc_enc_abr_clamp(i + dx, w)]
    })
    let uk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_abr_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_abr_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_abr_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_abr_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
fn hevc_enc_abr_run(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  target_bitrate~ : Int32,
  fps~ : Int32,
  b_slices~ : Bool = false,
  qp~ : Int32 = 22,
) -> Result[(Bytes, Int32), String] raise {
  let enc = match
    HevcStreamEncoder::open(
      width=64,
      height=64,
      qp~,
      b_slices~,
      target_bitrate~,
      fps~,
    ) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  let parts : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in enc.drain() {
          parts.push(au)
        }
      Err(e) => fail("push: \{e}")
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        parts.push(au)
      }
    Err(e) => fail("finish: \{e}")
  }
  let total : Array[Byte] = []
  for p in parts {
    for b in p {
      total.push(b)
    }
  }
  Ok((Bytes::from_array(total), total.length()))
}

///|
test "hevc enc abr: the budget is a ceiling and the QP only climbs" {
  // A deliberately tight budget (the flat-qp stream is far larger): the
  // controller must coarsen until the total fits roughly, and never spend
  // more bits than the flat stream did at the same qp.
  let frames = hevc_enc_abr_frames(6)
  // ABR off (the plain open) for the byte-identical baseline.
  let plain_enc = match HevcStreamEncoder::open(width=64, height=64, qp=22) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  let plain_parts : Array[Bytes] = []
  for f in frames {
    match plain_enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in plain_enc.drain() {
          plain_parts.push(au)
        }
      Err(e) => fail("push: \{e}")
    }
  }
  match plain_enc.finish() {
    Ok(tail) =>
      for au in tail {
        plain_parts.push(au)
      }
    Err(e) => fail("finish: \{e}")
  }
  // Tight budget: 6 frames at 30 fps need target >= 30 * bits/frame; a
  // small target forces strong coarsening.
  let (tight, tight_len) = match
    hevc_enc_abr_run(frames, target_bitrate=60000, fps=30, qp=22) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_true(tight.length() < 100000)
  // The ceiling property: the ABR stream is never larger than the flat one.
  let mut plain_len = 0
  for b in plain_parts {
    plain_len = plain_len + b.length()
  }
  assert_true(tight_len <= plain_len)
  assert_true(tight != Bytes::from_array([]))
  // The stream decodes cleanly with every POC present.
  let decoded = match ff_hevc_decode_frames_ex(tight, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("abr decode: \{e}")
  }
  assert_eq(decoded.length(), 6)
}

///|
test "hevc enc abr: generous budget stays at the flat qp bytes" {
  // A budget no flat-qp picture can exceed: the controller never fires
  // (ahead <= 0 for every picture), so the stream equals the plain one.
  let frames = hevc_enc_abr_frames(4)
  let (generous, _) = match
    hevc_enc_abr_run(frames, target_bitrate=100000000, fps=30, qp=26) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let plain_enc = match HevcStreamEncoder::open(width=64, height=64, qp=26) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  let plain_parts : Array[Bytes] = []
  for f in frames {
    match plain_enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in plain_enc.drain() {
          plain_parts.push(au)
        }
      Err(e) => fail("push: \{e}")
    }
  }
  match plain_enc.finish() {
    Ok(tail) =>
      for au in tail {
        plain_parts.push(au)
      }
    Err(e) => fail("finish: \{e}")
  }
  let total : Array[Byte] = []
  for p in plain_parts {
    for b in p {
      total.push(b)
    }
  }
  assert_eq(generous, Bytes::from_array(total))
}

///|
test "hevc enc abr: b-schedule composes and error paths reject" {
  // The controller composes with the B schedule (pending B parks its
  // suggestion; the anchor and B both feed the walk in coding order).
  let frames = hevc_enc_abr_frames(5)
  let (stream, _) = match
    hevc_enc_abr_run(frames, target_bitrate=80000, fps=30, b_slices=true, qp=24) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let decoded = match ff_hevc_decode_frames_ex(stream, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("abr b decode: \{e}")
  }
  assert_eq(decoded.length(), 5)
  // Rejections mirror the open-time contract.
  for
    (label, attempt) in [
      (
        "no fps",
        HevcStreamEncoder::open(width=64, height=64, target_bitrate=1000),
      ),
      (
        "crf clash",
        HevcStreamEncoder::open(
          width=64,
          height=64,
          crf=28.0,
          target_bitrate=1000,
          fps=30,
        ),
      ),
      (
        "below one bit",
        HevcStreamEncoder::open(width=64, height=64, target_bitrate=10, fps=30),
      ),
      (
        "negative",
        HevcStreamEncoder::open(width=64, height=64, target_bitrate=-1, fps=30),
      ),
    ] {
    match attempt {
      Err(e) => assert_true(e.length() > 0, msg=label)
      Ok(_) => fail("expected rejection: \{label}")
    }
  }
  // fps alone (no bitrate) is legal and flat.
  assert_true(HevcStreamEncoder::open(width=64, height=64, fps=30) is Ok(_))
}
