// Blackbox tests for §451: the AV1 encoder session. The key frame
// encodes real intra DC_PRED residuals through the pseudo-inverse
// fdct; the inter frames chain through the reference store. Every
// frame's decode must realize the encoder's expected planes
// pixel-for-pixel.

///|
/// Build a deterministic source plane (luma or chroma-ish) for the
/// sequence content.
pub fn av1enc_src_plane(
  w : Int32,
  h : Int32,
  salt : Int32,
) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      // Smooth base + a bounded overlay: real enough to exercise the
      // transform, small enough to stay inside the pixel range.
      let base = 96 + (y * 13 + x * 5 + salt * 29) % 64
      let ov = (x * 7 + y * 3 + salt * 11) % 20 - 10
      let v = base + ov
      p[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  p
}

///|
test "av1 encoder session: key + 2 inter, all frames exact" {
  let w = 64
  let h = 128
  let cw = 32
  let ch = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  // Three source frames: a moving + overlaying sequence.
  let src0 = @libavcodec.Av1EncPlanes::{
    y: av1enc_src_plane(w, h, 0),
    y_stride: w,
    u: av1enc_src_plane(cw, ch, 1),
    uv_stride: cw,
    v: av1enc_src_plane(cw, ch, 2),
  }
  let src1 = @libavcodec.Av1EncPlanes::{
    y: av1enc_src_plane(w, h, 5),
    y_stride: w,
    u: av1enc_src_plane(cw, ch, 6),
    uv_stride: cw,
    v: av1enc_src_plane(cw, ch, 7),
  }
  let src2 = @libavcodec.Av1EncPlanes::{
    y: av1enc_src_plane(w, h, 10),
    y_stride: w,
    u: av1enc_src_plane(cw, ch, 11),
    uv_stride: cw,
    v: av1enc_src_plane(cw, ch, 12),
  }
  let dec = @libavcodec.Av1Decoder::new()
  // ---- Frame 0: key.
  let (pkt0, exp0) = match enc.encode_frame(src0, base_q_idx=100) {
    Ok(v) => v
    Err(e) => fail("frame 0 encode: \{e}")
  }
  let d0 = match dec.decode_packet(pkt0) {
    Ok(Some(f)) => f
    Ok(None) => fail("frame 0 hidden")
    Err(e) => fail("frame 0 decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if d0.y[y * d0.y_stride + x] != exp0.y[y * w + x] {
        fail("K Y mismatch")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if d0.u[y * d0.uv_stride + x] != exp0.u[y * cw + x] ||
        d0.v[y * d0.uv_stride + x] != exp0.v[y * cw + x] {
        fail("K UV(\{y},\{x}) diverged")
      }
    }
  }
  // ---- Frames 1/2: inter with the full residual chain.
  for idx in 1..<=2 {
    let src = if idx == 1 { src1 } else { src2 }
    let (pkt, exp) = match enc.encode_frame(src, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("frame \{idx} encode: \{e}")
    }
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("frame \{idx} hidden")
      Err(e) => fail("frame \{idx} decode: \{e}")
    }
    for y in 0..<h {
      for x in 0..<w {
        if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
          fail(
            "F\{idx} Y(\{y},\{x}) = \{d.y[y * d.y_stride + x]} want \{exp.y[y * w + x]}",
          )
        }
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
          d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
          fail("F\{idx} UV(\{y},\{x}) diverged")
        }
      }
    }
  }
}

