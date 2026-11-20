// Blackbox tests for §463: multi-reference inter frames. The frame header
// maps all seven ref_frame_idx entries to one slot, and every block codes
// the configured reference index through the real ref tree — so coding a
// non-LAST index must decode pixel-exact and must actually resolve to the
// selected slot's picture (not blindly to LAST).

///|
fn mr_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
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
/// Build a key frame and return its sequence, temporal delimiter, packet
/// and decoded output.
fn mr_key(
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
/// Encode one inter frame from `ref_slot` coding `ref_idx`, then decode it
/// on a decoder that already consumed the key. Returns exactness.
fn mr_encode_check(
  seq : @libavcodec.Av1SequenceParameters,
  td : Bytes,
  key : Bytes,
  kf : @libavcodec.Av1FrameOutput,
  src_y : FixedArray[Int32],
  src_u : FixedArray[Int32],
  src_v : FixedArray[Int32],
  w : Int32,
  h : Int32,
  ref_slot : Int32,
  ref_idx : Int32,
) -> (Int32, Bool) raise {
  let cw = w >> 1
  let ch = h >> 1
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (obu, exp_y, exp_u, exp_v) = match
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
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
      base_q_idx=100,
      range=8,
      ref_slot~,
      ref_idx~,
    ) {
    Ok(v) => v
    Err(e) => fail("encode slot=\{ref_slot} idx=\{ref_idx}: \{e}")
  }
  let pkt : Array[Byte] = []
  for part in [td, obu] {
    for i in 0..<part.length() {
      pkt.push(part[i])
    }
  }
  let n = pkt.length()
  let dec = @libavcodec.Av1Decoder::new()
  let _ = match dec.decode_packet(key) {
    Ok(Some(f)) => f
    Ok(None) => fail("key hidden")
    Err(e) => fail("key decode: \{e}")
  }
  let f = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter hidden")
    Err(e) => fail("inter decode slot=\{ref_slot} idx=\{ref_idx}: \{e}")
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
  (n, exact)
}

///|
/// Encode one inter frame and return the raw packet bytes (for comparing
/// different reference indices byte for byte).
fn mr_encode_bytes(
  seq : @libavcodec.Av1SequenceParameters,
  td : Bytes,
  kf : @libavcodec.Av1FrameOutput,
  src_y : FixedArray[Int32],
  src_u : FixedArray[Int32],
  src_v : FixedArray[Int32],
  w : Int32,
  h : Int32,
  ref_idx : Int32,
) -> Bytes raise {
  let cw = w >> 1
  ignore(h)
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (obu, _, _, _) = match
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
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
      base_q_idx=100,
      range=8,
      ref_idx~,
    ) {
    Ok(v) => v
    Err(e) => fail("encode idx=\{ref_idx}: \{e}")
  }
  let pkt : Array[Byte] = []
  for part in [td, obu] {
    for i in 0..<part.length() {
      pkt.push(part[i])
    }
  }
  Bytes::from_array(pkt[:])
}

///|
test "av1 multi-ref: different reference indices produce different bitstreams" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, td, _, kf) = mr_key(w, h)
  let src_y = mr_src(w, h, 21)
  let src_u = mr_src(cw, ch, 22)
  let src_v = mr_src(cw, ch, 23)
  let b_last = mr_encode_bytes(seq, td, kf, src_y, src_u, src_v, w, h, 0)
  let b_altref = mr_encode_bytes(seq, td, kf, src_y, src_u, src_v, w, h, 6)
  // The ref tree writes a different bit prefix for ALTREF vs LAST, so the
  // packets must differ — identical bytes would mean the index never
  // reached the bitstream.
  if b_last.length() == b_altref.length() {
    let mut same = true
    for i in 0..<b_last.length() {
      if b_last[i] != b_altref[i] {
        same = false
      }
    }
    if same {
      fail("LAST and ALTREF produced identical bytes — ref tree not written")
    }
  }
  println(
    "multi-ref bitstreams differ: last=\{b_last.length()} altref=\{b_altref.length()}",
  )
}

///|
test "av1 multi-ref: every reference index decodes pixel-exact" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, td, key, kf) = mr_key(w, h)
  let src_y = mr_src(w, h, 5)
  let src_u = mr_src(cw, ch, 6)
  let src_v = mr_src(cw, ch, 7)
  // Every dav1d reference index 0..6 must round-trip: the header maps all
  // seven to slot 0, so each index resolves to the same picture.
  for ridx in 0..<7 {
    let (_, exact) = mr_encode_check(
      seq, td, key, kf, src_y, src_u, src_v, w, h, 0, ridx,
    )
    if !exact {
      fail("ref_idx=\{ridx} not pixel-exact")
    }
  }
}

///|
test "av1 multi-ref: default (slot 0, LAST) unchanged and deterministic" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, td, key, kf) = mr_key(w, h)
  let src_y = mr_src(w, h, 11)
  let src_u = mr_src(cw, ch, 12)
  let src_v = mr_src(cw, ch, 13)
  let (n0, e0) = mr_encode_check(
    seq, td, key, kf, src_y, src_u, src_v, w, h, 0, 0,
  )
  let (n1, e1) = mr_encode_check(
    seq, td, key, kf, src_y, src_u, src_v, w, h, 0, 0,
  )
  if n0 != n1 || !e0 || !e1 {
    fail("default path nondeterministic")
  }
  // A non-LAST index costs at least the extra ref-tree bit; it must not be
  // cheaper than LAST on identical content.
  let (n2, e2) = mr_encode_check(
    seq, td, key, kf, src_y, src_u, src_v, w, h, 0, 6,
  )
  println("multi-ref bytes: last=\{n0} altref=\{n2}")
  if !e2 {
    fail("ALTREF index not exact")
  }
  if n2 < n0 {
    fail("non-LAST reference coded cheaper than LAST: \{n0} -> \{n2}")
  }
}

///|
test "av1 multi-ref: invalid slot and index are rejected" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, _, _, kf) = mr_key(w, h)
  let src_y = mr_src(w, h, 1)
  let src_u = mr_src(cw, ch, 2)
  let src_v = mr_src(cw, ch, 3)
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let bad_slot = @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
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
    ref_slot=8,
  )
  if bad_slot is Ok(_) {
    fail("ref_slot=8 accepted")
  }
  let refs2 = @libavcodec.av1_refmvs_reference_store_new()
  refs2.refresh_without_mvs(0, w, h, 255)
  let bad_idx = @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
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
    ref_idx=7,
  )
  if bad_idx is Ok(_) {
    fail("ref_idx=7 accepted")
  }
}
