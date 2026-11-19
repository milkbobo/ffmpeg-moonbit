///|
/// HEVC encoder monochrome (§463) white-box coverage: the guard's empty
/// chroma planes, the Rext PTL's monochrome constraint, full I/P/B
/// round-trips with no chroma bins in the bitstream, and the option
/// interaction checks.

///|
fn hevc_enc_mono_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
/// Monochrome frames: luma gradient + translations; the chroma planes are
/// empty FixedArrays.
fn hevc_enc_mono_frames(
  n : Int32,
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let w = 64
  let h = 64
  let empty : FixedArray[Int32] = FixedArray::make(0, 0)
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 11 + j * 7 + 30) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, empty, empty.copy()),
  ]
  for k in 1..<n {
    let dx = k * 5
    let dy = k * 3
    let yk = hevc_enc_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_mono_clamp(j + dy, h) * w + hevc_enc_mono_clamp(i + dx, w)]
    })
    frames.push((yk, empty.copy(), empty.copy()))
  }
  frames
}

///|
test "hevc enc mono: SPS/PTL round-trip selects Rext monochrome" {
  let vps = hevc_enc_nal(hevc_enc_vps(chroma_format_idc=0), 32)
  let sps = hevc_enc_nal(
    hevc_enc_sps(64, 64, 0, 0, true, chroma_format_idc=0),
    33,
  )
  let pps = hevc_enc_nal(hevc_enc_pps(26, true), 34)
  let ps = new_hevc_param_sets()
  match ff_hevc_decode_extradata(hevc_enc_concat([vps, sps, pps]), ps, true) {
    Ok(_) => ()
    Err(e) => fail("mono parameter sets: \{e}")
  }
  let parsed = ps.sps_list[0].unwrap()
  assert_eq(parsed.chroma_format_idc, 0)
  assert_eq(parsed.pix_fmt, "gray")
  assert_eq(parsed.hshift[1], 0)
  assert_eq(parsed.vshift[1], 0)
  let ptl = parsed.ptl.general_ptl
  assert_eq(ptl.profile_idc, 4)
  assert_eq(ptl.profile_compatibility_flag[4], 1)
  assert_eq(ptl.max_monochrome_constraint_flag, 1)
  assert_eq(ptl.max_422chroma_constraint_flag, 1)
  assert_eq(ptl.max_420chroma_constraint_flag, 1)
}

///|
test "hevc enc mono: I/P/B round-trip with no chroma planes" {
  let frames = hevc_enc_mono_frames(5)
  let seq = match
    hevc_encode_sequence(
      frames,
      width=64,
      height=64,
      qp=26,
      b_slices=true,
      chroma_format_idc=0,
    ) {
    Ok(s) => s
    Err(e) => fail("mono I/P/B: \{e}")
  }
  assert_true(seq.frames.any(f => f.slice_type == hevc_slice_b))
  // The reconstruction carries no chroma samples.
  for f in seq.frames {
    assert_eq(f.recon_u.length(), 0)
    assert_eq(f.recon_v.length(), 0)
    assert_eq(f.cstride, 0)
  }
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("mono decode: \{e}")
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
      fail("no decoded frame with poc \{enc.poc}")
    }
    let pic = decoded[found].pic
    assert_eq(pic.cw, 0)
    assert_eq(pic.ch, 0)
    for i in 0..<(enc.width * enc.height) {
      if enc.recon_y[i] != pic.y[i] {
        fail("poc=\{enc.poc} y=\{i} enc=\{enc.recon_y[i]} dec=\{pic.y[i]}")
      }
    }
  }
}