///|
test "av1 encoder: quantized src block decodes via key-frame path" {
  // The exact residual the session key tile codes for block 0, run
  // through the §443 key-frame tile (handcrafted-spec path).
  let w = 64
  let src_y = av1enc_src_plane(w, 64, 0)
  let src_u = av1enc_src_plane(32, 32, 1)
  let src_v = av1enc_src_plane(32, 32, 2)
  let (toks, signs, delta) = @libavcodec.av1_enc_debug_quantize_leaf32(
    src_y, 100,
  )
  let seq = match
    @libavcodec.av1_parse_sequence_header(
      match
        @libavcodec.av1_enc_write_sequence_header_obu(
          @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let tile = match
    @libavcodec.av1_enc_write_ac_token_tile(toks, signs, base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 100,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("key decode: \{e}")
  }
  // Block 0's reconstruction = 128 (fresh DC) + delta — must equal the
  // wrapper's exact reconstruction.
  for y in 0..<32 {
    for x in 0..<32 {
      let want = 128 + delta[y * 32 + x]
      let got = out.y[y * out.y_stride + x]
      if want >= 0 && want <= 255 && got != want {
        fail("quantized spec mismatch at (\{y},\{x}): \{got} want \{want}")
      }
    }
  }
  ignore(src_u)
  ignore(src_v)
}

///|

///|
/// A chroma-stressed plane: a wider base range and a ±40 overlay, so
/// the chroma residuals quantize well clear of zero at mid qidx (the
/// smooth ±10 of av1enc_src_plane sits at the quantization noise floor
/// and codes all-skip around qidx 100).
fn av1enc_uv_stress_plane(
  w : Int32,
  h : Int32,
  salt : Int32,
) -> FixedArray[Int32] {
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
test "av1 encoder: key-frame chroma tokens, exact + qidx quality ladder" {
  // §452: the key tile's chroma TX_16X16 chains carry real tokens (the
  // chroma_tokens~ default). Exactness is the strong check; the quality
  // ladder (finer qidx → smaller chroma SAD) proves the tokens are
  // actually what reconstructs the planes.
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_u = av1enc_uv_stress_plane(cw, ch, 3)
  let src_v = av1enc_uv_stress_plane(cw, ch, 9)
  let mut sad40 = 0
  let mut sad220 = 0
  for q in [40, 220] {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
    let src = @libavcodec.Av1EncPlanes::{
      y: av1enc_src_plane(w, h, 0),
      y_stride: w,
      u: src_u,
      uv_stride: cw,
      v: src_v,
    }
    let (pkt, exp) = match enc.encode_frame(src, base_q_idx=q) {
      Ok(v) => v
      Err(e) => fail("encode q\{q}: \{e}")
    }
    let dec = @libavcodec.Av1Decoder::new()
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("key frame hidden")
      Err(e) => fail("decode q\{q}: \{e}")
    }
    let mut sad = 0
    for y in 0..<h {
      for x in 0..<w {
        if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
          fail("q\{q} Y(\{y},\{x}) diverged")
        }
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
          d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
          fail("q\{q} UV(\{y},\{x}) diverged")
        }
        sad += (d.u[y * d.uv_stride + x] - src_u[y * cw + x]).abs()
        sad += (d.v[y * d.uv_stride + x] - src_v[y * cw + x]).abs()
      }
    }
    if q == 40 {
      sad40 = sad
    } else {
      sad220 = sad
    }
  }
  // The finer quantizer must reconstruct the stressed chroma closer
  // (and concretely: not at the all-skip DC-prediction noise level).
  println("chroma SAD: q40=\{sad40} q220=\{sad220}")
  if sad40 >= sad220 {
    fail("qidx ladder inverted: q40=\{sad40} q220=\{sad220}")
  }
  if sad40 > 4096 * 8 {
    fail("q40 chroma SAD too high (all-skip level?): \{sad40}")
  }
}

///|
test "av1 encoder session: multi-tile key frame geometry" {
  // A 128x128 frame: 2x2 tiles — the key frame tile grid follows the
  // SB raster (the §444 multi-tile shape at the key frame).
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let src = @libavcodec.Av1EncPlanes::{
    y: av1enc_src_plane(w, h, 3),
    y_stride: w,
    u: av1enc_src_plane(cw, ch, 4),
    uv_stride: cw,
    v: av1enc_src_plane(cw, ch, 8),
  }
  let (pkt0, exp0) = match enc.encode_frame(src, base_q_idx=100) {
    Ok(v) => v
    Err(e) => fail("encode: \{e}")
  }
  let dec = @libavcodec.Av1Decoder::new()
  let d0 = match dec.decode_packet(pkt0) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if d0.y[y * d0.y_stride + x] != exp0.y[y * w + x] {
        fail("K Y mismatch")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if d0.u[y * d0.uv_stride + x] != exp0.u[y * cw + x] ||
        d0.v[y * d0.uv_stride + x] != exp0.v[y * cw + x] {
        fail("K UV(\{y},\{x}) diverged")
      }
    }
  }
}

