///|
/// §468b: encoder-side deblocking filter.
///
/// The decoder runs the in-loop deblocking filter after reconstructing, so
/// an encoder that writes a non-zero `loop_filter_level` must apply the
/// same filter to its own reconstruction — otherwise its "expected" planes
/// stop matching the decoded picture. These tests pin that contract.

///|
/// A blocky-but-gentle source: edges of ~8 levels so the deblocking filter
/// actually engages (a hard 160-level step is correctly left untouched,
/// because the filter gates on |p0-q0| against a small level-derived
/// limit).
fn db_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = if (x / 16 + y / 16) % 2 == 0 { 118 } else { 126 }
      p[y * w + x] = base + (x * 7 + y * 3 + salt * 5) % 5
    }
  }
  p
}

///|
/// §468b end-to-end: with the filter wired into the encoder, the frame's
/// "decode == expected" contract holds even at a non-zero loop-filter
/// level. This is the contract that matters — the decoder filters, and the
/// encoder's expected planes must already be filtered the same way.
test "av1 enc deblock: decode equals expected with lf on" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  for lf in [8, 32, 63] {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src : Av1EncPlanes = {
      y: db_src(w, h, 1),
      y_stride: w,
      u: db_src(cw, ch, 2),
      uv_stride: cw,
      v: db_src(cw, ch, 3),
    }
    let (pkt, exp) = match
      enc.encode_frame(
        src,
        base_q_idx=100,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("encode lf=\{lf}: \{e}")
    }
    let dec = Av1Decoder::new()
    let got = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("hidden")
      Err(e) => fail("decode lf=\{lf}: \{e}")
    }
    let mut yd = 0
    let mut uvd = 0
    for y in 0..<h {
      for x in 0..<w {
        if got.y[y * got.y_stride + x] != exp.y[y * w + x] {
          yd = yd + 1
        }
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if got.u[y * got.uv_stride + x] != exp.u[y * cw + x] {
          uvd = uvd + 1
        }
        if got.v[y * got.uv_stride + x] != exp.v[y * cw + x] {
          uvd = uvd + 1
        }
      }
    }
    println("lf=\{lf}: decode-vs-expected Y=\{yd} UV=\{uvd}")
    if yd != 0 || uvd != 0 {
      fail("lf=\{lf}: decode != expected (Y=\{yd} UV=\{uvd})")
    }
  }
}

///|
/// The filter must actually change pixels (otherwise the test above would
/// pass vacuously). Compare the filtered expected planes against the
/// unfiltered reconstruction of the same content: they must differ.
test "av1 enc deblock: the filter visibly changes the reconstruction" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let off = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
  let src : Av1EncPlanes = {
    y: db_src(w, h, 1),
    y_stride: w,
    u: db_src(cw, ch, 2),
    uv_stride: cw,
    v: db_src(cw, ch, 3),
  }
  let (_, exp_off) = match off.encode_frame(src, base_q_idx=100) {
    Ok(v) => v
    Err(e) => fail("encode off: \{e}")
  }
  let on = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
  let (_, exp_on) = match
    on.encode_frame(
      src,
      base_q_idx=100,
      loop_filter_level0=32,
      loop_filter_level1=32,
    ) {
    Ok(v) => v
    Err(e) => fail("encode on: \{e}")
  }
  let mut diff = 0
  for i in 0..<(w * h) {
    if exp_off.y[i] != exp_on.y[i] {
      diff = diff + 1
    }
  }
  println("deblock changed \{diff} luma pixels in the expected planes")
  if diff == 0 {
    fail("deblocking did not change the expected reconstruction")
  }
}

///|
/// Default (no loop-filter arguments) must behave exactly as before:
/// byte-identical to explicitly passing lf=0.
test "av1 enc deblock: default matches explicit lf=0" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src : Av1EncPlanes = {
    y: db_src(w, h, 1),
    y_stride: w,
    u: db_src(cw, ch, 2),
    uv_stride: cw,
    v: db_src(cw, ch, 3),
  }
  let encode = fn(explicit : Bool) -> (Bytes, Av1EncPlanes) raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let r = if explicit {
      enc.encode_frame(
        src,
        base_q_idx=100,
        loop_filter_level0=0,
        loop_filter_level1=0,
      )
    } else {
      enc.encode_frame(src, base_q_idx=100)
    }
    match r {
      Ok(v) => v
      Err(e) => fail("encode: \{e}")
    }
  }
  let (pa, ea) = encode(false)
  let (pb, eb) = encode(true)
  if pa.length() != pb.length() {
    fail("default vs explicit lf=0 packet length differs")
  }
  for i in 0..<pa.length() {
    if pa[i] != pb[i] {
      fail("default vs explicit lf=0 byte \{i} differs")
    }
  }
  for i in 0..<(w * h) {
    if ea.y[i] != eb.y[i] {
      fail("default vs explicit lf=0 expected plane differs at \{i}")
    }
  }
}
