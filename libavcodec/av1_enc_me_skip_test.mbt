// Blackbox tests for §458: per-SB skip/MV mode decision. Acceptance:
// the skip-mixed inter frame decodes pixel-for-pixel to the expected
// planes, static content costs fewer bytes than the §449b all-residual
// baseline, and the decision is deterministic.

///|
/// A deterministic, structured source plane.
fn me_skip_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = 96 + (y * 13 + x * 5 + salt * 29) % 64
      let ov = (x * 7 + y * 3 + salt * 11) % 20 - 10
      let v = base + ov
      p[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  p
}

///|
/// Build a shown key frame with one minimal tile per SB carrying a flat
/// reference. Returns the parsed seq, the temporal delimiter, and the
/// key packet; also returns a fresh decoder that has consumed the key.
fn me_skip_key(
  w : Int32,
  h : Int32,
) -> (
  @libavcodec.Av1SequenceParameters,
  Bytes,
  Bytes,
  @libavcodec.Av1FrameOutput,
) raise {
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let nb = w / 64 * (h / 64)
  let tiles : Array[Bytes] = []
  for _ in 0..<nb {
    let t = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
      Ok(b) => b
      Err(e) => fail(e)
    }
    tiles.push(t)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles,
      tile_cols: w / 64,
      tile_rows: h / 64,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i in 0..<part.length() {
      key.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  (seq, td, Bytes::from_array(key[:]), kf)
}

///|
/// A fresh decoder that has consumed the key packet (so its sequence
/// header and reference slot 0 are ready for one inter frame).
fn fresh_dec(
  key_pkt : Bytes,
) -> (@libavcodec.Av1Decoder, @libavcodec.Av1FrameOutput) raise {
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(key_pkt) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  (dec, kf)
}

///|
/// Encode one skip-mixed inter OBU, decode it, and return the packet length
/// plus the decode-vs-expected exactness verdict.
fn encode_and_check(
  seq : @libavcodec.Av1SequenceParameters,
  td : Bytes,
  dec : @libavcodec.Av1Decoder,
  kf : @libavcodec.Av1FrameOutput,
  src_y : FixedArray[Int32],
  src_u : FixedArray[Int32],
  src_v : FixedArray[Int32],
  w : Int32,
  h : Int32,
  skip_pct : Int32,
  qidx : Int32,
) -> (Int32, Bool) raise {
  let cw = w >> 1
  let ch = h >> 1
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (obu, exp_y, exp_u, exp_v) = match
    @libavcodec.av1_enc_write_me_skip420_inter_frame_obu(
      seq,
      refs,
      src_y,
      w,
      src_u,
      cw,
      src_v,
      kf.y,
      kf.y_stride,
      kf.u,
      kf.uv_stride,
      kf.v,
      base_q_idx=qidx,
      range=8,
      skip_sad_pct=skip_pct,
    ) {
    Ok(v) => v
    Err(e) => fail("encode skip pct \{skip_pct}: \{e}")
  }
  let pkt : Array[Byte] = []
  for part in [td, obu] {
    for i in 0..<part.length() {
      pkt.push(part[i])
    }
  }
  let bytes = pkt.length()
  let f = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  let mut exact = true
  for y in 0..<h {
    for x in 0..<w {
      if f.y[y * f.y_stride + x] != exp_y[y * w + x] {
        exact = false
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if f.u[y * f.uv_stride + x] != exp_u[y * cw + x] ||
        f.v[y * f.uv_stride + x] != exp_v[y * cw + x] {
        exact = false
      }
    }
  }
  (bytes, exact)
}

///|
test "av1 enc skip: skip=0 baseline decodes pixel-exact" {
  let w = 64
  let h = 128
  let cw = 32
  let ch = 64
  let (seq, td, key_pkt, _) = me_skip_key(w, h)
  let (dec, kf) = fresh_dec(key_pkt)
  let src_y = me_skip_src(w, h, 5)
  let src_u = me_skip_src(cw, ch, 6)
  let src_v = me_skip_src(cw, ch, 7)
  let (_, exact) = encode_and_check(
    seq, td, dec, kf, src_y, src_u, src_v, w, h, 0, 100,
  )
  if !exact {
    fail("skip=0 baseline not pixel-exact")
  }
}

///|
test "av1 enc skip: static content skips and shrinks the packet" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let (seq, td, key_pkt, base_kf) = me_skip_key(w, h)
  // Source = flat key + a small ±3 overlay. Every SB stays static
  // (zero MV) and its SAD is tiny relative to full range (skip triggers),
  // yet at fine q the residual quantizes to nonzero tokens, so the
  // all-residual baseline must actually spend bytes.
  let src_y = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let ov = (x * 7 + y * 3) % 7 - 3
      let v = base_kf.y[y * base_kf.y_stride + x] + ov
      src_y[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  let src_u = FixedArray::make(cw * ch, 0)
  let src_v = FixedArray::make(cw * ch, 0)
  for y in 0..<ch {
    for x in 0..<cw {
      let ovu = (x * 5 + y * 2) % 7 - 3
      let ovv = (x * 3 + y * 7) % 7 - 3
      let u = base_kf.u[y * base_kf.uv_stride + x] + ovu
      let v = base_kf.v[y * base_kf.uv_stride + x] + ovv
      src_u[y * cw + x] = if u < 0 { 0 } else if u > 255 { 255 } else { u }
      src_v[y * cw + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  for q in [40, 100, 180] {
    let (dec0, kf0) = fresh_dec(key_pkt)
    let (n_base, exact0) = encode_and_check(
      seq, td, dec0, kf0, src_y, src_u, src_v, w, h, 0, q,
    )
    let (dec1, kf1) = fresh_dec(key_pkt)
    let (n_skip, exact1) = encode_and_check(
      seq, td, dec1, kf1, src_y, src_u, src_v, w, h, 100, q,
    )
    println("skip packet q=\{q}: baseline=\{n_base} skip=\{n_skip}")
    if !exact0 || !exact1 {
      fail("static skip frame not pixel-exact")
    }
    // A static frame must take the GLOBALMV skip path, collapsing the
    // whole residual token chain to a handful of bytes.
    if n_skip * 2 >= n_base {
      fail(
        "skip did not shrink a static frame at q\{q}: \{n_base} -> \{n_skip}",
      )
    }
  }
}

///|
test "av1 enc skip: moving content with skip flag on stays exact" {
  let w = 64
  let h = 128
  let cw = 32
  let ch = 64
  let (seq, td, key_pkt, _) = me_skip_key(w, h)
  let src_y = me_skip_src(w, h, 21)
  let src_u = me_skip_src(cw, ch, 22)
  let src_v = me_skip_src(cw, ch, 23)
  let (dec, kf) = fresh_dec(key_pkt)
  let (_, exact) = encode_and_check(
    seq, td, dec, kf, src_y, src_u, src_v, w, h, 100, 100,
  )
  if !exact {
    fail("skip-on moving content not pixel-exact")
  }
}

///|
test "av1 enc skip: mixed static/moving SBs stay exact across bank edges" {
  // 128x128 = 2x2 SBs. SB (0,0) static with a tiny overlay (skips);
  // SB (1,0) shifted content (residual). This exercises the a-bank
  // transition at the 128px column boundary and the l-bank row reset.
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let (seq, td, key_pkt, base_kf) = me_skip_key(w, h)
  let src_y = FixedArray::make(w * h, 0)
  let src_u = FixedArray::make(cw * ch, 0)
  let src_v = FixedArray::make(cw * ch, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = base_kf.y[y * base_kf.y_stride + x]
      let v = if x < 64 {
        base + ((x * 7 + y * 3) % 7 - 3) // static SB, tiny overlay
      } else {
        base_kf.y[y * base_kf.y_stride + (x + 4) % w] // shifted by 4
      }
      src_y[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      src_u[y * cw + x] = base_kf.u[y * base_kf.uv_stride + x]
      src_v[y * cw + x] = base_kf.v[y * base_kf.uv_stride + x]
    }
  }
  let (dec, kf) = fresh_dec(key_pkt)
  let (_, exact) = encode_and_check(
    seq, td, dec, kf, src_y, src_u, src_v, w, h, 100, 40,
  )
  if !exact {
    fail("mixed skip/residual frame not pixel-exact across bank edges")
  }
}

///|
test "av1 enc skip: deterministic byte stream" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, td, key_pkt, _) = me_skip_key(w, h)
  let src_y = me_skip_src(w, h, 31)
  let src_u = me_skip_src(cw, ch, 32)
  let src_v = me_skip_src(cw, ch, 33)
  let (d0, kf0) = fresh_dec(key_pkt)
  let (d1, kf1) = fresh_dec(key_pkt)
  let (n0, e0) = encode_and_check(
    seq, td, d0, kf0, src_y, src_u, src_v, w, h, 50, 100,
  )
  let (n1, e1) = encode_and_check(
    seq, td, d1, kf1, src_y, src_u, src_v, w, h, 50, 100,
  )
  if n0 != n1 || !e0 || !e1 {
    fail("nondeterministic skip stream")
  }
}
