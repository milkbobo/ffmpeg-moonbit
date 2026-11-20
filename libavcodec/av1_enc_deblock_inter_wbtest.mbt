///|
/// §468c: encoder-side deblocking for INTER frames.
///
/// The inter path codes a whole 64x64 superblock with var-tx SPLIT into
/// four TX_32X32 leaves. With a non-zero loop-filter level the decoder
/// deblocks, so the encoder's expected planes must be deblocked the same
/// way for "decode == expected" to hold.

///|
fn dbi_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
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
/// Assert a decoded frame equals the expected planes pixel for pixel.
fn dbi_assert(
  got : Av1FrameOutput,
  exp : Av1EncPlanes,
  w : Int32,
  h : Int32,
  tag : String,
) -> Unit raise {
  let cw = w >> 1
  let ch = h >> 1
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
  println("\{tag}: Y=\{yd} UV=\{uvd}")
  if yd != 0 || uvd != 0 {
    fail("\{tag}: decode != expected (Y=\{yd} UV=\{uvd})")
  }
}

///|
test "av1 enc deblock inter: decode equals expected with lf on" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  for lf in [8, 32, 63] {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let dec = Av1Decoder::new()
    // Frame 0 = key (no filter), frame 1 = inter WITH the filter.
    let src0 : Av1EncPlanes = {
      y: dbi_src(w, h, 1),
      y_stride: w,
      u: dbi_src(cw, ch, 2),
      uv_stride: cw,
      v: dbi_src(cw, ch, 3),
    }
    let (pkt0, _) = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let _ = match dec.decode_packet(pkt0) {
      Ok(Some(f)) => f
      Ok(None) => fail("key hidden")
      Err(e) => fail("key decode: \{e}")
    }
    let src1 : Av1EncPlanes = {
      y: dbi_src(w, h, 5),
      y_stride: w,
      u: dbi_src(cw, ch, 6),
      uv_stride: cw,
      v: dbi_src(cw, ch, 7),
    }
    let (pkt1, exp1) = match
      enc.encode_frame(
        src1,
        base_q_idx=100,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("inter lf=\{lf}: \{e}")
    }
    let got = match dec.decode_packet(pkt1) {
      Ok(Some(f)) => f
      Ok(None) => fail("inter hidden")
      Err(e) => fail("inter decode lf=\{lf}: \{e}")
    }
    dbi_assert(got, exp1, w, h, "inter lf=\{lf}")
  }
}

///|
/// The filter must actually change the inter reconstruction (otherwise the
/// test above would pass vacuously).
test "av1 enc deblock inter: the filter changes the reconstruction" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let run = fn(lf : Int32) -> Av1EncPlanes raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src0 : Av1EncPlanes = {
      y: dbi_src(w, h, 1),
      y_stride: w,
      u: dbi_src(cw, ch, 2),
      uv_stride: cw,
      v: dbi_src(cw, ch, 3),
    }
    let _ = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let src1 : Av1EncPlanes = {
      y: dbi_src(w, h, 5),
      y_stride: w,
      u: dbi_src(cw, ch, 6),
      uv_stride: cw,
      v: dbi_src(cw, ch, 7),
    }
    let (_, exp) = match
      enc.encode_frame(
        src1,
        base_q_idx=100,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("inter lf=\{lf}: \{e}")
    }
    exp
  }
  let off = run(0)
  let on = run(32)
  let mut diff = 0
  for i in 0..<(w * h) {
    if off.y[i] != on.y[i] {
      diff = diff + 1
    }
  }
  println("inter deblock changed \{diff} luma pixels")
  if diff == 0 {
    fail("inter deblocking did not change the reconstruction")
  }
}

///|
/// Default lf=0 must stay byte-identical to before.
test "av1 enc deblock inter: default lf=0 unchanged" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let run = fn(explicit : Bool) -> Bytes raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src0 : Av1EncPlanes = {
      y: dbi_src(w, h, 1),
      y_stride: w,
      u: dbi_src(cw, ch, 2),
      uv_stride: cw,
      v: dbi_src(cw, ch, 3),
    }
    let _ = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let src1 : Av1EncPlanes = {
      y: dbi_src(w, h, 5),
      y_stride: w,
      u: dbi_src(cw, ch, 6),
      uv_stride: cw,
      v: dbi_src(cw, ch, 7),
    }
    let r = if explicit {
      enc.encode_frame(
        src1,
        base_q_idx=100,
        loop_filter_level0=0,
        loop_filter_level1=0,
      )
    } else {
      enc.encode_frame(src1, base_q_idx=100)
    }
    let (pkt, _) = match r {
      Ok(v) => v
      Err(e) => fail("inter: \{e}")
    }
    pkt
  }
  let a = run(false)
  let b = run(true)
  if a.length() != b.length() {
    fail("default vs explicit lf=0 inter length differs")
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      fail("default vs explicit lf=0 inter byte \{i} differs")
    }
  }
}
