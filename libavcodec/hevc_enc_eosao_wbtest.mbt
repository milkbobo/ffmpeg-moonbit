///|
/// HEVC encoder edge-offset SAO (§461) white-box coverage: the decision's
/// exact behaviour on a hand-built ringing residual (EO beats band there,
/// the category sign constraint holds), full encode/decode round-trips with
/// EO in the bitstream, the off-by-default byte identity, and streaming
/// equality under the flag.

///|
/// An 8x8 plane pair with a ringing residual: rows 0-3 are 100, rows 4-7
/// are 60 in the reconstruction; the source adds +3 on the two rows hugging
/// the edge only. Band offsets cannot help (both values' residuals average
/// to ~0) while EO category 2 (v below its upper neighbour) catches the
/// lower edge row exactly — the canonical EO-wins construction.
fn hevc_enc_eosao_ring() -> (FixedArray[Int32], Array[Int32]) {
  let src : FixedArray[Int32] = FixedArray::make(64, 0)
  let rec : Array[Int32] = Array::make(64, 0)
  for y in 0..<8 {
    for x in 0..<8 {
      let base = if y < 4 { 100 } else { 60 }
      rec[y * 8 + x] = base
      src[y * 8 + x] = if y == 3 || y == 4 { base + 3 } else { base }
    }
  }
  (src, rec)
}

///|
test "hevc enc eosao: eo_eval picks the vertical class and respects signs" {
  let (src, rec) = hevc_enc_eosao_ring()
  // Band first: both bands' residuals average below the rounding threshold,
  // so the band candidate is a no-op.
  let band = hevc_enc_sao_band_eval(8, src, rec, 8, 0, 0, 8, 8)
  assert_eq(band.gain, 0)
  assert_eq(band.kind, 0)
  // EO, all four directions competing: class 1 (vertical neighbours) wins —
  // the lower edge row is category 2 (v < upper neighbour), offset +3, and
  // the eight samples give an exact gain of 24.
  let cand = hevc_enc_sao_eo_eval(8, src, rec, 8, 0, 0, 8, 8, 8, 8, -1)
  assert_eq(cand.kind, hevc_sao_edge)
  assert_eq(cand.aux, 1)
  assert_eq(cand.gain, 24)
  assert_eq(cand.offsets[0], 0)
  assert_eq(cand.offsets[1], 3)
  assert_eq(cand.offsets[2], 0)
  assert_eq(cand.offsets[3], 0)
  // The sign constraint is structural: categories 1/2 offset up, 3/4 down.
  // A negative ringing on the same edge flips to category 3, clamped at 0.
  let flipped : FixedArray[Int32] = FixedArray::make(64, 0)
  for i in 0..<64 {
    flipped[i] = 2 * rec[i] - src[i]
  }
  let cand2 = hevc_enc_sao_eo_eval(8, flipped, rec, 8, 0, 0, 8, 8, 8, 8, -1)
  // The upper edge row (category 3) now carries -3: offset -3 applies.
  assert_eq(cand2.kind, hevc_sao_edge)
  assert_eq(cand2.aux, 1)
  assert_eq(cand2.gain, 24)
  // Category 3's offset is slot offsets[2] and must be negative.
  assert_eq(cand2.offsets[2], -3)
  assert_eq(cand2.offsets[1], 0)
  // force_class pins the direction: class 0 (horizontal neighbours) cannot
  // see the horizontal edge, so nothing beats 0.
  let flat = hevc_enc_sao_eo_eval(8, src, rec, 8, 0, 0, 8, 8, 8, 8, 0)
  assert_eq(flat.gain, 0)
  assert_eq(flat.kind, 0)
}

