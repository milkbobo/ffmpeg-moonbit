// Blackbox tests for §462: joint (qindex, skip) rate–distortion choice.
// The selector trial-encodes both the residual and the skip-mixed shape
// for every candidate q, so it must (a) stay deterministic, (b) return a
// member of the candidate sets, (c) prefer the skip shape on static
// content, and (d) the chosen frame must decode pixel-exact.

///|
fn rds_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = 96 + (y * 13 + x * 5 + salt * 29) % 64
      p[y * w + x] = v
    }
  }
  p
}

///|
/// Build a key frame and return (seq, td, key packet, decoded key).
fn rds_key(
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
  let n = w / 64 * (h / 64)
  let tiles : Array[Bytes] = []
  for _ in 0..<n {
    let t = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
      Ok(b) => b
      Err(e) => fail(e)
    }
    tiles.push(t)
  }
  let kf = match
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
  for part in [td, seq_obu, kf] {
    for i in 0..<part.length() {
      key.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let out = match dec.decode_packet(Bytes::from_array(key[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key hidden")
    Err(e) => fail("key decode: \{e}")
  }
  (seq, td, Bytes::from_array(key[:]), out)
}

///|
fn rds_choice(
  seq : @libavcodec.Av1SequenceParameters,
  refs : @libavcodec.Av1RefmvsReferenceStore,
  src_y : FixedArray[Int32],
  src_u : FixedArray[Int32],
  src_v : FixedArray[Int32],
  kf : @libavcodec.Av1FrameOutput,
  w : Int32,
  h : Int32,
  lambda : Int32,
) -> @libavcodec.Av1EncRdSkipChoice raise {
  let cw = w >> 1
  ignore(h)
  match
    @libavcodec.av1_enc_rd_select_q_skip_inter(
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
      [40, 100, 160, 220],
      [50, 100],
      lambda~,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail("joint select: \{e}")
  }
}

///|
test "av1 rd+skip: static content prefers the skip shape" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let (seq, _, _, kf) = rds_key(w, h)
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  // Source = the key reconstruction plus a tiny overlay: static, so the
  // skip shape should win at a low lambda (bits dominate).
  let src_y = FixedArray::make(w * h, 0)
  let src_u = FixedArray::make(cw * ch, 0)
  let src_v = FixedArray::make(cw * ch, 0)
  for y in 0..<h {
    for x in 0..<w {
      let ov = (x * 7 + y * 3) % 7 - 3
      let v = kf.y[y * kf.y_stride + x] + ov
      src_y[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      src_u[y * cw + x] = kf.u[y * kf.uv_stride + x]
      src_v[y * cw + x] = kf.v[y * kf.uv_stride + x]
    }
  }
  let c0 = rds_choice(seq, refs, src_y, src_u, src_v, kf, w, h, 0)
  println("joint(static, lambda=0): q=\{c0.q} skip=\{c0.skip_pct}")
  if c0.skip_pct == 0 {
    fail("static content did not choose the skip shape")
  }
}

///|
test "av1 rd+skip: deterministic and inside the candidate sets" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, _, _, kf) = rds_key(w, h)
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let src_y = rds_src(w, h, 5)
  let src_u = rds_src(cw, ch, 6)
  let src_v = rds_src(cw, ch, 7)
  let c0 = rds_choice(seq, refs, src_y, src_u, src_v, kf, w, h, 1000)
  let c1 = rds_choice(seq, refs, src_y, src_u, src_v, kf, w, h, 1000)
  if c0.q != c1.q || c0.skip_pct != c1.skip_pct || c0.cost != c1.cost {
    fail("joint selection nondeterministic")
  }
  if ![40, 100, 160, 220].contains(c0.q) {
    fail("q \{c0.q} outside candidates")
  }
  if c0.skip_pct != 0 && ![50, 100].contains(c0.skip_pct) {
    fail("skip \{c0.skip_pct} outside candidates")
  }
}

///|
/// §462 session wiring: the joint selector reaches the facade through
/// `rd_skip_pcts~` and the resulting frame chain stays pixel-exact.
test "av1 rd+skip: session facade joint selection stays exact" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src = @libavcodec.Av1EncPlanes::{
    y: rds_src(w, h, 21),
    y_stride: w,
    u: rds_src(cw, ch, 22),
    uv_stride: cw,
    v: rds_src(cw, ch, 23),
  }
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let dec = @libavcodec.Av1Decoder::new()
  for idx in 0..<3 {
    let (pkt, exp) = match
      enc.encode_frame(src, rd_skip_pcts=[50, 100], skip_uniform=true) {
      Ok(v) => v
      Err(e) => fail("joint session f\{idx}: \{e}")
    }
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("joint session frame \{idx} hidden")
      Err(e) => fail("joint session decode f\{idx}: \{e}")
    }
    for y in 0..<h {
      for x in 0..<w {
        if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
          fail("joint session f\{idx} Y(\{y},\{x}) diverged")
        }
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
          d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
          fail("joint session f\{idx} UV diverged")
        }
      }
    }
  }
}

///|
test "av1 rd+skip: chosen combination decodes pixel-exact" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, td, key, kf) = rds_key(w, h)
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let src_y = rds_src(w, h, 9)
  let src_u = rds_src(cw, ch, 10)
  let src_v = rds_src(cw, ch, 11)
  let pick = rds_choice(seq, refs, src_y, src_u, src_v, kf, w, h, 1000)
  // Encode the chosen shape for real (fresh refs: the selector forked).
  let refs2 = @libavcodec.av1_refmvs_reference_store_new()
  refs2.refresh_without_mvs(0, w, h, 255)
  let trial = if pick.skip_pct > 0 {
    @libavcodec.av1_enc_write_me_skip420_inter_frame_obu(
      seq,
      refs2,
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
      base_q_idx=pick.q,
      range=8,
      skip_sad_pct=pick.skip_pct,
      skip_uniform=true,
    )
  } else {
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs2,
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
      base_q_idx=pick.q,
      range=8,
    )
  }
  let (obu, exp_y, exp_u, exp_v) = match trial {
    Ok(v) => v
    Err(e) => fail("encode chosen: \{e}")
  }
  let pkt : Array[Byte] = []
  for part in [td, obu] {
    for i in 0..<part.length() {
      pkt.push(part[i])
    }
  }
  // Fresh decoder replaying key then the inter frame.
  let dec = @libavcodec.Av1Decoder::new()
  let _ = match dec.decode_packet(key) {
    Ok(Some(f)) => f
    Ok(None) => fail("key hidden")
    Err(e) => fail("key decode: \{e}")
  }
  let f = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if f.y[y * f.y_stride + x] != exp_y[y * w + x] {
        fail("joint Y(\{y},\{x}) diverged")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if f.u[y * f.uv_stride + x] != exp_u[y * cw + x] ||
        f.v[y * f.uv_stride + x] != exp_v[y * cw + x] {
        fail("joint UV(\{y},\{x}) diverged")
      }
    }
  }
}