///|
test "hevc enc mono: intra entry, 10-bit and streaming equality" {
  let frames = hevc_enc_mono_frames(2)
  // The single-frame intra entry.
  let f0 = match
    hevc_encode_intra_frame(
      frames[0].0,
      frames[0].1,
      frames[0].2,
      width=64,
      height=64,
      qp=24,
      chroma_format_idc=0,
    ) {
    Ok(f) => f
    Err(e) => fail("mono intra: \{e}")
  }
  let p0 = match ff_hevc_decode_intra_frame(f0.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("mono intra decode: \{e}")
  }
  assert_eq(p0.cw, 0)
  for i in 0..<(64 * 64) {
    if f0.recon_y[i] != p0.y[i] {
      fail("y=\{i} enc=\{f0.recon_y[i]} dec=\{p0.y[i]}")
    }
  }
  // 10-bit monochrome.
  let frames10 = hevc_enc_mono_frames(2)
  let seq10 = match
    hevc_encode_sequence(
      frames10,
      width=64,
      height=64,
      qp=26,
      bit_depth=10,
      chroma_format_idc=0,
    ) {
    Ok(s) => s
    Err(e) => fail("mono 10-bit: \{e}")
  }
  let decoded10 = match ff_hevc_decode_frames_ex(seq10.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("mono 10-bit decode: \{e}")
  }
  assert_eq(decoded10.length(), 2)
  // Streaming equals the batch entry.
  let batch = match
    hevc_encode_sequence(
      hevc_enc_mono_frames(4),
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      chroma_format_idc=0,
    ) {
    Ok(s) => s.annexb
    Err(e) => fail("mono batch: \{e}")
  }
  let enc = match
    HevcStreamEncoder::open(
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      chroma_format_idc=0,
    ) {
    Ok(e) => e
    Err(e) => fail("mono open: \{e}")
  }
  let parts : Array[Bytes] = []
  for f in hevc_enc_mono_frames(4) {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in enc.drain() {
          parts.push(au)
        }
      Err(e) => fail("mono push: \{e}")
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        parts.push(au)
      }
    Err(e) => fail("mono finish: \{e}")
  }
  let total : Array[Byte] = []
  for p in parts {
    for b in p {
      total.push(b)
    }
  }
  assert_eq(Bytes::from_array(total), batch)
}

///|
test "hevc enc mono: option interactions" {
  // sao_chroma on monochrome is rejected everywhere.
  let frames = hevc_enc_mono_frames(1)
  let bad = hevc_encode_sequence(
    frames,
    width=64,
    height=64,
    sao_chroma=true,
    chroma_format_idc=0,
  )
  match bad {
    Err(e) => assert_eq(e, "hevc enc: sao_chroma needs chroma_format_idc != 0")
    Ok(_) => fail("expected sao_chroma x mono to fail")
  }
  match
    HevcStreamEncoder::open(
      width=64,
      height=64,
      sao_chroma=true,
      chroma_format_idc=0,
    ) {
    Err(e) => assert_eq(e, "hevc enc: sao_chroma needs chroma_format_idc != 0")
    Ok(_) => fail("expected stream sao_chroma x mono to fail")
  }
  // sao_eo alone is fine on monochrome (luma EO).
  assert_true(
    hevc_encode_sequence(
      frames,
      width=64,
      height=64,
      sao_eo=true,
      chroma_format_idc=0,
    )
    is Ok(_),
  )
  // A negative chroma_format_idc is still rejected.
  match
    hevc_encode_sequence(frames, width=64, height=64, chroma_format_idc=-1) {
    Err(e) => assert_eq(e, "hevc enc: chroma_format_idc must be 0, 1, 2 or 3")
    Ok(_) => fail("expected chroma_format_idc=-1 to fail")
  }
  // The luma plane is still size-checked: a tiny luma is rejected even with
  // valid empty chroma planes.
  let tiny : FixedArray[Int32] = FixedArray::make(4, 0)
  match
    hevc_encode_sequence(
      [(tiny, tiny.copy(), tiny.copy())],
      width=64,
      height=64,
      chroma_format_idc=0,
    ) {
    Err(e) => assert_eq(e, "hevc enc: plane too small")
    Ok(_) => fail("expected tiny luma to fail")
  }
}
