// White-box tests for §466: ME reuse across the RD sweep.
//
// Motion estimation depends only on (src, ref) — not on the qindex or the
// skip threshold — so the three-way selector runs it once per reference
// and feeds the result into every (q, skip) trial. These tests pin the
// two properties that make the optimisation safe:
//   1. precomputed MVs produce byte-identical output to running ME inside
//      the encoder (the optimisation changes work, not bits);
//   2. the full-pel + sub-pel helper agrees with the encoder's own ME.

///|
fn mer_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = 80 + (y * 11 + x * 7 + salt * 31) % 96
      p[y * w + x] = v
    }
  }
  p
}

///|
/// Encode one inter frame twice — once letting the encoder run ME, once
/// with the MVs precomputed — and assert the packets are byte-identical.
fn mer_bytes_identical(q : Int32) -> Bool raise {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_y = mer_src(w, h, 3)
  let src_u = mer_src(cw, ch, 4)
  let src_v = mer_src(cw, ch, 5)
  let ref_y = mer_src(w, h, 9)
  let ref_u = mer_src(cw, ch, 10)
  let ref_v = mer_src(cw, ch, 11)
  let seq = match
    av1_parse_sequence_header(
      match
        av1_enc_write_sequence_header_obu(
          Av1SeqEncConfig::default(width=w, height=h),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let refs0 = av1_refmvs_reference_store_new()
  refs0.refresh_without_mvs(0, w, h, 255)
  let (auto, _, _, _) = match
    av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs0,
      src_y,
      w,
      src_u,
      cw,
      src_v,
      ref_y,
      w,
      ref_u,
      cw,
      ref_v,
      base_q_idx=q,
    ) {
    Ok(v) => v
    Err(e) => fail("auto ME: \{e}")
  }
  // The same ME, run through the shared helper.
  let (my, mx) = match av1_enc_me_for_ref(seq, src_y, w, ref_y, w, range=8) {
    Ok(v) => v
    Err(e) => fail("helper ME: \{e}")
  }
  let refs1 = av1_refmvs_reference_store_new()
  refs1.refresh_without_mvs(0, w, h, 255)
  let (pre, _, _, _) = match
    av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs1,
      src_y,
      w,
      src_u,
      cw,
      src_v,
      ref_y,
      w,
      ref_u,
      cw,
      ref_v,
      base_q_idx=q,
      precomputed_mvs_y8=my,
      precomputed_mvs_x8=mx,
    ) {
    Ok(v) => v
    Err(e) => fail("precomputed ME: \{e}")
  }
  if auto.length() != pre.length() {
    fail("q=\{q} length differs: auto=\{auto.length()} pre=\{pre.length()}")
  }
  for i in 0..<auto.length() {
    if auto[i] != pre[i] {
      fail("q=\{q} byte \{i} differs (auto=\{auto[i]} pre=\{pre[i]})")
    }
  }
  true
}

///|
test "av1 ME reuse: precomputed MVs give byte-identical frames" {
  for q in [40, 100, 160, 220] {
    if !mer_bytes_identical(q) {
      fail("q=\{q} not byte-identical")
    }
  }
}

