///|
fn hevc_enc_main10_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_main10_frames() -> Array[
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
      y0[hevc_enc_main10_clamp(j + dy, h) * w + hevc_enc_main10_clamp(i + dx, w)]
    })
    let uk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_main10_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_main10_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_main10_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_main10_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
fn hevc_enc_main10_assert_recon(seq : HevcEncodedSequence) -> Unit raise {
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("Main10 decode: \{e}")
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
      fail("no decoded Main10 frame with poc \{enc.poc}")
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
test "hevc enc main10: VPS/SPS profile and bit depth round-trip" {
  let vps = hevc_enc_nal(hevc_enc_vps(bit_depth=10), 32)
  let sps = hevc_enc_nal(hevc_enc_sps(64, 64, 0, 0, true, bit_depth=10), 33)
  let pps = hevc_enc_nal(hevc_enc_pps(26, true), 34)
  let ps = new_hevc_param_sets()
  match ff_hevc_decode_extradata(hevc_enc_concat([vps, sps, pps]), ps, true) {
    Ok(_) => ()
    Err(e) => fail("Main10 parameter sets: \{e}")
  }
  let parsed = ps.sps_list[0].unwrap()
  assert_eq(parsed.bit_depth, 10)
  assert_eq(parsed.bit_depth_chroma, 10)
  assert_eq(parsed.ptl.general_ptl.profile_idc, 2)
  assert_eq(parsed.ptl.general_ptl.profile_compatibility_flag[1], 1)
  assert_eq(parsed.ptl.general_ptl.profile_compatibility_flag[2], 1)
  // The optional argument is byte-for-byte compatible with the Main defaults.
  assert_eq(hevc_enc_vps(), hevc_enc_vps(bit_depth=8))
  assert_eq(
    hevc_enc_sps(64, 64, 0, 0, true),
    hevc_enc_sps(64, 64, 0, 0, true, bit_depth=8),
  )
}

///|
test "hevc enc main10: intra QP sweep preserves reconstruction" {
  let frames = [hevc_enc_main10_frames()[0]]
  for qp in [12, 26, 40] {
    let seq = match
      hevc_encode_sequence(
        frames,
        width=64,
        height=64,
        qp~,
        inter=false,
        bit_depth=10,
      ) {
      Ok(s) => s
      Err(e) => fail("Main10 qp=\{qp}: \{e}")
    }
    hevc_enc_main10_assert_recon(seq)
  }
}

///|
test "hevc enc main10: I/P/B and fractional MC round-trip" {
  let seq = match
    hevc_encode_sequence(
      hevc_enc_main10_frames(),
      width=64,
      height=64,
      qp=26,
      b_slices=true,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail("Main10 I/P/B: \{e}")
  }
  assert_true(seq.frames.any(f => f.slice_type == hevc_slice_b))
  assert_true(seq.frames[0].recon_y.any(sample => sample > 255))
  hevc_enc_main10_assert_recon(seq)
}

///|
test "hevc enc main10: unsupported bit depth is rejected" {
  let result = hevc_encode_sequence(
    [hevc_enc_main10_frames()[0]],
    width=64,
    height=64,
    bit_depth=9,
  )
  match result {
    Err(e) => assert_eq(e, "hevc enc: bit_depth must be 8, 10 or 12")
    Ok(_) => fail("expected bit_depth=9 to fail")
  }
}
