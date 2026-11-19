///|
/// HEVC encoder CRF (§458) white-box coverage: the causal recurrence's exact
/// QPs on hand-computable complexity sequences, saturation both ways, the
/// display-order stability under B-slice reordering, full encode/decode
/// round-trips under CRF, and the off-path byte identity with the flat QP.

///|
fn hevc_enc_crf_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
/// A 4x4 luma plane with `delta` added at the four even-row/even-column
/// positions the subsampled SAD looks at; chroma is flat (SAD is luma-only).
fn hevc_enc_crf_frames_sad(
  deltas : Array[Int32],
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let frames = []
  for d in deltas {
    let y : FixedArray[Int32] = FixedArray::make(16, 0)
    y[0] = d
    y[2] = d
    y[8] = d
    y[10] = d
    let c : FixedArray[Int32] = FixedArray::make(4, 128)
    frames.push((y, c.copy(), c.copy()))
  }
  frames
}

///|
/// 64x64 8-bit gradient + translation series (display order I0, B1, P2, P3
/// under `b_slices`), the classic vector for I/P/B round-trips. */
fn hevc_enc_crf_frames_ipb() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 13 + j * 9 + 512) & 1023 })
  let u0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 17 + j * 11 + 300) & 1023
  })
  let v0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 7 + j * 19 + 700) & 1023
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_crf_clamp(j + dy, h) * w + hevc_enc_crf_clamp(i + dx, w)]
    })
    let uk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_crf_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_crf_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_crf_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_crf_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
test "hevc enc crf: exact QPs on a hand-computed complexity sequence" {
  // Display position 0 has no predecessor: base = round(26) = 26.
  // Position 1: SAD 4000 joins the mean first, ratio 1 -> 26.
  // Position 2: static (SAD 0) against mean 2000 -> +6 saturation -> 32.
  let frames = hevc_enc_crf_frames_sad([0, 1000, 1000])
  let qps = hevc_enc_crf_qps(frames, 4, 4, 26.0)
  assert_eq(qps.length(), 3)
  assert_eq(qps[0], 26)
  assert_eq(qps[1], 26)
  assert_eq(qps[2], 32)
}

///|
test "hevc enc crf: harder than average refines, all-static stays at base" {
  // Growing complexity: each later sample is above the running mean, so the
  // QPs must not exceed base and at least one must refine below it.
  let frames = hevc_enc_crf_frames_sad([0, 100, 200, 400, 800])
  let qps = hevc_enc_crf_qps(frames, 4, 4, 30.0)
  assert_eq(qps[0], 30)
  assert_eq(qps[1], 30)
  for i in [2, 3, 4] {
    assert_true(qps[i] <= 30)
  }
  assert_true(qps.any(q => q < 30))
  // An all-static sequence has mean ~ 0: every picture codes at base.
  let still = hevc_enc_crf_frames_sad([7, 7, 7, 7])
  let qps2 = hevc_enc_crf_qps(still, 4, 4, 22.0)
  for q in qps2 {
    assert_eq(q, 22)
  }
}

///|
test "hevc enc crf: baseline follows round(crf) and saturates at 51" {
  let frames = hevc_enc_crf_frames_sad([5])
  assert_eq(hevc_enc_crf_qps(frames, 4, 4, 18.4)[0], 18)
  assert_eq(hevc_enc_crf_qps(frames, 4, 4, 18.5)[0], 19)
  // crf 51 + the +6 static saturation must still clamp into the format range.
  let st = hevc_enc_crf_frames_sad([9, 9])
  let qps = hevc_enc_crf_qps(st, 4, 4, 51.0)
  assert_eq(qps[0], 51)
  assert_eq(qps[1], 51)
}

///|
test "hevc enc crf: display-causal QPs are order-stable under B reordering" {
  // The qps driver runs in display order regardless of the coding order the
  // sequence entry picks; the B-slice path must therefore see the same
  // per-picture QPs as the all-P path for the same frames.
  let frames = hevc_enc_crf_frames_ipb()
  let a = hevc_enc_crf_qps(frames, 64, 64, 28.0)
  let b = hevc_enc_crf_qps(frames, 64, 64, 28.0)
  assert_eq(a, b)
  assert_eq(a[0], 28)
  assert_eq(a[1], 28)
}