///|
/// The skip writer must also be byte-identical with precomputed MVs.
fn mer_skip_identical(pct : Int32) -> Bool raise {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_y = mer_src(w, h, 13)
  let src_u = mer_src(cw, ch, 14)
  let src_v = mer_src(cw, ch, 15)
  let ref_y = mer_src(w, h, 16)
  let ref_u = mer_src(cw, ch, 17)
  let ref_v = mer_src(cw, ch, 18)
  let seq = match
    av1_parse_sequence_header(
      match
        av1_enc_write_sequence_header_obu(
          Av1SeqEncConfig::default(width=w, height=h),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let refs0 = av1_refmvs_reference_store_new()
  refs0.refresh_without_mvs(0, w, h, 255)
  let (auto, _, _, _) = match
    av1_enc_write_me_skip420_inter_frame_obu(
      seq,
      refs0,
      src_y,
      w,
      src_u,
      cw,
      src_v,
      ref_y,
      w,
      ref_u,
      cw,
      ref_v,
      base_q_idx=100,
      skip_sad_pct=pct,
      skip_uniform=true,
    ) {
    Ok(v) => v
    Err(e) => fail("auto skip ME: \{e}")
  }
  let (my, mx) = match av1_enc_me_for_ref(seq, src_y, w, ref_y, w, range=8) {
    Ok(v) => v
    Err(e) => fail("helper ME: \{e}")
  }
  let refs1 = av1_refmvs_reference_store_new()
  refs1.refresh_without_mvs(0, w, h, 255)
  let (pre, _, _, _) = match
    av1_enc_write_me_skip420_inter_frame_obu(
      seq,
      refs1,
      src_y,
      w,
      src_u,
      cw,
      src_v,
      ref_y,
      w,
      ref_u,
      cw,
      ref_v,
      base_q_idx=100,
      skip_sad_pct=pct,
      skip_uniform=true,
      precomputed_mvs_y8=my,
      precomputed_mvs_x8=mx,
    ) {
    Ok(v) => v
    Err(e) => fail("precomputed skip ME: \{e}")
  }
  if auto.length() != pre.length() {
    fail("skip pct=\{pct} length differs")
  }
  for i in 0..<auto.length() {
    if auto[i] != pre[i] {
      fail("skip pct=\{pct} byte \{i} differs")
    }
  }
  true
}

///|
test "av1 ME reuse: skip writer is byte-identical with precomputed MVs" {
  for pct in [50, 100] {
    if !mer_skip_identical(pct) {
      fail("skip pct=\{pct} not byte-identical")
    }
  }
}

///|
test "av1 ME reuse: precomputed MVs must match the SB count" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_y = mer_src(w, h, 1)
  let src_u = mer_src(cw, ch, 2)
  let src_v = mer_src(cw, ch, 3)
  let ref_y = mer_src(w, h, 4)
  let ref_u = mer_src(cw, ch, 5)
  let ref_v = mer_src(cw, ch, 6)
  let seq = match
    av1_parse_sequence_header(
      match
        av1_enc_write_sequence_header_obu(
          Av1SeqEncConfig::default(width=w, height=h),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let refs = av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  // A 64x64 frame has exactly one SB, so a two-entry array is rejected.
  let wrong : FixedArray[Int32] = [0, 0]
  let bad = av1_enc_write_me_res420_inter_frame_obu(
    seq,
    refs,
    src_y,
    w,
    src_u,
    cw,
    src_v,
    ref_y,
    w,
    ref_u,
    cw,
    ref_v,
    base_q_idx=100,
    precomputed_mvs_y8=wrong,
    precomputed_mvs_x8=wrong,
  )
  if bad is Ok(_) {
    fail("wrong-sized precomputed MV arrays accepted")
  }
}

///|
test "av1 ME reuse: the helper agrees with the encoder's own ME" {
  let w = 128
  let h = 128
  let src_y = mer_src(w, h, 7)
  // A horizontally shifted reference: ME should find a uniform non-zero dx.
  let ref_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      ref_y[y * w + x] = src_y[y * w + (x + 4) % w]
    }
  }
  let seq = match
    av1_parse_sequence_header(
      match
        av1_enc_write_sequence_header_obu(
          Av1SeqEncConfig::default(width=w, height=h),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let (my, mx) = match av1_enc_me_for_ref(seq, src_y, w, ref_y, w, range=8) {
    Ok(v) => v
    Err(e) => fail("helper: \{e}")
  }
  // The helper must reproduce the two-stage search exactly: full-pel then
  // sub-pel refinement around it.
  let (iy, ix) = match
    av1_enc_me_fullpel_sad(src_y, w, ref_y, w, w, h, range=8) {
    Ok(v) => v
    Err(e) => fail("fullpel: \{e}")
  }
  let (ry, rx) = match
    av1_enc_me_subpel_refine(src_y, w, ref_y, w, w, h, iy, ix) {
    Ok(v) => v
    Err(e) => fail("subpel: \{e}")
  }
  if my.length() != ry.length() || mx.length() != rx.length() {
    fail("helper MV array length mismatch")
  }
  for i in 0..<my.length() {
    if my[i] != ry[i] || mx[i] != rx[i] {
      fail(
        "helper MV \{i} differs: helper=(\{my[i]},\{mx[i]}) ref=(\{ry[i]},\{rx[i]})",
      )
    }
  }
}