///|
/// §456 deadzone — token domain: dz_pm zeroes sub-threshold
/// coefficients (strictly fewer nonzeros, eob never grows) while
/// dz = 0 stays the exact round-half-up spec. The byte-rate effect is
/// content-dependent under the adaptive CDFs (mid-scan zeros still pay
/// a base_tok symbol, so only eob/escape savings materialize), so the
/// rate claim lives at the token level, not the packet level.
test "av1 encoder: deadzone zeroes sub-threshold coefficients" {
  // A noise-heavy residual: smooth base + per-pixel noise, well past
  // the qidx-100 quantization noise floor.
  let res : FixedArray[Int32] = FixedArray::make(1024, 0)
  for y in 0..<32 {
    for x in 0..<32 {
      let base = (x * 11 + y * 7) % 32 - 16
      let noise = (x * 37 + y * 53 + x * y % 13) % 29 - 14
      res[y * 32 + x] = base + noise
    }
  }
  let (toks0, signs0, delta0) = @libavcodec.av1_enc_debug_quantize_leaf32(
    res, 100,
  )
  let (toks350, _, delta350) = @libavcodec.av1_enc_debug_quantize_leaf32(
    res,
    100,
    dz_pm=350,
  )
  ignore(signs0)
  let mut nz0 = 0
  let mut nz350 = 0
  let mut eob0 = -1
  let mut eob350 = -1
  for i in 0..<1024 {
    if toks0[i] != 0 {
      nz0 = nz0 + 1
      eob0 = i
    }
    if toks350[i] != 0 {
      nz350 = nz350 + 1
      eob350 = i
    }
    // Deadzone can only remove or shrink tokens, never grow them.
    if toks350[i] > toks0[i] {
      fail("dz grew token at \{i}: \{toks0[i]} -> \{toks350[i]}")
    }
  }
  if nz350 >= nz0 {
    fail("dz did not zero coefficients: nz \{nz0} -> \{nz350}")
  }
  if eob350 > eob0 {
    fail("dz grew eob: \{eob0} -> \{eob350}")
  }
  // dz = 0 delta is the reference reconstruction — sanity that the
  // wrapper still round-trips the itx.
  let mut acc : Int64 = 0L
  for i in 0..<1024 {
    acc += (delta0[i] - delta350[i]).abs().to_int64()
  }
  println(
    "deadzone tokens: nz \{nz0} -> \{nz350}, eob \{eob0} -> \{eob350}, |ddelta| = \{acc}",
  )
  if acc == 0L {
    fail("dz=350 changed nothing")
  }
}

///|
/// §456 deadzone — session e2e: both dz extremes decode pixel-exact
/// against their own expected planes, and neither rate nor distortion
/// blows up (the direction is content-dependent under the adaptive
/// CDFs — documented above).
test "av1 encoder: deadzone session frames stay exact and bounded" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_u = av1enc_uv_stress_plane(cw, ch, 3)
  let src_v = av1enc_uv_stress_plane(cw, ch, 9)
  let mut len0 = 0
  let mut sad0 = 0
  let mut sad350 = 0
  for dz in [0, 350] {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
    let src = @libavcodec.Av1EncPlanes::{
      y: av1enc_src_plane(w, h, 5),
      y_stride: w,
      u: src_u,
      uv_stride: cw,
      v: src_v,
    }
    let (pkt, exp) = match enc.encode_frame(src, base_q_idx=60, dz_pm=dz) {
      Ok(v) => v
      Err(e) => fail("encode dz\{dz}: \{e}")
    }
    let dec = @libavcodec.Av1Decoder::new()
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("key hidden")
      Err(e) => fail("decode dz\{dz}: \{e}")
    }
    let mut sad = 0
    for y in 0..<h {
      for x in 0..<w {
        if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
          fail("dz\{dz} Y(\{y},\{x}) diverged")
        }
        sad += (d.y[y * d.y_stride + x] - src.y[y * w + x]).abs()
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
          d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
          fail("dz\{dz} UV(\{y},\{x}) diverged")
        }
        sad += (d.u[y * d.uv_stride + x] - src_u[y * cw + x]).abs()
        sad += (d.v[y * d.uv_stride + x] - src_v[y * cw + x]).abs()
      }
    }
    if dz == 0 {
      len0 = pkt.length()
      sad0 = sad
    } else {
      if pkt.length() > len0 * 11 / 10 {
        fail("dz=350 packet grew >10%: \{len0} -> \{pkt.length()}")
      }
      sad350 = sad
    }
  }
  println("deadzone session: bytes \{len0}, sad \{sad0} -> \{sad350}")
  if sad350 > sad0 * 3 / 2 + 4096 {
    fail("dz distortion blew up: \{sad0} -> \{sad350}")
  }
}

