// Blackbox tests for §457: per-frame qindex rate–distortion selection.
// The selector must be deterministic, monotone at the lambda extremes,
// confined to the candidate set, leak nothing into the reference store,
// and — above all — the winning frame must decode pixel-exact to the
// reconstruction the selector scored.

///|
/// Deterministic source planes with a richer overlay than the session
/// fixture, so the qindex ladder actually spans a bit/distortion range.
fn rd_src_plane(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
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
fn rd_stress_plane(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = 100 + (x * 3 + y * 2 + salt * 17) % 56
      let ov = (x * 5 + y * 9 + salt * 7) % 80 - 40
      let v = base + ov
      p[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  p
}

///|
/// A parsed sequence header and a key-refreshed reference store, built
/// black-box from the seq-header OBU (no private Av1Encoder fields).
fn rd_seq_refs(
  w : Int32,
  h : Int32,
) -> (
  @libavcodec.Av1SequenceParameters,
  @libavcodec.Av1RefmvsReferenceStore,
  @libavcodec.Av1EncPlanes,
) raise {
  let obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail("seq header: \{e}")
  }
  let seq = match @libavcodec.av1_parse_sequence_header(obu) {
    Ok(s) => s
    Err(e) => fail("seq parse: \{e}")
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let cw = w >> 1
  let ch = h >> 1
  let ref_p = @libavcodec.Av1EncPlanes::{
    y: rd_src_plane(w, h, 0),
    y_stride: w,
    u: rd_stress_plane(cw, ch, 1),
    uv_stride: cw,
    v: rd_stress_plane(cw, ch, 2),
  }
  (seq, refs, ref_p)
}

///|
/// A helper that sets up a key frame, hands back its expected planes as
/// the inter reference, and returns a fresh decoder positioned at frame 0.
fn rd_setup(
  w : Int32,
  h : Int32,
) -> (@libavcodec.Av1Encoder, @libavcodec.Av1Decoder, @libavcodec.Av1EncPlanes) raise {
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let cw = w >> 1
  let ch = h >> 1
  let src = @libavcodec.Av1EncPlanes::{
    y: rd_src_plane(w, h, 0),
    y_stride: w,
    u: rd_stress_plane(cw, ch, 1),
    uv_stride: cw,
    v: rd_stress_plane(cw, ch, 2),
  }
  let dec = @libavcodec.Av1Decoder::new()
  let (pkt, exp) = match enc.encode_frame(src) {
    Ok(v) => v
    Err(e) => fail("key encode: \{e}")
  }
  match dec.decode_packet(pkt) {
    Ok(Some(_)) => ()
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  (enc, dec, exp)
}

///|
test "av1 rd: selector is deterministic and confined to candidates" {
  let w = 64
  let h = 64
  let (seq, refs, ref_p) = rd_seq_refs(w, h)
  let cands = [40, 100, 160, 220]
  let src = @libavcodec.Av1EncPlanes::{
    y: rd_src_plane(w, h, 7),
    y_stride: w,
    u: rd_stress_plane(32, 32, 8),
    uv_stride: 32,
    v: rd_stress_plane(32, 32, 9),
  }
  let pick = fn() -> Int32 raise {
    match
      @libavcodec.av1_enc_rd_select_q_inter(
        seq,
        refs,
        src.y,
        src.y_stride,
        src.u,
        src.uv_stride,
        src.v,
        ref_p.y,
        ref_p.y_stride,
        ref_p.u,
        ref_p.uv_stride,
        ref_p.v,
        cands,
        lambda=1000,
      ) {
      Ok(v) => v
      Err(e) => fail("select: \{e}")
    }
  }
  let q1 = pick()
  let q2 = pick()
  if q1 != q2 {
    fail("nondeterministic q: \{q1} vs \{q2}")
  }
  if !cands.contains(q1) {
    fail("q \{q1} outside candidates")
  }
}

///|
test "av1 rd: lambda=0 picks coarsest, huge lambda picks finest" {
  let w = 64
  let h = 64
  let (seq, refs, ref_p) = rd_seq_refs(w, h)
  let cands = [40, 100, 160, 220]
  let src = @libavcodec.Av1EncPlanes::{
    y: rd_src_plane(w, h, 11),
    y_stride: w,
    u: rd_stress_plane(32, 32, 12),
    uv_stride: 32,
    v: rd_stress_plane(32, 32, 13),
  }
  let select = fn(lambda : Int32) -> Int32 raise {
    match
      @libavcodec.av1_enc_rd_select_q_inter(
        seq,
        refs,
        src.y,
        src.y_stride,
        src.u,
        src.uv_stride,
        src.v,
        ref_p.y,
        ref_p.y_stride,
        ref_p.u,
        ref_p.uv_stride,
        ref_p.v,
        cands,
        lambda~,
      ) {
      Ok(v) => v
      Err(e) => fail("select lambda \{lambda}: \{e}")
    }
  }
  let qbits = select(0)
  let qdist = select(1000000)
  println("rd extremes: lambda=0 -> q\{qbits}, lambda=1e6 -> q\{qdist}")
  // lambda=0: bits only — q220 produces the smallest packet. The finer
  // candidates can occasionally pack equally well; ties go to the smaller
  // q, so assert the coarse half rather than pinning one value.
  if qbits < 160 {
    fail("lambda=0 did not favor a coarse q: \{qbits}")
  }
  // Huge lambda: distortion only — q40 reconstructs closest.
  if qdist != 40 {
    fail("huge lambda did not pick finest q: \{qdist}")
  }
}

///|
test "av1 rd: selection leaves the reference store untouched" {
  let w = 64
  let h = 64
  let (seq, refs, ref_p) = rd_seq_refs(w, h)
  // Snapshot slot 0 before any trial encode. The trial writers call
  // `refs.refresh(prepared, 1)`, which would replace slot 0 if the fork
  // were not isolated.
  let slot0 = match refs.slots[0] {
    Some(v) => v
    None => fail("no slot 0 after key refresh")
  }
  let src = @libavcodec.Av1EncPlanes::{
    y: rd_src_plane(w, h, 31),
    y_stride: w,
    u: rd_stress_plane(32, 32, 32),
    uv_stride: 32,
    v: rd_stress_plane(32, 32, 33),
  }
  let q = match
    @libavcodec.av1_enc_rd_select_q_inter(
      seq,
      refs,
      src.y,
      src.y_stride,
      src.u,
      src.uv_stride,
      src.v,
      ref_p.y,
      ref_p.y_stride,
      ref_p.u,
      ref_p.uv_stride,
      ref_p.v,
      [40, 100, 160, 220],
      lambda=1000,
    ) {
    Ok(v) => v
    Err(e) => fail("select: \{e}")
  }
  ignore(q)
  let after = match refs.slots[0] {
    Some(v) => v
    None => fail("slot 0 vanished")
  }
  if after.poc != slot0.poc || after.coded_width != slot0.coded_width {
    fail("RD trial leaked into the reference store")
  }
  if (after.rp is Some(_)) != (slot0.rp is Some(_)) {
    fail("RD trial leaked an rp map into the reference store")
  }
}

///|
test "av1 rd: session-selected inter frame decodes pixel-exact" {
  let w = 64
  let h = 128
  let cw = 32
  let ch = 64
  let (enc, dec, _) = rd_setup(w, h)
  let src = @libavcodec.Av1EncPlanes::{
    y: rd_src_plane(w, h, 21),
    y_stride: w,
    u: rd_stress_plane(cw, ch, 22),
    uv_stride: cw,
    v: rd_stress_plane(cw, ch, 23),
  }
  let (pkt, exp) = match
    enc.encode_frame(src, rd_lambda=1000, rd_candidates=[40, 100, 160, 220]) {
    Ok(v) => v
    Err(e) => fail("rd encode: \{e}")
  }
  let d = match dec.decode_packet(pkt) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
        fail("rd Y(\{y},\{x}) diverged")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
        d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
        fail("rd UV(\{y},\{x}) diverged")
      }
    }
  }
}