///|
test "hevc enc crf: I/P/B stream under CRF round-trips through the decoder" {
  let seq = match
    hevc_encode_sequence(
      hevc_enc_crf_frames_ipb(),
      width=64,
      height=64,
      crf=28.0,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail("CRF I/P/B: \{e}")
  }
  assert_true(seq.frames.any(f => f.slice_type == hevc_slice_b))
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("CRF decode: \{e}")
  }
  assert_eq(decoded.length(), seq.frames.length())
  for enc in seq.frames {
    let mut found = -1
    for k in 0..<decoded.length() {
      if decoded[k].poc == enc.poc {
        found = k
      }
    }
    if found < 0 {
      fail("no decoded CRF frame with poc \{enc.poc}")
    }
    let pic = decoded[found].pic
    for i in 0..<(enc.width * enc.height) {
      if enc.recon_y[i] != pic.y[i] {
        fail("poc=\{enc.poc} y=\{i} enc=\{enc.recon_y[i]} dec=\{pic.y[i]}")
      }
    }
    for i in 0..<((enc.width >> 1) * (enc.height >> 1)) {
      if enc.recon_u[i] != pic.cb[i] {
        fail("poc=\{enc.poc} u=\{i} enc=\{enc.recon_u[i]} dec=\{pic.cb[i]}")
      }
      if enc.recon_v[i] != pic.cr[i] {
        fail("poc=\{enc.poc} v=\{i} enc=\{enc.recon_v[i]} dec=\{pic.cr[i]}")
      }
    }
  }
}

///|
test "hevc enc crf: crf=10 sequence round-trips at every bit depth" {
  for bd in [8, 10, 12] {
    let seq = match
      hevc_encode_sequence(
        hevc_enc_crf_frames_ipb(),
        width=64,
        height=64,
        crf=10.0,
        bit_depth=bd,
      ) {
      Ok(s) => s
      Err(e) => fail("CRF bd=\{bd}: \{e}")
    }
    let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
      Ok(d) => d
      Err(e) => fail("CRF bd=\{bd} decode: \{e}")
    }
    assert_eq(decoded.length(), seq.frames.length())
    for enc in seq.frames {
      let mut found = -1
      for k in 0..<decoded.length() {
        if decoded[k].poc == enc.poc {
          found = k
        }
      }
      if found < 0 {
        fail("bd=\{bd}: no decoded frame with poc \{enc.poc}")
      }
      let pic = decoded[found].pic
      for i in 0..<(enc.width * enc.height) {
        if enc.recon_y[i] != pic.y[i] {
          fail(
            "bd=\{bd} poc=\{enc.poc} y=\{i} enc=\{enc.recon_y[i]} dec=\{pic.y[i]}",
          )
        }
      }
    }
  }
}

///|
test "hevc enc crf: qp argument is ignored under crf, off is byte-identical" {
  let frames = hevc_enc_crf_frames_ipb()
  // CRF on: the flat qp must not change a byte.
  let a = hevc_encode_frames(frames, width=64, height=64, qp=20, crf=30.0)
  let b = hevc_encode_frames(frames, width=64, height=64, qp=44, crf=30.0)
  assert_eq(a.unwrap(), b.unwrap())
  // CRF off (-1.0, the default) is the flat-qp path, unchanged.
  let off = hevc_encode_frames(frames, width=64, height=64, qp=26, crf=-1.0)
  let plain = hevc_encode_frames(frames, width=64, height=64, qp=26)
  assert_eq(off.unwrap(), plain.unwrap())
  // Determinism: the same CRF run is byte-identical.
  let r1 = hevc_encode_frames(frames, width=64, height=64, crf=28.0)
  let r2 = hevc_encode_frames(frames, width=64, height=64, crf=28.0)
  assert_eq(r1.unwrap(), r2.unwrap())
}

///|
test "hevc enc crf: out-of-range crf is rejected" {
  let frames = hevc_enc_crf_frames_ipb()
  for bad in [51.5, 52.0, 100.0] {
    let result = hevc_encode_sequence(frames, width=64, height=64, crf=bad)
    match result {
      Err(e) => assert_eq(e, "hevc enc: crf must be in 0.0..=51.0")
      Ok(_) => fail("expected crf=\{bad} to fail")
    }
  }
  // The boundary value itself is legal.
  assert_true(
    hevc_encode_frames(frames, width=64, height=64, crf=51.0) is Ok(_),
  )
  assert_true(hevc_encode_frames(frames, width=64, height=64, crf=0.0) is Ok(_))
}