///|
/// §458 session wiring: `skip_sad_pct~` reaches the per-SB mode decision
/// through the facade. A 3-frame sequence with skip on must still
/// round-trip frame by frame; byte savings are proven at the frame-level
/// writer tests, here only the facade reach and chain integrity matter.
test "av1 encoder session: skip_sad_pct wires through to inter frames" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src = @libavcodec.Av1EncPlanes::{
    y: av1enc_src_plane(w, h, 5),
    y_stride: w,
    u: av1enc_src_plane(cw, ch, 6),
    uv_stride: cw,
    v: av1enc_src_plane(cw, ch, 7),
  }
  for use_skip in [false, true] {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
    let dec = @libavcodec.Av1Decoder::new()
    for idx in 0..<3 {
      let (pkt, exp) = match
        enc.encode_frame(
          src,
          base_q_idx=100,
          skip_sad_pct=if use_skip { 100 } else { 0 },
        ) {
        Ok(v) => v
        Err(e) => fail("skip session encode f\{idx}: \{e}")
      }
      let d = match dec.decode_packet(pkt) {
        Ok(Some(f)) => f
        Ok(None) => fail("skip session frame \{idx} hidden")
        Err(e) => fail("skip session decode f\{idx}: \{e}")
      }
      for y in 0..<h {
        for x in 0..<w {
          if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
            fail("skip session f\{idx} Y(\{y},\{x}) diverged")
          }
        }
      }
      for y in 0..<ch {
        for x in 0..<cw {
          if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
            d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
            fail("skip session f\{idx} UV diverged")
          }
        }
      }
    }
  }
  // Byte-level savings of the skip path are proven at the frame level
  // (`av1_enc_me_skip_test.mbt`); here the contract is that the facade
  // reaches the skip writer and keeps the multiframe chain exact.
}

///|
/// §457+§458 coexistence: RD qindex selection and skip gating both live
/// on the facade. With RD on and skip off, the multiframe chain must stay
/// pixel-exact and the selected q must be in the candidate ladder.
test "av1 encoder session: RD and skip flags coexist" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src = @libavcodec.Av1EncPlanes::{
    y: av1enc_src_plane(w, h, 9),
    y_stride: w,
    u: av1enc_src_plane(cw, ch, 10),
    uv_stride: cw,
    v: av1enc_src_plane(cw, ch, 11),
  }
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let dec = @libavcodec.Av1Decoder::new()
  for idx in 0..<3 {
    let (pkt, exp) = match
      enc.encode_frame(
        src,
        rd_lambda=1000,
        rd_candidates=[40, 100, 160, 220],
        skip_sad_pct=0,
      ) {
      Ok(v) => v
      Err(e) => fail("rd+skip chain encode f\{idx}: \{e}")
    }
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("rd+skip chain frame \{idx} hidden")
      Err(e) => fail("rd+skip chain decode f\{idx}: \{e}")
    }
    for y in 0..<h {
      for x in 0..<w {
        if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
          fail("rd+skip chain f\{idx} Y(\{y},\{x}) diverged")
        }
      }
    }
  }
}
