// Blackbox tests for §498: per-SB 64x64-vs-32x32 partition decisions.
// The split path must round-trip pixel-exactly through the decoder, the
// decision must fire exactly where the quadrant motion demands it, and
// the all-NONE output must stay byte-identical to the single-partition
// writer.

///|
/// Textured source plane (same shape as the rd-test fixture): a strong
/// overlay keeps the ME landscape unambiguous, so exact-match shifts are
/// the unique SAD-0 points.
fn split_tex_plane(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
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
/// Shift a plane by (dx, dy) with edge clamping — mirrors the MC kernel's
/// clamped reads, so a whole-plane shift is reconstructed exactly under
/// the mv (dy * 8, dx * 8).
fn split_shift_plane(
  p : FixedArray[Int32],
  w : Int32,
  h : Int32,
  dx : Int32,
  dy : Int32,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  for y in 0..<h {
    for x in 0..<w {
      out[y * w + x] = p[clamp(y + dy, h) * w + clamp(x + dx, w)]
    }
  }
  out
}

///|
/// Per-quadrant motion inside SB (0,0): q0 static, q1 shifted +8 px
/// horizontally, q2 +8 px vertically, q3 diagonally — each quadrant is
/// an exact MC match (SAD 0), while no single 64x64 mv fits all four.
/// Every other SB stays static.
fn split_mixed_y(
  ref_y : FixedArray[Int32],
  w : Int32,
  h : Int32,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for i in 0..<(w * h) {
    out[i] = ref_y[i]
  }
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  for y in 0..<64 {
    for x in 0..<64 {
      let q = (x / 32) + (y / 32) * 2
      let dx = if q % 2 == 1 { 8 } else { 0 }
      let dy = if q / 2 == 1 { 8 } else { 0 }
      out[y * w + x] = ref_y[clamp(y + dy, h) * w + clamp(x + dx, w)]
    }
  }
  out
}

///|
/// Manual sequence header + a reference store refreshed like a key frame
/// (the rd-test pattern), for driving the partitioned entry directly.
fn split_seq_refs(
  w : Int32,
  h : Int32,
) -> (@libavcodec.Av1SequenceParameters, @libavcodec.Av1RefmvsReferenceStore) raise {
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
  (seq, refs)
}

///|
test "av1 split: decision rule" {
  // Strict quadrant win splits; ties and losses keep NONE; the margin
  // eats small wins.
  inspect(@libavcodec.av1_enc_split_decide(1000L, [200L, 200L, 200L, 200L], 0), content="true")
  inspect(@libavcodec.av1_enc_split_decide(1000L, [250L, 250L, 250L, 250L], 0), content="false")
  inspect(@libavcodec.av1_enc_split_decide(1000L, [230L, 230L, 230L, 230L], 71), content="true")
  inspect(@libavcodec.av1_enc_split_decide(1000L, [230L, 230L, 230L, 230L], 81), content="false")
  inspect(@libavcodec.av1_enc_split_decide(0L, [0L, 0L, 0L, 0L], 0), content="false")
}

///|
test "av1 split: mixed partition frame decodes pixel-exact" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  // Key frame through the session (the decoder needs one before any
  // inter frame), then the partitioned inter entry against the key's
  // reconstruction.
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let key_src = @libavcodec.Av1EncPlanes::{
    y: split_tex_plane(w, h, 0),
    y_stride: w,
    u: split_tex_plane(cw, ch, 1),
    uv_stride: cw,
    v: split_tex_plane(cw, ch, 2),
  }
  let dec = @libavcodec.Av1Decoder::new()
  let (pkt0, exp) = match enc.encode_frame(key_src) {
    Ok(v) => v
    Err(e) => fail("key encode: \{e}")
  }
  match dec.decode_packet(pkt0) {
    Ok(Some(_)) => ()
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // Encoder-side mirror of the key's reference refresh.
  let (seq, refs) = split_seq_refs(w, h)
  ignore(seq)
  let src_y = split_mixed_y(exp.y, w, h)
  let (obu, ey, eu, ev, splits) = match
    @libavcodec.av1_enc_write_me_res_part420_inter_frame_obu(
      seq,
      refs,
      src_y,
      w,
      exp.u,
      exp.uv_stride,
      exp.v,
      exp.y,
      exp.y_stride,
      exp.u,
      exp.uv_stride,
      exp.v,
      base_q_idx=100,
    ) {
    Ok(v) => v
    Err(e) => fail("split encode: \{e}")
  }
  // SB (0,0) has per-quadrant motion (split); the rest are static (NONE).
  inspect(splits[0], content="true")
  inspect(splits[1], content="false")
  inspect(splits[2], content="false")
  inspect(splits[3], content="false")
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let parts : Array[Byte] = []
  for i in 0..<td.length() {
    parts.push(td[i])
  }
  for i in 0..<obu.length() {
    parts.push(obu[i])
  }
  let d = match dec.decode_packet(Bytes::from_array(parts[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if d.y[y * d.y_stride + x] != ey[y * w + x] {
        fail("split Y(\{y},\{x}) diverged")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if d.u[y * d.uv_stride + x] != eu[y * cw + x] ||
        d.v[y * d.uv_stride + x] != ev[y * cw + x] {
        fail("split UV(\{y},\{x}) diverged")
      }
    }
  }
}

///|
///|
/// Chroma sources for the mixed-motion frame: `moving=true` shifts each
/// chroma quadrant (16x16) by its luma quadrant's shift halved, making
/// every chroma residual an exact MC match (zero → all-skip); `moving=
/// false` leaves chroma static, so the split SBs carry real chroma
/// residuals.
fn split_mixed_chroma(
  ref_p : FixedArray[Int32],
  cw : Int32,
  ch : Int32,
  moving : Bool,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  for i in 0..<(cw * ch) {
    out[i] = ref_p[i]
  }
  if !moving {
    return out
  }
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  // SB (0,0)'s chroma quadrants (16x16 each): q1 +4 px horizontal,
  // q2 +4 px vertical, q3 diagonal — halving the luma quadrant shifts.
  for y in 0..<32 {
    for x in 0..<32 {
      let q = (x / 16) + (y / 16) * 2
      let dx = if q % 2 == 1 { 4 } else { 0 }
      let dy = if q / 2 == 1 { 4 } else { 0 }
      out[y * cw + x] = ref_p[clamp(y + dy, ch) * cw + clamp(x + dx, cw)]
    }
  }
  out
}

///|
test "av1 split: chroma residuals are coded on split SBs" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let key_src = @libavcodec.Av1EncPlanes::{
    y: split_tex_plane(w, h, 21),
    y_stride: w,
    u: split_tex_plane(cw, ch, 22),
    uv_stride: cw,
    v: split_tex_plane(cw, ch, 23),
  }
  let dec = @libavcodec.Av1Decoder::new()
  let (pkt0, exp) = match enc.encode_frame(key_src) {
    Ok(v) => v
    Err(e) => fail("key encode: \{e}")
  }
  match dec.decode_packet(pkt0) {
    Ok(Some(_)) => ()
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  let (seq, refs_a) = split_seq_refs(w, h)
  ignore(seq)
  let refs_b = @libavcodec.av1_refmvs_reference_store_new()
  refs_b.refresh_without_mvs(0, w, h, 255)
  let src_y = split_mixed_y(exp.y, w, h)
  let encode = fn(
    refs,
    src_u : FixedArray[Int32],
    src_v : FixedArray[Int32],
  ) -> (
    Bytes,
    FixedArray[Int32],
    FixedArray[Int32],
  ) raise {
    match
      @libavcodec.av1_enc_write_me_res_part420_inter_frame_obu(
        seq,
        refs,
        src_y,
        w,
        src_u,
        cw,
        src_v,
        exp.y,
        exp.y_stride,
        exp.u,
        exp.uv_stride,
        exp.v,
        base_q_idx=100,
      ) {
      Ok((obu, _, eu, ev, _)) => (obu, eu, ev)
      Err(e) => fail("split encode: \{e}")
    }
  }
  // Static chroma: the split SB's chroma residuals are real (tokens
  // coded). Moving chroma: every quadrant is an exact match (all-skip).
  let (pkt_a, eu_a, _) = encode(refs_a, exp.u, exp.v)
  let (pkt_b, eu_b, _) = encode(
    refs_b,
    split_mixed_chroma(exp.u, cw, ch, true),
    split_mixed_chroma(exp.v, cw, ch, true),
  )
  if pkt_a.length() <= pkt_b.length() {
    fail(
      "chroma tokens did not grow the stream: \{pkt_a.length()} vs \{pkt_b.length()}",
    )
  }
  // The static-chroma run's reconstruction carries the chroma correction
  // (differences against the all-skip reconstruction inside SB 0).
  let mut diff = 0
  for y in 0..<32 {
    for x in 0..<32 {
      if eu_a[y * cw + x] != eu_b[y * cw + x] {
        diff += 1
      }
    }
  }
  if diff == 0 {
    fail("no chroma correction in the split SB reconstruction")
  }
  // Both streams decode pixel-exactly — each in its own decoder, since
  // frame A refreshes slot 0 and frame B was encoded against the key.
  for pair in [(pkt_a, eu_a, "static"), (pkt_b, eu_b, "moving")] {
    let (pkt, eu, tag) = pair
    let dec_i = @libavcodec.Av1Decoder::new()
    match dec_i.decode_packet(pkt0) {
      Ok(Some(_)) => ()
      Ok(None) => fail("key frame hidden (\{tag})")
      Err(e) => fail("key decode (\{tag}): \{e}")
    }
    let d = match dec_i.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("inter frame hidden (\{tag})")
      Err(e) => fail("inter decode (\{tag}): \{e}")
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if d.u[y * d.uv_stride + x] != eu[y * cw + x] {
          fail("chroma (\{tag}) U(\{y},\{x}) diverged")
        }
      }
    }
  }
}

///|
test "av1 split: session pipeline with split_margin" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let key_src = @libavcodec.Av1EncPlanes::{
    y: split_tex_plane(w, h, 5),
    y_stride: w,
    u: split_tex_plane(cw, ch, 6),
    uv_stride: cw,
    v: split_tex_plane(cw, ch, 7),
  }
  let dec = @libavcodec.Av1Decoder::new()
  let (pkt0, exp) = match enc.encode_frame(key_src) {
    Ok(v) => v
    Err(e) => fail("key encode: \{e}")
  }
  match dec.decode_packet(pkt0) {
    Ok(Some(_)) => ()
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  let src = @libavcodec.Av1EncPlanes::{
    y: split_mixed_y(exp.y, w, h),
    y_stride: w,
    u: exp.u,
    uv_stride: exp.uv_stride,
    v: exp.v,
  }
  let (pkt1, exp2) = match enc.encode_frame(src, split_margin=0) {
    Ok(v) => v
    Err(e) => fail("split session encode: \{e}")
  }
  let d = match dec.decode_packet(pkt1) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if d.y[y * d.y_stride + x] != exp2.y[y * w + x] {
        fail("session split Y(\{y},\{x}) diverged")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if d.u[y * d.uv_stride + x] != exp2.u[y * cw + x] ||
        d.v[y * d.uv_stride + x] != exp2.v[y * cw + x] {
        fail("session split UV(\{y},\{x}) diverged")
      }
    }
  }
}