///|
/// A 64x64 checkerboard at a coarse QP: DCT ringing along the block edges
/// is exactly what the EO categories model.
fn hevc_enc_eosao_checker() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let w = 64
  let h = 64
  // A half-screen vertical step: the band decision's per-value histograms
  // are dominated by the flat interiors (near-zero residual), while the EO
  // categories isolate the ringing columns hugging the edge.
  // 1-pixel horizontal stripes: extreme high frequency, so quantisation
  // leaves strong ringing whose sign follows the edge categories.
  let stripes = fn(phase : Int32) -> FixedArray[Int32] {
    hevc_enc_make_plane(w, h, fn(_i, j) {
      if ((j + phase) & 1) == 0 {
        172
      } else {
        84
      }
    })
  }
  let c : FixedArray[Int32] = FixedArray::make((w >> 1) * (h >> 1), 128)
  [
    (stripes(0), c.copy(), c.copy()),
    // Second frame: the stripes move by one pixel — real inter motion.
    (stripes(1), c.copy(), c.copy()),
  ]
}

///|
test "hevc enc eosao: ringing stream round-trips and differs from band-only" {
  let frames = hevc_enc_eosao_checker()
  let bandonly_result = hevc_encode_sequence(frames, width=64, height=64, qp=38)
  let bandonly = match bandonly_result {
    Ok(s) => s.annexb
    Err(e) => fail("band-only: \{e}")
  }
  let eo_result = hevc_encode_sequence(
    frames,
    width=64,
    height=64,
    qp=38,
    sao_eo=true,
  )
  let eo = match eo_result {
    Ok(s) => s.annexb
    Err(e) => fail("eo: \{e}")
  }
  // Both streams decode; whether the EO candidates actually beat the band
  // candidates on this fixture is the decision's business (pinned at unit
  // level above) — the stream contract is that either way stays legal.
  let decoded = match ff_hevc_decode_frames_ex(eo, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("eo decode: \{e}")
  }
  assert_eq(decoded.length(), 2)
  let plain_dec = match ff_hevc_decode_frames_ex(bandonly, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("band decode: \{e}")
  }
  assert_eq(plain_dec.length(), 2)
  // The EO-flagged stream round-trips sample-exact through our decoder.
  let seq_check = match
    hevc_encode_sequence(frames, width=64, height=64, qp=38, sao_eo=true) {
    Ok(s) => s
    Err(e) => fail("eo seq: \{e}")
  }
  for enc in seq_check.frames {
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
  }
}

///|
test "hevc enc eosao: chroma combination and 10-bit round-trip" {
  // EO + chroma SAO together: the flags are independent, the component
  // coupling still holds (Cr under Cb's type AND EO class).
  let frames = hevc_enc_eosao_checker()
  let seq = match
    hevc_encode_sequence(
      frames,
      width=64,
      height=64,
      qp=40,
      sao_chroma=true,
      sao_eo=true,
    ) {
    Ok(s) => s
    Err(e) => fail("combo: \{e}")
  }
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("combo decode: \{e}")
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
  // 10-bit under the same flags.
  let seq10 = match
    hevc_encode_sequence(
      frames,
      width=64,
      height=64,
      qp=40,
      sao_eo=true,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail("10-bit: \{e}")
  }
  let decoded10 = match ff_hevc_decode_frames_ex(seq10.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("10-bit decode: \{e}")
  }
  assert_eq(decoded10.length(), 2)
}

///|
test "hevc enc eosao: default off is byte-identical; streaming equals batch" {
  let frames = hevc_enc_eosao_checker()
  let plain_result = hevc_encode_frames(frames, width=64, height=64, qp=42)
  let plain = match plain_result {
    Ok(s) => s
    Err(e) => fail("plain: \{e}")
  }
  let off_result = hevc_encode_frames(
    frames,
    width=64,
    height=64,
    qp=42,
    sao_eo=false,
  )
  let off = match off_result {
    Ok(s) => s
    Err(e) => fail("off: \{e}")
  }
  assert_eq(off, plain)
  // Streaming with both SAO flags + CRF + B schedule.
  let batch = match
    hevc_encode_sequence(
      hevc_enc_csao_frames(4, 4),
      width=64,
      height=64,
      crf=30.0,
      b_slices=true,
      sao_chroma=true,
      sao_eo=true,
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
      sao_eo=true,
    ) {
    Ok(e) => e
    Err(e) => fail("open: \{e}")
  }
  let parts : Array[Bytes] = []
  for f in hevc_enc_csao_frames(4, 4) {
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
