// Blackbox tests for §460: NEARMV skip — a skipped SB with a non-zero MV
// coded through the uniform (NEWMV/NEARESTMV) chain. The decoder must
// realize the same MV-driven MC prediction the encoder scored, pixel for
// pixel, and a translated static-content frame must cost far less than
// the full-residual baseline.

///|
fn nm_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
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
fn nm_key(
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
  // One AC token tile per 64x64 SB (structured so a pure translation is
  // distinguishable from flat); the tile grid follows the SB raster.
  let sy : FixedArray[Int32] = FixedArray::make(1024, 0)
  let ss : FixedArray[Int32] = FixedArray::make(1024, 0)
  for i in 0..<1024 {
    sy[i] = 1 + i % 3
  }
  let tiles : Array[Bytes] = []
  let n_tiles = w / 64 * (h / 64)
  for _ in 0..<n_tiles {
    let t = match
      @libavcodec.av1_enc_write_ac_token_tile(sy, ss, base_q_idx=200) {
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
    Ok(None) => fail("key hidden")
    Err(e) => fail("key decode: \{e}")
  }
  (seq, td, Bytes::from_array(key[:]), kf)
}

///|
fn nm_fresh(
  key : Bytes,
) -> (@libavcodec.Av1Decoder, @libavcodec.Av1FrameOutput) raise {
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(key) {
    Ok(Some(f)) => f
    Ok(None) => fail("key hidden")
    Err(e) => fail("key decode: \{e}")
  }
  (dec, kf)
}

///|
/// Encode one NEARMV-skip inter frame; return packet length and whether
/// the decode matched the expected planes exactly.
fn nm_encode(
  seq : @libavcodec.Av1SequenceParameters,
  td : Bytes,
  dec : @libavcodec.Av1Decoder,
  kf : @libavcodec.Av1FrameOutput,
  src_y : FixedArray[Int32],
  src_u : FixedArray[Int32],
  src_v : FixedArray[Int32],
  w : Int32,
  h : Int32,
  pct : Int32,
  uniform : Bool,
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
      base_q_idx=100,
      range=8,
      skip_sad_pct=pct,
      skip_uniform=uniform,
    ) {
    Ok(v) => v
    Err(e) => fail("encode pct=\{pct} uniform=\{uniform}: \{e}")
  }
  let pkt : Array[Byte] = []
  for part in [td, obu] {
    for i in 0..<part.length() {
      pkt.push(part[i])
    }
  }
  let n = pkt.length()
  let f = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter hidden")
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
  (n, exact)
}

///|
test "av1 enc NEARMV skip: translated frame stays pixel-exact" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, td, key, _) = nm_key(w, h)
  let src_y = nm_src(w, h, 3)
  let src_u = nm_src(cw, ch, 4)
  let src_v = nm_src(cw, ch, 5)
  for y in 0..<ch {
    for x in 0..<cw {
      src_u[y * cw + x] = nm_src(cw, ch, 4)[y * cw + x]
      src_v[y * cw + x] = nm_src(cw, ch, 5)[y * cw + x]
    }
  }
  let (dec, kf) = nm_fresh(key)
  let (_, exact) = nm_encode(
    seq, td, dec, kf, src_y, src_u, src_v, w, h, 100, true,
  )
  if !exact {
    fail("NEARMV skip frame not pixel-exact")
  }
}

///|
test "av1 enc NEARMV skip: deterministic and byte-shrinking on translated content" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let (seq, td, key, base_kf) = nm_key(w, h)
  // Source = key reconstruction shifted by 4 columns, computed as a
  // deterministic pattern that ME will lock to a uniform non-zero MV.
  let src_y = FixedArray::make(w * h, 0)
  let src_u = FixedArray::make(cw * ch, 0)
  let src_v = FixedArray::make(cw * ch, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = 96 + (y * 13 + (x + 4) % w * 5) % 64
      src_y[y * w + x] = v
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      src_u[y * cw + x] = base_kf.u[y * base_kf.uv_stride + x]
      src_v[y * cw + x] = base_kf.v[y * base_kf.uv_stride + x]
    }
  }
  let (d0, kf0) = nm_fresh(key)
  let (n_base, e0) = nm_encode(
    seq, td, d0, kf0, src_y, src_u, src_v, w, h, 0, true,
  )
  let (d1, kf1) = nm_fresh(key)
  let (n_skip, e1) = nm_encode(
    seq, td, d1, kf1, src_y, src_u, src_v, w, h, 100, true,
  )
  let (d2, kf2) = nm_fresh(key)
  let (n_skip2, e2) = nm_encode(
    seq, td, d2, kf2, src_y, src_u, src_v, w, h, 100, true,
  )
  println("NEARMV skip: base=\{n_base} skip=\{n_skip} skip2=\{n_skip2}")
  // Prove the skip engaged on a non-zero MV: ME on this source against
  // the key reconstruction must find a horizontal displacement.
  let (my, mx) = match
    @libavcodec.av1_enc_me_fullpel_sad(
      src_y,
      w,
      kf0.y,
      kf0.y_stride,
      w,
      h,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail("me: \{e}")
  }
  if my[0] == 0 && mx[0] == 0 {
    fail("fixture did not produce a non-zero MV — NEARMV not exercised")
  }
  if !e0 || !e1 || !e2 {
    fail("NEARMV skip frame not exact")
  }
  if n_skip != n_skip2 {
    fail("NEARMV skip nondeterministic: \{n_skip} vs \{n_skip2}")
  }
  if n_skip * 3 >= n_base {
    fail("NEARMV skip did not shrink: \{n_base} -> \{n_skip}")
  }
}
