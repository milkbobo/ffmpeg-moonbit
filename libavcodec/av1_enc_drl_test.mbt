// Blackbox tests for §499: NEARMV stack hits through the drl bools.
// A per-SB mv field (A / B / B / B) puts the top-right SB's mv at stack
// index 1 of the next row's left SB, so with drl enabled that block codes
// NEARMV — three mode bools and no MV payload — instead of NEWMV's joint
// plus two component diffs. Both variants must decode pixel-exactly, and
// the drl stream must be strictly cheaper.

///|
/// Textured source plane (same shape as the rd/split fixtures).
fn drl_tex_plane(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
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
/// The per-SB mv field: SB (0,0) moves by (dx=2, dy=4) (mv (16, 32) in
/// 1/8-pel), every other SB moves by (dx=8, dy=-8) (mv (64, -64)). Each
/// SB is an exact MC match (clamped construction mirrors the kernel's
/// clamped reads), so ME recovers the exact mvs.
fn drl_mixed_y(ref_y : FixedArray[Int32], w : Int32, h : Int32) -> FixedArray[Int32] {
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
      let dx = if x < 64 && y < 64 { 2 } else { 8 }
      let dy = if x < 64 && y < 64 { 4 } else { -8 }
      out[y * w + x] = ref_y[clamp(y + dy, h) * w + clamp(x + dx, w)]
    }
  }
  out
}

///|
fn drl_seq(w : Int32, h : Int32) -> @libavcodec.Av1SequenceParameters raise {
  let obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail("seq header: \{e}")
  }
  match @libavcodec.av1_parse_sequence_header(obu) {
    Ok(s) => s
    Err(e) => fail("seq parse: \{e}")
  }
}

///|
test "av1 drl: the lower row's left SB carries the top-right mv as candidate 1" {
  let w = 128
  let h = 128
  let seq = drl_seq(w, h)
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let rf : @libavcodec.Av1Rf = {
    iw4: 0,
    ih4: 0,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp: false,
    force_integer_mv: false,
    use_ref_frame_mvs: false,
    gm_types: FixedArray::make(7, 0),
    gm_matrices: FixedArray::makei(7, _ => FixedArray::make(6, 0)),
  }
  let prepared = match
    refs.prepare_frame(
      [0, 0, 0, 0, 0, 0, 0],
      seq.order_hint_bits,
      0,
      w,
      h,
      false,
      rf,
      16,
    ) {
    Ok(p) => p
    Err(e) => fail("prepare: \{e}")
  }
  let rstate = prepared.state
  // SB row 0: SB0 codes NEWMV at A = (32, 16), SB1 at B = (-64, 64).
  rstate.begin_sbrow(0, 0, 16, 0, 8)
  rstate.splat_single(0, 3, (32, 16), false, 3, 0, 0, 16, 16)
  rstate.splat_single(0, 3, (-64, 64), false, 3, 16, 0, 16, 16)
  rstate.finish_sbrow(0, 16, 0, 8)
  // SB row 1: query the left SB's stack (bs 3 = BS_64x64).
  rstate.begin_sbrow(1, 0, 16, 8, 16)
  let stack = rstate.find(0, 32, 0, 32, 1, -1, 3, true, 16, 0)
  if stack.cnt < 2 {
    fail("stack too small: cnt = \{stack.cnt}")
  }
  if stack.cands[0].mv0 != (32, 16) {
    let (y, x) = stack.cands[0].mv0
    fail("cands[0] = (\{y}, \{x}), expected A (32, 16)")
  }
  if stack.cands[1].mv0 != (-64, 64) {
    let (y, x) = stack.cands[1].mv0
    fail("cands[1] = (\{y}, \{x}), expected B (-64, 64)")
  }
}

///|
/// Encode the same key + mv-field inter twice (drl off / on) in separate
/// sessions; the NEARMV chain replaces NEWMV's joint plus two component
/// diffs on the lower-left SB, so the drl stream must shrink.
test "av1 drl: NEARMV stream is cheaper" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let key_src = @libavcodec.Av1EncPlanes::{
    y: drl_tex_plane(w, h, 0),
    y_stride: w,
    u: drl_tex_plane(cw, ch, 1),
    uv_stride: cw,
    v: drl_tex_plane(cw, ch, 2),
  }
  let run = fn(drl : Bool) -> Bytes raise {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
    let (pkt0, exp) = match enc.encode_frame(key_src) {
      Ok(v) => v
      Err(e) => fail("key encode: \{e}")
    }
    ignore(pkt0)
    let src = @libavcodec.Av1EncPlanes::{
      y: drl_mixed_y(exp.y, w, h),
      y_stride: w,
      u: exp.u,
      uv_stride: exp.uv_stride,
      v: exp.v,
    }
    let (pkt1, _) = match enc.encode_frame(src, drl~) {
      Ok(v) => v
      Err(e) => fail("inter encode (drl=\{drl}): \{e}")
    }
    pkt1
  }
  let pkt_off = run(false)
  let pkt_on = run(true)
  if pkt_on.length() >= pkt_off.length() {
    fail(
      "drl stream not cheaper: \{pkt_on.length()} vs \{pkt_off.length()} bytes",
    )
  }
}

///|
test "av1 drl: both streams decode pixel-exact" {
  let w = 128
  let h = 128
  let cw = 64
  let ch = 64
  let key_src = @libavcodec.Av1EncPlanes::{
    y: drl_tex_plane(w, h, 3),
    y_stride: w,
    u: drl_tex_plane(cw, ch, 4),
    uv_stride: cw,
    v: drl_tex_plane(cw, ch, 5),
  }
  let run = fn(drl : Bool) -> (
    @libavcodec.Av1Decoder,
    @libavcodec.Av1EncPlanes,
    Bytes,
  ) raise {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
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
      y: drl_mixed_y(exp.y, w, h),
      y_stride: w,
      u: exp.u,
      uv_stride: exp.uv_stride,
      v: exp.v,
    }
    let (pkt1, exp2) = match enc.encode_frame(src, drl~) {
      Ok(v) => v
      Err(e) => fail("inter encode (drl=\{drl}): \{e}")
    }
    (dec, exp2, pkt1)
  }
  for pair in [(false, "off"), (true, "on")] {
    let (drl, tag) = pair
    let (dec, exp, pkt1) = run(drl)
    let d = match dec.decode_packet(pkt1) {
      Ok(Some(f)) => f
      Ok(None) => fail("inter frame hidden (\{tag})")
      Err(e) => fail("inter decode (\{tag}): \{e}")
    }
    for y in 0..<h {
      for x in 0..<w {
        if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
          fail("drl \{tag} Y(\{y},\{x}) diverged")
        }
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
          d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
          fail("drl \{tag} UV(\{y},\{x}) diverged")
        }
      }
    }
  }
}
