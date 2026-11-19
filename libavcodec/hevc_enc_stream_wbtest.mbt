///|
/// HEVC streaming encoder (§459) white-box coverage: the byte-equality
/// contract with the batch entries across the quality × schedule × length
/// matrix, the per-push output cadence, odd-length B schedules (the §459
/// RPS fix), depth/chroma spot checks and the error paths.

///|
fn hevc_enc_stream_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
/// The 64x64 gradient + translation series; `n` frames.
fn hevc_enc_stream_frames(
  n : Int32,
  bit_depth : Int32,
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let w = 64
  let h = 64
  let mask = (1 << bit_depth) - 1
  let half = 1 << (bit_depth - 1)
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 13 + j * 9 + half) & mask })
  let u0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 17 + j * 11 + half / 3) & mask
  })
  let v0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 7 + j * 19 + 2 * half / 3) & mask
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<n {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_stream_clamp(j + dy, h) * w + hevc_enc_stream_clamp(i + dx, w)]
    })
    let uk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_stream_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_stream_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_stream_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_stream_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
/// Run the streaming encoder over `frames` and concatenate the drained
/// access units (draining after every push and again at finish, the way a
/// chunked consumer works).
fn hevc_enc_stream_run(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  width~ : Int32,
  height~ : Int32,
  qp~ : Int32 = 26,
  crf~ : Double = -1.0,
  inter~ : Bool = true,
  b_slices~ : Bool = false,
  bit_depth~ : Int32 = 8,
  chroma_format_idc~ : Int32 = 1,
) -> Result[Bytes, String] raise {
  let enc = match
    HevcStreamEncoder::open(
      width~,
      height~,
      qp~,
      crf~,
      inter~,
      b_slices~,
      bit_depth~,
      chroma_format_idc~,
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
  let out : Array[Byte] = []
  for p in parts {
    for b in p {
      out.push(b)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
test "hevc enc stream: byte equality with the batch entries across the matrix" {
  // Flat QP and CRF × B schedule on/off × lengths 1..=6 (odd lengths cover
  // the §459 anchor_gap_two fix; 2 exercises the n<3 identity schedule).
  for b in [false, true] {
    for use_crf in [false, true] {
      for n in [1, 2, 3, 4, 5, 6] {
        let frames = hevc_enc_stream_frames(n, 8)
        let batch = match
          hevc_encode_sequence(
            frames,
            width=64,
            height=64,
            qp=26,
            crf=if use_crf { 28.0 } else { -1.0 },
            b_slices=b,
          ) {
          Ok(s) => s.annexb
          Err(e) => fail("batch b=\{b} crf=\{use_crf} n=\{n}: \{e}")
        }
        let stream = match
          hevc_enc_stream_run(
            frames,
            width=64,
            height=64,
            qp=26,
            crf=if use_crf { 28.0 } else { -1.0 },
            b_slices=b,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        if batch != stream {
          fail(
            "stream != batch: b=\{b} crf=\{use_crf} n=\{n} (\{stream.length()} vs \{batch.length()} bytes)",
          )
        }
      }
    }
  }
}

///|
test "hevc enc stream: byte equality for all-intra, 10-bit and 422" {
  // The §448 all-IDR schedule (inter=false, the hevc_encode_frames entry).
  let frames8 = hevc_enc_stream_frames(3, 8)
  let batch = match hevc_encode_frames(frames8, width=64, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail("batch: \{e}")
  }
  let stream = match
    hevc_enc_stream_run(frames8, width=64, height=64, qp=24, inter=false) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(stream, batch)
  // 10-bit + B schedule.
  let frames10 = hevc_enc_stream_frames(5, 10)
  let batch10 = match
    hevc_encode_sequence(
      frames10,
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      bit_depth=10,
    ) {
    Ok(s) => s.annexb
    Err(e) => fail("batch10: \{e}")
  }
  let stream10 = match
    hevc_enc_stream_run(
      frames10,
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(stream10, batch10)
  // 4:2:2 + B schedule (chroma planes are (w/2) x h at 4:2:2).
  let frames422 : Array[
    (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
  ] = []
  let base = hevc_enc_stream_frames(4, 8)
  for f in base {
    // Up-convert the (w/2, h/2) chroma to (w/2, h) by row duplication.
    let uc : FixedArray[Int32] = FixedArray::make(32 * 64, 0)
    let vc : FixedArray[Int32] = FixedArray::make(32 * 64, 0)
    for row in 0..<32 {
      for x in 0..<32 {
        uc[row * 64 + x] = f.1[row * 32 + x]
        vc[row * 64 + x] = f.2[row * 32 + x]
      }
    }
    frames422.push((f.0, uc, vc))
  }
  let batch422 = match
    hevc_encode_sequence(
      frames422,
      width=64,
      height=64,
      qp=28,
      b_slices=true,
      chroma_format_idc=2,
    ) {
    Ok(s) => s.annexb
    Err(e) => fail("batch422: \{e}")
  }
  let stream422 = match
    hevc_enc_stream_run(
      frames422,
      width=64,
      height=64,
      qp=28,
      b_slices=true,
      chroma_format_idc=2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(stream422, batch422)
}

///|
test "hevc enc stream: per-push output cadence" {
  let frames = hevc_enc_stream_frames(5, 8)
  let enc = match HevcStreamEncoder::open(width=64, height=64, b_slices=true) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  // I0 on the first push; odd pushes buffer; even pushes yield the P-B pair.
  let mut cadence = ""
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => cadence = cadence + "\{enc.drain().length()}"
      Err(e) => fail("push: \{e}")
    }
  }
  match enc.finish() {
    Ok(tail) => cadence = cadence + "|\{tail.length()}"
    Err(e) => fail("finish: \{e}")
  }
  assert_eq(cadence, "10202|0")
  // An even-length schedule flushes its trailing parked B as a tail P; an
  // odd-length one ends on the B of the last pair and has nothing pending.
  let enc2 = match HevcStreamEncoder::open(width=64, height=64, b_slices=true) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  for f in hevc_enc_stream_frames(4, 8) {
    match enc2.push_frame(f.0, f.1, f.2) {
      Ok(_) => ignore(enc2.drain())
      Err(e) => fail("push: \{e}")
    }
  }
  match enc2.finish() {
    Ok(tail) => assert_eq(tail.length(), 1)
    Err(e) => fail("finish: \{e}")
  }
  let enc4 = match HevcStreamEncoder::open(width=64, height=64, b_slices=true) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  for f in hevc_enc_stream_frames(3, 8) {
    match enc4.push_frame(f.0, f.1, f.2) {
      Ok(_) => ignore(enc4.drain())
      Err(e) => fail("push: \{e}")
    }
  }
  match enc4.finish() {
    Ok(tail) => assert_eq(tail.length(), 0)
    Err(e) => fail("finish: \{e}")
  }
  // Without B slices every push yields exactly one access unit.
  let enc3 = match HevcStreamEncoder::open(width=64, height=64) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  let mut cadence3 = ""
  for f in hevc_enc_stream_frames(4, 8) {
    match enc3.push_frame(f.0, f.1, f.2) {
      Ok(_) => cadence3 = cadence3 + "\{enc3.drain().length()}"
      Err(e) => fail("push: \{e}")
    }
  }
  assert_eq(cadence3, "1111")
}

///|
test "hevc enc stream: odd-length B schedules decode cleanly" {
  // The §459 fix's observable: every POC 0..n-1 exactly once (the decode
  // order is the coding order I0, P2, B1, P4, B3, ...; n=3 and n=5 end on
  // an anchor whose L0 is two display steps back).
  for (n, want) in [(3, "0,2,1,"), (5, "0,2,1,4,3,")] {
    let frames = hevc_enc_stream_frames(n, 8)
    let stream = match
      hevc_enc_stream_run(frames, width=64, height=64, b_slices=true) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let decoded = match ff_hevc_decode_frames_ex(stream, false, 0, true) {
      Ok(d) => d
      Err(e) => fail("n=\{n} decode: \{e}")
    }
    assert_eq(decoded.length(), n, msg="n=\{n}")
    let mut pocs = ""
    for d in decoded {
      pocs = pocs + "\{d.poc()},"
    }
    assert_eq(pocs, want)
  }
}

///|
test "hevc enc stream: error paths" {
  // Open-time validation.
  for
    bad in [
      HevcStreamEncoder::open(width=63, height=64),
      HevcStreamEncoder::open(width=64, height=0),
      HevcStreamEncoder::open(width=64, height=64, bit_depth=9),
      HevcStreamEncoder::open(width=64, height=64, chroma_format_idc=4),
      HevcStreamEncoder::open(width=64, height=64, qp=52),
      HevcStreamEncoder::open(width=64, height=64, crf=51.5),
    ] {
    assert_true(bad is Err(_))
  }
  // finish without a push mirrors the batch empty-array error.
  let enc = match HevcStreamEncoder::open(width=64, height=64) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  match enc.finish() {
    Err(e) => assert_eq(e, "hevc enc: no frames")
    Ok(_) => fail("expected finish() on an empty stream to fail")
  }
  // A too-small plane is rejected and leaves the encoder usable.
  let enc2 = match HevcStreamEncoder::open(width=64, height=64) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  let tiny : FixedArray[Int32] = FixedArray::make(4, 0)
  match enc2.push_frame(tiny, tiny.copy(), tiny.copy()) {
    Err(e) => assert_eq(e, "hevc enc: plane too small")
    Ok(_) => fail("expected a tiny plane to fail")
  }
  let frames = hevc_enc_stream_frames(1, 8)
  match enc2.push_frame(frames[0].0, frames[0].1, frames[0].2) {
    Ok(_) => assert_eq(enc2.drain().length(), 1)
    Err(e) => fail("usable after rejection: \{e}")
  }
}