///|
test "av1 split: all-NONE output is byte-identical to the single-partition writer" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let (seq, _) = split_seq_refs(w, h)
  let ref_y = split_tex_plane(w, h, 11)
  let ref_u = split_tex_plane(cw, ch, 12)
  let ref_v = split_tex_plane(cw, ch, 13)
  // Uniform diagonal move — every quadrant's best mv equals the SB's, so
  // the decision keeps NONE for all SBs. The chroma sources stay static,
  // so their residuals (reference minus the motion-shifted prediction)
  // are nonzero and both entries must produce identical chroma token
  // chains for the byte identity to hold.
  let src_y = split_shift_plane(ref_y, w, h, 8, 8)
  let refs_a = @libavcodec.av1_refmvs_reference_store_new()
  refs_a.refresh_without_mvs(0, w, h, 255)
  let refs_b = @libavcodec.av1_refmvs_reference_store_new()
  refs_b.refresh_without_mvs(0, w, h, 255)
  let (obu_a, _, _, _, splits) = match
    @libavcodec.av1_enc_write_me_res_part420_inter_frame_obu(
      seq,
      refs_a,
      src_y,
      w,
      ref_u,
      cw,
      ref_v,
      ref_y,
      w,
      ref_u,
      cw,
      ref_v,
    ) {
    Ok(v) => v
    Err(e) => fail("part encode: \{e}")
  }
  inspect(splits[0], content="false")
  let obu_b = match
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs_b,
      src_y,
      w,
      ref_u,
      cw,
      ref_v,
      ref_y,
      w,
      ref_u,
      cw,
      ref_v,
    ) {
    Ok(v) => v.0
    Err(e) => fail("plain encode: \{e}")
  }
  if obu_a != obu_b {
    fail(
      "all-NONE partitioned frame diverged from the single-partition writer (\{obu_a.length()} vs \{obu_b.length()} bytes)",
    )
  }
}
