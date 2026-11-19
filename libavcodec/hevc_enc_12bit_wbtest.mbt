///|
/// HEVC encoder 12-bit (Range Extensions) white-box coverage: the PTL must
/// switch to profile_idc=4 with max_10bit_constraint_flag=0 even for 4:2:0,
/// `qp_bd_offset` becomes 24, and every reconstruction (I QP sweep, I/P/B with
/// translated references, 4:2:2/4:4:4 combos) must match the decoder.

///|
fn hevc_enc_12bit_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
/// 64x64 I/B/P translation series in 12-bit sample range, mirroring the
/// Main10 vector so fractional-pel motion is exercised. */
fn hevc_enc_12bit_frames() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) {
    (i * 51 + j * 37 + 2048) & 4095
  })
  let u0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 67 + j * 43 + 1200) & 4095
  })
  let v0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 29 + j * 73 + 2800) & 4095
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_12bit_clamp(j + dy, h) * w + hevc_enc_12bit_clamp(i + dx, w)]
    })
    let uk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_12bit_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_12bit_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_12bit_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_12bit_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
/// Encode/decode round-trip for 12-bit 4:2:0 with POC alignment between the
/// encoder's local reconstruction and the decoder's output. */
fn hevc_enc_12bit_assert_recon(seq : HevcEncodedSequence) -> Unit raise {
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("12-bit decode: \{e}")
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
      fail("no decoded 12-bit frame with poc \{enc.poc}")
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
test "hevc enc 12bit: SPS/PTL round-trip selects Rext with max_10bit=0" {
  let vps = hevc_enc_nal(hevc_enc_vps(bit_depth=12), 32)
  let sps = hevc_enc_nal(hevc_enc_sps(64, 64, 0, 0, true, bit_depth=12), 33)
  let pps = hevc_enc_nal(hevc_enc_pps(26, true), 34)
  let ps = new_hevc_param_sets()
  match ff_hevc_decode_extradata(hevc_enc_concat([vps, sps, pps]), ps, true) {
    Ok(_) => ()
    Err(e) => fail("12-bit parameter sets: \{e}")
  }
  let parsed = ps.sps_list[0].unwrap()
  assert_eq(parsed.bit_depth, 12)
  assert_eq(parsed.bit_depth_chroma, 12)
  assert_eq(parsed.qp_bd_offset, 24)
  assert_eq(parsed.pix_fmt, "yuv420p12le")
  assert_eq(parsed.chroma_format_idc, 1)
  // 12-bit has no Main/Main10 profile: even 4:2:0 must announce Rext.
  let ptl = parsed.ptl.general_ptl
  assert_eq(ptl.profile_idc, 4)
  assert_eq(ptl.profile_compatibility_flag[4], 1)
  assert_eq(ptl.profile_compatibility_flag[1], 0)
  assert_eq(ptl.profile_compatibility_flag[2], 0)
  assert_eq(ptl.max_12bit_constraint_flag, 1)
  assert_eq(ptl.max_10bit_constraint_flag, 0)
  assert_eq(ptl.max_8bit_constraint_flag, 0)
  assert_eq(ptl.max_422chroma_constraint_flag, 1)
  assert_eq(ptl.max_420chroma_constraint_flag, 1)
  assert_eq(ptl.max_monochrome_constraint_flag, 0)
  // The defaults stay byte-for-byte at the Main 8-bit layout.
  assert_eq(hevc_enc_vps(), hevc_enc_vps(bit_depth=8))
  assert_eq(
    hevc_enc_sps(64, 64, 0, 0, true),
    hevc_enc_sps(64, 64, 0, 0, true, bit_depth=8),
  )
  // A 12-bit Rext PTL must differ from the 10-bit 4:2:0 Main10 one.
  assert_true(hevc_enc_vps(bit_depth=12) != hevc_enc_vps(bit_depth=10))
}

///|
test "hevc enc 12bit: 422/444 combos keep their chroma constraint flags" {
  let mk = fn(cfidc : Int32) -> HevcSps raise {
    let vps = hevc_enc_nal(
      hevc_enc_vps(bit_depth=12, chroma_format_idc=cfidc),
      32,
    )
    let sps = hevc_enc_nal(
      hevc_enc_sps(64, 64, 0, 0, true, bit_depth=12, chroma_format_idc=cfidc),
      33,
    )
    let pps = hevc_enc_nal(hevc_enc_pps(26, true), 34)
    let ps = new_hevc_param_sets()
    match ff_hevc_decode_extradata(hevc_enc_concat([vps, sps, pps]), ps, true) {
      Ok(_) => ps.sps_list[0].unwrap()
      Err(e) => fail("12-bit cfidc=\{cfidc} parameter sets: \{e}")
    }
  }
  let s422 = mk(2)
  assert_eq(s422.pix_fmt, "yuv422p12le")
  assert_eq(s422.ptl.general_ptl.max_422chroma_constraint_flag, 1)
  assert_eq(s422.ptl.general_ptl.max_420chroma_constraint_flag, 0)
  let s444 = mk(3)
  assert_eq(s444.pix_fmt, "yuv444p12le")
  assert_eq(s444.ptl.general_ptl.max_422chroma_constraint_flag, 0)
  assert_eq(s444.ptl.general_ptl.max_420chroma_constraint_flag, 0)
}

///|
test "hevc enc 12bit: intra QP sweep preserves reconstruction" {
  let frames = [hevc_enc_12bit_frames()[0]]
  for qp in [12, 26, 40] {
    let seq = match
      hevc_encode_sequence(
        frames,
        width=64,
        height=64,
        qp~,
        inter=false,
        bit_depth=12,
      ) {
      Ok(s) => s
      Err(e) => fail("12-bit qp=\{qp}: \{e}")
    }
    assert_true(seq.frames[0].recon_y.any(sample => sample > 1023))
    hevc_enc_12bit_assert_recon(seq)
  }
}

///|
test "hevc enc 12bit: non-CTB-aligned 48x40 intra round-trip" {
  let y = hevc_enc_make_plane(48, 40, fn(i, j) {
    (i * 21 + j * 33 + 900) & 4095
  })
  let u = hevc_enc_make_plane(24, 20, fn(i, j) { (i * 9 + j * 5 + 600) & 4095 })
  let v = hevc_enc_make_plane(24, 20, fn(i, j) { (i * 3 + j * 7 + 3000) & 4095 })
  let seq = match
    hevc_encode_sequence([(y, u, v)], width=48, height=40, qp=30, bit_depth=12) {
    Ok(s) => s
    Err(e) => fail("12-bit 48x40: \{e}")
  }
  hevc_enc_12bit_assert_recon(seq)
}

///|
test "hevc enc 12bit: I/P/B with translated references" {
  let seq = match
    hevc_encode_sequence(
      hevc_enc_12bit_frames(),
      width=64,
      height=64,
      qp=26,
      b_slices=true,
      bit_depth=12,
    ) {
    Ok(s) => s
    Err(e) => fail("12-bit I/P/B: \{e}")
  }
  assert_true(seq.frames.any(f => f.slice_type == hevc_slice_b))
  assert_true(seq.frames[0].recon_y.any(sample => sample > 1023))
  hevc_enc_12bit_assert_recon(seq)
}

///|
test "hevc enc 12bit: 422 and 444 intra round-trips" {
  // 4:2:2 chroma is (w/2) x h; 4:4:4 chroma is w x h.
  let y = hevc_enc_make_plane(64, 64, fn(i, j) {
    (i * 17 + j * 13 + 1500) & 4095
  })
  let u422 = hevc_enc_make_plane(32, 64, fn(i, j) {
    (i * 11 + j * 23 + 500) & 4095
  })
  let v422 = hevc_enc_make_plane(32, 64, fn(_, j) { (2048 + j * 5) & 4095 })
  let f422 = match
    hevc_encode_intra_frame(
      y,
      u422,
      v422,
      width=64,
      height=64,
      qp=26,
      bit_depth=12,
      chroma_format_idc=2,
    ) {
    Ok(f) => f
    Err(e) => fail("12-bit 422: \{e}")
  }
  let p422 = match ff_hevc_decode_intra_frame(f422.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("12-bit 422 decode: \{e}")
  }
  for i in 0..<(64 * 64) {
    if p422.y[i] != f422.recon_y[i] {
      fail("422 y=\{i} dec=\{p422.y[i]} enc=\{f422.recon_y[i]}")
    }
  }
  for i in 0..<(32 * 64) {
    if p422.cb[i] != f422.recon_u[i] {
      fail("422 u=\{i} dec=\{p422.cb[i]} enc=\{f422.recon_u[i]}")
    }
    if p422.cr[i] != f422.recon_v[i] {
      fail("422 v=\{i} dec=\{p422.cr[i]} enc=\{f422.recon_v[i]}")
    }
  }
  let u444 = hevc_enc_make_plane(64, 64, fn(i, j) {
    (i * 7 + j * 19 + 2500) & 4095
  })
  let v444 = hevc_enc_make_plane(64, 64, fn(i, j) {
    (i * 5 + j * 3 + 800) & 4095
  })
  let f444 = match
    hevc_encode_intra_frame(
      y,
      u444,
      v444,
      width=64,
      height=64,
      qp=26,
      bit_depth=12,
      chroma_format_idc=3,
    ) {
    Ok(f) => f
    Err(e) => fail("12-bit 444: \{e}")
  }
  let p444 = match ff_hevc_decode_intra_frame(f444.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("12-bit 444 decode: \{e}")
  }
  for i in 0..<(64 * 64) {
    if p444.y[i] != f444.recon_y[i] {
      fail("444 y=\{i} dec=\{p444.y[i]} enc=\{f444.recon_y[i]}")
    }
    if p444.cb[i] != f444.recon_u[i] {
      fail("444 u=\{i} dec=\{p444.cb[i]} enc=\{f444.recon_u[i]}")
    }
    if p444.cr[i] != f444.recon_v[i] {
      fail("444 v=\{i} dec=\{p444.cr[i]} enc=\{f444.recon_v[i]}")
    }
  }
}

///|
test "hevc enc 12bit: unsupported bit depths are rejected" {
  for bad in [9, 11, 14] {
    let result = hevc_encode_sequence(
      [hevc_enc_12bit_frames()[0]],
      width=64,
      height=64,
      bit_depth=bad,
    )
    match result {
      Err(e) => assert_eq(e, "hevc enc: bit_depth must be 8, 10 or 12")
      Ok(_) => fail("expected bit_depth=\{bad} to fail")
    }
  }
}
