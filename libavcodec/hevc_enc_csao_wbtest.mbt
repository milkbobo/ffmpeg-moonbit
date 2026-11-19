///|
/// HEVC encoder chroma SAO (§460) white-box coverage: the decision's
/// component coupling (Cr inherits Cb's type, both off when Cb is), full
/// encode/decode round-trips with the chroma offsets in the bitstream, the
/// off-by-default byte identity, and streaming equality under the flag.

///|
fn hevc_enc_csao_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
/// 64x64 frames with a chroma bias baked in: the reconstruction drifts from
/// the source in Cb/Cr, so the chroma band decision has a real error to
/// minimise. `bias` shifts the chroma planes of frame k by k * bias.
fn hevc_enc_csao_frames(
  n : Int32,
  bias : Int32,
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_make_plane(w, h, fn(i, j) { (i * 5 + j * 3 + 100) & 255 })
  let u0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 7 + j * 11 + 60) & 255
  })
  let v0 = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 3 + j * 13 + 200) & 255
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<n {
    let dx = k * 3
    let dy = k * 2
    let cb = k * bias
    let yk = hevc_enc_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_csao_clamp(j + dy, h) * w + hevc_enc_csao_clamp(i + dx, w)]
    })
    let uk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      (
        u0[hevc_enc_csao_clamp(j + dy, h >> 1) * (w >> 1) +
        hevc_enc_csao_clamp(i + dx, w >> 1)] +
        cb
      ) &
      255
    })
    let vk = hevc_enc_make_plane(w >> 1, h >> 1, fn(i, j) {
      (
        v0[hevc_enc_csao_clamp(j + dy, h >> 1) * (w >> 1) +
        hevc_enc_csao_clamp(i + dx, w >> 1)] -
        cb
      ) &
      255
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
test "hevc enc csao: decode round-trip with chroma SAO in the bitstream" {
  let frames = hevc_enc_csao_frames(3, 4)
  let seq = match
    hevc_encode_sequence(
      frames,
      width=64,
      height=64,
      qp=30,
      sao_chroma=true,
      inter=true,
    ) {
    Ok(s) => s
    Err(e) => fail("chroma SAO encode: \{e}")
  }
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("chroma SAO decode: \{e}")
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
test "hevc enc csao: Cr inherits Cb's type; off keeps every component at 0" {
  // Decode-side coupling, asserted on the decision output directly: build a
  // deblocked reconstruction with a Cb/Cr bias through one encode pass.
  let frames = hevc_enc_csao_frames(1, 0)
  let seq = match
    hevc_encode_sequence(
      [frames[0]],
      width=64,
      height=64,
      qp=26,
      sao_chroma=true,
    ) {
    Ok(s) => s
    Err(e) => fail("encode: \{e}")
  }
  ignore(seq)
  // The white-box decision: source vs a biased reconstruction.
  let sps = {
    let vps = hevc_enc_nal(hevc_enc_vps(), 32)
    let sps_nal = hevc_enc_nal(hevc_enc_sps(64, 64, 0, 0, true), 33)
    let pps = hevc_enc_nal(hevc_enc_pps(26, true), 34)
    let ps = new_hevc_param_sets()
    match
      ff_hevc_decode_extradata(hevc_enc_concat([vps, sps_nal, pps]), ps, true) {
      Ok(_) => ps.sps_list[0].unwrap()
      Err(e) => fail("parameter sets: \{e}")
    }
  }
  let src_u = frames[0].1
  let src_v = frames[0].2
  let pic = hevc_picture_new(64, 64, 32, 32)
  for i in 0..<(64 * 64) {
    pic.y[i] = frames[0].0[i]
  }
  for i in 0..<(32 * 32) {
    // A -3 bias in Cb and +2 in Cr: the band decision should fight both.
    pic.cb[i] = src_u[i] - 3
    pic.cr[i] = src_v[i] + 2
  }
  let sao = hevc_enc_sao_decide(
    sps,
    frames[0].0,
    src_u,
    src_v,
    pic,
    chroma=true,
  )
  let mut cb_active = 0
  for ctb in 0..<sps.ctb_size {
    let t_cb = sao.type_idx[ctb * 3 + 1]
    let t_cr = sao.type_idx[ctb * 3 + 2]
    // Cr's type is Cb's type, always — the syntax carries no Cr type bin.
    assert_eq(t_cr, t_cb)
    if t_cb != 0 {
      cb_active = cb_active + 1
      assert_eq(t_cb, hevc_sao_band)
      // The offsets fight the biases (Cb's bias is negative, Cr's positive).
      assert_true(sao.offset_val[ctb * 15 + 5 + 1] > 0)
      assert_true(sao.offset_val[ctb * 15 + 10 + 1] < 0)
    }
  }
  assert_true(cb_active > 0)
  // Chroma off: the decision leaves both chroma components untouched.
  let sao_off = hevc_enc_sao_decide(sps, frames[0].0, src_u, src_v, pic)
  for ctb in 0..<sps.ctb_size {
    assert_eq(sao_off.type_idx[ctb * 3 + 1], 0)
    assert_eq(sao_off.type_idx[ctb * 3 + 2], 0)
  }
}

///|
test "hevc enc csao: default off keeps the pinned bytes; flag grows the AUs" {
  let frames = hevc_enc_csao_frames(3, 4)
  let plain_result = hevc_encode_frames(frames, width=64, height=64, qp=30)
  let plain = match plain_result {
    Ok(s) => s
    Err(e) => fail("plain: \{e}")
  }
  let off_result = hevc_encode_frames(
    frames,
    width=64,
    height=64,
    qp=30,
    sao_chroma=false,
  )
  let off = match off_result {
    Ok(s) => s
    Err(e) => fail("off: \{e}")
  }
  assert_eq(off, plain)
  // The chroma flag adds per-CTB bins, so a stream with active chroma SAO
  // must differ (and typically grow) — the equality above would be vacuous
  // otherwise.
  let with_result = hevc_encode_frames(
    frames,
    width=64,
    height=64,
    qp=30,
    sao_chroma=true,
  )
  let flagged = match with_result {
    Ok(s) => s
    Err(e) => fail("flagged: \{e}")
  }
  assert_true(flagged != plain)
}

///|
test "hevc enc csao: 422 and 10-bit round-trips under the flag" {
  // 4:2:2 chroma is (w/2) x h; 4:4:4 w x h — the CTB chroma block geometry
  // both must clip correctly at picture edges.
  let base = hevc_enc_csao_frames(2, 5)
  let frames422 : Array[
    (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
  ] = []
  for f in base {
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
  let f422 = match
    hevc_encode_intra_frame(
      frames422[0].0,
      frames422[0].1,
      frames422[0].2,
      width=64,
      height=64,
      qp=28,
      chroma_format_idc=2,
      sao_chroma=true,
    ) {
    Ok(f) => f
    Err(e) => fail("422 chroma SAO: \{e}")
  }
  let p422 = match ff_hevc_decode_intra_frame(f422.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("422 decode: \{e}")
  }
  for i in 0..<(32 * 64) {
    if f422.recon_u[i] != p422.cb[i] {
      fail("422 u=\{i} enc=\{f422.recon_u[i]} dec=\{p422.cb[i]}")
    }
    if f422.recon_v[i] != p422.cr[i] {
      fail("422 v=\{i} enc=\{f422.recon_v[i]} dec=\{p422.cr[i]}")
    }
  }
  // 10-bit 4:2:0.
  let frames10 = hevc_enc_csao_frames(2, 6)
  let seq10 = match
    hevc_encode_sequence(
      frames10,
      width=64,
      height=64,
      qp=28,
      sao_chroma=true,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail("10-bit chroma SAO: \{e}")
  }
  let decoded10 = match ff_hevc_decode_frames_ex(seq10.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("10-bit decode: \{e}")
  }
  assert_eq(decoded10.length(), 2)
  let enc0 = seq10.frames[0]
  let pic0 = decoded10[0].pic
  for i in 0..<((enc0.width >> 1) * (enc0.height >> 1)) {
    if enc0.recon_u[i] != pic0.cb[i] {
      fail("10-bit u=\{i} enc=\{enc0.recon_u[i]} dec=\{pic0.cb[i]}")
    }
  }
}

///|
test "hevc enc csao: streaming equals the batch entry under the flag" {
  let frames = hevc_enc_csao_frames(4, 4)
  let batch = match
    hevc_encode_sequence(
      frames,
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      sao_chroma=true,
    ) {
    Ok(s) => s.annexb
    Err(e) => fail("batch: \{e}")
  }
  let enc = match
    HevcStreamEncoder::open(
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      sao_chroma=true,
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
  assert_eq(Bytes::from_array(total), batch)
}
